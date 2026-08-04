import Darwin
import Foundation

public struct RuntimePaths: Sendable {
    public let stateDirectory: URL
    public let stateDatabase: URL
    public let stateKey: URL
    public let runDirectory: URL
    public let socket: URL
    public let lock: URL
    public let serviceLock: URL
    public let archiveRoot: URL

    public init(
        stateDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kakaocli", isDirectory: true),
        archiveRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/kakaocli/archive", isDirectory: true)
    ) {
        self.stateDirectory = stateDirectory
        self.stateDatabase = stateDirectory.appendingPathComponent("state.sqlite3")
        self.stateKey = stateDirectory.appendingPathComponent("state.key")
        self.runDirectory = stateDirectory.appendingPathComponent("run", isDirectory: true)
        self.socket = runDirectory.appendingPathComponent("kakaocli.sock")
        self.lock = runDirectory.appendingPathComponent("send.lock")
        self.serviceLock = runDirectory.appendingPathComponent("service.lock")
        self.archiveRoot = archiveRoot
    }

    public func prepare() throws {
        for directory in [stateDirectory, runDirectory, archiveRoot,
                          archiveRoot.appendingPathComponent("objects", isDirectory: true)] {
            var existing = stat()
            if lstat(directory.path, &existing) == 0 {
                guard existing.st_mode & S_IFMT == S_IFDIR,
                      existing.st_uid == geteuid() else {
                    throw KakaoClientError.state(
                        "Refusing an insecure or foreign-owned runtime directory: \(directory.path)"
                    )
                }
            } else if errno != ENOENT {
                throw KakaoClientError.state("Could not inspect directory \(directory.path)")
            }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var verified = stat()
            guard lstat(directory.path, &verified) == 0,
                  verified.st_mode & S_IFMT == S_IFDIR,
                  verified.st_uid == geteuid(),
                  chmod(directory.path, 0o700) == 0 else {
                throw KakaoClientError.state("Could not secure directory \(directory.path)")
            }
        }
    }
}
