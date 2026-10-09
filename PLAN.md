# Profiles as pre-rendered worlds — design + outcome

**Status: shipped.** This file records the design that replaced the cc-switch
cutover, and the cc-switch findings that motivated it (those stay useful as
evidence about how the agents actually read config).

## The architecture

A **profile** is a named, complete "world" of machine-wide state: one provider,
a set of MCP servers, a set of skill sources. `lib/worlds.nix` renders each
profile into a full snapshot of every machine-wide config file; `modules/worlds.nix`
bakes one directory per profile and ships `profile <name>`, which installs a
world by copying it.

```
data/profiles.nix ─┐
data/providers.nix ├─► lib/worlds.nix (pure) ─► one baked dir per profile ─► profile <name>
data/mcp.nix ──────┤                              ($WORLDS/<name>/…)          │  copies it into $HOME
merged skill srcs ─┘                                                        └─ and re-points the
                                                                                3 skill link-trees
```

Principles:

1. **One writer per file.** The world is the only thing that writes
   `opencode.json`, `~/.pi/agent/{models,settings,mcp,pi-fff}.json` and the
   skill trees. `modules/home.nix` force-writes none of them.
2. **Switching is a file copy, not a diff.** Installing the same world twice is
   byte-identical (verified), so activation converges by construction.
3. **Activation follows the user.** It re-installs the *active* world (read from
   `~/.local/state/agent-runtime/world`), falling back to `agent.defaultProfile`
   only on a fresh machine — a rebuild never resets a `profile` choice.
4. **No imperative DB in the write path.** No seed marker, no per-server
   `set-apps` loops, no state that can drift from the files.

### What a world owns — and what it deliberately doesn't

| Path | Owner |
|---|---|
| `~/.config/opencode/opencode.json` | the world (provider + model + static keys + MCP) |
| `~/.pi/agent/{models,settings,mcp,pi-fff}.json` | the world |
| `.agents/skills`, `.claude/skills`, `.config/opencode/skills` | the world (symlink trees of the profile's skill sources) |
| `/etc/claude-code/managed-settings.json` | NixOS (immutable Claude Code plugins) |
| `~/.claude.json`, `~/.claude/settings.json` | **user-owned** — claude is driven by the `claude` wrapper + `--mcp-config`, never a written settings file |
| per-project `opencode.json`, `.claude/settings.local.json` | user/project (the `mcp` command, `writing`) |

## Why not cc-switch-cli

cc-switch-cli 5.10.5 was researched and smoke-tested end-to-end before this
design. What the tests actually showed:

- `provider add --config-file` is parse-only (key-less records accepted) and
  never expands `!cat`/`{file:…}` token expressions — good.
- `provider switch <id>` writes the claude live config and adds the opencode
  provider node, but **never sets a default model for opencode**, and
  `provider set-default` errors for everything except Hermes/OpenClaw.
- cc-switch does not write pi's defaults (`pi_config/mod.rs`: *"Pi owns account
  login and the active provider/model in settings.json. CC Switch only manages
  explicit provider entries in models.json."*) and rejects MCP writes for pi
  (`--app pi mcp` → "does not support pi"; `AppType::Pi => {}`).
- pi's `models.json` writes take an optimistic revision lock — two writers race.

So driving it meant three permanent runtime-owned exceptions (key-less claude
records + a key-injecting wrapper, an `OPENCODE_CONFIG` overlay for opencode's
model, a jq-written pi `settings.json`) and left every file with two writers —
Home Manager force-managing some, cc-switch rewriting others. The renderer that
we needed anyway (`lib/worlds.nix`) makes cc-switch redundant in the write path,
so it was dropped rather than kept as a second source of truth.

(Claude Code precedence — `settings.json.env` beats the process env and is never
expanded — still holds, and is why `claude` is a wrapper: the world records the
provider, and the wrapper injects that provider's key from
`/run/agenix/<provider>-token` at launch. The key is never written anywhere.)

## The shipped profiles

| Profile | Provider | Skills | MCP |
|---|---|---|---|
| `work` (default) | `neoplatform` | `ponytail` (+5 `ponytail-*`), `archify`, `archify-review`, `i-have-adhd` | always-on npm set |
| `free` | `free` | same coding set | always-on npm set |
| `study` | `free` | — | always-on npm set (`donsetch` included) |

`donsetch` + `bladebro` (the npm MCP set) are in every world; ARIS research
skills stay per-project via `writing`.

Consumers add profiles with the usual merge — no module, no option plumbing:

```nix
agent.profiles = lib.data.profiles // {
  side = { provider = "free"; skills = [ "ponytail" ]; mcp = [ "nixos" ]; };
};
agent.defaultProfile = "side";
```

Bad provider/MCP names and `extends` cycles fail `checks.worlds-resolve`; a bad
skill source name fails an HM assertion — neither surfaces at a `profile` call.

## Files

- `lib/worlds.nix` — pure renderer (profile resolve, MCP expand, per-agent
  dialects, world assembly). (NEW)
- `data/profiles.nix` — the profile registry (`work`/`free`/`study`). (NEW)
- `modules/worlds.nix` — bake the worlds, ship `profile` + the profile-following
  `claude` wrapper + the install-on-activation hook. (NEW, replaces
  `modules/ccswitch.nix`)
- `modules/home.nix` — keeps only the per-project mcp farm, binaries and `writing`;
  no longer force-writes the world files.
- `modules/skills.nix` — registers the merged source catalog and the per-project
  `skills` installers, but no longer links the machine-wide trees (the world
  owns them), so each tree has one writer.
- `modules/options.nix` — `agent.profiles` + `agent.defaultProfile`; `ccSwitch.*`
  removed; `claudeCode.commands` is now the fixed helpers (`writing`).
- `flake.nix` — `lib.data.worlds`, `checks.worlds-resolve`.
- Deleted: `lib/ccswitch.nix`, `modules/ccswitch.nix`.