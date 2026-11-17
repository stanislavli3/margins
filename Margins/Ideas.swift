import SwiftUI
import AppKit

// An idea is a short name attached to a highlight, like a tag in Finder.
// Ideas are added with the idea picker (stored in Highlight.tags); a #hashtag
// typed in a note counts as one too.

enum IdeaParser {
    private static let pattern = try? NSRegularExpression(pattern: "#([\\p{L}\\p{N}_-]+)")

    static func ideas(in text: String) -> [String] {
        guard let pattern = pattern, text.contains("#") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var result: [String] = []
        for match in pattern.matches(in: text, range: range) {
            guard let found = Range(match.range(at: 1), in: text) else { continue }
            let name = text[found].lowercased()
            if seen.insert(name).inserted { result.append(name) }
        }
        return result
    }

    /// "  #Deep Focus " -> "deep focus"
    static func normalize(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while name.hasPrefix("#") { name.removeFirst() }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Removes "#name" from a note.
    static func strip(_ name: String, from note: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(
            pattern: "\\s?#" + escaped + "(?![\\p{L}\\p{N}_-])",
            options: [.caseInsensitive]
        ) else { return note }
        let range = NSRange(note.startIndex..., in: note)
        return regex.stringByReplacingMatches(in: note, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

extension Highlight {
    /// Every idea on this highlight: picked ones first, then hashtags from the note.
    var ideas: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in tags.map({ IdeaParser.normalize($0) }) + IdeaParser.ideas(in: note)
        where !name.isEmpty && seen.insert(name).inserted {
            result.append(name)
        }
        return result
    }

    mutating func addIdea(_ raw: String) {
        let name = IdeaParser.normalize(raw)
        guard !name.isEmpty, !ideas.contains(name) else { return }
        tags.append(name)
    }

    mutating func removeIdea(_ raw: String) {
        let name = IdeaParser.normalize(raw)
        tags.removeAll { IdeaParser.normalize($0) == name }
        note = IdeaParser.strip(name, from: note)
    }
}

/// One highlight together with the book it came from.
struct Passage: Identifiable {
    let book: Book
    let highlight: Highlight
    var id: UUID { highlight.id }
}

struct IdeaSummary: Identifiable {
    let name: String
    let passages: Int
    let books: Int
    let lastUsed: Date
    var id: String { name }
}

struct IdeaRef: Identifiable {
    let name: String
    var id: String { name }
}

extension Library {
    /// Every idea with all of its passages, across all books.
    var ideaIndex: [String: [Passage]] {
        var index: [String: [Passage]] = [:]
        for book in books {
            for highlight in book.sortedHighlights {
                for idea in highlight.ideas {
                    index[idea, default: []].append(Passage(book: book, highlight: highlight))
                }
            }
        }
        return index
    }

    /// Ideas ordered by how many books they appear in, then by passages.
    var ideaSummaries: [IdeaSummary] {
        ideaIndex.map { name, passages in
            IdeaSummary(
                name: name,
                passages: passages.count,
                books: Set(passages.map { $0.book.id }).count,
                lastUsed: passages.map { $0.highlight.createdAt }.max() ?? .distantPast
            )
        }
        .sorted { a, b in
            if a.books != b.books { return a.books > b.books }
            if a.passages != b.passages { return a.passages > b.passages }
            return a.name < b.name
        }
    }

    /// Idea names, most recently used first.
    var recentIdeas: [String] {
        ideaSummaries.sorted { $0.lastUsed > $1.lastUsed }.map { $0.name }
    }
}

// MARK: - Idea page

/// Everything you've marked under one idea, across every book.
struct IdeaView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let name: String
    @State private var copied = false

    var body: some View {
        let passages = library.ideaIndex[name] ?? []
        let actions = passages.filter { $0.highlight.category == .protein }
        let bookIDs = orderedBookIDs(passages)

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(name.capitalized)
                            .font(.system(size: 28, weight: .bold, design: .serif))
                        Text("\(passages.count) \(passages.count == 1 ? "passage" : "passages") in \(bookIDs.count) \(bookIDs.count == 1 ? "book" : "books")")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    if passages.isEmpty {
                        Text("No passages yet. Add this idea to a highlight to see it here.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }

                    if !actions.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionTitle("To apply", color: Nutrient.protein.color)
                            ForEach(actions) { passage in
                                actionRow(passage)
                            }
                        }
                    }

                    ForEach(bookIDs, id: \.self) { bookID in
                        let items = passages.filter { $0.book.id == bookID }
                        if let first = items.first {
                            VStack(alignment: .leading, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(first.book.title)
                                        .font(.system(size: 17, weight: .semibold))
                                    if !first.book.author.isEmpty {
                                        Text(first.book.author)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                ForEach(items) { passage in
                                    passageRow(passage)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 44)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack(spacing: 10) {
                Spacer()
                Button(copied ? "Copied" : "Copy as Markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdown(passages, bookIDs: bookIDs), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .disabled(passages.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 680, height: 720)
        .background(.background)
    }

    private func orderedBookIDs(_ passages: [Passage]) -> [UUID] {
        var seen = Set<UUID>()
        var ordered: [UUID] = []
        for passage in passages where seen.insert(passage.book.id).inserted {
            ordered.append(passage.book.id)
        }
        return ordered
    }

    private func sectionTitle(_ title: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(title).font(.system(size: 17, weight: .semibold))
        }
    }

    private func actionRow(_ passage: Passage) -> some View {
        let item = passage.highlight
        return HStack(alignment: .top, spacing: 12) {
            Button {
                library.updateHighlight(item.id, in: passage.book.id) { $0.done.toggle() }
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(item.done ? AnyShapeStyle(Nutrient.protein.color) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .help("Mark as applied")

            VStack(alignment: .leading, spacing: 4) {
                Text(item.note.isEmpty ? item.text : item.note)
                    .font(.system(size: 14, weight: .medium))
                    .strikethrough(item.done)
                Text(passage.book.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func passageRow(_ passage: Passage) -> some View {
        let item = passage.highlight
        return HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(item.category.color.opacity(0.75))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                if !item.note.isEmpty {
                    Text(item.note)
                        .font(.system(size: 14, weight: .medium))
                }
                Text(item.text)
                    .font(.system(size: 14, design: .serif))
                    .foregroundStyle(item.note.isEmpty ? .primary : .secondary)
                    .lineSpacing(3)
                Text("\(item.category.title) · \(item.locationLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func markdown(_ passages: [Passage], bookIDs: [UUID]) -> String {
        var out = "# \(name.capitalized)\n\n"
        for bookID in bookIDs {
            let items = passages.filter { $0.book.id == bookID }
            guard let first = items.first else { continue }
            out += "## \(first.book.title)\n\n"
            for passage in items {
                let item = passage.highlight
                let quote = item.text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                out += "> \(quote)\n"
                let note = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty { out += "\n\(note)\n" }
                out += "\n"
            }
        }
        return out
    }
}

// MARK: - Graph

struct GraphNode: Identifiable {
    let id: String
    let label: String
    let idea: String?
    let weight: Int
    var x: Double = 0.5
    var y: Double = 0.5
}

struct GraphEdge: Identifiable {
    let a: Int
    let b: Int
    let betweenIdeas: Bool
    var id: String { "\(a)-\(b)" }
}

struct IdeaGraph {
    var nodes: [GraphNode] = []
    var edges: [GraphEdge] = []

    /// Ideas are linked to the books they appear in, and to each other when
    /// one highlight carries both.
    static func build(from books: [Book]) -> IdeaGraph {
        var graph = IdeaGraph()
        var position: [String: Int] = [:]
        var ideaBooks: [String: Set<UUID>] = [:]
        var links = Set<String>()

        for book in books {
            for highlight in book.highlights {
                for idea in highlight.ideas {
                    ideaBooks[idea, default: []].insert(book.id)
                }
            }
        }

        for (idea, bookIDs) in ideaBooks.sorted(by: { $0.key < $1.key }) {
            position["idea:" + idea] = graph.nodes.count
            graph.nodes.append(GraphNode(id: "idea:" + idea, label: idea, idea: idea, weight: bookIDs.count))
        }

        func link(_ first: Int, _ second: Int, betweenIdeas: Bool) {
            let a = min(first, second)
            let b = max(first, second)
            guard a != b, links.insert("\(a)-\(b)").inserted else { return }
            graph.edges.append(GraphEdge(a: a, b: b, betweenIdeas: betweenIdeas))
        }

        for book in books {
            var bookNode: Int?
            for highlight in book.highlights {
                let ideas = highlight.ideas
                guard !ideas.isEmpty else { continue }
                if bookNode == nil {
                    bookNode = graph.nodes.count
                    graph.nodes.append(GraphNode(id: "book:" + book.id.uuidString, label: book.title, idea: nil, weight: 1))
                }
                let indexes = ideas.compactMap { position["idea:" + $0] }
                if let bookNode = bookNode {
                    for index in indexes { link(index, bookNode, betweenIdeas: false) }
                }
                for first in indexes {
                    for second in indexes { link(first, second, betweenIdeas: true) }
                }
            }
        }

        graph.layout()
        return graph
    }

    /// A small force-directed layout in unit coordinates (0...1).
    private mutating func layout() {
        let count = nodes.count
        guard count > 0 else { return }
        if count == 1 {
            nodes[0].x = 0.5
            nodes[0].y = 0.5
            return
        }
        for index in 0..<count {
            let angle = 2 * Double.pi * Double(index) / Double(count)
            nodes[index].x = 0.5 + 0.3 * cos(angle)
            nodes[index].y = 0.5 + 0.3 * sin(angle)
        }

        let ideal = 0.7 * (1.0 / Double(count)).squareRoot()
        var temperature = 0.08

        for _ in 0..<300 {
            var moveX = [Double](repeating: 0, count: count)
            var moveY = [Double](repeating: 0, count: count)

            for i in 0..<count {
                for j in 0..<count where j > i {
                    let dx = nodes[i].x - nodes[j].x
                    let dy = nodes[i].y - nodes[j].y
                    let distance = max((dx * dx + dy * dy).squareRoot(), 0.001)
                    let force = ideal * ideal / distance
                    moveX[i] += dx / distance * force
                    moveY[i] += dy / distance * force
                    moveX[j] -= dx / distance * force
                    moveY[j] -= dy / distance * force
                }
            }

            for edge in edges {
                let dx = nodes[edge.a].x - nodes[edge.b].x
                let dy = nodes[edge.a].y - nodes[edge.b].y
                let distance = max((dx * dx + dy * dy).squareRoot(), 0.001)
                let force = distance * distance / ideal
                moveX[edge.a] -= dx / distance * force
                moveY[edge.a] -= dy / distance * force
                moveX[edge.b] += dx / distance * force
                moveY[edge.b] += dy / distance * force
            }

            for index in 0..<count {
                // A light pull towards the centre keeps separate clusters on screen.
                moveX[index] += (0.5 - nodes[index].x) * 0.05
                moveY[index] += (0.5 - nodes[index].y) * 0.05
                let length = max((moveX[index] * moveX[index] + moveY[index] * moveY[index]).squareRoot(), 0.0001)
                let step = min(length, temperature)
                nodes[index].x = min(max(nodes[index].x + moveX[index] / length * step, 0.08), 0.92)
                nodes[index].y = min(max(nodes[index].y + moveY[index] / length * step, 0.08), 0.92)
            }
            temperature = max(temperature * 0.985, 0.002)
        }
    }
}

/// The map of ideas across the whole library.
struct IdeasView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var graph = IdeaGraph()
    @State private var openIdea: IdeaRef?
    @State private var hovered: String?

    var body: some View {
        let summaries = library.ideaSummaries

        VStack(spacing: 0) {
            if summaries.isEmpty {
                ContentUnavailableView {
                    Label("No Ideas Yet", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("Click Add Idea under any highlight. Passages that share an idea are connected here, across all your books.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    graphView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    List(summaries) { summary in
                        Button {
                            openIdea = IdeaRef(name: summary.name)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(summary.name)
                                    .font(.system(size: 13, weight: .medium))
                                Text("\(summary.passages) \(summary.passages == 1 ? "passage" : "passages") · \(summary.books) \(summary.books == 1 ? "book" : "books")")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in
                            if inside { hovered = summary.name } else if hovered == summary.name { hovered = nil }
                        }
                    }
                    .frame(width: 230)
                }
            }

            Divider()
            HStack {
                Text("Click an idea to see everything you've marked under it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 940, height: 660)
        .background(.background)
        .onAppear { graph = IdeaGraph.build(from: library.books) }
        .sheet(item: $openIdea) { idea in
            IdeaView(name: idea.name)
        }
    }

    private var graphView: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            ZStack {
                Canvas { context, _ in
                    for edge in graph.edges {
                        let from = graph.nodes[edge.a]
                        let to = graph.nodes[edge.b]
                        var path = Path()
                        path.move(to: CGPoint(x: from.x * width, y: from.y * height))
                        path.addLine(to: CGPoint(x: to.x * width, y: to.y * height))
                        let lit = hovered != nil && (from.idea == hovered || to.idea == hovered)
                        context.stroke(
                            path,
                            with: .color(lit ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.3)),
                            lineWidth: edge.betweenIdeas ? 1.5 : 1
                        )
                    }
                }

                ForEach(graph.nodes) { node in
                    nodeView(node)
                        .position(x: node.x * width, y: node.y * height)
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func nodeView(_ node: GraphNode) -> some View {
        if let idea = node.idea {
            let diameter = CGFloat(16 + min(node.weight, 6) * 7)
            Button {
                openIdea = IdeaRef(name: idea)
            } label: {
                VStack(spacing: 4) {
                    Circle()
                        .fill(Color.accentColor.gradient)
                        .frame(width: diameter, height: diameter)
                        .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1))
                        .scaleEffect(hovered == idea ? 1.15 : 1)
                    Text(node.label)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { hovered = idea } else if hovered == idea { hovered = nil }
            }
            .animation(.easeOut(duration: 0.15), value: hovered)
            .help("\(node.weight) \(node.weight == 1 ? "book" : "books")")
        } else {
            Text(node.label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
                .frame(maxWidth: 130)
        }
    }
}

// MARK: - Idea tags on a highlight

/// Lays pills out left to right and wraps them onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// The row of idea pills under a highlight's note, with an Add Idea button.
struct IdeaTagsRow: View {
    let echoes: [Echo]
    /// Every idea in the library, most recently used first.
    let allIdeas: [String]
    let showSuggestions: Bool
    let toggle: (String) -> Void
    let open: (String) -> Void

    @State private var picking = false

    var body: some View {
        let attached = Set(echoes.map { $0.name })
        let suggestions = showSuggestions ? Array(allIdeas.filter { !attached.contains($0) }.prefix(3)) : []

        FlowLayout(spacing: 6) {
            ForEach(echoes) { echo in
                Button {
                    open(echo.name)
                } label: {
                    HStack(spacing: 4) {
                        Text(echo.name)
                        if echo.others > 0 {
                            Text("\(echo.others + 1)")
                                .foregroundStyle(Color.accentColor.opacity(0.65))
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(echo.label)
                .contextMenu {
                    Button("Open Idea") { open(echo.name) }
                    Button("Remove from This Highlight", role: .destructive) { toggle(echo.name) }
                }
            }

            ForEach(suggestions, id: \.self) { name in
                Button {
                    toggle(name)
                } label: {
                    Label(name, systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Add this idea")
            }

            Button {
                picking = true
            } label: {
                Label(echoes.isEmpty ? "Add Idea" : "Idea", systemImage: "tag")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Add or remove ideas")
            .popover(isPresented: $picking, arrowEdge: .bottom) {
                IdeaPicker(all: allIdeas, attached: attached, toggle: toggle)
            }
        }
    }
}

/// The small search-and-pick popover, in the style of Finder's tag picker.
struct IdeaPicker: View {
    let all: [String]
    let attached: Set<String>
    let toggle: (String) -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var cleaned: String { IdeaParser.normalize(query) }

    /// Rows to show: an optional "create" row first, then matching ideas.
    private var rows: [PickerRow] {
        let matches = cleaned.isEmpty ? all : all.filter { $0.contains(cleaned) }
        var result: [PickerRow] = []
        if !cleaned.isEmpty && !all.contains(cleaned) && !attached.contains(cleaned) {
            result.append(PickerRow(name: cleaned, isNew: true))
        }
        result += matches.prefix(8).map { PickerRow(name: $0, isNew: false) }
        return result
    }

    var body: some View {
        let rows = self.rows

        VStack(spacing: 0) {
            TextField("Add or find an idea", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .focused($focused)
                .onSubmit { choose(rows) }
                .onKeyPress(.downArrow) {
                    highlighted = min(highlighted + 1, max(rows.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    highlighted = max(highlighted - 1, 0)
                    return .handled
                }
                .onChange(of: query) { _, _ in highlighted = 0 }

            Divider()

            if rows.isEmpty {
                Text(all.isEmpty ? "Type a name and press Return to create your first idea." : "No matching ideas.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                VStack(spacing: 1) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        Button {
                            pick(row)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: row.isNew ? "plus" : "tag")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                Text(row.isNew ? "Create “\(row.name)”" : row.name)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if attached.contains(row.name) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(index == highlighted ? Color.accentColor.opacity(0.16) : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in
                            if inside { highlighted = index }
                        }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 250)
        .onAppear { focused = true }
    }

    private func choose(_ rows: [PickerRow]) {
        guard !rows.isEmpty else { return }
        pick(rows[min(highlighted, rows.count - 1)])
    }

    private func pick(_ row: PickerRow) {
        toggle(row.name)
        query = ""
        highlighted = 0
    }
}

struct PickerRow: Identifiable {
    let name: String
    let isNew: Bool
    var id: String { (isNew ? "new:" : "idea:") + name }
}
