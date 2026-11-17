import SwiftUI
import AppKit

/// Margulan Seisembai's "nutrients" — what a passage is good for.
enum Nutrient: String, Codable, CaseIterable, Identifiable {
    case protein, carb, fat, fiber, vitamin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .protein: return "Proteins"
        case .carb: return "Carbs"
        case .fat: return "Fats"
        case .fiber: return "Fiber"
        case .vitamin: return "Vitamins"
        }
    }

    /// What belongs in this category.
    var subtitle: String {
        switch self {
        case .protein: return "Tools and techniques to apply right away"
        case .carb: return "Ideas that inspire and make you think"
        case .fat: return "Stories and cases worth remembering"
        case .fiber: return "Facts, figures and references"
        case .vitamin: return "Quotes, jokes and anecdotes"
        }
    }

    /// What to do with it once the book is finished.
    var action: String {
        switch self {
        case .protein: return "Turn into tasks"
        case .carb: return "Think over on a walk"
        case .fat: return "Keep what stuck"
        case .fiber: return "Reference for talks"
        case .vitamin: return "Use in conversation"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .protein: return .systemRed
        case .carb: return .systemOrange
        case .fat: return .systemYellow
        case .fiber: return .systemBlue
        case .vitamin: return .systemGreen
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    var emoji: String {
        switch self {
        case .protein: return "🔴"
        case .carb: return "🟠"
        case .fat: return "🟡"
        case .fiber: return "🔵"
        case .vitamin: return "🟢"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .protein: return "1"
        case .carb: return "2"
        case .fat: return "3"
        case .fiber: return "4"
        case .vitamin: return "5"
        }
    }

    var shortcutLabel: String {
        "⌘" + String(shortcut.character)
    }
}

struct Highlight: Codable, Identifiable, Equatable {
    var id = UUID()
    var category: Nutrient
    var text: String
    var note: String = ""
    var createdAt = Date()
    var done = false

    // PDF location
    var pdfPage: Int?
    var pdfRects: [CGRect]?

    // EPUB location: chapter index + character offsets in the chapter text
    var chapter: Int?
    var start: Int?
    var end: Int?

    /// Reading-order sort key.
    var position: Double {
        if let page = pdfPage {
            let top = pdfRects?.map(\.maxY).max() ?? 0
            return Double(page) * 100_000 - Double(top)
        }
        return Double(chapter ?? 0) * 10_000_000 + Double(start ?? 0)
    }

    var locationLabel: String {
        if let page = pdfPage { return "Page \(page + 1)" }
        if let chapter = chapter { return "Section \(chapter + 1)" }
        return ""
    }
}

enum BookKind: String, Codable {
    case pdf, epub
}

struct Book: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var author: String = ""
    var kind: BookKind
    var addedAt = Date()
    var lastOpened: Date?

    var progress: Double = 0
    var pdfPage: Int = 0
    var chapterIndex: Int = 0
    var chapterScroll: Double = 0

    /// "Why am I reading this?" — decided before starting.
    var purpose: String = ""
    /// One date per completed read. Two or more makes it a classic.
    var readDates: [Date] = []
    var highlights: [Highlight] = []

    var isClassic: Bool { readDates.count >= 2 }
    var isFinished: Bool { !readDates.isEmpty }

    var sortedHighlights: [Highlight] {
        highlights.sorted { $0.position < $1.position }
    }

    func highlights(in category: Nutrient) -> [Highlight] {
        sortedHighlights.filter { $0.category == category }
    }
}

enum ReaderTheme: String, CaseIterable, Identifiable {
    case light, sepia, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .sepia: return "Sepia"
        case .dark: return "Dark"
        }
    }

    var background: String {
        switch self {
        case .light: return "#FFFFFF"
        case .sepia: return "#F8F1E3"
        case .dark: return "#1C1C1E"
        }
    }

    var foreground: String {
        switch self {
        case .light: return "#1D1D1F"
        case .sepia: return "#3B2F22"
        case .dark: return "#E5E5EA"
        }
    }

    var backgroundColor: NSColor { NSColor(hex: background) }
}

extension NSColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Book {
    /// The end-of-book report as Markdown.
    func reportMarkdown() -> String {
        var out = "# \(title)\n"
        if !author.isEmpty { out += "*\(author)*\n" }
        out += "\n"
        if !purpose.isEmpty { out += "**Why I'm reading this:** \(purpose)\n\n" }
        if !readDates.isEmpty {
            let dates = readDates.map { $0.formatted(date: .abbreviated, time: .omitted) }.joined(separator: ", ")
            out += "**Finished:** \(dates)\(isClassic ? " — Classic" : "")\n\n"
        }
        for nutrient in Nutrient.allCases {
            let items = highlights(in: nutrient)
            guard !items.isEmpty else { continue }
            out += "## \(nutrient.emoji) \(nutrient.title) — \(nutrient.action)\n\n"
            for item in items {
                let quote = item.text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                let note = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
                if nutrient == .protein {
                    out += "- [\(item.done ? "x" : " ")] \(note.isEmpty ? quote : note)\n"
                    if !note.isEmpty { out += "  > \(quote)\n" }
                } else {
                    out += "> \(quote)\n"
                    if !note.isEmpty { out += "\n\(note)\n" }
                    out += "\n"
                }
            }
            out += "\n"
        }
        return out
    }
}

// MARK: - Tolerant decoding
//
// Swift's automatic decoding fails when a field is missing from the JSON, which
// means adding a new field would make the existing library.json unreadable.
// These decoders fall back to a default for every missing field, so files from
// older and newer versions of Margins still load.
//
// RULE: when you add a field to Book or Highlight, add a line for it here too.

extension Highlight {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        category = try c.decodeIfPresent(Nutrient.self, forKey: .category) ?? .carb
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        pdfPage = try c.decodeIfPresent(Int.self, forKey: .pdfPage)
        pdfRects = try c.decodeIfPresent([CGRect].self, forKey: .pdfRects)
        chapter = try c.decodeIfPresent(Int.self, forKey: .chapter)
        start = try c.decodeIfPresent(Int.self, forKey: .start)
        end = try c.decodeIfPresent(Int.self, forKey: .end)
    }
}

extension Book {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(BookKind.self, forKey: .kind)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        lastOpened = try c.decodeIfPresent(Date.self, forKey: .lastOpened)
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        pdfPage = try c.decodeIfPresent(Int.self, forKey: .pdfPage) ?? 0
        chapterIndex = try c.decodeIfPresent(Int.self, forKey: .chapterIndex) ?? 0
        chapterScroll = try c.decodeIfPresent(Double.self, forKey: .chapterScroll) ?? 0
        purpose = try c.decodeIfPresent(String.self, forKey: .purpose) ?? ""
        readDates = try c.decodeIfPresent([Date].self, forKey: .readDates) ?? []
        highlights = try c.decodeIfPresent([Highlight].self, forKey: .highlights) ?? []
    }
}
