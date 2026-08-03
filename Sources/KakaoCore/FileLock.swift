import Darwin
import Foundation

public protocol SendTransactionLocking: AnyObject, Sendable {
    func lock() throws
    func unlock()
}

/// Advisory lock shared by direct CLI invocations and the optional service.
public final class SendTransactionLock: SendTransactionLocking, @unchecked Sendable {
    private let path: String
    private var descriptor: Int32 = -1

    public init(path: String) {
        self.path = path
    }

    deinit { unlock() }

    public func lock() throws {
        guard descriptor == -1 else { return }
        let opened = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard opened >= 0 else {
            throw KakaoClientError.state("Could not open the send lock")
        }
        guard fchmod(opened, S_IRUSR | S_IWUSR) == 0, flock(opened, LOCK_EX) == 0 else {
            Darwin.close(opened)
            throw KakaoClientError.state("Could not acquire the send lock")
        }
        descriptor = opened
    }

    public func unlock() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }
}
