# Selectively extract an official, digest-verified SDK into this run only.
import urllib.request,tarfile,hashlib,pathlib,json,os
base=pathlib.Path(os.environ['TMPDIR'])/'review'
out=pathlib.Path(__file__).resolve().parent
url='https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.19.0-stable.tar.xz'
expected='4cc1706fbd6e2a5c0ee34a6f8de875aae20904c9f47e18c88d2fcb25d9ea1a79'
h=hashlib.sha256();total=0;selected=[];omitted=[]
class Stream:
 def read(self,n=-1):
  global total
  data=response.read(n);h.update(data);total+=len(data);return data
with urllib.request.urlopen(url,timeout=60) as response:
 stream=Stream()
 with tarfile.open(fileobj=stream,mode='r|xz') as tar:
  for m in tar:
   n=m.name.removeprefix('flutter/')
   keep=any(n.startswith(x) for x in ['.git/','packages/','bin/cache/dart-sdk/','bin/cache/flutter_web_sdk/','bin/cache/pkg/','bin/cache/artifacts/engine/linux-x64/','bin/cache/artifacts/engine/common/','bin/cache/artifacts/material_fonts/','bin/internal/']) or (n.startswith('bin/cache/') and '/' not in n.removeprefix('bin/cache/')) or n in ['version','bin/flutter','bin/dart']
   # Omit IDE/devtools and unused VM tools; retain compiler/analyzer/runtime.
   if any(x in n for x in ['/devtools/','/resources/','/dartdevc.dart.snapshot','/dart2wasm','/gen_snapshot','/libflutter_linux_gtk','/flutter_linux/']):keep=False
   if keep and m.isfile():
    dest=base/'minimum-flutter'/n;dest.parent.mkdir(parents=True,exist_ok=True)
    with dest.open('wb') as f:
     src=tar.extractfile(m)
     while data:=src.read(1024*1024):f.write(data)
    dest.chmod(m.mode);selected.append({'path':n,'size':m.size})
   elif m.isfile():omitted.append({'path':n,'size':m.size})
 while stream.read(1024*1024):pass
actual=h.hexdigest()
(out/'minimum-download.json').write_text(json.dumps(dict(url=url,expected_sha256=expected,actual_sha256=actual,bytes=total,selected=selected,omitted=omitted),indent=2)+'\n')
assert actual==expected,(actual,expected)
print('Verified minimum official archive',actual,'selected bytes',sum(x['size'] for x in selected),flush=True)
