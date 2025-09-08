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
        
        // Create a cache for file occurrences to avoid redundant lookups
        var fileOccurrencesCache: [String: [SymbolOccurrence]] = [:]

        for var definition in analysisResult.definitions {
            let filePath = definition.location.filePath
            
            // Populate the cache if this is the first time we see this file
            if fileOccurrencesCache[filePath] == nil {
                fileOccurrencesCache[filePath] = index.store.symbolOccurrences(inFilePath: filePath)
            }
            
            guard let occurrencesInFile = fileOccurrencesCache[filePath] else {
                if verbose { log("Warning: Could not get any occurrences for file \(filePath)") }
                continue
            }
            
            // Now, find the specific occurrence that matches our definition's location.
            // Note: IndexStoreDB columns are 1-based and are UTF-8 offsets. SwiftSyntax is also 1-based.
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
        
        // --- STAGE 3 & 4 (Sprint 1 Version): Unused Type Analysis ---
        log("Analyzing for unused types (structs, classes, enums)...")
        var unusedTypes = [SourceDefinition]()
        
        let typeDefinitions = hydratedDefinitions.filter {
            $0.kind == .class || $0.kind == .struct || $0.kind == .enum
        }
        
        for definition in typeDefinitions {
            guard let usr = definition.usr else { continue }
            
            if definition.isEntryPoint {
                if verbose { log("Skipping analysis for entry point: \(definition.name)")}
                continue
            }

            // Check for references
            let references = index.store.occurrences(ofUSR: usr, roles: .reference)
            
            if references.isEmpty {
                unusedTypes.append(definition)
            }
        }
        log("Analysis complete.")

        // --- REPORTING ---
        report(unusedTypes)
    }

    private func report(_ unusedSymbols: [SourceDefinition]) {
        if unusedSymbols.isEmpty {
            print("\n✅ No unused types found.")
        } else {
            print("\n❌ Found \(unusedSymbols.count) potentially unused types:")
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