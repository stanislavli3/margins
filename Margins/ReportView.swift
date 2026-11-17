import SwiftUI
import AppKit

/// The end-of-book digest: everything you marked, grouped by what to do with it.
struct ReportView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    @State private var copied = false

    var body: some View {
        if let book = library.book(bookID) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        header(book)
                        if book.highlights.isEmpty {
                            Text("Nothing highlighted yet. Your notes will be collected here as you read.")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Nutrient.allCases) { nutrient in
                            let items = book.highlights(in: nutrient)
                            if !items.isEmpty { section(nutrient, items) }
                        }
                    }
                    .padding(.horizontal, 44)
                    .padding(.vertical, 36)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()
                footer(book)
            }
            .frame(width: 720, height: 780)
            .background(.background)
        }
    }

    private func header(_ book: Book) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(book.title)
                .font(.system(size: 28, weight: .bold, design: .serif))
            if !book.author.isEmpty {
                Text(book.author)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            if !book.purpose.isEmpty {
                Text("Why I'm reading this: \(book.purpose)")
                    .font(.system(size: 14))
                    .padding(.top, 6)
            }
            HStack(spacing: 14) {
                ForEach(Nutrient.allCases) { nutrient in
                    HStack(spacing: 5) {
                        Circle().fill(nutrient.color).frame(width: 8, height: 8)
                        Text("\(book.highlights(in: nutrient).count) \(nutrient.title)")
                    }
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.top, 8)

            if !book.readDates.isEmpty {
                let dates = book.readDates.map { $0.formatted(date: .abbreviated, time: .omitted) }
                Label("Finished \(dates.joined(separator: ", "))" + (book.isClassic ? " — Classic" : ""),
                      systemImage: book.isClassic ? "star.fill" : "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(book.isClassic ? .orange : .green)
                    .padding(.top, 2)
            }
        }
    }

    private func section(_ nutrient: Nutrient, _ items: [Highlight]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Circle().fill(nutrient.color).frame(width: 10, height: 10)
                    Text(nutrient.title)
                        .font(.system(size: 19, weight: .semibold))
                }
                Text("\(nutrient.subtitle). \(nutrient.action).")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            ForEach(items) { item in
                HStack(alignment: .top, spacing: 12) {
                    if nutrient == .protein {
                        Button {
                            library.updateHighlight(item.id, in: bookID) { $0.done.toggle() }
                        } label: {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 17))
                                .foregroundStyle(item.done ? AnyShapeStyle(nutrient.color) : AnyShapeStyle(.tertiary))
                        }
                        .buttonStyle(.plain)
                        .help("Mark as applied")
                    } else {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(nutrient.color.opacity(0.7))
                            .frame(width: 3)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        if !item.note.isEmpty {
                            Text(item.note)
                                .font(.system(size: 14, weight: .medium))
                                .strikethrough(item.done && nutrient == .protein)
                        }
                        Text(item.text)
                            .font(.system(size: 14, design: .serif))
                            .foregroundStyle(item.note.isEmpty ? .primary : .secondary)
                            .lineSpacing(3)
                        Text(item.locationLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func footer(_ book: Book) -> some View {
        HStack(spacing: 10) {
            Button {
                library.update(bookID) {
                    $0.readDates.append(Date())
                    $0.progress = 1
                }
            } label: {
                Label(book.isFinished ? "Finished Again" : "Mark as Finished", systemImage: "signature")
            }
            .help("Signs and dates the book. Two reads make it a Classic.")

            Spacer()

            Button(copied ? "Copied" : "Copy as Markdown") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(book.reportMarkdown(), forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            Button("Export…") { export(book) }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func export(_ book: Book) {
        let panel = NSSavePanel()
        let safeTitle = book.title.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(safeTitle) — Notes.md"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? book.reportMarkdown().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
