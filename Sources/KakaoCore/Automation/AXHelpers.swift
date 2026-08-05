import AppKit
import ApplicationServices

/// Low-level helpers for macOS Accessibility API.
public enum AXHelpers {

    /// Get the AXUIElement for a running application by bundle identifier.
    public static func appElement(bundleId: String) throws -> AXUIElement {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            throw KakaoError.kakaoTalkNotInstalled
        }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    /// Activate (bring to front) an app by bundle identifier.
    public static func activateApp(bundleId: String) throws {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            throw KakaoError.kakaoTalkNotInstalled
        }
        app.activate()
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// Get a string attribute from an AXUIElement.
    public static func attribute(_ element: AXUIElement, _ attr: String) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    /// Get an integer attribute from an AXUIElement.
    public static func intAttribute(_ element: AXUIElement, _ attr: String) -> Int? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
        guard result == .success else { return nil }
        return value as? Int
    }

    /// Get a boolean attribute from an AXUIElement.
    public static func boolAttribute(_ element: AXUIElement, _ attr: String) -> Bool? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
        guard result == .success else { return nil }
        if let num = value as? NSNumber { return num.boolValue }
        return nil
    }

    /// Get children of an AXUIElement.
    public static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard result == .success, let children = value as? [AXUIElement] else { return [] }
        return children
    }

    /// Get all windows of an app element.
    /// Note: KakaoTalk may return AXApplication elements instead of AXWindow elements
    /// when the window is in certain states. We return whatever is in the list.
    public static func windows(_ appElement: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        if result == .success,
           let windows = value as? [AXUIElement],
           !windows.isEmpty {
            return windows
        }

        // KakaoTalk 26.x can expose its windows only as direct application
        // children while it is inactive. Keep this fallback exact: direct
        // AXWindow children only, never arbitrary descendants.
        return children(appElement).filter { role($0) == kAXWindowRole as String }
    }

    /// Get the role of an element.
    public static func role(_ element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute as String)
    }

    public static func subrole(_ element: AXUIElement) -> String? {
        attribute(element, kAXSubroleAttribute as String)
    }

    /// Get the title/description of an element.
    public static func title(_ element: AXUIElement) -> String? {
        attribute(element, kAXTitleAttribute as String)
    }

    /// Get the value of an element.
    public static func value(_ element: AXUIElement) -> String? {
        attribute(element, kAXValueAttribute as String)
    }

    /// Get the description of an element.
    public static func description(_ element: AXUIElement) -> String? {
        attribute(element, kAXDescriptionAttribute as String)
    }

    /// Get the role description of an element.
    public static func roleDescription(_ element: AXUIElement) -> String? {
        attribute(element, kAXRoleDescriptionAttribute as String)
    }

    /// Get the identifier of an element.
    public static func identifier(_ element: AXUIElement) -> String? {
        attribute(element, kAXIdentifierAttribute as String)
    }

    static func isVerifiedRoomWindow(_ room: AXUIElement) -> Bool {
        role(room) == kAXWindowRole as String
            && subrole(room) == kAXStandardWindowSubrole as String
            && identifier(room) == "_NS:441"
            && boolAttribute(room, kAXMinimizedAttribute as String) == false
    }

    static func composerCandidates(in room: AXUIElement) -> [AXUIElement] {
        guard isVerifiedRoomWindow(room) else { return [] }
        // The current composer is the sole direct child of the certified
        // direct `_NS:47` scroll area. Avoid recursively traversing message
        // history, which is both slow and irrelevant to composition identity.
        return children(room)
            .filter {
                role($0) == kAXScrollAreaRole as String && identifier($0) == "_NS:47"
            }
            .flatMap(children)
            .filter { element in
                role(element) == kAXTextAreaRole as String
                    && identifier(element) == "_NS:51"
                    && isAttributeSettable(element, kAXValueAttribute as String)
            }
    }

    static func isCleanCompositionRoom(_ room: AXUIElement, composer: AXUIElement) -> Bool {
        guard isVerifiedRoomWindow(room) else { return false }
        let directChildren = children(room)
        let identified = directChildren.compactMap { child -> CompositionElementEvidence? in
            guard let childRole = role(child), let childIdentifier = identifier(child) else {
                return nil
            }
            return CompositionElementEvidence(role: childRole, identifier: childIdentifier)
        }
        let identifierlessButtons = directChildren.filter {
            role($0) == kAXButtonRole as String && identifier($0) == nil
        }
        let anonymousNonButtons = directChildren.filter {
            role($0) != kAXButtonRole as String && identifier($0) == nil
        }
        let anonymousLeaves = anonymousNonButtons.filter { children($0).isEmpty }
        let fixedLeaves = directChildren.filter { child in
            guard let childIdentifier = identifier(child) else { return false }
            return ["_NS:164", "_NS:144", "_NS:10", "_NS:54", "_NS:78"]
                .contains(childIdentifier)
        }
        let sliders = directChildren.filter { identifier($0) == "_NS:182" }
        let sliderChildren = sliders.first.map(children) ?? []
        let sliderChild = sliderChildren.count == 1 ? sliderChildren[0] : nil
        let sliderIsClean = sliders.count == 1
            && sliderChild.map { role($0) == kAXValueIndicatorRole as String } == true
            && sliderChild.map { identifier($0) == nil } == true
            && sliderChild.map { children($0).isEmpty } == true
        let emptyButtons = identifierlessButtons.filter { children($0).isEmpty }
        let nestedButtons = identifierlessButtons.filter { !children($0).isEmpty }
        let firstChildren = nestedButtons.first.map(children) ?? []
        let firstGroup = firstChildren.count == 1 ? firstChildren[0] : nil
        let secondChildren = firstGroup.map(children) ?? []
        let secondGroup = secondChildren.count == 1 ? secondChildren[0] : nil
        let nestedButtonIsClean = nestedButtons.count == 1
            && firstGroup.map { role($0) == kAXGroupRole as String } == true
            && firstGroup.map { identifier($0) == nil } == true
            && secondGroup.map { role($0) == kAXGroupRole as String } == true
            && secondGroup.map { identifier($0) == nil } == true
            && secondGroup.map { children($0).isEmpty } == true
        let composerScrolls = directChildren.filter {
            role($0) == kAXScrollAreaRole as String && identifier($0) == "_NS:47"
        }
        let composerChildren = composerScrolls.first.map(children) ?? []
        let composerChild = composerChildren.count == 1 ? composerChildren[0] : nil
        return BackgroundSendSelector.isCleanCompositionWindow(
            CompositionWindowEvidence(
                directChildCount: directChildren.count,
                identifiedDirectChildren: identified,
                identifierlessButtonCount: identifierlessButtons.count,
                anonymousLeafRoles: anonymousLeaves.compactMap(role),
                anonymousNonLeafCount: anonymousNonButtons.count - anonymousLeaves.count,
                fixedLeavesAreEmpty: fixedLeaves.count == 5
                    && fixedLeaves.allSatisfy { children($0).isEmpty },
                sliderHasOneAnonymousLeafValueIndicator: sliderIsClean,
                emptyIdentifierlessButtonCount: emptyButtons.count,
                nestedIdentifierlessButtonCount: nestedButtons.count,
                nestedButtonHasTwoEmptyGroups: nestedButtonIsClean,
                composerScrollCount: composerScrolls.count,
                composerIsOnlyScrollChild: composerChild.map { CFEqual($0, composer) } == true,
                composerIsLeaf: children(composer).isEmpty
            )
        )
    }

    static func sameElementSet(_ lhs: [AXUIElement], _ rhs: [AXUIElement]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.allSatisfy { candidate in
            rhs.filter { CFEqual(candidate, $0) }.count == 1
        } && rhs.allSatisfy { candidate in
            lhs.filter { CFEqual(candidate, $0) }.count == 1
        }
    }

    static func hasContainedFrame(_ element: AXUIElement, in container: AXUIElement) -> Bool {
        guard let elementPosition = position(element), let elementSize = size(element),
              let containerPosition = position(container), let containerSize = size(container),
              elementSize.width > 0, elementSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else { return false }
        let elementFrame = CGRect(origin: elementPosition, size: elementSize)
        let containerFrame = CGRect(origin: containerPosition, size: containerSize)
        return containerFrame.contains(elementFrame)
    }

    /// Set the value of an element.
    public static func setValue(_ element: AXUIElement, _ value: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef) == .success
    }

    /// Perform an action (e.g., press, confirm).
    public static func performAction(_ element: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }

    /// Return the actions exposed by an accessibility element.
    public static func actionNames(_ element: AXUIElement) -> [String] {
        var value: CFArray?
        let result = AXUIElementCopyActionNames(element, &value)
        guard result == .success else { return [] }
        return value as? [String] ?? []
    }

    /// Check whether an accessibility attribute can be changed.
    public static func isAttributeSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(
            element,
            attribute as CFString,
            &settable
        )
        return result == .success && settable.boolValue
    }

    /// Set focus on an element.
    public static func focus(_ element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef) == .success
    }

    /// Close a window via its close button.
    public static func closeWindow(_ window: AXUIElement) -> Bool {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &value)
        guard result == .success, let closeButton = value else { return false }
        return AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString) == .success
    }

    /// Dump the UI tree recursively for inspection.
    public static func dumpTree(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 6) -> String {
        guard depth <= maxDepth else { return "" }
        let indent = String(repeating: "  ", count: depth)
        let r = role(element) ?? "?"
        let t = title(element)
        let v = value(element)
        let d = description(element)
        let id = identifier(element)

        var line = "\(indent)[\(r)]"
        if let t { line += " title=\"\(t.prefix(60))\"" }
        if let v, !v.isEmpty { line += " value=\"\(v.prefix(60))\"" }
        if let d, !d.isEmpty { line += " desc=\"\(d.prefix(60))\"" }
        if let id, !id.isEmpty { line += " id=\"\(id)\"" }
        line += "\n"

        for child in children(element) {
            line += dumpTree(child, depth: depth + 1, maxDepth: maxDepth)
        }
        return line
    }

    /// Find all elements matching a role, searching recursively.
    public static func findAll(_ element: AXUIElement, role targetRole: String, maxDepth: Int = 10, currentDepth: Int = 0) -> [AXUIElement] {
        guard currentDepth <= maxDepth else { return [] }
        var results: [AXUIElement] = []
        if role(element) == targetRole {
            results.append(element)
        }
        for child in children(element) {
            results += findAll(child, role: targetRole, maxDepth: maxDepth, currentDepth: currentDepth + 1)
        }
        return results
    }

    /// Find the first element matching a role and containing text.
    public static func findFirst(_ element: AXUIElement, role targetRole: String, text: String, maxDepth: Int = 10, currentDepth: Int = 0) -> AXUIElement? {
        guard currentDepth <= maxDepth else { return nil }
        if role(element) == targetRole {
            let t = title(element) ?? value(element) ?? ""
            if t.localizedCaseInsensitiveContains(text) {
                return element
            }
        }
        for child in children(element) {
            if let found = findFirst(child, role: targetRole, text: text, maxDepth: maxDepth, currentDepth: currentDepth + 1) {
                return found
            }
        }
        return nil
    }

    /// Find the first element matching a role and identifier.
    public static func findFirst(_ element: AXUIElement, role targetRole: String, identifier targetId: String, maxDepth: Int = 10, currentDepth: Int = 0) -> AXUIElement? {
        guard currentDepth <= maxDepth else { return nil }
        if role(element) == targetRole {
            if identifier(element) == targetId {
                return element
            }
        }
        for child in children(element) {
            if let found = findFirst(child, role: targetRole, identifier: targetId, maxDepth: maxDepth, currentDepth: currentDepth + 1) {
                return found
            }
        }
        return nil
    }

    /// Find the AXRow in a chat list whose name label matches the given text.
    /// KakaoTalk chat-list labels use a small known identifier set across
    /// releases. Unknown static text is never treated as destination identity.
    public static func findChatRow(_ table: AXUIElement, chatName: String, exact: Bool = false) -> AXUIElement? {
        for row in children(table) {
            guard role(row) == "AXRow" else { continue }
            guard let name = exactRowName(row) else { continue }
            let matches = exact
                ? name == chatName
                : name.localizedCaseInsensitiveContains(chatName)
            if matches {
                return row
            }
        }
        return nil
    }

    /// Find the self-chat row (identified by "badge me" image in the cell).
    public static func findSelfChatRow(_ table: AXUIElement) -> AXUIElement? {
        for row in children(table) {
            guard role(row) == "AXRow" else { continue }
            for cell in children(row) {
                guard role(cell) == "AXCell" else { continue }
                for child in children(cell) {
                    if role(child) == "AXImage" {
                        let desc = description(child) ?? ""
                        if desc.contains("badge me") {
                            return row
                        }
                    }
                }
            }
        }
        return nil
    }

    public static func exactChatRows(_ table: AXUIElement, name: String) -> [AXUIElement] {
        let rows = visibleChatRows(in: table)
        let currentRows = rows.compactMap { row -> (AXUIElement, [AXUIElement])? in
            let chrome = currentChatRowChrome(row)
            return BackgroundSendSelector.isCurrentChatRowStructure(
                currentChatRowStructure(from: chrome)
            ) ? (row, chrome) : nil
        }
        if !currentRows.isEmpty {
            return currentRows.compactMap { row, chrome in
                let labels = chrome.filter {
                    role($0) == kAXStaticTextRole as String && identifier($0) == "_NS:40"
                }
                guard labels.count == 1,
                      (value(labels[0]) ?? title(labels[0])) == name else { return nil }
                return row
            }
        }
        return rows.filter { row in
            exactRowName(row) == name
        }
    }

    public static func selfChatRows(_ table: AXUIElement) -> [AXUIElement] {
        visibleChatRows(in: table).filter { row in
            // Stop at `_NS:87`: its message-preview payload may contain a
            // large attachment tree and is not stable row identity chrome.
            return chatRowIdentityChrome(row).filter {
                role($0) == kAXImageRole as String
                    && identifier($0) == "_NS:18"
                    && (description($0) ?? "").localizedCaseInsensitiveContains("badge me")
            }.count == 1
        }
    }

    /// Sending is permitted only to a currently visible row. KakaoTalk can
    /// expose hundreds of virtualized rows; querying every row while the app
    /// is inactive multiplies AX timeouts and can stall for tens of seconds.
    private static func visibleChatRows(in table: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            table,
            kAXVisibleRowsAttribute as CFString,
            &value
        ) == .success,
        let rows = value as? [AXUIElement],
        !rows.isEmpty,
        rows.count <= 64 else { return [] }
        return rows.filter { role($0) == kAXRowRole as String }
    }

    public static func exactRowName(_ row: AXUIElement) -> String? {
        let chrome = currentChatRowChrome(row)
        let currentLabels = chrome.filter {
            role($0) == kAXStaticTextRole as String && identifier($0) == "_NS:40"
        }
        if BackgroundSendSelector.isCurrentChatRowStructure(
            currentChatRowStructure(from: chrome)
        ), currentLabels.count == 1 {
            guard let name = value(currentLabels[0]) ?? title(currentLabels[0]),
                  !name.isEmpty else { return nil }
            return name
        }

        // Legacy layout proof stays deliberately structural rather than
        // accepting an arbitrary recursive static-text match.
        let legacyLabels = children(row)
            .filter { role($0) == kAXCellRole as String }
            .flatMap(children)
            .filter {
                role($0) == kAXStaticTextRole as String && identifier($0) == "_NS:18"
            }
        guard legacyLabels.count == 1,
              let name = value(legacyLabels[0]) ?? title(legacyLabels[0]),
              !name.isEmpty else { return nil }
        return name
    }

    /// KakaoTalk 26.x exposes destination identity as direct children of one
    /// row cell. Prefer this bounded shape in the send path so a long chat
    /// list cannot multiply AX timeouts through recursive preview traversal.
    private static func currentChatRowChrome(_ row: AXUIElement) -> [AXUIElement] {
        let cells = children(row).filter { role($0) == kAXCellRole as String }
        guard cells.count == 1 else { return [] }
        return children(cells[0])
    }

    private static func chatRowIdentityChrome(_ row: AXUIElement) -> [AXUIElement] {
        func collect(_ element: AXUIElement) -> [AXUIElement] {
            children(element).flatMap { child -> [AXUIElement] in
                // Message previews contain dynamic payload and are never part
                // of the destination identity proof.
                if identifier(child) == "_NS:87" { return [child] }
                return [child] + collect(child)
            }
        }
        return collect(row)
    }

    private static func currentChatRowStructure(
        from chrome: [AXUIElement]
    ) -> ChatRowStructureEvidence {
        ChatRowStructureEvidence(
            nameLabelCount: chrome.filter {
                role($0) == kAXStaticTextRole as String && identifier($0) == "_NS:40"
            }.count,
            profileButtonCount: chrome.filter {
                role($0) == kAXButtonRole as String && identifier($0) == "_NS:11"
            }.count,
            metadataLabelCount: chrome.filter {
                role($0) == kAXStaticTextRole as String && identifier($0) == "_NS:69"
            }.count,
            previewContainerCount: chrome.filter {
                role($0) == kAXScrollAreaRole as String && identifier($0) == "_NS:87"
            }.count
        )
    }

    /// Return KakaoTalk's chat-list table only when the selected Chats
    /// navigation control and the direct window/scroll-area/table structure
    /// are both unique. This is deliberately stricter than `chatListTable`,
    /// which remains available to legacy non-send workflows.
    public static func verifiedSendChatListTable(_ window: AXUIElement) -> AXUIElement? {
        let candidates = children(window)
            .filter { role($0) == "AXScrollArea" }
            .flatMap(children)
            .filter { table in
                guard role(table) == "AXTable" else { return false }
                let rows = children(table).filter { role($0) == "AXRow" }
                guard !rows.isEmpty else { return false }
                return rows.contains { exactRowName($0) != nil }
                    || !selfChatRows(table).isEmpty
            }

        let navigationControls = children(window)
            .filter {
                let elementRole = role($0)
                return elementRole == kAXCheckBoxRole as String
                    || elementRole == kAXButtonRole as String
                    || elementRole == kAXRadioButtonRole as String
            }
            .map { element in
                NavigationControlEvidence(
                    role: role(element),
                    identifier: identifier(element),
                    title: title(element),
                    description: description(element),
                    selected: boolAttribute(element, kAXSelectedAttribute as String)
                        ?? boolAttribute(element, kAXValueAttribute as String),
                    enabled: boolAttribute(element, kAXEnabledAttribute as String)
                )
            }
        guard BackgroundSendSelector.isVerifiedChatList(
            navigationControls: navigationControls,
            tableCandidateCount: candidates.count,
            statelessCandidateHasCurrentChatRowSchema: candidates.count == 1
                && children(candidates[0]).contains { row in
                    guard role(row) == kAXRowRole as String else { return false }
                    return BackgroundSendSelector.isCurrentChatRowStructure(
                        currentChatRowStructure(from: currentChatRowChrome(row))
                    )
                }
        ) else { return nil }
        return candidates[0]
    }

    /// Scroll a table row into the visible area of its parent scroll area.
    /// Returns true if the row is now visible (or was already visible).
    public static func scrollRowToVisible(_ row: AXUIElement, in scrollArea: AXUIElement) -> Bool {
        guard let rowPos = position(row), let rowSize = size(row),
              let areaPos = position(scrollArea), let areaSize = size(scrollArea) else {
            return false
        }

        let areaTop = areaPos.y
        let areaBottom = areaPos.y + areaSize.height
        let rowTop = rowPos.y
        let rowBottom = rowPos.y + rowSize.height

        // Already visible
        if rowTop >= areaTop && rowBottom <= areaBottom {
            return true
        }

        // Scroll using CGEvent wheel events on the scroll area center
        let scrollCenter = CGPoint(x: areaPos.x + areaSize.width / 2,
                                    y: areaPos.y + areaSize.height / 2)
        let maxAttempts = 80
        for _ in 0..<maxAttempts {
            let curPos = position(row)
            guard let curY = curPos?.y, let curH = size(row)?.height else { break }

            if curY >= areaTop && (curY + curH) <= areaBottom {
                return true // Row is now visible
            }

            // Scroll down if row is below visible area, up if above
            let deltaY: Int32 = curY > areaBottom ? -3 : 3
            scrollLines(deltaY: deltaY, at: scrollCenter)
            usleep(50000) // 50ms between scrolls
        }

        // Check one more time
        if let finalPos = position(row), let finalSize = size(row) {
            return finalPos.y >= areaTop && (finalPos.y + finalSize.height) <= areaBottom
        }
        return false
    }

    /// Get the AXTable (chat list) from the main window.
    public static func chatListTable(_ window: AXUIElement) -> AXUIElement? {
        // Structure: AXWindow > AXScrollArea > AXTable
        for child in children(window) {
            if role(child) == "AXScrollArea" {
                for subchild in children(child) {
                    if role(subchild) == "AXTable" {
                        return subchild
                    }
                }
            }
        }
        return nil
    }

    /// Get the AXScrollArea containing the chat list table from the main window.
    public static func chatListScrollArea(_ window: AXUIElement) -> AXUIElement? {
        for child in children(window) {
            if role(child) == "AXScrollArea" {
                for subchild in children(child) {
                    if role(subchild) == "AXTable" {
                        return child
                    }
                }
            }
        }
        return nil
    }

    /// Select a row in a table via AX API.
    public static func selectRow(_ row: AXUIElement, in table: AXUIElement) -> Bool {
        let result = AXUIElementSetAttributeValue(
            table,
            kAXSelectedRowsAttribute as CFString,
            [row] as CFTypeRef
        )
        guard result == .success else { return false }
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            table,
            kAXSelectedRowsAttribute as CFString,
            &value
        ) == .success,
        let rows = value as? [AXUIElement], rows.count == 1 else { return false }
        return CFEqual(rows[0], row)
    }

    public static func isExactlySelected(_ row: AXUIElement, in table: AXUIElement) -> Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            table,
            kAXSelectedRowsAttribute as CFString,
            &value
        ) == .success,
        let rows = value as? [AXUIElement], rows.count == 1 else { return false }
        return CFEqual(rows[0], row)
    }

    public static func isFocused(_ element: AXUIElement) -> Bool {
        boolAttribute(element, kAXFocusedAttribute as String) == true
    }

    /// Get the parent of an AXUIElement.
    public static func parent(_ element: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value)
        guard result == .success else { return nil }
        return (value as! AXUIElement)
    }

    /// Get the position (frame origin) of an element.
    public static func position(_ element: AXUIElement) -> CGPoint? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value)
        guard result == .success, let axValue = value else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(axValue as! AXValue, .cgPoint, &point)
        return point
    }

    /// Get the size of an element.
    public static func size(_ element: AXUIElement) -> CGSize? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)
        guard result == .success, let axValue = value else { return nil }
        var size = CGSize.zero
        AXValueGetValue(axValue as! AXValue, .cgSize, &size)
        return size
    }

    /// Click at the center of an element using CGEvent.
    public static func clickElement(_ element: AXUIElement) {
        guard let pos = position(element), let sz = size(element) else { return }
        let center = CGPoint(x: pos.x + sz.width / 2, y: pos.y + sz.height / 2)
        if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left),
           let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left) {
            mouseDown.post(tap: .cghidEventTap)
            usleep(50000)
            mouseUp.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Mouse Movement & Scroll

    /// Move the mouse cursor to a screen position.
    public static func moveMouse(to point: CGPoint) {
        if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                               mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    /// Send a scroll wheel event (pixel units). Negative deltaY = scroll up, positive = scroll down.
    public static func scroll(deltaY: Int32, at point: CGPoint? = nil) {
        if let point {
            moveMouse(to: point)
            usleep(50000) // 50ms settle
        }
        if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0) {
            event.post(tap: .cghidEventTap)
        }
    }

    /// Send a scroll wheel event (line units). Negative deltaY = scroll down, positive = scroll up.
    public static func scrollLines(deltaY: Int32, at point: CGPoint? = nil) {
        if let point {
            moveMouse(to: point)
            usleep(50000) // 50ms settle
        }
        if let event = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                               wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0) {
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Keyboard Helpers

    /// Type text using CGEvent (handles Unicode correctly).
    public static func typeText(_ text: String) {
        for char in text {
            let utf16 = Array(char.utf16)
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                usleep(5000) // 5ms between keystrokes
            }
        }
    }

    /// Press a key using CGEvent.
    public static func pressKey(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
           let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
            down.flags = flags
            up.flags = flags
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// Select all text (Cmd+A).
    public static func selectAll() {
        pressKey(keyCode: 0, flags: .maskCommand)
        Thread.sleep(forTimeInterval: 0.05)
    }

    /// Double-click at the center of an element using CGEvent.
    public static func doubleClickElement(_ element: AXUIElement) {
        guard let pos = position(element), let sz = size(element) else { return }
        let center = CGPoint(x: pos.x + sz.width / 2, y: pos.y + sz.height / 2)
        for _ in 0..<2 {
            if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left),
               let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left) {
                mouseDown.setIntegerValueField(.mouseEventClickState, value: 2)
                mouseUp.setIntegerValueField(.mouseEventClickState, value: 2)
                mouseDown.post(tap: .cghidEventTap)
                usleep(20000)
                mouseUp.post(tap: .cghidEventTap)
                usleep(20000)
            }
        }
    }
}
