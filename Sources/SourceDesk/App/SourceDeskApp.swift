import SwiftUI
import SourceDeskCore
import AppKit

/// SourceDesk's entry point.
///
/// The app is an ordinary SwiftUI `App` with an `NSApplicationDelegateAdaptor` only
/// for the pieces SwiftUI does not cover (activation policy and clean shutdown).
@main
struct SourceDeskApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState()
    @State private var chat: ChatViewModel?
    @State private var study: StudyToolsViewModel?
    @State private var search: SearchPanelViewModel?

    var body: some Scene {
        Window("SourceDesk", id: "main") {
            RootView()
                .environment(app)
                .environment(chatModel)
                .environment(studyModel)
                .environment(searchModel)
                .frame(minWidth: 1_040, minHeight: 620)
                .preferredColorScheme(app.settings.appearance.swiftUIScheme)
                .task {
                    app.start()
                    // The view models are created above; loading messages here means
                    // the first render already has the session's history.
                    _ = chatModel
                    chatModel.loadMessages()
                }
        }
        .defaultSize(width: 1_360, height: 860)
        .commands { SourceDeskCommands(app: app) }

        Settings {
            SettingsView()
                .environment(app)
                .frame(width: 780, height: 620)
                .preferredColorScheme(app.settings.appearance.swiftUIScheme)
        }
    }

    /// The view models are created lazily but stored, so a re-render never resets
    /// in-flight generation.
    private var chatModel: ChatViewModel {
        if let chat { return chat }
        let model = ChatViewModel(app: app)
        DispatchQueue.main.async { self.chat = model }
        return model
    }

    private var studyModel: StudyToolsViewModel {
        if let study { return study }
        let model = StudyToolsViewModel(app: app)
        DispatchQueue.main.async { self.study = model }
        return model
    }

    private var searchModel: SearchPanelViewModel {
        if let search { return search }
        let model = SearchPanelViewModel(app: app)
        DispatchQueue.main.async { self.search = model }
        return model
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Documentation screenshots are rendered from the real views, offscreen, and
        // the process exits — the app never reaches its window in that mode.
        if CommandLine.arguments.contains("--render-screenshots") {
            ScreenshotRenderer.runAndExit(arguments: CommandLine.arguments)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        DiagnosticsLog.shared.info("SourceDesk terminating", category: "lifecycle")
    }
}

// MARK: - Menu commands

/// Menu items are wired to the same actions the views use, so keyboard shortcuts and
/// buttons can never drift apart.
struct SourceDeskCommands: Commands {
    let app: AppState

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Notebook") { app.createNotebook(title: "Untitled notebook") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .saveItem) {
            Button("Export Notebook…") {
                NotificationCenter.default.post(name: .exportNotebook, object: nil)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Import Notebook…") {
                NotificationCenter.default.post(name: .importNotebook, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }

        CommandMenu("Notebook") {
            Button("Add Website…") { NotificationCenter.default.post(name: .addWebsite, object: nil) }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Add Files…") { NotificationCenter.default.post(name: .addFiles, object: nil) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Paste Text…") { NotificationCenter.default.post(name: .addPastedText, object: nil) }
            Divider()
            Button("Research") { app.section = .research }
                .keyboardShortcut("1", modifiers: .command)
            Button("Sources") { app.section = .sources }
                .keyboardShortcut("2", modifiers: .command)
            Button("Notes") { app.section = .notes }
                .keyboardShortcut("3", modifiers: .command)
            Button("Study Tools") { app.section = .studyTools }
                .keyboardShortcut("4", modifiers: .command)
            Button("Search") { app.section = .search }
                .keyboardShortcut("5", modifiers: .command)
            Divider()
            Button("Show Command Palette…") { app.commandPaletteVisible = true }
                .keyboardShortcut("k", modifiers: .command)
            Button("Refresh Models") {
                Task { await app.refreshAllModels() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}

extension Notification.Name {
    static let exportNotebook = Notification.Name("sourcedesk.exportNotebook")
    static let importNotebook = Notification.Name("sourcedesk.importNotebook")
    static let addWebsite = Notification.Name("sourcedesk.addWebsite")
    static let addFiles = Notification.Name("sourcedesk.addFiles")
    static let addPastedText = Notification.Name("sourcedesk.addPastedText")
    /// Open the Sources pane's find-by-topic panel.
    static let openFindSources = Notification.Name("sourcedesk.openFindSources")
}

extension AppearanceMode {
    var swiftUIScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
