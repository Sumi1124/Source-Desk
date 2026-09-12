import Foundation
import SwiftUI
import AppKit
import SourceDeskCore

/// Renders the application's real views to PNG files.
///
/// This exists because documentation needs screenshots of the *actual* interface,
/// and rendering the live views is more honest (and more reproducible) than capturing
/// the screen: the same view code that runs in the app is drawn here, against a seeded
/// library, so the images cannot drift from the product.
///
///   .build/debug/SourceDesk --render-screenshots docs/screenshots
///
/// Development utility only; it exits before the app's own run loop starts.
@MainActor
enum ScreenshotRenderer {

    static func runAndExit(arguments: [String]) -> Never {
        var outputDirectory = "docs/screenshots"
        if let index = arguments.firstIndex(of: "--render-screenshots"),
           index + 1 < arguments.count,
           !arguments[index + 1].hasPrefix("-") {
            outputDirectory = arguments[index + 1]
        }

        // AppKit resolves `NSColor` (windowBackgroundColor, textBackgroundColor, …)
        // from the *application* appearance, not from SwiftUI's colorScheme. Without
        // this, a machine in dark mode produces dark screenshots regardless of what
        // the view asks for.
        NSApp.appearance = NSAppearance(named: .aqua)

        let directory = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // A scratch library, seeded if it is empty, so screenshots always show content.
        let root = ProcessInfo.processInfo.environment["SOURCEDESK_SCREENSHOT_ROOT"]
            ?? "/tmp/sd-demo/Library/Application Support/SourceDesk"
        let paths = AppPaths(root: URL(fileURLWithPath: root))
        try? paths.createDirectories()

        if (try? NotebookStore(paths: paths).notebooks().isEmpty) ?? true {
            do { try DemoSeed.run(root: root) } catch {
                print("Could not seed the demo library: \(error)")
            }
        }

        let app = AppState(paths: paths)
        app.start()
        let chat = ChatViewModel(app: app)
        chat.loadMessages()
        let study = StudyToolsViewModel(app: app)
        let search = SearchPanelViewModel(app: app)

        if let notebook = app.notebooks.first(where: { $0.isFavorite }) ?? app.notebooks.first {
            app.selectNotebook(notebook.id)
            chat.loadMessages()
            if let source = app.sources.first(where: { $0.title.contains("Inspectorate") }) ?? app.sources.first {
                app.selectedSourceID = source.id
            }
            if let note = app.notes.first(where: { $0.kind == .summary }) ?? app.notes.first {
                app.selectedNoteID = note.id
            }
        }
        app.updateSettings { $0.appearance = .light }

        let environment: (AnyView) -> AnyView = { content in
            AnyView(content.environment(app).environment(chat).environment(study).environment(search))
        }

        // 1. The main window: sidebar, working area and inspector, exactly as the
        //    app composes them (the window chrome itself is not part of the capture).
        app.section = .research
        render(
            environment(AnyView(mainWindow())),
            to: directory.appendingPathComponent("01-research.png"),
            label: "main window"
        )

        // 2. Source management.
        app.section = .sources
        render(
            environment(AnyView(mainWindow(size: NSSize(width: 1_200, height: 800), includeSidebar: false))),
            to: directory.appendingPathComponent("02-sources.png"),
            label: "sources"
        )

        // 3. The inspector for a selected source.
        app.selectedSourceID = app.sources.first { $0.title.contains("Inspectorate") }?.id ?? app.sources.first?.id
        render(
            environment(AnyView(
                InspectorPanelView()
                    .frame(width: Design.inspectorWidth, height: 780)
                    .background(Color(nsColor: .windowBackgroundColor))
            )),
            to: directory.appendingPathComponent("03-source-inspector.png"),
            label: "source inspector"
        )

        // 4. Study tools.
        app.section = .studyTools
        study.selectedTool = .summary
        render(
            environment(AnyView(mainWindow(size: NSSize(width: 1_200, height: 800), includeSidebar: false))),
            to: directory.appendingPathComponent("04-study-tools.png"),
            label: "study tools"
        )

        // 5. Notes, showing structured material.
        app.section = .notes
        app.selectedNoteID = app.notes.first { $0.kind == .flashcards }?.id ?? app.notes.first?.id
        render(
            environment(AnyView(mainWindow(size: NSSize(width: 1_200, height: 800), includeSidebar: false))),
            to: directory.appendingPathComponent("05-notes-flashcards.png"),
            label: "notes"
        )

        // 6. Web search.
        app.section = .search
        render(
            environment(AnyView(mainWindow(size: NSSize(width: 1_200, height: 800), includeSidebar: false))),
            to: directory.appendingPathComponent("06-web-search.png"),
            label: "search"
        )

        // 7. Settings. A TabView renders no chrome without a real window, so each pane
        //    is captured on its own — which is also what a reader wants to see.
        let settingsPane = { (content: AnyView, name: String) in
            render(
                environment(AnyView(
                    content
                        .frame(width: 760, height: 620)
                        .background(Color(nsColor: .windowBackgroundColor))
                )),
                to: directory.appendingPathComponent(name),
                label: name.replacingOccurrences(of: ".png", with: "")
            )
        }
        settingsPane(AnyView(ProvidersSettings()), "07-settings-providers.png")
        settingsPane(AnyView(RetrievalSettings()), "07b-settings-retrieval.png")
        settingsPane(AnyView(PrivacySettings()), "07c-settings-privacy.png")

        // 8. The command palette, over a dimmed background.
        app.commandPaletteVisible = true
        render(
            environment(AnyView(
                ZStack {
                    Color(nsColor: .textBackgroundColor)
                    CommandPaletteView()
                }
                .frame(width: 1_120, height: 780)
            )),
            to: directory.appendingPathComponent("08-command-palette.png"),
            label: "command palette"
        )
        app.commandPaletteVisible = false

        // 9. The sidebar on its own, showing notebook structure.
        render(
            environment(AnyView(SidebarView(onAddWebsite: {}, onAddFiles: {}, onAddPastedText: {})
                .frame(width: 260, height: 700))),
            to: directory.appendingPathComponent("09-sidebar.png"),
            label: "sidebar"
        )

        // 10. The empty state, which is part of the product, not an accident.
        let emptyPaths = AppPaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("sourcedesk-empty-\(UUID().uuidString)", isDirectory: true))
        let emptyApp = AppState(paths: emptyPaths)
        emptyApp.start()
        let emptyChat = ChatViewModel(app: emptyApp)
        render(
            AnyView(ResearchView().frame(width: 1_120, height: 780)
                .environment(emptyApp).environment(emptyChat)
                .environment(StudyToolsViewModel(app: emptyApp))
                .environment(SearchPanelViewModel(app: emptyApp))),
            to: directory.appendingPathComponent("10-empty-state.png"),
            label: "empty state"
        )
        try? FileManager.default.removeItem(at: emptyPaths.root)

        print("Rendered screenshots to \(directory.path)")
        exit(0)
    }

    /// The application's own three-column composition.
    ///
    /// Rendering a bare column would drop the backgrounds the real window applies —
    /// text is drawn in the system label colour, which against a transparent backdrop
    /// is unreadable. Composing the columns exactly as `RootView` does is what makes
    /// these images faithful.
    private static func mainWindow(
        size: NSSize = NSSize(width: 1_360, height: 860),
        includeSidebar: Bool = true
    ) -> some View {
        HStack(spacing: 0) {
            if includeSidebar {
                SidebarView(onAddWebsite: {}, onAddFiles: {}, onAddPastedText: {})
                    .frame(width: Design.sidebarWidth)
                Divider()
            }
            WorkingAreaView(onAddWebsite: {}, onAddFiles: {}, onAddPastedText: {})
            if true {
                Divider()
                InspectorPanelView()
                    .frame(width: Design.inspectorWidth)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Draws a view through a real (offscreen) window.
    ///
    /// `ImageRenderer` is lighter, but it cannot draw AppKit-backed controls — a
    /// segmented `Picker`, a bordered `Button`, a `List` — and it renders materials
    /// (`.thinMaterial`) as black, because those need a window-backed appearance to
    /// resolve. Since the point of these images is to show the interface as it really
    /// appears, the view is hosted in an offscreen `NSWindow`, laid out, given a
    /// runloop turn, and then snapshotted.
    @discardableResult
    private static func render(_ view: AnyView, to url: URL, label: String) -> Bool {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .light))

        var size = hosting.fittingSize
        if size.width < 1 || size.height < 1 { size = NSSize(width: 1_120, height: 780) }
        let frame = CGRect(origin: .zero, size: size)
        hosting.frame = frame

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        // A borderless window's unpainted area is black; views that leave parts of
        // themselves transparent (a bare column with no background) would otherwise
        // be captured against black.
        window.backgroundColor = .textBackgroundColor
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)) // off-screen, still laid out
        window.orderFrontRegardless()

        hosting.layoutSubtreeIfNeeded()
        // One runloop turn lets SwiftUI resolve materials and lay out list rows.
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("  ✗ \(label): no bitmap representation available")
            window.orderOut(nil)
            return false
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        // `cacheDisplay` fills the bitmap's buffer, but `representation(using:)` reads
        // the colour data through the rep's own planes; creating a fresh bitmap from
        // the cached TIFF representation (and drawing into it explicitly) is what
        // produces a usable PNG rather than a white image.
        let png: Data?
        if let source = rep.cgImage,
           let context = CGContext(data: nil, width: source.width, height: source.height,
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
            // Opaque destination: the window background is painted first so nothing
            // can be captured against black, and translucent fills composite the way
            // they do on screen.
            context.setFillColor(NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)?.cgColor ?? CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: source.width, height: source.height))
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
            if let rendered = context.makeImage() {
                png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:])
            } else {
                png = rep.representation(using: .png, properties: [:])
            }
        } else {
            png = rep.representation(using: .png, properties: [:])
        }
        window.orderOut(nil)

        guard let png else {
            print("  ✗ \(label): PNG encoding failed")
            return false
        }
        do {
            try png.write(to: url)
            print("  ✓ \(label) → \(url.lastPathComponent) (\(Int(frame.width))×\(Int(frame.height)))")
            return true
        } catch {
            print("  ✗ \(label): \(error.localizedDescription)")
            return false
        }
    }
}
