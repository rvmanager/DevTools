// Sources/DeadCodeFinder/DeadCodeFinder.swift

import ArgumentParser
import Foundation

struct DeadCodeFinder: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "A tool to find unreachable Swift functions (dead code) in a project."
  )

  @Argument(help: "The root path of the Swift project to analyze.")
  private var projectPath: String

  @Option(
    name: .shortAndLong,
    help: "A comma-separated list of directories to exclude from analysis (e.g., '.build,Pods').")
  private var exclude: String?

  @Flag(name: .shortAndLong, help: "Enable verbose logging for detailed analysis steps.")
  private var verbose: Bool = false

func run() throws {
    let absolutePath = (projectPath as NSString).expandingTildeInPath

    log("Starting analysis of project at: \(absolutePath)")

    let excludedDirs =
      exclude?.components(separatedBy: ",") ?? [".build", "Pods", "Carthage", "DerivedData"]
    log("Excluding directories: \(excludedDirs.joined(separator: ", "))")

    // 1. Find all Swift files
    var swiftFiles = ProjectParser.findSwiftFiles(at: absolutePath, excluding: excludedDirs)
    
    // *** THE FIX: Exclude the package manifest from analysis ***
    swiftFiles.removeAll { $0.lastPathComponent == "Package.swift" }

    log("Found \(swiftFiles.count) Swift files to analyze.")

    // 2. Parse files to find function definitions and calls
    let analyzer = SyntaxAnalyzer(verbose: verbose)
    let analysisResult = analyzer.analyze(files: swiftFiles)
    log(
      "Found \(analysisResult.definitions.count) function definitions and \(analysisResult.calls.count) call sites."
    )
    log("Identified \(analysisResult.entryPoints.count) potential entry points.")

    // 3. Build the call graph
    let callGraph = CallGraph(
      definitions: analysisResult.definitions,
      calls: analysisResult.calls,
      entryPoints: analysisResult.entryPoints,
      verbose: verbose
    )

    // 4. Detect dead code
    let detector = DeadCodeDetector(graph: callGraph, verbose: verbose)
    let deadFunctions = detector.findDeadCode()

    // 5. Report results
    report(deadFunctions)
  }

  private func report(_ deadFunctions: [FunctionDefinition]) {
    if deadFunctions.isEmpty {
      print("\n✅ No dead functions found. Excellent!")
    } else {
      print("\n❌ Found \(deadFunctions.count) potentially dead functions:")
      let sortedFunctions = deadFunctions.sorted {
        $0.location.filePath < $1.location.filePath
          || ($0.location.filePath == $1.location.filePath && $0.location.line < $1.location.line)
      }
      for function in sortedFunctions {
        print("  - \(function.location.filePath):\(function.location.line) -> \(function.name)")
      }
    }
  }

  private func log(_ message: String) {
    if verbose {
      print("[INFO] \(message)")
    }
  }
}
