import urllib.request,tarfile,hashlib,pathlib,json,io,time,os
base=pathlib.Path(__file__).resolve().parent
out=pathlib.Path('/opt/handrail/repos/handrail/handrail-chat/handrail-sdk-chat-flutter/docs/validation/link-dialog-20261007')
url='https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.19.0-stable.tar.xz'
expected='4cc1706fbd6e2a5c0ee34a6f8de875aae20904c9f47e18c88d2fcb25d9ea1a79'
hash=hashlib.sha256(); total=0
class Stream:
 def read(self,n=-1):
  global total
  data=response.read(n);hash.update(data);total+=len(data);return data
selected=[]
with urllib.request.urlopen(url,timeout=60) as response:
 stream=Stream()
 with tarfile.open(fileobj=stream,mode='r|xz') as tar:
  for m in tar:
   n=m.name
   keep=any(n.startswith('flutter/'+x) for x in ['.git/','packages/','dev/','examples/','bin/cache/dart-sdk/','bin/cache/flutter_web_sdk/','bin/cache/pkg/','bin/cache/artifacts/engine/linux-x64/','bin/cache/artifacts/engine/common/','bin/cache/artifacts/material_fonts/','bin/internal/']) or ('/' not in n.removeprefix('flutter/bin/cache/') if n.startswith('flutter/bin/cache/') else False) or n in ['flutter/version','flutter/bin/flutter','flutter/bin/dart']
   if keep and m.isfile():
    dest=base/'minimum-flutter'/n.removeprefix('flutter/');dest.parent.mkdir(parents=True,exist_ok=True)
    with dest.open('wb') as f:
     src=tar.extractfile(m)
     while data:=src.read(1024*1024):f.write(data)
    dest.chmod(m.mode);selected.append(n)
 while stream.read(1024*1024): pass
actual=hash.hexdigest()
(out/'minimum-download.json').write_text(json.dumps(dict(url=url,expected_sha256=expected,actual_sha256=actual,bytes=total,selected_files=len(selected)),indent=2)+'\n')
assert actual==expected,(actual,expected)
print('minimum archive verified',actual,flush=True)
