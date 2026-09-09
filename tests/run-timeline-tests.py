#!/usr/bin/env python3
"""Run with Python 3 on macOS with Xcode and Homebrew ffmpeg installed."""
import hashlib, shutil, subprocess
from pathlib import Path
root=Path(__file__).resolve().parents[1]
media=Path('/tmp/quickpeek-edit-test');media.mkdir(exist_ok=True)
ff=shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
def run(args): subprocess.run(args,cwd=root,check=True)
source=media/'source.mp4'
if not source.exists():
    run([ff,'-v','error','-y','-f','lavfi','-i','testsrc=size=320x240:rate=30:duration=6','-f','lavfi','-i','sine=frequency=440:sample_rate=48000:duration=6','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac',str(source)])
before=hashlib.sha256(source.read_bytes()).hexdigest()
run([ff,'-v','error','-y','-display_rotation:v:0','90','-i',str(source),'-c','copy',str(media/'rotated.mp4')])
run([ff,'-v','error','-y','-i',str(source),'-an','-c:v','copy',str(media/'silent.mp4')])
run([ff,'-v','error','-y','-i',str(source),'-r','24','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac',str(media/'24fps.mp4')])
run(['swift','test','--package-path','QuickPeek/Packages/QuickPeekTimeline'])
run(['python3','tests/check-timeline-native.py'])
run(['python3','tests/check-timeline-output.py'])
assert hashlib.sha256(source.read_bytes()).hexdigest()==before
print('PASS: source SHA-256 unchanged:',before)
