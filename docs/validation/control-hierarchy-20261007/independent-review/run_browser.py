import json,os,pathlib,subprocess,time
base=pathlib.Path('/opt/handrail/.handrail/codex-runs/fcc2ea23-2c25-4cde-aef8-2db8d419786a/tmp/review');out=pathlib.Path(__file__).resolve().parent;ev=out.parent;flutter=base/'flutter'
env=dict(os.environ,FLUTTER_ROOT=str(flutter),PUB_CACHE=str(base/'pub-cache'),FLUTTER_SUPPRESS_ANALYTICS='true',BROWSER_TOOLS_DIR=str(base/'browser-tools'),BROWSER_TMPDIR='/opt/handrail/repos/handrail/handrail-chat/.huddle-tmp/r-fcc2',MODES='sdk',WIDTHS='390',ACTIVATIONS='pointer',REQUIRE_INPUT='1')
commands=[
 ('review-specific-semantics-final',[str(flutter/'bin/cache/dart-sdk/bin/dart'),str(flutter/'bin/cache/flutter_tools.snapshot'),'test','--no-pub','--concurrency=2','--reporter=expanded','test/handrail_message_composer_test.dart','test/handrail_chat_workspace_test.dart','--name','review restored Link|review exported heading'],{}),
 ('native-ax',['node',str(ev/'semantic_state_check.mjs'),str(base/'candidate/build/web'),str(out),'review'],{}),
 ('browser-semantics',['node',str(ev/'runtime_browser_check.mjs'),str(base/'candidate/build/web'),str(out),'review-semantics'],{'SEMANTICS':'on'}),
 ('browser-ordinary',['node',str(ev/'runtime_browser_check.mjs'),str(base/'candidate/build/web'),str(out),'review-ordinary'],{'SEMANTICS':'off'}),
]
results={}
for name,command,extra in commands:
 start=time.monotonic()
 with (out/(name+'.txt')).open('w') as f:
  try:code=subprocess.run(command,cwd=base/'candidate',env=dict(env,**extra),stdout=f,stderr=subprocess.STDOUT,timeout=300).returncode
  except subprocess.TimeoutExpired:code=124
 results[name]={'exit':code,'seconds':round(time.monotonic()-start,2),'command':command,'environment_overrides':extra,'timeout_seconds':300}
 (out/'browser-checks.json').write_text(json.dumps(results,indent=2)+'\n');print(name,code,flush=True)
