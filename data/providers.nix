# Provider registry shared by claude-code, opencode and pi.
#
# `url` is the OpenAI-compatible base. Claude Code speaks the Anthropic API,
# which is the same host minus a trailing `/v1` — modules/home.nix derives it,
# so no provider carries a second URL.
#
# `tokenSource` has exactly one of:
#   { env  = "VAR"; }   # default — works anywhere, including containers
#   { file = "/path"; } # written by modules/nixos.nix to the agenix store path
#
# `claudeModel` is this endpoint's model pair in Claude Code's own dialect. Its
# ids are the endpoint's, so they are not required to appear in `models` (which
# is the OpenAI-compatible catalogue pi and opencode read) — `small` on the free
# endpoint is one such id.
#
# The provider-pinned commands in `agent.claudeCode.commands` pick their tiers
# from `claudeModel`, so a model id is named in exactly one place.
#
# Every entry in `models` states its limits: pi reads them directly and
# opencode copies them through, and a missing limit is a mistake, not a default.
#
# The env form is the declaration; the NixOS module rewrites the tokenSource of
# every provider listed in its `agent.agenixFiles` option into a store path and
# declares the matching age secret, so the host never carries keys in its
# environment while containers do the opposite.
#
# This file carries no paths and no secrets: the .age ciphertexts stay on the
# NixOS host (see common/modules/agent-secrets.nix there), which is what keeps
# the runtime a self-contained flake usable from a container.
{
  neoplatform = {
    url = "https://llm.neoplatform.ru";
    tokenSource.env = "AGENT_NEOPLATFORM_TOKEN";
    claudeModel = {
      main = "deepseek-v4-flash";
      small = "qwen3-coder-128k:30b";
    };
    models."qwen3-coder-128k:30b".limit = {
      context = 128000;
      output = 32000;
    };
    models."gemma-4-31b-it".limit = {
      context = 200000;
      output = 32000;
    };
    models."deepseek-v4-flash".limit = {
      context = 200000;
      output = 32000;
    };
  };
  custom = {
    url = "https://llm.naidanov.ru";
    tokenSource.env = "AGENT_CUSTOM_TOKEN";
    claudeModel = {
      main = "deepseek-v4-flash";
      small = "qwen3-coder-next";
    };
    models."deepseek-v4-flash-direct".limit = {
      context = 200000;
      output = 32000;
    };
    models."deepseek-v4-flash".limit = {
      context = 200000;
      output = 32000;
    };
    models."qwen3-coder-next".limit = {
      context = 128000;
      output = 32000;
    };
  };
  free = {
    url = "https://llm-free.naidanov.ru/v1";
    tokenSource.env = "AGENT_FREE_TOKEN";
    claudeModel = {
      main = "main";
      small = "small";
    };
    models."muse-spark-1.3-contributor" = {
      name = "Muse Spark 1.3 Contributor";
      limit = {
        context = 128000;
        output = 32000;
      };
    };
    models."main".limit = {
      context = 256000;
      output = 32000;
    };
  };
}
