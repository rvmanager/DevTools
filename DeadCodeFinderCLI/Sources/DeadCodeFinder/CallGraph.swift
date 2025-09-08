// DeadCodeFinder/CallGraph.swift

import Foundation

class CallGraph {
  let definitions: [FunctionDefinition]
  let entryPoints: [FunctionDefinition]
  private(set) var adjacencyList: [UUID: Set<UUID>] = [:]
  private let nameToDefinitions: [String: [FunctionDefinition]]
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

    for call in calls {
        guard let callerDefs = nameToDefinitions[call.callerName], !callerDefs.isEmpty else {
            if verbose { print("Warning: Could not find definition for caller: \(call.callerName)") }
            continue
        }

        for callerDef in callerDefs {
            var potentialCallees: [FunctionDefinition] = []

            // *** THE FIX: Smarter Call Resolution Logic ***

            // 1. Get the caller's own type context (e.g., "GeminiAPIService" from "GeminiAPIService.generateSmartPlaylists")
            let callerTypeContext = callerDef.name.split(separator: ".").dropLast().joined(separator: ".")

            // 2. Prioritize finding the callee within the same type context.
            // This correctly resolves private methods and direct calls like `createPlaylistGenerationPrompt()`.
            if !callerTypeContext.isEmpty {
                let preferredCalleeName = "\(callerTypeContext).\(call.calleeName)"
                if let localCallees = nameToDefinitions[preferredCalleeName] {
                    potentialCallees = localCallees
                }
            }

            // 3. If no local callee was found, fall back to the old, broader search.
            // This handles calls to methods on other types or global functions.
            if potentialCallees.isEmpty {
                potentialCallees = definitions.filter {
                    $0.name.hasSuffix("." + call.calleeName) || $0.name == call.calleeName
                }
            }

            if potentialCallees.isEmpty {
                if verbose {
                    print("Note: Call to '\(call.calleeName)' could not be resolved. It may be a system or library function.")
                }
                continue
            }

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