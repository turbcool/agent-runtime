# NixOS half of the agent runtime: agenix secrets + the immutable Claude Code
# settings file + the base URL for interactive shells.
#
# The single job beyond wiring is the token rewrite: every provider listed in
# `agent.agenixFiles` gets its env-var tokenSource replaced by the path of a
# decrypted agenix secret. Home Manager then picks those up through the host's
# agent-bridge module, so the host resolves tokens from the store while a
# container resolves them from the environment — same module, same rendered
# config, different token source.
#
# Everything a per-provider command can decide for itself (base URL, token, the
# model tiers, the compact window) is deliberately NOT here: managed settings
# cannot be overridden, which would defeat those commands. What stays is what
# only the host can declare — the plugin marketplaces, which claude downloads.
#
# The ciphertexts live on the host, not here: this flake ships no secrets and
# no absolute paths, so a container install is a plain `nix profile install`.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.agent;
  inherit (cfg) providers;

  # agenix's owner is nullable: fall back to not chowning rather than reaching
  # into host-specific options (local.profile.username).
  owner = config.local.profile.username or null;

  # `{ env = ...; }` → `{ file = <store path>; }`. Lives in its own option
  # rather than rewriting `agent.providers` in place: the rewrite reads
  # config.agent.providers, so doing it there would be self-referential.
  # Home Manager receives this through the host's agent-bridge module.
  resolvedProviders = lib.mapAttrs (
    name: p:
    if cfg.agenixFiles ? ${name} then
      p
      // {
        tokenSource = {
          file = config.age.secrets."${name}-token".path;
        };
      }
    else
      p
  ) providers;

  # Declarative, immutable Claude Code config. Managed settings take the highest
  # precedence and cannot be overridden, freeing the user-scope
  # ~/.claude/settings.json to be a writable file that Claude's plugin install
  # flow can write to.
  #
  # Plugins only. Every *env* value lives in the per-provider commands
  # (modules/home.nix) instead: a locked CLAUDE_CODE_SUBAGENT_MODEL here used to
  # override the per-folder settings a `writing` run writes, and a session-wide
  # ANTHROPIC_BASE_URL here leaked the endpoint into every shell for no gain —
  # the commands own their endpoint, and `commands.claude` is the default one.
  managedSettings = pkgs.writeText "claude-code-managed-settings.json" (
    builtins.toJSON {
      extraKnownMarketplaces = cfg.plugins.marketplaces;
      enabledPlugins = cfg.plugins.plugins;
    }
  );
in
{
  imports = [ ./options.nix ];

  options.agent = {
    resolvedProviders = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      internal = true;
      description = "agent.providers with tokenSource rewritten for NixOS. This is what Home Manager should consume.";
    };

    agenixFiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      example = "{ neoplatform = ../secrets/neoplatform-token.age; }";
      description = ''
        agenix ciphertext per provider name. NixOS-only — a container has no
        age identity and resolves `tokenSource.env` instead. Providers left out
        keep their env-var tokenSource, i.e. the token is read from the
        environment on NixOS too.
      '';
    };
  };

  config = {
    agent.resolvedProviders = resolvedProviders;

    age.secrets = lib.mapAttrs' (name: file: {
      name = "${name}-token";
      value = {
        inherit file owner;
        mode = "0400";
      };
    }) cfg.agenixFiles;

    environment.etc."claude-code/managed-settings.json".source = managedSettings;
  };
}
