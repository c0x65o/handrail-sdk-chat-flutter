import pathlib,os,subprocess,json,time,fcntl,sys
b=pathlib.Path(os.environ['TMPDIR'])/'review'
out=pathlib.Path(__file__).resolve().parent
phase,fixture,script,*overrides=sys.argv[1:]
env=dict(os.environ,BROWSER_TOOLS_DIR=str(b/'browser-tools'),BROWSER_TMPDIR='/opt/handrail/repos/handrail/handrail-chat/.huddle-tmp/r6857',MODES='sdk',WIDTHS='1050,320,390',ACTIVATIONS='pointer',REQUIRE_INPUT='1')
pathlib.Path(env['BROWSER_TMPDIR']).mkdir(exist_ok=True)
env.update(x.split('=',1) for x in overrides)
locks=[(pathlib.Path(os.environ['HANDRAIL_CODEX_HEAVY_COMMAND_LOCK_DIR'])/f'slot-{i}.lock').open('a') for i in range(2)];lock=None
while lock is None:
 for slot in locks:
  try:fcntl.flock(slot,fcntl.LOCK_EX|fcntl.LOCK_NB);lock=slot;break
  except BlockingIOError:pass
 if lock is None:time.sleep(1)
def heavy():
 leaf=pathlib.Path(os.environ['HANDRAIL_CODEX_DELEGATED_CGROUP_PATH'])/'link-polish-validation'
 leaf.mkdir(exist_ok=True)
 (leaf/'cgroup.procs').write_text('0')
cmd=['node',str(pathlib.Path(script).resolve()),str(b/fixture/'build/web'),str(out),phase];start=time.monotonic()
with (out/(phase+'.txt')).open('w') as f:
 try:code=subprocess.run(cmd,env=env,stdout=f,stderr=subprocess.STDOUT,timeout=300,preexec_fn=heavy).returncode
 except subprocess.TimeoutExpired:code=124
(out/(phase+'-run.json')).write_text(json.dumps(dict(exit=code,seconds=round(time.monotonic()-start,2),command=cmd,overrides=overrides,timeout_seconds=300),indent=2)+'\n')
print(phase,code,flush=True)
