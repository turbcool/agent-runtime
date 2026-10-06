# MCP server registry, in three sets:
#
#   servers — reachable only through the `mcp <group|server>` command, which
#             merges one rendered JSON into the current folder's opencode.json
#   groups  — named subsets of `servers`
#   npm     — binaries installed by npm into $HOME/.npm/bin, exposed to *every*
#             agent: modules/home.nix writes them into opencode.json and into
#             each provider-pinned command's --mcp-config
#
# The entries are dialect-free on purpose — they say what a server *is*, and
# each renderer adds the fields its agent wants (opencode needs `type`,
# `enabled` and an absolute command path; Claude Code infers stdio from
# `command`). No `type`/`enabled` here: those are the agents' own defaults and
# repeating them only makes the next rename noisier.
#
# Both agents rewrite npm commands to absolute paths (an agent's environment may
# predate home.sessionPath — GUI launch, container without rc), so never rely on
# PATH here.
{
  servers = {
    nixos = {
      command = [ "mcp-nixos" ];
    };
    daisyui = {
      command = [
        "docker"
        "run"
        "-i"
        "--rm"
        "daisyui-mcp"
      ];
    };
    svelte = {
      url = "https://mcp.svelte.dev/mcp";
    };
    lucide-icons = {
      command = [
        "npx"
        "lucide-icons-mcp"
        "--stdio"
      ];
    };
  };

  groups = {
    nixos = [ "nixos" ];
    frontend = [
      "svelte"
      "daisyui"
      "lucide-icons"
    ];
  };

  npm = {
    donsetch = {
      command = "donsetch";
      args = [ "mcp" ];
    };
    bladebro = {
      command = "bladebro";
      args = [ "mcp" ];
    };
  };
}
