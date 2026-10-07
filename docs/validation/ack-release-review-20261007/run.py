import os, pathlib, subprocess, json, time, sys, fcntl

out = pathlib.Path(__file__).resolve().parent
repo = out.parents[2]
base = repo / 'build/ack-release-review'
name, runtime, *args = sys.argv[1:]
sdk = (repo.parent / '.huddle-tmp/ack-review-toolchains/flutter' if runtime.startswith('minimum')
       else base / 'current-flutter')
env = dict(os.environ, FLUTTER_ROOT=str(sdk), PUB_CACHE=str(base/'pub-cache'),
           TMPDIR=str(base/'tmp'), FLUTTER_SUPPRESS_ANALYTICS='true',
           HANDRAIL_WIDGET_EVIDENCE_DIR=str(out/name) if 'layout' in name else '')
cmd = [str(sdk/'bin/cache/dart-sdk/bin/dart'), str(sdk/'bin/cache/flutter_tools.snapshot'), *args]
slots = [(pathlib.Path(os.environ['HANDRAIL_CODEX_HEAVY_COMMAND_LOCK_DIR'])/f'slot-{i}.lock').open('a') for i in range(2)]
lock = None
while lock is None:
    for slot in slots:
        try:
            fcntl.flock(slot, fcntl.LOCK_EX|fcntl.LOCK_NB); lock=slot; break
        except BlockingIOError: pass
    if lock is None: time.sleep(1)
def heavy():
    leaf=pathlib.Path(os.environ['HANDRAIL_CODEX_DELEGATED_CGROUP_PATH'])/'ack-release-review'
    leaf.mkdir(exist_ok=True)
    (leaf/'cgroup.procs').write_text('0')
assert (lambda s:s.f_bavail*s.f_frsize)(os.statvfs(base)) > 2*1024**3
start=time.monotonic()
with (out/(name+'.txt')).open('w') as log:
    try: code=subprocess.run(cmd, cwd=base/runtime, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=300, preexec_fn=heavy).returncode
    except subprocess.TimeoutExpired: code=124
(out/(name+'.json')).write_text(json.dumps(dict(exit=code,seconds=round(time.monotonic()-start,2),command=cmd,fixture=runtime,timeout_seconds=300),indent=2)+'\n')
print(name,code,flush=True)
