import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(Library.self) private var library
    var open: (UUID) -> Void

    enum Shelf: String, CaseIterable, Identifiable {
        case all = "All"
        case reading = "Reading"
        case finished = "Finished"
        case classics = "Classics"
        var id: String { rawValue }
    }

    @State private var shelf: Shelf = .all
    @State private var importing = false
    @State private var reportBook: UUID?
    @State private var dropTargeted = false
    @State private var deleteCandidate: UUID?
    @State private var showIdeas = false
    @State private var showStats = false

    private var books: [Book] {
        switch shelf {
        case .all: return library.books
        case .reading: return library.books.filter { !$0.isFinished }
        case .finished: return library.books.filter { $0.isFinished }
        case .classics: return library.books.filter { $0.isClassic }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 36, alignment: .top)]

    var body: some View {
        Group {
            if let problem = library.loadProblem {
                ContentUnavailableView {
                    Label("Library Not Loaded", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(problem)
                        .textSelection(.enabled)
                } actions: {
                    Button("Show Library Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Library.root])
                    }
                }
            } else if library.books.isEmpty {
                ContentUnavailableView {
                    Label("No Books Yet", systemImage: "books.vertical")
                } description: {
                    Text("Drop a PDF or EPUB here, or add one from your Mac.")
                } actions: {
                    Button("Add Book…") { importing = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 40) {
                        ForEach(books) { book in
                            BookCard(book: book, cover: library.cover(for: book))
                                .onTapGesture { openBook(book) }
                                .contextMenu {
                                    Button("Open") { openBook(book) }
                                    Button("Show Report") { reportBook = book.id }
                                    Divider()
                                    Button("Delete…", role: .destructive) { deleteCandidate = book.id }
                                }
                        }
                    }
                    .padding(.horizontal, 44)
                    .padding(.vertical, 36)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(12)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            var imported = false
            for url in urls where library.importFile(url) { imported = true }
            return imported
        } isTargeted: { dropTargeted = $0 }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Shelf", selection: $shelf) {
                    ForEach(Shelf.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showStats = true } label: {
                    Label("Reading Time", systemImage: "chart.bar")
                }
                .help("Reading time and statistics")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showIdeas = true } label: {
                    Label("Ideas", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .help("Ideas across all your books")
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            ToolbarItem(placement: .primaryAction) {
                Button { importing = true } label: {
                    Label("Add Book", systemImage: "plus")
                }
                .help("Add a PDF or EPUB")
                .disabled(library.isReadOnly)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .epub],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                urls.forEach { library.importFile($0) }
            }
        }
        .sheet(isPresented: $showIdeas) {
            IdeasView()
        }
        .sheet(isPresented: $showStats) {
            ReadingStatsView()
        }
        .confirmationDialog(
            "Delete this book and all of its highlights and notes?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Book", role: .destructive) {
                if let id = deleteCandidate { library.delete(id) }
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text("The book file goes to the Trash, and a copy of your notes is kept in the Backups folder.")
        }
        .sheet(item: Binding(
            get: { reportBook.map(IdentifiedID.init) },
            set: { reportBook = $0?.id }
        )) { item in
            ReportView(bookID: item.id)
        }
    }

    private func openBook(_ book: Book) {
        library.update(book.id) { $0.lastOpened = Date() }
        open(book.id)
    }
}

struct IdentifiedID: Identifiable {
    let id: UUID
}

struct BookCard: View {
    let book: Book
    let cover: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            coverView
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: .black.opacity(hovering ? 0.28 : 0.18), radius: hovering ? 14 : 8, y: hovering ? 8 : 4)
                .scaleEffect(hovering ? 1.02 : 1)
                .animation(.easeOut(duration: 0.18), value: hovering)

            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                if !book.author.isEmpty {
                    Text(book.author)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if book.isClassic {
                        Label("Classic", systemImage: "star.fill")
                            .foregroundStyle(.orange)
                    } else if book.isFinished {
                        Label("Finished", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text(book.progress > 0 ? "\(Int(book.progress * 100))%" : "New")
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if !book.highlights.isEmpty {
                        Label("\(book.highlights.count)", systemImage: "highlighter")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .labelStyle(.titleAndIcon)
                .padding(.top, 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var coverView: some View {
        if let cover = cover {
            Color.clear
                .overlay {
                    Image(nsImage: cover)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
        } else {
            LinearGradient(colors: [Color(white: 0.36), Color(white: 0.22)],
                           startPoint: .top, endPoint: .bottom)
                .overlay(alignment: .topLeading) {
                    Text(book.title)
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(5)
                        .padding(14)
                }
        }
    }
}
