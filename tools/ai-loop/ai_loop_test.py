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
        for status, expected in cases.items():
            with self.subTest(status=status):
                event = {"status": status}
                if status == "needs_review":
                    event["next_agent"] = "claude-code"
                if status in {"needs_developer", "needs_fix"}:
                    event["next_agent"] = "codex"
                self.assertEqual(ai_loop.routing_decision(event), expected)

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

            prompt = ai_loop.compose_agent_prompt(
                repo=repo,
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

            prompt = ai_loop.compose_agent_prompt(
                repo=repo,
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

            prompt = ai_loop.compose_agent_prompt(
                repo=repo,
                log_path=log_path,
                role="reviewer",
                agent="claude-code",
            )

            base = ai_loop.resolve_diff_base(repo)
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
    def test_codex_real_and_smoke_profiles_set_reasoning_effort(self) -> None:
        repo = Path("/tmp/repo")
        with patch.dict(os.environ, {}, clear=True):
            real = ai_loop.command_for_agent(repo, "codex", "real")
            smoke = ai_loop.command_for_agent(repo, "codex", "smoke")

        self.assertEqual(
            real,
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
            smoke,
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

    def test_claude_profiles_set_model_and_effort(self) -> None:
        repo = Path("/tmp/repo")
        with patch.dict(os.environ, {}, clear=True):
            real = ai_loop.command_for_agent(repo, "claude-code", "real")
            smoke = ai_loop.command_for_agent(repo, "claude-code", "smoke")

        self.assertEqual(
            real,
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
            smoke,
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
            command = ai_loop.command_for_agent(repo, "claude-code", "smoke")

        self.assertEqual(command, ["profile-claude", "/tmp/repo"])

    def test_agent_profile_can_come_from_env(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            init_repo_with_ai_loop_tooling(repo)
            args = type("Args", (), {"agent_profile": ""})()
            with patch.dict(os.environ, {"AI_LOOP_AGENT_PROFILE": "smoke"}):
                profile = ai_loop.selected_agent_profile(repo, args)
        self.assertEqual(profile, "smoke")


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
                "import pathlib, sys\n"
                "pathlib.Path(sys.argv[1]).write_text(sys.stdin.read(), encoding='utf-8')\n",
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
