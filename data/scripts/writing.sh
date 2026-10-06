#!/usr/bin/env bash
# Prepare the current folder for ARIS (Auto-Research-In-Sleep): clone the skill
# repo once, symlink its skills into .claude/skills/ so `claude` exposes
# /research-pipeline, /paper-writing, …, and repoint Claude Code at the custom
# provider for THIS folder only.
# https://github.com/wanshuiyin/auto-claude-code-research-in-sleep
#
# The Codex MCP reviewer that the cross-model review skills want is a global,
# one-time step — printed at the end, never run from here.
#
# Nix-injected environment: JQ, CUSTOM_URL, CUSTOM_TOKEN, MAIN_MODEL,
# SMALL_MODEL (see modules/wrappers.nix). The defaults below keep the script
# runnable by hand.
set -euo pipefail

: "${JQ:=jq}"
: "${CUSTOM_URL:=https://llm.naidanov.ru}"
: "${MAIN_MODEL:=deepseek-v4-flash}"
: "${SMALL_MODEL:=qwen3-coder-next}"

REPO="${ARIS_REPO:-$HOME/aris_repo}"
URL="https://github.com/wanshuiyin/Auto-claude-code-research-in-sleep.git"

# 1. Ensure the ARIS repo exists in a stable location (clone once).
#    Bounded by `timeout` + --progress so a flaky/proxied network can't make
#    the clone hang silently; point at the 'proxy' toggle on failure.
if [ ! -d "$REPO/.git" ]; then
  echo "› Cloning ARIS → $REPO"
  if ! timeout 180 git clone --progress --depth 1 "$URL" "$REPO"; then
    echo "✗ Clone failed or timed out."
    echo "  GitHub may need a proxy — run 'proxy' to enable it, then retry 'writing'."
    exit 1
  fi
else
  echo "› Updating ARIS ($REPO)"
  git -C "$REPO" pull --ff-only 2>/dev/null || echo "  (could not update — continuing with the local copy)"
fi

# 2. Install ARIS skills into this folder (.claude/skills/<name> symlinks).
#    The installer prompts "Apply these N changes?" — feed 'y' so `writing` is
#    one-shot. Its safety rules *abort* (never prompt) on real conflicts, so
#    auto-confirming the apply gate is safe. Finite printf => no SIGPIPE under
#    pipefail.
echo "› Installing ARIS skills into: $PWD"
printf 'y\ny\ny\ny\n' | bash "$REPO/tools/install_aris.sh" "$PWD"

# Verify skills actually landed (the installer returns 0 even on user-abort, so
# an empty result would otherwise look like success).
skills_dir="$PWD/.claude/skills"
if [ ! -d "$skills_dir" ] || [ -z "$(ls -A "$skills_dir" 2>/dev/null)" ]; then
  echo "✗ No ARIS skills were linked into $skills_dir"
  exit 1
fi
echo "› $(ls -1 "$skills_dir" | wc -l | tr -d ' ') skill(s) linked into $skills_dir"

# 3. Repoint Claude Code at the custom provider for THIS folder only, by
#    merging an env block into .claude/settings.local.json. That file sits below
#    the immutable managed-settings.json but ABOVE the global exports from
#    .zshrc, so it cleanly overrides ANTHROPIC_BASE_URL, the token (both
#    AUTH_TOKEN and API_KEY, so Claude's auth-precedence can't pick a stale
#    value) and the model tiers. jq merges so existing keys (permissions, …)
#    survive; the token is read fresh and the file is written mode-0600.
#    NOTE: managed-settings.json locks CLAUDE_CODE_SUBAGENT_MODEL
#    system-wide, so subagents keep the global model — change
#    agent.claudeCode.smallModel in the host's HM config if the custom endpoint
#    rejects the global id.
sfile="$PWD/.claude/settings.local.json"
mkdir -p "$PWD/.claude"
if [ -z "${CUSTOM_TOKEN:-}" ]; then
  echo "✗ Custom provider token unavailable (${CUSTOM_TOKEN_SOURCE:-AGENT_CUSTOM_TOKEN})"
  echo "  Export it, or provision the agenix 'custom-token' secret on NixOS, then re-run 'writing'."
  exit 1
fi
base="$(cat "$sfile" 2>/dev/null || echo '{}')"
"$JQ" -e . >/dev/null 2>&1 <<<"$base" || base='{}'
merged="$("$JQ" --arg url "$CUSTOM_URL" --arg key "$CUSTOM_TOKEN" --arg m "$MAIN_MODEL" --arg h "$SMALL_MODEL" \
  '.env = ((.env // {}) + {
     "ANTHROPIC_BASE_URL": $url,
     "ANTHROPIC_AUTH_TOKEN": $key,
     "ANTHROPIC_API_KEY": $key,
     "ANTHROPIC_DEFAULT_OPUS_MODEL": $m,
     "ANTHROPIC_DEFAULT_SONNET_MODEL": $m,
     "ANTHROPIC_DEFAULT_HAIKU_MODEL": $h
   })' <<<"$base")"
( umask 077; printf '%s\n' "$merged" > "$sfile" )
chmod 600 "$sfile" # umask only governs creation; clamp a pre-existing file too
echo "› Claude → custom provider ($CUSTOM_URL, opus/sonnet=$MAIN_MODEL, haiku=$SMALL_MODEL) via $sfile"

# 4. Cross-model review skills need the Codex MCP reviewer — a global,
#    one-time step. Print it; don't mutate ~/.claude.json from here.
echo ""
echo "✅ ARIS ready in this folder (Claude → $CUSTOM_URL). Next: run  claude"
echo "   then try a workflow, e.g.:"
echo '     /research-pipeline "your research direction"'
echo '     /paper-writing "NARRATIVE_REPORT.md"'
if command -v codex >/dev/null 2>&1; then
  echo ""
  echo "💡 Codex is installed — enable review skills (run once):"
  echo "     claude mcp add codex -s user -- codex mcp-server"
else
  echo ""
  echo "💡 For review skills, install Codex and add it as an MCP server:"
  echo "     npm i -g @openai/codex && claude mcp add codex -s user -- codex mcp-server"
fi