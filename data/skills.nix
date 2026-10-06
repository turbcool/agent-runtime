# Skills that ship with the agent runtime — injected everywhere it runs, i.e.
# both NixOS hosts and the standalone agent-runtime containers.
#
# Format is agent-skills' source registry. Sources are addressed by `path`, not
# by flake-input name: paths come from *this* flake's lock (modules/skills.nix
# passes runtimeInputs), so a consumer needs no matching inputs and no `follows`
# wiring — it just imports the module.
#
# Host-only skills (orca) stay in /etc/nixos/config/skills.nix, merged into the
# same source set by common/hm/agent-skills.nix there.
{ runtimeInputs }:
{
  adhd = {
    path = "${runtimeInputs.i-have-adhd.outPath}/skills";
  };

  archify = {
    path = "${runtimeInputs.archify.outPath}/archify";
  };

  # The archify repo keeps a second skill outside archify/ — without this entry
  # only the diagram generator gets injected, not the review/triage workflow.
  archify-review = {
    path = "${runtimeInputs.archify.outPath}/.agents/skills";
  };

  ponytail = {
    path = "${runtimeInputs.ponytail.outPath}/skills";
  };

  # qmd ships a maintainer-facing `release` skill next to the useful one.
  qmd = {
    path = "${runtimeInputs.qmd.outPath}/skills";
    filter.nameRegex = "^qmd$";
  };
}
