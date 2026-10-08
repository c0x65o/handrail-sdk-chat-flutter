"""Run affected source checks sequentially, each bounded by run.py to 300s."""
import pathlib
import subprocess
import sys

out = pathlib.Path(__file__).resolve().parent
for runtime in ['current', 'minimum']:
    commands = [
        ('resolve', ['pub', 'get', '--no-example', '--offline', '--enforce-lockfile']),
        ('configured', ['test', '--no-pub', '--concurrency=2', '--reporter=expanded',
                        'test/core_import_boundary_test.dart',
                        'test/realtime_session_transport_test.dart',
                        'test/durable_resource_event_reducer_test.dart']),
        ('analysis', ['analyze', '--no-pub', 'lib/src/handrail_message_composer.dart',
                      'test/handrail_message_composer_test.dart',
                      'test/handrail_link_dialog_cases.dart']),
        ('links', ['test', '--no-pub', '--concurrency=2', '--reporter=expanded',
                   'test/handrail_message_composer_test.dart', '--name', 'link']),
    ]
    for label, args in commands:
        subprocess.run([sys.executable, str(out/'run.py'), runtime+'-source-'+label,
                        runtime, runtime+'-source', *args], check=True)
subprocess.run([sys.executable, str(out/'run.py'), 'minimum-final-build', 'minimum',
                'minimum-consumer', 'build', 'web', '--no-pub', '--release',
                '--web-renderer', 'canvaskit', '--no-web-resources-cdn'], check=True)
# The official 3.19 bootstrap differs from current Flutter's bootstrap.
repo = out.parents[2]
build = repo/'build/link-input/minimum-consumer/build/web'
(build/'index.html').write_bytes(
    (repo/'docs/validation/ack-release-review-20261007/minimum-index-adapter.html').read_bytes())
subprocess.run([sys.executable, str(out/'run.py'), 'minimum-final-browser', 'browser',
                'minimum-consumer', str(out/'browser.mjs'), str(build), str(out),
                'minimum-final', 'pointer-uppercase'], check=True)
