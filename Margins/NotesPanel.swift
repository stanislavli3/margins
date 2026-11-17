import SwiftUI

struct NotesPanel: View {
    @Environment(Library.self) private var library
    let bookID: UUID
    let bridge: ReaderBridge

    @State private var filter: Nutrient?
    @State private var ideaSheet: IdeaRef?
    @FocusState private var focusedNote: UUID?

    var body: some View {
        let book = library.book(bookID)
        let all = book?.sortedHighlights ?? []
        let shown = filter.map { nutrient in all.filter { $0.category == nutrient } } ?? all
        let ideaIndex = library.ideaIndex
        let recentIdeas = library.recentIdeas

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("WHY I'M READING THIS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                TextField("Decide before you start…", text: purposeBinding, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...4)

                HStack(spacing: 6) {
                    FilterChip(title: "All", count: all.count, color: .secondary, selected: filter == nil) {
                        filter = nil
                    }
                    ForEach(Nutrient.allCases) { nutrient in
                        let count = all.filter { $0.category == nutrient }.count
                        FilterChip(title: nil, count: count, color: nutrient.color, selected: filter == nutrient) {
                            filter = filter == nutrient ? nil : nutrient
                        }
                        .help("\(nutrient.title) — \(nutrient.subtitle)")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 4)
            }
            .padding(16)

            Divider()

            if shown.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "highlighter")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("No Highlights")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Select text and choose what it is: a tool to apply, an idea, a story, a fact or a quote.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(28)
                .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(shown) { item in
                                HighlightRow(
                                    item: item,
                                    selected: bridge.selectedHighlight == item.id,
                                    note: noteBinding(item.id),
                                    focus: $focusedNote,
                                    echoes: echoes(for: item, in: ideaIndex),
                                    suggestions: Array(recentIdeas.filter { !item.ideas.contains($0) }.prefix(6)),
                                    openIdea: { ideaSheet = IdeaRef(name: $0) },
                                    select: {
                                        bridge.selectedHighlight = item.id
                                        bridge.jump?(item)
                                    },
                                    recolor: { nutrient in
                                        bridge.recolor?(item.id, nutrient)
                                        library.updateHighlight(item.id, in: bookID) { $0.category = nutrient }
                                    },
                                    delete: {
                                        bridge.remove?(item.id)
                                        library.update(bookID) { $0.highlights.removeAll { $0.id == item.id } }
                                    }
                                )
                                .id(item.id)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: bridge.selectedHighlight) { _, id in
                        guard let id = id else { return }
                        if let filter = filter, all.first(where: { $0.id == id })?.category != filter {
                            self.filter = nil
                        }
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focusedNote = id }
                    }
                }
            }
        }
        .background(.background)
        .sheet(item: $ideaSheet) { idea in
            IdeaView(name: idea.name)
        }
    }

    /// For each idea on this highlight: how many other passages share it, and in how many other books.
    private func echoes(for item: Highlight, in index: [String: [Passage]]) -> [Echo] {
        item.ideas.map { name in
            let others = (index[name] ?? []).filter { $0.highlight.id != item.id }
            let otherBooks = Set(others.map { $0.book.id }).subtracting([bookID]).count
            return Echo(name: name, others: others.count, otherBooks: otherBooks)
        }
    }

    private var purposeBinding: Binding<String> {
        Binding(
            get: { library.book(bookID)?.purpose ?? "" },
            set: { value in library.update(bookID) { $0.purpose = value } }
        )
    }

    private func noteBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { library.book(bookID)?.highlights.first { $0.id == id }?.note ?? "" },
            set: { value in library.updateHighlight(id, in: bookID) { $0.note = value } }
        )
    }
}

struct Echo: Identifiable {
    let name: String
    let others: Int
    let otherBooks: Int
    var id: String { name }

    var label: String {
        if others == 0 { return "#\(name) · first passage" }
        let passages = "\(others) more"
        if otherBooks == 0 { return "#\(name) · \(passages) in this book" }
        return "#\(name) · \(passages), \(otherBooks) other \(otherBooks == 1 ? "book" : "books")"
    }
}

private struct FilterChip: View {
    let title: String?
    let count: Int
    let color: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let title = title {
                    Text(title)
                } else {
                    Circle().fill(color).frame(width: 8, height: 8)
                }
                Text("\(count)").monospacedDigit()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.clear), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct HighlightRow: View {
    let item: Highlight
    let selected: Bool
    @Binding var note: String
    var focus: FocusState<UUID?>.Binding
    let echoes: [Echo]
    let suggestions: [String]
    let openIdea: (String) -> Void
    let select: () -> Void
    let recolor: (Nutrient) -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(item.category.color)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.category.title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(item.category.color)
                    Spacer()
                    Text(item.locationLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Text(item.text)
                    .font(.system(size: 12.5, design: .serif))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(selected ? 12 : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: select)

                TextField("Add a note…", text: $note, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...12)
                    .focused(focus, equals: item.id)

                // Echoes: what else you've marked under the same ideas.
                ForEach(echoes) { echo in
                    Button {
                        openIdea(echo.name)
                    } label: {
                        Label(echo.label, systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(echo.others > 0 ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show everything under #\(echo.name)")
                }

                // One-click ideas you've used before.
                if selected && !suggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(suggestions, id: \.self) { name in
                                Button {
                                    let trimmed = note.trimmingCharacters(in: .whitespaces)
                                    note = trimmed.isEmpty ? "#\(name)" : "\(trimmed) #\(name)"
                                } label: {
                                    Text("#\(name)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(.quaternary, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? AnyShapeStyle(item.category.color.opacity(0.10)) : AnyShapeStyle(.quinary))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? item.category.color.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .contextMenu {
            Menu("Move to") {
                ForEach(Nutrient.allCases) { nutrient in
                    Button(nutrient.title) { recolor(nutrient) }
                }
            }
            Button("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.text, forType: .string)
            }
            Divider()
            Button("Delete Highlight", role: .destructive, action: delete)
        }
    }
}
