"""Bounded sequential Flutter/browser commands using the existing toolchains."""
import fcntl
import json
import os
import pathlib
import subprocess
import sys
import time

out = pathlib.Path(__file__).resolve().parent
repo = out.parents[2]
base = repo / 'build/link-input'
name, runtime, fixture, *args = sys.argv[1:]
sdk = (repo.parent / '.huddle-tmp/ack-review-toolchains/flutter' if runtime == 'minimum'
       else repo / 'build/ack-release-review/current-flutter')
env = dict(os.environ, FLUTTER_ROOT=str(sdk),
           PUB_CACHE=str(repo / 'build/ack-release-review/pub-cache'),
           TMPDIR=str(base/'tmp'), FLUTTER_SUPPRESS_ANALYTICS='true',
           BROWSER_TOOLS_DIR=str(repo.parent/'handrail-sdk-chat-js/examples/drop-in-react'),
           BROWSER_TMPDIR=str(repo.parent/'.huddle-tmp/li7'))
pathlib.Path(env['BROWSER_TMPDIR']).mkdir(exist_ok=True)
cmd = (['node', *args] if runtime == 'browser' else
       [str(sdk/'bin/cache/dart-sdk/bin/dart'), str(sdk/'bin/cache/flutter_tools.snapshot'), *args])
slots = [(pathlib.Path(os.environ['HANDRAIL_CODEX_HEAVY_COMMAND_LOCK_DIR'])/f'slot-{i}.lock').open('a') for i in range(2)]
lock = None
while lock is None:
    for slot in slots:
        try:
            fcntl.flock(slot, fcntl.LOCK_EX|fcntl.LOCK_NB)
            lock = slot
            break
        except BlockingIOError:
            pass
    if lock is None:
        time.sleep(1)

def heavy():
    leaf = pathlib.Path(os.environ['HANDRAIL_CODEX_DELEGATED_CGROUP_PATH'])/'link-input'
    leaf.mkdir(exist_ok=True)
    (leaf/'cgroup.procs').write_text('0')

start = time.monotonic()
with (out/(name+'.txt')).open('w') as log:
    try:
        code = subprocess.run(cmd, cwd=base/fixture, env=env, stdout=log,
                              stderr=subprocess.STDOUT, timeout=300, preexec_fn=heavy).returncode
    except subprocess.TimeoutExpired:
        code = 124
(out/(name+'.run.json')).write_text(json.dumps(dict(exit=code,
    seconds=round(time.monotonic()-start, 2), command=cmd, fixture=fixture,
    timeout_seconds=300), indent=2)+'\n')
print(name, code, flush=True)
sys.exit(code)
