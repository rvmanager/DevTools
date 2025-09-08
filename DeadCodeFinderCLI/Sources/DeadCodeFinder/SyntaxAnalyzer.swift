// DeadCodeFinder/SyntaxAnalyzer.swift

import Foundation
import SwiftSyntax
import SwiftParser

struct AnalysisResult {
  let definitions: [FunctionDefinition]
  let calls: [FunctionCall]
  let entryPoints: [FunctionDefinition]
}

class SyntaxAnalyzer {
  let verbose: Bool

  init(verbose: Bool) {
    self.verbose = verbose
  }

  func analyze(files: [URL]) -> AnalysisResult {
    var definitions = [FunctionDefinition]()
    var calls = [FunctionCall]()
    var entryPoints = [FunctionDefinition]()

    for fileURL in files {
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
    return AnalysisResult(definitions: definitions, calls: calls, entryPoints: entryPoints)
  }
}

private class FunctionVisitor: SyntaxVisitor {
  let fileURL: URL
  private(set) var definitions: [FunctionDefinition] = []
  private(set) var calls: [FunctionCall] = []

  private var functionContextStack: [String] = []

  init(fileURL: URL) {
    self.fileURL = fileURL
    super.init(viewMode: .sourceAccurate)
  }

  // MARK: - Identify Function & Property Definitions

  // This is the CORRECT override for handling variable declarations.
  override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
      // We only care about computed properties, which have an accessor block.
      guard let binding = node.bindings.first, binding.accessorBlock != nil else {
          return .visitChildren
      }
      guard let varName = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
          return .visitChildren
      }

      let fullName = createUniqueName(functionName: varName, node: node)
      let location = sourceLocation(for: node)

      // Check if it's a SwiftUI body entry point
      var isEntryPoint = false
      if varName == "body", let parentStruct = findEnclosingStruct(for: node) {
          if parentStruct.inheritanceClause?.inheritedTypes.contains(where: { $0.type.description.contains("View") }) == true {
              isEntryPoint = true
          }
      }

      let definition = FunctionDefinition(id: UUID(), name: fullName, location: location, isEntryPoint: isEntryPoint)
      definitions.append(definition)
      functionContextStack.append(fullName)

      return .visitChildren
  }
    
  // This is the CORRECT corresponding post-visit method.
  override func visitPost(_ node: VariableDeclSyntax) {
      // Pop context if it was a computed property
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
    let isPrivate = node.modifiers.contains { $0.name.text == "private" || $0.name.text == "fileprivate" }
    let isNonPrivateClassMethod = isEnclosedInClass(node: node) && !isPrivate
    let isEntryPoint = isOverridden || isModelMethod || isNonPrivateClassMethod || checkForEntryPoint(node: node, name: funcName)

    let definition = FunctionDefinition(
      id: UUID(), name: fullName, location: location, isEntryPoint: isEntryPoint)
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
    let isPrivate = node.modifiers.contains { $0.name.text == "private" || $0.name.text == "fileprivate" }
    let isNonPrivateClassMethod = isEnclosedInClass(node: node) && !isPrivate
    let isEntryPoint = isOverridden || isPublic || isModelMethod || isNonPrivateClassMethod

    let definition = FunctionDefinition(
      id: UUID(), name: fullName, location: location, isEntryPoint: isEntryPoint)
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
         let identifier = attribute.attributeName.as(IdentifierTypeSyntax.self) {
          return identifier.name.text == "Model"
      }
      return false
  }

  private func checkForEntryPoint(node: FunctionDeclSyntax, name: String) -> Bool {
    if name == "main", let parent = node.parent?.parent?.parent,
      let decl = parent.asProtocol(WithAttributesSyntax.self)
    {
      if decl.attributes.contains(where: { $0.as(AttributeSyntax.self)?.attributeName.description == "main" }) {
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
      if parent.inheritanceClause?.inheritedTypes.contains(where: { $0.type.description.contains("View") }) == true {
        return true
      }
    }
    if node.modifiers.contains(where: { $0.name.text == "public" }) {
      return true
    }
    return false
  }

  private func sourceLocation(for node: SyntaxProtocol) -> SourceLocation {
    let converter = SourceLocationConverter(fileName: fileURL.path, tree: node.root.as(SourceFileSyntax.self)!)
    let location = node.startLocation(converter: converter)
    return SourceLocation(
      filePath: fileURL.path, line: location.line, column: location.column)
  }
}