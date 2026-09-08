# Alice's successful Flutter DM send

Work request: `12c68f43-a552-4cb5-a4ec-3de3a942b25d`.
Finding: `ca39b9ed-cda7-4cbe-9212-23a1e4610931`.
Campaign: `298e20b4-4faf-4283-949d-3801cf437aa8`, dev.
Source work request: `8ff41fa4-8f28-4ee9-b884-7e87614c7db5`.
Source run: `fee77ab0-0d2f-42ba-825f-82575519ddf8`.

## Failure boundary

Handrail current context confirmed this project and work request. Dev-service
status reported both `chat-lab` (4167) and Mobile Preview (4115) stopped, with no
listeners. No service or project configuration was changed for this repair.

The three supplied screenshots were reviewed. The JSON attachment paths were
absent in this runner, so all three JSON artifacts were recovered through the
read-only `get_goal_completed_work_result` tool. Their bytes and SHA-256 hashes
are preserved in [campaign/](campaign/).

The captured send returned HTTP 201 for message
`c3376c1c-841b-4ad9-8156-ed7fde4d7aec`, sequence 4 in DM
`a184c0ce-84d7-4cde-a610-4d3558e7ebe2`, created at
`2026-09-07T18:02:11.417Z`. At `18:03:20.336Z`, Flutter was connected but still
displayed only messages 1–3 and retained the submitted text. Its durable stream
had advanced through the send timestamp. React and the subsequent Flutter reload
showed message 4. The campaign's read-only PostgreSQL snapshot records exactly
one such message. This evidence places the failure after successful persistence.

Source inspection and a failing local regression independently confirmed a
remaining application-code boundary: `sendMessage` reconciled the canonical
message and timeline ID, while the UI consumes `MessageTimelineMessage`
projections. Without the realtime echo, no projection was installed. The earlier
[named-thread repair](../flutter-named-threads/README.md) already fixed normalized
publication and HTTP-before-event reconciliation. In this workspace the composer
cleared before this patch; the missing timeline row still reproduced. The
campaign also used the stale assets documented by the earlier
[provenance repair](../flutter-served-provenance/README.md). These existing fixes
are preserved, not attributed to this patch. No env variable, provider credential,
managed resource, database migration, or authentication change is indicated.

## Change

After a successful send into a loaded conversation, if the authoritative row is
still missing from the UI projection, fetch one timeline row immediately after
the sent sequence minus one (`after=3&limit=1` for this campaign). Merge it through
the existing validated snapshot path, preserving history and server-provided
reaction/attachment metadata. An event that already supplied the row avoids the
extra read. HTTP/event reordering and redelivery retain one row.

This read runs independently of send completion, so the composer can clear and
accept the next message. Late results are ignored after disposal, identity
changes, or removal of the canonical message. A failed projection read does not
turn an accepted send into a failed send or trigger another POST; normal timeline
recovery remains available.

## Verification

- [Baseline regression](before-tests.log): with the fallback disabled, the
  connected Alice widget retained three rows after the exact captured HTTP 201.
  The composer-clear assertion passed; the four-row assertion failed. Three
  regression tests failed and the event-first case passed.
- [Relevant Flutter suites](tests.log): **211 passed**, using
  `flutter test --no-pub --concurrency=1` for `alice_send_reconciliation_test`,
  `send_message_client_test`, `handrail_message_composer_test`,
  `durable_resource_event_reducer_test` (the suggested check),
  `durable_message_event_reducer_test`, `named_thread_snapshot_test`, and
  `timeline_controller_test`.
- [Final regression](final-regression.log): **4 passed**; verifies the rendered fourth row,
  cleared editor, enabled Send after entering the next text, one POST, connected
  realtime with no message echo, a nonblocking delayed read, disposal, and both
  HTTP/event orderings. The final delayed response uses a valid one-row page.
- [Scoped Dart analysis](dart-analysis.log): **no issues found** in client source
  and the new test.
- `git diff --check` and original artifact SHA-256 verification passed.

Tests use narrow HTTP/socket fakes with the captured send response and canonical
DM rows, plus the existing draft HTTP fixture. They exercise the real Flutter
client, normalized store, timeline, and composer; they do not claim a new database
persistence check. No database state or dependency pins were changed.

The worker's Flutter SDK is read-only. Checks used its cached Flutter tool:
`FLUTTER_ALREADY_LOCKED=true /opt/handrail/.handrail/flutter-sdk/bin/cache/dart-sdk/bin/dart /opt/handrail/.handrail/flutter-sdk/bin/cache/flutter_tools.snapshot --no-version-check --suppress-analytics test --no-pub --concurrency=1 ...`.
The nonfatal native-tool stamp warnings are retained in the logs.

Live browser QA was not rerun because both dev services were stopped. A future
live replay must rebuild the Flutter lab assets using the existing provenance-aware
build script and verify the executing digest. No build publication was requested.

## Original artifact references

All original paths are under
`campaigns/298e20b4-4faf-4283-949d-3801cf437aa8/`; content remains available at
`/api/pm/qa-campaign-artifacts/<artifact-ID>/content`.

| Artifact | Artifact ID | SHA-256 |
| --- | --- | --- |
| `47-flutter-send-201-unreconciled.png` | `7acb4994-d602-4a96-82d8-2c0c02b9a802` | `cfba2af3efdd9737eb50b7b47290603ec7aeb629cf4f74e40bd4e14289ee3870` |
| `50-react-cross-client-dm-retained.png` | `7f7b99bb-f95f-4ffa-aed2-7f5d064246d4` | `41bcabebebce67813fa8f441c1425d2646610c7e78b0e8923766f49f814c09b5` |
| `51-flutter-reload-send-recovered.png` | `6d67e615-fb5b-4ebf-8b82-78db6d40c515` | `53c2c28f555de586c498cd1f89ca595dc0533cacb35cd7130cef32e5f76bddad` |
| [flutter-alice-dm-send.json](campaign/flutter-alice-dm-send.json) | `e8454331-1d93-41a2-a102-fdd99f2c9b65` | `e3210b6905c8af65d63c143192ec2f6a981ba34995af2ff1dcbc26927064c9d9` |
| [flutter-send-reload-recovery.json](campaign/flutter-send-reload-recovery.json) | `5de37fc8-55ee-4e0a-9553-452f3b628419` | `700bb354ae8829056567867620535c36a54fb33bee8f0e214559d068b01be52e` |
| [canonical-final.json](campaign/canonical-final.json) | `5d0390d1-c414-4afb-a981-0e37faef9d72` | `fa6e7a2dd32213fc53302379c999898b0a9a8ca76c66db9d05c148a21e279831` |
