# Agent configuration for pi, opencode and the provider-pinned commands, plus
# the remaining `agent.*` option surface (modules/options.nix).
#
# This module is evaluator-agnostic: it needs only `lib`, `pkgs`, `config` and
# this flake's own inputs, passed in as the `runtimeInputs` module argument
# (see flake.nix's mkHmConfig / the runtime's NixOS module, which supplies it
# via `home-manager.extraSpecialArgs`). Because that argument is ordinary
# module input, this file is a plain *path* — Nix' module system dedupes
# identical paths, so a host may import `homeModules.default` itself and still
# get the module injected once through `home-manager.sharedModules`.
#
# The machine-wide config (opencode.json, pi settings/models/mcp, skill trees,
# and the `claude` wrapper that follows the active profile) is owned by
# modules/worlds.nix as a baked "world"; this file keeps only what the world
# deliberately does NOT own: the per-project mcp farm + command, the binaries,
# and the fixed per-task commands (`writing`).
{ runtimeInputs, config, lib, pkgs, ... }:

let
  cfg = config.agent;
  inherit (cfg) providers;

  # opencode's "provider/model" split, used only by the assertion below (the
  # world's own model rendering is lib/worlds.nix's job).
  defaultModel = lib.splitString "/" cfg.defaultModel;

  W = import ../lib/worlds.nix lib;

  inherit (pkgs.stdenv.hostPlatform) system;
  llmAgents = runtimeInputs.llm-agents.packages.${system};
  realClaude = runtimeInputs.claude-code.packages.${system}.default;

  # npm installs into $HOME/.npm on NixOS (programs.npm + /etc/npmrc), which is
  # where the `npm` MCP servers' binaries live. One option, three uses: the MCP
  # renderers (as an absolute path), home.sessionPath (as a shell string, so a
  # container gets it too) and the activation hook that installs them.
  npmBin = "${cfg.npmPrefix}/bin";
  npmBinPath = lib.replaceStrings [ "\$HOME" ] [ config.home.homeDirectory ] npmBin;

  # --- token resolution ---------------------------------------------------
  # One provider field (tokenSource) -> the three dialects each agent speaks.
  # `command` and `shell` are evaluated at request/launch time, so the token is
  # read fresh from the env or the agenix store path and never baked into a
  # config file in the store. (The per-agent renderers live in lib/worlds.nix;
  # this map only feeds the `writing` command's env below.)
  tokenSyntax = lib.mapAttrs (
    _: p:
    let
      ts = p.tokenSource or { };
    in
    if ts ? file then
      {
        shell = "$(cat ${lib.escapeShellArg ts.file})";
        command = "!cat ${ts.file}";
        opencode = "{file:${ts.file}}";
      }
    else
      {
        # "$VAR" — expanded by the shell at launch time, so the key itself never
        # appears in the command script. Built by concatenation because a Nix
        # string "$${ts.env}" is the literal text `$${ts.env}`; this is the
        # container path (on NixOS agenix rewrites to the `file` branch above).
        shell = "\"" + "$" + ts.env + "\"";
        command = "!printenv ${ts.env}";
        opencode = "{env:${ts.env}}";
      }
  ) providers;

  # --- MCP ------------------------------------------------------------------
  # One registry (data/mcp.nix), one renderer (lib/worlds.nix's toOcMcp, so the
  # world and this per-project farm can never drift), two delivery routes:
  #   * npm — npm-installed binaries in npmPrefix/bin, exposed to every agent
  #     (written into the world by modules/worlds.nix);
  #   * servers/groups — opt-in per project through the `mcp` command, whose
  #     farm below holds one rendered fragment per name.
  #
  # A command is absolute wherever this module knows the binary: npm ones from
  # npmPrefix, `package`-backed ones from the store. An agent inherits the
  # environment it was launched with, which may predate home.sessionPath (GUI
  # launch, container without an rc file), so PATH is never the answer. A
  # command the registry leaves alone (a `docker run` argv, an `npx`
  # invocation) resolves its own tools and is passed through verbatim.
  npmCmd = srv: "${npmBinPath}/${srv.command}";

  # Entries naming a nixpkgs package rather than something installed per user.
  # The package joins the bundle below, so the registry alone decides what a
  # client has to install — nothing to remember on the host side.
  mcpPackages = lib.mapAttrs (_: srv: pkgs.${srv.package}) (
    lib.filterAttrs (_: srv: srv ? package) cfg.mcp.servers
  );

  mcpConfigDir = pkgs.linkFarm "agent-runtime-mcp-configs" (
    lib.mapAttrsToList (name: src: {
      name = "${name}.json";
      path = toString src;
    }) (
      lib.mapAttrs (
        name: members:
        pkgs.writeText "opencode-mcp-${name}.json" (
          builtins.toJSON {
            mcp = lib.listToAttrs (
              map (member: {
                name = member;
                value = W.toOcMcp cfg.mcp npmBinPath mcpPackages member;
              })
              members
            );
          }
        )
      ) (cfg.mcp.groups // lib.mapAttrs (name: _: [ name ]) cfg.mcp.servers)
    )
  );

  mcpUsage = ''
    Usage: mcp <group|server>

    Groups:
    ${lib.concatStringsSep "\n" (
      map (name: "  ${name} → ${lib.concatStringsSep ", " cfg.mcp.groups.${name}}") (lib.attrNames cfg.mcp.groups)
    )}

    Servers:
    ${lib.concatMapStringsSep "\n" (name: "  ${name}") (lib.attrNames cfg.mcp.servers)}
  '';

  # Shipped in the bundle, so the desktop login and a container get the same
  # command from the same place: activating a group is a local file read.
  mcpCommand = pkgs.writeShellScriptBin "mcp" ''
    if [ $# -eq 0 ]; then
      echo "${mcpUsage}"
      exit 0
    fi

    config="${mcpConfigDir}/$1.json"
    if [ ! -f "$config" ]; then
      echo "✗ Unknown MCP group or server: $1"
      echo ""
      echo "${mcpUsage}"
      exit 1
    fi

    if [ -f opencode.json ]; then
      ${pkgs.jq}/bin/jq -s '.[0] * .[1]' opencode.json "$config" > opencode.json.tmp \
        && mv opencode.json.tmp opencode.json
    else
      cp "$config" opencode.json
    fi
    echo "✓ MCP servers activated: $1"
  '';

  # --- binaries ------------------------------------------------------------
  # Hides donsetch's web_crawl from pi. pi has no settings key for this —
  # `defaultTools` cannot do it either, because AgentSession passes
  # `includeAllExtensionTools: true` unconditionally, which re-activates every
  # extension tool regardless of that list. Only --exclude-tools reaches
  # _excludedToolNames.
  piNoCrawl = pkgs.runCommand "pi-no-crawl" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
    mkdir -p "$out/bin"
    makeWrapper ${llmAgents.pi}/bin/pi "$out/bin/pi" --add-flags "--exclude-tools web_crawl"
  '';

  # --- fixed per-task commands --------------------------------------------
  # `writing` (and any consumer-declared command) exports one provider's
  # ANTHROPIC_* env for its own process — overriding any global shell export —
  # and runs the named script. The main `claude` command is NOT here: it is
  # profile-driven (modules/worlds.nix), reading the active world's provider.
  claudeMcpConfig = pkgs.writeText "claude-code-mcp.json" (
    builtins.toJSON {
      mcpServers = lib.mapAttrs (
        name: srv: srv // { command = npmCmd srv; }
      ) cfg.mcp.npm;
    }
  );

  mkCommand =
    name: c:
    let
      p = providers.${c.provider};
    in
    ''
      # Claude Code speaks the Anthropic API, which these endpoints serve from
      # the OpenAI-compatible base minus the /v1 suffix.
      export ANTHROPIC_BASE_URL="${lib.removeSuffix "/v1" p.url}"
      export ANTHROPIC_API_KEY=${tokenSyntax.${c.provider}.shell}
      export ANTHROPIC_DEFAULT_OPUS_MODEL="${p.claudeModel.main}"
      export ANTHROPIC_DEFAULT_SONNET_MODEL="${p.claudeModel.main}"
      export ANTHROPIC_DEFAULT_HAIKU_MODEL="${p.claudeModel.small}"
      export CLAUDE_CODE_SUBAGENT_MODEL="${p.claudeModel.small}"
      export CLAUDE_CODE_AUTO_COMPACT_WINDOW="1000000"
    ''
    + (
      if (c.script or null) != null then
        # The bash lives in data/scripts/ (shellcheck-able, no Nix string
        # escaping); only its environment comes from here.
        ''
          export JQ=${lib.escapeShellArg "${pkgs.jq}/bin/jq"}
          exec bash ${c.script} "$@"
        ''
      else
        # Non-strict --mcp-config, so it merges with ~/.claude.json and project
        # .mcp.json servers, and `claude mcp add` keeps working.
        ''
          out="''${XDG_CACHE_HOME:-$HOME/.cache}/claude-code/mcp-${name}.json"
          mkdir -p "$(dirname "$out")"
          # umask governs creation; chmod also clamps a pre-existing file's mode.
          ( umask 077; cat ${claudeMcpConfig} > "$out" )
          chmod 600 "$out"
          exec "${realClaude}/bin/claude" --mcp-config="$out" "$@"
        ''
    );

  commands = lib.mapAttrsToList (name: c: pkgs.writeShellScriptBin name (mkCommand name c)) (
    lib.optionalAttrs cfg.claudeCode.enable cfg.claudeCode.commands
  );

  runtimePackages =
    commands
    ++ [
      llmAgents.opencode
      piNoCrawl
      mcpCommand
    ]
    ++ builtins.attrValues mcpPackages
    # modules/skills.nix builds the per-project installers and the `skills`
    # dispatcher from the merged source set.
    ++ [ config.agent.skillTools ];
in
{
  imports = [
    ./options.nix
    (import ./skills.nix { inherit runtimeInputs; })
    # Worlds: the pre-rendered provider/mcp/skill snapshots + the `profile`
    # command and the profile-following `claude` wrapper. Owns every
    # machine-wide config file (see the module header).
    ./worlds.nix
  ];

  options.agent = {
    defaultModel = lib.mkOption {
      type = lib.types.str;
      default = "free/main";
      description = "opencode's `provider/model` form. pi splits it apart. The world's provider normally overrides this per profile; kept as the standalone fallback.";
    };

    smallModel = lib.mkOption {
      type = lib.types.str;
      default = "custom/qwen3-coder-next";
      description = "Small/subagent tier for pi *and* opencode. One line moves both agents.";
    };

    agents.includeTui = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Also install agent-deck. Turn off for slim/headless bundles.";
    };

    runtimeFiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.raw;
      default = { };
      internal = true;
      description = "Rendered config files as store paths, consumed by this flake's `agent-runtime-config` package.";
    };

    mcpCommand = lib.mkOption {
      type = lib.types.package;
      internal = true;
      default = mcpCommand;
      description = "The `mcp` command, rendered from this configuration's own registry. Published as `packages.mcp` so a client can depend on it alone.";
    };

    runtimePackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      internal = true;
      description = "Packages contributed by this module. Mirrored into home.packages, and the bulk of this flake's `agent-runtime` package.";
    };
  };

  config = {
    agent.runtimeFiles = { };
    agent.runtimePackages = runtimePackages;

    home = {
      packages = config.agent.runtimePackages;
      file = { };
      sessionPath = [ npmBin ];

      # The npm-installed MCP servers are not Nix packages — they are binaries
      # in npmPrefix/bin, so keep them present declaratively: a fresh machine,
      # or a wiped $HOME/.npm, gets them back on the next activation instead of
      # failing with "Executable not found in PATH". The list is the registry
      # itself (agent.mcp.npm), so a new server needs no edit here.
      activation.installMcpServers = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        for cmd in ${
          lib.concatStringsSep " " (map npmCmd (builtins.attrValues cfg.mcp.npm))
        }; do
          [ -x "$cmd" ] || {
            $DRY_RUN_CMD ${pkgs.nodejs}/bin/npm install --prefix "${cfg.npmPrefix}" -g \
            ${lib.concatStringsSep " " (builtins.attrNames cfg.mcp.npm)}
            break
          }
        done
      '';
    };

    # pi coding-agent — https://pi.dev
    assertions = [
      {
        assertion = lib.length defaultModel == 2;
        message = "agent.defaultModel must be \"provider/model\", got '${cfg.defaultModel}'";
      }
    ]
    # agent.defaultModel / agent.smallModel are "provider/model": both halves
    # must exist, or an agent silently falls back to its own defaults.
    ++
      map
        (
          ref:
          let
            parts = lib.splitString "/" ref;
          in
          {
            assertion = providers ? ${lib.head parts} && providers.${lib.head parts}.models ? ${lib.last parts};
            message = "agent.defaultModel/agent.smallModel: '${ref}' names no such model of that provider in data/providers.nix";
          }
        )
        [
          cfg.defaultModel
          cfg.smallModel
        ]
    ++ lib.mapAttrsToList (name: c: {
      assertion = providers ? ${c.provider} && providers.${c.provider} ? claudeModel;
      message = "agent.claudeCode.commands.${name} points at '${c.provider}', which has no claudeModel tiers in data/providers.nix";
    }) cfg.claudeCode.commands
    ++ lib.mapAttrsToList (name: p: {
      assertion = p ? tokenSource && (p.tokenSource ? env || p.tokenSource ? file);
      message = "agent.providers.${name}.tokenSource must have `env` or `file`";
    }) providers;
  };
}