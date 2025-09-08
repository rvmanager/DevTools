// DeadCodeFinder/CallGraph.swift

import Foundation
import IndexStoreDB

class CallGraph {
    private(set) var adjacencyList: [String: Set<String>] = [:]      // [Caller USR: Set<Callee USRs>]
    private(set) var reverseAdjacencyList: [String: Set<String>] = [:] // [Callee USR: Set<Caller USRs>]

    let usrToDefinition: [String: SourceDefinition]
    let definitions: [SourceDefinition]
    let verbose: Bool

    init(definitions: [SourceDefinition], index: IndexStore, verbose: Bool) {
        self.definitions = definitions
        self.usrToDefinition = Dictionary(uniqueKeysWithValues: definitions.compactMap {
            guard let usr = $0.usr else { return nil }
            return (usr, $0)
        })
        self.verbose = verbose
        buildGraph(index: index.store)
    }

    private func buildGraph(index: IndexStoreDB) {
        log("Building accurate call graph from \(definitions.count) definitions...")

        var fileRangeToUsrMap: [String: [(Range<Int>, String)]] = [:]
        for definition in definitions where definition.usr != nil {
            let range = definition.location.line ..< definition.location.endLine + 1
            fileRangeToUsrMap[definition.location.filePath, default: []].append((range, definition.usr!))
        }

        // Sort ranges to allow for efficient lookup later
        for (filePath, ranges) in fileRangeToUsrMap {
            fileRangeToUsrMap[filePath] = ranges.sorted { $0.0.lowerBound < $1.0.lowerBound }
        }
        
        log("Processing definitions to find references...")
        var count = 0
        for calleeDef in definitions {
            count += 1
            if verbose && count % 100 == 0 {
                log("...processed \(count)/\(definitions.count) definitions for references")
            }
            guard let calleeUsr = calleeDef.usr else { continue }

            // Find all places where this symbol is referenced.
            let references = index.occurrences(ofUSR: calleeUsr, roles: .reference)

            for reference in references {
                guard let rangesInFile = fileRangeToUsrMap[reference.location.path] else {
                    // This can happen if the reference is in a file we are not analyzing (e.g., system frameworks)
                    continue
                }

                // Find which definition contains this reference's location.
                // We search backwards because definitions can be nested.
                var containingUsr: String?
                for (range, usr) in rangesInFile.reversed() {
                    if range.contains(reference.location.line) {
                        containingUsr = usr
                        break
                    }
                }
                
                guard let callerUsr = containingUsr else {
                    log("Could not map reference at \(reference.location.path):\(reference.location.line) to a known definition.")
                    continue
                }

                // A function calling itself is not an edge we need to track for reachability from an entry point.
                if callerUsr == calleeUsr {
                    continue
                }
                
                if verbose {
                    let callerName = usrToDefinition[callerUsr]?.name ?? "Unknown"
                    let calleeName = calleeDef.name
                    log("[GRAPH EDGE] \(callerName) -> \(calleeName) at \(reference.location.path):\(reference.location.line)")
                }

                adjacencyList[callerUsr, default: Set()].insert(calleeUsr)
                reverseAdjacencyList[calleeUsr, default: Set()].insert(callerUsr)
            }
        }

        let edgeCount = adjacencyList.values.reduce(0) { $0 + $1.count }
        log("Accurate call graph built with \(definitions.count) nodes and \(edgeCount) edges.")
    }
    
    private func log(_ message: String) {
        if verbose {
            print("[GRAPH] \(message)")
        }
    }
}