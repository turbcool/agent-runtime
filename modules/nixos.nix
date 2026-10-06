# NixOS half of the agent runtime: the whole Home Manager half (wired in), the
# agenix secrets behind the providers, the host prerequisites the runtime's own
# configuration implies, and the immutable Claude Code settings file.
#
# Importing this module is all a NixOS host does: when `home-manager`'s NixOS
# module is present, `modules/home.nix` and the three values that only this side
# can compute (the token-resolved providers, the registry, the client's skill
# sources) are pushed into every Home Manager configuration through
# `home-manager.sharedModules` + `home-manager.extraSpecialArgs.runtimeInputs`.
# No bridge module, no HM import, no `inputs` in the host's extraSpecialArgs.

# `inputs` here is this flake's own input set, passed from flake.nix; `homeModule`
# is `modules/home.nix`, passed in as a plain (dedupable) path.

# The single job beyond wiring is the token rewrite: every provider listed in
# `agent.agenixFiles` gets its env-var tokenSource replaced by the path of a
# decrypted agenix secret. Standalone (containers) nothing is injected and
# `tokenSource.env` is used as declared — same module, same rendered config,
# different token source.
#
# Everything a per-provider command can decide for itself (base URL, token, the
# model tiers, the compact window) is deliberately NOT here: managed settings
# cannot be overridden, which would defeat those commands. What stays is what
# only the host can declare — the plugin marketplaces, which claude downloads.
#
# The ciphertexts live on the host, not here: this flake ships no secrets and
# no absolute paths, so a container install is a plain `nix profile install`.
{ homeModule, inputs }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.agent;
  inherit (cfg) providers;

  # agenix's owner is nullable: a client without a user module simply does not
  # set it, and agenix falls back to its own default. `local.profile.username`
  # is this author's convention, not a requirement.
  owner =
    if cfg.agenixOwner != null then
      cfg.agenixOwner
    else
      (config.local.profile.username or null);

  # Ciphertexts, from either spelling of the same fact: an explicit map, or a
  # directory holding `<provider>-token.age` for every provider in the registry.
  # The convention is what keeps "add a provider" to one ciphertext plus one
  # public key in the client's secrets manifest.
  agenixFiles =
    cfg.agenixFiles
    // lib.mapAttrs' (name: _: {
      name = name;
      value = "${cfg.agenixDir}/${name}-token.age";
    }) (lib.filterAttrs (name: _: cfg.agenixDir != null) providers);

  # `{ env = ...; }` → `{ file = <store path>; }`. Lives in its own option
  # rather than rewriting `agent.providers` in place: the rewrite reads
  # config.agent.providers, so doing it there would be self-referential.
  # Home Manager receives this through sharedModules below.
  resolvedProviders = lib.mapAttrs (
    name: p:
    if agenixFiles ? ${name} then
      p
      // {
        tokenSource = {
          file = config.age.secrets."${name}-token".path;
        };
      }
    else
      p
  ) providers;

  # The npm-installed MCP servers need an npm with a prefix this module also
  # knows about, and a dynamic loader that can start their prebuilt glibc
  # binaries. Declared here rather than in every client's package list, so
  # "import the module" really is the whole setup.
  needsNpm = cfg.mcp.npm != { };

  # npm's prefix is an npmrc *line* in nixpkgs, not an option — so the coupling
  # between the two halves of the runtime (agent.npmPrefix, which is where the
  # MCP command paths are built) can only be asserted, not derived. `replaceStrings`
  # turns the `$HOME` this module uses into the `${HOME}` npm expands.
  npmrcPrefix = "prefix = " + lib.replaceStrings [ "$HOME" ] [ "\${HOME}" ] cfg.npmPrefix;

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
      description = "agent.providers with tokenSource rewritten for NixOS. Injected into Home Manager by this module.";
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

    agenixDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "../secrets";
      description = ''
        Convention alternative to `agenixFiles`: every provider in the registry
        gets `<dir>/<provider>-token.age`. Merged with the explicit map, so a
        host can mix (e.g. an extra provider kept outside the directory).
      '';
    };

    agenixOwner = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "\"myuser\"";
      description = ''
        Owner of the decrypted secrets. Null means "don't say": agenix then uses
        its own default (root), which a desktop login usually cannot read —
        so a client with a user module should set this, or keep the
        `local.profile.username` convention this runtime's author uses.
      '';
    };
  };

  config = {
    agent.resolvedProviders = resolvedProviders;

    # Everything below is guarded on `home-manager`'s NixOS module being
    # imported: this flake must not require it. `sharedModules` is also the right
    # precedence — a value the client sets in its own Home Manager config wins.
    home-manager = lib.mkIf (config ? home-manager.sharedModules) {
      # The `runtimeInputs` argument home.nix declares. Supplied here so a NixOS
      # host never has to pass it for itself.
      extraSpecialArgs.runtimeInputs = inputs;
      sharedModules = [
        homeModule
        {
          agent.providers = resolvedProviders;
          agent.mcp = cfg.mcp;
          agent.skills.sources = cfg.skills.sources;
        }
      ];
    };

    age.secrets = lib.mapAttrs' (name: file: {
      name = "${name}-token";
      value = {
        inherit file;
        mode = "0400";
      } // lib.optionalAttrs (owner != null) { inherit owner; };
    }) agenixFiles;

    environment.etc."claude-code/managed-settings.json".source = managedSettings;

    programs.nix-ld = lib.mkIf needsNpm { enable = true; };

    programs.npm = {
      enable = lib.mkIf needsNpm true;
      npmrc = lib.mkDefault npmrcPrefix;
    };

    assertions = [
      {
        assertion = !needsNpm || lib.hasInfix npmrcPrefix config.programs.npm.npmrc;
        message = "agent.npmPrefix is '${cfg.npmPrefix}' but programs.npm.npmrc sets a different prefix; the MCP servers in ${cfg.npmPrefix}/bin would not be where this module's absolute paths point.";
      }
    ];
  };
}