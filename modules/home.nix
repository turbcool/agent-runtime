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
{ runtimeInputs, config, lib, pkgs, ... }:

let
  cfg = config.agent;
  inherit (cfg) providers;

  inherit (pkgs.stdenv.hostPlatform) system;
  llmAgents = runtimeInputs.llm-agents.packages.${system};
  realClaude = runtimeInputs.claude-code.packages.${system}.default;

  # npm installs into $HOME/.npm on NixOS (programs.npm + /etc/npmrc), which is
  # where the `npm` MCP servers' binaries live. One option, three uses: the two
  # MCP renderers (as an absolute path), home.sessionPath (as a shell string, so
  # a container gets it too) and the activation hook that installs them.
  npmBin = "${cfg.npmPrefix}/bin";
  npmBinPath = lib.replaceStrings [ "\$HOME" ] [ config.home.homeDirectory ] npmBin;

  # --- token resolution ---------------------------------------------------
  # One provider field (tokenSource) -> the three dialects each agent speaks.
  # `command` and `shell` are evaluated at request/launch time, so the token is
  # read fresh from the env or the agenix store path and never baked into a
  # config file in the store.
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
        # appears in the command script. (`\$` escapes the Nix interpolation.)
        shell = "\"\$${ts.env}\"";
        command = "!printenv ${ts.env}";
        opencode = "{env:${ts.env}}";
      }
  ) providers;

  # --- pi ------------------------------------------------------------------
  # pi names its model fields differently from opencode:
  # opencode's limit.context/limit.output are pi's contextWindow/maxTokens.
  # Both are required — data/providers.nix states every model's limits.
  toPiModel = id: m: {
    inherit id;
    name = m.name or id;
    contextWindow = m.limit.context;
    maxTokens = m.limit.output;
  };

  # Every provider in data/providers.nix is an OpenAI-compatible proxy. Verified
  # live: {url}/v1/models answers 200 with a bearer token for all three, and
  # llm-free only answers on /v1 — so normalise rather than trusting p.url.
  toPiProvider = name: p: {
    baseUrl = "${lib.removeSuffix "/v1" p.url}/v1";
    api = "openai-completions";
    # "!command" is read at request time and never cached, so the decrypted
    # agenix token (or the env var) exists only in pi's memory — nothing to
    # leak via a JSON file. auth.json would take precedence, so don't run
    # /login for these.
    apiKey = tokenSyntax.${name}.command;
    models = lib.mapAttrsToList toPiModel (p.models or { });
  };

  # llm.defaultModel is opencode's "provider/model" form; pi wants them apart.
  defaultModel = lib.splitString "/" cfg.defaultModel;

  piModels = pkgs.writeText "pi-models.json" (
    builtins.toJSON {
      providers = lib.mapAttrs toPiProvider providers;
    }
  );

  piSettings = pkgs.writeText "pi-settings.json" (
    builtins.toJSON {
      defaultProvider = lib.head defaultModel;
      defaultModel = lib.last defaultModel;

      # Hides every other model from /model and pins Ctrl+P cycling to our own
      # providers. A shell exporting ANTHROPIC_API_KEY + ANTHROPIC_BASE_URL
      # makes pi report the built-in `anthropic` provider as ready, and every
      # bundled Claude model then shows up pointing at the claude-code proxy.
      # The provider-pinned commands keep the key out of the shell environment,
      # so this is a guard now rather than a fix — delete it once pi behaves
      # with it gone.
      enabledModels = lib.mapAttrsToList (name: _: "${name}/*") providers;

      # pi npm-installs declared packages that are missing or out of date on
      # startup (package-manager.js installMissing), so listing them here is
      # enough — no activation hook needed. A network-less container therefore
      # needs its npm packages pre-seeded or it fails on first boot.
      #
      # pi-zentui — full TUI skin, supersedes @narumitw/pi-starship. Its config
      # (~/.pi/agent/zentui.json) is written by pi's /zentui, so it stays
      # user-owned like auth.json. Its Thinking (Experimental) renderer is tested
      # against pi 0.85/0.87 and may misbehave on pi 1.x — disabled by default.
      # donsetch — web_fetch/search/crawl/screenshot as native tools. Its
      # prebuilt Rust binary is glibc, which programs.nix-ld covers on NixOS.
      # @ff-labs/pi-fff — Rust/SIMD FFF search replacing pi's find/grep; mode
      # config below. linux-x64-gnu prebuilds match, nothing is compiled here.
      # @piex-dev/init — /init prompt template that writes the repo's AGENTS.md.
      # Prompt-only, so it costs nothing per request.
      # @juicesharp/rpiv-ask-user-question — one tool, ask_user_question: a
      # tabbed dialog of up to 4 typed-option questions. No config written.
      packages = [
        "npm:pi-zentui"
        "npm:donsetch"
        "npm:@ff-labs/pi-fff"
        "npm:@piex-dev/init"
        "npm:@juicesharp/rpiv-ask-user-question"
      ];

      # Skills and extensions are plain files in the agent dir — declare them
      # next to this module when there are any. Directories are copied, single
      # files are symlinked (edit, then /reload inside pi).
      # home.file.".pi/agent/skills/my-skill" = { source = ../data/pi/skills/my-skill; recursive = true; };
      # home.file.".pi/agent/extensions/foo.ts".source = ../data/pi/extensions/foo.ts;
    }
  );

  # https://pi.dev/packages/@ff-labs/pi-fff
  # "override" swaps pi's built-in find/grep for fffind/ffgrep and adds
  # multi_grep. pi reads this file before registering tools, and /fff-mode only
  # changes the running session (mode changes also want a /reload) — so this
  # file, not the session, is the place the mode is set.
  piFff = pkgs.writeText "pi-fff.json" (
    builtins.toJSON {
      mode = "override";
    }
  );

  # --- MCP ------------------------------------------------------------------
  # One registry (data/mcp.nix), one renderer, three delivery routes:
  #   * npm — npm-installed binaries in npmPrefix/bin, written into
  #     opencode.json *and* into each provider-pinned command's --mcp-config,
  #     so every agent has them;
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

  # The single opencode dialect mapping. Both opencode.json and the farm below
  # go through it, so an entry cannot render differently in the two.
  toOpencodeMcp =
    name: srv:
    if srv ? url then
      {
        type = "remote";
        url = srv.url;
        enabled = true;
      }
    else if cfg.mcp.npm ? ${name} then
      {
        type = "local";
        command = [ (npmCmd srv) ] ++ srv.args;
        enabled = true;
      }
    else if srv ? package then
      {
        type = "local";
        command = [ "${mcpPackages.${name}}/bin/${builtins.head srv.command}" ] ++ lib.tail srv.command;
        enabled = true;
      }
    else
      {
        type = "local";
        inherit (srv) command;
        enabled = true;
      };

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
                value = toOpencodeMcp member cfg.mcp.servers.${member};
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

  # --- opencode ------------------------------------------------------------
  # The npm set lands here through the renderer above; the rest of the registry
  # is per-project, merged in by `mcp <group|server>`.
  opencodeJson = pkgs.writeText "opencode.json" (
    builtins.toJSON (
      {
        "$schema" = "https://opencode.ai/config.json";
        permission = {
          webfetch = "allow";
          websearch = "allow";
          lsp = "allow";
        };
        compaction.reserved = 16000;
        plugin = map (
          name: "${runtimeInputs.${name}.outPath}/.opencode/plugins/${name}.mjs"
        ) cfg.plugins.opencodePlugins;
        agent.explore.model = cfg.smallModel;
        mcp = lib.listToAttrs (
          lib.mapAttrsToList (name: srv: {
            inherit name;
            value = toOpencodeMcp name srv;
          }) cfg.mcp.npm
        );
      }
      // {
        provider = lib.mapAttrs (name: p: {
          inherit name;
          npm = "@ai-sdk/openai-compatible";
          models = p.models or { };
          options = {
            baseURL = p.url;
            apiKey = tokenSyntax.${name}.opencode;
          };
        }) providers;
      }
      // {
        model = cfg.defaultModel;
        small_model = cfg.smallModel;
      }
    )
  );

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

  # --- provider-pinned commands -------------------------------------------
  # `claude`, `claude-free`, `writing`: each exports one provider's ANTHROPIC_*
  # env for its own process — overriding any global shell export — and then runs
  # either the real claude (with the npm MCP servers, see below) or the script
  # the record names. One binary, several endpoints, no global state.
  #
  # Claude Code MCP config, built from the same npm-installed set
  # (data/mcp.nix) that opencode.json gets, in Claude Code's dialect (it infers
  # stdio from `command`) and with absolute $HOME/.npm/bin paths. No secrets are
  # resolved here; a server that needs one gets it from the command's env.
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

  # Rendered config as store files, so the standalone container output can ship
  # them verbatim instead of re-implementing any of the rendering above.
  #
  # One table, two consumers: `runtimeFiles` ships these paths in the
  # `agent-runtime-config` package, `home.file` writes them into a desktop
  # login — same paths, same sources, nothing to keep in sync by hand.
  #
  # Same trick for the binaries: `agent.runtimePackages` is what we contribute
  # to home.packages, which keeps Home Manager's own baseline (man-db,
  # shared-mime-info, the HM reference manpage) out of the container bundle
  # while the two stay identical in content.
  fileSpecs = {
    # ~/.pi/agent/ is split deliberately. models.json is fully declarative here
    # — pi only ever reads it — while settings.json is force-managed just like
    # ~/.config/opencode/opencode.json, so changes made from pi's /settings are
    # reverted on the next activation. auth.json, sessions/, git/ and npm/ stay
    # user-owned so pi's own /login, pi install and session writes work.
    ".pi/agent/models.json" = {
      source = piModels;
    };
    ".pi/agent/settings.json" = {
      source = piSettings;
      force = true;
    };
    ".pi/agent/pi-fff.json" = {
      source = piFff;
      force = true;
    };
    ".config/opencode/opencode.json" = {
      source = opencodeJson;
      force = true;
    };
  };

  runtimeFiles = lib.mapAttrs (_: spec: spec.source) fileSpecs;

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
    ++ [ config.agent.skillTools ]
    ++ lib.optionals cfg.agents.includeTui [ llmAgents.agent-deck ];
in
{
  imports = [
    ./options.nix
    (import ./skills.nix { inherit runtimeInputs; })
  ];

  options.agent = {
    defaultModel = lib.mkOption {
      type = lib.types.str;
      default = "free/main";
      description = "opencode's `provider/model` form. pi splits it apart.";
    };

    smallModel = lib.mkOption {
      type = lib.types.str;
      default = "custom/qwen3-coder-next";
      description = "Small/subagent tier for pi and opencode. One line moves both agents.";
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
    agent.runtimeFiles = runtimeFiles;
    agent.runtimePackages = runtimePackages;

    home = {
      packages = config.agent.runtimePackages;
      file = fileSpecs;
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
