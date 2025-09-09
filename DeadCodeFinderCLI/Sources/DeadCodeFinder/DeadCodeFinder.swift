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
    // This provides the mapping from a location (file + line) to the definitive USR.
    // Map: [FilePath: [LineNumber: USR]]
    var usrLookup: [String: [Int: String]] = [:]
    var indexSymbolsByFile: [String: [(line: Int, symbol: String, usr: String)]] = [:]

    for fileURL in swiftFiles {
      let occurrences = index.store.symbolOccurrences(inFilePath: fileURL.path)
      let canonicalDefinitions = occurrences.filter {
        $0.roles.contains(.definition) && $0.roles.contains(.canonical)
      }

      for occ in canonicalDefinitions {
        usrLookup[occ.location.path, default: [:]][occ.location.line] = occ.symbol.usr
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
    // The `syntaxDefs` are the source of truth for ranges and entry points.
    // We enrich them with the USR from the lookup map.
    var hydratedDefinitions: [SourceDefinition] = []
    var unmappedCount = 0
    var exactMatches = 0
    var fuzzyMatches = 0

    for var def in syntaxAnalysis.definitions {
      if let usr = findUSRForDefinition(
        name: def.name, location: def.location, usrLookup: usrLookup, debugUSR: debugUSR)
      {
        def.usr = usr
        hydratedDefinitions.append(def)

        // Track match type for statistics
        if usrLookup[def.location.filePath]?[def.location.line] != nil {
          exactMatches += 1
        } else {
          fuzzyMatches += 1
        }
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

    if debugUSR {
      log("USR Matching Statistics:")
      log("  Exact matches: \(exactMatches)")
      log("  Fuzzy matches: \(fuzzyMatches)")
      log("  Unmapped: \(unmappedCount)")
    }

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

  private func findUSRForDefinition(
    name: String, location: SourceLocation, usrLookup: [String: [Int: String]], debugUSR: Bool
  ) -> String? {
    let filePath = location.filePath

    // Try exact match first
    if let usr = usrLookup[filePath]?[location.line] {
      if debugUSR {
        log("✅ Exact USR match for \(name) at line \(location.line)")
      }
      return usr
    }

    // Try nearby lines (±5 lines for better coverage)
    for offset in 1...5 {
      // Try lines after
      if let usr = usrLookup[filePath]?[location.line + offset] {
        if debugUSR {
          log(
            "✅ Fuzzy USR match for \(name) at line \(location.line + offset) (offset +\(offset) from SwiftSyntax line \(location.line))"
          )
        }
        return usr
      }

      // Try lines before
      let beforeLine = location.line - offset
      if beforeLine > 0, let usr = usrLookup[filePath]?[beforeLine] {
        if debugUSR {
          log(
            "✅ Fuzzy USR match for \(name) at line \(beforeLine) (offset -\(offset) from SwiftSyntax line \(location.line))"
          )
        }
        return usr
      }
    }

    // For structs/classes/enums, also try looking for any USR in the declaration range
    if location.endLine > location.line {
      for line in location.line...min(location.line + 20, location.endLine) {
        if let usr = usrLookup[filePath]?[line] {
          if debugUSR {
            log(
              "✅ Range USR match for \(name) at line \(line) (SwiftSyntax range: \(location.line)-\(location.endLine))"
            )
          }
          return usr
        }
      }
    }

    return nil
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
            "- Name: \(def.name), Kind: \(def.kind.rawValue), Location: \(def.location.line):\(def.location.column)"
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
