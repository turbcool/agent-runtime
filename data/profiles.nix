# Tool/transport profiles: named bundles of tool state that a single
# `profile <name>` command activates across every managed harness
# (claude / opencode / pi).
#
# A profile is dialect-free on purpose, exactly like the entries in
# data/mcp.nix: it names things that already exist in the registries
# (`agent.providers`, `agent.mcp.servers`+`mcp.groups`+`mcp.npm`,
# `agent.skills.sources`), and the cc-switch renderer in
# modules/ccswitch.nix turns each name into the dialect cc-switch wants per app.
# Names that don't resolve in the registries fail `checks.profiles-resolve` at
# build time, not at a `profile` call.
#
# `extends` is resolved by lib (cycle-asserted in the check). It lets a profile
# inherit `base`'s always-on set; entries in the extending profile override or
# append to the inherited ones (mcp/skills are unions, provider/provider-model
# are replaced, prompts replace).
#
# Bundled profiles ship here (base + work); consumers extend with
# `agent.profiles = lib.data.profiles // { side = { extends = "work"; … }; };`
# — exactly the merge shape `agent.providers`/`agent.mcp`/agent.plugins already
# use, so a consumer writes one extra line and adds nothing else.
{
  # base: bundled with the runtime, every profile extends this set.
  # donsetch is the always-present MCP (web_fetch/search/crawl) for everyone.
  base = { provider = "neoplatform"; mcp = [ "donsetch" ]; };

  # work: bundled; extends base. Adds bladebro + the nixos mcp server and the
  # ponytail skill. `provider free` still leaves base providers injected.
  work = {
    extends = "base";
    provider = "free";
    mcp = [ "bladebro" "nixos" ];
    skills = [ "ponytail" ];
  };
}
