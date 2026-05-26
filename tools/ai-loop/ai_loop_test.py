#!/usr/bin/env python3
"""Tests for tools/ai-loop/ai_loop.py."""

from __future__ import annotations

import importlib.util
import os
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
            branch="feature/test",
            started_at="2026-05-24T12:00:00+02:00",
        )
        parsed = ai_loop.parse_log_text(log)
        self.assertEqual(parsed.init["run_id"], "local-20260524-120000")
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
        repo = Path("/tmp/repo")
        with patch.dict(os.environ, {"AI_LOOP_AGENT_TIMEOUT_SECONDS": "0"}):
            with self.assertRaises(ai_loop.AILoopError):
                agent_dispatcher(repo).selected_timeout_seconds()


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
            commit_message = run(["git", "log", "-1", "--format=%B"], repo)
            self.assertIn("[ai-loop] Controller: max cycles reached", commit_message.stdout)
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
            self.assertIn("ai-loop dry-run (post-commit): would dispatch developer agent: codex", start_output)

            branch = run(["git", "branch", "--show-current"], repo)
            self.assertEqual(branch.stdout.strip(), "feature/ai-loop-test")

            logs = sorted((repo / "docs/ai-loop").glob("local-*.md"))
            self.assertEqual(len(logs), 1)
            parsed = ai_loop.parse_log_file(logs[0])
            self.assertEqual(parsed.latest_event["status"], "needs_developer")

            commit_message = run(["git", "log", "-1", "--format=%B"], repo)
            self.assertIn("[ai-loop] Human: start", commit_message.stdout)

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

    def test_hook_dry_run_uses_real_git_dir_in_linked_worktree(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            linked = root / "linked"
            repo.mkdir()

            run(["git", "init"], repo)
            run(["git", "config", "user.name", "AI Loop Test"], repo)
            run(["git", "config", "user.email", "ai-loop-test@example.com"], repo)

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
            self.assertIn("ai-loop dry-run (post-commit): would dispatch developer agent: codex", start_output)
            self.assertNotIn("lock exists, skipping", start_output)

            git_dir = run(["git", "rev-parse", "--git-dir"], linked).stdout.strip()
            self.assertNotEqual(git_dir, ".git")
            self.assertTrue(git_dir)


if __name__ == "__main__":
    unittest.main(verbosity=2)
