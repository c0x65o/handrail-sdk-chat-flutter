# Command Retry-After qualification — 2026-10-06

Work request `6c0a069f-a0a0-4f74-a8fd-83d08f030e39`, run `8bd3fc5e-0032-46f0-8ccd-03bc5b973bc5`.

The source correction is **uncommitted and unpublished**. Handrail's post-agent native workflow owns version bumps, commit and push. No deployment, PR, queue/database mutation, live message, live token request, or provider call was made. CI definitions and the existing five-minute full-CI skip policy were not changed.

## Source and reproduction

Both SDK checkouts were clean at entry:

| SDK | Baseline version | Immutable baseline commit (does not contain this fix) |
| --- | --- | --- |
| JS | `@handrail/chat` 1.0.52 | `a4b94b012e967402a9f72de33b1974a774d157be` |
| Flutter | `handrail_chat` 0.1.30 | `39dddc7b448917aa9392f557617cc3014cad6326` |

`before-js.json` records the baseline public client's existing build making three attempts with waits of 100 and 200 ms despite a real Fetch `Response` carrying `Retry-After: 60`. `reproduce_before.mjs` preserves the reproduction. Flutter's matching folder records the same baseline three attempts and 100/200 ms waits; its public response type could not represent response headers at all. Baseline scripts are for the baseline revisions only; the corrected implementation's injected wait must be paired with an advancing clock.

Handrail current-context verified this request and the attached authentication snapshot. No AGENTS.md or persistent guidance files were present in the mounted project/ancestor paths; the mounted `.agents` and `.codex` directories were empty. The KB catalog contained no Chat-specific entry. The supplied KB contracts and existing read-state qualification were read.

The request supplies Preview consumer evidence (WR `dc2a2642-5d61-43c5-861c-8d80f6939d7c`, run `87ed7b14-acaf-43a0-bdc5-799315aacf7a`): 131 requests in a shared 120-request PostgreSQL limiter window, 11 actual 429s, and 105 requests without 429s next window. The named `docs/bounded-chat-20261006/report.json` is absent from the mounted Preview checkout (`b48bf8418702f3acf3b12b8e401749e7ff3a63fb`); those figures are supplied evidence, not a new measurement by this run.

## Correction

Both dispatchers keep the longest observed command deadline and gate every subsequent transport attempt, including newly dispatched commands. Retry-After seconds (including zero) and HTTP dates are supported. Expired command dates retain ordinary backoff; missing, malformed, non-finite or unrepresentable headers fall back to 60 seconds. Waits are sliced to at most 60 seconds and recheck extensions; valid longer deadlines are not truncated. The existing backoff can lengthen a short server delay. Total attempt budgets, retry-safety opt-in, authentication refresh, response classification, request bodies and idempotency keys stay intact.

Cancellation and close still settle promptly without another attempt; late interrupted responses cannot install a cooldown. `closeActive` resets dispatcher cooldown alongside cancellation for its reusable lifecycle. Existing durable queues retain their identities and work. There is no generic scheduler or limiter-budget change. JS reuses the extracted read header parser; the qualified read-state polling/rendering code is untouched apart from the parser import, and its regressions pass. The read deadline wrapper retains its existing expired-header fallback.

Flutter adds optional `HandrailChatHttpResponse.headers` (default empty, preserving existing const constructors). Its shipped browser and ERP host adapters forward Retry-After. `http_parser` was already in the lockfile and is now a direct dependency for the platform-neutral HTTP-date parser. Both SDKs add an optional retry clock paired with the existing injectable wait hook; ordinary callers need no change.

## Verification and limits

See `provenance.json` for exact changed-source, test, package and artifact hashes and final results. Tests use disposable HTTP boundary fixtures, deterministic clocks and loopback HTTP servers. A tiny accepted-key ledger tests lost acknowledgements and deduplication at the transport boundary; it does not claim PostgreSQL persistence correctness. Existing durable queue/read-state tests supply their normal repository storage fixtures. No database implementation changed, and no new database harness was introduced.

JS checks: normal package build; full source and public-contract typecheck; command, durable-send, read-state, exports and browser-import regressions. Native global Fetch is tested against actual HTTP response headers. Flutter checks: native focused tests with concurrency 2 (including the requested durable-resource reducer); changed-file analysis; full lib/test analysis; compile-only qualification of the shipped browser adapter. Flutter's actual loopback HTTP test uses the shipped ERP adapter and public dispatcher, and a public `sendMessage` regression confirms header propagation into the feature path.

Full Flutter analysis has pre-existing informational lints in generated durable events, huddle recovery and realtime recovery tests. Its nonzero result remains a failed native gate; it is not represented as a passing check. No unrelated lint repair was made. The new example-import test's intentional relative import is documented locally; changed-file analysis is clean. Browser compilation proves type/platform compatibility, not a browser runtime or CORS integration run.

Flutter 3.41.7 / Dart 3.11.5 ran from a private writable copy in this run's tmp directory, with a private PUB_CACHE. Shared cache permissions and contents were not changed. The original lockfile's unrelated resolutions are preserved; only http_parser's dependency classification changes. Offline pub resolution locally refreshed older transitive entries for this Flutter toolchain; provenance records the actual local package graph separately from the intended lockfile.

## Native publication / consumer handoff

No corrected immutable published pins exist during this worker turn. After native versioning, validation, commit and push, record both new versions and full 40-character SHAs, then install each via its public HTTPS Git URL with that exact SHA and matching lockfile. Run JS `test:git-consumer` with `HANDRAIL_CHAT_JS_REVISION` set to the published SHA and the installed-command regressions. Repeat Flutter's command/header checks against the exact installed published Git dependency with an isolated writable toolchain. Do not substitute a local path, tarball, branch or registry package as release qualification.

Flutter consumers with their own transports must forward response headers into the new optional field; older adapters safely receive the 60-second fallback. Verify native and browser host transport forwarding (and CORS header exposure where cross-origin), plus actual Preview auth/PostgreSQL limiter windows after installation. Preview was not modified. This correction does **not** establish that Preview's total shared request budget is resolved.
