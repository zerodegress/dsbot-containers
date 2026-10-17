#!/bin/sh
# =============================================================================
# Container entrypoint.
#
#   0. import secrets from /run/secrets/dsh.env, run /docker-entrypoint.d hooks
#   1. seed the volume from the image on first start
#   2. bootstrap the login gate token when none was supplied
#   3. reconcile the plugins declared by the deployment layer
#   4. compose the patch order (volume -> image plugins -> mounted overlay -> image base)
#   5. preflight: the login gate must be in the composed tree
#   6. start, then probe: an unauthenticated request must not get the app shell
#
# The last two checks exist because shutup removes dsh's own token gate: if the
# login gate were skipped, nothing would be left. SKIP_GATE_CHECK=1 disables
# them; use it only while debugging.
# =============================================================================
set -eu

: "${DSH_HOME:=/data}"
: "${DSH_PORT:=3080}"
: "${DSH_BIND_HOST:=127.0.0.1}"
: "${SKIP_GATE_CHECK:=0}"
: "${DSH_PUBLIC_URL:=}"
: "${DSH_TRUSTED_HOST:=}"

log() { printf 'dsbot: %s\n' "$*"; }
die() { printf 'dsbot: FATAL %s\n' "$*" >&2; exit 1; }
# The probe writes the body to disk: the signal is "did an unauthenticated
# request receive the app shell", not the status code.
probe() { curl -s -m 5 -o "$TMP/probe.body" -w '%{http_code}' "$@" 2>/dev/null || echo 000; }

# --- 0. secrets --------------------------------------------------------------
if [ -f /run/secrets/dsh.env ]; then
    set -a
    # shellcheck disable=SC1091
    . /run/secrets/dsh.env
    set +a
    log "secrets: imported /run/secrets/dsh.env"
fi
if [ -d /docker-entrypoint.d ]; then
    for f in /docker-entrypoint.d/*.sh; do
        [ -x "$f" ] || continue
        log "hook: $f"
        "$f"
    done
fi

# --- 1. seed the volume (only when it has no profile yet) --------------------
if [ ! -f "$DSH_HOME/profiles/web/package.json" ]; then
    log "seeding $DSH_HOME from image seed"
    mkdir -p "$DSH_HOME"
    cp -a /opt/dsh-seed/. "$DSH_HOME"/
fi

# Every path dsh, pnpm and npm may want to write to, on a read-only root.
mkdir -p "$DSH_HOME/bot/workspace" \
         "$DSH_HOME/.pnpstore" "$DSH_HOME/.npmcache" \
         "$DSH_HOME/.pnpm-home" "$DSH_HOME/.npm-global" "$DSH_HOME/.cache" \
         "$DSH_HOME/auth"

# --- 2. login gate token -----------------------------------------------------
AUTH_MODE="$(sed -n 's/^auth_gate=//p' /etc/dsbot-versions 2>/dev/null | head -1 || true)"
SHUTUP_MODE="$(sed -n 's/^shutup=//p' /etc/dsbot-versions 2>/dev/null | head -1 || true)"

if [ -z "${DSH_AUTH_TOKEN:-}" ] && [ "$AUTH_MODE" = "1" ]; then
    TOKEN_FILE="$DSH_HOME/auth/token"
    if [ ! -s "$TOKEN_FILE" ]; then
        umask 077
        head -c 32 /dev/urandom | base64 | tr -d '=+/\n' > "$TOKEN_FILE"
        log "generated a login token and stored it at $TOKEN_FILE (0600)"
    fi
    DSH_AUTH_TOKEN="$(cat "$TOKEN_FILE")"
    export DSH_AUTH_TOKEN
    log "login token (save it now, it will not be printed again): $DSH_AUTH_TOKEN"
fi

# --- 3. plugins declared by the deployment layer -----------------------------
# Plugins bundled with the image arrive as carried packages plus --patch, so
# nothing can remove them. Plugins declared in the overlay are installed into
# the volume profile, where dsh picks them up as bundles.
if [ "${SKIP_OVERLAY_PLUGINS:-0}" != "1" ] && [ -x /usr/local/bin/dsbot-plugins ]; then
    if ! /usr/local/bin/dsbot-plugins sync; then
        die "the config layer (overlay) declares plugins that could not be installed; set OVERLAY_PLUGINS_STRICT=0 to continue anyway"
    fi
fi

# --- 4. patch order: later wins ---------------------------------------------
# The deployment layer outranks the volume profile, and the image base layer
# outranks both: what the image pins — the rows it inserts and the settings
# nobody is meant to change — is the last word, so no mounted patch can undo it.
# The bundled plugins' patches stay below the deployment layer, because their
# config is meant to be set from there.
set -- --profile web
for f in /opt/dsh-plugins/dsh-shutup/cordis.patch.yml \
         /opt/dsh-plugins/dsh-auth-gate/cordis.patch.yml \
         /etc/dsbot/overlay.yml; do
    [ -f "$f" ] && set -- "$@" --patch "$f"
done
if [ -d /etc/dsbot/overlay ]; then
    for p in $(ls -1 /etc/dsbot/overlay/*.patch.yml 2>/dev/null | sort); do
        set -- "$@" --patch "$p"
    done
fi
if [ -f /opt/dsh-layers/base-layer.patch.yml ]; then
    set -- "$@" --patch /opt/dsh-layers/base-layer.patch.yml
fi


# forge:reconcile — the ds-bot model this image uses; see docs/recipes.md
# --- 1b. ds-bot: what dsh will actually load vs what the image carries -------
# ds-bot is a carried package of the dsh installation, and dsh resolves a bundle
# from the installation anchor BEFORE the profile directory
# (@deepseek-ai/dsh-app-boot: resolveBundleDir() walks [installAnchor,
# <profile>/package.json]). So the copy here is the one that runs, and a copy
# that an older volume has under profiles/web/node_modules/ds-bot is shadowed —
# it is never the version that starts. The upstream image (github.com/
# Fei2411/DeepSeek-Bot, docker/entrypoint.sh:30-36) installs ds-bot into the
# profile instead and reinstalls it there on version drift; on this model that
# write would be a silent no-op, which is why the check below resolves the
# package the way dsh does and reports the answer instead of "fixing" it.
# The root is read-only (non-root runtime), so a carried package cannot be raised at
# runtime either: the only lever is DS_BOT_VERSION at build time. This step
# exists to make a mismatch loud, never to work around it.
ds_bot_resolve() { # package-name -> dir the Node loader would import, or empty
    pkg="$1"
    dsh_bin="$(command -v dsh 2>/dev/null || true)"
    [ -n "$dsh_bin" ] || return 0
    dsh_bin="$(readlink -f "$dsh_bin" 2>/dev/null || printf '%s' "$dsh_bin")"
    dsh_root="$(dirname "$(dirname "$dsh_bin")")"
    dir="$dsh_root"
    while [ -n "$dir" ]; do
        for cand in "$dir/node_modules/$pkg" "$dir/$pkg"; do
            if [ -f "$cand/package.json" ]; then printf '%s' "$cand"; return 0; fi
        done
        [ "$dir" = "/" ] && break
        dir="$(dirname "$dir")"
    done
}

image_ds_bot="$(sed -n 's/^dsbot=//p' /etc/dsbot-versions 2>/dev/null | head -1)"
resolved_dir=$(ds_bot_resolve ds-bot)
resolved_ds_bot=""
if [ -n "$resolved_dir" ]; then
    resolved_ds_bot=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$resolved_dir/package.json" 2>/dev/null | head -1 || true)
    log "ds-bot: dsh will load $resolved_dir (version ${resolved_ds_bot:-unknown})"
fi

profile_pkg="$DSH_HOME/profiles/web/node_modules/ds-bot/package.json"
profile_ds_bot=""
[ -f "$profile_pkg" ] && profile_ds_bot=$(sed -n \
    's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$profile_pkg" 2>/dev/null | head -1 || true)
case "$resolved_dir" in
    "$DSH_HOME"/profiles/*)
        log "ds-bot: the carrying dsh resolves it from the profile, not the image"
        ;;
    *)
        if [ -n "$profile_ds_bot" ]; then
            log "WARNING: the volume has ds-bot ${profile_ds_bot} under profiles/web/node_modules, but dsh"
            log "WARNING: resolves the carried copy first; that volume copy is dead weight and ignored."
        fi
        ;;
esac
# Drift cannot be repaired at runtime on a read-only root. Report, and let the
# image win; STRICT_DS_BOT_VERSION=1 makes it fatal for deployments that would
# rather not start than serve a version nobody pinned.
if [ -n "$image_ds_bot" ] && [ -n "$resolved_ds_bot" ] && [ "$resolved_ds_bot" != "$image_ds_bot" ]; then
    drift="ds-bot drift: the image carries $image_ds_bot but dsh would load $resolved_ds_bot from $resolved_dir"
    if [ "${STRICT_DS_BOT_VERSION:-0}" = "1" ]; then die "$drift"; fi
    log "ERROR: $drift — fix DS_BOT_VERSION and rebuild the image; a runtime reinstall cannot help here."
fi
if [ -z "$resolved_ds_bot" ]; then
    log "WARNING: ds-bot is not resolvable from the dsh installation; the image is broken."
fi

# Scratch space: /tmp must be a tmpfs under a read-only root; fall back to the
# volume when it is not mounted.
TMP="${TMPDIR:-/tmp}"
[ -w "$TMP" ] || TMP="$DSH_HOME/.cache"

# --- 5. preflight: the login gate must exist in the composed tree ------------
if [ "$SKIP_GATE_CHECK" != "1" ]; then
    log "preflight: composing the plugin tree"
    DUMP="$TMP/dsh-dump.yml"
    if ! dsh "$@" --dump-config >"$DUMP" 2>"$TMP/dsh-dump.err"; then
        sed -n '1,40p' "$TMP/dsh-dump.err" >&2
        die "dsh --dump-config failed (see above)"
    fi
    if grep -q 'skipped' "$DUMP"; then
        log "WARNING: the loader reported skipped bundles:"
        grep -n 'skipped' "$DUMP" | head -10
    fi
    if [ "$AUTH_MODE" = "1" ] && ! grep -q 'dsh-auth-gate' "$DUMP"; then
        grep -n 'shutup\|skipped\|error' "$DUMP" | head -20 || true
        die "the login gate is not in the composed config; with shutup installed that means an open door. Refusing to start."
    fi
    if [ "$SHUTUP_MODE" = "1" ] && ! grep -q 'shutup' "$DUMP"; then
        log "WARNING: shutup is not in the composed config (the token gate may still be on)"
    fi
    log "preflight ok (auth_gate=$AUTH_MODE shutup=$SHUTUP_MODE)"
fi

# --- 6. start ----------------------------------------------------------------
# Keep these comments above the command line: a comment inside a line
# continuation swallows every argument that follows it.
set -- "$@" --port "$DSH_PORT" --host "$DSH_BIND_HOST"
if [ -n "$DSH_PUBLIC_URL" ]; then
    # --public-url only exists from dsh 0.2.1 on; skip it when the CLI has no
    # such option instead of failing the start.
    if dsh web --help 2>&1 | grep -q -- '--public-url'; then
        set -- "$@" --public-url "$DSH_PUBLIC_URL"
    else
        log "note: this dsh has no --public-url (it is a 0.2.1 feature); ignoring DSH_PUBLIC_URL"
    fi
fi
[ -n "$DSH_TRUSTED_HOST" ] && set -- "$@" --trusted-host "$DSH_TRUSTED_HOST"

log "starting: dsh $*"
dsh "$@" &
DSH_PID=$!
trap 'kill -TERM "$DSH_PID" 2>/dev/null || true' TERM INT

if [ "$SKIP_GATE_CHECK" != "1" ]; then
    for _ in $(seq 1 60); do
        kill -0 "$DSH_PID" 2>/dev/null || die "dsh exited during startup"
        [ "$(probe "http://127.0.0.1:$DSH_PORT/")" != "000" ] && break
        sleep 0.5
    done
    set +e
    ANON_CODE="$(probe "http://127.0.0.1:$DSH_PORT/")"
    cp "$TMP/probe.body" "$TMP/probe.anon" 2>/dev/null
    AUTH_CODE="$(probe -H "Authorization: Bearer ${DSH_AUTH_TOKEN:-}" "http://127.0.0.1:$DSH_PORT/")"
    cp "$TMP/probe.body" "$TMP/probe.auth" 2>/dev/null
    set -e

    # The signal is the dsh app shell marker: an unauthenticated request must
    # get a login page, a redirect or a 401 instead.
    GATE_SUSPECT=0
    grep -q '__DSH_BOOT__' "$TMP/probe.anon" 2>/dev/null && GATE_SUSPECT=1
    if [ "$GATE_SUSPECT" = "0" ] && [ "$ANON_CODE" = "200" ] && [ "$AUTH_CODE" = "200" ]; then
        cmp -s "$TMP/probe.body" "$TMP/probe.anon" && GATE_SUSPECT=1
    fi
    log "probe: anonymous=$ANON_CODE with-token=$AUTH_CODE suspect_open_door=$GATE_SUSPECT"

    if [ "$AUTH_MODE" = "1" ]; then
        [ "$AUTH_CODE" = "200" ] || log "WARNING: the token got HTTP $AUTH_CODE on / (expected 200) — compare with $DSH_HOME/auth/token"
        if [ "$GATE_SUSPECT" = "1" ]; then
            case "$DSH_BIND_HOST" in
                127.*|::1|localhost) log "WARNING: the gate looks inactive, but we only bind loopback; continuing" ;;
                *) kill -TERM "$DSH_PID" 2>/dev/null || true
                   wait "$DSH_PID" 2>/dev/null || true
                   die "the app shell is served without credentials on $DSH_BIND_HOST:$DSH_PORT; refusing to expose it" ;;
            esac
        fi
    fi
fi

wait "$DSH_PID"
