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

  cc = cfg.claudeCode;
  ccProvider = resolvedProviders.${cc.provider};

  # Declarative, immutable Claude Code config. Managed settings take the highest
  # precedence and cannot be overridden, freeing the user-scope
  # ~/.claude/settings.json to be a writable file that Claude's plugin install
  # flow can write to.
  #
  # Only host-agnostic knobs live here. Anything provider-specific
  # (ANTHROPIC_BASE_URL, the ANTHROPIC_DEFAULT_*_MODEL tier map) must NOT be set
  # here — otherwise the per-provider wrappers in modules/wrappers.nix couldn't
  # repoint the agents at a different endpoint. Interactive `claude` still gets
  # those from the wrappers and from common/hm/claude-code.nix.
  managedSettings = pkgs.writeText "claude-code-managed-settings.json" (
    builtins.toJSON (
      {
        env = {
          CLAUDE_CODE_SUBAGENT_MODEL = cc.smallModel;
          CLAUDE_CODE_AUTO_COMPACT_WINDOW = "1000000";
        };
      }
      // (lib.optionalAttrs (cfg.plugins.marketplaces != { }) {
        extraKnownMarketplaces = cfg.plugins.marketplaces;
      })
      // (lib.optionalAttrs (cfg.plugins.plugins != { }) {
        enabledPlugins = cfg.plugins.plugins;
      })
    )
  );
in
{
  options.agent = {
    providers = lib.mkOption {
      type = lib.types.attrs;
      default = import ../data/providers.nix;
      description = "Provider registry (data/providers.nix), as declared. Prefer reading `agent.resolvedProviders`, which is this set with every agenix-backed tokenSource rewritten to a store path.";
    };

    resolvedProviders = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      internal = true;
      description = "agent.providers with tokenSource rewritten for NixOS. This is what Home Manager should consume.";
    };

    agenixFiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      example = literalExpression ''
        {
          neoplatform = ../../common/secrets/neoplatform-token.age;
        }
      '';
      description = ''
        agenix ciphertext per provider name. NixOS-only — a container has no
        age identity and resolves `tokenSource.env` instead. Providers left out
        keep their env-var tokenSource, i.e. the token is read from the
        environment on NixOS too.
      '';
    };

    plugins = lib.mkOption {
      type = lib.types.attrs;
      default = import ../data/plugins.nix;
    };

    claudeCode = {
      enable = lib.mkEnableOption "Claude Code integration" // {
        default = true;
      };
      provider = lib.mkOption {
        type = lib.types.str;
        default = "neoplatform";
      };
      mainModel = lib.mkOption {
        type = lib.types.str;
        default = "deepseek-v4-flash";
      };
      smallModel = lib.mkOption {
        type = lib.types.str;
        default = "qwen3-coder-128k:30b";
      };
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

    assertions = [
      {
        assertion = !cc.enable || resolvedProviders.${cc.provider} ? tokenSource;
        message = "agent.providers.${cc.provider} has no tokenSource";
      }
    ]
    ++ lib.mapAttrsToList (name: p: {
      assertion = p ? tokenSource && (p.tokenSource ? env || p.tokenSource ? file);
      message = "agent.providers.${name}.tokenSource must have `env` or `file`";
    }) providers;

    environment.etc."claude-code/managed-settings.json".source = managedSettings;

    environment.sessionVariables = lib.mkIf cc.enable {
      ANTHROPIC_BASE_URL = ccProvider.anthropicUrl or ccProvider.url;
    };
  };
}
