# MCP server registry. Read by modules/home.nix (opencode.json + the Claude Code
# wrappers) and by the consumer's `mcp` CLI, which renders one `mcp-config-<name>`
# package per server and merges it into the user's opencode.json.
#
# `npm` is the npm-installed set: binaries that live in $HOME/.npm/bin and are
# exposed to every agent. Both agents rewrite them to an absolute path (an
# agent's environment may predate home.sessionPath — GUI launch, container
# without rc). Consumers skip this key when they enumerate servers.
{
  nixos = {
    type = "local";
    command = [ "mcp-nixos" ];
    enabled = true;
  };
  daisyui = {
    type = "local";
    command = [
      "docker"
      "run"
      "-i"
      "--rm"
      "daisyui-mcp"
    ];
    enabled = true;
  };
  svelte = {
    type = "remote";
    url = "https://mcp.svelte.dev/mcp";
    enabled = true;
  };
  lucide-icons = {
    type = "local";
    command = [
      "npx"
      "lucide-icons-mcp"
      "--stdio"
    ];
    enabled = true;
  };

  wiki = {
    type = "local";
    command = [
      "qmd"
      "mcp"
    ];
    enabled = true;
  };

  npm = {
    donsetch = {
      type = "stdio";
      command = "donsetch";
      args = [ "mcp" ];
    };
    bladebro = {
      type = "stdio";
      command = "bladebro";
      args = [ "mcp" ];
    };
  };

  groups = {
    nixos = [ "nixos" ];
    frontend = [
      "svelte"
      "daisyui"
      "lucide-icons"
    ];
    wiki = [ "wiki" ];
  };
}
