# Browser lab compatibility

This lab declares Flutter >=3.19.0 and Dart >=3.3.0 <4.0.0, matching the
SDK package. Its lockfile was resolved with Flutter 3.19.0 / Dart 3.3.0.
`web` permits 0.5.1 for Dart 3.3 and 1.x for newer Dart; lint tooling uses 4.x.
The separate native host in `../examples/flutter-erp/` requires Dart ^3.11.5.

The public HTTPS Git dependency remains frozen at
`51bc3e1411858ce38980f5beded683dee957d1a3`, with a matching resolved Git SHA
in `pubspec.lock`. That published revision predates the uncommitted compatibility
repair. Resolving this pin does not prove that the pinned SDK compiles on 3.19.

Compatibility validation compiles a disposable copy of this lab with the repaired
SDK source substituted only in that temporary fixture. This does not change
consumer pins, install into Hitcents, publish the repair, or establish live QA.
See the SDK README and the sibling JS repository's
`docs/validation/owner-task-24350c4f/flutter-compatibility/` for exact commands,
both dependency locks, results, and the subsequent independent QA requirement.
