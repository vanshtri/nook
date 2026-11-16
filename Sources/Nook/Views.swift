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
    @StateObject private var box = Box<NSImage?>(nil)
    private var image: NSImage? { box.value }

    var body: some View {
        ZStack {
            Color.white.opacity(0.06)
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
        }
        .clipped()
        .task(id: url) {
            guard let url else { return }
            box.value = await Task.detached(priority: .utility) { Thumbs.image(for: url) }.value
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    var placeholder: String
    var autofocus = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.08)))
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

/// Black shape that grows out of the notch: square top, rounded bottom.
struct NotchShape: Shape {
    var radius: CGFloat = 24
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - radius), control: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    @ObservedObject var store: Store

    var body: some View {
        let results = Array(store.search(model.query).prefix(30))
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Nook").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                SearchField(text: $model.query, placeholder: "Search screenshots and copies")
                    .frame(maxWidth: 320)
                Spacer()
                if store.paused {
                    Label("Paused", systemImage: "pause.circle").font(.caption).foregroundStyle(.orange)
                }
            }
            if results.isEmpty {
                Text(model.query.isEmpty ? "Copy something or double-tap left ⌘ to capture." : "Nothing matches “\(model.query)”.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(results) { item in
                            ShelfCard(item: item)
                                .onTapGesture { store.copy(item); model.close() }
                                .onDrag { store.dragProvider(item) }
                                .contextMenu { itemContextMenu(item) }
                        }
                    }
                }
            }
        }
        .padding(.top, model.notchHeight + 6)
        .padding([.horizontal, .bottom], 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(NotchShape().fill(Color.black))
        .environment(\.colorScheme, .dark)
        .scaleEffect(x: model.open ? 1 : model.notchWidth / 700, y: model.open ? 1 : 0.15, anchor: .top)
        .opacity(model.open ? 1 : 0)
    }
}

struct ShelfCard: View {
    let item: Item
    @StateObject private var hover = Box(false)
    private var hovering: Bool { hover.value }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if item.kind == .image {
                    Thumb(url: Store.shared.imageURL(item))
                } else {
                    Text(item.text ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(7)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(Color.white.opacity(0.06))
                }
            }
            .frame(width: 150, height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(hovering ? 0.45 : 0.1)))

            HStack(spacing: 4) {
                Image(systemName: item.kind == .image ? "camera.viewfinder" : "doc.on.clipboard")
                Text(item.source ?? "").lineLimit(1)
                Spacer(minLength: 0)
                Text(timeFormatter.string(from: item.date))
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .frame(width: 150)
        }
        .onHover { hover.value = $0 }
    }
}

// MARK: - Memory panel

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var store: Store

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    var body: some View {
        let results = store.search(model.query)
        let index = Dictionary(uniqueKeysWithValues: results.enumerated().map { ($1.id, $0) })
        let groups = Dictionary(grouping: results) { Calendar.current.startOfDay(for: $0.date) }
            .sorted { $0.key > $1.key }

        VStack(spacing: 0) {
            HStack {
                SearchField(text: $model.query, placeholder: "Search everything you've copied or captured", autofocus: true)
                Text("\(results.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(14)
            Divider().opacity(0.4)

            if results.isEmpty {
                Text(model.query.isEmpty ? "Nothing yet." : "No matches.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2, pinnedViews: .sectionHeaders) {
                            ForEach(groups, id: \.key) { day, items in
                                Section {
                                    ForEach(items) { item in
                                        let i = index[item.id] ?? 0
                                        PanelRow(item: item, selected: i == model.selection, copied: model.copiedID == item.id)
                                            .id(item.id)
                                            .onTapGesture {
                                                model.selection = i
                                                Store.shared.copy(item)
                                                model.copiedID = item.id
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                                    model.copiedID = nil
                                                    model.close()
                                                }
                                            }
                                            .onDrag { store.dragProvider(item) }
                                            .contextMenu { itemContextMenu(item) }
                                    }
                                } header: {
                                    Text(dayLabel(day))
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 16).padding(.vertical, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(VisualEffect())
                                }
                            }
                        }
                        .padding(.bottom, 10)
                    }
                    .onChange(of: model.selection) { sel in
                        if results.indices.contains(sel) { proxy.scrollTo(results[sel].id) }
                    }
                    .onChange(of: model.query) { _ in model.selection = 0 }
                }
            }

            Divider().opacity(0.4)
            HStack(spacing: 14) {
                Text("↩ copy").foregroundStyle(.secondary)
                Text("↑↓ move").foregroundStyle(.secondary)
                Text("drag to export").foregroundStyle(.secondary)
                Spacer()
                Text("esc").foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
    }
}

struct PanelRow: View {
    let item: Item
    let selected: Bool
    let copied: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if item.kind == .image {
                    Thumb(url: Store.shared.imageURL(item))
                } else {
                    ZStack {
                        Color.white.opacity(0.06)
                        Image(systemName: "text.alignleft").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 72, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title.isEmpty ? " " : item.title)
                    .lineLimit(1)
                    .font(.system(size: 13))
                if item.kind == .text, let text = item.text, text.contains("\n") {
                    Text(text.components(separatedBy: .newlines).dropFirst().joined(separator: " "))
                        .lineLimit(1).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Image(systemName: item.kind == .image ? "camera.viewfinder" : "doc.on.clipboard")
                    Text(timeFormatter.string(from: item.date))
                    if let s = item.source { Text("· \(s)") }
                    if item.kind == .image && item.ocr == nil { Text("· reading text…") }
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if copied {
                Label("Copied", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.35) : .clear))
        .contentShape(Rectangle())
        .padding(.horizontal, 6)
    }
}
