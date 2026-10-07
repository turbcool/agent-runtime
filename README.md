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
- [Providers](#providers)
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
nix profile install github:turbcool/agent-runtime#agent-runtime             # pi, opencode, mcp, claude, claude-free, writing
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

`agent.claudeCode.commands` is an attrsOf record; the attr name is the command to
install, and the record says which provider it talks to and what it runs
afterwards:

| Command | Provider | Runs |
|---|---|---|
| `claude` | `neoplatform` (also the default endpoint, see below) | the real claude, with the npm MCP servers |
| `claude-free` | `free` | the same, repointed at the free endpoint with the free-account token |
| `writing` | `custom` | `data/scripts/writing.sh` — merges the same env into `./.claude/settings.local.json` (mode 0600) and prints the follow-up steps |

Each exports its provider's `ANTHROPIC_*` for its own process and therefore
overrides any global shell export, so one binary serves several endpoints
without global state. `writing` gets the identical env for free: its bash reads
`ANTHROPIC_BASE_URL` / `ANTHROPIC_API_KEY` / the tier variables the record
already rendered, which is why no model id is named twice.

The real `claude` is reachable only through these commands (they exec it by
absolute store path), so there is no option to put the unwrapped binary on PATH
— it would collide with `claude`.

To add a command:

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
| `agent.claudeCode.enable` | bool | `true` | install the provider-pinned commands |
| `agent.claudeCode.commands` | attrsOf `{ provider, script ? null }` | `claude`, `claude-free`, `writing` | one command per provider; the attr name is the command, `script` replaces the claude exec (see above) |

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

`~/.pi/agent/settings.json` is force-managed and its `packages` array (pi-zentui,
donsetch, `@ff-labs/pi-fff`, `@piex-dev/init`,
`@juicesharp/rpiv-ask-user-question`) has no option behind it. Add an extension
by editing that file with a small `home.file` override, not by patching the
module. `~/.pi/agent/zentui.json` and any extension's own config under
`~/.config/<ext>/` are read but never written, so they stay user-owned.

## What lands on disk

Managed (reverted on every activation):

| Path | Written by | Note |
|---|---|---|
| `~/.pi/agent/models.json` | `modules/home.nix` | providers + models, read-only for pi, so not force-managed |
| `~/.pi/agent/settings.json` | `modules/home.nix` | force-managed: default provider/model, `enabledModels` (hides bundled models so `/model` and Ctrl+P only cycle ours), `packages` |
| `~/.pi/agent/pi-fff.json` | `modules/home.nix` | `@ff-labs/pi-fff` mode `override`: swaps pi's find/grep for `fffind`/`ffgrep`, adds `multi_grep` |
| `~/.config/opencode/opencode.json` | `modules/home.nix` | force-managed: providers, models, permissions, compaction, the `opencodePlugins` list, and the two npm MCP servers with absolute paths. The rest of `data/mcp.nix` is not written here — `mcp <group\|server>` merges it into the *project's* `opencode.json` |
| `.agents/skills`, `.claude/skills`, `.config/opencode/skills` | `modules/skills.nix` | agent-skills symlink trees |
| `/etc/claude-code/managed-settings.json` | NixOS | see above |
| `/run/agenix/<provider>-token` | NixOS + agenix | 0400, decrypted at activation |

The first four are one table (`fileSpecs`) that feeds both `home.file` and
`runtimeFiles`, so the desktop login and the container bundle cannot drift.

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
| `lib.data` | the registries (`providers`, `mcp`, `plugins`, `skills`) so a client extends a record instead of re-deriving it |
| `lib.agentSkills` | agent-skills' library, for a client that wants a bundle shape of its own |
| `checks` | `bundle-contains-agents`, `mcp-servers-exist` |
| `devShells.default` | jq, nixfmt, statix |

## Checks, dev, gotchas

```bash
nix flake check            # bundle-contains-agents, mcp-servers-exist
nix develop                # jq, nixfmt, statix
```

- `bundle-contains-agents` is the contract for the bundle: `agent-runtime` must
  actually contain every `agent.claudeCode.commands` key plus `opencode`, `pi`,
  `mcp`. The list is derived from the option, so adding a command covers itself.
- `mcp-servers-exist` keeps the registry honest: every `package`-backed server
  must name a package that really exists in `pkgs`, so a typo in `data/mcp.nix`
  fails a check instead of a user's build.
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
