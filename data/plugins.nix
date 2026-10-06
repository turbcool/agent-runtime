# Claude Code plugin marketplaces + enabled plugins. Only NixOS consumes them —
# into the immutable managed-settings.json.
{
  marketplaces = {
    claude-plugins-official = {
      source = {
        source = "github";
        repo = "anthropics/claude-plugins-official";
      };
      autoUpdate = true;
    };
    ponytail = {
      source = {
        source = "github";
        repo = "DietrichGebert/ponytail";
      };
      autoUpdate = true;
    };
    i-have-adhd = {
      source = {
        source = "github";
        repo = "ayghri/i-have-adhd";
      };
      autoUpdate = true;
    };
  };

  plugins = {
    "code-simplifier@claude-plugins-official" = true;
    "ponytail@ponytail" = true;
    "i-have-adhd@i-have-adhd" = true;
  };

  # The same repos are also opencode plugins, loaded from .opencode/plugins/ by
  # absolute store path (modules/home.nix). Declared here so the opencode side
  # never hardcodes a path.
  opencodePlugins = [
    "ponytail"
    "i-have-adhd"
  ];
}
