import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import test from "node:test";

const root = resolve(import.meta.dirname, "..");
const workflowPath = resolve(root, ".github/workflows/flutter-analyze.yml");

test("Flutter analyze workflow preserves the static-analysis contract", async () => {
  const workflow = await readFile(workflowPath, "utf8");

  assert.match(
    workflow,
    /^on:\n  push:\n    branches:\n      - main\n  pull_request:\n\npermissions:/mu,
  );
  assert.match(workflow, /^permissions:\n  contents: read\n\nconcurrency:/mu);
  assert.match(
    workflow,
    /^concurrency:\n  group: [^\n]+\n  cancel-in-progress: true\n\njobs:/mu,
  );

  const timeout = workflow.match(/^    timeout-minutes: (\d+)$/mu);
  assert.ok(timeout, "the analyze job must declare a timeout");
  assert.ok(Number(timeout[1]) > 0 && Number(timeout[1]) <= 30, "the timeout must be bounded to 30 minutes");

  const actions = [...workflow.matchAll(/^        uses: (.+)$/gmu)].map((match) => match[1]);
  assert.deepEqual(actions, ["actions/checkout@v4", "subosito/flutter-action@v2"]);
  assert.match(workflow, /^          channel: stable$/mu);
  assert.match(workflow, /^          flutter-version: "3\.41\.7"$/mu);
  assert.match(workflow, /^          cache: true$/mu);
  assert.match(workflow, /^          pub-cache: true$/mu);

  const commands = [...workflow.matchAll(/^        run: (.+)$/gmu)].map((match) => match[1]);
  assert.deepEqual(commands, ["flutter pub get --no-example", "flutter analyze --no-pub lib test"]);

  const workingDirectories = [
    ...workflow.matchAll(/^        working-directory: (.+)$/gmu),
  ].map((match) => match[1]);
  assert.deepEqual(workingDirectories, [".", "."]);

  assert.doesNotMatch(
    workflow,
    /\b(?:flutter|dart)\s+(?:build|test|publish)\b|\b(?:npm publish|docker|kubectl|terraform|pulumi)\b|uses:\s*(?:aws-actions|azure|google-github-actions)\//iu,
  );
});
