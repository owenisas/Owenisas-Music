import Foundation

struct LyricLine: Identifiable, Equatable {
    let id = UUID()
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

class LyricsParser {
    static func parseVTT(fileURL: URL) -> [LyricLine] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }
        return parseVTT(content: content)
    }

    /// Parses WebVTT cues into lyric lines.
    ///
    /// Tolerant of the files this app has written over time and of what
    /// YouTube serves:
    /// - cue settings after the end time (`align:start position:0%`) are ignored
    /// - whitespace-only payload lines are skipped instead of ending the cue
    /// - a blank line followed by more text (not a new cue) continues the
    ///   cue, so legacy "plain lyrics in one cue" files show every stanza
    /// - auto-generated rolling captions (each cue repeats the previous
    ///   line, plus 10 ms carry-over cues) are collapsed to the new text
    static func parseVTT(content: String) -> [LyricLine] {
        let lines = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var cues: [(start: TimeInterval, end: TimeInterval, lines: [String])] = []
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            guard line.contains("-->"), let timing = parseTiming(line) else {
                i += 1
                continue
            }
            i += 1
            var textLines: [String] = []
            while i < lines.count {
                let raw = lines[i]
                if raw.isEmpty {
                    // A truly empty line ends the cue, unless what follows is
                    // plain text rather than another cue (stanza break inside
                    // a single cue, as the old plain-lyrics writer produced).
                    var j = i + 1
                    while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                    if j < lines.count, !textLines.isEmpty, !isCueStart(at: j, in: lines) {
                        textLines.append("")
                        i = j
                        continue
                    }
                    break
                }
                if raw.trimmingCharacters(in: .whitespaces).contains("-->") { break }
                let cleaned = cleanPayload(raw)
                if !cleaned.isEmpty {
                    textLines.append(cleaned)
                }
                i += 1
            }
            while textLines.last == "" { textLines.removeLast() }
            if !textLines.isEmpty {
                cues.append((timing.start, timing.end, textLines))
            }
        }

        return collapseRollingCaptions(cues)
    }

    /// `00:00:18.800 --> 00:00:21.790 align:start position:0%` → (18.8, 21.79)
    static func parseTiming(_ line: String) -> (start: TimeInterval, end: TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        let startToken = parts[0].trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).last.map(String.init) ?? ""
        let endToken = parts[1].trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        guard !startToken.isEmpty, !endToken.isEmpty else { return nil }
        return (parseTime(startToken), parseTime(endToken))
    }

    private static func isCueStart(at index: Int, in lines: [String]) -> Bool {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        if line.contains("-->") { return true }
        if line.hasPrefix("NOTE") || line == "STYLE" || line == "REGION" { return true }
        // Cue identifier line followed by a timing line.
        if index + 1 < lines.count, lines[index + 1].contains("-->") { return true }
        return false
    }

    private static func cleanPayload(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        // Remove tags like <c.color>…</c> and karaoke timestamps <00:00:19.039>.
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, value) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                                ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func collapseRollingCaptions(_ cues: [(start: TimeInterval, end: TimeInterval, lines: [String])]) -> [LyricLine] {
        var result: [LyricLine] = []
        for cue in cues {
            var lines = cue.lines
            if let previous = result.last {
                let previousLines = previous.text.components(separatedBy: "\n")
                // Rolling caption: the cue repeats the line already on screen,
                // then adds the new one. Keep only the new text.
                if lines.count >= 2, let lastShown = previousLines.last, lines.first == lastShown {
                    lines.removeFirst()
                }
                // 10 ms carry-over cue that only repeats text already shown.
                if cue.end - cue.start < 0.05, lines.allSatisfy({ previousLines.contains($0) }) {
                    continue
                }
                // Back-to-back identical cues: extend the previous one.
                let text = lines.joined(separator: "\n")
                if text == previous.text, cue.start - previous.endTime < 0.05 {
                    result[result.count - 1] = LyricLine(
                        startTime: previous.startTime,
                        endTime: max(previous.endTime, cue.end),
                        text: previous.text
                    )
                    continue
                }
            }
            let text = lines.joined(separator: "\n")
            guard !text.isEmpty else { continue }
            result.append(LyricLine(startTime: cue.start, endTime: cue.end, text: text))
        }
        return result
    }

    // Parse time in format HH:MM:SS.mmm or MM:SS.mmm
    static func parseTime(_ timeStr: String) -> TimeInterval {
        // Handle both dot (VTT) and comma (SRT) decimal separators
        let str = timeStr.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = str.components(separatedBy: ":")
        var seconds: TimeInterval = 0

        if parts.count == 3 {
            seconds += (Double(parts[0]) ?? 0) * 3600
            seconds += (Double(parts[1]) ?? 0) * 60
            seconds += Double(parts[2]) ?? 0
        } else if parts.count == 2 {
            seconds += (Double(parts[0]) ?? 0) * 60
            seconds += Double(parts[1]) ?? 0
        } else {
            seconds += Double(str) ?? 0
        }

        return seconds
    }
}

/// Writes WebVTT that `LyricsParser` reads back without losing lines.
enum LyricsVTTWriter {
    /// Synced LRC (`[mm:ss.xx]line`, several leading tags allowed) → VTT.
    /// An empty timed line ends the previous line (instrumental gap).
    static func vtt(fromLRC lrc: String) -> String? {
        var stamps: [(time: TimeInterval, text: String)] = []
        let tag = /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/
        for rawLine in lrc.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            var rest = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            var times: [TimeInterval] = []
            while let match = rest.prefixMatch(of: tag) {
                let minutes = Double(match.1) ?? 0
                let secs = Double(match.2) ?? 0
                let fraction = match.3.map { String($0) } ?? "0"
                let millis = Double(fraction.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
                times.append(minutes * 60 + secs + millis / 1000)
                rest = rest[match.range.upperBound...]
            }
            guard !times.isEmpty else { continue }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for time in times { stamps.append((time, text)) }
        }
        stamps.sort { $0.time < $1.time }

        var cues: [(start: TimeInterval, end: TimeInterval, text: String)] = []
        for (index, stamp) in stamps.enumerated() where !stamp.text.isEmpty {
            let end = index + 1 < stamps.count ? stamps[index + 1].time : stamp.time + 5
            cues.append((stamp.time, max(end, stamp.time + 0.1), stamp.text))
        }
        guard !cues.isEmpty else { return nil }
        return render(cues)
    }

    /// Unsynced lyrics → one cue per stanza, spread across the song so every
    /// line survives parsing (a blank line inside a cue would end it).
    static func vtt(fromPlainLyrics plain: String, duration: TimeInterval) -> String? {
        var stanzas: [[String]] = []
        var current: [String] = []
        for line in plain.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !current.isEmpty { stanzas.append(current); current = [] }
            } else {
                current.append(trimmed)
            }
        }
        if !current.isEmpty { stanzas.append(current) }
        let lineCount = stanzas.reduce(0) { $0 + $1.count }
        guard lineCount > 0 else { return nil }

        let total = duration > 0 ? duration : Double(lineCount) * 4
        let perLine = total / Double(lineCount)
        var cues: [(start: TimeInterval, end: TimeInterval, text: String)] = []
        var linesBefore = 0
        for stanza in stanzas {
            let start = Double(linesBefore) * perLine
            linesBefore += stanza.count
            let end = Double(linesBefore) * perLine
            cues.append((start, end, stanza.joined(separator: "\n")))
        }
        return render(cues)
    }

    static func formatTime(_ t: TimeInterval) -> String {
        let clamped = max(t, 0)
        let hours = Int(clamped) / 3600
        let minutes = (Int(clamped) % 3600) / 60
        let seconds = clamped - Double(hours * 3600 + minutes * 60)
        if hours > 0 {
            return String(format: "%02d:%02d:%06.3f", hours, minutes, seconds)
        }
        return String(format: "%02d:%06.3f", minutes, seconds)
    }

    private static func render(_ cues: [(start: TimeInterval, end: TimeInterval, text: String)]) -> String {
        var vtt = "WEBVTT\n\n"
        for cue in cues {
            vtt += "\(formatTime(cue.start)) --> \(formatTime(cue.end))\n\(cue.text)\n\n"
        }
        return vtt
    }
}
