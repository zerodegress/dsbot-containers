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
ARG TOOLS_IMAGE=docker.io/library/node:22.19-bookworm-slim
FROM ${TOOLS_IMAGE}

ARG DSH_VERSION=0.2.0-rc.2
ARG DS_BOT_VERSION=0.1.6
ARG AUTH_GATE_VERSION=0.17.4
# link-fgfgui/dsh-shutup is unmaintained; we track our own fork of it.
ARG SHUTUP_REPO=https://github.com/zerodegress/dsh-shutup
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
    PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium \
    LANG=zh_CN.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

# --- 0. base sanity: node >= 22.19; the tools layer is optional --------------
RUN set -eux; \
    node -e "const [a,b]=process.versions.node.split('.').map(Number); if(a<22||(a===22&&b<19)) { console.error('node '+process.versions.node+' < 22.19'); process.exit(1) }"; \
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
    npm install -g --prefix /usr/local "pnpm@10" "@deepseek-ai/dsh@${DSH_VERSION}"; \
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
    node -e "require.resolve('ds-bot',{paths:['$D/node_modules']}); console.log('ds-bot resolvable:', require('$D/package.json').dependencies['ds-bot'])"

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

# --- 7. the pair is all-or-nothing -------------------------------------------
RUN set -eux; \
    if [ "$INSTALL_SHUTUP" != "$INSTALL_AUTH_GATE" ]; then \
      echo "refusing to build: INSTALL_SHUTUP=$INSTALL_SHUTUP but INSTALL_AUTH_GATE=$INSTALL_AUTH_GATE"; \
      echo "shutup removes dsh's own token gate; the login gate is what replaces it."; \
      exit 1; \
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
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/dsbot-plugins \
 && node --check /usr/local/bin/dsbot-plugins

# Self-check the base layer: it must apply and must land both the ds-bot row and
# its config override. --dump-config composes the tree without starting dsh.
RUN set -eux; \
    mkdir -p /opt/verify; \
    DSH_HOME=/opt/verify dsh --profile web --patch /opt/dsh-layers/base-layer.patch.yml --dump-config > /opt/verify/dump.yml; \
    grep -q 'ds-bot' /opt/verify/dump.yml; \
    if ! grep -q 'updateCheck' /opt/verify/dump.yml; then \
      echo "base-layer config override for id 'bot' did not land; dump excerpt:"; \
      grep -n -A4 -B2 'bot' /opt/verify/dump.yml | head -40; exit 1; \
    fi; \
    rm -rf /opt/verify; \
    echo "base layer applies, registers ds-bot, and lands the bot config override"

RUN set -eux; \
    printf 'dsbot=%s\ndsh=%s\nauth_gate=%s\nshutup=%s\nshutup_commit=%s\ntools=%s\nbuilt=%s\n' \
      "$DS_BOT_VERSION" "$DSH_VERSION" "$AUTH_GATE_VERSION" "$INSTALL_SHUTUP" "$SHUTUP_COMMIT" \
      "$( [ -f /opt/tools-version ] && head -1 /opt/tools-version || echo 'bare' )" "$(date -u +%FT%TZ)" \
      > /etc/dsbot-versions; \
    cat /etc/dsbot-versions

# --- 10. runtime identity: non-root, everything writable lives in /data ------
RUN set -eux; \
    groupadd -g 10001 dsbot 2>/dev/null || true; \
    useradd -u 10001 -g 10001 -M -d /data -s /bin/bash dsbot 2>/dev/null || true; \
    mkdir -p /data /etc/dsbot/overlay; \
    chown -R 10001:10001 /data; \
    chmod -R a+rX /opt/dsh-seed /opt/dsh-plugins /opt/dsh-layers 2>/dev/null || true

USER 10001:10001
WORKDIR /data/bot/workspace
VOLUME ["/data"]
EXPOSE 3080
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
