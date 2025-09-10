// Sources/DeadCodeFinder/DeadCodeFinder.swift

import ArgumentParser
import Foundation
import IndexStoreDB

struct DeadCodeFinder: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "A tool to find unused Swift code in a project."
  )

  // A new struct to hold rich symbol information from IndexStoreDB.
  private struct SymbolInfo {
    let usr: String
    let name: String
    let kind: IndexSymbolKind
  }

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

  @Flag(help: "Dumps all symbols from SwiftSyntax and IndexStoreDB for debugging and then exits.")
  private var dumpSymbols: Bool = false

  @Flag(help: "Enable detailed USR matching debug information.")
  private var debugUSR: Bool = false

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
    let excludedDirs =
      exclude?.components(separatedBy: ",") ?? [".build", "Pods", "Carthage", "DerivedData"]

    log("🚀 Starting analysis of project at: \(absolutePath)")
    log("Using Index Store at: \(absoluteIndexStorePath)")
    log("Excluding directories: \(excludedDirs.joined(separator: ", "))")

    // --- STAGE 1: PARSE FILES FOR ACCURATE RANGES & ENTRY POINTS ---
    log("--- STAGE 1: Parsing Swift files with SwiftSyntax ---")
    let swiftFiles = ProjectParser.findSwiftFiles(at: absolutePath, excluding: excludedDirs)
    log("Found \(swiftFiles.count) Swift files to analyze.")

    let analyzer = SyntaxAnalyzer(verbose: verbose)
    let syntaxAnalysis = analyzer.analyze(files: swiftFiles)
    log(
      "Parsed \(syntaxAnalysis.definitions.count) definitions from source code with accurate ranges and entry points."
    )

    // --- STAGE 2: HYDRATE SYNTAX DEFINITIONS WITH CANONICAL USRs ---
    log("--- STAGE 2: Hydrating syntax definitions with canonical USRs from IndexStore ---")
    let index = try IndexStore(storePath: absoluteIndexStorePath, verbose: verbose)

    if dumpSymbols {
      performComprehensiveSymbolDump(
        for: swiftFiles, with: syntaxAnalysis.definitions, index: index.store)
      log("[DEBUG] Debug dump finished. The tool will now exit.")
      return
    }

    // Step 1: Create a lookup map from IndexStoreDB's canonical definitions.
    // This provides the mapping from a location (file + line) to a list of all symbols on that line.
    var usrLookup: [String: [Int: [SymbolInfo]]] = [:]
    var indexSymbolsByFile: [String: [(line: Int, symbol: String, usr: String)]] = [:]

    for fileURL in swiftFiles {
      let occurrences = index.store.symbolOccurrences(inFilePath: fileURL.path)
      let canonicalDefinitions = occurrences.filter {
        $0.roles.contains(.definition) && $0.roles.contains(.canonical)
      }

      for occ in canonicalDefinitions {
        // Create the rich SymbolInfo object.
        let info = SymbolInfo(usr: occ.symbol.usr, name: occ.symbol.name, kind: occ.symbol.kind)
        // Append all symbols for a given line, rather than overwriting.
        usrLookup[occ.location.path, default: [:]][occ.location.line, default: []].append(info)

        // Keep the old debug structure for comparison if needed.
        indexSymbolsByFile[occ.location.path, default: []].append(
          (
            line: occ.location.line,
            symbol: occ.symbol.name,
            usr: occ.symbol.usr
          ))
      }
    }
    log("Built a USR lookup map from IndexStore's canonical symbols.")

    if debugUSR {
      log("=== USR DEBUG MODE ===")
      for (filePath, symbols) in indexSymbolsByFile.sorted(by: { $0.key < $1.key }) {
        log("IndexStore symbols in \(filePath):")
        for symbol in symbols.sorted(by: { $0.line < $1.line }) {
          log("  Line \(symbol.line): \(symbol.symbol) -> \(symbol.usr)")
        }
      }
    }

    // Step 2: Hydrate the syntax definitions with their canonical USRs.
    // We enrich them with the USR from the lookup map using our intelligent matching function.
    var hydratedDefinitions: [SourceDefinition] = []
    var unmappedCount = 0

    for var def in syntaxAnalysis.definitions {
      // Replace the old, simple lookup with the new, scoring-based matcher.
      if let usr = findBestMatchingUSR(for: def, in: usrLookup) {
        def.usr = usr
        hydratedDefinitions.append(def)
      } else {
        unmappedCount += 1
        if debugUSR {
          log("❌ Could not find USR for: \(def.name) at \(def.location.description)")
          if let symbolsInFile = indexSymbolsByFile[def.location.filePath] {
            log("   Available IndexStore symbols in this file:")
            for symbol in symbolsInFile.sorted(by: { $0.line < $1.line }) {
              log("     Line \(symbol.line): \(symbol.symbol)")
            }
          }
        } else {
          log(
            "Could not find a canonical USR for syntax definition: \(def.name) at \(def.location.description)"
          )
        }
      }
    }

    let entryPointCount = hydratedDefinitions.filter { $0.isEntryPoint }.count
    log(
      "Successfully hydrated \(hydratedDefinitions.count) definitions with USRs. \(entryPointCount) marked as entry points. \(unmappedCount) definitions could not be mapped."
    )

    // --- STAGE 3: ACCURATE GRAPH CONSTRUCTION ---
    log("--- STAGE 3: Building Call Graph ---")
    let callGraph = CallGraph(definitions: hydratedDefinitions, index: index, verbose: verbose)

    // --- STAGE 4: REACHABILITY ANALYSIS ---
    log("--- STAGE 4: Analyzing for Unreachable Code ---")
    let detector = DeadCodeDetector(graph: callGraph, verbose: verbose)
    let deadSymbols = detector.findDeadCode()

    log("Analysis complete. Found \(deadSymbols.count) dead symbols.")

    // --- REPORTING ---
    callGraph.dumpAllProcessedReferences()

    report(deadSymbols, callGraph: callGraph)
  }

  /// Finds the best-matching canonical USR for a SwiftSyntax definition by comparing it against
  /// a list of candidates from IndexStoreDB and scoring them based on kind and name.
  private func findBestMatchingUSR(
    for def: SourceDefinition,
    in usrLookup: [String: [Int: [SymbolInfo]]]
  ) -> String? {
    let filePath = def.location.filePath

    // --- Phase 1: Try for a high-quality match on the exact line ---
    if let candidates = usrLookup[filePath]?[def.location.line] {
      if let bestMatch = scoreAndSelectBestCandidate(for: def, from: candidates) {
        if debugUSR {
          log("✅ Exact line match for \(def.name) with score \(bestMatch.score)")
        }
        return bestMatch.usr
      }
    }

    // --- Phase 2: Fallback to fuzzy line matching if no exact match was found ---
    if debugUSR {
      log("No exact line match for \(def.name), trying fuzzy search...")
    }

    // Collect all candidates from a wider range of lines to find the best possible fuzzy match.
    var fuzzyCandidates: [SymbolInfo] = []
    let searchRange = (def.location.line - 2)...(def.location.endLine + 2)
    for line in searchRange {
      if let candidatesOnLine = usrLookup[filePath]?[line] {
        fuzzyCandidates.append(contentsOf: candidatesOnLine)
      }
    }

    if !fuzzyCandidates.isEmpty,
      let bestMatch = scoreAndSelectBestCandidate(for: def, from: fuzzyCandidates)
    {
      if debugUSR {
        log("✅ Fuzzy match for \(def.name) with score \(bestMatch.score)")
      }
      return bestMatch.usr
    }

    return nil
  }

  /// Shared scoring logic for selecting the best symbol candidate.
  private func scoreAndSelectBestCandidate(
    for def: SourceDefinition,
    from candidates: [SymbolInfo]
  ) -> (usr: String, score: Int)? {
    var bestMatch: (usr: String, score: Int)?

    for candidate in candidates {
      var score = 0

      // 1. PRIMARY CRITERION: Symbol Kind Match.
      if isKindMatch(syntaxKind: def.kind, indexKind: candidate.kind) {
        score += 1000
      } else {
        continue
      }

      // 2. SECONDARY CRITERION: Name Match.
      let syntaxBaseName = (def.name.components(separatedBy: ".").last ?? def.name)
      let indexBaseName = (candidate.name.components(separatedBy: "(").first ?? candidate.name)
      if syntaxBaseName == indexBaseName {
        score += 100
      }

      // 3. TIE-BREAKER: Favor shorter USRs.
      score -= candidate.usr.count

      if bestMatch == nil || score > bestMatch!.score {
        bestMatch = (usr: candidate.usr, score: score)
      }
    }
    return bestMatch
  }

  /// Helper to bridge between the tool's internal DefinitionKind and IndexStoreDB's Symbol.Kind.
  private func isKindMatch(syntaxKind: DefinitionKind, indexKind: IndexSymbolKind) -> Bool {
    switch syntaxKind {
    case .function:
      return indexKind == .function || indexKind == .instanceMethod || indexKind == .staticMethod
    case .initializer:
      return indexKind == .constructor
    case .variable:
      return indexKind == .variable || indexKind == .instanceProperty
        || indexKind == .staticProperty
    case .struct:
      return indexKind == .struct
    case .class:
      return indexKind == .class
    case .enum:
      return indexKind == .enum
    }
  }

  private func report(_ unusedSymbols: [SourceDefinition], callGraph: CallGraph) {
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
    if expandedPath.hasPrefix("/") { return expandedPath }
    let currentWorkingDirectory = FileManager.default.currentDirectoryPath
    return (currentWorkingDirectory as NSString).appendingPathComponent(expandedPath)
  }

  private func performComprehensiveSymbolDump(
    for files: [URL], with definitions: [SourceDefinition], index: IndexStoreDB
  ) {
    print("\n\n--- COMPREHENSIVE SYMBOL DUMP START ---\n")
    let defsByFile = Dictionary(grouping: definitions, by: { $0.location.filePath })
    for fileURL in files.sorted(by: { $0.path < $1.path }) {
      let filePath = fileURL.path
      print("========================================================================")
      print("Filename: \(filePath)")
      print("========================================================================")
      print("\n[SwiftSyntax Definitions]")
      if let defsInFile = defsByFile[filePath] {
        for def in defsInFile.sorted(by: { $0.location.line < $1.location.line }) {
          print(
            "- Name: \(def.name), Kind: \(def.kind.rawValue), Location: \(def.location.line):\(def.location.column)-\(def.location.endLine):\(def.location.endColumn)"
          )
        }
      } else {
        print("- No definitions found.")
      }

      print("\n[IndexStoreDB Occurrences]")
      let occurrencesInFile = index.symbolOccurrences(inFilePath: filePath)
      if occurrencesInFile.isEmpty {
        print("- No occurrences found.")
      } else {
        for occ in occurrencesInFile.sorted(by: { $0.location.line < $1.location.line }) {
          if occ.roles.contains(.definition) {
            print(
              "- Symbol: \(occ.symbol.name), Kind: \(occ.symbol.kind), USR: \(occ.symbol.usr), Location: \(occ.location.line):\(occ.location.utf8Column), Roles: \(occ.roles), Properties: \(occ.relations.map { "\($0.symbol.name): \($0.roles)" }.joined(separator: ", "))"
            )
          }
        }
      }
      print("\n")
    }
    print("\n--- COMPREHENSIVE SYMBOL DUMP COMPLETE ---\n")
  }
}
