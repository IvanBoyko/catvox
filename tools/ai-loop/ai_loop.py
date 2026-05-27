#!/usr/bin/env python3
"""Local AI loop controller for CatVox."""

from __future__ import annotations

import argparse
import math
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
FALSY = {"0", "false", "no", "off"}
DEFAULT_MAX_CYCLES = 3
DEFAULT_AGENT_TIMEOUT_SECONDS = 1800.0
AGENT_TIMEOUT_ENV = "AI_LOOP_AGENT_TIMEOUT_SECONDS"
GH_COMMAND_ENV = "AI_LOOP_GH_COMMAND"
CREATE_PR_ENV = "AI_LOOP_CREATE_PR"
DEFAULT_GH_COMMAND = "gh"
AI_LOOP_LABEL = "ai-loop"
AI_LOOP_LABEL_COLOR = "BFD4F2"
AI_LOOP_LABEL_DESCRIPTION = (
    "Pull requests created by the local AI loop bootstrap."
)
AI_LOOP_BASE_REF = "origin/main"
GH_PR_URL_RE = re.compile(r"/pull/(\d+)\b")

TERMINAL_FINALIZE_STATUSES = {"clean", "max_cycles_reached", "failed"}
SUMMARY_BLOCK_START = "<!-- ai-loop:summary-start -->"
SUMMARY_BLOCK_END = "<!-- ai-loop:summary-end -->"
SUMMARY_BLOCK_RE = re.compile(
    rf"{re.escape(SUMMARY_BLOCK_START)}.*?{re.escape(SUMMARY_BLOCK_END)}",
    re.DOTALL,
)
TELEMETRY_FOOTER_MARKER = "<!-- ai-loop-telemetry"


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
    timeout_seconds: float


@dataclass(frozen=True)
class Telemetry:
    final_status: str
    cycles_run: int
    max_cycles: int
    developer_invocations: int
    reviewer_invocations: int
    clarifications: int
    started_at: str
    ended_at: str
    duration_seconds: int | None
    failure_reason: str | None
    pr_number: int | None
    run_id: str
    log_path: str


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

    def has_origin_remote(self) -> bool:
        result = self.run(["remote", "get-url", "origin"], check=False)
        return result.returncode == 0 and bool(result.stdout.strip())

    def fetch(self, remote: str, ref: str) -> None:
        self.run(["fetch", remote, ref], capture_output=False)

    def is_ancestor(self, ref: str, target: str = "HEAD") -> bool:
        result = self.run(
            ["merge-base", "--is-ancestor", ref, target],
            check=False,
        )
        return result.returncode == 0

    def push_branch(self, branch: str, *, set_upstream: bool = True) -> None:
        args = ["push"]
        if set_upstream:
            args.append("-u")
        args.extend(["origin", branch])
        self.run(args, capture_output=False)


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
    """Return the cycle number from a cap-relevant event.

    The cycle field is required on any event the cycle cap consults
    (currently reviewer ``needs_fix`` events). Treating a missing
    ``cycle:`` as zero would silently bypass the cap, so this helper
    raises ``AILoopError`` rather than defaulting.
    """
    raw_value = event.get("cycle", "").strip()
    if not raw_value:
        status = event.get("status", "")
        raise AILoopError(
            f"event with status {status!r} is missing required cycle metadata"
        )
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

    @staticmethod
    def normalize_timeout_seconds(raw_timeout: str) -> float:
        try:
            timeout_seconds = float(raw_timeout)
        except ValueError as exc:
            raise AILoopError(
                f"unsupported AI loop agent timeout {raw_timeout!r}; "
                "expected a positive, finite number of seconds"
            ) from exc
        # subprocess.run rejects non-finite timeouts at runtime with
        # OverflowError / undefined behavior on NaN, so reject inf / -inf /
        # NaN here and wrap the failure as AILoopError instead.
        if not math.isfinite(timeout_seconds) or timeout_seconds <= 0:
            raise AILoopError(
                f"unsupported AI loop agent timeout {raw_timeout!r}; "
                "expected a positive, finite number of seconds"
            )
        return timeout_seconds

    def selected_timeout_seconds(self) -> float:
        env_timeout = os.environ.get(AGENT_TIMEOUT_ENV, "").strip()
        if env_timeout:
            return self.normalize_timeout_seconds(env_timeout)

        config_timeout = self.git.run(
            ["config", "--get", "ai-loop.agentTimeoutSeconds"],
            check=False,
        ).stdout.strip()
        if config_timeout:
            return self.normalize_timeout_seconds(config_timeout)

        return DEFAULT_AGENT_TIMEOUT_SECONDS

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
            timeout_seconds=self.selected_timeout_seconds(),
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
            f"{shlex.join(invocation.command)} "
            f"(timeout: {invocation.timeout_seconds:g}s)",
            flush=True,
        )
        try:
            completed = subprocess.run(
                invocation.command,
                cwd=self.git.repo,
                input=invocation.prompt,
                text=True,
                check=False,
                timeout=invocation.timeout_seconds,
            )
        except FileNotFoundError as exc:
            raise AILoopError(
                f"{invocation.agent} command not found: {invocation.command[0]}"
            ) from exc
        except subprocess.TimeoutExpired as exc:
            raise AILoopError(
                f"{invocation.agent} exceeded timeout of "
                f"{invocation.timeout_seconds:g}s; loop stopped"
            ) from exc
        return completed.returncode


@dataclass(frozen=True)
class GhClient:
    git: GitContext

    @staticmethod
    def base_command() -> list[str]:
        override = os.environ.get(GH_COMMAND_ENV, "").strip()
        if override:
            return shlex.split(override)
        return [DEFAULT_GH_COMMAND]

    def run(
        self,
        args: Sequence[str],
        *,
        check: bool = True,
        capture_output: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [*self.base_command(), *args],
            cwd=self.git.repo,
            check=check,
            text=True,
            capture_output=capture_output,
        )

    def ensure_available(self) -> None:
        binary = self.base_command()[0]
        if shutil.which(binary) is None:
            raise AILoopError(
                f"{binary!r} CLI not found on PATH; install GitHub CLI "
                f"(https://cli.github.com) or set {GH_COMMAND_ENV}"
            )

    def ensure_authenticated(self) -> None:
        result = self.run(["auth", "status"], check=False)
        if result.returncode != 0:
            stderr = (result.stderr or result.stdout or "").strip()
            detail = f": {stderr}" if stderr else ""
            raise AILoopError(
                f"gh is not authenticated{detail}; run `gh auth login`"
            )

    def existing_open_pr_for_branch(self, branch: str) -> int | None:
        result = self.run(
            [
                "pr",
                "list",
                "--head",
                branch,
                "--state",
                "open",
                "--json",
                "number",
                "--jq",
                ".[].number",
            ],
        )
        numbers = [
            line.strip() for line in result.stdout.splitlines() if line.strip()
        ]
        if not numbers:
            return None
        try:
            return int(numbers[0])
        except ValueError as exc:
            raise AILoopError(
                f"could not parse PR number from gh pr list output: "
                f"{numbers[0]!r}"
            ) from exc

    def create_draft_pr(
        self,
        *,
        title: str,
        body: str,
        base: str,
        head: str,
    ) -> int:
        result = self.run(
            [
                "pr",
                "create",
                "--draft",
                "--title",
                title,
                "--body",
                body,
                "--base",
                base,
                "--head",
                head,
            ],
        )
        match = GH_PR_URL_RE.search(result.stdout)
        if not match:
            stdout = result.stdout.strip()
            raise AILoopError(
                f"could not parse PR number from gh pr create output: "
                f"{stdout!r}"
            )
        return int(match.group(1))

    def label_exists(self, name: str) -> bool:
        result = self.run(
            [
                "label",
                "list",
                "--search",
                name,
                "--json",
                "name",
                "--jq",
                ".[].name",
            ],
        )
        names = {
            line.strip() for line in result.stdout.splitlines() if line.strip()
        }
        return name in names

    def ensure_label(
        self,
        name: str,
        *,
        color: str,
        description: str,
    ) -> None:
        if self.label_exists(name):
            return
        self.run(
            [
                "label",
                "create",
                name,
                "--color",
                color,
                "--description",
                description,
            ],
        )

    def add_label_to_pr(self, pr_number: int, label: str) -> None:
        self.run(["pr", "edit", str(pr_number), "--add-label", label])

    def _binary_available(self) -> bool:
        return shutil.which(self.base_command()[0]) is not None

    def fetch_pr_body(self, pr_number: int) -> str | None:
        """Return the PR body, or ``None`` if ``gh`` is unavailable / fails.

        Fail-tolerant: never raises. The end-of-loop summary path uses this
        to read the current body before computing the next one.
        """
        if not self._binary_available():
            print(
                f"ai-loop: gh not available; skipping PR #{pr_number} body fetch",
                file=sys.stderr,
                flush=True,
            )
            return None
        result = self.run(
            [
                "pr",
                "view",
                str(pr_number),
                "--json",
                "body",
                "--jq",
                ".body",
            ],
            check=False,
        )
        if result.returncode != 0:
            stderr = (result.stderr or "").strip() or "gh pr view failed"
            print(
                f"ai-loop: could not fetch PR #{pr_number} body: {stderr}",
                file=sys.stderr,
                flush=True,
            )
            return None
        return result.stdout

    def edit_pr_body(self, pr_number: int, body: str) -> bool:
        """Set the PR body via ``gh pr edit --body-file``.

        Fail-tolerant: returns ``False`` on any failure (missing binary,
        non-zero exit) and logs a warning. Uses a temporary file rather
        than ``--body`` so the body can contain arbitrary markdown without
        shell escaping.
        """
        if not self._binary_available():
            print(
                f"ai-loop: gh not available; skipping PR #{pr_number} body edit",
                file=sys.stderr,
                flush=True,
            )
            return False
        import tempfile as _tempfile

        with _tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            suffix=".md",
            delete=False,
        ) as handle:
            handle.write(body)
            body_path = handle.name
        try:
            result = self.run(
                ["pr", "edit", str(pr_number), "--body-file", body_path],
                check=False,
            )
        finally:
            try:
                os.unlink(body_path)
            except OSError as exc:
                print(
                    f"ai-loop: could not remove temp PR body file {body_path}: {exc}",
                    file=sys.stderr,
                    flush=True,
                )
        if result.returncode != 0:
            stderr = (result.stderr or "").strip() or "gh pr edit failed"
            print(
                f"ai-loop: could not update PR #{pr_number} body: {stderr}",
                file=sys.stderr,
                flush=True,
            )
            return False
        return True

    def mark_pr_ready(self, pr_number: int) -> bool:
        """Flip a draft PR to ready-for-review.

        Fail-tolerant: returns ``False`` on any failure and logs a warning.
        """
        if not self._binary_available():
            print(
                f"ai-loop: gh not available; skipping PR #{pr_number} "
                "ready-for-review flip",
                file=sys.stderr,
                flush=True,
            )
            return False
        result = self.run(["pr", "ready", str(pr_number)], check=False)
        if result.returncode != 0:
            stderr = (result.stderr or "").strip() or "gh pr ready failed"
            print(
                f"ai-loop: could not mark PR #{pr_number} ready: {stderr}",
                file=sys.stderr,
                flush=True,
            )
            return False
        return True


def _resolve_git_dir(git: GitContext) -> Path:
    git_dir_value = git.required_output(["rev-parse", "--git-dir"]).strip()
    git_dir = Path(git_dir_value)
    if not git_dir.is_absolute():
        git_dir = git.repo / git_dir
    return git_dir


def _acquire_ai_loop_lock(git: GitContext) -> Path:
    """Acquire the ai-loop lock shared with the post-commit hook.

    Used by ``command_start`` to bracket the bootstrap so the
    post-commit hook fires during the bootstrap commits all hit the
    same lock and exit early without dispatching the agent. Without
    this, the first bootstrap commit dispatches against the
    pre-rename ``local-*.md`` log (whose contents are about to be
    overwritten by the rename step) and the second dispatches a
    redundant second invocation — both wasteful, and the first
    actively loses the agent's commit on success.
    """
    lock_dir = _resolve_git_dir(git) / "ai-loop.lock"
    try:
        lock_dir.mkdir(exist_ok=False)
    except FileExistsError as exc:
        raise AILoopError(
            f"ai-loop.lock already exists at {lock_dir}; another loop run "
            "is in progress, or a previous run failed to release the lock. "
            "Confirm no other ai-loop process is running and remove the "
            "lock directory manually before retrying."
        ) from exc
    return lock_dir


def _release_ai_loop_lock(lock_dir: Path) -> None:
    try:
        lock_dir.rmdir()
    except OSError:
        pass


def select_create_pr(git: GitContext, args: argparse.Namespace) -> bool:
    """Decide whether `start` should bootstrap a draft PR.

    Default is ON because ADR-0023 names `docs/ai-loop/pr-XXXX.md` as the
    MVP shape of the loop log. The opt-out path is for offline iteration
    and dry-run validation. Precedence (highest first):

    1. CLI flag (``--create-pr`` / ``--no-create-pr``)
    2. Environment variable (``AI_LOOP_CREATE_PR``)
    3. Git config (``ai-loop.createPr``)
    4. Default: True
    """
    cli_value = getattr(args, "create_pr", None)
    if cli_value is not None:
        return bool(cli_value)
    env_value = os.environ.get(CREATE_PR_ENV, "").strip().lower()
    if env_value in TRUTHY:
        return True
    if env_value in FALSY:
        return False
    config_value = (
        git.run(["config", "--get", "ai-loop.createPr"], check=False)
        .stdout.strip()
        .lower()
    )
    if config_value in TRUTHY:
        return True
    if config_value in FALSY:
        return False
    return True


def iso_now_local() -> str:
    return datetime.now().astimezone().replace(microsecond=0).isoformat()


def display_now_local() -> str:
    return datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z")


def make_run_id() -> str:
    return datetime.now().strftime("local-%Y%m%d-%H%M%S")


def pr_log_relpath(pr_number: int) -> str:
    return f"docs/ai-loop/pr-{pr_number:04d}.md"


def render_bootstrap_log(
    *,
    run_id: str,
    log_path: str,
    prompt: str,
    repo: str,
    branch: str,
    started_at: str,
    display_time: str | None = None,
    pr: int | None = None,
) -> str:
    display_time = display_time or display_now_local()
    title = f"PR #{pr:04d}" if pr is not None else run_id
    pr_config_line = f"\n- PR: #{pr:04d}" if pr is not None else ""
    pr_init_line = f"\npr: {pr}" if pr is not None else ""
    return f"""# AI Loop - {title}

## Initial user prompt

{prompt}

## Configuration

- Repository: {repo}
- Branch at start: {branch}
- Log path: {log_path}{pr_config_line}
- Max cycles: 3
- Developer agent: Codex
- Reviewer agent: Claude Code
- Started at: {started_at}

<!-- ai-loop-init
run_id: {run_id}
repo: {repo}
branch_at_start: {branch}
log_path: {log_path}{pr_init_line}
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


def _parse_iso_datetime(value: str) -> datetime | None:
    value = (value or "").strip()
    if not value:
        return None
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def _safe_int(value: str | None) -> int | None:
    if value is None:
        return None
    raw = value.strip()
    if not raw:
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def _format_duration(seconds: int | None) -> str:
    if seconds is None:
        return "unknown"
    if seconds < 60:
        return f"{seconds}s"
    minutes, remainder = divmod(seconds, 60)
    if minutes < 60:
        return f"{minutes}m {remainder}s" if remainder else f"{minutes}m"
    hours, minutes = divmod(minutes, 60)
    if minutes:
        return f"{hours}h {minutes}m"
    return f"{hours}h"


def derive_telemetry(parsed: ParsedLog, *, ended_at: str) -> Telemetry:
    """Summarize a parsed AI loop log into a Telemetry record.

    Pure function — depends only on the parsed log shape and the caller's
    end timestamp. The latest event must carry one of the terminal statuses
    in ``TERMINAL_FINALIZE_STATUSES``; the controller is responsible for
    guarding that contract before calling.
    """
    init = parsed.init or {}
    latest = parsed.latest_event or {}

    cycles_seen = [
        cycle
        for event in parsed.events
        if (cycle := _safe_int(event.get("cycle"))) is not None
    ]
    cycles_run = max(cycles_seen) if cycles_seen else 0

    developer_invocations = sum(
        1 for event in parsed.events if event.get("role") == "developer"
    )
    reviewer_invocations = sum(
        1 for event in parsed.events if event.get("role") == "reviewer"
    )
    clarifications = sum(
        1 for event in parsed.events if event.get("status") == "awaiting_human"
    )

    started_at = init.get("started_at", "")
    started_dt = _parse_iso_datetime(started_at)
    ended_dt = _parse_iso_datetime(ended_at)
    if started_dt and ended_dt:
        delta = int((ended_dt - started_dt).total_seconds())
        duration_seconds: int | None = max(delta, 0)
    else:
        duration_seconds = None

    final_status = latest.get("status", "")
    max_cycles = _safe_int(init.get("max_cycles")) or DEFAULT_MAX_CYCLES

    failure_reason: str | None = None
    if final_status == "failed":
        failure_reason = (
            latest.get("failure_reason")
            or latest.get("reason")
            or "agent reported failure"
        ).strip() or "agent reported failure"
    elif final_status == "max_cycles_reached":
        failure_reason = f"cycle cap of {max_cycles} reached"

    return Telemetry(
        final_status=final_status,
        cycles_run=cycles_run,
        max_cycles=max_cycles,
        developer_invocations=developer_invocations,
        reviewer_invocations=reviewer_invocations,
        clarifications=clarifications,
        started_at=started_at,
        ended_at=ended_at,
        duration_seconds=duration_seconds,
        failure_reason=failure_reason,
        pr_number=_safe_int(init.get("pr")),
        run_id=init.get("run_id", ""),
        log_path=init.get("log_path", ""),
    )


def render_summary_block(telemetry: Telemetry) -> str:
    """Render the delimited PR-body summary block for a terminal log.

    Idempotent: the same telemetry always produces the same block.
    """
    lines = [
        SUMMARY_BLOCK_START,
        "## AI Loop Summary",
        "",
        f"- Final status: `{telemetry.final_status}`",
        f"- Cycles run: {telemetry.cycles_run} of {telemetry.max_cycles}",
        f"- Developer invocations: {telemetry.developer_invocations}",
        f"- Reviewer invocations: {telemetry.reviewer_invocations}",
        f"- Human clarifications: {telemetry.clarifications}",
        f"- Started: {telemetry.started_at or 'unknown'}",
        f"- Ended: {telemetry.ended_at or 'unknown'}",
        f"- Duration: {_format_duration(telemetry.duration_seconds)}",
    ]
    if telemetry.log_path:
        lines.append(
            f"- Loop log: [{telemetry.log_path}]({telemetry.log_path})"
        )
    if telemetry.failure_reason:
        lines.append(f"- Stopped because: {telemetry.failure_reason}")
    lines.append("")
    lines.append(SUMMARY_BLOCK_END)
    return "\n".join(lines)


def replace_summary_block(body: str, new_block: str) -> str:
    """Replace an existing summary block in ``body`` or append a new one.

    Idempotent: re-running with the same ``new_block`` yields the same
    output regardless of whether the body already had a block.
    """
    if SUMMARY_BLOCK_RE.search(body):
        return SUMMARY_BLOCK_RE.sub(new_block, body, count=1)
    body_trimmed = body.rstrip()
    if not body_trimmed:
        return new_block + "\n"
    return f"{body_trimmed}\n\n{new_block}\n"


def render_telemetry_footer(telemetry: Telemetry) -> str:
    """Render the HTML-comment telemetry footer appended to the log."""
    fields: list[tuple[str, str]] = [
        ("final_status", telemetry.final_status),
        ("cycles_run", str(telemetry.cycles_run)),
        ("max_cycles", str(telemetry.max_cycles)),
        ("developer_invocations", str(telemetry.developer_invocations)),
        ("reviewer_invocations", str(telemetry.reviewer_invocations)),
        ("clarifications", str(telemetry.clarifications)),
        ("started_at", telemetry.started_at),
        ("ended_at", telemetry.ended_at),
    ]
    if telemetry.duration_seconds is not None:
        fields.append(("duration_seconds", str(telemetry.duration_seconds)))
    if telemetry.failure_reason:
        fields.append(("failure_reason", telemetry.failure_reason))
    if telemetry.pr_number is not None:
        fields.append(("pr", str(telemetry.pr_number)))
    if telemetry.run_id:
        fields.append(("run_id", telemetry.run_id))
    body = "\n".join(f"{key}: {value}" for key, value in fields)
    display_time = display_now_local()
    return f"""
## {display_time} - Controller - Finalize loop ({telemetry.final_status})

The controller wrote the end-of-loop summary and telemetry for this run.

<!-- ai-loop-telemetry
{body}
-->
"""


def verify_tool(name: str, *, required: bool) -> str:
    path = shutil.which(name)
    if path:
        return f"ok: {name} -> {path}"
    prefix = "missing" if required else "warn: missing"
    return f"{prefix}: {name}"


def verify_gh_auth_for_setup() -> str:
    """Return a setup-time status line for gh authentication.

    `start` defaults to creating a draft PR, which requires `gh auth status`
    to succeed. Surface this at setup time so the prereq is visible up front
    instead of failing at first bootstrap.
    """
    if shutil.which(DEFAULT_GH_COMMAND) is None:
        return (
            f"warn: {DEFAULT_GH_COMMAND} missing; install GitHub CLI before "
            "running `make ai-loop-start` (or pass AI_LOOP_CREATE_PR=0 to "
            "stay local-only)"
        )
    result = subprocess.run(
        [DEFAULT_GH_COMMAND, "auth", "status"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return "ok: gh authenticated"
    return (
        "warn: gh installed but not authenticated; run `gh auth login` "
        "before `make ai-loop-start` (or pass AI_LOOP_CREATE_PR=0 to "
        "stay local-only)"
    )


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
        verify_gh_auth_for_setup(),
    ]:
        print(message)
    return 0


def placeholder_pr_title(prompt: str, *, max_length: int = 70) -> str:
    first_line = next(
        (line.strip() for line in prompt.splitlines() if line.strip()),
        "",
    )
    if not first_line:
        first_line = "AI loop bootstrap"
    prefix = "[wip] "
    available = max(1, max_length - len(prefix))
    if len(first_line) > available:
        first_line = first_line[: available - 1].rstrip() + "…"
    return f"{prefix}{first_line}"


def placeholder_pr_body(branch: str) -> str:
    return (
        f"Local AI loop run from branch `{branch}`. The committed log under "
        "`docs/ai-loop/` carries the agent conversation as it accumulates.\n\n"
        "Per AI loop convention, agents update this PR title and body as the "
        "work evolves; the bootstrap title and body are intentionally minimal."
    )


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

    create_pr = select_create_pr(git, args)
    gh: GhClient | None = None
    if create_pr:
        gh = GhClient(git)
        gh.ensure_available()
        gh.ensure_authenticated()
        if not git.has_origin_remote():
            raise AILoopError(
                "no `origin` remote configured; add one with "
                "`git remote add origin <url>` before bootstrapping a PR"
            )

    existing_branches = git.run(["branch", "--list", branch]).stdout.strip()
    if existing_branches:
        git.run(["switch", branch], capture_output=False)
    else:
        git.run(["switch", "-c", branch], capture_output=False)

    git.ensure_clean_worktree()

    if create_pr:
        assert gh is not None
        git.fetch("origin", "main")
        if not git.is_ancestor(AI_LOOP_BASE_REF, "HEAD"):
            raise AILoopError(
                f"branch {branch!r} is not a descendant of {AI_LOOP_BASE_REF}; "
                "rebase onto current origin/main before bootstrapping a PR"
            )
        existing_pr = gh.existing_open_pr_for_branch(branch)
        if existing_pr is not None:
            raise AILoopError(
                f"open PR #{existing_pr} already exists for branch "
                f"{branch!r}; close or reuse it before bootstrapping a new loop"
            )

    # Hold the same lock the post-commit hook uses for the entire
    # bootstrap. Every `[ai-loop]` commit below would otherwise fire
    # the hook in-process and dispatch the routed agent against
    # transient log state — the first hook fire sees the local-*.md
    # log just before the rename step rewrites it (silently losing any
    # commit the agent made), and even when the agent is unavailable
    # the hook still wastes an invocation attempt. With the lock held
    # here, all nested hook fires during bootstrap commits skip
    # immediately. After bootstrap completes we dispatch the agent
    # explicitly (see below) so auto-start is preserved without the
    # bug.
    lock_dir = _acquire_ai_loop_lock(git)
    try:
        run_id = make_run_id()
        rel_log_path = f"docs/ai-loop/{run_id}.md"
        log_path = repo / rel_log_path
        if log_path.exists():
            raise AILoopError(f"AI loop log already exists: {rel_log_path}")
        log_path.parent.mkdir(parents=True, exist_ok=True)
        started_at = iso_now_local()
        display_time = display_now_local()
        log_path.write_text(
            render_bootstrap_log(
                run_id=run_id,
                log_path=rel_log_path,
                prompt=prompt,
                repo=git.repo_name(),
                branch=git.current_branch(),
                started_at=started_at,
                display_time=display_time,
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

        if create_pr:
            assert gh is not None
            git.push_branch(branch)
            pr_number = gh.create_draft_pr(
                title=placeholder_pr_title(prompt),
                body=placeholder_pr_body(branch),
                base="main",
                head=branch,
            )
            print(f"created draft PR #{pr_number}")

            new_rel_log_path = pr_log_relpath(pr_number)
            new_log_path = repo / new_rel_log_path
            if new_log_path.exists():
                raise AILoopError(
                    f"PR-numbered log already exists: {new_rel_log_path}; "
                    "loop bootstrap cannot rename onto an existing file"
                )
            git.run(["mv", rel_log_path, new_rel_log_path], capture_output=False)
            new_log_path.write_text(
                render_bootstrap_log(
                    run_id=run_id,
                    log_path=new_rel_log_path,
                    prompt=prompt,
                    repo=git.repo_name(),
                    branch=git.current_branch(),
                    started_at=started_at,
                    display_time=display_time,
                    pr=pr_number,
                ),
                encoding="utf-8",
            )
            git.run(["add", new_rel_log_path], capture_output=True)
            git.run(
                [
                    "commit",
                    "-m",
                    f"[ai-loop] Human: bootstrap pr-{pr_number:04d}",
                ],
                capture_output=False,
            )
            print(f"renamed to {new_rel_log_path}")

            # Push the rename commit so the remote PR shows the
            # pr-NNNN.md log rather than the pre-rename local-*.md
            # placeholder. The first push above carried only the start
            # commit (since the PR needed an existing remote tip
            # before `gh pr create`).
            git.push_branch(branch, set_upstream=False)

            gh.ensure_label(
                AI_LOOP_LABEL,
                color=AI_LOOP_LABEL_COLOR,
                description=AI_LOOP_LABEL_DESCRIPTION,
            )
            gh.add_label_to_pr(pr_number, AI_LOOP_LABEL)
            print(f"applied label {AI_LOOP_LABEL!r} to PR #{pr_number}")

            log_path = new_log_path

        # Bootstrap is complete. If the caller asked for invocation
        # (env, git config, or future --invoke flag), dispatch now
        # while we still hold the lock — agent commits inside the
        # loop will fire the post-commit hook in their subprocesses,
        # and those hook fires hit the same lock and skip, so the
        # only dispatch chain is this explicit one. If the agent
        # fails (codex usage limit, etc.) the AILoopError raised
        # here propagates after the PR and branch are already in
        # place, so the user can fix the underlying issue and retry
        # via `make ai-loop-continue --invoke` without redoing the
        # bootstrap.
        dispatcher = AgentDispatcher(git)
        if dispatcher.should_invoke(args):
            git.ensure_dispatch_safe_worktree()
            router = StateRouter()
            profile = dispatcher.selected_profile(args)
            run_agent_loop(
                git=git,
                router=router,
                dispatcher=dispatcher,
                log_path=log_path,
                profile=profile,
                trigger="start",
            )
        return 0
    finally:
        _release_ai_loop_lock(lock_dir)


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
        # Finalize when the log already entered command_continue in a
        # terminal state — happens when the hook fires on the agent's
        # own terminal commit, or when the user re-runs `continue` on a
        # previously terminated log. The function is idempotent so a
        # repeat call is a no-op once the telemetry footer is present.
        if dispatcher.should_invoke(args):
            finalize_terminal_log(git=git, log_path=log_path)
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
    is_chained_dispatch = False
    while True:
        parsed = parse_log_file(log_path)
        latest = parsed.latest_event
        if not latest:
            raise AILoopError(f"no ai-loop-event blocks found in {log_path}")

        route = router.route_for_event(latest)
        decision = routing_decision_for_log(router, parsed, latest)
        if not route:
            print_stop_decision(trigger, decision, is_chained_dispatch)
            finalize_terminal_log(git=git, log_path=log_path)
            return

        if should_stop_for_cycle_cap(parsed, latest, route):
            print_stop_decision(trigger, decision, is_chained_dispatch)
            append_max_cycles_reached_event(
                git=git,
                log_path=log_path,
                latest=latest,
                max_cycles=max_cycles_for_log(parsed),
            )
            finalize_terminal_log(git=git, log_path=log_path)
            return

        if is_chained_dispatch:
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
        is_chained_dispatch = True


def print_stop_decision(
    trigger: str,
    decision: str,
    is_chained_dispatch: bool,
) -> None:
    if is_chained_dispatch:
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


def push_finalized_branch(git: GitContext, branch: str) -> bool:
    """Push ``branch`` to ``origin`` so the remote PR reflects the loop's
    local commits before any PR-body or draft-ready mutation runs.

    Fail-tolerant: returns ``True`` on success and ``False`` on any push
    failure (network blip, no `origin`, push rejected). Callers should
    short-circuit the subsequent PR mutations on ``False`` so the
    controller does not half-finalize — flipping a draft PR to
    ready-for-review against a stale branch is exactly the foot-gun this
    push exists to prevent.
    """
    result = git.run(["push", "origin", branch], check=False)
    if result.returncode != 0:
        stderr = (result.stderr or "").strip() or "git push failed"
        print(
            f"ai-loop: could not push branch {branch!r}: {stderr}",
            file=sys.stderr,
            flush=True,
        )
        return False
    return True


def finalize_terminal_log(*, git: GitContext, log_path: Path) -> None:
    """Write the end-of-loop summary + telemetry for a terminal log.

    No-op for non-terminal statuses (``awaiting_human``, ``paused``,
    unknown). Idempotent: if a telemetry footer already exists in the log
    (from a previous controller pass), this function returns without
    making a second commit or PR mutation.

    On terminal statuses, the controller:

    1. Appends a telemetry footer to the log and commits it.
    2. If a PR number is known from ``ai-loop-init``, replaces the
       delimited summary block in the PR body (appends if absent).
    3. If the final status is ``clean``, marks the PR ready-for-review;
       on ``max_cycles_reached`` / ``failed`` the PR stays in draft so
       the human can adjudicate.

    All ``gh`` interactions are fail-tolerant: a missing or failing
    ``gh`` logs a warning and the controller continues. The local
    telemetry footer is still committed even when the PR mutation
    cannot be performed.
    """
    parsed = parse_log_file(log_path)
    latest = parsed.latest_event or {}
    status = latest.get("status", "")
    if status not in TERMINAL_FINALIZE_STATUSES:
        return

    log_text = log_path.read_text(encoding="utf-8")
    if TELEMETRY_FOOTER_MARKER in log_text:
        print(
            f"ai-loop: telemetry footer already present in {log_path.name}; "
            "finalize is a no-op",
            flush=True,
        )
        return

    git.ensure_dispatch_safe_worktree()
    telemetry = derive_telemetry(parsed, ended_at=iso_now_local())
    footer = render_telemetry_footer(telemetry)
    rel_log_path = repo_relative_path(git.repo, log_path)
    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(footer)
    git.run(["add", rel_log_path], capture_output=True)
    git.run(
        [
            "commit",
            "-m",
            f"[ai-loop] Controller: finalize {telemetry.final_status}",
        ],
        capture_output=False,
    )
    print(
        f"ai-loop: wrote end-of-loop telemetry footer ({telemetry.final_status})",
        flush=True,
    )

    if telemetry.pr_number is None:
        return

    # Push the branch before mutating the PR. The local HEAD now carries
    # the finalize commit plus whatever the agents committed during the
    # loop — `run_agent_loop` only verifies `HEAD` advanced after each
    # agent turn, it does not push. Without this push, `gh pr edit` /
    # `gh pr ready` succeed against the PR object while `origin/<branch>`
    # still points at the pre-loop bootstrap tip, leaving reviewers
    # notified on a stale branch. See Codex bot finding B3 on PR #90
    # (same shape as PR #88's bootstrap-rename push fix on PR #86).
    branch = git.current_branch()
    if not push_finalized_branch(git, branch):
        print(
            f"ai-loop: skipping PR #{telemetry.pr_number} body and ready "
            f"updates because pushing {branch!r} failed; the local telemetry "
            "commit is intact, push the branch manually and re-run finalize "
            "to retry the PR-side updates",
            file=sys.stderr,
            flush=True,
        )
        return

    gh = GhClient(git)
    current_body = gh.fetch_pr_body(telemetry.pr_number)
    if current_body is None:
        return

    new_body = replace_summary_block(current_body, render_summary_block(telemetry))
    if new_body == current_body:
        print(
            f"ai-loop: PR #{telemetry.pr_number} body summary already current",
            flush=True,
        )
    elif gh.edit_pr_body(telemetry.pr_number, new_body):
        print(
            f"ai-loop: updated PR #{telemetry.pr_number} body with end-of-loop summary",
            flush=True,
        )

    if telemetry.final_status == "clean":
        if gh.mark_pr_ready(telemetry.pr_number):
            print(
                f"ai-loop: marked PR #{telemetry.pr_number} ready for review",
                flush=True,
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
    start.add_argument(
        "--create-pr",
        action=argparse.BooleanOptionalAction,
        default=None,
        help=(
            "default ON: push the branch, create a draft PR, rename the log "
            f"to docs/ai-loop/pr-NNNN.md, and apply the {AI_LOOP_LABEL!r} "
            f"label. Pass --no-create-pr (or {CREATE_PR_ENV}=0 / git config "
            "ai-loop.createPr false) for offline iteration that keeps the "
            "local-YYYYMMDD-HHMMSS.md log only."
        ),
    )
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
