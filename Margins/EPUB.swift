import Foundation

struct EPUBChapter: Identifiable {
    let id: Int
    let title: String
    let url: URL
}

struct EPUBPackage {
    var title = ""
    var author = ""
    var chapters: [EPUBChapter] = []
    var coverURL: URL?
}

/// Minimal EPUB reader: unzip, find the OPF, read metadata, spine and table of contents.
enum EPUBLoader {
    static func unzip(_ file: URL, to directory: URL) -> Bool {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", file.path, "-d", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        // unzip exits 1 for harmless warnings.
        return process.terminationStatus <= 1
    }

    static func load(root: URL) -> EPUBPackage? {
        // 1. container.xml points at the OPF package file.
        var opfPath: String?
        let container = root.appendingPathComponent("META-INF/container.xml")
        SimpleXML.parse(container, onStart: { name, attributes in
            if name == "rootfile", opfPath == nil { opfPath = attributes["full-path"] }
        })
        guard let opfPath = opfPath else { return nil }
        let opfURL = root.appendingPathComponent(opfPath)
        let opfDirectory = opfURL.deletingLastPathComponent()

        // 2. OPF: metadata, manifest, spine.
        struct Item { let href: String; let type: String; let properties: String }
        var manifest: [String: Item] = [:]
        var spine: [String] = []
        var coverID: String?
        var ncxID: String?
        var package = EPUBPackage()

        SimpleXML.parse(opfURL, onStart: { name, attributes in
            switch name {
            case "item":
                if let id = attributes["id"], let href = attributes["href"] {
                    manifest[id] = Item(
                        href: href,
                        type: attributes["media-type"] ?? "",
                        properties: attributes["properties"] ?? ""
                    )
                }
            case "itemref":
                if let idref = attributes["idref"] { spine.append(idref) }
            case "meta":
                if attributes["name"] == "cover" { coverID = attributes["content"] }
            case "spine":
                ncxID = attributes["toc"]
            default:
                break
            }
        }, onEnd: { name, text in
            if name == "title", package.title.isEmpty { package.title = text }
            if name == "creator", package.author.isEmpty { package.author = text }
        })

        func resolve(_ href: String) -> URL {
            let clean = href.components(separatedBy: "#")[0]
            let decoded = clean.removingPercentEncoding ?? clean
            return opfDirectory.appendingPathComponent(decoded).standardizedFileURL
        }

        // 3. Table of contents titles from the NCX, when there is one.
        var titles: [String: String] = [:]
        let ncxItem = ncxID.flatMap { manifest[$0] }
            ?? manifest.values.first { $0.type == "application/x-dtbncx+xml" }
        if let ncxItem = ncxItem {
            let ncxURL = resolve(ncxItem.href)
            let ncxDirectory = ncxURL.deletingLastPathComponent()
            var pendingLabel = ""
            SimpleXML.parse(ncxURL, onStart: { name, attributes in
                guard name == "content", let src = attributes["src"] else { return }
                let clean = src.components(separatedBy: "#")[0]
                let decoded = clean.removingPercentEncoding ?? clean
                let path = ncxDirectory.appendingPathComponent(decoded).standardizedFileURL.path
                if titles[path] == nil, !pendingLabel.isEmpty { titles[path] = pendingLabel }
            }, onEnd: { name, text in
                if name == "text" { pendingLabel = text }
            })
        }

        // 4. Chapters in reading order.
        var index = 0
        for idref in spine {
            guard let item = manifest[idref] else { continue }
            let url = resolve(item.href)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let title = titles[url.path] ?? "Section \(index + 1)"
            package.chapters.append(EPUBChapter(id: index, title: title, url: url))
            index += 1
        }
        guard !package.chapters.isEmpty else { return nil }

        // 5. Cover image.
        let coverItem = manifest.values.first { $0.properties.contains("cover-image") }
            ?? coverID.flatMap { manifest[$0] }
        if let coverItem = coverItem, coverItem.type.hasPrefix("image") {
            let url = resolve(coverItem.href)
            if FileManager.default.fileExists(atPath: url.path) { package.coverURL = url }
        }

        return package
    }
}

/// Tiny callback wrapper around XMLParser. Element names are reported without their namespace prefix.
final class SimpleXML: NSObject, XMLParserDelegate {
    private let onStart: (String, [String: String]) -> Void
    private let onEnd: (String, String) -> Void
    private var text = ""

    private init(onStart: @escaping (String, [String: String]) -> Void,
                 onEnd: @escaping (String, String) -> Void) {
        self.onStart = onStart
        self.onEnd = onEnd
    }

    static func parse(_ url: URL,
                      onStart: @escaping (String, [String: String]) -> Void = { _, _ in },
                      onEnd: @escaping (String, String) -> Void = { _, _ in }) {
        guard let parser = XMLParser(contentsOf: url) else { return }
        let delegate = SimpleXML(onStart: onStart, onEnd: onEnd)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.parse()
    }

    private func local(_ name: String) -> String {
        name.components(separatedBy: ":").last ?? name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        onStart(local(elementName), attributeDict)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        onEnd(local(elementName), text.trimmingCharacters(in: .whitespacesAndNewlines))
        text = ""
    }
}
