// Sources/DeadCodeFinder/SyntaxAnalyzer.swift

import Foundation
import SwiftParser
import SwiftSyntax

struct AnalysisResult {
  let definitions: [SourceDefinition]
  let calls: [FunctionCall]
  let entryPoints: [SourceDefinition]
}

class SyntaxAnalyzer: @unchecked Sendable {
  let verbose: Bool

  init(verbose: Bool) {
    self.verbose = verbose
  }

  func analyze(files: [URL]) -> AnalysisResult {
    let definitions = ThreadSafeArray<SourceDefinition>()
    let calls = ThreadSafeArray<FunctionCall>()
    let entryPoints = ThreadSafeArray<SourceDefinition>()

    log("Starting concurrent analysis of \(files.count) files...")
    DispatchQueue.concurrentPerform(iterations: files.count) { index in
      let fileURL = files[index]
      log("Parsing \(fileURL.path)...")
      do {
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        let sourceTree = Parser.parse(source: source)

        let visitor = FunctionVisitor(fileURL: fileURL, verbose: verbose)
        visitor.walk(sourceTree)

        definitions.append(contentsOf: visitor.definitions)
        calls.append(contentsOf: visitor.calls)
        let fileEntryPoints = visitor.definitions.filter { $0.isEntryPoint }
        if !fileEntryPoints.isEmpty {
          entryPoints.append(contentsOf: fileEntryPoints)
        }
        log("Finished parsing \(fileURL.path). Found \(visitor.definitions.count) definitions.")

      } catch {
        print("[ERROR] Error parsing file \(fileURL.path): \(error)")
      }
    }

    log("Finished all concurrent analysis.")
    return AnalysisResult(
      definitions: definitions.items,
      calls: calls.items,
      entryPoints: entryPoints.items
    )
  }

  private func log(_ message: String) {
    if verbose {
      print("[SYNTAX] \(message)")
    }
  }
}

// Thread-safe array wrapper to fix concurrency warnings
private class ThreadSafeArray<T: Sendable>: @unchecked Sendable {
  private var _items: [T] = []
  private let queue = DispatchQueue(
    label: "com.deadcodefinder.threadsafe-array", attributes: .concurrent)

  var items: [T] {
    var itemsCopy: [T]!
    queue.sync {
      itemsCopy = self._items
    }
    return itemsCopy
  }

  func append(contentsOf newItems: [T]) {
    guard !newItems.isEmpty else { return }
    queue.async(flags: .barrier) {
      self._items.append(contentsOf: newItems)
    }
  }
}

private class FunctionVisitor: SyntaxVisitor {
  let fileURL: URL
  let verbose: Bool
  private(set) var definitions: [SourceDefinition] = []
  private(set) var calls: [FunctionCall] = []

  private var contextStack: [String] = []

  init(fileURL: URL, verbose: Bool) {
    self.fileURL = fileURL
    self.verbose = verbose
    super.init(viewMode: .sourceAccurate)
  }

  // Generic entrance handler for any declaration that creates a new scope.
  // It creates a unique name for the scope and pushes it onto the context stack.
  private func enterScope(name: String, node: SyntaxProtocol) {
    let fullName = createUniqueName(baseName: name, node: node)
    contextStack.append(fullName)
  }

  // Generic exit handler to pop the context when leaving a scope.
  private func exitScope() {
    _ = contextStack.popLast()
  }

  override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
    let name = node.name.text
    let fullName = createUniqueName(baseName: name, node: node)
    let location = sourceLocation(for: node)

    var isEntryPoint = false
    if let inheritedTypes = node.inheritanceClause?.inheritedTypes {
      isEntryPoint = inheritedTypes.contains {
        let typeDescription = $0.type.description
        let isEntryPointType =
          typeDescription.contains("View") || typeDescription.contains("App")
          || typeDescription.contains("ParsableCommand") || typeDescription.contains("Decodable")
          || typeDescription.contains("Codable")
        if isEntryPointType && verbose {
          log("Marking '\(fullName)' as entry point due to inheritance: \(typeDescription)")
        }
        return isEntryPointType
      }
    }
    if node.attributes.contains(where: {
      $0.as(AttributeSyntax.self)?.attributeName.description == "main"
    }) {
      isEntryPoint = true
      if verbose { log("Marking '\(fullName)' as entry point due to @main attribute") }
    }

    let definition = SourceDefinition(
      name: fullName,
      kind: .struct,
      location: location,
      isEntryPoint: isEntryPoint
    )
    definitions.append(definition)

    if isEntryPoint {
      for member in node.memberBlock.members {
        if let initDecl = member.decl.as(InitializerDeclSyntax.self) {
          let initFullName = createUniqueName(baseName: "init", node: initDecl)
          let initLocation = sourceLocation(for: initDecl)
          let initDef = SourceDefinition(
            name: initFullName,
            kind: .initializer,
            location: initLocation,
            isEntryPoint: true
          )
          definitions.append(initDef)
          if verbose {
            log("Marking '\(initFullName)' as entry point (part of entry point struct)")
          }
        }
      }
    }

    enterScope(name: name, node: node)
    return .visitChildren
  }

  override func visitPost(_ node: StructDeclSyntax) {
    exitScope()
  }

  override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
    let name = node.name.text
    let fullName = createUniqueName(baseName: name, node: node)
    let location = sourceLocation(for: node)

    var isEntryPoint = false
    if let inheritedTypes = node.inheritanceClause?.inheritedTypes {
      isEntryPoint = inheritedTypes.contains {
        let typeDescription = $0.type.description
        let isEntryPointType = typeDescription.contains("XCTestCase")
        if isEntryPointType && verbose {
          log("Marking '\(fullName)' as entry point due to inheritance: \(typeDescription)")
        }
        return isEntryPointType
      }
    }

    let definition = SourceDefinition(
      name: fullName,
      kind: .class,
      location: location,
      isEntryPoint: isEntryPoint
    )
    definitions.append(definition)
    enterScope(name: name, node: node)
    return .visitChildren
  }

  override func visitPost(_ node: ClassDeclSyntax) {
    exitScope()
  }

  override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
    let name = node.name.text
    let fullName = createUniqueName(baseName: name, node: node)
    let location = sourceLocation(for: node)

    let definition = SourceDefinition(
      name: fullName,
      kind: .enum,
      location: location,
      isEntryPoint: false
    )
    definitions.append(definition)
    enterScope(name: name, node: node)
    return .visitChildren
  }

  override func visitPost(_ node: EnumDeclSyntax) {
    exitScope()
  }

  override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
    for binding in node.bindings {
      guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
        continue
      }
      let varName = pattern.identifier.text

      // We only care about member variables that are computed properties (have a body)
      guard node.parent?.is(MemberBlockSyntax.self) == true, binding.accessorBlock != nil else {
        continue
      }

      let fullName = createUniqueName(baseName: varName, node: node)
      let location = sourceLocation(for: node)

      var isEntryPoint = false
      if varName == "body", let parentStruct = findEnclosingStruct(for: node) {
        if parentStruct.inheritanceClause?.inheritedTypes.contains(where: {
          let typeDescription = $0.type.description
          let isEntryPointType = typeDescription.contains("View") || typeDescription.contains("App")
          if isEntryPointType && verbose {
            log("Marking '\(fullName)' as entry point because it is a 'body' in a View/App")
          }
          return isEntryPointType
        }) == true {
          isEntryPoint = true
        }
      }

      let definition = SourceDefinition(
        name: fullName, kind: .variable, location: location, isEntryPoint: isEntryPoint
      )
      definitions.append(definition)
      enterScope(name: varName, node: node)
    }
    return .visitChildren
  }

  override func visitPost(_ node: VariableDeclSyntax) {
    for binding in node.bindings {
      guard node.parent?.is(MemberBlockSyntax.self) == true, binding.accessorBlock != nil else {
        continue
      }
      exitScope()
    }
  }

  override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
    let funcName = node.name.text
    let fullName = createUniqueName(baseName: funcName, node: node)
    let location = sourceLocation(for: node)

    let isOverridden = node.modifiers.contains { $0.name.text == "override" }
    let isModelMethod = isEnclosedInModel(node: node)
    let isPrivate = node.modifiers.contains {
      $0.name.text == "private" || $0.name.text == "fileprivate"
    }
    let isNonPrivateClassMethod = isEnclosedInClass(node: node) && !isPrivate
    let isEntryPointByHeuristics = checkForEntryPoint(
      node: node, name: funcName, fullName: fullName)

    let isEntryPoint =
      isOverridden || isModelMethod || isNonPrivateClassMethod || isEntryPointByHeuristics

    if verbose && isEntryPoint {
      var reasons: [String] = []
      if isOverridden { reasons.append("is override") }
      if isModelMethod { reasons.append("is SwiftData @Model method") }
      if isNonPrivateClassMethod { reasons.append("is non-private class method") }
      if isEntryPointByHeuristics { reasons.append("heuristic match") }
      log("Marking '\(fullName)' as entry point (\(reasons.joined(separator: ", ")))")
    }

    let definition = SourceDefinition(
      name: fullName, kind: .function, location: location, isEntryPoint: isEntryPoint
    )
    definitions.append(definition)
    enterScope(name: funcName, node: node)
    return .visitChildren
  }

  override func visitPost(_ node: FunctionDeclSyntax) {
    exitScope()
  }

  override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
    let fullName = createUniqueName(baseName: "init", node: node)
    let location = sourceLocation(for: node)
    let isOverridden = node.modifiers.contains { $0.name.text == "override" }
    let isPublic = node.modifiers.contains { $0.name.text == "public" }
    let isModelMethod = isEnclosedInModel(node: node)
    let isPrivate = node.modifiers.contains {
      $0.name.text == "private" || $0.name.text == "fileprivate"
    }
    let isNonPrivateClassMethod = isEnclosedInClass(node: node) && !isPrivate
    let isEntryPoint = isOverridden || isPublic || isModelMethod || isNonPrivateClassMethod

    if verbose && isEntryPoint {
      var reasons: [String] = []
      if isOverridden { reasons.append("is override") }
      if isPublic { reasons.append("is public") }
      if isModelMethod { reasons.append("is SwiftData @Model method") }
      if isNonPrivateClassMethod { reasons.append("is non-private class method") }
      log("Marking '\(fullName)' as entry point (\(reasons.joined(separator: ", ")))")
    }

    let definition = SourceDefinition(
      name: fullName,
      kind: .initializer,
      location: location,
      isEntryPoint: isEntryPoint
    )
    definitions.append(definition)
    enterScope(name: "init", node: node)
    return .visitChildren
  }

  override func visitPost(_ node: InitializerDeclSyntax) {
    exitScope()
  }

  // Visit closures and treat them as temporary, unnamed function scopes.
  override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
    // Create a unique but descriptive name for the closure based on its location
    let closureName = "closure_\(node.position.utf8Offset)"
    enterScope(name: closureName, node: node)
    return .visitChildren
  }

  override func visitPost(_ node: ClosureExprSyntax) {
    exitScope()
  }

  override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
    guard let callerName = contextStack.last else {
      return .visitChildren
    }
    var calleeName = ""
    if let calledMember = node.calledExpression.as(MemberAccessExprSyntax.self) {
      calleeName = calledMember.declName.baseName.text
    } else if let calledIdentifier = node.calledExpression.as(DeclReferenceExprSyntax.self) {
      calleeName = calledIdentifier.baseName.text
      if let firstChar = calleeName.first, firstChar.isUppercase {
        calleeName += ".init"
      }
    }
    if !calleeName.isEmpty {
      let location = sourceLocation(for: node)
      let call = FunctionCall(callerName: callerName, calleeName: calleeName, location: location)
      calls.append(call)
    }
    return .visitChildren
  }

  override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
    guard let callerName = contextStack.last else {
      return .visitChildren
    }

    let calleeName = node.baseName.text

    guard let firstChar = calleeName.first, firstChar.isLowercase else {
      return .visitChildren
    }

    let callerShortName = String(callerName.split(separator: ".").last ?? "")
    if callerShortName == calleeName {
      return .visitChildren
    }

    let location = sourceLocation(for: node)
    let call = FunctionCall(callerName: callerName, calleeName: calleeName, location: location)
    calls.append(call)

    return .visitChildren
  }

  private func log(_ message: String) {
    if verbose {
      print("[VISITOR] \(message)")
    }
  }

  private func getCurrentTypeContext() -> String {
    // Walk up the context stack to find the nearest type (struct/class/enum)
    for context in contextStack.reversed() {
      // Extract the type name from contexts like "RefreshSchedulingService.calculateNextRefreshDate"
      let components = context.components(separatedBy: ".")
      if components.count >= 1 {
        let firstComponent = components[0]
        // Check if this looks like a type name (starts with uppercase)
        if let firstChar = firstComponent.first, firstChar.isUppercase {
          return firstComponent
        }
      }
    }
    return ""
  }

  private func createUniqueName(baseName: String, node: SyntaxProtocol) -> String {
    var context = ""
    var current: Syntax? = node._syntaxNode
    while let parent = current?.parent {
      if let typeNode = parent.as(StructDeclSyntax.self) {
        context = typeNode.name.text + "." + context
      } else if let typeNode = parent.as(ClassDeclSyntax.self) {
        context = typeNode.name.text + "." + context
      } else if let typeNode = parent.as(EnumDeclSyntax.self) {
        context = typeNode.name.text + "." + context
      } else if let typeNode = parent.as(ActorDeclSyntax.self) {
        context = typeNode.name.text + "." + context
      } else if let typeNode = parent.as(ExtensionDeclSyntax.self) {
        context = typeNode.extendedType.trimmedDescription + "." + context
        break
      }
      current = parent
    }
    return context + baseName
  }

  private func findEnclosingStruct(for node: SyntaxProtocol) -> StructDeclSyntax? {
    var current: Syntax? = node._syntaxNode
    while let parent = current?.parent {
      if let structDecl = parent.as(StructDeclSyntax.self) {
        return structDecl
      }
      current = parent
    }
    return nil
  }

  private func isEnclosedInModel(node: SyntaxProtocol) -> Bool {
    var current: Syntax? = node._syntaxNode
    while let parent = current?.parent {
      if let classDecl = parent.as(ClassDeclSyntax.self) {
        if classDecl.attributes.contains(where: { isModelMacro($0) }) {
          return true
        }
      }
      if parent.is(SourceFileSyntax.self) { break }
      current = parent
    }
    return false
  }

  private func isEnclosedInClass(node: SyntaxProtocol) -> Bool {
    var current: Syntax? = node._syntaxNode
    while let parent = current?.parent {
      if parent.is(ClassDeclSyntax.self) { return true }
      if parent.is(SourceFileSyntax.self) { break }
      current = parent
    }
    return false
  }

  private func isModelMacro(_ attr: AttributeListSyntax.Element) -> Bool {
    if let attribute = attr.as(AttributeSyntax.self),
      let identifier = attribute.attributeName.as(IdentifierTypeSyntax.self)
    {
      return identifier.name.text == "Model"
    }
    return false
  }

  private func checkForEntryPoint(node: FunctionDeclSyntax, name: String, fullName: String) -> Bool
  {
    let representableMethods: Set<String> = [
      "makeUIView", "updateUIView", "makeNSView", "updateNSView", "makeCoordinator",
    ]
    if representableMethods.contains(name) {
      if verbose { log("... \(fullName) is entry point (ViewRepresentable method)") }
      return true
    }

    if name == "main", let parent = node.parent?.parent?.parent,
      let decl = parent.asProtocol(WithAttributesSyntax.self)
    {
      if decl.attributes.contains(where: {
        $0.as(AttributeSyntax.self)?.attributeName.description == "main"
      }) {
        if verbose { log("... \(fullName) is entry point (global main)") }
        return true
      }
    }
    if name == "run", let parentStruct = findEnclosingStruct(for: node) {
      if let inheritedTypes = parentStruct.inheritanceClause?.inheritedTypes {
        for inheritedType in inheritedTypes {
          if let simpleType = inheritedType.type.as(IdentifierTypeSyntax.self) {
            if simpleType.name.text == "ParsableCommand" {
              if verbose { log("... \(fullName) is entry point (ParsableCommand.run)") }
              return true
            }
          }
        }
      }
    }
    if name.starts(with: "test") && fileURL.path.lowercased().contains("test") {
      if verbose { log("... \(fullName) is entry point (XCTest method)") }
      return true
    }
    let lifecycleMethods: Set<String> = [
      "applicationDidFinishLaunching", "viewDidLoad", "viewWillAppear", "viewDidAppear",
    ]
    if lifecycleMethods.contains(name) {
      if verbose { log("... \(fullName) is entry point (UIKit/AppKit lifecycle)") }
      return true
    }
    if name == "body", let parent = node.parent?.parent?.parent?.as(StructDeclSyntax.self) {
      if parent.inheritanceClause?.inheritedTypes.contains(where: {
        $0.type.description.contains("View")
      }) == true {
        if verbose { log("... \(fullName) is entry point (SwiftUI body)") }
        return true
      }
    }
    if node.modifiers.contains(where: { $0.name.text == "public" }) {
      if verbose { log("... \(fullName) is entry point (public modifier)") }
      return true
    }
    return false
  }

  private func sourceLocation(for node: SyntaxProtocol) -> SourceLocation {
    let converter = SourceLocationConverter(
      fileName: fileURL.path, tree: node.root.as(SourceFileSyntax.self)!)

    let startPosition = node.positionAfterSkippingLeadingTrivia
    let start = converter.location(for: startPosition)
    let end = node.endLocation(converter: converter)

    let lineStartPosition = converter.position(ofLine: start.line, column: 1)

    let utf8Column = start.offset - lineStartPosition.utf8Offset + 1

    return SourceLocation(
      filePath: fileURL.path,
      line: start.line,
      column: start.column,
      utf8Column: utf8Column,
      endLine: end.line,
      endColumn: end.column
    )
  }

  // Debug helper to try multiple line positions for USR lookup
  private func findUSRForDefinition(
    name: String, primaryLocation: SourceLocation, usrLookup: [String: [Int: String]]
  ) -> String? {
    let filePath = primaryLocation.filePath

    // Try exact match first
    if let usr = usrLookup[filePath]?[primaryLocation.line] {
      if verbose {
        log("Found exact USR match for \(name) at line \(primaryLocation.line)")
      }
      return usr
    }

    // Try nearby lines (±3 lines)
    for offset in 1...3 {
      // Try lines after
      if let usr = usrLookup[filePath]?[primaryLocation.line + offset] {
        if verbose {
          log(
            "Found USR for \(name) at line \(primaryLocation.line + offset) (offset +\(offset) from SwiftSyntax line \(primaryLocation.line))"
          )
        }
        return usr
      }

      // Try lines before
      let beforeLine = primaryLocation.line - offset
      if beforeLine > 0, let usr = usrLookup[filePath]?[beforeLine] {
        if verbose {
          log(
            "Found USR for \(name) at line \(beforeLine) (offset -\(offset) from SwiftSyntax line \(primaryLocation.line))"
          )
        }
        return usr
      }
    }

    // For structs/classes, also try looking for any USR in a wider range (the body)
    if primaryLocation.endLine > primaryLocation.line {
      for line in primaryLocation.line...min(primaryLocation.line + 10, primaryLocation.endLine) {
        if let usr = usrLookup[filePath]?[line] {
          if verbose {
            log(
              "Found USR for \(name) in body range at line \(line) (SwiftSyntax range: \(primaryLocation.line)-\(primaryLocation.endLine))"
            )
          }
          return usr
        }
      }
    }

    return nil
  }
}
