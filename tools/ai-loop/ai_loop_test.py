#!/usr/bin/env python3
"""Tests for tools/ai-loop/ai_loop.py."""

from __future__ import annotations

import argparse
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


sys.dont_write_bytecode = True

REPO_ROOT = Path(__file__).resolve().parents[2]
TOOL_DIR = REPO_ROOT / "tools/ai-loop"
AI_LOOP_PATH = TOOL_DIR / "ai_loop.py"

spec = importlib.util.spec_from_file_location("ai_loop", AI_LOOP_PATH)
assert spec and spec.loader
ai_loop = importlib.util.module_from_spec(spec)
sys.modules["ai_loop"] = ai_loop
spec.loader.exec_module(ai_loop)


def run(
    cmd: list[str],
    cwd: Path,
    *,
    check: bool = True,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=cwd,
        check=check,
        text=True,
        capture_output=True,
        env=env,
    )


def write_minimal_instruction_files(repo: Path) -> None:
    (repo / ".codex").mkdir()
    (repo / "AGENTS.md").write_text("root agent instructions\n", encoding="utf-8")
    (repo / ".codex/AGENTS.md").write_text("codex instructions\n", encoding="utf-8")
    (repo / "CLAUDE.md").write_text("claude instructions\n", encoding="utf-8")


def init_repo_with_ai_loop_tooling(repo: Path) -> None:
    run(["git", "init"], repo)
    run(["git", "config", "user.name", "AI Loop Test"], repo)
    run(["git", "config", "user.email", "ai-loop-test@example.com"], repo)
    # Tests using this helper validate hook routing / dispatch, not the
    # default-on PR bootstrap. Pin the opt-out so they don't try to talk to
    # GitHub when `start` is invoked. PrBootstrapTests build their own
    # repo via init_repo_with_bare_origin and leave the config unset so
    # the default-ON path is exercised.
    run(["git", "config", "ai-loop.createPr", "false"], repo)
    write_minimal_instruction_files(repo)
    shutil.copytree(TOOL_DIR, repo / "tools/ai-loop")
    run(["git", "add", "."], repo)
    run(["git", "commit", "-m", "Initial tools"], repo)


def write_fake_sequence_agent(script_path: Path) -> None:
    script_path.write_text(
        """from pathlib import Path
import re
import subprocess
import sys

AGENT_FOR_ROLE = {
    "developer": "codex",
    "reviewer": "claude-code",
}

role = sys.argv[1]
calls_path = Path(sys.argv[2])
sequence_path = Path(sys.argv[3])
prompt = sys.stdin.read()

if len(sys.argv) >= 5:
    log_path = Path(sys.argv[4])
else:
    match = re.search(r"^AI loop log: (?P<path>.+)$", prompt, re.MULTILINE)
    if not match:
        raise SystemExit("AI loop log path not found in prompt")
    log_path = Path(match.group("path").strip())
    if not log_path.is_absolute():
        log_path = Path.cwd() / log_path

if calls_path.exists():
    calls = calls_path.read_text(encoding="utf-8").splitlines()
else:
    calls = []

sequence = [
    line.strip()
    for line in sequence_path.read_text(encoding="utf-8").splitlines()
    if line.strip()
]
index = len(calls)
if index >= len(sequence):
    raise SystemExit("fake agent sequence exhausted")

parts = sequence[index].split("|")
while len(parts) < 4:
    parts.append("")
expected_role, cycle, status, next_agent = parts[:4]
if expected_role != role:
    raise SystemExit(f"expected role {expected_role}, got {role}")

calls_path.write_text("\\n".join([*calls, role]) + "\\n", encoding="utf-8")

agent = AGENT_FOR_ROLE[role]
metadata = [
    f"agent: {agent}",
    f"role: {role}",
    f"cycle: {cycle}",
    f"status: {status}",
]
if next_agent:
    metadata.append(f"next_agent: {next_agent}")

event = (
    f"\\n## Fake {role} event {index + 1}\\n\\n"
    "<!-- ai-loop-event\\n"
    + "\\n".join(metadata)
    + "\\n-->\\n"
)
message = f"[ai-loop] {agent}: {status}"

with log_path.open("a", encoding="utf-8") as handle:
    handle.write(event)
subprocess.run(["git", "add", str(log_path)], check=True)
subprocess.run(["git", "commit", "-m", message], check=True)
""",
        encoding="utf-8",
    )


def git_context(repo: Path) -> ai_loop.GitContext:
    return ai_loop.GitContext(repo)


def prompt_composer(repo: Path) -> ai_loop.PromptComposer:
    return ai_loop.PromptComposer(git_context(repo))


def agent_dispatcher(repo: Path) -> ai_loop.AgentDispatcher:
    return ai_loop.AgentDispatcher(git_context(repo))


def write_committed_log(
    repo: Path,
    text: str,
    *,
    message: str = "[ai-loop] Test event",
) -> Path:
    log_path = repo / "docs/ai-loop/local-20260524-120000.md"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text(text, encoding="utf-8")
    run(["git", "add", "docs/ai-loop/local-20260524-120000.md"], repo)
    run(["git", "commit", "-m", message], repo)
    return log_path


GH_SHIM_SOURCE = """\
import json
import os
import sys
from pathlib import Path

state_dir = Path(os.environ["GH_SHIM_STATE_DIR"])
state_dir.mkdir(parents=True, exist_ok=True)

log_path = state_dir / "gh_calls.log"
with log_path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps({"argv": sys.argv[1:]}) + "\\n")

argv = sys.argv[1:]
if not argv:
    sys.exit(0)

subcommand = argv[0]

if subcommand == "auth":
    rc_path = state_dir / "auth_rc.txt"
    rc = int(rc_path.read_text(encoding="utf-8").strip()) if rc_path.exists() else 0
    if rc != 0:
        sys.stderr.write("gh shim: not authenticated\\n")
    sys.exit(rc)

if subcommand == "pr":
    if len(argv) < 2:
        sys.exit(2)
    pr_sub = argv[1]
    if pr_sub == "list":
        existing_path = state_dir / "existing_prs.txt"
        if existing_path.exists():
            sys.stdout.write(existing_path.read_text(encoding="utf-8"))
        sys.exit(0)
    if pr_sub == "create":
        next_path = state_dir / "next_pr.txt"
        if next_path.exists():
            next_num = int(next_path.read_text(encoding="utf-8").strip())
        else:
            next_num = 1
        next_path.write_text(str(next_num + 1), encoding="utf-8")
        if (state_dir / "create_fail.txt").exists():
            sys.stderr.write("gh shim: pr create simulated failure\\n")
            sys.exit(1)
        sys.stdout.write(
            f"https://github.com/example/example/pull/{next_num}\\n"
        )
        sys.exit(0)
    if pr_sub == "edit":
        edits_path = state_dir / "pr_edits.log"
        body_path_arg = None
        if "--body-file" in argv:
            idx = argv.index("--body-file")
            if idx + 1 < len(argv):
                body_path_arg = argv[idx + 1]
        entry = {"argv": argv}
        if body_path_arg:
            try:
                entry["body"] = Path(body_path_arg).read_text(encoding="utf-8")
            except OSError:
                entry["body"] = None
        with edits_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry) + "\\n")
        if body_path_arg:
            # Mirror real gh behavior: persist new body so subsequent
            # `pr view` returns it.
            body_state = state_dir / "pr_body.txt"
            if entry["body"] is not None:
                body_state.write_text(entry["body"], encoding="utf-8")
        sys.exit(0)
    if pr_sub == "view":
        body_state = state_dir / "pr_body.txt"
        body = body_state.read_text(encoding="utf-8") if body_state.exists() else ""
        if "--jq" in argv:
            sys.stdout.write(body)
        else:
            sys.stdout.write(json.dumps({"body": body}))
        sys.exit(0)
    if pr_sub == "ready":
        ready_path = state_dir / "pr_ready.log"
        with ready_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps({"argv": argv}) + "\\n")
        rc_path = state_dir / "ready_rc.txt"
        rc = int(rc_path.read_text(encoding="utf-8").strip()) if rc_path.exists() else 0
        if rc != 0:
            sys.stderr.write("gh shim: pr ready simulated failure\\n")
        sys.exit(rc)
    sys.exit(2)

if subcommand == "label":
    if len(argv) < 2:
        sys.exit(2)
    label_sub = argv[1]
    labels_path = state_dir / "labels.txt"
    if label_sub == "list":
        if labels_path.exists():
            sys.stdout.write(labels_path.read_text(encoding="utf-8"))
        sys.exit(0)
    if label_sub == "create":
        if len(argv) < 3:
            sys.exit(2)
        name = argv[2]
        existing = (
            labels_path.read_text(encoding="utf-8").splitlines()
            if labels_path.exists()
            else []
        )
        if name not in existing:
            existing.append(name)
        labels_path.write_text("\\n".join(existing) + "\\n", encoding="utf-8")
        sys.exit(0)
    sys.exit(2)

sys.stderr.write(f"gh shim: unsupported argv: {argv}\\n")
sys.exit(2)
"""


def write_gh_shim(script_path: Path) -> None:
    script_path.write_text(GH_SHIM_SOURCE, encoding="utf-8")


def read_gh_calls(state_dir: Path) -> list[list[str]]:
    log_path = state_dir / "gh_calls.log"
    if not log_path.exists():
        return []
    import json as _json

    return [
        _json.loads(line)["argv"]
        for line in log_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


def init_repo_with_bare_origin(repo: Path, origin: Path) -> None:
    run(["git", "init", "--bare", "--initial-branch=main", str(origin)], origin.parent)
    run(["git", "init", "--initial-branch=main"], repo)
    run(["git", "config", "user.name", "AI Loop Test"], repo)
    run(["git", "config", "user.email", "ai-loop-test@example.com"], repo)
    run(["git", "remote", "add", "origin", str(origin)], repo)
    write_minimal_instruction_files(repo)
    shutil.copytree(TOOL_DIR, repo / "tools/ai-loop")
    run(["git", "add", "."], repo)
    run(["git", "commit", "-m", "Initial tools"], repo)
    run(["git", "push", "-u", "origin", "main"], repo)


class MetadataParsingTests(unittest.TestCase):
    def test_parse_init_and_events(self) -> None:
        text = """# AI Loop

<!-- ai-loop-init
run_id: local-20260524-120000
max_cycles: 3
-->

<!-- ai-loop-event
agent: human
status: needs_developer
next_agent: codex
-->

<!-- ai-loop-event
agent: codex
status: needs_review
next_agent: claude-code
-->
"""
        parsed = ai_loop.parse_log_text(text)
        self.assertEqual(parsed.init["run_id"], "local-20260524-120000")
        self.assertEqual(len(parsed.events), 2)
        self.assertEqual(parsed.latest_event["status"], "needs_review")

    def test_reject_invalid_metadata_line(self) -> None:
        with self.assertRaises(ValueError):
            ai_loop.parse_kv_block("agent human")

    def test_routing_decisions(self) -> None:
        cases = {
            "needs_developer": "would dispatch developer agent: codex",
            "needs_review": "would dispatch reviewer agent: claude-code",
            "needs_fix": "would dispatch developer agent: codex",
            "clean": "stop: review is clean",
            "awaiting_human": "stop: awaiting human clarification",
            "failed": "stop: loop is failed",
            "max_cycles_reached": "stop: cycle cap reached",
        }
        router = ai_loop.StateRouter()
        for status, expected in cases.items():
            with self.subTest(status=status):
                event = {"status": status}
                if status == "needs_review":
                    event["next_agent"] = "claude-code"
                if status in {"needs_developer", "needs_fix"}:
                    event["next_agent"] = "codex"
                self.assertEqual(router.routing_decision(event), expected)

    def test_clarified_events_resume_the_named_agent(self) -> None:
        router = ai_loop.StateRouter()
        cases = {
            "codex": "would dispatch developer agent: codex",
            "claude-code": "would dispatch reviewer agent: claude-code",
            "human": "stop: clarified event is missing a supported next_agent",
        }
        for next_agent, expected in cases.items():
            with self.subTest(next_agent=next_agent):
                self.assertEqual(
                    router.routing_decision(
                        {"status": "clarified", "next_agent": next_agent}
                    ),
                    expected,
                )

    def test_bootstrap_log_contains_valid_metadata(self) -> None:
        log = ai_loop.render_bootstrap_log(
            run_id="local-20260524-120000",
            log_path="docs/ai-loop/local-20260524-120000.md",
            prompt="Implement the thing",
            repo="kathelix/catvox",
            commit_at_start="deadbeefcafef00d1234567890abcdef12345678",
            started_at="2026-05-24T12:00:00+02:00",
        )
        parsed = ai_loop.parse_log_text(log)
        self.assertEqual(parsed.init["run_id"], "local-20260524-120000")
        self.assertEqual(
            parsed.init["commit_at_start"],
            "deadbeefcafef00d1234567890abcdef12345678",
        )
        self.assertNotIn("branch_at_start", parsed.init)
        self.assertEqual(parsed.latest_event["status"], "needs_developer")
        self.assertEqual(parsed.latest_event["next_agent"], "codex")

    def test_max_cycles_defaults_to_three_when_missing(self) -> None:
        parsed = ai_loop.parse_log_text(
            """# AI Loop

<!-- ai-loop-event
agent: claude-code
role: reviewer
cycle: 3
status: needs_fix
next_agent: codex
-->
"""
        )
        latest = parsed.latest_event
        assert latest is not None
        route = ai_loop.StateRouter().route_for_event(latest)

        self.assertEqual(ai_loop.max_cycles_for_log(parsed), 3)
        self.assertTrue(ai_loop.should_stop_for_cycle_cap(parsed, latest, route))

    def test_cycle_for_event_requires_explicit_cycle(self) -> None:
        # Missing cycle metadata on a cap-relevant event must fail loud rather
        # than silently default to 0, which would bypass the cycle cap.
        cases = [
            {"status": "needs_fix"},
            {"status": "needs_fix", "cycle": ""},
            {"status": "needs_fix", "cycle": "   "},
        ]
        for event in cases:
            with self.subTest(event=event):
                with self.assertRaises(ai_loop.AILoopError) as ctx:
                    ai_loop.cycle_for_event(event)
                self.assertIn("missing required cycle metadata", str(ctx.exception))

    def test_cycle_for_event_rejects_non_integer(self) -> None:
        with self.assertRaises(ai_loop.AILoopError):
            ai_loop.cycle_for_event({"status": "needs_fix", "cycle": "two"})

    def test_should_stop_for_cycle_cap_raises_when_cycle_missing(self) -> None:
        # The cap check should propagate the cycle_for_event error so a
        # malformed needs_fix event stops the loop instead of dispatching the
        # developer at an undefined cycle.
        parsed = ai_loop.parse_log_text(
            """# AI Loop

<!-- ai-loop-init
run_id: local-20260524-120000
max_cycles: 3
-->

<!-- ai-loop-event
agent: claude-code
role: reviewer
status: needs_fix
next_agent: codex
-->
"""
        )
        latest = parsed.latest_event
        assert latest is not None
        route = ai_loop.StateRouter().route_for_event(latest)

        with self.assertRaises(ai_loop.AILoopError):
            ai_loop.should_stop_for_cycle_cap(parsed, latest, route)


class GitContextTests(unittest.TestCase):
    def test_repo_name_supports_ssh_and_https_remotes(self) -> None:
        cases = {
            "git@github.com:kathelix/catvox.git": "kathelix/catvox",
            "https://github.com/kathelix/catvox.git": "kathelix/catvox",
            "https://github.com/kathelix/catvox": "kathelix/catvox",
            "git@github.com:kathelix/catvox": "kathelix/catvox",
        }
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            run(["git", "init"], repo)
            run(["git", "remote", "add", "origin", "git@github.com:kathelix/catvox.git"], repo)
            git = git_context(repo)

            for remote, expected in cases.items():
                with self.subTest(remote=remote):
                    run(["git", "remote", "set-url", "origin", remote], repo)
                    self.assertEqual(git.repo_name(), expected)


class PromptCompositionTests(unittest.TestCase):
    def test_developer_prompt_puts_codex_instructions_before_task_context(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            init_repo_with_ai_loop_tooling(repo)
            log_path = repo / "docs/ai-loop/local-20260524-120000.md"
            log_path.parent.mkdir(parents=True)
            log_path.write_text(
                """# AI Loop

<!-- ai-loop-event
agent: human
role: owner
cycle: 0
status: needs_developer
next_agent: codex
-->
""",
                encoding="utf-8",
            )

            prompt = prompt_composer(repo).compose_agent_prompt(
                log_path=log_path,
                role="developer",
                agent="codex",
            )
            task_context_index = prompt.index("<task_context>")

            for marker in [
                'path="AGENTS.md"',
                'path=".codex/AGENTS.md"',
                'path="tools/ai-loop/prompts/common.md"',
                'path="tools/ai-loop/prompts/developer.md"',
            ]:
                with self.subTest(marker=marker):
                    self.assertLess(prompt.index(marker), task_context_index)
            self.assertNotIn('path="CLAUDE.md"', prompt)
            self.assertNotIn("root agent instructions", prompt)
            self.assertNotIn("codex instructions", prompt)

    def test_reviewer_prompt_puts_claude_instructions_before_task_context(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            init_repo_with_ai_loop_tooling(repo)
            log_path = repo / "docs/ai-loop/local-20260524-120000.md"
            log_path.parent.mkdir(parents=True)
            log_path.write_text(
                """# AI Loop

<!-- ai-loop-event
agent: codex
role: developer
cycle: 1
status: needs_review
next_agent: claude-code
-->
""",
                encoding="utf-8",
            )

            prompt = prompt_composer(repo).compose_agent_prompt(
                log_path=log_path,
                role="reviewer",
                agent="claude-code",
            )
            task_context_index = prompt.index("<task_context>")

            for marker in [
                'path="AGENTS.md"',
                'path="CLAUDE.md"',
                'path="tools/ai-loop/prompts/common.md"',
                'path="tools/ai-loop/prompts/reviewer.md"',
            ]:
                with self.subTest(marker=marker):
                    self.assertLess(prompt.index(marker), task_context_index)
            self.assertNotIn('path=".codex/AGENTS.md"', prompt)
            self.assertNotIn("root agent instructions", prompt)
            self.assertNotIn("claude instructions", prompt)

    def test_prompt_uses_sha_context_without_full_patch(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            init_repo_with_ai_loop_tooling(repo)
            run(["git", "switch", "-c", "feature/context-test"], repo)
            (repo / "changed.txt").write_text("changed content\n", encoding="utf-8")
            run(["git", "add", "changed.txt"], repo)
            run(["git", "commit", "-m", "Add changed file"], repo)
            log_path = repo / "docs/ai-loop/local-20260524-120000.md"
            log_path.parent.mkdir(parents=True, exist_ok=True)
            log_path.write_text(
                """# AI Loop

## Initial user prompt

Review the changed file.

<!-- ai-loop-event
agent: codex
role: developer
cycle: 1
status: needs_review
next_agent: claude-code
-->
""",
                encoding="utf-8",
            )

            prompt = prompt_composer(repo).compose_agent_prompt(
                log_path=log_path,
                role="reviewer",
                agent="claude-code",
            )

            base = git_context(repo).resolve_diff_base()
            self.assertIsNotNone(base)
            assert base is not None
            head_sha = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
            merge_base = run(["git", "merge-base", "HEAD", base], repo).stdout.strip()
            diff_range = f"{merge_base}..{head_sha}"

            self.assertIn("## Git Status (`git status --short --branch`)", prompt)
            self.assertIn("Resolved base ref:", prompt)
            self.assertIn("Resolved base ref SHA:", prompt)
            self.assertIn(f"Resolved merge-base SHA: {merge_base}", prompt)
            self.assertIn(f"Dispatch HEAD SHA: {head_sha}", prompt)
            self.assertIn(f"Diff range: {diff_range}", prompt)
            self.assertIn("Changed files (`git diff --name-status", prompt)
            self.assertIn("Diff stat (`git diff --stat", prompt)
            self.assertIn("Suggested local inspection commands:", prompt)
            self.assertIn(f"git diff {diff_range}", prompt)
            self.assertIn(f"git diff {diff_range} -- <path>", prompt)
            self.assertIn("git status --short --branch", prompt)
            self.assertIn("Stale-state guard:", prompt)
            self.assertIn("git rev-parse HEAD", prompt)
            self.assertIn("Dispatch HEAD SHA above", prompt)
            self.assertIn("stop and report stale state", prompt)
            self.assertIn("changed.txt", prompt)
            self.assertIn("1 file changed", prompt)
            self.assertNotIn("diff --git", prompt)
            self.assertNotIn("@@", prompt)
            self.assertNotIn("+changed content", prompt)


class CommandProfileTests(unittest.TestCase):
    def test_default_agent_profiles_set_model_and_effort(self) -> None:
        repo = Path("/tmp/repo")
        dispatcher = agent_dispatcher(repo)
        with patch.dict(os.environ, {}, clear=True):
            codex_real = dispatcher.command_for_agent("codex", "real")
            codex_smoke = dispatcher.command_for_agent("codex", "smoke")
            claude_real = dispatcher.command_for_agent("claude-code", "real")
            claude_smoke = dispatcher.command_for_agent("claude-code", "smoke")

        self.assertEqual(
            codex_real,
            [
                "codex",
                "exec",
                "--cd",
                "/tmp/repo",
                "-c",
                'model_reasoning_effort="xhigh"',
                "-",
            ],
        )
        self.assertEqual(
            codex_smoke,
            [
                "codex",
                "exec",
                "--cd",
                "/tmp/repo",
                "-c",
                'model_reasoning_effort="low"',
                "-",
            ],
        )
        self.assertEqual(
            claude_real,
            [
                "claude",
                "--print",
                "--input-format",
                "text",
                "--model",
                "opus",
                "--effort",
                "max",
            ],
        )
        self.assertEqual(
            claude_smoke,
            [
                "claude",
                "--print",
                "--input-format",
                "text",
                "--model",
                "haiku",
                "--effort",
                "low",
            ],
        )

    def test_profile_specific_command_override_wins_over_legacy_override(self) -> None:
        repo = Path("/tmp/repo")
        with patch.dict(
            os.environ,
            {
                "AI_LOOP_CLAUDE_SMOKE_COMMAND": "profile-claude {repo}",
                "AI_LOOP_CLAUDE_COMMAND": "legacy-claude {repo}",
            },
            clear=True,
        ):
            command = agent_dispatcher(repo).command_for_agent("claude-code", "smoke")

        self.assertEqual(command, ["profile-claude", "/tmp/repo"])

    def test_agent_profile_can_come_from_env(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            init_repo_with_ai_loop_tooling(repo)
            args = type("Args", (), {"agent_profile": ""})()
            with patch.dict(os.environ, {"AI_LOOP_AGENT_PROFILE": "smoke"}):
                profile = agent_dispatcher(repo).selected_profile(args)
        self.assertEqual(profile, "smoke")

    def test_agent_timeout_can_come_from_env(self) -> None:
        repo = Path("/tmp/repo")
        with patch.dict(os.environ, {"AI_LOOP_AGENT_TIMEOUT_SECONDS": "12.5"}):
            timeout = agent_dispatcher(repo).selected_timeout_seconds()

        self.assertEqual(timeout, 12.5)

    def test_agent_timeout_can_come_from_git_config(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            init_repo_with_ai_loop_tooling(repo)
            run(["git", "config", "ai-loop.agentTimeoutSeconds", "7"], repo)
            with patch.dict(os.environ, {}, clear=True):
                timeout = agent_dispatcher(repo).selected_timeout_seconds()

        self.assertEqual(timeout, 7.0)

    def test_reject_invalid_agent_timeout(self) -> None:
        # subprocess.run rejects non-finite timeouts at runtime with an
        # unwrapped OverflowError (and NaN comparisons are False either way,
        # so the previous <= 0 guard let NaN slip through). All non-positive
        # and non-finite values must be rejected here as AILoopError.
        repo = Path("/tmp/repo")
        cases = ["0", "-1", "not-a-number", "inf", "-inf", "nan", "Infinity", "NaN"]
        for raw in cases:
            with self.subTest(raw=raw):
                with patch.dict(os.environ, {"AI_LOOP_AGENT_TIMEOUT_SECONDS": raw}):
                    with self.assertRaises(ai_loop.AILoopError) as ctx:
                        agent_dispatcher(repo).selected_timeout_seconds()
                self.assertIn("positive, finite number of seconds", str(ctx.exception))


class AgentDispatchTests(unittest.TestCase):
    def test_continue_can_invoke_reviewer_with_composed_prompt_on_stdin(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            repo.mkdir()
            init_repo_with_ai_loop_tooling(repo)

            log_path = repo / "docs/ai-loop/local-20260524-120000.md"
            log_path.parent.mkdir(parents=True)
            log_path.write_text(
                """# AI Loop

<!-- ai-loop-event
agent: codex
role: developer
cycle: 1
status: needs_review
next_agent: claude-code
-->
""",
                encoding="utf-8",
            )
            run(["git", "add", "docs/ai-loop/local-20260524-120000.md"], repo)
            run(["git", "commit", "-m", "[ai-loop] Codex: ready for review"], repo)

            fake_agent = root / "fake_agent.py"
            captured_prompt = root / "captured_prompt.txt"
            fake_agent.write_text(
                "from pathlib import Path\n"
                "import re\n"
                "import subprocess\n"
                "import sys\n"
                "prompt = sys.stdin.read()\n"
                "Path(sys.argv[1]).write_text(prompt, encoding='utf-8')\n"
                "match = re.search(r'^AI loop log: (?P<path>.+)$', prompt, re.MULTILINE)\n"
                "if not match:\n"
                "    raise SystemExit('AI loop log path not found in prompt')\n"
                "log_path = Path(match.group('path').strip())\n"
                "if not log_path.is_absolute():\n"
                "    log_path = Path.cwd() / log_path\n"
                "with log_path.open('a', encoding='utf-8') as handle:\n"
                "    handle.write('\\n## Fake reviewer event\\n\\n<!-- ai-loop-event\\n')\n"
                "    handle.write('agent: claude-code\\nrole: reviewer\\ncycle: 1\\nstatus: clean\\n')\n"
                "    handle.write('-->\\n')\n"
                "subprocess.run(['git', 'add', str(log_path)], check=True)\n"
                "subprocess.run(['git', 'commit', '-m', '[ai-loop] claude-code: clean'], check=True)\n",
                encoding="utf-8",
            )
            env = os.environ.copy()
            env["AI_LOOP_CLAUDE_COMMAND"] = f"{sys.executable} {fake_agent} {captured_prompt}"

            script = repo / "tools/ai-loop/ai_loop.py"
            result = run(
                [
                    sys.executable,
                    str(script),
                    "continue",
                    "--trigger",
                    "test",
                    "--log",
                    str(log_path),
                    "--invoke",
                ],
                repo,
                env=env,
            )

            self.assertIn("dispatching reviewer agent claude-code", result.stdout)
            prompt = captured_prompt.read_text(encoding="utf-8")
            self.assertLess(prompt.index('path="AGENTS.md"'), prompt.index("<task_context>"))
            self.assertLess(prompt.index('path="CLAUDE.md"'), prompt.index("<task_context>"))
            self.assertIn("status: needs_review", prompt)

    def test_invoked_agent_must_commit_ai_loop_event(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            repo.mkdir()
            init_repo_with_ai_loop_tooling(repo)
            log_path = write_committed_log(
                repo,
                """# AI Loop

<!-- ai-loop-event
agent: codex
role: developer
cycle: 1
status: needs_review
next_agent: claude-code
-->
""",
            )

            fake_agent = root / "fake_agent.py"
            fake_agent.write_text("import sys\nsys.stdin.read()\n", encoding="utf-8")
            env = os.environ.copy()
            env["AI_LOOP_CLAUDE_COMMAND"] = f"{sys.executable} {fake_agent}"

            script = repo / "tools/ai-loop/ai_loop.py"
            result = run(
                [
                    sys.executable,
                    str(script),
                    "continue",
                    "--trigger",
                    "test",
                    "--log",
                    str(log_path),
                    "--invoke",
                ],
                repo,
                check=False,
                env=env,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn(
                "reviewer agent exited without committing an AI loop event",
                result.stderr,
            )

    def test_invoked_agent_timeout_stops_loop(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            repo.mkdir()
            init_repo_with_ai_loop_tooling(repo)
            log_path = write_committed_log(
                repo,
                """# AI Loop

<!-- ai-loop-event
agent: codex
role: developer
cycle: 1
status: needs_review
next_agent: claude-code
-->
""",
            )

            fake_agent = root / "fake_agent.py"
            fake_agent.write_text(
                "import sys, time\nsys.stdin.read()\ntime.sleep(5)\n",
                encoding="utf-8",
            )
            env = os.environ.copy()
            env["AI_LOOP_CLAUDE_COMMAND"] = f"{sys.executable} {fake_agent}"
            env["AI_LOOP_AGENT_TIMEOUT_SECONDS"] = "0.1"

            script = repo / "tools/ai-loop/ai_loop.py"
            result = run(
                [
                    sys.executable,
                    str(script),
                    "continue",
                    "--trigger",
                    "test",
                    "--log",
                    str(log_path),
                    "--invoke",
                ],
                repo,
                check=False,
                env=env,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn(
                "claude-code exceeded timeout of 0.1s; loop stopped",
                result.stderr,
            )
            parsed = ai_loop.parse_log_file(log_path)
            self.assertEqual(parsed.latest_event["status"], "needs_review")

    def test_dispatch_loop_runs_until_reviewer_clean(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            repo.mkdir()
            init_repo_with_ai_loop_tooling(repo)

            log_path = repo / "docs/ai-loop/local-20260524-120000.md"
            log_path.parent.mkdir(parents=True)
            log_path.write_text(
                """# AI Loop

<!-- ai-loop-event
agent: human
role: owner
cycle: 0
status: needs_developer
next_agent: codex
-->
""",
                encoding="utf-8",
            )
            run(["git", "add", "docs/ai-loop/local-20260524-120000.md"], repo)
            run(["git", "commit", "-m", "[ai-loop] Human: start"], repo)

            fake_agent = root / "fake_agent.py"
            calls_path = root / "agent_calls.txt"
            sequence_path = root / "agent_sequence.txt"
            sequence_path.write_text(
                "\n".join(
                    [
                        "developer|1|needs_review|claude-code",
                        "reviewer|1|needs_fix|codex",
                        "developer|2|needs_review|claude-code",
                        "reviewer|2|clean|",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            write_fake_sequence_agent(fake_agent)

            env = os.environ.copy()
            env["AI_LOOP_CODEX_COMMAND"] = (
                f"{sys.executable} {fake_agent} developer {calls_path} "
                f"{sequence_path} {log_path}"
            )
            env["AI_LOOP_CLAUDE_COMMAND"] = (
                f"{sys.executable} {fake_agent} reviewer {calls_path} "
                f"{sequence_path} {log_path}"
            )

            script = repo / "tools/ai-loop/ai_loop.py"
            result = run(
                [
                    sys.executable,
                    str(script),
                    "continue",
                    "--trigger",
                    "test",
                    "--log",
                    str(log_path),
                    "--invoke",
                ],
                repo,
                env=env,
            )

            self.assertIn("dispatching developer agent codex", result.stdout)
            self.assertIn(
                "ai-loop handoff: dispatching reviewer agent: claude-code",
                result.stdout,
            )
            self.assertIn(
                "ai-loop handoff: dispatching developer agent: codex",
                result.stdout,
            )
            self.assertIn("dispatching reviewer agent claude-code", result.stdout)
            self.assertIn("ai-loop handoff: stop: review is clean", result.stdout)
            self.assertEqual(
                calls_path.read_text(encoding="utf-8").splitlines(),
                ["developer", "reviewer", "developer", "reviewer"],
            )
            parsed = ai_loop.parse_log_file(log_path)
            self.assertEqual(parsed.latest_event["status"], "clean")
            status = run(["git", "status", "--porcelain"], repo)
            self.assertEqual(status.stdout, "")

    def test_cycle_cap_stops_without_invoking_developer_and_commits_event(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            repo.mkdir()
            init_repo_with_ai_loop_tooling(repo)
            log_path = write_committed_log(
                repo,
                """# AI Loop

<!-- ai-loop-init
run_id: local-20260524-120000
max_cycles: 3
-->

<!-- ai-loop-event
agent: claude-code
role: reviewer
cycle: 3
status: needs_fix
next_agent: codex
-->
""",
            )

            fail_agent = root / "fail_agent.py"
            calls_path = root / "unexpected_call.txt"
            fail_agent.write_text(
                "from pathlib import Path\n"
                "import sys\n"
                "Path(sys.argv[1]).write_text('called', encoding='utf-8')\n"
                "raise SystemExit(17)\n",
                encoding="utf-8",
            )
            env = os.environ.copy()
            env["AI_LOOP_CODEX_COMMAND"] = f"{sys.executable} {fail_agent} {calls_path}"

            script = repo / "tools/ai-loop/ai_loop.py"
            result = run(
                [
                    sys.executable,
                    str(script),
                    "continue",
                    "--trigger",
                    "test",
                    "--log",
                    str(log_path),
                    "--invoke",
                ],
                repo,
                env=env,
            )

            self.assertIn("ai-loop (test): stop: cycle cap reached", result.stdout)
            self.assertFalse(calls_path.exists())
            parsed = ai_loop.parse_log_file(log_path)
            self.assertEqual(parsed.latest_event["agent"], "controller")
            self.assertEqual(parsed.latest_event["role"], "orchestrator")
            self.assertEqual(parsed.latest_event["cycle"], "3")
            self.assertEqual(parsed.latest_event["status"], "max_cycles_reached")
            self.assertIn("stopped_at", parsed.latest_event)
            commit_messages = run(["git", "log", "--format=%s"], repo)
            self.assertIn(
                "[ai-loop] Controller: max cycles reached", commit_messages.stdout
            )
            self.assertIn(
                "[ai-loop] Controller: finalize max_cycles_reached",
                commit_messages.stdout,
            )
            self.assertIn(
                ai_loop.TELEMETRY_FOOTER_MARKER,
                log_path.read_text(encoding="utf-8"),
            )
            status = run(["git", "status", "--porcelain"], repo)
            self.assertEqual(status.stdout, "")

    def test_cycle_cap_dry_run_does_not_commit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            init_repo_with_ai_loop_tooling(repo)
            log_path = write_committed_log(
                repo,
                """# AI Loop

<!-- ai-loop-init
run_id: local-20260524-120000
max_cycles: 3
-->

<!-- ai-loop-event
agent: claude-code
role: reviewer
cycle: 3
status: needs_fix
next_agent: codex
-->
""",
            )
            head_before = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
            log_before = log_path.read_text(encoding="utf-8")

            script = repo / "tools/ai-loop/ai_loop.py"
            result = run(
                [
                    sys.executable,
                    str(script),
                    "continue",
                    "--trigger",
                    "test",
                    "--log",
                    str(log_path),
                ],
                repo,
            )

            self.assertIn(
                "ai-loop dry-run (test): stop: cycle cap reached",
                result.stdout,
            )
            head_after = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
            self.assertEqual(head_after, head_before)
            self.assertEqual(log_path.read_text(encoding="utf-8"), log_before)
            parsed = ai_loop.parse_log_file(log_path)
            self.assertEqual(parsed.latest_event["status"], "needs_fix")

    def test_needs_fix_event_without_cycle_fails_loud_and_does_not_dispatch(
        self,
    ) -> None:
        # Defends the cycle cap against missing-metadata bypass: a reviewer
        # needs_fix event with no cycle field must abort the loop with a clear
        # error rather than dispatch the developer at an undefined cycle. See
        # GitHub issue #84 for the broader controller-side cycle hardening.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            repo.mkdir()
            init_repo_with_ai_loop_tooling(repo)
            log_path = write_committed_log(
                repo,
                """# AI Loop

<!-- ai-loop-init
run_id: local-20260524-120000
max_cycles: 3
-->

<!-- ai-loop-event
agent: claude-code
role: reviewer
status: needs_fix
next_agent: codex
-->
""",
            )

            fail_agent = root / "fail_agent.py"
            calls_path = root / "unexpected_call.txt"
            fail_agent.write_text(
                "from pathlib import Path\n"
                "import sys\n"
                "Path(sys.argv[1]).write_text('called', encoding='utf-8')\n"
                "raise SystemExit(17)\n",
                encoding="utf-8",
            )
            env = os.environ.copy()
            env["AI_LOOP_CODEX_COMMAND"] = (
                f"{sys.executable} {fail_agent} {calls_path}"
            )

            head_before = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
            log_before = log_path.read_text(encoding="utf-8")

            script = repo / "tools/ai-loop/ai_loop.py"
            result = run(
                [
                    sys.executable,
                    str(script),
                    "continue",
                    "--trigger",
                    "test",
                    "--log",
                    str(log_path),
                    "--invoke",
                ],
                repo,
                check=False,
                env=env,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("missing required cycle metadata", result.stderr)
            self.assertFalse(calls_path.exists())
            head_after = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
            self.assertEqual(head_after, head_before)
            self.assertEqual(log_path.read_text(encoding="utf-8"), log_before)
            status = run(["git", "status", "--porcelain"], repo)
            self.assertEqual(status.stdout, "")

    def test_clarified_event_resumes_named_agent_and_continues(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            repo.mkdir()
            init_repo_with_ai_loop_tooling(repo)
            log_path = write_committed_log(
                repo,
                """# AI Loop

<!-- ai-loop-init
run_id: local-20260524-120000
max_cycles: 3
-->

<!-- ai-loop-event
agent: human
role: owner
cycle: 1
status: clarified
next_agent: codex
questions: q1
-->
""",
            )

            fake_agent = root / "fake_agent.py"
            calls_path = root / "agent_calls.txt"
            sequence_path = root / "agent_sequence.txt"
            sequence_path.write_text(
                "\n".join(
                    [
                        "developer|2|needs_review|claude-code",
                        "reviewer|2|clean|",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            write_fake_sequence_agent(fake_agent)

            env = os.environ.copy()
            env["AI_LOOP_CODEX_COMMAND"] = (
                f"{sys.executable} {fake_agent} developer {calls_path} "
                f"{sequence_path} {log_path}"
            )
            env["AI_LOOP_CLAUDE_COMMAND"] = (
                f"{sys.executable} {fake_agent} reviewer {calls_path} "
                f"{sequence_path} {log_path}"
            )

            script = repo / "tools/ai-loop/ai_loop.py"
            result = run(
                [
                    sys.executable,
                    str(script),
                    "continue",
                    "--trigger",
                    "test",
                    "--log",
                    str(log_path),
                    "--invoke",
                ],
                repo,
                env=env,
            )

            self.assertIn("dispatching developer agent codex", result.stdout)
            self.assertIn(
                "ai-loop handoff: dispatching reviewer agent: claude-code",
                result.stdout,
            )
            self.assertEqual(
                calls_path.read_text(encoding="utf-8").splitlines(),
                ["developer", "reviewer"],
            )
            parsed = ai_loop.parse_log_file(log_path)
            self.assertEqual(parsed.latest_event["status"], "clean")

    def test_stop_statuses_do_not_dispatch(self) -> None:
        cases = {
            "clean": "stop: review is clean",
            "awaiting_human": "stop: awaiting human clarification",
            "failed": "stop: loop is failed",
            "paused": "stop: loop is paused",
            "max_cycles_reached": "stop: cycle cap reached",
            "mystery": "stop: unknown status 'mystery'",
        }
        for status, expected in cases.items():
            with self.subTest(status=status):
                with tempfile.TemporaryDirectory() as tmp:
                    repo = Path(tmp)
                    init_repo_with_ai_loop_tooling(repo)
                    log_path = write_committed_log(
                        repo,
                        f"""# AI Loop

<!-- ai-loop-event
agent: claude-code
role: reviewer
cycle: 1
status: {status}
-->
""",
                    )

                    script = repo / "tools/ai-loop/ai_loop.py"
                    result = run(
                        [
                            sys.executable,
                            str(script),
                            "continue",
                            "--trigger",
                            "test",
                            "--log",
                            str(log_path),
                            "--invoke",
                        ],
                        repo,
                    )

                    self.assertIn(f"ai-loop (test): {expected}", result.stdout)
                    self.assertEqual(
                        run(["git", "status", "--porcelain"], repo).stdout,
                        "",
                    )


class GitIntegrationTests(unittest.TestCase):
    def test_setup_start_and_hook_dry_run(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            run(["git", "init"], repo)
            run(["git", "config", "user.name", "AI Loop Test"], repo)
            run(["git", "config", "user.email", "ai-loop-test@example.com"], repo)
            # This test exercises hook routing only, not the default-on PR
            # bootstrap. Opt out so `start` doesn't try to talk to GitHub.
            run(["git", "config", "ai-loop.createPr", "false"], repo)

            shutil.copytree(TOOL_DIR, repo / "tools/ai-loop")
            run(["git", "add", "tools/ai-loop"], repo)
            run(["git", "commit", "-m", "Initial tools"], repo)

            script = repo / "tools/ai-loop/ai_loop.py"
            setup = run([sys.executable, str(script), "setup"], repo)
            self.assertIn("configured core.hooksPath=tools/ai-loop/hooks", setup.stdout)

            hooks_path = run(["git", "config", "--get", "core.hooksPath"], repo)
            self.assertEqual(hooks_path.stdout.strip(), "tools/ai-loop/hooks")

            start = run(
                [
                    sys.executable,
                    str(script),
                    "start",
                    "--branch",
                    "feature/ai-loop-test",
                    "--prompt",
                    "Implement test workflow",
                ],
                repo,
            )
            start_output = start.stdout + start.stderr
            # The bootstrap holds the ai-loop lock, so the post-commit
            # hook fired by the `[ai-loop] Human: start` commit must
            # see "lock exists" and skip. Without this guard the hook
            # used to dispatch the agent against the transient log
            # state — see the user-reported smoke failure on PR #90
            # where this fired even when codex was unavailable.
            self.assertIn("lock exists, skipping continuation", start_output)
            self.assertNotIn("would dispatch", start_output)

            branch = run(["git", "branch", "--show-current"], repo)
            self.assertEqual(branch.stdout.strip(), "feature/ai-loop-test")

            logs = sorted((repo / "docs/ai-loop").glob("local-*.md"))
            self.assertEqual(len(logs), 1)
            parsed = ai_loop.parse_log_file(logs[0])
            self.assertEqual(parsed.latest_event["status"], "needs_developer")

            commit_message = run(["git", "log", "-1", "--format=%B"], repo)
            self.assertIn("[ai-loop] Human: start", commit_message.stdout)

            # Verify the lock was released when command_start returned.
            # A subsequent [ai-loop] commit's post-commit hook must
            # now run normally and print the dry-run routing decision.
            # If the lock had leaked, this fire would also print
            # "lock exists" instead, leaving the loop wedged.
            with logs[0].open("a", encoding="utf-8") as handle:
                handle.write("\n<!-- regression marker -->\n")
            run(["git", "add", str(logs[0].relative_to(repo))], repo)
            post_start = run(
                [
                    "git",
                    "commit",
                    "-m",
                    "[ai-loop] Human: regression marker",
                ],
                repo,
            )
            post_start_output = post_start.stdout + post_start.stderr
            self.assertIn(
                "ai-loop dry-run (post-commit): would dispatch developer agent: codex",
                post_start_output,
            )
            self.assertNotIn("lock exists", post_start_output)

    def test_hook_invocation_hands_developer_to_reviewer_under_lock(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            repo.mkdir()
            init_repo_with_ai_loop_tooling(repo)

            script = repo / "tools/ai-loop/ai_loop.py"
            run([sys.executable, str(script), "setup"], repo)

            fake_agent = root / "fake_agent.py"
            calls_path = root / "agent_calls.txt"
            sequence_path = root / "agent_sequence.txt"
            sequence_path.write_text(
                "\n".join(
                    [
                        "developer|1|needs_review|claude-code",
                        "reviewer|1|needs_fix|codex",
                        "developer|2|needs_review|claude-code",
                        "reviewer|2|clean|",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            write_fake_sequence_agent(fake_agent)

            env = os.environ.copy()
            env["AI_LOOP_INVOKE_AGENTS"] = "1"
            env["AI_LOOP_CODEX_COMMAND"] = (
                f"{sys.executable} {fake_agent} developer {calls_path} {sequence_path}"
            )
            env["AI_LOOP_CLAUDE_COMMAND"] = (
                f"{sys.executable} {fake_agent} reviewer {calls_path} {sequence_path}"
            )

            start = run(
                [
                    sys.executable,
                    str(script),
                    "start",
                    "--branch",
                    "feature/ai-loop-hook-handoff",
                    "--prompt",
                    "Implement hook reviewer handoff",
                ],
                repo,
                env=env,
            )
            start_output = start.stdout + start.stderr

            self.assertIn("dispatching developer agent codex", start_output)
            self.assertIn(
                "ai-loop handoff: dispatching reviewer agent: claude-code",
                start_output,
            )
            self.assertIn(
                "ai-loop handoff: dispatching developer agent: codex",
                start_output,
            )
            self.assertIn("dispatching reviewer agent claude-code", start_output)
            self.assertIn("ai-loop handoff: stop: review is clean", start_output)
            self.assertIn("ai-loop: lock exists, skipping continuation", start_output)
            self.assertEqual(
                calls_path.read_text(encoding="utf-8").splitlines(),
                ["developer", "reviewer", "developer", "reviewer"],
            )

            logs = sorted((repo / "docs/ai-loop").glob("local-*.md"))
            self.assertEqual(len(logs), 1)
            parsed = ai_loop.parse_log_file(logs[0])
            self.assertEqual(parsed.latest_event["status"], "clean")
            status = run(["git", "status", "--porcelain"], repo)
            self.assertEqual(status.stdout, "")

    def test_answer_appends_clarified_event_and_wakes_hook(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            init_repo_with_ai_loop_tooling(repo)
            script = repo / "tools/ai-loop/ai_loop.py"
            run([sys.executable, str(script), "setup"], repo)

            log_path = repo / "docs/ai-loop/local-20260524-120000.md"
            log_path.parent.mkdir(parents=True)
            log_path.write_text(
                """# AI Loop

## Initial user prompt

Implement a clarification workflow.

<!-- ai-loop-event
agent: codex
role: developer
cycle: 1
status: awaiting_human
next_agent: human
questions: q1,q2
-->
""",
                encoding="utf-8",
            )
            run(["git", "add", "docs/ai-loop/local-20260524-120000.md"], repo)
            run(["git", "commit", "-m", "[ai-loop] Codex: ask clarification"], repo)

            result = run(
                [
                    sys.executable,
                    str(script),
                    "answer",
                    "--log",
                    str(log_path),
                    "--answer",
                    "q1 A, q2 B",
                ],
                repo,
            )
            output = result.stdout + result.stderr
            self.assertIn(
                "ai-loop dry-run (post-commit): would dispatch developer agent: codex",
                output,
            )
            self.assertIn(
                "appended human answer to docs/ai-loop/local-20260524-120000.md",
                output,
            )

            parsed = ai_loop.parse_log_file(log_path)
            self.assertEqual(parsed.latest_event["agent"], "human")
            self.assertEqual(parsed.latest_event["status"], "clarified")
            self.assertEqual(parsed.latest_event["next_agent"], "codex")
            self.assertEqual(parsed.latest_event["questions"], "q1,q2")

            commit_message = run(["git", "log", "-1", "--format=%B"], repo)
            self.assertIn("[ai-loop] Human: answer q1,q2", commit_message.stdout)
            status = run(["git", "status", "--porcelain"], repo)
            self.assertEqual(status.stdout, "")

    def test_hook_ignores_commit_with_ai_loop_only_in_body(self) -> None:
        # Regression guard for the hook's prefix tightening: a normal
        # commit whose body merely references `[ai-loop]` (e.g. a
        # retrospective lesson or a fix note explaining the convention)
        # must NOT wake the controller. Before the prefix fix, the hook
        # matched `[ai-loop]` anywhere in the full commit message and
        # tripped on harmless mentions like these.
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            init_repo_with_ai_loop_tooling(repo)
            script = repo / "tools/ai-loop/ai_loop.py"
            run([sys.executable, str(script), "setup"], repo)

            (repo / "notes.md").write_text(
                "Mention of the `[ai-loop]` convention.\n",
                encoding="utf-8",
            )
            run(["git", "add", "notes.md"], repo)
            commit = run(
                [
                    "git",
                    "commit",
                    "-m",
                    "Add notes",
                    "-m",
                    "Body references `[ai-loop] Human: start` in backticks.",
                ],
                repo,
            )

            output = commit.stdout + commit.stderr
            # Neither the dry-run routing line nor the
            # "latest commit did not change an AI loop log" failure
            # should appear: the hook must exit before invoking the
            # controller at all.
            self.assertNotIn("ai-loop dry-run", output)
            self.assertNotIn("ai-loop:", output)
            self.assertNotIn("lock exists, skipping", output)

    def test_hook_dry_run_uses_real_git_dir_in_linked_worktree(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            linked = root / "linked"
            repo.mkdir()

            run(["git", "init"], repo)
            run(["git", "config", "user.name", "AI Loop Test"], repo)
            run(["git", "config", "user.email", "ai-loop-test@example.com"], repo)
            # This test exercises hook routing in a linked worktree only,
            # not the default-on PR bootstrap.
            run(["git", "config", "ai-loop.createPr", "false"], repo)

            shutil.copytree(TOOL_DIR, repo / "tools/ai-loop")
            run(["git", "add", "tools/ai-loop"], repo)
            run(["git", "commit", "-m", "Initial tools"], repo)
            run([sys.executable, str(repo / "tools/ai-loop/ai_loop.py"), "setup"], repo)
            run(["git", "worktree", "add", "-b", "feature/linked", str(linked)], repo)

            linked_script = linked / "tools/ai-loop/ai_loop.py"
            start = run(
                [
                    sys.executable,
                    str(linked_script),
                    "start",
                    "--branch",
                    "feature/ai-loop-linked-start",
                    "--prompt",
                    "Implement linked worktree workflow",
                ],
                linked,
            )
            start_output = start.stdout + start.stderr
            # The bootstrap holds the ai-loop lock (now keyed off the
            # real gitdir resolved via `git rev-parse --git-dir`, which
            # in a linked worktree points to .git/worktrees/<name>/),
            # so the post-commit hook fired during bootstrap must see
            # "lock exists" and skip. That this works for the linked
            # worktree as well confirms the lock resolution honors the
            # real git dir rather than the worktree's stub .git file.
            self.assertIn("lock exists, skipping continuation", start_output)
            self.assertNotIn("would dispatch", start_output)

            git_dir = run(["git", "rev-parse", "--git-dir"], linked).stdout.strip()
            self.assertNotEqual(git_dir, ".git")
            self.assertTrue(git_dir)

            # Verify the lock was released after bootstrap by making a
            # follow-up [ai-loop] commit in the linked worktree and
            # confirming its hook fire runs the dry-run dispatch path
            # rather than skipping. If `_acquire_ai_loop_lock` had
            # resolved the git dir incorrectly (e.g., used `.git`
            # relative path inside the worktree), the lock would have
            # leaked into the worktree's stub .git file and broken
            # follow-up hook fires.
            log_path = sorted((linked / "docs/ai-loop").glob("local-*.md"))[0]
            with log_path.open("a", encoding="utf-8") as handle:
                handle.write("\n<!-- regression marker -->\n")
            run(["git", "add", str(log_path.relative_to(linked))], linked)
            post_start = run(
                [
                    "git",
                    "commit",
                    "-m",
                    "[ai-loop] Human: regression marker",
                ],
                linked,
            )
            post_start_output = post_start.stdout + post_start.stderr
            self.assertIn(
                "ai-loop dry-run (post-commit): would dispatch developer agent: codex",
                post_start_output,
            )
            self.assertNotIn("lock exists", post_start_output)


class PlaceholderRenderTests(unittest.TestCase):
    def test_pr_log_relpath_pads_to_four_digits(self) -> None:
        self.assertEqual(ai_loop.pr_log_relpath(86), "docs/ai-loop/pr-0086.md")
        self.assertEqual(ai_loop.pr_log_relpath(1), "docs/ai-loop/pr-0001.md")
        self.assertEqual(ai_loop.pr_log_relpath(12345), "docs/ai-loop/pr-12345.md")

    def test_placeholder_pr_title_truncates_long_first_line(self) -> None:
        title = ai_loop.placeholder_pr_title(
            "a" * 200, max_length=20
        )
        self.assertTrue(title.startswith("[wip] "))
        self.assertLessEqual(len(title), 20)
        self.assertTrue(title.endswith("…"))

    def test_placeholder_pr_title_uses_first_non_blank_line(self) -> None:
        title = ai_loop.placeholder_pr_title("\n\n  Implement issue #63  \n\n…")
        self.assertEqual(title, "[wip] Implement issue #63")

    def test_placeholder_pr_title_falls_back_when_prompt_blank(self) -> None:
        title = ai_loop.placeholder_pr_title("   \n  \n")
        self.assertEqual(title, "[wip] AI loop bootstrap")

    def test_placeholder_pr_body_mentions_branch_and_upkeep_rule(self) -> None:
        body = ai_loop.placeholder_pr_body("feature/test-branch")
        self.assertIn("`feature/test-branch`", body)
        self.assertIn("docs/ai-loop/", body)
        self.assertIn("update this PR title and body", body)

    def test_render_bootstrap_log_includes_pr_when_supplied(self) -> None:
        log = ai_loop.render_bootstrap_log(
            run_id="local-20260524-120000",
            log_path="docs/ai-loop/pr-0086.md",
            prompt="Implement the thing",
            repo="kathelix/catvox",
            commit_at_start="deadbeefcafef00d1234567890abcdef12345678",
            started_at="2026-05-24T12:00:00+02:00",
            display_time="2026-05-24 12:00 CEST",
            pr=86,
        )
        self.assertIn("# AI Loop - PR #0086", log)
        self.assertIn("- PR: #0086", log)
        self.assertIn(
            "- Commit at start: deadbeefcafef00d1234567890abcdef12345678", log
        )
        parsed = ai_loop.parse_log_text(log)
        assert parsed.init is not None
        self.assertEqual(parsed.init["pr"], "86")
        self.assertEqual(parsed.init["log_path"], "docs/ai-loop/pr-0086.md")
        self.assertEqual(parsed.init["run_id"], "local-20260524-120000")
        self.assertEqual(
            parsed.init["commit_at_start"],
            "deadbeefcafef00d1234567890abcdef12345678",
        )
        self.assertNotIn("branch_at_start", parsed.init)

    def test_render_bootstrap_log_without_pr_keeps_legacy_shape(self) -> None:
        log = ai_loop.render_bootstrap_log(
            run_id="local-20260524-120000",
            log_path="docs/ai-loop/local-20260524-120000.md",
            prompt="Implement the thing",
            repo="kathelix/catvox",
            commit_at_start="deadbeefcafef00d1234567890abcdef12345678",
            started_at="2026-05-24T12:00:00+02:00",
            display_time="2026-05-24 12:00 CEST",
        )
        self.assertIn("# AI Loop - local-20260524-120000", log)
        self.assertNotIn("- PR:", log)
        parsed = ai_loop.parse_log_text(log)
        assert parsed.init is not None
        self.assertNotIn("pr", parsed.init)
        self.assertEqual(
            parsed.init["commit_at_start"],
            "deadbeefcafef00d1234567890abcdef12345678",
        )

    def test_render_bootstrap_log_includes_env_vars_when_supplied(self) -> None:
        log = ai_loop.render_bootstrap_log(
            run_id="local-20260524-120000",
            log_path="docs/ai-loop/pr-0093.md",
            prompt="Smoke test",
            repo="kathelix/catvox",
            commit_at_start="deadbeefcafef00d1234567890abcdef12345678",
            started_at="2026-05-24T12:00:00+02:00",
            env_vars=[
                ("AI_LOOP_AGENT_PROFILE", "smoke"),
                ("AI_LOOP_BRANCH", "smoke/eol-summary-clean-2026-05-27"),
                ("AI_LOOP_INVOKE_AGENTS", "1"),
            ],
            pr=93,
        )
        self.assertIn("### Environment variables at start", log)
        self.assertIn("AI_LOOP_INVOKE_AGENTS=1", log)
        self.assertIn("AI_LOOP_AGENT_PROFILE=smoke", log)
        self.assertIn(
            "AI_LOOP_BRANCH=smoke/eol-summary-clean-2026-05-27", log
        )

    def test_render_bootstrap_log_omits_env_section_when_empty(self) -> None:
        log = ai_loop.render_bootstrap_log(
            run_id="local-20260524-120000",
            log_path="docs/ai-loop/local-20260524-120000.md",
            prompt="Implement the thing",
            repo="kathelix/catvox",
            commit_at_start="deadbeefcafef00d1234567890abcdef12345678",
            started_at="2026-05-24T12:00:00+02:00",
            env_vars=[],
        )
        self.assertNotIn("Environment variables at start", log)


class CollectAiLoopEnvVarsTests(unittest.TestCase):
    def test_filters_to_ai_loop_prefix_and_sorts(self) -> None:
        env = {
            "PATH": "/usr/bin",
            "AI_LOOP_INVOKE_AGENTS": "1",
            "AI_LOOP_AGENT_PROFILE": "smoke",
            "AI_LOOP_BRANCH": "smoke/eol",
            "HOME": "/Users/test",
        }
        pairs = ai_loop.collect_ai_loop_env_vars(env)
        # Sorted alphabetically; non-AI_LOOP_ vars filtered out.
        self.assertEqual(
            pairs,
            [
                ("AI_LOOP_AGENT_PROFILE", "smoke"),
                ("AI_LOOP_BRANCH", "smoke/eol"),
                ("AI_LOOP_INVOKE_AGENTS", "1"),
            ],
        )

    def test_excludes_content_vars(self) -> None:
        env = {
            "AI_LOOP_PROMPT": "Implement the thing",
            "AI_LOOP_ANSWER": "q1 A",
            "AI_LOOP_NEXT_AGENT": "codex",
            "AI_LOOP_AGENT_PROFILE": "smoke",
        }
        pairs = ai_loop.collect_ai_loop_env_vars(env)
        keys = [key for key, _ in pairs]
        self.assertEqual(keys, ["AI_LOOP_AGENT_PROFILE"])
        self.assertNotIn("AI_LOOP_PROMPT", keys)
        self.assertNotIn("AI_LOOP_ANSWER", keys)
        self.assertNotIn("AI_LOOP_NEXT_AGENT", keys)

    def test_returns_empty_when_no_ai_loop_vars_set(self) -> None:
        self.assertEqual(
            ai_loop.collect_ai_loop_env_vars(
                {"PATH": "/usr/bin", "HOME": "/Users/test"}
            ),
            [],
        )


class PrBootstrapTests(unittest.TestCase):
    def _shim_env(
        self,
        state_dir: Path,
        shim_path: Path,
    ) -> dict[str, str]:
        # AI_LOOP_CREATE_PR is intentionally unset so these tests exercise
        # the default-ON behavior. Tests that need to verify the opt-out
        # path or the explicit truthy/falsy precedence set it themselves.
        env = os.environ.copy()
        env["AI_LOOP_GH_COMMAND"] = f"{sys.executable} {shim_path}"
        env["GH_SHIM_STATE_DIR"] = str(state_dir)
        env.pop("AI_LOOP_CREATE_PR", None)
        return env

    def test_create_pr_happy_path_renames_log_and_applies_label(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            origin = root / "origin.git"
            repo.mkdir()
            init_repo_with_bare_origin(repo, origin)

            shim = root / "gh_shim.py"
            state_dir = root / "gh_state"
            write_gh_shim(shim)
            env = self._shim_env(state_dir, shim)

            script = repo / "tools/ai-loop/ai_loop.py"
            result = run(
                [
                    sys.executable,
                    str(script),
                    "start",
                    "--branch",
                    "feature/pr-bootstrap-happy",
                    "--prompt",
                    "Implement issue #63 PR-numbered bootstrap",
                ],
                repo,
                env=env,
            )

            output = result.stdout + result.stderr
            self.assertIn("created draft PR #1", output)
            self.assertIn("renamed to docs/ai-loop/pr-0001.md", output)
            self.assertIn("applied label 'ai-loop' to PR #1", output)

            new_log = repo / "docs/ai-loop/pr-0001.md"
            old_logs = list((repo / "docs/ai-loop").glob("local-*.md"))
            self.assertEqual(old_logs, [])
            self.assertTrue(new_log.exists())
            parsed = ai_loop.parse_log_file(new_log)
            assert parsed.init is not None
            self.assertEqual(parsed.init["pr"], "1")
            self.assertEqual(parsed.init["log_path"], "docs/ai-loop/pr-0001.md")

            # PR #93 review finding V1: commit_at_start replaces
            # branch_at_start. The value must be a real SHA from the
            # repo (origin/main tip at bootstrap time).
            commit_at_start = parsed.init["commit_at_start"]
            self.assertNotIn("branch_at_start", parsed.init)
            self.assertEqual(len(commit_at_start), 40)
            origin_main_sha = run(
                ["git", "rev-parse", "origin/main"], repo
            ).stdout.strip()
            self.assertEqual(commit_at_start, origin_main_sha)

            # PR #93 review finding V2: the AI_LOOP_* env vars set
            # at bootstrap time are rendered in the log so a human
            # reader can reconstruct how the loop was started. The
            # shim env in this test sets AI_LOOP_GH_COMMAND, which
            # must appear in the Environment block; non-AI_LOOP_*
            # env vars (like GH_SHIM_STATE_DIR) must not.
            log_text = new_log.read_text(encoding="utf-8")
            self.assertIn("### Environment variables at start", log_text)
            self.assertIn("AI_LOOP_GH_COMMAND=", log_text)
            self.assertNotIn("GH_SHIM_STATE_DIR=", log_text)

            commits = run(["git", "log", "--format=%s"], repo).stdout.splitlines()
            self.assertEqual(commits[0], "[ai-loop] Human: bootstrap pr-0001")
            self.assertTrue(commits[1].startswith("[ai-loop] Human: start local-"))

            # Branch was pushed
            remote_branches = run(
                ["git", "branch", "-r"], repo
            ).stdout
            self.assertIn(
                "origin/feature/pr-bootstrap-happy", remote_branches
            )

            # Both bootstrap commits (start local-..., bootstrap pr-NNNN)
            # must be on origin. The first push happens before `gh pr
            # create`, but the rename commit needs a second explicit push
            # — without it, the remote PR shows the pre-rename
            # local-*.md log instead of pr-NNNN.md (see PR #86 smoke
            # finding F5).
            local_head = run(
                ["git", "rev-parse", "HEAD"], repo
            ).stdout.strip()
            remote_head = run(
                ["git", "rev-parse", "origin/feature/pr-bootstrap-happy"],
                repo,
            ).stdout.strip()
            self.assertEqual(
                local_head,
                remote_head,
                "bootstrap rename commit should be pushed to origin",
            )

            calls = read_gh_calls(state_dir)
            pr_create = [c for c in calls if c[:2] == ["pr", "create"]]
            self.assertEqual(len(pr_create), 1)
            self.assertIn("--draft", pr_create[0])
            self.assertIn("--base", pr_create[0])
            self.assertIn("main", pr_create[0])
            self.assertIn("--head", pr_create[0])
            self.assertIn("feature/pr-bootstrap-happy", pr_create[0])
            title_index = pr_create[0].index("--title") + 1
            self.assertTrue(pr_create[0][title_index].startswith("[wip] "))

            label_create = [c for c in calls if c[:2] == ["label", "create"]]
            self.assertEqual(len(label_create), 1)
            self.assertEqual(label_create[0][2], "ai-loop")

            pr_edits = [c for c in calls if c[:2] == ["pr", "edit"]]
            self.assertEqual(len(pr_edits), 1)
            self.assertIn("--add-label", pr_edits[0])
            self.assertIn("ai-loop", pr_edits[0])

    def test_opt_out_via_env_keeps_legacy_local_log_and_skips_gh(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            origin = root / "origin.git"
            repo.mkdir()
            init_repo_with_bare_origin(repo, origin)

            shim = root / "gh_shim.py"
            state_dir = root / "gh_state"
            write_gh_shim(shim)
            env = self._shim_env(state_dir, shim)
            env["AI_LOOP_CREATE_PR"] = "0"

            script = repo / "tools/ai-loop/ai_loop.py"
            result = run(
                [
                    sys.executable,
                    str(script),
                    "start",
                    "--branch",
                    "feature/pr-bootstrap-opt-out-env",
                    "--prompt",
                    "Implement the requested change",
                ],
                repo,
                env=env,
            )

            output = result.stdout + result.stderr
            self.assertNotIn("created draft PR", output)
            self.assertNotIn("renamed to docs/ai-loop/pr-", output)

            local_logs = sorted((repo / "docs/ai-loop").glob("local-*.md"))
            self.assertEqual(len(local_logs), 1)
            pr_logs = list((repo / "docs/ai-loop").glob("pr-*.md"))
            self.assertEqual(pr_logs, [])
            self.assertEqual(read_gh_calls(state_dir), [])

    def test_opt_out_via_git_config_keeps_legacy_local_log(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            origin = root / "origin.git"
            repo.mkdir()
            init_repo_with_bare_origin(repo, origin)
            run(["git", "config", "ai-loop.createPr", "false"], repo)

            shim = root / "gh_shim.py"
            state_dir = root / "gh_state"
            write_gh_shim(shim)
            env = self._shim_env(state_dir, shim)

            script = repo / "tools/ai-loop/ai_loop.py"
            result = run(
                [
                    sys.executable,
                    str(script),
                    "start",
                    "--branch",
                    "feature/pr-bootstrap-opt-out-config",
                    "--prompt",
                    "Implement the requested change",
                ],
                repo,
                env=env,
            )

            output = result.stdout + result.stderr
            self.assertNotIn("created draft PR", output)

            local_logs = sorted((repo / "docs/ai-loop").glob("local-*.md"))
            self.assertEqual(len(local_logs), 1)
            pr_logs = list((repo / "docs/ai-loop").glob("pr-*.md"))
            self.assertEqual(pr_logs, [])
            self.assertEqual(read_gh_calls(state_dir), [])

    def test_opt_out_via_cli_flag_keeps_legacy_local_log(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            origin = root / "origin.git"
            repo.mkdir()
            init_repo_with_bare_origin(repo, origin)

            shim = root / "gh_shim.py"
            state_dir = root / "gh_state"
            write_gh_shim(shim)
            env = self._shim_env(state_dir, shim)
            env["AI_LOOP_CREATE_PR"] = "1"  # would be on; --no-create-pr wins

            script = repo / "tools/ai-loop/ai_loop.py"
            result = run(
                [
                    sys.executable,
                    str(script),
                    "start",
                    "--branch",
                    "feature/pr-bootstrap-opt-out-cli",
                    "--prompt",
                    "Implement the requested change",
                    "--no-create-pr",
                ],
                repo,
                env=env,
            )

            output = result.stdout + result.stderr
            self.assertNotIn("created draft PR", output)

            local_logs = sorted((repo / "docs/ai-loop").glob("local-*.md"))
            self.assertEqual(len(local_logs), 1)
            pr_logs = list((repo / "docs/ai-loop").glob("pr-*.md"))
            self.assertEqual(pr_logs, [])
            self.assertEqual(read_gh_calls(state_dir), [])

    def test_missing_gh_binary_fails_before_commit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            origin = root / "origin.git"
            repo.mkdir()
            init_repo_with_bare_origin(repo, origin)

            head_before = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()

            env = os.environ.copy()
            env["AI_LOOP_GH_COMMAND"] = "/nonexistent/gh-binary-does-not-exist"
            # Default is ON; pop in case the test runner inherits an opt-out.
            env.pop("AI_LOOP_CREATE_PR", None)

            script = repo / "tools/ai-loop/ai_loop.py"
            result = run(
                [
                    sys.executable,
                    str(script),
                    "start",
                    "--branch",
                    "feature/pr-bootstrap-no-gh",
                    "--prompt",
                    "Implement",
                ],
                repo,
                check=False,
                env=env,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("CLI not found on PATH", result.stderr)
            head_after = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
            self.assertEqual(head_after, head_before)
            self.assertEqual(
                list((repo / "docs/ai-loop").glob("*"))
                if (repo / "docs/ai-loop").exists()
                else [],
                [],
            )

    def test_gh_auth_failure_fails_before_commit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            origin = root / "origin.git"
            repo.mkdir()
            init_repo_with_bare_origin(repo, origin)

            shim = root / "gh_shim.py"
            state_dir = root / "gh_state"
            write_gh_shim(shim)
            state_dir.mkdir(parents=True, exist_ok=True)
            (state_dir / "auth_rc.txt").write_text("1", encoding="utf-8")
            env = self._shim_env(state_dir, shim)

            head_before = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()

            script = repo / "tools/ai-loop/ai_loop.py"
            result = run(
                [
                    sys.executable,
                    str(script),
                    "start",
                    "--branch",
                    "feature/pr-bootstrap-auth-fail",
                    "--prompt",
                    "Implement",
                ],
                repo,
                check=False,
                env=env,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("gh is not authenticated", result.stderr)
            self.assertIn("gh auth login", result.stderr)
            head_after = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
            self.assertEqual(head_after, head_before)

    def test_missing_origin_remote_fails_before_commit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            repo.mkdir()
            run(["git", "init", "--initial-branch=main"], repo)
            run(["git", "config", "user.name", "AI Loop Test"], repo)
            run(["git", "config", "user.email", "ai-loop-test@example.com"], repo)
            write_minimal_instruction_files(repo)
            shutil.copytree(TOOL_DIR, repo / "tools/ai-loop")
            run(["git", "add", "."], repo)
            run(["git", "commit", "-m", "Initial tools"], repo)

            shim = root / "gh_shim.py"
            state_dir = root / "gh_state"
            write_gh_shim(shim)
            env = self._shim_env(state_dir, shim)

            head_before = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()

            script = repo / "tools/ai-loop/ai_loop.py"
            result = run(
                [
                    sys.executable,
                    str(script),
                    "start",
                    "--branch",
                    "feature/pr-bootstrap-no-origin",
                    "--prompt",
                    "Implement",
                ],
                repo,
                check=False,
                env=env,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("no `origin` remote configured", result.stderr)
            head_after = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
            self.assertEqual(head_after, head_before)

    def test_branch_not_descendant_of_origin_main_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            origin = root / "origin.git"
            repo.mkdir()
            init_repo_with_bare_origin(repo, origin)

            # Create an orphan branch with no shared history with main but
            # keep the tools/ai-loop tree intact so the script remains
            # invokable from the new worktree.
            run(["git", "checkout", "--orphan", "feature/diverged"], repo)
            run(["git", "commit", "-m", "Diverged root"], repo)

            shim = root / "gh_shim.py"
            state_dir = root / "gh_state"
            write_gh_shim(shim)
            env = self._shim_env(state_dir, shim)

            head_before = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()

            script = repo / "tools/ai-loop/ai_loop.py"
            result = run(
                [
                    sys.executable,
                    str(script),
                    "start",
                    "--branch",
                    "feature/diverged",
                    "--prompt",
                    "Implement",
                ],
                repo,
                check=False,
                env=env,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("not a descendant of origin/main", result.stderr)
            head_after = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
            self.assertEqual(head_after, head_before)
            pr_logs = list((repo / "docs/ai-loop").glob("*.md"))
            self.assertEqual(pr_logs, [])

    def test_existing_open_pr_for_branch_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            origin = root / "origin.git"
            repo.mkdir()
            init_repo_with_bare_origin(repo, origin)

            shim = root / "gh_shim.py"
            state_dir = root / "gh_state"
            write_gh_shim(shim)
            state_dir.mkdir(parents=True, exist_ok=True)
            (state_dir / "existing_prs.txt").write_text("42\n", encoding="utf-8")
            env = self._shim_env(state_dir, shim)

            head_before = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()

            script = repo / "tools/ai-loop/ai_loop.py"
            result = run(
                [
                    sys.executable,
                    str(script),
                    "start",
                    "--branch",
                    "feature/pr-bootstrap-existing-pr",
                    "--prompt",
                    "Implement",
                ],
                repo,
                check=False,
                env=env,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("open PR #42 already exists", result.stderr)
            head_after = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
            self.assertEqual(head_after, head_before)
            pr_logs = list((repo / "docs/ai-loop").glob("*.md"))
            self.assertEqual(pr_logs, [])

    def test_pr_create_failure_leaves_local_commit_intact(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            origin = root / "origin.git"
            repo.mkdir()
            init_repo_with_bare_origin(repo, origin)

            shim = root / "gh_shim.py"
            state_dir = root / "gh_state"
            write_gh_shim(shim)
            state_dir.mkdir(parents=True, exist_ok=True)
            (state_dir / "create_fail.txt").write_text("1", encoding="utf-8")
            env = self._shim_env(state_dir, shim)

            head_before = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()

            script = repo / "tools/ai-loop/ai_loop.py"
            result = run(
                [
                    sys.executable,
                    str(script),
                    "start",
                    "--branch",
                    "feature/pr-bootstrap-create-fail",
                    "--prompt",
                    "Implement",
                ],
                repo,
                check=False,
                env=env,
            )

            self.assertEqual(result.returncode, 1)
            head_after = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
            self.assertNotEqual(head_after, head_before)
            # The legacy local-*.md commit should still be on the branch.
            local_logs = list((repo / "docs/ai-loop").glob("local-*.md"))
            self.assertEqual(len(local_logs), 1)
            # No pr-*.md created
            pr_logs = list((repo / "docs/ai-loop").glob("pr-*.md"))
            self.assertEqual(pr_logs, [])

    def test_invoke_agents_dispatches_once_after_bootstrap(self) -> None:
        """Regression for the user-reported smoke failure on PR #90.

        When ``AI_LOOP_INVOKE_AGENTS=1`` is set and the post-commit
        hook is installed, ``make ai-loop-start`` previously fired the
        hook between bootstrap commits — once after
        ``[ai-loop] Human: start local-...`` and once after
        ``[ai-loop] Human: bootstrap pr-NNNN``. Each fire dispatched
        the developer agent against transient log state. The first
        dispatch operated on the pre-rename ``local-*.md`` log whose
        content is about to be overwritten by the rename step; on
        success the agent's commit was silently lost, on failure (e.g.
        codex usage limit) it just wasted an invocation. The fix is
        to acquire the same ``.git/ai-loop.lock`` the hook uses for
        the entire bootstrap and dispatch explicitly at the end —
        single controlled invocation.

        This test verifies:
        - bootstrap completes (PR created, branch pushed, label).
        - the fake developer agent is called **exactly once**, not
          zero (lock leaked → explicit dispatch never fired) and not
          twice (lock not held → hook fired during bootstrap).
        - the single invocation operated on the renamed
          ``pr-NNNN.md`` log, not on the pre-rename ``local-*.md``,
          confirming the dispatch happened after the rename rather
          than via the first bootstrap hook fire.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            origin = root / "origin.git"
            repo.mkdir()
            init_repo_with_bare_origin(repo, origin)

            # Install the post-commit hook. Without this the lock
            # check below proves nothing — the test must exercise
            # the hook firing path that would have dispatched
            # without the lock.
            script = repo / "tools/ai-loop/ai_loop.py"
            run([sys.executable, str(script), "setup"], repo)

            shim = root / "gh_shim.py"
            state_dir = root / "gh_state"
            write_gh_shim(shim)

            fake_agent = root / "fake_agent.py"
            calls_path = root / "agent_calls.txt"
            sequence_path = root / "agent_sequence.txt"
            # Single dispatch terminating in awaiting_human so the
            # explicit run_agent_loop returns after one agent call
            # without needing a reviewer turn. `awaiting_human` is
            # not in TERMINAL_FINALIZE_STATUSES, so finalize is also
            # a no-op — keeps the assertion surface tight.
            sequence_path.write_text(
                "developer|1|awaiting_human|\n", encoding="utf-8"
            )
            write_fake_sequence_agent(fake_agent)

            env = self._shim_env(state_dir, shim)
            env["AI_LOOP_INVOKE_AGENTS"] = "1"
            env["AI_LOOP_CODEX_COMMAND"] = (
                f"{sys.executable} {fake_agent} developer "
                f"{calls_path} {sequence_path}"
            )

            result = run(
                [
                    sys.executable,
                    str(script),
                    "start",
                    "--branch",
                    "feature/pr-bootstrap-invoke",
                    "--prompt",
                    "Implement issue under invoke=1",
                ],
                repo,
                env=env,
            )

            output = result.stdout + result.stderr

            # Bootstrap completed.
            self.assertIn("created draft PR #1", output)
            self.assertIn("renamed to docs/ai-loop/pr-0001.md", output)
            self.assertIn("applied label 'ai-loop' to PR #1", output)

            # Hook fired during bootstrap commits but was suppressed
            # by the lock — assert the suppression message appears
            # (and the dispatch decision does NOT appear from a hook
            # fire, since the hook never reached the dispatch path
            # while the lock was held).
            self.assertIn("lock exists, skipping continuation", output)

            # The fake developer agent was dispatched exactly once
            # via the explicit run_agent_loop after bootstrap. Zero
            # would mean the explicit dispatch path didn't fire
            # (lock leaked or should_invoke missed the env var).
            # Two would mean the lock didn't suppress one of the
            # bootstrap hook fires.
            self.assertTrue(calls_path.exists())
            self.assertEqual(
                calls_path.read_text(encoding="utf-8").splitlines(),
                ["developer"],
            )

            # The one invocation must have operated on the renamed
            # pr-NNNN.md log. Verify by inspecting the committed log:
            # the fake event's agent metadata is committed against
            # the file the agent was given.
            pr_log = repo / "docs/ai-loop/pr-0001.md"
            self.assertTrue(pr_log.exists())
            parsed = ai_loop.parse_log_file(pr_log)
            self.assertEqual(parsed.latest_event["status"], "awaiting_human")
            self.assertEqual(parsed.latest_event["agent"], "codex")

            # No stray local-*.md file (the rename step ran cleanly).
            local_logs = list((repo / "docs/ai-loop").glob("local-*.md"))
            self.assertEqual(local_logs, [])


class SelectCreatePrTests(unittest.TestCase):
    """Cover the precedence rules for ``select_create_pr``.

    Default is ON because ADR-0023 names docs/ai-loop/pr-XXXX.md as the
    MVP form of the loop log. CLI > env > git config > default.
    """

    def _make_repo(self, tmp: Path, config_value: str | None) -> ai_loop.GitContext:
        repo = tmp / "repo"
        repo.mkdir()
        run(["git", "init"], repo)
        run(["git", "config", "user.name", "AI Loop Test"], repo)
        run(["git", "config", "user.email", "ai-loop-test@example.com"], repo)
        if config_value is not None:
            run(["git", "config", "ai-loop.createPr", config_value], repo)
        return ai_loop.GitContext(repo)

    def _ns(self, cli: bool | None) -> argparse.Namespace:
        return argparse.Namespace(create_pr=cli)

    def test_precedence_matrix(self) -> None:
        cases: list[tuple[bool | None, str | None, str | None, bool, str]] = [
            (None, None, None, True, "default ON when nothing set"),
            (None, "1", None, True, "env truthy"),
            (None, "0", None, False, "env falsy"),
            (None, "true", None, True, "env true variant"),
            (None, "false", None, False, "env false variant"),
            (None, "yes", None, True, "env yes variant"),
            (None, "no", None, False, "env no variant"),
            (None, "on", None, True, "env on variant"),
            (None, "off", None, False, "env off variant"),
            (None, None, "true", True, "git config truthy"),
            (None, None, "false", False, "git config falsy"),
            (None, "1", "false", True, "env on beats git config off"),
            (None, "0", "true", False, "env off beats git config on"),
            (True, "0", "false", True, "cli True beats env+config off"),
            (False, "1", "true", False, "cli False beats env+config on"),
            (None, "garbage", None, True, "unrecognized env falls through to default"),
            (
                None,
                None,
                "garbage",
                True,
                "unrecognized git config falls through to default",
            ),
        ]
        for cli, env_value, config_value, expected, description in cases:
            with self.subTest(description=description):
                with tempfile.TemporaryDirectory() as tmp_str:
                    tmp = Path(tmp_str)
                    git = self._make_repo(tmp, config_value)
                    env: dict[str, str] = {}
                    if env_value is not None:
                        env["AI_LOOP_CREATE_PR"] = env_value
                    with patch.dict(os.environ, env, clear=True):
                        self.assertEqual(
                            ai_loop.select_create_pr(git, self._ns(cli)),
                            expected,
                        )


def _telemetry_log_text(
    *,
    pr: int | None = 90,
    max_cycles: int = 3,
    started_at: str = "2026-05-27T14:00:00+00:00",
    extra_events: str = "",
    final_event: str = (
        "<!-- ai-loop-event\n"
        "agent: claude-code\n"
        "role: reviewer\n"
        "cycle: 2\n"
        "status: clean\n"
        "-->"
    ),
) -> str:
    pr_line = f"\npr: {pr}" if pr is not None else ""
    header = (
        "# AI Loop\n\n"
        "<!-- ai-loop-init\n"
        "run_id: local-20260527-140000\n"
        "repo: kathelix/catvox\n"
        "commit_at_start: deadbeefcafef00d1234567890abcdef12345678\n"
        "log_path: docs/ai-loop/pr-0090.md\n"
        f"max_cycles: {max_cycles}{pr_line}\n"
        f"started_at: {started_at}\n"
        "-->\n"
    )
    return f"{header}\n{extra_events}\n{final_event}\n"


class TelemetryDerivationTests(unittest.TestCase):
    def _parse(self, text: str) -> ai_loop.ParsedLog:
        return ai_loop.parse_log_text(text)

    def test_clean_run_counts_developer_and_reviewer_invocations(self) -> None:
        events = (
            "<!-- ai-loop-event\n"
            "agent: codex\n"
            "role: developer\n"
            "cycle: 1\n"
            "status: needs_review\n"
            "-->\n\n"
            "<!-- ai-loop-event\n"
            "agent: claude-code\n"
            "role: reviewer\n"
            "cycle: 1\n"
            "status: needs_fix\n"
            "-->\n\n"
            "<!-- ai-loop-event\n"
            "agent: codex\n"
            "role: developer\n"
            "cycle: 2\n"
            "status: needs_review\n"
            "-->"
        )
        text = _telemetry_log_text(extra_events=events, started_at="2026-05-27T14:00:00+00:00")
        parsed = self._parse(text)
        telemetry = ai_loop.derive_telemetry(
            parsed, ended_at="2026-05-27T14:23:00+00:00"
        )
        self.assertEqual(telemetry.final_status, "clean")
        self.assertEqual(telemetry.cycles_run, 2)
        self.assertEqual(telemetry.max_cycles, 3)
        self.assertEqual(telemetry.developer_invocations, 2)
        # Final event is also reviewer (the clean event) plus the
        # mid-loop needs_fix reviewer event = 2.
        self.assertEqual(telemetry.reviewer_invocations, 2)
        self.assertEqual(telemetry.clarifications, 0)
        self.assertEqual(telemetry.pr_number, 90)
        self.assertEqual(telemetry.duration_seconds, 23 * 60)
        self.assertIsNone(telemetry.failure_reason)

    def test_clarifications_counted_from_awaiting_human(self) -> None:
        events = (
            "<!-- ai-loop-event\n"
            "agent: codex\n"
            "role: developer\n"
            "cycle: 1\n"
            "status: awaiting_human\n"
            "-->\n\n"
            "<!-- ai-loop-event\n"
            "agent: human\n"
            "role: owner\n"
            "status: clarified\n"
            "next_agent: codex\n"
            "-->\n\n"
            "<!-- ai-loop-event\n"
            "agent: codex\n"
            "role: developer\n"
            "cycle: 1\n"
            "status: awaiting_human\n"
            "-->\n\n"
            "<!-- ai-loop-event\n"
            "agent: human\n"
            "role: owner\n"
            "status: clarified\n"
            "next_agent: codex\n"
            "-->"
        )
        text = _telemetry_log_text(extra_events=events)
        parsed = self._parse(text)
        telemetry = ai_loop.derive_telemetry(parsed, ended_at="2026-05-27T14:23:00+00:00")
        self.assertEqual(telemetry.clarifications, 2)

    def test_max_cycles_reached_uses_cap_in_reason(self) -> None:
        events = (
            "<!-- ai-loop-event\n"
            "agent: claude-code\n"
            "role: reviewer\n"
            "cycle: 3\n"
            "status: needs_fix\n"
            "-->"
        )
        final = (
            "<!-- ai-loop-event\n"
            "agent: controller\n"
            "role: orchestrator\n"
            "cycle: 3\n"
            "status: max_cycles_reached\n"
            "-->"
        )
        text = _telemetry_log_text(extra_events=events, final_event=final)
        parsed = self._parse(text)
        telemetry = ai_loop.derive_telemetry(parsed, ended_at="2026-05-27T14:23:00+00:00")
        self.assertEqual(telemetry.final_status, "max_cycles_reached")
        self.assertEqual(telemetry.cycles_run, 3)
        self.assertEqual(telemetry.failure_reason, "cycle cap of 3 reached")

    def test_failed_uses_event_reason_when_present(self) -> None:
        final = (
            "<!-- ai-loop-event\n"
            "agent: codex\n"
            "role: developer\n"
            "cycle: 1\n"
            "status: failed\n"
            "failure_reason: build broke\n"
            "-->"
        )
        text = _telemetry_log_text(final_event=final)
        parsed = self._parse(text)
        telemetry = ai_loop.derive_telemetry(parsed, ended_at="2026-05-27T14:05:00+00:00")
        self.assertEqual(telemetry.final_status, "failed")
        self.assertEqual(telemetry.failure_reason, "build broke")

    def test_failed_falls_back_to_generic_reason(self) -> None:
        final = (
            "<!-- ai-loop-event\n"
            "agent: codex\n"
            "role: developer\n"
            "cycle: 1\n"
            "status: failed\n"
            "-->"
        )
        text = _telemetry_log_text(final_event=final)
        parsed = self._parse(text)
        telemetry = ai_loop.derive_telemetry(parsed, ended_at="2026-05-27T14:05:00+00:00")
        self.assertEqual(telemetry.failure_reason, "agent reported failure")

    def test_zero_cycles_when_no_cycle_metadata(self) -> None:
        final = (
            "<!-- ai-loop-event\n"
            "agent: claude-code\n"
            "role: reviewer\n"
            "status: clean\n"
            "-->"
        )
        text = _telemetry_log_text(final_event=final)
        parsed = self._parse(text)
        telemetry = ai_loop.derive_telemetry(parsed, ended_at="2026-05-27T14:05:00+00:00")
        self.assertEqual(telemetry.cycles_run, 0)

    def test_missing_pr_in_init_yields_none(self) -> None:
        text = _telemetry_log_text(pr=None)
        parsed = self._parse(text)
        telemetry = ai_loop.derive_telemetry(parsed, ended_at="2026-05-27T14:05:00+00:00")
        self.assertIsNone(telemetry.pr_number)

    def test_duration_none_when_started_unparseable(self) -> None:
        text = _telemetry_log_text(started_at="not-a-date")
        parsed = self._parse(text)
        telemetry = ai_loop.derive_telemetry(parsed, ended_at="2026-05-27T14:05:00+00:00")
        self.assertIsNone(telemetry.duration_seconds)


class SummaryBlockRenderingTests(unittest.TestCase):
    def _telemetry(self, **overrides: object) -> ai_loop.Telemetry:
        defaults: dict[str, object] = {
            "final_status": "clean",
            "cycles_run": 2,
            "max_cycles": 3,
            "developer_invocations": 2,
            "reviewer_invocations": 2,
            "clarifications": 0,
            "started_at": "2026-05-27T14:00:00+00:00",
            "ended_at": "2026-05-27T14:23:00+00:00",
            "duration_seconds": 1380,
            "failure_reason": None,
            "pr_number": 90,
            "run_id": "local-20260527-140000",
            "log_path": "docs/ai-loop/pr-0090.md",
        }
        defaults.update(overrides)
        return ai_loop.Telemetry(**defaults)  # type: ignore[arg-type]

    def test_clean_summary_has_no_stopped_because_line(self) -> None:
        block = ai_loop.render_summary_block(self._telemetry())
        self.assertTrue(block.startswith(ai_loop.SUMMARY_BLOCK_START))
        self.assertTrue(block.rstrip().endswith(ai_loop.SUMMARY_BLOCK_END))
        self.assertIn("Final status: `clean`", block)
        self.assertIn("Cycles run: 2 of 3", block)
        self.assertIn("docs/ai-loop/pr-0090.md", block)
        self.assertNotIn("Stopped because", block)

    def test_failed_summary_includes_stopped_because(self) -> None:
        block = ai_loop.render_summary_block(
            self._telemetry(final_status="failed", failure_reason="build broke")
        )
        self.assertIn("Stopped because: build broke", block)

    def test_max_cycles_summary_includes_stopped_because(self) -> None:
        block = ai_loop.render_summary_block(
            self._telemetry(
                final_status="max_cycles_reached",
                failure_reason="cycle cap of 3 reached",
                cycles_run=3,
            )
        )
        self.assertIn("Stopped because: cycle cap of 3 reached", block)

    def test_duration_formats_minutes(self) -> None:
        block = ai_loop.render_summary_block(self._telemetry(duration_seconds=1380))
        self.assertIn("Duration: 23m", block)

    def test_duration_formats_hours_minutes(self) -> None:
        block = ai_loop.render_summary_block(self._telemetry(duration_seconds=3700))
        self.assertIn("Duration: 1h 1m", block)

    def test_duration_unknown_when_missing(self) -> None:
        block = ai_loop.render_summary_block(self._telemetry(duration_seconds=None))
        self.assertIn("Duration: unknown", block)


class ReplaceSummaryBlockTests(unittest.TestCase):
    BLOCK_V1 = (
        ai_loop.SUMMARY_BLOCK_START
        + "\nold content\n"
        + ai_loop.SUMMARY_BLOCK_END
    )
    BLOCK_V2 = (
        ai_loop.SUMMARY_BLOCK_START
        + "\nnew content\n"
        + ai_loop.SUMMARY_BLOCK_END
    )

    def test_replace_existing_block_keeps_surrounding_prose(self) -> None:
        body = f"# Title\n\nIntro line.\n\n{self.BLOCK_V1}\n\nTrailing prose.\n"
        result = ai_loop.replace_summary_block(body, self.BLOCK_V2)
        self.assertNotIn("old content", result)
        self.assertIn("new content", result)
        self.assertIn("# Title", result)
        self.assertIn("Trailing prose.", result)

    def test_append_when_no_existing_block(self) -> None:
        body = "# Title\n\nSome agent-written prose.\n"
        result = ai_loop.replace_summary_block(body, self.BLOCK_V2)
        self.assertIn("Some agent-written prose.", result)
        self.assertTrue(result.rstrip().endswith(ai_loop.SUMMARY_BLOCK_END))

    def test_idempotent_when_block_already_current(self) -> None:
        body = f"# Title\n\nIntro.\n\n{self.BLOCK_V2}\n"
        result = ai_loop.replace_summary_block(body, self.BLOCK_V2)
        self.assertEqual(result, body)

    def test_empty_body_yields_block_only(self) -> None:
        result = ai_loop.replace_summary_block("", self.BLOCK_V2)
        self.assertEqual(result.rstrip(), self.BLOCK_V2)

    def test_re_replacement_does_not_duplicate(self) -> None:
        body = self.BLOCK_V1
        once = ai_loop.replace_summary_block(body, self.BLOCK_V2)
        twice = ai_loop.replace_summary_block(once, self.BLOCK_V2)
        # Block must appear exactly once across re-applications.
        self.assertEqual(twice.count(ai_loop.SUMMARY_BLOCK_START), 1)
        self.assertEqual(twice.count(ai_loop.SUMMARY_BLOCK_END), 1)


class TelemetryFooterRenderingTests(unittest.TestCase):
    def _telemetry(self, **overrides: object) -> ai_loop.Telemetry:
        defaults: dict[str, object] = {
            "final_status": "clean",
            "cycles_run": 2,
            "max_cycles": 3,
            "developer_invocations": 2,
            "reviewer_invocations": 2,
            "clarifications": 0,
            "started_at": "2026-05-27T14:00:00+00:00",
            "ended_at": "2026-05-27T14:23:00+00:00",
            "duration_seconds": 1380,
            "failure_reason": None,
            "pr_number": 90,
            "run_id": "local-20260527-140000",
            "log_path": "docs/ai-loop/pr-0090.md",
        }
        defaults.update(overrides)
        return ai_loop.Telemetry(**defaults)  # type: ignore[arg-type]

    def test_footer_includes_marker_and_status(self) -> None:
        footer = ai_loop.render_telemetry_footer(self._telemetry())
        self.assertIn(ai_loop.TELEMETRY_FOOTER_MARKER, footer)
        self.assertIn("final_status: clean", footer)
        self.assertIn("cycles_run: 2", footer)
        self.assertIn("pr: 90", footer)
        self.assertIn("run_id: local-20260527-140000", footer)

    def test_footer_omits_pr_when_absent(self) -> None:
        footer = ai_loop.render_telemetry_footer(self._telemetry(pr_number=None))
        self.assertNotIn("pr:", footer)

    def test_footer_includes_failure_reason_when_present(self) -> None:
        footer = ai_loop.render_telemetry_footer(
            self._telemetry(final_status="failed", failure_reason="build broke")
        )
        self.assertIn("failure_reason: build broke", footer)

    def test_footer_parses_back_as_kv_block(self) -> None:
        footer = ai_loop.render_telemetry_footer(self._telemetry())
        match = re.search(
            r"<!--\s*ai-loop-telemetry\s*\n(.*?)\n\s*-->", footer, re.DOTALL
        )
        assert match is not None
        block = ai_loop.parse_kv_block(match.group(1))
        self.assertEqual(block["final_status"], "clean")
        self.assertEqual(block["pr"], "90")
        self.assertEqual(block["duration_seconds"], "1380")


class FinalizeTerminalLogTests(unittest.TestCase):
    def _shim_env(self, state_dir: Path, shim: Path) -> dict[str, str]:
        env = os.environ.copy()
        env["AI_LOOP_GH_COMMAND"] = f"{sys.executable} {shim}"
        env["GH_SHIM_STATE_DIR"] = str(state_dir)
        env.pop("AI_LOOP_CREATE_PR", None)
        return env

    def _setup_repo(self, root: Path) -> Path:
        """Set up a test repo with a bare `origin` so finalize can push.

        Finalize now pushes the current branch before mutating the PR
        (see PR following Codex bot finding B3 on PR #90). Tests that
        exercise the PR-mutation path therefore need a real remote;
        without it, push fails and the PR-side assertions get skipped.
        """
        repo = root / "repo"
        origin = root / "origin.git"
        repo.mkdir()
        init_repo_with_bare_origin(repo, origin)
        return repo

    def _write_pr_log(
        self,
        repo: Path,
        *,
        pr: int = 90,
        events: str,
        final_event: str,
        max_cycles: int = 3,
    ) -> Path:
        log_path = repo / f"docs/ai-loop/pr-{pr:04d}.md"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.write_text(
            _telemetry_log_text(
                pr=pr,
                max_cycles=max_cycles,
                extra_events=events,
                final_event=final_event,
            ),
            encoding="utf-8",
        )
        run(["git", "add", str(log_path.relative_to(repo))], repo)
        run(["git", "commit", "-m", "[ai-loop] Test bootstrap"], repo)
        return log_path

    def test_finalize_on_clean_writes_footer_updates_pr_and_marks_ready(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self._setup_repo(root)

            shim = root / "gh_shim.py"
            state_dir = root / "gh_state"
            write_gh_shim(shim)
            state_dir.mkdir(parents=True, exist_ok=True)
            (state_dir / "pr_body.txt").write_text(
                "Initial PR body.\n", encoding="utf-8"
            )
            env = self._shim_env(state_dir, shim)

            log_path = self._write_pr_log(
                repo,
                events=(
                    "<!-- ai-loop-event\n"
                    "agent: codex\n"
                    "role: developer\n"
                    "cycle: 1\n"
                    "status: needs_review\n"
                    "-->\n"
                ),
                final_event=(
                    "<!-- ai-loop-event\n"
                    "agent: claude-code\n"
                    "role: reviewer\n"
                    "cycle: 1\n"
                    "status: clean\n"
                    "-->"
                ),
            )

            ai_loop_module_dir = repo / "tools/ai-loop"
            # Run finalize in-process via the script entry to mimic real use.
            run(
                [
                    sys.executable,
                    str(ai_loop_module_dir / "ai_loop.py"),
                    "continue",
                    "--trigger",
                    "test",
                    "--log",
                    str(log_path),
                    "--invoke",
                ],
                repo,
                env=env,
            )

            updated_log = log_path.read_text(encoding="utf-8")
            self.assertIn(ai_loop.TELEMETRY_FOOTER_MARKER, updated_log)
            self.assertIn("final_status: clean", updated_log)

            commits = run(["git", "log", "--format=%s"], repo).stdout
            self.assertIn("[ai-loop] Controller: finalize clean", commits)

            # gh edit + ready called
            calls = read_gh_calls(state_dir)
            pr_edits = [c for c in calls if c[:2] == ["pr", "edit"]]
            self.assertEqual(len(pr_edits), 1)
            self.assertIn("--body-file", pr_edits[0])
            pr_ready = [c for c in calls if c[:2] == ["pr", "ready"]]
            self.assertEqual(len(pr_ready), 1)
            self.assertEqual(pr_ready[0][2], "90")

            # Local HEAD must match origin/<branch>. Without the push
            # step in finalize_terminal_log, the controller's finalize
            # commit (plus the agent commits that preceded it in a real
            # loop) would stay local while gh pr edit + gh pr ready
            # succeed against the PR object, leaving reviewers notified
            # on a stale branch. Codex bot finding B3 on PR #90; same
            # shape as PR #88's bootstrap-rename push fix on PR #86.
            local_head = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
            remote_head = run(
                ["git", "rev-parse", "origin/main"], repo
            ).stdout.strip()
            self.assertEqual(
                local_head,
                remote_head,
                "finalize must push branch before mutating the PR",
            )

            new_body = (state_dir / "pr_body.txt").read_text(encoding="utf-8")
            self.assertIn(ai_loop.SUMMARY_BLOCK_START, new_body)
            self.assertIn("Final status: `clean`", new_body)
            self.assertIn("Initial PR body.", new_body)

    def test_finalize_retries_pr_side_when_footer_already_present(self) -> None:
        """When the telemetry footer is already in the log, finalize
        must NOT duplicate the footer commit, but it MUST still retry
        the PR-side operations. Without this, a previous push failure
        (which committed the footer locally but skipped the PR
        updates) leaves the PR in a permanently stale state: the
        TELEMETRY_FOOTER_MARKER check used to return early and
        prevent any recovery. See Codex bot finding B5 on PR #91.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self._setup_repo(root)

            shim = root / "gh_shim.py"
            state_dir = root / "gh_state"
            write_gh_shim(shim)
            state_dir.mkdir(parents=True, exist_ok=True)
            (state_dir / "pr_body.txt").write_text(
                "Initial PR body.\n", encoding="utf-8"
            )
            env = self._shim_env(state_dir, shim)

            log_path = self._write_pr_log(
                repo,
                events=(
                    "<!-- ai-loop-event\n"
                    "agent: codex\n"
                    "role: developer\n"
                    "cycle: 1\n"
                    "status: needs_review\n"
                    "-->\n"
                ),
                final_event=(
                    "<!-- ai-loop-event\n"
                    "agent: claude-code\n"
                    "role: reviewer\n"
                    "cycle: 1\n"
                    "status: clean\n"
                    "-->"
                ),
            )

            script = repo / "tools/ai-loop/ai_loop.py"

            run(
                [
                    sys.executable,
                    str(script),
                    "continue",
                    "--trigger",
                    "test",
                    "--log",
                    str(log_path),
                    "--invoke",
                ],
                repo,
                env=env,
            )
            head_after_first = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
            calls_after_first = read_gh_calls(state_dir)
            edits_after_first = [
                c for c in calls_after_first if c[:2] == ["pr", "edit"]
            ]
            self.assertEqual(
                len(edits_after_first),
                1,
                "first finalize must call pr edit exactly once",
            )

            # Re-run with the footer already present. The footer
            # commit must be skipped, but PR-side ops must run again
            # so a previously-failed push can recover (B5).
            result = run(
                [
                    sys.executable,
                    str(script),
                    "continue",
                    "--trigger",
                    "test",
                    "--log",
                    str(log_path),
                    "--invoke",
                ],
                repo,
                env=env,
            )
            self.assertIn(
                "telemetry footer already present", result.stdout + result.stderr
            )
            head_after_second = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
            self.assertEqual(
                head_after_first,
                head_after_second,
                "second finalize must not duplicate the footer commit",
            )

            # The PR body is now current (replace_summary_block is
            # idempotent), so no NEW pr edit calls are expected. pr
            # view / pr ready may repeat on the retry; that is by
            # design and tolerated.
            calls_after_second = read_gh_calls(state_dir)
            edits_after_second = [
                c for c in calls_after_second if c[:2] == ["pr", "edit"]
            ]
            # Account for the same `pr edit` body call on first run
            # (idempotent — replace_summary_block on the second pass
            # produces an identical body so the second call is also
            # a no-op at the gh layer, even if the wrapper short-
            # circuits before invoking it).
            body_edits = [
                c
                for c in edits_after_second
                if "--body-file" in c
            ]
            self.assertEqual(
                len(body_edits),
                1,
                "pr edit --body-file must not be re-issued when body is current",
            )

    def test_finalize_on_max_cycles_keeps_pr_draft(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self._setup_repo(root)

            shim = root / "gh_shim.py"
            state_dir = root / "gh_state"
            write_gh_shim(shim)
            state_dir.mkdir(parents=True, exist_ok=True)
            (state_dir / "pr_body.txt").write_text(
                "Initial PR body.\n", encoding="utf-8"
            )
            env = self._shim_env(state_dir, shim)

            log_path = self._write_pr_log(
                repo,
                events=(
                    "<!-- ai-loop-event\n"
                    "agent: codex\n"
                    "role: developer\n"
                    "cycle: 1\n"
                    "status: needs_review\n"
                    "-->\n\n"
                    "<!-- ai-loop-event\n"
                    "agent: claude-code\n"
                    "role: reviewer\n"
                    "cycle: 1\n"
                    "status: needs_fix\n"
                    "next_agent: codex\n"
                    "-->\n"
                ),
                final_event=(
                    "<!-- ai-loop-event\n"
                    "agent: controller\n"
                    "role: orchestrator\n"
                    "cycle: 1\n"
                    "status: max_cycles_reached\n"
                    "-->"
                ),
                max_cycles=1,
            )

            script = repo / "tools/ai-loop/ai_loop.py"
            run(
                [
                    sys.executable,
                    str(script),
                    "continue",
                    "--trigger",
                    "test",
                    "--log",
                    str(log_path),
                    "--invoke",
                ],
                repo,
                env=env,
            )

            updated_body = (state_dir / "pr_body.txt").read_text(encoding="utf-8")
            self.assertIn("Final status: `max_cycles_reached`", updated_body)
            self.assertIn("Stopped because: cycle cap of 1 reached", updated_body)

            calls = read_gh_calls(state_dir)
            pr_ready = [c for c in calls if c[:2] == ["pr", "ready"]]
            self.assertEqual(
                pr_ready,
                [],
                "PR must remain draft on max_cycles_reached",
            )

    def test_finalize_on_failed_keeps_pr_draft(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self._setup_repo(root)

            shim = root / "gh_shim.py"
            state_dir = root / "gh_state"
            write_gh_shim(shim)
            state_dir.mkdir(parents=True, exist_ok=True)
            (state_dir / "pr_body.txt").write_text(
                "Initial PR body.\n", encoding="utf-8"
            )
            env = self._shim_env(state_dir, shim)

            log_path = self._write_pr_log(
                repo,
                events=(
                    "<!-- ai-loop-event\n"
                    "agent: codex\n"
                    "role: developer\n"
                    "cycle: 1\n"
                    "status: needs_review\n"
                    "-->\n"
                ),
                final_event=(
                    "<!-- ai-loop-event\n"
                    "agent: claude-code\n"
                    "role: reviewer\n"
                    "cycle: 1\n"
                    "status: failed\n"
                    "failure_reason: ran out of context\n"
                    "-->"
                ),
            )

            script = repo / "tools/ai-loop/ai_loop.py"
            run(
                [
                    sys.executable,
                    str(script),
                    "continue",
                    "--trigger",
                    "test",
                    "--log",
                    str(log_path),
                    "--invoke",
                ],
                repo,
                env=env,
            )

            updated_body = (state_dir / "pr_body.txt").read_text(encoding="utf-8")
            self.assertIn("Final status: `failed`", updated_body)
            self.assertIn("Stopped because: ran out of context", updated_body)

            calls = read_gh_calls(state_dir)
            pr_ready = [c for c in calls if c[:2] == ["pr", "ready"]]
            self.assertEqual(pr_ready, [])

    def test_finalize_without_pr_only_writes_footer(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self._setup_repo(root)

            shim = root / "gh_shim.py"
            state_dir = root / "gh_state"
            write_gh_shim(shim)
            env = self._shim_env(state_dir, shim)

            log_path = repo / "docs/ai-loop/local-20260527-140000.md"
            log_path.parent.mkdir(parents=True, exist_ok=True)
            log_path.write_text(
                _telemetry_log_text(
                    pr=None,
                    extra_events=(
                        "<!-- ai-loop-event\n"
                        "agent: codex\n"
                        "role: developer\n"
                        "cycle: 1\n"
                        "status: needs_review\n"
                        "-->\n"
                    ),
                    final_event=(
                        "<!-- ai-loop-event\n"
                        "agent: claude-code\n"
                        "role: reviewer\n"
                        "cycle: 1\n"
                        "status: clean\n"
                        "-->"
                    ),
                ),
                encoding="utf-8",
            )
            run(["git", "add", str(log_path.relative_to(repo))], repo)
            run(["git", "commit", "-m", "[ai-loop] Bootstrap"], repo)

            script = repo / "tools/ai-loop/ai_loop.py"
            run(
                [
                    sys.executable,
                    str(script),
                    "continue",
                    "--trigger",
                    "test",
                    "--log",
                    str(log_path),
                    "--invoke",
                ],
                repo,
                env=env,
            )

            updated_log = log_path.read_text(encoding="utf-8")
            self.assertIn(ai_loop.TELEMETRY_FOOTER_MARKER, updated_log)
            calls = read_gh_calls(state_dir)
            self.assertEqual(
                calls,
                [],
                "no gh calls expected when init has no PR number",
            )

    def test_finalize_tolerates_missing_gh(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self._setup_repo(root)

            env = os.environ.copy()
            env["AI_LOOP_GH_COMMAND"] = "/nonexistent/gh-binary-does-not-exist"

            log_path = self._write_pr_log(
                repo,
                events=(
                    "<!-- ai-loop-event\n"
                    "agent: codex\n"
                    "role: developer\n"
                    "cycle: 1\n"
                    "status: needs_review\n"
                    "-->\n"
                ),
                final_event=(
                    "<!-- ai-loop-event\n"
                    "agent: claude-code\n"
                    "role: reviewer\n"
                    "cycle: 1\n"
                    "status: clean\n"
                    "-->"
                ),
            )

            script = repo / "tools/ai-loop/ai_loop.py"
            result = run(
                [
                    sys.executable,
                    str(script),
                    "continue",
                    "--trigger",
                    "test",
                    "--log",
                    str(log_path),
                    "--invoke",
                ],
                repo,
                env=env,
            )
            self.assertEqual(result.returncode, 0)
            updated_log = log_path.read_text(encoding="utf-8")
            self.assertIn(ai_loop.TELEMETRY_FOOTER_MARKER, updated_log)
            self.assertIn("gh not available", result.stderr)

    def test_finalize_tolerates_gh_ready_failure(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self._setup_repo(root)

            shim = root / "gh_shim.py"
            state_dir = root / "gh_state"
            write_gh_shim(shim)
            state_dir.mkdir(parents=True, exist_ok=True)
            (state_dir / "pr_body.txt").write_text(
                "Initial PR body.\n", encoding="utf-8"
            )
            (state_dir / "ready_rc.txt").write_text("1", encoding="utf-8")
            env = self._shim_env(state_dir, shim)

            log_path = self._write_pr_log(
                repo,
                events=(
                    "<!-- ai-loop-event\n"
                    "agent: codex\n"
                    "role: developer\n"
                    "cycle: 1\n"
                    "status: needs_review\n"
                    "-->\n"
                ),
                final_event=(
                    "<!-- ai-loop-event\n"
                    "agent: claude-code\n"
                    "role: reviewer\n"
                    "cycle: 1\n"
                    "status: clean\n"
                    "-->"
                ),
            )

            script = repo / "tools/ai-loop/ai_loop.py"
            result = run(
                [
                    sys.executable,
                    str(script),
                    "continue",
                    "--trigger",
                    "test",
                    "--log",
                    str(log_path),
                    "--invoke",
                ],
                repo,
                env=env,
            )
            self.assertEqual(result.returncode, 0)
            # PR body still updated; only the ready flip failed.
            updated_body = (state_dir / "pr_body.txt").read_text(encoding="utf-8")
            self.assertIn("Final status: `clean`", updated_body)
            self.assertIn("could not mark PR #90 ready", result.stderr)

    def test_finalize_skipped_on_awaiting_human(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self._setup_repo(root)

            shim = root / "gh_shim.py"
            state_dir = root / "gh_state"
            write_gh_shim(shim)
            env = self._shim_env(state_dir, shim)

            log_path = self._write_pr_log(
                repo,
                events=(
                    "<!-- ai-loop-event\n"
                    "agent: codex\n"
                    "role: developer\n"
                    "cycle: 1\n"
                    "status: needs_review\n"
                    "-->\n"
                ),
                final_event=(
                    "<!-- ai-loop-event\n"
                    "agent: codex\n"
                    "role: developer\n"
                    "cycle: 1\n"
                    "status: awaiting_human\n"
                    "next_agent: human\n"
                    "-->"
                ),
            )
            head_before = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()

            script = repo / "tools/ai-loop/ai_loop.py"
            run(
                [
                    sys.executable,
                    str(script),
                    "continue",
                    "--trigger",
                    "test",
                    "--log",
                    str(log_path),
                    "--invoke",
                ],
                repo,
                env=env,
            )

            head_after = run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
            self.assertEqual(head_before, head_after)
            updated_log = log_path.read_text(encoding="utf-8")
            self.assertNotIn(ai_loop.TELEMETRY_FOOTER_MARKER, updated_log)

    def test_finalize_skips_pr_updates_when_push_fails(self) -> None:
        """Codex bot finding B3 on PR #90: when push fails after the
        finalize commit, the controller must NOT mutate the PR body or
        flip the draft to ready — doing so would notify reviewers on a
        stale branch. The local telemetry commit still lands so the
        run is traceable, and the user can push manually then re-run
        finalize to retry the PR-side updates.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self._setup_repo(root)

            # Break origin so the push step in finalize fails. The
            # commit itself is still made locally.
            run(
                ["git", "remote", "set-url", "origin", "/nonexistent/origin"],
                repo,
            )

            shim = root / "gh_shim.py"
            state_dir = root / "gh_state"
            write_gh_shim(shim)
            state_dir.mkdir(parents=True, exist_ok=True)
            (state_dir / "pr_body.txt").write_text(
                "Initial PR body.\n", encoding="utf-8"
            )
            env = self._shim_env(state_dir, shim)

            log_path = self._write_pr_log(
                repo,
                events=(
                    "<!-- ai-loop-event\n"
                    "agent: codex\n"
                    "role: developer\n"
                    "cycle: 1\n"
                    "status: needs_review\n"
                    "-->\n"
                ),
                final_event=(
                    "<!-- ai-loop-event\n"
                    "agent: claude-code\n"
                    "role: reviewer\n"
                    "cycle: 1\n"
                    "status: clean\n"
                    "-->"
                ),
            )

            script = repo / "tools/ai-loop/ai_loop.py"
            result = run(
                [
                    sys.executable,
                    str(script),
                    "continue",
                    "--trigger",
                    "test",
                    "--log",
                    str(log_path),
                    "--invoke",
                ],
                repo,
                env=env,
            )

            # Local finalize commit still lands so the log is intact.
            updated_log = log_path.read_text(encoding="utf-8")
            self.assertIn(ai_loop.TELEMETRY_FOOTER_MARKER, updated_log)
            commits = run(["git", "log", "--format=%s"], repo).stdout
            self.assertIn("[ai-loop] Controller: finalize clean", commits)

            # Both warning lines on stderr — the push failure and the
            # explicit short-circuit explaining what to do next.
            self.assertIn(
                "could not push branch",
                result.stderr,
            )
            self.assertIn(
                "skipping PR #90 body and ready updates",
                result.stderr,
            )

            # gh must NOT have been called for body fetch/edit/ready.
            # gh auth status from setup-time invocations is unrelated;
            # filter to the finalize-relevant subcommands.
            calls = read_gh_calls(state_dir)
            pr_calls = [c for c in calls if c[:1] == ["pr"]]
            self.assertEqual(
                pr_calls,
                [],
                "no PR-side gh calls expected when push failed",
            )

            # PR body unchanged.
            self.assertEqual(
                (state_dir / "pr_body.txt").read_text(encoding="utf-8"),
                "Initial PR body.\n",
            )

    def test_finalize_recovers_after_push_failure_on_retry(self) -> None:
        """Regression for Codex bot finding B5 on PR #91.

        When a transient push failure leaves the telemetry footer
        committed locally but the PR-side updates skipped, the user
        is expected to push the branch manually and re-run
        ``continue --invoke``. Before the B5 fix the retry hit the
        ``TELEMETRY_FOOTER_MARKER`` early-return and the PR body /
        ready transition were skipped permanently. After the fix
        the retry skips only the footer commit and still applies
        the PR-side updates.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = self._setup_repo(root)

            shim = root / "gh_shim.py"
            state_dir = root / "gh_state"
            write_gh_shim(shim)
            state_dir.mkdir(parents=True, exist_ok=True)
            (state_dir / "pr_body.txt").write_text(
                "Initial PR body.\n", encoding="utf-8"
            )
            env = self._shim_env(state_dir, shim)

            # First call: simulate push failure by pointing origin at
            # a non-existent path. The footer is committed locally,
            # PR-side ops are skipped.
            origin_url = run(
                ["git", "remote", "get-url", "origin"], repo
            ).stdout.strip()
            run(
                ["git", "remote", "set-url", "origin", "/nonexistent/origin"],
                repo,
            )

            log_path = self._write_pr_log(
                repo,
                events=(
                    "<!-- ai-loop-event\n"
                    "agent: codex\n"
                    "role: developer\n"
                    "cycle: 1\n"
                    "status: needs_review\n"
                    "-->\n"
                ),
                final_event=(
                    "<!-- ai-loop-event\n"
                    "agent: claude-code\n"
                    "role: reviewer\n"
                    "cycle: 1\n"
                    "status: clean\n"
                    "-->"
                ),
            )

            script = repo / "tools/ai-loop/ai_loop.py"
            first = run(
                [
                    sys.executable,
                    str(script),
                    "continue",
                    "--trigger",
                    "test",
                    "--log",
                    str(log_path),
                    "--invoke",
                ],
                repo,
                env=env,
            )

            # Sanity-check the precondition: footer committed, no PR
            # mutation yet.
            self.assertIn(ai_loop.TELEMETRY_FOOTER_MARKER, log_path.read_text(encoding="utf-8"))
            self.assertIn("could not push branch", first.stderr)
            self.assertEqual(
                (state_dir / "pr_body.txt").read_text(encoding="utf-8"),
                "Initial PR body.\n",
            )
            calls_after_first = read_gh_calls(state_dir)
            self.assertEqual(
                [c for c in calls_after_first if c[:1] == ["pr"]],
                [],
                "first call (push failed) must not issue PR-side gh calls",
            )

            # Simulate manual recovery: restore origin so the next
            # push succeeds.
            run(
                ["git", "remote", "set-url", "origin", origin_url],
                repo,
            )

            second = run(
                [
                    sys.executable,
                    str(script),
                    "continue",
                    "--trigger",
                    "test",
                    "--log",
                    str(log_path),
                    "--invoke",
                ],
                repo,
                env=env,
            )

            output = second.stdout + second.stderr
            # Footer was already present; second call must skip the
            # footer commit but still attempt PR-side ops.
            self.assertIn("telemetry footer already present", output)

            # Head must not advance (no second finalize commit) — count
            # the finalize lines explicitly rather than substring-match
            # on adjacent duplicates, which was a fragile check.
            finalize_subjects = [
                line
                for line in run(
                    ["git", "log", "--format=%s"], repo
                ).stdout.splitlines()
                if line == "[ai-loop] Controller: finalize clean"
            ]
            self.assertEqual(
                len(finalize_subjects),
                1,
                "second finalize must not duplicate the controller commit",
            )

            # PR body now updated with the summary block.
            updated_body = (state_dir / "pr_body.txt").read_text(encoding="utf-8")
            self.assertIn(ai_loop.SUMMARY_BLOCK_START, updated_body)
            self.assertIn("Final status: `clean`", updated_body)

            # PR ready was called (clean status).
            calls_after_second = read_gh_calls(state_dir)
            pr_ready = [c for c in calls_after_second if c[:2] == ["pr", "ready"]]
            self.assertEqual(len(pr_ready), 1)
            self.assertEqual(pr_ready[0][2], "90")


if __name__ == "__main__":
    unittest.main(verbosity=2)
