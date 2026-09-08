# Extraction validation

The repository split is prepared locally and remains incomplete until consumer
Git pins, lockfiles, service cutover, and preview validation are finished.
No commits or pushes were made by this goal run.

- JS normal install/build and full TypeScript typecheck passed.
- Generator/conformance-runner checks: 146 tests passed.
- Focused Flutter migration checks: 698 tests passed.
- Cross-runtime conformance: all four suites passed, including snapshot drift
  verification and public API citation checks against the new Flutter checkout.
- Final migration-specific Node assertions: 22 passed.
- Flutter workflow contract checks: 2 passed.
- Flutter lab source fingerprint and peer-checkout wiring checks: 3 passed.
  This checks configuration and resolved-source selection; the actual Git-pinned
  consumer build still requires the authorized SDK commits.

The initial broad Node run reported 2,734 passes, 111 failures, and 7 cancellations.
This run predates the final documentation-assertion corrections and Git-consumer
gate separation; it is not a green result. Representative HTTP-boundary and
React-action failures reproduce in the original checkout. Other failures remain
recorded rather than silently skipped or treated as migration passes.

The full Flutter run stalled after 233 passes and was interrupted before shared
fixture paths were changed. The original checkout also stalled in the same
widget-builder case during a separate bounded 40-second run. Neither run is
counted as a successful full-suite test. Flutter analysis returned 64 info-level
diagnostics, zero warnings, and zero errors; the diagnostic list exactly matches
the original checkout. Strict analyze therefore still exits nonzero.

All 1,667 original source/documentation files in the copy manifest were checked
against their initial SHA-256 hashes and remain unchanged. The extracted runtime
sources retain their content, except that the standard JS build refreshed stale
package-version metadata from 1.0.18 to the manifest's 1.0.19.

Detailed logs and the source mapping are under the project workspace's
`.handrail/sdk-split/` directory. `state.json` records completed checks, pending
cutover work, and configuration changes.

A source audit of the initial broad Node failures found 53 failing test files.
51 are byte-identical to their original versions. The two changed files are the
export/installation and workflow contracts; their migration checks now pass.
This does not claim that every original failure was reproduced.
