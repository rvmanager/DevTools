// Sources/DeadCodeFinder/DeadCodeDetector.swift

import Foundation

class DeadCodeDetector {
  let graph: CallGraph
  let verbose: Bool

  init(graph: CallGraph, verbose: Bool) {
    self.graph = graph
    self.verbose = verbose
  }

  func findDeadCode() -> [FunctionDefinition] {
    if verbose {
      print("Starting reachability analysis from \(graph.entryPoints.count) entry points...")
    }

    let reachableFunctionIDs = findReachableFunctions()
    if verbose { print("Found \(reachableFunctionIDs.count) reachable functions.") }

    let allFunctionIDs = Set(graph.definitions.map { $0.id })
    let deadFunctionIDs = allFunctionIDs.subtracting(reachableFunctionIDs)

    let deadFunctions = deadFunctionIDs.compactMap { graph.definition(for: $0) }

    // Filter out known false positives
    return deadFunctions.filter { !$0.isEntryPoint }
  }

  private func findReachableFunctions() -> Set<UUID> {
    var reachable = Set<UUID>()
    var queue = graph.entryPoints.map { $0.id }

    for id in queue {
      reachable.insert(id)
    }

    var head = 0
    while head < queue.count {
      let currentFuncID = queue[head]
      head += 1

      if let callees = graph.adjacencyList[currentFuncID] {
        for calleeID in callees {
          if !reachable.contains(calleeID) {
            reachable.insert(calleeID)
            queue.append(calleeID)
          }
        }
      }
    }

    return reachable
  }
}
