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
  let usr: String          // The unique, stable identifier for the symbol.
  let name: String         // The human-readable name of the symbol.
  let kind: String         // The kind of symbol (e.g., "class", "function.method.instance").
  let location: SourceLocation
}