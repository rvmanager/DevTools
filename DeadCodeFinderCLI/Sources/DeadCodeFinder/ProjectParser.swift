// Sources/DeadCodeFinder/ProjectParser.swift

import Foundation

class ProjectParser {
  static func findSwiftFiles(at path: String, excluding excludedDirs: [String]) -> [URL] {
    var swiftFiles: [URL] = []
    let fileManager = FileManager.default
    let projectURL = URL(fileURLWithPath: path)

    guard
      let enumerator = fileManager.enumerator(
        at: projectURL, includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles])
    else {
      return []
    }

    for case let fileURL as URL in enumerator {
      // Check if the file is in an excluded directory
      let isInExcludedDir = excludedDirs.contains { dirName in
        fileURL.path.contains("/\(dirName)/")
      }
      if isInExcludedDir {
        enumerator.skipDescendants()
        continue
      }

      // Check if it's a regular Swift file
      if fileURL.pathExtension == "swift" {
        swiftFiles.append(fileURL)
      }
    }
    return swiftFiles
  }
}
