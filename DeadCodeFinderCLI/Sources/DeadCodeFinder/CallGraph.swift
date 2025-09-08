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
        if verbose { print("Building accurate call graph from \(definitions.count) definitions...") }

        // 1. Create a more robust spatial lookup map that understands source ranges.
        // [FilePath: [Sorted list of (line range, USR)]]
        var fileRangeToUsrMap: [String: [(Range<Int>, String)]] = [:]
        for definition in definitions where definition.usr != nil {
            let range = definition.location.line ..< definition.location.endLine + 1
            fileRangeToUsrMap[definition.location.filePath, default: []].append((range, definition.usr!))
        }

        // Sort the ranges for each file to allow for efficient searching.
        for (filePath, ranges) in fileRangeToUsrMap {
            fileRangeToUsrMap[filePath] = ranges.sorted { $0.0.lowerBound < $1.0.lowerBound }
        }
        
        // 2. For each definition, find what other symbols reference it.
        for calleeDef in definitions {
            guard let calleeUsr = calleeDef.usr else { continue }

            let references = index.occurrences(ofUSR: calleeUsr, roles: .reference)

            for reference in references {
                // Find which definition contains this reference by checking our range map.
                guard let rangesInFile = fileRangeToUsrMap[reference.location.path] else {
                    continue
                }

                // Find the tightest-fitting range that contains the reference line.
                var containingUsr: String?
                for (range, usr) in rangesInFile.reversed() { // Reverse search finds inner scopes first
                    if range.contains(reference.location.line) {
                        containingUsr = usr
                        break
                    }
                }
                
                guard let callerUsr = containingUsr else {
                    if verbose { log("Could not map reference at \(reference.location.path):\(reference.location.line) to a known definition.") }
                    continue
                }

                // Don't add edges from a symbol to itself.
                if callerUsr == calleeUsr {
                    continue
                }

                adjacencyList[callerUsr, default: Set()].insert(calleeUsr)
                reverseAdjacencyList[calleeUsr, default: Set()].insert(callerUsr)
            }
        }

        if verbose {
            let edgeCount = adjacencyList.values.reduce(0) { $0 + $1.count }
            print("Accurate call graph built with \(definitions.count) nodes and \(edgeCount) edges.")
        }
    }
    
    private func log(_ message: String) {
        if verbose {
            print("[GRAPH] \(message)")
        }
    }
}