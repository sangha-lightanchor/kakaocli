import ArgumentParser
import KakaoCore

struct ArchiveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "archive",
        abstract: "Inspect or reconcile the local allowlisted archive",
        subcommands: [Status.self, Reconcile.self]
    )

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status")
        @Flag(name: .long) var json = false
        @OptionGroup var database: DatabaseOptions
        mutating func run() async throws {
            let connection = serviceConnection()
            let status: ArchiveStatus
            if !database.usesOverride, connection.isAvailable {
                status = try connection.call(LocalServiceRequest(method: "archive_status"), as: ArchiveStatus.self)
            } else {
                status = try await liveClient(database).archiveStatus()
            }
            if json { try JSONOutput.print(status) }
            else {
                print("messages=\(status.messageCount) attachments=\(status.attachmentCount) objects=\(status.objectCount) pending=\(status.pendingDownloadCount) expired=\(status.expiredAttachmentCount) failed=\(status.failedDownloadCount) low_disk=\(status.pausedLowDiskCount) webhooks=\(status.pendingWebhookCount)")
            }
        }
    }

    struct Reconcile: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "reconcile", abstract: "Run an allowlisted seven-day reconciliation now")
        @OptionGroup var database: DatabaseOptions
        mutating func run() async throws {
            try await liveClient(database).processArchiveNow()
            print("Archive reconciliation complete")
        }
    }
}
