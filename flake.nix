{
  description = "Declarative agent runtime: claude-code + opencode + pi with providers, keys and MCP wiring. Usable as a NixOS/Home Manager module pair or as a standalone `nix profile install` bundle for containers.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # pi, opencode, agent-deck.
    llm-agents.url = "github:numtide/llm-agents.nix";

    # The claude binary itself — npm-published, so it needs this to be
    # reproducible (and to reach a binary cache).
    claude-code.url = "github:sadjow/claude-code-nix";

    # Skill discovery + install (Home Manager module + the bundle lib).
    agent-skills.url = "github:Kyure-A/agent-skills-nix";

    # Referenced by path from data/skills.nix and data/plugins.nix. Resolved
    # against *this* flake's lock, so a consumer needs neither matching inputs
    # nor `follows` wiring.
    archify = {
      url = "github:tt-a1i/archify";
      flake = false;
    };
    qmd.url = "github:tobi/qmd";

    # Also loaded as opencode plugins, by absolute store path.
    ponytail = {
      url = "github:DietrichGebert/ponytail";
      flake = false;
    };
    i-have-adhd = {
      url = "github:ayghri/i-have-adhd";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      ...
    }@inputs:
    let
      # Keep in sync with /etc/nixos/flake.nix; the hosts pin x86_64-linux.
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (nixpkgs) lib;

      # Modules close over this flake's own inputs instead of reading the
      # consumer's `inputs` module arg, which is what keeps a consumer from
      # having to declare the runtime's inputs at all.
      mkModule = path: import path { runtimeInputs = inputs; };

      # Standalone Home Manager: the exact module the NixOS hosts get through
      # common/hm/default.nix, evaluated with no OS underneath. That is what
      # makes the container config identical to the desktop config.
      hmConfig = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = { inherit inputs; };
        modules = [
          (mkModule ./modules/home.nix)
          ./modules/container.nix
        ];
      };

      # --- MCP ------------------------------------------------------------
      # data/mcp.nix is the registry, but only its `npm` set reaches every
      # agent (through the Home Manager module). The rest is opt-in per project
      # via `mcp <group|server>`, which merges a rendered opencode.json fragment
      # into the current folder. The configs are baked into a farm and shipped
      # with the command, so activating one is a local file read — no `nix
      # build`, and the same behaviour inside a container.
      mcp = import ./data/mcp.nix;
      toOpencodeMcp =
        srv:
        if srv ? url then
          {
            type = "remote";
            inherit (srv) url;
            enabled = true;
          }
        else
          {
            type = "local";
            inherit (srv) command;
            enabled = true;
          };
      mcpConfigPkgs = lib.mapAttrs (
        name: members:
        pkgs.writeText "opencode-mcp-$name.json" (
          builtins.toJSON {
            mcp = lib.listToAttrs (
              map (member: {
                name = member;
                value = toOpencodeMcp mcp.servers.${member};
              }) members
            );
          }
        )
      ) (mcp.groups // lib.mapAttrs (name: _: [ name ]) mcp.servers);
      mcpConfigDir = pkgs.linkFarm "agent-runtime-mcp-configs" (
        lib.mapAttrsToList (name: src: {
          name = "${name}.json";
          path = toString src;
        }) mcpConfigPkgs
      );
      mcpUsage = ''
        Usage: mcp <group|server>

        Groups:
        ${lib.concatStringsSep "\n" (
          map (name: "  ${name} → ${lib.concatStringsSep ", " mcp.groups.${name}}") (lib.attrNames mcp.groups)
        )}

        Servers:
        ${lib.concatMapStringsSep "\n" (name: "  ${name}") (lib.attrNames mcp.servers)}
      '';

      # Everything modules/home.nix contributes (pi, opencode, claude,
      # claude-free, writing) plus this file's `mcp`.
      agentRuntime = pkgs.buildEnv {
        name = "agent-runtime";
        paths = hmConfig.config.agent.runtimePackages ++ [ mcpCommand ];
        pathsToLink = [
          "/bin"
        ];
      };

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

      # The rendered ~/.pi and ~/.config/opencode trees as store paths, so a
      # container image can COPY them straight into $HOME (`cp -rL` it into a
      # live one, then `chmod -R u+w`: store paths are read-only and pi must be
      # able to create ~/.pi/agent/sessions).
      agentRuntimeConfig = pkgs.linkFarm "agent-runtime-config" (
        lib.mapAttrsToList (name: src: {
          inherit name;
          path = toString src;
        }) hmConfig.config.agent.runtimeFiles
      );
    in
    {
      nixosModules.default = ./modules/nixos.nix;
      homeModules.default = mkModule ./modules/home.nix;

      homeConfigurations.agent-runtime = hmConfig;

      packages.${system} = {
        inherit agentRuntime agentRuntimeConfig mcpCommand;
        agent-runtime = agentRuntime;
        agent-runtime-config = agentRuntimeConfig;
        mcp = mcpCommand;
        default = agentRuntime;
      };

      # The contract the modules assert for every consumer, checked against the
      # bundle the container output ships: every agent must actually be in it.
      checks.${system}.bundle-contains-agents =
        pkgs.runCommand "bundle-contains-agents"
          {
            nativeBuildInputs = [ pkgs.coreutils ];
          }
          ''
            for bin in claude claude-free writing opencode pi mcp; do
              if [ ! -x "${agentRuntime}/bin/$bin" ]; then
                echo "missing from bundle: $bin" >&2
                exit 1
              fi
            done
            touch $out
          '';

      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = [
          pkgs.jq
          pkgs.nixfmt
          pkgs.statix
        ];
      };
    };
}
