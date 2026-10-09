# Profiles: named, complete "worlds" of machine-wide agent state.
#
# A profile names a provider, a set of MCP servers, and a set of skill sources.
# `lib/worlds.nix` renders each one into a full, immutable snapshot of every
# machine-wide config file (opencode.json, pi's settings/models/mcp, and the
# skill link-trees); `modules/worlds.nix` bakes one directory per profile and
# ships `profile <name>`, which installs a world by copying that directory into
# $HOME. One writer, one atomic switch, no imperative diffing.
#
# Profiles are dialect-free, exactly like data/mcp.nix: they reference names
# that already exist in `agent.providers`, `agent.mcp` (servers/groups/npm) and
# the merged agent-skills source set (`agent.skills.sources` + the runtime's).
# A name that doesn't resolve fails `checks.worlds-resolve` at build time, not at
# a `profile` call.
#
# Consumers extend with the usual merge:
#   agent.profiles = lib.data.profiles // { mine = { … }; };
# `extends` inherits another profile's provider/mcp/skills (cycle-checked).
#
# Field reference:
#   provider  name in data/providers.nix — becomes the world for claude, pi and
#             opencode (one provider per world).
#   mcp       opt-in mcp servers/groups layered on the always-on npm set.
#   skills    agent-skills source names linked into the machine-wide skill trees.
{
  # work: the default. Strong model, the coding toolchain (ponytail family for
  # minimal-solution coding, archify for architecture diagrams, i-have-adhd for
  # interaction guidance). donsetch is always on via the npm set; nixos is the
  # one extra server here.
  work = {
    provider = "neoplatform";
    mcp = [ ];
    skills = [
      "ponytail"
      "archify"
      "archify-review"
      "adhd"
    ];
  };

  # free: same coding toolchain, on the free endpoint (provider's tiers and
  # models come from data/providers.nix, not from here).
  free = {
    provider = "free";
    mcp = [ ];
    skills = [
      "ponytail"
      "archify"
      "archify-review"
      "adhd"
    ];
  };

  # study: the free endpoint for reading/learning. No machine-wide skills —
  # ARIS (research/writing skills) is installed per project by the `writing`
  # command; donsetch (always-on) covers web fetch/search. Point claude at this
  # with `profile study`, then run `writing` in a repo for the ARIS bundle.
  study = {
    provider = "free";
    mcp = [ ];
    skills = [ ];
  };
}