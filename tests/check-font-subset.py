from pathlib import Path
import hashlib, importlib.util, tempfile, os, sys
from fontTools.ttLib import TTFont
root=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('font_subset',root/'QuickPeek/QuickPeek/font_subset.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
fixture = sys.argv[1] if len(sys.argv) > 1 else os.environ.get('QP_FONT_FIXTURE')
if not fixture:
 raise SystemExit('Provide a Chinese TTF/OTF: python3 tests/check-font-subset.py /path/to/font.ttf (or set QP_FONT_FIXTURE)')
source=Path(fixture).expanduser()
if not source.is_file(): raise SystemExit(f'Font fixture not found: {source}')
original=hashlib.sha256(source.read_bytes()).hexdigest()
text=''.join(chr(c) for c in range(32,127))+'‘’“”–—…•·©®™€£¥¢°±×÷‰'
with tempfile.TemporaryDirectory() as d:
 out=Path(d)/'Latin.ttf'
 result=m.export(source,out,text)
 with TTFont(source) as a,TTFont(out) as b:
  ac,bc=a.getBestCmap(),b.getBestCmap()
  assert set(bc)==set(ac)&set(map(ord,text))
  assert all(not 0x3400<=c<=0x9fff for c in bc)
  assert all(c in bc for c in map(ord,'ABCxyz0129!?'))
  for c in bc: assert a['hmtx'][ac[c]]==b['hmtx'][bc[c]]
  assert a['name'].getDebugName(6)!=b['name'].getDebugName(6)
  assert out.stat().st_size<source.stat().st_size
  print('PASS Chinese font -> Latin subset:',result)
 custom=Path(d)/'Custom.ttf'; m.export(source,custom,'A汉')
 with TTFont(custom) as f: assert set(f.getBestCmap())=={ord('A'),ord('汉')}
 try:m.export(source,source,text)
 except ValueError:pass
 else:raise AssertionError('source overwrite accepted')
 try:m.export(source,Path(d)/'empty.ttf','\U0010FFFF')
 except ValueError:pass
 else:raise AssertionError('empty subset accepted')
 assert hashlib.sha256(source.read_bytes()).hexdigest()==original
 print('PASS custom characters, empty selection, original identity, source protection')
