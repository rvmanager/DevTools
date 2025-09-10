// Sources/DeadCodeFinder/Models.swift

import Foundation

enum DefinitionKind: String {
  case `struct`
  case `class`
  case `enum`
  case function
  case initializer
  case variable
}

struct SourceDefinition {
  let id: UUID = UUID()
  let name: String
  let kind: DefinitionKind
  let location: SourceLocation
  var usr: String?
  var isEntryPoint: Bool
}

struct FunctionCall {
  let callerName: String
  let calleeName: String
  let location: SourceLocation
}

struct CallHierarchyInfo {
  let function: SourceDefinition
  let highestCaller: SourceDefinition?
  let level: Int
}

typealias FunctionDefinition = SourceDefinition

struct SourceLocation {
  let filePath: String
  let line: Int
  let column: Int
  let utf8Column: Int
  let endLine: Int
  let endColumn: Int

  var description: String {
    "\(filePath):\(line):\(column)"
  }
}
