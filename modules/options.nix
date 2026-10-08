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

    skills.sources = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = ''
        Extra agent-skills sources merged into `programs.agent-skills.sources`
        — the client's own skills, next to the runtime's (data/skills.nix).
        Sources are `path`-addressed (data/skills.nix sets the precedent): a
        flake input name cannot be resolved from inside this flake, so a client
        writes `{ path = "''${inputs.foo}/skills"; }`.

        Declared in both halves on purpose: the NixOS module forwards it into
        every Home Manager configuration, so a NixOS client declares it once,
        next to its agenix files.
      '';
    };

    mcp = lib.mkOption {
      type = lib.types.attrs;
      default = import ../data/mcp.nix;
      description = ''
        MCP registry (data/mcp.nix). `npm` is the npm-installed set this module
        ships to every agent; `servers`+`groups` are what the `mcp
        <group|server>` command offers. A `servers` entry may carry
        `package = "<nixpkgs attr>"`, which is resolved, added to the bundle and
        rendered as a store path.
      '';
    };

    npmPrefix = lib.mkOption {
      type = lib.types.str;
      default = "$HOME/.npm";
      description = ''
        npm's prefix (NixOS-wiki home approach). Its bin/ holds the `mcp.npm`
        servers, so this is the single source for their absolute paths, for
        home.sessionPath, for the activation hook that installs them, and for
        the npmrc the NixOS module sets.
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

    profiles = lib.mkOption {
      type = lib.types.attrs;
      default = import ../data/profiles.nix;
      description = ''
        Profile registry (data/profiles.nix). A profile names providers, mcp
        servers, skills and prompts that a single `profile <name>` call
        activates across claude/opencode/pi. Profiles are dialect-free and
        resolved against `agent.providers` / `agent.mcp` / `agent.skills.sources`
        by `modules/ccswitch.nix`; `extends` inherits (checked) another profile.
        Consumers merge: `agent.profiles = lib.data.profiles // { mine = …; };`.
      '';
    };

    ccSwitch = {
      enable = lib.mkEnableOption ''
        Drive provider/MCP/skill/prompt management for claude/opencode/pi through
        cc-switch-cli (nixpkgs). When on, the runtime compiles the registries
        into cc-switch records on activation and ships `profile`/`provider`
        commands that wrap cc-switch verbs; cc-switch owns the live config files
        its service layer writes, the runtime keeps only the pi files cc-switch
        disclaims (settings.json default model + ~/.pi/agent/mcp.json) and the
        static opencode keys + plugin list. Off by default here.
      '' // { default = false; };

      package = lib.mkOption {
        type = lib.types.package;
        default = null;
        defaultText = lib.literalExpression "pkgs.cc-switch-cli";
        description = ''
          cc-switch-cli package to drive. Null falls back to `pkgs.cc-switch-cli`
          in `modules/ccswitch.nix` when enabled. Override to pin a version or
          swap a fork.
        '';
      };

      # Internal: resolved-profile JSON per name, consumed by the `profile`
      # shim. Built only when enabled, so hosts that leave it off get no farm.
      profileShards = lib.mkOption {
        type = lib.types.attrsOf lib.types.path;
        default = { };
        internal = true;
        description = "Resolved profile JSON (after extends expansion + mcp group expansion), per profile name.";
      };
    };
  };
}
