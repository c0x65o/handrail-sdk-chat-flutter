import json,os,pathlib,subprocess,time
base=pathlib.Path('/opt/handrail/.handrail/codex-runs/fcc2ea23-2c25-4cde-aef8-2db8d419786a/tmp/review');out=pathlib.Path(__file__).resolve().parent;flutter=base/'flutter'
command=[str(flutter/'bin/cache/dart-sdk/bin/dart'),str(flutter/'bin/cache/flutter_tools.snapshot')]
env=dict(os.environ,FLUTTER_ROOT=str(flutter),PUB_CACHE=str(base/'pub-cache'),FLUTTER_SUPPRESS_ANALYTICS='true')
checks=[
 ('lifetime-route-owned-clean',['test','--no-pub','--concurrency=2','--reporter=expanded','test/dialog_lifetime_test.dart','--name','routeOwnsController=true']),
 ('lifetime-early-dispose-clean',['test','--no-pub','--concurrency=2','--reporter=expanded','test/dialog_lifetime_test.dart','--name','routeOwnsController=false']),
 ('review-specific-semantics',['test','--no-pub','--concurrency=2','--reporter=expanded','test/handrail_message_composer_test.dart','test/handrail_chat_workspace_test.dart','--name','review restored Link|review exported heading']),
 ('version-and-realtime',['test','--no-pub','--concurrency=2','--reporter=expanded','test/core_import_boundary_test.dart','test/realtime_session_transport_test.dart']),
]
results={}
for name,args in checks:
 start=time.monotonic()
 with (out/(name+'.txt')).open('w') as f:
  try:code=subprocess.run(command+args,cwd=base/'candidate',env=env,stdout=f,stderr=subprocess.STDOUT,timeout=300).returncode
  except subprocess.TimeoutExpired:code=124
 results[name]={'exit':code,'seconds':round(time.monotonic()-start,2),'command':command+args,'timeout_seconds':300}
 (out/'final-checks.json').write_text(json.dumps(results,indent=2)+'\n');print(name,code,flush=True)
