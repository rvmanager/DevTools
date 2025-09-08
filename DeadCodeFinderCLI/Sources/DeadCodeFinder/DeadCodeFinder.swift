// Sources/DeadCodeFinder/DeadCodeFinder.swift

import ArgumentParser
import Foundation

struct DeadCodeFinder: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "A tool to find unused Swift code in a project using IndexStoreDB."
  )

  @Argument(help: "The root path of the Swift project to analyze.")
  private var projectPath: String

  @Option(
    name: .shortAndLong,
    help: "The path to Xcode's Index Store. Found in your project's DerivedData directory.")
  private var indexStorePath: String

  @Flag(name: .shortAndLong, help: "Enable verbose logging for detailed analysis steps.")
  private var verbose: Bool = false

  func run() throws {
    let absolutePath = (projectPath as NSString).expandingTildeInPath
    let absoluteIndexStorePath = (indexStorePath as NSString).expandingTildeInPath

    log("Starting analysis of project at: \(absolutePath)")
    log("Using Index Store at: \(absoluteIndexStorePath)")

    // 1. Initialize the Index Store
    let index = try IndexStore(storePath: absoluteIndexStorePath, projectPath: absolutePath)

    // 2. Find all symbol definitions in the project
    log("Finding all symbol definitions in project...")
    let allSymbols = index.findAllSymbolDefinitions()
    log("Found \(allSymbols.count) total symbol definitions.")

    // 3. Analyze for unused symbols
    log("Analyzing for unused symbols...")
    let unusedSymbols = index.findUnusedSymbols(in: allSymbols)
    log("Analysis complete.")
    
    // 4. Report results
    report(unusedSymbols)
  }

  private func report(_ unusedSymbols: [SymbolDefinition]) {
    if unusedSymbols.isEmpty {
      print("\n✅ No unused symbols found. Excellent!")
    } else {
      print("\n❌ Found \(unusedSymbols.count) potentially unused symbols:")
      let sortedSymbols = unusedSymbols.sorted {
        $0.location.filePath < $1.location.filePath
          || ($0.location.filePath == $1.location.filePath && $0.location.line < $1.location.line)
      }
      for symbol in sortedSymbols {
        // Example Output: /path/to/File.swift:42 -> myFunction() [function.method.instance]
        print("  - \(symbol.location.description) -> \(symbol.name) [\(symbol.kind)]")
      }
    }
  }

  private func log(_ message: String) {
    if verbose {
      print("[INFO] \(message)")
    }
  }
}