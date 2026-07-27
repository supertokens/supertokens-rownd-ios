//
//  RowndStorage.swift
//  ios native
//
//  Created by Matt Hamann on 6/15/22.
//

import Foundation
import OSLog

class Storage: NSObject, NSFilePresenter {
    private static let log = Logger(subsystem: "io.rownd.sdk", category: "storage")

    private let defaultContainerName = "io.rownd.sdk"

    @available(*, deprecated, message: "Use NSFileCoordinator instead")
    private lazy var userDefaultsStore = UserDefaults(suiteName: defaultContainerName)

    private let debouncer = Debouncer(delay: 0.1) // 100ms
    static var shared = Storage()
    private let operationQueue: OperationQueue

    var presentedItemURL: URL? {
        guard let sharedPrefix = Rownd.config.appGroupPrefix else {
            return computeAppStoragePath()
        }
        return computeSharedStoragePath(sharedPrefix)
    }

    var presentedItemOperationQueue: OperationQueue {
        return operationQueue
    }

    override init() {
        operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1

        super.init()

        NSFileCoordinator.addFilePresenter(self)
    }

    func presentedItemDidChange() {
        // Future use
    }

    private func computeSharedStoragePath(_ prefix: String? = nil) -> URL? {
        guard let storagePrefix = prefix else {
            return nil
        }

        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "\(storagePrefix).\(defaultContainerName)")
    }

    private func computeAppStoragePath() -> URL? {
        return try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent(defaultContainerName)
    }

    private func writeToStorage(_ value: String, fileUrl: URL) -> Bool {
        let fileCoordinator: NSFileCoordinator = NSFileCoordinator(filePresenter: self)
        var coordinationError: NSError?
        var didWrite = false
        fileCoordinator.coordinate(writingItemAt: fileUrl, options: .forReplacing, error: &coordinationError) { url in
            do {
                try value.write(to: url, atomically: false, encoding: .utf8)
                didWrite = true
            } catch {
                Self.log.error("Writing state failed \(String(describing: error))")
            }
        }

        if let error = coordinationError {
            Self.log.error("Storage write coordination failed: \(error.localizedDescription).")
        }

        return didWrite && coordinationError == nil
    }

    private func readFromStorage(_ fileUrl: URL) -> String? {
        var data: String?
        let fileCoordinator: NSFileCoordinator = NSFileCoordinator(filePresenter: self)
        fileCoordinator.coordinate(readingItemAt: fileUrl, options: [], error: nil) { url in
            if let contents = try? String(contentsOf: url, encoding: .utf8) {
                data = contents
            }
        }

        return data
    }

    func get(forKey key: String) -> String? {
        // Try to read from shared container (app group)
        var value: String?
        if let sharedFileUrl = computeSharedStoragePath(Rownd.config.appGroupPrefix) {
            value = readFromStorage(sharedFileUrl.appendingPathComponent(key))
            Self.log.trace("Read from shared container: \(Redact.redactSensitiveKeys(in: value).data(using: .utf8)?.prettyPrintedJSONString)")
        }

        // If that fails, read from primary app container
        guard value == nil else {
            Self.log.debug("Returning data from shared container")
            return value
        }

        if let appFileUrl = computeAppStoragePath() {
            value = readFromStorage(appFileUrl.appendingPathComponent(key))
            Self.log.trace("Read from app container: \(Redact.redactSensitiveKeys(in: value).data(using: .utf8)?.prettyPrintedJSONString)")
        }

        guard value == nil else {
            Self.log.debug("Returning data from app container")
            return value
        }

        // If we don't get anything, try the legacy UserDefaults store
        value = userDefaultsStore?.object(forKey: key) as? String
        Self.log.trace("Read from UserDefaults: \(Redact.redactSensitiveKeys(in: value).data(using: .utf8)?.prettyPrintedJSONString)")
        return value
    }

    @discardableResult
    func remove(forKey key: String) -> Bool {
        var didRemove = true
        var urls: [URL] = []

        if let sharedFileUrl = computeSharedStoragePath(Rownd.config.appGroupPrefix) {
            urls.append(sharedFileUrl.appendingPathComponent(key))
        }
        if let appFileUrl = computeAppStoragePath() {
            urls.append(appFileUrl.appendingPathComponent(key))
        }

        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                didRemove = false
                Self.log.error("Removing stored state failed: \(String(describing: error))")
            }
        }

        userDefaultsStore?.removeObject(forKey: key)
        return didRemove
    }

    func hasInstallationMarker(forKey key: String) -> Bool {
        let markerURL: URL?
        if Bundle.main.bundlePath.hasSuffix(".appex") {
            markerURL = computeSharedStoragePath(Rownd.config.appGroupPrefix)?.appendingPathComponent(key)
                ?? computeAppStoragePath()?.appendingPathComponent(key)
        } else {
            markerURL = computeAppStoragePath()?.appendingPathComponent(key)
        }

        guard let markerURL else { return false }
        return FileManager.default.fileExists(atPath: markerURL.path)
    }

    @discardableResult
    func setInstallationMarker(forKey key: String) -> Bool {
        let urls = installationMarkerURLs(forKey: key)

        for url in urls {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("true".utf8).write(to: url, options: .atomic)
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = true
                var mutableURL = url
                try mutableURL.setResourceValues(resourceValues)
            } catch {
                Self.log.error("Writing installation marker failed: \(String(describing: error))")
                for markerURL in urls where FileManager.default.fileExists(atPath: markerURL.path) {
                    try? FileManager.default.removeItem(at: markerURL)
                }
                return false
            }
        }

        return true
    }

    private func installationMarkerURLs(forKey key: String) -> [URL] {
        var urls: [URL] = []

        if let sharedURL = computeSharedStoragePath(Rownd.config.appGroupPrefix) {
            urls.append(sharedURL.appendingPathComponent(key))
        }
        if let appURL = computeAppStoragePath() {
            urls.append(appURL.appendingPathComponent(key))
        }

        return urls
    }

    @discardableResult
    func set(_ value: String, forKey key: String) -> Bool {
        var didWrite = true

        // If shared folder enabled, write to that
        if let sharedFileUrl = computeSharedStoragePath(Rownd.config.appGroupPrefix) {
            let sharedURL = sharedFileUrl.appendingPathComponent(key)
            let didWriteSharedValue = writeToStorage(value, fileUrl: sharedURL)
            didWrite = didWriteSharedValue && didWrite
            if didWriteSharedValue {
                Self.log.debug("Successfully wrote to \(String(describing: sharedURL))")
            }
        }

        // Always write to default
        appFileIf: if let appFileUrl = computeAppStoragePath() {
            if !FileManager.default.fileExists(atPath: appFileUrl.path) {
                do {
                    try FileManager.default.createDirectory(at: appFileUrl, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    Self.log.error("Failed to create storage directory: \(String(describing: error))")
                    didWrite = false
                    break appFileIf
                }
            }

            let appURL = appFileUrl.appendingPathComponent(key)
            let didWriteAppValue = writeToStorage(value, fileUrl: appURL)
            didWrite = didWriteAppValue && didWrite
            if didWriteAppValue {
                Self.log.debug("Successfully wrote to \(String(describing: appURL))")
            }
        } else {
            didWrite = false
        }

        // We no longer want to use UserDefaults for state, so we'll remove this later.
        // Mainly keeping it around for backward compat purposes. Remove in v5.0 or later.
        userDefaultsStore?.set(value, forKey: key)
        return didWrite
    }
}
