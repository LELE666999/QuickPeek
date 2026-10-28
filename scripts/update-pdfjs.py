#!/usr/bin/env python3
"""Rebuild the pinned offline PDF renderer. Requires Python 3, Node and npm only at build time."""
from pathlib import Path
import base64,hashlib,io,json,shutil,subprocess,tarfile,tempfile,urllib.request
VERSION='6.4.299'
INTEGRITY='AVl138zALtfaAPvADulE0PZThbYzCBS79nL4pOSL/6Sm/4AH5A21BD9VHt97OlCuzJuCpmeZtAtkinisF4Vb1g=='
ROOT=Path(__file__).resolve().parents[1]/'QuickPeek/QuickPeek/PDFCompatibility'
url=f'https://registry.npmjs.org/pdfjs-dist/-/pdfjs-dist-{VERSION}.tgz'
archive=urllib.request.urlopen(url,timeout=60).read()
assert base64.b64encode(hashlib.sha512(archive).digest()).decode()==INTEGRITY,'PDF.js archive integrity mismatch'
with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
 for member in tar.getmembers():
  name=member.name.removeprefix('package/')
  if not member.isfile() or name.endswith('.map'):continue
  if name=='LICENSE' or name.startswith(('cmaps/','standard_fonts/','wasm/')):
   assert '..' not in Path(name).parts
   target=ROOT/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(tar.extractfile(member).read())
 with tempfile.TemporaryDirectory() as tmp:
  for source,global_name in [('pdf','pdfjsLib'),('pdf.worker','pdfjsWorker')]:
   original=tar.extractfile(f'package/build/{source}.mjs').read().decode()
   input_path=Path(tmp)/(source+'.mjs');input_path.write_text(original)
   output=ROOT/'engine'/(source+'.js');output.parent.mkdir(parents=True,exist_ok=True)
   subprocess.run(['npm','exec','--yes','--package=esbuild@0.25.12','--','esbuild',str(input_path),'--bundle','--format=iife','--global-name='+global_name,'--target=safari18','--outfile='+str(output)],check=True)
   header=original[:original.index(' * @licend')+len(' * @licend')]+'\n */\n'
   output.write_text(header+output.read_text())
(ROOT/'VERSION.json').write_text(json.dumps({'project':'Mozilla PDF.js','version':VERSION,'repository':'https://github.com/mozilla/pdf.js','archive':url,'sha512':INTEGRITY,'bundler':'esbuild 0.25.12','format':'classic IIFE for WKWebView file-origin support'},indent=2)+'\n')
print('Updated offline PDF.js',VERSION)
