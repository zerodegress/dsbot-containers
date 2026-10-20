# syntax=docker/dockerfile:1.6
# =============================================================================
# L1 — tool image (dsbot-tools). Same base image as the dsbot layer, no dsh and
# no ds-bot: it is a prebuilt variant of the base, not a hidden layer.
#
#   docker build -t dsbot-tools:bookworm -f tools/Dockerfile tools
#   docker build -t dsbot-tools:bookworm-heavy -f tools/Dockerfile tools --build-arg WITH_HEAVY=1
#
# WITH_PACK picks how much of the language stacks comes along:
#   core (default)  documents, PDF, images, web, browsers, data frames
#   full            adds the scientific/ML/vision/notebook/crawling half of the
#                   Python stack and the bundler/linter/test half of the Node CLIs
#                   (+~2.8 GB)
#
# Contracts with the dsbot layer (see docs/architecture.md):
#   * everything here must be readable by a non-root uid: /opt/venv and the
#     Playwright browsers are chmod a+rX, and no tool may expect to write into
#     /usr or $HOME — the dsbot layer points every cache at /data.
#   * LibreOffice ships as -nogui; it conflicts with libreoffice-writer/calc.
# =============================================================================
ARG BASE_IMAGE=docker.io/library/node:22.22-bookworm-slim
FROM ${BASE_IMAGE}

ARG WITH_HEAVY=0
ARG WITH_PACK=core
ARG TZ=Asia/Shanghai
ARG PIP_INDEX_URL=https://pypi.org/simple
ARG NPM_REGISTRY=https://registry.npmjs.org
ARG DOCKER_CLI_VERSION=27.5.1
# jj has no Debian package, and building it needs the rust toolchain that sits
# behind WITH_HEAVY (+~2.5GB), so the published static binary is the only option.
# Pinned by version and sha256 the way the shutup fork is: the tarball lands in
# /usr/local/bin, so a checksum that does not match must stop the build.
ARG JJ_VERSION=0.46.0
ARG JJ_SHA256=fce0271158e665ceb82dc66c5eb95b1728649094e9133074f3b5baece345fc08
# yq must be the Go one (mikefarah), not Debian's 3.1.0: bookworm ships a jq
# wrapper whose expression syntax differs, and a v4 expression given to it fails
# silently with a wrong value. This image pins everything that parses the
# deployment's patch YAML, so it gets the real thing.
ARG YQ_VERSION=4.54.1
ARG YQ_SHA256=e68a456f90c577af3fe4960184b3a3cf5c461e0348407c10f107da3a5fec8972
ARG TOOLS_REVISION=dev
ARG DEBIAN_FRONTEND=noninteractive

ENV LANG=zh_CN.UTF-8 \
    LANGUAGE=zh_CN:zh \
    LC_ALL=zh_CN.UTF-8 \
    TZ=${TZ} \
    PATH=/opt/venv/bin:/usr/local/bin:${PATH} \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_INDEX_URL=${PIP_INDEX_URL} \
    NPM_CONFIG_REGISTRY=${NPM_REGISTRY} \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    PUPPETEER_SKIP_DOWNLOAD=1 \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium \
    PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright \
    DEBIAN_FRONTEND=noninteractive

# --- 1. system, CLI tools, locales ------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl wget aria2 gnupg openssl jq unzip zip tar \
      xz-utils bzip2 p7zip-full unrar-free file \
      git git-lfs less vim nano tmux rsync openssh-client \
      procps htop lsof net-tools iputils-ping dnsutils traceroute netcat-openbsd \
      bc uuid-runtime parallel cron tzdata locales man-db bash-completion \
      ripgrep fd-find fzf tree sqlite3 miller datamash gh \
      time; \
    sed -i 's/^# *zh_CN.UTF-8/zh_CN.UTF-8/' /etc/locale.gen; \
    locale-gen; \
    update-locale LANG=zh_CN.UTF-8; \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime; \
    echo $TZ > /etc/timezone; \
    ln -sf "$(command -v fdfind)" /usr/local/bin/fd; \
    rm -rf /var/lib/apt/lists/*

# --- 2. build toolchain, Python, native headers ------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      build-essential cmake pkg-config autoconf automake libtool gdb strace binutils \
      python3 python3-dev python3-venv python3-pip python3-full pipx \
      zlib1g-dev libbz2-dev libreadline-dev liblzma-dev libsqlite3-dev \
      libssl-dev libffi-dev libxml2-dev libxslt1-dev \
      libjpeg-dev libpng-dev libfreetype6-dev libyaml-dev tk-dev \
      libpq-dev default-libmysqlclient-dev libcurl4-openssl-dev \
      libpango-1.0-0 libpangoft2-1.0-0 libcairo2 libgdk-pixbuf-2.0-0 \
      shared-mime-info libxrender1 libxtst6; \
    rm -rf /var/lib/apt/lists/*

# --- 3. office, media, fonts, OCR -------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      libreoffice-nogui pandoc \
      poppler-utils qpdf ghostscript mupdf-tools imagemagick ffmpeg graphviz \
      tesseract-ocr tesseract-ocr-chi-sim tesseract-ocr-chi-tra tesseract-ocr-eng \
      pngquant optipng jpegoptim gifsicle libimage-exiftool-perl \
      fonts-noto-cjk fonts-noto-color-emoji fonts-dejavu fonts-liberation \
      fonts-wqy-zenhei fonts-wqy-microhei fontconfig; \
    fc-cache -f; \
    rm -rf /var/lib/apt/lists/*

# --- 4. headless browser (system chromium plus Playwright's own copy) --------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends chromium chromium-driver xvfb; \
    rm -rf /var/lib/apt/lists/*

# --- 5. Python virtualenv (core) ---------------------------------------------
COPY python-requirements.txt /tmp/python-requirements.txt
RUN set -eux; \
    python3 -m venv /opt/venv; \
    /opt/venv/bin/pip install --upgrade pip setuptools wheel uv; \
    /opt/venv/bin/pip install -r /tmp/python-requirements.txt; \
    /opt/venv/bin/playwright install --with-deps chromium; \
    rm -rf /tmp/python-requirements.txt /root/.cache/pip /root/.cache/uv

# --- 5b. Python extras (WITH_PACK=full) --------------------------------------
# A separate step so the core layer above stays cacheable.
COPY python-requirements.full.txt /tmp/python-requirements.full.txt
RUN set -eux; \
    [ "$WITH_PACK" = "full" ] || { echo "WITH_PACK=core: skipping the python extras"; exit 0; }; \
    /opt/venv/bin/pip install -r /tmp/python-requirements.full.txt; \
    rm -rf /tmp/python-requirements.full.txt /root/.cache/pip /root/.cache/uv

# --- 6. global Node CLIs (core) ----------------------------------------------
COPY npm-globals.txt /tmp/npm-globals.txt
RUN set -eux; \
    sed -e 's/#.*$//' /tmp/npm-globals.txt | grep -vE '^[[:space:]]*$' \
      | xargs npm install -g --no-fund --no-audit; \
    npm cache clean --force; \
    rm -rf /tmp/npm-globals.txt /root/.npm

# --- 6b. global Node CLIs extras (WITH_PACK=full) ----------------------------
COPY npm-globals.full.txt /tmp/npm-globals.full.txt
RUN set -eux; \
    [ "$WITH_PACK" = "full" ] || { echo "WITH_PACK=core: skipping the npm extras"; exit 0; }; \
    sed -e 's/#.*$//' /tmp/npm-globals.full.txt | grep -vE '^[[:space:]]*$' \
      | xargs npm install -g --no-fund --no-audit; \
    npm cache clean --force; \
    rm -rf /tmp/npm-globals.full.txt /root/.npm

# --- 7. duckdb CLI (not packaged by Debian) ----------------------------------
RUN set -eux; \
    curl -fsSL -o /tmp/duckdb.zip \
      https://github.com/duckdb/duckdb/releases/latest/download/duckdb_cli-linux-amd64.zip; \
    unzip -o /tmp/duckdb.zip -d /usr/local/bin; \
    chmod +x /usr/local/bin/duckdb; \
    rm -f /tmp/duckdb.zip

# --- 8. docker CLI (static; no socket is mounted by default) -----------------
RUN set -eux; \
    curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_CLI_VERSION}.tgz" \
      | tar -xz --strip-components=1 -C /usr/local/bin docker/docker; \
    docker --version

# --- 8b. jj (jujutsu): static musl release, pinned by version + sha256 -------
# No Debian package exists, and the toolchain that would build it is behind
# WITH_HEAVY (+~2.5GB), so the published static binary is the only option. The
# tarball holds ./jj plus LICENSE and README, so it is unpacked into a temp dir
# and only the binary is installed. The checksum is not advisory: a mismatch
# stops the build before anything reaches /usr/local/bin. The binary ships
# unstripped at 31.4 MB; stripping brings it to 25.3 MB and `jj --version` still
# runs, which is most of this layer's budget saved for free.
RUN set -eux; \
    tmp="$(mktemp -d)"; \
    trap 'rm -rf "$tmp"' EXIT; \
    curl -fsSL "https://github.com/jj-vcs/jj/releases/download/v${JJ_VERSION}/jj-v${JJ_VERSION}-x86_64-unknown-linux-musl.tar.gz" -o "$tmp/jj.tgz"; \
    echo "${JJ_SHA256}  $tmp/jj.tgz" | sha256sum -c -; \
    tar -xzf "$tmp/jj.tgz" -C "$tmp"; \
    test -f "$tmp/jj" || { echo "the jj tarball no longer has ./jj at its root; layout changed, refusing to guess" >&2; exit 1; }; \
    install -m 0755 "$tmp/jj" /usr/local/bin/jj; \
    strip /usr/local/bin/jj; \
    jj --version

# --- 8c. yq v4 (Go, static): the real one, not bookworm's 3.1.0 --------------
# Debian ships yq 3.1.0, a jq wrapper with different expression syntax. A v4
# expression handed to it does not error — it returns a wrong value, which is the
# worst failure mode for anything parsing the deployment's patch YAML. The
# tarball carries the binary plus a man page and an install script, so only
# `yq_linux_amd64` is installed. `strip` is deliberately not run: measured on
# v4.54.1 it does not shrink the binary at all (14,168,232 vs 14,168,224 bytes),
# because the release is already stripped.
RUN set -eux; \
    tmp="$(mktemp -d)"; \
    trap 'rm -rf "$tmp"' EXIT; \
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64.tar.gz" -o "$tmp/yq.tgz"; \
    echo "${YQ_SHA256}  $tmp/yq.tgz" | sha256sum -c -; \
    tar -xzf "$tmp/yq.tgz" -C "$tmp"; \
    test -f "$tmp/yq_linux_amd64" || { echo "the yq tarball no longer has yq_linux_amd64 at its root; layout changed, refusing to guess" >&2; exit 1; }; \
    install -m 0755 "$tmp/yq_linux_amd64" /usr/local/bin/yq; \
    yq --version; \
    printf 'a: {b: 1}\n' | yq -o=json '.a' | grep -q '"b": 1'

# --- 9. optional heavy layer (+~2.5GB with --build-arg WITH_HEAVY=1) ---------
RUN set -eux; \
    if [ "$WITH_HEAVY" = "1" ]; then \
      apt-get update; \
      apt-get install -y --no-install-recommends \
        openjdk-17-jre-headless \
        texlive-xetex texlive-latex-recommended texlive-fonts-recommended \
        texlive-lang-chinese latexmk \
        golang-go rustc cargo; \
      rm -rf /var/lib/apt/lists/*; \
    fi

# --- 10. non-root readability + provenance -----------------------------------
# BASE_IMAGE is declared before FROM, where it is only in scope for FROM itself.
# Re-declaring it here, next to its only use inside the stage, keeps the
# instruction stream above untouched so the expensive layers stay cacheable.
ARG BASE_IMAGE
RUN set -eux; \
    # Only touch entries that are not already world-readable: a blanket
    # chmod -R over these trees copies every file into a new layer (3.4 GB of
    # pure duplication under overlayfs) for no permission change at all.
    find /opt/venv /opt/ms-playwright ! -type d ! -perm -o+r -exec chmod a+r {} +; \
    find /opt/venv /opt/ms-playwright -type d ! -perm -o+rx -exec chmod a+rx {} +; \
    echo "non-world-readable entries left: $(find /opt/venv /opt/ms-playwright ! -perm -o+r 2>/dev/null | wc -l)"; \
    printf 'tools_revision=%s\nbase_image=%s\npack=%s\nwith_heavy=%s\nbuilt=%s\n' \
      "$TOOLS_REVISION" "${BASE_IMAGE:-unset}" "$WITH_PACK" "$WITH_HEAVY" "$(date -u +%FT%TZ)" > /opt/tools-version; \
    cat /opt/tools-version

COPY doctor.sh /opt/tools/doctor.sh
RUN chmod 0755 /opt/tools/doctor.sh
