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

    // 4. MODIFIED: Calculate call hierarchy for all functions
    log("Calculating call hierarchy for all functions...")
    let callHierarchy = callGraph.calculateCallHierarchy()
    log("Calculation complete.")

    // 5. Report results
    report(callHierarchy)
  }

  // MODIFIED: This function is completely rewritten for the new output format.
  private func report(_ callHierarchy: [CallHierarchyInfo]) {
    // Sort the results by call level, lowest first.
    let sortedHierarchy = callHierarchy.sorted {
      if $0.level != $1.level {
        return $0.level < $1.level
      }
      if $0.function.location.filePath != $1.function.location.filePath {
        return $0.function.location.filePath < $1.function.location.filePath
      }
      return $0.function.location.line < $1.function.location.line
    }

    print("\n--- Function Call Hierarchy Report ---")
    for info in sortedHierarchy {
      let location = "\(info.function.location.filePath):\(info.function.location.line)"
      let funcName = info.function.name
      let highestCallerName = info.highestCaller?.name ?? "<none>"
      let level = info.level

      // Print in the requested tab-separated format.
      print("\(location)\t\(funcName)\t\(highestCallerName)\t\(level)")
    }
  }

  private func log(_ message: String) {
    if verbose {
      print("[INFO] \(message)")
    }
  }
}
