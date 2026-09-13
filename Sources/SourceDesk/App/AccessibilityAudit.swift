import AppKit
import ApplicationServices
import SwiftUI
import SourceDeskCore

/// Dumps the accessibility tree of the real app window.
///
/// Why this exists: an icon-only control is invisible to VoiceOver unless it carries a
/// label, and `.help()` — the SwiftUI tooltip — is *not* an accessibility label. Source
/// review cannot tell the difference between "has a tooltip" and "is announced", so the only
/// honest check is to build the real view and ask AppKit what it exposes.
///
/// Run with `SourceDesk --audit-accessibility`. Exits non-zero if any interactive element
/// has no accessible name, so it can gate a release.
enum AccessibilityAudit {

    @MainActor
    static func runAndExit(arguments: [String]) {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("a11y-\(UUID().uuidString)", isDirectory: true))
        let state = AppState(paths: paths)
        state.start()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_360, height: 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: RootView()
            .environment(state)
            .environment(ChatViewModel(app: state))
            .environment(StudyToolsViewModel(app: state))
            .environment(SearchPanelViewModel(app: state)))
        window.orderFrontRegardless()

        // SwiftUI builds its accessibility tree after the first layout pass, so a short
        // wait is required before any of this is populated.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let result = walk(window.contentView)
            report(result)
            reportViaAXAPI()
            let unnamed = lastUnnamedCount
            try? FileManager.default.removeItem(at: paths.root)
            // Only app-owned controls count: an unannounced button here means a VoiceOver
            // user cannot tell what it does.
            exit(unnamed == 0 ? 0 : 1)
        }
    }

    struct Result {
        var labelled: [(role: String, name: String)] = []
        /// Interactive elements with no accessible name at all.
        var unlabelled: [String] = []
    }

    private static let interactiveRoles: Set<NSAccessibility.Role> = [
        .button, .checkBox, .radioButton, .popUpButton, .menuButton,
        .textField, .slider, .comboBox
    ]

    @MainActor
    private static func walk(_ element: Any?) -> Result {
        var result = Result()
        walk(element, into: &result)
        return result
    }

    /// Counts every node visited, so an empty result can be told apart from a walk that
    /// never ran.
    nonisolated(unsafe) private static var visited = 0

    @MainActor
    private static func walk(_ element: Any?, into result: inout Result) {
        guard let element else { return }
        visited += 1
        let obj = element as AnyObject
        guard let role = obj.accessibilityRole?() else { return }

        if interactiveRoles.contains(role) {
            // The name VoiceOver actually speaks. Only label and title are consulted:
            // `accessibilityValue()` is ambiguous on `AnyObject` (AppKit declares it on
            // several protocols), and a value is not a name anyway.
            let candidates = [
                obj.accessibilityLabel?() ?? "",
                obj.accessibilityTitle?() ?? ""
            ]
            let name = candidates.first {
                !$0.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty
            } ?? ""
            if name.isEmpty {
                let help = obj.accessibilityHelp?() ?? ""
                let hint = help.isEmpty ? "" : " (has tooltip but no label: \"\(help)\")"
                result.unlabelled.append("\(role.rawValue)\(hint)")
            } else {
                result.labelled.append((role.rawValue, name))
            }
        }

        for child in obj.accessibilityChildren?() ?? [] {
            walk(child, into: &result)
        }
    }

    private static func report(_ result: Result) {
        print("nodes visited: \(visited)")
        print("=== ACCESSIBLE INTERACTIVE ELEMENTS (\(result.labelled.count)) ===")
        for item in result.labelled.sorted(by: { $0.name < $1.name }) {
            print("  [\(item.role)] \(item.name)")
        }
        print("")
        print("=== UNLABELLED INTERACTIVE ELEMENTS (\(result.unlabelled.count)) ===")
        for item in result.unlabelled.sorted() {
            print("  \(item)")
        }
    }

    // MARK: Assistive-client view

    /// Reads the same window through the Accessibility API — the interface VoiceOver
    /// actually consumes, rather than the view tree — and lists every control the system
    /// would expose. This is the authoritative answer to "is this control announced?".
    @MainActor
    private static func reportViaAXAPI() {
        let app = AXUIElementCreateApplication(getpid())
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let windowList = windows as? [AXUIElement],
              let first = windowList.first else {
            print("AX: no windows exposed")
            return
        }

        var found: [String] = []
        var nameless: [String] = []

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 40 else { return }
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            let role = (roleRef as? String) ?? ""

            // The window's own controls — close, minimise, zoom — belong to AppKit, not to
            // the app, and carry no label by design. Excluding them by subrole keeps the
            // audit reporting only controls this codebase is responsible for.
            var subroleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
            let subrole = (subroleRef as? String) ?? ""
            let windowControls = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]
            if windowControls.contains(subrole) { return }

            let controls = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                            "AXMenuButton", "AXTextField", "AXSlider", "AXComboBox"]
            if controls.contains(role) {
                var titleRef: CFTypeRef?
                var descRef: CFTypeRef?
                var helpRef: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
                AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)
                AXUIElementCopyAttributeValue(element, kAXHelpAttribute as CFString, &helpRef)
                // A text field's placeholder is what VoiceOver reads when no label is set,
                // so it counts as a name rather than being reported as unannounced.
                var placeholderRef: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXPlaceholderValueAttribute as CFString, &placeholderRef)

                let title = (titleRef as? String) ?? ""
                let desc = (descRef as? String) ?? ""
                let help = (helpRef as? String) ?? ""
                let placeholder = (placeholderRef as? String) ?? ""
                let name = !title.isEmpty ? title : (!desc.isEmpty ? desc : placeholder)

                // Position and identifier, so an unnamed control can be located in the
                // layout rather than guessed at.
                var posRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
                AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
                var point = CGPoint.zero
                var size = CGSize.zero
                if let posRef { AXValueGetValue(posRef as! AXValue, .cgPoint, &point) }
                if let sizeRef { AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) }
                var identRef: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identRef)
                let ident = (identRef as? String) ?? ""
                let where_ = "\(Int(point.x)),\(Int(point.y)) \(Int(size.width))x\(Int(size.height))"
                    + (ident.isEmpty ? "" : " id=\(ident)")

                if name.isEmpty {
                    nameless.append("\(role) at \(where_)\(help.isEmpty ? " (tooltip only: \"\(help)\")" : "")")
                } else {
                    found.append("[\(role)] \(name)   at \(where_)")
                }
            }

            var childrenRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
            for child in (childrenRef as? [AXUIElement]) ?? [] {
                visit(child, depth: depth + 1)
            }
        }

        visit(first, depth: 0)

        print("")
        print("=== AX API: NAMED CONTROLS (\(found.count)) ===")
        for item in found.sorted() { print("  \(item)") }
        print("=== AX API: UNNAMED CONTROLS (\(nameless.count)) ===")
        for item in nameless.sorted() { print("  \(item)") }

        lastUnnamedCount = nameless.count
    }

    /// Number of app-owned controls the last AX walk found without an accessible name.
    /// Read by the caller to decide the exit code.
    nonisolated(unsafe) static var lastUnnamedCount = 0
}
