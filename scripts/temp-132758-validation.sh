#!/usr/bin/env bash
set -euo pipefail

: "${BASE_SHA:?BASE_SHA is required}"
: "${TARGET_BRANCH:?TARGET_BRANCH is required}"
: "${TRIGGER_SHA:?TRIGGER_SHA is required}"

# The workflow has already reset the checkout to BASE_SHA. Reproduce the bug
# with only the new regression before touching production code.
python3 <<'PY'
from pathlib import Path

path = Path("src/agents/cli-runner/prepare.test.ts")
text = path.read_text()
anchor = '''  it("ignores stored CLI session candidates when the backend disables sessions", async () => {
    setCliBackendForPrepareTest({'''
replacement = '''  it("ignores stored CLI session candidates when the backend disables sessions", async () => {
    fixture.appendTranscript({
      id: "msg-sessionless-user",
      parentId: null,
      timestamp: new Date(1).toISOString(),
      message: {
        role: "user",
        content: "prior sessionless context",
        timestamp: 1,
      },
    });
    fixture.appendTranscript({
      id: "msg-sessionless-assistant",
      parentId: "msg-sessionless-user",
      timestamp: new Date(2).toISOString(),
      message: {
        role: "assistant",
        content: [{ type: "text", text: "prior sessionless answer" }],
        api: "responses",
        provider: "test-cli",
        model: "test-model",
        usage: {
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
        },
        stopReason: "stop",
        timestamp: 2,
      },
    });
    setCliBackendForPrepareTest({'''
if text.count(anchor) != 1:
    raise SystemExit(f"red test anchor mismatch: {text.count(anchor)}")
text = text.replace(anchor, replacement, 1)
assertion_anchor = '''    expect(context.reusableCliSession).toEqual({ mode: "none" });
    expect(transcriptCheck).not.toHaveBeenCalled();'''
assertion_replacement = '''    expect(context.reusableCliSession).toEqual({ mode: "none" });
    expect(context.openClawHistoryPrompt).toContain("prior sessionless context");
    expect(context.openClawHistoryPrompt).toContain("prior sessionless answer");
    expect(context.openClawHistoryPrompt).toContain("stateless ask");
    expect(transcriptCheck).not.toHaveBeenCalled();'''
if text.count(assertion_anchor) != 1:
    raise SystemExit(f"red assertion anchor mismatch: {text.count(assertion_anchor)}")
path.write_text(text.replace(assertion_anchor, assertion_replacement, 1))
PY

set +e
pnpm test src/agents/cli-runner/prepare.test.ts > "$RUNNER_TEMP/red.log" 2>&1
red_status=$?
set -e
cat "$RUNNER_TEMP/red.log"
if [ "$red_status" -eq 0 ]; then
  echo "Regression unexpectedly passed before the production fix." >&2
  exit 1
fi
grep -F 'ignores stored CLI session candidates when the backend disables sessions' "$RUNNER_TEMP/red.log" >/dev/null
grep -F 'the given combination of arguments (undefined and string) is invalid for this assertion' "$RUNNER_TEMP/red.log" >/dev/null
printf '%s\n' 'RED PROOF: openClawHistoryPrompt is undefined for an uncompacted sessionMode:none turn.'

git reset --hard "$BASE_SHA"

# Apply the narrow owner-boundary repair plus the final regressions.
python3 <<'PY'
from pathlib import Path


def replace_once(path: str, old: str, new: str, label: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one anchor, found {count}")
    p.write_text(text.replace(old, new, 1))


def replace_between(path: str, start_marker: str, end_marker: str, replacement: str, label: str) -> None:
    p = Path(path)
    text = p.read_text()
    start = text.find(start_marker)
    if start < 0:
        raise SystemExit(f"{label}: start marker not found")
    end = text.find(end_marker, start)
    if end < 0:
        raise SystemExit(f"{label}: end marker not found")
    end += len(end_marker)
    p.write_text(text[:start] + replacement + text[end:])


prepare = "src/agents/cli-runner/prepare.ts"
replace_between(
    prepare,
    '    const reusableCliSessionCandidate: CliReusableSession = ignoreCliSessionCandidate\n',
    '            : { mode: "none" };\n',
    '''    const configuredCliSessionCandidate: CliReusableSession = isSideQuestion
      ? { mode: "none" }
      : controlOperationCliSessionId
        ? { mode: "reuse", sessionId: controlOperationCliSessionId }
        : params.cliSessionBinding
          ? resolveCliSessionReuse({
              binding: params.cliSessionBinding,
              authProfileId: effectiveAuthProfileId,
              authEpoch,
              authEpochVersion: CLI_AUTH_EPOCH_VERSION,
              extraSystemPromptHash,
              messageToolPolicyHash,
              promptToolNamesHash,
              cwdHash,
              mcpConfigHash: preparedBackendFinal.mcpConfigHash,
              mcpResumeHash: preparedBackendFinal.mcpResumeHash,
            })
          : params.cliSessionId
            ? { mode: "reuse", sessionId: params.cliSessionId }
            : { mode: "none" };
    const reusableCliSessionCandidate: CliReusableSession = ignoreCliSessionCandidate
      ? { mode: "none" }
      : configuredCliSessionCandidate;
''',
    "configured session candidate",
)
replace_once(
    prepare,
    '''    const invalidatedReason = resolveCliSessionInvalidatedReason(reusableCliSession);
    if (invalidatedReason) {''',
    '''    const invalidatedReason = resolveCliSessionInvalidatedReason(reusableCliSession);
    const sessionlessRawReseedReason =
      !isSideQuestion &&
      !isControlOperation &&
      preparedBackendFinal.backend.sessionMode === "none"
        ? (resolveCliSessionInvalidatedReason(configuredCliSessionCandidate) ?? "sessionless")
        : undefined;
    if (invalidatedReason) {''',
    "sessionless reason owner",
)
replace_once(
    prepare,
    '    const rawTranscriptReseedReason = reusableCliSessionId ? "session-expired" : invalidatedReason;',
    '''    const rawTranscriptReseedReason = reusableCliSessionId
      ? "session-expired"
      : (invalidatedReason ?? sessionlessRawReseedReason);''',
    "raw reseed selection",
)

history = "src/agents/cli-runner/session-history.ts"
replace_once(
    history,
    '''  | "orphaned-tool-use"
  | "session-expired";''',
    '''  | "orphaned-tool-use"
  | "session-expired"
  | "sessionless";''',
    "sessionless reason type",
)
replace_once(
    history,
    '''  "mcp",
  "session-expired",
]);''',
    '''  "mcp",
  "session-expired",
  "sessionless",
]);''',
    "sessionless reason allowlist",
)

prepare_test = "src/agents/cli-runner/prepare.test.ts"
replace_once(
    prepare_test,
    '''  it("ignores stored CLI session candidates when the backend disables sessions", async () => {
    setCliBackendForPrepareTest({''',
    '''  it("ignores stored CLI session candidates when the backend disables sessions", async () => {
    fixture.appendTranscript({
      id: "msg-sessionless-user",
      parentId: null,
      timestamp: new Date(1).toISOString(),
      message: {
        role: "user",
        content: "prior sessionless context",
        timestamp: 1,
      },
    });
    fixture.appendTranscript({
      id: "msg-sessionless-assistant",
      parentId: "msg-sessionless-user",
      timestamp: new Date(2).toISOString(),
      message: {
        role: "assistant",
        content: [{ type: "text", text: "prior sessionless answer" }],
        api: "responses",
        provider: "test-cli",
        model: "test-model",
        usage: {
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
        },
        stopReason: "stop",
        timestamp: 2,
      },
    });
    setCliBackendForPrepareTest({''',
    "prepare regression setup",
)
replace_once(
    prepare_test,
    '''    expect(context.reusableCliSession).toEqual({ mode: "none" });
    expect(transcriptCheck).not.toHaveBeenCalled();''',
    '''    expect(context.reusableCliSession).toEqual({ mode: "none" });
    expect(context.openClawHistoryPrompt).toContain("prior sessionless context");
    expect(context.openClawHistoryPrompt).toContain("prior sessionless answer");
    expect(context.openClawHistoryPrompt).toContain("stateless ask");
    expect(transcriptCheck).not.toHaveBeenCalled();''',
    "prepare regression assertions",
)

insert_anchor = '  it("checks claude-cli transcript content under the resolved cwd", async () => {'
auth_test = '''  it("does not raw-reseed auth-boundary history for sessionless backends", async () => {
    fixture.appendTranscript({
      id: "msg-sessionless-auth",
      parentId: null,
      timestamp: new Date(1).toISOString(),
      message: { role: "user", content: "previous credential context", timestamp: 1 },
    });
    setCliBackendForPrepareTest({
      sessionMode: "none",
      reseedFromRawTranscriptWhenUncompacted: true,
    });
    const transcriptCheck = vi.fn(async () => true);
    const orphanCheck = vi.fn(async () => false);
    setCliRunnerPrepareTestDeps({
      claudeCliSessionTranscriptHasContent: transcriptCheck,
      claudeCliSessionTranscriptHasOrphanedToolUse: orphanCheck,
    });

    const context = await fixture.prepare({
      sessionKey: "agent:main:telegram:direct:peer",
      prompt: "new credential ask",
      provider: "claude-cli",
      model: "opus",
      cliSessionBinding: {
        sessionId: "stale-credential-session",
        authProfileId: "anthropic:old-profile",
      },
      cliSessionId: "stale-credential-session",
    });

    expect(context.reusableCliSession).toEqual({ mode: "none" });
    expect(context.openClawHistoryPrompt).toBeUndefined();
    expect(transcriptCheck).not.toHaveBeenCalled();
    expect(orphanCheck).not.toHaveBeenCalled();
  });

''' + insert_anchor
replace_once(prepare_test, insert_anchor, auth_test, "sessionless auth-boundary regression")

history_test = "src/agents/cli-runner/session-history.test.ts"
replace_once(
    history_test,
    '''    "mcp",
    "session-expired",
  ] as const)("raw-reseeds consecutive user rows for %s only with opt-in", async (reason) => {''',
    '''    "mcp",
    "session-expired",
    "sessionless",
  ] as const)("raw-reseeds consecutive user rows for %s only with opt-in", async (reason) => {''',
    "sessionless policy coverage",
)
PY

pnpm exec oxfmt --write \
  src/agents/cli-runner/prepare.ts \
  src/agents/cli-runner/prepare.test.ts \
  src/agents/cli-runner/session-history.ts \
  src/agents/cli-runner/session-history.test.ts

echo "===== focused prepare tests ====="
pnpm test src/agents/cli-runner/prepare.test.ts
echo "===== focused session-history tests ====="
pnpm test src/agents/cli-runner/session-history.test.ts
echo "===== focused execute-plugin tests ====="
pnpm test src/agents/cli-runner/execute-plugin.test.ts
echo "===== changed-file gate ====="
pnpm check:changed -- \
  src/agents/cli-runner/prepare.ts \
  src/agents/cli-runner/prepare.test.ts \
  src/agents/cli-runner/session-history.ts \
  src/agents/cli-runner/session-history.test.ts
git diff --check

# Final scope review before commit.
test "$(git diff --name-only | sort)" = "$(printf '%s\n' \
  src/agents/cli-runner/prepare.test.ts \
  src/agents/cli-runner/prepare.ts \
  src/agents/cli-runner/session-history.test.ts \
  src/agents/cli-runner/session-history.ts | sort)"
grep -F 'sessionMode: "always"' extensions/anthropic/cli-backend.ts >/dev/null
test -z "$(git diff -- extensions/anthropic/cli-backend.ts)"

echo "===== final diff ====="
git diff --stat
git diff --numstat

git config user.name "Sylvester Kaczmarek"
git config user.email "16242628+sylvesterkaczmarek@users.noreply.github.com"
git add \
  src/agents/cli-runner/prepare.ts \
  src/agents/cli-runner/prepare.test.ts \
  src/agents/cli-runner/session-history.ts \
  src/agents/cli-runner/session-history.test.ts
git commit -m "fix(cli): reseed history for sessionless turns"
final_sha="$(git rev-parse HEAD)"
printf 'FINAL_SHA=%s\n' "$final_sha"
git push origin "HEAD:refs/heads/$TARGET_BRANCH" \
  --force-with-lease="refs/heads/$TARGET_BRANCH:${TRIGGER_SHA}"
