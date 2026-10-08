# Pure Nix library: turn the agent-runtime registries (providers / mcp / profiles)
# into the dialect-specific record shards that `cc-switch provider add
# --config-file` and `mcp set-apps`/`skills set-apps` consume.
#
# Import style: a plain function `lib: { … }`, so the check does
#   let render = (import ./lib/ccswitch.nix) lib;
# with no Home Manager and no `config` — the renderers need only `lib` + the
# data files.
#
# Smoke-test reference (cc-switch-cli 5.10.5):
#   - `--config-file` is parse-only → a key-less claude node is accepted
#   - cc-switch does NOT evaluate apiKey/header expressions → our `!cat`/`!printenv`
#     and `{file:…}`/`{env:…}` token-source forms survive for pi/opencode verbatim
#   - Claude Code settings.json.env beats the *process* environment → claude
#     provider records are deliberately key-less; the runtime's `claude` wrapper
#     injects ANTHROPIC_API_KEY from agenix at launch.
lib:

let
  inherit (lib) mapAttrs concatMap;
  inherit (lib.strings) removeSuffix;
in
rec {
  # The three dialects cc-switch can write for.
  apps = [ "claude" "open-code" "pi" ];

  # One provider, rendered as the bare `settings_config` node for `app`.
  # Claude: env + role-model tiers + default model, NO api key.
  # pi/opencode: keep the tokenSource expression verbatim (`!cat`/`!printenv`
  #   for pi, `{file:…}`/`{env:…}` for opencode — both are resolved by the agent).
  renderProvider = app: name: p:
    let
      ts = p.tokenSource or { };
      key = if ts ? file then
              if app == "open-code" then "{file:${ts.file}}" else "!cat ${ts.file}"
            else
              if app == "open-code" then "{env:${ts.env}}" else "!printenv ${ts.env}";
    in
    if app == "claude" then
      { env = {
          ANTHROPIC_BASE_URL = removeSuffix "/v1" p.url;
          ANTHROPIC_DEFAULT_OPUS_MODEL = p.claudeModel.main;
          ANTHROPIC_DEFAULT_SONNET_MODEL = p.claudeModel.main;
          ANTHROPIC_DEFAULT_HAIKU_MODEL = p.claudeModel.small;
        };
        model = p.claudeModel.main;
      }
    else if app == "open-code" then
      { name = name;
        npm = "@ai-sdk/openai-compatible";
        models = p.models or { };
        options = { baseURL = p.url; apiKey = key; };
      }
    else                       # pi — additive provider node in models.json
      { url = "${removeSuffix "/v1" p.url}/v1";
        api = "openai-completions";
        apiKey = key;
        models = mapAttrs (id: m: { inherit id; name = m.name or id; limit = m.limit; }) (p.models or { });
      }
  ;

  # Resolve `extends` into a merged record: mcp/skills unioned across the chain,
  # provider/prompts replaced by the leaf. Throws on unknown names or cycles.
  resolveProfile = profiles: name:
    let
      walk = seen: n:
        let p = profiles."${n}" or (throw "profile: unknown profile '${n}'");
        in if lib.elem n seen then
          throw "profile: cycle on '${n}'"
        else
          let parent = if p ? extends then walk (seen ++ [ n ]) p.extends else { };
          in {
            provider = p.provider or parent.provider or null;
            mcp = (parent.mcp or []) ++ (p.mcp or []);
            skills = (parent.skills or []) ++ (p.skills or []);
            prompts = p.prompts or parent.prompts or null;
          };
    in walk [ ] name;

  # Expand mcp *group* names (servers/groups/npm) and dedup — a profile may say
  # `mcp = [ "frontend" ]` and get the full member list. Throws on unknown names.
  expandMcp = mcpReg: names:
    lib.lists.unique (concatMap (n:
      if mcpReg.groups ? ${n} then mcpReg.groups.${n}
      else if (mcpReg.servers ? ${n} || mcpReg.npm ? ${n}) then [ n ]
      else throw "profile: mcp name '${n}' is not a server/group/npm entry"
    ) names);
}
