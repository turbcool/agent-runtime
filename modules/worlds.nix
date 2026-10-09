# Worlds: pre-rendered, immutable snapshots of every machine-wide agent config,
# installed atomically by one `profile <name>` command.
#
# This replaces modules/ccswitch.nix (see PLAN.md). cc-switch owned live files
# through a stateful DB and a CLI that only set *some* keys, which forced three
# per-app exceptions and left every file with two writers. Here a world is a
# single baked directory; the installer copies it, so:
#
#   * one writer per file (this module) — home.nix force-writes none of them;
#   * switching is idempotent — installing the same world twice is byte-equal;
#   * activation converges to the *active* world (read from a state file), so a
#     rebuild never silently resets a user's choice.
#
# What a world owns (machine-wide, in $HOME):
#   .config/opencode/opencode.json   provider + model + static keys + mcp
#   .pi/agent/{models,settings,mcp,pi-fff}.json
#   .agents/skills, .claude/skills, .config/opencode/skills  (skill link-trees)
#
# What it deliberately does NOT own: ~/.claude.json and ~/.claude/settings.json
# (claude's mutable state + plugin flow). Claude Code is driven by the `claude`
# wrapper, which reads the active world and injects that provider's env + MCP.
{ runtimeInputs, config, lib, pkgs, ... }:

let
  cfg = config.agent;
  W = import ../lib/worlds.nix lib;

  home = config.home.homeDirectory;
  npmBin = lib.replaceStrings [ "$HOME" ] [ home ] "${cfg.npmPrefix}/bin";

  # package-backed mcp servers → store path, so their command is absolute.
  serverPaths = lib.mapAttrs (_: srv: pkgs.${srv.package}) (
    lib.filterAttrs (_: srv: srv ? package) cfg.mcp.servers
  );

  # pi's npm extension list (ported from the old force-managed settings.json).
  piPackages = [
    "npm:pi-zentui"
    "npm:donsetch"
    "npm:@ff-labs/pi-fff"
    "npm:@piex-dev/init"
    "npm:@juicesharp/rpiv-ask-user-question"
  ];

  opencodePlugins = map (name: "${runtimeInputs.${name}.outPath}/.opencode/plugins/${name}.mjs") cfg.plugins.opencodePlugins;

  renderArgs = {
    profiles = cfg.profiles;
    providers = cfg.providers;
    mcp = cfg.mcp;
    opencodePlugins = opencodePlugins;
    piPackages = piPackages;
    npmBin = npmBin;
    serverPaths = serverPaths;
    smallModel = cfg.smallModel;
  };

  # One skill bundle per profile: the skills of that profile's sources, shared
  # by all three machine-wide trees (a skill is just a dir with SKILL.md).
  agentLib = runtimeInputs.agent-skills.lib.agent-skills;
  catalog = agentLib.discoverCatalog config.programs.agent-skills.sources;
  skillBundle =
    names:
    if names == [ ] then
      pkgs.runCommand "world-skills-empty" { } "mkdir -p $out"
    else
      agentLib.mkBundle {
        inherit pkgs;
        selection = agentLib.selectSkills {
          inherit catalog;
          sources = config.programs.agent-skills.sources;
          allowlist = agentLib.allowlistFor {
            inherit catalog;
            sources = config.programs.agent-skills.sources;
            enableAll = names;
          };
          skills = { };
        };
      };

  skillTargets = {
    agents = ".agents/skills";
    claude = ".claude/skills";
    opencode = ".config/opencode/skills";
  };

  # The baked world directory: HOME-relative config files + meta/ (the wrapper's
  # inputs) + skills/ (one bundle per target).
  worldDir =
    name:
    let
      w = W.render (renderArgs // { inherit name; });
    in
    pkgs.linkFarm "world-${name}" (
      (lib.mapAttrsToList (dest: contents: {
        name = dest;
        path = pkgs.writeText "world-${name}${dest}" contents;
      }) (lib.filterAttrs (dest: _: !lib.hasPrefix "claude-mcp.json" dest) w.files))
      ++ [
        {
          name = "meta/claude-mcp.json";
          path = pkgs.writeText "world-${name}-claude-mcp.json" w.files."claude-mcp.json";
        }
        {
          name = "meta/provider.json";
          path = pkgs.writeText "world-${name}-provider.json" (
            builtins.toJSON {
              inherit name;
              provider = w.provider;
              model = "${w.provider}/${cfg.providers.${w.provider}.claudeModel.main}";
            }
          );
        }
      ]
      ++ (lib.mapAttrsToList (t: _: {
        name = "skills/${t}";
        path = skillBundle w.skills;
      }) skillTargets)
    );

  worlds = lib.mapAttrs (name: _: worldDir name) cfg.profiles;
  worldsDir = pkgs.linkFarm "agent-runtime-worlds" (lib.mapAttrsToList (n: p: {
    name = n;
    path = p;
  }) worlds);

  defaultWorld = cfg.defaultProfile;
  defaultRendered = W.render (renderArgs // { name = defaultWorld; });
  sourceNames = lib.attrNames config.programs.agent-skills.sources;

  # Provider facts the `claude` wrapper needs to inject env for whichever
  # provider the active world selected. keyShell is an expression (`$(cat
  # <agenix path>)`), never a key.
  providersMeta = pkgs.writeText "world-providers.json" (
    builtins.toJSON (
      lib.mapAttrs (
        n: p:
        let
          ts = W.tokenSyntaxFor n p;
        in
        {
          baseUrl = lib.removeSuffix "/v1" p.url;
          keyShell = ts.shell;
          main = p.claudeModel.main;
          small = p.claudeModel.small;
        }
      ) cfg.providers
    )
  );

  stateFile = ".local/state/agent-runtime/world";

  # The one installer, shared by the `profile` command and activation.
  installer = pkgs.writeShellScript "agent-runtime-install-world" ''
    set -euo pipefail
    W=${lib.escapeShellArg "${worldsDir}"}
    world="''${1:-}"
    [ -d "$W/$world" ] || { echo "✗ Unknown profile: $world" >&2; exit 2; }

    # config files: copy everything except meta/ and skills/
    while IFS= read -r f; do
      rel="''${f#$W/$world/}"
      dest="$HOME/$rel"
      mkdir -p "$(dirname "$dest")"
      cp -f "$f" "$dest"
    done < <(find -L "$W/$world" -type f ! -path "*/meta/*" ! -path "*/skills/*")

    # skills: replace the store-backed symlink trees with this world's bundle
    for t in agents claude opencode; do
      case $t in
        agents)   dest="$HOME/.agents/skills" ;;
        claude)   dest="$HOME/.claude/skills" ;;
        opencode) dest="$HOME/.config/opencode/skills" ;;
      esac
      mkdir -p "$dest"
      # drop only symlinks we own (into the store); leave anything else alone
      find "$dest" -maxdepth 1 -type l -lname '/nix/store/*' -delete 2>/dev/null || true
      src="$W/$world/skills/$t"
      if [ -d "$src" ]; then
        for s in "$src"/*; do
          [ -e "$s" ] || continue
          ln -sfn "$s" "$dest/$(basename "$s")"
        done
      fi
    done

    mkdir -p "$(dirname "$HOME/${stateFile}")"
    printf '%s\n' "$world" > "$HOME/${stateFile}"
  '';

  # `profile <name>` — the whole user-facing switch surface.
  profileCommand = pkgs.writeShellScriptBin "profile" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail
    worlds=${lib.escapeShellArg "${worldsDir}"}
    names="${lib.concatStringsSep " " (lib.attrNames cfg.profiles)}"
    if [ $# -eq 0 ]; then
      echo "Usage: profile <name>"
      echo ""
      echo "Profiles:"
      for n in $names; do echo "  $n"; done
      echo ""
      echo "Current: $(cat "$HOME/${stateFile}" 2>/dev/null || echo "(none yet — activating ${defaultWorld})")"
      exit 0
    fi
    "${installer}" "$1"
    echo "✓ Profile $1 active — restart opencode/pi/claude to pick it up."
  '';

  # `claude` now follows the active world: read the world → its provider → that
  # provider's env, inject it (overriding any global ANTHROPIC_* in the shell)
  # and pass the world's MCP config. Claude's settings.json.env would beat the
  # process env and is never expanded, so the key is injected here, at launch,
  # straight from the agenix path — never written to a file or the store.
  claudeCommand = pkgs.writeShellScriptBin "claude" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail
    meta=${lib.escapeShellArg "${providersMeta}"}
    worlds=${lib.escapeShellArg "${worldsDir}"}
    jqbin=${lib.escapeShellArg "${pkgs.jq}/bin/jq"}
    world=$(cat "$HOME/${stateFile}" 2>/dev/null || true)
    [ -n "$world" ] && [ -d "$worlds/$world" ] || world=${lib.escapeShellArg defaultWorld}
    provider=$("$jqbin" -r '.provider' "$worlds/$world/meta/provider.json")
    row=$("$jqbin" -r --arg p "$provider" '.[$p]' "$meta")

    export ANTHROPIC_BASE_URL="$("$jqbin" -r '.baseUrl' <<<"$row")"
    export ANTHROPIC_API_KEY=$(eval "$("$jqbin" -r '.keyShell' <<<"$row")")
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$("$jqbin" -r '.main' <<<"$row")"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$("$jqbin" -r '.main' <<<"$row")"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$("$jqbin" -r '.small' <<<"$row")"
    export CLAUDE_CODE_SUBAGENT_MODEL="$("$jqbin" -r '.small' <<<"$row")"
    export CLAUDE_CODE_AUTO_COMPACT_WINDOW="1000000"

    # world's MCP config, written 0600 like the old commands did
    out="''${XDG_CACHE_HOME:-$HOME/.cache}/claude-code/mcp-$world.json"
    mkdir -p "$(dirname "$out")"
    ( umask 077; cat "$worlds/$world/meta/claude-mcp.json" > "$out" )
    chmod 600 "$out"
    exec ${lib.escapeShellArg "${runtimeInputs.claude-code.packages.${pkgs.stdenv.hostPlatform.system}.default}/bin/claude"} --mcp-config="$out" "$@"
  '';
in
{
  config = {
    agent.runtimePackages = [
      profileCommand
      claudeCommand
    ];

    # The container bundle ships the DEFAULT world's files and skill trees
    # verbatim (agent-runtime-config), so a `COPY`-style container starts with a
    # working config; on a desktop the activation below installs them instead.
    agent.runtimeFiles =
      lib.mapAttrs (
        dest: contents: pkgs.writeText "world-file${dest}" contents
      ) (
        lib.filterAttrs (dest: _: dest != "claude-mcp.json" && !lib.hasPrefix "meta/" dest) defaultRendered.files
      )
      // lib.mapAttrs' (t: dest: {
        name = dest;
        value = skillBundle defaultRendered.skills;
      }) skillTargets;

    # activation converges to the ACTIVE world, or bakes in the default on a
    # fresh machine. Idempotent, and never overrides a user's `profile` choice.
    home.activation.installWorld = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      active=$(cat "$HOME/${stateFile}" 2>/dev/null || true)
      "${installer}" "''${active:-${defaultWorld}}"
    '';

    assertions = [
      # A profile naming a skill source that does not exist would silently
      # yield an empty bundle; catch it here rather than at a `profile` call.
      {
        assertion = lib.all (
          name: lib.all (s: lib.elem s sourceNames) (W.resolveProfile cfg.profiles name).skills
        ) (lib.attrNames cfg.profiles);
        message = "a profile names a skill source that is not in the merged agent-skills source set (${lib.concatStringsSep ", " sourceNames})";
      }
    ];
  };
}