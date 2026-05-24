#!/usr/bin/env python3
"""Tests for tools/ai-loop/ai_loop.py."""

from __future__ import annotations

import importlib.util
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


sys.dont_write_bytecode = True

REPO_ROOT = Path(__file__).resolve().parents[2]
TOOL_DIR = REPO_ROOT / "tools/ai-loop"
AI_LOOP_PATH = TOOL_DIR / "ai_loop.py"

spec = importlib.util.spec_from_file_location("ai_loop", AI_LOOP_PATH)
assert spec and spec.loader
ai_loop = importlib.util.module_from_spec(spec)
sys.modules["ai_loop"] = ai_loop
spec.loader.exec_module(ai_loop)


def run(cmd: list[str], cwd: Path, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=cwd, check=check, text=True, capture_output=True)


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


if __name__ == "__main__":
    unittest.main(verbosity=2)
