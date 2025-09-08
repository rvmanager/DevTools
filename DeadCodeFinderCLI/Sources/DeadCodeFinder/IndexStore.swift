// Sources/DeadCodeFinder/IndexStore.swift

import Foundation
import IndexStoreDB

/// A helper class to manage the IndexStoreDB instance.
class IndexStore {
    let store: IndexStoreDB
    let verbose: Bool

    // A hardcoded path to the libIndexStore.dylib that ships with Xcode.
    private static let libIndexStorePath =
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib"

    init(storePath: String, verbose: Bool = false) throws {
        self.verbose = verbose
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: storePath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NSError(domain: "DeadCodeFinder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Index store path does not exist or is not a directory: \(storePath)"])
        }

        let lib = try IndexStoreLibrary(dylibPath: Self.libIndexStorePath)

        // Create a temporary path for the index database.
        let dbPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deadcodefinder_index_\(UUID().uuidString)")
            .path
        
        do {
            self.store = try IndexStoreDB(
                storePath: storePath,
                databasePath: dbPath,
                library: lib,
                listenToUnitEvents: false
            )
            
            // --- THIS IS THE FIX ---
            // Explicitly wait for the index store to process any new unit files.
            // Without this, the database will be empty and all queries will fail.
            self.store.pollForUnitChangesAndWait()
            // -----------------------

            self.log("IndexStoreDB opened and synchronized successfully.")
        } catch {
            print("[ERROR] Failed to initialize IndexStoreDB: \(error)")
            try? FileManager.default.removeItem(atPath: dbPath)
            throw error
        }
    }
    
    private func log(_ message: String) {
        if verbose {
            print("[INDEX] \(message)")
        }
    }
}