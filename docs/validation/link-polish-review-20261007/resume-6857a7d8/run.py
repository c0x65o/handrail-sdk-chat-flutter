import os,pathlib,subprocess,json,time,sys,fcntl
base=pathlib.Path(os.environ['TMPDIR'])/'review'
out=pathlib.Path(__file__).resolve().parent
name,fixture,*args=sys.argv[1:]
f=base/('minimum-flutter' if name.startswith('minimum') else 'flutter')
env=dict(os.environ,HANDRAIL_WIDGET_EVIDENCE_DIR=str(out/name) if 'layout' in name else '',FLUTTER_ROOT=str(f),PUB_CACHE=str(base/'pub-cache'),FLUTTER_SUPPRESS_ANALYTICS='true')
cmd=[str(f/'bin/cache/dart-sdk/bin/dart'),str(f/'bin/cache/flutter_tools.snapshot')]+args
# Participate in the worker's native heavy-command slots and delegated cgroup.
lockdir=pathlib.Path(os.environ['HANDRAIL_CODEX_HEAVY_COMMAND_LOCK_DIR'])
slots=[(lockdir/f'slot-{i}.lock').open('a') for i in range(2)]
lock=None
while lock is None:
 for slot in slots:
  try:
   fcntl.flock(slot,fcntl.LOCK_EX|fcntl.LOCK_NB);lock=slot;break
  except BlockingIOError: pass
 if lock is None: time.sleep(1)
def heavy():
 leaf=pathlib.Path(os.environ['HANDRAIL_CODEX_DELEGATED_CGROUP_PATH'])/'link-polish-validation'
 leaf.mkdir(exist_ok=True)
 (leaf/'cgroup.procs').write_text('0')
 print('Native delegated cgroup:',pathlib.Path('/proc/self/cgroup').read_text().strip(),flush=True)
free=os.statvfs(base)
assert free.f_bavail*free.f_frsize > 2*1024**3, 'Less than 2 GiB validation headroom'
start=time.monotonic()
with (out/(name+'.txt')).open('w') as log:
 try: code=subprocess.run(cmd,cwd=base/fixture,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=300,preexec_fn=heavy).returncode
 except subprocess.TimeoutExpired: code=124
(out/(name+'.json')).write_text(json.dumps(dict(exit=code,seconds=round(time.monotonic()-start,2),command=cmd,fixture=fixture,timeout_seconds=300),indent=2)+'\n')
print(name,code,flush=True)
