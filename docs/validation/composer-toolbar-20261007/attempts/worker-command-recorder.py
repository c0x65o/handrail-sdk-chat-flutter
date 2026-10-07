import os,pathlib,subprocess,sys,time,json
w=pathlib.Path(__file__).parent
repo=pathlib.Path('/opt/handrail/repos/handrail/handrail-chat/handrail-sdk-chat-flutter')
out=repo/'docs/validation/composer-toolbar-20261007'
source,chain,label,*args=sys.argv[1:]
sdk=w/('flutter-'+chain)
env=dict(os.environ,FLUTTER_ROOT=str(sdk),PUB_CACHE=str(sdk/'bin/cache/pub-cache'),FLUTTER_SUPPRESS_ANALYTICS='true',TMPDIR=str(w))
start=time.monotonic()
with (out/(label+'.txt')).open('w') as f:
 try:
  result=subprocess.run([str(sdk/'bin/flutter'),*args],cwd=w/source,env=env,stdout=f,stderr=subprocess.STDOUT,timeout=300)
  code=result.returncode
 except subprocess.TimeoutExpired: code=124
(out/(label+'.json')).write_text(json.dumps({'exit':code,'seconds':time.monotonic()-start,'command':['flutter',*args],'source':source,'toolchain':chain,'cap':300},indent=2)+'\n')
print(label,code,flush=True)
raise SystemExit(code)
