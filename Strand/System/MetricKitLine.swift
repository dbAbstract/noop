import Foundation

/// The strap-log lines for the reports iOS hands NOOP through MetricKit: one a day about the day before, and one
/// after a crash, a hang, a CPU or disk-write exception, or a slow launch.
///
/// Nothing here is sent anywhere. iOS gathers these numbers on the phone and delivers them to the app; the lines go
/// only into NOOP's own strap log, which a person exports by hand. They exist so a battery or crash question can be
/// answered from what the phone measured — how much CPU NOOP used in the background, why iOS closed it — rather than
/// from the phone's Analytics Data files, which a user has to find and share one by one.
///
/// Each line says only what iOS reported: a field MetricKit left out is left out of the line, not printed as zero.
/// Pure so `StrandTests` covers it; the subscriber that fills it (`MetricKitLog`) is iOS-only.
enum MetricKitLine {

    /// One app-exit reason and how often it happened in the report's window, fore- and background added.
    struct Exit: Equatable {
        let reason: String
        let count: Int
    }

    /// The daily metric report, reduced to what a battery or crash question needs.
    struct Day: Equatable {
        var begin: Date
        var end: Date
        var appVersion: String
        var foreground: TimeInterval?
        var background: TimeInterval?
        var cpu: TimeInterval?
        var peakMemoryBytes: Double?
        var diskWriteBytes: Double?
        var hangs: Int?
        var exits: [Exit] = []
    }

    static func day(_ d: Day, timeZone: TimeZone = .current) -> String {
        var parts: [String] = []
        if let v = d.foreground { parts.append("foreground \(duration(v))") }
        if let v = d.background { parts.append("background \(duration(v))") }
        if let v = d.cpu { parts.append("CPU \(duration(v))") }
        if let v = d.peakMemoryBytes { parts.append("peak memory \(bytes(v))") }
        if let v = d.diskWriteBytes { parts.append("disk writes \(bytes(v))") }
        if let v = d.hangs { parts.append("hangs \(v)") }
        let exits = d.exits.filter { $0.count > 0 }
        parts.append("exits: " + (exits.isEmpty ? "none" : exits.map { "\($0.reason) \($0.count)" }
            .joined(separator: ", ")))
        return "MetricKit day \(stamp(d.begin, timeZone)) → \(stamp(d.end, timeZone)) (NOOP \(d.appVersion)): "
            + parts.joined(separator: ", ")
    }

    /// A crash, hang, exception or slow-launch report: `kind` names it, `detail` is what iOS said about it.
    static func diagnostic(_ kind: String, appVersion: String, at: Date, detail: String,
                           timeZone: TimeZone = .current) -> String {
        "MetricKit \(kind) (NOOP \(appVersion), reported \(stamp(at, timeZone))): \(detail)"
    }

    /// "1h 12m", "6m 12s", "40s", and tenths below ten seconds ("2.4s") where a hang lives.
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "?" }
        if seconds < 10 {
            let tenths = (seconds * 10).rounded() / 10
            return tenths == tenths.rounded() ? "\(Int(tenths))s" : String(format: "%.1fs", tenths)
        }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// The call stack iOS attached to a crash or hang (`MXCallStackTree.jsonRepresentation()`), as strap-log lines.
    ///
    /// FORK-LOCAL. Without it a report says only THAT the app was stuck ("0x8BADF00D … 10.00 seconds"), never where.
    /// One line per stack: the thread iOS attributed the report to, plus the first thread (the main thread in a
    /// per-thread crash tree) when that is a different one. Frames are `binary+0xoffset` in MetricKit's order, the
    /// offset into the binary's text segment, which `atos` resolves against the build's dSYM (the fork build keeps
    /// it as an artifact). Where frames branch (an aggregated hang tree), the path with the most samples is
    /// followed. A last line names each binary's UUID, so a dSYM can be checked against the build that crashed.
    static func stack(_ json: Data, limit: Int = 48) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let stacks = root["callStacks"] as? [[String: Any]], !stacks.isEmpty else { return [] }
        let attributed = stacks.firstIndex { ($0["threadAttributed"] as? Bool) == true }
        var picked: [Int] = []
        if let attributed { picked.append(attributed) }
        if attributed != 0 { picked.append(0) }

        func heaviest(_ frames: Any?) -> [String: Any]? {
            (frames as? [[String: Any]])?.max {
                (($0["sampleCount"] as? NSNumber)?.intValue ?? 0) < (($1["sampleCount"] as? NSNumber)?.intValue ?? 0)
            }
        }
        var binaries: [String: String] = [:]
        var lines: [String] = []
        for index in picked {
            var frames: [String] = []
            var frame = heaviest(stacks[index]["callStackRootFrames"])
            var total = 0
            while let f = frame {
                total += 1
                let name = f["binaryName"] as? String ?? "?"
                if let uuid = f["binaryUUID"] as? String { binaries[name] = uuid }
                if frames.count < limit {
                    let offset = (f["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value ?? 0
                    frames.append("\(name)+0x\(String(offset, radix: 16))")
                }
                frame = heaviest(f["subFrames"])
            }
            guard !frames.isEmpty else { continue }
            let label = index == attributed ? "thread \(index), attributed" : "thread \(index)"
            let more = total > frames.count ? " … \(total - frames.count) more" : ""
            lines.append("MetricKit stack (\(label)): " + frames.joined(separator: " < ") + more)
        }
        if !binaries.isEmpty {
            lines.append("MetricKit binaries: " + binaries.sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        return lines
    }

    /// Whole megabytes, or gigabytes to one decimal from 1,000 MB up.
    static func bytes(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "?" }
        let mb = value / 1_048_576
        if mb >= 1000 { return String(format: "%.1f GB", mb / 1024) }
        return "\(Int(mb.rounded())) MB"
    }

    private static func stamp(_ date: Date, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
