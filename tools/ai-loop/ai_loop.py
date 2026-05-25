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
from urllib.parse import urlparse


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

ROLE_FOR_AGENT = {agent: role for role, agent in AGENT_FOR_ROLE.items()}

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

COMMAND_ENV_FOR_AGENT = {
    "codex": "AI_LOOP_CODEX_COMMAND",
    "claude-code": "AI_LOOP_CLAUDE_COMMAND",
}

AGENT_PROFILES = ("real", "smoke")
DEFAULT_AGENT_PROFILE = "real"
AGENT_PROFILE_ENV = "AI_LOOP_AGENT_PROFILE"

PROFILE_COMMAND_ENV_FOR_AGENT = {
    ("codex", "real"): "AI_LOOP_CODEX_REAL_COMMAND",
    ("codex", "smoke"): "AI_LOOP_CODEX_SMOKE_COMMAND",
    ("claude-code", "real"): "AI_LOOP_CLAUDE_REAL_COMMAND",
    ("claude-code", "smoke"): "AI_LOOP_CLAUDE_SMOKE_COMMAND",
}

PROFILE_MODEL_ENV_FOR_AGENT = {
    ("codex", "real"): "AI_LOOP_CODEX_REAL_MODEL",
    ("codex", "smoke"): "AI_LOOP_CODEX_SMOKE_MODEL",
    ("claude-code", "real"): "AI_LOOP_CLAUDE_REAL_MODEL",
    ("claude-code", "smoke"): "AI_LOOP_CLAUDE_SMOKE_MODEL",
}

PROFILE_EFFORT_ENV_FOR_AGENT = {
    ("codex", "real"): "AI_LOOP_CODEX_REAL_EFFORT",
    ("codex", "smoke"): "AI_LOOP_CODEX_SMOKE_EFFORT",
    ("claude-code", "real"): "AI_LOOP_CLAUDE_REAL_EFFORT",
    ("claude-code", "smoke"): "AI_LOOP_CLAUDE_SMOKE_EFFORT",
}

DEFAULT_PROFILE_MODEL_FOR_AGENT = {
    ("codex", "real"): "",
    ("codex", "smoke"): "",
    ("claude-code", "real"): "opus",
    ("claude-code", "smoke"): "haiku",
}

DEFAULT_PROFILE_EFFORT_FOR_AGENT = {
    ("codex", "real"): "xhigh",
    ("codex", "smoke"): "low",
    ("claude-code", "real"): "max",
    ("claude-code", "smoke"): "low",
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
DEFAULT_MAX_CYCLES = 3


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
    profile: str
    command: list[str]
    prompt: str


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


@dataclass(frozen=True)
class GitContext:
    repo: Path

    def run(
        self,
        args: Sequence[str],
        *,
        check: bool = True,
        capture_output: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", "-C", str(self.repo), *args],
            check=check,
            text=True,
            capture_output=capture_output,
        )

    def ensure_clean_worktree(self) -> None:
        status = self.run(["status", "--porcelain"]).stdout.strip()
        if status:
            raise AILoopError(
                "working tree must be clean before committing an AI loop event"
            )

    def ensure_dispatch_safe_worktree(self) -> None:
        status = self.run(["status", "--porcelain"]).stdout.strip()
        if status:
            raise AILoopError(
                "working tree must be clean before dispatching an agent; "
                "commit, stash, or remove local changes first"
            )

    def current_branch(self) -> str:
        return self.run(["branch", "--show-current"]).stdout.strip()

    def repo_name(self) -> str:
        remote = self.run(
            ["remote", "get-url", "origin"],
            check=False,
        ).stdout.strip()
        if not remote:
            return self.repo.name
        if remote.endswith(".git"):
            remote = remote[:-4]

        parsed = urlparse(remote)
        if parsed.scheme and parsed.path:
            path = parsed.path.lstrip("/")
            return path or remote

        if "://" not in remote and ":" in remote and "/" in remote:
            return remote.split(":", 1)[1]
        return remote

    def output(self, args: Sequence[str]) -> str:
        result = self.run(args, check=False)
        if result.returncode != 0:
            stderr = result.stderr.strip()
            return f"[command failed: git {' '.join(args)}]\n{stderr}".rstrip()
        return result.stdout.rstrip()

    def required_output(self, args: Sequence[str]) -> str:
        return self.run(args).stdout.strip()

    def resolve_diff_base(self) -> str | None:
        for ref in ("origin/main", "main", "origin/master", "master"):
            result = self.run(["rev-parse", "--verify", "--quiet", ref], check=False)
            if result.returncode == 0:
                return ref
        result = self.run(["rev-list", "--max-parents=0", "HEAD"], check=False)
        root_commit = result.stdout.strip().splitlines()
        return root_commit[0] if root_commit else None

    def branch_context(self) -> str:
        base = self.resolve_diff_base()
        if not base:
            return "No Git base ref could be resolved for branch context."

        base_sha = self.output(["rev-parse", base]).strip() or base
        merge_base = self.output(["merge-base", "HEAD", base]).strip() or base_sha
        head_sha = self.required_output(["rev-parse", "HEAD"])
        diff_range = f"{merge_base}..{head_sha}"
        name_status = self.output(["diff", "--name-status", diff_range])
        stat = self.output(["diff", "--stat", diff_range])
        if not name_status:
            name_status = "(no committed file changes)"
        if not stat:
            stat = "(no committed diff stat)"
        return f"""Resolved base ref: {base}
Resolved base ref SHA: {base_sha}
Resolved merge-base SHA: {merge_base}
Dispatch HEAD SHA: {head_sha}
Diff range: {diff_range}

Changed files (`git diff --name-status {diff_range}`):
{name_status}

Diff stat (`git diff --stat {diff_range}`):
{stat}

Suggested local inspection commands:
- git status --short --branch
- git diff --stat {diff_range}
- git diff --name-status {diff_range}
- git diff {diff_range}
- git diff {diff_range} -- <path>

Stale-state guard: before editing or reviewing, run `git rev-parse HEAD`. If
it differs from the Dispatch HEAD SHA above, stop and report stale state instead
of editing or reviewing."""

    def latest_ai_loop_log_from_head(self) -> Path:
        result = self.run(["show", "--name-only", "--format=", "HEAD"])
        paths = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        ai_loop_paths = [path for path in paths if AI_LOOP_LOG_RE.match(path)]
        if not ai_loop_paths:
            raise AILoopError("latest commit did not change an AI loop log")
        return self.repo / ai_loop_paths[-1]


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


def initial_prompt_from_log(log_text: str) -> str:
    match = INITIAL_PROMPT_RE.search(log_text)
    if not match:
        return "(initial prompt section not found; read the full AI loop log)"
    body = match.group("body").strip()
    return body or "(initial prompt is empty)"


def render_event_metadata(event: dict[str, str]) -> str:
    return "\n".join(f"{key}: {value}" for key, value in event.items())


def repo_relative_path(repo: Path, path: Path) -> str:
    try:
        return path.resolve().relative_to(repo.resolve()).as_posix()
    except ValueError as exc:
        raise AILoopError(f"path is outside repository: {path}") from exc


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


def max_cycles_for_log(parsed: ParsedLog) -> int:
    raw_value = (parsed.init or {}).get("max_cycles", "").strip()
    if not raw_value:
        return DEFAULT_MAX_CYCLES
    try:
        max_cycles = int(raw_value)
    except ValueError as exc:
        raise AILoopError(f"invalid max_cycles value: {raw_value!r}") from exc
    if max_cycles < 1:
        raise AILoopError(f"max_cycles must be at least 1; found {max_cycles}")
    return max_cycles


def cycle_for_event(event: dict[str, str]) -> int:
    raw_value = event.get("cycle", "0").strip() or "0"
    try:
        cycle = int(raw_value)
    except ValueError as exc:
        raise AILoopError(f"invalid cycle value: {raw_value!r}") from exc
    if cycle < 0:
        raise AILoopError(f"cycle must be non-negative; found {cycle}")
    return cycle


def should_stop_for_cycle_cap(
    parsed: ParsedLog,
    event: dict[str, str],
    route: Route | None,
) -> bool:
    if not route or route.role != "developer":
        return False
    if event.get("status") != "needs_fix":
        return False
    return cycle_for_event(event) >= max_cycles_for_log(parsed)


def routing_decision_for_log(
    router: "StateRouter",
    parsed: ParsedLog,
    event: dict[str, str],
) -> str:
    route = router.route_for_event(event)
    if should_stop_for_cycle_cap(parsed, event, route):
        return "stop: cycle cap reached"
    return router.routing_decision(event)


@dataclass(frozen=True)
class StateRouter:
    def route_for_event(self, event: dict[str, str]) -> Route | None:
        status = event.get("status", "")
        if status in STATUS_TO_ROUTE:
            role = STATUS_TO_ROUTE[status]
            agent = event.get("next_agent") or AGENT_FOR_ROLE[role]
            return Route(role=role, agent=agent)
        if status == "clarified":
            agent = event.get("next_agent", "")
            role = ROLE_FOR_AGENT.get(agent)
            if role:
                return Route(role=role, agent=agent)
        return None

    def routing_decision(self, event: dict[str, str]) -> str:
        route = self.route_for_event(event)
        if route:
            return f"would dispatch {route.role} agent: {route.agent}"
        status = event.get("status", "")
        if status == "clarified":
            return "stop: clarified event is missing a supported next_agent"
        if status in STATUS_TO_STOP_REASON:
            return f"stop: {STATUS_TO_STOP_REASON[status]}"
        return f"stop: unknown status {status!r}"


@dataclass(frozen=True)
class PromptComposer:
    git: GitContext

    def require_file_exists(self, rel_path: str) -> None:
        path = self.git.repo / rel_path
        if not path.is_file():
            raise AILoopError(f"required prompt context file is missing: {rel_path}")

    def render_instruction_manifest(self, prompt_files: Sequence[str]) -> str:
        lines = [
            "Read these repository instruction files from disk, in order, before acting.",
            "They are listed here instead of inlined so local agent calls stay lean.",
        ]
        for index, rel_path in enumerate(prompt_files, start=1):
            self.require_file_exists(rel_path)
            lines.append(f'{index}. <file path="{rel_path}" required="true" />')
        return "\n".join(lines)

    def compose_agent_prompt(
        self,
        *,
        log_path: Path,
        role: str,
        agent: str,
    ) -> str:
        rel_log_path = log_path.resolve().relative_to(self.git.repo.resolve())
        prompt_files = PROMPT_FILES_FOR_ROLE.get(role)
        if not prompt_files:
            raise AILoopError(f"unsupported agent role: {role}")

        instruction_manifest = self.render_instruction_manifest(prompt_files)
        status = self.git.output(["status", "--short", "--branch"])
        branch = self.git.current_branch()
        head = self.git.required_output(["rev-parse", "HEAD"])

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

Repository: {self.git.repo_name()}
Branch: {branch}
HEAD: {head}
AI loop log: {rel_log_path}

## Git Status (`git status --short --branch`)

{status or "(clean)"}

## AI Loop Log

{loop_context(log_path)}

## Branch Context

{self.git.branch_context()}
</task_context>
"""


@dataclass(frozen=True)
class AgentDispatcher:
    git: GitContext

    @staticmethod
    def normalize_profile(raw_profile: str) -> str:
        profile = raw_profile.strip().lower()
        if profile not in AGENT_PROFILES:
            allowed = ", ".join(AGENT_PROFILES)
            raise AILoopError(
                f"unsupported AI loop agent profile {raw_profile!r}; "
                f"expected one of: {allowed}"
            )
        return profile

    def selected_profile(self, args: argparse.Namespace) -> str:
        arg_profile = getattr(args, "agent_profile", "") or ""
        if arg_profile:
            return self.normalize_profile(arg_profile)

        env_profile = os.environ.get(AGENT_PROFILE_ENV, "")
        if env_profile:
            return self.normalize_profile(env_profile)

        config_profile = self.git.run(
            ["config", "--get", "ai-loop.agentProfile"],
            check=False,
        ).stdout.strip()
        if config_profile:
            return self.normalize_profile(config_profile)

        return DEFAULT_AGENT_PROFILE

    @staticmethod
    def env_or_default(env_name: str | None, default: str) -> str:
        if not env_name:
            return default
        return os.environ.get(env_name, default).strip()

    def command_parts_from_template(self, template: str) -> list[str]:
        return [part.format(repo=str(self.git.repo)) for part in shlex.split(template)]

    def default_command_for_agent_profile(self, agent: str, profile: str) -> list[str]:
        model = self.env_or_default(
            PROFILE_MODEL_ENV_FOR_AGENT.get((agent, profile)),
            DEFAULT_PROFILE_MODEL_FOR_AGENT.get((agent, profile), ""),
        )
        effort = self.env_or_default(
            PROFILE_EFFORT_ENV_FOR_AGENT.get((agent, profile)),
            DEFAULT_PROFILE_EFFORT_FOR_AGENT.get((agent, profile), ""),
        )

        if agent == "codex":
            command = ["codex", "exec", "--cd", "{repo}"]
            if model:
                command.extend(["--model", model])
            if effort:
                command.extend(["-c", f'model_reasoning_effort="{effort}"'])
            command.append("-")
        elif agent == "claude-code":
            command = ["claude", "--print", "--input-format", "text"]
            if model:
                command.extend(["--model", model])
            if effort:
                command.extend(["--effort", effort])
        else:
            raise AILoopError(f"unsupported agent command target: {agent}")

        return [part.format(repo=str(self.git.repo)) for part in command]

    def command_for_agent(self, agent: str, profile: str) -> list[str]:
        profile_env_var = PROFILE_COMMAND_ENV_FOR_AGENT.get((agent, profile))
        profile_override = (
            os.environ.get(profile_env_var, "") if profile_env_var else ""
        )
        if profile_override:
            return self.command_parts_from_template(profile_override)

        env_var = COMMAND_ENV_FOR_AGENT.get(agent)
        override = os.environ.get(env_var, "") if env_var else ""
        if override:
            return self.command_parts_from_template(override)

        return self.default_command_for_agent_profile(agent, profile)

    def build_invocation(
        self,
        log_path: Path,
        route: Route,
        profile: str,
    ) -> AgentInvocation:
        return AgentInvocation(
            role=route.role,
            agent=route.agent,
            profile=profile,
            command=self.command_for_agent(route.agent, profile),
            prompt=PromptComposer(self.git).compose_agent_prompt(
                log_path=log_path,
                role=route.role,
                agent=route.agent,
            ),
        )

    def should_invoke(self, args: argparse.Namespace) -> bool:
        if getattr(args, "dry_run", False):
            return False
        if getattr(args, "invoke", False):
            return True
        env_value = os.environ.get("AI_LOOP_INVOKE_AGENTS", "").strip().lower()
        if env_value in TRUTHY:
            return True
        config_value = self.git.run(
            ["config", "--get", "ai-loop.invokeAgents"],
            check=False,
        ).stdout.strip().lower()
        return config_value in TRUTHY

    def run_invocation(self, invocation: AgentInvocation) -> int:
        print(
            "ai-loop invoke: "
            f"dispatching {invocation.role} agent {invocation.agent} "
            f"with {invocation.profile} profile: "
            f"{shlex.join(invocation.command)}",
            flush=True,
        )
        try:
            completed = subprocess.run(
                invocation.command,
                cwd=self.git.repo,
                input=invocation.prompt,
                text=True,
                check=False,
            )
        except FileNotFoundError as exc:
            raise AILoopError(
                f"{invocation.agent} command not found: {invocation.command[0]}"
            ) from exc
        return completed.returncode


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


def render_human_answer_event(
    *,
    answer: str,
    questions: str,
    cycle: str,
    next_agent: str,
    answered_at: str,
) -> str:
    display_time = display_now_local()
    question_label = questions or "clarification"
    metadata = {
        "agent": "human",
        "role": "owner",
        "status": "clarified",
        "next_agent": next_agent,
        "answered_at": answered_at,
    }
    if cycle:
        metadata["cycle"] = cycle
    if questions:
        metadata["questions"] = questions

    return f"""
## {display_time} - Human - Answer {question_label}

Answer:
{answer}

Result:
- status: clarified
- next_agent: {next_agent}

<!-- ai-loop-event
{render_event_metadata(metadata)}
-->
"""


def render_max_cycles_reached_event(
    *,
    cycle: str,
    max_cycles: int,
    stopped_at: str,
) -> str:
    display_time = display_now_local()
    metadata = {
        "agent": "controller",
        "role": "orchestrator",
        "cycle": cycle,
        "status": "max_cycles_reached",
        "stopped_at": stopped_at,
    }
    return f"""
## {display_time} - Controller - Max Cycles Reached

The controller stopped before dispatching another developer turn because cycle
{cycle} reached the configured limit of {max_cycles}.

Result:
- status: max_cycles_reached
- cycle: {cycle}

<!-- ai-loop-event
{render_event_metadata(metadata)}
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
    git = GitContext(repo)
    hooks_path = repo / "tools/ai-loop/hooks"
    post_commit = hooks_path / "post-commit"
    if post_commit.exists():
        mode = post_commit.stat().st_mode
        post_commit.chmod(mode | 0o111)

    git.run(["config", "core.hooksPath", "tools/ai-loop/hooks"], capture_output=True)
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
    git = GitContext(repo)
    branch = args.branch or os.environ.get("AI_LOOP_BRANCH", "")
    prompt = args.prompt or os.environ.get("AI_LOOP_PROMPT", "")
    if not branch:
        raise AILoopError("AI_LOOP_BRANCH or --branch is required")
    if not prompt:
        raise AILoopError("AI_LOOP_PROMPT or --prompt is required")

    git.ensure_clean_worktree()

    existing_branches = git.run(["branch", "--list", branch]).stdout.strip()
    if existing_branches:
        git.run(["switch", branch], capture_output=False)
    else:
        git.run(["switch", "-c", branch], capture_output=False)

    git.ensure_clean_worktree()

    run_id = make_run_id()
    rel_log_path = f"docs/ai-loop/{run_id}.md"
    log_path = repo / rel_log_path
    if log_path.exists():
        raise AILoopError(f"AI loop log already exists: {rel_log_path}")
    log_path.parent.mkdir(parents=True, exist_ok=True)
    started_at = iso_now_local()
    log_path.write_text(
        render_bootstrap_log(
            run_id=run_id,
            log_path=rel_log_path,
            prompt=prompt,
            repo=git.repo_name(),
            branch=git.current_branch(),
            started_at=started_at,
        ),
        encoding="utf-8",
    )

    git.run(["add", rel_log_path], capture_output=True)
    git.run(
        ["commit", "-m", f"[ai-loop] Human: start {run_id}"],
        capture_output=False,
    )
    print(f"created {rel_log_path}")
    print(f"ai-loop run id: {run_id}")
    return 0


def command_answer(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve() if args.repo else repo_root_from_cwd()
    git = GitContext(repo)
    answer = args.answer or os.environ.get("AI_LOOP_ANSWER", "")
    if not answer:
        raise AILoopError("AI_LOOP_ANSWER or --answer is required")

    git.ensure_clean_worktree()
    log_path = (
        Path(args.log).resolve() if args.log else git.latest_ai_loop_log_from_head()
    )
    rel_log_path = repo_relative_path(repo, log_path)
    if not AI_LOOP_LOG_RE.match(rel_log_path):
        raise AILoopError(f"not an AI loop log path: {rel_log_path}")

    parsed = parse_log_file(log_path)
    latest = parsed.latest_event
    if not latest:
        raise AILoopError(f"no ai-loop-event blocks found in {log_path}")
    if latest.get("status") != "awaiting_human":
        status = latest.get("status", "")
        raise AILoopError(
            "latest AI loop event must have status awaiting_human before "
            f"answering; found {status!r}"
        )

    next_agent = (
        args.next_agent
        or os.environ.get("AI_LOOP_NEXT_AGENT", "")
        or latest.get("resume_agent", "")
        or latest.get("agent", "")
    )
    if next_agent == "human":
        next_agent = ""
    if next_agent not in ROLE_FOR_AGENT:
        supported = ", ".join(sorted(ROLE_FOR_AGENT))
        raise AILoopError(
            "unable to determine which agent should resume after the answer; "
            f"use --next-agent with one of: {supported}"
        )

    questions = args.questions or latest.get("questions", "")
    event = render_human_answer_event(
        answer=answer,
        questions=questions,
        cycle=latest.get("cycle", ""),
        next_agent=next_agent,
        answered_at=iso_now_local(),
    )
    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(event)

    git.run(["add", rel_log_path], capture_output=True)
    commit_subject = f"[ai-loop] Human: answer {questions or 'clarification'}"
    git.run(["commit", "-m", commit_subject], capture_output=False)
    print(f"appended human answer to {rel_log_path}")
    return 0


def command_continue(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve() if args.repo else repo_root_from_cwd()
    git = GitContext(repo)
    router = StateRouter()
    dispatcher = AgentDispatcher(git)
    log_path = (
        Path(args.log).resolve() if args.log else git.latest_ai_loop_log_from_head()
    )
    parsed = parse_log_file(log_path)
    latest = parsed.latest_event
    if not latest:
        raise AILoopError(f"no ai-loop-event blocks found in {log_path}")

    route = router.route_for_event(latest)
    if not route:
        print(f"ai-loop ({args.trigger}): {router.routing_decision(latest)}")
        return 0

    if not dispatcher.should_invoke(args):
        print(
            f"ai-loop dry-run ({args.trigger}): "
            f"{routing_decision_for_log(router, parsed, latest)}"
        )
        return 0

    git.ensure_dispatch_safe_worktree()
    profile = dispatcher.selected_profile(args)
    run_agent_loop(
        git=git,
        router=router,
        dispatcher=dispatcher,
        log_path=log_path,
        profile=profile,
        trigger=args.trigger,
    )
    return 0


def invoke_route(
    dispatcher: AgentDispatcher,
    log_path: Path,
    route: Route,
    profile: str,
) -> None:
    invocation = dispatcher.build_invocation(log_path, route, profile)
    return_code = dispatcher.run_invocation(invocation)
    if return_code != 0:
        raise AILoopError(
            f"{invocation.agent} exited with status {return_code}; loop stopped"
        )


def run_agent_loop(
    *,
    git: GitContext,
    router: StateRouter,
    dispatcher: AgentDispatcher,
    log_path: Path,
    profile: str,
    trigger: str,
) -> None:
    has_dispatched = False
    while True:
        parsed = parse_log_file(log_path)
        latest = parsed.latest_event
        if not latest:
            raise AILoopError(f"no ai-loop-event blocks found in {log_path}")

        route = router.route_for_event(latest)
        decision = routing_decision_for_log(router, parsed, latest)
        if not route:
            print_stop_decision(trigger, decision, has_dispatched)
            return

        if should_stop_for_cycle_cap(parsed, latest, route):
            print_stop_decision(trigger, decision, has_dispatched)
            append_max_cycles_reached_event(
                git=git,
                log_path=log_path,
                latest=latest,
                max_cycles=max_cycles_for_log(parsed),
            )
            return

        if has_dispatched:
            print(
                f"ai-loop handoff: dispatching {route.role} agent: {route.agent}",
                flush=True,
            )

        previous_head = git.required_output(["rev-parse", "HEAD"])
        invoke_route(dispatcher, log_path, route, profile)
        current_head = git.required_output(["rev-parse", "HEAD"])
        if current_head == previous_head:
            raise AILoopError(
                f"{route.role} agent exited without committing an AI loop event; "
                "loop stopped"
            )

        git.ensure_dispatch_safe_worktree()
        log_path = git.latest_ai_loop_log_from_head()
        has_dispatched = True


def print_stop_decision(trigger: str, decision: str, has_dispatched: bool) -> None:
    if has_dispatched:
        print(f"ai-loop handoff: {decision}", flush=True)
    else:
        print(f"ai-loop ({trigger}): {decision}", flush=True)


def append_max_cycles_reached_event(
    *,
    git: GitContext,
    log_path: Path,
    latest: dict[str, str],
    max_cycles: int,
) -> None:
    git.ensure_dispatch_safe_worktree()
    rel_log_path = repo_relative_path(git.repo, log_path)
    event = render_max_cycles_reached_event(
        cycle=str(cycle_for_event(latest)),
        max_cycles=max_cycles,
        stopped_at=iso_now_local(),
    )
    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(event)

    git.run(["add", rel_log_path], capture_output=True)
    git.run(
        ["commit", "-m", "[ai-loop] Controller: max cycles reached"],
        capture_output=False,
    )


def command_compose_prompt(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve() if args.repo else repo_root_from_cwd()
    if not args.log:
        raise AILoopError("--log is required when composing a prompt")
    git = GitContext(repo)
    log_path = Path(args.log).resolve()
    agent = args.agent or AGENT_FOR_ROLE[args.role]
    prompt = PromptComposer(git).compose_agent_prompt(
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

    answer = subparsers.add_parser(
        "answer",
        help="append a human clarification answer and resume the local loop",
    )
    answer.add_argument("--log", help="AI loop log path; defaults to latest log in HEAD")
    answer.add_argument("--answer", help="human answer text")
    answer.add_argument(
        "--questions",
        help="question ids being answered; defaults to latest event questions",
    )
    answer.add_argument(
        "--next-agent",
        choices=sorted(ROLE_FOR_AGENT),
        help="agent to resume; defaults to the agent that asked for clarification",
    )
    answer.set_defaults(func=command_answer)

    cont = subparsers.add_parser("continue", help="continue the local AI loop")
    cont.add_argument("--trigger", default="manual", help="wake-up source")
    cont.add_argument("--log", help="AI loop log path; defaults to latest log in HEAD")
    cont.add_argument("--invoke", action="store_true", help="invoke the routed agent")
    cont.add_argument(
        "--agent-profile",
        choices=AGENT_PROFILES,
        help=f"agent command profile; defaults to {AGENT_PROFILE_ENV} or real",
    )
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
