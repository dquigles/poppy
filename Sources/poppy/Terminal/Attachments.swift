import AppKit
import UniformTypeIdentifiers

/// Images and files going into the agent (DESIGN §9.10). Agents take an attachment as its
/// path: Claude Code and Codex attach an image when its path is pasted. So a clipboard
/// image or dropped image data is saved as a PNG, and every attachment becomes a
/// shell-escaped path, pasted like typed text.
enum Attachments {
    /// Where pasted/dropped images and screenshots are saved; per-user and private.
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("poppy-images")
    static let maxAge: TimeInterval = 7 * 24 * 3600

    static let dropTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .png, .tiff, .string] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    /// The text to paste for `pasteboard`: file paths for files, a saved PNG's path for image
    /// data, else nil (plain text is left to the normal paste). `completion` gets it on the
    /// main actor; file promises (e.g. the screenshot thumbnail, Mail attachments) arrive
    /// later, so it may be called asynchronously. Returns false if there's nothing to attach.
    @discardableResult
    static func text(from pasteboard: NSPasteboard, completion: @escaping @MainActor (String) -> Void) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            appLog("attachments: \(urls.count) file(s)")
            completion(pasteText(for: urls))
            return true
        }
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !promises.isEmpty, prepareDirectory() {
            appLog("attachments: \(promises.count) promised file(s)")
            receive(promises, completion: completion)
            return true
        }
        // Image data (a clipboard screenshot, "Copy Image", a dragged image), unless there's
        // text too (e.g. a dragged rich-text selection): then the text wins, as for ⌘V.
        if hasImageWithoutText(pasteboard), let url = saveImage(from: pasteboard) {
            completion(pasteText(for: [url]))
            return true
        }
        appLog("attachments: no file or image on the pasteboard")
        return false
    }

    /// The operation to show for a drag: copy if the source allows it, else whatever it
    /// allows (the screenshot thumbnail, for one, may offer only a move of its file).
    static func operation(for info: NSDraggingInfo) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        for op: NSDragOperation in [.copy, .generic, .link, .move] where mask.contains(op) { return op }
        return []
    }

    /// Logs what a drag carries (types and allowed operations), for diagnosing drops.
    static func logDrag(_ info: NSDraggingInfo, _ what: String) {
        let types = info.draggingPasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? "none"
        appLog("drop: \(what) ops=\(info.draggingSourceOperationMask.rawValue) types=[\(types)]")
    }

    /// True when a ⌘V should attach rather than paste text: files, or an image without text.
    static func hasAttachment(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || hasImageWithoutText(pasteboard)
    }

    private static func hasImageWithoutText(_ pasteboard: NSPasteboard) -> Bool {
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return pasteboard.availableType(from: [.png, .tiff]) != nil && text.isEmpty
    }

    /// Text safe to paste into the agent (DESIGN §9.10): no ESC or other control characters
    /// but tab and newline, so nothing can end a bracketed paste early (`ESC[201~`) and turn
    /// the rest into keystrokes; CR/CRLF become newlines.
    static func sanitized(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return String(String.UnicodeScalarView(normalized.unicodeScalars.filter { scalar in
            scalar == "\t" || scalar == "\n" || !(scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value))
        }))
    }

    /// Paths separated by spaces, each escaped the way Terminal does for a dropped file
    /// (backslash before shell-special characters), with a trailing space to keep typing.
    /// A path with a control character (e.g. a newline in a file name) is left out and
    /// logged: it can't be pasted as one argument.
    static func pasteText(for urls: [URL]) -> String {
        let paths = urls.map { (($0 as NSURL).filePathURL ?? $0).path }.filter { path in
            let ok = !path.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
            if !ok { appLog("attachments: skipped a path with control characters") }
            return ok
        }
        return paths.isEmpty ? "" : paths.map(escape).joined(separator: " ") + " "
    }

    static func escape(_ path: String) -> String {
        var result = ""
        for character in path {
            if " \\'\"`$&|;<>()[]{}*?!#~^".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// A new, unused file name in `directory`, e.g. "screenshot-20260929-171502.png".
    static func newImageURL(prefix: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        var url = directory.appendingPathComponent("\(prefix)-\(stamp).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(prefix)-\(stamp)-\(n).png")
            n += 1
        }
        return url
    }

    static func prepareDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            return true
        } catch {
            appLog("attachments: could not create \(directory.path): \(error)")
            return false
        }
    }

    /// Saves the pasteboard's image as PNG; nil if there's none or it can't be written.
    private static func saveImage(from pasteboard: NSPasteboard) -> URL? {
        guard prepareDirectory() else { return nil }
        let png: Data?
        if let data = pasteboard.data(forType: .png) {
            png = data
        } else if let tiff = pasteboard.data(forType: .tiff) {
            png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        } else {
            png = nil
        }
        guard let png else { return nil }
        let url = newImageURL(prefix: "image")
        do {
            try png.write(to: url, options: .atomic)
            appLog("attachments: saved \(url.lastPathComponent) (\(png.count / 1024) KB)")
            return url
        } catch {
            appLog("attachments: could not save image: \(error)")
            return nil
        }
    }

    /// Each drop's promised files go into their own folder (names can't collide, and they
    /// age from when they arrived, DESIGN §9.10).
    private static func receive(_ promises: [NSFilePromiseReceiver], completion: @escaping @MainActor (String) -> Void) {
        let destination = directory.appendingPathComponent("drop-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            appLog("attachments: could not create \(destination.path): \(error)")
            return
        }
        let queue = OperationQueue()
        let group = DispatchGroup()
        let collected = PromisedFiles()
        for promise in promises {
            group.enter()
            promise.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue,
                                         reader: PromisedFiles.reader(collecting: collected, group: group))
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                let urls = collected.urls
                if !urls.isEmpty { completion(pasteText(for: urls)) }
            }
        }
    }

    /// Deletes saved images and dropped-file folders that arrived over a week ago (by
    /// creation date: a promised file keeps its original modification date). At launch
    /// and on each agent start.
    static func removeOldFiles() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for file in files {
            let date = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            if Date().timeIntervalSince(date ?? .distantPast) > maxAge { try? FileManager.default.removeItem(at: file) }
        }
    }
}

/// URLs collected from promise callbacks on a background queue.
private nonisolated final class PromisedFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [URL] = []
    func append(_ url: URL) { lock.withLock { list.append(url) } }
    var urls: [URL] { lock.withLock { list } }

    /// Built outside the main actor: AppKit calls it on the operation queue, and a closure
    /// formed in main-actor code would trap there on Swift 6's isolation check.
    static func reader(collecting collected: PromisedFiles, group: DispatchGroup) -> @Sendable (URL, (any Error)?) -> Void {
        { url, error in
            if let error {
                appLog("attachments: promised file failed: \(error)")
            } else {
                collected.append(url)
            }
            group.leave()
        }
    }
}
