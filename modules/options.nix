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
      description = "Claude Code plugin marketplaces + enabled plugins (data/plugins.nix). Only NixOS consumes them — into the immutable managed-settings.json.";
    };

    claudeCode = {
      enable = lib.mkEnableOption "Claude Code integration" // {
        default = true;
      };
      provider = lib.mkOption {
        type = lib.types.str;
        default = "neoplatform";
        description = "Provider the default `claude` wrapper talks to.";
      };
      mainModel = lib.mkOption {
        type = lib.types.str;
        default = "deepseek-v4-flash";
        description = "Opus/Sonnet tier for `claude`, and the subagent model in managed-settings.json.";
      };
      smallModel = lib.mkOption {
        type = lib.types.str;
        default = "qwen3-coder-128k:30b";
        description = "Haiku tier for `claude`.";
      };
    };
  };
}
