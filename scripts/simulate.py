#!/usr/bin/env python3
"""Speak commands with `say`, run them through the real Presto pipeline (recording -> live speech
recognition -> Jev -> engine -> executor), and print what happened and how early.

    scripts/simulate.py "open calculator and then open textedit"      # dry run: nothing executes
    scripts/simulate.py --execute "open calculator"                   # really does it
    scripts/simulate.py --suite                                       # the standard dry-run suite
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build/Build/Products/Debug/Presto.app/Contents/MacOS/Presto")

# (sentence, expected net actions)
SUITE = [
    ("Open Calculator and then open TextEdit", ["open_app Calculator", "open_app TextEdit"]),
    ("Open Notes and Messages", ["open_app Notes", "open_app Messages"]),
    ("Open Safari, no, Chrome", ["open_app Google Chrome"]),
    ("Set the volume to 30 and pause the music", ["set_volume 30%", "play_pause"]),
    ("Make it louder, then skip this song", ["volume_up", "next_track"]),
    ("Quit Calculator", ["quit_app Calculator"]),
    ("Search for best pizza in Brooklyn", ['web_search "best pizza in Brooklyn"']),
    ("Go to github dot com", ['open_website "https://github.com"']),
    ("Go to youtube dot com", ['open_website "https://youtube.com"']),
    ("Type hello world", ['type_text "hello world"']),
    ("Take a screenshot and switch to dark mode", ["screenshot", "dark_mode"]),
    ("Never mind", ["cancel"]),
    ("Bring up my calendar and make it full screen", ["open_app Calendar", "fullscreen"]),
]


def run(sentence, execute, rate):
    audio = os.path.join(tempfile.mkdtemp(), "command.aiff")
    # `say` sometimes lingers after writing the file; the file is complete by then.
    try:
        subprocess.run(["say", "-r", str(rate), "-o", audio, sentence], check=True, timeout=15)
    except subprocess.TimeoutExpired:
        pass
    duration = float(subprocess.run(["afinfo", audio], capture_output=True, text=True).stdout
                     .split("estimated duration:")[1].split()[0])
    args = [APP, "--simulate-audio", audio, "--exit-when-done"] + ([] if execute else ["--dry-run"])
    out = subprocess.run(args, capture_output=True, text=True, timeout=90).stdout
    events = []
    for line in out.splitlines():
        try:
            events.append(json.loads(line))
        except ValueError:
            pass
    start = next((e["t"] for e in events if e["event"] == "listen_start"), 0)
    lines, net, finished = [], [], None
    for e in events:
        t = e["t"] - start
        if e["event"] == "heard":
            lines.append(f"  {t:5.2f}s  heard  “{e['text']}”")
        elif e["event"] == "fired":
            lines.append(f"  {t:5.2f}s  ⚡ {e['action']}")
            net.append(e["action"])
        elif e["event"] == "executed" and e["status"] != "done" and e.get("reason") != "dry run":
            lines.append(f"  {t:5.2f}s     {e['status']}: {e.get('reason', '')}")
        elif e["event"] == "undone":
            lines.append(f"  {t:5.2f}s  ↩ undid {e['action']}")
            if e["action"] in net:
                net.remove(e["action"])
        elif e["event"] == "cancelled":
            net.append("cancel")
        elif e["event"] == "finished":
            finished = e
    # Undo in dry run isn't executed, so apply corrections from the engine's own record.
    if finished and not execute:
        net = [f["action"] for f in finished["fired"]] + (["cancel"] if finished["cancelled"] else [])
    return duration, lines, net, finished


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("sentences", nargs="*")
    parser.add_argument("--execute", action="store_true", help="really perform the actions")
    parser.add_argument("--suite", action="store_true")
    parser.add_argument("--rate", type=int, default=185, help="speaking rate, words per minute")
    options = parser.parse_args()
    cases = SUITE if options.suite else [(s, None) for s in options.sentences]
    if not cases:
        parser.error("give a sentence or --suite")
    passed = 0
    for sentence, expected in cases:
        duration, lines, net, finished = run(sentence, options.execute, options.rate)
        ok = expected is None or net == expected
        passed += ok
        print(f"{'PASS' if ok else 'FAIL'}  “{sentence}”  (audio {duration:.2f}s)")
        print("\n".join(lines))
        if finished:
            for f in finished["fired"]:
                print(f"         {f['action']}: {f['early_s']:+.2f}s before the voice stopped")
            print(f"         {finished['jev_calls']} Jev calls, mean {finished['jev_mean_ms']} ms")
        if not ok:
            print(f"         expected {expected}, got {net}")
    print(f"\n{passed}/{len(cases)} passed")
    sys.exit(0 if passed == len(cases) else 1)


if __name__ == "__main__":
    main()
