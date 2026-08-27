import SwiftUI

enum HealthMuleStyle {
    static let contentWidth: CGFloat = 720
    static let pagePadding: CGFloat = 20
    static let cardRadius: CGFloat = 20
    static let sectionSpacing: CGFloat = 24
    static let rowIconSize: CGFloat = 36

    /// One canonical scale so screens cannot drift apart. Card titles and body
    /// copy sit a step below the system defaults, which read oversized in a
    /// dense status app.
    enum Text {
        static let heroTitle = Font.title3.weight(.semibold)
        static let heroMessage = Font.callout
        static let sectionTitle = Font.headline
        static let sectionSubtitle = Font.footnote
        static let cardTitle = Font.subheadline.weight(.semibold)
        static let cardBody = Font.footnote
        static let factLabel = Font.caption2.weight(.medium)
        static let factValue = Font.subheadline.weight(.semibold)
    }

    static var canvas: Color {
        Color(uiColor: .systemBackground)
    }

    static var surface: Color {
        Color(uiColor: .secondarySystemBackground)
    }

    static var tint: Color {
        Color("AccentColor")
    }

    static var hairline: Color {
        Color.primary.opacity(0.07)
    }

    static var inset: Color {
        Color.primary.opacity(0.055)
    }
}

enum StatusTone: Equatable {
    case neutral
    case accent
    case success
    case warning
    case danger

    var color: Color {
        switch self {
        case .neutral:
            .secondary
        case .accent:
            .primary
        case .success:
            .green
        case .warning:
            .orange
        case .danger:
            .red
        }
    }
}

extension SyncActivityOutcome {
    var statusLabel: String {
        switch self {
        case .running:
            "Running"
        case .succeeded:
            "Succeeded"
        case .pending:
            "Pending"
        case .skipped:
            "Skipped"
        case .failed:
            "Failed"
        case .interrupted:
            "Interrupted"
        }
    }

    var statusTone: StatusTone {
        switch self {
        case .running, .pending:
            .accent
        case .succeeded:
            .success
        case .skipped, .interrupted:
            .warning
        case .failed:
            .danger
        }
    }
}

struct StatusGlyph: View {
    let systemImage: String
    var tone: StatusTone = .neutral
    var size = HealthMuleStyle.rowIconSize

    var body: some View {
        Image(systemName: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tone.color)
            .frame(width: size, height: size)
            .background(tone.color.opacity(0.1), in: Circle())
            .accessibilityHidden(true)
    }
}

struct IconStatusRow: View {
    let title: String
    let status: String
    var detail: String?
    let systemImage: String
    var tone: StatusTone = .neutral
    var showsChevron = false
    var accessibilityLabel: String?
    var accessibilityValue: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusGlyph(systemImage: systemImage, tone: tone)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(HealthMuleStyle.Text.cardTitle)

                Text(status)
                    .font(HealthMuleStyle.Text.cardBody)
                    .foregroundStyle(.secondary)

                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 10)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityValue(accessibilityValue ?? [status, detail]
            .compactMap { $0 }
            .joined(separator: ". "))
    }
}

struct HealthMuleNote: View {
    let text: String
    var systemImage = "info.circle"
    var tone: StatusTone = .neutral

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tone.color)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .font(HealthMuleStyle.Text.sectionSubtitle)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct StatusBadge: View {
    let title: String
    let tone: StatusTone

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tone.color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.08), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct SectionHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(HealthMuleStyle.Text.sectionTitle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Explanatory copy for the group above it. iOS puts this below its section,
/// not above it as a subtitle. A heading answers "what is this". A footer
/// answers "what does it mean".
struct SectionFooter: View {
    let text: String
    /// Set when the section's own element already announces this string, so
    /// VoiceOver does not read it twice.
    var isAccessibilityHidden = false

    var body: some View {
        Text(text)
            .font(HealthMuleStyle.Text.sectionSubtitle)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .accessibilityHidden(isAccessibilityHidden)
    }
}

struct StatusHero<Action: View>: View {
    let badge: String
    let tone: StatusTone
    let title: String
    let message: String
    var progress: SyncProgress?
    var showsActionPlaceholder = false
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusBadge(title: badge, tone: tone)
                .accessibilityIdentifier("status-hero-badge")
            Text(title)
                .font(HealthMuleStyle.Text.heroTitle)
                .accessibilityIdentifier("status-hero-title")
            Text(message)
                .font(HealthMuleStyle.Text.heroMessage)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("status-hero-message")

            if let progress, progress.totalUnits > 0 {
                SyncDayProgressView(progress: progress)
            }

            if showsActionPlaceholder {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(HealthMuleStyle.inset)
                    .frame(height: 52)
                    .accessibilityHidden(true)
            } else {
                action()
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                    .tint(HealthMuleStyle.tint)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .healthMuleCard(padding: 20)
    }
}

/// The queue facts shown on both Home and Sync. One component so the two
/// screens cannot disagree about their order, labels, or type.
struct SyncFactsRow: View {
    let summary: SyncSummary

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize > .large {
            VStack(spacing: 14) {
                fact(.lastSync, compact: false)
                Divider()
                fact(.latestDay, compact: false)
                Divider()
                fact(.pending, compact: false)
            }
        } else {
            HStack(alignment: .top, spacing: 0) {
                fact(.lastSync, compact: true)
                    .padding(.trailing, 10)
                Divider()
                fact(.latestDay, compact: true)
                    .padding(.horizontal, 10)
                Divider()
                fact(.pending, compact: true)
                    .padding(.leading, 10)
            }
        }
    }

    private enum Fact {
        case lastSync
        case latestDay
        case pending

        var label: String {
            switch self {
            case .lastSync: "Last Drive sync"
            case .latestDay: "Data through"
            case .pending: "To upload"
            }
        }
    }

    private func fact(_ fact: Fact, compact: Bool) -> some View {
        let full: String
        let shown: String
        switch fact {
        case .lastSync:
            full = summary.lastSyncText
            shown = compact ? summary.compactLastSyncText : full
        case .latestDay:
            full = summary.latestExportedDayText
            shown = compact ? summary.compactLatestDayText : full
        case .pending:
            full = summary.pendingUploadCount.formatted()
            shown = full
        }

        return VStack(alignment: .leading, spacing: 4) {
            Text(fact.label)
                .font(HealthMuleStyle.Text.factLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(shown)
                .font(HealthMuleStyle.Text.factValue)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.default, value: shown)
                .lineLimit(compact ? 1 : nil)
                .minimumScaleFactor(compact ? 0.82 : 1)
                .allowsTightening(compact)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fact.label)
        .accessibilityValue(full)
    }
}

struct InlineProgressLabel: View {
    let title: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 20, height: 20)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct OperationBanner: View {
    let state: OperationState

    var body: some View {
        if state != .idle {
            HStack(alignment: .center, spacing: 10) {
                if state.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tone.color)
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: symbolName)
                        .foregroundStyle(tone.color)
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                }
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .healthMuleCard(padding: 14)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("operation-status")
        }
    }

    private var message: String {
        switch state {
        case .idle:
            ""
        case .working(_, let message),
             .warning(_, let message),
             .succeeded(_, let message),
             .failed(_, let message):
            message
        }
    }

    private var tone: StatusTone {
        switch state {
        case .failed:
            .danger
        case .warning:
            .warning
        case .succeeded:
            .success
        case .idle, .working:
            .accent
        }
    }

    private var symbolName: String {
        switch state {
        case .failed:
            "exclamationmark.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .succeeded:
            "checkmark.circle.fill"
        case .idle, .working:
            "arrow.triangle.2.circlepath"
        }
    }
}

private struct HealthMuleCardModifier: ViewModifier {
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                HealthMuleStyle.surface,
                in: RoundedRectangle(
                    cornerRadius: HealthMuleStyle.cardRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: HealthMuleStyle.cardRadius,
                    style: .continuous
                )
                .stroke(HealthMuleStyle.hairline, lineWidth: 1)
            }
    }
}

extension View {
    func healthMuleCard(padding: CGFloat = 18) -> some View {
        modifier(HealthMuleCardModifier(padding: padding))
    }
}
