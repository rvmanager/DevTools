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
        // First, identify all symbols that are reachable from known entry points.
        let reachableSet = findReachableSymbols()
        if verbose { print("Found \(reachableSet.count) reachable symbols via graph traversal.") }

        var deadSymbols: [SourceDefinition] = []

        // A symbol is dead if it's not an entry point and it was not found in the reachability traversal.
        for definition in graph.definitions {
            guard let usr = definition.usr else { continue }
            
            if !definition.isEntryPoint && !reachableSet.contains(usr) {
                deadSymbols.append(definition)
            }
        }
        
        // An additional check for types: A type might be reachable (e.g., a function returns it),
        // but if it has no incoming references otherwise, it's often a sign of being part of a dead API surface.
        // For simplicity in this sprint, we'll rely on the reachability analysis,
        // but this is an area for future refinement.
        
        return deadSymbols
    }

    private func findReachableSymbols() -> Set<String> {
        var reachable = Set<String>()
        
        // The initial queue is all USRs of definitions marked as entry points.
        var queue = graph.definitions.filter { $0.isEntryPoint }.compactMap { $0.usr }
        
        if verbose {
            print("Starting reachability analysis from \(queue.count) entry points...")
        }

        for usr in queue {
            reachable.insert(usr)
        }

        var head = 0
        while head < queue.count {
            let currentUsr = queue[head]
            head += 1

            // Find all symbols that are called *by* the current symbol.
            if let callees = graph.adjacencyList[currentUsr] {
                for calleeUsr in callees {
                    if !reachable.contains(calleeUsr) {
                        reachable.insert(calleeUsr)
                        queue.append(calleeUsr)
                    }
                }
            }
        }

        return reachable
    }
}