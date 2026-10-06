# agent-runtime

Declarative agent runtime: **pi + opencode + claude-code**, with LLM providers,
token wiring, MCP servers, bundled skills and Claude Code plugins. One module
pair, three consumers:

| Consumer | How it uses this flake |
|---|---|
| NixOS + Home Manager | `nixosModules.default` + `homeModules.default` |
| Standalone container | `nix profile install …#agent-runtime` (env-var tokens) |
| Any other HM setup | `homeModules.default` alone (tokens from the environment) |

Same modules everywhere, so a desktop login and a container image get byte-identical
`~/.pi` and `~/.config/opencode` trees — only the token *source* differs.

```nix
# NixOS + Home Manager (consumer side)
inputs.agent-runtime.nixosModules.default   # agenix secrets, Claude Code managed settings
inputs.agent-runtime.homeModules.default    # pi/opencode config, binaries, all agent.* options
```

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
- [Checks, dev, gotchas](#checks-dev-gotchas)

## Quick start

### Container / standalone

```bash
nix profile install github:turbcool/agent-runtime#agent-runtime             # pi, opencode, claude, claude-free, writing
nix profile install github:turbcool/agent-runtime#agent-runtime-install     # one-shot: lay ~/.pi, ~/.config/opencode + skills into $HOME
nix build github:turbcool/agent-runtime#agent-runtime-config                # rendered config + skill trees, for COPY in a Dockerfile
nix develop github:turbcool/agent-runtime                                  # ad-hoc shell (jq, nixfmt, statix)
```

`#agent-runtime` is a `buildEnv` of `agent.runtimePackages` — deliberately not
`home.packages`, because standalone HM folds its own baseline (man-db,
mime-support) into that list. `#agent-runtime-config` is a `linkFarm` of
`agent.runtimeFiles`; `#agent-runtime-install` `cp -rL`s it into `$HOME` and
re-adds write permission (store paths are read-only, and pi must be able to
create `~/.pi/agent/sessions`).

Export `AGENT_NEOPLATFORM_TOKEN`, `AGENT_CUSTOM_TOKEN`, `AGENT_FREE_TOKEN`
before running an agent.

### NixOS host

```nix
inputs.agent-runtime = {
  url = "github:turbcool/agent-runtime";
  inputs = { nixpkgs.follows = "nixpkgs"; home-manager.follows = "home-manager"; };
};

# imports
inputs.agent-runtime.nixosModules.default   # → agent.agenixFiles, agent.claudeCode.*
inputs.agent-runtime.homeModules.default    # → agent.providers, agent.defaultModel, ...

# the only required host-side wiring: provider name → .age ciphertext
agent.agenixFiles = {
  neoplatform = ../secrets/neoplatform-token.age;
  custom = ../secrets/custom-token.age;
  free = ../secrets/free-token.age;
};
```

Those tokens are then decrypted by agenix and every agent reads them from
`/run/agenix/<name>-token` — never from an environment variable, never from a
config file in the store.

### Input wiring

Skill sources name flake inputs (`input = "archify"`), and agent-skills resolves
them against the **consuming** flake. So every input referenced by
`data/skills.nix` must be declared by the consumer too, or point `follows` at
the runtime's copy:

```nix
inputs = { archify.follows = "agent-runtime/archify"; };
```

## Providers

`data/providers.nix` is the registry. Every entry is an OpenAI-compatible proxy;
`anthropicUrl` exists for the Claude Code wrappers, which speak the Anthropic
API instead.

| Provider | Endpoint | Anthropic URL | Token env var | Models (context / max output) |
|---|---|---|---|---|
| `neoplatform` | `https://llm.neoplatform.ru` | — | `AGENT_NEOPLATFORM_TOKEN` | `deepseek-v4-flash` (200k/32k), `gemma-4-31b-it` (200k/32k), `qwen3-coder-128k:30b` (128k/32k) |
| `custom` | `https://llm.naidanov.ru` | — | `AGENT_CUSTOM_TOKEN` | `deepseek-v4-flash` (200k/32k), `deepseek-v4-flash-direct` (200k/32k), `qwen3-coder-next` (128k/32k) |
| `free` | `https://llm-free.naidanov.ru/v1` | `https://llm-free.naidanov.ru` | `AGENT_FREE_TOKEN` | `main` (256k/32k), `muse-spark-1.3-contributor` (defaults 128k/32k) |

A provider is:

```nix
{
  url = "https://…";            # OpenAI-compatible base; "/v1" is normalised away
  anthropicUrl = "https://…";   # optional, Claude Code wrappers only
  models.<id> = { name = "…"; limit.context = 200000; limit.output = 32000; };
  tokenSource = { env = "AGENT_X_TOKEN"; };   # the declaration; see below
}
```

Override the registry wholesale rather than patching the data file:

```nix
agent.providers = (import <agent-runtime>/data/providers.nix) // {
  myproxy = { url = "https://…"; tokenSource.env = "AGENT_MYPROXY_TOKEN"; };
};
```

### Token resolution

One field, `tokenSource`, two resolvers. `data/providers.nix` declares
`{ env = … }`; on NixOS every provider named in `agent.agenixFiles` is rewritten
to the decrypted secret's store path (`agent.resolvedProviders`), which
Home Manager receives through the consumer's bridge module.

| | NixOS host (`agenixFiles`) | Container / plain HM |
|---|---|---|
| declared | `{ env = "AGENT_FREE_TOKEN"; }` | same |
| resolved | `{ file = /run/agenix/free-token; }` | unchanged |
| pi (`apiKey`) | `!cat /run/agenix/free-token` | `!printenv AGENT_FREE_TOKEN` |
| opencode | `{file:/run/agenix/free-token}` | `{env:AGENT_FREE_TOKEN}` |
| shell wrappers | `$(cat /run/agenix/free-token)` | `"$AGENT_FREE_TOKEN"` |

Consequences worth keeping:

- `command`/`shell` forms are evaluated at launch or request time, so the key is
  never baked into a script or a JSON file in the store. pi reads it per
  request; do **not** run pi's `/login` for these providers — `auth.json` takes
  precedence over the provider's `apiKey`.
- A provider absent from `agenixFiles` stays env-based on NixOS too. That is the
  intended escape hatch for a provider whose token you manage yourself.
- `agent.agenixFiles` keys must match provider names; the agenix secret is named
  `<provider>-token` and gets `mode = "0400"`, chowned to
  `local.profile.username` when that option exists.

### Claude Code wrappers

`agent.claudeCode.provider` picks the endpoint for `claude`; each entry in
`agent.claudeCode.wrappers` adds one more command (`claude-free` by default).
Wrappers export `ANTHROPIC_*` for their own process and exec the real binary by
absolute store path, so one binary serves several providers without a global
shell export. `writing` is a one-shot per-project setup: it merges the `custom`
provider into `./.claude/settings.local.json` (mode 0600) and prints the
follow-up steps (plain bash in `data/scripts/writing.sh`, its environment
injected from `modules/wrappers.nix`). `agent.claudeCode.exposeRealBinary`
additionally puts the unwrapped `claude` on PATH — off by default, because it
collides with the wrapper of the same name.

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

**Adding host-specific skills:** extend `programs.agent-skills.sources`, never
import the agent-skills Home Manager module again. `modules/skills.nix` is the
only importer, and the module is a Nix *function*, so a second import makes every
`programs.agent-skills.*` option collide ("already declared").

```nix
programs.agent-skills.sources.my-skill = { input = "my-repo"; subdir = "skills"; };
```

Two registries merge into one catalog on purpose: runtime skills above
(hosts **and** containers) plus whatever a host adds (e.g. `orca*` in
turbcool/nixos' `config/skills.nix`).

## Configuration options

### `modules/home.nix` — every consumer

| Option | Type | Default | Effect |
|---|---|---|---|
| `agent.providers` | attrs | `data/providers.nix` | provider registry; on NixOS the NixOS module rewrites `agenixFiles` providers to store paths |
| `agent.defaultModel` | str | `"free/main"` | `provider/model`; pi gets the two halves, opencode the joined string |
| `agent.smallModel` | str | `"custom/qwen3-coder-next"` | small/subagent tier — one line moves it for pi *and* opencode |
| `agent.mcp` | attrs | `data/mcp.nix` | MCP registry. Its `npm` set (the npm-installed servers) is written into opencode.json *and* handed to the Claude Code wrappers, each in its own dialect; the rest reaches opencode.json through the consumer's `mcp <group\|server>` CLI |
| `agent.plugins` | attrs | `data/plugins.nix` | Claude Code marketplaces + enabled plugins; only NixOS consumes them (into managed-settings.json) |
| `agent.skills.enable` | bool | `true` | declare the bundled skills |
| `agent.agents.enable` | bool | `true` | put `pi` + `opencode` in `home.packages` |
| `agent.agents.includeTui` | bool | `true` | also install `agent-deck`; off for slim/headless bundles |
| `agent.pi.enable` | bool | `true` | write `~/.pi/agent/{models,settings,pi-fff}.json` |
| `agent.opencode.enable` | bool | `true` | write `~/.config/opencode/opencode.json` |
| `agent.claudeCode.enable` | bool | `true` | build the `claude` wrappers + `writing` |
| `agent.claudeCode.provider` | str | `"neoplatform"` | endpoint for `claude` |
| `agent.claudeCode.mainModel` / `.smallModel` | str | `deepseek-v4-flash` / `qwen3-coder-128k:30b` | opus/sonnet and haiku tiers for `claude` |
| `agent.claudeCode.exposeRealBinary` | bool | `false` | also put the unwrapped `claude` on PATH |
| `agent.claudeCode.wrappers` | list of `{ name, provider, mainModel, smallModel, comment }` | one `claude-free` entry | one wrapper command per provider |

Internal: `agent.tokenSyntax`, `agent.runtimeFiles`, `agent.runtimePackages` —
computed, read-only.

`agent.agents.enable` also installs a `pi` wrapper that appends
`--exclude-tools web_crawl`: pi has no settings key for it (`defaultTools`
cannot help, since sessions re-activate every extension tool), and the flag is
the only thing that reaches pi's excluded-tool list. donsetch's `web_fetch` and
`web_search` stay available.

### `modules/nixos.nix` — NixOS only

| Option | Type | Default | Effect |
|---|---|---|---|
| `agent.agenixFiles` | attrsOf path | `{}` | provider name → `.age` ciphertext; declares `age.secrets.<name>-token` (0400) and rewrites that provider's `tokenSource` to the store path |
| `agent.claudeCode.{enable,provider,mainModel,smallModel}` | — | as above | declared once in `modules/options.nix` and imported by both halves |

Also writes, without an option of its own:

- `age.secrets.<provider>-token` for each entry in `agenixFiles`
- `/etc/claude-code/managed-settings.json` — immutable Claude Code settings
  (subagent model, auto-compact window, marketplaces, enabled plugins). Highest
  precedence by design, which leaves the user-scope `~/.claude/settings.json`
  writable for the plugin install flow. Provider-specific values
  (`ANTHROPIC_BASE_URL`, the model tier map) are deliberately **not** here —
  the per-provider wrappers own those.
- `environment.sessionVariables.ANTHROPIC_BASE_URL` when Claude Code is enabled.

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
| `~/.pi/agent/models.json` | `agent.pi.enable` | providers + models, read-only for pi |
| `~/.pi/agent/settings.json` | `agent.pi.enable` | force-managed: default provider/model, `enabledModels` (hides bundled models so `/model` and Ctrl+P only cycle ours), `packages` |
| `~/.pi/agent/pi-fff.json` | `agent.pi.enable` | `@ff-labs/pi-fff` mode `override`: swaps pi's find/grep for `fffind`/`ffgrep`, adds `multi_grep` |
| `~/.config/opencode/opencode.json` | `agent.opencode.enable` | force-managed: providers, models, permissions, compaction, ponytail/i-have-adhd plugins, and the two npm MCP servers with absolute paths. The remaining servers from `data/mcp.nix` are not written here — the consumer's `mcp <group|server>` CLI merges `#mcp-config-<name>` into this file |
| `.agents/skills`, `.claude/skills`, `.config/opencode/skills` | `agent.skills.enable` | agent-skills symlink trees |
| `/etc/claude-code/managed-settings.json` | NixOS | see above |
| `/run/agenix/<provider>-token` | NixOS + agenix | 0400, decrypted at activation |

User-owned on purpose, so the agents' own write paths keep working: pi's
`auth.json`, `sessions/`, `git/`, `npm/`, `zentui.json`, `~/.claude/settings.json`,
extension config under `~/.config/<ext>/`, and `.claude/settings.local.json` +
`~/.cache/claude-code/mcp-<wrapper>.json` (both written by wrappers at
`umask 077`/mode 0600, never from the store).

## MCP servers

`data/mcp.nix` is the registry: `nixos`, `daisyui`, `svelte`, `lucide-icons`,
`wiki`, plus a `groups` view (`nixos`, `frontend`, `wiki`) and the reserved
`npm` set — `donsetch` and `bladebro`, whose binaries are npm-installed into
`~/.npm/bin`. Each ordinary server has an `enabled` flag. `npm` is declared once
and derived twice: into opencode.json (`type = "local"`, absolute command path)
and into each `claude` wrapper's `--mcp-config` (`type = "stdio"`). Both forms
use absolute `$HOME/.npm/bin/…` paths, because a wrapper's environment can
predate `home.sessionPath` (GUI launch, container without rc). A consumer
enumerating servers must skip `groups` and `npm`.

`donsetch` and `bladebro` are not Nix packages — they are npm-installed per user
(`npm i -g bladebro donsetch`) and need `programs.nix-ld` on NixOS.

## Claude Code plugins

`data/plugins.nix` declares marketplaces (`claude-plugins-official`, `ponytail`,
`i-have-adhd`, all auto-updating) and enabled plugins
(`code-simplifier@claude-plugins-official`, `ponytail@ponytail`,
`i-have-adhd@i-have-adhd`). `modules/home.nix` additionally loads the ponytail
and i-have-adhd opencode plugins by absolute store path.

## Checks, dev, gotchas

```bash
nix flake check            # bundle-contains-agents
nix develop                # jq, nixfmt, statix
```

- The check is the contract for the bundle: `agent-runtime` must actually
  contain `claude`, `claude-free`, `writing`, `opencode`, `pi`. Config
  correctness is asserted by the modules themselves instead, so it is checked
  for *every* consumer — not only for the defaults a flake check can see.
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
