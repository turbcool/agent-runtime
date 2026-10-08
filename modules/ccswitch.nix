# cc-switch-cli as the runtime switch engine.
#
# PR1 (additive; enable = false by default → no host behaviour change):
#   * `lib/ccswitch.nix` — pure dialect renderers + profile resolver, exercised
#     by `checks.profiles-resolve` so a bad profile fails `nix flake check`
#     instead of a `profile` call.
#   * baked shard farms + `profile`/`provider` shims + a seed activation, emitted
#     only `mkIf cfg.ccSwitch.enable`, so a host that leaves it off sees no
#     cc-switch-cli in its closure and no file changes.
#
# Ownership (see PLAN.md): cc-switch owns ~everything that moves at runtime
# (providers, mcp, skills, prompts, *.skills dirs, claude ~/.claude.json,
# opencode opencode.json, pi models.json); the runtime owns only the two pi
# files cc-switch disclaims (settings.json defaults + ~/.pi/agent/mcp.json),
# the static opencode keys (via OPENCODE_CONFIG), and /etc managed-settings
# (plugins).
#
# Smoke-tested against cc-switch-cli 5.10.5: key-less `provider add
# --config-file` accepted; `{file:…}`/`!printenv` keys pass through verbatim;
# `--app pi mcp …` errors ("does not support pi") → pi mcp.json handled here.
{ config, lib, pkgs, ... }:

let
  cfg = config.agent;
  render = (import ../lib/ccswitch.nix) lib;
  enabled = cfg.ccSwitch.enable;
  cc = cfg.ccSwitch.package or pkgs.cc-switch-cli;

  apps = [ "claude" "open-code" "pi" ];

  # Resolved profile JSON per name (extends expanded, mcp groups expanded).
  resolve = name:
    let r = render.resolveProfile cfg.profiles name; in
    r // { mcp = render.expandMcp cfg.mcp r.mcp; };

  # provider shard per (name, app): cc-switch `provider add --config-file`.
  providerShards = pkgs.linkFarm "ccswitch-providers" (lib.flatten (
    lib.mapAttrsToList (n: p:
      map (app: { name = "provider-${n}-${app}.json";
                  path = pkgs.writeText "ccswitch-provider-${n}-${app}.json"
                           (builtins.toJSON (render.renderProvider app n p)); })
        apps
    ) cfg.providers
  ));

  # flat unique server/skill id lists, baked for the shims so bash needs no option access.
  serverIds = render.expandMcp cfg.mcp (
    (lib.attrNames (cfg.mcp.npm or {}))
    ++ (lib.attrNames (cfg.mcp.servers or {}))
    ++ (lib.attrNames (cfg.mcp.groups or {}))
  );
  skillIds = lib.attrNames (config.programs.agent-skills.sources or { });

  farm = pkgs.linkFarm "ccswitch-farm" {
    providers = providerShards;
    profiles = pkgs.linkFarm "ccswitch-profiles" (lib.mapAttrsToList (n: _: {
      name = "${n}.json";
      path = pkgs.writeText "ccswitch-profile-${n}.json" (builtins.toJSON (resolve n));
    }) cfg.profiles);
    manifest = pkgs.writeText "ccswitch-manifest.json" (builtins.toJSON {
      servers = serverIds;
      skills = skillIds;
    });
  };
in
{
  config = lib.mkIf enabled {
    agent.ccSwitch.profileShards =
      lib.mapAttrs (n: _: pkgs.writeText "ccswitch-profile-${n}.json" (builtins.toJSON (resolve n))) cfg.profiles;

    agent.runtimePackages = [ cc ]
      ++ [
        (pkgs.writeShellScriptBin "profile" ''
          #!${pkgs.bash}/bin/bash
          set -euo pipefail
          cc=${lib.escapeShellArg "${cc}/bin/cc-switch"}
          farm=${toString farm}
          if [ $# -eq 0 ]; then
            echo "Usage: profile <name>  (profiles: ${concatStringsSep " " (lib.attrNames cfg.profiles)})"
            exit 0
          fi
          P="$farm/profiles/$1.json"; [ -f "$P" ] || { echo "unknown profile: $1" >&2; exit 2; }
          prof_mcp=$(jq -r '.mcp[]?' "$P" | sort -u)
          # activate profile servers, disable the rest — across claude+opencode
          for app in claude open-code; do
            while read srv; do
              if printf '%s\n' "$prof_mcp" | grep -qx "$srv"; then
                "$cc" --app "$app" mcp set-apps "$srv" --apps "$app" >/dev/null 2>&1 || true
              else
                "$cc" --app "$app" mcp set-apps "$srv" --apps "" >/dev/null 2>&1 || true
              fi
            done < <(jq -r '.servers[]' "$farm/manifest.json")
            "$cc" --app "$app" mcp sync >/dev/null 2>&1 || true
            done
          def=$(jq -r '.provider // empty' "$P")
          for app in claude open-code; do
            [ -n "$def" ] || continue
            if [ "$app" = "claude" ]; then
              "$cc" --app "$app" provider switch "$def" >/dev/null 2>&1 || true
            else
              "$cc" --app "$app" provider switch "$def" >/dev/null 2>&1 || true
              mkdir -p "$HOME/.config/agent-runtime"
              jq -n --arg m "$def/main" '{model:$m, small_model:$m}' \
                > "$HOME/.config/agent-runtime/opencode-overrides.json"
            fi
          done
          "$cc" mcp sync >/dev/null 2>&1 || true
          "$cc" skills sync >/dev/null 2>&1 || true
          # pi: cc-switch won't write settings.json or mcp.json
          def=$(jq -r '.provider // empty' "$P")
          mkdir -p "$HOME/.pi/agent"
          # TODO(PR2): render ~/.pi/agent/mcp.json from this profile's server defs
          jq -n '{mcpServers:{}}' > "$HOME/.pi/agent/mcp.json"
          if [ -f "$HOME/.pi/agent/settings.json" ]; then
            jq --arg p "$def" --arg m "$def" '.defaultProvider=$p | .defaultModel=$m' \
              "$HOME/.pi/agent/settings.json" > "$HOME/.pi/agent/settings.json.tmp" \
              && mv "$HOME/.pi/agent/settings.json.tmp" "$HOME/.pi/agent/settings.json"
          fi
          mkdir -p "$HOME/.local/state/agent-runtime"
          printf '%s\n' "$1" > "$HOME/.local/state/agent-runtime/profile"
          echo "ok: profile $1 active (claude/opencode via cc-switch, pi via runtime)"
        '' )
        (pkgs.writeShellScriptBin "provider" ''
          #!${pkgs.bash}/bin/bash
          set -euo pipefail
          cc=${lib.escapeShellArg "${cc}/bin/cc-switch"}
          if [ $# -eq 0 ]; then
            echo "Usage: provider <name>  (providers: ${concatStringsSep " " (lib.attrNames cfg.providers)})"
            exit 0
          fi
          # claude: cc-switch writes env.* (key-less) + model to ~/.claude/settings.json
          "$cc" --app claude provider switch "$1" >/dev/null 2>&1 || true
          # opencode: provider node is idempotent (seeded at activation); default
          # model is the runtime's OPENCODE_CONFIG overlay, not cc-switch's.
          "$cc" --app open-code provider switch "$1" >/dev/null 2>&1 || true
          mkdir -p "$HOME/.config/agent-runtime"
          jq -n --arg m "$1/main" '{model:$m, small_model:$m}' \
            > "$HOME/.config/agent-runtime/opencode-overrides.json"
          # pi: cc-switch disclaims default provider/model → we own settings.json
          mkdir -p "$HOME/.pi/agent"
          if [ -f "$HOME/.pi/agent/settings.json" ]; then
            jq --arg p "$1" '.defaultProvider=$p | .defaultModel=$p' \
              "$HOME/.pi/agent/settings.json" > "$HOME/.pi/agent/settings.json.tmp" \
              && mv "$HOME/.pi/agent/settings.json.tmp" "$HOME/.pi/agent/settings.json"
          fi
          mkdir -p "$HOME/.local/state/agent-runtime"
          printf '%s\n' "$1" > "$HOME/.local/state/agent-runtime/provider"
          echo "ok: provider $1 set as default (all providers remain injected)"
        '' )
      ];

    home.activation.seedCcSwitch = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      cc=${lib.escapeShellArg "${cc}/bin/cc-switch"}
      farm=${toString farm}
      [ -x "$cc" ] || { echo "cc-switch not built; skipping seed" >&2; return 0; }
      if [ ! -f "$HOME/.local/state/agent-runtime/ccswitch-seeded" ]; then
        for name in ${concatStringsSep " " (lib.attrNames cfg.providers)}; do
          for app in claude open-code pi; do
            "$cc" --app "$app" provider add --id "$name" --name "$name" \
              --config-file "$farm/providers/provider-$name-$app.json" >/dev/null 2>&1 || true
          done
        done
        "$cc" mcp sync >/dev/null 2>&1 || true
        "$cc" skills sync >/dev/null 2>&1 || true
        run mkdir -p "$HOME/.local/state/agent-runtime"
        run touch "$HOME/.local/state/agent-runtime/ccswitch-seeded"
      fi
    '';
  };
}
