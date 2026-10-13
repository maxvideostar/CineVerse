#!/bin/bash
# Asambleaza instalatorul all-in-one CineVerse
set -euo pipefail
cd "$(dirname "$0")"
OUT=/home/claude/outputs/cineverse-install.sh

# verificari de siguranta pentru heredoc-uri
for f in server.py index.html; do
  grep -qx 'CINEVERSE_PY_EOF\|CINEVERSE_HTML_EOF\|CINEVERSE_B64_EOF' "$f" && { echo "EROARE: marker heredoc gasit in $f"; exit 1; } || true
done

{
  cat header.sh
  echo "cat > \"\$APP/server.py\" <<'CINEVERSE_PY_EOF'"
  cat server.py
  echo "CINEVERSE_PY_EOF"
  echo
  echo "cat > \"\$APP/static/index.html\" <<'CINEVERSE_HTML_EOF'"
  cat index.html
  echo "CINEVERSE_HTML_EOF"
  for a in icon-180.png icon-192.png icon-512.png CineVerse.apk; do
    echo "base64 -d > \"\$APP/static/$a\" <<'CINEVERSE_B64_EOF'"
    base64 -w76 "static/$a"
    echo "CINEVERSE_B64_EOF"
  done
  cat footer.sh
} > "$OUT"

bash -n "$OUT" && echo "OK sintaxa bash"
ls -la "$OUT"
