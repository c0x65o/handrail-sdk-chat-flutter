"""Run qualification checks sequentially against an unpacked SDK source fixture.
Usage: python run_checks.py SOURCE FLUTTER_ROOT PRIVATE_PUB_CACHE OUTPUT PREFIX
"""
import json, os, pathlib, subprocess, sys, time
source, flutter_root, pub_cache, output, prefix = map(pathlib.Path, sys.argv[1:])
output = output.resolve()
env = dict(os.environ, FLUTTER_ROOT=str(flutter_root), PUB_CACHE=str(pub_cache), FLUTTER_SUPPRESS_ANALYTICS='true')
flutter = str(flutter_root / 'bin/flutter')
tests = ['core_import_boundary_test.dart', 'handrail_message_composer_test.dart',
         'durable_resource_event_reducer_test.dart', 'realtime_session_transport_test.dart',
         'draft_runtime_test.dart', 'handrail_chat_workspace_test.dart', 'handrail_thread_view_test.dart', 'offline_send_message_queue_test.dart',
         'offline_send_message_queue_pump_test.dart']
commands = {
    'toolchain': [flutter, '--version'],
    'tests': [flutter, 'test', '--no-pub', '--concurrency=2', '--reporter=expanded'] + ['test/' + t for t in tests],
    'scoped-analyze': [flutter, 'analyze', '--no-pub', 'lib/src/handrail_message_composer.dart', 'lib/src/handrail_thread_view.dart', 'lib/src/handrail_chat_workspace.dart', 'test/handrail_message_composer_test.dart', 'test/handrail_chat_workspace_test.dart', 'test/handrail_thread_view_test.dart', 'test/handrail_format_semantics_cases.dart', 'test/handrail_thread_header_cases.dart', 'test/handrail_control_hierarchy_cases.dart', 'test/handrail_named_thread_cases.dart'],
    'analyze': [flutter, 'analyze', '--no-pub', 'lib', 'test'],
}
results = {}
for name, command in commands.items():
    started = time.monotonic()
    with (output / f'{prefix}-{name}.txt').open('w') as log:
        try:
            result = subprocess.run(command, cwd=source, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=300)
            code = result.returncode
        except subprocess.TimeoutExpired:
            code = 124
    (output / f'{prefix}-{name}.exit').write_text(str(code) + '\n')
    results[name] = {'command': command, 'exit': code, 'seconds': round(time.monotonic()-started, 2), 'timeout_seconds': 300}
    print(name, code, flush=True)
(output / f'{prefix}-checks.json').write_text(json.dumps(results, indent=2) + '\n')
