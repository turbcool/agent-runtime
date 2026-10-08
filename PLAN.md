# Profiles + cc-switch cutover — plan

Goal: `profile <name>` / `provider <name>` shell commands that activate a bundle of
tools across claude / opencode / pi, backed by cc-switch-cli (nixpkgs) as the
runtime owner of live config files, with the agent-runtime flake remaining the
*declarative compiler* (registries + providers + skills stay in Nix).

## What cc-switch-cli actually does (verified, v5.10.5)

- `cc-switch --app <app> provider add --id X --name N --config-file <json>` — **non-interactive**,
  `--config-file` is parse-only (no key validation). Confirmed key-less claude
  records are accepted; `{file:…}`/`!cat`/`!printenv` expressions are stored
  verbatim and NOT evaluated by cc-switch.
- `--app` accepts `claude`, `codex`, `gemini`, `open-code`, `hermes`, `open-claw`, `pi`.
- MCP is written per app; `--app pi mcp …` **errors: "does not support pi"** —
  `services/mcp.rs` arms `AppType::Pi => {}` are no-ops, `pi_config/` has no
  mcp.json path. → pi `mcp.json` stays the runtime's.
- `provider` writes: claude `~/.claude/settings.json` (env+model), opencode
  `~/.config/opencode/opencode.json` (provider/mcp are read-modify-written,
  unknown keys preserved), pi `~/.pi/agent/models.json` (additive providers,
  **with optimistic revision lock** — two concurrent writers fail).
- `provider add` for pi does NOT touch `defaultProvider`/`defaultModel` —
  `pi_config/mod.rs:3`: *"Pi owns account login and the active provider/model in
  settings.json. CC Switch only manages explicit provider entries in
  models.json."*
- Claude Code: `settings.json.env` **beats** the process environment (verified —
  sending `${FOO}` literal; not expanded; and a process env key is overridden by
  the settings.json key). Keys are NEVER expanded.

## Ownership (final)

| artifact | owner |
|---|---|
| `~/.cc-switch/cc-switch.db` | cc-switch |
| claude `~/.claude/settings.json` (env/model) + `~/.claude.json` (mcpServers) | cc-switch |
| /etc/claude-code/managed-settings.json (plugins, immutable) | Nix |
| `~/.config/opencode/opencode.json` (provider/mcp/model) | cc-switch |
| opencode static: permission/plugin/compaction/agent.explore/small_model | Nix, via `OPENCODE_CONFIG` store file + `opencode` wrapper |
| `~/.pi/agent/models.json` (providers) | cc-switch |
| `~/.pi/agent/settings.json` (defaultProvider/defaultModel/packages/enabledModels) | **runtime** (cc-switch won't write defaults) |
| `~/.pi/agent/mcp.json` (servers) | **runtime** (cc-switch has no pi MCP writer) |
| `~/.claude/skills`, `~/.config/opencode/skills`, `~/.pi/agent/skills` | cc-switch SSOT |
| `.agents/skills` (cross-vendor; cc-switch ignores) | runtime / agent-skills |

## `provider` verb map (verified V3/V4)

`provider set-default` only works for Hermes/OpenClaw (errors otherwise). Use:

- `cc-switch --app claude provider switch <id>` → writes `env.*` + `model` to
  `~/.claude/settings.json` (key-less; runtime wrapper supplies the agenix key).
- `cc-switch --app open-code provider switch <id>` → writes the provider node
  into global `~/.config/opencode/opencode.json` (all providers pre-seeded).
  **Default `model` is owned by the runtime**: a user-owned `OPENCODE_CONFIG`
  overlay (higher precedence than global opencode.json) holds `model`/`small_model`,
  so `provider N` rewrites that overlay to `N/<model>`. No contention (cc-switch
  doesn't touch model; we don't touch provider/mcp).
- pi: cc-switch only manages `models.json`; runtime writes
  `~/.pi/agent/settings.json` (`defaultProvider`/`defaultModel`).

cc-switch **does not** write a default `model` for opencode (verified: opencode.json
has no `model` key after `provider switch`) and `provider current` is a no-op for
opencode — so opencode model switching is the runtime's `provider` command.

## Token strategy for claude

`ANTHROPIC_API_KEY` is **omitted** from cc-switch's claude provider record and
injected at launch by the runtime `claude` wrapper, reading the declared provider
from `~/.local/state/agent-runtime/provider` and sourcing
`/run/agenix/<provider>-token` only for the bakery ids. Reason: settings.json.env
wins over the shell env and is never expanded, so any key cc-switch writes would
freeze the provider's key in plaintext. This keeps the agenix invariant (key never
on disk, never in the DB).

## Files (diff plan)

- `data/profiles.nix` — `base` + `work` profiles (`extends`-based). (NEW)
- `lib/ccswitch.nix` — `renderProvider app name p`, `resolveProfile profiles name`,
  `expandMcp mcpReg names`. (NEW, pure)
- `modules/ccswitch.nix` — shims `profile`/`provider`, seed activation, provider
  + profile shard farms; `mkIf agent.ccSwitch.enable`. (NEW)
- `modules/options.nix` — `agent.profiles`, `agent.ccSwitch.{enable,package,profileShards}`. (ADD)
- `modules/home.nix` — import `./ccswitch.nix`. (ADD)
- `flake.nix` — `lib.data.profiles` + `.ccswitch`; `checks.profiles-resolve`. (ADD)
- `/etc/nixos` host: `agent.ccSwitch.enable = true;`; remove the plaintext
  `ANTHROPIC_*` exports from `~/.zshrc`. (host-side, post-PR2)
- delete: `mcp` command, `claudeCode.commands` env wiring, `claudeMcpConfig`,
  opencode provider block in `modules/home.nix`. (PR3)

## Activation (converges)

Seed once (`~/.local/state/agent-runtime/ccswitch-seeded` marker), then: write
pi settings.json + `.agents/skills` + OPENCODE_CONFIG + managed-settings + npm;
seed providers/MCP/skills into cc-switch; apply declared profile/provider from
state. Rebuild twice = no diff.

## Open questions for PR2

- `skills import-from-apps` on agent-skills symlink trees: does cc-switch copy
  store paths into `~/.cc-switch/skills/` (breaks GC safety) or symlink?
- `provider add --id X` when X exists: confirmed error-prone → seed uses
  content-hash replace, not blind add.
- `~/.zshrc` plaintext key must be removed before cutover (it currently leaks
  into every child process incl. MCP servers).
