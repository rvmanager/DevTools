// Sources/DeadCodeFinder/IndexStore.swift

import Foundation
import IndexStoreDB

class IndexStore {
    private let store: IndexStoreDB
    private let projectPath: String

    // A hardcoded path to the libIndexStore.dylib that ships with Xcode.
    private static let libIndexStorePath = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib"

    init(storePath: String, projectPath: String) throws {
        // Validate the index store path exists and is a directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: storePath, isDirectory: &isDirectory),
            isDirectory.boolValue else {
            throw NSError(domain: "DeadCodeFinder", code: 1, 
                        userInfo: [NSLocalizedDescriptionKey: "Index store path does not exist or is not a directory: \(storePath)"])
        }
        
        let lib = try IndexStoreLibrary(dylibPath: Self.libIndexStorePath)
        
        let dbPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deadcodefinder_index_\(UUID().uuidString)")
            .path
        
        print("[DEBUG] Using database path: \(dbPath)")
        print("[DEBUG] Index store path: \(storePath)")
        
        do {
            self.store = try IndexStoreDB(
                storePath: storePath,
                databasePath: dbPath,
                library: lib,
                listenToUnitEvents: false
            )
            self.projectPath = projectPath
            print("[INFO] IndexStoreDB opened successfully.")
        } catch {
            print("[ERROR] Failed to initialize IndexStoreDB: \(error)")
            // Clean up the database path if it was created
            try? FileManager.default.removeItem(atPath: dbPath)
            throw error
        }
    }

    /// Finds all symbol definitions within the specified project path.
    func findAllSymbolDefinitions() -> [SymbolDefinition] {
        var symbols = [SymbolDefinition]()
        var processedCount = 0
        var skippedCount = 0

        // LMDB typical limits (conservative estimates)
        let maxUSRLength = 1000  // Much more conservative
        let maxNameLength = 200  
        let maxPathLength = 1000
        let maxKindLength = 50

        print("[DEBUG] Starting to enumerate symbol occurrences...")
        print("[DEBUG] Using limits - USR: \(maxUSRLength), Name: \(maxNameLength), Path: \(maxPathLength), Kind: \(maxKindLength)")
        
        store.forEachCanonicalSymbolOccurrence(byName: "") { occurrence in
            defer { 
                processedCount += 1
                if processedCount % 100 == 0 {
                    print("[DEBUG] Processed \(processedCount) occurrences, found \(symbols.count) valid symbols, skipped \(skippedCount)...")
                }
            }
            
            // We only care about definitions.
            guard occurrence.roles.contains(.definition) else { return true }
            
            // Exclude noisy symbols like accessors.
            guard !occurrence.roles.contains(.accessorOf) else { return true }
            
            // Get location path
            let locationPath = occurrence.location.path
            
            // Exclude symbols from system frameworks and other projects.
            guard locationPath.starts(with: projectPath) else { return true }

            // Get symbol properties with detailed validation
            let usr = occurrence.symbol.usr
            let name = occurrence.symbol.name
            let kindString = String(describing: occurrence.symbol.kind)
            
            // More detailed validation and logging
            var skipReason: String? = nil
            
            if usr.isEmpty {
                skipReason = "Empty USR"
            } else if usr.count > maxUSRLength {
                skipReason = "USR too long (\(usr.count) > \(maxUSRLength))"
            } else if name.isEmpty {
                skipReason = "Empty name"
            } else if name.count > maxNameLength {
                skipReason = "Name too long (\(name.count) > \(maxNameLength))"
            } else if kindString.count > maxKindLength {
                skipReason = "Kind too long (\(kindString.count) > \(maxKindLength))"
            } else if locationPath.count > maxPathLength {
                skipReason = "Path too long (\(locationPath.count) > \(maxPathLength))"
            }
            
            if let reason = skipReason {
                skippedCount += 1
                print("[WARNING] Skipping symbol '\(name.prefix(50))...' - \(reason)")
                if skippedCount <= 5 { // Show details for first few
                    print("[DEBUG] Full USR: '\(usr.prefix(100))...'")
                    print("[DEBUG] Full name: '\(name.prefix(100))...'")
                    print("[DEBUG] Kind: '\(kindString)'")
                    print("[DEBUG] Path: '\(locationPath.prefix(100))...'")
                }
                return true
            }
            
            // Get location properties
            let line = occurrence.location.line
            let column = occurrence.location.utf8Column
            
            guard line >= 0, column >= 0 else {
                skippedCount += 1
                print("[WARNING] Invalid location - line: \(line), column: \(column)")
                return true
            }

            let definition = SymbolDefinition(
                usr: usr,
                name: name,
                kind: kindString,
                location: SourceLocation(
                    filePath: locationPath,
                    line: line,
                    column: column
                )
            )
            symbols.append(definition)
            
            return true // Continue iterating
        }
        
        print("[DEBUG] Completed. Processed: \(processedCount), Valid symbols: \(symbols.count), Skipped: \(skippedCount)")
        return symbols
    }

    /// Takes a list of symbols and returns the subset that have no references.
    func findUnusedSymbols(in allSymbols: [SymbolDefinition]) -> [SymbolDefinition] {
        var unusedSymbols = [SymbolDefinition]()
        var processedSymbols = 0

        print("[DEBUG] Analyzing \(allSymbols.count) symbols for usage...")

        for symbol in allSymbols {
            defer { 
                processedSymbols += 1
                if processedSymbols % 10 == 0 {
                    print("[DEBUG] Analyzed \(processedSymbols)/\(allSymbols.count) symbols...")
                }
            }
            
            print("[DEBUG] Checking symbol #\(processedSymbols + 1): '\(symbol.name.prefix(50))'")
            
            // Double-check USR validity (should already be validated above)
            guard !symbol.usr.isEmpty, symbol.usr.count <= 1000 else {
                print("[WARNING] Skipping symbol '\(symbol.name)' with invalid USR in usage check (length: \(symbol.usr.count))")
                continue
            }
            
            print("[DEBUG] Getting references for USR: '\(symbol.usr.prefix(50))...' (length: \(symbol.usr.count))")
            
            // Check for references
            let occurrences = store.occurrences(ofUSR: symbol.usr, roles: .reference)
            print("[DEBUG] Found \(occurrences.count) references")
            
            if occurrences.isEmpty {
                print("[DEBUG] No references found, checking for overrides...")
                
                // Check for overrides
                let overrideOccurrences = store.occurrences(ofUSR: symbol.usr, roles: .overrideOf)
                print("[DEBUG] Found \(overrideOccurrences.count) overrides")
                
                if overrideOccurrences.isEmpty {
                    print("[DEBUG] Symbol '\(symbol.name)' appears unused, adding to results")
                    unusedSymbols.append(symbol)
                } else {
                    print("[DEBUG] Symbol '\(symbol.name)' has overrides, keeping")
                }
            } else {
                print("[DEBUG] Symbol '\(symbol.name)' has references, keeping")
            }
        }
        
        print("[DEBUG] Found \(unusedSymbols.count) potentially unused symbols")
        return unusedSymbols
    }
}