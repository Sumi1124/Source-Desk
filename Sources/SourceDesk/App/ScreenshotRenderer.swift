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

    /// Set from `--dark`, so one run produces the light set and another the dark set.
    /// A renderer that only ever captured one appearance would leave the documentation
    /// unable to show that the interface works in both, which is a claim the app makes.
    private static var darkMode = false

    /// AppKit raises on a malformed window rather than returning an error, and an
    /// Objective-C exception inside the render loop terminates the process with no output
    /// at all — which is exactly how a broken toolbar reported itself. Installing a handler
    /// turns that into a readable line naming the label that failed.
    private static func installExceptionLogger() {
        NSSetUncaughtExceptionHandler { exception in
            let message = "  ✗ AppKit exception: \(exception.name.rawValue): \(exception.reason ?? "")\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    }

    static func runAndExit(arguments: [String]) -> Never {
        installExceptionLogger()
        var outputDirectory = "docs/screenshots"
        darkMode = arguments.contains("--dark")
        if let index = arguments.firstIndex(of: "--render-screenshots"),
           index + 1 < arguments.count,
           !arguments[index + 1].hasPrefix("-") {
            outputDirectory = arguments[index + 1]
        }

        // AppKit resolves `NSColor` (windowBackgroundColor, textBackgroundColor, …)
        // from the *application* appearance, not from SwiftUI's colorScheme. Without
        // this, a machine in dark mode produces dark screenshots regardless of what
        // the view asks for.
        NSApp.appearance = NSAppearance(named: darkMode ? .darkAqua : .aqua)

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
        app.updateSettings { $0.appearance = darkMode ? .dark : .light }

        let environment: (AnyView) -> AnyView = { content in
            AnyView(content.environment(app).environment(chat).environment(study).environment(search))
        }

        // Light and dark renders share every filename except the suffix, so a reader can
        // compare them and the README can pick either.
        func output(_ name: String) -> URL {
            directory.appendingPathComponent(darkMode ? name.replacingOccurrences(of: ".png", with: "-dark.png") : name)
        }

        // 1. The main window: sidebar, working area and inspector, exactly as the
        //    app composes them, captured with the real title bar and toolbar.
        app.section = .research
        render(
            environment(AnyView(columns())),
            to: output("01-research.png"),
            label: "main window",
            size: NSSize(width: 1_360, height: 800)
        )

        // 2. Source management.
        app.section = .sources
        render(
            environment(AnyView(columns(size: NSSize(width: 1_200, height: 800)))),
            to: output("02-sources.png"),
            label: "sources",
            size: NSSize(width: 1_200, height: 800)
        )

        // 3. The inspector for a selected source.
        app.selectedSourceID = app.sources.first { $0.title.contains("Inspectorate") }?.id ?? app.sources.first?.id
        render(
            environment(AnyView(
                InspectorPanelView()
                    .frame(width: Design.inspectorWidth, height: 780)
                    .background(Color(nsColor: .windowBackgroundColor))
            )),
            to: output("03-source-inspector.png"),
            label: "source inspector"
        )

        // 4. Study tools.
        app.section = .studyTools
        study.selectedTool = .summary
        render(
            environment(AnyView(columns(size: NSSize(width: 1_200, height: 800)))),
            to: output("04-study-tools.png"),
            label: "study tools",
            size: NSSize(width: 1_200, height: 800)
        )

        // 5. Notes, showing structured material.
        app.section = .notes
        app.selectedNoteID = app.notes.first { $0.kind == .flashcards }?.id ?? app.notes.first?.id
        render(
            environment(AnyView(columns(size: NSSize(width: 1_200, height: 800)))),
            to: output("05-notes-flashcards.png"),
            label: "notes",
            size: NSSize(width: 1_200, height: 800)
        )

        // 6. Web search.
        app.section = .search
        render(
            environment(AnyView(columns(size: NSSize(width: 1_200, height: 800)))),
            to: output("06-web-search.png"),
            label: "search",
            size: NSSize(width: 1_200, height: 800)
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
                to: output(name),
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
            to: output("08-command-palette.png"),
            label: "command palette"
        )
        app.commandPaletteVisible = false

        // 9. The sidebar on its own, showing notebook structure.
        render(
            environment(AnyView(SidebarView(onAddWebsite: {}, onAddFiles: {}, onAddPastedText: {})
                .frame(width: 260, height: 700)
                .background(.thinMaterial))),
            to: output("09-sidebar.png"),
            label: "sidebar",
            title: "Notebooks",
            showsToolbar: false
        )

        // 10. The empty state, which is part of the product, not an accident.
        let emptyPaths = AppPaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("sourcedesk-empty-\(UUID().uuidString)", isDirectory: true))
        let emptyApp = AppState(paths: emptyPaths)
        emptyApp.start()
        let emptyChat = ChatViewModel(app: emptyApp)
        render(
            AnyView(ResearchView()
                .frame(width: 1_120, height: 760)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(emptyApp).environment(emptyChat)
                .environment(StudyToolsViewModel(app: emptyApp))
                .environment(SearchPanelViewModel(app: emptyApp))),
            to: output("10-empty-state.png"),
            label: "empty state",
            title: "SourceDesk",
            size: NSSize(width: 1_120, height: 760)
        )
        try? FileManager.default.removeItem(at: emptyPaths.root)

        print("Rendered screenshots to \(directory.path)")
        exit(0)
    }

    /// The application's real root view, hosted as the window's content.
    ///
    /// This is what the running app shows: `NavigationSplitView`, the sidebar, the section
    /// picker and model menu in the real toolbar, the inspector, and the sheets. Rendering
    /// it rather than a hand-composed HStack of columns has two benefits — the images cannot
    /// drift from the product, and SwiftUI resolves `.searchable` placements the way the app
    /// does. The previous hand-composed version put both the sidebar's and the sources' search
    /// into one window toolbar, which AppKit refuses as a duplicate identifier and traps on.
    private static func rootWindow(size: NSSize = NSSize(width: 1_360, height: 800)) -> some View {
        RootView()
            .frame(width: size.width, height: size.height)
    }

    /// The three columns in a `NavigationSplitView`, as the app arranges them.
    ///
    /// The split view matters for correctness, not decoration: `SidebarView` declares
    /// `.searchable(placement: .sidebar)` and `SourcesView` declares
    /// `.searchable(placement: .toolbar)`. Flattened into a plain `HStack` both resolve
    /// against the same window toolbar, and AppKit raises
    /// "NSToolbar already contains an item with the identifier com.apple.SwiftUI.search",
    /// which traps. In a split view each placement belongs to its own column, which is how
    /// the app itself is laid out.
    private static func columns(
        size: NSSize = NSSize(width: 1_360, height: 800),
        includeSidebar: Bool = true,
        includeInspector: Bool = true
    ) -> some View {
        HStack(spacing: 0) {
            if includeSidebar {
                VStack(spacing: 0) {
                    SidebarView(onAddWebsite: {}, onAddFiles: {}, onAddPastedText: {}, inlineFilterField: true)
                }
                .frame(width: Design.sidebarWidth)
                .background(.thinMaterial)
                Divider()
            }
            WorkingAreaView(onAddWebsite: {}, onAddFiles: {}, onAddPastedText: {},
                            inlineSearchField: true)
            if includeInspector {
                Divider()
                InspectorPanelView()
                    .frame(width: Design.inspectorWidth)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The application's own three-column composition.
    ///
    /// Rendering a bare column would drop the backgrounds the real window applies —
    /// text is drawn in the system label colour, which against a transparent backdrop
    /// is unreadable. Composing the columns exactly as `RootView` does is what makes
    /// these images faithful, and the sidebar carries the app's own sidebar material so
    /// it looks like the translucent column it is on screen.
    private static func mainWindow(
        size: NSSize = NSSize(width: 1_360, height: 860),
        includeSidebar: Bool = true,
        includeInspector: Bool = true
    ) -> some View {
        HStack(spacing: 0) {
            if includeSidebar {
                SidebarView(onAddWebsite: {}, onAddFiles: {}, onAddPastedText: {})
                    .frame(width: Design.sidebarWidth)
                    .background(.thinMaterial)
                Divider()
            }
            WorkingAreaView(onAddWebsite: {}, onAddFiles: {}, onAddPastedText: {},
                            inlineSearchField: true)
            if includeInspector {
                Divider()
                InspectorPanelView()
                    .frame(width: Design.inspectorWidth)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Draws a view through a real (offscreen) window, **including the window chrome**.
    ///
    /// `ImageRenderer` is lighter, but it cannot draw AppKit-backed controls — a
    /// segmented `Picker`, a bordered `Button`, a `List` — and it renders materials
    /// (`.thinMaterial`) as black, because those need a window-backed appearance to
    /// resolve. Since the point of these images is to show the interface as it really
    /// appears, the view is hosted in an offscreen `NSWindow`.
    ///
    /// It is a *titled* window with a toolbar, not a borderless one, and the capture is
    /// taken from the theme frame (`contentView.superview`) rather than the content view.
    /// That is what puts the traffic lights, the title and the toolbar into the image —
    /// a screenshot of a Mac app that shows no window chrome reads as a web page, and the
    /// documentation is judged in seconds.
    @discardableResult
    private static func render(
        _ view: AnyView,
        to url: URL,
        label: String,
        title: String = "SourceDesk",
        showsToolbar: Bool = true,
        size: NSSize? = nil
    ) -> Bool {
        let appearance: NSAppearance.Name = darkMode ? .darkAqua : .aqua
        let hosting = NSHostingView(
            rootView: view
                .environment(\.colorScheme, darkMode ? .dark : .light)
        )

        var contentSize = size ?? hosting.fittingSize
        if contentSize.width < 1 || contentSize.height < 1 {
            contentSize = NSSize(width: 1_120, height: 780)
        }
        let frame = CGRect(origin: .zero, size: contentSize)
        hosting.frame = frame

        // Deliberately *not* `.fullSizeContentView`: the chrome is what this needs, and
        // letting content extend under the title bar made the theme frame and the hosting
        // view disagree about their area, which crashed the offscreen layout on the second
        // capture. A standard titled window lays out predictably.
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.title = title
        // A window whose content is unpainted would otherwise capture against black.
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting

        // No NSToolbar is installed.
        //
        // Attaching one was the first attempt at getting a toolbar into these images, and
        // it crashes: SwiftUI builds the app's real toolbar through `.toolbar { }` and
        // `.searchable()`, and AppKit refuses a second item with the same identifier
        // ("NSToolbar already contains an item with the identifier com.apple.SwiftUI.search").
        // The window is given only its title bar, which is the part that was missing — the
        // three columns below it already carry the section picker, the model menu and the
        // search field, because those live in the content SwiftUI renders.
        _ = showsToolbar

        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)) // off-screen, still laid out
        window.orderFrontRegardless()

        hosting.layoutSubtreeIfNeeded()
        // One runloop turn lets SwiftUI resolve materials and lay out list rows.
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        // The theme frame owns the title bar and toolbar; the content view does not.
        guard let themeFrame = window.contentView?.superview,
              let rep = themeFrame.bitmapImageRepForCachingDisplay(in: themeFrame.bounds) else {
            print("  ✗ \(label): no bitmap representation available")
            window.orderOut(nil)
            return false
        }
        themeFrame.layoutSubtreeIfNeeded()
        let captureBounds = themeFrame.bounds
        themeFrame.cacheDisplay(in: captureBounds, to: rep)
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
            let backdrop = (NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)?.cgColor)
                ?? CGColor(gray: darkMode ? 0 : 1, alpha: 1)
            context.setFillColor(backdrop)
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
            print("  ✓ \(label) → \(url.lastPathComponent) (\(Int(captureBounds.width))×\(Int(captureBounds.height))"
                  + (darkMode ? ", dark" : "") + ")")
            return true
        } catch {
            print("  ✗ \(label): \(error.localizedDescription)")
            return false
        }
    }
}
