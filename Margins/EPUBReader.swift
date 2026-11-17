import SwiftUI
import WebKit

struct EPUBReaderView: NSViewRepresentable {
    let library: Library
    let bookID: UUID
    let bridge: ReaderBridge
    let fontSize: Double
    let theme: ReaderTheme

    func makeCoordinator() -> Coordinator {
        Coordinator(library: library, bookID: bookID, bridge: bridge)
    }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(WeakMessageHandler(coordinator), name: "margins")
        configuration.userContentController.addUserScript(
            WKUserScript(source: readerScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.underPageBackgroundColor = theme.backgroundColor
        coordinator.webView = webView
        coordinator.fontSize = fontSize
        coordinator.theme = theme

        let root = library.epubRoot(for: bookID)
        coordinator.root = root
        coordinator.chapters = EPUBLoader.load(root: root)?.chapters ?? []

        let book = library.book(bookID)
        let chapters = coordinator.chapters
        DispatchQueue.main.async {
            bridge.chapters = chapters
            coordinator.load(book?.chapterIndex ?? 0, fraction: book?.chapterScroll ?? 0)
        }

        bridge.highlightSelection = { [weak coordinator] in coordinator?.highlight($0) }
        bridge.jump = { [weak coordinator] in coordinator?.jump(to: $0) }
        bridge.remove = { [weak coordinator] in coordinator?.run("margins.remove('\($0.uuidString)')") }
        bridge.recolor = { [weak coordinator] in
            coordinator?.run("margins.recolor('\($0.uuidString)', '\($1.rawValue)')")
        }
        bridge.goToChapter = { [weak coordinator] in coordinator?.load($0, fraction: 0) }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.fontSize != fontSize || coordinator.theme != theme else { return }
        coordinator.fontSize = fontSize
        coordinator.theme = theme
        webView.underPageBackgroundColor = theme.backgroundColor
        coordinator.run("margins.setStyle('\(theme.background)', '\(theme.foreground)', \(Int(fontSize)))")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let library: Library
        let bookID: UUID
        let bridge: ReaderBridge
        weak var webView: WKWebView?
        var root = URL(fileURLWithPath: "/")
        var chapters: [EPUBChapter] = []
        var fontSize: Double = 19
        var theme: ReaderTheme = .light

        private var current = 0
        private var pendingFraction: Double = 0
        private var pendingJump: UUID?

        init(library: Library, bookID: UUID, bridge: ReaderBridge) {
            self.library = library
            self.bookID = bookID
            self.bridge = bridge
        }

        func run(_ script: String) {
            webView?.evaluateJavaScript(script, completionHandler: nil)
        }

        func load(_ index: Int, fraction: Double, jumpTo: UUID? = nil) {
            guard !chapters.isEmpty else { return }
            current = min(max(index, 0), chapters.count - 1)
            pendingFraction = fraction
            pendingJump = jumpTo
            bridge.chapterIndex = current
            bridge.hasSelection = false
            saveProgress(fraction)
            webView?.loadFileURL(chapters[current].url, allowingReadAccessTo: root)
        }

        private func saveProgress(_ fraction: Double) {
            let index = current
            let count = Double(max(chapters.count, 1))
            library.update(bookID) {
                $0.chapterIndex = index
                $0.chapterScroll = fraction
                $0.progress = min((Double(index) + fraction) / count, 1)
            }
        }

        func highlight(_ nutrient: Nutrient) {
            let id = UUID()
            let chapter = current
            let script = "margins.highlight('\(id.uuidString)', '\(nutrient.rawValue)')"
            webView?.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self = self,
                      let json = result as? String,
                      let data = json.data(using: .utf8),
                      let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let start = info["start"] as? Int,
                      let end = info["end"] as? Int,
                      let text = info["text"] as? String else { return }
                var item = Highlight(id: id, category: nutrient, text: text)
                item.chapter = chapter
                item.start = start
                item.end = end
                self.library.update(self.bookID) { $0.highlights.append(item) }
                self.bridge.hasSelection = false
                self.bridge.selectedHighlight = id
            }
        }

        func jump(to highlight: Highlight) {
            guard let chapter = highlight.chapter else { return }
            if chapter == current {
                run("margins.scrollTo('\(highlight.id.uuidString)')")
            } else {
                load(chapter, fraction: 0, jumpTo: highlight.id)
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let chapter = current
            let marks: [[String: Any]] = (library.book(bookID)?.highlights ?? [])
                .filter { $0.chapter == chapter }
                .compactMap { item in
                    guard let start = item.start, let end = item.end else { return nil }
                    return ["id": item.id.uuidString, "cat": item.category.rawValue, "start": start, "end": end]
                }
            let config: [String: Any] = [
                "bg": theme.background,
                "fg": theme.foreground,
                "size": Int(fontSize),
                "fraction": pendingFraction,
                "hasNext": current < chapters.count - 1,
                "highlights": marks
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: config),
                  let json = String(data: data, encoding: .utf8) else { return }
            let jump = pendingJump
            pendingJump = nil
            webView.evaluateJavaScript("margins.setup(\(json))") { [weak self] _, _ in
                if let jump = jump { self?.run("margins.scrollTo('\(jump.uuidString)')") }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if url.isFileURL {
                let path = url.standardizedFileURL.path
                if let index = chapters.firstIndex(where: { $0.url.path == path }) {
                    load(index, fraction: 0)
                }
            } else if url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "selection":
                let has = body["has"] as? Bool ?? false
                if bridge.hasSelection != has { bridge.hasSelection = has }
            case "progress":
                if let fraction = body["fraction"] as? Double { saveProgress(fraction) }
            case "tap":
                if let string = body["id"] as? String, let id = UUID(uuidString: string) {
                    bridge.selectedHighlight = id
                }
            case "hover":
                // The pointer is over a highlight: send its note back to be shown beside it.
                guard let string = body["id"] as? String, let id = UUID(uuidString: string),
                      let item = library.book(bookID)?.highlights.first(where: { $0.id == id }) else { return }
                let note = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !note.isEmpty else { return }
                let payload: [String: Any] = [
                    "id": string, "note": note, "cat": item.category.rawValue, "title": item.category.title
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload),
                   let json = String(data: data, encoding: .utf8) {
                    run("margins.showNote(\(json))")
                }
            case "next":
                if current < chapters.count - 1 { load(current + 1, fraction: 0) }
            case "prev":
                if current > 0 { load(current - 1, fraction: 0) }
            default:
                break
            }
        }
    }
}

/// Avoids the retain cycle WKUserContentController creates with its message handlers.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// Injected into every chapter: typography, highlights, selection and progress reporting.
private let readerScript = #"""
(function () {
  if (window.margins) return;
  const post = (m) => window.webkit.messageHandlers.margins.postMessage(m);
  const style = document.createElement('style');
  (document.head || document.documentElement).appendChild(style);

  function setStyle(bg, fg, size) {
    const dark = String(bg).toLowerCase() === '#1c1c1e';
    const noteBg = dark ? 'rgba(58, 58, 60, 0.92)' : 'rgba(255, 255, 255, 0.9)';
    const noteFg = dark ? '#f2f2f7' : '#1d1d1f';
    const noteBorder = dark ? 'rgba(255, 255, 255, 0.14)' : 'rgba(0, 0, 0, 0.1)';
    style.textContent = `
      html { background: ${bg} !important; }
      body {
        background: ${bg} !important; color: ${fg} !important;
        font-family: ui-serif, "New York", "Iowan Old Style", Georgia, serif !important;
        font-size: ${size}px !important; line-height: 1.65 !important;
        max-width: 660px; margin: 0 auto !important; padding: 56px 44px 96px !important;
        -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility;
        hyphens: auto; -webkit-hyphens: auto;
      }
      p, li, blockquote, td, dd, dt, span, div { color: inherit !important; line-height: inherit !important; }
      p, li, blockquote, td, span { font-family: inherit !important; }
      h1, h2, h3, h4 {
        color: inherit !important; line-height: 1.25 !important;
        font-family: -apple-system, system-ui, sans-serif !important; letter-spacing: -0.01em;
      }
      a { color: #0a84ff !important; text-decoration: none; }
      img, svg, video { max-width: 100% !important; height: auto !important; }
      ::selection { background: rgba(10, 132, 255, 0.28); }
      mark.margins-hl { color: inherit; border-radius: 3px; padding: 1px 0; cursor: pointer; transition: box-shadow .3s; }
      mark.margins-hl[data-cat="protein"] { background: rgba(255, 69, 58, 0.30); }
      mark.margins-hl[data-cat="carb"] { background: rgba(255, 159, 10, 0.34); }
      mark.margins-hl[data-cat="fat"] { background: rgba(255, 214, 10, 0.44); }
      mark.margins-hl[data-cat="fiber"] { background: rgba(10, 132, 255, 0.26); }
      mark.margins-hl[data-cat="vitamin"] { background: rgba(48, 209, 88, 0.32); }
      mark.margins-hl.margins-flash { box-shadow: 0 0 0 3px rgba(10, 132, 255, 0.45); }
      .margins-ui { margin-top: 72px; text-align: center; }
      .margins-ui button {
        font: 500 14px -apple-system, system-ui, sans-serif; color: #0a84ff;
        background: rgba(10, 132, 255, 0.10); border: 0; border-radius: 999px;
        padding: 10px 22px; cursor: pointer;
      }
      .margins-ui button:hover { background: rgba(10, 132, 255, 0.18); }
      .margins-note {
        position: fixed; z-index: 9999; left: 0; top: 0; box-sizing: border-box;
        min-width: 120px; max-width: 300px; padding: 10px 12px; border-radius: 10px;
        background: ${noteBg} !important; border: 0.5px solid ${noteBorder};
        -webkit-backdrop-filter: blur(24px) saturate(180%);
        box-shadow: 0 10px 30px rgba(0, 0, 0, 0.18), 0 1px 3px rgba(0, 0, 0, 0.08);
        opacity: 0; visibility: hidden; transition: opacity .15s ease; pointer-events: none;
        text-align: left; hyphens: manual; -webkit-hyphens: manual;
      }
      .margins-note.show { opacity: 1; visibility: visible; }
      .margins-note, .margins-note div {
        font-family: -apple-system, system-ui, sans-serif !important; color: ${noteFg} !important;
      }
      .margins-note-label {
        font-size: 10px !important; font-weight: 600; letter-spacing: .04em;
        text-transform: uppercase; line-height: 1.3 !important; margin-bottom: 4px;
      }
      .margins-note-label[data-cat="protein"] { color: #ff453a !important; }
      .margins-note-label[data-cat="carb"] { color: #ff9500 !important; }
      .margins-note-label[data-cat="fat"] { color: #c79a00 !important; }
      .margins-note-label[data-cat="fiber"] { color: #0a84ff !important; }
      .margins-note-label[data-cat="vitamin"] { color: #28a745 !important; }
      .margins-note-body { font-size: 13px !important; line-height: 1.45 !important; white-space: pre-wrap; }
    `;
  }

  function textNodes() {
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    const nodes = [];
    let node;
    while ((node = walker.nextNode())) nodes.push(node);
    return nodes;
  }

  function offsetOf(container, offset) {
    const range = document.createRange();
    range.selectNodeContents(document.body);
    range.setEnd(container, offset);
    return range.toString().length;
  }

  function wrap(id, cat, start, end) {
    let position = 0;
    for (const node of textNodes()) {
      const length = node.data.length;
      const from = Math.max(start, position) - position;
      const to = Math.min(end, position + length) - position;
      position += length;
      if (to <= from) continue;
      if (node.parentElement && node.parentElement.closest('.margins-ui, .margins-note, script, style')) continue;
      let target = node;
      if (from > 0) target = node.splitText(from);
      if (to - from < target.data.length) target.splitText(to - from);
      if (!target.data.trim()) continue;
      const mark = document.createElement('mark');
      mark.className = 'margins-hl';
      mark.dataset.id = id;
      mark.dataset.cat = cat;
      target.parentNode.insertBefore(mark, target);
      mark.appendChild(target);
    }
  }

  function marks(id) {
    return Array.from(document.querySelectorAll('mark.margins-hl')).filter((m) => m.dataset.id === id);
  }

  function highlight(id, cat) {
    const selection = window.getSelection();
    if (!selection.rangeCount || selection.isCollapsed) return null;
    const range = selection.getRangeAt(0);
    const start = offsetOf(range.startContainer, range.startOffset);
    const end = offsetOf(range.endContainer, range.endOffset);
    const text = selection.toString().trim();
    if (end <= start || !text) return null;
    wrap(id, cat, start, end);
    selection.removeAllRanges();
    return JSON.stringify({ start: start, end: end, text: text });
  }

  function remove(id) {
    marks(id).forEach((mark) => {
      const parent = mark.parentNode;
      while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
      parent.removeChild(mark);
      parent.normalize();
    });
  }

  function recolor(id, cat) {
    marks(id).forEach((mark) => { mark.dataset.cat = cat; });
  }

  function scrollTo(id) {
    const found = marks(id);
    if (!found.length) return;
    found[0].scrollIntoView({ block: 'center', behavior: 'smooth' });
    found.forEach((mark) => mark.classList.add('margins-flash'));
    setTimeout(() => found.forEach((mark) => mark.classList.remove('margins-flash')), 1200);
  }

  function setup(config) {
    setStyle(config.bg, config.fg, config.size);
    (config.highlights || []).forEach((h) => wrap(h.id, h.cat, h.start, h.end));
    if (config.hasNext && !document.querySelector('.margins-ui')) {
      const footer = document.createElement('div');
      footer.className = 'margins-ui';
      const button = document.createElement('button');
      button.textContent = 'Next Section';
      button.addEventListener('click', () => post({ type: 'next' }));
      footer.appendChild(button);
      document.body.appendChild(footer);
    }
    requestAnimationFrame(() => {
      const max = document.documentElement.scrollHeight - window.innerHeight;
      if (config.fraction > 0 && max > 0) window.scrollTo(0, config.fraction * max);
    });
  }

  // Note shown beside a highlight while the pointer is over it.
  let noteEl = null;
  let hoverId = null;

  function hideNote() {
    hoverId = null;
    if (noteEl) noteEl.classList.remove('show');
  }

  function showNote(payload) {
    if (hoverId !== payload.id) return;
    const found = marks(payload.id);
    if (!found.length) return;
    if (!noteEl) {
      noteEl = document.createElement('div');
      noteEl.className = 'margins-note';
      document.body.appendChild(noteEl);
    }
    noteEl.textContent = '';
    const label = document.createElement('div');
    label.className = 'margins-note-label';
    label.dataset.cat = payload.cat;
    label.textContent = payload.title;
    const text = document.createElement('div');
    text.className = 'margins-note-body';
    text.textContent = payload.note;
    noteEl.appendChild(label);
    noteEl.appendChild(text);

    const rect = found[0].getBoundingClientRect();
    const width = noteEl.offsetWidth;
    const height = noteEl.offsetHeight;
    const left = Math.min(Math.max(rect.left + rect.width / 2 - width / 2, 12), window.innerWidth - width - 12);
    let top = rect.top - height - 10;
    if (top < 12) top = rect.bottom + 10;
    noteEl.style.left = left + 'px';
    noteEl.style.top = top + 'px';
    noteEl.classList.add('show');
  }

  document.addEventListener('mouseover', (event) => {
    const mark = event.target.closest && event.target.closest('mark.margins-hl');
    if (mark) {
      if (hoverId !== mark.dataset.id) {
        hideNote();
        hoverId = mark.dataset.id;
        post({ type: 'hover', id: hoverId });
      }
    } else if (hoverId) {
      hideNote();
    }
  });
  window.addEventListener('scroll', hideNote);
  document.addEventListener('mousedown', hideNote);

  let lastHas = false;
  document.addEventListener('selectionchange', () => {
    const selection = window.getSelection();
    const has = !!selection && !selection.isCollapsed && selection.toString().trim().length > 0;
    if (has !== lastHas) { lastHas = has; post({ type: 'selection', has: has }); }
  });

  let scrollTimer = null;
  window.addEventListener('scroll', () => {
    if (scrollTimer) return;
    scrollTimer = setTimeout(() => {
      scrollTimer = null;
      const max = document.documentElement.scrollHeight - window.innerHeight;
      post({ type: 'progress', fraction: max > 0 ? Math.min(window.scrollY / max, 1) : 1 });
    }, 400);
  });

  document.addEventListener('click', (event) => {
    const mark = event.target.closest && event.target.closest('mark.margins-hl');
    if (mark) post({ type: 'tap', id: mark.dataset.id });
  });

  document.addEventListener('keydown', (event) => {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    if (event.key === 'ArrowRight') post({ type: 'next' });
    if (event.key === 'ArrowLeft') post({ type: 'prev' });
  });

  window.margins = { setStyle, setup, highlight, remove, recolor, scrollTo, showNote };
})();
"""#
