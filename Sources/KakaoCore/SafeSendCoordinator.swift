import CryptoKit
import Foundation

public final class SafeSendCoordinator: @unchecked Sendable {
    private let database: KakaoDatabaseAccess
    private let state: SendStateStoring
    private let ui: KakaoSendUI
    private let transactionLock: SendTransactionLocking
    private let confirmationAttempts: Int
    private let confirmationDelay: TimeInterval

    public init(
        database: KakaoDatabaseAccess,
        state: SendStateStoring,
        ui: KakaoSendUI,
        transactionLock: SendTransactionLocking,
        confirmationAttempts: Int = 50,
        confirmationDelay: TimeInterval = 0.1
    ) {
        self.database = database
        self.state = state
        self.ui = ui
        self.transactionLock = transactionLock
        self.confirmationAttempts = max(1, confirmationAttempts)
        self.confirmationDelay = max(0, confirmationDelay)
    }

    public func send(_ request: SendRequest) throws -> SendReceipt {
        let bodyData = Data(request.body.utf8)
        guard !bodyData.isEmpty else {
            throw KakaoClientError.invalidRequest("Message body cannot be empty")
        }
        guard !bodyData.contains(0) else {
            throw KakaoClientError.invalidRequest("Message body cannot contain NUL bytes")
        }
        let bodyHash = SHA256.hash(data: bodyData).map { String(format: "%02x", $0) }.joined()

        try transactionLock.lock()
        defer { transactionLock.unlock() }

        if let stored = try state.sendAttempt(requestID: request.requestID) {
            guard stored.destinationKey == request.destination.storageKey,
                  stored.bodySHA256 == bodyHash else {
                throw KakaoClientError.requestIDConflict(request.requestID)
            }
            return stored.receipt
        }

        let chat: Chat
        switch request.destination {
        case .chatID(let id):
            guard let resolved = try database.chat(id: id) else {
                throw KakaoClientError.chatNotFound(id)
            }
            chat = resolved
        case .selfChat:
            guard let resolved = try database.selfChat() else {
                throw KakaoClientError.selfChatNotFound
            }
            chat = resolved
        }
        guard chat.displayName != "(unknown)" else {
            throw KakaoClientError.uiPrecondition("Chat ID \(chat.id) has no provable UI identity")
        }

        let highWatermark = try database.maxLogID(chatID: chat.id)
        do {
            try ui.submit(chat: chat, body: request.body)
        } catch let error as SendUIError {
            switch error {
            case .preconditionFailed(let message):
                throw KakaoClientError.uiPrecondition(message)
            case .outcomeUnknown:
                return try storeUnknown(request: request, chat: chat, bodyHash: bodyHash)
            }
        } catch {
            throw error
        }

        for attempt in 0..<confirmationAttempts {
            if let logID = try database.confirmedOutgoing(
                chatID: chat.id,
                body: bodyData,
                after: highWatermark
            ) {
                let receipt = SendReceipt(
                    requestID: request.requestID,
                    chatID: chat.id,
                    logID: logID,
                    status: .confirmed
                )
                try state.saveSendAttempt(
                    destinationKey: request.destination.storageKey,
                    bodySHA256: bodyHash,
                    receipt: receipt
                )
                return receipt
            }
            if attempt + 1 < confirmationAttempts, confirmationDelay > 0 {
                Thread.sleep(forTimeInterval: confirmationDelay)
            }
        }
        return try storeUnknown(request: request, chat: chat, bodyHash: bodyHash)
    }

    private func storeUnknown(request: SendRequest, chat: Chat, bodyHash: String) throws -> SendReceipt {
        let receipt = SendReceipt(
            requestID: request.requestID,
            chatID: chat.id,
            logID: nil,
            status: .unknown
        )
        try state.saveSendAttempt(
            destinationKey: request.destination.storageKey,
            bodySHA256: bodyHash,
            receipt: receipt
        )
        return receipt
    }
}
