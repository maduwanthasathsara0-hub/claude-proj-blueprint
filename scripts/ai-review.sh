#!/bin/bash
# AI-powered code review via Claude API (Sonnet)
# Called by pre-commit-review.sh in hybrid/deep mode.
#
# Sends the staged diff to Claude API for intelligent analysis.
# Returns warnings only — never blocks (bash checks handle blocking).
#
# Requires: ANTHROPIC_API_KEY in environment or .env file
# Model: configurable via AI_REVIEW_MODEL (default: claude-sonnet-4-20250514)

set -euo pipefail

# ─── Config ─────────────────────────────────────────────────
AI_REVIEW_MODEL="${AI_REVIEW_MODEL:-claude-sonnet-4-20250514}"
AI_REVIEW_MAX_TOKENS="${AI_REVIEW_MAX_TOKENS:-500}"
AI_REVIEW_MAX_DIFF_LINES="${AI_REVIEW_MAX_DIFF_LINES:-300}"

# ─── Resolve API key ────────────────────────────────────────
# Search order: env var → project .env → home .env → home .anthropic
API_KEY="${ANTHROPIC_API_KEY:-}"

if [ -z "$API_KEY" ]; then
  for env_file in ".env" "$HOME/.env" "$HOME/.anthropic/.env" "$HOME/.config/anthropic/.env"; do
    if [ -f "$env_file" ]; then
      CANDIDATE=$(grep '^ANTHROPIC_API_KEY=' "$env_file" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
      if [ -n "$CANDIDATE" ]; then
        API_KEY="$CANDIDATE"
        break
      fi
    fi
  done
fi

if [ -z "$API_KEY" ]; then
  echo "⚠️  AI Review: ANTHROPIC_API_KEY not found"
  echo "   Set it in: .env, ~/.env, or export ANTHROPIC_API_KEY=sk-..."
  exit 0
fi

# ─── Get staged diff ────────────────────────────────────────
DIFF=$(git diff --cached --diff-filter=ACMR -- '*.ts' '*.py' '*.go' '*.rs' '*.js' '*.tsx' '*.jsx' | head -n "$AI_REVIEW_MAX_DIFF_LINES")

if [ -z "$DIFF" ]; then
  echo "✅ AI Review: no diff to analyze"
  exit 0
fi

# ─── Project context ────────────────────────────────────────
PROJECT_CONTEXT=""
if [ -f ".claude/skills/code-review/SKILL.md" ]; then
  PROJECT_CONTEXT=$(head -40 .claude/skills/code-review/SKILL.md)
fi

# ─── Export vars for Python ─────────────────────────────────
export API_KEY
export AI_REVIEW_MODEL
export AI_REVIEW_MAX_TOKENS
export REVIEW_DIFF="$DIFF"
export PROJECT_CONTEXT

# ─── Call Claude API via Python (handles JSON escaping safely) ──
AI_OUTPUT=$(python3 << 'PYEOF'
import json, sys, os, urllib.request, urllib.error

api_key = os.environ.get("API_KEY", "")
model = os.environ.get("AI_REVIEW_MODEL", "claude-sonnet-4-20250514")
max_tokens = int(os.environ.get("AI_REVIEW_MAX_TOKENS", "500"))
diff = os.environ.get("REVIEW_DIFF", "")
project_context = os.environ.get("PROJECT_CONTEXT", "")

if not api_key or not diff:
    print("⚠️  AI Review: missing API key or diff — skipping")
    sys.exit(0)

system_prompt = f"""You are a code reviewer. Analyze the git diff and report issues.

Rules:
- Only report real, actionable issues — no generic advice
- Focus on: logic bugs, edge cases, missing error handling, security risks, business logic errors
- Do NOT report style/formatting issues (linter handles those)
- Do NOT report missing tests (bash check handles that)
- Do NOT report compilation errors (tsc handles that)
- Be concise: max 3-5 findings, one line each
- If the diff looks clean, just say 'No issues found'

{project_context}Output format (one per line):
⚠️ SHOULD FIX [file]: description
ℹ️ CONSIDER [file]: description"""

payload = json.dumps({
    "model": model,
    "max_tokens": max_tokens,
    "system": system_prompt,
    "messages": [{"role": "user", "content": f"Review this staged diff:\n\n{diff}"}]
}).encode("utf-8")

req = urllib.request.Request(
    "https://api.anthropic.com/v1/messages",
    data=payload,
    headers={
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
    },
)

try:
    with urllib.request.urlopen(req, timeout=25) as resp:
        data = json.loads(resp.read().decode("utf-8"))
        if "content" in data and len(data["content"]) > 0:
            print(data["content"][0]["text"])
        else:
            print("⚠️  AI Review: empty response")
except urllib.error.HTTPError as e:
    body = e.read().decode("utf-8", errors="replace")
    try:
        err = json.loads(body)
        print(f"⚠️  AI Review: API error — {err.get('error', {}).get('message', body[:100])}")
    except Exception:
        print(f"⚠️  AI Review: HTTP {e.code}")
except Exception as e:
    print(f"⚠️  AI Review: {e}")
PYEOF
) || true

if [ -z "$AI_OUTPUT" ]; then
  echo "⚠️  AI Review: no output — skipping"
  exit 0
fi

# ─── Output ─────────────────────────────────────────────────
echo "$AI_OUTPUT"

# AI review never blocks — exit 0 always
exit 0
