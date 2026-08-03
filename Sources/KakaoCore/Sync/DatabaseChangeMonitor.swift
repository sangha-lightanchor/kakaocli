import Darwin
import Foundation

public enum DatabaseChangeReason: Sendable {
    case filesystem
    case reconciliation
}

/// Watches the database and current WAL using vnode notifications, with a
/// debounced callback and a 60-second reconciliation backstop.
public final class DatabaseChangeMonitor: @unchecked Sendable {
    private let paths: [String]
    private let queue = DispatchQueue(label: "com.kakaocli.database-events", qos: .utility)
    private let debounce: TimeInterval
    private let reconciliation: TimeInterval
    private var sources: [DispatchSourceFileSystemObject] = []
    private var descriptors: [Int32] = []
    private var timer: DispatchSourceTimer?
    private var pending: DispatchWorkItem?

    public init(databasePath: String, debounce: TimeInterval = 0.1, reconciliation: TimeInterval = 60) {
        self.paths = [databasePath, databasePath + "-wal"]
        self.debounce = debounce
        self.reconciliation = reconciliation
    }

    deinit { stop() }

    public func start(handler: @escaping @Sendable (DatabaseChangeReason) -> Void) {
        stop()
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let descriptor = Darwin.open(path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .rename, .delete],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.pending?.cancel()
                let item = DispatchWorkItem { handler(.filesystem) }
                self.pending = item
                self.queue.asyncAfter(deadline: .now() + self.debounce, execute: item)
            }
            source.setCancelHandler { Darwin.close(descriptor) }
            source.resume()
            descriptors.append(descriptor)
            sources.append(source)
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + reconciliation, repeating: reconciliation)
        timer.setEventHandler { handler(.reconciliation) }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        for source in sources { source.cancel() }
        sources.removeAll()
        descriptors.removeAll()
        timer?.cancel()
        timer = nil
    }
}
