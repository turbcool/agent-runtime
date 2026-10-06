# The `claude` / `claude-free` / `writing` command wrappers.
#
# Each wrapper pins one provider for its own process only: it exports the
# provider's ANTHROPIC_* env, then execs the real claude with the MCP config
# its agent needs. That env overrides any global shell export, so one wrapper
# per endpoint is all it takes to run the same binary against several providers.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.agent;
  inherit (cfg) providers;

  inherit (pkgs.stdenv.hostPlatform) system;
  realClaude = inputs.claude-code.packages.${system}.default;

  cc = cfg.claudeCode;

  # Claude Code MCP config, built from the same npm-installed server set
  # (data/mcp.nix) that opencode.json gets, in Claude Code's dialect and with
  # absolute $HOME/.npm/bin paths: a wrapper runs inside the agent's environment,
  # which may predate home.sessionPath (GUI launch, container without rc) — so
  # never rely on PATH. No secrets are resolved here; a server that needs one
  # gets it from its own wrapper env.
  claudeMcpConfig = pkgs.writeText "claude-code-mcp.json" (
    builtins.toJSON {
      mcpServers = lib.mapAttrs (
        name: srv: srv // { command = "${config.home.homeDirectory}/.npm/bin/${srv.command}"; }
      ) cfg.mcp.npm;
    }
  );

  mkClaudeMcp = binName: ''
    out="''${XDG_CACHE_HOME:-$HOME/.cache}/claude-code/mcp-${binName}.json"
    mkdir -p "$(dirname "$out")"
    # umask governs creation; chmod also clamps a pre-existing file's mode.
    ( umask 077; cat ${claudeMcpConfig} > "$out" )
    chmod 600 "$out"
    exec "${realClaude}/bin/claude" --mcp-config="$out" "$@"
  '';

  # One provider-pinned claude wrapper. Non-strict --mcp-config, so it merges
  # with ~/.claude.json and project .mcp.json servers, and `claude mcp add`
  # keeps working.
  mkClaudeWrapper = w: ''
    export ANTHROPIC_BASE_URL="${providers.${w.provider}.anthropicUrl or providers.${w.provider}.url}"
    export ANTHROPIC_API_KEY=${cfg.tokenSyntax.${w.provider}.shell}
    export ANTHROPIC_DEFAULT_OPUS_MODEL="${w.mainModel}"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="${w.mainModel}"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="${w.smallModel}"
    export CLAUDE_CODE_SUBAGENT_MODEL="${w.smallModel}"
    ${mkClaudeMcp w.name}
  '';

  # The default `claude`: whatever claudeCode.provider/mainModel/smallModel say.
  # Its env overrides the global exports from the consumer's shell config for
  # this process only.
  defaultWrapper = {
    name = "claude";
    provider = cc.provider;
    inherit (cc) mainModel;
    inherit (cc) smallModel;
    comment = "Primary Claude Code wrapper (managed-settings.json stays in modules/nixos.nix).";
  };

  wrappers = lib.optionals cc.enable (
    map (w: pkgs.writeShellScriptBin w.name (mkClaudeWrapper w)) (
      [ defaultWrapper ] ++ cfg.claudeCode.wrappers
    )
  );

  # The bash lives in data/scripts/writing.sh (shellcheck-able, no Nix string
  # escaping); only its environment comes from here. agent.smallModel is
  # provider-qualified for opencode, so take the model id alone.
  writing = pkgs.writeShellScriptBin "writing" ''
    set -euo pipefail
    export JQ=${lib.escapeShellArg "${pkgs.jq}/bin/jq"}
    export CUSTOM_URL=${lib.escapeShellArg providers.custom.url}
    export CUSTOM_TOKEN=${cfg.tokenSyntax.custom.shell}
    export CUSTOM_TOKEN_SOURCE=${
      lib.escapeShellArg (providers.custom.tokenSource.env or providers.custom.tokenSource.file)
    }
    export MAIN_MODEL=deepseek-v4-flash
    export SMALL_MODEL=${lib.escapeShellArg (lib.last (lib.splitString "/" cfg.smallModel))}
    exec bash ${../data/scripts/writing.sh} "$@"
  '';
in
{
  # Appended to agent.runtimePackages; modules/home.nix mirrors that into
  # home.packages so the container bundle and a desktop login get exactly the
  # same set.
  config.agent.runtimePackages =
    wrappers
    ++ lib.optionals cc.enable [ writing ]
    # The real binary is normally reachable only through the wrappers (which
    # exec it by absolute store path). Opt in if something needs an unwrapped
    # `claude` on PATH — but then it collides with the wrapper.
    ++ lib.optionals (cc.enable && cc.exposeRealBinary) [ realClaude ];
}
