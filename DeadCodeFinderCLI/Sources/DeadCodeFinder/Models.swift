// Sources/DeadCodeFinder/Models.swift

import Foundation

struct SourceLocation {
  let filePath: String
  let line: Int
  let column: Int
}

struct FunctionDefinition {
  let id: UUID
  let name: String
  let location: SourceLocation
  let isEntryPoint: Bool
}

struct FunctionCall {
  let callerName: String
  let calleeName: String
  let location: SourceLocation
}
