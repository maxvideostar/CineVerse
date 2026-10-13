#!/usr/bin/env bash
# =====================================================================================
#  CineVerse by NetStreaming – media server personal stil Netflix pentru Ubuntu (22.04 / 24.04)
#  Filme + seriale · metadate TMDB · subtitrări RO automate (OpenSubtitles)
#  Transcodare HW (VAAPI / QuickSync / NVENC) + tone-mapping HDR→SDR · streaming extern max 4 Mbps
#  Utilizatori cu permisiuni · protecție brute-force · sesiuni de max 4 ore · fișă episod · descărcare · Google Cast
#
#  Instalare / actualizare:   sudo bash cineverse-install.sh
#  Dezinstalare:              sudo bash cineverse-install.sh --uninstall
#  Resetare administrator:    sudo bash cineverse-install.sh --reset-admin
#
#  Variabile opționale (instalare fără întrebări):
#    CINEVERSE_PORT=8200 CINEVERSE_MEDIA="/media/filme;/media/seriale" CINEVERSE_ADMIN=admin
#    CINEVERSE_PASS=parola TMDB_KEY=... OS_KEY=... OS_USER=... OS_PASS=...
# =====================================================================================
set -euo pipefail

APP=/opt/cineverse
DATA=/var/lib/cineverse
SVC=cineverse
USR=cineverse
G='\e[1;32m'; R='\e[1;31m'; Y='\e[1;33m'; B='\e[1;36m'; N='\e[0m'
say(){ echo -e "${B}==>${N} $*"; }
ok(){ echo -e "${G}✔${N} $*"; }
warn(){ echo -e "${Y}!${N} $*"; }
die(){ echo -e "${R}✘ $*${N}"; exit 1; }

[ "$(id -u)" = 0 ] || die "Rulează cu sudo:  sudo bash $0"

if [ "${1:-}" = "--uninstall" ]; then
  systemctl disable --now $SVC 2>/dev/null || true
  rm -f /etc/systemd/system/$SVC.service; systemctl daemon-reload
  rm -rf "$APP"
  a=n; ( : </dev/tty ) 2>/dev/null && read -rp "Șterg și baza de date / cache-ul din $DATA? [y/N] " a </dev/tty
  [[ "$a" =~ ^[yY] ]] && rm -rf "$DATA" && userdel $USR 2>/dev/null || true
  ok "CineVerse a fost dezinstalat."; exit 0
fi

TTY=""; ( : </dev/tty ) 2>/dev/null && TTY=/dev/tty

if [ "${1:-}" = "--reset-admin" ]; then
  [ -f "$DATA/cineverse.db" ] || die "CineVerse nu este instalat."
  [ -n "$TTY" ] || die "Rulează comanda într-un terminal."
  read -rp "Nume cont administrator: " RA_USER <"$TTY"
  read -rsp "Parolă nouă: " RA_PASS <"$TTY"; echo
  [ -n "$RA_USER" ] && [ ${#RA_PASS} -ge 4 ] || die "Nume și parolă (min. 4 caractere) obligatorii."
  runuser -u $USR -- env CINEVERSE_DATA="$DATA" "$APP/venv/bin/python" "$APP/server.py" setup --admin-user "$RA_USER" --admin-pass "$RA_PASS" >/dev/null
  systemctl restart $SVC
  ok "Contul '$RA_USER' este acum singurul administrator (parola a fost schimbată, sesiunile vechi închise)."; exit 0
fi
ask(){ # ask VAR "Întrebare" "implicit" [secret]
  local var=$1 q=$2 def=${3:-} val
  if [ -n "${!var:-}" ]; then return; fi
  if [ -n "$TTY" ]; then
    if [ "${4:-}" = secret ]; then read -rsp "$q: " val <"$TTY"; echo; else read -rp "$q${def:+ [$def]}: " val <"$TTY"; fi
    printf -v "$var" '%s' "${val:-$def}"
  else printf -v "$var" '%s' "$def"; fi
}

UPDATE=0; [ -f "$DATA/cineverse.db" ] && UPDATE=1

echo -e "${R}"
echo " ██████╗██╗███╗   ██╗███████╗██╗   ██╗███████╗██████╗ ███████╗███████╗"
echo "██╔════╝██║████╗  ██║██╔════╝██║   ██║██╔════╝██╔══██╗██╔════╝██╔════╝"
echo "██║     ██║██╔██╗ ██║█████╗  ██║   ██║█████╗  ██████╔╝███████╗█████╗  "
echo "██║     ██║██║╚██╗██║██╔══╝  ╚██╗ ██╔╝██╔══╝  ██╔══██╗╚════██║██╔══╝  "
echo "╚██████╗██║██║ ╚████║███████╗ ╚████╔╝ ███████╗██║  ██║███████║███████╗"
echo " ╚═════╝╚═╝╚═╝  ╚═══╝╚══════╝  ╚═══╝  ╚══════╝╚═╝  ╚═╝╚══════╝╚══════╝"
echo -e "${N}                                              ${B}by NetStreaming${N}\n"

# ---- migrare automata din vechea instalare "Cinemo"
OLD_DATA=/var/lib/cinemo
if [ $UPDATE = 0 ] && [ -f "$OLD_DATA/cinemo.db" ]; then
  say "Am găsit instalarea Cinemo – o mut în CineVerse (setări, bibliotecă, utilizatori, progres, subtitrări)…"
  OLD_PORT=$(sed -n 's/^Environment=CINEMO_PORT=//p' /etc/systemd/system/cinemo.service 2>/dev/null || true)
  systemctl disable --now cinemo >/dev/null 2>&1 || true
  mkdir -p "$DATA"
  cp -a "$OLD_DATA/." "$DATA/"
  for s in "" -wal -shm; do [ -f "$DATA/cinemo.db$s" ] && mv -f "$DATA/cinemo.db$s" "$DATA/cineverse.db$s"; done
  rm -rf "$DATA/transcode"; mkdir -p "$DATA/transcode"
  python3 - "$DATA/cineverse.db" <<'PYMIG'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("UPDATE subtitles SET path=replace(path,'/var/lib/cinemo/','/var/lib/cineverse/') WHERE path LIKE '/var/lib/cinemo/%'")
c.execute("UPDATE settings SET v='CineVerse' WHERE k='server_name' AND v='Cinemo'")
c.commit()
PYMIG
  CINEVERSE_MEDIA=$(python3 -c "import sqlite3,re;c=sqlite3.connect('$DATA/cineverse.db');r=c.execute(\"select v from settings where k='media_dirs'\").fetchone();print(';'.join(d.strip() for d in re.split(r'[\\n;]+',(r[0] if r else '')) if d.strip()))")
  rm -f /etc/systemd/system/cinemo.service; systemctl daemon-reload
  rm -rf /opt/cinemo
  CINEVERSE_PORT=${OLD_PORT:-8200}
  UPDATE=1; MIGRATED=1
  ok "Datele au fost copiate. Vechiul folder $OLD_DATA a rămas ca backup (îl poți șterge după ce verifici)."
fi

if [ $UPDATE = 1 ] && [ -z "${MIGRATED:-}" ]; then
  say "Instalare existentă găsită – actualizez aplicația (setările și biblioteca rămân)."
  CINEVERSE_PORT=$(sed -n 's/^Environment=CINEVERSE_PORT=//p' /etc/systemd/system/$SVC.service 2>/dev/null || true)
  CINEVERSE_PORT=${CINEVERSE_PORT:-8200}
elif [ -n "${MIGRATED:-}" ]; then
  :
else
  ask CINEVERSE_PORT  "Port web" "8200"
  ask CINEVERSE_MEDIA "Foldere cu filme/seriale (separate prin ;)" "/media"
  ask CINEVERSE_ADMIN "Utilizator administrator" "admin"
  while [ -z "${CINEVERSE_PASS:-}" ]; do
    ask CINEVERSE_PASS "Parolă administrator" "" secret
    [ -n "$TTY" ] || { CINEVERSE_PASS=$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 12); GEN_PASS=1; }
  done
  echo -e "\n${Y}Chei API gratuite (le poți pune și mai târziu din Administrare → Setări):${N}"
  echo "  TMDB (postere, descrieri, actori):  https://www.themoviedb.org/settings/api"
  echo "  OpenSubtitles (subtitrări RO):      https://www.opensubtitles.com/en/consumers"
  ask TMDB_KEY "Cheie TMDB (Enter = sari)" ""
  ask OS_KEY   "OpenSubtitles API key (Enter = sari)" ""
  if [ -n "${OS_KEY:-}" ]; then
    ask OS_USER "OpenSubtitles utilizator (opțional, mărește limita zilnică)" ""
    [ -n "${OS_USER:-}" ] && ask OS_PASS "OpenSubtitles parolă" "" secret
  fi
fi

# ------------------------------------------------------------------ pachete
say "Instalez pachetele de sistem…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip ffmpeg curl ca-certificates acl pciutils >/dev/null
GPU=$(lspci 2>/dev/null | grep -Ei 'vga|3d|display' || true)
if echo "$GPU" | grep -qi intel; then
  say "GPU Intel detectat – instalez driverele VAAPI/QuickSync"
  grep -q multiverse /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null || { add-apt-repository -y multiverse >/dev/null 2>&1 && apt-get update -qq || true; }
  apt-get install -y -qq intel-media-va-driver-non-free vainfo >/dev/null 2>&1 || apt-get install -y -qq intel-media-va-driver vainfo >/dev/null 2>&1 || true
  apt-get install -y -qq i965-va-driver >/dev/null 2>&1 || true
  apt-get install -y -qq libvpl2 libmfx-gen1.2 >/dev/null 2>&1 || apt-get install -y -qq libmfx1 >/dev/null 2>&1 || true
fi
if echo "$GPU" | grep -Eqi 'amd|ati|radeon'; then
  say "GPU AMD detectat – instalez mesa-va-drivers"
  apt-get install -y -qq mesa-va-drivers vainfo >/dev/null 2>&1 || true
fi
echo "$GPU" | grep -qi nvidia && warn "GPU NVIDIA detectat – pentru NVENC trebuie driverul proprietar (ex: sudo ubuntu-drivers install)."
ok "Pachete instalate"

# ------------------------------------------------------------------ utilizator sistem
id $USR >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -d "$DATA" $USR
for g in video render; do getent group $g >/dev/null && usermod -aG $g $USR; done
mkdir -p "$APP/static" "$DATA"

# ------------------------------------------------------------------ fișierele aplicației
say "Scriu aplicația în $APP…"
