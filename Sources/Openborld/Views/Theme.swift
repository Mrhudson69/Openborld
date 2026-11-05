import SwiftUI
import AppKit
import OpenborldCore

// MARK: - Adaptive colour

extension Color {
    /// A colour that resolves differently in light and dark appearance.
    ///
    /// Dark mode needs lighter, less saturated variants rather than inverted
    /// ones — a mid-tone brand blue that reads well on white drops below the
    /// contrast floor on a dark surface.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    static func adaptive(
        light: (Double, Double, Double),
        dark: (Double, Double, Double)
    ) -> Color {
        adaptive(
            light: NSColor(srgbRed: light.0, green: light.1, blue: light.2, alpha: 1),
            dark: NSColor(srgbRed: dark.0, green: dark.1, blue: dark.2, alpha: 1)
        )
    }
}

// MARK: - Semantic tokens

/// The app's design tokens.
///
/// Every size, colour, and duration in the UI comes from here. The point isn't
/// tidiness: it's that a token can be checked once for contrast and rhythm, and
/// then every view that uses it is correct by construction.
enum Theme {

    // MARK: Spacing — a 4pt rhythm

    enum Space {
        /// 2 — hairline gaps inside a control.
        static let hair: CGFloat = 2
        /// 4 — between an icon and its label.
        static let xs: CGFloat = 4
        /// 6 — inside compact controls.
        static let sm: CGFloat = 6
        /// 8 — default gap between related items.
        static let md: CGFloat = 8
        /// 12 — standard edge inset for bars and panes.
        static let lg: CGFloat = 12
        /// 16 — between groups.
        static let xl: CGFloat = 16
        /// 24 — between sections.
        static let xxl: CGFloat = 24
        /// 32 — around empty states and sheet content.
        static let huge: CGFloat = 32
    }

    // MARK: Type scale

    /// A fixed scale rather than ad-hoc sizes, so weight and size together
    /// carry hierarchy instead of competing with it.
    enum Typo {
        /// 9 — uppercase section eyebrows only. Never body text.
        static let eyebrow = Font.system(size: 9, weight: .semibold)
        /// 10 — metadata under a label.
        static let micro = Font.system(size: 10)
        /// 11 — secondary labels, column headers, status.
        static let caption = Font.system(size: 11)
        static let captionStrong = Font.system(size: 11, weight: .medium)
        /// 12 — the body size of this app: file names, list rows.
        static let body = Font.system(size: 12)
        static let bodyStrong = Font.system(size: 12, weight: .medium)
        /// 13 — sheet and section titles.
        static let title = Font.system(size: 13, weight: .semibold)
        /// 15 — the title of a sheet that fills the window.
        static let largeTitle = Font.system(size: 15, weight: .semibold)

        /// Tabular figures, so a changing byte count doesn't jiggle its column.
        static let data = Font.system(size: 11).monospacedDigit()
        static let dataSmall = Font.system(size: 10).monospacedDigit()
        static let mono = Font.system(size: 10, design: .monospaced)
    }

    // MARK: Icon sizes

    enum Icon {
        /// 8 — a glyph adorning another glyph: a sort arrow, a link marker.
        static let tiny: CGFloat = 8
        /// 9 — inside a pill or badge.
        static let badge: CGFloat = 9
        /// 11 — adornments beside text.
        static let xs: CGFloat = 11
        /// 12 — list row icons, sidebar rows.
        static let sm: CGFloat = 12
        /// 13 — toolbar glyphs.
        static let md: CGFloat = 13
        /// 16 — emphasis in a sheet header.
        static let lg: CGFloat = 16
        /// 22 — sheet hero glyph.
        static let hero: CGFloat = 22
        /// 34 — empty-state illustration.
        static let display: CGFloat = 34
        /// 42 — the single large glyph at the top of the inspector.
        static let illustration: CGFloat = 42

        /// The square a toolbar glyph is centred in. Pointer targets want more
        /// room than the glyph itself.
        static let hitSize = CGSize(width: 26, height: 22)
    }

    // MARK: Radius

    enum Radius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 6
        static let lg: CGFloat = 9
        static let pill: CGFloat = 999
    }

    // MARK: Row metrics

    enum Row {
        static let height: CGFloat = 26
        static let transferHeight: CGFloat = 46
        static let headerHeight: CGFloat = 22
        static let toolbarHeight: CGFloat = 38
        static let breadcrumbHeight: CGFloat = 32
        static let statusHeight: CGFloat = 24
    }

    // MARK: Motion

    /// One set of durations, chosen by distance travelled rather than per-site
    /// taste, so the whole app shares a rhythm.
    enum Motion {
        /// 120ms — a state change in place: hover, selection tint.
        static let instant: Double = 0.12
        /// 200ms — a control changing shape or a disclosure opening.
        static let standard: Double = 0.20
        /// 260ms — something entering or leaving the screen.
        static let enter: Double = 0.26
        /// Exits read as faster than entrances.
        static let exit: Double = 0.17

        static let hover = Animation.easeOut(duration: instant)
        static let state = Animation.easeOut(duration: standard)
        static let appear = Animation.spring(response: 0.34, dampingFraction: 0.82)
    }

    // MARK: Surfaces and semantic colour

    enum Surface {
        /// The pane background behind a file list.
        static let content = Color(nsColor: .controlBackgroundColor)
        /// Toolbars, status bars, and the sidebar footer.
        static let bar = Color(nsColor: .windowBackgroundColor)
        /// A recessed well: code, link text, a list inside a sheet.
        static let well = Color(nsColor: .textBackgroundColor)
        /// Hairline separators — visible in both appearances.
        static let border = Color(nsColor: .separatorColor)
        /// A faint fill for an unselected tile.
        static let subtle = Color.primary.opacity(0.045)
    }

    enum Ink {
        static let primary = Color(nsColor: .labelColor)

        /// Secondary **text**.
        ///
        /// Deliberately not `secondaryLabelColor`: composited on white that
        /// measures 3.98:1, under the 4.5:1 floor for normal text. This is a
        /// measured grey — 4.94:1 light, 7.91:1 dark — kept close to the
        /// platform tone so the app still reads as native.
        static let secondary = Color.adaptive(
            light: (0.44, 0.44, 0.45),
            dark: (0.70, 0.70, 0.72)
        )

        /// Decoration only: separators, chevrons, empty-state glyphs, the
        /// inactive half of a control. Never text a user has to read, and
        /// never the sole carrier of meaning — it measures below 2:1.
        static let faint = Color(nsColor: .tertiaryLabelColor)

        static let disabled = Color(nsColor: .disabledControlTextColor)
    }

    /// Status colours, darkened for light mode and lightened for dark so each
    /// clears 4.5:1 against its own surface in both.
    enum Status {
        static let success = Color.adaptive(
            light: (0.09, 0.47, 0.22),
            dark: (0.40, 0.82, 0.52)
        )

        /// Soft indicator tints for the sidebar's connection dots.
        ///
        /// These are non-text UI, so the floor is 3:1 rather than 4.5:1, which
        /// buys a lighter, friendlier tone than the text-grade `success` and
        /// `danger` above. The glyph still differs per state, so the colour is
        /// never the only signal.
        /// The lightest values that still clear 3:1 on white — a lighter
        /// green simply disappears against a light sidebar.
        static let onlineSoft = Color.adaptive(
            light: (0.16, 0.66, 0.33),
            dark: (0.44, 0.88, 0.58)
        )
        static let offlineSoft = Color.adaptive(
            light: (0.92, 0.38, 0.38),
            dark: (1.00, 0.56, 0.54)
        )
        // 4.69:1 on white. The obvious amber (0.69, 0.42, 0.01) measures
        // 4.24:1 — close enough to look fine and still fail the text floor.
        static let warning = Color.adaptive(
            light: (0.66, 0.39, 0.01),
            dark: (0.98, 0.76, 0.33)
        )
        static let danger = Color.adaptive(
            light: (0.75, 0.11, 0.11),
            dark: (1.00, 0.49, 0.47)
        )
        static let info = Color.accentColor
        static let idle = Ink.faint
    }
}

// MARK: - Reduced motion

private struct ReducedMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Mirrors the system "Reduce motion" setting.
    var reducedMotion: Bool {
        get { self[ReducedMotionKey.self] }
        set { self[ReducedMotionKey.self] = newValue }
    }
}

extension View {
    /// Applies an animation unless the user asked for less motion, in which
    /// case the view snaps to its final state instead.
    func motion(_ animation: Animation, reduced: Bool) -> some View {
        self.animation(reduced ? nil : animation, value: UUID())
    }
}

/// Reads the system "Reduce motion" setting and publishes it down the tree.
struct MotionReader: ViewModifier {
    @State private var reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private static let changes = NSWorkspace.shared.notificationCenter.publisher(
        for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
    )

    func body(content: Content) -> some View {
        content
            .environment(\.reducedMotion, reduced)
            .onReceive(Self.changes) { _ in
                reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
    }
}

extension View {
    /// Publishes the system reduce-motion setting to this subtree.
    func readsMotionPreference() -> some View {
        modifier(MotionReader())
    }
}

// MARK: - Shared controls

/// A toolbar / inline icon button.
///
/// Icon-only controls are the main accessibility hazard in a dense UI, so this
/// makes the right thing automatic: an accessibility label is required, the
/// pointer target is larger than the glyph, hover and pressed states animate
/// rather than snap, and focus is visible for keyboard users.
struct IconButton: View {
    let symbol: String
    /// Spoken by VoiceOver and shown in the tooltip. Required, not optional.
    let label: String
    var detail: String? = nil
    var size: CGFloat = Theme.Icon.md
    var isEnabled: Bool = true
    var isActive: Bool = false
    var role: ButtonRole? = nil
    let action: () -> Void

    @Environment(\.reducedMotion) private var reducedMotion
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                // A fixed box keeps the glyph from shifting neighbours when it
                // changes, and gives the pointer more than the glyph to hit.
                .frame(width: Theme.Icon.hitSize.width, height: Theme.Icon.hitSize.height)
                .foregroundStyle(foreground)
                .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .focusable(isEnabled)
        .focused($isFocused)
        .overlay {
            if isFocused, isEnabled {
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .accessibilityHidden(true)
            }
        }
        .onHover { hovering in
            guard isEnabled else { return }
            if reducedMotion {
                isHovering = hovering
            } else {
                withAnimation(Theme.Motion.hover) { isHovering = hovering }
            }
        }
        // `help` is the tooltip; `accessibilityLabel` is what VoiceOver reads.
        // A tooltip alone leaves keyboard and screen-reader users with nothing.
        .help(detail.map { "\(label) — \($0)" } ?? label)
        .accessibilityLabel(label)
        .accessibilityHint(detail ?? "")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private var foreground: Color {
        guard isEnabled else { return Theme.Ink.disabled }
        if role == .destructive { return Theme.Status.danger }
        return isActive ? Color.accentColor : Theme.Ink.primary
    }

    private var background: Color {
        guard isEnabled else { return .clear }
        if isActive { return Color.accentColor.opacity(isHovering ? 0.22 : 0.15) }
        return isHovering ? Color.primary.opacity(0.09) : .clear
    }
}

/// A status indicator that doesn't rely on colour alone.
///
/// A coloured dot is invisible to anyone who can't distinguish the hues, so the
/// shape carries the meaning too and the state is always available as text.
struct StatusIndicator: View {
    let status: ConnectionStatus
    var showsLabel = false

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: symbol)
                .font(.system(size: Theme.Icon.badge, weight: .bold))
                .foregroundStyle(tint)
            if showsLabel {
                Text(status.label)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Ink.secondary)
            }
        }
        .help(status.label)
        .accessibilityLabel("Connection status: \(status.label)")
    }

    private var symbol: String {
        switch status {
        case .idle: "circle.fill"
        case .connecting: "circle.dotted"
        case .connected: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    /// Green when the connection is live, soft red when it isn't. Connecting
    /// keeps amber so an in-progress attempt doesn't read as a failure.
    private var tint: Color {
        switch status {
        case .connected: Theme.Status.onlineSoft
        case .connecting: Theme.Status.warning
        case .idle, .failed: Theme.Status.offlineSoft
        }
    }
}

/// A count badge. The value is announced as a phrase, not a bare number.
struct CountBadge: View {
    let count: Int
    let noun: String
    var tint: Color = .accentColor

    var body: some View {
        Text("\(count)")
            .font(.system(size: Theme.Icon.badge, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint, in: Capsule())
            .accessibilityLabel("\(count) \(noun)")
    }
}

/// Section eyebrow used in the inspector and sheets.
struct Eyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Theme.Typo.eyebrow)
            .tracking(0.6)
            .foregroundStyle(Theme.Ink.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
