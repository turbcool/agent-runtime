# Provider registry shared by claude-code, opencode and pi.
#
# `tokenSource` has exactly one of:
#   { env  = "VAR"; }   # default — works anywhere, including containers
#   { file = "/path"; } # written by modules/nixos.nix to the agenix store path
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
    anthropicUrl = "https://llm-free.naidanov.ru";
    tokenSource.env = "AGENT_FREE_TOKEN";
    models."muse-spark-1.3-contributor".name = "Muse Spark 1.3 Contributor";
    models."main".limit = {
      context = 256000;
      output = 32000;
    };
  };
}
