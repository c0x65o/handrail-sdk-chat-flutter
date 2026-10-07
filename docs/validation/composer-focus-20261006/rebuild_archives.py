"""Rebuild the exact retained fixture archives using a private Flutter toolchain.
Usage: python rebuild_archives.py EVIDENCE_DIR WORK_DIR FLUTTER_ROOT PRIVATE_PUB_CACHE
"""
import hashlib, json, os, pathlib, subprocess, sys, time
bundle, work, flutter_root, cache = [pathlib.Path(p).resolve() for p in sys.argv[1:]]
env = dict(os.environ, FLUTTER_ROOT=str(flutter_root), PUB_CACHE=str(cache), FLUTTER_SUPPRESS_ANALYTICS='true')
flutter = str(flutter_root/'bin/flutter')
results = {}
for phase in ['baseline', 'candidate']:
    source = work/('custody-'+phase)
    source.mkdir(parents=True, exist_ok=False)
    archive = bundle/(phase+'-sources.tar.gz')
    subprocess.run(['tar', '-xzf', str(archive), '-C', str(source)], check=True)
    commands = [[flutter,'pub','get','--no-example'], [flutter,'build','web','--release','--no-pub','--no-web-resources-cdn','--target','tool/focus_probe.dart']]
    results[phase] = {'source_archive_sha256':hashlib.sha256(archive.read_bytes()).hexdigest(), 'commands':commands}
    for label, command in zip(['custody-pub-get','build'],commands):
        started=time.monotonic()
        with (bundle/f'{phase}-{label}.txt').open('w') as log:
            result=subprocess.run(command,cwd=source,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=300)
        results[phase][label]={'exit':result.returncode,'seconds':round(time.monotonic()-started,2)}
        if result.returncode: raise SystemExit(f'{phase} {label} failed: {result.returncode}')
    results[phase]['main_dart_js_sha256']=hashlib.sha256((source/'build/web/main.dart.js').read_bytes()).hexdigest()
    print(phase,results[phase]['main_dart_js_sha256'],flush=True)
(bundle/'archive-rebuilds.json').write_text(json.dumps(results,indent=2)+'\n')
