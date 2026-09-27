import AppKit
import Foundation
import PrestoCore
import SwiftUI

// Renders the demo video's frames from a timeline made by scripts/make_demo.py and pipes them
// into ffmpeg. Usage: PrestoDemo <timeline.json> <out.mp4>

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: PrestoDemo <timeline.json> <out.mp4>\n".utf8))
    exit(2)
}
let timeline = try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
let output = arguments[2]
let fps = timeline.fps

// Lay segments end to end and gather everything that happens on the pretend desktop.
var world = World()
var starts: [Double] = []
var sceneIndex: [Int: Int] = [:]
var clock = 0.0
for (index, segment) in timeline.segments.enumerated() {
    starts.append(clock)
    if segment.kind == .scene, let audio = segment.audio, let events = segment.events {
        let offset = segment.audioOffset ?? 0
        var actions: [String: Action] = [:]
        for e in events { if let action = e.firedAction { actions[action.description] = action } }
        var early: [String: Double] = [:]
        let finished = events.first { $0.event == "finished" }
        for f in finished?.fired ?? [] { early[f.action] = f.early_s }
        let scene = SceneData(
            segmentStart: clock, audioStart: clock + offset, duration: segment.duration, title: segment.title,
            said: segment.subtitle ?? "", events: events, envelope: Envelope(url: URL(fileURLWithPath: audio), fps: fps),
            actions: actions, early: early, finished: finished?.t,
            speechEnd: events.first { $0.event == "speech_end" }?.t
        )
        sceneIndex[index] = world.scenes.count
        world.add(scene)
    }
    clock += segment.duration
}
world.loadIcons()
let total = Int((clock * Double(fps)).rounded())
print("rendering \(total) frames (\(String(format: "%.1f", clock)) s)")

// ffmpeg reads raw BGRA frames from stdin.
let ffmpeg = Process()
ffmpeg.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
ffmpeg.arguments = ["-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "1920x1080", "-r", "\(fps)",
                    "-i", "-", "-c:v", "libx264", "-preset", "medium", "-crf", "17", "-pix_fmt", "yuv420p", output]
let pipe = Pipe()
ffmpeg.standardInput = pipe
try ffmpeg.run()

let width = 1920, height = 1080
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!

for frame in 0 ..< total {
    let time = Double(frame) / Double(fps)
    let index = starts.lastIndex { $0 <= time } ?? 0
    let segment = timeline.segments[index]
    let view: AnyView
    if let s = sceneIndex[index] {
        let number = world.scenes.indices.firstIndex(of: s).map { $0 + 1 } ?? 1
        view = AnyView(SceneFrame(world: world, scene: world.scenes[s], number: number, time: time))
    } else {
        view = AnyView(CardFrame(segment: segment, local: time - starts[index]))
    }
    let renderer = ImageRenderer(content: view.frame(width: 1920, height: 1080))
    renderer.scale = 1
    guard let image = renderer.cgImage else { continue }
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    pipe.fileHandleForWriting.write(Data(bytes: context.data!, count: width * height * 4))
    if frame % 150 == 0 { print("frame \(frame)/\(total)") }
}
try pipe.fileHandleForWriting.close()
ffmpeg.waitUntilExit()
print(ffmpeg.terminationStatus == 0 ? "wrote \(output)" : "ffmpeg failed")
