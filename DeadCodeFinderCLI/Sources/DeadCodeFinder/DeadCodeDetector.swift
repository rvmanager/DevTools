// Sources/DeadCodeFinder/DeadCodeDetector.swift

import Foundation

class DeadCodeDetector {
  let graph: CallGraph
  let verbose: Bool
  private let definitions: [SourceDefinition]

  init(graph: CallGraph, verbose: Bool) {
    self.graph = graph
    self.verbose = verbose
    // Create a local copy for modification
    self.definitions = graph.definitions
  }

  func findDeadCode() -> [SourceDefinition] {
    log("Starting dead code detection...")

    // First, identify all symbols that are reachable from known entry points.
    let reachableUsrs = findReachableSymbols()
    log("Found \(reachableUsrs.count) reachable symbols via graph traversal.")

    var deadSymbols: [SourceDefinition] = []
    var aliveSymbols: [SourceDefinition] = []

    // Initial Pass: A symbol is dead if it's not an entry point and not in the reachable set.
    for definition in definitions {
      guard let usr = definition.usr else { continue }

      let isReachable = reachableUsrs.contains(usr)
      let isEntryPoint = definition.isEntryPoint

      if isEntryPoint || isReachable {
        aliveSymbols.append(definition)
      } else {
        deadSymbols.append(definition)
      }
    }

    // Post-Processing Pass: Implement the SwiftUI View heuristic.
    let rescuedSymbols = rescueSwiftUIViewMembers(
      deadSymbols: deadSymbols,
      aliveSymbols: aliveSymbols
    )

    if !rescuedSymbols.isEmpty {
      log("Rescued \(rescuedSymbols.count) symbols based on SwiftUI View heuristic.")
      // Remove rescued symbols from the dead list
      let rescuedUsrs = Set(rescuedSymbols.compactMap { $0.usr })
      deadSymbols.removeAll { definition in
        guard let usr = definition.usr else { return false }
        return rescuedUsrs.contains(usr)
      }
      aliveSymbols.append(contentsOf: rescuedSymbols)
    }

    // Final Logging
    for definition in definitions {
      guard let usr = definition.usr else { continue }
      let isAlive = aliveSymbols.contains { $0.usr == usr }

      if !isAlive {
        if verbose {
          log("[DEAD] Found dead symbol: \(definition.name) at \(definition.location.description)")
        }
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

  /// A heuristic to rescue private methods of reachable SwiftUI Views.
  /// In SwiftUI, methods are often called implicitly from the `body` via closures (e.g., `Button(action: myPrivateMethod)`),
  /// and IndexStoreDB may not register these as formal call references.
  private func rescueSwiftUIViewMembers(
    deadSymbols: [SourceDefinition], aliveSymbols: [SourceDefinition]
  ) -> [SourceDefinition] {
    var rescued: [SourceDefinition] = []

    // Create a lookup set of all reachable type USRs for efficient checking.
    let aliveTypeUsrs = Set(
      aliveSymbols.filter { $0.kind == .struct || $0.kind == .class }.compactMap { $0.usr })

    for deadSymbol in deadSymbols {
      // We only care about private instance methods/vars for this heuristic.
      guard deadSymbol.kind == .function || deadSymbol.kind == .variable else { continue }

      // Extract the parent type's name from the symbol's full name (e.g., "MyView.myFunction" -> "MyView").
      let components = deadSymbol.name.components(separatedBy: ".")
      guard components.count > 1 else { continue }
      let parentTypeName = components.dropLast().joined(separator: ".")

      // Find the definition of the parent type.
      guard let parentType = definitions.first(where: { $0.name == parentTypeName }) else {
        continue
      }

      // If the parent type is in the set of reachable types, we rescue this private method.
      if let parentUsr = parentType.usr, aliveTypeUsrs.contains(parentUsr) {
        if verbose {
          log(
            "[HEURISTIC] Rescuing '\(deadSymbol.name)' because its parent View '\(parentTypeName)' is alive."
          )
        }
        rescued.append(deadSymbol)
      }
    }

    return rescued
  }

  private func findReachableSymbols() -> Set<String> {
    var reachable = Set<String>()

    // The initial queue is all USRs of definitions marked as entry points by SwiftSyntax.
    var queue = definitions.filter { $0.isEntryPoint }.compactMap { $0.usr }

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
