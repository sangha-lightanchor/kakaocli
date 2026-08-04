import ApplicationServices
import Foundation

/// Accessibility helpers intentionally limited to element inspection, direct
/// attribute mutation, and actions on already-rendered KakaoTalk controls.
/// There is no app activation, window raise, cursor movement, or global input.
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
        if !declared.isEmpty { return declared }

        // Current KakaoTalk can return an empty AXWindows array while inactive
        // even though its rendered windows remain direct application children.
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
        let labels = descendants(row) {
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
        descendants(row) { element in
            role(element) == kAXImageRole as String
                && (description(element) ?? "").localizedCaseInsensitiveContains("badge me")
        }.count == 1
    }

    private static func isChatListRow(_ row: AXUIElement) -> Bool {
        let elements = descendants(row, matching: { _ in true })
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
            guard role(element) == kAXScrollAreaRole as String,
                  identifier(element) == "_NS:87" else { return false }
            let textAreas = descendants(element) {
                role($0) == kAXTextAreaRole as String && identifier($0) == "_NS:91"
            }
            return textAreas.count == 1
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
}
