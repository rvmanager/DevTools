// DeadCodeFinder/CallGraph.swift

import Foundation

class CallGraph {
  let definitions: [FunctionDefinition]
  let entryPoints: [FunctionDefinition]
  private(set) var adjacencyList: [UUID: Set<UUID>] = [:]
  private(set) var reverseAdjacencyList: [UUID: Set<UUID>] = [:]
  private let nameToDefinitions: [String: [FunctionDefinition]]
  private let idToDefinition: [UUID: FunctionDefinition]
  private var memo: [UUID: (highestCaller: FunctionDefinition?, level: Int)] = [:]

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

  func calculateCallHierarchy() -> [CallHierarchyInfo] {
    var hierarchy = [CallHierarchyInfo]()
    memo.removeAll()

    for definition in definitions {
      // MODIFIED: Start the recursive search with an empty path.
      let (highestCaller, level) = findLongestPath(from: definition.id, path: [])
      let info = CallHierarchyInfo(function: definition, highestCaller: highestCaller, level: level)
      hierarchy.append(info)
    }
    return hierarchy
  }

  // MODIFIED: This function now tracks its path to detect cycles.
  private func findLongestPath(from functionId: UUID, path: Set<UUID>) -> (
    highestCaller: FunctionDefinition?, level: Int
  ) {
    // *** THE FIX: Cycle detection ***
    // If the function is already in the current path, we have a cycle. Stop.
    if path.contains(functionId) {
      return (highestCaller: nil, level: -1)  // Return a value that won't be chosen as the max.
    }

    if let cachedResult = memo[functionId] {
      return cachedResult
    }

    guard let callers = reverseAdjacencyList[functionId], !callers.isEmpty else {
      let result = (highestCaller: nil as FunctionDefinition?, level: 0)
      memo[functionId] = result
      return result
    }

    // Add the current function to the path for the recursive calls.
    var newPath = path
    newPath.insert(functionId)

    var maxLevel = -1
    var overallHighestCaller: FunctionDefinition?

    for callerId in callers {
      // Pass the updated path down.
      let (pathHighestCaller, pathLevel) = findLongestPath(from: callerId, path: newPath)

      // Skip results from cyclical paths.
      if pathLevel == -1 {
        continue
      }

      if pathLevel > maxLevel {
        maxLevel = pathLevel
        overallHighestCaller = pathHighestCaller ?? definition(for: callerId)
      }
    }

    // Handle cases where all paths were cycles or no callers were found.
    if maxLevel == -1 {
      let result = (highestCaller: nil as FunctionDefinition?, level: 0)
      memo[functionId] = result
      return result
    }

    let result = (highestCaller: overallHighestCaller, level: maxLevel + 1)
    memo[functionId] = result
    return result
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
        let callerTypeContext = callerDef.name.split(separator: ".").dropLast().joined(
          separator: ".")

        if !callerTypeContext.isEmpty {
          let preferredCalleeName = "\(callerTypeContext).\(call.calleeName)"
          if let localCallees = nameToDefinitions[preferredCalleeName] {
            potentialCallees = localCallees
          }
        }

        if potentialCallees.isEmpty {
          potentialCallees = definitions.filter {
            $0.name.hasSuffix("." + call.calleeName) || $0.name == call.calleeName
          }
        }

        if potentialCallees.isEmpty {
          if verbose {
            print(
              "Note: Call to '\(call.calleeName)' could not be resolved. It may be a system or library function."
            )
          }
          continue
        }

        if adjacencyList[callerDef.id] == nil {
          adjacencyList[callerDef.id] = Set<UUID>()
        }
        for calleeDef in potentialCallees {
          adjacencyList[callerDef.id]?.insert(calleeDef.id)
          if reverseAdjacencyList[calleeDef.id] == nil {
            reverseAdjacencyList[calleeDef.id] = Set<UUID>()
          }
          reverseAdjacencyList[calleeDef.id]?.insert(callerDef.id)
        }
      }
    }

    if verbose {
      let edgeCount = adjacencyList.values.reduce(0) { $0 + $1.count }
      print("Call graph built with \(definitions.count) nodes and \(edgeCount) edges.")
    }
  }
}
