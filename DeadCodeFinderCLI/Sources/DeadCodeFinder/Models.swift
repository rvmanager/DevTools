// Sources/DeadCodeFinder/Models.swift

import Foundation

// Represents a location in a source file.
struct SourceLocation: CustomStringConvertible {
  let filePath: String
  let line: Int
  let column: Int

  var description: String {
    "\(filePath):\(line):\(column)"
  }
}

// Represents a defined symbol (class, function, etc.) found in the index.
struct SymbolDefinition {
  let usr: String
  let name: String
  let kind: String
  let location: SourceLocation
}
