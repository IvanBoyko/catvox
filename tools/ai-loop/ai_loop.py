#!/usr/bin/env python3
"""Local AI loop controller for CatVox.

Slice 1 intentionally stops at setup, bootstrap log creation, event parsing, and
dry-run routing. It does not invoke Codex, Claude, or any other agent.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Sequence


STATUS_TO_ROUTE = {
    "needs_developer": "developer",
    "needs_fix": "developer",
    "needs_review": "reviewer",
}

STATUS_TO_STOP_REASON = {
    "clean": "review is clean",
    "awaiting_human": "awaiting human clarification",
    "failed": "loop is failed",
    "max_cycles_reached": "cycle cap reached",
    "paused": "loop is paused",
}

AGENT_FOR_ROLE = {
    "developer": "codex",
    "reviewer": "claude-code",
}

EVENT_BLOCK_RE = re.compile(r"<!--\s*ai-loop-event\s*\n(.*?)\n\s*-->", re.DOTALL)
INIT_BLOCK_RE = re.compile(r"<!--\s*ai-loop-init\s*\n(.*?)\n\s*-->", re.DOTALL)
KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*$")
AI_LOOP_LOG_RE = re.compile(r"^docs/ai-loop/(?:local-\d{8}-\d{6}|pr-\d{4})\.md$")


class AILoopError(RuntimeError):
    """User-facing ai-loop failure."""


@dataclass(frozen=True)
class ParsedLog:
    init: dict[str, str] | None
    events: list[dict[str, str]]

    @property
    def latest_event(self) -> dict[str, str] | None:
        return self.events[-1] if self.events else None


def run_git(
    repo: Path,
    args: Sequence[str],
    *,
    check: bool = True,
    capture_output: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=check,
        text=True,
        capture_output=capture_output,
    )


def repo_root_from_cwd() -> Path:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            check=True,
            text=True,
            capture_output=True,
        )
    except subprocess.CalledProcessError as exc:
        raise AILoopError("ai-loop must be run inside a Git repository") from exc
    return Path(result.stdout.strip()).resolve()


def ensure_clean_worktree(repo: Path) -> None:
    status = run_git(repo, ["status", "--porcelain"]).stdout.strip()
    if status:
        raise AILoopError(
            "working tree must be clean before ai-loop-start creates the bootstrap commit"
        )


def current_branch(repo: Path) -> str:
    return run_git(repo, ["branch", "--show-current"]).stdout.strip()


def repo_name(repo: Path) -> str:
    remote = run_git(repo, ["remote", "get-url", "origin"], check=False).stdout.strip()
    if not remote:
        return repo.name
    if remote.endswith(".git"):
        remote = remote[:-4]
    if ":" in remote and "/" in remote:
        return remote.split(":", 1)[1]
    if "github.com/" in remote:
        return remote.split("github.com/", 1)[1]
    return remote


def parse_kv_block(block: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in block.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            raise ValueError(f"invalid metadata line: {raw_line!r}")
        key, value = line.split(":", 1)
        key = key.strip()
        if not KEY_RE.match(key):
            raise ValueError(f"invalid metadata key: {key!r}")
        if key in values:
            raise ValueError(f"duplicate metadata key: {key!r}")
        values[key] = value.strip()
    return values


def parse_log_text(text: str) -> ParsedLog:
    init_match = INIT_BLOCK_RE.search(text)
    init = parse_kv_block(init_match.group(1)) if init_match else None
    events = [parse_kv_block(match.group(1)) for match in EVENT_BLOCK_RE.finditer(text)]
    return ParsedLog(init=init, events=events)


def parse_log_file(path: Path) -> ParsedLog:
    return parse_log_text(path.read_text(encoding="utf-8"))


def routing_decision(event: dict[str, str]) -> str:
    status = event.get("status", "")
    if status in STATUS_TO_ROUTE:
        role = STATUS_TO_ROUTE[status]
        agent = event.get("next_agent") or AGENT_FOR_ROLE[role]
        return f"would dispatch {role} agent: {agent}"
    if status in STATUS_TO_STOP_REASON:
        return f"stop: {STATUS_TO_STOP_REASON[status]}"
    return f"stop: unknown status {status!r}"


def latest_ai_loop_log_from_head(repo: Path) -> Path:
    result = run_git(repo, ["show", "--name-only", "--format=", "HEAD"])
    paths = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    ai_loop_paths = [path for path in paths if AI_LOOP_LOG_RE.match(path)]
    if not ai_loop_paths:
        raise AILoopError("latest commit did not change an AI loop log")
    return repo / ai_loop_paths[-1]


def iso_now_local() -> str:
    return datetime.now().astimezone().replace(microsecond=0).isoformat()


def display_now_local() -> str:
    return datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z")


def make_run_id() -> str:
    return datetime.now().strftime("local-%Y%m%d-%H%M%S")


def render_bootstrap_log(
    *,
    run_id: str,
    log_path: str,
    prompt: str,
    repo: str,
    branch: str,
    started_at: str,
) -> str:
    display_time = display_now_local()
    return f"""# AI Loop - {run_id}

## Initial user prompt

{prompt}

## Configuration

- Repository: {repo}
- Branch at start: {branch}
- Log path: {log_path}
- Max cycles: 3
- Developer agent: Codex
- Reviewer agent: Claude Code
- Started at: {started_at}

<!-- ai-loop-init
run_id: {run_id}
repo: {repo}
branch_at_start: {branch}
log_path: {log_path}
max_cycles: 3
developer_agent: codex
reviewer_agent: claude-code
started_at: {started_at}
-->

## {display_time} - Human - Start local AI loop

Started the local AI loop. Slice 1 stops at dry-run routing; no agent is
invoked yet.

Result:
- status: needs_developer
- cycle: 0
- next_agent: codex

<!-- ai-loop-event
agent: human
role: owner
cycle: 0
status: needs_developer
next_agent: codex
-->
"""


def verify_tool(name: str, *, required: bool) -> str:
    path = shutil.which(name)
    if path:
        return f"ok: {name} -> {path}"
    prefix = "missing" if required else "warn: missing"
    return f"{prefix}: {name}"


def command_setup(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve() if args.repo else repo_root_from_cwd()
    hooks_path = repo / "tools/ai-loop/hooks"
    post_commit = hooks_path / "post-commit"
    if post_commit.exists():
        mode = post_commit.stat().st_mode
        post_commit.chmod(mode | 0o111)

    run_git(repo, ["config", "core.hooksPath", "tools/ai-loop/hooks"], capture_output=True)
    print("configured core.hooksPath=tools/ai-loop/hooks")
    for message in [
        verify_tool("git", required=True),
        verify_tool("python3", required=True),
        verify_tool("codex", required=False),
        verify_tool("claude", required=False),
        verify_tool("gh", required=False),
    ]:
        print(message)
    return 0


def command_start(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve() if args.repo else repo_root_from_cwd()
    branch = args.branch or os.environ.get("AI_LOOP_BRANCH", "")
    prompt = args.prompt or os.environ.get("AI_LOOP_PROMPT", "")
    if not branch:
        raise AILoopError("AI_LOOP_BRANCH or --branch is required")
    if not prompt:
        raise AILoopError("AI_LOOP_PROMPT or --prompt is required")

    ensure_clean_worktree(repo)

    existing_branches = run_git(repo, ["branch", "--list", branch]).stdout.strip()
    if existing_branches:
        run_git(repo, ["switch", branch], capture_output=False)
    else:
        run_git(repo, ["switch", "-c", branch], capture_output=False)

    ensure_clean_worktree(repo)

    run_id = make_run_id()
    rel_log_path = f"docs/ai-loop/{run_id}.md"
    log_path = repo / rel_log_path
    if log_path.exists():
        raise AILoopError(f"AI loop log already exists: {rel_log_path}")
    log_path.parent.mkdir(parents=True, exist_ok=True)
    started_at = iso_now_local()
    active_branch = current_branch(repo)
    log_path.write_text(
        render_bootstrap_log(
            run_id=run_id,
            log_path=rel_log_path,
            prompt=prompt,
            repo=repo_name(repo),
            branch=active_branch,
            started_at=started_at,
        ),
        encoding="utf-8",
    )

    run_git(repo, ["add", rel_log_path], capture_output=True)
    run_git(
        repo,
        ["commit", "-m", f"[ai-loop] Human: start {run_id}"],
        capture_output=False,
    )
    print(f"created {rel_log_path}")
    print(f"ai-loop run id: {run_id}")
    return 0


def command_continue(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve() if args.repo else repo_root_from_cwd()
    log_path = Path(args.log).resolve() if args.log else latest_ai_loop_log_from_head(repo)
    parsed = parse_log_file(log_path)
    latest = parsed.latest_event
    if not latest:
        raise AILoopError(f"no ai-loop-event blocks found in {log_path}")
    print(f"ai-loop dry-run ({args.trigger}): {routing_decision(latest)}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="CatVox local AI loop controller")
    parser.add_argument("--repo", help="Git repository root; defaults to current repository")
    subparsers = parser.add_subparsers(dest="command", required=True)

    setup = subparsers.add_parser("setup", help="configure local AI loop hooks")
    setup.set_defaults(func=command_setup)

    start = subparsers.add_parser("start", help="start a local AI loop run")
    start.add_argument("--branch", help="feature branch to create or switch to")
    start.add_argument("--prompt", help="initial human prompt for the local loop")
    start.set_defaults(func=command_start)

    cont = subparsers.add_parser("continue", help="continue the local AI loop")
    cont.add_argument("--trigger", default="manual", help="wake-up source")
    cont.add_argument("--log", help="AI loop log path; defaults to latest log in HEAD")
    cont.set_defaults(func=command_continue)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except AILoopError as exc:
        print(f"ai-loop: {exc}", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr.strip() if exc.stderr else str(exc)
        print(f"ai-loop command failed: {stderr}", file=sys.stderr)
        return exc.returncode or 1
    except ValueError as exc:
        print(f"ai-loop metadata error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
