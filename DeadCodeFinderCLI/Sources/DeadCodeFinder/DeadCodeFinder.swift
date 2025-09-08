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

    func validate() throws {
        log("Validating input paths...")
        let absolutePath = resolveAbsolutePath(projectPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ValidationError("Project path does not exist or is not a directory: \(absolutePath)")
        }
        log("Project path is valid: \(absolutePath)")
        
        let absoluteIndexStorePath = resolveAbsolutePath(indexStorePath)
        guard FileManager.default.fileExists(atPath: absoluteIndexStorePath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ValidationError("Index store path does not exist or is not a directory: \(absoluteIndexStorePath)")
        }
        log("Index store path is valid: \(absoluteIndexStorePath)")
    }

    func run() throws {
        let absolutePath = resolveAbsolutePath(projectPath)
        let absoluteIndexStorePath = resolveAbsolutePath(indexStorePath)

        log("🚀 Starting analysis of project at: \(absolutePath)")
        log("Using Index Store at: \(absoluteIndexStorePath)")

        let excludedDirs =
            exclude?.components(separatedBy: ",") ?? [".build", "Pods", "Carthage", "DerivedData"]
        log("Excluding directories: \(excludedDirs.joined(separator: ", "))")

        // --- STAGE 1: DECLARATION INVENTORY (SwiftSyntax) ---
        log("--- STAGE 1: Parsing Swift files ---")
        let swiftFiles = ProjectParser.findSwiftFiles(at: absolutePath, excluding: excludedDirs)
        log("Found \(swiftFiles.count) Swift files to analyze.")

        let analyzer = SyntaxAnalyzer(verbose: verbose)
        let analysisResult = analyzer.analyze(files: swiftFiles)
        log("Found \(analysisResult.definitions.count) definitions (structs, classes, functions, etc.).")
        log("Identified \(analysisResult.entryPoints.count) potential entry points from syntax.")
        
        // --- STAGE 2: SYMBOL HYDRATION (IndexStoreDB) ---
        log("--- STAGE 2: Hydrating Symbols with USRs ---")
        log("Connecting to Index Store...")
        let index = try IndexStore(storePath: absoluteIndexStorePath, verbose: verbose)
        
        log("Hydrating \(analysisResult.definitions.count) definitions with USRs...")
        var hydratedDefinitions = [SourceDefinition]()
        var fileOccurrencesCache: [String: [SymbolOccurrence]] = [:]
        var hydratedCount = 0
        var unhydratedCount = 0

        for var definition in analysisResult.definitions {
            let filePath = definition.location.filePath
            
            if fileOccurrencesCache[filePath] == nil {
                log("Caching symbols for file: \(filePath)")
                fileOccurrencesCache[filePath] = index.store.symbolOccurrences(inFilePath: filePath)
            }
            
            guard let occurrencesInFile = fileOccurrencesCache[filePath] else { continue }

            if verbose {
                print("\n[DEBUG] ----------------------------------------------------")
                print("[DEBUG] Attempting to match definition:")
                print("[DEBUG]   - Name: \(definition.name)")
                print("[DEBUG]   - SwiftSyntax Location: line=\(definition.location.line), utf8Column=\(definition.location.utf8Column)")
                
                let potentialMatches = occurrencesInFile.filter { $0.location.line == definition.location.line }
                
                if potentialMatches.isEmpty {
                    print("[DEBUG]   - IndexStoreDB: No symbols found on line \(definition.location.line).")
                } else {
                    print("[DEBUG]   - IndexStoreDB Symbols on line \(definition.location.line):")
                    for occ in potentialMatches {
                        print("[DEBUG]     - Symbol: \(occ.symbol.name), Kind: \(occ.symbol.kind), Location: line=\(occ.location.line), utf8Column=\(occ.location.utf8Column), Roles: \(occ.roles)")
                    }
                }
                 print("[DEBUG] ----------------------------------------------------")
            }
            
            // --- FINAL FIX ---
            // Find all symbols at the exact location.
            let potentialMatches = occurrencesInFile.filter {
                $0.location.line == definition.location.line &&
                $0.location.utf8Column == definition.location.utf8Column
            }

            // Prefer the symbol that is NOT an accessor. This handles properties vs. getters.
            // For other cases (like struct vs init), the first match is usually correct.
            let match = potentialMatches.first { !$0.roles.contains(.accessorOf) } ?? potentialMatches.first
            // --- END FINAL FIX ---

            if let defOccurrence = match, !defOccurrence.symbol.usr.isEmpty {
                definition.usr = defOccurrence.symbol.usr
                hydratedDefinitions.append(definition)
                hydratedCount += 1
                if verbose {
                    log("[HYDRATED] '\(definition.name)' -> Matched IndexStore Symbol: '\(defOccurrence.symbol.name)' (\(defOccurrence.symbol.kind)), USR: \(definition.usr ?? "N/A")")
                }
            } else {
                unhydratedCount += 1
                log("[HYDRATION WARNING] Could not find USR for \(definition.name) at \(definition.location.description)")
            }
        }
        log("Successfully hydrated \(hydratedCount) definitions. Failed to hydrate \(unhydratedCount).")
        
        // --- STAGE 3: ACCURATE GRAPH CONSTRUCTION ---
        log("--- STAGE 3: Building Call Graph ---")
        let callGraph = CallGraph(definitions: hydratedDefinitions, index: index, verbose: verbose)
        
        // --- STAGE 4: REACHABILITY ANALYSIS ---
        log("--- STAGE 4: Analyzing for Unreachable Code ---")
        let detector = DeadCodeDetector(graph: callGraph, verbose: verbose)
        let deadSymbols = detector.findDeadCode()
        
        log("Analysis complete. Found \(deadSymbols.count) dead symbols.")

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
        if message.starts(with: "---") || message.starts(with: "🚀") || !verbose {
             print("[INFO] \(message)")
        } else if verbose {
             print("[DEBUG] \(message)")
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