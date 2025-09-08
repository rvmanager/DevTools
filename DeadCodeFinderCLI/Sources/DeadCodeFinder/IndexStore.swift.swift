// Sources/DeadCodeFinder/IndexStore.swift

import Foundation
import IndexStoreDB

class IndexStore {
    private let store: IndexStoreDB
    private let projectPath: String

    // A hardcoded path to the libIndexStore.dylib that ships with Xcode.
    private static let libIndexStorePath = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib"

    init(storePath: String, projectPath: String) throws {
        let lib = try IndexStoreLibrary(dylibPath: Self.libIndexStorePath)
        
        // The databasePath is a temporary location for the index to create its cache.
        let dbPath = NSTemporaryDirectory() + "deadcodefinder_index_\(getpid())"
        
        self.store = try IndexStoreDB(
            storePath: storePath,
            databasePath: dbPath,
            library: lib,
            listenToUnitEvents: false)
        
        self.projectPath = projectPath
        print("[INFO] IndexStoreDB opened successfully.")
    }

    /// Finds all symbol definitions within the specified project path.
    func findAllSymbolDefinitions() -> [SymbolDefinition] {
        var symbols = [SymbolDefinition]()

        // *** THE FIX: Use the correct argument label `byName:` ***
        // Passing an empty string to `byName` finds all symbols.
        store.forEachCanonicalSymbolOccurrence(byName: "") { occurrence in
            // We only care about definitions.
            guard occurrence.roles.contains(.definition) else { return true }
            
            // Exclude symbols from system frameworks and other projects.
            guard occurrence.location.path.starts(with: projectPath) else { return true }
            
            // Exclude noisy symbols like accessors.
            guard !occurrence.roles.contains(.accessorOf) else { return true }

            let definition = SymbolDefinition(
                usr: occurrence.symbol.usr,
                name: occurrence.symbol.name,
                // *** THE FIX: Use `String(describing:)` to get the string representation of the kind. ***
                kind: String(describing: occurrence.symbol.kind),
                location: SourceLocation(
                    filePath: occurrence.location.path,
                    line: occurrence.location.line,
                    column: occurrence.location.utf8Column
                )
            )
            symbols.append(definition)
            
            return true // Continue iterating
        }
        return symbols
    }

    /// Takes a list of symbols and returns the subset that have no references.
    func findUnusedSymbols(in allSymbols: [SymbolDefinition]) -> [SymbolDefinition] {
        var unusedSymbols = [SymbolDefinition]()

        for symbol in allSymbols {
            // A symbol is unused if it has zero references.
            let occurrences = store.occurrences(ofUSR: symbol.usr, roles: .reference)
            
            if occurrences.isEmpty {
                // Before declaring it unused, perform a sanity check for overrides.
                // If a symbol is an override of another, it's considered used.
                let overrideOccurrences = store.occurrences(ofUSR: symbol.usr, roles: .overrideOf)
                if overrideOccurrences.isEmpty {
                    unusedSymbols.append(symbol)
                }
            }
        }
        return unusedSymbols
    }
}