import SwiftUI

struct ReaderView: View {
    @Environment(Library.self) private var library
    let bookID: UUID
    var close: () -> Void

    @State private var bridge = ReaderBridge()
    @State private var showNotes = true
    @State private var showReport = false
    @State private var session = ReadingSession()
    @Environment(ReadingLog.self) private var readingLog
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @AppStorage("readerFontSize") private var fontSize = 19.0
    @AppStorage("readerTheme") private var themeRaw = ReaderTheme.light.rawValue

    private var theme: ReaderTheme { ReaderTheme(rawValue: themeRaw) ?? .light }

    var body: some View {
        if let book = library.book(bookID) {
            reader(book)
        } else {
            Color.clear.onAppear(perform: close)
        }
    }

    private func reader(_ book: Book) -> some View {
        ZStack(alignment: .bottom) {
            switch book.kind {
            case .pdf:
                PDFReaderView(library: library, bookID: bookID, bridge: bridge)
            case .epub:
                EPUBReaderView(library: library, bookID: bookID, bridge: bridge,
                               fontSize: fontSize, theme: theme)
            }

            if bridge.hasSelection {
                SelectionBar { nutrient in
                    bridge.highlightSelection?(nutrient)
                    showNotes = true
                }
                .padding(.bottom, 28)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: bridge.hasSelection)
        .inspector(isPresented: $showNotes) {
            NotesPanel(bookID: bookID, bridge: bridge)
                .inspectorColumnWidth(min: 280, ideal: 330, max: 460)
        }
        .navigationTitle(book.title)
        .navigationSubtitle(subtitle(book))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: close) {
                    Label("Library", systemImage: "chevron.left")
                }
                .help("Back to Library")
                .keyboardShortcut("l", modifiers: .command)
            }

            if book.kind == .epub {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        ForEach(bridge.chapters) { chapter in
                            Button {
                                bridge.goToChapter?(chapter.id)
                            } label: {
                                if chapter.id == bridge.chapterIndex {
                                    Label(chapter.title, systemImage: "checkmark")
                                } else {
                                    Text(chapter.title)
                                }
                            }
                        }
                    } label: {
                        Label("Contents", systemImage: "list.bullet")
                    }
                    .help("Table of Contents")

                    Menu {
                        Button("Larger Text") { fontSize = min(fontSize + 1, 30) }
                            .keyboardShortcut("+", modifiers: .command)
                        Button("Smaller Text") { fontSize = max(fontSize - 1, 13) }
                            .keyboardShortcut("-", modifiers: .command)
                        Divider()
                        Picker("Theme", selection: $themeRaw) {
                            ForEach(ReaderTheme.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Appearance", systemImage: "textformat.size")
                    }
                    .help("Text Size and Theme")
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                ReadingTimerButton(session: session)

                Button { showReport = true } label: {
                    Label("Report", systemImage: "doc.text")
                }
                .help("Book Report")
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button { showNotes.toggle() } label: {
                    Label("Notes", systemImage: "sidebar.trailing")
                }
                .help("Show or Hide Notes")
                .keyboardShortcut("n", modifiers: [.command, .option])
            }
        }
        .sheet(isPresented: $showReport) {
            ReportView(bookID: bookID)
        }
        .onReceive(tick) { now in
            session.tick(now, log: readingLog, bookID: bookID)
        }
        .onDisappear {
            session.flush(log: readingLog, bookID: bookID)
        }
    }

    private func subtitle(_ book: Book) -> String {
        let percent = "\(Int((book.progress * 100).rounded()))%"
        if book.kind == .epub, bridge.chapters.indices.contains(bridge.chapterIndex) {
            return "\(bridge.chapters[bridge.chapterIndex].title) · \(percent)"
        }
        if book.kind == .pdf { return "Page \(book.pdfPage + 1) · \(percent)" }
        return percent
    }
}

/// Appears when text is selected: one tap (or ⌘1–⌘5) files the passage under a nutrient.
struct SelectionBar: View {
    var pick: (Nutrient) -> Void
    @State private var hovered: Nutrient?

    var body: some View {
        VStack(spacing: 8) {
            Text(hovered.map { "\($0.title) — \($0.subtitle)" } ?? "Highlight as…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .animation(nil, value: hovered)

            HStack(spacing: 14) {
                ForEach(Nutrient.allCases) { nutrient in
                    Button { pick(nutrient) } label: {
                        VStack(spacing: 5) {
                            Circle()
                                .fill(nutrient.color.gradient)
                                .frame(width: 26, height: 26)
                                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                                .scaleEffect(hovered == nutrient ? 1.18 : 1)
                            Text(nutrient.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(hovered == nutrient ? .primary : .secondary)
                        }
                        .frame(width: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(nutrient.shortcut, modifiers: .command)
                    .help("\(nutrient.subtitle) (\(nutrient.shortcutLabel))")
                    .onHover { inside in
                        if inside { hovered = nutrient } else if hovered == nutrient { hovered = nil }
                    }
                    .animation(.easeOut(duration: 0.15), value: hovered)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}
