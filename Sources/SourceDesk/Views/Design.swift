import SwiftUI
import SourceDeskCore

/// Shared visual vocabulary.
///
/// The design rules here are deliberate and narrow, because "serious research tool"
/// is a visual position, not a slogan:
///
/// * Typography and spacing carry the hierarchy — no gradients, no glow, no
///   oversized rounded cards, no decorative emoji.
/// * Native macOS metrics: a translucent sidebar, hairline separators, a real
///   toolbar, standard control sizes, and the system accent colour.
/// * Colour is reserved for meaning: source status, privacy level, citation type.
enum Design {

    // MARK: Metrics

    /// Sidebar width, matching the platform's own applications.
    static let sidebarWidth: CGFloat = 232
    static let inspectorWidth: CGFloat = 330
    static let minimumCentreWidth: CGFloat = 420
    static let contentMaxWidth: CGFloat = 760
    static let rowCornerRadius: CGFloat = 6

    static let spacingTight: CGFloat = 4
    static let spacingSmall: CGFloat = 8
    static let spacingMedium: CGFloat = 14
    static let spacingLarge: CGFloat = 22

    // MARK: Fonts

    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    static let rowTitle = Font.system(size: 13)
    static let caption = Font.system(size: 11)

    // MARK: Onboarding

    /// Fixed size for the welcome flow. A form that resizes under the user as they move
    /// between steps is disorienting, and every step fits comfortably at this size.
    static let onboardingWidth: CGFloat = 620
    static let onboardingHeight: CGFloat = 560
    /// Measure that keeps body text readable rather than full-bleed across the sheet.
    static let onboardingContentWidth: CGFloat = 500
    static let monoCaption = Font.system(size: 11, design: .monospaced)
    static let answerBody = Font.system(size: 14)

    // MARK: Colours

    static func statusColor(_ status: SourceStatus) -> Color {
        switch status {
        case .ready: return .secondary
        case .partial: return .orange
        case .failed: return .red
        case .cancelled: return .secondary
        default: return .accentColor
        }
    }

    static func privacyColor(_ level: PrivacyLevel) -> Color {
        switch level {
        case .local: return .green
        case .cloud: return .orange
        case .web: return .blue
        }
    }

    static func citationColor(_ kind: CitationKind) -> Color {
        switch kind {
        case .notebook: return .accentColor
        case .web: return .blue
        }
    }

    /// Semantic colours for state, as opposed to decoration.
    ///
    /// `.green` and `.orange` are vivid in light mode and wash out against white (the pure
    /// system green measures about 2.7:1 on a white background — below the 4.5:1 floor for
    /// text, and uncomfortable even for a 6pt dot). These shades hold up in both
    /// appearances while staying recognisably the same colour.
    static let statusOnline = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.42, green: 0.88, blue: 0.52, alpha: 1)
            : NSColor(red: 0.11, green: 0.53, blue: 0.24, alpha: 1)
    })

    static let statusWarning = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.98, green: 0.72, blue: 0.33, alpha: 1)
            : NSColor(red: 0.66, green: 0.40, blue: 0.03, alpha: 1)
    })

    static func accent(forIndex index: Int) -> Color {
        let palette: [Color] = [.blue, .purple, .teal, .indigo, .pink, .orange]
        return palette[abs(index) % palette.count]
    }
}

// MARK: - Small reusable views

/// A section header for an inspector or sidebar group. Uses the platform's own
/// uppercase caption style rather than a custom treatment.
@MainActor
struct SectionHeader: View {
    let title: String
    var trailing: AnyView?

    init(_ title: String) {
        self.title = title
        self.trailing = nil
    }

    init<T: View>(_ title: String, @ViewBuilder trailing: () -> T) {
        self.title = title
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(Design.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .tracking(0.4)
            Spacer(minLength: 6)
            if let trailing { trailing }
        }
    }
}

/// A key/value line used throughout the inspector.
@MainActor
struct DetailRow: View {
    let label: String
    let value: String
    var monospaced = false
    var tint: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.spacingSmall) {
            Text(label)
                .font(Design.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(monospaced ? Design.monoCaption : Design.caption)
                .foregroundStyle(tint ?? .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// A quiet status pill: a dot plus a short label. No background cards.
@MainActor
struct StatusPill: View {
    let text: String
    var color: Color = .secondary
    var symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(text)
                .font(Design.caption)
                .foregroundStyle(color)
        }
    }
}

/// Empty states are a first-class part of the product: every one explains what the
/// panel is for and offers the action that fills it.
@MainActor
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var primaryAction: (title: String, action: () -> Void)?
    var secondaryAction: (title: String, action: () -> Void)?
    var footnote: String?

    var body: some View {
        VStack(spacing: Design.spacingMedium) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if primaryAction != nil || secondaryAction != nil {
                HStack(spacing: Design.spacingSmall) {
                    if let primaryAction {
                        Button(primaryAction.title, action: primaryAction.action)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                    }
                    if let secondaryAction {
                        Button(secondaryAction.title, action: secondaryAction.action)
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                    }
                }
            }
            if let footnote {
                Text(footnote)
                    .font(Design.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
        }
        .padding(Design.spacingLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shows a `SourceDeskError` the way the product promises: what happened, and what
/// to do about it — never a bare "something went wrong".
@MainActor
struct ErrorCard: View {
    let title: String
    let message: String
    var recovery: String?
    var isWarning = false
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Design.spacingSmall) {
            Image(systemName: isWarning ? "exclamationmark.triangle" : "exclamationmark.octagon")
                .foregroundStyle(isWarning ? Color.orange : Color.red)
                .font(.system(size: 13))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let recovery {
                    Text(recovery)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Dismiss")
                .help("Dismiss")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Design.rowCornerRadius, style: .continuous)
                .fill((isWarning ? Color.orange : Color.red).opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.rowCornerRadius, style: .continuous)
                .strokeBorder((isWarning ? Color.orange : Color.red).opacity(0.25), lineWidth: 0.5)
        )
    }
}

/// A progress bar for long operations, with the stage named. Cancellation is always
/// offered, because a 500-page PDF import should never be uninterruptible.
@MainActor
struct ProgressBanner: View {
    let title: String
    let stage: String
    let fraction: Double
    var detail: String?
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Design.spacingSmall) {
                ProgressView()
                    .controlSize(.small)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(stage)
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                if let onCancel {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.link)
                        .font(Design.caption)
                }
            }
            ProgressView(value: min(1, max(0, fraction)))
                .progressViewStyle(.linear)
            if let detail {
                Text(detail)
                    .font(Design.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Design.rowCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

/// The privacy banner. Shown whenever content could leave the Mac, so the user is
/// never surprised about what a cloud provider receives.
@MainActor
struct PrivacyNotice: View {
    let level: PrivacyLevel
    var providerName: String?
    var detailOverride: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: level == .local ? "lock.fill" : "arrow.up.right.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Design.privacyColor(level))
            Text(text)
                .font(Design.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var text: String {
        if let detailOverride { return detailOverride }
        switch level {
        case .local: return L("Local: your sources stay on this Mac.")
        case .cloud: return providerName.map { "Cloud: content you send is processed by \($0)." } ?? PrivacyLevel.cloud.detail
        case .web: return L("Web: this query is sent to your search provider.")
        }
    }
}

/// A labelled field used in the add-source sheet and settings.
@MainActor
struct LabelledField<Content: View>: View {
    let label: String
    var help: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
            content
            if let help {
                Text(help)
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
