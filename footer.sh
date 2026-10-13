
# ------------------------------------------------------------------ hls.js (player)
if [ ! -s "$APP/static/hls.min.js" ] || [ $UPDATE = 1 ]; then
  curl -fsSL --retry 3 -o "$APP/static/hls.min.js.tmp" https://cdn.jsdelivr.net/npm/hls.js@1/dist/hls.min.js \
   || curl -fsSL --retry 3 -o "$APP/static/hls.min.js.tmp" https://unpkg.com/hls.js@1/dist/hls.min.js \
   || warn "Nu am putut descărca hls.js – playerul îl va încărca din CDN."
  [ -s "$APP/static/hls.min.js.tmp" ] && mv "$APP/static/hls.min.js.tmp" "$APP/static/hls.min.js" || rm -f "$APP/static/hls.min.js.tmp"
fi

# ------------------------------------------------------------------ Python venv
say "Creez mediul Python…"
[ -x "$APP/venv/bin/python" ] || python3 -m venv "$APP/venv"
"$APP/venv/bin/pip" install -q --upgrade pip >/dev/null
"$APP/venv/bin/pip" install -q --upgrade "fastapi>=0.115" "uvicorn[standard]>=0.30" "httpx>=0.27" "guessit>=3.8" "pychromecast>=14" >/dev/null
ok "Dependențe Python instalate"

chown -R root:root "$APP"; chmod -R a+rX "$APP"
chown -R $USR:$USR "$DATA"

# ------------------------------------------------------------------ permisiuni foldere media
if [ $UPDATE = 0 ] || [ -n "${MIGRATED:-}" ]; then
  IFS=';' read -ra DIRS <<< "$CINEVERSE_MEDIA"
  for d in "${DIRS[@]}"; do
    d=$(echo "$d" | xargs); [ -z "$d" ] && continue
    [ -d "$d" ] || { warn "Folderul $d nu există (îl poți corecta din Administrare → Setări)"; continue; }
    if ! runuser -u $USR -- test -r "$d" -a -x "$d" 2>/dev/null || ! runuser -u $USR -- ls "$d" >/dev/null 2>&1; then
      say "Dau acces de citire utilizatorului '$USR' la $d (ACL)…"
      p="$d"; while [ "$p" != "/" ]; do p=$(dirname "$p"); setfacl -m u:$USR:x "$p" 2>/dev/null || true; done
      setfacl -R -m u:$USR:rX "$d" 2>/dev/null || true
      setfacl -R -d -m u:$USR:rX "$d" 2>/dev/null || true
    fi
  done
fi
if [ -n "${MIGRATED:-}" ]; then
  id cinemo >/dev/null 2>&1 && userdel cinemo 2>/dev/null || true
fi
if [ $UPDATE = 0 ]; then
  say "Configurez serverul…"
  runuser -u $USR -- env CINEVERSE_DATA="$DATA" "$APP/venv/bin/python" "$APP/server.py" setup \
    --admin-user "$CINEVERSE_ADMIN" --admin-pass "$CINEVERSE_PASS" --media-dirs "$CINEVERSE_MEDIA" \
    --tmdb-key "${TMDB_KEY:-}" --os-key "${OS_KEY:-}" --os-user "${OS_USER:-}" --os-pass "${OS_PASS:-}" >/dev/null
fi

# ------------------------------------------------------------------ systemd
cat > /etc/systemd/system/$SVC.service <<UNIT
[Unit]
Description=CineVerse by NetStreaming – media server
After=network-online.target remote-fs.target
Wants=network-online.target

[Service]
User=$USR
Group=$USR
SupplementaryGroups=video render
Environment=CINEVERSE_DATA=$DATA
Environment=CINEVERSE_PORT=$CINEVERSE_PORT
Environment=PYTHONUNBUFFERED=1
ExecStart=$APP/venv/bin/python $APP/server.py run --port $CINEVERSE_PORT
Restart=always
RestartSec=3
Nice=-2
LimitNOFILE=65536
NoNewPrivileges=true
ProtectSystem=full
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
getent group render >/dev/null || sed -i 's/^SupplementaryGroups=.*/SupplementaryGroups=video/' /etc/systemd/system/$SVC.service
systemctl daemon-reload
systemctl enable $SVC >/dev/null 2>&1
systemctl restart $SVC

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$CINEVERSE_PORT"/tcp >/dev/null && ok "Port $CINEVERSE_PORT deschis în ufw"
  ufw allow 5353/udp comment "mDNS - Google Cast" >/dev/null && ok "mDNS (5353/udp) permis – pentru descoperirea Chromecast"
fi

say "Aștept pornirea…"
for i in $(seq 1 30); do curl -fs -o /dev/null "http://127.0.0.1:$CINEVERSE_PORT/" && break; sleep 1; done
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if curl -fs -o /dev/null "http://127.0.0.1:$CINEVERSE_PORT/"; then
  echo
  echo -e "${G}══════════════════════════════════════════════════════════════${N}"
  echo -e "  ${G}CineVerse by NetStreaming rulează!${N}   ➜  ${B}http://${IP:-localhost}:$CINEVERSE_PORT${N}"
  if [ $UPDATE = 0 ]; then
    echo -e "  Utilizator: ${B}$CINEVERSE_ADMIN${N}"
    [ -n "${GEN_PASS:-}" ] && echo -e "  Parolă generată: ${B}$CINEVERSE_PASS${N}"
  fi
  VA=$(runuser -u $USR -- vainfo 2>/dev/null | grep -c VAEntrypointEncSlice || true)
  [ "${VA:-0}" -gt 0 ] && echo -e "  Transcodare hardware: ${G}VAAPI disponibil${N}" || echo -e "  Transcodare hardware: vezi Administrare → Bibliotecă"
  echo -e "  Loguri:  ${B}journalctl -u $SVC -f${N}"
  echo -e "${G}══════════════════════════════════════════════════════════════${N}"
else
  die "Serviciul nu a pornit. Verifică:  journalctl -u $SVC -n 50 --no-pager"
fi
