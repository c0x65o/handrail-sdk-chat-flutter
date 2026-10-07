"""Run bounded local checks; fixtures are extracted into this run's scratch only."""
import json,os,pathlib,subprocess,time
base=pathlib.Path('/opt/handrail/.handrail/codex-runs/fcc2ea23-2c25-4cde-aef8-2db8d419786a/tmp/review')
out=pathlib.Path(__file__).resolve().parent
flutter=base/'flutter'
command=[str(flutter/'bin/cache/dart-sdk/bin/dart'),str(flutter/'bin/cache/flutter_tools.snapshot')]
env=dict(os.environ,FLUTTER_ROOT=str(flutter),PUB_CACHE=str(base/'pub-cache'),FLUTTER_SUPPRESS_ANALYTICS='true')
checks=[
 ('baseline-resolve','baseline',['pub','get','--no-example']),
 ('candidate-regressions','candidate',['test','--no-pub','--concurrency=2','--reporter=expanded','test/handrail_message_composer_test.dart','test/handrail_chat_workspace_test.dart','test/handrail_thread_view_test.dart','--name','single format action|one thread dismissal hierarchy|standalone thread title|format toolbar render']),
 ('baseline-regressions','baseline',['test','--no-pub','--concurrency=2','--reporter=expanded','test/handrail_message_composer_test.dart','test/handrail_chat_workspace_test.dart','test/handrail_thread_view_test.dart','--name','single format action|one thread dismissal hierarchy|standalone thread title|format toolbar render']),
 ('candidate-boundaries','candidate',['test','--no-pub','--concurrency=2','--reporter=expanded','test/handrail_message_composer_test.dart','test/handrail_chat_workspace_test.dart','test/handrail_thread_view_test.dart','--name','authority|revok|account|logout|identity|close callback|focus restoration|system Back|Escape|named thread|preferences|subscriptions']),
 ('durable-reducer','candidate',['test','--no-pub','--concurrency=2','--reporter=expanded','test/durable_resource_event_reducer_test.dart']),
 ('scoped-analysis','candidate',['analyze','--no-pub','lib/src/handrail_message_composer.dart','lib/src/handrail_thread_view.dart','lib/src/handrail_chat_workspace.dart','test/handrail_message_composer_test.dart','test/handrail_chat_workspace_test.dart','test/handrail_thread_view_test.dart']),
]
results={}
for name,fixture,args in checks:
 start=time.monotonic()
 with (out/(name+'.txt')).open('w') as f:
  try:code=subprocess.run(command+args,cwd=base/fixture,env=env,stdout=f,stderr=subprocess.STDOUT,timeout=300).returncode
  except subprocess.TimeoutExpired:code=124
 results[name]={'exit':code,'seconds':round(time.monotonic()-start,2),'command':command+args,'fixture':fixture,'timeout_seconds':300}
 (out/'checks.json').write_text(json.dumps(results,indent=2)+'\n')
 print(name,code,flush=True)
