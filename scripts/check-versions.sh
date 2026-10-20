#!/usr/bin/env bash
# Compare the pins in versions.env against the registries and against the
# Dockerfiles. Read-only: it reports, it never rewrites anything.
#
#   scripts/check-versions.sh              # all checks
#   scripts/check-versions.sh digest        # base image only
#   scripts/check-versions.sh packages      # npm pins only
#   scripts/check-versions.sh args          # versions.env vs Dockerfile ARGs
#
# Exit codes: 0 clean (warnings allowed), 1 drift found, 2 tooling/network.
#
# Why this exists: a pinned digest without a drift check is a frozen image, and
# a frozen image stops receiving base-image security updates silently. The check
# runs on a schedule and fails loudly instead of letting the pin rot.
#
# Deliberately queries the registries, never the git remote: the git endpoint of
# this hosting serves cached refs, so a lagging `ls-remote` is not evidence of
# anything about the registries.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${VERSIONS_FILE:-$ROOT/versions.env}"
MODE="${1:-all}"

FAILED=0
WARNED=0
fail() { printf '  [FAIL] %s\n' "$*"; FAILED=$((FAILED + 1)); }
warn() { printf '  [WARN] %s\n' "$*"; WARNED=$((WARNED + 1)); }
ok()   { printf '  [OK]   %s\n' "$*"; }
note() { printf '  [..]   %s\n' "$*"; }

[ -r "$ENV_FILE" ] || { printf 'cannot read %s\n' "$ENV_FILE" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { printf 'node is required to parse registry JSON\n' >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { printf 'curl is required\n' >&2; exit 2; }

# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

# Read a dotted path out of JSON on stdin. Empty output means "not present".
json() {
  node -e '
    let raw = "";
    process.stdin.on("data", (c) => (raw += c)).on("end", () => {
      let v;
      try { v = JSON.parse(raw); } catch { process.exit(3); }
      for (const k of process.argv[1].split(".")) {
        if (v === undefined || v === null) break;
        v = v[k];
      }
      if (v !== undefined && v !== null) process.stdout.write(String(v));
    });' "$1"
}

fetch() { curl -fsSL --max-time 25 "$1" 2>/dev/null; }

check_digest() {
  printf '\nBase image\n'
  # Split "registry/owner/name:tag" into the Hub API path and the tag. Taking
  # ${var##*/} would leave "name:tag", which is the bug this line exists to avoid.
  local ref="${NODE_BASE_IMAGE%%@*}" tag repo body json_digest json_amd64
  tag="${ref##*:}"
  repo="${ref%:*}"
  repo="${repo#docker.io/}"
  body="$(fetch "https://hub.docker.com/v2/repositories/${repo}/tags/${tag}")"
  json_digest="$(printf '%s' "$body" | json digest)"
  if [ -z "$json_digest" ]; then
    printf 'could not read the tag from the registry\n' >&2
    return 2
  fi
  if [ "$json_digest" = "${NODE_BASE_DIGEST:-}" ]; then
    ok "manifest list digest matches the pin"
  else
    fail "the tag now resolves to ${json_digest}, versions.env pins ${NODE_BASE_DIGEST:-<unset>}"
    note "re-pin deliberately, or record why the old one is kept; do not let it rot"
  fi
  json_amd64="$(printf '%s' "$body" | json 'images.0.digest')"
  local amd64_pinned="${NODE_AMD64_DIGEST:-}"
  if [ -n "$json_amd64" ] && [ -n "$amd64_pinned" ] && [ "$json_amd64" != "$amd64_pinned" ]; then
    warn "the amd64 image digest moved too (${json_amd64})"
  fi
}

check_npm() {
  printf '\nPackages\n'
  local pairs="dsh:@deepseek-ai/dsh:${DSH_VERSION:-} ds-bot:ds-bot:${DS_BOT_VERSION:-} auth-gate:dsh-auth-gate:${AUTH_GATE_VERSION:-}"
  local item name pkg pin meta latest code
  for item in $pairs; do
    name="${item%%:*}"; item="${item#*:}"
    pkg="${item%%:*}"; pin="${item##*:}"
    [ -n "$pin" ] || { note "$name: no pin recorded, skipped"; continue; }
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "https://registry.npmjs.org/${pkg}/${pin}" 2>/dev/null)"
    if [ "$code" = "200" ]; then
      ok "$name ${pin} exists"
    else
      fail "$name ${pin} cannot be resolved from the registry (HTTP ${code})"
      continue
    fi
    latest="$(fetch "https://registry.npmjs.org/${pkg}" | json 'dist-tags.latest')"
    if [ -n "$latest" ] && [ "$latest" != "$pin" ]; then
      warn "$name newer release available: ${latest} (pin stays ${pin}; update deliberately)"
    fi
  done
}

check_args() {
  printf '\nVersions file vs Dockerfiles\n'
  local d="$ROOT/Dockerfile" t="$ROOT/tools/Dockerfile" want have
  for pair in DSH_VERSION DS_BOT_VERSION AUTH_GATE_VERSION; do
    want="${!pair:-}"
    have="$(sed -n "s/^ARG ${pair}=//p" "$d" | head -1)"
    if [ -z "$have" ]; then
      fail "${pair} is not an ARG in Dockerfile"
    elif [ "$have" != "$want" ]; then
      fail "${pair}: Dockerfile says ${have}, versions.env says ${want}"
    else
      ok "${pair} ${have}"
    fi
  done
  for pair in JJ_VERSION YQ_VERSION; do
    want="${!pair:-}"
    have="$(sed -n "s/^ARG ${pair}=//p" "$t" | head -1)"
    if [ -z "$have" ]; then
      fail "${pair} is not an ARG in tools/Dockerfile"
    elif [ "$have" != "$want" ]; then
      fail "${pair}: tools/Dockerfile says ${have}, versions.env says ${want}"
    else
      ok "${pair} ${have}"
    fi
  done
  # The base image digest appears in two ARG defaults; both must carry it.
  local missing=""
  grep -q "NODE_BASE_DIGEST\|@${NODE_BASE_DIGEST#sha256:}" "$d" 2>/dev/null || true
  for f in "$d" "$t"; do
    if ! grep -q "@sha256:" "$f"; then missing="$missing $f"; fi
  done
  if [ -n "$missing" ]; then
    fail "no digest pinned in:$missing"
  else
    ok "both Dockerfiles pin the base image by digest"
  fi
}

case "$MODE" in
  all)      check_digest || exit 2; check_npm; check_args ;;
  digest)   check_digest || exit 2 ;;
  packages) check_npm ;;
  args)     check_args ;;
  *) printf 'usage: %s [all|digest|packages|args]\n' "$0" >&2; exit 2 ;;
esac

printf '\n%d failed, %d warning(s)\n' "$FAILED" "$WARNED"
[ "$FAILED" -eq 0 ]
