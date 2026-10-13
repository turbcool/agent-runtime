# agent-runtime as a container image: pi, opencode, claude, mcp, writing, skills.
#
#   docker build -t agent-runtime -f docker/Dockerfile .
#   docker run --rm -it -v "$PWD:/work" -w /work \
#     -e AGENT_NEOPLATFORM_TOKEN -e AGENT_CUSTOM_TOKEN -e AGENT_FREE_TOKEN \
#     agent-runtime
#
# Tokens are env at run time on purpose — nothing secret is baked into a layer,
# which is exactly why the providers are env-based in a container and file-based
# under NixOS. To pin a revision:
#   docker build --build-arg RUNTIME=github:turbcool/agent-runtime/<rev> ...
#
# The image keeps /nix/store: the agent entrypoints are store-path bash wrappers
# that exec store paths (claude-code, node, jq, ...), so a "slim" image without
# the store cannot host them.
FROM nixos/nix:2.28.3

# The base image already sets sandbox = false, the cache keys, and a profile with
# git + curl + bash, so flakes and node are the only gaps. node/npm is what
# #install uses to seed the MCP servers (bladebro, donsetch) that have no nix
# package, and what the lucide-icons server shells out to via npx.
RUN printf 'experimental-features = nix-command flakes\n' >> /etc/nix/nix.conf \
 && nix profile install nixpkgs#nodejs

# The whole install in one command: binaries onto PATH, rendered config into
# $HOME, npm MCP servers seeded, missing tokens reported (a warning, not a
# failure — the tokens belong to the run, not the build).
ARG RUNTIME=github:turbcool/agent-runtime
RUN nix run ${RUNTIME}#install \
 && chmod -R u+w /root/.pi /root/.config /root/.claude

# /root/.npm/bin is where #install seeds bladebro + donsetch, and the rendered
# MCP registry resolves them as $HOME/.npm/bin/<server> — which is /root here.
# A non-root user needs $HOME/.npm/bin on PATH instead.
ENV PATH=/root/.npm/bin:/root/.local/bin:$PATH
WORKDIR /work