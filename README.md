# agent-runtime

Declarative agent runtime: **claude-code + opencode + pi** with providers, keys,
MCP wiring and bundled skills. One module pair — usable from NixOS + Home
Manager, or standalone as a `nix profile` bundle in a container.

- NixOS: `nixosModules.default` (agenix secrets, Claude Code managed settings,
  `ANTHROPIC_BASE_URL`)
- Home Manager: `homeModules.default` (pi/opencode config, binaries, all
  `agent.*` options), OS-agnostic
- Data: `data/providers.nix`, `data/mcp.nix`, `data/skills.nix`, `data/plugins.nix`

No secrets and no absolute paths live here: a container resolves provider
tokens from `AGENT_*_TOKEN` env vars, a NixOS host from agenix ciphertexts it
points at with `agent.agenixFiles` (see `common/modules/agent-secrets.nix` in
[turbcool/nixos](https://github.com/turbcool/nixos)).

## Container usage

```bash
nix profile install github:turbcool/agent-runtime#agent-runtime             # pi, opencode, claude, claude-free, writing
nix profile install github:turbcool/agent-runtime#agent-runtime-install     # one-shot: lay ~/.pi, ~/.config/opencode + skills into $HOME
nix build github:turbcool/agent-runtime#agent-runtime-config                # rendered config + skill trees, for COPY in a Dockerfile
nix develop github:turbcool/agent-runtime                                  # ad-hoc shell (jq, nixfmt, statix)
```

Known container gaps: `bladebro`/`donsetch` stay a runtime `npm i -g` (they
need a manual `nix-ld` setup outside NixOS), and pi npm-installs its declared
packages on first startup, so an air-gapped container needs them pre-seeded.

## Host usage

Consumed as `git+file:/home/turb/repos/agent-runtime` by
[turbcool/nixos](https://github.com/turbcool/nixos), whose inputs it `follows`
so nothing is fetched twice. Uncommitted changes are picked up; commit before
rebuilding for a reproducible result.

```bash
nix flake check        # providers resolve to a token, bundle has all 5 agents
```
