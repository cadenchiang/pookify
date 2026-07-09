import SwiftUI
import AppKit
import IslandCore

/// Root of the notch UI. Anchored flush to the top of the screen so it fuses with the physical
/// notch, easing in/out with the reveal transition.
struct IslandRootView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isVisible {
                IslandPill(model: model)
                    .transition(.notchReveal)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Open/close timing is driven per-direction from the controller (withAnimation) so the
        // retract can be slower than the emerge.
    }
}

/// Open/close motion: the slim bar grows out of the notch — its left and right edges sweep
/// outward from the camera — then settles. On close it retracts back into the notch. Anchored at
/// the top-center (the notch), it scales mostly horizontally so it reads like an iPhone Live
/// Activity appearing/disappearing.
private struct NotchReveal: ViewModifier {
    let progress: Double
    func body(content: Content) -> some View {
        // Pure horizontal scale, anchored at the notch — NO opacity fade. Fading a black pill over
        // the bright wallpaper turns it translucent-gray mid-animation (the "weird gray"); scaling
        // solid black into/out of the notch stays pure black the whole way.
        // Floor at 0.001, never 0: a zero scale is a singular transform, and the session stack's
        // NSScrollView asserts converting through its inverse (convertSizeFromBacking → abort).
        content
            .scaleEffect(x: max(0.001, progress), y: 1, anchor: .top)
    }
}
/// Close motion: the slim bar retracts into the notch the way it emerged — its left and right
/// edges sweep inward toward the camera. Pure horizontal scale: no vertical motion (nothing
/// "moves up"), no opacity fade, solid black the whole way. Safe because the hide path always
/// de-expands to the slim bar BEFORE this plays, so x-only never squishes a tall pill.
private struct NotchRetract: ViewModifier {
    let progress: Double   // 1 = full size, 0 = collapsed into the notch
    func body(content: Content) -> some View {
        // Same 0.001 floor as the reveal: never a singular (zero-scale) transform.
        content.scaleEffect(x: max(0.001, progress), y: 1, anchor: .top)
    }
}
extension AnyTransition {
    /// Per-direction timing attached to the transition itself (reliable, unlike withAnimation on a
    /// shared ObservableObject): a lively horizontal emerge, and a smooth scale-into-the-notch retract.
    static var notchReveal: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: NotchReveal(progress: 0), identity: NotchReveal(progress: 1))
                .animation(Theme.appear),
            removal: .modifier(active: NotchRetract(progress: 0), identity: NotchRetract(progress: 1))
                .animation(Theme.disappear)
        )
    }
}

/// The notch-fused black island.
///
/// - **Closed (slim):** balanced, symmetric wings — the agent glyph on the left of the camera and
///   the live timer on the right, the same size and distance so it reads perfectly centered on the
///   notch. No words here.
/// - **Expanded:** it grows **taller** (downward), never wider, so it never covers the menu bar.
///   The status wording ("Editing", "Awaiting permission", …) and a detail line drop in *below*
///   the notch. Pure flat black, no shadow — one object with the hardware.
struct IslandPill: View {
    @ObservedObject var model: IslandModel
    @State private var hoverWork: DispatchWorkItem?
    /// Which edges of the session stack currently hide rows — drives the edge fog.
    @State private var stackEdges = StackEdges(top: false, bottom: false)

    // Symmetric wing metrics — both sides identical so the camera gap is centered.
    private let wing: CGFloat = Theme.wing  // room for a 2-digit:2-digit clock (e.g. 15:48) with even margins
    private let iconSize: CGFloat = 18
    private let dropHeight: CGFloat = Theme.dropHeight
    // The notch shape's concave top corners inset each outer edge by ~topRadius, so content centered
    // in the raw wing lands a few px outside the visible black. Nudge each wing's content toward the
    // notch to optically center it in the area actually available beside the camera.
    private let wingInset: CGFloat = 4

    // `collapsing`/`opening` win over everything: while the island is being hidden OR emerging
    // it must present slim — it never retracts tall and never emerges tall.
    private var expanded: Bool {
        (model.hovering || model.isExpanded) && !model.collapsing && !model.opening
    }
    private var closedH: CGFloat { model.topInset }
    // The camera gap: the physical notch's width, or the synthetic notch's on displays
    // without one — the island renders identically either way.
    private var gap: CGFloat { model.notchWidth }
    private var closedWidth: CGFloat { wing + gap + wing }

    private func textWidth(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
    }
    private var labelW: CGFloat { textWidth(statusTitle, 13.5, .semibold) }

    // Width stays equal to the closed width on a notched Mac (so expanding never widens it). Only on
    // a non-notched display, where the gap is tiny, does it widen enough to fit the dropped-in label.
    // (The session stack lays out within the closed width, so it never asks for more.)
    private var pillWidth: CGFloat {
        expanded && !model.isMulti ? max(closedWidth, labelW + 40) : closedWidth
    }
    private var pillHeight: CGFloat { expanded ? closedH + model.dropHeight : closedH }

    var body: some View {
        let topR: CGFloat = 7
        let bottomR: CGFloat = expanded ? 14 : max(10, closedH * 0.40)
        let shape = NotchShape(topRadius: topR, bottomRadius: bottomR)

        ZStack(alignment: .top) {
            shape.fill(Theme.pill)
            VStack(spacing: 0) {
                notchRow
                    .frame(width: closedWidth, height: closedH)
                dropDown
                    .frame(height: model.dropHeight)
                    .opacity(expanded ? 1 : 0)
            }
        }
        .frame(width: pillWidth, height: pillHeight, alignment: .top)
        .clipShape(shape)
        .contentShape(shape)
        .onHover { isOver in
            hoverWork?.cancel()
            if isOver {
                // small intent delay so a passing pointer doesn't pop it open
                let work = DispatchWorkItem { model.hovering = true }
                hoverWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            } else {
                model.hovering = false
            }
        }
        .onTapGesture { model.onActivate?() }
        .contextMenu { menuItems }
        .animation(Theme.expand, value: expanded)
        .animation(Theme.expand, value: model.state)
        .animation(Theme.expand, value: model.showsTimer)
        .animation(Theme.expand, value: model.sessions.count)
    }

    // MARK: closed row (balanced, centered on the camera)

    private var notchRow: some View {
        HStack(spacing: 0) {
            // Left wing — the agent's mark, ALWAYS here, centered (never moves between states).
            // Animates while working; when the turn is done it rests on its fullest frame (a
            // complete spark next to the checkmark), never frozen mid-morph.
            AgentGlyph(provider: model.provider, claudeStyle: model.claudeStyle,
                       working: model.state.isWorking,
                       done: model.state == .done || model.state == .completed,
                       size: iconSize)
                .frame(width: iconSize, height: iconSize)
                .frame(width: wing, height: closedH)
                .offset(x: wingInset)                  // nudge toward the notch to optically center

            Color.clear.frame(width: gap, height: closedH)

            // Right wing — the status, centered to mirror the agent mark: timer while working,
            // a check when done, an amber dot for permission, a warning on error.
            rightStatus
                .frame(width: wing, height: closedH)
                .offset(x: -wingInset)                 // mirror nudge so the bar stays balanced
        }
    }

    @ViewBuilder private var rightStatus: some View {
        if model.isMulti {
            // With 2+ live sessions, show one status dot per session (colored by its state) next to
            // the total count — so you can see how many are running AND where each one is at a
            // glance: working (orange), compacting (violet), awaiting permission/error (amber), done
            // (green). Per-session timers live in the expanded stack; a single lead timer up here
            // would just read as wrong when several clocks are running.
            multiStatus
        } else if model.showsTimer {
            TimerText(startedAt: model.startedAt)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
        } else {
            switch model.state {
            case .permission:
                Circle().fill(Theme.amber).frame(width: 8, height: 8)
            case .done, .completed:
                // A finished session — a calm green check. "Done" reads green the whole time it's
                // on screen (no orange just-finished flash), matching the green Done in the stack.
                Image(systemName: "checkmark")
                    .font(.system(size: iconSize * 0.6, weight: .bold))
                    .foregroundStyle(Theme.green)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: iconSize * 0.6, weight: .semibold))
                    .foregroundStyle(Theme.amber)
            default:
                Color.clear
            }
        }
    }

    /// The collapsed multi-session indicator: a colored dot per session + the total count. The
    /// notch wing is narrow, so past `maxDots` sessions the dots cap (the count still reflects the
    /// true total) rather than overflow the bar. Dots follow the stack order (most urgent first).
    private var maxDots: Int { 5 }
    private var multiStatus: some View {
        HStack(spacing: 4) {
            HStack(spacing: 2.5) {
                ForEach(model.sessions.prefix(maxDots)) { s in
                    Circle()
                        .fill(Theme.stateDot(s.state, s.provider))
                        .frame(width: 5.5, height: 5.5)
                }
            }
            Text("\(model.sessions.count)")
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.95))
        }
        .lineLimit(1)
    }

    // MARK: drop-down (the taller part — words live here)

    /// One session: today's layout, untouched. Two or more: the session stack.
    @ViewBuilder private var dropDown: some View {
        if model.isMulti {
            sessionStack
        } else {
            singleDrop
        }
    }

    private var singleDrop: some View {
        VStack(spacing: 4) {
            if model.state.isWorking {
                // Live "AI shimmer" sweeping across the current activity word + dots. Compaction
                // shimmers in violet so the state reads as distinct from ordinary work.
                WorkingLabel(word: statusWord, tint: model.state == .compacting ? Theme.purple : .white)
            } else {
                Text(statusTitle)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(statusTitleColor)
                    .lineLimit(1)
            }
            Capsule()
                .fill(accentColor)
                .frame(width: 26, height: 2.5)
                .opacity(0.9)
            if !model.detail.isEmpty {
                Text(model.detail)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 5)
    }

    // MARK: session stack (2+ sessions — every session as a row, most urgent first)

    /// Three rows tall; with more sessions the list scrolls (trackpad/wheel) and half of the
    /// fourth row peeks out, fogged into the black — the scroll affordance. The fog lifts once
    /// you reach the bottom, and a matching fade appears at the top when rows sit above.
    ///
    /// At-edge detection reads the content's REAL frame in the scroll viewport (not computed
    /// heights, which can drift from layout by a pixel and leave the fog stuck on the last row):
    /// fog below only while the content's actual bottom edge lies past the viewport.
    @ViewBuilder private var sessionStack: some View {
        let scroll = ScrollView(.vertical) {
            VStack(spacing: Theme.sessionRowSpacing) {
                ForEach(model.sessions) { session in
                    SessionRow(session: session,
                               isDisplayed: session.id == model.displayedId,
                               select: { model.onSelectSession(session.id) })
                }
            }
            .padding(.horizontal, 6)   // slim insets: rows need every point of width
            .padding(.top, 7)
            .padding(.bottom, 0)       // last row sits flush against the pill's bottom edge
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)

        // Which edges hide rows right now. GeometryReader preferences CANNOT provide this on
        // macOS — they never re-collect across the NSScrollView bridge (they report zero, once)
        // — so use the purpose-built scroll-geometry API where available.
        if #available(macOS 15.0, *) {
            scroll
                .onScrollGeometryChange(for: StackEdges.self) { geo in
                    StackEdges(top: geo.contentOffset.y > 2,
                               bottom: geo.contentOffset.y + geo.containerSize.height
                                       < geo.contentSize.height - 2)
                } action: { _, edges in
                    stackEdges = edges
                }
                .mask(stackFog)
        } else {
            // macOS 14 has no reliable scroll-offset source: keep the fog on whenever the list
            // overflows. It can't lift at the very bottom there — a fair trade for correctness
            // everywhere else.
            scroll
                .onAppear { stackEdges = StackEdges(top: false, bottom: stackOverflows) }
                .onChange(of: model.sessions.count) { _, _ in
                    stackEdges = StackEdges(top: false, bottom: stackOverflows)
                }
                .mask(stackFog)
        }
    }

    private var stackOverflows: Bool { model.sessions.count > Theme.sessionRowsVisible }

    private var stackFog: some View {
        let viewH = model.dropHeight
        let fogTop = stackEdges.top
        let fogBottom = stackEdges.bottom
        return (
            // Content dissolves into the pill at whichever edge hides more rows — a deep fog,
            // no other chrome. Over pure black this reads as fog, not a hard clip. The bottom
            // band is tall enough to swallow the whole peeking row.
            LinearGradient(stops: [
                .init(color: .black.opacity(fogTop ? 0 : 1), location: 0),
                .init(color: .black, location: fogTop ? 18 / viewH : 0),
                .init(color: .black, location: fogBottom ? 1 - 32 / viewH : 1),
                // An eased midpoint makes the fog thicken fast: the peeking row reads as a
                // silhouette dissolving into the pill, not as dimmed-but-legible text.
                .init(color: .black.opacity(fogBottom ? 0.28 : 1), location: fogBottom ? 1 - 12 / viewH : 1),
                .init(color: .black.opacity(fogBottom ? 0 : 1), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .animation(.easeOut(duration: 0.18), value: fogTop)
            .animation(.easeOut(duration: 0.18), value: fogBottom)
        )
    }

    @ViewBuilder private var menuItems: some View {
        if let pin = model.pinnedId, model.isMulti {
            Button("Unpin — follow the busiest session") { model.onSelectSession(pin) }
            Divider()
        }
        Menu("Claude icon") {
            Button((model.claudeStyle == .spark ? "✓ " : "") + "Spark") { chooseStyle(.spark) }
            Button((model.claudeStyle == .crab ? "✓ " : "") + "Clawd (crab)") { chooseStyle(.crab) }
        }
        if NSScreen.screens.count > 1 {
            Menu("Display") {
                // Automatic owns the check whenever the preference isn't in effect — including a
                // saved display that's currently disconnected, so the menu never shows no choice.
                Button((NSScreen.preferredDisplayConnected ? "" : "✓ ") + "Automatic") { chooseDisplay(nil) }
                Divider()
                ForEach(NSScreen.screens, id: \.self) { screen in
                    if let id = screen.displayID {
                        Button((NSScreen.preferredDisplayID == id ? "✓ " : "") + screenLabel(screen)) {
                            chooseDisplay(id)
                        }
                    }
                }
            }
        }
        Divider()
        Button("Quit") { model.onQuit() }
    }

    /// A human-readable menu label for a display, marking the built-in (notched) and primary
    /// screens so identically-named externals stay distinguishable. (`screens.first` is the
    /// primary display — NSScreen.main is merely the one with keyboard focus, which changes
    /// with whatever app is frontmost.)
    private func screenLabel(_ screen: NSScreen) -> String {
        var name = screen.localizedName
        if screen.hasNotch { name += " (built-in)" }
        else if screen == NSScreen.screens.first { name += " (main)" }
        return name
    }

    private func chooseDisplay(_ id: CGDirectDisplayID?) {
        hoverWork?.cancel()
        model.hovering = false
        model.onChooseDisplay(id)
    }

    /// Apply a Claude icon choice and drop the hover state. Opening the context menu can swallow the
    /// pointer-exit event, leaving `hovering` stuck true (the pill stays expanded after the menu
    /// closes); clearing it here collapses the pill cleanly once you move away.
    private func chooseStyle(_ style: ClaudeStyle) {
        hoverWork?.cancel()
        model.hovering = false
        model.onChooseClaudeStyle(style)
    }

    private var accentColor: Color { Theme.stateDot(model.state, model.provider) }

    /// The finished "Done" title reads green (matching its check); permission/error stay amber;
    /// everything else is plain white.
    private var statusTitleColor: Color {
        switch model.state {
        case .done, .completed:   return Theme.green
        case .permission, .error: return Theme.amber
        default:                  return .white
        }
    }

    private var statusTitle: String {
        switch model.state {
        case .permission: return "Awaiting permission"
        case .done:       return "Done"
        case .completed:  return "Done"
        case .error:      return "Error"
        case .idle:       return "Idle"
        default:          return model.label.isEmpty ? "Working…" : model.label
        }
    }

    /// The working label with any trailing dots stripped (WorkingLabel adds its own animated ellipsis).
    private var statusWord: String {
        var w = statusTitle
        while let last = w.last, last == "…" || last == "." || last == " " { w.removeLast() }
        return w
    }
}

/// Which edges of the session stack currently hide rows beyond them.
private struct StackEdges: Equatable {
    var top: Bool
    var bottom: Bool
}

/// One session in the expanded stack: state dot · project · activity (+ file) · live timer.
/// Clicking a row pins that session to the island (clicking the pinned one unpins). The row's
/// own tap gesture wins over the pill's expand/collapse toggle, so selecting never collapses.
private struct SessionRow: View {
    let session: SessionInfo
    let isDisplayed: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(projectDisplay)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .layoutPriority(1)
            // Activity + file name: the file name is the informative part and must stay whole.
            // When both can't fit, the generic label ("Reading", "Editing") drops out entirely —
            // ViewThatFits, so it never leaves a truncated sliver behind. Only a truly long
            // file name ever truncates, and then in its middle so the extension survives.
            Group {
                if session.detail.isEmpty {
                    activityText
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 4) {
                            activityText
                            detailText
                        }
                        detailText
                    }
                }
            }
            // Must outrank the Spacer: at equal priority the spacer splits the free width with
            // the text group and the label truncates even when the row has room to spare.
            .layoutPriority(0.9)
            Spacer(minLength: 4)
            trailing
                .layoutPriority(1)
        }
        .padding(.horizontal, 8)
        .frame(height: Theme.sessionRowHeight)
        .background(
            // Hover-only highlight: no row is ever pre-selected (clicking a row navigates to its
            // terminal, it doesn't "select" it), so a persistent highlight just read as stuck. A
            // clear hover fill makes it obvious which row you're about to click.
            RoundedRectangle(cornerRadius: 8)
                .fill(.white.opacity(hovering ? 0.16 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var dotColor: Color { Theme.stateDot(session.state, session.provider) }

    private var activityText: some View {
        Text(activityWord)
            .font(.system(size: 10.5))
            .foregroundStyle(activityColor)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// "Done" reads green (matching its check); permission amber; other activity a dim white.
    private var activityColor: Color {
        switch session.state {
        case .done, .completed: return Theme.green
        case .permission:       return Theme.amber
        default:                return .white.opacity(0.52)
        }
    }

    private var detailText: some View {
        Text("· " + session.detail)
            .font(.system(size: 10.5))
            .foregroundStyle(.white.opacity(0.52))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// A pathological project (folder) name must not starve the whole row — cap it hard;
    /// normal repo names pass through untouched.
    private var projectDisplay: String {
        let p = session.project.isEmpty ? "session" : session.project
        return p.count > 20 ? p.prefix(19) + "…" : p
    }

    private var activityWord: String {
        switch session.state {
        case .permission: return "Awaiting permission"
        case .done:       return "Done"
        case .completed:  return "Done"
        case .error:      return "Error"
        default:          return session.label.isEmpty ? "Working…" : session.label
        }
    }

    /// Timer while the turn runs (it keeps counting through a permission wait, like the real turn
    /// clock); a check or warning for the transient end states.
    @ViewBuilder private var trailing: some View {
        if session.startedAt > 0 {
            TimerText(startedAt: session.startedAt)
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(session.state == .permission ? 0.55 : 0.8))
        } else if session.state == .done || session.state == .completed {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.green)
        } else if session.state == .error {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.amber)
        }
    }
}

/// The active-status word with a soft left-to-right "AI shimmer" (a bright band sweeps across the dim
/// text) plus an animated ellipsis. Driven from absolute time so the motion is smooth and continuous.
struct WorkingLabel: View {
    let word: String
    var tint: Color = .white

    var body: some View {
        // 30 updates/s is visually indistinguishable for a slow 2.6s shimmer sweep and gentle
        // dots, and far cheaper than the display-refresh-rate (up to 120Hz) default.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Text(word)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(1)
                .overlay(alignment: .trailing) {
                    // animated ellipsis just past the word, so the label width never jiggles
                    HStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle().frame(width: 2.6, height: 2.6).opacity(dotOpacity(t, i))
                        }
                    }
                    .offset(x: 13, y: 1)
                }
                .padding(.trailing, 15)   // reserve room for the dots
                .foregroundStyle(shimmer(t))
        }
    }

    private func dotOpacity(_ t: Double, _ i: Int) -> Double {
        let cycle = (t * 2.2).truncatingRemainder(dividingBy: 3.0)   // 0..3, one dot lights at a time
        return 0.2 + 0.8 * max(0, 1 - abs(cycle - Double(i)))
    }

    /// A dim gradient with a soft bright band whose center sweeps left→right and loops. Gentle:
    /// slow sweep and low contrast so it reads as a subtle shimmer, not a strobe.
    private func shimmer(_ t: Double) -> LinearGradient {
        let period = 2.6
        let p = (t.truncatingRemainder(dividingBy: period)) / period   // 0..1
        let c = p * 1.4 - 0.2                                            // band center: -0.2 … 1.2
        func loc(_ v: Double) -> Double { min(1, max(0, v)) }
        let dim = tint.opacity(0.62)
        let bright = tint.opacity(0.9)
        return LinearGradient(
            stops: [
                .init(color: dim,    location: 0),
                .init(color: dim,    location: loc(c - 0.3)),
                .init(color: bright, location: loc(c)),
                .init(color: dim,    location: loc(c + 0.3)),
                .init(color: dim,    location: 1),
            ],
            startPoint: .leading, endPoint: .trailing)
    }
}

/// Live elapsed clock, ticking each second. Never wraps (single line, monospaced).
struct TimerText: View {
    let startedAt: Double
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(elapsedString(Int(context.date.timeIntervalSince1970 - startedAt)))
        }
    }
}
