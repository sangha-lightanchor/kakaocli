import ArgumentParser
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
            let client = try KakaoClient.live(databasePath: database.db, databaseKey: database.key, paths: paths)
            try LocalServiceServer(socketURL: paths.socket).run(client: client)
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status", abstract: "Check the local service")

        mutating func run() throws {
            let paths = RuntimePaths()
            let connection = LocalServiceConnection(socketURL: paths.socket)
            guard connection.isAvailable else {
                print("stopped socket=\(paths.socket.path)")
                return
            }
            let status = try connection.call(LocalServiceRequest(method: "status"), as: ServiceStatus.self)
            print("running pid=\(status.processID) socket=\(status.socketPath)")
        }
    }
}
