import Testing
@testable import KakaoCore

@Suite("Foreground room warm-up decisions")
struct ForegroundRoomWarmupTests {
    @Test("menu action requires exact stable row-menu evidence")
    func menuEvidence() {
        let exact = RoomWarmupMenuEvidence(
            matchingItemCount: 1,
            exactForeground: true,
            sceneUnchanged: true,
            menuStillPresent: true,
            itemBelongsToMenu: true
        )
        #expect(RoomWarmupValidator.permitsOpenItemPress(exact))

        let invalid = [
            RoomWarmupMenuEvidence(matchingItemCount: 0, exactForeground: true, sceneUnchanged: true, menuStillPresent: true, itemBelongsToMenu: true),
            RoomWarmupMenuEvidence(matchingItemCount: 2, exactForeground: true, sceneUnchanged: true, menuStillPresent: true, itemBelongsToMenu: true),
            RoomWarmupMenuEvidence(matchingItemCount: 1, exactForeground: false, sceneUnchanged: true, menuStillPresent: true, itemBelongsToMenu: true),
            RoomWarmupMenuEvidence(matchingItemCount: 1, exactForeground: true, sceneUnchanged: false, menuStillPresent: true, itemBelongsToMenu: true),
            RoomWarmupMenuEvidence(matchingItemCount: 1, exactForeground: true, sceneUnchanged: true, menuStillPresent: false, itemBelongsToMenu: true),
            RoomWarmupMenuEvidence(matchingItemCount: 1, exactForeground: true, sceneUnchanged: true, menuStillPresent: true, itemBelongsToMenu: false),
        ]
        for evidence in invalid {
            #expect(!RoomWarmupValidator.permitsOpenItemPress(evidence))
        }
    }

    @Test("opened room requires one exact clean new window")
    func openedRoomEvidence() {
        let exact = RoomWarmupOpenedRoomEvidence(
            windowDelta: 1,
            newWindowCount: 1,
            verifiedRoomWindow: true,
            exactTitle: true,
            composerCount: 1,
            composerEmpty: true,
            cleanComposition: true
        )
        #expect(RoomWarmupValidator.isExactOpenedRoom(exact))

        let invalid = [
            RoomWarmupOpenedRoomEvidence(windowDelta: 0, newWindowCount: 1, verifiedRoomWindow: true, exactTitle: true, composerCount: 1, composerEmpty: true, cleanComposition: true),
            RoomWarmupOpenedRoomEvidence(windowDelta: 2, newWindowCount: 2, verifiedRoomWindow: true, exactTitle: true, composerCount: 1, composerEmpty: true, cleanComposition: true),
            RoomWarmupOpenedRoomEvidence(windowDelta: 1, newWindowCount: 1, verifiedRoomWindow: false, exactTitle: true, composerCount: 1, composerEmpty: true, cleanComposition: true),
            RoomWarmupOpenedRoomEvidence(windowDelta: 1, newWindowCount: 1, verifiedRoomWindow: true, exactTitle: false, composerCount: 1, composerEmpty: true, cleanComposition: true),
            RoomWarmupOpenedRoomEvidence(windowDelta: 1, newWindowCount: 1, verifiedRoomWindow: true, exactTitle: true, composerCount: 2, composerEmpty: true, cleanComposition: true),
            RoomWarmupOpenedRoomEvidence(windowDelta: 1, newWindowCount: 1, verifiedRoomWindow: true, exactTitle: true, composerCount: 1, composerEmpty: false, cleanComposition: true),
            RoomWarmupOpenedRoomEvidence(windowDelta: 1, newWindowCount: 1, verifiedRoomWindow: true, exactTitle: true, composerCount: 1, composerEmpty: true, cleanComposition: false),
        ]
        for evidence in invalid {
            #expect(!RoomWarmupValidator.isExactOpenedRoom(evidence))
        }
    }
}
