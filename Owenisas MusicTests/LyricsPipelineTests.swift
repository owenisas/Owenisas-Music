import Foundation
import Testing
@testable import Owenisas_Music

// Lyrics writer/parser round-trips and parser tolerance. Lyric text here is
// synthetic; only the file shapes mirror what LRCLIB and YouTube return.

struct LyricsVTTRoundTripTests {
    @Test("Synced LRC survives writer → parser, including multi-tag lines and gaps")
    func syncedRoundTrip() throws {
        let lrc = """
        [ar:Test Artist]
        [00:10.50]first line
        [00:14.20][01:30.00]repeated chorus line
        [00:18.00]
        [00:20.123]after the gap
        [01:35.5]last line
        """
        let vtt = try #require(LyricsVTTWriter.vtt(fromLRC: lrc))
        let lines = LyricsParser.parseVTT(content: vtt)
        #expect(lines.map(\.text) == ["first line", "repeated chorus line", "after the gap", "repeated chorus line", "last line"])
        #expect(abs(lines[0].startTime - 10.5) < 0.001)
        #expect(abs(lines[1].endTime - 18.0) < 0.001, "an empty timed line ends the previous line")
        #expect(abs(lines[2].startTime - 20.123) < 0.001)
        #expect(abs(lines[4].startTime - 95.5) < 0.001)
    }

    @Test("Plain lyrics keep every line of every stanza")
    func plainStanzasSurvive() throws {
        let stanzas = [
            (1...4).map { "verse one line \($0)" },
            (1...3).map { "chorus line \($0)" },
            (1...2).map { "outro line \($0)" },
        ]
        let plain = stanzas.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
        let vtt = try #require(LyricsVTTWriter.vtt(fromPlainLyrics: plain, duration: 90))
        let cues = LyricsParser.parseVTT(content: vtt)
        #expect(cues.count == 3)
        let parsedLines = cues.flatMap { $0.text.components(separatedBy: "\n") }
        #expect(parsedLines == stanzas.flatMap { $0 })
        #expect(abs((cues.last?.endTime ?? 0) - 90) < 0.01)
        #expect(zip(cues, cues.dropFirst()).allSatisfy { $0.endTime <= $1.startTime + 0.001 })
    }

    @Test("Hour-long timestamps round-trip")
    func longTimes() {
        #expect(LyricsVTTWriter.formatTime(65.25) == "01:05.250")
        #expect(LyricsVTTWriter.formatTime(3725.5) == "01:02:05.500")
        #expect(abs(LyricsParser.parseTime("01:02:05.500") - 3725.5) < 0.001)
    }
}

struct LyricsParserToleranceTests {
    @Test("Legacy single-cue plain lyrics with blank lines are read completely")
    func legacyPlainCue() {
        let content = "WEBVTT\n\n00:00.000 --> 99:59.999\nline a\nline b\n\nline c\n\nline d\n"
        let lines = LyricsParser.parseVTT(content: content)
        #expect(lines.count == 1)
        #expect(lines[0].text.components(separatedBy: "\n").filter { !$0.isEmpty } == ["line a", "line b", "line c", "line d"])
    }

    @Test("Cue settings after the end time are ignored")
    func cueSettings() throws {
        let content = "WEBVTT\n\n00:00:18.800 --> 00:00:21.790 align:start position:0%\nhello\n"
        let line = try #require(LyricsParser.parseVTT(content: content).first)
        #expect(abs(line.startTime - 18.8) < 0.001)
        #expect(abs(line.endTime - 21.79) < 0.001)
    }

    @Test("Whitespace-only first payload line doesn't drop the cue")
    func whitespaceFirstLine() {
        let content = "WEBVTT\n\n00:01.000 --> 00:03.000\n \nHello <c>there</c> &amp; you\n\n00:03.000 --> 00:04.000\nnext\n"
        #expect(LyricsParser.parseVTT(content: content).map(\.text) == ["Hello there & you", "next"])
    }

    @Test("Auto-generated rolling captions collapse to the new text")
    func rollingCaptions() {
        // Same shape as YouTube ASR VTT: each cue repeats the line already on
        // screen, and 10 ms cues carry the old line over.
        // Built line by line: the whitespace-only payload lines matter.
        let content = [
            "WEBVTT", "Kind: captions", "Language: en", "",
            "00:00:00.320 --> 00:00:18.790 align:start position:0%", " ", "[Music]", "",
            "00:00:18.790 --> 00:00:18.800 align:start position:0%", " ", " ", "",
            "00:00:18.800 --> 00:00:21.790 align:start position:0%", " ", "alpha<00:00:19.039><c> beta</c>", "",
            "00:00:21.790 --> 00:00:21.800 align:start position:0%", "alpha beta", " ", "",
            "00:00:21.800 --> 00:00:25.950 align:start position:0%", "alpha beta", "gamma<00:00:22.800><c> delta</c>", "",
            "00:00:25.950 --> 00:00:25.960 align:start position:0%", "gamma delta", " ", "",
            "00:00:25.960 --> 00:00:29.109 align:start position:0%", "gamma delta", "epsilon", "",
        ].joined(separator: "\n")
        let lines = LyricsParser.parseVTT(content: content)
        #expect(lines.map(\.text) == ["[Music]", "alpha beta", "gamma delta", "epsilon"])
        #expect(lines.allSatisfy { $0.endTime > $0.startTime })
    }

    @Test("Back-to-back identical cues merge")
    func duplicateCuesMerge() {
        let content = "WEBVTT\n\n00:00.433 --> 00:10.477\n♪ ♪\n\n00:10.477 --> 00:20.487\n♪ ♪\n\n00:27.726 --> 00:29.129\nwords\n"
        let lines = LyricsParser.parseVTT(content: content)
        #expect(lines.map(\.text) == ["♪ ♪", "words"])
        #expect(abs(lines[0].endTime - 20.487) < 0.001)
    }
}

#if !APP_STORE
struct LyricsQueryNormalizerTests {
    @Test("YouTube titles and channels become clean LRCLIB queries")
    func queries() {
        #expect(LyricsQueryNormalizer.query(videoTitle: "Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)", channel: "Rick Astley")
                == LyricsQuery(track: "Never Gonna Give You Up", artist: "Rick Astley"))
        #expect(LyricsQueryNormalizer.query(videoTitle: "Luis Fonsi - Despacito ft. Daddy Yankee", channel: "LuisFonsiVEVO")
                == LyricsQuery(track: "Despacito", artist: "Luis Fonsi"))
        #expect(LyricsQueryNormalizer.query(videoTitle: "Blinding Lights", channel: "TheWeekndVEVO")
                == LyricsQuery(track: "Blinding Lights", artist: "The Weeknd"))
        #expect(LyricsQueryNormalizer.query(videoTitle: "Hello", channel: "Adele - Topic")
                == LyricsQuery(track: "Hello", artist: "Adele"))
        #expect(LyricsQueryNormalizer.query(videoTitle: "【MV】YOASOBI「アイドル」", channel: "Ayase / YOASOBI")
                == LyricsQuery(track: "アイドル", artist: "YOASOBI"))
        #expect(LyricsQueryNormalizer.query(videoTitle: "Song Name [MV]", channel: "Band")
                == LyricsQuery(track: "Song Name", artist: "Band"))
        #expect(LyricsQueryNormalizer.query(videoTitle: "Artist - Song (Lyrics)", channel: nil).track == "Song")
        #expect(LyricsQueryNormalizer.query(videoTitle: "Artist - Song | Official Video", channel: nil).track == "Song")
        #expect(LyricsQueryNormalizer.query(videoTitle: "Artist - Song Official Audio", channel: nil).track == "Song")
    }

    @Test("Meaningful brackets survive; reversed 'Title - Artist' is detected")
    func keepsMeaning() {
        #expect(LyricsQueryNormalizer.query(videoTitle: "Artist - Song (Remix)", channel: nil).track == "Song (Remix)")
        #expect(LyricsQueryNormalizer.query(videoTitle: "Despacito - Luis Fonsi", channel: "Luis Fonsi")
                == LyricsQuery(track: "Despacito", artist: "Luis Fonsi"))
        #expect(LyricsQueryNormalizer.cleanTrack("Despacito (feat. Daddy Yankee)") == "Despacito")
        #expect(LyricsQueryNormalizer.cleanTrack("Soft Cell") == "Soft Cell")
    }

    @Test("Comparison keys fold case, accents and punctuation")
    func keys() {
        #expect(LyricsQueryNormalizer.key("Beyoncé & JAY-Z") == "beyonce and jay z")
        #expect(LyricsQueryNormalizer.key("Don’t Stop Me Now!") == "dont stop me now")
        #expect(LyricsQueryNormalizer.key("Don't Stop Me Now") == LyricsQueryNormalizer.key("DONT stop me now"))
    }
}

struct LRCLIBMatcherTests {
    private let rick = LyricsQuery(track: "Never Gonna Give You Up", artist: "Rick Astley")

    @Test("YouTube-titled LRCLIB entries match after normalization")
    func youtubeTitledEntry() {
        let record = LRCLIBRecord(trackName: "Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)",
                                  artistName: "Rick Astley", duration: 214, syncedLyrics: "[00:19.64]x")
        #expect(LRCLIBMatcher.isAcceptable(record, query: rick, duration: 213))
    }

    @Test("Featuring suffix on the LRCLIB side still matches")
    func featuring() {
        let record = LRCLIBRecord(trackName: "Despacito ft Daddy Yankee", artistName: "Luis Fonsi", duration: 281, syncedLyrics: "[00:01.00]x")
        #expect(LRCLIBMatcher.isAcceptable(record, query: LyricsQuery(track: "Despacito", artist: "Luis Fonsi"), duration: 282))
    }

    @Test("Wrong title or length more than 5 s off is rejected")
    func rejects() {
        let wrongSong = LRCLIBRecord(trackName: "Together Forever", artistName: "Rick Astley", duration: 213, syncedLyrics: "[00:01.00]x")
        #expect(!LRCLIBMatcher.isAcceptable(wrongSong, query: rick, duration: 213))
        let tooLong = LRCLIBRecord(trackName: "Never Gonna Give You Up", artistName: "Rick Astley", duration: 240, syncedLyrics: "[00:01.00]x")
        #expect(!LRCLIBMatcher.isAcceptable(tooLong, query: rick, duration: 213))
        let instrumental = LRCLIBRecord(trackName: "Never Gonna Give You Up", artistName: "Rick Astley", duration: 213, instrumental: true)
        #expect(!LRCLIBMatcher.isAcceptable(instrumental, query: rick, duration: 213))
    }

    @Test("Unknown length requires the artist to match too")
    func unknownDuration() {
        let cover = LRCLIBRecord(trackName: "Never Gonna Give You Up", artistName: "Some Cover Band", duration: 200, plainLyrics: "x")
        #expect(!LRCLIBMatcher.isAcceptable(cover, query: rick, duration: 0))
        let original = LRCLIBRecord(trackName: "Never Gonna Give You Up", artistName: "Rick Astley", duration: 213, plainLyrics: "x")
        #expect(LRCLIBMatcher.isAcceptable(original, query: rick, duration: 0))
    }

    @Test("best() skips an unvalidated first hit and prefers artist + synced")
    func bestPick() {
        let records = [
            LRCLIBRecord(trackName: "Something Else", artistName: "Rick Astley", duration: 213, syncedLyrics: "[00:01.00]wrong"),
            LRCLIBRecord(trackName: "Never Gonna Give You Up", artistName: "Cover Band", duration: 213, syncedLyrics: "[00:01.00]cover"),
            LRCLIBRecord(trackName: "Never Gonna Give You Up", artistName: "Rick Astley", duration: 215, plainLyrics: "plain"),
            LRCLIBRecord(trackName: "Never Gonna Give You Up", artistName: "Rick Astley", duration: 214, syncedLyrics: "[00:01.00]right"),
        ]
        let best = LRCLIBMatcher.best(records, query: rick, duration: 213)
        #expect(best?.syncedLyrics == "[00:01.00]right")
        #expect(LRCLIBMatcher.best([records[0]], query: rick, duration: 213) == nil)
    }
}
#endif
