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
          # Per-folder setup instead of a one-shot claude run: it persists the
          # same env into ./.claude/settings.local.json, then exits. (The `claude`
          # command itself is built by modules/worlds.nix and follows the active
          # profile, so it is not pinned to a provider here.)
          writing = {
            provider = "custom";
            script = ../data/scripts/writing.sh;
          };
        };
        description = ''
          Provider-pinned commands, keyed by the command name to install. Each
          exports its provider's ANTHROPIC_* env for its own process only —
          overriding whatever the shell exports — and then execs claude, or the
          `script` when one is given. `claude` itself is profile-driven
          (modules/worlds.nix); this is for the fixed, per-task helpers like
          `writing`.
        '';
      };
    };

    profiles = lib.mkOption {
      type = lib.types.attrs;
      default = import ../data/profiles.nix;
      description = ''
        Profile registry (data/profiles.nix). A profile names a provider, MCP
        servers/groups and skill sources; `lib/worlds.nix` renders each into a
        complete snapshot of the machine-wide config that `profile <name>`
        installs. Profiles are dialect-free and resolved against
        `agent.providers` / `agent.mcp` / the merged agent-skills sources;
        `extends` inherits (checked) another profile. Consumers merge:
        `agent.profiles = lib.data.profiles // { mine = …; };`.
      '';
    };

    defaultProfile = lib.mkOption {
      type = lib.types.str;
      default = "work";
      description = ''
        Profile installed on first activation (and whenever no world is active
        yet). After a user runs `profile <name>`, activation converges to that
        world instead, so a rebuild never resets their choice.
      '';
    };
  };
}
