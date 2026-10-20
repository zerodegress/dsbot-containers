#!/bin/sh
# =============================================================================
# agent-env.sh — move the agent's HOME, XDG roots and caches into the workspace.
#
# The agent shell runs under a Landlock profile whose writable roots are exactly:
#
#   * the session workspace
#   * /tmp
#   * the per-process tmpdir
#
# (see @deepseek-ai/dsh-sandbox `writableRoots()` — the set is hard-coded, there
# is no policy knob to add a root). The image's own HOME=/data and every cache
# variable under /data therefore point outside that grant: git, npm, pnpm, uv,
# pip and cargo fail with EACCES, and `test -w` / `os.access()` still report
# "writable" because access(2) never consults Landlock.
#
# It is sourced automatically by every non-interactive bash (`BASH_ENV` is set in
# the image) and is safe to `. /opt/dsbot/agent-env.sh` by hand from another
# shell. Two blind spots are documented in docs/configuration.md: `sh -c` does
# not read BASH_ENV, and a child a program spawns with a hand-built environment
# never sees it.
#
# Contract — every bash command in the container pays for this, so do not break it:
#   1. silent: it prints nothing, ever.
#   2. never fatal: a failed probe leaves the environment exactly as it was.
#   3. armed only inside an agent session (DSH_SESSION_ID set, or
#      DSBOT_AGENT_ENV_ALWAYS=1), so image builds and the entrypoint are untouched.
#   4. off switch: DSBOT_NO_AGENT_ENV=1.
#   5. idempotent: re-sourcing recomputes the same values and touches nothing else.
#   6. never adopts a tmpfs or pseudo-fs: /tmp, /dev/shm and /run are small or
#      noexec, and a cache tree there fills up and breaks every later command.
# =============================================================================

if [ "${DSBOT_NO_AGENT_ENV:-0}" != "1" ] && \
   { [ -n "${DSH_SESSION_ID:-}" ] || [ "${DSBOT_AGENT_ENV_ALWAYS:-0}" = "1" ]; }; then

    # --- pick the root -------------------------------------------------------
    # Candidates, most specific first: the root an outer shell already adopted
    # (sticky, so a child shell that `cd`s elsewhere keeps using it), then the
    # nearest existing `.home` marker walking up from $PWD (so a command run in
    # `docs/` does not grow a second cache tree), then $PWD/.home itself.
    #
    # A candidate is only accepted if its directories can actually be created.
    # That is not paranoia: the walk can leave the session workspace and find
    # another Bot's `.home`, which looks like a marker but is not writable — and
    # silently sharing a cache tree across Bots would be worse than not adopting.
    DSH_AGENT_CANDS="${DSBOT_AGENT_HOME:-}"

    case "$PWD" in
        /tmp|/tmp/*|/dev/shm|/dev/shm/*|/run|/run/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*)
            DSH_AGENT_CANDS=""   # never adopt a tmpfs or a pseudo-filesystem
            ;;
        *)
            DSH_AGENT_SCAN="$PWD"
            while : ; do
                if [ -d "$DSH_AGENT_SCAN/.home" ]; then
                    DSH_AGENT_CANDS="${DSH_AGENT_CANDS}${DSH_AGENT_CANDS:+
}$DSH_AGENT_SCAN/.home"
                fi
                [ "$DSH_AGENT_SCAN" = "/" ] && break
                DSH_AGENT_SCAN="$(dirname "$DSH_AGENT_SCAN")"
            done
            DSH_AGENT_CANDS="${DSH_AGENT_CANDS}${DSH_AGENT_CANDS:+
}$PWD/.home"
            unset DSH_AGENT_SCAN
            ;;
    esac

    # --- adopt the first candidate that can hold the overlay -----------------
    # Every directory is created up front: Chromium creates its own, LibreOffice
    # does not, and with XDG_CONFIG_HOME pointing at a missing directory soffice
    # exits 77 without producing anything. A real `mkdir`, not `test -w` — under
    # Landlock the two disagree.
    DSH_AGENT_ROOT=""
    DSH_AGENT_OLDIFS="$IFS"
    IFS='
'
    for _cand in $DSH_AGENT_CANDS; do
        if mkdir -p "$_cand/.config/git" "$_cand/.config/jj" \
                    "$_cand/.cache/pip" "$_cand/.cache/uv" \
                    "$_cand/.npmcache" "$_cand/.pnpstore" \
                    "$_cand/.npm-global/bin" "$_cand/.local/bin" \
                    "$_cand/.local/share" "$_cand/.local/state" \
                    "$_cand/.cargo" "$_cand/.rustup" \
                    "$_cand/.go/mod" "$_cand/.go/build" "$_cand/.go/bin" 2>/dev/null; then
            DSH_AGENT_ROOT="$_cand"
            break
        fi
    done
    IFS="$DSH_AGENT_OLDIFS"
    unset DSH_AGENT_CANDS DSH_AGENT_OLDIFS _cand

    if [ -n "$DSH_AGENT_ROOT" ]; then
        # HOME moves with the rest: git and jj both key off it, and leaving it at
        # /data means `~` is a read-only directory inside the agent shell.
        HOME="$DSH_AGENT_ROOT"
        XDG_CONFIG_HOME="$DSH_AGENT_ROOT/.config"
        XDG_CACHE_HOME="$DSH_AGENT_ROOT/.cache"
        XDG_DATA_HOME="$DSH_AGENT_ROOT/.local/share"
        XDG_STATE_HOME="$DSH_AGENT_ROOT/.local/state"

        PIP_CACHE_DIR="$DSH_AGENT_ROOT/.cache/pip"
        UV_CACHE_DIR="$DSH_AGENT_ROOT/.cache/uv"

        # pnpm reads npm_config_store_dir; PNPM_STORE_DIR and pnpm_config_store_dir
        # are ignored, which is why the image sets this exact name.
        npm_config_cache="$DSH_AGENT_ROOT/.npmcache"
        npm_config_store_dir="$DSH_AGENT_ROOT/.pnpstore"
        npm_config_prefix="$DSH_AGENT_ROOT/.npm-global"

        CARGO_HOME="$DSH_AGENT_ROOT/.cargo"
        RUSTUP_HOME="$DSH_AGENT_ROOT/.rustup"
        # GOPATH moves with the module and build caches. Leaving it at the image
        # default means `go install` writes its binaries outside the grant while
        # the caches are inside it — the two halves disagree and only the binary
        # write fails.
        GOPATH="$DSH_AGENT_ROOT/.go"
        GOMODCACHE="$DSH_AGENT_ROOT/.go/mod"
        GOCACHE="$DSH_AGENT_ROOT/.go/build"

        # Neither tool falls back to XDG_CONFIG_HOME for its own config file, so
        # both stay explicit even though HOME now points inside the workspace: a
        # tool that resets HOME would otherwise write to /data again.
        JJ_CONFIG="$DSH_AGENT_ROOT/.config/jj/config.toml"
        GIT_CONFIG_GLOBAL="$DSH_AGENT_ROOT/.config/git/config"

        # Sticky: child shells reuse this root instead of re-deriving one from
        # wherever they happen to be standing.
        DSBOT_AGENT_HOME="$DSH_AGENT_ROOT"

        export HOME XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_STATE_HOME \
               PIP_CACHE_DIR UV_CACHE_DIR \
               npm_config_cache npm_config_store_dir npm_config_prefix \
               CARGO_HOME RUSTUP_HOME GOPATH GOMODCACHE GOCACHE \
               JJ_CONFIG GIT_CONFIG_GLOBAL DSBOT_AGENT_HOME

        # PATH: prepend once, never twice (nested shells re-source this).
        case ":$PATH:" in
            *":$DSH_AGENT_ROOT/.npm-global/bin:"*) ;;
            *) PATH="$DSH_AGENT_ROOT/.npm-global/bin:$DSH_AGENT_ROOT/.local/bin:$PATH"; export PATH ;;
        esac
    fi

    unset DSH_AGENT_ROOT
fi
