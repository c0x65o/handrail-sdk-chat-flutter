import pathlib, os, subprocess, json, time, fcntl, sys
out=pathlib.Path(__file__).resolve().parent
repo=out.parents[2]
base=repo/'build/ack-release-review'
phase=sys.argv[1]
short_tmp=repo.parent/'.huddle-tmp/a8336'
short_tmp.mkdir(exist_ok=True)
env=dict(os.environ, BROWSER_TOOLS_DIR=str(repo.parent/'handrail-sdk-chat-js/examples/drop-in-react'),
         BROWSER_TMPDIR=str(short_tmp))
slots=[(pathlib.Path(os.environ['HANDRAIL_CODEX_HEAVY_COMMAND_LOCK_DIR'])/f'slot-{i}.lock').open('a') for i in range(2)]
lock=None
while lock is None:
    for slot in slots:
        try: fcntl.flock(slot,fcntl.LOCK_EX|fcntl.LOCK_NB);lock=slot;break
        except BlockingIOError: pass
    if lock is None: time.sleep(1)
def heavy():
    leaf=pathlib.Path(os.environ['HANDRAIL_CODEX_DELEGATED_CGROUP_PATH'])/'ack-release-review'
    leaf.mkdir(exist_ok=True);(leaf/'cgroup.procs').write_text('0')
cmd=['node',str(out/'browser_layout.mjs'),str(base/'minimum/build/web'),str(out),phase]
start=time.monotonic()
with (out/(phase+'.txt')).open('w') as log:
    try: code=subprocess.run(cmd,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=300,preexec_fn=heavy).returncode
    except subprocess.TimeoutExpired: code=124
(out/(phase+'-run.json')).write_text(json.dumps(dict(exit=code,seconds=round(time.monotonic()-start,2),command=cmd,timeout_seconds=300),indent=2)+'\n')
print(phase,code)
