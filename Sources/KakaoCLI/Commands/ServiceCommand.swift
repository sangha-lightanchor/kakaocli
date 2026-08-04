import ArgumentParser
import Foundation
import KakaoCore

struct ServiceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "service",
        abstract: "Run or inspect the optional local service",
        subcommands: [Run.self, Status.self]
    )

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "run", abstract: "Run the service in the current process")
        @OptionGroup var database: DatabaseOptions

        mutating func run() throws {
            let paths = RuntimePaths()
            try paths.prepare()
            let client = try KakaoClient.live(databasePath: database.db, paths: paths)
            try LocalServiceServer(
                socketURL: paths.socket,
                lifetimeLockURL: paths.serviceLock
            ).run(client: client)
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status", abstract: "Check the local service")
        @Flag(name: .long, help: "Output JSON") var json = false

        mutating func run() throws {
            let paths = RuntimePaths()
            let connection = LocalServiceConnection(socketURL: paths.socket)
            guard connection.isAvailable else {
                if json {
                    struct Stopped: Encodable { let running = false; let socketPath: String }
                    try JSONOutput.print(Stopped(socketPath: paths.socket.path))
                } else {
                    print("stopped socket=\(paths.socket.path)")
                }
                throw ExitCode.failure
            }
            let status = try connection.call(LocalServiceRequest(method: "status"), as: ServiceStatus.self)
            if json { try JSONOutput.print(status) }
            else {
                print("running pid=\(status.processID) socket=\(status.socketPath) protocol=\(status.protocolVersion)")
            }
        }
    }
}
