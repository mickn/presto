import AVFoundation
import Foundation
import PrestoCore

/// The demo script produced by scripts/make_demo.py: title cards, plus scenes that each carry the
/// voice recording Presto heard and the event log of that real run.
struct Timeline: Decodable {
    var fps: Int
    var segments: [Segment]
}

struct Segment: Decodable {
    enum Kind: String, Decodable { case card, scene }

    var kind: Kind
    var duration: Double
    var title: String
    var subtitle: String?
    var detail: String?
    /// Scenes: the recording, and when it starts within the segment.
    var audio: String?
    var audioOffset: Double?
    var events: [LogEvent]?
}

/// One line of ~/Library/Logs/Presto/events.jsonl, `t` in seconds from the start of the recording.
struct LogEvent: Decodable {
    var event: String
    var t: Double
    var text: String?
    var clause: String?
    var verb: String?
    var verb_conf: Double?
    var app: String?
    var app_conf: Double?
    var level: Int?
    var ms: Int?
    var action: String?
    var status: String?
    var reason: String?
    var picked: String?
    var fired: [FiredSummary]?

    struct FiredSummary: Decodable {
        var action: String
        var early_s: Double
    }

    /// The action of a "fired" event.
    var firedAction: Action? {
        guard event == "fired", let verb, let v = Verb(rawValue: verb) else { return nil }
        return Action(verb: v, app: app?.isEmpty == false ? app : nil,
                      level: (level ?? -1) >= 0 ? level : nil, text: text?.isEmpty == false ? text : nil)
    }
}

/// Loudness of a recording, one value per video frame, for the waveform and the HUD's pulse.
struct Envelope {
    var values: [Float]
    var fps: Double
    /// Seconds from the start of the recording to its last loud frame.
    var voiceEnd: Double

    init(url: URL, fps: Int) {
        self.fps = Double(fps)
        values = []
        voiceEnd = 0
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let samples = buffer.floatChannelData?[0] else { return }
        let perFrame = Int(file.processingFormat.sampleRate) / fps
        var index = 0
        while index < Int(buffer.frameLength) {
            let end = min(index + perFrame, Int(buffer.frameLength))
            var sum: Float = 0
            for i in index ..< end { sum += samples[i] * samples[i] }
            values.append((sum / Float(max(end - index, 1))).squareRoot())
            index = end
        }
        let peak = values.max() ?? 1
        if peak > 0 { values = values.map { $0 / peak } }
        if let last = values.lastIndex(where: { $0 > 0.08 }) { voiceEnd = Double(last + 1) / self.fps }
    }

    func value(at seconds: Double) -> Float {
        let i = Int(seconds * fps)
        return values.indices.contains(i) ? values[i] : 0
    }
}
