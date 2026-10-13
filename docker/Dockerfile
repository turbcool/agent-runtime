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
#
# Docker's layer cache keys on the instruction text, not on what github: resolves
# to upstream — rebuild with the pinned rev after changing the runtime, or pass
# --no-cache.
FROM nixos/nix:2.28.3

# The base image already sets sandbox = false, the cache keys, and a profile with
# git + curl + bash, so flakes and node are the only gaps. node/npm is what
# #install uses to seed the MCP servers (bladebro, donsetch) that have no nix
# package, and what the lucide-icons server shells out to via npx.
RUN printf 'experimental-features = nix-command flakes\n' >> /etc/nix/nix.conf \
 && nix profile install nixpkgs#nodejs

# The two MCP servers are prebuilt glibc binaries (npm packages, no nix
# packaging), and nixos/nix ships no /lib64 — so the ELF interpreter the loader
# looks for simply is not there. Give them the loader plus libc/libm where a
# normal glibc binary expects to find them. Cheap, and unlike nix-ld it does not
# depend on the binaries resolving anything else out of the store.
RUN G="$(nix eval --raw nixpkgs#glibc.outPath)" \
 && mkdir -p /lib64 /lib/x86_64-linux-gnu \
 && cp -L "$G/lib/ld-linux-x86-64.so.2" /lib64/ \
 && cp -L "$G/lib/libc.so.6" "$G/lib/libm.so.6" /lib/x86_64-linux-gnu/

# The whole install in one command: binaries onto PATH, rendered config into
# $HOME, npm MCP servers seeded, missing tokens reported (a warning, not a
# failure — the tokens belong to the run, not the build).
#
# The gc belongs in THIS layer, not a later one. Docker commits the end state of
# a RUN, so pruning here means the flake sources it evaluated (nixpkgs alone is
# 482 MB) and any build toolchain never reach the image at all. Pruning in a
# later RUN leaves them in the earlier layer's tar and the image only drops from
# 6.4 GB to 4.2 GB, which is nearly nothing.
ARG RUNTIME=github:turbcool/agent-runtime
RUN nix run ${RUNTIME}#install \
 && nix profile install ${RUNTIME}#agent-runtime \
 && nix store gc \
 && { chmod -R u+w /root/.pi /root/.config /root/.claude 2>/dev/null || true; } \
 && rm -rf /root/.npm/_cacache /root/.cache/nix

# /root/.npm/bin is where #install seeds bladebro + donsetch, and the rendered
# MCP registry resolves them as $HOME/.npm/bin/<server> — which is /root here.
# A non-root user needs $HOME/.npm/bin on PATH instead.
ENV PATH=/root/.npm/bin:/root/.local/bin:$PATH
WORKDIR /work

# `claude` reads its provider from the active world, not from whichever token is
# exported: run `profile` to list them and `profile free` to pick one. A fresh
# container has no world state yet, so it falls back to agent.defaultProfile
# (currently `work` → neoplatform). Pass only the token that world needs.