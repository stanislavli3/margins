import SwiftUI
import AppKit

/// Time spent reading, per day and per book. Kept in its own file
/// (reading-log.json) so library.json is never touched by the timer.
@Observable
final class ReadingLog {
    /// "2026-11-17" -> book id -> seconds
    private(set) var days: [String: [String: Double]] = [:]

    @ObservationIgnored private var canSave = true
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    private static var fileURL: URL { Library.root.appendingPathComponent("reading-log.json") }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }

    init() {
        load()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.save()
        }
    }

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: Self.fileURL)
            days = try JSONDecoder().decode([String: [String: Double]].self, from: data)
        } catch {
            // Unreadable: leave the file exactly as it is and don't write over it.
            canSave = false
        }
    }

    func add(_ seconds: Double, to bookID: UUID) {
        guard seconds > 0 else { return }
        days[Self.dayKey(Date()), default: [:]][bookID.uuidString, default: 0] += seconds
        dirty = true
    }

    func save() {
        guard canSave, dirty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(days) else { return }
        do {
            try data.write(to: Self.fileURL, options: .atomic)
            dirty = false
        } catch {
            print("Margins: couldn't save reading log: \(error)")
        }
    }

    // MARK: Statistics

    func seconds(on date: Date) -> Double {
        (days[Self.dayKey(date)] ?? [:]).values.reduce(0, +)
    }

    var total: Double {
        days.values.reduce(0) { $0 + $1.values.reduce(0, +) }
    }

    /// The last `count` days, oldest first.
    func lastDays(_ count: Int) -> [DayTotal] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DayTotal(date: date, seconds: seconds(on: date))
        }
    }

    /// Days in a row with at least a minute of reading, counting back from today
    /// (or from yesterday, if nothing has been read yet today).
    var streak: Int {
        let calendar = Calendar.current
        var date = calendar.startOfDay(for: Date())
        if seconds(on: date) < 60 {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: date) else { return 0 }
            date = yesterday
        }
        var count = 0
        while seconds(on: date) >= 60 {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = previous
        }
        return count
    }

    /// Total seconds per book id.
    var perBook: [String: Double] {
        var totals: [String: Double] = [:]
        for day in days.values {
            for (book, seconds) in day { totals[book, default: 0] += seconds }
        }
        return totals
    }

    // MARK: Formatting and activity

    /// "1 h 05 min" or "12 min".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 60 {
            return "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min"
        }
        return "\(minutes) min"
    }

    /// "12:34" or "1:02:03".
    static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds)
        let h = whole / 3600
        let m = (whole % 3600) / 60
        let s = whole % 60
        if h > 0 { return "\(h):\(String(format: "%02d", m)):\(String(format: "%02d", s))" }
        return "\(String(format: "%02d", m)):\(String(format: "%02d", s))"
    }

    /// Seconds since the last key press, click or scroll anywhere on the Mac.
    static func idleSeconds() -> Double {
        let anyInput = CGEventType(rawValue: UInt32.max) ?? .mouseMoved
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}

/// One open book's reading session. Counts while Margins is in front and you've
/// touched the Mac in the last five minutes.
@Observable
final class ReadingSession {
    var seconds: Double = 0
    var paused = false

    @ObservationIgnored private var pending: Double = 0
    @ObservationIgnored private var last = Date()

    func tick(_ now: Date, log: ReadingLog, bookID: UUID) {
        let delta = min(max(now.timeIntervalSince(last), 0), 2)
        last = now
        guard !paused, NSApp.isActive, ReadingLog.idleSeconds() < 300 else { return }
        seconds += delta
        pending += delta
        if pending >= 15 { flush(log: log, bookID: bookID) }
    }

    func flush(log: ReadingLog, bookID: UUID) {
        guard pending > 0 else { return }
        log.add(pending, to: bookID)
        pending = 0
        log.save()
    }

    func togglePause() {
        paused.toggle()
        last = Date()
    }
}

/// The timer shown in the reader's toolbar. Click it to pause.
struct ReadingTimerButton: View {
    let session: ReadingSession

    var body: some View {
        Button {
            session.togglePause()
        } label: {
            Label(ReadingLog.clock(session.seconds), systemImage: session.paused ? "pause.circle" : "timer")
                .labelStyle(.titleAndIcon)
                .monospacedDigit()
        }
        .help(session.paused ? "Timer paused. Click to resume." : "Reading time this session. Click to pause.")
    }
}

struct DayTotal: Identifiable {
    let date: Date
    let seconds: Double
    var id: Date { date }
}

struct BookTotal: Identifiable {
    let id: String
    let seconds: Double
}

/// Reading statistics for the whole library.
struct ReadingStatsView: View {
    @Environment(Library.self) private var library
    @Environment(ReadingLog.self) private var log
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let recent = log.lastDays(14)
        let week = recent.suffix(7).reduce(0) { $0 + $1.seconds }
        let peak = max(recent.map { $0.seconds }.max() ?? 0, 60)
        let books = log.perBook
            .map { BookTotal(id: $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Reading Time")
                        .font(.system(size: 28, weight: .bold, design: .serif))

                    HStack(spacing: 12) {
                        metric("Today", ReadingLog.duration(log.seconds(on: Date())))
                        metric("Last 7 days", ReadingLog.duration(week))
                        metric("All time", ReadingLog.duration(log.total))
                        metric("Streak", "\(log.streak) \(log.streak == 1 ? "day" : "days")")
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Last 14 days")
                            .font(.system(size: 17, weight: .semibold))
                        HStack(alignment: .bottom, spacing: 8) {
                            ForEach(recent) { day in
                                VStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(day.seconds >= 60 ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.quaternary))
                                        .frame(height: max(CGFloat(day.seconds / peak) * 120, 3))
                                    Text(day.date.formatted(.dateTime.day()))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .help("\(day.date.formatted(date: .abbreviated, time: .omitted)): \(ReadingLog.duration(day.seconds))")
                            }
                        }
                        .frame(height: 146, alignment: .bottom)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("By book")
                            .font(.system(size: 17, weight: .semibold))
                        if books.isEmpty {
                            Text("Open a book and the timer starts on its own.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(books) { entry in
                            HStack {
                                Text(title(for: entry.id))
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                Spacer()
                                Text(ReadingLog.duration(entry.seconds))
                                    .font(.system(size: 13))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 44)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 640, height: 640)
        .background(.background)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 19, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func title(for id: String) -> String {
        library.books.first { $0.id.uuidString == id }?.title ?? "Removed book"
    }
}
