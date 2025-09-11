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

  private struct ReportItem: Comparable {
    let number: String
    let description: String
    private let components: [Int]

    init(number: String, symbol: SourceDefinition) {
      self.number = number
      // The leading space aligns the output nicely
      self.description =
        " \(number) \(symbol.location.description) -> \(symbol.name) [\(symbol.kind.rawValue)]"
      self.components = number.split(separator: ".").compactMap { Int($0) }
    }

    static func < (lhs: ReportItem, rhs: ReportItem) -> Bool {
      for (l, r) in zip(lhs.components, rhs.components) {
        if l != r {
          return l < r
        }
      }
      return lhs.components.count < rhs.components.count
    }

    static func == (lhs: ReportItem, rhs: ReportItem) -> Bool {
      return lhs.components == rhs.components
    }
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

  @Flag(
    name: .long,
    help:
      "Prevents the tool from flagging unreferenced public and internal properties as dead code. Use this when analyzing a library or framework."
  )
  private var respectPublicApi: Bool = false

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
    // MODIFIED: Pass the new flag and index store to the detector
    let detector = DeadCodeDetector(
      graph: callGraph,
      index: index,
      verbose: verbose,
      respectPublicApi: respectPublicApi
    )
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
    case .variable, .property:
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
      return
    }

    print("\n❌ Found \(unusedSymbols.count) potentially unused symbols:")

    // 1. Setup data structures for dead symbols only
    // CORRECTED LINE: Added explicit type annotation to help the compiler.
    let unusedUsrToDefinition = Dictionary(
      unusedSymbols.compactMap { def -> (String, SourceDefinition)? in
        guard let usr = def.usr else { return nil }
        return (usr, def)
      }, uniquingKeysWith: { (first, _) in first })
    let unusedUsrs = Set(unusedUsrToDefinition.keys)

    var deadDependencies: [String: Set<String>] = [:]
    var deadReferrers: [String: Set<String>] = [:]

    for unusedUsr in unusedUsrs {
      if let dependencies = callGraph.adjacencyList[unusedUsr] {
        deadDependencies[unusedUsr] = dependencies.filter { unusedUsrs.contains($0) }
      }
      if let referrers = callGraph.reverseAdjacencyList[unusedUsr] {
        deadReferrers[unusedUsr] = referrers.filter { unusedUsrs.contains($0) }
      }
    }

    // 2. Find connected components (islands)
    var visitedUsrs = Set<String>()
    var islands: [[SourceDefinition]] = []
    for symbol in unusedSymbols {
      guard let usr = symbol.usr, !visitedUsrs.contains(usr) else { continue }

      var currentIslandUsrs = Set<String>()
      var queue = [usr]
      visitedUsrs.insert(usr)

      while !queue.isEmpty {
        let currentUsr = queue.removeFirst()
        currentIslandUsrs.insert(currentUsr)

        let neighbors = (deadDependencies[currentUsr] ?? Set()).union(
          deadReferrers[currentUsr] ?? Set())
        for neighborUsr in neighbors where !visitedUsrs.contains(neighborUsr) {
          visitedUsrs.insert(neighborUsr)
          queue.append(neighborUsr)
        }
      }
      islands.append(currentIslandUsrs.compactMap { unusedUsrToDefinition[$0] })
    }

    // 3. Process each island to generate numbered report items
    var allReportItems: [ReportItem] = []
    for (islandIndex, island) in islands.enumerated() {
      let islandUsrs = Set(island.compactMap { $0.usr })
      var numberMap: [String: String] = [:]

      // Find leaves (symbols in the island not depending on anything else *in the island*)
      let leaves = island.filter {
        guard let usr = $0.usr else { return true }
        let dependencies = deadDependencies[usr] ?? Set()
        return dependencies.isDisjoint(with: islandUsrs)
      }.sorted { $0.name < $1.name }

      // Recursive function to traverse upwards from leaves and number referrers
      func numberReferrers(from usr: String, baseNumber: String) {
        guard
          let referrers = deadReferrers[usr]?.sorted(by: { (usrA, usrB) -> Bool in
            (unusedUsrToDefinition[usrA]?.name ?? "") < (unusedUsrToDefinition[usrB]?.name ?? "")
          })
        else { return }

        for (referrerIndex, referrerUsr) in referrers.enumerated() {
          // If a symbol refers to multiple items, it gets numbered by the first traversal
          if numberMap[referrerUsr] != nil { continue }

          let newNumber = "\(baseNumber).\(referrerIndex + 1)"
          numberMap[referrerUsr] = newNumber

          // Recurse upwards to the next level of referrers
          numberReferrers(from: referrerUsr, baseNumber: newNumber)
        }
      }

      // Start the numbering process from the leaves of the island
      for (leafIndex, leaf) in leaves.enumerated() {
        guard let leafUsr = leaf.usr, numberMap[leafUsr] == nil else { continue }

        let number = "\(islandIndex + 1).\(leafIndex)"
        numberMap[leafUsr] = number
        numberReferrers(from: leafUsr, baseNumber: number)
      }

      // Generate ReportItem objects for every symbol in the island
      for symbol in island {
        guard let usr = symbol.usr else { continue }
        // If a symbol wasn't numbered (e.g., part of a cycle), assign a base island number
        let number = numberMap[usr] ?? "\(islandIndex + 1)"
        allReportItems.append(ReportItem(number: number, symbol: symbol))
      }
    }

    // 4. Sort and print the final, formatted report
    allReportItems.sort()
    for item in allReportItems {
      print(item.description)
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
