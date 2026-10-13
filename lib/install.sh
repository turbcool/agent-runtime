#!/usr/bin/env bash
# Standalone container / non-NixOS installer.
#
# `nix run github:turbcool/agent-runtime#install` (or `#agent-runtime-install`)
# links the bundle onto PATH, copies the rendered ~/.pi + opencode config onto
# the writable $HOME, seeds the npm packages the agents expect, and reports
# missing tokens. Uses `pkgs.substitute` (`--replace`, not var expansion) so
# the script's bash `${...}` (including `${!VAR:-}`) is never touched.
#
# $1 (optional) overrides the install dir; default $HOME/.local/bin.
#
# Air-gapped machines must copy the `#agent-runtime` and `#agent-runtime-config`
# outputs in by hand first (this script assumes it can reach the npm registry
# for bladebro / donsetch, or that they are already present).
set -euo pipefail

binDir="${1:-$HOME/.local/bin}"

src="@agentRuntime@"
cfg="@agentRuntimeConfig@"

mkdir -p "$binDir"
cp -rPn "$src/bin/"* "$binDir"/

# The config farm is a linkFarm of read-only store paths; make it writable
# where the agents expect to mutate ($HOME/.pi/.../sessions, opencode.json).
# "$cfg/." and not "$cfg/": with a trailing slash cp copies the farm directory
# itself into $HOME and leaves none of its contents where the agents look.
cp -rLn "$cfg/." "$HOME"
chmod -R u+w "$HOME/.pi" "$HOME/.config/opencode" 2>/dev/null || true

# pi/npm seed declared packages at startup; the two npm MCP servers are not Nix
# packages and have no other install step, so do it here if npm is present.
# --allow-scripts is not optional: npm 11 gates lifecycle scripts by default and
# both servers download their platform binary in postinstall, so without it you
# get two wrappers with no binary behind them (and npm skips the scripts of an
# already-installed package, so a later repair run does not help either).
if command -v npm >/dev/null 2>&1; then
  npmServers="donsetch bladebro"
  npm install --prefix "$HOME/.npm" -g \
    --allow-scripts="$(echo $npmServers | tr ' ' ',')" $npmServers || true
fi

missed=""
for v in AGENT_NEOPLATFORM_TOKEN AGENT_CUSTOM_TOKEN AGENT_FREE_TOKEN; do
  [ -n "${!v:-}" ] || missed="$missed $v"
done

echo "✓ agent-runtime installed to $binDir"
echo "✓ config copied to $HOME"
[ -z "$missed" ] && echo "✓ tokens present" || echo "✗ missing tokens:$missed  (export them before running an agent)"
