# syntax=docker/dockerfile:1.6
# =============================================================================
# L2 — dsbot image: dsh + ds-bot + the two bundled plugins, on top of the tool
# image. Every version is a build argument; the build fails loudly when a pin
# and a declared compatibility range disagree, so a plugin that dsh would skip
# cannot reach a running container unnoticed.
#
#   docker build -t dsbot-containers:local . \
#     --build-arg TOOLS_IMAGE=dsbot-tools:bookworm \
#     --build-arg DSH_VERSION=0.2.0-rc.2 \
#     --build-arg DS_BOT_VERSION=0.1.6
#
# docs/development.md has the version matrix; docs/security.md explains why
# shutup and the login gate are installed as a pair.
# =============================================================================
ARG TOOLS_IMAGE=docker.io/library/node:22.22-bookworm-slim
FROM ${TOOLS_IMAGE}

ARG DSH_VERSION=0.2.0-rc.2
# forge:npm-arg — the --allow-scripts flag below is enforced by npm itself.
# The base image (node 22.22) ships npm 10.9.8, whose config definitions have
# no allow-scripts key at all (only allow-same-version); the key appears in npm
# 12. The upstream reference installs from node 24, npm 11.3.0, and never
# notices. This image upgrades npm first and then proves the upgrade took.
ARG NPM_VERSION=12
ARG DS_BOT_VERSION=0.1.6
ARG AUTH_GATE_VERSION=0.17.4
# link-fgfgui/dsh-shutup is unmaintained; we track our own fork of it.
# The default is a placeholder: a deployment must pass its own fork here
# (--build-arg SHUTUP_REPO=…), because SHUTUP_SHA256 only verifies that fork.
ARG SHUTUP_REPO=https://github.com/your-org/dsh-shutup
ARG SHUTUP_COMMIT=4d4aeb6759f23991290e6227b57a9b8594f04202
ARG SHUTUP_SHA256=f457899a489dcaee62e86ed0e6cdf856d00f2d7292007270a54f6ddfdebef5db
ARG INSTALL_SHUTUP=1
ARG INSTALL_AUTH_GATE=1
ARG STRICT_VERSIONS=1
ARG NPM_REGISTRY=https://registry.npmjs.org
ARG DEBIAN_FRONTEND=noninteractive

ENV DSH_HOME=/data \
    DSH_PORT=3080 \
    NODE_PATH=/usr/local/lib/node_modules:/data/.npm-global/lib/node_modules \
    PATH=/opt/venv/bin:/data/.npm-global/bin:/data/.pnpm-home:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    PNPM_HOME=/data/.pnpm-home \
    npm_config_store_dir=/data/.pnpstore \
    npm_config_cache=/data/.npmcache \
    npm_config_prefix=/data/.npm-global \
    npm_config_update_notifier=false \
    NPM_CONFIG_REGISTRY=${NPM_REGISTRY} \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    XDG_CACHE_HOME=/data/.cache \
    XDG_CONFIG_HOME=/data/.config \
    XDG_DATA_HOME=/data/.local/share \
    XDG_STATE_HOME=/data/.local/state \
    PIP_CACHE_DIR=/data/.cache/pip \
    UV_CACHE_DIR=/data/.cache/uv \
    CARGO_HOME=/data/.cargo \
    RUSTUP_HOME=/data/.rustup \
    GOPATH=/data/.go \
    GOMODCACHE=/data/.go/mod \
    GOCACHE=/data/.go/build \
    JJ_CONFIG=/data/.config/jj/config.toml \
    GIT_CONFIG_GLOBAL=/data/.config/git/config \
    PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium \
    LANG=zh_CN.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

# The agent shell runs under a Landlock profile that only grants writes to the
# session workspace, /tmp and its private tmpdir — the set is hard-coded in dsh
# (`writableRoots()`), so the /data paths above are unreachable from inside it.
# Every non-interactive bash therefore sources agent-env.sh, which points XDG and
# every cache at `<workspace>/.home`. HOME is deliberately left alone: it is the
# configuration root of dsh and of several tools at once. The variables above
# stay as they are — they are what the entrypoint, dsh itself and any unsandboxed
# child use, and they are the list agent-env.sh overrides. See
# docs/configuration.md.
ENV BASH_ENV=/opt/dsbot/agent-env.sh

# --- 0. base sanity: node >= 22.22.2; the tools layer is optional ------------
# The floor follows the base this repository pins: npm 12 (the default
# NPM_VERSION) needs node ^22.22.2, so a base below that cannot install it.
RUN set -eux; \
    node -e "const [a,b,c]=process.versions.node.split('.').map(Number); if(a<22||(a===22&&b<22)||(a===22&&b===22&&c<2)) { console.error('node '+process.versions.node+' < 22.22.2 (npm '+(process.env.NPM_VERSION||'')+' needs node ^22.22.2)'); process.exit(1) }"; \
    if [ -f /opt/tools-version ]; then echo "base: tools layer"; cat /opt/tools-version; \
    else echo "base: bare (no /opt/tools-version) — building a tool-less image"; fi

# --- 1. runtime minimum: tini as PID 1, plus curl/git to fetch plugins ------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends tini ca-certificates curl git; \
    rm -rf /var/lib/apt/lists/*; \
    tini --version

# --- 2. assert ds-bot's own dsh pin, when the package declares one -----------
RUN set -eux; \
    DSH_VERSION="$DSH_VERSION" DS_BOT_VERSION="$DS_BOT_VERSION" STRICT_VERSIONS="$STRICT_VERSIONS" REG="$NPM_REGISTRY" \
    node -e 'const V=process.env.DSH_VERSION,B=process.env.DS_BOT_VERSION,S=process.env.STRICT_VERSIONS; \
      fetch(process.env.REG.replace(/\/$/,"")+"/ds-bot/"+B) \
        .then(r=>r.json()).then(m=>{ \
          const v=m.dsBot&&m.dsBot.verifiedDsh; \
          if(!v){console.log("ds-bot@"+B+": no dsBot.verifiedDsh (nothing to assert)");return} \
          if(v===V){console.log("ds-bot@"+B+": verifiedDsh="+v+" matches pinned dsh "+V);return} \
          const msg="ds-bot@"+B+" declares verifiedDsh="+v+" but the image pins dsh "+V; \
          if(S==="1"){console.error(msg);process.exit(1)} console.warn(msg) \
        }) \
        .catch(e=>{console.error("version self-check could not reach the registry:",e.message);process.exit(1)})'

# --- 3. dsh itself, pinned ---------------------------------------------------
# --prefix /usr/local is not redundant: ENV npm_config_prefix points global
# installs at /data so the agent can install packages at run time on a read-only
# root, and that redirection must not apply here. dsh has to live in the image,
# not in the volume, or mounting a volume over /data would hide it.
RUN set -eux; \
    npm install -g --prefix /usr/local "npm@${NPM_VERSION}"; \
    test "$(npm --version | cut -d. -f1)" -ge 11 || { \
      echo "npm $(npm --version) has no --allow-scripts; set NPM_VERSION to 11 or newer" >&2; exit 1; }; \
    # forge:allow-scripts — the whitelist is enforced by npm here.
    npm install -g --prefix /usr/local "pnpm@10" "@deepseek-ai/dsh@${DSH_VERSION}" \
        --allow-scripts=@deepseek-ai/dsh-subprocess-local,node-pty,koffi,@google/genai,protobufjs; \
    test -f /usr/local/lib/node_modules/@deepseek-ai/dsh/package.json; \
    dsh --version; \
    npm cache clean --force; rm -rf /root/.npm

# Packages below become "carried packages" of dsh: dsh resolves plugin names
# against its own declared dependencies, so dropping a directory in place is not
# enough — it must also be registered in dsh's package.json. Unpacking a tarball
# and registering it by hand avoids npm's tree resolver, which cannot handle
# these packages' peer dependencies. Never install their peers: a second copy of
# @deepseek-ai/cordis would mean a second service registry.

# --- 4. ds-bot (no runtime dependencies of its own) --------------------------
RUN set -eux; \
    D=/usr/local/lib/node_modules/@deepseek-ai/dsh; \
    cd /tmp; npm pack "ds-bot@${DS_BOT_VERSION}" --silent > /dev/null; \
    mkdir -p "$D/node_modules/ds-bot"; \
    tar -xzf "ds-bot-${DS_BOT_VERSION}.tgz" --strip-components=1 -C "$D/node_modules/ds-bot"; \
    rm -f "ds-bot-${DS_BOT_VERSION}.tgz"; \
    D="$D" V="$DS_BOT_VERSION" node -e "const fs=require('fs'),p=process.env.D+'/package.json',j=JSON.parse(fs.readFileSync(p,'utf8'));j.dependencies['ds-bot']=process.env.V;fs.writeFileSync(p,JSON.stringify(j,null,2))"; \
    node -e "for (const m of ['ds-bot','ds-bot/web-search']) require.resolve(m,{paths:['$D/node_modules']}); console.log('ds-bot resolvable (web-search subpath included):', require('$D/package.json').dependencies['ds-bot'])"

# --- 5. login gate (dsh-auth-gate): default token mode, fail-closed ----------
# It imports yaml and zod, which the dsh tree does not carry, so those two are
# unpacked next to it; every other import resolves to dsh's own copy.
COPY scripts/check-dsh-auth-gate.js /opt/scripts/check-dsh-auth-gate.js
RUN set -eux; \
    [ "$INSTALL_AUTH_GATE" = "1" ] || { echo "auth gate disabled (INSTALL_AUTH_GATE=0)"; exit 0; }; \
    D=/usr/local/lib/node_modules/@deepseek-ai/dsh; \
    cd /tmp; npm pack "dsh-auth-gate@${AUTH_GATE_VERSION}" "yaml@2" "zod@4" --silent > /dev/null; \
    mkdir -p /opt/dsh-plugins/dsh-auth-gate "$D/node_modules/yaml" "$D/node_modules/zod"; \
    tar -xzf "dsh-auth-gate-${AUTH_GATE_VERSION}.tgz" --strip-components=1 -C /opt/dsh-plugins/dsh-auth-gate; \
    tar -xzf yaml-*.tgz --strip-components=1 -C "$D/node_modules/yaml"; \
    tar -xzf zod-*.tgz  --strip-components=1 -C "$D/node_modules/zod"; \
    rm -f ./*.tgz; \
    rm -rf "$D/node_modules/dsh-auth-gate"; \
    cp -a /opt/dsh-plugins/dsh-auth-gate "$D/node_modules/dsh-auth-gate"; \
    D="$D" V="$AUTH_GATE_VERSION" node -e "const fs=require('fs'),p=process.env.D+'/package.json',j=JSON.parse(fs.readFileSync(p,'utf8'));j.dependencies['dsh-auth-gate']=process.env.V;fs.writeFileSync(p,JSON.stringify(j,null,2))"; \
    D="$D" DSH_VERSION="$DSH_VERSION" node /opt/scripts/check-dsh-auth-gate.js; \
    test -f /opt/dsh-plugins/dsh-auth-gate/cordis.patch.yml; \
    node -e "console.log('dsh-auth-gate carried by dsh:', require('$D/package.json').dependencies['dsh-auth-gate'])"

# --- 6. dsh-shutup: our fork at a pinned commit ------------------------------
# The fork tracks the dsh line this image pins; a port to a new dsh line is a
# commit there, not a patch here.
RUN set -eux; \
    [ "$INSTALL_SHUTUP" = "1" ] || { echo "shutup disabled (INSTALL_SHUTUP=0)"; exit 0; }; \
    D=/usr/local/lib/node_modules/@deepseek-ai/dsh; \
    mkdir -p /opt/dsh-plugins/dsh-shutup; \
    curl -fsSL "${SHUTUP_REPO}/archive/${SHUTUP_COMMIT}.tar.gz" -o /tmp/shutup.tgz; \
    echo "${SHUTUP_SHA256}  /tmp/shutup.tgz" | sha256sum -c -; \
    tar -xzf /tmp/shutup.tgz --strip-components=1 -C /opt/dsh-plugins/dsh-shutup; \
    rm -f /tmp/shutup.tgz; \
    rm -rf "$D/node_modules/dsh-shutup"; \
    cp -a /opt/dsh-plugins/dsh-shutup "$D/node_modules/dsh-shutup"; \
    D="$D" node -e "const fs=require('fs'),p=process.env.D+'/package.json',j=JSON.parse(fs.readFileSync(p,'utf8'));j.dependencies['dsh-shutup']=require(process.env.D+'/node_modules/dsh-shutup/package.json').version;fs.writeFileSync(p,JSON.stringify(j,null,2))"; \
    node -e "for (const m of ['dsh-shutup/startup','dsh-shutup','commander','@deepseek-ai/dsh-cmdline']) require.resolve(m,{paths:['$D/node_modules']}); console.log('dsh-shutup resolvable:', require('$D/package.json').dependencies['dsh-shutup'])"

# --- 7. gate pairing: warn, never refuse (the operator owns the risk) ---------
RUN set -eux; \
    if [ "$INSTALL_SHUTUP" != "$INSTALL_AUTH_GATE" ]; then \
      echo "WARNING: INSTALL_SHUTUP=$INSTALL_SHUTUP with INSTALL_AUTH_GATE=$INSTALL_AUTH_GATE"; \
      echo "  shutup removes dsh's own token gate, and the login gate is what replaces it."; \
      echo "  This image therefore has no gate of its own. Front it with an authenticated"; \
      echo "  proxy or keep it on a private network, or set both build args the same way."; \
      echo "  Building anyway: the operator owns that risk." >&2; \
    fi

# --- 8. seed: a clean web profile with only dsh's own bundles ----------------
RUN set -eux; \
    mkdir -p /opt/dsh-seed; \
    DSH_HOME=/opt/dsh-seed dsh --profile web --dump-config > /dev/null; \
    test -f /opt/dsh-seed/profiles/web/package.json; \
    ! grep -q '"ds-bot"' /opt/dsh-seed/profiles/web/package.json

# --- 9. image-owned files ----------------------------------------------------
COPY dsh-layers/base-layer.patch.yml /opt/dsh-layers/base-layer.patch.yml
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/dsbot-plugins.js /usr/local/bin/dsbot-plugins
# agent-env.sh is sourced by every non-interactive bash (BASH_ENV above); it
# moves HOME and the caches into <workspace>/.home, because the sandbox only
# grants writes there. It must be readable, silent and harmless when it cannot
# adopt a directory — the checks below hold it to that.
COPY scripts/agent-env.sh /opt/dsbot/agent-env.sh
# Skills the image ships: the Bot reads them through skill-filesystem, which the
# deployment layer points at this directory (customSkillDirs).
COPY skills/ /opt/dsh-skills/
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/dsbot-plugins \
 && chmod -R a+rX /opt/dsh-skills \
 && test -f /opt/dsh-skills/dsbot-self-config/SKILL.md \
 && node --check /usr/local/bin/dsbot-plugins

# agent-env.sh must be syntax-clean, silent, and behave in exactly four ways:
# adopt a writable cwd, refuse a tmpfs, leave an unwritable cwd alone, and honour
# the off switch. This runs as root during the build, so it tests the script's own
# logic; the sandbox it works around does not exist here, which is why every
# assertion is about what the script sets rather than whether a write is denied.
RUN set -eux; \
    chmod 0755 /opt/dsbot/agent-env.sh; \
    sh -n /opt/dsbot/agent-env.sh; \
    test "$BASH_ENV" = /opt/dsbot/agent-env.sh; \
    # /tmp is a tmpfs and the script refuses those, so the fixture lives in /opt. \
    ws=/opt/agent-env-selftest; rm -rf "$ws"; mkdir -p "$ws"; \
    home="$(cd "$ws" && DSH_SESSION_ID=build-selftest bash -c 'printf %s "$HOME"')"; \
    [ "$home" = "$ws/.home" ] || { echo "agent-env: HOME not adopted, got $home"; exit 1; }; \
    for v in XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_STATE_HOME PIP_CACHE_DIR UV_CACHE_DIR npm_config_cache npm_config_store_dir CARGO_HOME RUSTUP_HOME GOMODCACHE GOCACHE JJ_CONFIG GIT_CONFIG_GLOBAL DSBOT_AGENT_HOME; do \
      out="$(cd "$ws" && DSH_SESSION_ID=build-selftest bash -c "printf %s \"\$$v\"")"; \
      [ -n "$out" ] || { echo "agent-env: $v not set"; exit 1; }; \
      case "$out" in "$ws"/*) ;; *) echo "agent-env: $v does not point inside $ws ($out)"; exit 1;; esac; \
    done; \
    for d in .config/git .config/jj .cache/pip .cache/uv .npmcache .pnpstore .npm-global/bin .local/share .local/state .cargo .rustup .go/mod .go/build; do \
      [ -d "$ws/.home/$d" ] || { echo "agent-env: $ws/.home/$d was not created"; exit 1; }; \
    done; \
    out="$(cd /tmp && DSH_SESSION_ID=build-selftest bash -c 'printf %s "$HOME"')"; \
    case "$out" in /tmp/*) echo "agent-env: adopted a tmpfs ($out)"; exit 1;; esac; \
    out="$(cd / && DSH_SESSION_ID=build-selftest bash -c 'printf %s "$XDG_CONFIG_HOME"')"; \
    case "$out" in "$ws"/*) echo "agent-env: adopted a directory it cannot write ($out)"; exit 1;; esac; \
    out="$(cd "$ws" && DSBOT_NO_AGENT_ENV=1 DSH_SESSION_ID=build-selftest bash -c 'printf %s "$XDG_CONFIG_HOME"')"; \
    case "$out" in "$ws"/*) echo "agent-env: DSBOT_NO_AGENT_ENV=1 was ignored ($out)"; exit 1;; esac; \
    out="$(cd "$ws" && DSH_SESSION_ID=build-selftest bash -c 'printf %s "$XDG_CONFIG_HOME"' 2>&1 >/dev/null)"; \
    [ -z "$out" ] || { echo "agent-env: wrote to stderr, it must be silent: $out"; exit 1; }; \
    rm -rf "$ws"; \
    echo "agent-env: adopts a writable cwd, refuses tmpfs, leaves unwritable dirs alone, silent, off switch works"

# Self-check the base layer: it must apply and must land the ds-bot row, the
# web-search row and the bot config override. --dump-config composes the tree
# without starting dsh.
RUN set -eux; \
    mkdir -p /opt/verify; \
    DSH_HOME=/opt/verify dsh --profile web --patch /opt/dsh-layers/base-layer.patch.yml --dump-config > /opt/verify/dump.yml; \
    grep -q 'ds-bot' /opt/verify/dump.yml; \
    if ! grep -q 'web-search-auto' /opt/verify/dump.yml; then \
      echo "base layer did not insert the web-search row (ds-bot/web-search); dump excerpt:"; \
      grep -n -B2 -A4 'web-search' /opt/verify/dump.yml | head -40; exit 1; \
    fi; \
    if ! grep -q 'updateCheck' /opt/verify/dump.yml; then \
      echo "base-layer config override for id 'bot' did not land; dump excerpt:"; \
      grep -n -A4 -B2 'bot' /opt/verify/dump.yml | head -40; exit 1; \
    fi; \
    rm -rf /opt/verify; \
    echo "base layer applies, registers ds-bot and web-search, and lands the bot config override"

RUN set -eux; \
    tools_meta='bare'; \
    if [ -f /opt/tools-version ]; then \
      tools_rev="$(sed -n 's/^tools_revision=//p' /opt/tools-version | head -1)"; \
      tools_pack="$(sed -n 's/^pack=//p' /opt/tools-version | head -1)"; \
      tools_meta="${tools_rev:-unknown} pack=${tools_pack:-unknown}"; \
    fi; \
    printf 'dsbot=%s\ndsh=%s\nauth_gate=%s\nauth_gate_version=%s\nshutup=%s\nshutup_commit=%s\ntools=%s\nbuilt=%s\n' \
      "$DS_BOT_VERSION" "$DSH_VERSION" "$INSTALL_AUTH_GATE" "$AUTH_GATE_VERSION" "$INSTALL_SHUTUP" "$SHUTUP_COMMIT" \
      "$tools_meta" "$(date -u +%FT%TZ)" \
      > /etc/dsbot-versions; \
    cat /etc/dsbot-versions; \
    # forge:recipe — one line per artifact, and where it came from.
    printf 'dsh %s\nds-bot %s\nnpm %s\nscripts %s\ndsh-auth-gate %s\ndsh-shutup %s\nshutup_commit %s\ntools %s\nbuilt %s\n' \
      "$DSH_VERSION" "$DS_BOT_VERSION" "$(npm --version 2>/dev/null || echo unknown)" "${scripts_meta:-unknown}" \
      "$AUTH_GATE_VERSION" "$INSTALL_SHUTUP" "$SHUTUP_COMMIT" \
      "$tools_meta" "$(date -u +%FT%TZ)" \
      > /etc/dsbot-recipe; \
    cat /etc/dsbot-recipe

# --- 10. runtime identity: non-root, everything writable lives in /data ------
# /data/bot/workspace is created here, before the chown: WORKDIR below runs after
# it and would otherwise create the directory as root, which 10001 cannot write.
RUN set -eux; \
    groupadd -g 10001 dsbot 2>/dev/null || true; \
    useradd -u 10001 -g 10001 -M -d /data -s /bin/bash dsbot 2>/dev/null || true; \
    mkdir -p /data /etc/dsbot/overlay /data/bot/workspace; \
    chown -R 10001:10001 /data; \
    chmod -R a+rX /opt/dsh-seed /opt/dsh-plugins /opt/dsh-layers /opt/dsh-skills 2>/dev/null || true

USER 10001:10001
WORKDIR /data/bot/workspace
# forge:oci-labels — a registry listing should describe the image on its own.
# IMAGE_SOURCE is the OCI source label; it defaults to a placeholder, so a
# deployment passes --build-arg IMAGE_SOURCE=<its own repository URL>.
ARG IMAGE_SOURCE=https://github.com/your-org/dsbot-containers
LABEL org.opencontainers.image.title="dsbot-containers" \
      org.opencontainers.image.description="DS Bot on DeepSeek Harness: dsh web plus the bundled shutup and login-gate pair, non-root on a read-only root" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.licenses="Apache-2.0"

VOLUME ["/data"]
EXPOSE 3080
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
