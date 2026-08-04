import ArgumentParser

@main
struct KakaoCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kakaocli",
        abstract: "Safe local KakaoTalk library and CLI",
        version: "1.0.6",
        subcommands: [
            AuthCommand.self,
            ChatsCommand.self,
            MessagesCommand.self,
            WarmupCommand.self,
            SendCommand.self,
            ServiceCommand.self,
            ConfigCommand.self,
            ArchiveCommand.self,
            MigrationCommand.self,
        ]
    )
}
