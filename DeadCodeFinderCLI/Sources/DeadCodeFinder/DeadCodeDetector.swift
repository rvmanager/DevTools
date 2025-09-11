// Sources/DeadCodeFinder/DeadCodeDetector.swift

import Foundation
import IndexStoreDB

class DeadCodeDetector {
  let graph: CallGraph
  let index: IndexStore
  let verbose: Bool
  let respectPublicApi: Bool
  private let definitions: [SourceDefinition]

  init(graph: CallGraph, index: IndexStore, verbose: Bool, respectPublicApi: Bool) {
    self.graph = graph
    self.index = index
    self.verbose = verbose
    self.respectPublicApi = respectPublicApi
    self.definitions = graph.definitions
  }

  func findDeadCode() -> [SourceDefinition] {
    log("Starting dead code detection...")

    // STAGE 1: Find all unused stored properties.
    let unusedPropertyUsrs = findUnusedPropertyUsrs()
    log("Found \(unusedPropertyUsrs.count) unused properties.")

    // STAGE 2: Create a mutable copy of the graph to prune.
    var prunedAdjacencyList = graph.adjacencyList
    let propertyDefs = definitions.filter { $0.kind == .property }

    for propertyDef in propertyDefs {
      guard let propertyUsr = propertyDef.usr,
        unusedPropertyUsrs.contains(propertyUsr),
        let propertyTypeName = propertyDef.typeName,
        let containerUsr = findContainerUsr(for: propertyDef)
      else { continue }

      // --- Configurable Pruning Logic ---
      var isPrunable = true
      if respectPublicApi {
        // If the safety flag is on, only prune private/fileprivate
        if propertyDef.accessLevel != .private && propertyDef.accessLevel != .fileprivate {
          isPrunable = false
        }
      }

      guard isPrunable else {
        if verbose {
          log(
            "[PRUNING] SKIPPED pruning for unreferenced public/internal property: '\(propertyDef.name)' (Safe API mode enabled)"
          )
        }
        continue
      }

      // Find the USR of the property's type (e.g., UnusedTest2)
      guard
        let propertyTypeUsr = graph.usrToDefinition.first(where: {
          $0.value.name == propertyTypeName
        })?.key
      else { continue }

      // This is the invalid edge: Container -> PropertyType. Remove it.
      prunedAdjacencyList[containerUsr]?.remove(propertyTypeUsr)

      if verbose {
        let containerName = graph.usrToDefinition[containerUsr]?.name ?? "???"
        log(
          "[PRUNING] Removing edge from '\(containerName)' to '\(propertyTypeName)' due to unused property '\(propertyDef.name)'."
        )
      }
    }

    // STAGE 3: Run reachability analysis on the pruned graph.
    let finalReachableUsrs = findReachableSymbols(using: prunedAdjacencyList)
    log("Found \(finalReachableUsrs.count) reachable symbols after pruning.")

    var deadSymbols: [SourceDefinition] = []
    var aliveSymbols: [SourceDefinition] = []

    // Pass 1: A symbol is dead if it's not an entry point and not in the final reachable set.
    for definition in definitions {
      guard let usr = definition.usr else { continue }
      let isReachable = finalReachableUsrs.contains(usr)
      let isEntryPoint = definition.isEntryPoint
      if isEntryPoint || isReachable {
        aliveSymbols.append(definition)
      } else {
        deadSymbols.append(definition)
      }
    }

    // Pass 2: Apply heuristics to rescue symbols that are implicitly used.
    let rescuedSymbols = rescueSwiftUIViewMembers(
      deadSymbols: deadSymbols,
      aliveSymbols: aliveSymbols
    )
    if !rescuedSymbols.isEmpty {
      log("Rescued \(rescuedSymbols.count) symbols based on SwiftUI View heuristic.")
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
      let isAlive = !deadSymbols.contains(where: { $0.usr == usr })
      if !isAlive {
        if verbose {
          log("[DEAD] Found dead symbol: \(definition.name) at \(definition.location.description)")
        }
      }
    }
    return deadSymbols
  }

  /// A heuristic to rescue private methods of reachable SwiftUI Views.
  private func rescueSwiftUIViewMembers(
    deadSymbols: [SourceDefinition], aliveSymbols: [SourceDefinition]
  ) -> [SourceDefinition] {
    var rescued: [SourceDefinition] = []
    let aliveTypeUsrs = Set(
      aliveSymbols.filter { $0.kind == .struct || $0.kind == .class }.compactMap { $0.usr })
    for deadSymbol in deadSymbols {
      guard deadSymbol.kind == .function || deadSymbol.kind == .variable else { continue }
      let components = deadSymbol.name.components(separatedBy: ".")
      guard components.count > 1 else { continue }
      let parentTypeName = components.dropLast().joined(separator: ".")
      guard let parentType = definitions.first(where: { $0.name == parentTypeName }) else {
        continue
      }
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

  /// Performs a breadth-first search on the call graph to find all reachable symbols.
  private func findReachableSymbols(using adjacencyList: [String: Set<String>]? = nil) -> Set<
    String
  > {
    let graphToUse = adjacencyList ?? self.graph.adjacencyList
    var reachable = Set<String>()
    var queue = definitions.filter { $0.isEntryPoint }.compactMap { $0.usr }
    log("Starting reachability analysis from \(queue.count) entry points...")
    for usr in queue {
      reachable.insert(usr)
    }
    var head = 0
    while head < queue.count {
      let currentUsr = queue[head]
      head += 1
      if let callees = graphToUse[currentUsr] {
        for calleeUsr in callees {
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

  /// Finds all stored properties that are defined but never referenced.
  private func findUnusedPropertyUsrs() -> Set<String> {
    var unused = Set<String>()
    let propertyDefinitions = definitions.filter { $0.kind == .property }
    for propDef in propertyDefinitions {
      guard let usr = propDef.usr else { continue }
      let occurrences = index.store.occurrences(ofUSR: usr, roles: .reference)
      if occurrences.isEmpty {
        if verbose {
          log("[PROPERTY] Found unused property: \(propDef.name)")
        }
        unused.insert(usr)
      }
    }
    return unused
  }

  /// Finds the USR of the type that contains a given property definition.
  private func findContainerUsr(for propertyDef: SourceDefinition) -> String? {
    let components = propertyDef.name.components(separatedBy: ".")
    guard components.count > 1 else { return nil }
    let containerTypeName = components.dropLast().joined(separator: ".")
    return graph.usrToDefinition.first(where: { $0.value.name == containerTypeName })?.key
  }

  private func log(_ message: String) {
    if verbose {
      print("[DETECTOR] \(message)")
    }
  }
}
