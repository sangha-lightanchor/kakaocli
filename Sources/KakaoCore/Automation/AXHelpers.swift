import ApplicationServices
import Foundation

/// Accessibility helpers intentionally limited to element inspection, direct
/// attribute mutation, and actions on already-rendered KakaoTalk controls.
/// There is no app activation, window raise, cursor movement, or global input.
enum AXHelpers {
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
        attribute(app, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
    }

    static func role(_ element: AXUIElement) -> String? { string(element, kAXRoleAttribute as String) }
    static func title(_ element: AXUIElement) -> String? { string(element, kAXTitleAttribute as String) }
    static func value(_ element: AXUIElement) -> String? { string(element, kAXValueAttribute as String) }
    static func identifier(_ element: AXUIElement) -> String? { string(element, kAXIdentifierAttribute as String) }
    static func description(_ element: AXUIElement) -> String? { string(element, kAXDescriptionAttribute as String) }

    static func setValue(_ element: AXUIElement, _ value: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef) == .success
    }

    static func focus(_ element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef) == .success
    }

    static func isFocused(_ element: AXUIElement) -> Bool {
        bool(element, kAXFocusedAttribute as String) == true
    }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success
            && settable.boolValue
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

    static func chatList(in mainWindow: AXUIElement) -> AXUIElement? {
        guard hasSelectedChatsNavigation(in: mainWindow) else { return nil }

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
                return tableRows.contains { exactName(in: $0) != nil || isSelfRow($0) }
            }
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }

    static func rows(in table: AXUIElement) -> [AXUIElement] {
        children(table).filter { role($0) == kAXRowRole as String }
    }

    static func exactName(in row: AXUIElement) -> String? {
        let labels = descendants(row) {
            role($0) == kAXStaticTextRole as String && identifier($0) == "_NS:18"
        }
        guard labels.count == 1 else { return nil }
        return value(labels[0]) ?? title(labels[0])
    }

    static func isSelfRow(_ row: AXUIElement) -> Bool {
        descendants(row) { element in
            role(element) == kAXImageRole as String
                && (description(element) ?? "").localizedCaseInsensitiveContains("badge me")
        }.count == 1
    }

    static func selectExactly(_ row: AXUIElement, in table: AXUIElement) -> Bool {
        guard AXUIElementSetAttributeValue(
            table,
            kAXSelectedRowsAttribute as CFString,
            [row] as CFTypeRef
        ) == .success,
        let selected = attribute(table, kAXSelectedRowsAttribute as String) as? [AXUIElement],
        selected.count == 1 else { return false }
        return CFEqual(selected[0], row)
    }

    static func isExactlySelected(_ row: AXUIElement, in table: AXUIElement) -> Bool {
        guard let selected = attribute(table, kAXSelectedRowsAttribute as String) as? [AXUIElement],
              selected.count == 1 else { return false }
        return CFEqual(selected[0], row)
    }

    private static func hasSelectedChatsNavigation(in mainWindow: AXUIElement) -> Bool {
        let matches = descendants(mainWindow) { element in
            SendUIValidator.isSelectedChatsNavigation(
                NavigationControlEvidence(
                    role: role(element),
                    identifier: identifier(element),
                    title: title(element),
                    description: description(element),
                    selected: bool(element, kAXSelectedAttribute as String) == true
                        || bool(element, kAXValueAttribute as String) == true
                )
            )
        }
        return matches.count == 1
    }
}
