# agent-runtime

Declarative agent runtime: **pi + opencode + claude-code**, with LLM providers,
token wiring, MCP servers, bundled skills and Claude Code plugins. One module
pair, three consumers:

| Consumer | How it uses this flake |
|---|---|
| NixOS + Home Manager | `nixosModules.default` **alone** — it injects the home half itself |
| Standalone container | `nix profile install …#agent-runtime` (env-var tokens) |
| Any other HM setup | `homeModules.default` alone (tokens from the environment) |

Same modules everywhere, so a desktop login and a container image get byte-identical
`~/.pi` and `~/.config/opencode` trees — only the token *source* differs.

```nix
# NixOS + Home Manager (consumer side) — one import, that is the whole setup
inputs.agent-runtime.nixosModules.default   # agenix secrets, Claude Code managed
                                            # settings, npm + nix-ld, and it wires
                                            # the home half via home-manager.sharedModules
```

The NixOS module injects the Home Manager half through
`home-manager.sharedModules` + `home-manager.extraSpecialArgs.runtimeInputs`, so a
NixOS host writes **no** Home Manager code and never imports
`homeModules.default` itself. `nixosModules.default` is a plain path, so a host
that *also* imports `homeModules.default` for its own overrides still dedupes
cleanly instead of colliding. A non-NixOS consumer (plain HM, no
`home-manager` NixOS module) imports `homeModules.default` directly, because
there is no `sharedModules` to inject through.

**The flake ships no secrets and no absolute paths.** A container install needs
nothing but the binaries and `AGENT_*_TOKEN` env vars.

## Contents

- [Quick start](#quick-start)
- [Using the runtime](#using-the-runtime)
- [Providers](#providers)
- [Profiles](#profiles)
- [Skills](#skills)
- [Configuration options](#configuration-options)
- [What lands on disk](#what-lands-on-disk)
- [MCP servers](#mcp-servers)
- [Claude Code plugins](#claude-code-plugins)
- [Flake outputs](#flake-outputs)
- [Checks, dev, gotchas](#checks-dev-gotchas)

## Quick start

### Container / standalone

```bash
nix profile install github:turbcool/agent-runtime#agent-runtime             # pi, opencode, claude, profile, mcp, writing, skills
nix build github:turbcool/agent-runtime#agent-runtime-config                # rendered config + skill trees, for COPY in a Dockerfile
nix run github:turbcool/agent-runtime#install                               # one command: install binaries, copy config, seed npm, report missing tokens
nix develop github:turbcool/agent-runtime                                  # ad-hoc shell (jq, nixfmt, statix)
```

`#install` is the no-argument convenience wrapper (`lib/install.sh`): it links
the binaries, `cp -rL`s the config tree into `$HOME`, seeds the npm globals the
MCP servers need, and prints which `AGENT_*_TOKEN` env vars are still missing.
It substitutes the store paths at build time, so it needs no arguments.

`#agent-runtime` is a `buildEnv` of `agent.runtimePackages` — deliberately not
`home.packages`, because standalone HM folds its own baseline (man-db,
mime-support) into that list. `#agent-runtime-config` is a `linkFarm` of
`agent.runtimeFiles`; in a live container `cp -rL` it into `$HOME` and then
`chmod -R u+w` (store paths are read-only, and pi must be able to create
`~/.pi/agent/sessions`).

Export `AGENT_NEOPLATFORM_TOKEN`, `AGENT_CUSTOM_TOKEN`, `AGENT_FREE_TOKEN`
before running an agent.

### NixOS host

```nix
inputs.agent-runtime = {
  url = "github:turbcool/agent-runtime";
  inputs = { nixpkgs.follows = "nixpkgs"; home-manager.follows = "home-manager"; };
};

# imports — this single import is the whole NixOS setup
inputs.agent-runtime.nixosModules.default   # → agent.agenix*, agent.claudeCode.*,
                                            #   agent.skills.sources, npm + nix-ld,
                                            #   and it injects the home half

# host-only skills, merged into the runtime's own catalog
agent.skills.sources = { orca.path = "${inputs.orca-skills}/skills"; };

# provider .age ciphertexts: one directory covers the whole registry
agent.agenixDir = ../secrets;   # → ../secrets/<provider>-token.age per provider
# (or name them explicitly instead:)
# agent.agenixFiles = { neoplatform = ../secrets/neoplatform-token.age; };

# owner of the decrypted secrets; without it agenix defaults to root, which a
# desktop login cannot read
agent.agenixOwner = "turb";
```

Those tokens are then decrypted by agenix and every agent reads them from
`/run/agenix/<name>-token` — never from an environment variable, never from a
config file in the store.

### Input wiring: none

Skill sources and opencode plugins are addressed by *absolute path* out of this
flake's own lock (`data/skills.nix` takes a `runtimeInputs` argument closed over
by `flake.nix`), not by flake-input name. A consumer therefore declares no
inputs and writes no `follows` wiring for them — it just imports the module:

```nix
inputs.agent-runtime.homeModules.default;
```

## Using the runtime

For the person at the keyboard. Once the runtime is on `PATH` — a NixOS host, or
a container built from `#agent-runtime` — these are the commands and the choices.

### Commands

| Command | What it runs |
|---|---|
| `pi` | the pi coding agent (its wrapper hides pi's `web_crawl` tool) |
| `opencode` | the opencode agent |
| `claude` | Claude Code, pointed at **whatever provider the active profile selects** (its wrapper reads the active world and injects the env) |
| `profile <name>` | switch every agent at once to a named world (see [Profiles](#profiles)) |
| `writing` | Claude Code + `data/scripts/writing.sh` — merges the `custom` provider env into the project's `.claude/settings.local.json` and installs the ARIS research skills for that folder |
| `mcp <group\|server>` | merge a rendered MCP fragment into the **current project's** `opencode.json` (`mcp nixos`, `mcp frontend`) |
| `skills <source>` / `skills-install-<source>` | install a skill source into the current project |

### Choosing a provider

Three providers ship — `neoplatform`, `custom`, `free` ([full table](#providers)).
On NixOS their keys are decrypted to `/run/agenix/<id>-token`; in a container,
export `AGENT_NEOPLATFORM_TOKEN`, `AGENT_CUSTOM_TOKEN`, `AGENT_FREE_TOKEN`.

You normally pick one by **switching profile** (`profile work` → neoplatform,
`profile free`/`profile study` → free); the active profile's provider is applied
to claude, pi and opencode together, and the wrapper injects the matching key
from agenix at launch (never a key in a file). `writing` is the one command
pinned to `custom`, because it sets up a single folder for research writing.

## Profiles

A **profile** is a named, complete "world" of machine-wide state: one provider,
a set of MCP servers, and a set of skill sources. `data/profiles.nix` ships three:

| Profile | Provider | Skills | MCP |
|---|---|---|---|
| `work` | `neoplatform` | `ponytail` (+5 `ponytail-*`), `archify`, `archify-review`, `i-have-adhd` | always-on only |
| `free` | `free` | same coding set as `work` | always-on only |
| `study` | `free` | — (ARIS comes per-project via `writing`) | `donsetch` |

`profile <name>` installs that world into `$HOME` atomically — it copies the
pre-rendered config files and re-points the three skill link-trees — so all
three agents move together and a `nixos-rebuild` (which re-installs the *active*
world) never resets your choice. `donsetch` and `bladebro` (the npm MCP set) are
on in every world.

Add a profile by extending the registry (nothing else changes):

```nix
agent.profiles = lib.data.profiles // {
  side = { provider = "free"; skills = [ "ponytail" ]; mcp = [ "nixos" ]; };
};
agent.defaultProfile = "side";   # optional: what a fresh machine starts on
```

A profile naming a provider/mcp/skill that doesn't resolve fails
`checks.worlds-resolve` at build time (skills) or an HM assertion — never a
silent half-switch.

### What's always on

- **MCP** — `donsetch` (fetch/search/crawl) and `bladebro` (stealth browser) are
  wired into every agent in every world. The rest (`nixos`, `daisyui`, `svelte`,
  `lucide-icons`, and the `frontend` / `nixos` groups) is opt-in per project with
  `mcp <group|server>`.
- **Skills** — the runtime ships `archify`, `archify-review`, `i-have-adhd`,
  `qmd`, `ponytail` + five `ponytail-*`; a profile selects which of them are
  machine-wide. `skills <source>` installs any source into a project on top.

## Providers

`data/providers.nix` is the registry. Every entry is an OpenAI-compatible proxy
with one URL; `claudeModel` is that endpoint's model pair in Claude Code's own
dialect, which is served from the same base minus a trailing `/v1`.

| Provider | Endpoint | Token env var | Models (context / max output) |
|---|---|---|---|
| `neoplatform` | `https://llm.neoplatform.ru` | `AGENT_NEOPLATFORM_TOKEN` | `deepseek-v4-flash` (200k/32k), `gemma-4-31b-it` (200k/32k), `qwen3-coder-128k:30b` (128k/32k) |
| `custom` | `https://llm.naidanov.ru` | `AGENT_CUSTOM_TOKEN` | `deepseek-v4-flash` (200k/32k), `deepseek-v4-flash-direct` (200k/32k), `qwen3-coder-next` (128k/32k) |
| `free` | `https://llm-free.naidanov.ru/v1` | `AGENT_FREE_TOKEN` | `main` (256k/32k), `muse-spark-1.3-contributor` (128k/32k) |

A provider is:

```nix
{
  url = "https://…";            # OpenAI-compatible base; "/v1" is normalised away
  claudeModel = { main = "…"; small = "…"; };  # this endpoint's Claude Code tiers
  models.<id> = { name = "…"; limit.context = 200000; limit.output = 32000; };
  tokenSource = { env = "AGENT_X_TOKEN"; };   # the declaration; see below
}
```

Every model states its limits: pi reads them straight through and opencode
copies them, so a missing one is a mistake rather than a default. `claudeModel`
ids need not appear in `models` — they are the Anthropic endpoint's own names
(`small` on the free endpoint is one), which is why only `agent.defaultModel` /
`agent.smallModel` are asserted against the catalogue.

Override the registry wholesale rather than patching the data file:

```nix
agent.providers = (import <agent-runtime>/data/providers.nix) // {
  myproxy = { url = "https://…"; tokenSource.env = "AGENT_MYPROXY_TOKEN"; };
};
```

### Token resolution

One field, `tokenSource`, two resolvers. `data/providers.nix` declares
`{ env = … }`; on NixOS every provider named in `agent.agenixDir` /
`agent.agenixFiles` is rewritten to the decrypted secret's path
(`agent.resolvedProviders`), which Home Manager receives through
`home-manager.sharedModules` — the consumer writes no bridge module.

| | NixOS host (`agenixDir`/`agenixFiles`) | Container / plain HM |
|---|---|---|
| declared | `{ env = "AGENT_FREE_TOKEN"; }` | same |
| resolved | `{ file = /run/agenix/free-token; }` | unchanged |
| pi (`apiKey`) | `!cat /run/agenix/free-token` | `!printenv AGENT_FREE_TOKEN` |
| opencode | `{file:/run/agenix/free-token}` | `{env:AGENT_FREE_TOKEN}` |
| shell commands | `$(cat /run/agenix/free-token)` | `"$AGENT_FREE_TOKEN"` |

Consequences worth keeping:

- `command`/`shell` forms are evaluated at launch or request time, so the key is
  never baked into a script or a JSON file in the store. pi reads it per
  request; do **not** run pi's `/login` for these providers — `auth.json` takes
  precedence over the provider's `apiKey`.
- A provider absent from both `agenixDir` and `agenixFiles` stays env-based on
  NixOS too. That is the intended escape hatch for a provider whose token you
  manage yourself.
- `agenixFiles` keys must match provider names; the agenix secret is named
  `<provider>-token` and gets `mode = "0400"`. Its owner is `agent.agenixOwner`
  when set; when that is null agenix falls back to root, which a desktop login
  usually cannot read — so a host with a user should set it.

### Provider-pinned commands

The main `claude` command is **profile-driven**, not provider-pinned: it reads
the active world's provider and injects that provider's `ANTHROPIC_*` for its
own process (see [Profiles](#profiles)). What remains in
`agent.claudeCode.commands` is for the rare helper that must always talk to
one fixed endpoint:

| Command | Provider | Runs |
|---|---|---|
| `writing` | `custom` | `data/scripts/writing.sh` — merges the env into `./.claude/settings.local.json` (mode 0600), links the ARIS research skills into the folder, and prints the follow-up steps |

Each such command exports its provider's `ANTHROPIC_*` only for its own process,
so it overrides any global shell export without touching global state. `writing`
reads `ANTHROPIC_BASE_URL` / `ANTHROPIC_API_KEY` / the tier variables the record
already rendered, so no model id is named twice.

To add one:

```nix
agent.claudeCode.commands.claude-pro = { provider = "neoplatform"; };
```

## Skills

`data/skills.nix` declares the skills that ship with the runtime, injected
everywhere it runs. Sources are directories inside flake inputs, so a skill
contributes every markdown file it ships.

| Skill | From input | What it is |
|---|---|---|
| `archify` | `archify` | architecture/workflow/sequence/state diagrams as standalone HTML |
| `archify-review` | `archify` (`.agents/skills`) | diagram/issue triage workflow, shipped outside `archify/` |
| `i-have-adhd` | `i-have-adhd` | ADHD-aware interaction guidance |
| `ponytail` | `ponytail` | minimal-solution coding mode (also an opencode plugin) |
| `ponytail-review` / `-audit` / `-gain` / `-help` / `-debt` | `ponytail` (`skills/`) | the same repo's review, whole-repo audit, scoreboard, cheat-sheet and debt-ledger modes |
| `qmd` | `qmd` (`skills/`, name-filtered) | local markdown search; the repo's maintainer `release` skill is filtered out |

Ten skills, three targets, one bundle each: `.agents/skills` (cross-vendor),
`.claude/skills`, `.config/opencode/skills`. On NixOS `modules/skills.nix` only
declares the sources and agent-skills' activation links the trees; for the
standalone config there is no activation, so the filtered bundles are
registered in `agent.runtimeFiles` for `agent-runtime-config` to ship.

**Adding host-specific skills:** set `agent.skills.sources` — the host-facing
mirror of `programs.agent-skills.sources`, so a NixOS host never touches the
agent-skills options (or its module) directly:

```nix
# a NixOS host: host-only skills, merged with the runtime's own
agent.skills.sources.my-skill = { path = "${inputs.my-skills}/skills"; };
```

`modules/skills.nix` merges both registries into one catalog, then builds the
per-source installers and the dispatcher into `agent.skillTools`:

| Command | What it does |
|---|---|
| `skills <source>` | install one source's skills into the current project |
| `skills-install-<source>` | the same, one binary per source, for scripts and CI |

Both land in `home.packages` / `#agent-runtime`, so a container gets them too and
no host has to ship its own `skills` wrapper. Extend the sources, never import
the agent-skills Home Manager module yourself: `modules/skills.nix` is the only
importer, and it is a plain path, so a second import of the *runtime* module
dedupes rather than colliding.

Two registries merge into one catalog on purpose: runtime skills above
(hosts **and** containers) plus whatever a host adds (e.g. `orca*` in
turbcool/nixos' `config/skills.nix`).

## Configuration options

### `modules/home.nix` — every consumer

| Option | Type | Default | Effect |
|---|---|---|---|
| `agent.providers` | attrs | `data/providers.nix` | provider registry; on NixOS the NixOS module rewrites `agenixDir`/`agenixFiles` providers to their decrypted path |
| `agent.defaultModel` | str | `"free/main"` | `provider/model`; pi gets the two halves, opencode the joined string |
| `agent.smallModel` | str | `"custom/qwen3-coder-next"` | small/subagent tier for pi *and* opencode — one line moves both |
| `agent.mcp` | attrs | `data/mcp.nix` | MCP registry, in three sets: `servers`/`groups` (offered by the `mcp` command, which ships with the bundle) and `npm`, written into opencode.json *and* into each claude command's `--mcp-config`. The `mcp` command renders this same option, so an override reaches both |
| `agent.plugins` | attrs | `data/plugins.nix` | Claude Code marketplaces + enabled plugins (NixOS side) plus `opencodePlugins`, the repo names `modules/home.nix` loads into opencode.json. All three are derived from one `community` list |
| `agent.agents.includeTui` | bool | `true` | also install `agent-deck`; off for slim/headless bundles |
| `agent.npmPrefix` | str | `"$HOME/.npm"` | where npm installs; its `bin/` holds the `npm` MCP servers, so this is the single source for their absolute paths, for `home.sessionPath` and for the activation hook that installs them |
| `agent.claudeCode.enable` | bool | `true` | install the fixed per-task commands |
| `agent.claudeCode.commands` | attrsOf `{ provider, script ? null }` | `writing` | fixed provider-pinned helpers; the main `claude` command is profile-driven (see [Profiles](#profiles)), so this is only for commands pinned to one endpoint (`writing`) |
| `agent.profiles` | attrs | `data/profiles.nix` | profile registry: `{ provider, mcp = [...], skills = [...] }` per name; each is rendered into a complete world and installed by `profile <name>` (see [Profiles](#profiles)) |
| `agent.defaultProfile` | str | `"work"` | the world installed on first activation, and when no profile is active yet; a rebuild re-installs the *active* world, never this one |

Internal: `agent.runtimeFiles`, `agent.runtimePackages`, `agent.skillTools`,
`agent.mcpCommand` — computed, read-only.

`agent.pi.enable`/`agent.opencode.enable`/`agents.enable`/`skills.enable` are
gone: nothing flipped them, and the config files they guarded are the reason the
bundle exists. What is left instead is a `pi` wrapper that appends
`--exclude-tools web_crawl`: pi has no settings key for it (`defaultTools`
cannot help, since sessions re-activate every extension tool), and the flag is
the only thing that reaches pi's excluded-tool list. donsetch's `web_fetch` and
`web_search` stay available.

### `modules/nixos.nix` — NixOS only

| Option | Type | Default | Effect |
|---|---|---|---|
| `agent.agenixDir` | nullOr path | `null` | convention alternative to `agenixFiles`: every provider in the registry gets `<dir>/<provider>-token.age`, so one directory entry covers the whole registry. Merged with the explicit map |
| `agent.agenixFiles` | attrsOf path | `{}` | provider name → `.age` ciphertext; declares `age.secrets.<name>-token` (0400) and rewrites that provider's `tokenSource` to the decrypted path |
| `agent.agenixOwner` | nullOr str | `null` | owner of the decrypted secrets; null means "don't say", and agenix then uses root, which a desktop login usually cannot read |
| `agent.skills.sources` | attrs | `{}` | host-only skills, merged with the runtime's own into one catalog (see [Skills](#skills)) |
| `agent.claudeCode.{enable,commands}` | — | as above | declared once in `modules/options.nix` and imported by both halves |

Everything below is wired without the consumer asking:

- `home-manager.sharedModules` + `home-manager.extraSpecialArgs.runtimeInputs` —
  guarded on the `home-manager` NixOS module being imported, so this flake never
  *requires* it. This is what makes a NixOS host a one-import setup, and it is
  `sharedModules` precedence so a host's own Home Manager config still wins.
- `programs.npm` (with an `npmrc` assertion against `agent.npmPrefix`) and
  `programs.nix-ld` — the prerequisites of the npm MCP servers, previously
  repeated by every consumer.

Also writes, without an option of its own:

- `age.secrets.<provider>-token` for each provider in `agenixDir`/`agenixFiles`
- `/etc/claude-code/managed-settings.json` — the immutable Claude Code settings:
  plugin marketplaces and enabled plugins, nothing else. Highest precedence by
  design, which leaves the user-scope `~/.claude/settings.json` writable for the
  plugin install flow. Every *env* value lives in the per-provider command
  instead — a locked `CLAUDE_CODE_SUBAGENT_MODEL` here used to override the
  per-folder settings a `writing` run writes.
- `environment.sessionVariables` — nothing. The endpoint, the token and the
  model tiers are all per-provider *process* state; publishing a base URL
  globally only made pi think the built-in `anthropic` provider was live.

### Not an option: the pi package list

The world's `settings.json` carries the `packages` array (pi-zentui,
donsetch, `@ff-labs/pi-fff`, `@piex-dev/init`,
`@juicesharp/rpiv-ask-user-question`) has no option behind it. Add an extension
by editing that file with a small `home.file` override, not by patching the
module. `~/.pi/agent/zentui.json` and any extension's own config under
`~/.config/<ext>/` are read but never written, so they stay user-owned.

## What lands on disk

Managed by the active **world** (`modules/worlds.nix`), reinstalled on every
activation and on every `profile <name>`:

| Path | Written by | Note |
|---|---|---|
| `~/.config/opencode/opencode.json` | the installed world | provider + model + static keys + the npm MCP servers, all with absolute paths; the *project's* `opencode.json` is where `mcp <group\|server>` merges extra servers |
| `~/.pi/agent/models.json` | the installed world | all providers + models, read-only for pi |
| `~/.pi/agent/settings.json` | the installed world | default provider/model of the world's provider, `enabledModels`, `packages` |
| `~/.pi/agent/mcp.json` | the installed world | the always-on npm MCP servers in pi's dialect |
| `~/.pi/agent/pi-fff.json` | the installed world | `@ff-labs/pi-fff` mode `override` |
| `.agents/skills`, `.claude/skills`, `.config/opencode/skills` | the installed world | symlink trees of the profile's selected skill sources |
| `/etc/claude-code/managed-settings.json` | NixOS | immutable Claude Code plugins (see above) |
| `/run/agenix/<provider>-token` | NixOS + agenix | 0400, decrypted at activation |

These are one pre-rendered snapshot per profile (`lib/worlds.nix`), so the
desktop login, the container bundle (`agent-runtime-config`) and every `profile`
switch all read the same bytes — and `~/.claude.json` / `~/.claude/settings.json`
stay **user-owned** (claude is driven by the `claude` wrapper + `--mcp-config`,
not by a written settings file).

User-owned on purpose, so the agents' own write paths keep working: pi's
`auth.json`, `sessions/`, `git/`, `npm/`, `zentui.json`, `~/.claude/settings.json`,
extension config under `~/.config/<ext>/`, and `.claude/settings.local.json` +
`~/.cache/claude-code/mcp-<command>.json` (both written by the commands at
`umask 077`/mode 0600, never from the store).

One activation hook ships with the module: `installMcpServers` re-runs
`npm i -g` for `agent.mcp.npm` when one of those binaries is missing, so a
wiped `~/.npm` recovers by itself. It is the registry's own list, not a
hand-copied one — a container still has no activation to run it.

## MCP servers

`data/mcp.nix` is the registry, in three sets that stay separate on purpose:

| Set | What it is | How it reaches an agent |
|---|---|---|
| `servers` | `nixos`, `daisyui`, `svelte`, `lucide-icons` | opt-in per project: `mcp <server>` merges a rendered fragment into `./opencode.json` |
| `groups` | `nixos`, `frontend` | the same, by name: `mcp frontend` |
| `npm` | `donsetch`, `bladebro` (binaries in `~/.npm/bin`) | every agent, always: opencode.json + each claude command's `--mcp-config` |

The `mcp` command ships with the bundle (`#mcp`, and inside `#agent-runtime`), so
containers get it too. It reads its configs from a baked-in store farm, so
activating a group is a local file read — no `nix build`, no flake reference.

Entries are dialect-free: they say what a server *is*, and each renderer adds
what its agent wants (opencode gets `type`/`enabled` and an absolute command
path; Claude Code infers stdio from `command`). `npm` commands are absolute
paths for both, because an agent's environment can predate `home.sessionPath`
(GUI launch, container without rc).

A server that needs a binary nobody installs is dead weight — so a `package`-backed
entry is resolved by the module itself (`pkgs.${entry.package}`, added to
`agent.runtimePackages`), rather than each consumer listing the same package
again. `mcp-nixos` is such an entry. An npm server still needs its global
install.

`donsetch` and `bladebro` are not Nix packages — they are npm-installed per user
(the activation hook does it when missing). On NixOS the runtime enables
`programs.nix-ld` for them, because the host otherwise has to remember that
their prebuilt glibc binaries need the NixOS stub loader.

## Claude Code plugins

`data/plugins.nix` declares marketplaces (`claude-plugins-official`, `ponytail`,
`i-have-adhd`, all auto-updating) and enabled plugins
(`code-simplifier@claude-plugins-official`, `ponytail@ponytail`,
`i-have-adhd@i-have-adhd`) — these are the immutable part of managed-settings.json.
Its `opencodePlugins` list names the repos `modules/home.nix` loads into
opencode.json as plugins, by absolute store path resolved from this flake's
inputs.

## Flake outputs

| Output | What it is |
|---|---|
| `nixosModules.default` | the one-import NixOS setup (see [NixOS host](#nixos-host)) |
| `homeModules.default` | the home half alone, for a plain Home Manager consumer |
| `homeModules.container` | `homeModules.default` + `modules/container.nix` (headless tweaks: no TUI extras, `$HOME` handling) |
| `homeConfigurations.agent-runtime` | a ready standalone Home Manager configuration, no OS under it |
| `packages.agent-runtime` (also `default`) | the `buildEnv` bundle of `agent.runtimePackages` |
| `packages.agent-runtime-config` | the rendered config + skill trees, a `linkFarm` for `COPY` |
| `packages.install` | no-argument installer: bundle on PATH, config into `$HOME`, seed npm, report missing tokens |
| `packages.mcp` | just the `mcp` command, for a client that already has the bundle |
| `lib.data` | the registries (`providers`, `mcp`, `plugins`, `skills`, `profiles`) plus `lib.data.worlds` (the pure renderer), so a client extends a record instead of re-deriving it |
| `lib.agentSkills` | agent-skills' library, for a client that wants a bundle shape of its own |
| `checks` | `bundle-contains-agents`, `mcp-servers-exist`, `worlds-resolve` |
| `devShells.default` | jq, nixfmt, statix |

## Checks, dev, gotchas

```bash
nix flake check            # bundle-contains-agents, mcp-servers-exist, worlds-resolve
nix develop                # jq, nixfmt, statix
```

- `bundle-contains-agents` is the contract for the bundle: `agent-runtime` must
  actually contain every `agent.claudeCode.commands` key plus `opencode`, `pi`,
  `mcp`. The list is derived from the option, so adding a command covers itself.
- `mcp-servers-exist` keeps the registry honest: every `package`-backed server
  must name a package that really exists in `pkgs`, so a typo in `data/mcp.nix`
  fails a check instead of a user's build.
- `worlds-resolve` resolves every bundled profile (extends + MCP-group expansion)
  and renders each into a full world, so a bad provider/mcp name or an `extends`
  cycle fails a check instead of a `profile` call. Skill names are checked
  against the merged source set by an HM assertion, which a host can extend.
- Config correctness is asserted by the modules themselves instead, so it is
  checked for *every* consumer — not only for the defaults a flake check can
  see.
- **No top-level `formatter` output.** Nix evaluates a `formatter` at system
  `«none»` here and `nix flake check` fails; format with the devshell's `nixfmt`
  (the old `nixfmt-rfc-style` alias).
- pi npm-installs missing/out-of-date packages on startup, so an air-gapped
  container needs its npm packages pre-seeded.
- A terminal at least 100 columns wide is needed for `@juicesharp/rpiv-ask-user-question`
  previews; narrower terminals stack the preview under the options.
- pi's Thinking (Experimental) renderer, as implemented by pi-zentui, is tested
  against pi 0.85/0.87 and may misbehave on pi 1.x — it ships disabled.

## License

MIT for this flake's own code. Bundled skills and plugins keep their upstream
licenses.
