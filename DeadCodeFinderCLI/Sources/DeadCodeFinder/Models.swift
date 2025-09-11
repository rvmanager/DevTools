// Sources/DeadCodeFinder/Models.swift

import Foundation

enum AccessLevel: String {
  case `private`
  case `fileprivate`
  case `internal`
  case `public`
  case `open`
}

enum DefinitionKind: String {
  case `struct`
  case `class`
  case `enum`
  case function
  case initializer
  case variable
  case property
}

struct SourceDefinition {
  let id: UUID = UUID()
  let name: String
  let kind: DefinitionKind
  let location: SourceLocation
  var usr: String?
  var isEntryPoint: Bool
  var typeName: String?
  var accessLevel: AccessLevel?
}

struct FunctionCall {
  let callerName: String
  let calleeName: String
  let location: SourceLocation
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
