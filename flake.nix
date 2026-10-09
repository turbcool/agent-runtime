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

  # The home module is a plain *path* — Nix' module system dedupes identical
  # paths, so a host may import `homeModules.default` itself and still get the
  # module injected exactly once via `nixosModules.default` ->
  # `home-manager.sharedModules` (two lambda instances would collide on every
  # `programs.agent-skills.*` option). The module takes this flake's own inputs
  # through the `runtimeInputs` module argument, supplied by `mkHmConfig` (and,
  # for NixOS, by this module via `home-manager.extraSpecialArgs`), so a NixOS
  # host writes one import and no extra arguments.
  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      ...
    }@inputs:
    let
      inherit (nixpkgs) lib;

      # Add a system here to publish for another client fleet; nothing else in
      # the flake hardcodes one.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = lib.genAttrs systems;
      firstSystem = lib.elemAt systems 0;

      # The registries, as plain data. A client extends a record instead of
      # re-deriving it: `agent.providers = agent-runtime.lib.data.providers // { … };`.
      data =
        let runtimeInputs = inputs;
        in {
          providers = import ./data/providers.nix;
          mcp = import ./data/mcp.nix;
          plugins = import ./data/plugins.nix;
          skills = import ./data/skills.nix { inherit runtimeInputs; };
        };

      forEachSystem =
        f:
        forAllSystems (
          system:
          f (
            rec {
              inherit system;
              pkgs = nixpkgs.legacyPackages.${system};
            }
          )
        );

      # The home module (plain path, dedupable) plus container tweaks. Shared by
      # the standalone config, the container module set, and the package checks.
      homeModule = ./modules/home.nix;
      homeModulesList = [ homeModule ./modules/container.nix ];

      mkHmConfig = pkgs: modules: home-manager.lib.homeManagerConfiguration {
        inherit pkgs modules;
        extraSpecialArgs = { runtimeInputs = inputs; };
      };
    in
    {
      # NixOS half: agenix secrets + managed settings + host prerequisites
      # (programs.npm/nix-ld, derived from the registry) + the auto-wiring of the
      # home half. The home module is injected through `home-manager.sharedModules`
      # when this host imports home-manager's NixOS module, so a NixOS client
      # writes one import and nothing in its Home Manager config.
      nixosModules.default =
        import ./modules/nixos.nix {
          inherit inputs;
          homeModule = homeModule;
        };

      # Standalone Home Manager — the module a non-NixOS consumer imports. It
      # does not include container.nix. The `runtimeInputs` argument is read from
      # extraSpecialArgs; use `homeConfigurations.agent-runtime` or `.container`
      # if you do not want to pass it yourself.
      homeModules.default = homeModule;

      # The container flavour as an importable module list (home + container
      # tweaks), so a standalone Home Manager setup can build its own config with
      # overrides instead of taking `homeConfigurations.agent-runtime` as given:
      #   homeManagerConfiguration { modules = [ inputs.agent-runtime.homeModules.container { agent.defaultModel = …; } ]; }
      homeModules.container = homeModulesList;

      # The exact module set `nixosModules.default` injects, with no OS under it.
      homeConfigurations.agent-runtime =
        mkHmConfig nixpkgs.legacyPackages.${firstSystem} homeModulesList;

      packages = forEachSystem (
        {
          pkgs,
          system,
          ...
        }:
        let
          hmConfig = mkHmConfig pkgs homeModulesList;
          cfg = hmConfig.config.agent;

          # Everything modules/home.nix + modules/skills.nix contribute (pi,
          # opencode, claude, claude-free, writing, mcp, skills) — deliberately
          # not `home.packages`, because standalone HM folds its own baseline
          # (man-db, shared-mime-info) into that list.
          agentRuntime = pkgs.buildEnv {
            name = "agent-runtime";
            paths = cfg.runtimePackages;
            pathsToLink = [
              "/bin"
            ];
          };

          # The rendered ~/.pi and ~/.config/opencode trees as store paths, so a
          # container image can COPY them straight into $HOME.
          agentRuntimeConfig = pkgs.linkFarm "agent-runtime-config" (
            lib.mapAttrsToList (
              name: src: {
                inherit name;
                path = toString src;
              }
            )
            cfg.runtimeFiles
          );

          # One command instead of the documented four steps: install the bundle
          # on PATH, copy the config farm onto the writable $HOME, seed the npm
          # packages the agents expect, and report which tokens are still missing.
          install = pkgs.substitute {
            name = "agent-runtime-install";
            src = ./lib/install.sh;
            dir = "bin";
            executable = true;
            substitutions = [
              "--replace" "@agentRuntime@" "${agentRuntime}"
              "--replace" "@agentRuntimeConfig@" "${agentRuntimeConfig}"
            ];
          };
        in
        {
          inherit agentRuntime agentRuntimeConfig install;
          agent-runtime = agentRuntime;
          agent-runtime-config = agentRuntimeConfig;
          mcp = cfg.mcpCommand;
          default = agentRuntime;
        }
      );

      # The contract every consumer gets — checked against the bundle the
      # container output ships: every command must actually be in it. The names
      # come from the options, so adding one is covered here without editing it.
      checks = forEachSystem (
        {
          pkgs,
          system,
          ...
        }:
        let
          hmConfig = mkHmConfig pkgs homeModulesList;
          agentRuntime = (self.packages.${system}).agentRuntime;
        in
        {
          bundle-contains-agents = pkgs.runCommand "bundle-contains-agents"
            {
              nativeBuildInputs = [ pkgs.coreutils ];
            }
            ''
              for bin in ${
                lib.concatStringsSep " " (
                  builtins.attrNames hmConfig.config.agent.claudeCode.commands
                  ++ [
                    "opencode"
                    "pi"
                    "mcp"
                    "skills"
                  ]
                  ++ map (name: "skills-install-${name}") (
                    builtins.attrNames hmConfig.config.programs.agent-skills.sources
                  )
                )
              }; do
                if [ ! -x "${agentRuntime}/bin/$bin" ]; then
                  echo "missing from bundle: $bin" >&2
                  exit 1
                fi
              done
              touch $out
            '';

          # A package-backed MCP entry names both an nixpkgs attribute and the
          # binary inside it; a typo in either is invisible until a project runs
          # `mcp <server>`, so assert it here instead.
          mcp-servers-exist = pkgs.runCommand "mcp-servers-exist"
            {
              nativeBuildInputs = [ pkgs.coreutils ];
            }
            ''
              for bin in ${
                lib.concatStringsSep " " (
                  lib.mapAttrsToList (
                    name: srv: "${pkgs.${srv.package}}/bin/${builtins.head srv.command}"
                  ) (lib.filterAttrs (_: srv: srv ? package) hmConfig.config.agent.mcp.servers)
                )
              }; do
                if [ ! -x "$bin" ]; then
                  echo "MCP server binary not found: $bin" >&2
                  exit 1
                fi
              done
              touch $out
            '';

          # A profile is dialect-free and resolved against the provider/mcp
          # registries; resolve every profile (extends + mcp-group expansion)
          # and render each one into a full world (opencode.json, pi settings/
          # models/mcp) at eval time, so a bad name or a cycle fails
          # `nix flake check` instead of a `profile` call. (Skill names are
          # checked against the merged source set by a module assertion, which
          # a client can extend; here we only see the bundled registries.)
          worlds-resolve = pkgs.runCommand "worlds-resolve"
            { nativeBuildInputs = [ pkgs.jq ]; }
            (let
              W = (import ./lib/worlds.nix) lib;
              providers = import ./data/providers.nix;
              mcp = import ./data/mcp.nix;
              profiles = import ./data/profiles.nix;
              rendered = lib.mapAttrs (n: _:
                W.render {
                  inherit providers mcp profiles;
                  name = n;
                  npmBin = "/run/current-system/sw/bin";
                  smallModel = "custom/qwen3-coder-next";
                }
              ) profiles;
            in
            ''
              printf '%s\n' ${lib.escapeShellArg (builtins.toJSON rendered)} \
                | ${pkgs.jq}/bin/jq -e 'map_values(.provider) | length == ${toString (builtins.length (builtins.attrNames profiles))}' > /dev/null
              echo 'every profile resolves and renders a complete world' >&2
              touch $out
            ''
            )
          ;
        }
      );

      # The data registries, so a client extends a record instead of
      # re-deriving it.
      lib.data = data // {
        profiles = import ./data/profiles.nix;
        worlds = (import ./lib/worlds.nix) lib;
      };

      # agent-skills' library, for a client that wants a bundle shape of its own.
      lib.agentSkills = inputs.agent-skills.lib.agent-skills;

      devShells = forEachSystem (
        {
          pkgs,
          ...
        }:
        {
          default = pkgs.mkShellNoCC {
            packages = [
              pkgs.jq
              pkgs.nixfmt
              pkgs.statix
            ];
          };
        }
      );
    };
}
