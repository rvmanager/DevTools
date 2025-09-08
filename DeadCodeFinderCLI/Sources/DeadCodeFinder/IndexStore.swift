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
//        self.log("Initializing IndexStore...")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: storePath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NSError(domain: "DeadCodeFinder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Index store path does not exist or is not a directory: \(storePath)"])
        }

//        self.log("Loading dylib from: \(Self.libIndexStorePath)")
        let lib = try IndexStoreLibrary(dylibPath: Self.libIndexStorePath)

        // Create a temporary path for the index database.
        let dbPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deadcodefinder_index_\(UUID().uuidString)")
            .path
        
//        self.log("Using temporary DB path: \(dbPath)")

        do {
            self.store = try IndexStoreDB(
                storePath: storePath,
                databasePath: dbPath,
                library: lib,
                listenToUnitEvents: false
            )
            self.log("IndexStoreDB opened successfully.")
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