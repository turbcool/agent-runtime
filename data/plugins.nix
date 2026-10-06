# Claude Code plugin marketplaces + enabled plugins, plus the repos that are also
# opencode plugins. Only NixOS consumes the first two — into the immutable
# managed-settings.json — while modules/home.nix loads `opencodePlugins` by
# absolute store path from .opencode/plugins/.
let
  # Repos that ship a plugin for both agents, in load order. Claude Code's
  # convention for a GitHub marketplace makes the plugin id equal the marketplace
  # name, and the opencode plugin is .opencode/plugins/<name>.mjs — so one entry
  # per repo derives all three facts.
  community = [
    {
      name = "ponytail";
      repo = "DietrichGebert/ponytail";
    }
    {
      name = "i-have-adhd";
      repo = "ayghri/i-have-adhd";
    }
  ];

  official = "claude-plugins-official";

  marketplace = repo: {
    source = {
      source = "github";
      inherit repo;
    };
    autoUpdate = true;
  };

  # fold `community` into an initial set, one entry per repo
  fold = step: initial: builtins.foldl' (acc: c: acc // step c) initial community;
in
{
  marketplaces =
    fold
      (c: {
        ${c.name} = marketplace c.repo;
      })
      {
        ${official} = marketplace "anthropics/${official}";
      };

  plugins =
    fold
      (c: {
        "${c.name}@${c.name}" = true;
      })
      {
        "code-simplifier@${official}" = true;
      };

  opencodePlugins = map (c: c.name) community;
}
