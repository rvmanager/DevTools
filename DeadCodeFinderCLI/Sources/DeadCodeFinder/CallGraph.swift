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
        var containingUsr: String?
        var mappingResult: String

        if let rangesInFile = fileRangeToUsrMap[reference.location.path] {
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
        }

        let calleeName = calleeDef.name
        let location = reference.location
        if let callerUsr = containingUsr, let callerDef = usrToDefinition[callerUsr] {
          mappingResult =
            "[MAPPED]   Call to '\(calleeName)' at \(location.path):\(location.line) -> Mapped to caller '\(callerDef.name)'"
        } else {
          mappingResult =
            "[UNMAPPED] Call to '\(calleeName)' at \(location.path):\(location.line) -> FAILED TO MAP"
        }
        allProcessedReferencesLog.append(mappingResult)

        // The rest of the logic proceeds as normal
        guard let callerUsr = containingUsr else {
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
