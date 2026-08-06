import Testing
@testable import KakaoCore

@Suite("Already-open room binding decisions")
struct OpenRoomBindingTests {
    @Test("binding requires one unchanged exact clean room and foreground")
    func readyEvidence() {
        let exact = evidence()
        #expect(OpenRoomBindingValidator.isReady(exact))

        let invalid = [
            evidence(matchingRoomCount: 0),
            evidence(matchingRoomCount: 2),
            evidence(sameWindow: false),
            evidence(exactTitle: false),
            evidence(composerCount: 0),
            evidence(composerCount: 2),
            evidence(composerIdentityMatches: false),
            evidence(composerEmpty: false),
            evidence(cleanComposition: false),
            evidence(windowSetUnchanged: false),
            evidence(foregroundUnchanged: false),
        ]
        for candidate in invalid {
            #expect(!OpenRoomBindingValidator.isReady(candidate))
        }
    }

    private func evidence(
        matchingRoomCount: Int = 1,
        sameWindow: Bool = true,
        exactTitle: Bool = true,
        composerCount: Int = 1,
        composerIdentityMatches: Bool = true,
        composerEmpty: Bool = true,
        cleanComposition: Bool = true,
        windowSetUnchanged: Bool = true,
        foregroundUnchanged: Bool = true
    ) -> OpenRoomBindingEvidence {
        OpenRoomBindingEvidence(
            matchingRoomCount: matchingRoomCount,
            sameWindow: sameWindow,
            exactTitle: exactTitle,
            composerCount: composerCount,
            composerIdentityMatches: composerIdentityMatches,
            composerEmpty: composerEmpty,
            cleanComposition: cleanComposition,
            windowSetUnchanged: windowSetUnchanged,
            foregroundUnchanged: foregroundUnchanged
        )
    }
}
