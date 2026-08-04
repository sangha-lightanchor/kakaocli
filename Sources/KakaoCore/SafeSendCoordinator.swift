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
        confirmationAttempts: Int = 120,
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
        try KakaoLimits.validateSendBody(request.body)
        let bodyData = Data(request.body.utf8)
        let bodyHash = SHA256.hash(data: bodyData).map { String(format: "%02x", $0) }.joined()

        try transactionLock.lock()
        defer { transactionLock.unlock() }

        if let stored = try state.sendAttempt(requestID: request.requestID) {
            guard stored.destinationKey == request.destination.storageKey,
                  stored.bodySHA256 == bodyHash else {
                throw KakaoClientError.requestIDConflict(request.requestID)
            }
            if stored.receipt.status == .unknown,
               let storedBody = stored.body,
               let storedHighWatermark = stored.highWatermark,
               let logID = try database.confirmedOutgoing(
                   chatID: stored.receipt.chatID,
                   body: storedBody,
                   after: storedHighWatermark
               ) {
                let confirmed = SendReceipt(
                    requestID: request.requestID,
                    chatID: stored.receipt.chatID,
                    logID: logID,
                    status: .confirmed
                )
                let claimed = try state.claimConfirmedSendAttempt(
                    destinationKey: stored.destinationKey,
                    bodySHA256: stored.bodySHA256,
                    body: storedBody,
                    highWatermark: storedHighWatermark,
                    receipt: confirmed
                )
                return claimed ? confirmed : stored.receipt
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
        guard try database.chatUIIdentityCount(displayName: chat.displayName) == 1 else {
            throw KakaoClientError.uiPrecondition(
                "Chat ID \(chat.id) does not have a database-unique UI identity"
            )
        }

        let highWatermark = try database.maxLogID(chatID: chat.id)
        let provisional = SendReceipt(
            requestID: request.requestID,
            chatID: chat.id,
            logID: nil,
            status: .unknown
        )
        // Reserve the request before the irreversible UI action. If the
        // process dies after this point, replay returns unknown instead of
        // risking a duplicate message.
        try state.saveSendAttempt(
            destinationKey: request.destination.storageKey,
            bodySHA256: bodyHash,
            body: bodyData,
            highWatermark: highWatermark,
            receipt: provisional
        )
        do {
            try ui.submit(chat: chat, body: request.body)
        } catch let error as SendUIError {
            switch error {
            case .preconditionFailed(let message):
                // SafeKakaoSender guarantees that this case occurs before a
                // submit action and clears any text it composed.
                try state.removeSendAttempt(requestID: request.requestID)
                throw KakaoClientError.uiPrecondition(message)
            case .outcomeUnknown:
                // Invoking the UI control may have succeeded even when the AX
                // call could not acknowledge it. Confirmation is read-only and
                // must still run; it never retries the UI action.
                break
            }
        } catch {
            // Once the reservation exists, an unclassified transport error
            // cannot prove that no action occurred. Continue confirmation and
            // conservatively keep `unknown`; never expose a retry-safe error.
        }

        for attempt in 0..<confirmationAttempts {
            do {
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
                    let claimed = try state.claimConfirmedSendAttempt(
                        destinationKey: request.destination.storageKey,
                        bodySHA256: bodyHash,
                        body: bodyData,
                        highWatermark: highWatermark,
                        receipt: receipt
                    )
                    // Another request ID already owning this exact log row
                    // makes attribution ambiguous. Never claim it or retry UI.
                    return claimed ? receipt : provisional
                }
            } catch {
                // A read or receipt-upgrade failure after the UI action has an
                // unknown outcome. The durable reservation blocks UI replay.
                return provisional
            }
            if attempt + 1 < confirmationAttempts, confirmationDelay > 0 {
                Thread.sleep(forTimeInterval: confirmationDelay)
            }
        }
        return provisional
    }
}
