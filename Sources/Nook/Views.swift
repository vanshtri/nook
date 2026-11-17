import AppKit
import SwiftUI

// MARK: - Shared bits

/// Tiny observable box. (@State is a compiler macro that only ships with full Xcode,
/// so the app uses this instead and builds with just the Command Line Tools.)
final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}

struct Thumb: View {
    let url: URL?
    var maxPixel: Int = 320
    var fill: Bool = true
    @StateObject private var box = Box<NSImage?>(nil)
    private var image: NSImage? { box.value }

    var body: some View {
        Group {
            if fill {
                ZStack {
                    Color.white.opacity(0.06)
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    }
                }
                .clipped()
            } else {
                ZStack {
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            guard let url else { return }
            let px = maxPixel
            box.value = await Task.detached(priority: .userInitiated) { Thumbs.image(for: url, maxPixel: px) }.value
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    var placeholder: String
    var autofocus = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.45))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(Capsule().fill(Color.white.opacity(focused ? 0.12 : 0.08)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(focused ? 0.16 : 0.06), lineWidth: 1))
        .onAppear { if autofocus { DispatchQueue.main.async { focused = true } } }
    }
}

private let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.timeStyle = .short
    f.dateStyle = .none
    return f
}()

private func itemContextMenu(_ item: Item) -> some View {
    Group {
        Button("Copy") { Store.shared.copy(item) }
        if let url = Store.shared.imageURL(item) {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Open") { NSWorkspace.shared.open(url) }
        }
        Divider()
        Button("Delete", role: .destructive) { Store.shared.delete(item) }
    }
}

// MARK: - Shelf

/// The shelf's outline: concave "shoulders" where it meets the top of the screen (like the
/// hardware notch), straight sides, and rounded bottom corners.
struct NotchShape: Shape {
    var bottomRadius: CGFloat = 24
    var shoulder: CGFloat = 12
    var closedTop = true

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in r: CGRect) -> Path {
        let s = min(shoulder, r.width / 4)
        let br = max(0, min(bottomRadius, (r.width - 2 * s) / 2, r.height - s))
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + s, y: r.minY + s), control: CGPoint(x: r.minX + s, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - br))
        p.addQuadCurve(to: CGPoint(x: r.minX + s + br, y: r.maxY), control: CGPoint(x: r.minX + s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - s - br, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - s, y: r.maxY - br), control: CGPoint(x: r.maxX - s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + s))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - s, y: r.minY))
        if closedTop { p.closeSubpath() }
        return p
    }
}

private let nookGreen = Color(red: 0.38, green: 0.84, blue: 0.58)

/// "now", "5m", "3h", "Yesterday", "Nov 12".
private func shortAgo(_ date: Date) -> String {
    let seconds = Date().timeIntervalSince(date)
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(Int(seconds / 60))m" }
    let cal = Calendar.current
    if cal.isDateInToday(date) { return "\(Int(seconds / 3600))h" }
    if cal.isDateInYesterday(date) { return "Yesterday" }
    return date.formatted(.dateTime.month(.abbreviated).day())
}

struct ShelfPillButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.85))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
            .contentShape(Capsule())
    }
}

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    @ObservedObject var store: Store
    private let shoulder: CGFloat = 12

    var body: some View {
        let open = model.open
        let radius: CGFloat = open ? 26 : 9
        ZStack(alignment: .top) {
            Color.black
            // Laid out at full size and revealed by the growing shape, so nothing reflows mid-animation.
            content
                .frame(width: model.width, height: model.height, alignment: .top)
                .opacity(open ? 1 : 0)
                .scaleEffect(open ? 1 : 0.94, anchor: .top)
        }
        .frame(width: open ? model.width : model.notchWidth + 2 * shoulder,
               height: open ? model.height : model.notchHeight,
               alignment: .top)
        .clipShape(NotchShape(bottomRadius: radius, shoulder: shoulder))
        .overlay(
            NotchShape(bottomRadius: radius, shoulder: shoulder, closedTop: false)
                .stroke(Color.white.opacity(open ? 0.09 : 0), lineWidth: 1)
        )
        .shadow(color: .black.opacity(open ? 0.55 : 0), radius: 24, y: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var content: some View {
        let results = Array(store.search(model.query).prefix(30))
        return VStack(alignment: .leading, spacing: 14) {
            header
            if results.isEmpty {
                emptyState
            } else {
                cards(results)
            }
        }
        .padding(.top, model.notchHeight + 8)
        .padding(.horizontal, shoulder + 18)
        .padding(.bottom, 16)
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                Text("Nook")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
            }
            if store.paused {
                Label("Paused", systemImage: "pause.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.16)))
            }
            Spacer()
            SearchField(text: $model.query, placeholder: "Search")
                .frame(width: 230)
            Button { model.openPanel() } label: {
                HStack(spacing: 5) {
                    Text("History")
                    Image(systemName: "arrow.up.right").font(.system(size: 9.5, weight: .bold))
                }
            }
            .buttonStyle(ShelfPillButton())
            .help("Open the full history (double-tap right ⌘)")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.query.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color.white.opacity(0.3))
            Text(model.query.isEmpty ? "Copy something, or double-tap left ⌘ to capture." : "No matches for “\(model.query)”")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cards(_ results: [Item]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(results) { item in
                    ShelfCard(item: item, copied: model.copiedID == item.id)
                        .onTapGesture { model.copy(item) }
                        .onDrag { store.dragProvider(item) }
                        .contextMenu { itemContextMenu(item) }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .padding(.horizontal, -6)
        // Soft edges instead of cards being chopped off.
        .mask(
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 8)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 44)
            }
        )
    }
}

struct ShelfCard: View {
    let item: Item
    let copied: Bool
    @StateObject private var hover = Box(false)
    private let size = CGSize(width: 156, height: 112)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 7) {
            preview
                .frame(width: size.width, height: size.height)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.white.opacity(hover.value ? 0.3 : 0.09), lineWidth: 1))
                .overlay {
                    if copied {
                        ZStack {
                            shape.fill(Color.black.opacity(0.6))
                            VStack(spacing: 5) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 26))
                                    .foregroundStyle(nookGreen)
                                Text("Copied")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Color.white)
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }
                }
                .shadow(color: .black.opacity(hover.value ? 0.5 : 0), radius: 10, y: 5)
            HStack(spacing: 5) {
                AppBadge(name: item.source, size: 12,
                         fallback: item.kind == .image ? "camera.viewfinder" : "doc.on.clipboard")
                Text(item.source ?? (item.kind == .image ? "Screenshot" : "Copied")).lineLimit(1)
                Spacer(minLength: 4)
                Text(shortAgo(item.date)).fixedSize()
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Color.white.opacity(0.5))
            .frame(width: size.width)
        }
        .scaleEffect(hover.value ? 1.035 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hover.value)
        .onHover { hover.value = $0 }
    }

    @ViewBuilder private var preview: some View {
        if item.kind == .image {
            Thumb(url: Store.shared.imageURL(item), maxPixel: 360)
        } else {
            textPreview
        }
    }

    @ViewBuilder private var textPreview: some View {
        let kind = item.textKind
        let text = String((item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
        if kind == .color, let c = parseHexColor(text) {
            let light = (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) > 0.6
            Color(red: c.r, green: c.g, blue: c.b, opacity: c.a)
                .overlay(alignment: .bottomLeading) {
                    Text(text.uppercased())
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(light ? Color.black.opacity(0.75) : Color.white)
                        .padding(10)
                }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(kind.tint)
                switch kind {
                case .link:
                    Text(URL(string: text)?.host ?? text)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.95))
                        .lineLimit(2)
                    Text(text)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .lineLimit(3)
                case .code:
                    Spacer(minLength: 0)
                    Text(text)
                        .font(.system(size: 19, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.95))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                case .snippet:
                    Text(text)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(6)
                default:
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .lineLimit(5)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                LinearGradient(colors: [kind.tint.opacity(0.10), Color(white: 0.09)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        }
    }
}

// MARK: - Memory panel

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// What a piece of copied text looks like, for icons and previews.
enum TextKind {
    case link, color, snippet, code, email, text

    var symbol: String {
        switch self {
        case .link: return "link"
        case .color: return "paintpalette.fill"
        case .snippet: return "chevron.left.forwardslash.chevron.right"
        case .code: return "number"
        case .email: return "envelope.fill"
        case .text: return "text.alignleft"
        }
    }

    var tint: Color {
        switch self {
        case .link: return Color(red: 0.40, green: 0.65, blue: 1.00)
        case .color: return Color(red: 1.00, green: 0.50, blue: 0.70)
        case .snippet: return Color(red: 0.72, green: 0.56, blue: 1.00)
        case .code: return Color(red: 1.00, green: 0.66, blue: 0.32)
        case .email: return Color(red: 0.38, green: 0.84, blue: 0.58)
        case .text: return Color(white: 0.78)
        }
    }

    var label: String {
        switch self {
        case .link: return "Link"
        case .color: return "Color"
        case .snippet: return "Snippet"
        case .code: return "Code"
        case .email: return "Email"
        case .text: return "Text"
        }
    }
}

extension Item {
    var textKind: TextKind {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ pattern: String) -> Bool { t.range(of: pattern, options: .regularExpression) != nil }
        if matches(#"^https?://\S+$"#) { return .link }
        if matches(#"^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"#) { return .color }
        if matches(#"^[^\s@]+@[^\s@]+\.[A-Za-z]{2,}$"#) { return .email }
        if t.count <= 32, t.contains(where: { $0.isNumber }), matches(#"^[A-Za-z0-9][A-Za-z0-9._:+/-]*$"#) { return .code }
        let commands = ["git ", "npm ", "npx ", "yarn ", "pnpm ", "brew ", "cd ", "ls ", "curl ", "sudo ", "docker ",
                        "python ", "python3 ", "pip ", "swift ", "make ", "$ ", "./"]
        if commands.contains(where: { t.hasPrefix($0) }) { return .snippet }
        let signals = ["{", "}", "=>", "();", "</", "/>", "func ", "const ", "let ", "def ", "import ", "return "]
        if signals.contains(where: { t.contains($0) }) { return .snippet }
        return .text
    }
}

/// Parses "#RGB", "#RRGGBB" or "#RRGGBBAA".
func parseHexColor(_ s: String) -> (r: Double, g: Double, b: Double, a: Double)? {
    var h = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard h.hasPrefix("#") else { return nil }
    h.removeFirst()
    if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
    guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
    if h.count == 6 {
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255, 1)
    }
    return (Double((v >> 24) & 0xFF) / 255, Double((v >> 16) & 0xFF) / 255,
            Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
}

/// Finds an app's icon from its display name ("Claude", "System Settings"…).
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    private static var misses = Set<String>()

    static func icon(for name: String?) -> NSImage? {
        guard let name, !name.isEmpty else { return nil }
        if let hit = cache[name] { return hit }
        if misses.contains(name) { return nil }
        var found: NSImage?
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            found = app.icon
        } else {
            let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                           NSHomeDirectory() + "/Applications", "/System/Library/CoreServices/Applications"]
            for folder in folders {
                let path = "\(folder)/\(name).app"
                if FileManager.default.fileExists(atPath: path) {
                    found = NSWorkspace.shared.icon(forFile: path)
                    break
                }
            }
        }
        if let found { cache[name] = found } else { misses.insert(name) }
        return found
    }
}

private func friendlyDate(_ date: Date) -> String {
    let cal = Calendar.current
    let time = timeFormatter.string(from: date)
    if cal.isDateInToday(date) { return "Today at \(time)" }
    if cal.isDateInYesterday(date) { return "Yesterday at \(time)" }
    return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " at \(time)"
}

/// Square tile: a screenshot thumbnail, a colour swatch, or a tinted icon for the kind of text.
struct ItemTile: View {
    let item: Item
    var size: CGFloat = 36

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        content
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
    }

    @ViewBuilder private var content: some View {
        if item.kind == .image {
            Thumb(url: Store.shared.imageURL(item), maxPixel: 160)
        } else if item.textKind == .color, let c = parseHexColor(item.text ?? "") {
            Color(red: c.r, green: c.g, blue: c.b, opacity: c.a)
        } else {
            let kind = item.textKind
            ZStack {
                kind.tint.opacity(0.16)
                Image(systemName: kind.symbol)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(kind.tint)
            }
        }
    }
}

struct AppBadge: View {
    let name: String?
    var size: CGFloat = 13
    var fallback = "app.dashed"

    var body: some View {
        if let icon = AppIcons.icon(for: name) {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: fallback)
                .font(.system(size: size * 0.78, weight: .medium))
                .frame(width: size, height: size)
        }
    }
}

struct PillButton: ButtonStyle {
    var prominent = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return configuration.label
            .font(.system(size: 12, weight: .medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .foregroundStyle(destructive ? Color(red: 1, green: 0.45, blue: 0.45) : Color.white.opacity(prominent ? 1 : 0.88))
            .background(shape.fill(prominent ? Color.accentColor : Color.white.opacity(configuration.isPressed ? 0.16 : 0.09)))
            .overlay(shape.strokeBorder(Color.white.opacity(prominent ? 0.18 : 0.07), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(shape)
    }
}

struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.75))
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 17)
                .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(Color.white.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 4.5, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(0.45))
        }
    }
}

struct FilterChips: View {
    @Binding var selection: PanelFilter
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelFilter.allCases, id: \.self) { filter in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { selection = filter }
                } label: {
                    Text(filter.rawValue)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(selection == filter ? 0.95 : 0.5))
                        .padding(.horizontal, 10).padding(.vertical, 4.5)
                        .background {
                            if selection == filter {
                                Capsule().fill(Color.white.opacity(0.14))
                                    .matchedGeometryEffect(id: "chip", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2.5)
        .background(Capsule().fill(Color.black.opacity(0.25)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var store: Store
    @FocusState private var searchFocused: Bool

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    var body: some View {
        let results = model.results()
        let selected = results.indices.contains(model.selection) ? results[model.selection] : results.first

        VStack(spacing: 0) {
            header
            hairline
            if results.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    list(results).frame(width: 316)
                    Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
                    ZStack {
                        if let selected {
                            PreviewPane(item: selected, model: model)
                                .id(selected.id)
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            hairline
            footer(canCopyText: selected.map { $0.kind == .image && !($0.ocr ?? "").isEmpty } ?? false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                VisualEffect(material: .hudWindow)
                Color.black.opacity(0.2)
                LinearGradient(colors: [Color.white.opacity(0.06), .clear], startPoint: .top, endPoint: .center)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.13), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .scaleEffect(model.appeared ? 1 : 0.965)
        .opacity(model.appeared ? 1 : 0)
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
        .onChange(of: model.focusToken) { _ in DispatchQueue.main.async { searchFocused = true } }
        .onChange(of: model.query) { _ in model.selection = 0 }
        .onChange(of: model.filter) { _ in model.selection = 0 }
    }

    private var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.45))
            TextField("Search screenshots and copies…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($searchFocused)
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
            FilterChips(selection: $model.filter)
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    private var emptyTitle: String {
        switch model.filter {
        case .all: return "Nothing remembered yet"
        case .screenshots: return "No screenshots yet"
        case .text: return "No copied text yet"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: model.query.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.white.opacity(0.25))
            Text(model.query.isEmpty ? emptyTitle : "No matches for “\(model.query)”")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.6))
            if model.query.isEmpty {
                Text("Copy something, or double-tap left ⌘ to capture an area.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
        }
    }

    private func list(_ results: [Item]) -> some View {
        let index = Dictionary(uniqueKeysWithValues: results.enumerated().map { ($1.id, $0) })
        let groups = Dictionary(grouping: results) { Calendar.current.startOfDay(for: $0.date) }
            .sorted { $0.key > $1.key }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    Color.clear.frame(height: 0).id("top")
                    ForEach(groups, id: \.key) { day, items in
                        Section {
                            ForEach(items) { item in
                                let i = index[item.id] ?? 0
                                PanelRow(item: item, selected: i == model.selection, copied: model.copiedID == item.id)
                                    .id(item.id)
                                    .gesture(TapGesture(count: 2).onEnded { model.copyAndClose(item) })
                                    .simultaneousGesture(TapGesture().onEnded {
                                        withAnimation(.easeOut(duration: 0.12)) { model.selection = i }
                                    })
                                    .onDrag { store.dragProvider(item) }
                                    .contextMenu { itemContextMenu(item) }
                            }
                        } header: {
                            Text(dayLabel(day).uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.7)
                                .foregroundStyle(Color.white.opacity(0.35))
                                .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            // Items added while the panel was hidden push the list down (macOS keeps existing rows in
            // place), so always start from the top when it opens or the results change.
            .onChange(of: model.focusToken) { _ in proxy.scrollTo("top", anchor: .top) }
            .onChange(of: model.query) { _ in proxy.scrollTo("top", anchor: .top) }
            .onChange(of: model.filter) { _ in proxy.scrollTo("top", anchor: .top) }
            .onChange(of: model.selection) { sel in
                if sel == 0 { proxy.scrollTo("top", anchor: .top) }
                else if results.indices.contains(sel) { proxy.scrollTo(results[sel].id) }
            }
        }
    }

    private func footer(canCopyText: Bool) -> some View {
        HStack(spacing: 16) {
            if let toast = model.toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color(red: 0.38, green: 0.84, blue: 0.58))
                    .transition(.opacity)
            } else {
                KeyHint(keys: "↑↓", label: "Navigate")
                KeyHint(keys: "↩", label: "Copy")
                if canCopyText { KeyHint(keys: "⇧↩", label: "Copy text") }
                KeyHint(keys: "⇥", label: "Filter")
            }
            Spacer()
            KeyHint(keys: "esc", label: model.query.isEmpty ? "Close" : "Clear")
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }
}

struct PanelRow: View {
    let item: Item
    let selected: Bool
    let copied: Bool
    @StateObject private var hover = Box(false)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 11) {
            ItemTile(item: item, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title.isEmpty ? "Untitled" : item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.93))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    AppBadge(name: item.source, size: 12,
                             fallback: item.kind == .image ? "camera.viewfinder" : "doc.on.clipboard")
                    Text(item.source ?? (item.kind == .image ? "Screenshot" : "Copied")).lineLimit(1)
                    Text("·")
                    Text(timeFormatter.string(from: item.date)).fixedSize()
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.45))
            }
            Spacer(minLength: 0)
            if copied {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(red: 0.38, green: 0.84, blue: 0.58))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(shape.fill(Color.white.opacity(selected ? 0.11 : (hover.value ? 0.05 : 0))))
        .overlay(shape.strokeBorder(Color.white.opacity(selected ? 0.07 : 0), lineWidth: 1))
        .contentShape(shape)
        .onHover { hover.value = $0 }
        .padding(.horizontal, 8)
    }
}

/// Right-hand side of the panel: a big look at the selected item and what you can do with it.
struct PreviewPane: View {
    let item: Item
    @ObservedObject var model: PanelModel
    private let well = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            media
            VStack(alignment: .leading, spacing: 7) {
                Text(heading)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .lineLimit(2)
                meta
            }
            if item.kind == .image, let ocr = item.ocr, !ocr.isEmpty {
                recognised(ocr)
            }
            Spacer(minLength: 0)
            actions
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var heading: String {
        if item.kind == .image { return item.title.isEmpty ? "Screenshot" : item.title }
        return item.textKind.label
    }

    @ViewBuilder private var media: some View {
        if item.kind == .image {
            Thumb(url: Store.shared.imageURL(item), maxPixel: 1400, fill: false)
                .padding(10)
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .background(well.fill(Color.black.opacity(0.28)))
                .overlay(well.strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
                .onDrag { Store.shared.dragProvider(item) }
        } else {
            textMedia
        }
    }

    @ViewBuilder private var textMedia: some View {
        let text = String((item.text ?? "").prefix(20_000))
        switch item.textKind {
        case .color:
            if let c = parseHexColor(text) {
                let light = (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) > 0.6
                well.fill(Color(red: c.r, green: c.g, blue: c.b, opacity: c.a))
                    .frame(height: 160)
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
                                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                            Text("RGB \(Int(c.r * 255)) \(Int(c.g * 255)) \(Int(c.b * 255))")
                                .font(.system(size: 12, design: .monospaced))
                                .opacity(0.75)
                        }
                        .foregroundStyle(light ? Color.black.opacity(0.8) : Color.white)
                        .padding(14)
                    }
                    .overlay(well.strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            }
        case .link:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "globe").foregroundStyle(TextKind.link.tint)
                    Text(URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? text)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.95))
                        .lineLimit(1)
                }
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .textSelection(.enabled)
                    .lineLimit(6)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(well.fill(Color.black.opacity(0.28)))
            .overlay(well.strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        case .code:
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.95))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .frame(height: 130)
                .background(well.fill(Color.black.opacity(0.28)))
                .overlay(well.strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        default:
            ScrollView {
                Text(text)
                    .font(item.textKind == .snippet ? .system(size: 12.5, design: .monospaced) : .system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(Color.white.opacity(0.88))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(height: 220)
            .background(well.fill(Color.black.opacity(0.28)))
            .overlay(well.strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        }
    }

    private var meta: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                AppBadge(name: item.source, size: 14,
                         fallback: item.kind == .image ? "camera.viewfinder" : "doc.on.clipboard")
                Text(item.source ?? (item.kind == .image ? "Screenshot" : "Clipboard"))
            }
            Label(friendlyDate(item.date), systemImage: "clock")
            if item.kind == .image, let url = Store.shared.imageURL(item), let px = Thumbs.pixelSize(for: url) {
                let dims = "\(Int(px.width)) × \(Int(px.height))"
                Label(dims, systemImage: "aspectratio")
            } else if item.kind == .text {
                let count = (item.text ?? "").count
                Label("\(count) character\(count == 1 ? "" : "s")", systemImage: "character.cursor.ibeam")
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Color.white.opacity(0.5))
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
    }

    private func recognised(_ ocr: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TEXT IN SCREENSHOT")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Color.white.opacity(0.35))
            ScrollView {
                Text(ocr)
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .foregroundStyle(Color.white.opacity(0.7))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 96)
            .mask(
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 22)
                }
            )
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { model.copyAndClose(item) } label: { Label("Copy", systemImage: "doc.on.doc") }
                .buttonStyle(PillButton(prominent: true))
            if item.kind == .image {
                if let ocr = item.ocr, !ocr.isEmpty {
                    Button { model.copyTextAndClose(item, ocr) } label: { Label("Copy Text", systemImage: "text.viewfinder") }
                        .buttonStyle(PillButton())
                }
                if let url = Store.shared.imageURL(item) {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                        .buttonStyle(PillButton())
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                        .buttonStyle(PillButton())
                        .help("Show in Finder")
                }
            } else if item.textKind == .link,
                      let url = URL(string: (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) {
                Button { NSWorkspace.shared.open(url) } label: { Label("Open Link", systemImage: "safari") }
                    .buttonStyle(PillButton())
            }
            Spacer(minLength: 0)
            Button { Store.shared.delete(item) } label: { Image(systemName: "trash") }
                .buttonStyle(PillButton(destructive: true))
                .help("Delete")
        }
    }
}
