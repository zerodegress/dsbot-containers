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
ARG BASE_IMAGE=docker.io/library/node:22.19-bookworm-slim
FROM ${BASE_IMAGE}

ARG WITH_HEAVY=0
ARG WITH_PACK=core
ARG TZ=Asia/Shanghai
ARG PIP_INDEX_URL=https://pypi.org/simple
ARG NPM_REGISTRY=https://registry.npmjs.org
ARG DOCKER_CLI_VERSION=27.5.1
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
      ripgrep fd-find fzf tree sqlite3 miller datamash gh; \
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
