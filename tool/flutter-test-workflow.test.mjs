import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import test from "node:test";

const root = resolve(import.meta.dirname, "..");
const workflowPath = resolve(root, ".github/workflows/flutter-test.yml");

test("Flutter test workflow preserves the full-package CI gate contract", async () => {
  const workflow = await readFile(workflowPath, "utf8");

  assert.match(
    workflow,
    /^on:\n  push:\n    branches:\n      - main\n  pull_request:\n\npermissions:/mu,
  );
  assert.match(workflow, /^permissions:\n  contents: read\n\nconcurrency:/mu);
  assert.match(
    workflow,
    /^concurrency:\n  group: flutter-test-\$\{\{ github\.ref \}\}\n  cancel-in-progress: true\n\njobs:/mu,
  );

  assert.match(workflow, /^    runs-on: ubuntu-latest$/mu);
  const timeout = workflow.match(/^    timeout-minutes: (\d+)$/mu);
  assert.ok(timeout, "the Flutter test job must declare a timeout");
  assert.ok(
    Number(timeout[1]) > 0 && Number(timeout[1]) <= 30,
    "the Flutter test job timeout must be bounded to 30 minutes",
  );

  const actions = [...workflow.matchAll(/^        uses: (.+)$/gmu)].map(
    (match) => match[1],
  );
  assert.deepEqual(actions, [
    "actions/checkout@v4",
    "subosito/flutter-action@v2",
  ]);
  assert.match(workflow, /^          channel: stable$/mu);
  assert.match(workflow, /^          flutter-version: "3\.41\.7"$/mu);
  assert.match(workflow, /^          cache: true$/mu);
  assert.match(workflow, /^          pub-cache: true$/mu);

  const commands = [...workflow.matchAll(/^        run: (.+)$/gmu)].map(
    (match) => match[1],
  );
  assert.deepEqual(commands, ["flutter pub get --no-example", "flutter test --no-pub --concurrency=2"]);
  assert.equal(
    commands.filter((command) => command === "flutter test --no-pub --concurrency=2").length,
    1,
    "the full Flutter package must be tested exactly once",
  );

  const workingDirectories = [
    ...workflow.matchAll(/^        working-directory: (.+)$/gmu),
  ].map((match) => match[1]);
  assert.deepEqual(workingDirectories, [
    ".",
    ".",
  ]);

  assert.doesNotMatch(workflow, /^\s*(?:services|env):$/mu);
  assert.doesNotMatch(workflow, /\bsecrets?\b/iu);
  assert.doesNotMatch(workflow, /^\s*continue-on-error:/mu);
  assert.doesNotMatch(
    workflow.replaceAll(" --no-example", ""),
    /\b(?:preview|example|publish|release|deploy(?:ment)?|production|staging|provider|hosting|docker|kubectl|helm|terraform|pulumi|serverless|flyctl|vercel|netlify|cloudflare|migrate|migration|xcodebuild|gradlew?|fastlane|codesign|signing|keychain|keystore|flutter\s+build|dart\s+compile|npm\s+publish|gh\s+release|curl|wget)\b|uses:\s*(?:aws-actions|azure|google-github-actions|cloudflare)\//iu,
  );
});
