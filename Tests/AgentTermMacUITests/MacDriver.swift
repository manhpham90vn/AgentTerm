import AppKit
import ApplicationServices
import Foundation
import XCTest

/// One element of the Mac app's window as accessibility describes it.
struct Node {
    let element: AXUIElement
    let role: String
    let identifier: String
    let title: String
    let label: String
    let value: String
    let help: String
    let enabled: Bool
    let depth: Int

    /// Everything a person, or VoiceOver, would know it by.
    var text: String { [title, label, value].filter { !$0.isEmpty }.joined(separator: " | ") }
    var summary: String { "\(role) id=\(identifier) title=\(title) label=\(label) value=\(value.prefix(60))" }
}

/// Starts the Mac app against a host of its own and drives it the way
/// VoiceOver would: by pressing and reading its accessibility elements. No
/// pointer is moved and no key is sent, so a run leaves the desktop alone.
final class MacDriver {
    /// Nil for an app that something else started and will stop.
    let process: Process?
    let pid: pid_t
    private let app: AXUIElement

    /// An app that is already running.
    init(pid: pid_t) {
        process = nil
        self.pid = pid
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 5)
    }

    /// Whether this process may use accessibility at all.
    static var isAllowed: Bool { AXIsProcessTrusted() }

    init(executable: URL, environment: [String: String]) throws {
        let process = Process()
        process.executableURL = executable
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        pid = process.processIdentifier
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 5)
    }

    /// Closes the app's window with that title, as its close button does.
    func closeWindow(titled title: String, file: StaticString = #filePath, line: UInt = #line) {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        let windows = value as? [AXUIElement] ?? []
        for window in windows {
            var name: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &name)
            guard name as? String == title else { continue }
            var button: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button)
            guard let button, CFGetTypeID(button) == AXUIElementGetTypeID() else { break }
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            return
        }
        XCTFail("no window titled \(title) to close", file: file, line: line)
    }

    func quit() {
        guard let process, process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    // MARK: Reading

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String {
        guard let value = attribute(element, name) else { return "" }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    /// Every element of the app's windows, in the order they are laid out.
    /// The menu bar is left out unless asked for: it is large and rarely wanted.
    func nodes(menus: Bool = false) -> [Node] {
        var found: [Node] = []
        func walk(_ element: AXUIElement, _ depth: Int) {
            let role = Self.string(element, kAXRoleAttribute)
            if !menus, role == kAXMenuBarRole { return }
            found.append(
                Node(
                    element: element, role: role, identifier: Self.string(element, kAXIdentifierAttribute),
                    title: Self.string(element, kAXTitleAttribute), label: Self.string(element, kAXDescriptionAttribute),
                    value: Self.string(element, kAXValueAttribute), help: Self.string(element, kAXHelpAttribute),
                    enabled: (Self.attribute(element, kAXEnabledAttribute) as? Bool) ?? true, depth: depth))
            guard depth < 40, let children = Self.attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
            for child in children { walk(child, depth + 1) }
        }
        walk(app, 0)
        return found
    }

    /// A way to pick an element: by identifier, or by what it says.
    enum Query: CustomStringConvertible {
        case id(String)
        /// An identifier that ends like this: for one that holds a path,
        /// which the same folder has more than one of.
        case idEnding(String)
        /// A button, of whatever kind, that says exactly this.
        case button(String)
        /// Anything whose title, label or value is exactly this.
        case text(String)
        /// Anything whose title, label or value contains this.
        case containing(String)
        case role(String)

        var description: String {
            switch self {
            case .id(let id): return "id \(id)"
            case .idEnding(let end): return "id ending in \(end)"
            case .button(let name): return "button \"\(name)\""
            case .text(let text): return "\"\(text)\""
            case .containing(let text): return "something with \"\(text)\""
            case .role(let role): return "a \(role)"
            }
        }

        func matches(_ node: Node) -> Bool {
            switch self {
            case .id(let id): return node.identifier == id
            case .idEnding(let end): return node.identifier.hasSuffix(end)
            case .button(let name):
                return [kAXButtonRole, kAXMenuButtonRole, kAXPopUpButtonRole, kAXMenuItemRole, kAXCheckBoxRole, kAXRadioButtonRole].contains(node.role)
                    && (node.title == name || node.label == name)
            case .text(let text): return node.title == text || node.label == text || node.value == text
            case .containing(let text): return node.title.contains(text) || node.label.contains(text) || node.value.contains(text)
            case .role(let role): return node.role == role
            }
        }
    }

    func all(_ query: Query, menus: Bool = false) -> [Node] { nodes(menus: menus).filter(query.matches) }
    func first(_ query: Query, menus: Bool = false) -> Node? { nodes(menus: menus).first(where: query.matches) }
    func exists(_ query: Query) -> Bool { first(query) != nil }

    /// Waits for something to be on screen, as a person would.
    @discardableResult
    func wait(for query: Query, timeout: TimeInterval = 10, menus: Bool = false, file: StaticString = #filePath, line: UInt = #line) -> Node? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let node = first(query, menus: menus) { return node }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        XCTFail("\(query) did not appear. On screen:\n\(screen())", file: file, line: line)
        return nil
    }

    /// Waits for something to hold.
    func wait(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        XCTFail("timed out waiting for: \(what). On screen:\n\(screen())", file: file, line: line)
    }

    func waitGone(_ query: Query, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        wait("\(query) to go away", timeout: timeout, file: file, line: line) { !self.exists(query) }
    }

    /// What is on screen, one element a line, for a failure's message.
    func screen() -> String {
        nodes().filter { !$0.text.isEmpty || !$0.identifier.isEmpty }.map { String(repeating: " ", count: min($0.depth, 10)) + $0.summary }
            .joined(separator: "\n")
    }

    // MARK: Acting

    /// Presses a button, a row, a tab: whatever says it can be pressed.
    func press(_ query: Query, menus: Bool = false, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        guard wait(for: query, timeout: timeout, menus: menus, file: file, line: line) != nil else { return }
        // A button that is there may not be ready yet: a sheet's, until
        // what it needs has loaded.
        wait("\(query) to be enabled", timeout: timeout, file: file, line: line) { self.first(query, menus: menus)?.enabled ?? false }
        guard let node = first(query, menus: menus) else { return }
        let result = AXUIElementPerformAction(node.element, kAXPressAction as CFString)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        // A button that closes what it is in, a sheet's, is gone before the
        // press is answered, and the press is then reported as failed.
        if result != .success, first(query, menus: menus) != nil {
            XCTFail("\(query) could not be pressed (\(result.rawValue))", file: file, line: line)
        }
    }

    /// Does one of an element's own named actions, as VoiceOver's actions
    /// menu would: "Resume" on a conversation, say.
    func perform(_ action: String, on query: Query, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        guard let node = wait(for: query, timeout: timeout, file: file, line: line) else { return }
        var names: CFArray?
        AXUIElementCopyActionNames(node.element, &names)
        let all = (names as? [String]) ?? []
        guard let name = all.first(where: { $0 == action || $0.contains("Name:\(action)\n") }) else {
            XCTFail("\(query) has no action \(action); it has \(all)", file: file, line: line)
            return
        }
        XCTAssertEqual(AXUIElementPerformAction(node.element, name as CFString), .success, file: file, line: line)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    /// Picks an item of the app's menu bar, such as ["File", "New Shell"].
    func menu(_ path: [String], file: StaticString = #filePath, line: UInt = #line) {
        var current = nodes(menus: true).first { $0.role == kAXMenuBarRole }?.element
        for name in path {
            guard let parent = current else { break }
            var next: AXUIElement?
            func search(_ element: AXUIElement, _ depth: Int) {
                guard next == nil, depth < 4, let children = Self.attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
                for child in children where next == nil {
                    if Self.string(child, kAXTitleAttribute) == name { next = child } else { search(child, depth + 1) }
                }
            }
            search(parent, 0)
            current = next
        }
        guard let item = current else {
            XCTFail("no menu item \(path.joined(separator: " > "))", file: file, line: line)
            return
        }
        XCTAssertEqual(AXUIElementPerformAction(item, kAXPressAction as CFString), .success, file: file, line: line)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    /// Writes into a text field or an editor, as typing would leave it.
    func write(_ text: String, into query: Query, confirm: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        guard let node = wait(for: query, file: file, line: line) else { return }
        AXUIElementSetAttributeValue(node.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let result = AXUIElementSetAttributeValue(node.element, kAXValueAttribute as CFString, text as CFString)
        XCTAssertEqual(result, .success, "could not write into \(query)", file: file, line: line)
        if confirm { AXUIElementPerformAction(node.element, kAXConfirmAction as CFString) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    func value(of query: Query) -> String? { first(query)?.value }

    /// A picture of the app's window, for a failure that words do not explain.
    func capture(to url: URL) {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        guard
            let id = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && (($0[kCGWindowLayer as String] as? Int) ?? 1) == 0 })?[
                kCGWindowNumber as String] as? Int
        else { return }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(id), url.path]
        try? capture.run()
        capture.waitUntilExit()
    }
}
