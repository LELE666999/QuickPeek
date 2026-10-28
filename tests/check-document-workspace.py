#!/usr/bin/env python3
"""Exercise the production PDF controller, exports, AI client, and offline WKWebView renderer."""
from pathlib import Path
import http.server,json,os,plistlib,shutil,subprocess,threading,zipfile
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/document-checks';OUT.mkdir(parents=True,exist_ok=True)
for p in OUT.glob('*diagnostic.txt'):p.unlink()
# A PDF with genuine stamp/signature appearance streams, plus a print-only stamp.
objects=[]
def obj(value):objects.append(value.encode('ascii'));return len(objects)
def stream(value,extra=''):
 return f'<< /Length {len(value.encode("ascii"))} {extra} >>\nstream\n{value}\nendstream'
obj('<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [11 0 R] /NeedAppearances false >> >>')
obj('<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>')
obj('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 6 0 R >> >> /Contents 7 0 R /Annots [10 0 R 11 0 R 12 0 R] >>')
obj('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 6 0 R >> >> /Contents 8 0 R >>')
obj('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 792 612] /Resources << /Font << /F1 6 0 R >> >> /Contents 9 0 R >>')
obj('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')
for text in ['QuickPeek PDF TEST - PAGE ONE','Second page: total amount 123.45','Third page - LANDSCAPE']:
 obj(stream(f'BT /F1 20 Tf 40 560 Td ({text}) Tj ET'))
obj('<< /Type /Annot /Subtype /Stamp /Rect [100 300 300 400] /F 4 /AP << /N 13 0 R >> /Name /Approved /Contents (STAMP AP TEST) >>')
obj('<< /Type /Annot /Subtype /Widget /FT /Sig /T (SealSignature) /Rect [100 160 300 240] /F 4 /AP << /N 14 0 R >> >>')
obj('<< /Type /Annot /Subtype /Stamp /Rect [100 50 300 130] /F 36 /AP << /N 15 0 R >> /Contents (PRINT ONLY) >>')
for color,text in [('1 0 0','APPROVED'),('0 0.65 0','SIGNED'),('0 0 1','PRINT ONLY')]:
 obj(stream(f'{color} RG 5 w 5 5 190 70 re S BT /F1 20 Tf {color} rg 18 30 Td ({text}) Tj ET','/Type /XObject /Subtype /Form /BBox [0 0 200 80] /Resources << /Font << /F1 6 0 R >> >>'))
data=b'%PDF-1.7\n';offsets=[0]
for i,o in enumerate(objects,1): offsets.append(len(data));data+=f'{i} 0 obj\n'.encode()+o+b'\nendobj\n'
xref=len(data);data+=f'xref\n0 {len(objects)+1}\n0000000000 65535 f \n'.encode()
for offset in offsets[1:]:data+=f'{offset:010d} 00000 n \n'.encode()
data+=f'trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF'.encode()
(OUT/'stamp-fixture.pdf').write_bytes(data)
requests=[]
class Handler(http.server.BaseHTTPRequestHandler):
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length'])));requests.append((self.path,body,self.headers.get('Authorization'),self.headers.get('api-key')))
  status=401 if self.path.startswith('/error') else 307 if self.path.startswith('/redirect') else 200
  self.send_response(status)
  if status==307:self.send_header('Location','https://example.invalid/must-not-follow')
  self.send_header('Content-Type','application/json');self.end_headers()
  content={'choices':[{'message':{'content':'Fixture AI answer [第 1 页]'},'finish_reason':'length' if self.path.startswith('/length') else 'stop'}]}
  self.wfile.write(json.dumps(content).encode())
 def log_message(self,*args):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
app=OUT/'DocumentChecks.app';mac=app/'Contents/MacOS';resources=app/'Contents/Resources';mac.mkdir(parents=True,exist_ok=True);resources.mkdir(parents=True,exist_ok=True)
shutil.copytree(ROOT/'QuickPeek/QuickPeek/PDFCompatibility',resources/'PDFCompatibility',dirs_exist_ok=True)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.quickpeek.document-checks','CFBundleExecutable':'DocumentChecks','CFBundleName':'DocumentChecks','NSHighResolutionCapable':True,'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True}}))
sources=[ROOT/'QuickPeek/QuickPeek'/name for name in ['GlassControls.swift','PDFWorkspace.swift','DocumentExport.swift','PDFCompatibility.swift','DocumentAI.swift']]
subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','6','-target','arm64-apple-macos26.0',*map(str,sources),str(ROOT/'tests/document-workspace-checks.swift'),'-o',str(mac/'DocumentChecks')],check=True,cwd=ROOT)
env=dict(os.environ,QP_DOC_TEST_ROOT=str(OUT),QP_DOC_TEST_PORT=str(server.server_port))
try:subprocess.run([str(mac/'DocumentChecks')],env=env,check=True,timeout=120)
finally:server.shutdown()
assert len(requests)>=6,requests
assert all((x[2] is None and x[3]=='fixture-key') if x[0].startswith('/mimo') else (x[2]=='Bearer fixture-key' and x[3] is None) for x in requests),requests
assert all('fixture-key' not in json.dumps(x[1]) for x in requests)
with zipfile.ZipFile(OUT/'test.pptx') as z:
 assert len([n for n in z.namelist() if n.startswith('ppt/slides/slide') and n.endswith('.xml')])==3
 import xml.etree.ElementTree as ET
 for n in z.namelist():
  if n.endswith(('.xml','.rels')):ET.fromstring(z.read(n))
with zipfile.ZipFile(OUT/'test.docx') as z:assert 'word/document.xml' in z.namelist()
print('PASS: PDF appearances, non-destructive edits, native viewing, offline PDF.js, document exports, AI HTTP errors/redirects/chunking')
