import Foundation

public struct RuntimePaths: Sendable {
    public let stateDirectory: URL
    public let stateDatabase: URL
    public let runDirectory: URL
    public let socket: URL
    public let lock: URL
    public let archiveRoot: URL

    public init(
        stateDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kakaocli", isDirectory: true),
        archiveRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/kakaocli/archive", isDirectory: true)
    ) {
        self.stateDirectory = stateDirectory
        self.stateDatabase = stateDirectory.appendingPathComponent("state.sqlite3")
        self.runDirectory = stateDirectory.appendingPathComponent("run", isDirectory: true)
        self.socket = runDirectory.appendingPathComponent("kakaocli.sock")
        self.lock = runDirectory.appendingPathComponent("send.lock")
        self.archiveRoot = archiveRoot
    }

    public func prepare() throws {
        for directory in [stateDirectory, runDirectory, archiveRoot,
                          archiveRoot.appendingPathComponent("objects", isDirectory: true)] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard chmod(directory.path, 0o700) == 0 else {
                throw KakaoClientError.state("Could not secure directory \(directory.path)")
            }
        }
    }
}
