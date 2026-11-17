import SwiftUI
import PDFKit

/// Shared state between the reader chrome (toolbar, notes panel) and the PDF / EPUB view.
@Observable
final class ReaderBridge {
    var hasSelection = false
    var selectedHighlight: UUID?
    var chapters: [EPUBChapter] = []
    var chapterIndex = 0

    @ObservationIgnored var highlightSelection: ((Nutrient) -> Void)?
    @ObservationIgnored var jump: ((Highlight) -> Void)?
    @ObservationIgnored var remove: ((UUID) -> Void)?
    @ObservationIgnored var recolor: ((UUID, Nutrient) -> Void)?
    @ObservationIgnored var goToChapter: ((Int) -> Void)?
}

/// A PDF view that reports which highlight the pointer is over.
final class HoverPDFView: PDFView {
    var onHover: ((PDFAnnotation?) -> Void)?
    private var hoverArea: NSTrackingArea?
    private weak var lastHit: PDFAnnotation?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        var hit: PDFAnnotation?
        if let page = page(for: point, nearest: false) {
            let pagePoint = convert(point, to: page)
            hit = page.annotations.first { $0.bounds.contains(pagePoint) }
        }
        if hit !== lastHit {
            lastHit = hit
            onHover?(hit)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if lastHit != nil {
            lastHit = nil
            onHover?(nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if lastHit != nil {
            lastHit = nil
            onHover?(nil)
        }
        super.mouseDown(with: event)
    }
}

/// The small card shown beside a highlight while the pointer is over it.
struct NotePopover: View {
    let category: Nutrient
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(category.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(category.color)
            Text(note)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 260, alignment: .leading)
        .padding(12)
    }
}

struct PDFReaderView: NSViewRepresentable {
    let library: Library
    let bookID: UUID
    let bridge: ReaderBridge

    func makeCoordinator() -> Coordinator {
        Coordinator(library: library, bookID: bookID, bridge: bridge)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = HoverPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .windowBackgroundColor

        let coordinator = context.coordinator
        coordinator.view = view

        if let book = library.book(bookID) {
            view.document = PDFDocument(url: library.fileURL(for: book))
            book.highlights.forEach { coordinator.add($0) }
            let savedPage = book.pdfPage
            DispatchQueue.main.async {
                if let page = view.document?.page(at: savedPage) { view.go(to: page) }
                coordinator.ready = true
            }
        }

        let center = NotificationCenter.default
        center.addObserver(coordinator, selector: #selector(Coordinator.selectionChanged),
                           name: .PDFViewSelectionChanged, object: view)
        center.addObserver(coordinator, selector: #selector(Coordinator.pageChanged),
                           name: .PDFViewPageChanged, object: view)
        center.addObserver(coordinator, selector: #selector(Coordinator.annotationHit(_:)),
                           name: .PDFViewAnnotationHit, object: view)

        view.onHover = { [weak coordinator] annotation in coordinator?.hover(annotation) }

        bridge.highlightSelection = { [weak coordinator] in coordinator?.highlight($0) }
        bridge.jump = { [weak coordinator] in coordinator?.jump(to: $0) }
        bridge.remove = { [weak coordinator] in coordinator?.remove($0) }
        bridge.recolor = { [weak coordinator] in coordinator?.recolor($0, $1) }
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {}

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        coordinator.hover(nil)
    }

    final class Coordinator: NSObject {
        let library: Library
        let bookID: UUID
        let bridge: ReaderBridge
        weak var view: PDFView?
        var ready = false
        private var annotations: [UUID: [PDFAnnotation]] = [:]
        private var notePopover: NSPopover?
        private var hoverWork: DispatchWorkItem?

        init(library: Library, bookID: UUID, bridge: ReaderBridge) {
            self.library = library
            self.bookID = bookID
            self.bridge = bridge
        }

        private func tint(_ nutrient: Nutrient) -> NSColor {
            nutrient.nsColor.withAlphaComponent(0.4)
        }

        func add(_ highlight: Highlight) {
            guard let pageIndex = highlight.pdfPage,
                  let rects = highlight.pdfRects,
                  let page = view?.document?.page(at: pageIndex) else { return }
            var created: [PDFAnnotation] = []
            for rect in rects {
                let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
                annotation.color = tint(highlight.category)
                page.addAnnotation(annotation)
                created.append(annotation)
            }
            annotations[highlight.id] = created
        }

        func highlight(_ nutrient: Nutrient) {
            guard let view = view, let document = view.document,
                  let selection = view.currentSelection else { return }

            // One highlight per page the selection touches.
            var rectsByPage: [Int: [CGRect]] = [:]
            var textByPage: [Int: [String]] = [:]
            for line in selection.selectionsByLine() {
                guard let page = line.pages.first else { continue }
                let index = document.index(for: page)
                let bounds = line.bounds(for: page)
                guard bounds.width > 0, bounds.height > 0 else { continue }
                rectsByPage[index, default: []].append(bounds)
                if let string = line.string { textByPage[index, default: []].append(string) }
            }

            var firstID: UUID?
            for index in rectsByPage.keys.sorted() {
                let text = (textByPage[index] ?? []).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                var item = Highlight(category: nutrient, text: text)
                item.pdfPage = index
                item.pdfRects = rectsByPage[index]
                add(item)
                library.update(bookID) { $0.highlights.append(item) }
                if firstID == nil { firstID = item.id }
            }

            view.clearSelection()
            bridge.hasSelection = false
            if let firstID = firstID { bridge.selectedHighlight = firstID }
        }

        func jump(to highlight: Highlight) {
            guard let pageIndex = highlight.pdfPage,
                  let page = view?.document?.page(at: pageIndex) else { return }
            if let rect = highlight.pdfRects?.first {
                view?.go(to: rect.insetBy(dx: 0, dy: -120), on: page)
            } else {
                view?.go(to: page)
            }
        }

        func remove(_ id: UUID) {
            annotations[id]?.forEach { $0.page?.removeAnnotation($0) }
            annotations[id] = nil
        }

        func recolor(_ id: UUID, _ nutrient: Nutrient) {
            annotations[id]?.forEach { $0.color = tint(nutrient) }
            view?.needsDisplay = true
            view?.documentView?.needsDisplay = true
        }

        /// Shows the note for the highlight under the pointer, after a short pause.
        func hover(_ annotation: PDFAnnotation?) {
            hoverWork?.cancel()
            hoverWork = nil
            notePopover?.close()
            notePopover = nil

            guard let annotation = annotation,
                  let id = annotations.first(where: { entry in entry.value.contains { $0 === annotation } })?.key,
                  let item = library.book(bookID)?.highlights.first(where: { $0.id == id }) else { return }
            let note = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !note.isEmpty else { return }

            let work = DispatchWorkItem { [weak self] in
                guard let self = self, let view = self.view, let page = annotation.page else { return }
                let rect = view.convert(annotation.bounds, from: page)
                let host = NSHostingController(rootView: NotePopover(category: item.category, note: note))
                host.sizingOptions = [.preferredContentSize]
                let popover = NSPopover()
                popover.behavior = .applicationDefined
                popover.animates = true
                popover.contentViewController = host
                popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
                self.notePopover = popover
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }

        @objc func selectionChanged() {
            let text = view?.currentSelection?.string ?? ""
            let has = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if bridge.hasSelection != has { bridge.hasSelection = has }
        }

        @objc func pageChanged() {
            guard ready, let view = view, let document = view.document,
                  let page = view.currentPage else { return }
            let index = document.index(for: page)
            let count = max(document.pageCount, 1)
            library.update(bookID) {
                $0.pdfPage = index
                $0.progress = count > 1 ? Double(index) / Double(count - 1) : 1
            }
        }

        @objc func annotationHit(_ notification: Notification) {
            guard let hit = notification.userInfo?["PDFAnnotationHit"] as? PDFAnnotation else { return }
            for (id, list) in annotations where list.contains(where: { $0 === hit }) {
                bridge.selectedHighlight = id
                return
            }
        }
    }
}
