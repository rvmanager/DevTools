// Sources/DeadCodeFinder/CallGraph.swift

import Foundation
import IndexStoreDB

class CallGraph {
  private(set) var adjacencyList: [String: Set<String>] = [:]
  private(set) var reverseAdjacencyList: [String: Set<String>] = [:]

  // No more multiple lists. Just one list to capture all failures.
  private(set) var unmappedReferences: [(calleeName: String, reference: SymbolOccurrence)] = []

  let usrToDefinition: [String: SourceDefinition]
  let definitions: [SourceDefinition]
  let verbose: Bool

  init(definitions: [SourceDefinition], index: IndexStore, verbose: Bool) {
    self.definitions = definitions

    self.usrToDefinition = Dictionary(
      definitions.compactMap { def -> (String, SourceDefinition)? in
        guard let usr = def.usr else { return nil }
        return (usr, def)
      }, uniquingKeysWith: { (first, _) in first })

    self.verbose = verbose
    buildGraph(index: index.store)
  }

  private func buildGraph(index: IndexStoreDB) {
    let uniqueDefinitionCount = usrToDefinition.count
    log("Building accurate call graph from \(uniqueDefinitionCount) unique definitions...")

    var fileRangeToUsrMap: [String: [(Range<Int>, String)]] = [:]
    for (usr, definition) in usrToDefinition {
      let startLine = definition.location.line
      let endLine = max(definition.location.endLine, definition.location.line + 50)
      let range = startLine..<(endLine + 1)
      fileRangeToUsrMap[definition.location.filePath, default: []].append((range, usr))
    }

    for (filePath, ranges) in fileRangeToUsrMap {
      fileRangeToUsrMap[filePath] = ranges.sorted { (first, second) in
        if first.0.lowerBound != second.0.lowerBound {
          return first.0.lowerBound < second.0.lowerBound
        }
        return (first.0.upperBound - first.0.lowerBound)
          < (second.0.upperBound - second.0.lowerBound)
      }
    }

    log("Processing definitions to find references...")
    var count = 0
    for (calleeUsr, calleeDef) in usrToDefinition {
      count += 1
      if verbose && count % 100 == 0 {
        log("...processed \(count)/\(uniqueDefinitionCount) definitions for references")
      }

      let references = index.occurrences(ofUSR: calleeUsr, roles: .reference)

      for reference in references {
        guard let rangesInFile = fileRangeToUsrMap[reference.location.path] else {
          unmappedReferences.append((calleeName: calleeDef.name, reference: reference))
          continue
        }

        var containingUsr: String?
        var bestRange: (Range<Int>, String)?

        for (range, usr) in rangesInFile {
          if range.contains(reference.location.line) {
            if bestRange == nil {
              bestRange = (range, usr)
            } else {
              let currentSize = range.upperBound - range.lowerBound
              let bestSize = bestRange!.0.upperBound - bestRange!.0.lowerBound
              if currentSize < bestSize {
                bestRange = (range, usr)
              }
            }
          }
        }

        containingUsr = bestRange?.1

        // THIS IS THE GUARANTEED FIX.
        // If no containing range is found, 'containingUsr' will be nil.
        // This block will execute, add the reference to the list, log the message, and then continue.
        guard let callerUsr = containingUsr else {
          unmappedReferences.append((calleeName: calleeDef.name, reference: reference))
          if verbose {
            log(
              "Could not map reference at \(reference.location.path):\(reference.location.line) to a known definition."
            )
          }
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

  func reportUnmappedReferences() {
    // Cleaned up the reporting logic to be clear and match your log output.
    if !unmappedReferences.isEmpty {
      print(
        "\n⚠️ Found \(unmappedReferences.count) references that could not be mapped to a calling function:"
      )
      let sortedUnmapped = unmappedReferences.sorted {
        if $0.reference.location.path != $1.reference.location.path {
          return $0.reference.location.path < $1.reference.location.path
        }
        return $0.reference.location.line < $1.reference.location.line
      }

      for (calleeName, reference) in sortedUnmapped {
        let location = reference.location
        print(
          "  - Call to '\(calleeName)' at \(location.path):\(location.line):\(location.utf8Column)")
      }
    } else {
      // Explicitly state that no unmapped references were found.
      print("\n✅ All references were successfully mapped to a calling function.")
    }
  }

  private func log(_ message: String) {
    if verbose {
      print("[GRAPH] \(message)")
    }
  }
}
