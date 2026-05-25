#!/usr/bin/env python3
"""Local AI loop controller for CatVox."""

from __future__ import annotations

import argparse
import os
import re
import shlex
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

PROMPT_FILES_FOR_ROLE = {
    "developer": [
        "AGENTS.md",
        ".codex/AGENTS.md",
        "tools/ai-loop/prompts/common.md",
        "tools/ai-loop/prompts/developer.md",
    ],
    "reviewer": [
        "AGENTS.md",
        "CLAUDE.md",
        "tools/ai-loop/prompts/common.md",
        "tools/ai-loop/prompts/reviewer.md",
    ],
}

DEFAULT_COMMAND_FOR_AGENT = {
    "codex": ["codex", "exec", "--cd", "{repo}", "-"],
    "claude-code": ["claude", "--print", "--input-format", "text"],
}

COMMAND_ENV_FOR_AGENT = {
    "codex": "AI_LOOP_CODEX_COMMAND",
    "claude-code": "AI_LOOP_CLAUDE_COMMAND",
}

EVENT_BLOCK_RE = re.compile(r"<!--\s*ai-loop-event\s*\n(.*?)\n\s*-->", re.DOTALL)
INIT_BLOCK_RE = re.compile(r"<!--\s*ai-loop-init\s*\n(.*?)\n\s*-->", re.DOTALL)
KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*$")
AI_LOOP_LOG_RE = re.compile(r"^docs/ai-loop/(?:local-\d{8}-\d{6}|pr-\d{4})\.md$")
INITIAL_PROMPT_RE = re.compile(
    r"## Initial user prompt\s*\n(?P<body>.*?)(?=\n## |\Z)",
    re.DOTALL,
)
TRUTHY = {"1", "true", "yes", "on"}


class AILoopError(RuntimeError):
    """User-facing ai-loop failure."""


@dataclass(frozen=True)
class ParsedLog:
    init: dict[str, str] | None
    events: list[dict[str, str]]

    @property
    def latest_event(self) -> dict[str, str] | None:
        return self.events[-1] if self.events else None


@dataclass(frozen=True)
class Route:
    role: str
    agent: str


@dataclass(frozen=True)
class AgentInvocation:
    role: str
    agent: str
    command: list[str]
    prompt: str


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


def ensure_dispatch_safe_worktree(repo: Path) -> None:
    status = run_git(repo, ["status", "--porcelain"]).stdout.strip()
    if status:
        raise AILoopError(
            "working tree must be clean before dispatching an agent; "
            "commit, stash, or remove local changes first"
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


def route_for_event(event: dict[str, str]) -> Route | None:
    status = event.get("status", "")
    if status in STATUS_TO_ROUTE:
        role = STATUS_TO_ROUTE[status]
        agent = event.get("next_agent") or AGENT_FOR_ROLE[role]
        return Route(role=role, agent=agent)
    return None


def routing_decision(event: dict[str, str]) -> str:
    route = route_for_event(event)
    if route:
        return f"would dispatch {route.role} agent: {route.agent}"
    status = event.get("status", "")
    if status in STATUS_TO_STOP_REASON:
        return f"stop: {STATUS_TO_STOP_REASON[status]}"
    return f"stop: unknown status {status!r}"


def require_file_exists(repo: Path, rel_path: str) -> None:
    path = repo / rel_path
    if not path.is_file():
        raise AILoopError(f"required prompt context file is missing: {rel_path}")


def render_instruction_manifest(repo: Path, prompt_files: Sequence[str]) -> str:
    lines = [
        "Read these repository instruction files from disk, in order, before acting.",
        "They are listed here instead of inlined so local agent calls stay lean.",
    ]
    for index, rel_path in enumerate(prompt_files, start=1):
        require_file_exists(repo, rel_path)
        lines.append(f'{index}. <file path="{rel_path}" required="true" />')
    return "\n".join(lines)


def resolve_diff_base(repo: Path) -> str | None:
    for ref in ("origin/main", "main", "origin/master", "master"):
        result = run_git(repo, ["rev-parse", "--verify", "--quiet", ref], check=False)
        if result.returncode == 0:
            return ref
    result = run_git(repo, ["rev-list", "--max-parents=0", "HEAD"], check=False)
    root_commit = result.stdout.strip().splitlines()
    return root_commit[0] if root_commit else None


def git_output(repo: Path, args: Sequence[str]) -> str:
    result = run_git(repo, args, check=False)
    if result.returncode != 0:
        stderr = result.stderr.strip()
        return f"[command failed: git {' '.join(args)}]\n{stderr}".rstrip()
    return result.stdout.rstrip()


def git_required_output(repo: Path, args: Sequence[str]) -> str:
    return run_git(repo, args).stdout.strip()


def branch_context(repo: Path) -> str:
    base = resolve_diff_base(repo)
    if not base:
        return "No Git base ref could be resolved for branch context."

    base_sha = git_output(repo, ["rev-parse", base]).strip() or base
    merge_base = git_output(repo, ["merge-base", "HEAD", base]).strip() or base_sha
    head_sha = git_required_output(repo, ["rev-parse", "HEAD"])
    diff_range = f"{merge_base}..{head_sha}"
    name_status = git_output(repo, ["diff", "--name-status", diff_range])
    stat = git_output(repo, ["diff", "--stat", diff_range])
    if not name_status:
        name_status = "(no committed file changes)"
    if not stat:
        stat = "(no committed diff stat)"
    return f"""Base ref: {base}
Base ref SHA: {base_sha}
Merge base SHA: {merge_base}
Head SHA: {head_sha}
Diff range: {diff_range}

Changed files:
{name_status}

Diff stat:
{stat}

Suggested local inspection commands:
- git diff --stat {diff_range}
- git diff --name-status {diff_range}
- git diff {diff_range}
- git diff {diff_range} -- <path>

Stale-state guard: if current HEAD differs from {head_sha} before acting, stop
and report stale state instead of editing or reviewing."""


def initial_prompt_from_log(log_text: str) -> str:
    match = INITIAL_PROMPT_RE.search(log_text)
    if not match:
        return "(initial prompt section not found; read the full AI loop log)"
    body = match.group("body").strip()
    return body or "(initial prompt is empty)"


def render_event_metadata(event: dict[str, str]) -> str:
    return "\n".join(f"{key}: {value}" for key, value in event.items())


def loop_context(log_path: Path) -> str:
    log_text = log_path.read_text(encoding="utf-8")
    parsed = parse_log_text(log_text)
    latest = parsed.latest_event
    latest_metadata = (
        render_event_metadata(latest)
        if latest
        else "(no ai-loop-event blocks found; read the full AI loop log)"
    )
    return f"""AI loop log path: {log_path}

Initial user prompt:
{initial_prompt_from_log(log_text)}

Latest event metadata:
{latest_metadata}

Read the full AI loop log from disk before appending to it or when prior
conversation details are needed."""


def compose_agent_prompt(
    *,
    repo: Path,
    log_path: Path,
    role: str,
    agent: str,
) -> str:
    rel_log_path = log_path.resolve().relative_to(repo.resolve())
    prompt_files = PROMPT_FILES_FOR_ROLE.get(role)
    if not prompt_files:
        raise AILoopError(f"unsupported agent role: {role}")

    instruction_manifest = render_instruction_manifest(repo, prompt_files)
    status = git_output(repo, ["status", "--short", "--branch"])
    branch = current_branch(repo)
    head = git_required_output(repo, ["rev-parse", "HEAD"])

    return f"""# CatVox Local AI Loop Invocation

You are the {role} agent for the CatVox local AI loop.
Agent id: {agent}

The repository and agent-specific instruction file manifest below is
authoritative. Read those files before using any task context.

<instruction_files>
{instruction_manifest}
</instruction_files>

<task_context>
## Current Repository State

Repository: {repo_name(repo)}
Branch: {branch}
HEAD: {head}
AI loop log: {rel_log_path}

## Git Status

{status or "(clean)"}

## AI Loop Log

{loop_context(log_path)}

## Branch Context

{branch_context(repo)}
</task_context>
"""


def command_for_agent(repo: Path, agent: str) -> list[str]:
    env_var = COMMAND_ENV_FOR_AGENT.get(agent)
    override = os.environ.get(env_var, "") if env_var else ""
    if override:
        return [part.format(repo=str(repo)) for part in shlex.split(override)]

    template = DEFAULT_COMMAND_FOR_AGENT.get(agent)
    if not template:
        raise AILoopError(f"unsupported agent command target: {agent}")
    return [part.format(repo=str(repo)) for part in template]


def build_agent_invocation(repo: Path, log_path: Path, route: Route) -> AgentInvocation:
    return AgentInvocation(
        role=route.role,
        agent=route.agent,
        command=command_for_agent(repo, route.agent),
        prompt=compose_agent_prompt(
            repo=repo,
            log_path=log_path,
            role=route.role,
            agent=route.agent,
        ),
    )


def should_invoke_agents(repo: Path, args: argparse.Namespace) -> bool:
    if getattr(args, "dry_run", False):
        return False
    if getattr(args, "invoke", False):
        return True
    env_value = os.environ.get("AI_LOOP_INVOKE_AGENTS", "").strip().lower()
    if env_value in TRUTHY:
        return True
    config_value = run_git(
        repo,
        ["config", "--get", "ai-loop.invokeAgents"],
        check=False,
    ).stdout.strip().lower()
    return config_value in TRUTHY


def run_agent_invocation(repo: Path, invocation: AgentInvocation) -> int:
    print(
        "ai-loop invoke: "
        f"dispatching {invocation.role} agent {invocation.agent}: "
        f"{shlex.join(invocation.command)}",
        flush=True,
    )
    try:
        completed = subprocess.run(
            invocation.command,
            cwd=repo,
            input=invocation.prompt,
            text=True,
            check=False,
        )
    except FileNotFoundError as exc:
        raise AILoopError(
            f"{invocation.agent} command not found: {invocation.command[0]}"
        ) from exc
    return completed.returncode


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

Started the local AI loop. Default mode uses dry-run routing; no agent is
invoked unless local agent invocation is enabled explicitly.

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

    route = route_for_event(latest)
    if not route:
        print(f"ai-loop ({args.trigger}): {routing_decision(latest)}")
        return 0

    if not should_invoke_agents(repo, args):
        print(f"ai-loop dry-run ({args.trigger}): {routing_decision(latest)}")
        return 0

    ensure_dispatch_safe_worktree(repo)
    invocation = build_agent_invocation(repo, log_path, route)
    return_code = run_agent_invocation(repo, invocation)
    if return_code != 0:
        raise AILoopError(
            f"{invocation.agent} exited with status {return_code}; loop stopped"
        )
    return 0


def command_compose_prompt(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve() if args.repo else repo_root_from_cwd()
    if not args.log:
        raise AILoopError("--log is required when composing a prompt")
    log_path = Path(args.log).resolve()
    agent = args.agent or AGENT_FOR_ROLE[args.role]
    prompt = compose_agent_prompt(
        repo=repo,
        log_path=log_path,
        role=args.role,
        agent=agent,
    )
    if args.output:
        output = Path(args.output)
        output.write_text(prompt, encoding="utf-8")
        print(f"wrote {output}")
    else:
        print(prompt)
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
    cont.add_argument("--invoke", action="store_true", help="invoke the routed agent")
    cont.add_argument(
        "--dry-run",
        action="store_true",
        help="print the routing decision even if invocation is enabled",
    )
    cont.set_defaults(func=command_continue)

    compose = subparsers.add_parser(
        "compose-prompt",
        help="render the prompt that would be sent to a local agent",
    )
    compose.add_argument("--role", choices=sorted(PROMPT_FILES_FOR_ROLE), required=True)
    compose.add_argument("--agent", help="agent id; defaults to the role default")
    compose.add_argument("--log", required=True, help="AI loop log path")
    compose.add_argument("--output", help="write prompt to this path instead of stdout")
    compose.set_defaults(func=command_compose_prompt)
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
