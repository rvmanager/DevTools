// Sources/DeadCodeFinder/DeadCodeFinder.swift

import ArgumentParser
import Foundation
import IndexStoreDB

struct DeadCodeFinder: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "A tool to find unused Swift code in a project."
    )

    @Argument(help: "The root path of the Swift project to analyze.")
    private var projectPath: String
    
    @Option(name: .shortAndLong, help: "The path to Xcode's Index Store. Found in your project's DerivedData directory.")
    private var indexStorePath: String

    @Option(
        name: .shortAndLong,
        help: "A comma-separated list of directories to exclude from analysis (e.g., '.build,Pods').")
    private var exclude: String?

    @Flag(name: .shortAndLong, help: "Enable verbose logging for detailed analysis steps.")
    private var verbose: Bool = false

    func run() throws {
        let absolutePath = resolveAbsolutePath(projectPath)
        let absoluteIndexStorePath = resolveAbsolutePath(indexStorePath)

        log("Starting analysis of project at: \(absolutePath)")
        log("Using Index Store at: \(absoluteIndexStorePath)")

        let excludedDirs =
            exclude?.components(separatedBy: ",") ?? [".build", "Pods", "Carthage", "DerivedData"]
        log("Excluding directories: \(excludedDirs.joined(separator: ", "))")

        // --- STAGE 1: DECLARATION INVENTORY (SwiftSyntax) ---
        let swiftFiles = ProjectParser.findSwiftFiles(at: absolutePath, excluding: excludedDirs)
        log("Found \(swiftFiles.count) Swift files to analyze.")

        let analyzer = SyntaxAnalyzer(verbose: verbose)
        let analysisResult = analyzer.analyze(files: swiftFiles)
        log("Found \(analysisResult.definitions.count) definitions (structs, classes, functions, etc.).")
        log("Identified \(analysisResult.entryPoints.count) potential entry points.")
        
        // --- STAGE 2: SYMBOL HYDRATION (IndexStoreDB) ---
        log("Connecting to Index Store...")
        let index = try IndexStore(storePath: absoluteIndexStorePath)
        
        log("Hydrating \(analysisResult.definitions.count) definitions with USRs...")
        var hydratedDefinitions = [SourceDefinition]()
        var fileOccurrencesCache: [String: [SymbolOccurrence]] = [:]

        for var definition in analysisResult.definitions {
            let filePath = definition.location.filePath
            
            if fileOccurrencesCache[filePath] == nil {
                fileOccurrencesCache[filePath] = index.store.symbolOccurrences(inFilePath: filePath)
            }
            
            guard let occurrencesInFile = fileOccurrencesCache[filePath] else { continue }
            
            let match = occurrencesInFile.first { occ in
                return occ.location.line == definition.location.line
                    && occ.location.utf8Column == definition.location.column
                    && occ.roles.contains(.definition)
            }

            if let defOccurrence = match, !defOccurrence.symbol.usr.isEmpty {
                definition.usr = defOccurrence.symbol.usr
                hydratedDefinitions.append(definition)
            } else {
                if verbose { log("Warning: Could not find USR for \(definition.name) at \(definition.location.description)") }
            }
        }
        log("Successfully hydrated \(hydratedDefinitions.count) definitions.")
        
        // --- STAGE 3: ACCURATE GRAPH CONSTRUCTION ---
        log("Building accurate call graph...")
        let callGraph = CallGraph(definitions: hydratedDefinitions, index: index, verbose: verbose)
        
        // --- STAGE 4: REACHABILITY ANALYSIS ---
        log("Analyzing for unreachable (dead) code...")
        let detector = DeadCodeDetector(graph: callGraph, verbose: verbose)
        let deadSymbols = detector.findDeadCode()
        log("Analysis complete.")

        // --- REPORTING ---
        report(deadSymbols)
    }

    private func report(_ unusedSymbols: [SourceDefinition]) {
        if unusedSymbols.isEmpty {
            print("\n✅ No unused symbols found. Excellent!")
        } else {
            print("\n❌ Found \(unusedSymbols.count) potentially unused symbols:")
            let sortedSymbols = unusedSymbols.sorted {
                $0.location.filePath < $1.location.filePath
                    || ($0.location.filePath == $1.location.filePath && $0.location.line < $1.location.line)
            }
            for symbol in sortedSymbols {
                print("  - \(symbol.location.description) -> \(symbol.name) [\(symbol.kind.rawValue)]")
            }
        }
    }

    private func log(_ message: String) {
        if verbose {
            print("[INFO] \(message)")
        }
    }
    
    private func resolveAbsolutePath(_ path: String) -> String {
        let expandedPath = (path as NSString).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return expandedPath
        }
        let currentWorkingDirectory = FileManager.default.currentDirectoryPath
        return (currentWorkingDirectory as NSString).appendingPathComponent(expandedPath)
    }
}