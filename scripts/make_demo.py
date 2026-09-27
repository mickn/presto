#!/usr/bin/env python3
"""Make the demo video from a real run.

Each scene's command is spoken by a voice recording (from --voices, else macOS `say`), played
into Presto exactly like a live microphone, and really executed. Presto's event log from that run
drives the rendered video, so every timing on screen is measured, not animated by hand.

    scripts/make_demo.py --voices demo/voices --out demo/presto-demo.mp4

Voice files are looked up as <id>.mp3/.wav/.aiff for the ids in SCRIPT below. Optional music.mp3
(ducked under speech) and sfx.mp3 (played as each action runs) are picked up from the same folder.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build/Build/Products/Debug/Presto.app/Contents/MacOS/Presto")
RENDERER = os.path.join(ROOT, "build/Build/Products/Release/PrestoDemo")
FPS = 30
AUDIO_OFFSET = 0.6   # the HUD says "Listening…" briefly before the voice starts
SCENE_TAIL = 2.2     # time to show how early each action fired

SCRIPT = [
    {"id": "intro", "kind": "card", "title": "Presto", "detail": "voice commands that run before you finish talking",
     "say": "This is Presto. It acts on your voice before you finish the sentence."},
    {"id": "s1", "kind": "scene", "title": "Apps open mid-sentence",
     "say": "Open Calculator, and then open Chess."},
    {"id": "correct", "kind": "card", "title": "Change your mind", "subtitle": "Say “no” and it undoes the last step.",
     "say": "Change your mind halfway? It undoes, and corrects."},
    {"id": "s2", "kind": "scene", "title": "Corrections undo instantly",
     "say": "Open Maps. No, Weather."},
    {"id": "words", "kind": "card", "title": "Every word counts", "subtitle": "Numbers and searches wait for the whole thought.",
     "say": "Anything that needs every word, waits for it."},
    {"id": "s3", "kind": "scene", "title": "Numbers and searches wait for every word",
     "say": "Set the volume to twenty, and search for the best tacos in Austin."},
    {"id": "cleanup", "kind": "card", "title": "One breath, three apps", "subtitle": "Clauses run in order, as soon as each is clear.",
     "say": "And it cleans up just as fast."},
    {"id": "s4", "kind": "scene", "title": "Clean up in one breath",
     "say": "Quit Calculator, Chess, and Weather."},
    {"id": "outro", "kind": "card", "title": "Built on Jev", "subtitle": "On-device speech → Jev decisions in ~200 ms → actions",
     "detail": "github.com/mickn/presto",
     "say": "Every decision comes from Jev, a model that answers in probabilities, in about two hundred milliseconds. Presto is open source."},
]


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                         capture_output=True, text=True, check=True).stdout
    return float(out.strip())


def voice_file(item, voices, workdir):
    for ext in ("mp3", "wav", "aiff", "m4a"):
        path = os.path.join(voices or "", f"{item['id']}.{ext}")
        if voices and os.path.exists(path):
            return path
    path = os.path.join(workdir, f"{item['id']}.aiff")
    try:
        subprocess.run(["say", "-r", "180", "-o", path, item["say"]], check=True, timeout=20)
    except subprocess.TimeoutExpired:
        pass  # `say` sometimes lingers after writing the file
    return path


def run_scene(audio, execute):
    args = [APP, "--simulate-audio", audio, "--exit-when-done"] + ([] if execute else ["--dry-run"])
    out = subprocess.run(args, capture_output=True, text=True, timeout=120).stdout
    events = [json.loads(line) for line in out.splitlines() if line.startswith("{")]
    start = next(e["t"] for e in events if e["event"] == "audio_start")
    keep = {"heard", "jev", "fired", "executed", "undone", "speech_end", "finished", "cancelled", "chose"}
    result = []
    for e in events:
        if e["event"] in keep:
            e = dict(e)
            e["t"] = round(e["t"] - start, 3)
            e.pop("time", None)
            result.append(e)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--voices", help="folder with <id>.mp3 voice files")
    parser.add_argument("--out", default=os.path.join(ROOT, "demo/presto-demo.mp4"))
    parser.add_argument("--dry-run", action="store_true", help="don't execute the commands")
    parser.add_argument("--timeline", help="re-render a saved <out>.timeline.json instead of running Presto again")
    options = parser.parse_args()
    os.makedirs(os.path.dirname(options.out), exist_ok=True)
    workdir = tempfile.mkdtemp(prefix="presto-demo-")

    if options.timeline:
        with open(options.timeline) as f:
            segments = json.load(f)["segments"]
    else:
        segments = run_script(options, workdir)
    render(segments, options, workdir)


def run_script(options, workdir):
    volume = subprocess.run(["osascript", "-e", "output volume of (get volume settings)"], capture_output=True, text=True).stdout.strip()
    muted = subprocess.run(["osascript", "-e", "output muted of (get volume settings)"], capture_output=True, text=True).stdout.strip()
    segments, clock = [], 0.0
    try:
        for item in SCRIPT:
            audio = voice_file(item, options.voices, workdir)
            length = duration(audio)
            if item["kind"] == "card":
                segment = {"kind": "card", "title": item["title"], "subtitle": item.get("subtitle"),
                           "detail": item.get("detail"), "audio": audio, "duration": round(length + 0.9, 3)}
            else:
                events = run_scene(audio, not options.dry_run)
                finished = next((e["t"] for e in events if e["event"] == "finished"), length)
                fired = [e["action"] for e in events if e["event"] == "fired"]
                print(f"{item['id']}: {item['say']!r} -> {fired}")
                segment = {"kind": "scene", "title": item["title"], "subtitle": item["say"], "audio": audio,
                           "audioOffset": AUDIO_OFFSET, "events": events,
                           "duration": round(AUDIO_OFFSET + max(length, finished) + SCENE_TAIL, 3)}
            segments.append(segment)
            clock += segment["duration"]
    finally:
        if volume:
            subprocess.run(["osascript", "-e", f"set volume output volume {volume}",
                            "-e", f"set volume {'with' if muted == 'true' else 'without'} output muted"])

    return segments


def render(segments, options, workdir):
    audio_tracks, action_times, clock = [], [], 0.0
    for segment in segments:
        if segment["kind"] == "card":
            audio_tracks.append((segment["audio"], clock + 0.35))
        else:
            start = clock + segment["audioOffset"]
            audio_tracks.append((segment["audio"], start))
            action_times += [start + e["t"] for e in segment["events"]
                             if e["event"] == "executed" and e.get("status") in ("done", "skipped")]
        clock += segment["duration"]
    timeline = os.path.join(workdir, "timeline.json")
    with open(timeline, "w") as f:
        json.dump({"fps": FPS, "segments": segments}, f, indent=1)
    video = os.path.join(workdir, "video.mp4")
    subprocess.run([RENDERER, timeline, video], check=True)

    # Voices are levelled one by one, music ducks under them, and a soft blip marks each action.
    inputs, filters = [], []
    for i, (path, at) in enumerate(audio_tracks):
        inputs += ["-i", path]
        delay = int(at * 1000)
        filters.append(f"[{i + 1}:a]aformat=sample_rates=48000:channel_layouts=stereo,loudnorm=I=-16:TP=-2,"
                       f"aresample=48000,adelay={delay}|{delay}[v{i}]")
    count = len(audio_tracks)
    voices = "".join(f"[v{i}]" for i in range(count))
    filters.append(f"{voices}amix=inputs={count}:normalize=0:duration=longest,apad=whole_dur={clock:.3f},"
                   f"atrim=0:{clock:.3f},asplit=2[voice][sidechain]")
    layers = ["[voice]"]
    extra = count + 1
    sfx = os.path.join(options.voices or "", "sfx.mp3")
    if options.voices and os.path.exists(sfx) and action_times:
        inputs += ["-i", sfx]
        copies = "".join(f"[fx{i}]" for i in range(len(action_times)))
        filters.append(f"[{extra}:a]aformat=sample_rates=48000:channel_layouts=stereo,volume=14dB,asplit={len(action_times)}{copies}")
        for i, at in enumerate(action_times):
            filters.append(f"[fx{i}]adelay={int(at * 1000)}|{int(at * 1000)}[fxd{i}]")
        filters.append("".join(f"[fxd{i}]" for i in range(len(action_times)))
                       + f"amix=inputs={len(action_times)}:normalize=0,volume=0.5[fx]")
        layers.append("[fx]")
        extra += 1
    music = os.path.join(options.voices or "", "music.mp3")
    if options.voices and os.path.exists(music):
        inputs += ["-i", music]
        filters.append(f"[{extra}:a]aformat=sample_rates=48000:channel_layouts=stereo,atrim=0:{clock:.3f},volume=0.22,"
                       f"afade=t=in:d=1.5,afade=t=out:st={max(clock - 3, 0):.3f}:d=3[bed]")
        filters.append("[bed][sidechain]sidechaincompress=threshold=0.02:ratio=6:attack=15:release=450[music]")
        layers.append("[music]")
    else:
        filters.append("[sidechain]anullsink")
    filters.append("".join(layers) + f"amix=inputs={len(layers)}:normalize=0,alimiter=limit=0.95[aout]")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", video, *inputs, "-filter_complex", ";".join(filters),
                    "-map", "0:v", "-map", "[aout]", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-shortest",
                    "-movflags", "+faststart", options.out], check=True)
    with open(options.out.replace(".mp4", ".timeline.json"), "w") as f:
        json.dump({"fps": FPS, "segments": segments}, f, indent=1)
    print(f"wrote {options.out} ({clock:.1f} s)")


if __name__ == "__main__":
    sys.exit(main())
