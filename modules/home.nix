# Agent configuration for pi, opencode and the provider-pinned commands, plus
# the remaining `agent.*` option surface (modules/options.nix).
#
# This module is evaluator-agnostic: it needs only `lib`, `pkgs`, `config` and
# this flake's own inputs — the latter closed over as `runtimeInputs` by
# flake.nix, never read from the consumer — so the exact same file runs under
# NixOS+Home Manager and under the standalone homeManagerConfiguration in this
# flake's `homeConfigurations`, which is what makes the container config
# identical to the desktop config. Only the token source differs.
{ runtimeInputs }:
{
  config,
  lib,
  pkgs,
  ...
}:

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

  # --- opencode ------------------------------------------------------------
  # cfg.mcp.npm is the npm-installed server set (data/mcp.nix); it is written
  # here and handed to the provider-pinned commands below, each in its own
  # dialect. The other servers reach opencode.json through the `mcp
  # <group|server>` command, which merges a per-server config in.
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
        mcp = lib.mapAttrs (name: srv: {
          type = "local";
          # Absolute path: MCP servers inherit the agent's environment, which
          # may predate home.sessionPath (e.g. GUI-launched) — never rely on PATH.
          command = [ "${npmBinPath}/${srv.command}" ] ++ srv.args;
          enabled = true;
        }) cfg.mcp.npm;
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
        name: srv: srv // { command = "${npmBinPath}/${srv.command}"; }
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
    ]
    ++ lib.optionals cfg.agents.includeTui [ llmAgents.agent-deck ];
in
{
  imports = [
    ./options.nix
    (import ./skills.nix { inherit runtimeInputs; })
  ];

  options.agent = {
    mcp = lib.mkOption {
      type = lib.types.attrs;
      default = import ../data/mcp.nix;
      description = "MCP registry (data/mcp.nix). `npm` is the npm-installed set this module ships to every agent; `servers`+`groups` are what the `mcp <group|server>` command offers.";
    };

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

    npmPrefix = lib.mkOption {
      type = lib.types.str;
      default = "$HOME/.npm";
      description = "npm's prefix (NixOS-wiki home approach). Its bin/ holds the `mcp.npm` servers, so this is where their absolute paths come from.";
    };

    runtimeFiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.raw;
      default = { };
      internal = true;
      description = "Rendered config files as store paths, consumed by this flake's `agent-runtime-config` package.";
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
          lib.concatStringsSep " " (
            map (srv: "${npmBinPath}/${srv.command}") (builtins.attrValues cfg.mcp.npm)
          )
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
