// Sources/DeadCodeFinder/DeadCodeDetector.swift

import Foundation

class DeadCodeDetector {
    let graph: CallGraph
    let verbose: Bool

    init(graph: CallGraph, verbose: Bool) {
        self.graph = graph
        self.verbose = verbose
    }

    func findDeadCode() -> [SourceDefinition] {
        log("Starting dead code detection...")
        // First, identify all symbols that are reachable from known entry points.
        let reachableUsrs = findReachableSymbols()
        log("Found \(reachableUsrs.count) reachable symbols via graph traversal.")

        var deadSymbols: [SourceDefinition] = []

        // A symbol is dead if it's not an entry point itself and it was not found in the reachability traversal.
        for definition in graph.definitions {
            guard let usr = definition.usr else { continue }
            
            if !definition.isEntryPoint && !reachableUsrs.contains(usr) {
                log("[DEAD] Found dead symbol: \(definition.name) at \(definition.location.description)")
                deadSymbols.append(definition)
            } else if verbose {
                if definition.isEntryPoint {
                    log("[ALIVE] Symbol is alive (entry point): \(definition.name)")
                } else {
                    log("[ALIVE] Symbol is alive (reachable): \(definition.name)")
                }
            }
        }
        
        return deadSymbols
    }

    private func findReachableSymbols() -> Set<String> {
        var reachable = Set<String>()
        
        // The initial queue is all USRs of definitions marked as entry points by SwiftSyntax.
        var queue = graph.definitions.filter { $0.isEntryPoint }.compactMap { $0.usr }
        
        log("Starting reachability analysis from \(queue.count) entry points...")

        // Add all entry points to the reachable set initially.
        for usr in queue {
            if verbose, let def = graph.usrToDefinition[usr] {
                log(" -> Adding entry point to queue: \(def.name)")
            }
            reachable.insert(usr)
        }

        // Perform a classic Breadth-First Search (BFS) to find all reachable nodes.
        var head = 0
        while head < queue.count {
            let currentUsr = queue[head]
            head += 1

            if verbose, let def = graph.usrToDefinition[currentUsr] {
                log("  - Traversing from: \(def.name)")
            }

            // Find all symbols that are called *by* the current symbol.
            if let callees = graph.adjacencyList[currentUsr] {
                for calleeUsr in callees {
                    // If we haven't seen this callee before, add it to the reachable set and the queue to visit later.
                    if !reachable.contains(calleeUsr) {
                        reachable.insert(calleeUsr)
                        queue.append(calleeUsr)
                        if verbose, let def = graph.usrToDefinition[calleeUsr] {
                             log("    - Found new reachable symbol: \(def.name)")
                        }
                    }
                }
            }
        }

        return reachable
    }
    
    private func log(_ message: String) {
        if verbose {
            print("[DETECTOR] \(message)")
        }
    }
}