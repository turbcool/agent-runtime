# Pure renderer: turn the agent-runtime registries (providers / mcp / skills /
# profiles) into a "world" — one complete, immutable snapshot of every
# machine-wide agent config file that a single provider+MCP+skill selection
# needs. Switching profiles is then an atomic copy of one baked directory,
# not N imperative edits.
#
# This replaces the cc-switch-cli design. The reasons are in PLAN.md, but the
# short version: cc-switch owns its config files through a stateful DB plus a
# CLI that only sets *some* keys, which forced three per-app exceptions
# (key-less claude records, an OPENCODE_CONFIG overlay for opencode's model,
# a jq-written pi settings.json) and left every file with two writers. A world
# has one writer — this renderer — and the switch is a file copy.
#
# Import style: a plain function `lib: { … }`, so the check does
#   let worlds = (import ./lib/worlds.nix) lib;
# with no Home Manager and no `config`.
#
# Token handling is unchanged from the previous design: every rendered key is an
# *expression* the agent evaluates at request time (`!cat <agenix path>` for pi,
# `{file:<agenix path>}` / `{env:VAR}` for opencode), so no key is ever baked
# into a file in the store. Claude Code is the one agent whose settings.json.env
# beats the process environment and is never expanded, so claude is NOT driven
# by a written file at all: the `claude` wrapper reads the active world and
# injects the key itself. See modules/worlds.nix.
lib:

let
  inherit (lib) mapAttrs mapAttrsToList concatLists concatMap removeSuffix optionals;

  inherit (lib.strings) escapeShell;

  head0 = xs: builtins.head xs;
  last0 = xs: builtins.elemAt xs ((builtins.length xs) - 1);
in
rec {
  # --- profile resolution -------------------------------------------------
  # `extends` merges into a leaf: provider replaces, mcp/skills are unions.
  # Throws on an unknown name or a cycle (both caught by checks.worlds-resolve).
  resolveProfile = profiles: name:
    let
      walk =
        seen: n:
        let
          p = profiles.${n} or (throw "world: unknown profile '${n}'");
        in
        if builtins.elem n seen then
          throw "world: cycle on profile '${n}'"
        else
          let
            parent = if p ? extends then walk (seen ++ [ n ]) p.extends else { };
          in
          {
            provider = p.provider or parent.provider or (throw "world: profile '${n}' names no provider");
            mcp = (parent.mcp or [ ]) ++ (p.mcp or [ ]);
            skills = (parent.skills or [ ]) ++ (p.skills or [ ]);
          };
    in
    walk [ ] name;

  # A profile may name an mcp group ("frontend") or a server/npm entry
  # ("donsetch"); expand groups to their members and dedup, preserving order.
  expandMcp = mcpReg: names:
    lib.lists.unique (
      concatMap
        (n:
          if mcpReg.groups ? ${n} then
            mcpReg.groups.${n}
          else if (mcpReg.servers ? ${n} || mcpReg.npm ? ${n}) then
            [ n ]
          else
            throw "world: '${n}' is not an mcp server, group or npm entry")
        names
    );

  # --- token syntax -------------------------------------------------------
  # One tokenSource field → the three dialects. `command`/`shell` are evaluated
  # by the agent or the wrapper at launch, so a key is never written down.
  tokenSyntaxFor =
    provider: p:
    let
      ts = p.tokenSource or { };
    in
    if ts ? file then
      {
        shell = "$(cat ${escapeShell ts.file})";
        command = "!cat ${ts.file}";
        opencode = "{file:${ts.file}}";
      }
    else
      {
        # "$VAR" — expanded by the shell at launch, so the key itself never
        # lands in a script or a file. Built by concatenation: a Nix string
        # "$${ts.env}" is the *literal* text `$${ts.env}` (a `$` not followed by
        # an interpolation is left alone), which silently yielded an empty key
        # on the env path (only reachable in containers — on NixOS agenix
        # rewrites every token to the `file` branch above).
        shell = "\"" + "$" + ts.env + "\"";
        command = "!printenv ${ts.env}";
        opencode = "{env:${ts.env}}";
      };

  # --- per-agent model dialects -------------------------------------------
  # opencode's limit.context/limit.output are pi's contextWindow/maxTokens.
  toPiModel =
    id: m:
    {
      inherit id;
      name = m.name or id;
      contextWindow = m.limit.context;
      maxTokens = m.limit.output;
    };

  toPiProvider =
    name: p:
    let
      ts = tokenSyntaxFor name p;
    in
    {
      baseUrl = "${removeSuffix "/v1" p.url}/v1";
      api = "openai-completions";
      apiKey = ts.command;
      models = mapAttrsToList toPiModel (p.models or { });
    };

  # ---- MCP dialects ------------------------------------------------------
  # `kind` is "url" | "npm" | "package" | "raw"; one dispatcher keeps the
  # opencode/pi/claude renderings from drifting.
  mcpCommand =
    npmBin: serverPaths: kind: name: srv:
    if kind == "npm" then
      [ "${npmBin}/${srv.command}" ] ++ (srv.args or [ ])
    else if kind == "package" then
      [ "${serverPaths.${name}}/bin/${head0 srv.command}" ] ++ lib.tail srv.command
    else
      srv.command;

  mcpKind = mcpReg: serverPaths: name: srv:
    if srv ? url then
      "url"
    else if mcpReg.npm ? ${name} then
      "npm"
    else if serverPaths ? ${name} then
      "package"
    else
      "raw";

  # opencode's dialect (type/enabled + absolute command).
  toOcMcp =
    mcpReg: npmBin: serverPaths: name:
    let
      srv = mcpReg.servers.${name} or mcpReg.npm.${name};
      kind = mcpKind mcpReg serverPaths name srv;
    in
    if kind == "url" then
      {
        type = "remote";
        url = srv.url;
        enabled = true;
      }
    else
      {
        type = "local";
        command = mcpCommand npmBin serverPaths kind name srv;
        enabled = true;
      };

  # pi's dialect: mcpServers: { name: { command, args } } or { url }.
  toPiMcp =
    mcpReg: npmBin: serverPaths: name:
    let
      srv = mcpReg.servers.${name} or mcpReg.npm.${name};
      kind = mcpKind mcpReg serverPaths name srv;
      argv = mcpCommand npmBin serverPaths kind name srv;
    in
    if kind == "url" then
      { url = srv.url; }
    else
      {
        command = head0 argv;
        args = lib.tail argv;
      };

  # Claude Code's dialect (mcpServers, infers stdio from command).
  toClaudeMcp =
    mcpReg: npmBin: serverPaths: name:
    let
      srv = mcpReg.servers.${name} or mcpReg.npm.${name};
      kind = mcpKind mcpReg serverPaths name srv;
      argv = mcpCommand npmBin serverPaths kind name srv;
    in
    {
      command = head0 argv;
      args = lib.tail argv;
    };

  # --- the world ----------------------------------------------------------
  # render args:
  #   profiles      the profile registry
  #   providers     the provider registry (all of them land in pi's models.json)
  #   mcp           the mcp registry
  #   name          the profile to render
  #   opencodePlugins  already-resolved store paths for opencode's plugin list
  #   piPackages       pi's npm package list
  #   npmBin        absolute path of $npmPrefix/bin
  #   serverPaths   package-backed mcp servers → store path
  #   smallModel    "provider/model" for the small/subagent tier
  # Returns { provider, skills, files } where `files` maps a $HOME-relative
  # path to its rendered JSON (as a string, wrapped with writeText by the module).
  render =
    {
      profiles,
      providers,
      mcp,
      name,
      opencodePlugins ? [ ],
      piPackages ? [ ],
      npmBin,
      serverPaths ? { },
      smallModel,
    }:
    let
      r = resolveProfile profiles name;
      worldMcp = expandMcp mcp r.mcp;
      provider = providers.${r.provider} or (throw "world: profile '${name}' names unknown provider '${r.provider}'");
      ts = tokenSyntaxFor r.provider provider;

      # claudeModel.main is always a real model of the endpoint (checked), and
      # it is the same id pi/opencode address it by, so one field drives all
      # three agents' default model.
      defaultModel = "${r.provider}/${provider.claudeModel.main}";

      # npm servers are always on for every agent; a profile's `mcp` list adds
      # opt-in servers/groups on top of them.
      allMcp = lib.lists.unique (builtins.attrNames mcp.npm ++ worldMcp);

      ocMcp = name: toOcMcp mcp npmBin serverPaths name;
      piMcp = name: toPiMcp mcp npmBin serverPaths name;
      claudeMcp = name: toClaudeMcp mcp npmBin serverPaths name;

      providerBlock =
        name': p:
        {
          inherit name';
          npm = "@ai-sdk/openai-compatible";
          models = p.models or { };
          options = {
            baseURL = p.url;
            apiKey = (tokenSyntaxFor name' p).opencode;
          };
        };

      files = {
        ".config/opencode/opencode.json" = builtins.toJSON {
          "$schema" = "https://opencode.ai/config.json";
          permission = {
            webfetch = "allow";
            websearch = "allow";
            lsp = "allow";
          };
          compaction.reserved = 16000;
          plugin = opencodePlugins;
          agent.explore.model = smallModel;
          mcp = lib.listToAttrs (map (n: {
            name = n;
            value = ocMcp n;
          }) allMcp);
          provider = lib.mapAttrs providerBlock providers;
          model = defaultModel;
          small_model = smallModel;
        };

        ".pi/agent/models.json" = builtins.toJSON {
          providers = lib.mapAttrs (
            n: p:
            let
              x = tokenSyntaxFor n p;
            in
            {
              baseUrl = "${removeSuffix "/v1" p.url}/v1";
              api = "openai-completions";
              apiKey = x.command;
              models = mapAttrsToList toPiModel (p.models or { });
            }
          ) providers;
        };

        ".pi/agent/settings.json" = builtins.toJSON {
          defaultProvider = r.provider;
          defaultModel = provider.claudeModel.main;
          enabledModels = map (n: "${n}/*") (lib.attrNames providers);
          packages = piPackages;
        };

        ".pi/agent/mcp.json" = builtins.toJSON {
          mcpServers = lib.listToAttrs (map (n: {
            name = n;
            value = piMcp n;
          }) allMcp);
        };

        ".pi/agent/pi-fff.json" = builtins.toJSON {
          mode = "override";
        };
      };

      # claude's MCP, handed to the `claude` wrapper via --mcp-config. This is
      # a 0600 file the wrapper writes at launch (like the previous commands),
      # not a written world file, so ~/.claude.json stays user-owned.
      claudeMcpConfig = builtins.toJSON {
        mcpServers = lib.listToAttrs (map (n: {
          name = n;
          value = claudeMcp n;
        }) allMcp);
      };
    in
    {
      provider = r.provider;
      skills = lib.lists.unique r.skills;
      files = files // { "claude-mcp.json" = claudeMcpConfig; };
    };
}