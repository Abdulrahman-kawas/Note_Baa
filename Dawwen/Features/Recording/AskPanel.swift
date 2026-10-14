import SwiftUI

/// Where the Ask AI panel sits while recording.
enum AskLayout {
    case hidden
    /// Shares the screen with the live transcript.
    case split
    /// A window over the screen that can be moved and resized.
    case floating
    /// Minimized to a button that can be dragged anywhere.
    case bubble
}

/// The Ask AI panel's title row while recording, with buttons to dock it beside the transcript,
/// float it over the screen, minimize it to a button, or close it.
struct AskPanelHeader: View {
    let isBusy: Bool
    /// Docked side by side rather than stacked, for the dock button's icon.
    let sideBySide: Bool
    @Binding var layout: AskLayout

    var body: some View {
        HStack(spacing: 18) {
            Label("Ask AI", systemImage: "sparkles")
                .font(.subheadline.bold())
            if isBusy { ProgressView().controlSize(.small) }
            Spacer(minLength: 8)
            if layout == .split {
                Button {
                    layout = .floating
                } label: {
                    Image(systemName: "pip.enter")
                        .accessibilityLabel("Float over the screen")
                }
            } else {
                Button {
                    layout = .split
                } label: {
                    Image(systemName: sideBySide ? "rectangle.split.2x1" : "rectangle.split.1x2")
                        .accessibilityLabel("Dock beside the transcript")
                }
            }
            Button {
                layout = .bubble
            } label: {
                Image(systemName: "minus.circle")
                    .accessibilityLabel("Minimize")
            }
            Button {
                layout = .hidden
            } label: {
                Image(systemName: "xmark.circle")
                    .accessibilityLabel("Close")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// Two panes, stacked or side by side, with a handle between them that changes how the space is
/// shared (a double tap evens it out). Without the second pane the first takes all the space, and it
/// keeps its state either way, such as how far it is scrolled.
struct SplitPanes<First: View, Second: View>: View {
    let sideBySide: Bool
    let showsSecond: Bool
    /// The first pane's share of the space.
    @Binding var fraction: CGFloat
    @ViewBuilder var first: First
    @ViewBuilder var second: Second

    @Environment(\.layoutDirection) private var layoutDirection
    @GestureState private var dragged: CGFloat = 0

    private static var handleThickness: CGFloat { 18 }

    var body: some View {
        GeometryReader { proxy in
            let total = max((sideBySide ? proxy.size.width : proxy.size.height) - Self.handleThickness, 1)
            let firstLength = showsSecond ? total * Self.clamped(fraction + dragged / total) : nil
            let layout = sideBySide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                first
                    .frame(width: sideBySide ? firstLength : nil, height: sideBySide ? nil : firstLength)
                if showsSecond {
                    handle(total: total)
                    second
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func handle(total: CGFloat) -> some View {
        // Side by side in a right-to-left layout the first pane is on the right, so dragging right shrinks it.
        let sign: CGFloat = sideBySide && layoutDirection == .rightToLeft ? -1 : 1
        func distance(_ value: DragGesture.Value) -> CGFloat {
            sign * (sideBySide ? value.translation.width : value.translation.height)
        }
        return Capsule()
            .fill(.secondary)
            .frame(width: sideBySide ? 5 : 36, height: sideBySide ? 36 : 5)
            .frame(width: sideBySide ? Self.handleThickness : nil, height: sideBySide ? nil : Self.handleThickness)
            .frame(maxWidth: sideBySide ? nil : .infinity, maxHeight: sideBySide ? .infinity : nil)
            .background(.bar)
            // A bigger target than it looks, reaching a little into both panes.
            .contentShape(Rectangle().inset(by: -10))
            .zIndex(1)
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .updating($dragged) { value, state, _ in state = distance(value) }
                    .onEnded { value in fraction = Self.clamped(fraction + distance(value) / total) }
            )
            .onTapGesture(count: 2) { fraction = 0.5 }
            .accessibilityElement()
            .accessibilityLabel("Divider")
            .accessibilityValue("\(Int((fraction * 100).rounded()))%")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: fraction = Self.clamped(fraction + 0.1)
                case .decrement: fraction = Self.clamped(fraction - 0.1)
                @unknown default: break
                }
            }
    }

    private static func clamped(_ fraction: CGFloat) -> CGFloat {
        min(max(fraction, 0.2), 0.8)
    }
}

/// A window over the screen. Drag its top bar to move it; drag the corner grip, or pinch, to resize
/// it. It stays inside `bounds`, which shrink while the keyboard is up, so its text field stays in view.
struct FloatingWindow<Header: View, Content: View>: View {
    @Binding var frame: CGRect
    let bounds: CGSize
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    @Environment(\.layoutDirection) private var layoutDirection
    @GestureState private var moved: CGSize = .zero
    @GestureState private var resized: CGSize = .zero
    @GestureState private var pinched: CGFloat = 1

    private static var minimumSize: CGSize { CGSize(width: 260, height: 240) }

    var body: some View {
        let shown = arranged(moved: moved, resized: resized, scaled: pinched)
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Capsule()
                    .fill(.tertiary)
                    .frame(width: 36, height: 5)
                    .padding(.top, 6)
                header
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .global)
                    .updating($moved) { value, state, _ in state = value.translation }
                    .onEnded { value in frame = arranged(moved: value.translation) }
            )
            Divider()
            content
        }
        .environment(\.layoutDirection, layoutDirection)
        .frame(width: shown.width, height: shown.height)
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color(.separator))
        }
        .overlay(alignment: .bottomTrailing) { grip }
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .simultaneousGesture(
            MagnifyGesture()
                .updating($pinched) { value, state, _ in state = value.magnification }
                .onEnded { value in frame = arranged(scaled: value.magnification) }
        )
        .offset(x: shown.minX, y: shown.minY)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Placed in screen terms: x grows to the right whatever the language. The content above keeps
        // the app's own direction.
        .environment(\.layoutDirection, .leftToRight)
    }

    private var grip: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .background(.thinMaterial, in: Circle())
            .overlay { Circle().strokeBorder(Color(.separator)) }
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
            // Half outside the corner, clear of the send button.
            .offset(x: 14, y: 14)
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .updating($resized) { value, state, _ in state = value.translation }
                    .onEnded { value in frame = arranged(resized: value.translation) }
            )
            .accessibilityLabel("Resize")
    }

    /// The window as shown: moved, resized from its corner, or scaled about its centre, then fitted.
    private func arranged(moved: CGSize = .zero, resized: CGSize = .zero, scaled: CGFloat = 1) -> CGRect {
        var result = Self.fitted(frame, in: bounds).offsetBy(dx: moved.width, dy: moved.height)
        result.size.width += resized.width
        result.size.height += resized.height
        if scaled != 1 {
            let width = result.width * scaled, height = result.height * scaled
            result = CGRect(x: result.midX - width / 2, y: result.midY - height / 2, width: width, height: height)
        }
        return Self.fitted(result, in: bounds)
    }

    /// At least the minimum size, no bigger than `bounds`, and fully inside them.
    private static func fitted(_ frame: CGRect, in bounds: CGSize) -> CGRect {
        let width = min(max(frame.width, minimumSize.width), bounds.width)
        let height = min(max(frame.height, minimumSize.height), bounds.height)
        return CGRect(x: min(max(frame.minX, 0), bounds.width - width),
                      y: min(max(frame.minY, 0), bounds.height - height),
                      width: width, height: height)
    }
}

/// The minimized panel: a button that can be dragged anywhere and settles against the nearest side.
/// A dot shows when an answer finished while it was minimized.
struct FloatingBubble: View {
    @Binding var center: CGPoint
    let bounds: CGSize
    let isBusy: Bool
    let hasNews: Bool
    let open: () -> Void

    @GestureState(resetTransaction: Transaction(animation: .spring(duration: 0.3)))
    private var dragged: CGSize = .zero

    private static var diameter: CGFloat { 56 }
    private static var margin: CGFloat { 12 }

    var body: some View {
        ZStack {
            Circle().fill(.tint)
            if isBusy {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .overlay(alignment: .topTrailing) {
            if hasNews {
                Circle()
                    .fill(.red)
                    .frame(width: 14, height: 14)
                    .overlay { Circle().stroke(.background, lineWidth: 2) }
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .contentShape(Circle())
        .onTapGesture(perform: open)
        .gesture(
            DragGesture(coordinateSpace: .global)
                .updating($dragged) { value, state, _ in state = value.translation }
                .onEnded { value in
                    let dropped = Self.fitted(CGPoint(x: center.x + value.translation.width,
                                                      y: center.y + value.translation.height), in: bounds)
                    let inset = Self.diameter / 2 + Self.margin
                    withAnimation(.spring(duration: 0.3)) {
                        center = CGPoint(x: dropped.x < bounds.width / 2 ? inset : bounds.width - inset, y: dropped.y)
                    }
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Ask AI")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .position(Self.fitted(CGPoint(x: center.x + dragged.width, y: center.y + dragged.height), in: bounds))
        .environment(\.layoutDirection, .leftToRight)
    }

    private static func fitted(_ point: CGPoint, in bounds: CGSize) -> CGPoint {
        let inset = diameter / 2 + margin
        return CGPoint(x: min(max(point.x, inset), max(bounds.width - inset, inset)),
                       y: min(max(point.y, inset), max(bounds.height - inset, inset)))
    }
}
