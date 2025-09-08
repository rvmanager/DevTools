// Sources/DeadCodeFinder/Models.swift

import Foundation

enum DefinitionKind: String, Sendable {
    case `struct`
    case `class`
    case `enum`
    case function
    case initializer
    case variable
}

struct SourceDefinition: Sendable {
  let id: UUID = UUID()
  let name: String
  let kind: DefinitionKind
  let location: SourceLocation
  let isEntryPoint: Bool
  var usr: String?
}

struct FunctionCall: Sendable {
  let callerName: String
  let calleeName: String
  let location: SourceLocation
}

struct CallHierarchyInfo: Sendable {
  let function: FunctionDefinition
  let highestCaller: FunctionDefinition?
  let level: Int
}

typealias FunctionDefinition = SourceDefinition

struct SourceLocation: Sendable {
  let filePath: String
  let line: Int
  let column: Int

  var description: String {
    "\(filePath):\(line):\(column)"
  }
}