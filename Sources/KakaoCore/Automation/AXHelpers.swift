import ApplicationServices
import Foundation

/// Accessibility helpers intentionally limited to element inspection, direct
/// value mutation, and actions on already-rendered KakaoTalk controls.
/// Activation, room navigation, keyboard input, focus mutation, and selection
/// mutation are prohibited everywhere.
enum AXHelpers {
    enum ChatListResolution {
        case verified(AXUIElement)
        case navigationUnverified
        case tableUnverified

        var table: AXUIElement? {
            guard case .verified(let table) = self else { return nil }
            return table
        }
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        (attribute(element, name) as? NSNumber)?.boolValue
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
    }

    static func windows(_ app: AXUIElement) -> [AXUIElement] {
        let declared = attribute(app, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
        // KakaoTalk can transiently return AXApplication objects (including
        // duplicates of itself) through AXWindows after a room closes. Never
        // treat a merely non-empty attribute as a window set.
        if !declared.isEmpty,
           declared.allSatisfy({ role($0) == kAXWindowRole as String }) {
            return declared
        }

        // Current KakaoTalk can return an empty or malformed AXWindows array
        // while its rendered windows remain direct application children.
        // Accept only direct AXWindow children; never search arbitrary
        // descendants or make the application active to repopulate AXWindows.
        return children(app).filter { role($0) == kAXWindowRole as String }
    }

    static func role(_ element: AXUIElement) -> String? { string(element, kAXRoleAttribute as String) }
    static func subrole(_ element: AXUIElement) -> String? { string(element, kAXSubroleAttribute as String) }
    static func title(_ element: AXUIElement) -> String? { string(element, kAXTitleAttribute as String) }
    static func value(_ element: AXUIElement) -> String? { string(element, kAXValueAttribute as String) }
    static func identifier(_ element: AXUIElement) -> String? { string(element, kAXIdentifierAttribute as String) }
    static func description(_ element: AXUIElement) -> String? { string(element, kAXDescriptionAttribute as String) }

    static func rect(_ element: AXUIElement) -> CGRect? {
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &rawPosition
        ) == .success,
        AXUIElementCopyAttributeValue(
            element, kAXSizeAttribute as CFString, &rawSize
        ) == .success,
        let rawPosition, let rawSize,
        CFGetTypeID(rawPosition) == AXValueGetTypeID(),
        CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(rawPosition as! AXValue) == .cgPoint,
              AXValueGetValue(rawPosition as! AXValue, .cgPoint, &point),
              AXValueGetType(rawSize as! AXValue) == .cgSize,
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else { return nil }
        let rect = CGRect(origin: point, size: size)
        guard !rect.isNull, !rect.isInfinite,
              rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    static func hasContainedFrame(_ element: AXUIElement, in container: AXUIElement) -> Bool {
        guard let frame = rect(element), let containerFrame = rect(container) else { return false }
        return containerFrame.contains(frame)
    }

    static func setValue(_ element: AXUIElement, _ value: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef) == .success
    }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success
            && settable.boolValue
    }

    static func contains(_ root: AXUIElement, _ target: AXUIElement) -> Bool {
        descendants(root, matching: { CFEqual($0, target) }).count == 1
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    static func perform(_ element: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }

    static func descendants(
        _ root: AXUIElement,
        matching predicate: (AXUIElement) -> Bool,
        depth: Int = 0,
        maximumDepth: Int = 12
    ) -> [AXUIElement] {
        guard depth <= maximumDepth else { return [] }
        var result = predicate(root) ? [root] : []
        for child in children(root) {
            result += descendants(child, matching: predicate, depth: depth + 1, maximumDepth: maximumDepth)
        }
        return result
    }

    static func chatListResolution(in mainWindow: AXUIElement) -> ChatListResolution {
        // KakaoTalk's chat list is a direct table child of a direct scroll-area
        // child of the main window. Do not accept an arbitrary descendant table
        // from Contacts, search results, settings, or a transient panel.
        let candidates = children(mainWindow)
            .filter { role($0) == kAXScrollAreaRole as String }
            .flatMap(children)
            .filter { table in
                guard role(table) == kAXTableRole as String else { return false }
                let tableRows = rows(in: table)
                guard !tableRows.isEmpty else { return false }
                return tableRows.contains(where: isChatListRow)
            }
        guard candidates.count == 1 else { return .tableUnverified }

        let navigationControls = children(mainWindow).map { element in
            NavigationControlEvidence(
                role: role(element),
                identifier: identifier(element),
                title: title(element),
                description: description(element),
                selected: bool(element, kAXSelectedAttribute as String)
                    ?? bool(element, kAXValueAttribute as String),
                enabled: bool(element, kAXEnabledAttribute as String)
            )
        }
        guard SendUIValidator.isVerifiedChatList(
            navigationControls: navigationControls,
            tableCandidateCount: candidates.count
        ) else {
            return .navigationUnverified
        }
        return .verified(candidates[0])
    }

    static func chatList(in mainWindow: AXUIElement) -> AXUIElement? {
        chatListResolution(in: mainWindow).table
    }

    static func rows(in table: AXUIElement) -> [AXUIElement] {
        children(table).filter { role($0) == kAXRowRole as String }
    }

    static func exactName(in row: AXUIElement) -> String? {
        let labels = chatRowChromeElements(row).filter {
            role($0) == kAXStaticTextRole as String && identifier($0) == "_NS:40"
        }
        guard labels.count == 1 else { return nil }
        guard let name = value(labels[0]) ?? title(labels[0]),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return name
    }

    static func isSelfRow(_ row: AXUIElement) -> Bool {
        chatRowChromeElements(row).filter { element in
            role(element) == kAXImageRole as String
                && (description(element) ?? "").localizedCaseInsensitiveContains("badge me")
        }.count == 1
    }

    static func matchingRows(in table: AXUIElement, chat: Chat) -> [AXUIElement] {
        rows(in: table).filter { row in
            chat.isSelfChat
                ? isSelfRow(row)
                : exactName(in: row) == chat.displayName
        }
    }

    static func isVerifiedRoomWindow(_ room: AXUIElement) -> Bool {
        role(room) == kAXWindowRole as String
            && subrole(room) == kAXStandardWindowSubrole as String
            && identifier(room) == "_NS:441"
            && bool(room, kAXMinimizedAttribute as String) == false
    }

    static func composerCandidates(in room: AXUIElement) -> [AXUIElement] {
        guard isVerifiedRoomWindow(room) else { return [] }
        return descendants(room) { element in
            role(element) == kAXTextAreaRole as String
                && identifier(element) == "_NS:51"
                && isSettable(element, kAXValueAttribute as String)
        }
    }

    /// Current KakaoTalk clean composition chrome. The message-history table
    /// below `_NS:29` is intentionally variable; every composition-adjacent
    /// direct child and its fixed subtree is fail-closed. Extra reply, search,
    /// edit, attachment, or preview controls therefore prevent composition.
    static func isCleanCompositionRoom(
        _ room: AXUIElement,
        composer: AXUIElement
    ) -> Bool {
        guard isVerifiedRoomWindow(room) else { return false }
        let children = children(room)
        let identifiedDirectChildren = children.compactMap { child -> CompositionElementEvidence? in
            guard let role = role(child), let identifier = identifier(child) else { return nil }
            return CompositionElementEvidence(role: role, identifier: identifier)
        }
        let identifierlessButtons = children.filter {
            role($0) == kAXButtonRole as String && identifier($0) == nil
        }
        let anonymousNonButtons = children.filter {
            role($0) != kAXButtonRole as String && identifier($0) == nil
        }
        let anonymousLeaves = anonymousNonButtons.filter { self.children($0).isEmpty }
        let currentFixedIdentifiers = Set(["_NS:164", "_NS:144", "_NS:10", "_NS:54", "_NS:78"])
        let legacyFixedIdentifiers = Set(["_NS:164", "_NS:144", "_NS:10", "_NS:30", "_NS:42", "_NS:78"])
        let fixedLeavesAreEmpty = [currentFixedIdentifiers, legacyFixedIdentifiers].contains {
            identifiers in
            let matching = children.filter { child in
                identifier(child).map(identifiers.contains) == true
            }
            return matching.count == identifiers.count
                && matching.allSatisfy { self.children($0).isEmpty }
        }
        let sliders = children.filter { identifier($0) == "_NS:182" }
        let sliderChild = sliders.first.flatMap { self.children($0).only }
        let sliderIsClean = sliders.count == 1
            && sliderChild.map { role($0) == kAXValueIndicatorRole as String } == true
            && sliderChild.map { identifier($0) == nil } == true
            && sliderChild.map { self.children($0).isEmpty } == true
        let emptyButtons = identifierlessButtons.filter { self.children($0).isEmpty }
        let nestedButtons = identifierlessButtons.filter { !self.children($0).isEmpty }
        let firstGroup = nestedButtons.first.flatMap { self.children($0).only }
        let secondGroup = firstGroup.flatMap { self.children($0).only }
        let nestedButtonIsClean = nestedButtons.count == 1
            && firstGroup.map { role($0) == kAXGroupRole as String } == true
            && firstGroup.map { identifier($0) == nil } == true
            && secondGroup.map { role($0) == kAXGroupRole as String } == true
            && secondGroup.map { identifier($0) == nil } == true
            && secondGroup.map { self.children($0).isEmpty } == true
        let composerScrolls = children.filter {
            role($0) == kAXScrollAreaRole as String && identifier($0) == "_NS:47"
        }
        let composerChild = composerScrolls.first.flatMap { self.children($0).only }
        return CompositionWindowValidator.isClean(CompositionWindowEvidence(
            directChildCount: children.count,
            identifiedDirectChildren: identifiedDirectChildren,
            identifierlessButtonCount: identifierlessButtons.count,
            anonymousLeafRoles: anonymousLeaves.compactMap { role($0) },
            anonymousNonLeafCount: anonymousNonButtons.count - anonymousLeaves.count,
            fixedLeavesAreEmpty: fixedLeavesAreEmpty,
            sliderHasOneAnonymousLeafValueIndicator: sliderIsClean,
            emptyIdentifierlessButtonCount: emptyButtons.count,
            nestedIdentifierlessButtonCount: nestedButtons.count,
            nestedButtonHasTwoEmptyGroups: nestedButtonIsClean,
            composerScrollCount: composerScrolls.count,
            composerIsOnlyScrollChild: composerChild.map({ CFEqual($0, composer) }) == true,
            composerIsLeaf: self.children(composer).isEmpty
        ))
    }

    static func sameElementSet(_ lhs: [AXUIElement], _ rhs: [AXUIElement]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.allSatisfy { candidate in
            rhs.filter { CFEqual(candidate, $0) }.count == 1
        } && rhs.allSatisfy { candidate in
            lhs.filter { CFEqual(candidate, $0) }.count == 1
        }
    }

    private static func isChatListRow(_ row: AXUIElement) -> Bool {
        let elements = chatRowChromeElements(row)
        let names = elements.filter {
            guard role($0) == kAXStaticTextRole as String,
                  identifier($0) == "_NS:40",
                  let name = value($0) ?? title($0) else { return false }
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let profileControls = elements.filter {
            role($0) == kAXButtonRole as String && identifier($0) == "_NS:11"
        }
        let metadataLabels = elements.filter {
            role($0) == kAXStaticTextRole as String && identifier($0) == "_NS:69"
        }
        let messagePreviews = elements.filter { element in
            role(element) == kAXScrollAreaRole as String
                && identifier(element) == "_NS:87"
        }
        return SendUIValidator.isChatRowStructure(
            ChatRowStructureEvidence(
                nonemptyNameLabelCount: names.count,
                profileControlCount: profileControls.count,
                metadataLabelCount: metadataLabels.count,
                messagePreviewCount: messagePreviews.count
            )
        )
    }

    private static func chatRowChromeElements(
        _ root: AXUIElement,
        depth: Int = 0
    ) -> [AXUIElement] {
        guard depth <= 12 else { return [] }
        var result = [root]
        for child in children(root) {
            // `_NS:87` is the certified preview container. Its descendants
            // are message-dependent payload, not stable row chrome.
            if identifier(child) == "_NS:87" {
                result.append(child)
            } else {
                result += chatRowChromeElements(child, depth: depth + 1)
            }
        }
        return result
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
