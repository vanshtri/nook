import AppKit
import Combine
import ImageIO
import Vision

/// One remembered thing: a piece of copied text or a screenshot.
struct Item: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case text, image }

    let id: UUID
    let kind: Kind
    var date: Date
    var text: String?        // copied text
    var imageFile: String?   // file name inside Store.imagesDir
    var ocr: String?         // recognised text for images (nil = not processed yet)
    var headline: String?    // best title line picked from the OCR (largest readable text)
    var source: String?      // app that was in front when it was copied or captured

    /// One-line title used in lists.
    var title: String {
        switch kind {
        case .text:
            let line = (text ?? "").components(separatedBy: .newlines)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            return String(line.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(140))
        case .image:
            if let h = headline, !h.isEmpty { return h }
            if ocr == nil { return "Reading screenshot…" }
            return "Screenshot"
        }
    }
}

/// Everything lives in ~/Library/Application Support/Nook. No network, no accounts.
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var items: [Item] = []
    @Published var paused = false

    let root: URL
    let imagesDir: URL
    private let indexURL: URL
    private let maxItems = 5000
    private let ioQueue = DispatchQueue(label: "nook.store.io", qos: .utility)
    private var saveWork: DispatchWorkItem?

    /// Pasteboard changeCount produced by our own "copy" so the watcher ignores it.
    var ownChangeCount = -1

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("Nook", isDirectory: true)
        imagesDir = root.appendingPathComponent("images", isDirectory: true)
        indexURL = root.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        load()
    }

    func imageURL(_ item: Item) -> URL? {
        item.imageFile.map { imagesDir.appendingPathComponent($0) }
    }

    // MARK: Adding

    func addText(_ s: String, source: String?) {
        guard !paused else { return }
        if let i = items.firstIndex(where: { $0.kind == .text && $0.text == s }) {
            var existing = items.remove(at: i)
            existing.date = Date()
            items.insert(existing, at: 0)
        } else {
            items.insert(Item(id: UUID(), kind: .text, date: Date(), text: s, source: source), at: 0)
        }
        trimAndSave()
    }

    /// Copies (or moves) an image file into the store and OCRs it in the background.
    @discardableResult
    func addImage(at url: URL, move: Bool, source: String?) -> Item? {
        guard !paused else { return nil }
        let id = UUID()
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let dest = imagesDir.appendingPathComponent("\(id.uuidString).\(ext)")
        do {
            if move { try FileManager.default.moveItem(at: url, to: dest) }
            else { try FileManager.default.copyItem(at: url, to: dest) }
        } catch {
            NSLog("Nook: could not store image: \(error)")
            return nil
        }
        return ingest(id: id, file: dest, source: source)
    }

    @discardableResult
    func addImage(pngData: Data, source: String?) -> Item? {
        guard !paused else { return nil }
        let id = UUID()
        let dest = imagesDir.appendingPathComponent("\(id.uuidString).png")
        guard (try? pngData.write(to: dest)) != nil else { return nil }
        return ingest(id: id, file: dest, source: source)
    }

    private func ingest(id: UUID, file: URL, source: String?) -> Item {
        let item = Item(id: id, kind: .image, date: Date(), imageFile: file.lastPathComponent, source: source)
        items.insert(item, at: 0)
        trimAndSave()
        runOCR(for: item)
        return item
    }

    private func runOCR(for item: Item) {
        guard let url = imageURL(item) else { return }
        OCR.recognize(url: url) { [weak self] text, headline in
            DispatchQueue.main.async {
                guard let self, let i = self.items.firstIndex(where: { $0.id == item.id }) else { return }
                self.items[i].ocr = text
                self.items[i].headline = headline ?? ""
                self.scheduleSave()
            }
        }
    }

    // MARK: Actions

    /// Puts the item back on the clipboard and moves it to the top.
    func copy(_ item: Item) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            pb.setString(item.text ?? "", forType: .string)
        case .image:
            // Offer PNG *and* TIFF: browsers / Electron apps paste PNG, older Cocoa apps want TIFF.
            if let url = imageURL(item), let data = try? Data(contentsOf: url),
               let rep = NSBitmapImageRep(data: data) {
                let png = url.pathExtension.lowercased() == "png"
                    ? data : rep.representation(using: .png, properties: [:])
                pb.declareTypes([.png, .tiff], owner: nil)
                if let png { pb.setData(png, forType: .png) }
                if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
            }
        }
        ownChangeCount = pb.changeCount
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            var moved = items.remove(at: i)
            moved.date = Date()
            items.insert(moved, at: 0)
            scheduleSave()
        }
    }

    func delete(_ item: Item) {
        if let url = imageURL(item) { try? FileManager.default.removeItem(at: url) }
        items.removeAll { $0.id == item.id }
        scheduleSave()
    }

    func clearAll() {
        for item in items { if let url = imageURL(item) { try? FileManager.default.removeItem(at: url) } }
        items.removeAll()
        scheduleSave()
    }

    /// Every word of the query must appear in the copied text or the OCR text.
    func search(_ query: String) -> [Item] {
        let tokens = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return items }
        return items.filter { item in
            let hay = (item.text ?? "") + "\n" + (item.ocr ?? "") + "\n" + (item.source ?? "")
            return tokens.allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// Something you can drag into Finder, Mail, Slack… as a real file or text.
    func dragProvider(_ item: Item) -> NSItemProvider {
        switch item.kind {
        case .text:
            return NSItemProvider(object: (item.text ?? "") as NSString)
        case .image:
            if let url = imageURL(item), let p = NSItemProvider(contentsOf: url) { return p }
            return NSItemProvider()
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([Item].self, from: data) else { return }
        items = decoded
        // Finish OCR for anything interrupted by a quit, and give older items a proper title.
        for item in items where item.kind == .image && (item.ocr == nil || item.headline == nil) { runOCR(for: item) }
    }

    private func trimAndSave() {
        if items.count > maxItems {
            for old in items[maxItems...] { if let url = imageURL(old) { try? FileManager.default.removeItem(at: url) } }
            items.removeLast(items.count - maxItems)
        }
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = items
        let url = indexURL
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
        saveWork = work
        ioQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

/// On-device text recognition with Apple's Vision framework.
enum OCR {
    /// Returns all recognised text plus a headline: the line most likely to be the title.
    static func recognize(url: URL, completion: @escaping (_ text: String, _ headline: String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { completion("", nil); return }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            do { try VNImageRequestHandler(cgImage: cg).perform([request]) } catch { NSLog("Nook: OCR failed: \(error)") }
            let observations = request.results ?? []
            let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            completion(text, headline(from: observations, imageHeight: CGFloat(cg.height)))
        }
    }

    /// Words that show up in menu bars and toolbars and make useless titles.
    private static let chrome: Set<String> = [
        "file", "edit", "view", "go", "window", "help", "history", "bookmarks", "format", "tools",
        "search", "all", "done", "cancel", "ok", "open", "close", "back", "forward", "share",
        "settings", "today", "new", "more", "menu", "home",
    ]

    /// Picks the biggest, cleanest line of text: usually a heading, window title or the key message.
    static func headline(from observations: [VNRecognizedTextObservation], imageHeight: CGFloat) -> String? {
        var best: (score: CGFloat, text: String)?
        for obs in observations {
            guard let cand = obs.topCandidates(1).first else { continue }
            let line = cand.string.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: " ›>·•|:;-–—_~"))
            let box = obs.boundingBox                    // normalised, origin bottom-left
            let letters = line.unicodeScalars.filter(CharacterSet.letters.contains).count
            let words: [String] = line.components(separatedBy: " ").filter { $0.count >= 2 }
            guard letters >= 4,
                  line.count <= 90,
                  Double(letters) / Double(max(line.count, 1)) >= 0.55,
                  words.count >= 2 || line.count >= 7,
                  !words.allSatisfy({ chrome.contains($0.lowercased()) })
            else { continue }
            // Skip the macOS menu bar strip on full-screen shots.
            if imageHeight > 700 && box.minY > 0.965 { continue }

            var score = box.height * CGFloat(cand.confidence)
            if words.count >= 3 { score *= 1.15 }
            if (12...70).contains(line.count) { score *= 1.1 }
            if line.first?.isUppercase == true { score *= 1.05 }
            // Text sliced by the crop edge ("y is about…", "a comm and…") makes a poor title.
            if line.first?.isLowercase == true { score *= 0.7 }
            if box.minX < 0.01 || box.maxX > 0.99 { score *= 0.7 }
            // Input placeholders and keyboard hints ("Type / for commands", "+ to send").
            if line.first.map({ !$0.isLetter && !$0.isNumber }) == true { score *= 0.75 }
            let lower = line.lowercased()
            if ["type ", "for commands", "to send", "press ", "search…", "search..."].contains(where: lower.contains) { score *= 0.5 }
            if best == nil || score > best!.score { best = (score, line) }
        }
        return best?.text
    }
}

/// Small downscaled previews, cached in memory.
enum Thumbs {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(for url: URL, maxPixel: Int = 480) -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}
