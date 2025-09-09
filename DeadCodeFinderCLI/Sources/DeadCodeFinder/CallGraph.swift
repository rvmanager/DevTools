// Sources/DeadCodeFinder/CallGraph.swift

import Foundation
import IndexStoreDB

class CallGraph {
  private(set) var adjacencyList: [String: Set<String>] = [:]
  private(set) var reverseAdjacencyList: [String: Set<String>] = [:]

  let usrToDefinition: [String: SourceDefinition]
  let definitions: [SourceDefinition]
  let verbose: Bool

  init(definitions: [SourceDefinition], index: IndexStore, verbose: Bool) {
    self.definitions = definitions

    // --- THIS IS THE FIX ---
    // The `definitions` array can contain duplicates where different syntax nodes
    // resolve to the same canonical symbol (e.g., class and extension), resulting in the same USR.
    // `Dictionary(uniqueKeysWithValues:)` crashes on these duplicate keys.
    // We now use `Dictionary(_:uniquingKeysWith:)` to handle this gracefully,
    // keeping the first definition we encounter for any given USR.
    self.usrToDefinition = Dictionary(
      definitions.compactMap { def -> (String, SourceDefinition)? in
        guard let usr = def.usr else { return nil }
        return (usr, def)
      }, uniquingKeysWith: { (first, _) in first })
    // --- END FIX ---

    self.verbose = verbose
    buildGraph(index: index.store)
  }

  private func buildGraph(index: IndexStoreDB) {
    let uniqueDefinitionCount = usrToDefinition.count
    log("Building accurate call graph from \(uniqueDefinitionCount) unique definitions...")

    var fileRangeToUsrMap: [String: [(Range<Int>, String)]] = [:]
    // Use the now-unique usrToDefinition dictionary as the source of truth
    for (usr, definition) in usrToDefinition {
      // Use the full line range of the symbol's body for accurate reference mapping.
      let range = definition.location.line..<definition.location.endLine + 1
      fileRangeToUsrMap[definition.location.filePath, default: []].append((range, usr))
    }

    for (filePath, ranges) in fileRangeToUsrMap {
      fileRangeToUsrMap[filePath] = ranges.sorted { $0.0.lowerBound < $1.0.lowerBound }
    }

    log("Processing definitions to find references...")
    var count = 0
    // Iterate over the unique dictionary
    for (calleeUsr, calleeDef) in usrToDefinition {
      count += 1
      if verbose && count % 100 == 0 {
        log("...processed \(count)/\(uniqueDefinitionCount) definitions for references")
      }

      let references = index.occurrences(ofUSR: calleeUsr, roles: .reference)

      for reference in references {
        guard let rangesInFile = fileRangeToUsrMap[reference.location.path] else {
          continue
        }

        var containingUsr: String?
        // Search reversed to find the most specific (inner) scope first.
        for (range, usr) in rangesInFile.reversed() {
          if range.contains(reference.location.line) {
            containingUsr = usr
            break
          }
        }

        guard let callerUsr = containingUsr else {
          log(
            "Could not map reference at \(reference.location.path):\(reference.location.line) to a known definition."
          )
          continue
        }

        if callerUsr == calleeUsr {
          continue
        }

        if verbose {
          let callerName = usrToDefinition[callerUsr]?.name ?? "Unknown"
          let calleeName = calleeDef.name
          log(
            "[GRAPH EDGE] \(callerName) -> \(calleeName) at \(reference.location.path):\(reference.location.line)"
          )
        }

        adjacencyList[callerUsr, default: Set()].insert(calleeUsr)
        reverseAdjacencyList[calleeUsr, default: Set()].insert(callerUsr)
      }
    }

    let edgeCount = adjacencyList.values.reduce(0) { $0 + $1.count }
    log("Accurate call graph built with \(uniqueDefinitionCount) nodes and \(edgeCount) edges.")
  }

  private func log(_ message: String) {
    if verbose {
      print("[GRAPH] \(message)")
    }
  }
}
