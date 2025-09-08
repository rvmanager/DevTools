// Sources/DeadCodeFinder/CallGraph.swift

import Foundation

class CallGraph {
  let definitions: [FunctionDefinition]
  let entryPoints: [FunctionDefinition]

  // A map from a function's unique ID to the set of function IDs it calls.
  private(set) var adjacencyList: [UUID: Set<UUID>] = [:]

  // Fast lookup from function name to all definitions (handles overloads)
  private let nameToDefinitions: [String: [FunctionDefinition]]
  // Fast lookup from ID to definition
  private let idToDefinition: [UUID: FunctionDefinition]

  init(
    definitions: [FunctionDefinition], calls: [FunctionCall], entryPoints: [FunctionDefinition],
    verbose: Bool
  ) {
    self.definitions = definitions
    self.entryPoints = entryPoints

    self.idToDefinition = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
    self.nameToDefinitions = Dictionary(grouping: definitions, by: { $0.name })

    buildGraph(calls: calls, verbose: verbose)
  }

  func definition(for id: UUID) -> FunctionDefinition? {
    return idToDefinition[id]
  }

  private func buildGraph(calls: [FunctionCall], verbose: Bool) {
    if verbose { print("Building call graph...") }

    let callerNameToDefs = Dictionary(grouping: definitions, by: { $0.name })

    for call in calls {
      // Find the definition for the caller
      guard let callerDefs = callerNameToDefs[call.callerName], !callerDefs.isEmpty else {
        if verbose { print("Warning: Could not find definition for caller: \(call.callerName)") }
        continue
      }

      // Find potential definitions for the callee.
      // This is a simplification; it doesn't resolve types. It finds all functions with a matching name.
      let potentialCallees = definitions.filter {
        $0.name.hasSuffix("." + call.calleeName) || $0.name == call.calleeName
      }

      if potentialCallees.isEmpty {
        if verbose {
          print(
            "Note: Call to '\(call.calleeName)' could not be resolved. It may be a system or library function."
          )
        }
        continue
      }

      for callerDef in callerDefs {
        if adjacencyList[callerDef.id] == nil {
          adjacencyList[callerDef.id] = Set<UUID>()
        }
        for calleeDef in potentialCallees {
          adjacencyList[callerDef.id]?.insert(calleeDef.id)
        }
      }
    }

    if verbose {
      let edgeCount = adjacencyList.values.reduce(0) { $0 + $1.count }
      print("Call graph built with \(definitions.count) nodes and \(edgeCount) edges.")
    }
  }
}
