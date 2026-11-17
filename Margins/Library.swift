import SwiftUI
import AppKit
import PDFKit

/// All books, highlights and progress. Stored as one JSON file in
/// ~/Library/Application Support/Margins — nothing leaves this Mac.
@Observable
final class Library {
    var books: [Book] = []

    /// Set when library.json exists but couldn't be read. While it's set the
    /// app writes nothing, so the file on disk stays exactly as it was.
    private(set) var loadProblem: String?
    var isReadOnly: Bool { loadProblem != nil }

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    /// How many books the file on disk holds; used to refuse accidental wipes.
    @ObservationIgnored private var savedBookCount = 0
    /// Only a real delete may shrink the library to zero books.
    @ObservationIgnored private var allowEmptySave = false

    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Margins", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static var indexURL: URL { root.appendingPathComponent("library.json") }
    /// The version of library.json from just before the latest save.
    private static var previousURL: URL { root.appendingPathComponent("library.previous.json") }
    /// One copy per day, plus copies made by install.sh and of unreadable files.
    static var backupsURL: URL { root.appendingPathComponent("Backups", isDirectory: true) }
    private static let dailyBackupsToKeep = 60

    /// Held for as long as this copy of Margins runs, so two copies can't save over each other.
    @ObservationIgnored private var lockFD: Int32 = -1

    init() {
        if acquireLock() {
            load()
        } else {
            loadProblem = "Margins is already open in another window or copy. "
                + "This one is read-only so the two can't overwrite each other's notes. Close it and use the other one."
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.saveNow()
        }
    }

    /// False when another running copy of Margins already holds the library.
    private func acquireLock() -> Bool {
        let path = Self.root.appendingPathComponent(".lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        lockFD = fd
        return true
    }

    // MARK: Paths

    func directory(for id: UUID) -> URL {
        Self.root.appendingPathComponent("Books/\(id.uuidString)", isDirectory: true)
    }

    func fileURL(for book: Book) -> URL {
        directory(for: book.id).appendingPathComponent("book.\(book.kind.rawValue)")
    }

    func epubRoot(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("epub", isDirectory: true)
    }

    func coverURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("cover")
    }

    func cover(for book: Book) -> NSImage? {
        NSImage(contentsOf: coverURL(for: book.id))
    }

    // MARK: Reading and writing

    func book(_ id: UUID) -> Book? {
        books.first { $0.id == id }
    }

    func update(_ id: UUID, _ change: (inout Book) -> Void) {
        guard !isReadOnly, let index = books.firstIndex(where: { $0.id == id }) else { return }
        change(&books[index])
        scheduleSave()
    }

    func updateHighlight(_ id: UUID, in bookID: UUID, _ change: (inout Highlight) -> Void) {
        update(bookID) { book in
            guard let index = book.highlights.firstIndex(where: { $0.id == id }) else { return }
            change(&book.highlights[index])
        }
    }

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.indexURL.path) else {
            // First launch is fine. But if backups exist, the file went missing:
            // don't start an empty library on top of that.
            if let latest = Self.latestBackup() {
                loadProblem = "library.json is missing, but backups exist. Nothing will be saved until it's restored. "
                    + "Copy \(latest.lastPathComponent) from the Backups folder to library.json, then reopen Margins."
            }
            return
        }
        do {
            let data = try Data(contentsOf: Self.indexURL)
            books = try Self.decode(data)
            savedBookCount = books.count
            makeDailyBackup()
        } catch {
            books = []
            loadProblem = "This version of Margins couldn't read library.json, so it isn't touching it. "
                + "Your books, notes and progress are still in the file. Nothing will be saved until this is fixed.\n\n"
                + "Details: \(error)"
            keepCopy(of: Self.indexURL, named: "unreadable")
        }
    }

    static func decode(_ data: Data) throws -> [Book] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Book].self, from: data)
    }

    private func scheduleSave() {
        guard !isReadOnly else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            await MainActor.run { self?.saveNow() }
        }
    }

    func saveNow() {
        // 1. Never write after a failed load.
        guard !isReadOnly else { return }
        // 2. Never replace a non-empty library with an empty one unless the user deleted the last book.
        if books.isEmpty && savedBookCount > 0 && !allowEmptySave { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(books) else { return }
        // 3. Only write what this build can read back in full.
        guard let check = try? Self.decode(data), check.count == books.count else { return }

        // 4. Keep the version being replaced, then write atomically.
        let fm = FileManager.default
        if fm.fileExists(atPath: Self.indexURL.path) {
            try? fm.removeItem(at: Self.previousURL)
            try? fm.copyItem(at: Self.indexURL, to: Self.previousURL)
        }
        do {
            try data.write(to: Self.indexURL, options: .atomic)
            savedBookCount = books.count
            allowEmptySave = false
        } catch {
            print("Margins: couldn't save library: \(error)")
        }
    }

    // MARK: Backups

    private func makeDailyBackup() {
        guard !books.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.backupsURL, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let target = Self.backupsURL.appendingPathComponent("library-\(formatter.string(from: Date())).json")
        if !fm.fileExists(atPath: target.path) {
            try? fm.copyItem(at: Self.indexURL, to: target)
        }
        // Prune only the daily copies; install and unreadable copies are kept.
        let files = (try? fm.contentsOfDirectory(at: Self.backupsURL, includingPropertiesForKeys: nil)) ?? []
        let daily = files
            .filter { $0.lastPathComponent.hasPrefix("library-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in daily.dropFirst(Self.dailyBackupsToKeep) {
            try? fm.removeItem(at: old)
        }
    }

    private func keepCopy(of url: URL, named label: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.backupsURL, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let target = Self.backupsURL.appendingPathComponent("\(label)-\(formatter.string(from: Date())).json")
        try? fm.copyItem(at: url, to: target)
    }

    private static func latestBackup() -> URL? {
        let key = URLResourceKey.contentModificationDateKey
        let files = (try? FileManager.default.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: [key])) ?? []
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [key]).contentModificationDate) ?? .distantPast
        }
        return files.filter { $0.pathExtension == "json" }.max { modified($0) < modified($1) }
    }

    // MARK: Import and delete

    @discardableResult
    func importFile(_ source: URL) -> Bool {
        guard !isReadOnly else { return false }
        let ext = source.pathExtension.lowercased()
        guard let kind = BookKind(rawValue: ext) else { return false }

        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        var book = Book(title: source.deletingPathExtension().lastPathComponent, kind: kind)
        let dir = directory(for: book.id)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: fileURL(for: book))
        } catch {
            return false
        }

        switch kind {
        case .pdf:
            guard let document = PDFDocument(url: fileURL(for: book)) else {
                try? fm.removeItem(at: dir)
                return false
            }
            let attributes = document.documentAttributes ?? [:]
            if let title = attributes[PDFDocumentAttribute.titleAttribute] as? String,
               !title.trimmingCharacters(in: .whitespaces).isEmpty {
                book.title = title
            }
            if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String {
                book.author = author
            }
            if let page = document.page(at: 0) {
                let thumbnail = page.thumbnail(of: CGSize(width: 480, height: 720), for: .cropBox)
                if let tiff = thumbnail.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: coverURL(for: book.id))
                }
            }

        case .epub:
            let root = epubRoot(for: book.id)
            guard EPUBLoader.unzip(fileURL(for: book), to: root),
                  let package = EPUBLoader.load(root: root) else {
                try? fm.removeItem(at: dir)
                return false
            }
            if !package.title.isEmpty { book.title = package.title }
            book.author = package.author
            if let cover = package.coverURL {
                try? fm.copyItem(at: cover, to: coverURL(for: book.id))
            }
        }

        books.insert(book, at: 0)
        scheduleSave()
        return true
    }

    func delete(_ id: UUID) {
        guard !isReadOnly else { return }
        // Keep a copy that still has this book's notes, then move the files to the
        // Trash (recoverable) instead of erasing them.
        saveNow()
        keepCopy(of: Self.indexURL, named: "before-delete")
        allowEmptySave = true
        books.removeAll { $0.id == id }
        let folder = directory(for: id)
        do {
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        } catch {
            try? FileManager.default.removeItem(at: folder)
        }
        scheduleSave()
    }
}
