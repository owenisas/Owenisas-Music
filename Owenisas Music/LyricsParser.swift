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
        
        let lines = content.components(separatedBy: .newlines)
        var lyrics = [LyricLine]()
        
        // typical VTT structure:
        // WEBVTT
        //
        // 00:00:01.000 --> 00:00:03.000
        // Hello world
        
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.contains("-->") {
                // Parse times
                let parts = line.components(separatedBy: "-->")
                if parts.count == 2 {
                    let start = parseTime(parts[0])
                    let end = parseTime(parts[1])
                    
                    // The next lines until an empty line are the text
                    var text = ""
                    i += 1
                    while i < lines.count {
                        let textLine = lines[i].trimmingCharacters(in: .whitespaces)
                        if textLine.isEmpty {
                            break
                        }
                        // Remove HTML tags often found in VTT like <c.color>...</c>
                        let cleanText = textLine.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
                        text += (text.isEmpty ? "" : "\n") + cleanText
                        i += 1
                    }
                    
                    if !text.isEmpty {
                        lyrics.append(LyricLine(startTime: start, endTime: end, text: text))
                    }
                }
            }
            i += 1
        }
        
        return lyrics
    }
    
    // Parse time in format HH:MM:SS.mmm or MM:SS.mmm
    private static func parseTime(_ timeStr: String) -> TimeInterval {
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
