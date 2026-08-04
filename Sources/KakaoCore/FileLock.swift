import Darwin
import Foundation

public protocol SendTransactionLocking: AnyObject, Sendable {
    func lock() throws
    func unlock()
}

/// Advisory lock shared by direct CLI invocations and the optional service.
public final class SendTransactionLock: SendTransactionLocking, @unchecked Sendable {
    private let path: String
    /// Held for the entire send transaction. `flock` protects independent file
    /// descriptions, while this mutex also protects callers sharing this exact
    /// lock object inside one process.
    private let inProcessLock = NSLock()
    private var descriptor: Int32 = -1

    public init(path: String) {
        self.path = path
    }

    deinit { unlock() }

    public func lock() throws {
        inProcessLock.lock()
        guard descriptor == -1 else {
            inProcessLock.unlock()
            throw KakaoClientError.state("The send lock is already held by this caller")
        }
        let opened = Darwin.open(
            path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard opened >= 0 else {
            inProcessLock.unlock()
            throw KakaoClientError.state("Could not open the send lock")
        }
        var metadata = stat()
        guard fstat(opened, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1 else {
            Darwin.close(opened)
            inProcessLock.unlock()
            throw KakaoClientError.state("The send lock is not a secure regular file")
        }
        guard fchmod(opened, S_IRUSR | S_IWUSR) == 0,
              fstat(opened, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o777 == 0o600,
              flock(opened, LOCK_EX) == 0 else {
            Darwin.close(opened)
            inProcessLock.unlock()
            throw KakaoClientError.state("Could not acquire the send lock")
        }
        descriptor = opened
    }

    public func unlock() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
        inProcessLock.unlock()
    }
}
