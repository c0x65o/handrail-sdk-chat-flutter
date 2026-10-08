"""Materialize small fixtures only; reuse existing Flutter SDKs and pub cache.

No SDK downloads/copies, path dependencies, or source modification. Run from
any directory. Existing source fixtures are intentionally not overwritten.
"""
import pathlib
import shutil

out = pathlib.Path(__file__).resolve().parent
repo = out.parents[2]
base = repo/'build/link-input'
base.mkdir(exist_ok=True)
(base/'tmp').mkdir(exist_ok=True)
for runtime in ['current', 'minimum']:
    consumer = base/(runtime+'-consumer')
    consumer.mkdir(exist_ok=True)
    (consumer/'lib').mkdir(exist_ok=True)
    (consumer/'web').mkdir(exist_ok=True)
    shutil.copy2(out/'probe.dart', consumer/'lib/main.dart')
    for name in ['pubspec.yaml', 'pubspec.lock']:
        shutil.copy2(out/(runtime+'-consumer-'+name), consumer/name)
    shutil.copy2(out/('minimum-index.html' if runtime == 'minimum' else 'current-index.html'),
                 consumer/'web/index.html')
    source = base/(runtime+'-source')
    if source.exists():
        continue
    source.mkdir()
    for name in ['lib', 'test', '.handrail']:
        shutil.copytree(repo/name, source/name)
    for name in ['pubspec.yaml', 'analysis_options.yaml']:
        shutil.copy2(repo/name, source/name)
    shutil.copy2(repo/'pubspec.lock' if runtime == 'current' else
                 out/'minimum-source-pubspec.lock', source/'pubspec.lock')
