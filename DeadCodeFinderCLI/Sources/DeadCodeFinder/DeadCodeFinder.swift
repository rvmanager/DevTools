// Sources/DeadCodeFinder/DeadCodeFinder.swift

import ArgumentParser
import Foundation
import IndexStoreDB

// Helper to check if symbol kinds match between SwiftSyntax and IndexStoreDB
private func symbolKindsMatch(_ syntaxKind: DefinitionKind, _ indexStoreKind: Any) -> Bool {
  let kindString = String(describing: indexStoreKind)
  switch syntaxKind {
  case .struct: return kindString.contains("struct")
  case .class: return kindString.contains("class")
  case .enum: return kindString.contains("enum")
  case .function: return kindString.contains("function")
  case .initializer: return kindString.contains("constructor") || kindString.contains("init")
  case .variable: return kindString.contains("variable") || kindString.contains("property")
  }
}

struct DeadCodeFinder: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "A tool to find unused Swift code in a project."
  )

  @Argument(help: "The root path of the Swift project to analyze.")
  private var projectPath: String

  @Option(
    name: .shortAndLong,
    help: "The path to Xcode's Index Store. Found in your project's DerivedData directory.")
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
    guard FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw ValidationError("Project path does not exist or is not a directory: \(absolutePath)")
    }
    log("Project path is valid: \(absolutePath)")

    let absoluteIndexStorePath = resolveAbsolutePath(indexStorePath)
    guard FileManager.default.fileExists(atPath: absoluteIndexStorePath, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw ValidationError(
        "Index store path does not exist or is not a directory: \(absoluteIndexStorePath)")
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
    log(
      "Found \(analysisResult.definitions.count) definitions (structs, classes, functions, etc.).")
    log("Identified \(analysisResult.entryPoints.count) potential entry points from syntax.")

    // --- STAGE 2: SYMBOL HYDRATION (IndexStoreDB) ---
    log("--- STAGE 2: Hydrating Symbols with USRs ---")
    log("Connecting to Index Store...")
    let index = try IndexStore(storePath: absoluteIndexStorePath, verbose: verbose)

    log("Hydrating \(analysisResult.definitions.count) definitions with USRs...")
    var hydratedDefinitions = [SourceDefinition]()
    var fileOccurrencesCache: [String: [SymbolOccurrence]] = [:]
    
    // Track used USRs per file to prevent incorrect re-matching
    var usedUsrsPerFile: [String: Set<String>] = [:]
    
    // Arrays for detailed failure analysis
    var definitionsRequiringFallback: [(definition: SourceDefinition, matchResult: String)] = []

    for var definition in analysisResult.definitions {
      let filePath = definition.location.filePath

      if fileOccurrencesCache[filePath] == nil {
        if verbose { log("Caching symbols for file: \(filePath)") }
        fileOccurrencesCache[filePath] = index.store.symbolOccurrences(inFilePath: filePath)
        usedUsrsPerFile[filePath] = Set<String>()
      }

      guard let occurrencesInFile = fileOccurrencesCache[filePath] else { continue }
      
      var match: SymbolOccurrence?
      var matchMethod = "FAILED"

      // Pass 1: Perfect Match (Line & Column).
      if let perfectMatch = occurrencesInFile.first(where: {
        $0.location.line == definition.location.line
          && $0.location.utf8Column == definition.location.utf8Column
          && !usedUsrsPerFile[filePath]!.contains($0.symbol.usr)
      }) {
        match = perfectMatch
        matchMethod = "Pass 1 (Perfect)"
      } else {
        // This definition failed Pass 1, track its outcome
        
        // Pass 2: Neighborhood Match (Name, Kind, and nearby Line).
        if match == nil {
          let searchNeighborhood = (definition.location.line - 2)...(definition.location.line + 2)
          if let neighborhoodMatch = occurrencesInFile.first(where: {
              searchNeighborhood.contains($0.location.line)
              && $0.symbol.name.hasPrefix(definition.name)
              && symbolKindsMatch(definition.kind, $0.symbol.kind)
              && !usedUsrsPerFile[filePath]!.contains($0.symbol.usr)
          }) {
              match = neighborhoodMatch
              matchMethod = "Pass 2 (Neighborhood)"
          }
        }
        
        // Pass 3: Line & Kind Match.
        if match == nil {
            if let lineMatch = occurrencesInFile.first(where: {
                $0.location.line == definition.location.line
                && symbolKindsMatch(definition.kind, $0.symbol.kind)
                && !usedUsrsPerFile[filePath]!.contains($0.symbol.usr)
            }) {
                match = lineMatch
                matchMethod = "Pass 3 (Line & Kind)"
            }
        }
        
        // Pass 4: Global Name & Kind Match (Ultimate Fallback).
        if match == nil {
            if let globalNameMatch = occurrencesInFile.first(where: {
                $0.symbol.name.hasPrefix(definition.name)
                && symbolKindsMatch(definition.kind, $0.symbol.kind)
                && !usedUsrsPerFile[filePath]!.contains($0.symbol.usr)
            }) {
                match = globalNameMatch
                matchMethod = "Pass 4 (Global Name)"
            }
        }
        
        definitionsRequiringFallback.append((definition, match != nil ? "OK - \(matchMethod)" : "FAIL"))
      }

      if let defOccurrence = match, !defOccurrence.symbol.usr.isEmpty {
        definition.usr = defOccurrence.symbol.usr
        hydratedDefinitions.append(definition)
        usedUsrsPerFile[filePath]!.insert(defOccurrence.symbol.usr) // Mark this USR as used
      }
    }

    let hydratedCount = hydratedDefinitions.count
    let unhydratedCount = analysisResult.definitions.count - hydratedCount
    
    log("Successfully hydrated \(hydratedCount) definitions. Failed to hydrate \(unhydratedCount).")

    // Detailed Failure Report
    if verbose && !definitionsRequiringFallback.isEmpty {
        print("\n--- Hydration Fallback Analysis ---")
        print("The following \(definitionsRequiringFallback.count) definitions failed the 'Perfect Match' and required fallbacks:")
        let failures = definitionsRequiringFallback.filter { $0.matchResult == "FAIL" }
        let successes = definitionsRequiringFallback.filter { $0.matchResult != "FAIL" }

        if !successes.isEmpty {
            print("\n[SUCCESSFUL FALLBACKS - \(successes.count)]")
            for (def, result) in successes.sorted(by: { $0.definition.location.filePath < $1.definition.location.filePath }) {
                print("  - [\(result)] \(def.name) at \(def.location.description)")
            }
        }
        
        if !failures.isEmpty {
            print("\n[FAILED FALLBACKS - \(failures.count)]")
            for (def, _) in failures.sorted(by: { $0.definition.location.filePath < $1.definition.location.filePath }) {
                 print("  - [FAIL] \(def.name) at \(def.location.description)")
            }
        }
        print("---------------------------------\n")
    }


    // --- STAGE 3: ACCURATE GRAPH CONSTRUCTION ---
    log("--- STAGE 3: Building Call Graph ---")
    let callGraph = CallGraph(definitions: hydratedDefinitions, index: index, verbose: verbose)

    // --- STAGE 4: REACHABILITY ANALYSIS ---
    log("--- STAGE 4: Analyzing for Unreachable Code ---")
    let detector = DeadCodeDetector(graph: callGraph, verbose: verbose)
    let deadSymbols = detector.findDeadCode() // CORRECTED LINE

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
