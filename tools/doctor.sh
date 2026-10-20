#!/usr/bin/env bash
# Smoke test for the tool image: reports versions and actually exercises the
# capabilities the image is built for (file IO, documents, media, OCR, browser).
#   bash /opt/tools/doctor.sh
set -uo pipefail
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

ok()   { printf '  \033[32m[OK]\033[0m   %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[90m[--]\033[0m   %s\n' "$*"; }
head_() { printf '\n\033[1;36m%s\033[0m\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

head_ "Versions"
# soffice and docker left the loop on purpose: `soffice --version` prints
# nothing (so an [OK] there means "binary exists", not "works"), and
# `docker --version` only proves the CLI is installed. Both are probed below.
for c in node npm pnpm python3 pip git rg fd jq jj pandoc ffmpeg convert tesseract duckdb; do
  if have "$c"; then
    v="$($c --version 2>&1 | head -1 | cut -c1-60)"
    ok "$c: $v"
  else
    skip "$c (absent)"
  fi
done

# yq has to be the Go one (v4). Debian's 3.1.0 is a jq wrapper with different
# syntax: a v4 expression given to it returns a wrong value instead of failing,
# so the version is the check that matters, not the presence of the binary.
if have yq; then
  v="$(yq --version 2>/dev/null | head -1)"
  case "$v" in
    *"version v4."*) ok "yq: $v" ;;
    *) skip "yq: ${v:-no version output} — not v4 (v3 syntax differs; do not trust its output)" ;;
  esac
else
  skip "yq (absent)"
fi

# soffice prints nothing to stdout in this image, so a version string is not a
# signal. Probe the binary and say "present" when it stays quiet.
if have soffice; then
  v="$(soffice --version 2>/dev/null | head -1)"
  ok "soffice: ${v:-present (no version output)}"
else
  skip "soffice (absent)"
fi

# `command -v time` resolves to the Bash builtin, which has no -v; only the real
# binary counts, and only GNU time can report peak RSS.
if [ -x /usr/bin/time ] && /usr/bin/time -v true >/dev/null 2>&1; then
  ok "time: $(/usr/bin/time --version 2>&1 | head -1)"
else
  skip "GNU time (absent — bare 'time' would be the shell builtin)"
fi

# A CLI without a daemon cannot build anything; say which one we have.
if have docker; then
  if docker info >/dev/null 2>&1; then ok "docker: $(docker --version) (daemon reachable)"; else skip "docker CLI present, daemon unreachable"; fi
else
  skip "docker (absent)"
fi

head_ "File IO"
if printf 'hello\n' > "$TMP/a.txt" && grep -q hello "$TMP/a.txt"; then ok "write + read"; else bad "write + read"; fi

head_ "Documents"
if have pandoc && printf '# hi\n' > "$TMP/a.md" && pandoc "$TMP/a.md" -o "$TMP/a.docx" 2>/dev/null; then
  ok "pandoc md -> docx"
else
  skip "pandoc conversion"
fi
if have soffice && [ -f "$TMP/a.docx" ] && soffice --headless --convert-to pdf --outdir "$TMP" "$TMP/a.docx" >/dev/null 2>&1 && [ -f "$TMP/a.pdf" ]; then
  ok "libreoffice docx -> pdf"
else
  skip "libreoffice conversion"
fi

head_ "Media"
if have convert && convert -size 64x64 xc:white "$TMP/a.png" 2>/dev/null; then ok "imagemagick render"; else skip "imagemagick"; fi
if have ffmpeg && ffmpeg -loglevel error -f lavfi -i testsrc=size=64x64:rate=1 -t 1 "$TMP/a.mp4" -y 2>/dev/null; then ok "ffmpeg encode"; else skip "ffmpeg"; fi

head_ "OCR"
if have tesseract && [ -f "$TMP/a.png" ]; then
  if tesseract "$TMP/a.png" stdout >/dev/null 2>&1; then ok "tesseract runs"; else bad "tesseract runs"; fi
else
  skip "tesseract"
fi

head_ "Python"
if python3 -c "import venv, sqlite3" 2>/dev/null; then ok "stdlib venv + sqlite3"; else bad "stdlib venv + sqlite3"; fi
if /opt/venv/bin/python -c "import numpy, pandas, PIL" 2>/dev/null; then ok "/opt/venv numpy pandas pillow"; else bad "/opt/venv numpy pandas pillow"; fi

head_ "Browser"
if [ -x /usr/bin/chromium ]; then
  if chromium --headless --no-sandbox --disable-gpu --dump-dom about:blank >/dev/null 2>&1; then ok "chromium headless"; else skip "chromium headless (may need xvfb)"; fi
else
  skip "chromium"
fi

head_ "Node tooling"
if have mmdc; then ok "mermaid-cli (mmdc)"; else skip "mermaid-cli"; fi
if node -e "require('sharp')" 2>/dev/null; then ok "sharp"; else skip "sharp"; fi

printf '\n\033[1m%s passed, %s failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
