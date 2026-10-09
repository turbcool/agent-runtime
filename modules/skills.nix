# Skills: the registry, the three targets, and the per-project installers.
#
# One source set, two consumers. `programs.agent-skills.sources` gets the
# runtime's own skills (data/skills.nix) plus whatever a client adds through
# `agent.skills.sources`, so agent-skills' activation links one merged catalog
# into every target, and the `skills` command below offers every source of that
# same merged set for a per-project install. Adding a skill is one entry in one
# place and reaches both.
#
# On NixOS this module only declares the sources and lets agent-skills'
# activation do the linking. For the standalone container config there is no
# activation to run, so the already-filtered per-target bundles are registered in
# `agent.runtimeFiles` and end up in `agent-runtime-config` for COPY.
{ runtimeInputs }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.agent;
  skillConfig = import ../data/skills.nix { inherit runtimeInputs; };

  # The merged catalog: runtime skills + client skills. agent-skills resolves
  # `path`-addressed sources without any input of its own, which is what lets a
  # client add `{ path = "${inputs.foo}/skills"; }` from its own flake.
  sources = config.programs.agent-skills.sources;
  catalog = runtimeInputs.agent-skills.lib.agent-skills.discoverCatalog sources;
  agentLib = runtimeInputs.agent-skills.lib.agent-skills;

  # One installer per source, built from the merged catalog. This used to be a
  # consumer's `lib/skills-install.nix` + a `skills` wrapper that ran
  # `nix build` against a hardcoded flake path; here the installers are part of
  # the bundle and `skills <source>` is a plain exec of the one on PATH.
  installerFor =
    name:
    pkgs.writeShellScriptBin "skills-install-${name}" (
      "${
        agentLib.mkLocalInstallProgram {
          inherit pkgs;
          bundle = agentLib.mkBundle {
            inherit pkgs;
            selection = agentLib.selectSkills {
              inherit catalog sources;
              allowlist = agentLib.allowlistFor {
                inherit catalog sources;
                enableAll = [ name ];
              };
              skills = { };
            };
          };
          targets.opencode = {
            enable = true;
            dest = ".opencode/skills";
            structure = "copy-tree";
          };
        }
      }/bin/skills-install-local"
    );

  skillInstallers = pkgs.buildEnv {
    name = "agent-skill-installers";
    paths = map installerFor (lib.attrNames sources);
    pathsToLink = [
      "/bin"
    ];
  };

  skillNames = lib.attrNames sources;

  skillsCommand = pkgs.writeShellScriptBin "skills" ''
    if [ $# -eq 0 ]; then
      echo "Usage: skills <source>"
      echo ""
      echo "Sources:"
    ${lib.concatMapStringsSep "\n" (name: "  ${name}") skillNames}
      exit 0
    fi

    installer="${skillInstallers}/bin/skills-install-$1"
    if [ ! -x "$installer" ]; then
      echo "✗ Unknown skill source: $1"
      echo ""
      echo "Usage: skills <source>"
      echo ""
      echo "Sources:"
    ${lib.concatMapStringsSep "\n" (name: "  ${name}") skillNames}
      exit 1
    fi

    ( cd . && "$installer" )
    echo "✓ Skills installed to .opencode/skills: $1"
  '';
in
{
  # The ONLY import of the agent-skills Home Manager module in this repo.
  # It is a Nix function rather than a path, so NixOS' collectImports cannot
  # dedupe it by location — importing it from another module as well makes every
  # programs.agent-skills.* option fail with "already declared".
  # Clients therefore extend `agent.skills.sources` (merged below), never
  # re-import the machinery.
  imports = [ runtimeInputs.agent-skills.homeManagerModules.default ];

  options.agent.skillTools = lib.mkOption {
    type = lib.types.package;
    default = pkgs.buildEnv {
      name = "agent-skill-tools";
      paths = [
        skillInstallers
        skillsCommand
      ];
      pathsToLink = [
        "/bin"
      ];
    };
    internal = true;
    description = "Per-project skill installers plus the `skills` dispatcher. Contributed to `agent.runtimePackages` by modules/home.nix.";
  };

  config = {
    programs.agent-skills = {
      enable = true;
      # One merged set: the runtime's skills first, then the client's. This is
      # the catalog the per-project `skills <source>` installers and the world's
      # skill bundles are built from. The machine-wide link-trees themselves
      # are owned by the active world (modules/worlds.nix), so agent-skills is
      # NOT told to link every target here — that would give each skill tree a
      # second writer and make `profile` unable to change the active skills.
      sources = skillConfig // cfg.skills.sources;
    };
  };
}