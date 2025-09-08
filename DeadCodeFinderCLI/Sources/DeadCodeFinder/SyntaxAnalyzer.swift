// DeadCodeFinder/SyntaxAnalyzer.swift

import Foundation
import SwiftParser
import SwiftSyntax

// SPRINT 1: Updated to use the new SourceDefinition model.
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
    // SPRINT 1: Changed to use SourceDefinition
    let definitions = ThreadSafeArray<SourceDefinition>()
    let calls = ThreadSafeArray<FunctionCall>()
    let entryPoints = ThreadSafeArray<SourceDefinition>()

    // Using concurrentPerform for faster parsing
    DispatchQueue.concurrentPerform(iterations: files.count) { index in
        let fileURL = files[index]
        if verbose { print("Parsing \(fileURL.path)...") }
        do {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let sourceTree = Parser.parse(source: source)

            let visitor = FunctionVisitor(fileURL: fileURL)
            visitor.walk(sourceTree)

            definitions.append(contentsOf: visitor.definitions)
            calls.append(contentsOf: visitor.calls)
            entryPoints.append(contentsOf: visitor.definitions.filter { $0.isEntryPoint })

        } catch {
            print("Error parsing file \(fileURL.path): \(error)")
        }
    }
    
    return AnalysisResult(
        definitions: definitions.items,
        calls: calls.items,
        entryPoints: entryPoints.items
    )
  }
}

// Thread-safe array wrapper to fix concurrency warnings
private class ThreadSafeArray<T: Sendable>: @unchecked Sendable {
    private var _items: [T] = []
    private let queue = DispatchQueue(label: "ThreadSafeArray", attributes: .concurrent)
    
    var items: [T] {
        return queue.sync { _items }
    }
    
    func append(_ item: T) {
        queue.async(flags: .barrier) {
            self._items.append(item)
        }
    }
    
    func append(contentsOf items: [T]) {
        queue.async(flags: .barrier) {
            self._items.append(contentsOf: items)
        }
    }
}

private class FunctionVisitor: SyntaxVisitor {
  let fileURL: URL
  // SPRINT 1: Changed to use SourceDefinition
  private(set) var definitions: [SourceDefinition] = []
  private(set) var calls: [FunctionCall] = []

  private var functionContextStack: [String] = []

  init(fileURL: URL) {
    self.fileURL = fileURL
    super.init(viewMode: .sourceAccurate)
  }
    
  // MARK: - SPRINT 1: Identify Type Definitions

  override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
      let name = node.name.text
      let fullName = createUniqueName(functionName: name, node: node)
      let location = sourceLocation(for: node)
      
      var isEntryPoint = false
      if let inheritedTypes = node.inheritanceClause?.inheritedTypes {
          isEntryPoint = inheritedTypes.contains {
              $0.type.description.contains("View") || $0.type.description.contains("App") || $0.type.description.contains("ParsableCommand")
          }
      }
      if node.attributes.contains(where: { $0.as(AttributeSyntax.self)?.attributeName.description == "main" }) {
          isEntryPoint = true
      }

      let definition = SourceDefinition(
          name: fullName,
          kind: .struct,
          location: location,
          isEntryPoint: isEntryPoint
      )
      definitions.append(definition)
      functionContextStack.append(fullName)
      return .visitChildren
  }
    
  override func visitPost(_ node: StructDeclSyntax) {
      _ = functionContextStack.popLast()
  }
    
  override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
      let name = node.name.text
      let fullName = createUniqueName(functionName: name, node: node)
      let location = sourceLocation(for: node)
      
      var isEntryPoint = false
      if let inheritedTypes = node.inheritanceClause?.inheritedTypes {
          isEntryPoint = inheritedTypes.contains {
              $0.type.description.contains("XCTestCase")
          }
      }
      
      let definition = SourceDefinition(
          name: fullName,
          kind: .class,
          location: location,
          isEntryPoint: isEntryPoint
      )
      definitions.append(definition)
      functionContextStack.append(fullName)
      return .visitChildren
  }
    
  override func visitPost(_ node: ClassDeclSyntax) {
      _ = functionContextStack.popLast()
  }
    
  override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
      let name = node.name.text
      let fullName = createUniqueName(functionName: name, node: node)
      let location = sourceLocation(for: node)
      
      let definition = SourceDefinition(
          name: fullName,
          kind: .enum,
          location: location,
          isEntryPoint: false // Enums are rarely entry points
      )
      definitions.append(definition)
      functionContextStack.append(fullName)
      return .visitChildren
  }
    
  override func visitPost(_ node: EnumDeclSyntax) {
      _ = functionContextStack.popLast()
  }

  // MARK: - Identify Function & Property Definitions

  override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
    guard let binding = node.bindings.first, binding.accessorBlock != nil else {
      return .visitChildren
    }
    guard let varName = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
      return .visitChildren
    }

    let fullName = createUniqueName(functionName: varName, node: node)
    let location = sourceLocation(for: node)

    var isEntryPoint = false
    if varName == "body", let parentStruct = findEnclosingStruct(for: node) {
      if parentStruct.inheritanceClause?.inheritedTypes.contains(where: {
        $0.type.description.contains("View") || $0.type.description.contains("App")
      }) == true {
        isEntryPoint = true
      }
    }

    let definition = SourceDefinition(
        name: fullName, kind: .variable, location: location, isEntryPoint: isEntryPoint
    )
    definitions.append(definition)
    functionContextStack.append(fullName)

    return .visitChildren
  }

  override func visitPost(_ node: VariableDeclSyntax) {
    if let binding = node.bindings.first, binding.accessorBlock != nil {
      _ = functionContextStack.popLast()
    }
  }

  override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
    let funcName = node.name.text
    let fullName = createUniqueName(functionName: funcName, node: node)
    let location = sourceLocation(for: node)

    let isOverridden = node.modifiers.contains { $0.name.text == "override" }
    let isModelMethod = isEnclosedInModel(node: node)
    let isPrivate = node.modifiers.contains {
      $0.name.text == "private" || $0.name.text == "fileprivate"
    }
    let isNonPrivateClassMethod = isEnclosedInClass(node: node) && !isPrivate
    let isEntryPoint =
      isOverridden || isModelMethod || isNonPrivateClassMethod
      || checkForEntryPoint(node: node, name: funcName)

    let definition = SourceDefinition(
        name: fullName, kind: .function, location: location, isEntryPoint: isEntryPoint
    )
    definitions.append(definition)
    functionContextStack.append(fullName)
    return .visitChildren
  }

  override func visitPost(_ node: FunctionDeclSyntax) {
    _ = functionContextStack.popLast()
  }

  override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
    let fullName = createUniqueName(functionName: "init", node: node)
    let location = sourceLocation(for: node)
    let isOverridden = node.modifiers.contains { $0.name.text == "override" }
    let isPublic = node.modifiers.contains { $0.name.text == "public" }
    let isModelMethod = isEnclosedInModel(node: node)
    let isPrivate = node.modifiers.contains {
      $0.name.text == "private" || $0.name.text == "fileprivate"
    }
    let isNonPrivateClassMethod = isEnclosedInClass(node: node) && !isPrivate
    let isEntryPoint = isOverridden || isPublic || isModelMethod || isNonPrivateClassMethod

    let definition = SourceDefinition(
        name: fullName, kind: .initializer, location: location, isEntryPoint: isEntryPoint
    )
    definitions.append(definition)
    functionContextStack.append(fullName)
    return .visitChildren
  }

  override func visitPost(_ node: InitializerDeclSyntax) {
    _ = functionContextStack.popLast()
  }

  // MARK: - Identify Function Calls

  override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
    guard let callerName = functionContextStack.last else {
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
    guard let callerName = functionContextStack.last else {
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

  // MARK: - Helpers

  private func createUniqueName(functionName: String, node: SyntaxProtocol) -> String {
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
          // For extensions, we just get the type name and stop traversing up.
          context = typeNode.extendedType.trimmedDescription + "." + context
          break
      }
      current = parent
    }
    return context + functionName
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

  private func checkForEntryPoint(node: FunctionDeclSyntax, name: String) -> Bool {
    if name == "main", let parent = node.parent?.parent?.parent,
      let decl = parent.asProtocol(WithAttributesSyntax.self)
    {
      if decl.attributes.contains(where: {
        $0.as(AttributeSyntax.self)?.attributeName.description == "main"
      }) {
        return true
      }
    }
    if name == "run", let parentStruct = findEnclosingStruct(for: node) {
      if let inheritedTypes = parentStruct.inheritanceClause?.inheritedTypes {
        for inheritedType in inheritedTypes {
          if let simpleType = inheritedType.type.as(IdentifierTypeSyntax.self) {
            if simpleType.name.text == "ParsableCommand" {
              return true
            }
          }
        }
      }
    }
    if name.starts(with: "test") && fileURL.path.lowercased().contains("test") {
      return true
    }
    let lifecycleMethods: Set<String> = [
      "applicationDidFinishLaunching", "viewDidLoad", "viewWillAppear", "viewDidAppear",
    ]
    if lifecycleMethods.contains(name) {
      return true
    }
    if name == "body", let parent = node.parent?.parent?.parent?.as(StructDeclSyntax.self) {
      if parent.inheritanceClause?.inheritedTypes.contains(where: {
        $0.type.description.contains("View")
      }) == true {
        return true
      }
    }
    if node.modifiers.contains(where: { $0.name.text == "public" }) {
      return true
    }
    return false
  }

  private func sourceLocation(for node: SyntaxProtocol) -> SourceLocation {
    let converter = SourceLocationConverter(
      fileName: fileURL.path, tree: node.root.as(SourceFileSyntax.self)!)
    let location = node.startLocation(converter: converter)
    return SourceLocation(
      filePath: fileURL.path, line: location.line, column: location.column)
  }
}