import Darwin
import Foundation

public enum DatabaseChangeReason: Sendable {
    case filesystem
    case reconciliation
}

/// Watches the database, WAL, and their parent directory. The directory source
/// lets the monitor attach to a WAL created after startup and rearm file sources
/// after checkpoint rename/delete cycles.
public final class DatabaseChangeMonitor: @unchecked Sendable {
    private let watchedPaths: [String]
    private let parentPath: String
    private let queue = DispatchQueue(label: "com.kakaocli.database-events", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let debounce: TimeInterval
    private let reconciliation: TimeInterval
    private var fileSources: [String: FileWatch] = [:]
    private var directorySource: FileWatch?
    private var timer: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private var handler: (@Sendable (DatabaseChangeReason) -> Void)?

    public init(databasePath: String, debounce: TimeInterval = 0.1, reconciliation: TimeInterval = 60) {
        self.watchedPaths = [databasePath, databasePath + "-wal"]
        self.parentPath = URL(fileURLWithPath: databasePath).deletingLastPathComponent().path
        self.debounce = max(0, debounce)
        self.reconciliation = max(1, reconciliation)
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit { stop() }

    public func start(handler: @escaping @Sendable (DatabaseChangeReason) -> Void) {
        onQueue {
            stopLocked()
            self.handler = handler
            installDirectorySource()
            refreshFileSources()

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + reconciliation, repeating: reconciliation)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.installDirectorySource()
                self.refreshFileSources()
                self.handler?(.reconciliation)
            }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        onQueue { stopLocked() }
    }

    private func installDirectorySource() {
        if let directorySource {
            var info = stat()
            var descriptorInfo = stat()
            if lstat(parentPath, &info) == 0,
               fstat(directorySource.descriptor, &descriptorInfo) == 0,
               info.st_dev == descriptorInfo.st_dev,
               info.st_ino == descriptorInfo.st_ino {
                return
            }
            directorySource.source.cancel()
            self.directorySource = nil
        }

        let descriptor = Darwin.open(parentPath, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.scheduleFilesystemNotification()
            self.refreshFileSources()
            if !self.descriptorStillMatchesPath(descriptor, path: self.parentPath) {
                if let watch = self.directorySource, watch.descriptor == descriptor {
                    watch.source.cancel()
                    self.directorySource = nil
                }
                self.installDirectorySource()
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        directorySource = FileWatch(source: source, descriptor: descriptor)
    }

    private func refreshFileSources() {
        for path in watchedPaths {
            if let watch = fileSources[path] {
                if descriptorStillMatchesPath(watch.descriptor, path: path) { continue }
                watch.source.cancel()
                fileSources.removeValue(forKey: path)
            }
            installFileSource(path: path)
        }
    }

    private func installFileSource(path: String) {
        guard fileSources[path] == nil else { return }
        let descriptor = Darwin.open(path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.scheduleFilesystemNotification()
            if !self.descriptorStillMatchesPath(descriptor, path: path) {
                if let watch = self.fileSources[path], watch.descriptor == descriptor {
                    watch.source.cancel()
                    self.fileSources.removeValue(forKey: path)
                }
                self.installFileSource(path: path)
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        fileSources[path] = FileWatch(source: source, descriptor: descriptor)
    }

    private func scheduleFilesystemNotification() {
        pending?.cancel()
        let handler = self.handler
        let item = DispatchWorkItem { handler?(.filesystem) }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private func descriptorStillMatchesPath(_ descriptor: Int32, path: String) -> Bool {
        var descriptorInfo = stat()
        var pathInfo = stat()
        return fstat(descriptor, &descriptorInfo) == 0
            && lstat(path, &pathInfo) == 0
            && descriptorInfo.st_dev == pathInfo.st_dev
            && descriptorInfo.st_ino == pathInfo.st_ino
    }

    private func stopLocked() {
        pending?.cancel()
        pending = nil
        for watch in fileSources.values { watch.source.cancel() }
        fileSources.removeAll()
        directorySource?.source.cancel()
        directorySource = nil
        timer?.cancel()
        timer = nil
        handler = nil
    }

    private func onQueue(_ operation: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { operation() }
        else { queue.sync(execute: operation) }
    }
}

private struct FileWatch {
    let source: DispatchSourceFileSystemObject
    let descriptor: Int32
}
