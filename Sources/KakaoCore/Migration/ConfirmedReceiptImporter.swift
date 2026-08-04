import CryptoKit
import Foundation

/// Restores one durable idempotency receipt from an already-existing outgoing
/// source-database row. This performs read-only proof and never invokes UI.
public final class ConfirmedReceiptImporter: @unchecked Sendable {
    private let database: KakaoDatabaseAccess
    private let state: SendStateStoring

    public init(database: KakaoDatabaseAccess, state: SendStateStoring) {
        self.database = database
        self.state = state
    }

    public func importReceipt(
        request: SendRequest,
        chatID: ChatID,
        logID: Int64
    ) throws -> SendReceipt {
        try KakaoLimits.validateSendBody(request.body)
        guard chatID.rawValue > 0, logID > 0 else {
            throw KakaoClientError.invalidRequest("Recovered chat and log IDs must be positive")
        }

        switch request.destination {
        case .chatID(let destinationID):
            guard destinationID == chatID, try database.chat(id: chatID) != nil else {
                throw KakaoClientError.invalidRequest(
                    "The recovered chat ID does not match an exact source-database chat"
                )
            }
        case .selfChat:
            guard try database.selfChat()?.id == chatID else {
                throw KakaoClientError.invalidRequest(
                    "The recovered chat ID is not the current source-database self-chat"
                )
            }
        }

        let body = Data(request.body.utf8)
        guard try database.confirmedOutgoing(
            chatID: chatID,
            body: body,
            after: logID - 1
        ) == logID else {
            throw KakaoClientError.invalidRequest(
                "The source database does not contain that exact outgoing message row"
            )
        }

        let bodyHash = SHA256.hash(data: body)
            .map { String(format: "%02x", $0) }
            .joined()
        let destinationKey = request.destination.storageKey
        let receipt = SendReceipt(
            requestID: request.requestID,
            chatID: chatID,
            logID: logID,
            status: .confirmed
        )

        var createdReservation = false
        if let existing = try state.sendAttempt(requestID: request.requestID) {
            guard existing.destinationKey == destinationKey,
                  existing.bodySHA256 == bodyHash,
                  existing.receipt.chatID == chatID else {
                throw KakaoClientError.requestIDConflict(request.requestID)
            }
            if existing.receipt.status == .confirmed {
                guard existing.receipt.logID == logID else {
                    throw KakaoClientError.requestIDConflict(request.requestID)
                }
                return existing.receipt
            }
        } else {
            try state.saveSendAttempt(
                destinationKey: destinationKey,
                bodySHA256: bodyHash,
                body: body,
                highWatermark: logID - 1,
                receipt: SendReceipt(
                    requestID: request.requestID,
                    chatID: chatID,
                    logID: nil,
                    status: .unknown
                )
            )
            createdReservation = true
        }

        let claimed = try state.claimConfirmedSendAttempt(
            destinationKey: destinationKey,
            bodySHA256: bodyHash,
            body: body,
            highWatermark: logID - 1,
            receipt: receipt
        )
        guard claimed else {
            if createdReservation {
                try? state.removeSendAttempt(requestID: request.requestID)
            }
            throw KakaoClientError.state(
                "The recovered log ID is already owned by another request ID"
            )
        }
        return receipt
    }
}
