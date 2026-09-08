# Durable shared-storage integration lab

The existing **chat-lab** dev service builds this authoritative Flutter example.
Open `/__flutter-chat-lab/?sharedStorage=1&namespace=round12&writer=a` on that
service's origin, then use **Open second writer**. The ordinary Timeline Lab and
Mobile Preview workspace remain available. This is a browser integration fixture,
not a production backend or a native mobile adapter.

Both tabs run independent compiled Flutter engines and separate IndexedDB
connections. They share a stable fixture tenant/user/device identity and the
`handrail-shared-storage-<namespace>` database. Use the same origin and browser
profile. Different origins/profiles/devices do not share IndexedDB. Choose a new
`namespace` for a clean run; do not clear browser storage when testing restart.

The `indexeddb-exact-cas-strict-v1` adapter checks the exact encoded string and
replaces/removes it inside one read/write transaction. All writes await strict
transaction completion. Unsupported strict durability fails visibly. No
in-memory lock or map implements persistence. A logout clears all record kinds
for the selected identity in one transaction.

Every engine starts **offline**. Queue sends and a read through sequence 4, inspect
the stored intents, close the browser, reopen the same profile/URL, then reconnect
both writers. The SDK's realtime readiness and durable recovery pumps drive
replay. A controlled HTTP/realtime fixture supplies canonical responses; its
separate durable IndexedDB ledger accepts each idempotency key once. Multiple
HTTP attempts may occur across engines; they must settle to one canonical
application. This proves durable local adapter/recovery integration, not actual
network/provider or production server idempotency.

**Export evidence** downloads the shared adapter trace, canonical ledger, current
records, identity, writer, network/recovery state, and compiled provenance. Traces
include exact expected/actual/replacement fixture values and CAS outcomes, in
transaction commit order. They intentionally contain authored fixture message
text; use this surface only with synthetic content. Tokens/request headers are
never logged. The build script embeds Git HEAD, a SHA-256 digest of actual SDK
and example library/web/pubspec inputs (including dirty/untracked source), and
UTC build time. It rejects a source tree changed during compilation. Direct
`flutter run` without those defines is visibly **unattested**. No generated
revision file needs committing.

## Repeatable verification

From `examples/drop-in-react`:

```sh
npm run build:flutter:lab
npx playwright install chromium
npx playwright test e2e/flutter-shared-storage.spec.mjs --project=chromium --workers=1 --retries=0
```

The test serves the compiled bundle locally, opens two Flutter engines against
one persistent Chromium profile, exits the entire browser process, and relaunches
that profile. It checks:

- No send publication before the adapter commit; both send/read intents survive
  restart and settle after both writers reconnect, without duplicate canonical
  applications or replay after another connectivity cycle.
- Concurrent append/cancel retains unrelated intents and produces losing CAS
  observations through the real database adapter.
- A stale normalized snapshot exact-value exchange is rejected even when the
  replacement differs only in valid JSON whitespace (adapter contract probe).
- Actual SDK push commands retain the highest revision after a delayed writer.
- The SDK storage mutator's delayed malformed-value quarantine cannot delete a
  valid replacement installed by the other engine.
- Exported evidence contains adapter identity and compiled source provenance,
  and contains no fixture push token.

The JSON bridge `window.handrailStorageLab(JSON.stringify(command))` is available
only on this opt-in lab route. The browser test documents commands and pause
points. Pauses happen outside transactions so other engines can commit; the CAS
itself always uses IndexedDB's transaction isolation. Playwright attaches the
complete trace/provenance JSON to its report. Browser storage eviction, native
mobile process integration, real socket loss, and production transport behavior
remain separate acceptance targets.
