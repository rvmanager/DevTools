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

    // DEBUG: Let's specifically check some of the false positives
    let suspiciousSymbols = [
      "RefreshSchedulingService.calculateNextRefreshDateAfterError",
      "RefreshSchedulingService.calculatePublishingFrequency",
      "RefreshSchedulingService.determineActivityLevel",
    ]

    // A symbol is dead if it's not an entry point itself and it was not found in the reachability traversal.
    for definition in graph.definitions {
      guard let usr = definition.usr else {
        log("[DEBUG] Definition without USR: \(definition.name)")
        continue
      }

      let isReachable = reachableUsrs.contains(usr)
      let isEntryPoint = definition.isEntryPoint
      let isDead = !isEntryPoint && !isReachable

      // Debug specific symbols
      if suspiciousSymbols.contains(where: { definition.name.contains($0) }) {
        log("[DEBUG] Suspicious symbol analysis:")
        log("  Name: \(definition.name)")
        log("  USR: \(usr)")
        log("  Is Entry Point: \(isEntryPoint)")
        log("  Is Reachable: \(isReachable)")
        log("  Will be marked dead: \(isDead)")

        // Check what calls this symbol
        if let callers = graph.reverseAdjacencyList[usr] {
          log("  Called by \(callers.count) symbols:")
          for callerUsr in callers {
            if let callerDef = graph.usrToDefinition[callerUsr] {
              log("    - \(callerDef.name)")
            } else {
              log("    - Unknown caller with USR: \(callerUsr)")
            }
          }
        } else {
          log("  Called by: NONE")
        }

        // Check what this symbol calls
        if let callees = graph.adjacencyList[usr] {
          log("  Calls \(callees.count) symbols:")
          for calleeUsr in callees {
            if let calleeDef = graph.usrToDefinition[calleeUsr] {
              log("    - \(calleeDef.name)")
            } else {
              log("    - Unknown callee with USR: \(calleeUsr)")
            }
          }
        } else {
          log("  Calls: NONE")
        }
      }

      if isDead {
        if verbose {
          log("[DEAD] Found dead symbol: \(definition.name) at \(definition.location.description)")
        }
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
