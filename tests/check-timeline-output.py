#!/usr/bin/env python3
"""Verify decoded pictures and independently deleted audio in the real exports."""
import subprocess, array, math
from pathlib import Path
ff='/opt/homebrew/bin/ffmpeg'
p=Path('/tmp/quickpeek-edit-test')
def frame(name,t):
    return subprocess.check_output([ff,'-v','error','-ss',str(t),'-i',str(p/name),'-frames:v','1','-vf','scale=96:64','-f','rawvideo','-pix_fmt','rgb24','-'])
for output,source in [(0.5,0.5),(1.5,2.5),(2.5,4.5),(3.5,5.5)]:
    a=frame('timeline-batch.mp4',output);b=frame('source.mp4',source)
    error=sum(abs(x-y) for x,y in zip(a,b))/len(a)
    assert error<12,(output,source,error)
    print(f'PASS: output {output:.1f}s matches source {source:.1f}s (mean pixel error {error:.2f})')
def rms(t):
    raw=subprocess.check_output([ff,'-v','error','-ss',str(t),'-i',str(p/'timeline-detached.mp4'),'-t','0.3','-vn','-ac','1','-ar','16000','-f','f32le','-'])
    samples=array.array('f');samples.frombytes(raw)
    return math.sqrt(sum(x*x for x in samples)/max(1,len(samples)))
active=rms(.3);silent=rms(1.3);resumed=rms(2.3)
assert active>0.01 and silent<0.001 and resumed>0.01,(active,silent,resumed)
print(f'PASS: detached audio silence only at deleted interval: {active:.5f}, {silent:.5f}, {resumed:.5f}')

for output,source in [(0.5,2.5),(2.5,4.5),(4.5,0.5)]:
    a=frame('timeline-reordered.mp4',output);b=frame('source.mp4',source)
    assert len(a)==len(b) and len(a)>0
    error=sum(abs(x-y) for x,y in zip(a,b))/len(a)
    assert error<12,(output,source,error)
    print(f'PASS: reordered output {output:.1f}s matches source {source:.1f}s (mean pixel error {error:.2f})')

# A context export must contain the middle segment, not the full multiselection.
clip=p/'clip-exports/clip.mp4'
if clip.exists():
    for output,source in [(0.1,2.1),(1.5,3.5)]:
        a=frame('clip-exports/clip.mp4',output);b=frame('source.mp4',source)
        assert len(a)==len(b) and len(a)>0
        error=sum(abs(x-y) for x,y in zip(a,b))/len(a)
        assert error<12,(output,source,error)
        print(f'PASS: context clip {output:.1f}s matches source {source:.1f}s (mean pixel error {error:.2f})')
