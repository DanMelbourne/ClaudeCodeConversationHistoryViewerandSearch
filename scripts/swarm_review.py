#!/usr/bin/env python3
"""Swarm code review — fan a repo's changed files out to an LLM, one request
per file, and collect prioritised [P0]-[P2] findings.

Project-agnostic: resolves the repo via `git rev-parse --show-toplevel`, loads
its review prompt from `.swarm-review.md` in the repo root (falling back to a
generic code-review prompt), and reviews whatever file types you point it at.

Providers (pick with REVIEW_PROVIDER, default groq):
    groq        openai/gpt-oss-120b   $0.15/M in, $0.60/M out  (batch-capable)
    openrouter  openai/gpt-oss-120b   pay-as-you-go, no TPM cap
    deepseek    deepseek-v4-flash     $0.10/M in, $0.20/M out  (cheapest)
Override the model with REVIEW_MODEL. API key comes from the matching env var
(GROQ_API_KEY / OPENROUTER_API_KEY / DEEPSEEK_API_KEY) or the macOS Keychain
(`security add-generic-password -s GROQ_API_KEY -a $USER -w`).

Per-project setup:
    1. Drop this script anywhere on PATH (or in the repo's scripts/ dir).
    2. Optional: add a `.swarm-review.md` to the repo root with the project's
       own invariants / bug-classes. Without it, a generic prompt is used.
    3. Run it from inside the repo.

File selection: defaults to a broad set of source extensions. Narrow with
`--ext swift,ts,py` or REVIEW_EXTS.

Modes:
    Sync (default)   — parallel requests, findings written live.
    Batch (--batch)  — one async Groq job, 50% cheaper, no TPM cap. Submit and
                       collect are separate so you can submit overnight.

Usage:
    swarm_review.py                       # working-tree changes
    swarm_review.py --vs main             # diff vs main + working tree
    swarm_review.py --all                 # every source file in the repo
    swarm_review.py --ext ts,tsx --all    # only TS/TSX
    swarm_review.py path/to/File.py       # explicit list
    swarm_review.py --batch <files…>      # submit Groq batch; prints batch_id
    swarm_review.py --batch-status BATCH_ID
    swarm_review.py --batch-collect BATCH_ID

Output: review-findings/SUMMARY.md plus per-file detail in review-findings/by-file/.
Batch state: .swarm-batches/<batch_id>.json. Add both to .gitignore.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

PROVIDERS = {
    "groq": {
        "url": "https://api.groq.com/openai/v1/chat/completions",
        "key_env": "GROQ_API_KEY",
        "default_model": "openai/gpt-oss-120b",
        # Groq free tier is rate-limited by TPM (~8K/min) more aggressively
        # than by RPM, and the 429-backoff smooths the rest. Conservative
        # defaults; raise via REVIEW_RPM / REVIEW_CONCURRENT on a paid tier.
        "default_rpm": 10,
        "default_concurrent": 2,
    },
    "openrouter": {
        "url": "https://openrouter.ai/api/v1/chat/completions",
        "key_env": "OPENROUTER_API_KEY",
        "default_model": "openai/gpt-oss-120b",
        "default_rpm": 300,
        "default_concurrent": 10,
    },
    # DeepSeek direct API. V4 Flash: $0.10/M in, $0.20/M out — cheapest
    # capable code-review option found. 1M context, non-reasoning, so the
    # response shape is the normal `choices[0].message.content`.
    "deepseek": {
        "url": "https://api.deepseek.com/v1/chat/completions",
        "key_env": "DEEPSEEK_API_KEY",
        "default_model": "deepseek-v4-flash",
        "default_rpm": 60,
        "default_concurrent": 8,
    },
}

PROVIDER = os.environ.get("REVIEW_PROVIDER", "groq").lower()
if PROVIDER not in PROVIDERS:
    sys.exit(f"unknown REVIEW_PROVIDER={PROVIDER!r}; options: {', '.join(PROVIDERS)}")
CFG = PROVIDERS[PROVIDER]


def _keychain_lookup(service: str) -> str | None:
    try:
        out = subprocess.check_output(
            ["security", "find-generic-password", "-s", service, "-w"],
            text=True, stderr=subprocess.DEVNULL,
        )
        return out.strip() or None
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


API_KEY = os.environ.get(CFG["key_env"]) or _keychain_lookup(CFG["key_env"])
if not API_KEY:
    sys.exit(
        f"No API key found.\n"
        f"  Tried env var: {CFG['key_env']}\n"
        f"  Tried macOS Keychain service: {CFG['key_env']}\n"
        f"  Get one:\n"
        f"    Groq:       https://console.groq.com/keys\n"
        f"    OpenRouter: https://openrouter.ai/keys\n"
        f"    DeepSeek:   https://platform.deepseek.com/api_keys\n"
        f"  Store in Keychain:\n"
        f"    security add-generic-password -s {CFG['key_env']} -a $USER -w"
    )

MODEL = os.environ.get("REVIEW_MODEL", CFG["default_model"])
RPM = int(os.environ.get("REVIEW_RPM", CFG["default_rpm"]))
CONCURRENT = int(os.environ.get("REVIEW_CONCURRENT", CFG["default_concurrent"]))


def _resolve_repo_root() -> Path:
    """Repo root from the CURRENT working directory, so the script can live
    anywhere and operate on whatever repo you run it inside. Falls back to the
    script's own parent-of-scripts dir, then the cwd."""
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            text=True, stderr=subprocess.DEVNULL,
        ).strip()
        if out:
            return Path(out)
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    here = Path(__file__).resolve()
    if here.parent.name == "scripts":
        return here.parent.parent
    return Path.cwd()


REPO_ROOT = _resolve_repo_root()
OUT_DIR = REPO_ROOT / "review-findings"
PROGRESS_PATH = OUT_DIR / ".progress.jsonl"
BATCH_STATE_DIR = REPO_ROOT / ".swarm-batches"
BATCH_API_BASE = "https://api.groq.com/openai/v1"
SCRIPT_HINT = sys.argv[0] if sys.argv and sys.argv[0] else "swarm_review.py"
USER_AGENT = "swarm-review/2.0"

# Source-file extensions to review. Override with --ext or REVIEW_EXTS.
DEFAULT_EXTS = (
    "swift,ts,tsx,js,jsx,mjs,py,go,rs,rb,java,kt,kts,c,cc,cpp,cxx,"
    "h,hpp,hh,m,mm,cs,php,scala,sh,bash,sql,lua,dart,ex,exs"
)
# Maps an extension to its Markdown code-fence language hint.
FENCE_LANG = {
    "swift": "swift", "ts": "typescript", "tsx": "tsx", "js": "javascript",
    "jsx": "jsx", "mjs": "javascript", "py": "python", "go": "go", "rs": "rust",
    "rb": "ruby", "java": "java", "kt": "kotlin", "kts": "kotlin", "c": "c",
    "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "h": "c", "hpp": "cpp", "hh": "cpp",
    "m": "objectivec", "mm": "objectivec", "cs": "csharp", "php": "php",
    "scala": "scala", "sh": "bash", "bash": "bash", "sql": "sql", "lua": "lua",
    "dart": "dart", "ex": "elixir", "exs": "elixir",
}
# Directories never worth scanning under --all.
IGNORE_DIRS = {
    ".git", ".build", "build", "node_modules", "dist", ".swiftpm", "Pods",
    "vendor", ".venv", "venv", "env", "__pycache__", ".next", "target",
    "DerivedData", ".swarm-batches", "review-findings", ".mypy_cache",
    ".pytest_cache", "coverage", ".gradle", "out",
}


def _parse_exts(spec: str) -> set[str]:
    return {e.strip().lstrip(".").lower() for e in spec.split(",") if e.strip()}


EXTS = _parse_exts(os.environ.get("REVIEW_EXTS", DEFAULT_EXTS))


def _matches_ext(path_str: str) -> bool:
    ext = path_str.rsplit(".", 1)[-1].lower() if "." in path_str else ""
    return ext in EXTS


def _fence_lang(path: Path) -> str:
    return FENCE_LANG.get(path.suffix.lstrip(".").lower(), "")


GENERIC_SYSTEM_PROMPT = """You are a senior engineer reviewing one source file for bugs.

Hunt these classes of issue, hardest-hitting first:
1. CORRECTNESS — logic errors, off-by-one, wrong operators, unhandled nil/None,
   incorrect conditionals, broken control flow.
2. INVARIANT VIOLATIONS — when a name or doc implies a property (expand ⇒
   result ≥ input; reversible ⇒ decode(encode(x)) == x; idempotent ⇒ no change
   when the precondition already holds), check it actually holds.
3. CONCURRENCY — data races, unsynchronised shared mutable state, deadlocks,
   leaked tasks/threads, async/await misuse, callbacks on the wrong thread.
4. RESOURCE & ERROR HANDLING — unclosed handles, unbalanced acquire/release,
   swallowed errors, missing failure paths, non-atomic file writes.
5. SECURITY — secrets in plaintext or logs, injection (SQL, shell, prompt),
   unvalidated input crossing a trust boundary, unsafe deserialisation.
6. API MISUSE — fatal-on-duplicate collection inits, force-unwraps that can
   fail, truncation/rounding that loses data, shared-instance mutation.
7. MISSING TEST COVERAGE — visible behaviour or a stated invariant with no test.

OUTPUT FORMAT — prioritised findings only, this exact markdown shape:

## [P0] Short title

- **File:** `path/relative/to/repo.ext:LINE`
- **Issue:** one sentence describing what's wrong
- **Why it matters:** one sentence on the user-visible or correctness impact
- **Fix direction:** one sentence on the likely fix

## [P1] ...

Priorities:
- P0  correctness bug, data loss, crash, security, build break
- P1  invariant violation, missing test for visible behaviour, regression risk
- P2  cleanup, robustness, minor consistency

Rules:
- Use the line numbers shown in the file. Do NOT invent line numbers.
- One finding per `## [Pn]` heading. Don't combine.
- Favour precision over volume: only flag issues you are confident are real.
- If nothing worth flagging, output exactly:  No findings.
- No preamble. No closing summary. Just findings or `No findings.`
"""


def _load_system_prompt() -> tuple[str, str]:
    """Returns (prompt_text, source_label)."""
    env_file = os.environ.get("REVIEW_PROMPT_FILE")
    if env_file:
        p = Path(env_file)
        if p.is_file():
            return p.read_text(encoding="utf-8"), f"env REVIEW_PROMPT_FILE={env_file}"
    repo_prompt = REPO_ROOT / ".swarm-review.md"
    if repo_prompt.is_file():
        return repo_prompt.read_text(encoding="utf-8"), ".swarm-review.md"
    return GENERIC_SYSTEM_PROMPT, "built-in generic"


SYSTEM_PROMPT, PROMPT_SOURCE = _load_system_prompt()


class RateLimiter:
    def __init__(self, rpm: int) -> None:
        self.rpm = rpm
        self.stamps: list[float] = []
        self.lock = threading.Lock()

    def acquire(self) -> None:
        while True:
            with self.lock:
                now = time.monotonic()
                self.stamps = [t for t in self.stamps if now - t < 60.0]
                if len(self.stamps) < self.rpm:
                    self.stamps.append(now)
                    return
                wait = 60.0 - (now - self.stamps[0]) + 0.05
            time.sleep(wait)


def number_lines(content: str) -> str:
    return "\n".join(f"{i + 1:5d}\t{line}" for i, line in enumerate(content.splitlines()))


def _git(args: list[str]) -> str:
    try:
        return subprocess.check_output(
            ["git", *args], cwd=REPO_ROOT, text=True, stderr=subprocess.DEVNULL
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def _in_git_repo() -> bool:
    return _git(["rev-parse", "--is-inside-work-tree"]).strip() == "true"


def _rel(path: Path) -> Path:
    """Path relative to the repo root, or the path unchanged if it lies
    outside REPO_ROOT (or is already relative). main() filters out-of-tree
    files before review, but this keeps every display/naming/custom-id site
    crash-proof regardless of caller — the original bug here was an
    unguarded relative_to() ValueError."""
    try:
        return path.relative_to(REPO_ROOT)
    except ValueError:
        return path


def changed_files(vs_branch: str | None) -> list[Path]:
    paths: list[Path] = []
    if vs_branch:
        out = _git(["diff", "--name-only", f"{vs_branch}...HEAD"])
        paths += [REPO_ROOT / p for p in out.splitlines() if _matches_ext(p)]
    # Working tree (staged + unstaged + untracked).
    status = _git(["status", "--porcelain"])
    for line in status.splitlines():
        p = line[3:].strip()
        if " -> " in p:  # renames: "old -> new"
            p = p.split(" -> ", 1)[1]
        if _matches_ext(p):
            paths.append(REPO_ROOT / p)
    seen: set[Path] = set()
    result: list[Path] = []
    for p in paths:
        rp = p.resolve()
        if rp in seen or not rp.exists():
            continue
        seen.add(rp)
        result.append(rp)
    return result


def all_source_files() -> list[Path]:
    # Single os.walk that prunes IGNORE_DIRS as it descends (so it never
    # enters node_modules/.build/etc), instead of N per-extension rglob
    # passes that scan the whole tree N times and only filter afterwards.
    result: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(REPO_ROOT):
        dirnames[:] = [d for d in dirnames if d not in IGNORE_DIRS]
        for fn in filenames:
            ext = fn.rsplit(".", 1)[-1].lower() if "." in fn else ""
            if ext in EXTS:
                result.append(Path(dirpath) / fn)
    return sorted(result)


MAX_INPUT_BYTES = 400_000


def build_chat_body(path: Path) -> dict | None:
    """Return the chat-completions request body for one file, or None if the
    file is unreadable / too large. Shared by sync and batch."""
    try:
        content = path.read_text(encoding="utf-8")
    except Exception:
        return None
    if len(content.encode("utf-8")) > MAX_INPUT_BYTES:
        return None
    rel = _rel(path)
    lang = _fence_lang(path)
    user = (
        f"File: `{rel}`\n\n"
        f"```{lang}\n{number_lines(content)}\n```\n\n"
        f"Review this file. Output prioritised findings per the system prompt, "
        f"or exactly `No findings.`"
    )
    return {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user},
        ],
        "temperature": 0.2,
        "max_tokens": 2048,
    }


def _post_chat(payload: dict, limiter: RateLimiter) -> dict:
    """POST a chat-completions payload with retry/backoff. Returns the parsed
    JSON response, or {"error": "..."} on failure. Shared by single-shot and
    agentic review. Each call counts against the rate limiter (so an agentic
    file's N tool round-trips are paced like N requests)."""
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        CFG["url"],
        data=body,
        headers={
            "Authorization": f"Bearer {API_KEY}",
            "Content-Type": "application/json",
            # Cloudflare in front of some provider APIs blocks the default
            # `Python-urllib/...` UA with HTTP 403 / error 1010.
            "User-Agent": USER_AGENT,
        },
        method="POST",
    )
    backoff = 2.0
    for _ in range(6):
        limiter.acquire()
        try:
            with urllib.request.urlopen(req, timeout=180) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as e:
            if e.code in (429, 502, 503, 504):
                time.sleep(backoff)
                backoff = min(backoff * 2, 60.0)
                continue
            detail = e.read().decode("utf-8", errors="replace")[:400]
            return {"error": f"HTTP {e.code}: {detail}"}
        except Exception as e:
            return {"error": f"request failed: {e}"}
    return {"error": "rate-limited after 6 retries"}


def review_one(path: Path, limiter: RateLimiter) -> tuple[Path, str | None, str | None]:
    body_dict = build_chat_body(path)
    if body_dict is None:
        return path, None, f"skipped: unreadable or > {MAX_INPUT_BYTES // 1000}KB"
    resp = _post_chat(body_dict, limiter)
    if "error" in resp:
        return path, None, resp["error"]
    try:
        content = resp["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        return path, None, "malformed response shape"
    if content is None:
        return path, None, "null content (reasoning model? raise max_tokens or switch model)"
    return path, content.strip(), None


# ─── Agentic review (per-file reviewer with read-only repo tools) ───────────

AGENTIC_TOOLS = [
    {"type": "function", "function": {
        "name": "grep",
        "description": "Search the repository for a regex/literal pattern. Returns "
                       "matching file:line:text (capped). Use to find where a symbol is "
                       "defined or used elsewhere before judging the file under review.",
        "parameters": {"type": "object", "properties": {
            "pattern": {"type": "string", "description": "regex or literal to search for"},
            "glob": {"type": "string", "description": "optional pathspec, e.g. '*.swift'"},
        }, "required": ["pattern"]},
    }},
    {"type": "function", "function": {
        "name": "read_file",
        "description": "Read a repo file (or a line range) to inspect a definition or "
                       "call site. Path is relative to the repo root.",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string"},
            "start": {"type": "integer", "description": "1-based start line (optional)"},
            "end": {"type": "integer", "description": "end line inclusive (optional)"},
        }, "required": ["path"]},
    }},
    {"type": "function", "function": {
        "name": "list_files",
        "description": "List repo files matching a glob (e.g. 'Sources/**/*.swift'). Use "
                       "to discover where something lives.",
        "parameters": {"type": "object", "properties": {
            "glob": {"type": "string"},
        }, "required": ["glob"]},
    }},
]

AGENTIC_HINT = (
    "\n\nYou have read-only tools — grep, read_file, list_files — to inspect OTHER "
    "files in this repo. Before flagging anything that depends on code you can't see "
    "(is a symbol defined? used anywhere? does a type conform to a protocol? what does "
    "a caller pass? is a method @MainActor?), VERIFY with a tool instead of guessing. "
    "Prefer precision: a finding you couldn't confirm cross-file should be dropped or "
    "downgraded. When done investigating, output the findings (or exactly `No findings.`) "
    "as your final message with NO tool calls."
)

MAX_TOOL_ITERS = 8
GREP_MAX_LINES = 80
READ_MAX_LINES = 400
LIST_MAX = 120
TOOL_RESULT_MAX_CHARS = 8000


def _safe_repo_path(rel: str) -> Path | None:
    """Resolve a tool-supplied path under REPO_ROOT, or None if it escapes
    (path traversal / symlink out). resolve() collapses .. and follows
    symlinks, so an out-of-tree target is caught here."""
    try:
        p = (REPO_ROOT / rel).resolve()
    except Exception:
        return None
    if p != REPO_ROOT and REPO_ROOT not in p.parents:
        return None
    return p


def tool_grep(pattern: str, glob: str | None = None) -> str:
    if not pattern:
        return "(empty pattern)"
    # git grep is fast and respects .gitignore (skips dist/, .build/,
    # node_modules, review-findings, etc. automatically); --untracked also
    # covers new/untracked source files. Plain `grep -r .` over the working
    # tree was timing out on the large dist/ + Xcode-project dirs.
    cmd = ["git", "grep", "-nI", "--untracked", "-e", pattern]
    if glob:
        # git grep pathspec: match the basename anywhere in the tree.
        base = glob.rsplit("/", 1)[-1] or glob
        cmd += ["--", base if base.startswith("*") else f"*{base}"]
    try:
        out = subprocess.run(cmd, cwd=REPO_ROOT, capture_output=True, text=True, timeout=20)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return "(grep unavailable / timed out)"
    lines = out.stdout.splitlines()
    if not lines:
        return "(no matches)"
    capped = lines[:GREP_MAX_LINES]
    extra = "" if len(lines) <= GREP_MAX_LINES else f"\n… +{len(lines) - GREP_MAX_LINES} more matches"
    return "\n".join(capped) + extra


def tool_read(path: str, start: int | None = None, end: int | None = None) -> str:
    p = _safe_repo_path(path)
    if p is None:
        return "(path outside repo)"
    if not p.is_file():
        return "(not a file)"
    try:
        lines = p.read_text(encoding="utf-8").splitlines()
    except Exception as e:
        return f"(read failed: {e})"
    n = len(lines)
    s = max(1, start or 1)
    e = min(n, end or n)
    if e < s:
        e = s
    if e - s + 1 > READ_MAX_LINES:
        e = s + READ_MAX_LINES - 1
    chunk = lines[s - 1:e]
    numbered = "\n".join(f"{s + i:5d}\t{ln}" for i, ln in enumerate(chunk))
    return f"{path} (lines {s}-{e} of {n}):\n{numbered}"


def tool_list(glob: str) -> str:
    try:
        matches = sorted(
            str(p.relative_to(REPO_ROOT))
            for p in REPO_ROOT.glob(glob)
            if p.is_file() and not any(part in IGNORE_DIRS for part in p.relative_to(REPO_ROOT).parts)
        )
    except Exception as e:
        return f"(glob failed: {e})"
    if not matches:
        return "(no matches)"
    capped = matches[:LIST_MAX]
    extra = "" if len(matches) <= LIST_MAX else f"\n… +{len(matches) - LIST_MAX} more"
    return "\n".join(capped) + extra


# Models reach for familiar names — map the common variants onto our tools
# so a hallucinated "search"/"cat"/"ls" still works instead of dead-ending.
_TOOL_ALIASES = {
    "search": "grep", "rg": "grep", "ripgrep": "grep", "git_grep": "grep",
    "search_code": "grep", "find_in_files": "grep",
    "cat": "read_file", "open": "read_file", "view": "read_file", "read": "read_file",
    "open_file": "read_file",
    "ls": "list_files", "find": "list_files", "glob": "list_files", "list": "list_files",
}


def execute_tool(name: str, args: dict) -> str:
    canon = _TOOL_ALIASES.get(name, name)
    try:
        if canon == "grep":
            pattern = args.get("pattern") or args.get("query") or args.get("q") or ""
            glob = args.get("glob") or args.get("include") or args.get("path_glob")
            return tool_grep(pattern, glob)
        if canon == "read_file":
            path = args.get("path") or args.get("file") or args.get("filename") or ""
            return tool_read(path, args.get("start"), args.get("end"))
        if canon == "list_files":
            glob = args.get("glob") or args.get("pattern") or args.get("path") or "*"
            return tool_list(glob)
    except Exception as e:
        return f"(tool {name} failed: {e})"
    return (f"(unknown tool '{name}' — available tools: grep(pattern, glob), "
            f"read_file(path, start, end), list_files(glob). Use one of these.)")


def agentic_review_one(path: Path, limiter: RateLimiter) -> tuple[Path, str | None, str | None]:
    """Multi-turn review: the model may call grep/read_file/list_files to check
    cross-file facts before reporting. Returns the same (path, findings, err)
    shape as review_one so run_sync's loop is unchanged."""
    base = build_chat_body(path)
    if base is None:
        return path, None, f"skipped: unreadable or > {MAX_INPUT_BYTES // 1000}KB"
    messages = [dict(m) for m in base["messages"]]
    messages[-1]["content"] += AGENTIC_HINT

    for i in range(MAX_TOOL_ITERS):
        last = i == MAX_TOOL_ITERS - 1
        if last:
            # Final iteration: drop tools and demand a conclusion so a model
            # that keeps investigating (e.g. V4 Flash loops indefinitely)
            # salvages a finding instead of erroring out. Append the nudge
            # BEFORE building the payload so there's no append-after-construct
            # aliasing dependency on the shared messages list.
            messages.append({
                "role": "user",
                "content": "You've investigated enough. Output your findings now "
                           "(or exactly `No findings.`) with no further tool calls.",
            })
        payload = {
            "model": MODEL,
            "messages": messages,
            "temperature": 0.2,
            # Bigger budget than single-shot: a reasoning model spends tokens
            # thinking between/around tool calls, and the final findings answer
            # still needs room — too small a cap yields null content.
            "max_tokens": 4096,
        }
        if not last:
            payload["tools"] = AGENTIC_TOOLS
        resp = _post_chat(payload, limiter)
        if "error" in resp:
            return path, None, resp["error"]
        try:
            msg = resp["choices"][0]["message"]
        except (KeyError, IndexError, TypeError):
            return path, None, "malformed response shape"

        tool_calls = msg.get("tool_calls")
        if tool_calls and not last:
            # Ensure each tool_call has an id: a provider that omits it would
            # otherwise write `tool_call_id: null` into the history and poison
            # every later request. Fix it on the call so the assistant turn and
            # its tool replies agree.
            for idx, tc in enumerate(tool_calls):
                if not tc.get("id"):
                    tc["id"] = f"call_{i}_{idx}"
            messages.append({
                "role": "assistant",
                "content": msg.get("content"),
                "tool_calls": tool_calls,
            })
            for tc in tool_calls:
                fn = tc.get("function", {})
                try:
                    args = json.loads(fn.get("arguments") or "{}")
                except (json.JSONDecodeError, TypeError):
                    args = {}
                result = execute_tool(fn.get("name", ""), args)
                messages.append({
                    "role": "tool",
                    "tool_call_id": tc["id"],
                    "content": result[:TOOL_RESULT_MAX_CHARS],
                })
            continue

        content = msg.get("content")
        if content is None:
            if tool_calls:
                names = [tc.get("function", {}).get("name") for tc in tool_calls]
                return path, None, f"kept calling tools {names} instead of concluding"
            if not last:
                # gpt-oss/OpenRouter quirk: the model ends on reasoning without
                # emitting a structured tool_call OR an answer (the intended tool
                # call leaks into the reasoning text). Nudge it to act and retry
                # rather than giving up — the loop's last iteration force-concludes.
                messages.append({
                    "role": "user",
                    "content": "Your last turn produced no answer and no structured tool "
                               "call. Either emit a proper function/tool call, or output "
                               "your findings now (or `No findings.`).",
                })
                continue
            return path, None, "null content (reasoning model? raise max_tokens or switch model)"
        return path, content.strip(), None

    return path, None, f"tool loop hit {MAX_TOOL_ITERS} iterations without a final answer"


def safe_name(rel: Path) -> str:
    # Keep the original extension in the name (Foo.swift.md) so files that
    # differ only by extension in a polyglot repo don't collide.
    return re.sub(r"[^A-Za-z0-9_.-]", "__", str(rel)) + ".md"


def _counts(out: str) -> tuple[int, int, int]:
    return out.count("## [P0]"), out.count("## [P1]"), out.count("## [P2]")


def write_one_finding(rel: Path, out: str) -> None:
    """Persist a single file's findings markdown immediately (atomically, so a
    kill mid-write can't leave a truncated .md), keeping a killed run's work."""
    d = OUT_DIR / "by-file"
    d.mkdir(parents=True, exist_ok=True)
    final = d / safe_name(rel)
    tmp = d / (safe_name(rel) + ".tmp")
    tmp.write_text(f"# {rel}\n\n{out}\n", encoding="utf-8")
    os.replace(tmp, final)


# Guards the progress-log append. Today log_progress is only called from the
# as_completed loop on the main thread, but the lock keeps it correct if a
# future change ever logs from worker threads.
_progress_lock = threading.Lock()


def log_progress(rel: Path, status: str, detail: str = "") -> None:
    """Append a completed-file record (flushed per line) so --resume can skip
    it and --rebuild-summary knows the reviewed count. status: found|clean|err."""
    OUT_DIR.mkdir(exist_ok=True)
    with _progress_lock, PROGRESS_PATH.open("a", encoding="utf-8") as f:
        f.write(json.dumps({"path": str(rel), "status": status, "detail": detail}) + "\n")
        f.flush()


def _repo_head() -> str:
    return _git(["rev-parse", "HEAD"]).strip()


def _write_progress_head(head: str) -> None:
    """Record the repo HEAD as a meta line so --resume can warn if the working
    tree moved since the run that produced the progress log."""
    OUT_DIR.mkdir(exist_ok=True)
    with _progress_lock, PROGRESS_PATH.open("a", encoding="utf-8") as f:
        f.write(json.dumps({"_head": head}) + "\n")
        f.flush()


def _progress_head() -> str:
    if not PROGRESS_PATH.exists():
        return ""
    for line in PROGRESS_PATH.read_text(encoding="utf-8").splitlines():
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict) and "_head" in obj:
            return obj["_head"]
    return ""


def completed_paths() -> set[str]:
    """Rel-path strings already reviewed in a prior (possibly killed) run.
    Skips the `_head` meta line and any malformed/non-path records."""
    if not PROGRESS_PATH.exists():
        return set()
    done: set[str] = set()
    for line in PROGRESS_PATH.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
            if isinstance(obj, dict) and "path" in obj:
                done.add(obj["path"])
        except (json.JSONDecodeError, TypeError):
            continue
    return done


def rebuild_summary(reviewed: int | None = None) -> tuple[int, int, int]:
    """Regenerate SUMMARY.md from the by-file/ dir on disk (no API calls).
    Used at the end of every run and recoverable after a kill via
    --rebuild-summary. `reviewed` overrides the file-count line (batch-collect
    knows its total; the sync path leaves it None to read the progress log)."""
    by_file = OUT_DIR / "by-file"
    found: list[tuple[Path, str, int, int, int]] = []
    if by_file.is_dir():
        for md in sorted(by_file.glob("*.md")):
            text = md.read_text(encoding="utf-8")
            nl = text.find("\n")
            # removeprefix, NOT lstrip — lstrip("# ") strips a whole char-set
            # and would eat leading '#'/' ' from a path like "#config.py".
            header = text[:nl].removeprefix("# ").strip() if nl >= 0 else md.stem
            body = text[nl + 1:].strip() if nl >= 0 else text.strip()
            p0, p1, p2 = _counts(body)
            found.append((Path(header), body, p0, p1, p2))
    found.sort(key=lambda x: (-x[2], -x[3], -x[4], str(x[0])))
    total_p0 = sum(x[2] for x in found)
    total_p1 = sum(x[3] for x in found)
    total_p2 = sum(x[4] for x in found)
    if reviewed is None:
        reviewed = len(completed_paths()) or len(found)
    lines: list[str] = [
        "# Swarm Review Summary",
        "",
        f"- Provider: `{PROVIDER}` / `{MODEL}`",
        f"- Prompt: `{PROMPT_SOURCE}`",
        f"- Files reviewed: {reviewed}",
        f"- Files with findings: {len(found)}",
        f"- Total findings: **P0={total_p0}  P1={total_p1}  P2={total_p2}**",
        "",
    ]
    for rel, body, p0, p1, p2 in found:
        lines.append(f"## `{rel}`  · P0={p0} P1={p1} P2={p2} · [details](by-file/{safe_name(rel)})")
        lines.append("")
        lines.append(body)
        lines.append("")
    OUT_DIR.mkdir(exist_ok=True)
    (OUT_DIR / "SUMMARY.md").write_text("\n".join(lines), encoding="utf-8")
    return total_p0, total_p1, total_p2


def write_findings(
    file_results: list[tuple[Path, str]], files_reviewed: int
) -> tuple[int, int, int]:
    """Persist (path, content) pairs then rebuild SUMMARY. Used by batch-collect
    (which has every result in memory at once, so no incremental kill risk)."""
    for path, out in file_results:
        if out == "No findings.":
            continue
        write_one_finding(_rel(path), out)
    return rebuild_summary(reviewed=files_reviewed)


# ─── Batch flow (Groq async batches: 50% off, no TPM cap) ───────────────────

def _multipart_body(
    fields: dict[str, str],
    file_field: str,
    file_data: bytes,
    filename: str,
    file_content_type: str = "application/json",
) -> tuple[bytes, str]:
    """Encode a multipart/form-data body. Returns (body_bytes, content_type)."""
    boundary = "----swarm" + os.urandom(16).hex()
    crlf = b"\r\n"
    parts: list[bytes] = []
    for name, value in fields.items():
        parts.append(f"--{boundary}".encode())
        parts.append(f'Content-Disposition: form-data; name="{name}"'.encode())
        parts.append(b"")
        parts.append(value.encode())
    parts.append(f"--{boundary}".encode())
    parts.append(
        f'Content-Disposition: form-data; name="{file_field}"; filename="{filename}"'.encode()
    )
    parts.append(f"Content-Type: {file_content_type}".encode())
    parts.append(b"")
    parts.append(file_data)
    parts.append(f"--{boundary}--".encode())
    parts.append(b"")
    return crlf.join(parts), f"multipart/form-data; boundary={boundary}"


def _http(
    method: str,
    url: str,
    *,
    body: bytes | None = None,
    content_type: str | None = None,
    timeout: int = 120,
) -> tuple[int, bytes]:
    """Authenticated HTTP request returning (status_code, body). Doesn't raise
    on HTTP errors — caller inspects the code."""
    headers = {
        "Authorization": f"Bearer {API_KEY}",
        "User-Agent": USER_AGENT,
    }
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def _require_groq() -> None:
    if PROVIDER != "groq":
        sys.exit(
            f"batch mode is only implemented for REVIEW_PROVIDER=groq (got {PROVIDER}). "
            f"OpenRouter/DeepSeek don't expose a batch endpoint — use the sync path."
        )


def _format_age(created_at: float | None) -> str:
    if not created_at:
        return ""
    elapsed = time.time() - float(created_at)
    if elapsed < 3600:
        return f"{int(elapsed / 60)}m ago"
    if elapsed < 86400:
        return f"{elapsed / 3600:.1f}h ago"
    return f"{elapsed / 86400:.1f}d ago"


def submit_batch(files: list[Path]) -> int:
    """Build a JSONL of chat-completion requests, upload it, create the batch,
    save local state so collect can run from another shell / day."""
    _require_groq()
    BATCH_STATE_DIR.mkdir(exist_ok=True)

    lines: list[str] = []
    custom_id_to_path: dict[str, str] = {}
    skipped: list[Path] = []
    for i, path in enumerate(files):
        body_dict = build_chat_body(path)
        if body_dict is None:
            skipped.append(path)
            continue
        custom_id = f"req_{i}"
        custom_id_to_path[custom_id] = str(_rel(path))
        lines.append(json.dumps({
            "custom_id": custom_id,
            "method": "POST",
            "url": "/v1/chat/completions",
            "body": body_dict,
        }))

    if not lines:
        print("nothing to submit (all files unreadable or too large)")
        return 1

    jsonl = ("\n".join(lines) + "\n").encode("utf-8")
    print(f"Repo:     {REPO_ROOT}")
    print(f"Provider: {PROVIDER}")
    print(f"Model:    {MODEL}")
    print(f"Prompt:   {PROMPT_SOURCE}")
    print(f"Building: {len(lines)} request(s), {len(jsonl) / 1024:.1f} KB JSONL")
    if skipped:
        print(f"          (skipped {len(skipped)} unreadable/oversized)")

    # 1. Upload the JSONL.
    print("Uploading input file...")
    body, content_type = _multipart_body(
        fields={"purpose": "batch"},
        file_field="file",
        file_data=jsonl,
        filename="batch.jsonl",
    )
    code, resp = _http("POST", f"{BATCH_API_BASE}/files",
                       body=body, content_type=content_type, timeout=300)
    if code not in (200, 201):
        sys.exit(f"file upload failed: HTTP {code}: {resp[:600].decode(errors='replace')}")
    file_info = json.loads(resp)
    input_file_id = file_info["id"]
    print(f"  → file_id={input_file_id}")

    # 2. Create the batch.
    print("Creating batch job...")
    batch_req = json.dumps({
        "input_file_id": input_file_id,
        "endpoint": "/v1/chat/completions",
        "completion_window": "24h",
    }).encode("utf-8")
    code, resp = _http("POST", f"{BATCH_API_BASE}/batches",
                       body=batch_req, content_type="application/json")
    if code not in (200, 201):
        sys.exit(f"batch create failed: HTTP {code}: {resp[:600].decode(errors='replace')}")
    batch = json.loads(resp)
    batch_id = batch["id"]

    # 3. Save local state — collect needs the custom_id → path map.
    state = {
        "batch_id": batch_id,
        "input_file_id": input_file_id,
        "model": MODEL,
        "provider": PROVIDER,
        "submitted_at": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime()),
        "custom_id_to_path": custom_id_to_path,
    }
    state_file = BATCH_STATE_DIR / f"{batch_id}.json"
    state_file.write_text(json.dumps(state, indent=2), encoding="utf-8")

    print()
    print(f"✓ Submitted batch_id={batch_id}")
    print(f"  State:   {state_file.relative_to(REPO_ROOT)}")
    print(f"  Status:  {SCRIPT_HINT} --batch-status {batch_id}")
    print(f"  Collect: {SCRIPT_HINT} --batch-collect {batch_id}")
    return 0


def batch_status(batch_id: str) -> int:
    _require_groq()
    code, resp = _http("GET", f"{BATCH_API_BASE}/batches/{batch_id}")
    if code != 200:
        sys.exit(f"status fetch failed: HTTP {code}: {resp[:600].decode(errors='replace')}")
    info = json.loads(resp)
    rc = info.get("request_counts") or {}
    age = _format_age(info.get("created_at"))
    print(f"batch_id: {batch_id}")
    print(f"status:   {info.get('status', '?')}" + (f"  ·  started {age}" if age else ""))
    print(f"progress: {rc.get('completed', 0)}/{rc.get('total', 0)} complete"
          + (f", {rc.get('failed', 0)} failed" if rc.get('failed') else ""))
    if info.get("status") == "completed":
        print(f"output:   ready  →  {SCRIPT_HINT} --batch-collect {batch_id}")
    elif info.get("status") in ("failed", "expired", "cancelled"):
        errs = info.get("errors") or info.get("error")
        if errs:
            print(f"error:    {errs}")
    return 0


def batch_collect(batch_id: str) -> int:
    _require_groq()
    state_file = BATCH_STATE_DIR / f"{batch_id}.json"
    if not state_file.exists():
        sys.exit(
            f"no local state for {batch_id} at {state_file.relative_to(REPO_ROOT)}\n"
            f"(submitted from another machine? you'd need its state file to map "
            f"custom_ids back to source paths)"
        )
    state = json.loads(state_file.read_text(encoding="utf-8"))
    custom_id_to_path: dict[str, str] = state["custom_id_to_path"]
    expected_total = len(custom_id_to_path)

    code, resp = _http("GET", f"{BATCH_API_BASE}/batches/{batch_id}")
    if code != 200:
        sys.exit(f"status fetch failed: HTTP {code}: {resp[:600].decode(errors='replace')}")
    info = json.loads(resp)
    status = info.get("status")
    if status != "completed":
        sys.exit(f"batch not ready (status={status}). Run --batch-status to see progress.")
    output_file_id = info.get("output_file_id")
    if not output_file_id:
        sys.exit(f"batch completed but has no output_file_id; raw: {info}")

    print(f"Fetching output file {output_file_id}...")
    code, resp = _http("GET", f"{BATCH_API_BASE}/files/{output_file_id}/content", timeout=600)
    if code != 200:
        sys.exit(f"output fetch failed: HTTP {code}: {resp[:600].decode(errors='replace')}")

    file_results: list[tuple[Path, str]] = []
    errors: list[tuple[str, object]] = []
    for line in resp.decode("utf-8").splitlines():
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        custom_id = obj.get("custom_id")
        rel_path = custom_id_to_path.get(custom_id)
        if not rel_path:
            continue
        path = REPO_ROOT / rel_path
        response = obj.get("response") or {}
        err = obj.get("error")
        if err or response.get("status_code") != 200:
            errors.append((rel_path, err or response.get("status_code")))
            continue
        body = response.get("body") or {}
        try:
            content = body["choices"][0]["message"]["content"]
            content = content.strip() if content is not None else None
        except (KeyError, IndexError, TypeError):
            content = None
        if content is None:
            errors.append((rel_path, "null/malformed content"))
            continue
        file_results.append((path, content))

    if errors:
        print(f"  {len(errors)} request(s) errored (first: {errors[0]})")

    print(f"Writing findings for {len(file_results)} result(s)...")
    p0, p1, p2 = write_findings(file_results, files_reviewed=expected_total)
    print()
    print(f"Done. Summary: {(OUT_DIR / 'SUMMARY.md').relative_to(REPO_ROOT)}")
    print(f"      Totals: P0={p0}  P1={p1}  P2={p2}")
    return 0


# ─── Sync flow ──────────────────────────────────────────────────────────────

def run_sync(files: list[Path], resume: bool = False, agentic: bool = False) -> int:
    worker = agentic_review_one if agentic else review_one
    current_head = _repo_head()
    if resume:
        already = completed_paths()
        prior_head = _progress_head()
        if already and prior_head and current_head and prior_head != current_head:
            print(f"⚠ resume: progress was recorded at HEAD {prior_head[:8]} but you're "
                  f"now at {current_head[:8]} — the already-done list may not match the "
                  f"current file contents. Delete review-findings/ for a clean pass.")
        if already:
            before = len(files)
            files = [f for f in files if str(_rel(f)) not in already]
            print(f"Resuming: {len(already)} file(s) already done, "
                  f"{len(files)} of {before} remaining")
    else:
        # Fresh run: reset the done-set so a stale log from an earlier run on a
        # different file set / commit can't silently skip files. by-file/ is
        # left in place (overwritten per file); delete review-findings/ for a
        # fully clean slate.
        PROGRESS_PATH.unlink(missing_ok=True)
        if current_head:
            _write_progress_head(current_head)

    print(f"Repo:        {REPO_ROOT}")
    print(f"Provider:    {PROVIDER}")
    print(f"Model:       {MODEL}")
    print(f"Prompt:      {PROMPT_SOURCE}")
    print(f"Mode:        {'agentic (grep/read tools, multi-turn — higher cost)' if agentic else 'single-shot'}")
    print(f"Limits:      ≤{RPM} req/min, ≤{CONCURRENT} concurrent")
    print(f"Reviewing:   {len(files)} file(s)")
    print()

    if not files:
        rebuild_summary()
        print("nothing to do (all files already reviewed — run --rebuild-summary to refresh SUMMARY)")
        return 0

    limiter = RateLimiter(RPM)
    done = 0

    # Findings and the progress log are written incrementally as each file
    # completes, so a killed run keeps everything done so far — re-run with
    # --resume to continue. SUMMARY is rebuilt from disk at the end.
    with ThreadPoolExecutor(max_workers=CONCURRENT) as ex:
        futs = {ex.submit(worker, f, limiter): f for f in files}
        for fut in as_completed(futs):
            path, out, err = fut.result()
            done += 1
            rel = _rel(path)
            tag = f"[{done:>3}/{len(files)}]"
            if err:
                print(f"  {tag} ERR    {rel}  ({err})")
                log_progress(rel, "err", err)
                continue
            if out is None:
                print(f"  {tag} ERR    {rel}  (empty response, no error)")
                log_progress(rel, "err", "empty response")
                continue
            if out == "No findings.":
                print(f"  {tag} clean  {rel}")
                log_progress(rel, "clean")
                continue
            p0, p1, p2 = _counts(out)
            write_one_finding(rel, out)
            log_progress(rel, "found")
            print(f"  {tag} FOUND  {rel}  P0={p0} P1={p1} P2={p2}")

    total_p0, total_p1, total_p2 = rebuild_summary()
    print()
    print(f"Done. Summary: {(OUT_DIR / 'SUMMARY.md').relative_to(REPO_ROOT)}")
    print(f"      Totals: P0={total_p0}  P1={total_p1}  P2={total_p2}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("files", nargs="*", help="explicit files to review")
    ap.add_argument("--vs", metavar="BRANCH", help="also include diff vs this branch")
    ap.add_argument("--all", action="store_true",
                    help="review every source file in the repo (by --ext)")
    ap.add_argument("--ext", metavar="LIST",
                    help="comma-separated extensions to review (default: broad source set)")
    ap.add_argument("--resume", action="store_true",
                    help="skip files already recorded in review-findings/.progress.jsonl "
                         "(continue a run the harness killed)")
    ap.add_argument("--agentic", action="store_true",
                    help="per-file reviewer gets read-only grep/read_file/list_files tools "
                         "to verify cross-file facts before reporting (multi-turn, slower, "
                         "higher cost, far fewer false positives)")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument(
        "--batch", action="store_true",
        help="submit as a Groq async batch (50%% cheaper, sidesteps TPM cap, "
             "completes within 24h SLA — use --batch-status / --batch-collect afterwards)"
    )
    mode.add_argument(
        "--batch-status", metavar="BATCH_ID",
        help="check status of a previously-submitted batch"
    )
    mode.add_argument(
        "--batch-collect", metavar="BATCH_ID",
        help="fetch results of a completed batch and write findings"
    )
    mode.add_argument(
        "--rebuild-summary", action="store_true",
        help="regenerate SUMMARY.md from review-findings/by-file/ on disk "
             "(recover the summary after a killed run; no API calls)"
    )
    args = ap.parse_args()

    if args.ext:
        global EXTS
        EXTS = _parse_exts(args.ext)

    if args.rebuild_summary:
        p0, p1, p2 = rebuild_summary()
        print(f"Rebuilt {(OUT_DIR / 'SUMMARY.md').relative_to(REPO_ROOT)} "
              f"— P0={p0} P1={p1} P2={p2}")
        return 0
    if args.batch_status:
        return batch_status(args.batch_status)
    if args.batch_collect:
        return batch_collect(args.batch_collect)

    if args.all:
        files = all_source_files()
    elif args.files:
        files = [Path(f).resolve() for f in args.files]
    else:
        if not _in_git_repo():
            print(f"not inside a git repo (cwd={Path.cwd()}). "
                  f"Pass files explicitly, use --all, or cd into a repo.")
            return 1
        files = changed_files(args.vs)

    files = [f for f in files if f.exists()]

    # Drop anything outside the repo root: a repo-scoped review of an
    # out-of-tree file is meaningless, and the diagnostic below tells the
    # user which files were dropped. (Display/naming sites use _rel(), so
    # an out-of-tree path no longer crashes even if one slips through.)
    in_repo: list[Path] = []
    outside: list[Path] = []
    for f in files:
        try:
            f.relative_to(REPO_ROOT)
            in_repo.append(f)
        except ValueError:
            outside.append(f)
    if outside:
        print(f"skipping {len(outside)} file(s) outside the repo root ({REPO_ROOT}):")
        for f in outside[:5]:
            print(f"  {f}")
        if len(outside) > 5:
            print(f"  …and {len(outside) - 5} more")
    files = in_repo

    if not files:
        print("no matching files to review "
              f"(exts: {', '.join(sorted(EXTS))})")
        return 0

    if args.batch:
        if args.agentic:
            print("--agentic is sync-only (batch can't run a tool loop); ignoring --batch")
        else:
            return submit_batch(files)
    return run_sync(files, resume=args.resume, agentic=args.agentic)


if __name__ == "__main__":
    sys.exit(main())
