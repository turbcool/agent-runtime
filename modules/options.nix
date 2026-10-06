# Options that both halves of the runtime declare: NixOS (which reads them
# through homeModules) and the standalone homeConfiguration. Declared once so
# the two modules cannot drift apart.
{
  lib,
  ...
}:

{
  options.agent = {
    providers = lib.mkOption {
      type = lib.types.attrs;
      default = import ../data/providers.nix;
      description = ''
        Provider registry (data/providers.nix). On NixOS every provider also
        named in `agent.agenixFiles` gets its `tokenSource` rewritten to the
        agenix store path; Home Manager should read `agent.resolvedProviders`
        there, `agent.providers` everywhere else.
      '';
    };

    plugins = lib.mkOption {
      type = lib.types.attrs;
      default = import ../data/plugins.nix;
      description = "Claude Code plugin marketplaces + enabled plugins (data/plugins.nix), plus the `opencodePlugins` list loaded into opencode.json. NixOS consumes the first two — into the immutable managed-settings.json.";
    };

    claudeCode = {
      enable = lib.mkEnableOption "Claude Code integration" // {
        default = true;
      };
      commands = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              provider = lib.mkOption {
                type = lib.types.str;
                description = "Provider this command talks to; its `url`/`anthropicUrl` and `claudeModel` tiers do the rest.";
              };
              script = lib.mkOption {
                type = lib.types.nullOr lib.types.path;
                default = null;
                description = "Run this bash script instead of claude, with the same ANTHROPIC_* env already exported (data/scripts/writing.sh).";
              };
            };
          }
        );
        default = {
          # The default endpoint: also what environment.sessionVariables
          # publishes as ANTHROPIC_BASE_URL on NixOS.
          claude = {
            provider = "neoplatform";
          };
          claude-free = {
            provider = "free";
          };
          # Per-folder setup instead of a one-shot claude run: it persists the
          # same env into ./.claude/settings.local.json, then exits.
          writing = {
            provider = "custom";
            script = ../data/scripts/writing.sh;
          };
        };
        description = ''
          Provider-pinned commands, keyed by the command name to install. Each
          exports its provider's ANTHROPIC_* env for its own process only —
          overriding whatever the shell exports — and then execs claude, or the
          `script` when one is given.
        '';
      };
    };
  };
}
