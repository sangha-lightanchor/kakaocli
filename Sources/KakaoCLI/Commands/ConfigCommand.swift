import ArgumentParser
import Foundation
import KakaoCore

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Manage local allowlists and optional webhook delivery",
        subcommands: [AllowChat.self, DisallowChat.self, List.self, Webhook.self]
    )

    struct AllowChat: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "allow-chat", abstract: "Allow one exact chat ID to be archived")
        @Argument var chatID: Int64
        @OptionGroup var database: DatabaseOptions
        mutating func run() async throws {
            guard chatID > 0 else { throw ValidationError("chat ID must be positive") }
            try await liveClient(database).allow(chatID: ChatID(rawValue: chatID))
            print("Allowed chat_id=\(chatID)")
        }
    }

    struct DisallowChat: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "disallow-chat", abstract: "Stop archiving one chat ID")
        @Argument var chatID: Int64
        @OptionGroup var database: DatabaseOptions
        mutating func run() async throws {
            guard chatID > 0 else { throw ValidationError("chat ID must be positive") }
            try await liveClient(database).disallow(chatID: ChatID(rawValue: chatID))
            print("Disallowed chat_id=\(chatID)")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List allowlisted chat IDs")
        @Flag(name: .long) var json = false
        @OptionGroup var database: DatabaseOptions
        mutating func run() async throws {
            let values = try await liveClient(database).allowedChats()
            if json { try JSONOutput.print(values) }
            else { values.forEach { print($0) } }
        }
    }

    struct Webhook: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "webhook", abstract: "Configure a fresh generic webhook; disabled when --disable is set")
        @Option(name: .long) var url: String?
        @Flag(name: .long) var bearerTokenStdin = false
        @Flag(name: .long) var disable = false
        @OptionGroup var database: DatabaseOptions
        mutating func run() async throws {
            guard disable != (url != nil) else { throw ValidationError("Specify exactly one of --url or --disable") }
            guard !disable || !bearerTokenStdin else {
                throw ValidationError("--bearer-token-stdin cannot be used with --disable")
            }
            let token: String?
            if bearerTokenStdin {
                let data = try readBoundedStdin(
                    maximumBytes: KakaoLimits.maximumSecretBytes,
                    label: "bearer token"
                )
                guard let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines) else {
                    throw ValidationError("bearer token stdin must be UTF-8")
                }
                token = value
            } else { token = nil }
            let parsedURL: URL?
            if disable {
                parsedURL = nil
            } else {
                guard let raw = url, let value = URL(string: raw), value.scheme != nil else {
                    throw ValidationError("--url must be an absolute URL")
                }
                parsedURL = value
            }
            try await liveClient(database).configureWebhook(
                url: parsedURL,
                bearerToken: token
            )
            print(disable ? "Webhook disabled" : "Webhook configured")
        }
    }
}
