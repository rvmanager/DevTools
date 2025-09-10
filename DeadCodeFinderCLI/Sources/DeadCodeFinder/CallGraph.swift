// Sources/DeadCodeFinder/CallGraph.swift

import Foundation
import IndexStoreDB

class CallGraph {
  private(set) var adjacencyList: [String: Set<String>] = [:]
  private(set) var reverseAdjacencyList: [String: Set<String>] = [:]

  private(set) var allProcessedReferencesLog: [String] = []

  let usrToDefinition: [String: SourceDefinition]
  let definitions: [SourceDefinition]
  let verbose: Bool

  // A pre-computed map of file paths to a sorted list of definitions within that file.
  private let geometricMap: [String: [SourceDefinition]]

  init(definitions: [SourceDefinition], index: IndexStore, verbose: Bool) {
    self.definitions = definitions
    self.verbose = verbose
    self.usrToDefinition = Dictionary(
      definitions.compactMap { def -> (String, SourceDefinition)? in
        guard let usr = def.usr else { return nil }
        return (usr, def)
      }, uniquingKeysWith: { (first, _) in first })

    // Step 1: Create the pre-computed geometric map.
    var mapBuilder: [String: [SourceDefinition]] = [:]
    for def in definitions {
      mapBuilder[def.location.filePath, default: []].append(def)
    }
    // Sort each file's definitions by starting line number for efficient searching.
    self.geometricMap = mapBuilder.mapValues { defs in
      defs.sorted { $0.location.line < $1.location.line }
    }

    buildGraph(index: index.store)
  }

  private func buildGraph(index: IndexStoreDB) {
    let uniqueDefinitionCount = usrToDefinition.count
    log("Building accurate call graph from \(uniqueDefinitionCount) unique definitions...")

    var count = 0
    for (calleeUsr, calleeDef) in usrToDefinition {
      count += 1
      if verbose && count % 50 == 0 {
        log("...processed \(count)/\(uniqueDefinitionCount) definitions for references")
      }

      // Find all occurrences where the callee is referenced.
      let references = index.occurrences(ofUSR: calleeUsr, roles: .reference)

      for reference in references {
        // Step 2: Implement the hybrid approach.
        var callerUsr: String?
        var mappingMethod: String = "UNKNOWN"

        // First, try the high-precision symbolic traversal.
        if let symbolicCallerUsr = findEnclosingKnownDefinition(for: reference, in: index) {
          callerUsr = symbolicCallerUsr
          mappingMethod = "SYMBOLIC"
        } else {
          // If symbolic traversal fails, use the geometric fallback.
          if let geometricCallerUsr = findEnclosingKnownDefinitionByLocation(for: reference) {
            callerUsr = geometricCallerUsr
            mappingMethod = "GEOMETRIC"
          }
        }

        guard let finalCallerUsr = callerUsr else {
          let mappingResult =
            "[UNMAPPED] Call to '\(calleeDef.name)' at \(reference.location.path):\(reference.location.line) -> FAILED TO MAP"
          allProcessedReferencesLog.append(mappingResult)
          if verbose {
            log(
              "Could not map reference at \(reference.location.path):\(reference.location.line) to a known definition via any method."
            )
          }
          continue
        }

        guard let callerDef = usrToDefinition[finalCallerUsr] else {
          continue
        }

        let mappingResult =
          "[MAPPED]   Call to '\(calleeDef.name)' at \(reference.location.path):\(reference.location.line) -> Mapped to caller '\(callerDef.name)' via \(mappingMethod)"
        allProcessedReferencesLog.append(mappingResult)

        // Don't create edges for a function calling itself.
        if finalCallerUsr == calleeUsr {
          continue
        }

        if verbose {
          log(
            "[GRAPH EDGE (\(mappingMethod))] \(callerDef.name) -> \(calleeDef.name) at \(reference.location.path):\(reference.location.line)"
          )
        }

        adjacencyList[finalCallerUsr, default: Set()].insert(calleeUsr)
        reverseAdjacencyList[calleeUsr, default: Set()].insert(finalCallerUsr)
      }
    }

    let edgeCount = adjacencyList.values.reduce(0) { $0 + $1.count }
    log("Accurate call graph built with \(uniqueDefinitionCount) nodes and \(edgeCount) edges.")
  }

  /// Walks up the symbolic containment hierarchy from a reference to find the enclosing USR of a known SourceDefinition.
  private func findEnclosingKnownDefinition(
    for occurrence: SymbolOccurrence, in index: IndexStoreDB
  ) -> String? {
    var initialUsr: String?

    // Phase 1: Try to find the direct caller via the `.calledBy` relation. This is the most precise.
    if let directCallerRelation = occurrence.relations.first(where: { $0.roles.contains(.calledBy) }
    ) {
      initialUsr = directCallerRelation.symbol.usr
    }
    // Phase 2: If `.calledBy` isn't available, find what directly contains the reference itself.
    else if let containerRelation = occurrence.relations.first(where: {
      $0.roles.contains(.containedBy)
    }) {
      initialUsr = containerRelation.symbol.usr
    }

    guard var currentUsr = initialUsr else {
      // If we can't find an initial symbol, we cannot proceed.
      return nil
    }

    // Loop up to 10 levels up the hierarchy to find a known definition.
    // This prevents infinite loops and handles deeply nested closures or functions.
    for _ in 0..<10 {
      // If the current USR belongs to a definition we parsed with SwiftSyntax, we found our caller.
      if usrToDefinition.keys.contains(currentUsr) {
        return currentUsr
      }

      // Otherwise, find the definition of the current symbol (e.g., the closure)...
      let definitionOccurrences = index.occurrences(ofUSR: currentUsr, roles: .definition)
      guard let definition = definitionOccurrences.first else {
        // This symbol is not defined in the index, so we can't go further up the chain.
        return nil
      }

      // ...and then find what contains it for the next iteration.
      guard
        let containerRelation = definition.relations.first(where: {
          $0.roles.contains(.containedBy)
        })
      else {
        // This symbol is not contained by anything else (e.g., it's a top-level function we didn't parse).
        return nil
      }

      // Set the container as the next symbol to check.
      currentUsr = containerRelation.symbol.usr
    }

    // If we exhausted the loop, we didn't find a known definition.
    return nil
  }

  // Step 3: Implement the Geometric Fallback Function
  /// Finds the enclosing known definition for an occurrence based on its file path and line number.
  private func findEnclosingKnownDefinitionByLocation(for occurrence: SymbolOccurrence) -> String? {
    let path = occurrence.location.path
    let line = occurrence.location.line

    // 1. Look up the definitions for the given file path.
    guard let definitionsInFile = geometricMap[path] else {
      return nil
    }

    // 2. Find all definitions that contain the reference's line number.
    let containingDefinitions = definitionsInFile.filter { def in
      def.location.line <= line && def.location.endLine >= line
    }

    // 3. Find the most specific (inner-most) definition by choosing the one with the latest start line.
    if let mostSpecificDef = containingDefinitions.max(by: { $0.location.line < $1.location.line })
    {
      if verbose {
        log("[GEOMETRIC FALLBACK] Mapped reference at \(path):\(line) to '\(mostSpecificDef.name)'")
      }
      return mostSpecificDef.usr
    }

    return nil
  }

  func dumpAllProcessedReferences() {
    print("\n--- Comprehensive Reference Mapping Log ---")
    if allProcessedReferencesLog.isEmpty {
      print("No references were processed.")
    } else {
      print("Processed \(allProcessedReferencesLog.count) references:")
      // Sort for consistent output
      for logEntry in allProcessedReferencesLog.sorted() {
        print(logEntry)
      }
    }
    print("--- End of Log ---")
  }

  private func log(_ message: String) {
    if verbose {
      print("[GRAPH] \(message)")
    }
  }
}
