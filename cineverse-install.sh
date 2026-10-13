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
cat > "$APP/server.py" <<'CINEVERSE_PY_EOF'
#!/usr/bin/env python3
"""CineVerse by NetStreaming - media server personal (filme + seriale), stil Netflix.
Metadate TMDB, subtitrari RO automate (OpenSubtitles), transcodare HW (VAAPI/NVENC) prin FFmpeg.
"""
import os, re, sys, json, time, math, ipaddress, asyncio, collections, socket, sqlite3, hashlib, secrets, threading, subprocess, shutil, signal, struct, queue, logging, random, argparse, datetime, tempfile, smtplib, hmac, base64
from pathlib import Path

for _v in ("SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE"):
    if os.environ.get(_v) and not os.access(os.environ[_v], os.R_OK):
        os.environ.pop(_v)
import httpx
from fastapi import FastAPI, Request, Response, HTTPException
from fastapi.responses import FileResponse, JSONResponse, HTMLResponse, PlainTextResponse, StreamingResponse
from starlette.background import BackgroundTask
from urllib.parse import quote

VERSION = "3.4.1"
APPDIR = Path(__file__).resolve().parent
STATIC = APPDIR / "static"
IS_WIN = os.name == "nt"
_def_data = (Path(os.environ.get("ProgramData", r"C:\ProgramData")) / "CineVerse") if IS_WIN else Path("/var/lib/cineverse")
DATA = Path(os.environ.get("CINEVERSE_DATA", str(_def_data)))
# ffmpeg/ffprobe livrate langa aplicatie (Windows) – le punem in PATH ca sa ramana apelabile dupa nume
_ffdir = os.environ.get("CINEVERSE_FFMPEG_DIR", "")
if _ffdir and Path(_ffdir).is_dir():
    os.environ["PATH"] = _ffdir + os.pathsep + os.environ.get("PATH", "")
DB_PATH = DATA / "cineverse.db"
IMG = DATA / "images"
SUBS = DATA / "subs"
TRANS = Path(os.environ.get("CINEVERSE_TRANSCODE", str(DATA / "transcode")))
for d in (DATA, IMG, SUBS, TRANS):
    d.mkdir(parents=True, exist_ok=True)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("cineverse")
logging.getLogger("httpx").setLevel(logging.WARNING)

VIDEO_EXT = {".mkv", ".mp4", ".m4v", ".avi", ".mov", ".wmv", ".ts", ".m2ts", ".webm", ".mpg", ".mpeg", ".flv", ".ogv", ".divx", ".3gp"}
SUB_EXT = {".srt", ".vtt", ".ass", ".ssa", ".sub"}
TEXT_SUB_CODECS = {"subrip", "ass", "ssa", "mov_text", "webvtt", "text"}
RO_CODES = {"ro", "rum", "ron", "romanian", "romana", "română", "rom"}
TMDB_IMG_SIZES = {"w92", "w154", "w185", "w300", "w342", "w500", "w780", "w1280", "h632", "original"}

DEFAULT_SETTINGS = {
    "tmdb_key": "", "os_key": "", "os_user": "", "os_pass": "", "subsro_key": "",
    "media_dirs": "", "hwaccel": "auto", "vaapi_device": "/dev/dri/renderD128",
    "auto_subs": "1", "scan_interval": "5", "max_height": "1080", "bitrate": "8M",
    "server_name": "CineVerse",
    # retea
    "lan_networks": "192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, 100.64.0.0/10, 127.0.0.0/8, ::1/128, fc00::/7, fe80::/10",
    "lan_auto": "1",       # adauga automat retelele serverului (inclusiv prefixul IPv6 public de acasa)
    "cast_hosts": "",      # IP-uri Chromecast (optional, daca mDNS nu merge)
    "epg_urls": "",        # surse XMLTV (una pe linie)
    "live_refresh": "12",  # ore intre reimprospatarile listelor M3U
    "remote_enabled": "1", "remote_max": "4M",
    "download_mode": "all",   # all = LAN liber + extern limitat la bitrate; lan = doar LAN; off = dezactivat
    # securitate
    "backup_auto": "off", "backup_keep": "7", "backup_dir": "", "backup_images": "0", "backup_scope": "config",
    # conturi noi create de vizitatori
    "signup_mode": "off", "signup_invite": "", "signup_verify": "1", "signup_domains": "",
    "signup_remote": "1", "signup_live": "1", "signup_download": "0", "signup_max_q": "", "signup_libs": "",
    # e-mail
    "smtp_host": "", "smtp_port": "587", "smtp_user": "", "smtp_pass": "", "smtp_from": "", "smtp_tls": "starttls",
    "public_url": "",
    # securitate
    "pw_min": "8", "hsts": "0", "monitor_remote": "1",
    "session_hours": "0", "bf_attempts": "5", "bf_window": "10", "bf_block": "15", "bf_lan_exempt": "1",
    # HDR
    "tonemap": "1", "tonemap_alg": "hable",
}

# trepte de calitate (total video+audio). Streaming extern: maxim 4 Mbps.
REMOTE_CAP = 4_000_000
QUALITIES = [  # cheie, bps total, inaltime max, audio kbps, eticheta
    ("4M", 4_000_000, 1080, 160, "4 Mbps · 1080p"),
    ("3M", 3_000_000, 720, 128, "3 Mbps · 720p"),
    ("2M", 2_000_000, 720, 128, "2 Mbps · 720p"),
    ("1.5M", 1_500_000, 720, 128, "1.5 Mbps · 720p"),
    ("1M", 1_000_000, 540, 96, "1 Mbps · 540p"),
    ("750k", 750_000, 480, 96, "750 kbps · 480p"),
    ("500k", 500_000, 360, 64, "500 kbps · 360p"),
]
QMAP = {q[0]: q for q in QUALITIES}

# ---------------------------------------------------------------- DB
_local = threading.local()
_wlock = threading.RLock()


def db():
    c = getattr(_local, "c", None)
    if c is None:
        c = sqlite3.connect(DB_PATH, timeout=30, check_same_thread=False)
        c.row_factory = sqlite3.Row
        c.execute("PRAGMA journal_mode=WAL")
        c.execute("PRAGMA foreign_keys=ON")
        _local.c = c
    return c


def q(sql, args=(), one=False):
    cur = db().execute(sql, args)
    rows = cur.fetchall()
    return (rows[0] if rows else None) if one else rows


def x(sql, args=()):
    with _wlock:
        c = db()
        cur = c.execute(sql, args)
        c.commit()
        return cur.lastrowid


SCHEMA = """
CREATE TABLE IF NOT EXISTS settings(k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY, username TEXT UNIQUE COLLATE NOCASE, pw TEXT, admin INTEGER DEFAULT 0, created REAL);
CREATE TABLE IF NOT EXISTS sessions(token TEXT PRIMARY KEY, user_id INTEGER REFERENCES users(id) ON DELETE CASCADE, created REAL);
CREATE TABLE IF NOT EXISTS items(id INTEGER PRIMARY KEY, kind TEXT, key TEXT UNIQUE, title TEXT, orig_title TEXT, year INTEGER,
  tmdb_id INTEGER, overview TEXT, tagline TEXT, poster TEXT, backdrop TEXT, logo TEXT, genres TEXT DEFAULT '[]', rating REAL,
  runtime INTEGER, cert TEXT, cast_json TEXT DEFAULT '[]', director TEXT, trailer TEXT, added REAL, matched INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS media(id INTEGER PRIMARY KEY, item_id INTEGER REFERENCES items(id) ON DELETE CASCADE, path TEXT UNIQUE,
  season INTEGER, episode INTEGER, ep_title TEXT, ep_overview TEXT, still TEXT, air_date TEXT, duration REAL, size INTEGER,
  probe TEXT, added REAL, subs_checked REAL DEFAULT 0);
CREATE TABLE IF NOT EXISTS subtitles(id INTEGER PRIMARY KEY, media_id INTEGER REFERENCES media(id) ON DELETE CASCADE, lang TEXT,
  label TEXT, source TEXT, path TEXT, stream_index INTEGER, UNIQUE(media_id, source, path, stream_index));
CREATE TABLE IF NOT EXISTS progress(user_id INTEGER REFERENCES users(id) ON DELETE CASCADE, media_id INTEGER REFERENCES media(id) ON DELETE CASCADE,
  position REAL, duration REAL, watched INTEGER DEFAULT 0, updated REAL, PRIMARY KEY(user_id, media_id));
CREATE TABLE IF NOT EXISTS live_channels(id INTEGER PRIMARY KEY, name TEXT, url TEXT, logo TEXT, grp TEXT DEFAULT '', num INTEGER,
  tvg_id TEXT DEFAULT '', enabled INTEGER DEFAULT 1, source TEXT DEFAULT 'manual', mode TEXT DEFAULT 'auto', ua TEXT DEFAULT '',
  locked INTEGER DEFAULT 0, probe TEXT, added REAL);
CREATE TABLE IF NOT EXISTS live_playlists(id INTEGER PRIMARY KEY, url TEXT, name TEXT, last REAL, count INTEGER DEFAULT 0, err TEXT DEFAULT '');
CREATE TABLE IF NOT EXISTS live_epg(tvg_id TEXT, start REAL, stop REAL, title TEXT, descr TEXT);
CREATE TABLE IF NOT EXISTS tokens(h TEXT PRIMARY KEY, user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
  kind TEXT, created REAL, expires REAL, used INTEGER DEFAULT 0);
CREATE INDEX IF NOT EXISTS i_epg ON live_epg(tvg_id, stop);
CREATE TABLE IF NOT EXISTS play_log(id INTEGER PRIMARY KEY, user_id INTEGER, username TEXT, media_id INTEGER, title TEXT, client TEXT,
  device TEXT, ip TEXT, remote INTEGER, method TEXT, quality TEXT, started REAL, ended REAL, watched REAL DEFAULT 0, last_pos REAL, duration REAL);
CREATE INDEX IF NOT EXISTS i_playlog_started ON play_log(started);
CREATE TABLE IF NOT EXISTS mylist(user_id INTEGER REFERENCES users(id) ON DELETE CASCADE, item_id INTEGER REFERENCES items(id) ON DELETE CASCADE,
  added REAL, PRIMARY KEY(user_id, item_id));
CREATE INDEX IF NOT EXISTS i_media_item ON media(item_id);
CREATE INDEX IF NOT EXISTS i_items_tmdb ON items(kind, tmdb_id);
"""


def init_db():
    c = db()
    c.executescript(SCHEMA)
    for k, v in DEFAULT_SETTINGS.items():
        c.execute("INSERT OR IGNORE INTO settings(k,v) VALUES(?,?)", (k, v))
    c.execute("UPDATE settings SET v='CineVerse' WHERE k='server_name' AND v='Cinemo'")   # migrare din Cinemo
    c.execute("UPDATE settings SET v='5' WHERE k='scan_interval' AND v='30'")   # scanare la 5 minute (vechiul implicit era 30)
    # o singura data: sesiunile nu mai expira automat (vechea limita era 1-4 ore)
    if not c.execute("SELECT 1 FROM settings WHERE k='sess_unlimited_done'").fetchone():
        c.execute("UPDATE settings SET v='0' WHERE k='session_hours' AND v IN ('1','2','3','4')")
        c.execute("INSERT INTO settings(k,v) VALUES('sess_unlimited_done','1')")
    # un singur cont de administrator: pastram primul (contul creat la instalare), restul devin utilizatori
    c.execute("UPDATE users SET admin=0 WHERE admin=1 AND id <> (SELECT MIN(id) FROM users WHERE admin=1)")
    c.execute("UPDATE subtitles SET path=replace(path,'/var/lib/cinemo/','/var/lib/cineverse/') WHERE path LIKE '/var/lib/cinemo/%'")
    for tbl, col, decl in [("users", "remote_ok", "INTEGER DEFAULT 1"), ("users", "max_q", "TEXT DEFAULT ''"),
                           ("users", "max_streams", "INTEGER DEFAULT 0"), ("users", "can_download", "INTEGER DEFAULT 1"), ("users", "live_ok", "INTEGER DEFAULT 1"), ("users", "libs", "TEXT DEFAULT ''"),
                           ("users", "email", "TEXT DEFAULT ''"), ("users", "email_ok", "INTEGER DEFAULT 1"),
                           ("users", "active", "INTEGER DEFAULT 1"), ("users", "totp", "TEXT DEFAULT ''"),
                           ("users", "totp_codes", "TEXT DEFAULT ''"), ("users", "signup_ip", "TEXT DEFAULT ''"), ("sessions", "ip", "TEXT"), ("sessions", "ua", "TEXT"),
                           ("sessions", "last_seen", "REAL"), ("sessions", "mkey", "TEXT")]:
        if col not in [r[1] for r in c.execute(f"PRAGMA table_info({tbl})")]:
            c.execute(f"ALTER TABLE {tbl} ADD COLUMN {col} {decl}")
    c.commit()


def S(k):
    r = q("SELECT v FROM settings WHERE k=?", (k,), one=True)
    return r["v"] if r and r["v"] is not None else DEFAULT_SETTINGS.get(k, "")


def set_S(k, v):
    x("INSERT INTO settings(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", (k, str(v)))


# ---------------------------------------------------------------- auth
def hash_pw(pw, salt=None):
    salt = salt or secrets.token_hex(16)
    h = hashlib.pbkdf2_hmac("sha256", pw.encode(), salt.encode(), 200_000).hex()
    return f"pbkdf2${salt}${h}"


def check_pw(pw, stored):
    try:
        _, salt, _h = stored.split("$")
        return secrets.compare_digest(hash_pw(pw, salt), stored)
    except Exception:
        return False


def create_user(username, pw, admin=False):
    return x("INSERT INTO users(username,pw,admin,created) VALUES(?,?,?,?)", (username.strip(), hash_pw(pw), 1 if admin else 0, time.time()))


SESSION_OPTS = ("0", "4", "12", "24", "168", "720", "2160")   # ore; 0 = sesiunea nu expira


def session_ttl():
    """Durata maxima a unei sesiuni, in secunde. 0 = nu expira niciodata."""
    try:
        return max(0, int(S("session_hours") or 0)) * 3600
    except ValueError:
        return 0


COOKIE = "__Host-cineverse"        # prefixul __Host- impiedica un alt site de pe acelasi domeniu sa-l suprascrie
COOKIE_OLD = "cineverse"

# Numai aceste rute accepta cheia din adresa (?t=). Sunt cele puse in <video src> si <img src>,
# unde browserul/televizorul nu poate trimite antete. Restul cer cookie sau Authorization.
MEDIA_PATHS = ("/api/hls/", "/api/stream/", "/api/live/s/", "/api/live/logo/", "/api/subs/", "/img/")


def mkey_for(req: Request):
    """Cheia cu care clientii cer imagini si flux video, fara sa expuna tokenul de sesiune in adresa."""
    tok = req_token(req)
    if not tok:
        return None
    r = q("SELECT mkey FROM sessions WHERE token=?", (tok,), one=True)
    if r and r["mkey"]:
        return r["mkey"]
    mk = secrets.token_urlsafe(24)          # sesiuni facute inainte de actualizare
    x("UPDATE sessions SET mkey=? WHERE token=?", (mk, tok))
    return mk


def session_cookie(req: Request):
    return req.cookies.get(COOKIE) or req.cookies.get(COOKIE_OLD)


def req_token(req: Request):
    """Sesiunea vine din cookie (browser) sau din antetul Authorization (aplicatia de TV)."""
    tok = session_cookie(req)
    if tok:
        return tok
    auth = req.headers.get("authorization") or ""
    if auth[:7].lower() == "bearer ":
        return auth[7:].strip()
    return None


def current_user(req: Request):
    tok = req_token(req)
    r = None
    if tok:
        r = q("SELECT u.*, s.created AS s_created, s.last_seen AS s_seen FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token=?",
              (tok,), one=True)
    if r is None and req.method in ("GET", "HEAD"):
        mk = req.query_params.get("t")
        if mk and req.url.path.startswith(MEDIA_PATHS):
            # cheia de media deschide doar continutul, niciodata administrarea sau contul
            r = q("SELECT u.*, s.created AS s_created, s.last_seen AS s_seen FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.mkey=?",
                  (mk,), one=True)
    if not r:
        return None
    now = time.time()
    ttl = session_ttl()
    if ttl and now - max(r["s_seen"] or 0, r["s_created"] or 0) > ttl:   # glisanta: conteaza ultima activitate
        x("DELETE FROM sessions WHERE token=?", (tok,))
        return None
    if not _row(r, "active", 1):
        x("DELETE FROM sessions WHERE token=?", (tok,))
        return None
    if not r["s_seen"] or now - r["s_seen"] > 60:
        x("UPDATE sessions SET last_seen=?, ip=? WHERE token=?", (now, client_ip(req), tok))
    return r


# ---------------------------------------------------------------- e-mail, jetoane, parole, 2FA
MAIL_STATE = {"last": 0.0, "err": "", "sent": 0}


def mail_enabled():
    return bool(S("smtp_host").strip() and S("smtp_from").strip())


def public_base(req=None):
    """Adresa publica folosita in e-mailuri. Fara ea, linkurile ar duce spre IP-ul local."""
    u = (S("public_url") or "").strip().rstrip("/")
    if u:
        return u if u.startswith("http") else "https://" + u
    if req is not None:
        try:
            return str(req.base_url).rstrip("/")
        except Exception:
            pass
    return ""


def send_mail(to, subject, text):
    """Trimite un e-mail simplu. Ridica exceptie daca nu reuseste."""
    from email.message import EmailMessage
    host, port = S("smtp_host").strip(), int(S("smtp_port") or 587)
    mode = S("smtp_tls") or "starttls"
    frm = S("smtp_from").strip() or S("smtp_user").strip()
    if not host or not frm:
        raise RuntimeError("Trimiterea de e-mailuri nu e configurată (Administrare → Conturi → E-mail).")
    m = EmailMessage()
    m["From"] = f"CineVerse <{frm}>"
    m["To"] = to
    m["Subject"] = subject
    m.set_content(text)
    if mode == "ssl":
        srv = smtplib.SMTP_SSL(host, port, timeout=25)
    else:
        srv = smtplib.SMTP(host, port, timeout=25)
    try:
        srv.ehlo()
        if mode == "starttls":
            srv.starttls()
            srv.ehlo()
        if S("smtp_user").strip():
            srv.login(S("smtp_user").strip(), S("smtp_pass"))
        srv.send_message(m)
    finally:
        try:
            srv.quit()
        except Exception:
            pass
    MAIL_STATE.update(last=time.time(), err="", sent=MAIL_STATE["sent"] + 1)


def mail_bg(to, subject, text):
    """Trimitem in fundal – utilizatorul nu trebuie sa astepte dupa serverul de mail."""
    def run():
        try:
            send_mail(to, subject, text)
        except Exception as e:
            MAIL_STATE["err"] = str(e)[:200]
            log.warning("e-mail către %s eșuat: %s", to, e)
    threading.Thread(target=run, daemon=True).start()


# ---- jetoane de unica folosinta (resetare parola, confirmare adresa)
def make_token(uid, kind, ttl):
    raw = secrets.token_urlsafe(32)
    h = hashlib.sha256(raw.encode()).hexdigest()
    now = time.time()
    x("DELETE FROM tokens WHERE expires < ?", (now,))
    x("INSERT INTO tokens(h,user_id,kind,created,expires,used) VALUES(?,?,?,?,?,0)", (h, uid, kind, now, now + ttl))
    return raw


def peek_token(raw, kind):
    """Verifica jetonul fara sa-l consume – ca o parola respinsa sa nu strice linkul."""
    h = hashlib.sha256((raw or "").encode()).hexdigest()
    r = q("SELECT * FROM tokens WHERE h=? AND kind=?", (h, kind), one=True)
    if not r or r["used"] or r["expires"] < time.time():
        return None
    return q("SELECT * FROM users WHERE id=?", (r["user_id"],), one=True)


def burn_token(raw):
    x("UPDATE tokens SET used=1 WHERE h=?", (hashlib.sha256((raw or "").encode()).hexdigest(),))


def use_token(raw, kind):
    u = peek_token(raw, kind)
    if u:
        burn_token(raw)
    return u


# ---- reguli pentru parole
COMMON_PW = {"parola", "password", "123456", "12345678", "123456789", "qwerty", "abc123", "111111",
             "cineverse", "admin", "administrator", "iloveyou", "welcome", "monkey", "dragon",
             "parola123", "password1", "1234567890", "qwertyuiop", "letmein", "football"}


def pw_min():
    try:
        return max(4, min(64, int(S("pw_min") or 8)))
    except ValueError:
        return 8


def pw_problem(pw, username="", email=""):
    pw = pw or ""
    n = pw_min()
    if len(pw) < n:
        return f"Parola trebuie să aibă cel puţin {n} caractere."
    low = pw.lower()
    if low in COMMON_PW:
        return "Parola asta e printre cele mai folosite din lume. Alege alta."
    if username and username.lower() in low:
        return "Parola nu trebuie să conţină numele contului."
    if email and email.split("@")[0].lower() and len(email.split("@")[0]) > 2 and email.split("@")[0].lower() in low:
        return "Parola nu trebuie să conţină adresa de e-mail."
    if re.fullmatch(r"(.)\1*", pw):
        return "Parola nu poate fi un singur caracter repetat."
    return None


EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s.]+\.[^@\s]{2,}$")


def email_problem(email):
    email = (email or "").strip()
    if not EMAIL_RE.match(email):
        return "Adresa de e-mail nu pare validă."
    dom = (S("signup_domains") or "").strip()
    if dom:
        allowed = [d.strip().lower().lstrip("@") for d in re.split(r"[\s,;]+", dom) if d.strip()]
        if allowed and email.split("@")[-1].lower() not in allowed:
            return "Adresele de la acest furnizor nu sunt acceptate pe acest server."
    return None


# ---- limitare simpla pe IP (inregistrari, resetari de parola)
RL = collections.defaultdict(list)
RL_LOCK = threading.Lock()


def rl_check(key, limit, window, msg):
    now = time.time()
    with RL_LOCK:
        hits = [t for t in RL[key] if now - t < window]
        if len(hits) >= limit:
            RL[key] = hits
            raise HTTPException(429, msg)
        hits.append(now)
        RL[key] = hits
        if len(RL) > 5000:
            for k in [k for k, v in list(RL.items()) if not v or now - v[-1] > 3600][:2000]:
                RL.pop(k, None)


# ---- autentificare in doi pasi (TOTP, ca in Google Authenticator)
def totp_new():
    return base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")


def totp_at(secret, ts):
    key = base64.b32decode(secret + "=" * (-len(secret) % 8), casefold=True)
    h = hmac.new(key, struct.pack(">Q", int(ts // 30)), hashlib.sha1).digest()
    o = h[-1] & 0x0F
    return "%06d" % ((struct.unpack(">I", h[o:o + 4])[0] & 0x7FFFFFFF) % 1000000)


def totp_ok(secret, code):
    code = re.sub(r"\D", "", code or "")
    if len(code) != 6 or not secret:
        return False
    now = time.time()
    for drift in (-1, 0, 1):                      # acceptam si ceasuri usor decalate
        if secrets.compare_digest(totp_at(secret, now + drift * 30), code):
            return True
    return False


def recovery_new(n=6):
    codes = ["-".join(secrets.token_hex(2) for _ in range(2)) for _ in range(n)]
    return codes, json.dumps([hashlib.sha256(c.encode()).hexdigest() for c in codes])


def recovery_use(u, code):
    try:
        hs = json.loads(_row(u, "totp_codes", "") or "[]")
    except Exception:
        return False
    h = hashlib.sha256((code or "").strip().lower().encode()).hexdigest()
    if h not in hs:
        return False
    hs.remove(h)
    x("UPDATE users SET totp_codes=? WHERE id=?", (json.dumps(hs), u["id"]))
    return True


# ---------------------------------------------------------------- protectie la ghicirea parolei
BF = {"fails": {}, "blocked": {}, "log": collections.deque(maxlen=200)}
BF_LOCK = threading.Lock()


def bf_exempt(req):
    return S("bf_lan_exempt") == "1" and not is_remote(req)


def bf_check(req):
    ip = client_ip(req)
    with BF_LOCK:
        until = BF["blocked"].get(ip, 0)
        if until and until <= time.time():
            BF["blocked"].pop(ip, None)
            until = 0
    if until and not bf_exempt(req):
        mins = max(1, math.ceil((until - time.time()) / 60))
        raise HTTPException(429, f"Prea multe încercări greșite. IP-ul tău e blocat încă {mins} min.")


def bf_record(req, username, ok):
    ip, now = client_ip(req), time.time()
    with BF_LOCK:
        BF["log"].appendleft({"t": now, "ip": ip, "user": (username or "")[:40], "ok": ok, "remote": is_remote(req)})
        if ok:
            BF["fails"].pop(ip, None)
            return
        if bf_exempt(req):
            return
        win = max(1, int(S("bf_window") or 10)) * 60
        lst = [t for t in BF["fails"].get(ip, []) if now - t < win] + [now]
        BF["fails"][ip] = lst
        if len(lst) >= max(2, int(S("bf_attempts") or 5)):
            BF["blocked"][ip] = now + max(1, int(S("bf_block") or 15)) * 60
            BF["fails"].pop(ip, None)
            log.warning("IP blocat pentru ghicirea parolei: %s (utilizator: %s)", ip, username)


def need_user(req: Request):
    u = current_user(req)
    if not u:
        raise HTTPException(401, "Sesiune expirată sau neautentificat")
    return u


def need_admin(req: Request):
    u = need_user(req)
    if not u["admin"]:
        raise HTTPException(403, "Doar administratorul")
    return u


# ---------------------------------------------------------------- retea (LAN / extern)
_nets_cache = {"raw": None, "nets": []}


def lan_nets():
    raw = S("lan_networks")
    if raw != _nets_cache["raw"]:
        nets = []
        for part in re.split(r"[\s,;]+", raw or ""):
            try:
                if part:
                    nets.append(ipaddress.ip_network(part, strict=False))
            except ValueError:
                log.warning("Retea LAN invalida: %s", part)
        _nets_cache.update(raw=raw, nets=nets)
    return _nets_cache["nets"]


def client_ip(req: Request):
    return req.client.host if req.client else "127.0.0.1"


_srv_nets = {"t": 0, "nets": []}


VIRT_IF = ("docker", "br-", "veth", "tailscale", "wg", "tun", "vethernet", "hyper-v", "vmware",
           "virtualbox", "vmnet", "wsl", "loopback", "npcap", "zerotier", "ifb", "dummy", "bond", "sit")


def _iface_addrs():
    """[(adresa, lungime_prefix)] pentru interfetele reale ale serverului, pe Linux si pe Windows."""
    out = []
    try:
        if IS_WIN:
            ps = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command",
                                 "Get-NetIPAddress -AddressState Preferred | "
                                 "Select-Object IPAddress,PrefixLength,InterfaceAlias | ConvertTo-Json -Compress"],
                                capture_output=True, text=True, timeout=15,
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)).stdout
            data = json.loads(ps or "[]")
            for a in (data if isinstance(data, list) else [data]):
                alias = str(a.get("InterfaceAlias") or "").lower()
                if any(v in alias for v in VIRT_IF):
                    continue
                ip = str(a.get("IPAddress") or "").split("%")[0]     # fara %zona de la IPv6
                if ip:
                    out.append((ip, int(a.get("PrefixLength") or 0)))
        else:
            raw = subprocess.run(["ip", "-j", "addr"], capture_output=True, text=True, timeout=5).stdout
            for itf in json.loads(raw or "[]"):
                if itf.get("ifname", "").lower().startswith(VIRT_IF):
                    continue
                for a in itf.get("addr_info", []):
                    out.append((a["local"], a["prefixlen"]))
    except Exception:
        pass
    if not out:                                   # plan de rezerva: adresa principala, prefix presupus
        try:
            sk = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sk.connect(("198.51.100.1", 80))
            out = [(sk.getsockname()[0], 24)]
            sk.close()
        except Exception:
            pass
    return out


def server_nets():
    """Retelele interfetelor serverului (IPv4 + IPv6 global, ex. prefixul /64 Digi) – clientii din ele sunt LAN."""
    if time.time() - _srv_nets["t"] < 60:
        return _srv_nets["nets"]
    nets = []
    for addr, plen in _iface_addrs():
        try:
            n = ipaddress.ip_interface(f"{addr}/{plen}").network
            if n.prefixlen >= (16 if n.version == 4 else 48):   # fara retele prea mari
                nets.append(n)
        except Exception:
            pass
    _srv_nets.update(t=time.time(), nets=nets)
    return nets


def is_remote(req: Request):
    try:
        ip = ipaddress.ip_address(client_ip(req))
    except ValueError:
        return True
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    nets = lan_nets() + (server_nets() if S("lan_auto") == "1" else [])
    return not any(ip.version == n.version and ip in n for n in nets)


def remote_max_bps():
    q_ = QMAP.get(S("remote_max")) or QUALITIES[0]
    return min(q_[1], REMOTE_CAP)


def allowed_qualities(remote, user=None):
    if remote:
        cap = remote_max_bps()
        uq = QMAP.get((user["max_q"] if user is not None and "max_q" in user.keys() else "") or "")
        if uq:
            cap = min(cap, uq[1])
        lst = [q_ for q_ in QUALITIES if q_[1] <= cap]
        return lst or [QUALITIES[-1]]
    return list(QUALITIES)


# redari active (pentru limita de ecrane pe utilizator)
ACTIVE = {}
ALOCK = threading.Lock()


def touch_active(uid, client, **kw):
    with ALOCK:
        e = ACTIVE.setdefault((uid, client), {"uid": uid, "client": client})
        e.update(kw, t=time.time())


STOP_REQ = set()   # (uid, client) oprite de administrator


def device_name(ua):
    ua = ua or ""
    if "CineVerseAndroid" in ua:
        return "Aplicația Android"
    if "CineVerseDesktop" in ua:
        return "Aplicația Windows"
    os_ = ("iPhone" if "iPhone" in ua else "iPad" if "iPad" in ua else "Android" if "Android" in ua else "Windows" if "Windows" in ua
           else "Mac" if "Mac OS" in ua else "Smart TV" if re.search(r"SmartTV|Tizen|Web0S|webOS", ua) else "Linux" if "Linux" in ua else "")
    br = ("Edge" if "Edg/" in ua else "Opera" if "OPR/" in ua else "Chrome" if "Chrome/" in ua else "Firefox" if "Firefox/" in ua
          else "Safari" if "Safari/" in ua else "Browser")
    return f"{br} · {os_}" if os_ else br


def fmt_bps(b):
    return f"{b / 1e6:.1f} Mbps".replace(".0 ", " ") if b >= 1e6 else f"{b / 1e3:.0f} kbps"


def esc_html(t):
    return (str(t or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;"))


def fmt_size(n):
    for unit in ("octeți", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "octeți" else f"{n:.1f} {unit}"
        n /= 1024.0


def media_title(m):
    it = q("SELECT title, kind FROM items WHERE id=?", (m["item_id"],), one=True)
    if it and it["kind"] == "series":
        return f"{it['title']} – S{m['season']}:E{m['episode']}" + (f" {m['ep_title']}" if m["ep_title"] else "")
    return it["title"] if it else Path(m["path"]).stem


def playback_details(m, info, a_idx, method, hw, ql, remote):
    v = info.get("video") or {}
    auds = info.get("audio", [])
    a = next((x_ for x_ in auds if x_["index"] == a_idx), None)
    src_v = (f"{v.get('width')}×{v.get('height')} · {(v.get('codec') or '?').upper()}" + (" 10-bit" if "10" in (v.get("pix_fmt") or "") else "")
             + (" · HDR" if v.get("hdr") else "")) if v else "—"
    src_a = (f"{LANG_NAMES.get(a['lang'], a['lang'].upper())} · {(a['codec'] or '').upper()} {a['channels']}ch") if a else "—"
    maxh = int(S("max_height") or 1080)
    if ql:
        maxh = min(maxh, ql[2])
    oh = min(v.get("height") or maxh, maxh)
    hwl = {"vaapi": "GPU (VAAPI)", "nvenc": "GPU (NVENC)", "qsv": "GPU (QuickSync)"}.get((hw or "").split("+")[0], "CPU")
    if method == "direct":
        lab, out_v, out_a, br = "Redare directă", "Original (fără procesare)", "Original", info.get("bitrate") or 0
    elif method == "copy":
        lab, out_v, out_a, br = "Remux (video copiat, fără re-encodare)", "Original · H.264", "AAC stereo", info.get("bitrate") or 0
    else:
        lab = f"Transcodare – {hwl}" + (" + tone-mapping HDR→SDR" if "tonemap" in (hw or "") else "")
        out_v, out_a = f"{oh}p · H.264", f"AAC stereo {ql[3] if ql else 192}k"
        br = ql[1] if ql else int(float((S("bitrate") or "8M").rstrip("M")) * 1e6)
    return {"method_label": lab, "src_video": src_v, "out_video": out_v, "src_audio": src_a, "out_audio": out_a,
            "container": Path(m["path"]).suffix.lstrip(".").upper(), "bitrate": fmt_bps(br) if br else "—",
            "quality": ql[4] if ql else ("Original" if method in ("direct", "copy") else f"LAN · max {maxh}p"), "size": m["size"] or 0, "file": Path(m["path"]).name}


def log_play(u, client, m, remote, ua, method, quality, start):
    """intrare noua in istoric doar cand clientul porneste alt fisier (seek/schimbare pista pastreaza intrarea)"""
    with ALOCK:
        e = ACTIVE.get((u["id"], client))
        if e and e.get("media") == m["id"] and e.get("log_id"):
            return e["log_id"], e.get("started", time.time())
    now = time.time()
    lid = x("""INSERT INTO play_log(user_id,username,media_id,title,client,device,ip,remote,method,quality,started,ended,watched,last_pos,duration)
               VALUES(?,?,?,?,?,?,?,?,?,?,?,?,0,?,?)""",
            (u["id"], u["username"], m["id"], media_title(m), client, device_name(ua), "", 1 if remote else 0, method, quality,
             now, now, start, m["duration"] or 0))
    return lid, now


def active_for(uid, exclude=None):
    now = time.time()
    with ALOCK:
        for k in [k for k, e in ACTIVE.items() if now - e["t"] > 60]:
            ACTIVE.pop(k, None)
        return [e for (u_, c), e in ACTIVE.items() if u_ == uid and c != exclude]


# ---------------------------------------------------------------- utilitare
def norm(s):
    s = (s or "").lower()
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def ffprobe(path):
    try:
        out = subprocess.run(["ffprobe", "-v", "error", "-print_format", "json", "-show_format", "-show_streams", path],
                             capture_output=True, timeout=60).stdout
        d = json.loads(out or b"{}")
    except Exception as e:
        log.warning("ffprobe %s: %s", path, e)
        return None
    fmt = d.get("format", {})
    info = {"format": fmt.get("format_name", ""), "duration": float(fmt.get("duration") or 0), "bitrate": int(fmt.get("bit_rate") or 0),
            "video": None, "audio": [], "subs": []}
    for s in d.get("streams", []):
        t = s.get("codec_type")
        tags = {k.lower(): v for k, v in (s.get("tags") or {}).items()}
        lang = (tags.get("language") or "und").lower()
        if t == "video" and info["video"] is None and not (s.get("disposition") or {}).get("attached_pic"):
            info["video"] = {"index": s["index"], "codec": s.get("codec_name"), "width": s.get("width") or 0, "height": s.get("height") or 0,
                             "pix_fmt": s.get("pix_fmt") or "", "profile": s.get("profile") or "",
                             "hdr": (s.get("color_transfer") in ("smpte2084", "arib-std-b67"))}
            if not info["duration"]:
                info["duration"] = float(s.get("duration") or 0)
        elif t == "audio":
            info["audio"].append({"index": s["index"], "codec": s.get("codec_name"), "lang": lang, "channels": s.get("channels") or 2,
                                  "title": tags.get("title", ""), "default": bool((s.get("disposition") or {}).get("default"))})
        elif t == "subtitle":
            info["subs"].append({"index": s["index"], "codec": s.get("codec_name"), "lang": lang, "title": tags.get("title", ""),
                                 "forced": bool((s.get("disposition") or {}).get("forced"))})
    return info


def os_hash(path):
    try:
        size = os.path.getsize(path)
        if size < 131072:
            return None
        h = size
        with open(path, "rb") as f:
            a = f.read(65536)
            f.seek(size - 65536)
            b = f.read(65536)
        for chunk in (a, b):
            for (v,) in struct.iter_unpack("<Q", chunk):
                h = (h + v) & 0xFFFFFFFFFFFFFFFF
        return "%016x" % h
    except Exception:
        return None


# ---------------------------------------------------------------- subtitrari (encoding + conversie)
MOJIBAKE = str.maketrans({"º": "ș", "ª": "Ș", "þ": "ț", "Þ": "Ț", "ã": "ă", "Ã": "Ă"})
CEDILLA = str.maketrans({"ş": "ș", "Ş": "Ș", "ţ": "ț", "Ţ": "Ț"})


def decode_sub(b: bytes) -> str:
    if b[:2] in (b"\xff\xfe", b"\xfe\xff"):
        t = b.decode("utf-16", errors="replace")
    else:
        try:
            t = b.decode("utf-8-sig")
        except UnicodeDecodeError:
            t = b.decode("cp1250", errors="replace")   # cp1250 / iso-8859-2 / iso-8859-16 au aceleasi pozitii pt diacritice RO
    bad = sum(t.count(c) for c in "ºªþÞã")
    good = sum(t.count(c) for c in "șțăŞşţȘȚ")
    if bad > 5 and bad > good:
        t = t.translate(MOJIBAKE)
    return t.translate(CEDILLA)


TS_RE = re.compile(r"(?:(\d+):)?(\d{1,2}):(\d{1,2})[,.](\d{1,3})")


def _ts(m):
    h = int(m.group(1) or 0)
    return f"{h:02d}:{int(m.group(2)):02d}:{int(m.group(3)):02d}.{m.group(4).ljust(3, '0')[:3]}"


def to_vtt(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n").lstrip("﻿").strip()
    if text.startswith("WEBVTT"):
        return text + "\n"
    out = ["WEBVTT", ""]
    for block in re.split(r"\n\s*\n", text):
        lines = block.split("\n")
        for i, l in enumerate(lines):
            if "-->" in l:
                ts = list(TS_RE.finditer(l))
                if len(ts) < 2:
                    break
                body = [re.sub(r"\{\\[^}]*\}", "", y) for y in lines[i + 1:]]
                body = [y for y in body if y.strip()]
                if body:
                    out += [f"{_ts(ts[0])} --> {_ts(ts[1])}"] + body + [""]
                break
    return "\n".join(out) + "\n"


def lang_from_name(name):
    parts = [p.lower() for p in re.split(r"[._\-\s\[\]()]+", name)]
    for p in reversed(parts):
        if p in RO_CODES:
            return "ro"
        if p in ("en", "eng", "english"):
            return "en"
    return "und"


LANG_NAMES = {"ro": "Română", "rum": "Română", "ron": "Română", "en": "Engleză", "eng": "Engleză", "fr": "Franceză", "fre": "Franceză",
              "fra": "Franceză", "de": "Germană", "ger": "Germană", "deu": "Germană", "es": "Spaniolă", "spa": "Spaniolă", "it": "Italiană",
              "ita": "Italiană", "hu": "Maghiară", "hun": "Maghiară", "ru": "Rusă", "rus": "Rusă", "und": "Necunoscută", "jpn": "Japoneză",
              "ja": "Japoneză", "por": "Portugheză", "pt": "Portugheză", "tur": "Turcă", "tr": "Turcă"}


def is_ro(lang):
    return (lang or "").lower() in RO_CODES


# ---------------------------------------------------------------- TMDB
class TMDB:
    API = "https://api.themoviedb.org/3"

    def __init__(self):
        self.cli = httpx.Client(timeout=20, follow_redirects=True)

    def get(self, path, **params):
        key = S("tmdb_key").strip()
        if not key:
            return None
        headers = {"Accept": "application/json"}
        if len(key) > 40:
            headers["Authorization"] = f"Bearer {key}"
        else:
            params["api_key"] = key
        for attempt in range(3):
            try:
                r = self.cli.get(self.API + path, params=params, headers=headers)
                if r.status_code == 429:
                    time.sleep(2 + attempt * 2)
                    continue
                if r.status_code == 404:
                    return None
                r.raise_for_status()
                return r.json()
            except Exception as e:
                log.warning("TMDB %s: %s", path, e)
                time.sleep(1)
        return None

    def search(self, kind, title, year=None):
        path = "/search/movie" if kind == "movie" else "/search/tv"
        yk = "year" if kind == "movie" else "first_air_date_year"
        for p in ([{yk: year}] if year else []) + [{}]:
            d = self.get(path, query=title, language="ro-RO", include_adult="false", **p)
            res = (d or {}).get("results") or []
            if res:
                nt = norm(title)
                res.sort(key=lambda r: (norm(r.get("title") or r.get("name")) != nt and norm(r.get("original_title") or r.get("original_name")) != nt,
                                        -(r.get("popularity") or 0)))
                return res[0]["id"]
        return None

    def details(self, kind, tid):
        p = "/movie/" if kind == "movie" else "/tv/"
        extra = "credits,videos,images," + ("release_dates" if kind == "movie" else "content_ratings")
        d = self.get(p + str(tid), language="ro-RO", append_to_response=extra, include_image_language="ro,en,null",
                     include_video_language="ro,en")
        if not d:
            return None
        if not d.get("overview") or not d.get("tagline"):
            en = self.get(p + str(tid), language="en-US") or {}
            d["overview"] = d.get("overview") or en.get("overview", "")
            d["tagline"] = d.get("tagline") or en.get("tagline", "")
        return d

    def season(self, tid, n):
        ro = self.get(f"/tv/{tid}/season/{n}", language="ro-RO") or {}
        eps = {e["episode_number"]: e for e in ro.get("episodes", [])}
        if any(not e.get("overview") or re.match(r"^Episodul \d+$", e.get("name") or "") for e in eps.values()):
            en = self.get(f"/tv/{tid}/season/{n}", language="en-US") or {}
            for e in en.get("episodes", []):
                r = eps.get(e["episode_number"])
                if r is None:
                    continue
                if not r.get("overview"):
                    r["overview"] = e.get("overview")
                if not r.get("name") or re.match(r"^Episodul \d+$", r.get("name") or ""):
                    r["name"] = e.get("name") or r.get("name")
        return eps


tmdb = TMDB()


def apply_tmdb(item_id, kind, tid):
    d = tmdb.details(kind, tid)
    if not d:
        return False
    # daca exista deja alt item cu acelasi tmdb -> unim
    other = q("SELECT id FROM items WHERE kind=? AND tmdb_id=? AND id<>?", (kind, tid, item_id), one=True)
    if other:
        x("UPDATE media SET item_id=? WHERE item_id=?", (other["id"], item_id))
        x("UPDATE OR IGNORE mylist SET item_id=? WHERE item_id=?", (other["id"], item_id))
        x("DELETE FROM items WHERE id=?", (item_id,))
        return True
    title = d.get("title") or d.get("name")
    orig = d.get("original_title") or d.get("original_name")
    date = d.get("release_date") or d.get("first_air_date") or ""
    year = int(date[:4]) if date[:4].isdigit() else None
    genres = [g["name"] for g in d.get("genres", [])]
    cast = [{"name": c.get("name"), "character": c.get("character"), "profile": c.get("profile_path")}
            for c in (d.get("credits") or {}).get("cast", [])[:15]]
    if kind == "movie":
        director = ", ".join(c["name"] for c in (d.get("credits") or {}).get("crew", []) if c.get("job") == "Director")
        runtime = d.get("runtime")
        cert = ""
        for rel in (d.get("release_dates") or {}).get("results", []):
            if rel.get("iso_3166_1") in ("RO", "US"):
                for rd in rel.get("release_dates", []):
                    if rd.get("certification"):
                        cert = rd["certification"]
                        break
                if cert and rel.get("iso_3166_1") == "RO":
                    break
    else:
        director = ", ".join(c.get("name") for c in d.get("created_by", []))
        rts = d.get("episode_run_time") or []
        runtime = rts[0] if rts else None
        cert = ""
        for cr in (d.get("content_ratings") or {}).get("results", []):
            if cr.get("iso_3166_1") in ("RO", "US") and cr.get("rating"):
                cert = cr["rating"]
                if cr["iso_3166_1"] == "RO":
                    break
    trailer = ""
    vids = sorted((d.get("videos") or {}).get("results", []), key=lambda v: (v.get("type") != "Trailer", v.get("iso_639_1") != "ro"))
    for v in vids:
        if v.get("site") == "YouTube":
            trailer = v.get("key")
            break
    logo = ""
    logos = (d.get("images") or {}).get("logos", [])
    logos.sort(key=lambda l: ({"ro": 0, "en": 1}.get(l.get("iso_639_1"), 2), -(l.get("vote_average") or 0)))
    for l in logos:
        if l.get("file_path", "").endswith(".png") or l.get("file_path", "").endswith(".svg"):
            logo = l["file_path"]
            break
    x("""UPDATE items SET title=?, orig_title=?, year=?, tmdb_id=?, overview=?, tagline=?, poster=?, backdrop=?, logo=?, genres=?, rating=?,
         runtime=?, cert=?, cast_json=?, director=?, trailer=?, matched=1 WHERE id=?""",
      (title, orig, year, tid, d.get("overview", ""), d.get("tagline", ""), d.get("poster_path"), d.get("backdrop_path"), logo,
       json.dumps(genres, ensure_ascii=False), d.get("vote_average"), runtime, cert, json.dumps(cast, ensure_ascii=False), director,
       trailer, item_id))
    if kind == "series":
        x("UPDATE media SET ep_title=NULL WHERE item_id=?", (item_id,))
        fill_episodes(item_id)
    return True


def fill_episodes(item_id):
    it = q("SELECT * FROM items WHERE id=?", (item_id,), one=True)
    if not it or not it["tmdb_id"]:
        return
    rows = q("SELECT id, season, episode FROM media WHERE item_id=? AND ep_title IS NULL", (item_id,))
    seasons = sorted({r["season"] for r in rows if r["season"] is not None})
    for sn in seasons:
        eps = tmdb.season(it["tmdb_id"], sn)
        for r in rows:
            if r["season"] == sn and r["episode"] in eps:
                e = eps[r["episode"]]
                x("UPDATE media SET ep_title=?, ep_overview=?, still=?, air_date=? WHERE id=?",
                  (e.get("name") or f"Episodul {r['episode']}", e.get("overview") or "", e.get("still_path"), e.get("air_date"), r["id"]))


# ---------------------------------------------------------------- scanare biblioteca
scan_state = {"running": False, "phase": "", "done": 0, "total": 0, "last": 0, "error": ""}
scan_lock = threading.Lock()


def media_dirs():
    return [d.strip() for d in re.split(r"[\n;]+", S("media_dirs")) if d.strip()]


# ---------------------------------------------------------------- biblioteci (un folder media = o biblioteca)
def libs_all():
    """Bibliotecile disponibile, cu un nume prietenos (numele folderului)."""
    return [{"path": d, "name": (Path(d).name or d)} for d in media_dirs()]


def _row(row, k, default=""):
    try:
        v = row[k]
    except Exception:
        return default
    return default if v is None else v


def user_libs(u):
    """Folderele pe care le vede utilizatorul. None = toate (implicit si pentru administrator)."""
    if not u or _row(u, "admin", 0):
        return None
    raw = str(_row(u, "libs", "")).strip()
    if not raw:
        return None                    # gol = toate bibliotecile (si valoarea implicita)
    if raw == "-":
        return []                      # marcaj explicit: nicio biblioteca
    dirs = media_dirs()
    allowed = [p.strip() for p in re.split(r"[\n;]+", raw) if p.strip() and p.strip() in dirs]
    return allowed                     # lista goala = utilizatorul nu vede nicio biblioteca


def _pfx(p):
    return ((p.rstrip("/\\") + os.sep).lower() if IS_WIN else (p.rstrip("/") + os.sep))


def lib_path_sql(u, col="m.path"):
    """Conditie SQL care limiteaza un rand din `media` la bibliotecile utilizatorului."""
    libs = user_libs(u)
    if libs is None:
        return "", []
    if not libs:
        return " AND 0", []
    expr = f"LOWER({col})" if IS_WIN else col
    parts, params = [], []
    for p in libs:
        pref = _pfx(p)
        parts.append(f"substr({expr},1,?)=?")
        params += [len(pref), pref]
    return " AND (" + " OR ".join(parts) + ")", params


def lib_item_sql(u, item_col="items.id"):
    """Conditie SQL care limiteaza un rand din `items` la bibliotecile utilizatorului."""
    cond, params = lib_path_sql(u, "mm.path")
    if not cond:
        return "", []
    if cond == " AND 0":
        return " AND 0", []
    return f" AND EXISTS(SELECT 1 FROM media mm WHERE mm.item_id={item_col}{cond})", params


def path_allowed(u, path):
    libs = user_libs(u)
    if libs is None:
        return True
    t = (str(path).lower() if IS_WIN else str(path))
    return any(t.startswith(_pfx(p)) for p in libs)


def need_media(u, m, what="Fișierul"):
    """Opreste accesul la un fisier dintr-o biblioteca pe care utilizatorul nu o are."""
    if not m:
        raise HTTPException(404)
    if not path_allowed(u, m["path"]):
        raise HTTPException(403, f"{what} face parte dintr-o bibliotecă la care contul tău nu are acces")
    return m


def guess(path, root):
    from guessit import guessit
    rel = os.path.relpath(path, root)
    try:
        g = guessit(rel)
    except Exception:
        g = {}
    base = Path(path).stem
    if g.get("type") == "episode" and g.get("episode") is not None:
        title = g.get("title") or Path(path).parent.name
        ep = g.get("episode")
        ep = ep[0] if isinstance(ep, list) else ep
        se = g.get("season", 1)
        se = se[0] if isinstance(se, list) else se
        return {"kind": "series", "title": str(title), "year": g.get("year"), "season": int(se), "episode": int(ep)}
    title = g.get("title") or base
    if isinstance(title, list):
        title = " ".join(title)
    return {"kind": "movie", "title": str(title), "year": g.get("year") if isinstance(g.get("year"), int) else None}


RO_WORDS = re.compile(r"\b(și|să|că|nu|este|pentru|care|ești|asta|acum|unde|când|doar|foarte|aici|trebuie|vreau|poate|îmi|mă|tău)\b", re.I)
EN_WORDS = re.compile(r"\b(the|you|and|what|this|that|is|are|don't|i'm|it's|with|have|your)\b", re.I)


def detect_sub_lang(path):
    """Limba unei subtitrari fara cod in nume: dupa diacritice si cuvinte uzuale."""
    try:
        with open(path, "rb") as fh:
            txt = decode_sub(fh.read(96 * 1024))
    except Exception:
        return "und"
    txt = re.sub(r"\d+:\d+:\d+[,.]\d+\s*-->.*|<[^>]+>|\{[^}]*\}", " ", txt)
    letters = max(1, sum(ch.isalpha() for ch in txt))
    dia = sum(txt.count(ch) for ch in "ăâîșțĂÂÎȘȚ")
    ro, en = len(RO_WORDS.findall(txt)), len(EN_WORDS.findall(txt))
    if dia / letters > 0.004 and ro >= en * 0.6 or ro >= 5 and ro > en * 1.5:
        return "ro"
    if en >= 5 and en > ro * 2 and dia / letters < 0.002:
        return "en"
    return "und"


def find_local_subs(media_id, path):
    p = Path(path)
    stem = p.stem.lower()
    try:
        siblings = list(p.parent.iterdir())
    except Exception:
        return
    subdirs = [d for d in siblings if d.is_dir() and d.name.lower() in ("subs", "subtitles", "subtitrari")]
    cands = [f for f in siblings if f.is_file()]
    for sd in subdirs:
        try:
            cands += [f for f in sd.iterdir() if f.is_file()]
        except Exception:
            pass
    for f in cands:
        if f.suffix.lower() not in SUB_EXT or f.suffix.lower() == ".sub":
            continue
        if not f.name.lower().startswith(stem) and f.parent == p.parent:
            continue
        old = q("SELECT lang FROM subtitles WHERE media_id=? AND source='local' AND path=?", (media_id, str(f)), one=True)
        if old and old["lang"] != "und":
            continue   # deja cunoscuta – nu mai citim fisierul la fiecare scanare
        lang = lang_from_name(f.stem[len(stem):] if f.name.lower().startswith(stem) else f.stem)
        if lang == "und" and f.suffix.lower() in (".srt", ".vtt", ".ass", ".ssa"):
            lang = detect_sub_lang(f)
        label = LANG_NAMES.get(lang, "Externă") + " (fișier)"
        x("""INSERT INTO subtitles(media_id,lang,label,source,path,stream_index) VALUES(?,?,?,?,?,-1)
             ON CONFLICT(media_id,source,path,stream_index) DO UPDATE SET lang=excluded.lang, label=excluded.label""",
          (media_id, lang, label, "local", str(f)))


def add_embedded_subs(media_id, info):
    for s in (info or {}).get("subs", []):
        if s["codec"] in TEXT_SUB_CODECS:
            label = LANG_NAMES.get(s["lang"], s["lang"].upper()) + (f" – {s['title']}" if s["title"] else "") + (" (forțat)" if s["forced"] else "")
            lang = "ro" if is_ro(s["lang"]) or re.search(r"rom[aâ]n|rumän|roumain", s["title"] or "", re.I) else s["lang"]
            x("INSERT OR IGNORE INTO subtitles(media_id,lang,label,source,path,stream_index) VALUES(?,?,?,?,?,?)",
              (media_id, lang, label, "embedded", "", s["index"]))


def get_item_for(g):
    key = ("movie:" + norm(g["title"]) + f":{g['year'] or ''}") if g["kind"] == "movie" else ("tv:" + norm(g["title"]))
    r = q("SELECT id FROM items WHERE key=?", (key,), one=True)
    if r:
        return r["id"]
    return x("INSERT INTO items(kind,key,title,year,added) VALUES(?,?,?,?,?)", (g["kind"], key, g["title"], g["year"], time.time()))


def scan_library():
    if not scan_lock.acquire(blocking=False):
        return
    try:
        scan_state.update(running=True, phase="Caut fișiere", done=0, total=0, error="")
        found = {}
        for root in media_dirs():
            if not os.path.isdir(root):
                log.warning("Folder inexistent/inaccesibil: %s", root)
                scan_state["error"] = f"Folder inaccesibil: {root}"
                continue
            for dp, dn, fn in os.walk(root, followlinks=True):
                dn[:] = [d for d in dn if not d.startswith(".") and d.lower() not in ("sample", "samples", "extras", "featurettes", "@eadir")]
                for f in fn:
                    if Path(f).suffix.lower() in VIDEO_EXT and "sample" not in f.lower() and not f.startswith("."):
                        found[os.path.join(dp, f)] = root
        existing = {r["path"]: r["id"] for r in q("SELECT id,path FROM media")}
        roots_ok = [r for r in media_dirs() if os.path.isdir(r)]
        for p, mid in existing.items():
            if p not in found and (any(p.startswith(r) for r in roots_ok) or not any(p.startswith(r) for r in media_dirs())):
                x("DELETE FROM media WHERE id=?", (mid,))
        x("DELETE FROM items WHERE id NOT IN (SELECT DISTINCT item_id FROM media WHERE item_id IS NOT NULL)")
        new = [p for p in found if p not in existing]
        scan_state.update(phase="Analizez fișiere noi", total=len(new), done=0)
        for p in sorted(new):
            try:
                g = guess(p, found[p])
                info = ffprobe(p)
                item_id = get_item_for(g)
                mid = x("INSERT INTO media(item_id,path,season,episode,duration,size,probe,added) VALUES(?,?,?,?,?,?,?,?)",
                        (item_id, p, g.get("season"), g.get("episode"), (info or {}).get("duration") or 0, os.path.getsize(p),
                         json.dumps(info), time.time()))
                find_local_subs(mid, p)
                add_embedded_subs(mid, info)
                x("UPDATE items SET added=? WHERE id=?", (time.time(), item_id))
            except Exception as e:
                log.exception("scan %s: %s", p, e)
            scan_state["done"] += 1
        # re-scan subtitrari locale pentru toate (fisiere .srt adaugate ulterior)
        for r in q("SELECT id,path FROM media"):
            find_local_subs(r["id"], r["path"])
        if S("tmdb_key"):
            todo = q("SELECT id,kind,title,year FROM items WHERE matched=0")
            scan_state.update(phase="Descarc metadate TMDB", total=len(todo), done=0)
            for it in todo:
                try:
                    tid = tmdb.search(it["kind"], it["title"], it["year"])
                    if tid:
                        apply_tmdb(it["id"], it["kind"], tid)
                    else:
                        x("UPDATE items SET matched=2 WHERE id=?", (it["id"],))
                except Exception as e:
                    log.exception("tmdb %s: %s", it["title"], e)
                scan_state["done"] += 1
            for it in q("SELECT DISTINCT item_id FROM media m JOIN items i ON i.id=m.item_id WHERE i.kind='series' AND i.matched=1 AND m.ep_title IS NULL"):
                fill_episodes(it["item_id"])
        scan_state.update(phase="Gata", last=time.time())
        subs_worker.enqueue_all()
    except Exception as e:
        log.exception("scan: %s", e)
        scan_state["error"] = str(e)
    finally:
        scan_state["running"] = False
        scan_lock.release()


def scan_async():
    threading.Thread(target=scan_library, daemon=True).start()


# ---------------------------------------------------------------- OpenSubtitles
class OpenSubs:
    BASE = "https://api.opensubtitles.com/api/v1"

    def __init__(self):
        self.token = None
        self.base = self.BASE
        self.tok_time = 0
        self.remaining = None
        self.reset = ""
        self.last_error = ""
        self.cli = httpx.Client(timeout=30, follow_redirects=True)
        self.lock = threading.Lock()

    def headers(self):
        h = {"Api-Key": S("os_key").strip(), "User-Agent": f"CineVerse v{VERSION}", "Accept": "application/json", "Content-Type": "application/json"}
        if self.token:
            h["Authorization"] = f"Bearer {self.token}"
        return h

    def enabled(self):
        return bool(S("os_key").strip())

    def login(self):
        if not (S("os_user") and S("os_pass")):
            return
        if self.token and time.time() - self.tok_time < 12 * 3600:
            return
        try:
            r = self.cli.post(self.BASE + "/login", json={"username": S("os_user"), "password": S("os_pass")}, headers=self.headers())
            if r.status_code == 200:
                d = r.json()
                self.token = d.get("token")
                self.tok_time = time.time()
                if d.get("base_url"):
                    self.base = "https://" + d["base_url"].replace("https://", "").rstrip("/") + "/api/v1"
                self.remaining = (d.get("user") or {}).get("allowed_downloads", self.remaining)
            else:
                self.last_error = f"login {r.status_code}: {r.text[:200]}"
                log.warning("OpenSubtitles %s", self.last_error)
        except Exception as e:
            self.last_error = f"login: {e}"

    def search(self, media_id):
        m = q("SELECT m.*, i.kind, i.tmdb_id, i.title, i.year, i.orig_title FROM media m JOIN items i ON i.id=m.item_id WHERE m.id=?", (media_id,), one=True)
        if not m:
            return []
        with self.lock:
            self.login()
            base = {"languages": "ro"}
            if m["kind"] == "series":
                if m["tmdb_id"]:
                    base["parent_tmdb_id"] = m["tmdb_id"]
                else:
                    base["query"] = m["title"]
                base["season_number"] = m["season"]
                base["episode_number"] = m["episode"]
            else:
                if m["tmdb_id"]:
                    base["tmdb_id"] = m["tmdb_id"]
                else:
                    base["query"] = m["title"]
                    if m["year"]:
                        base["year"] = m["year"]
            h = os_hash(m["path"])
            attempts = ([dict(base, moviehash=h)] if h else []) + [base]
            if m["kind"] == "movie" and m["tmdb_id"]:
                attempts.append({"languages": "ro", "query": m["orig_title"] or m["title"], **({"year": m["year"]} if m["year"] else {})})
            results, seen = [], set()
            for params in attempts:
                params = {k: (str(v).lower() if isinstance(v, str) else v) for k, v in sorted(params.items())}
                try:
                    r = self.cli.get(self.base + "/subtitles", params=params, headers=self.headers())
                    if r.status_code != 200:
                        self.last_error = f"search {r.status_code}: {r.text[:200]}"
                        continue
                    for s in r.json().get("data", []):
                        a = s.get("attributes", {})
                        if (a.get("language") or "").lower() not in ("ro", "rum", "ron"):
                            continue
                        for f in a.get("files", []):
                            if f["file_id"] in seen:
                                continue
                            seen.add(f["file_id"])
                            results.append({"file_id": f["file_id"], "file_name": f.get("file_name") or "", "release": a.get("release") or "",
                                            "downloads": a.get("download_count") or 0, "hash_match": bool(a.get("moviehash_match")),
                                            "hi": bool(a.get("hearing_impaired")), "trusted": bool(a.get("from_trusted")),
                                            "ai": bool(a.get("ai_translated") or a.get("machine_translated")), "fps": a.get("fps")})
                except Exception as e:
                    self.last_error = f"search: {e}"
                if results and (any(r["hash_match"] for r in results) or "moviehash" not in params):
                    break
                time.sleep(0.4)
        fname = set(norm(Path(m["path"]).stem).split())

        def score(r):
            rel = set(norm(r["release"] + " " + r["file_name"]).split())
            sim = len(fname & rel) / max(1, len(fname | rel))
            return r["hash_match"] * 1000 + sim * 150 + math.log1p(r["downloads"]) * 6 + r["trusted"] * 10 - r["hi"] * 5 - r["ai"] * 60
        results.sort(key=score, reverse=True)
        return results[:25]

    def download(self, media_id, file_id, label_extra=""):
        with self.lock:
            self.login()
            r = self.cli.post(self.base + "/download", json={"file_id": int(file_id)}, headers=self.headers())
            if r.status_code != 200:
                self.last_error = f"download {r.status_code}: {r.text[:200]}"
                raise HTTPException(502, "OpenSubtitles: " + (r.json().get("message") if "json" in r.headers.get("content-type", "") else r.text[:200]))
            d = r.json()
            self.remaining = d.get("remaining", self.remaining)
            self.reset = d.get("reset_time", "")
            raw = self.cli.get(d["link"]).content
        vtt = to_vtt(decode_sub(raw))
        out = SUBS / f"os_{media_id}_{file_id}.vtt"
        out.write_text(vtt, encoding="utf-8")
        label = "Română (OpenSubtitles)" + (f" – {label_extra}" if label_extra else "")
        x("INSERT OR IGNORE INTO subtitles(media_id,lang,label,source,path,stream_index) VALUES(?,?,?,?,?,-1)",
          (media_id, "ro", label, "opensubtitles", str(out)))
        return q("SELECT * FROM subtitles WHERE media_id=? AND path=?", (media_id, str(out)), one=True)


opensubs = OpenSubs()


# ---------------------------------------------------------------- Subs.ro
class SubsRo:
    BASE = "https://api.subs.ro/v1.0"

    def __init__(self):
        self.cli = httpx.Client(timeout=20, follow_redirects=True)
        self.lock = threading.Lock()

    def enabled(self):
        return bool(S("subsro_key").strip())

    def _headers(self):
        return {
            "X-Subs-Api-Key": S("subsro_key").strip(),
            "Accept": "application/json",
            "User-Agent": f"CineVerse v{VERSION}",
        }

    def search(self, media_id):
        m = q("SELECT m.*, i.kind, i.imdb_id, i.title, i.year FROM media m JOIN items i ON i.id=m.item_id WHERE m.id=?",
              (media_id,), one=True)
        if not m:
            return []
        imdb = (m["imdb_id"] or "").strip()
        if not imdb:
            return []
        if not imdb.startswith("tt"):
            imdb = f"tt{imdb}"
        with self.lock:
            try:
                r = self.cli.get(f"{self.BASE}/search/imdbid/{imdb}",
                                 params={"language": "ro"}, headers=self._headers())
                if r.status_code != 200:
                    log.warning("subsro search %s: %s", r.status_code, r.text[:200])
                    return []
                data = r.json()
                items = data.get("items") or []
                results = []
                for item in items:
                    sid = item.get("id")
                    title = item.get("title") or ""
                    if not sid or not title:
                        continue
                    dl_url = item.get("downloadLink") or f"{self.BASE}/subtitle/{sid}/download"
                    results.append({
                        "subtitle_id": sid,
                        "title": title,
                        "description": item.get("description") or title,
                        "translator": item.get("translator") or "",
                        "download_url": dl_url,
                        "year": item.get("year"),
                    })
                return results
            except Exception as e:
                log.warning("subsro search: %s", e)
                return []

    def download(self, media_id, subtitle_id, download_url):
        import io, zipfile, rarfile  # rarfile optional
        with self.lock:
            try:
                r = self.cli.get(download_url, headers=self._headers())
                if r.status_code != 200:
                    raise HTTPException(502, f"Subs.ro download {r.status_code}")
                body = r.content
            except HTTPException:
                raise
            except Exception as e:
                raise HTTPException(502, f"Subs.ro: {e}") from e

        # Dacă e arhivă ZIP, extragem primul fișier de subtitrare
        sub_bytes = None
        sub_name = f"subsro_{media_id}_{subtitle_id}.srt"
        try:
            if zipfile.is_zipfile(io.BytesIO(body)):
                with zipfile.ZipFile(io.BytesIO(body)) as zf:
                    for name in zf.namelist():
                        if any(name.lower().endswith(ext) for ext in (".srt", ".ass", ".ssa", ".vtt", ".sub")):
                            sub_bytes = zf.read(name)
                            sub_name = Path(name).name
                            break
            elif body[:7] in (b"Rar!\x1a\x07\x00", b"Rar!\x1a\x07\x01"):
                try:
                    import rarfile
                    with rarfile.RarFile(io.BytesIO(body)) as rf:
                        for name in rf.namelist():
                            if any(name.lower().endswith(ext) for ext in (".srt", ".ass", ".ssa", ".vtt", ".sub")):
                                sub_bytes = rf.read(name)
                                sub_name = Path(name).name
                                break
                except Exception:
                    pass
        except Exception:
            pass

        if sub_bytes is None:
            sub_bytes = body  # sperăm că e direct .srt

        vtt = to_vtt(decode_sub(sub_bytes))
        out = SUBS / f"subsro_{media_id}_{subtitle_id}.vtt"
        out.write_text(vtt, encoding="utf-8")
        label = "Română (Subs.ro)"
        x("INSERT OR IGNORE INTO subtitles(media_id,lang,label,source,path,stream_index) VALUES(?,?,?,?,?,-1)",
          (media_id, "ro", label, "subsro", str(out)))
        return q("SELECT * FROM subtitles WHERE media_id=? AND path=?", (media_id, str(out)), one=True)


subsro = SubsRo()


class SubsWorker:
    def __init__(self):
        self.q = queue.Queue()
        self.pending = set()
        self.paused_until = 0
        threading.Thread(target=self.run, daemon=True).start()

    def enqueue(self, mid):
        if mid not in self.pending:
            self.pending.add(mid)
            self.q.put(mid)

    def enqueue_all(self):
        if S("auto_subs") != "1":
            return
        if not opensubs.enabled() and not subsro.enabled():
            return
        week = time.time() - 7 * 86400
        for r in q("SELECT id FROM media WHERE subs_checked < ? ORDER BY added DESC", (week,)):
            if not q("SELECT 1 FROM subtitles WHERE media_id=? AND lang='ro'", (r["id"],), one=True):
                self.enqueue(r["id"])

    def run(self):
        while True:
            mid = self.q.get()
            self.pending.discard(mid)
            try:
                while time.time() < self.paused_until:
                    time.sleep(30)
                if S("auto_subs") != "1":
                    continue
                if q("SELECT 1 FROM subtitles WHERE media_id=? AND lang='ro'", (mid,), one=True):
                    continue

                found = False

                # 1. Încearcă OpenSubtitles
                if opensubs.enabled():
                    res = opensubs.search(mid)
                    if res:
                        try:
                            opensubs.download(mid, res[0]["file_id"])
                            log.info("Subtitrare RO descarcata (OpenSubtitles) pentru media %s", mid)
                            found = True
                        except HTTPException as e:
                            log.warning("Download subtitrare OpenSubtitles: %s", e.detail)
                            if "quota" in str(e.detail).lower() or "limit" in str(e.detail).lower() or opensubs.remaining == 0:
                                self.paused_until = time.time() + 3600 * 3
                                self.enqueue(mid)
                                continue

                # 2. Fallback: Subs.ro
                if not found and subsro.enabled():
                    res = subsro.search(mid)
                    if res:
                        try:
                            subsro.download(mid, res[0]["subtitle_id"], res[0]["download_url"])
                            log.info("Subtitrare RO descarcata (Subs.ro) pentru media %s", mid)
                            found = True
                        except HTTPException as e:
                            log.warning("Download subtitrare Subs.ro: %s", e.detail)

                x("UPDATE media SET subs_checked=? WHERE id=?", (time.time(), mid))
                time.sleep(2)
            except Exception as e:
                log.warning("subs worker: %s", e)


subs_worker = None

# ---------------------------------------------------------------- transcodare / HLS
HW = {"mode": "none", "detail": "", "zscale": False, "tonemap_vaapi": False}


def popen_kw():
    """Pornim ffmpeg intr-un grup de procese propriu (si fara fereastra de consola pe Windows)."""
    if IS_WIN:
        return {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP | getattr(subprocess, "CREATE_NO_WINDOW", 0)}
    return {"preexec_fn": os.setsid} if hasattr(os, "setsid") else {}


def proc_pause(proc, pause):
    """Suspenda/reia un ffmpeg care a transcodat prea mult inainte. Pe Windows are nevoie de psutil."""
    if not proc or proc.poll() is not None:
        return False
    if IS_WIN:
        try:
            import psutil
            pr = psutil.Process(proc.pid)
            pr.suspend() if pause else pr.resume()
            return True
        except Exception:
            return False          # fara psutil doar transcodam mai departe – nu e o eroare
    os.kill(proc.pid, signal.SIGSTOP if pause else signal.SIGCONT)
    return True


def _test_cmd(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, timeout=20).returncode == 0
    except Exception:
        return False


def detect_filters():
    try:
        out = subprocess.run(["ffmpeg", "-hide_banner", "-filters"], capture_output=True, text=True, timeout=20).stdout
    except Exception:
        out = ""
    HW["zscale"] = " zscale " in out and " tonemap " in out
    HW["tonemap_vaapi"] = " tonemap_vaapi " in out


def detect_hw():
    detect_filters()
    pref = S("hwaccel")
    dev = S("vaapi_device")
    tests = {
        "vaapi": ["ffmpeg", "-hide_banner", "-loglevel", "error", "-init_hw_device", f"vaapi=va:{dev}", "-filter_hw_device", "va",
                  "-f", "lavfi", "-i", "testsrc2=s=640x360:d=1", "-vf", "format=nv12,hwupload", "-c:v", "h264_vaapi", "-f", "null", "-"],
        "nvenc": ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=640x360:d=1", "-c:v", "h264_nvenc",
                  "-f", "null", "-"],
        "qsv": ["ffmpeg", "-hide_banner", "-loglevel", "error", "-init_hw_device", "qsv=hw", "-filter_hw_device", "hw", "-f", "lavfi",
                "-i", "testsrc2=s=640x360:d=1", "-vf", "format=nv12,hwupload=extra_hw_frames=64", "-c:v", "h264_qsv", "-f", "null", "-"],
        "amf": ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=640x360:d=1",
                "-vf", "format=nv12", "-c:v", "h264_amf", "-f", "null", "-"],       # AMD, mai ales pe Windows
    }
    auto = ["nvenc", "qsv", "amf"] if IS_WIN else ["vaapi", "nvenc", "qsv"]
    order = [pref] if pref in tests else (auto if pref == "auto" else [])
    for m in order:
        if m == "vaapi" and not os.path.exists(dev):
            continue
        if _test_cmd(tests[m]):
            HW.update(mode=m, detail=f"{m} OK")
            log.info("Accelerare hardware: %s", m)
            return
    HW.update(mode="none", detail="software (libx264)" + (" – HW indisponibil" if pref not in ("none",) else ""))
    log.info("Transcodare software (libx264)")


def keyframe_before(path, t):
    if t <= 0.5:
        return 0.0
    try:
        out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-skip_frame", "nokey", "-read_intervals",
                              f"{max(0, t - 15)}%{t + 0.5}", "-show_entries", "frame=pts_time,best_effort_timestamp_time", "-of", "csv=p=0", path],
                             capture_output=True, timeout=20, text=True).stdout
        ts = []
        for line in out.split("\n"):
            for v in line.split(","):
                try:
                    ts.append(float(v))
                    break
                except ValueError:
                    pass
        ts = [v for v in ts if v <= t + 0.05]
        return max(ts) if ts else None
    except Exception:
        return None


class Session:
    def __init__(self, sid, media_id, user_id, client):
        self.sid, self.media_id, self.user_id, self.client = sid, media_id, user_id, client
        self.dir = TRANS / sid
        self.dir.mkdir(parents=True, exist_ok=True)
        self.proc = None
        self.last = time.time()
        self.req_seg = 0
        self.stopped = False
        self.hw = "none"
        self.method = ""

    def kill(self):
        try:
            if self.proc and self.proc.poll() is None:
                proc_pause(self.proc, False)
                self.proc.terminate()
                try:
                    self.proc.wait(5)
                except Exception:
                    self.proc.kill()
        except Exception:
            pass
        shutil.rmtree(self.dir, ignore_errors=True)


SESSIONS = {}
SLOCK = threading.Lock()


def build_cmd(path, info, start, audio_index, method, hw, ql=None, tm_mode="hw"):
    v = info.get("video") or {}
    maxh = int(S("max_height") or 1080)
    br = S("bitrate") or "8M"
    buf = "16M"
    abr = 192
    if ql:  # treapta de calitate (ex: streaming extern)
        abr = ql[3]
        vb = max(150, int(ql[1] / 1000 * 0.95) - abr)   # 5% rezerva pentru overhead-ul containerului (MPEG-TS)
        br, buf = f"{vb}k", f"{vb * 2}k"
        maxh = min(maxh, ql[2])
    h = v.get("height") or 1080
    w = v.get("width") or 1920
    if h > maxh:
        w, h = int(round(w * maxh / h / 2) * 2), maxh
    w, h = w - w % 2, h - h % 2
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y"]
    vcodec = (v.get("codec") or "").lower()
    hwdec_ok = vcodec in ("h264", "hevc", "mpeg2video", "vc1", "vp9", "av1")
    # HDR -> SDR: pe GPU (tonemap_vaapi) sau software (zscale + tonemap)
    hdr = bool(v.get("hdr")) and S("tonemap") == "1" and method == "transcode"
    alg = S("tonemap_alg") if S("tonemap_alg") in ("hable", "mobius", "reinhard", "clip") else "hable"
    sw_tm = ""
    if hdr and HW.get("zscale"):
        sw_tm = (f"scale={w}:{h},zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap={alg}:desat=0,"
                 f"zscale=t=bt709:m=bt709:r=tv,format=yuv420p")
    hw_tm = hdr and hw == "vaapi" and hwdec_ok and HW.get("tonemap_vaapi") and tm_mode == "hw"
    if hdr and hw in ("nvenc",):
        hwdec_ok = False            # decodare pe CPU ca sa putem aplica tone-mapping software
    if hdr and hw == "vaapi" and not hw_tm and sw_tm:
        hwdec_ok = False
    if method == "transcode" and hw == "vaapi":
        dev = S("vaapi_device")
        if hwdec_ok:
            cmd += ["-hwaccel", "vaapi", "-hwaccel_device", dev, "-hwaccel_output_format", "vaapi"]
        else:
            cmd += ["-init_hw_device", f"vaapi=va:{dev}", "-filter_hw_device", "va"]
    elif method == "transcode" and hw == "nvenc" and hwdec_ok:
        cmd += ["-hwaccel", "cuda", "-hwaccel_output_format", "cuda"]
    elif method == "transcode" and hw == "qsv":
        cmd += ["-init_hw_device", "qsv=hw", "-filter_hw_device", "hw"]
    if start > 0:
        cmd += ["-ss", f"{start:.3f}"]
    cmd += ["-i", path, "-map", f"0:{v['index']}" if v else "0:v:0?"]
    if audio_index is not None:
        cmd += ["-map", f"0:{audio_index}"]
    cmd += ["-sn", "-dn", "-map_metadata", "-1", "-map_chapters", "-1"]
    if method == "copy":
        cmd += ["-c:v", "copy"]
    elif hw == "vaapi":
        if hw_tm:
            vf = f"tonemap_vaapi=format=nv12:p=bt709:t=bt709:m=bt709,scale_vaapi=w={w}:h={h}"
        elif sw_tm:
            vf = f"{sw_tm},format=nv12,hwupload"
        else:
            vf = f"scale_vaapi=w={w}:h={h}:format=nv12" if hwdec_ok else f"format=nv12,hwupload,scale_vaapi=w={w}:h={h}"
        cmd += ["-vf", vf, "-c:v", "h264_vaapi", "-b:v", br, "-maxrate", br, "-bufsize", buf, "-g", "72", "-bf", "0"]
    elif hw == "nvenc":
        vf = sw_tm or (f"scale_cuda={w}:{h}:format=yuv420p" if hwdec_ok else f"scale={w}:{h},format=yuv420p")
        cmd += ["-vf", vf, "-c:v", "h264_nvenc", "-preset", "p4", "-rc", "vbr", "-b:v", br, "-maxrate", br, "-bufsize", buf, "-g", "72", "-bf", "0"]
    elif hw == "qsv":
        cmd += ["-vf", (sw_tm or f"scale={w}:{h}") + ",format=nv12,hwupload=extra_hw_frames=64", "-c:v", "h264_qsv", "-b:v", br, "-maxrate", br, "-bufsize", buf, "-g", "72"]
    elif hw == "amf":
        cmd += ["-vf", (sw_tm or f"scale={w}:{h}") + ",format=nv12", "-c:v", "h264_amf", "-usage", "transcoding", "-b:v", br,
                "-maxrate", br, "-bufsize", buf, "-g", "72"]
    else:
        rc = ["-b:v", br] if ql else ["-crf", "21"]
        cmd += ["-vf", sw_tm or f"scale={w}:{h},format=yuv420p", "-c:v", "libx264", "-preset", "veryfast", *rc, "-maxrate", br,
                "-bufsize", buf, "-profile:v", "high", "-level", "4.1", "-g", "72", "-keyint_min", "72", "-sc_threshold", "0"]
    if method != "copy":
        cmd += ["-force_key_frames", "expr:gte(t,n_forced*3)"]
    if hdr and (hw_tm or sw_tm):
        cmd += ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
    if audio_index is not None:
        cmd += ["-c:a", "aac", "-ac", "2", "-b:a", f"{abr}k", "-ar", "48000"]
    cmd += ["-max_muxing_queue_size", "4096", "-f", "hls", "-hls_time", "6", "-hls_playlist_type", "event", "-hls_list_size", "0",
            "-start_number", "0"]
    return cmd


def start_session(media, start, audio_index, user_id, client, force_transcode=False, ql=None):
    force_transcode = force_transcode or bool(ql)
    info = json.loads(media["probe"] or "{}") or ffprobe(media["path"]) or {}
    v = info.get("video") or {}
    with SLOCK:
        for sid, s in list(SESSIONS.items()):
            if s.user_id == user_id and s.client == client:
                s.kill()
                SESSIONS.pop(sid, None)
    maxh = int(S("max_height") or 1080)
    can_copy = (not force_transcode and (v.get("codec") == "h264") and (v.get("pix_fmt") in ("yuv420p", "yuvj420p"))
                and (v.get("height") or 0) <= maxh + 8)
    plans = []
    is_hdr = bool(v.get("hdr")) and S("tonemap") == "1"
    if can_copy and not is_hdr:
        kf = keyframe_before(media["path"], start)
        if kf is not None:
            plans.append(("copy", "none", kf, "hw"))
    if HW["mode"] != "none":
        plans.append(("transcode", HW["mode"], start, "hw"))
        if is_hdr and HW["mode"] == "vaapi":
            plans.append(("transcode", "vaapi", start, "sw"))   # daca tonemap_vaapi nu merge: tone-mapping CPU + encodare GPU
    plans.append(("transcode", "none", start, "sw"))
    last_err = ""
    for method, hw, st, tm in plans:
        sid = secrets.token_hex(8)
        s = Session(sid, media["id"], user_id, client)
        cmd = build_cmd(media["path"], info, st, audio_index, method, hw, ql, tm)
        cmd += ["-hls_segment_filename", str(s.dir / "s%05d.ts"), str(s.dir / "index.m3u8")]
        errf = open(s.dir / "ffmpeg.log", "wb")
        s.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=errf, **popen_kw())
        s.hw, s.method = hw + ("+tonemap" if is_hdr and method == "transcode" else ""), method
        s.quality = ql[0] if ql else "orig"
        t0 = time.time()
        ok = False
        while time.time() - t0 < 45:
            pl = s.dir / "index.m3u8"
            if pl.exists() and "#EXTINF" in pl.read_text(errors="ignore"):
                ok = True
                break
            if s.proc.poll() is not None:
                break
            time.sleep(0.15)
        if ok:
            with SLOCK:
                SESSIONS[sid] = s
            log.info("Sesiune %s: %s/%s de la %.1fs – %s", sid, method, hw, st, Path(media["path"]).name)
            return s, st
        last_err = (s.dir / "ffmpeg.log").read_text(errors="ignore")[-600:]
        log.warning("Plan %s/%s esuat: %s", method, hw, last_err)
        s.kill()
    raise HTTPException(500, "Transcodare eșuată: " + last_err)


def janitor():
    while True:
        time.sleep(2)
        now = time.time()
        with SLOCK:
            items = list(SESSIONS.items())
        for sid, s in items:
            if now - s.last > 120:
                s.kill()
                with SLOCK:
                    SESSIONS.pop(sid, None)
                continue
            if s.proc and s.proc.poll() is None:
                produced = len(list(s.dir.glob("s*.ts")))
                ahead = produced - s.req_seg
                try:
                    if ahead > 40 and not s.stopped:
                        s.stopped = proc_pause(s.proc, True)
                    elif ahead < 25 and s.stopped:
                        proc_pause(s.proc, False)
                        s.stopped = False
                except Exception:
                    pass


def periodic_scan():
    time.sleep(5)
    scan_library()
    while True:
        try:
            iv = max(1, int(S("scan_interval") or 5))
        except ValueError:
            iv = 5
        time.sleep(iv * 60)
        scan_library()


# ---------------------------------------------------------------- serializare
def card(it, extra=None):
    d = {"id": it["id"], "kind": it["kind"], "title": it["title"], "year": it["year"], "poster": it["poster"], "backdrop": it["backdrop"],
         "logo": it["logo"], "rating": it["rating"], "genres": json.loads(it["genres"] or "[]")[:3], "cert": it["cert"],
         "runtime": it["runtime"], "overview": (it["overview"] or "")[:400]}
    if extra:
        d.update(extra)
    return d


def media_dict(m, user_id):
    p = q("SELECT position, duration, watched FROM progress WHERE user_id=? AND media_id=?", (user_id, m["id"]), one=True)
    info = json.loads(m["probe"] or "{}") or {}
    v = info.get("video") or {}
    h = v.get("height") or 0
    qual = "4K" if h > 1600 else "HD" if h >= 700 else "SD" if h else ""
    return {"id": m["id"], "season": m["season"], "episode": m["episode"], "title": m["ep_title"] or (f"Episodul {m['episode']}" if m["episode"] else Path(m["path"]).stem),
            "overview": m["ep_overview"] or "", "still": m["still"], "air_date": m["air_date"], "duration": m["duration"],
            "file": Path(m["path"]).name, "quality": qual, "hdr": bool(v.get("hdr")),
            "position": p["position"] if p else 0, "watched": bool(p and p["watched"]),
            "has_ro": bool(q("SELECT 1 FROM subtitles WHERE media_id=? AND lang='ro'", (m["id"],), one=True))}


# ---------------------------------------------------------------- app
from contextlib import asynccontextmanager


@asynccontextmanager
async def lifespan(_app):
    _startup()
    yield


def _startup():
    global subs_worker
    init_db()
    detect_hw()
    subs_worker = SubsWorker()
    shutil.rmtree(TRANS, ignore_errors=True)
    TRANS.mkdir(parents=True, exist_ok=True)
    threading.Thread(target=janitor, daemon=True).start()
    threading.Thread(target=cast_init, daemon=True).start()
    threading.Thread(target=cast_janitor, daemon=True).start()
    threading.Thread(target=live_janitor, daemon=True).start()
    threading.Thread(target=live_refresher, daemon=True).start()
    threading.Thread(target=backup_worker, daemon=True).start()
    threading.Thread(target=periodic_scan, daemon=True).start()


app = FastAPI(title="CineVerse by NetStreaming", docs_url=None, redoc_url=None, lifespan=lifespan)

# Aplicatiile native (televizor webOS etc.) ruleaza din alt origin si nu pot folosi cookie-uri.
# Permitem apelurile catre /api din orice origin – autentificarea se face cu token, nu cu cookie,
# deci browserul nu trimite cookie-ul si nu apare risc de CSRF.
API_CORS = {"Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Authorization, Content-Type, Range",
            "Access-Control-Allow-Methods": "GET, HEAD, POST, PUT, DELETE, OPTIONS",
            "Access-Control-Expose-Headers": "Content-Length, Content-Range",
            "Access-Control-Max-Age": "86400"}


SEC_HEADERS = {
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "same-origin",
    "X-Frame-Options": "SAMEORIGIN",
    "Cross-Origin-Opener-Policy": "same-origin",
    "Permissions-Policy": "geolocation=(), microphone=(), camera=(), interest-cohort=()",
}


@app.middleware("http")
async def api_cors(req: Request, call_next):
    is_api = req.url.path.startswith("/api/")
    if is_api and req.method == "OPTIONS":
        resp = Response(status_code=204, headers=API_CORS)
    else:
        resp = await call_next(req)
        if is_api:
            for k, v in API_CORS.items():
                resp.headers.setdefault(k, v)
    for k, v in SEC_HEADERS.items():
        resp.headers.setdefault(k, v)
    # HSTS doar peste HTTPS si doar daca administratorul l-a pornit
    if S("hsts") == "1" and (req.url.scheme == "https" or req.headers.get("x-forwarded-proto") == "https"):
        resp.headers.setdefault("Strict-Transport-Security", "max-age=15552000")
    return resp



@app.get("/", response_class=HTMLResponse)
def index():
    return HTMLResponse((STATIC / "index.html").read_text(encoding="utf-8"), headers={"Cache-Control": "no-cache"})


@app.get("/manifest.webmanifest")
def manifest():
    name = S("server_name") or "CineVerse"
    return JSONResponse({
        "name": f"{name} by NetStreaming", "short_name": name, "start_url": "/", "scope": "/", "display": "standalone",
        "orientation": "any", "background_color": "#0d1220", "theme_color": "#0d1220", "lang": "ro",
        "icons": [{"src": "/static/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any maskable"},
                  {"src": "/static/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any maskable"}]},
        media_type="application/manifest+json", headers={"Cache-Control": "no-cache"})


@app.get("/app/android")
def android_apk():
    p = STATIC / "CineVerse.apk"
    if not p.is_file():
        raise HTTPException(404, "Aplicația Android nu este inclusă pe acest server")
    return FileResponse(p, media_type="application/vnd.android.package-archive", filename="CineVerse.apk")


@app.get("/static/{name}")
def static(name: str):
    p = STATIC / name
    if "/" in name or ".." in name or not p.is_file():
        raise HTTPException(404)
    return FileResponse(p, headers={"Cache-Control": "max-age=86400"})


@app.get("/api/ping")
def ping():
    """Raspuns scurt, fara autentificare – clientii il folosesc ca sa verifice adresa serverului."""
    return {"app": "cineverse", "name": S("server_name") or "CineVerse", "token_auth": True}


@app.post("/api/login")
async def login(req: Request):
    d = await req.json()
    bf_check(req)
    name = (d.get("username") or "").strip()
    u = q("SELECT * FROM users WHERE username=? OR (email<>'' AND email=?)", (name, name.lower()), one=True)
    if not u or not check_pw(d.get("password") or "", u["pw"]):
        bf_record(req, name, False)
        await asyncio.sleep(1)
        bf_check(req)
        raise HTTPException(401, "Utilizator sau parolă greșită")
    if not _row(u, "active", 1):
        bf_record(req, name, True)
        raise HTTPException(403, "Contul tău așteaptă aprobarea administratorului.")
    if not _row(u, "email_ok", 1):
        bf_record(req, name, True)
        raise HTTPException(403, "Confirmă întâi adresa de e-mail – ţi-am trimis un link când ţi-ai făcut contul.")
    # pasul doi, daca e activat pe cont
    sec = _row(u, "totp", "")
    if sec:
        code = (d.get("code") or "").strip()
        if not code:
            raise HTTPException(401, "2FA")             # semnal pentru client: mai cere un cod
        if not (totp_ok(sec, code) or recovery_use(u, code)):
            bf_record(req, name, False)
            await asyncio.sleep(1)
            bf_check(req)
            raise HTTPException(401, "Cod greșit sau expirat.")
    if is_remote(req) and (S("remote_enabled") != "1" or not u["remote_ok"]):
        bf_record(req, name, True)
        raise HTTPException(403, "Contul tău nu are acces din afara rețelei locale")
    bf_record(req, name, True)
    tok = secrets.token_urlsafe(32)
    now = time.time()
    mkey = secrets.token_urlsafe(24)
    x("INSERT INTO sessions(token,user_id,created,last_seen,ip,ua,mkey) VALUES(?,?,?,?,?,?,?)",
      (tok, u["id"], now, now, client_ip(req), (req.headers.get("user-agent") or "")[:200], mkey))
    ttl = session_ttl()
    if ttl:
        x("DELETE FROM sessions WHERE COALESCE(last_seen, created) < ?", (now - ttl,))
    r = JSONResponse({"ok": True, "token": tok, "mkey": mkey} if d.get("token") else {"ok": True})
    https = req.url.scheme == "https" or req.headers.get("x-forwarded-proto") == "https"
    if https:
        r.set_cookie(COOKIE, tok, max_age=ttl or 10 * 365 * 24 * 3600, httponly=True, samesite="lax", secure=True, path="/")
        r.delete_cookie(COOKIE_OLD, path="/")
    else:
        r.set_cookie(COOKIE_OLD, tok, max_age=ttl or 10 * 365 * 24 * 3600, httponly=True, samesite="lax", secure=False, path="/")
    return r


@app.get("/api/signup/info")
def signup_info():
    m = S("signup_mode")
    return {"enabled": m in ("open", "invite", "approve"), "mode": m,
            "need_invite": m == "invite", "verify": S("signup_verify") == "1" and mail_enabled(),
            "approve": m == "approve", "pw_min": pw_min(), "mail": mail_enabled(),
            "server_name": S("server_name") or "CineVerse"}


def apply_signup_perms(uid):
    """Drepturile implicite pentru conturile facute de vizitatori."""
    x("UPDATE users SET remote_ok=?, live_ok=?, can_download=?, max_q=?, libs=? WHERE id=?",
      (1 if S("signup_remote") == "1" else 0, 1 if S("signup_live") == "1" else 0,
       1 if S("signup_download") == "1" else 0,
       S("signup_max_q") if S("signup_max_q") in QMAP else "", S("signup_libs"), uid))


@app.post("/api/signup")
async def signup(req: Request):
    mode = S("signup_mode")
    if mode not in ("open", "invite", "approve"):
        raise HTTPException(403, "Pe acest server conturile se fac doar de către administrator.")
    ip = client_ip(req)
    # limita larga pe incercari (ca sa nu poata fi bombardat), verificata inainte de orice
    rl_check("sut:" + ip, 40, 3600, "Prea multe încercări. Ia o pauză de câteva minute.")
    d = await req.json()
    name = (d.get("username") or "").strip()
    email = (d.get("email") or "").strip().lower()
    pw = d.get("password") or ""
    if not re.fullmatch(r"[A-Za-z0-9._-]{3,24}", name):
        raise HTTPException(400, "Numele contului: 3–24 caractere, doar litere, cifre, punct, minus sau underscore.")
    e = email_problem(email)
    if e:
        raise HTTPException(400, e)
    e = pw_problem(pw, name, email)
    if e:
        raise HTTPException(400, e)
    if mode == "invite" and (d.get("invite") or "").strip() != S("signup_invite").strip():
        raise HTTPException(403, "Codul de invitaţie nu este corect.")
    if q("SELECT 1 FROM users WHERE username=?", (name,), one=True):
        raise HTTPException(400, "Există deja un cont cu acest nume.")
    if q("SELECT 1 FROM users WHERE email<>'' AND email=?", (email,), one=True):
        raise HTTPException(400, "Există deja un cont cu această adresă de e-mail.")
    # limita stricta doar pe conturi chiar create – greselile de tastare nu o consuma
    rl_check("su:" + ip, 5, 3600, "Prea multe conturi create de pe această adresă. Încearcă peste o oră.")
    verify = S("signup_verify") == "1" and mail_enabled()
    try:
        uid = create_user(name, pw, False)
    except sqlite3.IntegrityError:
        raise HTTPException(400, "Există deja un cont cu acest nume.")
    x("UPDATE users SET email=?, email_ok=?, active=?, signup_ip=? WHERE id=?",
      (email, 0 if verify else 1, 0 if mode == "approve" else 1, ip, uid))
    apply_signup_perms(uid)
    log.info("Cont nou: %s <%s> de la %s", name, email, ip)
    if verify:
        tok = make_token(uid, "verify", 48 * 3600)
        base = public_base(req)
        mail_bg(email, "Confirmă-ţi contul CineVerse",
                "Salut, " + name + "!\n\nTocmai ţi-ai făcut cont pe " + (S("server_name") or "CineVerse") + ".\n"
                "Confirmă adresa de e-mail deschizând linkul de mai jos:\n\n"
                + base + "/api/verify?t=" + tok + "\n\n"
                "Linkul e valabil 48 de ore. Dacă nu tu ai cerut contul, ignoră mesajul.\n")
    return {"ok": True, "verify": verify, "approve": mode == "approve"}


@app.get("/api/verify")
def verify_email(t: str = ""):
    u = use_token(t, "verify")
    page = ("<!doctype html><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>"
            "<title>CineVerse</title><style>body{background:#0d1220;color:#fff;font-family:Segoe UI,Roboto,Arial,sans-serif;"
            "display:flex;align-items:center;justify-content:center;height:100vh;margin:0;text-align:center}"
            "div{max-width:460px;padding:30px}h1{color:#e50914;font-size:28px;margin-bottom:14px}"
            "p{color:#b9c1d4;line-height:1.5}a{color:#e50914;font-weight:700}</style><div>")
    if not u:
        return HTMLResponse(page + "<h1>Link expirat</h1><p>Linkul de confirmare nu mai este valabil. "
                                   "Cere unul nou încercând să te autentifici.</p></div>", status_code=400)
    x("UPDATE users SET email_ok=1 WHERE id=?", (u["id"],))
    extra = ("<p>Contul tău aşteaptă acum aprobarea administratorului. Te anunţăm pe e-mail când e gata.</p>"
             if not _row(u, "active", 1) else "<p><a href='/'>Intră în cont</a></p>")
    return HTMLResponse(page + "<h1>Adresă confirmată</h1><p>Mulţumim, " + esc_html(u["username"]) + ".</p>" + extra + "</div>")


@app.post("/api/forgot")
async def forgot(req: Request):
    rl_check("fg:" + client_ip(req), 5, 1800, "Prea multe cereri. Încearcă peste o jumătate de oră.")
    d = await req.json()
    who = (d.get("login") or "").strip()
    u = q("SELECT * FROM users WHERE username=? OR (email<>'' AND email=?)", (who, who.lower()), one=True)
    if u and _row(u, "email", "") and mail_enabled():
        rl_check("fgu:%s" % u["id"], 3, 1800, "Ţi-am trimis deja un link recent. Verifică-ţi e-mailul.")
        tok = make_token(u["id"], "reset", 3600)
        base = public_base(req)
        mail_bg(u["email"], "Resetare parolă CineVerse",
                "Salut, " + u["username"] + "!\n\nCineva a cerut resetarea parolei pentru contul tău.\n"
                "Dacă tu ai cerut-o, deschide linkul de mai jos şi alege o parolă nouă:\n\n"
                + base + "/#/reset?t=" + tok + "\n\n"
                "Linkul e valabil o oră şi poate fi folosit o singură dată.\n"
                "Dacă nu tu ai cerut, ignoră mesajul – parola rămâne neschimbată.\n")
    # raspuns identic, ca sa nu se poata afla ce conturi exista
    return {"ok": True}


@app.post("/api/reset")
async def reset_pw(req: Request):
    rl_check("rs:" + client_ip(req), 10, 1800, "Prea multe încercări. Încearcă mai târziu.")
    d = await req.json()
    tok = d.get("token") or ""
    u = peek_token(tok, "reset")
    if not u:
        raise HTTPException(400, "Linkul de resetare a expirat sau a fost deja folosit.")
    e = pw_problem(d.get("password") or "", u["username"], _row(u, "email", ""))
    if e:
        raise HTTPException(400, e)          # linkul ramane valabil, poate reincerca
    burn_token(tok)
    x("UPDATE users SET pw=?, email_ok=1 WHERE id=?", (hash_pw(d["password"]), u["id"]))
    x("DELETE FROM sessions WHERE user_id=?", (u["id"],))      # toate dispozitivele se deconecteaza
    log.info("Parolă resetată prin e-mail pentru %s", u["username"])
    if _row(u, "email", "") and mail_enabled():
        mail_bg(u["email"], "Parola CineVerse a fost schimbată",
                "Salut, " + u["username"] + "!\n\nParola contului tău tocmai a fost schimbată.\n"
                "Dacă nu tu ai făcut asta, anunţă administratorul serverului imediat.\n")
    return {"ok": True}


@app.post("/api/me/email")
async def set_my_email(req: Request):
    u = need_user(req)
    d = await req.json()
    em = (d.get("email") or "").strip().lower()
    if em:
        e = email_problem(em)
        if e:
            raise HTTPException(400, e)
        if q("SELECT 1 FROM users WHERE email=? AND id<>?", (em, u["id"]), one=True):
            raise HTTPException(400, "Alt cont foloseşte deja această adresă.")
    x("UPDATE users SET email=?, email_ok=1 WHERE id=?", (em, u["id"]))
    return {"ok": True}


# ---- autentificare in doi pasi
@app.post("/api/me/2fa/start")
def tfa_start(req: Request):
    u = need_user(req)
    sec = totp_new()
    TFA_PENDING[u["id"]] = {"secret": sec, "t": time.time()}
    label = quote((S("server_name") or "CineVerse") + ":" + u["username"])
    uri = "otpauth://totp/" + label + "?secret=" + sec + "&issuer=" + quote(S("server_name") or "CineVerse") + "&digits=6&period=30"
    return {"secret": " ".join(sec[i:i + 4] for i in range(0, len(sec), 4)), "raw": sec, "uri": uri}


@app.post("/api/me/2fa/enable")
async def tfa_enable(req: Request):
    u = need_user(req)
    d = await req.json()
    p = TFA_PENDING.get(u["id"])
    if not p or time.time() - p["t"] > 900:
        raise HTTPException(400, "A expirat. Ia-o de la capăt.")
    if not totp_ok(p["secret"], d.get("code") or ""):
        raise HTTPException(400, "Codul nu se potriveşte. Verifică ora telefonului şi încearcă din nou.")
    codes, hashed = recovery_new()
    x("UPDATE users SET totp=?, totp_codes=? WHERE id=?", (p["secret"], hashed, u["id"]))
    TFA_PENDING.pop(u["id"], None)
    log.info("2FA activat pentru %s", u["username"])
    return {"ok": True, "codes": codes}


@app.post("/api/me/2fa/disable")
async def tfa_disable(req: Request):
    u = need_user(req)
    d = await req.json()
    if not check_pw(d.get("password") or "", u["pw"]):
        raise HTTPException(403, "Parola nu e corectă.")
    x("UPDATE users SET totp='', totp_codes='' WHERE id=?", (u["id"],))
    return {"ok": True}


TFA_PENDING = {}


@app.post("/api/me/logout-all")
def logout_all(req: Request):
    u = need_user(req)
    x("DELETE FROM sessions WHERE user_id=?", (u["id"],))
    with ALOCK:
        for k in [k for k in ACTIVE if k[0] == u["id"]]:
            ACTIVE.pop(k, None)
    r = JSONResponse({"ok": True})
    r.delete_cookie(COOKIE, path="/")
    r.delete_cookie(COOKIE_OLD, path="/")
    return r


@app.post("/api/logout")
def logout(req: Request):
    x("DELETE FROM sessions WHERE token=?", (session_cookie(req) or "",))
    r = JSONResponse({"ok": True})
    r.delete_cookie(COOKIE, path="/")
    r.delete_cookie(COOKIE_OLD, path="/")
    return r


@app.get("/api/me")
def me(req: Request):
    u = need_user(req)
    return {"id": u["id"], "username": u["username"], "admin": bool(u["admin"]), "server_name": S("server_name"),
            "has_tmdb": bool(S("tmdb_key")), "has_os": opensubs.enabled(), "remote": is_remote(req), "ip": client_ip(req),
            "email": _row(u, "email", ""), "has_2fa": bool(_row(u, "totp", "")), "mkey": mkey_for(req),
            "expires": (max(u["s_seen"] or 0, u["s_created"] or 0) + session_ttl()) if session_ttl() else None,
            "download": download_mode(req, u),
            "live": bool(u["live_ok"]) and bool(q("SELECT 1 FROM live_channels WHERE enabled=1 LIMIT 1", one=True)),
            "devices": q("SELECT COUNT(*) c FROM sessions WHERE user_id=? AND COALESCE(last_seen, created) > ?",
                         (u["id"], time.time() - session_ttl() if session_ttl() else 0), one=True)["c"]}


@app.post("/api/me/password")
async def change_pw(req: Request):
    u = need_user(req)
    d = await req.json()
    if not check_pw(d.get("old") or "", u["pw"]):
        raise HTTPException(400, "Parola actuală e greșită")
    if len(d.get("new") or "") < 4:
        raise HTTPException(400, "Parola nouă e prea scurtă")
    x("UPDATE users SET pw=? WHERE id=?", (hash_pw(d["new"]), u["id"]))
    x("DELETE FROM sessions WHERE user_id=? AND token<>?", (u["id"], session_cookie(req) or ""))   # deconecteaza celelalte dispozitive
    return {"ok": True}


BW_WINDOW = 60.0          # secunde peste care calculam bitrate-ul real (fereastra mai lunga = cifra mai stabila)


def note_bytes(uid, client=None, live_ch=None, n=0):
    """Retine cati octeti am trimis efectiv unui spectator, ca sa putem arata bitrate-ul real."""
    if not n:
        return
    now = time.time()
    with ALOCK:
        for (k_uid, k_cli), e in ACTIVE.items():
            if k_uid != uid:
                continue
            if client is not None and k_cli != client:
                continue
            if live_ch is not None and e.get("live_ch") != live_ch:
                continue
            bw = e.get("bw")
            if bw is None:
                bw = e["bw"] = collections.deque(maxlen=400)
            bw.append((now, n))
            if client is None:
                break          # la TV Live nu stim clientul exact – il punem pe primul care se potriveste


def real_bps(e):
    """Bitrate-ul masurat (biti/secunda) pe ultimele BW_WINDOW secunde."""
    bw = e.get("bw")
    if not bw:
        return 0
    now = time.time()
    tot = sum(n for t, n in bw if now - t <= BW_WINDOW)
    if not tot:
        return 0
    # impartim la fereastra intreaga odata ce redarea dureaza de destul timp, ca sa nu umfle
    # cifra rafalele de la inceput, cand playerul isi umple memoria tampon
    span = min(BW_WINDOW, max(4.0, now - (e.get("started") or now)))
    return int(tot * 8 / span)


def continue_watching(u):
    uid = u["id"]
    lc, lp = lib_path_sql(u, "m.path")
    rows = q(f"""SELECT p.*, m.item_id, m.season, m.episode FROM progress p JOIN media m ON m.id=p.media_id
                WHERE p.user_id=?{lc} ORDER BY p.updated DESC LIMIT 200""", (uid, *lp))
    out, seen = [], set()
    for r in rows:
        if r["item_id"] in seen:
            continue
        seen.add(r["item_id"])
        it = q("SELECT * FROM items WHERE id=?", (r["item_id"],), one=True)
        if not it:
            continue
        if not r["watched"] and r["position"] > 20:
            m = q("SELECT * FROM media WHERE id=?", (r["media_id"],), one=True)
            out.append(card(it, {"resume_media": r["media_id"], "resume_pos": r["position"], "resume_dur": r["duration"] or m["duration"],
                                 "resume_label": f"S{m['season']}:E{m['episode']} {m['ep_title'] or ''}".strip() if it["kind"] == "series" else ""}))
        elif r["watched"] and it["kind"] == "series":
            nxt = q("""SELECT * FROM media WHERE item_id=? AND (season>? OR (season=? AND episode>?)) ORDER BY season, episode LIMIT 1""",
                    (it["id"], r["season"], r["season"], r["episode"]), one=True)
            if nxt and not q("SELECT 1 FROM progress WHERE user_id=? AND media_id=? AND watched=1", (uid, nxt["id"]), one=True):
                out.append(card(it, {"resume_media": nxt["id"], "resume_pos": 0, "resume_dur": nxt["duration"],
                                     "resume_label": f"Urmează: S{nxt['season']}:E{nxt['episode']} {nxt['ep_title'] or ''}".strip()}))
        if len(out) >= 20:
            break
    return out


@app.get("/api/home")
def home(req: Request):
    u = need_user(req)
    rows = []
    L, LP = lib_item_sql(u)
    Li, LPi = lib_item_sql(u, "i.id")
    cw = continue_watching(u)
    if cw:
        rows.append({"title": f"Continuă vizionarea pentru {u['username']}", "items": cw, "kind": "continue"})
    ml = q(f"SELECT i.* FROM mylist l JOIN items i ON i.id=l.item_id WHERE l.user_id=?{Li} ORDER BY l.added DESC", (u["id"], *LPi))
    if ml:
        rows.append({"title": "Lista mea", "items": [card(i) for i in ml]})
    rec = q(f"SELECT * FROM items WHERE 1=1{L} ORDER BY added DESC LIMIT 30", tuple(LP))
    if rec:
        rows.append({"title": "Adăugate recent", "items": [card(i) for i in rec]})
    top = q(f"SELECT * FROM items WHERE rating IS NOT NULL{L} ORDER BY rating DESC LIMIT 20", tuple(LP))
    if len(top) >= 4:
        rows.append({"title": "Cele mai apreciate", "items": [card(i) for i in top], "kind": "top"})
    mv = q(f"SELECT * FROM items WHERE kind='movie'{L} ORDER BY RANDOM() LIMIT 30", tuple(LP))
    if mv:
        rows.append({"title": "Filme", "items": [card(i) for i in mv]})
    tv = q(f"SELECT * FROM items WHERE kind='series'{L} ORDER BY RANDOM() LIMIT 30", tuple(LP))
    if tv:
        rows.append({"title": "Seriale", "items": [card(i) for i in tv]})
    counts = {}
    allit = q(f"SELECT * FROM items WHERE 1=1{L}", tuple(LP))
    for i in allit:
        for g in json.loads(i["genres"] or "[]"):
            counts.setdefault(g, []).append(i)
    for g, its in sorted(counts.items(), key=lambda kv: -len(kv[1]))[:10]:
        if len(its) >= 3:
            random.shuffle(its)
            rows.append({"title": g, "items": [card(i) for i in its[:30]]})
    pool = [i for i in q(f"SELECT * FROM items WHERE backdrop IS NOT NULL{L} ORDER BY added DESC LIMIT 15", tuple(LP))] or allit[:10]
    hero = [card(i) for i in random.sample(pool, min(5, len(pool)))] if pool else []
    return {"hero": hero, "rows": rows}


@app.get("/api/browse")
def browse(req: Request, kind: str = "movie", genre: str = "", sort: str = "added"):
    u = need_user(req)
    order = {"added": "added DESC", "title": "title COLLATE NOCASE", "year": "year DESC", "rating": "rating DESC"}.get(sort, "added DESC")
    L, LP = lib_item_sql(u)
    its = q(f"SELECT * FROM items WHERE kind=?{L} ORDER BY {order}", (kind, *LP))
    if genre:
        its = [i for i in its if genre in json.loads(i["genres"] or "[]")]
    genres = sorted({g for i in q(f"SELECT genres FROM items WHERE kind=?{L}", (kind, *LP)) for g in json.loads(i["genres"] or "[]")})
    return {"items": [card(i) for i in its], "genres": genres}


@app.get("/api/mylist")
def mylist(req: Request):
    u = need_user(req)
    L, LP = lib_item_sql(u, "i.id")
    return {"items": [card(i) for i in q(f"SELECT i.* FROM mylist l JOIN items i ON i.id=l.item_id WHERE l.user_id=?{L} ORDER BY l.added DESC",
                                         (u["id"], *LP))]}


@app.post("/api/mylist/{item_id}")
def toggle_list(item_id: int, req: Request):
    u = need_user(req)
    if q("SELECT 1 FROM mylist WHERE user_id=? AND item_id=?", (u["id"], item_id), one=True):
        x("DELETE FROM mylist WHERE user_id=? AND item_id=?", (u["id"], item_id))
        return {"in_list": False}
    x("INSERT INTO mylist(user_id,item_id,added) VALUES(?,?,?)", (u["id"], item_id, time.time()))
    return {"in_list": True}


@app.get("/api/search")
def search(req: Request, q_: str = ""):
    need_user(req)
    return search_impl(q_)


@app.get("/api/find")
def find(req: Request, q: str = ""):
    u = need_user(req)
    return search_impl(q, u)


def search_impl(term, u=None):
    t = norm(term)
    if not t:
        return {"items": []}
    out = []
    L, LP = lib_item_sql(u) if u else ("", [])
    for i in q(f"SELECT * FROM items WHERE 1=1{L}", tuple(LP)):
        hay = norm(" ".join([i["title"] or "", i["orig_title"] or "", i["director"] or "", " ".join(json.loads(i["genres"] or "[]")),
                            " ".join(c["name"] or "" for c in json.loads(i["cast_json"] or "[]"))]))
        if all(w in hay for w in t.split()):
            score = 0 if norm(i["title"]).startswith(t) else 1 if t in norm(i["title"]) else 2
            out.append((score, i))
    out.sort(key=lambda s: (s[0], -(s[1]["rating"] or 0)))
    return {"items": [card(i) for _, i in out[:60]]}


@app.get("/api/item/{item_id}")
def item(item_id: int, req: Request):
    u = need_user(req)
    L, LP = lib_item_sql(u)
    it = q(f"SELECT * FROM items WHERE id=?{L}", (item_id, *LP), one=True)
    if not it:
        raise HTTPException(404)
    d = card(it)
    d.update(overview=it["overview"] or "", tagline=it["tagline"], orig_title=it["orig_title"], genres=json.loads(it["genres"] or "[]"),
             cast=json.loads(it["cast_json"] or "[]"), director=it["director"], trailer=it["trailer"], tmdb_id=it["tmdb_id"],
             matched=it["matched"], in_list=bool(q("SELECT 1 FROM mylist WHERE user_id=? AND item_id=?", (u["id"], item_id), one=True)))
    lc, lp = lib_path_sql(u, "path")
    ms = [media_dict(m, u["id"]) for m in q(f"SELECT * FROM media WHERE item_id=?{lc} ORDER BY season, episode, path", (item_id, *lp))]
    if it["kind"] == "series":
        seasons = {}
        for m in ms:
            seasons.setdefault(m["season"] or 1, []).append(m)
        d["seasons"] = [{"season": k, "episodes": v} for k, v in sorted(seasons.items())]
        # episod de reluat
        prog = q("""SELECT p.*, m.season, m.episode FROM progress p JOIN media m ON m.id=p.media_id WHERE p.user_id=? AND m.item_id=?
                    ORDER BY p.updated DESC LIMIT 1""", (u["id"], item_id), one=True)
        nxt = ms[0] if ms else None
        if prog:
            cur = next((m for m in ms if m["id"] == prog["media_id"]), None)
            if cur and not cur["watched"]:
                nxt = cur
            elif cur:
                idx = ms.index(cur)
                nxt = ms[idx + 1] if idx + 1 < len(ms) else cur
        d["next"] = nxt
    else:
        d["media"] = ms
        d["next"] = ms[0] if ms else None
    if d["next"]:
        info = json.loads(q("SELECT probe FROM media WHERE id=?", (d["next"]["id"],), one=True)["probe"] or "{}") or {}
        d["audio"] = [LANG_NAMES.get(a["lang"], a["lang"]) for a in info.get("audio", [])]
    return d


@app.post("/api/play")
async def play(req: Request):
    u = need_user(req)
    d = await req.json()
    remote = is_remote(req)
    if remote and S("remote_enabled") != "1":
        raise HTTPException(403, "Streaming-ul din afara rețelei locale este dezactivat de administrator")
    if remote and not u["remote_ok"]:
        raise HTTPException(403, "Contul tău nu are acces la streaming din afara rețelei locale")
    client = str(d.get("client") or "web")[:64]
    if u["max_streams"] and len(active_for(u["id"], exclude=client)) >= u["max_streams"]:
        raise HTTPException(429, f"Ai atins numărul maxim de ecrane simultane ({u['max_streams']}). Oprește redarea pe alt dispozitiv.")
    allowed = allowed_qualities(remote, u)
    ql = QMAP.get(d.get("quality") or "")
    if ql not in allowed:
        ql = allowed[0] if remote else None   # extern: cea mai mare treapta permisa (max 4 Mbps)
    m = need_media(u, q("SELECT * FROM media WHERE id=?", (int(d["media_id"]),), one=True))
    if not m:
        raise HTTPException(404)
    if not os.path.exists(m["path"]):
        raise HTTPException(404, "Fișierul nu mai există pe disc")
    info = json.loads(m["probe"] or "{}") or ffprobe(m["path"]) or {}
    # daca probe-ul din DB nu are audio, re-ruleaza ffprobe live si actualizeaza DB
    if not info.get("audio") and m["path"] and Path(m["path"]).exists():
        fresh = ffprobe(m["path"])
        if fresh and fresh.get("audio"):
            info = fresh
            x("UPDATE media SET probe=? WHERE id=?", (json.dumps(fresh), m["id"]))
    start = max(0.0, float(d.get("start") or 0))
    audio = info.get("audio", [])
    a_idx = d.get("audio")
    if a_idx is None and audio:
        # preferinta: romana, apoi default, apoi prima
        pick = next((a for a in audio if is_ro(a["lang"])), None) or next((a for a in audio if a["default"]), None) or audio[0]
        a_idx = pick["index"]
    v = info.get("video") or {}
    fmt = info.get("format", "")
    ext = Path(m["path"]).suffix.lower()
    first_audio = audio[0]["index"] if audio else None
    sel_audio = next((a for a in audio if a["index"] == a_idx), None)
    direct = (not ql and not d.get("force_transcode") and ext in (".mp4", ".m4v", ".webm", ".mov") and ("mp4" in fmt or "webm" in fmt)
              and v.get("codec") in ("h264", "vp9", "vp8") and v.get("pix_fmt") in ("yuv420p", "yuvj420p")
              and (not audio or (a_idx == first_audio and sel_audio and sel_audio["codec"] in ("aac", "mp3", "opus", "vorbis")))
              and (v.get("height") or 0) <= int(S("max_height") or 1080) + 8)
    base = {"media_id": m["id"], "duration": m["duration"] or info.get("duration") or 0,
            "audio": [{"index": a["index"], "label": LANG_NAMES.get(a["lang"], a["lang"].upper()) + (f" – {a['title']}" if a["title"] else "")
                       + f" ({a['channels']}ch)", "lang": a["lang"]} for a in audio], "audio_index": a_idx,
            "remote": remote, "quality": ql[0] if ql else "orig",
            "qualities": ([] if remote else [{"key": "orig", "label": "Original"}]) + [{"key": x[0], "label": x[4]} for x in allowed]}
    ua = req.headers.get("user-agent") or ""
    common = dict(media=m["id"], remote=remote, ip=client_ip(req), user=u["username"], ua=ua, device=device_name(ua), title=media_title(m),
                  item_id=m["item_id"], img=None, duration=base["duration"], pos=start, paused=False, last_ping=time.time(),
                  audio_label=next((a_["label"] for a_ in base["audio"] if a_["index"] == a_idx), "—"))
    it_ = q("SELECT poster, backdrop FROM items WHERE id=?", (m["item_id"],), one=True)
    common["img"] = m["still"] or (it_["backdrop"] if it_ else None) or (it_["poster"] if it_ else None)
    STOP_REQ.discard((u["id"], client))
    if direct:
        lid, st0 = log_play(u, client, m, remote, ua, "direct", "orig", start)
        x("UPDATE play_log SET ip=? WHERE id=?", (client_ip(req), lid))
        touch_active(u["id"], client, method="direct", quality="orig", log_id=lid, started=st0,
                     details=playback_details(m, info, a_idx, "direct", "", None, remote), **common)
        return dict(base, mode="direct", url=f"/api/stream/{m['id']}", offset=0, start=start, method="direct")
    s, st = start_session(m, start, a_idx, u["id"], client, bool(d.get("force_transcode")), ql)
    s.remote = remote
    lid, st0 = log_play(u, client, m, remote, ua, f"{s.method}/{s.hw}", s.quality, start)
    x("UPDATE play_log SET ip=?, method=?, quality=? WHERE id=?", (client_ip(req), f"{s.method}/{s.hw}", s.quality, lid))
    touch_active(u["id"], client, method=f"{s.method}/{s.hw}", quality=s.quality, log_id=lid, started=st0,
                 details=playback_details(m, info, a_idx, s.method, s.hw, ql, remote), **common)
    return dict(base, mode="hls", url=f"/api/hls/{s.sid}/index.m3u8", sid=s.sid, offset=st, start=start, method=f"{s.method}/{s.hw}")


@app.post("/api/play/stop")
async def stop_client(req: Request):
    u = need_user(req)
    d = await req.json()
    with ALOCK:
        e = ACTIVE.pop((u["id"], str(d.get("client") or "")), None)
    if e and e.get("log_id"):
        x("UPDATE play_log SET ended=? WHERE id=?", (time.time(), e["log_id"]))
    return {"ok": True}


@app.delete("/api/play/{sid}")
def stop_play(sid: str, req: Request):
    need_user(req)
    with SLOCK:
        s = SESSIONS.pop(sid, None)
    if s:
        s.kill()
    return {"ok": True}


@app.get("/api/hls/{sid}/{name}")
def hls(sid: str, name: str, req: Request):
    need_user(req)
    s = SESSIONS.get(sid)
    if not s or not re.fullmatch(r"index\.m3u8|s\d{5}\.ts", name):
        raise HTTPException(404)
    s.last = time.time()
    with ALOCK:
        e = ACTIVE.get((s.user_id, s.client))
        if e:
            e["t"] = s.last
    p = s.dir / name
    if name.endswith(".ts"):
        n = int(name[1:6])
        s.req_seg = max(s.req_seg, n) if n >= s.req_seg - 5 else n
        if s.stopped and n + 20 >= len(list(s.dir.glob("s*.ts"))):
            try:
                proc_pause(s.proc, False)
                s.stopped = False
            except Exception:
                pass
        for _ in range(100):
            if p.exists():
                break
            time.sleep(0.1)
        if not p.exists():
            raise HTTPException(404)
        try:
            note_bytes(s.user_id, client=s.client, n=p.stat().st_size)
        except Exception:
            pass
        return FileResponse(p, media_type="video/mp2t", headers={"Cache-Control": "no-cache"})
    return Response(p.read_text(errors="ignore"), media_type="application/vnd.apple.mpegurl", headers={"Cache-Control": "no-cache"})


@app.get("/api/stream/{media_id}")
def stream(media_id: int, req: Request):
    u = need_user(req)
    if is_remote(req):
        raise HTTPException(403, "Redarea directă e permisă doar în rețeaua locală")
    m = need_media(u, q("SELECT path FROM media WHERE id=?", (media_id,), one=True))
    if not m or not os.path.exists(m["path"]):
        raise HTTPException(404)
    ext = Path(m["path"]).suffix.lower()
    mt = {".mp4": "video/mp4", ".m4v": "video/mp4", ".webm": "video/webm", ".mov": "video/mp4"}.get(ext, "application/octet-stream")
    return FileResponse(m["path"], media_type=mt)


# ---------------------------------------------------------------- descarcare
DL_ACTIVE = {}
DL_LOCK = threading.Lock()


def download_mode(req, u):
    """full = viteza maxima (LAN) · throttled = extern, limitat la bitrate-ul utilizatorului · none = interzis"""
    mode = S("download_mode")
    if mode == "off" or not u["can_download"]:
        return "none"
    if not is_remote(req):
        return "full"
    if mode == "lan" or S("remote_enabled") != "1" or not u["remote_ok"]:
        return "none"
    return "throttled"


@app.get("/api/download/{media_id}")
async def download(media_id: int, req: Request):
    u = need_user(req)
    mode = download_mode(req, u)
    if mode == "none":
        raise HTTPException(403, "Descărcarea nu este permisă pentru contul tău din această rețea")
    m = need_media(u, q("SELECT m.*, i.title AS it_title, i.year, i.kind FROM media m JOIN items i ON i.id=m.item_id WHERE m.id=?", (media_id,), one=True))
    if not m or not os.path.exists(m["path"]):
        raise HTTPException(404, "Fișierul nu mai există pe disc")
    ext = Path(m["path"]).suffix.lower()
    if m["kind"] == "series":
        nice = f"{m['it_title']} - S{(m['season'] or 0):02d}E{(m['episode'] or 0):02d}" + (f" - {m['ep_title']}" if m["ep_title"] else "")
    else:
        nice = f"{m['it_title']}" + (f" ({m['year']})" if m["year"] else "")
    nice = re.sub(r'[\\/:*?"<>|]+', " ", nice).strip() + ext
    import unicodedata
    ascii_ = unicodedata.normalize("NFKD", nice).encode("ascii", "ignore").decode() or f"video{ext}"
    disp = f"attachment; filename=\"{ascii_}\"; filename*=UTF-8''{quote(nice)}"
    log.info("Descarcare %s: %s (%s)", u["username"], nice, mode)
    if mode == "full":
        return FileResponse(m["path"], media_type="application/octet-stream", headers={"Content-Disposition": disp})
    # extern: limitat la treapta maxima permisa utilizatorului (max 4 Mbps), o singura descarcare simultana
    bps = allowed_qualities(True, u)[0][1]
    with DL_LOCK:
        if DL_ACTIVE.get(u["id"], 0) >= 1:
            raise HTTPException(429, "Ai deja o descărcare în curs din afara rețelei locale")
        DL_ACTIVE[u["id"]] = DL_ACTIVE.get(u["id"], 0) + 1
    size = os.path.getsize(m["path"])
    start, end, status = 0, size - 1, 200
    rng = re.match(r"bytes=(\d*)-(\d*)", req.headers.get("range", ""))
    if rng and (rng.group(1) or rng.group(2)):
        if rng.group(1):
            start = int(rng.group(1))
            end = min(int(rng.group(2)), size - 1) if rng.group(2) else size - 1
        else:
            start = max(0, size - int(rng.group(2)))
        if start >= size:
            with DL_LOCK:
                DL_ACTIVE[u["id"]] -= 1
            raise HTTPException(416)
        status = 206
    rate = bps * 0.97 / 8

    async def gen():
        sent, t0 = 0, time.monotonic()
        try:
            with open(m["path"], "rb") as f:
                f.seek(start)
                left = end - start + 1
                while left > 0:
                    data = f.read(min(65536, left))
                    if not data:
                        break
                    yield data
                    sent += len(data)
                    left -= len(data)
                    ahead = sent / rate - (time.monotonic() - t0)
                    if ahead > 0:
                        await asyncio.sleep(ahead)
        finally:
            with DL_LOCK:
                DL_ACTIVE[u["id"]] = max(0, DL_ACTIVE.get(u["id"], 1) - 1)
    headers = {"Content-Disposition": disp, "Accept-Ranges": "bytes", "Content-Length": str(end - start + 1)}
    if status == 206:
        headers["Content-Range"] = f"bytes {start}-{end}/{size}"
    return StreamingResponse(gen(), status_code=status, media_type="application/octet-stream", headers=headers)


@app.post("/api/progress")
async def progress(req: Request):
    u = need_user(req)
    try:
        d = await req.json()
    except Exception:
        d = json.loads((await req.body()) or b"{}")
    pos, dur = float(d.get("position") or 0), float(d.get("duration") or 0)
    stop, e = False, None
    if d.get("client"):
        key = (u["id"], str(d["client"]))
        if key in STOP_REQ:
            STOP_REQ.discard(key)
            stop = True
        now = time.time()
        with ALOCK:
            e = ACTIVE.get(key)
            if e:
                if not e.get("paused"):
                    e["watched_add"] = min(15.0, now - e.get("last_ping", now))
                else:
                    e["watched_add"] = 0
                e.update(t=now, last_ping=now, pos=pos, paused=bool(d.get("paused")))
                if "sub" in d:
                    sid_ = d.get("sub")
                    e["sub_label"] = (q("SELECT label FROM subtitles WHERE id=?", (int(sid_),), one=True) or {"label": "—"})["label"] if sid_ else "Fără"
        if e and e.get("log_id"):
            x("UPDATE play_log SET ended=?, last_pos=?, watched=watched+? WHERE id=?", (now, pos, e.get("watched_add", 0), e["log_id"]))
    watched = 1 if dur and (pos / dur > 0.93 or dur - pos < 90 and pos / dur > 0.8) else 0
    x("""INSERT INTO progress(user_id,media_id,position,duration,watched,updated) VALUES(?,?,?,?,?,?)
         ON CONFLICT(user_id,media_id) DO UPDATE SET position=excluded.position, duration=excluded.duration, watched=excluded.watched, updated=excluded.updated""",
      (u["id"], int(d["media_id"]), 0 if watched else pos, dur, watched, time.time()))
    return {"ok": True, "watched": bool(watched), "stop": stop}


@app.post("/api/watched/{media_id}")
async def mark_watched(media_id: int, req: Request):
    u = need_user(req)
    d = await req.json()
    if d.get("watched"):
        x("INSERT OR REPLACE INTO progress(user_id,media_id,position,duration,watched,updated) VALUES(?,?,0,0,1,?)", (u["id"], media_id, time.time()))
    else:
        x("DELETE FROM progress WHERE user_id=? AND media_id=?", (u["id"], media_id))
    return {"ok": True}


@app.get("/api/media/{media_id}/next")
def next_media(media_id: int, req: Request):
    u = need_user(req)
    m = need_media(u, q("SELECT * FROM media WHERE id=?", (media_id,), one=True))
    if not m or m["season"] is None:
        return {"next": None}
    n = q("SELECT * FROM media WHERE item_id=? AND (season>? OR (season=? AND episode>?)) ORDER BY season, episode LIMIT 1",
          (m["item_id"], m["season"], m["season"], m["episode"]), one=True)
    return {"next": {"id": n["id"], "season": n["season"], "episode": n["episode"], "title": n["ep_title"] or f"Episodul {n['episode']}",
                     "still": n["still"]} if n else None}


_EP_CACHE = {}


def tmdb_episode(tid, sn, en):
    key = (tid, sn, en)
    c = _EP_CACHE.get(key)
    if c and time.time() - c[0] < 86400:
        return c[1]
    d = tmdb.get(f"/tv/{tid}/season/{sn}/episode/{en}", language="ro-RO", append_to_response="credits") or {}
    out = {}
    if d:
        crew = d.get("crew") or (d.get("credits") or {}).get("crew") or []
        guests = d.get("guest_stars") or (d.get("credits") or {}).get("guest_stars") or []
        out = {"rating": d.get("vote_average") or None, "votes": d.get("vote_count") or 0,
               "directors": list(dict.fromkeys(c_["name"] for c_ in crew if c_.get("job") == "Director")),
               "writers": list(dict.fromkeys(c_["name"] for c_ in crew if c_.get("job") in ("Writer", "Screenplay", "Teleplay", "Story"))),
               "guests": [{"name": g.get("name"), "character": g.get("character"), "profile": g.get("profile_path")} for g in guests[:12]],
               "runtime": d.get("runtime")}
    _EP_CACHE[key] = (time.time(), out)
    return out


@app.get("/api/media/{media_id}/details")
def media_details(media_id: int, req: Request):
    u = need_user(req)
    m = need_media(u, q("SELECT m.*, i.title AS it_title, i.kind, i.tmdb_id, i.logo, i.backdrop, i.id AS iid FROM media m JOIN items i ON i.id=m.item_id WHERE m.id=?",
                        (media_id,), one=True))
    if not m:
        raise HTTPException(404)
    d = media_dict(m, u["id"])
    info = json.loads(m["probe"] or "{}") or {}
    v = info.get("video") or {}
    d.update(item_id=m["iid"], series=m["it_title"], logo=m["logo"], backdrop=m["backdrop"],
             poster=(q("SELECT poster FROM items WHERE id=?", (m["iid"],), one=True) or {"poster": None})["poster"],
             nice_title=m["it_title"],
             nice_sub=(f"S{m['season']}:E{m['episode']}" + (f" · {m['ep_title']}" if m["ep_title"] else "")) if m["kind"] == "series" else "",
             video=(f"{v.get('width')}×{v.get('height')} · {(v.get('codec') or '').upper()}" + (" · 10-bit" if "10" in (v.get("pix_fmt") or "") else "")) if v else "",
             size=m["size"] or 0,
             audio=[LANG_NAMES.get(a_["lang"], a_["lang"].upper()) + (f" – {a_['title']}" if a_["title"] else "") + f" ({a_['channels']}ch, {(a_['codec'] or '').upper()})"
                    for a_ in info.get("audio", [])],
             subs=[r["label"] for r in q("SELECT label FROM subtitles WHERE media_id=? ORDER BY (lang='ro') DESC, id", (media_id,))])
    sib = q("SELECT id, season, episode, ep_title FROM media WHERE item_id=? ORDER BY season, episode, path", (m["item_id"],))
    ids = [r["id"] for r in sib]
    i_ = ids.index(media_id) if media_id in ids else -1
    fmt = lambda r: {"id": r["id"], "label": f"S{r['season']}:E{r['episode']}" + (f" – {r['ep_title']}" if r["ep_title"] else "")} if r else None
    d["prev"] = fmt(sib[i_ - 1]) if i_ > 0 else None
    d["next"] = fmt(sib[i_ + 1]) if 0 <= i_ < len(sib) - 1 else None
    d["extra"] = {}
    if m["kind"] == "series" and m["tmdb_id"] and m["season"] is not None and m["episode"] is not None and S("tmdb_key"):
        try:
            d["extra"] = tmdb_episode(m["tmdb_id"], m["season"], m["episode"])
        except Exception as e:
            log.warning("TMDB episod: %s", e)
    return d


@app.get("/api/media/{media_id}/info")
def media_info(media_id: int, req: Request):
    u = need_user(req)
    m = need_media(u, q("SELECT m.*, i.title as it_title, i.kind, i.logo FROM media m JOIN items i ON i.id=m.item_id WHERE m.id=?", (media_id,), one=True))
    if not m:
        raise HTTPException(404)
    sub = f"S{m['season']}:E{m['episode']} „{m['ep_title'] or ''}”" if m["kind"] == "series" else ""
    return {"id": m["id"], "item_id": m["item_id"], "title": m["it_title"], "subtitle": sub, "kind": m["kind"]}


@app.get("/api/media/{media_id}/subs")
def list_subs(media_id: int, req: Request):
    need_user(req)
    rows = q("SELECT * FROM subtitles WHERE media_id=? ORDER BY (lang='ro') DESC, source, id", (media_id,))
    return {"subs": [{"id": r["id"], "lang": r["lang"], "label": r["label"], "source": r["source"]} for r in rows],
            "can_search": opensubs.enabled() or subsro.enabled()}


def sub_text(sub_id):
    r = q("SELECT s.*, m.path as mpath FROM subtitles s JOIN media m ON m.id=s.media_id WHERE s.id=?", (sub_id,), one=True)
    if not r:
        raise HTTPException(404)
    if r["source"] == "embedded":
        out = SUBS / f"emb_{r['media_id']}_{r['stream_index']}.vtt"
        if not out.exists():
            tmp = out.with_suffix(".tmp.vtt")
            subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", r["mpath"], "-map", f"0:{r['stream_index']}",
                            "-f", "webvtt", str(tmp)], capture_output=True, timeout=600)
            if not tmp.exists():
                raise HTTPException(500, "Nu am putut extrage subtitrarea")
            tmp.write_text(decode_sub(tmp.read_bytes()), encoding="utf-8")
            tmp.rename(out)
        return out.read_text(encoding="utf-8")
    if r["source"] == "local":
        p = Path(r["path"])
        if not p.exists():
            raise HTTPException(404)
        if p.suffix.lower() in (".ass", ".ssa"):
            out = SUBS / f"loc_{r['id']}.vtt"
            if not out.exists() or out.stat().st_mtime < p.stat().st_mtime:
                subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-sub_charenc", "UTF-8", "-i", str(p), "-f", "webvtt", str(out)],
                               capture_output=True, timeout=60)
            return out.read_text(encoding="utf-8", errors="replace")
        return to_vtt(decode_sub(p.read_bytes()))
    return Path(r["path"]).read_text(encoding="utf-8")


@app.get("/api/subs/{sub_id}.vtt")
def get_sub(sub_id: int, req: Request):
    u = need_user(req)
    need_media(u, q("SELECT m.path FROM subtitles s JOIN media m ON m.id=s.media_id WHERE s.id=?", (sub_id,), one=True), "Subtitrarea")
    return PlainTextResponse(sub_text(sub_id), media_type="text/vtt; charset=utf-8")


@app.post("/api/media/{media_id}/subs/search")
def subs_search(media_id: int, req: Request):
    u = need_user(req)
    need_media(u, q("SELECT path FROM media WHERE id=?", (media_id,), one=True))
    if not opensubs.enabled() and not subsro.enabled():
        raise HTTPException(400, "Nicio sursă de subtitrări configurată (Admin → Setări → OpenSubtitles sau Subs.ro)")
    os_results = opensubs.search(media_id) if opensubs.enabled() else []
    sr_results = []
    if subsro.enabled():
        for r in subsro.search(media_id):
            sr_results.append({"file_id": None, "subtitle_id": r["subtitle_id"],
                                "download_url": r["download_url"],
                                "file_name": r["title"], "release": r["description"],
                                "downloads": 0, "hash_match": False, "hi": False,
                                "ai": False, "trusted": True, "fps": None, "source": "subsro"})
    results = [dict(r, source="opensubtitles") for r in os_results] + sr_results
    return {"results": results, "remaining": opensubs.remaining, "error": opensubs.last_error}


@app.post("/api/media/{media_id}/subs/download")
async def subs_download(media_id: int, req: Request):
    need_user(req)
    d = await req.json()
    source = d.get("source", "opensubtitles")
    if source == "subsro":
        r = subsro.download(media_id, d["subtitle_id"], d["download_url"])
        return {"sub": {"id": r["id"], "lang": r["lang"], "label": r["label"], "source": r["source"]}, "remaining": None}
    r = opensubs.download(media_id, int(d["file_id"]), (d.get("release") or "")[:60])
    return {"sub": {"id": r["id"], "lang": r["lang"], "label": r["label"], "source": r["source"]}, "remaining": opensubs.remaining}


@app.delete("/api/subs/{sub_id}")
def del_sub(sub_id: int, req: Request):
    need_admin(req)
    r = q("SELECT * FROM subtitles WHERE id=?", (sub_id,), one=True)
    if r and r["source"] == "opensubtitles":
        Path(r["path"]).unlink(missing_ok=True)
        x("DELETE FROM subtitles WHERE id=?", (sub_id,))
    return {"ok": True}


@app.get("/img/{size}/{name}")
def img(size: str, name: str, req: Request):
    need_user(req)
    p = img_file(size, name)
    mt = "image/png" if name.endswith(".png") else "image/svg+xml" if name.endswith(".svg") else "image/jpeg"
    return FileResponse(p, media_type=mt, headers={"Cache-Control": "max-age=2592000"})


def img_file(size, name):
    if size not in TMDB_IMG_SIZES or not re.fullmatch(r"[A-Za-z0-9_\-]+\.(jpg|png|svg|jpeg)", name):
        raise HTTPException(404)
    p = IMG / f"{size}_{name}"
    if not p.exists():
        try:
            r = httpx.get(f"https://image.tmdb.org/t/p/{size}/{name}", timeout=20, follow_redirects=True)
            r.raise_for_status()
            tmp = p.with_suffix(p.suffix + ".tmp")
            tmp.write_bytes(r.content)
            tmp.rename(p)
        except Exception:
            raise HTTPException(404)
    return p


# ---------------------------------------------------------------- Google Cast (serverul comanda Chromecast-ul)
HTTP_PORT = int(os.environ.get("CINEVERSE_PORT", "8200"))
CAST = {"ok": False, "err": "", "browser": None, "zconf": None}
CAST_CC = {}        # uuid -> Chromecast conectat
CAST_ACTIVE = {}    # user_id -> redarea curenta pe TV
CAST_STREAMS = {}   # token -> CastStream
CAST_LOCK = threading.RLock()
SEG = 6.0           # durata unui segment HLS pentru Cast


def cast_hosts():
    return [h for h in re.split(r"[\s,;]+", S("cast_hosts") or "") if re.fullmatch(r"[0-9a-fA-F.:]+|[A-Za-z0-9.-]+", h)]


def cast_init():
    try:
        import zeroconf
        from pychromecast.discovery import CastBrowser, SimpleCastListener
        if CAST.get("browser"):
            try:
                CAST["browser"].stop_discovery()
                CAST["zconf"].close()
            except Exception:
                pass
        zc = zeroconf.Zeroconf()
        hosts = cast_hosts()
        br = CastBrowser(SimpleCastListener(), zc, known_hosts=hosts or None)
        br.start_discovery()
        CAST.update(ok=True, browser=br, zconf=zc, err="")
        log.info("Google Cast: caut dispozitive în rețea (mDNS%s)", f" + {', '.join(hosts)}" if hosts else "")
    except Exception as e:
        CAST.update(ok=False, err=str(e))
        log.warning("Google Cast indisponibil: %s", e)


def cast_devices():
    if not CAST["ok"]:
        return []
    out = []
    for uuid, ci in list(CAST["browser"].devices.items()):
        if (getattr(ci, "cast_type", None) or "cast") != "cast":
            continue   # fara boxe audio / grupuri
        out.append({"id": str(uuid), "name": ci.friendly_name, "model": ci.model_name or "", "host": ci.host})
    return sorted(out, key=lambda d: d["name"].lower())


def cast_cc(dev_id):
    import pychromecast
    with CAST_LOCK:
        cc = CAST_CC.get(dev_id)
        if cc is not None and cc.socket_client.is_connected:
            return cc
        info = next((ci for u, ci in CAST["browser"].devices.items() if str(u) == dev_id), None)
        if not info:
            raise HTTPException(404, "Dispozitivul Cast nu mai este disponibil")
        cc = pychromecast.get_chromecast_from_cast_info(info, CAST["zconf"])
        cc.wait(timeout=12)
        CAST_CC[dev_id] = cc
        return cc


def local_ip_for(host):
    s_ = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s_.connect((host, 8009))
        return s_.getsockname()[0]
    finally:
        s_.close()


class CastStream:
    """HLS 'VOD' sintetic pentru Chromecast: playlist complet (0..durata), segmente de 6s generate la cerere.
    La un salt departe, ffmpeg reporneste exact de la segmentul cerut (timestamp-uri aliniate)."""
    def __init__(self, token, media, info, audio_index, user_id, sub_id):
        self.token, self.media, self.info, self.audio, self.user_id, self.sub_id = token, media, info, audio_index, user_id, sub_id
        self.dir = TRANS / f"cast_{token}"
        self.dir.mkdir(parents=True, exist_ok=True)
        self.duration = float(media["duration"] or info.get("duration") or 0)
        self.nseg = max(1, math.ceil(self.duration / SEG))
        self.proc, self.run_start, self.req = None, 0, 0
        self.last = time.time()
        self.stopped = False
        self.lock = threading.Lock()
        self.method = ""

    def seg_path(self, n):
        return self.dir / f"s{n:05d}.ts"

    def kill(self):
        if self.proc and self.proc.poll() is None:
            try:
                proc_pause(self.proc, False)
                self.proc.terminate()
                self.proc.wait(5)
            except Exception:
                try:
                    self.proc.kill()
                except Exception:
                    pass
        self.proc = None

    def start_at(self, n):
        self.kill()
        t = n * SEG
        v = self.info.get("video") or {}
        is_hdr = bool(v.get("hdr")) and S("tonemap") == "1"
        plans = ([(HW["mode"], "hw")] + ([("vaapi", "sw")] if is_hdr and HW["mode"] == "vaapi" else [])) if HW["mode"] != "none" else []
        plans.append(("none", "sw"))
        err = ""
        for hw, tm in plans:
            cmd = build_cmd(self.media["path"], self.info, t, self.audio, "transcode", hw, None, tm)
            k = cmd.index("-start_number")
            cmd[k + 1] = str(n)
            cmd[k:k] = ["-output_ts_offset", f"{t:.3f}", "-muxdelay", "0", "-muxpreload", "0", "-hls_flags", "temp_file+independent_segments"]
            cmd += ["-hls_segment_filename", str(self.dir / "s%05d.ts"), str(self.dir / "ffmpeg.m3u8")]
            logf = open(self.dir / "ffmpeg.log", "wb")
            self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=logf, **popen_kw())
            self.run_start, self.stopped, self.method = n, False, f"transcode/{hw}"
            t0 = time.time()
            while time.time() - t0 < 40:
                if self.seg_path(n).exists():
                    log.info("Cast %s: segmentul %d pornit (%s)", self.token[:6], n, self.method)
                    return True
                if self.proc.poll() is not None:
                    break
                time.sleep(0.15)
            err = (self.dir / "ffmpeg.log").read_text(errors="ignore")[-400:]
            self.kill()
        log.warning("Cast: transcodare esuata: %s", err)
        return False

    def produced_max(self):
        n = self.run_start
        while self.seg_path(n + 1).exists():
            n += 1
        return n

    def get_segment(self, n):
        self.last = time.time()
        if n < 0 or n >= self.nseg:
            return None
        p = self.seg_path(n)
        with self.lock:
            self.req = n
            if not p.exists():
                running = self.proc is not None and self.proc.poll() is None
                if not (running and self.run_start <= n <= self.produced_max() + 4):
                    self.start_at(n)          # salt: repornim exact de la segmentul cerut
            if self.stopped and self.proc and n + 8 >= self.produced_max():
                try:
                    proc_pause(self.proc, False)
                    self.stopped = False
                except Exception:
                    pass
        for _ in range(250):
            if p.exists():
                return p
            if self.proc is None or self.proc.poll() is not None:
                break
            time.sleep(0.1)
        return p if p.exists() else None

    def playlist(self):
        out = ["#EXTM3U", "#EXT-X-VERSION:3", f"#EXT-X-TARGETDURATION:{int(SEG) + 1}", "#EXT-X-MEDIA-SEQUENCE:0",
               "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS"]
        for n in range(self.nseg):
            d = min(SEG, self.duration - n * SEG)
            out += [f"#EXTINF:{max(0.1, d):.3f},", f"s{n:05d}.ts"]
        out.append("#EXT-X-ENDLIST")
        return "\n".join(out) + "\n"

    def cleanup(self):
        self.kill()
        shutil.rmtree(self.dir, ignore_errors=True)


def cast_janitor():
    while True:
        time.sleep(3)
        now = time.time()
        active_tokens = {a["token"] for a in CAST_ACTIVE.values()}
        for tok, st in list(CAST_STREAMS.items()):
            if tok not in active_tokens and now - st.last > 180:
                st.cleanup()
                CAST_STREAMS.pop(tok, None)
                continue
            if st.proc and st.proc.poll() is None:   # nu transcoda prea mult inainte
                ahead = st.produced_max() - st.req
                try:
                    if ahead > 30 and not st.stopped:
                        st.stopped = proc_pause(st.proc, True)
                    elif ahead < 15 and st.stopped:
                        proc_pause(st.proc, False)
                        st.stopped = False
                except Exception:
                    pass
        # progres + episodul urmator
        for uid, a in list(CAST_ACTIVE.items()):
            try:
                cc = CAST_CC.get(a["device"])
                ms = cc.media_controller.status if cc else None
                if not ms:
                    continue
                if a.get("live"):
                    if a.get("log_id"):
                        dt_ = min(15.0, now - a.get("last_tick", now)) if ms.player_state == "PLAYING" else 0
                        a["last_tick"] = now
                        x("UPDATE play_log SET ended=?, watched=watched+? WHERE id=?", (now, dt_, a["log_id"]))
                    if ms.player_state == "IDLE" and a.get("started", now) < now - 20:
                        cast_stop(uid, quit_app=False)
                    continue
                pos = ms.adjusted_current_time or 0
                if a.get("log_id"):
                    dt_ = min(15.0, now - a.get("last_tick", now)) if ms.player_state == "PLAYING" else 0
                    a["last_tick"] = now
                    x("UPDATE play_log SET ended=?, last_pos=?, watched=watched+? WHERE id=?", (now, pos, dt_, a["log_id"]))
                if ms.player_state in ("PLAYING", "PAUSED", "BUFFERING") and pos > 5 and now - a.get("saved", 0) > 10:
                    save_progress(uid, a["media_id"], pos, a["duration"])
                    a["saved"], a["pos"] = now, pos
                if ms.player_state == "IDLE" and ms.idle_reason == "FINISHED" and a.get("started", now) < now - 20:
                    save_progress(uid, a["media_id"], a["duration"], a["duration"])
                    m = q("SELECT * FROM media WHERE id=?", (a["media_id"],), one=True)
                    nxt = m and m["season"] is not None and q("SELECT id FROM media WHERE item_id=? AND (season>? OR (season=? AND episode>?)) ORDER BY season, episode LIMIT 1",
                                                              (m["item_id"], m["season"], m["season"], m["episode"]), one=True)
                    if nxt:
                        log.info("Cast: episodul următor pe %s", a["device_name"])
                        cast_start(uid, a["device"], nxt["id"], 0, None, "auto")
                    else:
                        cast_stop(uid, quit_app=False)
                elif ms.player_state == "IDLE" and ms.idle_reason in ("CANCELLED", "INTERRUPTED", "ERROR") and a.get("started", now) < now - 20:
                    cast_stop(uid, quit_app=False)
            except Exception as e:
                log.warning("cast janitor: %s", e)


def save_progress(uid, media_id, pos, dur):
    watched = 1 if dur and (pos / dur > 0.93 or dur - pos < 90 and pos / dur > 0.8) else 0
    x("""INSERT INTO progress(user_id,media_id,position,duration,watched,updated) VALUES(?,?,?,?,?,?)
         ON CONFLICT(user_id,media_id) DO UPDATE SET position=excluded.position, duration=excluded.duration, watched=excluded.watched, updated=excluded.updated""",
      (uid, media_id, 0 if watched else pos, dur, watched, time.time()))


def pick_ro_sub(media_id, audio_lang):
    if is_ro(audio_lang or ""):
        return None
    r = q("SELECT id FROM subtitles WHERE media_id=? AND lang='ro' ORDER BY source='embedded', id LIMIT 1", (media_id,), one=True)
    return r["id"] if r else None


def cast_start(uid, dev_id, media_id, start, audio, sub_id):
    m = q("SELECT m.*, i.title AS it_title, i.kind, i.poster, i.backdrop, i.year FROM media m JOIN items i ON i.id=m.item_id WHERE m.id=?",
          (media_id,), one=True)
    if not m or not os.path.exists(m["path"]):
        raise HTTPException(404, "Fișierul nu există")
    info = json.loads(m["probe"] or "{}") or ffprobe(m["path"]) or {}
    auds = info.get("audio", [])
    if audio is None and auds:
        audio = (next((a_ for a_ in auds if is_ro(a_["lang"])), None) or next((a_ for a_ in auds if a_["default"]), None) or auds[0])["index"]
    alang = next((a_["lang"] for a_ in auds if a_["index"] == audio), "")
    if sub_id == "auto":
        sub_id = pick_ro_sub(media_id, alang)
    cc = cast_cc(dev_id)
    old = CAST_ACTIVE.get(uid)
    tok = secrets.token_urlsafe(18)
    st = CastStream(tok, m, info, audio, uid, sub_id)
    n0 = int(max(0, start) // SEG)
    if not st.start_at(n0):
        st.cleanup()
        raise HTTPException(500, "Transcodarea pentru Cast a eșuat")
    CAST_STREAMS[tok] = st
    base = f"http://{local_ip_for(cc.cast_info.host)}:{HTTP_PORT}/cast/{tok}"
    if m["kind"] == "series":
        title = f"{m['ep_title'] or ('Episodul ' + str(m['episode']))}"
        md = {"metadataType": 2, "seriesTitle": m["it_title"], "title": title, "season": m["season"], "episode": m["episode"]}
        full = f"{m['it_title']} – S{m['season']}:E{m['episode']} {m['ep_title'] or ''}".strip()
    else:
        title = m["it_title"]
        md = {"metadataType": 1, "title": title, **({"releaseDate": str(m["year"])} if m["year"] else {})}
        full = title
    img = m["still"] or m["backdrop"] or m["poster"]
    thumb = f"{base}/image.jpg" if img else None
    if thumb:
        md["images"] = [{"url": thumb}]
    mc = cc.media_controller
    kw = dict(title=title, thumb=thumb, current_time=max(0.0, float(start)), stream_type="BUFFERED", metadata=md,
              media_info={"hlsSegmentFormat": "ts", "hlsVideoSegmentFormat": "mpeg2_ts"})
    if sub_id:
        kw.update(subtitles=f"{base}/sub.vtt", subtitles_lang="ro-RO", subtitles_mime="text/vtt", subtitle_id=1)
    mc.play_media(f"{base}/index.m3u8", "application/x-mpegURL", **kw)
    mc.block_until_active(timeout=15)
    un = (q("SELECT username FROM users WHERE id=?", (uid,), one=True) or {"username": "?"})["username"]
    same = old and old.get("media_id") == media_id and old.get("log_id")
    lid = old["log_id"] if same else x("""INSERT INTO play_log(user_id,username,media_id,title,client,device,ip,remote,method,quality,started,ended,watched,last_pos,duration)
        VALUES(?,?,?,?,?,?,?,0,?,?,?,?,0,?,?)""", (uid, un, media_id, full, "cast", f"Chromecast · {cc.cast_info.friendly_name}", "rețea locală",
                                                   st.method, "LAN", time.time(), time.time(), start, st.duration))
    CAST_ACTIVE[uid] = {"log_id": lid, "last_tick": time.time(),
                        "device": dev_id, "device_name": cc.cast_info.friendly_name, "token": tok, "media_id": media_id, "item_id": m["item_id"],
                        "audio": audio, "sub_id": sub_id, "duration": st.duration, "title": full, "img": img, "started": time.time(), "pos": start}
    if old and old["token"] != tok:
        st_old = CAST_STREAMS.pop(old["token"], None)
        if st_old:
            st_old.cleanup()
    log.info("Cast: %s → %s (de la %.0fs)", full, cc.cast_info.friendly_name, start)
    return CAST_ACTIVE[uid]


def cast_stop(uid, quit_app=True):
    a = CAST_ACTIVE.pop(uid, None)
    if not a:
        return
    cc = CAST_CC.get(a["device"])
    try:
        if cc:
            ms = cc.media_controller.status
            if not a.get("live") and ms and ms.adjusted_current_time and ms.adjusted_current_time > 5:
                save_progress(uid, a["media_id"], ms.adjusted_current_time, a["duration"])
            if quit_app:
                cc.quit_app()
    except Exception as e:
        log.warning("cast stop: %s", e)
    st = CAST_STREAMS.pop(a["token"], None)
    if st:
        st.cleanup()
    LIVE_TOKENS.pop(a["token"], None)
    if a.get("log_id"):
        x("UPDATE play_log SET ended=? WHERE id=?", (time.time(), a["log_id"]))


def need_lan_user(req):
    u = need_user(req)
    if is_remote(req):
        raise HTTPException(403, "Google Cast e disponibil doar în rețeaua locală")
    return u


@app.get("/api/cast/devices")
def cast_list(req: Request):
    need_user(req)
    if is_remote(req):
        return {"available": False, "devices": []}
    return {"available": CAST["ok"], "devices": cast_devices(), "error": CAST["err"]}


@app.post("/api/cast/play")
async def cast_play(req: Request):
    u = need_lan_user(req)
    d = await req.json()
    need_media(u, q("SELECT path FROM media WHERE id=?", (int(d["media_id"]),), one=True))
    a = await asyncio.to_thread(cast_start, u["id"], str(d["device"]), int(d["media_id"]), float(d.get("start") or 0),
                                d.get("audio"), d.get("sub", "auto"))
    return {"ok": True, "device": a["device_name"]}


@app.get("/api/cast/status")
def cast_status(req: Request):
    u = need_user(req)
    a = CAST_ACTIVE.get(u["id"])
    if not a:
        return {"active": False}
    cc = CAST_CC.get(a["device"])
    ms = cc.media_controller.status if cc else None
    if a.get("live"):
        return {"active": True, "live": True, "device": a["device"], "device_name": a["device_name"], "channel": a["channel"],
                "title": a["title"], "logo": a.get("logo"), "state": (ms.player_state if ms else "UNKNOWN"), "duration": 0, "position": 0,
                "volume": (cc.status.volume_level if cc and cc.status else 1), "muted": bool(cc and cc.status and cc.status.volume_muted),
                "subs": [], "sub_id": None, "img": None}
    subs = [{"id": r["id"], "label": r["label"]} for r in q("SELECT id,label FROM subtitles WHERE media_id=? ORDER BY (lang='ro') DESC, id", (a["media_id"],))]
    st = CAST_STREAMS.get(a["token"])
    info = st.info if st else {}
    return {"active": True, "device": a["device"], "device_name": a["device_name"], "media_id": a["media_id"], "item_id": a["item_id"],
            "title": a["title"], "img": a["img"], "duration": a["duration"],
            "position": (ms.adjusted_current_time if ms and ms.adjusted_current_time is not None else a.get("pos", 0)),
            "state": (ms.player_state if ms else "UNKNOWN"),
            "volume": (cc.status.volume_level if cc and cc.status else 1), "muted": bool(cc and cc.status and cc.status.volume_muted),
            "sub_id": a["sub_id"], "subs": subs, "audio": a["audio"],
            "audios": [{"index": x_["index"], "label": LANG_NAMES.get(x_["lang"], x_["lang"].upper())} for x_ in info.get("audio", [])]}


@app.post("/api/cast/control")
async def cast_control(req: Request):
    u = need_lan_user(req)
    d = await req.json()
    a = CAST_ACTIVE.get(u["id"])
    act = d.get("action")
    if not a:
        return {"ok": False}
    cc = CAST_CC.get(a["device"])
    mc = cc.media_controller if cc else None
    if act == "stop":
        await asyncio.to_thread(cast_stop, u["id"])
    elif act == "pause":
        await asyncio.to_thread(mc.pause)
    elif act == "play":
        await asyncio.to_thread(mc.play)
    elif act in ("seek", "sub", "audio") and a.get("live"):
        pass
    elif act == "seek":
        await asyncio.to_thread(mc.seek, max(0.0, min(float(d["pos"]), a["duration"] - 2)))
    elif act == "volume":
        await asyncio.to_thread(cc.set_volume, max(0.0, min(1.0, float(d["value"]))))
    elif act == "mute":
        await asyncio.to_thread(cc.set_volume_muted, bool(d.get("value")))
    elif act in ("sub", "audio"):   # reincarcam la pozitia curenta cu alta subtitrare / pista audio
        pos = (mc.status.adjusted_current_time if mc and mc.status else a.get("pos", 0)) or 0
        sub = (int(d["value"]) if d.get("value") else None) if act == "sub" else a["sub_id"]
        aud = int(d["value"]) if act == "audio" else a["audio"]
        await asyncio.to_thread(cast_start, u["id"], a["device"], a["media_id"], pos, aud, sub)
    return {"ok": True}


# ---- rutele citite de Chromecast (fara cookie; acces prin token temporar, CORS deschis)
CORS = {"Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "*", "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
        "Cache-Control": "no-cache"}


def _cast_stream(token):
    st = CAST_STREAMS.get(token)
    if not st:
        raise HTTPException(404)
    st.last = time.time()
    return st


@app.options("/cast/{token}/{name}")
def cast_options(token: str, name: str):
    return Response(status_code=204, headers=CORS)


@app.get("/cast/{token}/{name}")
def cast_file(token: str, name: str):
    st = _cast_stream(token)
    if name == "index.m3u8":
        return Response(st.playlist(), media_type="application/vnd.apple.mpegurl", headers=CORS)
    m = re.fullmatch(r"s(\d{5})\.ts", name)
    if m:
        p = st.get_segment(int(m.group(1)))
        if not p:
            raise HTTPException(404)
        return FileResponse(p, media_type="video/mp2t", headers=CORS)
    if name == "sub.vtt" and st.sub_id:
        return PlainTextResponse(sub_text(st.sub_id), media_type="text/vtt; charset=utf-8", headers=CORS)
    if name == "image.jpg":
        a = next((v for v in CAST_ACTIVE.values() if v["token"] == token), None)
        if a and a.get("img"):
            return FileResponse(img_file("w780", a["img"].lstrip("/")), media_type="image/jpeg", headers=CORS)
    raise HTTPException(404)


# ---------------------------------------------------------------- TV LIVE
LIVE = {}            # (channel_id, variant) -> LiveSession
LIVE_LOCK = threading.RLock()
LIVE_TOKENS = {}     # token Chromecast -> (channel_id, variant)
EPG_STATE = {"running": False, "last": 0, "count": 0, "err": ""}
CH_CHECK_STATE = {"running": False, "last": 0, "done": 0, "total": 0, "disabled": 0, "err": ""}


def live_probe(url, ua=""):
    cmd = ["ffprobe", "-v", "error", "-print_format", "json", "-show_streams", "-analyzeduration", "6000000", "-probesize", "6000000"]
    if url.startswith("http"):
        cmd += ["-rw_timeout", "10000000"] + (["-user_agent", ua] if ua else [])
    try:
        out = subprocess.run(cmd + [url], capture_output=True, timeout=25).stdout
        d = json.loads(out or b"{}")
    except Exception as e:
        return {"ok": False, "error": str(e)}
    v = next((x_ for x_ in d.get("streams", []) if x_.get("codec_type") == "video" and not (x_.get("disposition") or {}).get("attached_pic")), None)
    a = next((x_ for x_ in d.get("streams", []) if x_.get("codec_type") == "audio"), None)
    if not v and not a:
        return {"ok": False, "error": "Nu am putut citi stream-ul (verifică URL-ul)"}
    return {"ok": True, "vcodec": (v or {}).get("codec_name"), "width": (v or {}).get("width"), "height": (v or {}).get("height"),
            "pix_fmt": (v or {}).get("pix_fmt"), "acodec": (a or {}).get("codec_name"), "channels": (a or {}).get("channels"), "t": time.time()}


def ch_probe(ch):
    pr = json.loads(ch["probe"] or "{}") if ch["probe"] else {}
    if not pr.get("ok") or time.time() - pr.get("t", 0) > 86400:
        pr = live_probe(ch["url"], ch["ua"])
        if pr.get("ok"):
            x("UPDATE live_channels SET probe=? WHERE id=?", (json.dumps(pr), ch["id"]))
    return pr


class LiveSession:
    """Un singur ffmpeg per canal + varianta de calitate, oricati spectatori. Reporneste singur daca sursa cade."""
    def __init__(self, ch, variant):
        self.ch, self.variant = dict(ch), variant
        self.dir = TRANS / f"live_{ch['id']}_{variant.replace('.', '_')}"
        self.proc, self.last, self.method, self.err, self.restarts = None, time.time(), "", "", 0
        self.lock = threading.Lock()
        self.probe = {}

    def build(self, hw):
        ch, pr = self.ch, self.probe
        url = ch["url"]
        ql = QMAP.get(self.variant)
        cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y"]
        if url.startswith("http"):
            cmd += ["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_on_network_error", "1", "-reconnect_delay_max", "4",
                    "-rw_timeout", "15000000"] + (["-user_agent", ch["ua"]] if ch["ua"] else [])
        vc = (pr.get("vcodec") or "").lower()
        copy = pr.get("vcodec") and ch["mode"] != "transcode" and not ql and vc == "h264" and (pr.get("pix_fmt") or "yuv420p") in ("yuv420p", "yuvj420p")
        if ch["mode"] == "copy" and not ql:
            copy = True
        h0 = pr.get("height") or 720
        maxh = min(int(S("max_height") or 1080), ql[2] if ql else 10000)
        h = min(h0, maxh)
        h -= h % 2
        vb = (max(150, int(ql[1] / 1000 * 0.95) - ql[3]) if ql else int(float((S("bitrate") or "8M").rstrip("M")) * 1000))
        if not copy and hw == "vaapi":
            cmd += ["-init_hw_device", f"vaapi=va:{S('vaapi_device')}", "-filter_hw_device", "va"]
        cmd += ["-fflags", "+genpts+discardcorrupt", "-i", url, "-map", "0:v:0?", "-map", "0:a:0?", "-sn", "-dn"]
        if not pr.get("vcodec"):
            cmd += ["-vn"]
        elif copy:
            cmd += ["-c:v", "copy"]
            self.method = "Remux (video copiat)"
        else:
            vf = f"yadif=deint=interlaced,scale=-2:{h},format=yuv420p"
            if hw == "vaapi":
                cmd += ["-vf", f"yadif=deint=interlaced,scale=-2:{h},format=nv12,hwupload", "-c:v", "h264_vaapi", "-b:v", f"{vb}k",
                        "-maxrate", f"{vb}k", "-bufsize", f"{vb * 2}k"]
            elif hw == "nvenc":
                cmd += ["-vf", vf, "-c:v", "h264_nvenc", "-preset", "p4", "-b:v", f"{vb}k", "-maxrate", f"{vb}k", "-bufsize", f"{vb * 2}k"]
            elif hw == "qsv":
                cmd += ["-vf", f"yadif=deint=interlaced,scale=-2:{h},format=nv12,hwupload=extra_hw_frames=64", "-c:v", "h264_qsv",
                        "-b:v", f"{vb}k", "-maxrate", f"{vb}k", "-bufsize", f"{vb * 2}k"]
            elif hw == "amf":
                cmd += ["-vf", f"yadif=deint=interlaced,scale=-2:{h},format=nv12", "-c:v", "h264_amf", "-usage", "transcoding",
                        "-b:v", f"{vb}k", "-maxrate", f"{vb}k", "-bufsize", f"{vb * 2}k"]
            else:
                cmd += ["-vf", vf, "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency", "-b:v", f"{vb}k", "-maxrate", f"{vb}k",
                        "-bufsize", f"{vb * 2}k", "-sc_threshold", "0"]
            cmd += ["-g", "50", "-force_key_frames", "expr:gte(t,n_forced*2)"]
            self.method = f"Transcodare – {'GPU (' + hw.upper() + ')' if hw in ('vaapi', 'nvenc', 'qsv', 'amf') else 'CPU'}"
        cmd += ["-c:a", "aac", "-ac", "2", "-b:a", "128k", "-ar", "48000",
                "-f", "hls", "-hls_time", "4", "-hls_list_size", "8", "-hls_delete_threshold", "4",
                "-hls_flags", "delete_segments+independent_segments+temp_file+omit_endlist",
                "-hls_segment_filename", str(self.dir / "s%06d.ts"), str(self.dir / "index.m3u8")]
        return cmd

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def ready(self):
        pl = self.dir / "index.m3u8"
        return pl.exists() and pl.read_text(errors="ignore").count("#EXTINF") >= 2

    def start(self):
        with self.lock:
            if self.alive():
                return True
            shutil.rmtree(self.dir, ignore_errors=True)
            self.dir.mkdir(parents=True, exist_ok=True)
            self.probe = ch_probe(q("SELECT * FROM live_channels WHERE id=?", (self.ch["id"],), one=True) or self.ch)
            if not self.probe.get("ok"):
                self.err = self.probe.get("error", "Sursa nu răspunde")
                return False
            plans = ([HW["mode"]] if HW["mode"] in ("vaapi", "nvenc", "qsv", "amf") else []) + ["none"]
            for hw in plans:
                self.proc = subprocess.Popen(self.build(hw), stdout=subprocess.DEVNULL, stderr=open(self.dir.parent / f"{self.dir.name}.log", "wb"),
                                             **popen_kw())
                t0 = time.time()
                while time.time() - t0 < 30:
                    if self.ready():
                        log.info("TV Live: %s (%s) pornit – %s", self.ch["name"], self.variant, self.method)
                        self.err = ""
                        return True
                    if self.proc.poll() is not None:
                        break
                    time.sleep(0.2)
                self.err = (self.dir.parent / f"{self.dir.name}.log").read_text(errors="ignore")[-300:] or "Sursa nu a trimis date"
                self.stop(keep=True)
                if "copy" in self.method.lower():
                    break
            log.warning("TV Live: %s nu a pornit: %s", self.ch["name"], self.err)
            return False

    def stop(self, keep=False):
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.terminate()
                self.proc.wait(4)
            except Exception:
                try:
                    self.proc.kill()
                except Exception:
                    pass
        self.proc = None
        if not keep:
            shutil.rmtree(self.dir, ignore_errors=True)


def live_session(ch, variant):
    key = (ch["id"], variant)
    with LIVE_LOCK:
        ls = LIVE.get(key)
        if ls is None:
            ls = LiveSession(ch, variant)
            LIVE[key] = ls
    ls.last = time.time()
    if not ls.alive() and not ls.start():
        raise HTTPException(502, f"Canalul „{ch['name']}” nu poate fi pornit: {ls.err[:160]}")
    return ls


def live_janitor():
    while True:
        time.sleep(4)
        now = time.time()
        used = set(LIVE_TOKENS.values())
        for key, ls in list(LIVE.items()):
            idle = now - ls.last
            if idle > 45 and key not in used:
                ls.stop()
                LIVE.pop(key, None)
            elif not ls.alive() and idle < 20 and ls.restarts < 30:   # sursa a cazut, dar cineva se uita -> repornim
                ls.restarts += 1
                threading.Thread(target=ls.start, daemon=True).start()


def epg_now(tvg_ids):
    now = time.time()
    out = {}
    if not tvg_ids:
        return out
    ph = ",".join("?" * len(tvg_ids))
    for r in q(f"SELECT tvg_id, start, stop, title FROM live_epg WHERE tvg_id IN ({ph}) AND stop > ? AND start < ? ORDER BY start",
               (*tvg_ids, now, now + 6 * 3600)):
        e = out.setdefault(r["tvg_id"], [])
        if len(e) < 2:
            e.append({"start": r["start"], "stop": r["stop"], "title": r["title"]})
    return out


def ch_public(c, epg):
    e = epg.get(c["tvg_id"] or "", [])
    return {"id": c["id"], "name": c["name"], "num": c["num"], "group": c["grp"] or "", "logo": bool(c["logo"]),
            "now": e[0] if e and e[0]["start"] <= time.time() else None, "next": e[1] if len(e) > 1 else (e[0] if e and e[0]["start"] > time.time() else None)}


def need_live_user(req):
    u = need_user(req)
    if not u["live_ok"]:
        raise HTTPException(403, "Contul tău nu are acces la TV Live")
    return u


@app.get("/api/live/channels")
def live_channels(req: Request):
    u = need_user(req)
    if not u["live_ok"]:
        return {"channels": [], "groups": []}
    chs = q("SELECT * FROM live_channels WHERE enabled=1 ORDER BY COALESCE(num, 99999), name COLLATE NOCASE")
    epg = epg_now([c["tvg_id"] for c in chs if c["tvg_id"]])
    groups = []
    for c in chs:
        if c["grp"] and c["grp"] not in groups:
            groups.append(c["grp"])
    return {"channels": [ch_public(c, epg) for c in chs], "groups": groups}


@app.get("/api/live/logo/{cid}")
def live_logo(cid: int, req: Request):
    need_user(req)
    c = q("SELECT logo FROM live_channels WHERE id=?", (cid,), one=True)
    if not c or not c["logo"]:
        raise HTTPException(404)
    return FileResponse(logo_file(cid, c["logo"]), headers={"Cache-Control": "max-age=86400"})


def logo_file(cid, url):
    p = IMG / f"live_{cid}_{hashlib.md5(url.encode()).hexdigest()[:10]}"
    if not p.exists():
        try:
            r = httpx.get(url, timeout=15, follow_redirects=True)
            r.raise_for_status()
            p.write_bytes(r.content)
        except Exception:
            raise HTTPException(404)
    return p


@app.post("/api/live/play")
async def live_play(req: Request):
    u = need_live_user(req)
    d = await req.json()
    ch = q("SELECT * FROM live_channels WHERE id=? AND enabled=1", (int(d["channel"]),), one=True)
    if not ch:
        raise HTTPException(404, "Canal inexistent")
    remote = is_remote(req)
    if remote and (S("remote_enabled") != "1" or not u["remote_ok"]):
        raise HTTPException(403, "Contul tău nu are acces din afara rețelei locale")
    client = str(d.get("client") or "web")[:64]
    if u["max_streams"] and len(active_for(u["id"], exclude=client)) >= u["max_streams"]:
        raise HTTPException(429, f"Ai atins numărul maxim de ecrane simultane ({u['max_streams']}).")
    allowed = allowed_qualities(remote, u)
    ql = QMAP.get(d.get("quality") or "")
    if ql not in allowed:
        ql = allowed[0] if remote else None
    variant = ql[0] if ql else "orig"
    ls = await asyncio.to_thread(live_session, ch, variant)
    pr = ls.probe
    ua = req.headers.get("user-agent") or ""
    epg = epg_now([ch["tvg_id"]] if ch["tvg_id"] else [])
    title = f"📺 {ch['name']}"
    with ALOCK:
        e = ACTIVE.get((u["id"], client))
        same = e and e.get("live_ch") == ch["id"] and e.get("log_id")
    lid = e["log_id"] if same else x("""INSERT INTO play_log(user_id,username,media_id,title,client,device,ip,remote,method,quality,started,ended,watched,last_pos,duration)
        VALUES(?,?,NULL,?,?,?,?,?,?,?,?,?,0,0,0)""", (u["id"], u["username"], title, client, device_name(ua), client_ip(req), 1 if remote else 0,
                                                      ls.method, variant, time.time(), time.time()))
    STOP_REQ.discard((u["id"], client))
    details = {"method_label": ls.method, "container": "Live",
               "src_video": f"{pr.get('width')}×{pr.get('height')} · {(pr.get('vcodec') or '?').upper()}" if pr.get("vcodec") else "doar audio",
               "out_video": ("Original · H.264" if "Remux" in ls.method else f"{min(pr.get('height') or 720, ql[2] if ql else 10000)}p · H.264") if pr.get("vcodec") else "—",
               "src_audio": f"{(pr.get('acodec') or '?').upper()} {pr.get('channels') or ''}ch", "out_audio": "AAC stereo 128k",
               "quality": ql[4] if ql else "Original", "bitrate": fmt_bps(ql[1]) if ql else "—", "size": 0}
    touch_active(u["id"], client, media=None, live_ch=ch["id"], remote=remote, ip=client_ip(req), user=u["username"], ua=ua, device=device_name(ua),
                 title=title + (f" · {epg[ch['tvg_id']][0]['title']}" if ch["tvg_id"] in epg else ""), item_id=None, img=None, duration=0, pos=0,
                 paused=False, last_ping=time.time(), audio_label="—", method=ls.method, quality=variant, log_id=lid,
                 started=(e.get("started") if same else time.time()), details=details, sub_label="—")
    return {"ok": True, "url": f"/api/live/s/{ch['id']}/{variant}/index.m3u8", "channel": ch_public(ch, epg), "method": ls.method,
            "quality": variant, "remote": remote,
            "qualities": ([] if remote else [{"key": "orig", "label": "Original"}]) + [{"key": x_[0], "label": x_[4]} for x_ in allowed]}


@app.get("/api/live/s/{cid}/{variant}/{name}")
def live_file(cid: int, variant: str, name: str, req: Request):
    u = need_live_user(req)
    if is_remote(req) and QMAP.get(variant) not in allowed_qualities(True, u):
        raise HTTPException(403)
    r = _live_serve(cid, variant, name, {"Cache-Control": "no-cache"})
    if name.endswith(".ts"):
        try:
            note_bytes(u["id"], live_ch=cid, n=os.path.getsize(r.path))
        except Exception:
            pass
    return r


def _live_serve(cid, variant, name, headers):
    ls = LIVE.get((cid, variant))
    if not ls or not re.fullmatch(r"index\.m3u8|s\d{6}\.ts", name):
        raise HTTPException(404)
    ls.last = time.time()
    p = ls.dir / name
    if name.endswith(".m3u8"):
        if not p.exists():
            raise HTTPException(404)
        return Response(p.read_text(errors="ignore"), media_type="application/vnd.apple.mpegurl", headers=headers)
    if not p.exists():
        raise HTTPException(404)
    return FileResponse(p, media_type="video/mp2t", headers=headers)


@app.post("/api/live/ping")
async def live_ping(req: Request):
    u = need_user(req)
    d = await req.json()
    key = (u["id"], str(d.get("client") or ""))
    stop = key in STOP_REQ
    STOP_REQ.discard(key)
    now = time.time()
    with ALOCK:
        e = ACTIVE.get(key)
        if e:
            add = 0 if e.get("paused") else min(15.0, now - e.get("last_ping", now))
            e.update(t=now, last_ping=now, paused=bool(d.get("paused")))
    if e and e.get("log_id"):
        x("UPDATE play_log SET ended=?, watched=watched+? WHERE id=?", (now, add, e["log_id"]))
    with LIVE_LOCK:
        for (cid, _v), ls in LIVE.items():
            if e and cid == e.get("live_ch"):
                ls.last = now
    return {"ok": True, "stop": stop}


# ---- Chromecast pentru TV Live
def cast_start_live(uid, dev_id, cid):
    ch = q("SELECT * FROM live_channels WHERE id=? AND enabled=1", (cid,), one=True)
    if not ch:
        raise HTTPException(404, "Canal inexistent")
    ls = live_session(ch, "orig")
    cc = cast_cc(dev_id)
    old = CAST_ACTIVE.get(uid)
    if old and not old.get("live"):
        cast_stop(uid, quit_app=False)
    elif old:
        LIVE_TOKENS.pop(old["token"], None)
    tok = secrets.token_urlsafe(18)
    LIVE_TOKENS[tok] = (ch["id"], "orig")
    base = f"http://{local_ip_for(cc.cast_info.host)}:{HTTP_PORT}/cast/live/{tok}"
    thumb = f"{base}/logo" if ch["logo"] else None
    cc.media_controller.play_media(f"{base}/index.m3u8", "application/x-mpegURL", title=ch["name"], thumb=thumb, stream_type="LIVE",
                                   metadata={"metadataType": 0, "title": ch["name"], "subtitle": "TV Live", **({"images": [{"url": thumb}]} if thumb else {})},
                                   media_info={"hlsSegmentFormat": "ts", "hlsVideoSegmentFormat": "mpeg2_ts"})
    cc.media_controller.block_until_active(timeout=15)
    un = (q("SELECT username FROM users WHERE id=?", (uid,), one=True) or {"username": "?"})["username"]
    lid = x("""INSERT INTO play_log(user_id,username,media_id,title,client,device,ip,remote,method,quality,started,ended,watched,last_pos,duration)
        VALUES(?,?,NULL,?,?,?,?,0,?,?,?,?,0,0,0)""", (uid, un, f"📺 {ch['name']}", "cast", f"Chromecast · {cc.cast_info.friendly_name}", "rețea locală",
                                                     ls.method, "LAN", time.time(), time.time()))
    CAST_ACTIVE[uid] = {"live": True, "channel": ch["id"], "device": dev_id, "device_name": cc.cast_info.friendly_name, "token": tok,
                        "title": f"📺 {ch['name']}", "logo": bool(ch["logo"]), "started": time.time(), "log_id": lid, "last_tick": time.time(),
                        "media_id": None, "item_id": None, "img": None, "duration": 0,
                        "details": {"method_label": ls.method, "container": "Live", "src_video": "", "out_video": "", "src_audio": "", "out_audio": "AAC stereo",
                                    "quality": "LAN", "bitrate": "—", "size": 0}}
    return CAST_ACTIVE[uid]


@app.post("/api/cast/live")
async def cast_live(req: Request):
    u = need_lan_user(req)
    if not u["live_ok"]:
        raise HTTPException(403, "Contul tău nu are acces la TV Live")
    d = await req.json()
    a = await asyncio.to_thread(cast_start_live, u["id"], str(d["device"]), int(d["channel"]))
    return {"ok": True, "device": a["device_name"]}


@app.options("/cast/live/{token}/{name}")
def cast_live_options(token: str, name: str):
    return Response(status_code=204, headers=CORS)


@app.get("/cast/live/{token}/{name}")
def cast_live_file(token: str, name: str):
    t = LIVE_TOKENS.get(token)
    if not t:
        raise HTTPException(404)
    if name == "logo":
        c = q("SELECT logo FROM live_channels WHERE id=?", (t[0],), one=True)
        if c and c["logo"]:
            return FileResponse(logo_file(t[0], c["logo"]), headers=CORS)
        raise HTTPException(404)
    ls = LIVE.get(t)
    if ls and not ls.alive():
        threading.Thread(target=ls.start, daemon=True).start()
    return _live_serve(t[0], t[1], name, CORS)


# ---- import M3U + EPG
def parse_m3u(text):
    out, cur = [], None
    for line in text.splitlines():
        line = line.strip().lstrip("\ufeff")
        if line.startswith("#EXTINF"):
            attrs = dict(re.findall(r'([\w-]+)="([^"]*)"', line))
            name = line.rsplit(",", 1)[-1].strip() if "," in line else attrs.get("tvg-name", "Canal")
            cur = {"name": name or attrs.get("tvg-name") or "Canal", "logo": attrs.get("tvg-logo", ""), "grp": attrs.get("group-title", ""),
                   "tvg_id": attrs.get("tvg-id", ""), "num": int(attrs["tvg-chno"]) if attrs.get("tvg-chno", "").isdigit() else None, "ua": ""}
        elif line.startswith("#EXTVLCOPT:http-user-agent=") and cur is not None:
            cur["ua"] = line.split("=", 1)[1]
        elif line and not line.startswith("#") and cur is not None:
            cur["url"] = line
            out.append(cur)
            cur = None
    return out


# Doar protocoale de streaming. Fara file:, pipe:, concat:, subfile: – ffmpeg le-ar deschide
# si un furnizor de liste ostil ar putea citi fisiere locale sau scana reteaua interna.
LIVE_URL_RE = re.compile(r"^(https?|rtmps?|rtsp|rtsps|udp|rtp|srt|mms|mmsh)://[^\s]", re.I)


def import_url_ok(url):
    """Filtru pentru adresele venite din liste facute de altcineva.
    Refuzam localhost: acolo stau servicii care nu sunt accesibile din retea (inclusiv CineVerse).
    Adresele din reteaua locala raman permise – multi au sursa IPTV pe alt calculator din casa."""
    if not LIVE_URL_RE.match(url or ""):
        return False
    try:
        host = re.sub(r"^[a-z]+://", "", url, flags=re.I).split("/")[0].split("@")[-1]
        host = host.split("]")[0].lstrip("[") if host.startswith("[") else host.split(":")[0]
        if host.lower() in ("localhost", "localhost.localdomain", "0.0.0.0", "::", "::1"):
            return False
        ip = ipaddress.ip_address(host)
        if ip.is_loopback or ip.is_unspecified or ip.is_link_local:
            return False
    except ValueError:
        pass                      # nume de domeniu obisnuit
    except Exception:
        pass
    return True


def import_m3u(pid, text):
    chans = parse_m3u(text)
    src = f"m3u:{pid}"
    existing = {r["url"]: r for r in q("SELECT * FROM live_channels WHERE source=?", (src,))}
    seen = set()
    base_num = (q("SELECT MAX(num) m FROM live_channels", one=True)["m"] or 0)
    skipped = 0
    for c in chans:
        if not import_url_ok(c["url"]):
            skipped += 1               # file:, pipe:, localhost – nu sunt fluxuri de televiziune, sunt risc
            continue
        seen.add(c["url"])
        r = existing.get(c["url"])
        if r:
            if not r["locked"]:
                x("UPDATE live_channels SET name=?, logo=?, grp=?, tvg_id=?, ua=? WHERE id=?", (c["name"], c["logo"], c["grp"], c["tvg_id"], c["ua"], r["id"]))
        else:
            base_num += 1
            x("INSERT INTO live_channels(name,url,logo,grp,num,tvg_id,enabled,source,mode,ua,added) VALUES(?,?,?,?,?,?,1,?,'auto',?,?)",
              (c["name"], c["url"], c["logo"], c["grp"], c["num"] or base_num, c["tvg_id"], src, c["ua"], time.time()))
    for url, r in existing.items():
        if url not in seen and not r["locked"]:
            x("DELETE FROM live_channels WHERE id=?", (r["id"],))
    if skipped:
        log.warning("Import M3U: am ignorat %d adrese cu protocol nepermis", skipped)
    return len(chans) - skipped


def refresh_playlist(pid):
    pl = q("SELECT * FROM live_playlists WHERE id=?", (pid,), one=True)
    if not pl or not pl["url"]:
        return
    try:
        r = httpx.get(pl["url"], timeout=30, follow_redirects=True)
        r.raise_for_status()
        n = import_m3u(pid, r.text)
        x("UPDATE live_playlists SET last=?, count=?, err='' WHERE id=?", (time.time(), n, pid))
    except Exception as e:
        x("UPDATE live_playlists SET last=?, err=? WHERE id=?", (time.time(), str(e)[:200], pid))


def xmltv_time(sv):
    m = re.match(r"(\d{14})\s*([+-]\d{4})?", sv or "")
    if not m:
        return None
    dt = datetime.datetime.strptime(m.group(1), "%Y%m%d%H%M%S")
    tz = m.group(2) or "+0000"
    off = (int(tz[1:3]) * 60 + int(tz[3:5])) * (1 if tz[0] == "+" else -1)
    return dt.replace(tzinfo=datetime.timezone(datetime.timedelta(minutes=off))).timestamp()


def refresh_epg():
    if EPG_STATE["running"]:
        return
    EPG_STATE.update(running=True, err="")
    import gzip, tempfile
    import xml.etree.ElementTree as ET
    try:
        chs = q("SELECT id, name, tvg_id FROM live_channels")
        wanted = {c["tvg_id"] for c in chs if c["tvg_id"]}
        by_name = {norm(c["name"]): c for c in chs if not c["tvg_id"]}
        now, total = time.time(), 0
        for url in [u_ for u_ in re.split(r"[\s]+", S("epg_urls") or "") if u_]:
            tmp = tempfile.NamedTemporaryFile(delete=False, dir=str(DATA), suffix=".xml")
            with httpx.stream("GET", url, timeout=120, follow_redirects=True) as r:
                r.raise_for_status()
                for chunk in r.iter_bytes():
                    tmp.write(chunk)
            tmp.close()
            with open(tmp.name, "rb") as fh:
                gz = fh.read(2) == b"\x1f\x8b"
            fh = gzip.open(tmp.name, "rb") if gz else open(tmp.name, "rb")
            rows = []
            for _ev, el in ET.iterparse(fh, events=("end",)):
                if el.tag == "channel":
                    cid = el.get("id") or ""
                    for dn in el.findall("display-name"):   # potrivire automata dupa nume pentru canalele fara tvg-id
                        c = by_name.pop(norm(dn.text or ""), None)
                        if c:
                            x("UPDATE live_channels SET tvg_id=? WHERE id=?", (cid, c["id"]))
                            wanted.add(cid)
                    el.clear()
                elif el.tag == "programme":
                    cid = el.get("channel") or ""
                    if cid in wanted:
                        st_, sp_ = xmltv_time(el.get("start")), xmltv_time(el.get("stop"))
                        if st_ and sp_ and sp_ > now - 3600 and st_ < now + 36 * 3600:
                            rows.append((cid, st_, sp_, (el.findtext("title") or "").strip(), (el.findtext("desc") or "").strip()[:500]))
                    el.clear()
            fh.close()
            os.unlink(tmp.name)
            ids = {r_[0] for r_ in rows}
            with _wlock:
                c = db()
                for cid in ids:
                    c.execute("DELETE FROM live_epg WHERE tvg_id=?", (cid,))
                c.executemany("INSERT INTO live_epg VALUES(?,?,?,?,?)", rows)
                c.execute("DELETE FROM live_epg WHERE stop < ?", (now - 3600,))
                c.commit()
            total += len(rows)
        EPG_STATE.update(last=time.time(), count=total)
    except Exception as e:
        EPG_STATE["err"] = str(e)[:200]
        log.warning("EPG: %s", e)
    finally:
        EPG_STATE["running"] = False


def run_channel_check(only_enabled=True):
    """Testează toate canalele cu ffprobe și dezactivează cele care nu răspund."""
    if CH_CHECK_STATE["running"]:
        return
    CH_CHECK_STATE.update(running=True, err="", done=0, disabled=0)
    try:
        filt = "WHERE enabled=1" if only_enabled else ""
        chs = q(f"SELECT * FROM live_channels {filt} ORDER BY COALESCE(num,99999)")
        CH_CHECK_STATE["total"] = len(chs)
        disabled = 0
        for ch in chs:
            try:
                pr = live_probe(ch["url"], ch["ua"] or "")
                x("UPDATE live_channels SET probe=? WHERE id=?", (json.dumps({**pr, "t": time.time()}), ch["id"]))
                if not pr.get("ok"):
                    x("UPDATE live_channels SET enabled=0 WHERE id=?", (ch["id"],))
                    # opreste sesiunea live daca e pornita
                    for k in list(LIVE.keys()):
                        if k[0] == ch["id"]:
                            try: LIVE[k].stop()
                            except: pass
                    disabled += 1
            except Exception as e:
                log.warning("ch_check canal %s: %s", ch["name"], e)
            CH_CHECK_STATE["done"] += 1
            CH_CHECK_STATE["disabled"] = disabled
        CH_CHECK_STATE["last"] = time.time()
        log.info("Verificare canale: %d testate, %d dezactivate", len(chs), disabled)
    except Exception as e:
        CH_CHECK_STATE["err"] = str(e)[:200]
        log.warning("run_channel_check: %s", e)
    finally:
        CH_CHECK_STATE["running"] = False


def live_refresher():
    time.sleep(20)
    while True:
        try:
            iv = max(1, int(S("live_refresh") or 12)) * 3600
            for pl in q("SELECT * FROM live_playlists"):
                if time.time() - (pl["last"] or 0) > iv:
                    refresh_playlist(pl["id"])
            if S("epg_urls") and time.time() - EPG_STATE["last"] > 6 * 3600:
                refresh_epg()
            # verificare automata canale – o data pe zi, noaptea
            check_iv = 86400  # 24h
            if time.time() - CH_CHECK_STATE["last"] > check_iv and not CH_CHECK_STATE["running"]:
                threading.Thread(target=run_channel_check, daemon=True).start()
        except Exception as e:
            log.warning("live refresher: %s", e)
        time.sleep(600)


# ---- administrare TV Live
@app.get("/api/admin/live")
def admin_live(req: Request):
    need_admin(req)
    chs = q("SELECT * FROM live_channels ORDER BY COALESCE(num, 99999), name COLLATE NOCASE")
    epgc = {r["tvg_id"]: r["n"] for r in q("SELECT tvg_id, COUNT(*) n FROM live_epg GROUP BY tvg_id")}
    running = {k[0] for k, ls in LIVE.items() if ls.alive()}
    return {"channels": [{"id": c["id"], "name": c["name"], "url": c["url"], "logo": c["logo"], "group": c["grp"], "num": c["num"],
                          "tvg_id": c["tvg_id"], "enabled": bool(c["enabled"]), "source": c["source"], "mode": c["mode"], "ua": c["ua"],
                          "probe": json.loads(c["probe"]) if c["probe"] else None, "epg": epgc.get(c["tvg_id"], 0), "running": c["id"] in running}
                         for c in chs],
            "playlists": [dict(r) for r in q("SELECT * FROM live_playlists ORDER BY id")],
            "epg": {"urls": S("epg_urls"), **EPG_STATE}}


@app.post("/api/admin/live/channel")
async def admin_live_save(req: Request):
    need_admin(req)
    d = await req.json()
    name, url = (d.get("name") or "").strip(), (d.get("url") or "").strip()
    if not name or not LIVE_URL_RE.match(url):
        raise HTTPException(400, "Nume și URL valid obligatorii (http, https, rtmp, rtsp, udp, srt)")
    vals = (name, url, (d.get("logo") or "").strip(), (d.get("group") or "").strip(), int(d["num"]) if str(d.get("num") or "").isdigit() else None,
            (d.get("tvg_id") or "").strip(), 1 if d.get("enabled", True) else 0, d.get("mode") if d.get("mode") in ("auto", "copy", "transcode") else "auto",
            (d.get("ua") or "").strip())
    if d.get("id"):
        old = q("SELECT url, mode FROM live_channels WHERE id=?", (int(d["id"]),), one=True)
        x("UPDATE live_channels SET name=?, url=?, logo=?, grp=?, num=?, tvg_id=?, enabled=?, mode=?, ua=?, locked=1 WHERE id=?", (*vals, int(d["id"])))
        if old and (old["url"] != url or old["mode"] != vals[7]):
            x("UPDATE live_channels SET probe=NULL WHERE id=?", (int(d["id"]),))
            for k in [k for k in LIVE if k[0] == int(d["id"])]:
                LIVE.pop(k).stop()
        cid = int(d["id"])
    else:
        cid = x("INSERT INTO live_channels(name,url,logo,grp,num,tvg_id,enabled,mode,ua,source,locked,added) VALUES(?,?,?,?,?,?,?,?,?,'manual',1,?)",
                (*vals, time.time()))
        if vals[4] is None:
            x("UPDATE live_channels SET num=(SELECT COALESCE(MAX(num),0)+1 FROM live_channels) WHERE id=?", (cid,))
    return {"ok": True, "id": cid}


@app.delete("/api/admin/live/channel/{cid}")
def admin_live_del(cid: int, req: Request):
    need_admin(req)
    for k in [k for k in LIVE if k[0] == cid]:
        LIVE.pop(k).stop()
    x("DELETE FROM live_channels WHERE id=?", (cid,))
    return {"ok": True}


@app.post("/api/admin/live/test")
async def admin_live_test(req: Request):
    need_admin(req)
    d = await req.json()
    return await asyncio.to_thread(live_probe, (d.get("url") or "").strip(), (d.get("ua") or "").strip())


@app.post("/api/admin/live/playlist")
async def admin_live_playlist(req: Request):
    need_admin(req)
    d = await req.json()
    if d.get("text"):
        pid = x("INSERT INTO live_playlists(url,name,last,count) VALUES('',?,?,0)", ((d.get("name") or "Listă lipită")[:60], time.time()))
        n = import_m3u(pid, d["text"])
        x("UPDATE live_playlists SET count=? WHERE id=?", (n, pid))
        return {"ok": True, "count": n}
    url = (d.get("url") or "").strip()
    if not url.startswith("http"):
        raise HTTPException(400, "URL M3U invalid")
    pid = x("INSERT INTO live_playlists(url,name,last,count) VALUES(?,?,0,0)", (url, (d.get("name") or url.split("/")[-1])[:60]))
    await asyncio.to_thread(refresh_playlist, pid)
    r = q("SELECT * FROM live_playlists WHERE id=?", (pid,), one=True)
    if r["err"]:
        raise HTTPException(400, "Nu am putut descărca lista: " + r["err"])
    return {"ok": True, "count": r["count"]}


@app.post("/api/admin/live/playlist/upload")
async def admin_live_playlist_upload(req: Request):
    """Primește fișier .m3u ca flux brut și îl importă ca playlist nou."""
    need_admin(req)
    name = req.headers.get("X-Playlist-Name", "Fișier M3U")[:60]
    total = 0
    chunks = []
    async for chunk in req.stream():
        chunks.append(chunk)
        total += len(chunk)
        if total > 50 * 1024 * 1024:
            raise HTTPException(413, "Fișier prea mare (max 50 MB)")
    if not total:
        raise HTTPException(400, "Fișier gol")
    text = b"".join(chunks).decode("utf-8", errors="replace")
    if "#EXTM3U" not in text and "#EXTINF" not in text:
        raise HTTPException(400, "Nu pare un fișier M3U valid")
    pid = x("INSERT INTO live_playlists(url,name,last,count) VALUES('',?,?,0)", (name, time.time()))
    n = import_m3u(pid, text)
    x("UPDATE live_playlists SET count=? WHERE id=?", (n, pid))
    return {"ok": True, "count": n}


@app.post("/api/admin/live/playlist/{pid}/refresh")
async def admin_live_pl_refresh(pid: int, req: Request):
    need_admin(req)
    await asyncio.to_thread(refresh_playlist, pid)
    return {"ok": True}


@app.delete("/api/admin/live/playlist/{pid}")
def admin_live_pl_del(pid: int, req: Request, keep: int = 0):
    need_admin(req)
    if not keep:
        x("DELETE FROM live_channels WHERE source=? AND locked=0", (f"m3u:{pid}",))
    x("UPDATE live_channels SET source='manual' WHERE source=?", (f"m3u:{pid}",))
    x("DELETE FROM live_playlists WHERE id=?", (pid,))
    return {"ok": True}


@app.post("/api/admin/live/epg")
async def admin_live_epg(req: Request):
    need_admin(req)
    d = await req.json()
    if "urls" in d:
        set_S("epg_urls", d["urls"].strip())
    threading.Thread(target=refresh_epg, daemon=True).start()
    return {"ok": True}


@app.post("/api/admin/live/check")
async def admin_live_check(req: Request):
    """Porneste verificarea manuala a tuturor canalelor."""
    need_admin(req)
    if CH_CHECK_STATE["running"]:
        return {"ok": False, "msg": "Verificare deja în curs"}
    d = await req.json()
    only_enabled = d.get("only_enabled", True)
    threading.Thread(target=run_channel_check, args=(only_enabled,), daemon=True).start()
    return {"ok": True}


@app.get("/api/admin/live/check")
def admin_live_check_status(req: Request):
    """Status curent al verificarii."""
    need_admin(req)
    return dict(CH_CHECK_STATE)


# ---------------------------------------------------------------- monitorizare sistem
SYS_PREV = {"t": 0.0, "cpu": None, "cores": None, "net": {}, "disk": None}
SYS_LOCK = threading.Lock()


def _read(path, default=""):
    try:
        with open(path, "r", errors="ignore") as f:
            return f.read()
    except Exception:
        return default


def _cpu_times():
    """(total, idle) global si pe fiecare nucleu, din /proc/stat."""
    tot, cores = None, []
    for line in _read("/proc/stat").splitlines():
        if not line.startswith("cpu"):
            break
        p = line.split()
        if len(p) < 5:
            continue
        v = [int(x_) for x_ in p[1:]]
        pair = (sum(v), v[3] + (v[4] if len(v) > 4 else 0))
        if p[0] == "cpu":
            tot = pair
        else:
            cores.append(pair)
    return tot, cores


def _pct(prev, now):
    if not prev or not now:
        return None
    dt, di = now[0] - prev[0], now[1] - prev[1]
    if dt <= 0:
        return None
    return round(max(0.0, min(100.0, (1 - di / dt) * 100)), 1)


def _hwmon_temps():
    out = []
    try:
        for hw in sorted(Path("/sys/class/hwmon").glob("hwmon*")):
            chip = _read(hw / "name").strip() or hw.name
            for t in sorted(hw.glob("temp*_input")):
                try:
                    c = int(_read(t, "0").strip()) / 1000.0
                except ValueError:
                    continue
                if not (-20 < c < 150):
                    continue
                lbl = _read(t.with_name(t.name.replace("_input", "_label")), "").strip()
                out.append({"label": (chip + (" · " + lbl if lbl else "")), "c": round(c, 1)})
    except Exception:
        pass
    return out[:12]


def _mounts():
    out, seen = [], set()
    skip_fs = {"tmpfs", "devtmpfs", "squashfs", "overlay", "proc", "sysfs", "cgroup", "cgroup2",
               "devpts", "debugfs", "tracefs", "securityfs", "pstore", "bpf", "configfs", "fusectl",
               "autofs", "mqueue", "hugetlbfs", "ramfs", "efivarfs", "binfmt_misc", "nsfs"}
    for line in _read("/proc/mounts").splitlines():
        p = line.split()
        if len(p) < 3 or p[2] in skip_fs or p[1].startswith(("/proc", "/sys", "/dev", "/run", "/snap")):
            continue
        try:
            st = os.statvfs(p[1])
        except Exception:
            continue
        total = st.f_blocks * st.f_frsize
        # sarim peste monturi de retea si peste marimi nerealiste (rclone, sshfs raporteaza exabytes)
        if total < 512 * 1024 ** 2 or total > 500 * 1024 ** 4 or (p[0], total) in seen:
            continue
        if p[2].startswith("fuse.") and p[2] not in ("fuse.ntfs", "fuse.exfat"):
            continue
        seen.add((p[0], total))
        free = st.f_bavail * st.f_frsize
        used = total - st.f_bfree * st.f_frsize
        out.append({"mount": p[1], "dev": p[0], "fs": p[2], "total": total, "used": used,
                    "free": free, "pct": round(used / total * 100, 1) if total else 0})
    return sorted(out, key=lambda d: d["mount"])[:8]


def _top_procs(n=8):
    """Procesele care consuma cel mai mult procesor, calculat intre doua masuratori."""
    out = []
    try:
        hz = os.sysconf("SC_CLK_TCK") or 100
        page = os.sysconf("SC_PAGE_SIZE") or 4096
        now = time.time()
        prev = SYS_PREV.get("procs") or {}
        cur = {}
        for d in os.listdir("/proc"):
            if not d.isdigit():
                continue
            st = _read(f"/proc/{d}/stat")
            if not st:
                continue
            try:
                rp = st.rindex(")")
                name = st[st.index("(") + 1:rp]
                f = st[rp + 2:].split()
                ticks = int(f[11]) + int(f[12])          # utime + stime
                rss = int(f[21]) * page
            except Exception:
                continue
            cur[d] = ticks
            pt, pv = prev.get(d)if isinstance(prev.get(d), tuple) else (None, None)
            if pv is not None and now > pt:
                cpu = max(0.0, (ticks - pv) / hz / (now - pt) * 100)
            else:
                cpu = 0.0
            cmd = _read(f"/proc/{d}/cmdline").replace("\x00", " ").strip()
            out.append({"pid": int(d), "name": name, "cpu": round(cpu, 1), "mem": rss,
                        "cmd": (cmd or name)[:110]})
        SYS_PREV["procs"] = {k: (now, v) for k, v in cur.items()}
    except Exception:
        return []
    out.sort(key=lambda p_: -p_["cpu"])
    return out[:n]


def _services():
    out = []
    for svc in ("cineverse", "nginx"):
        st = "necunoscut"
        try:
            r = subprocess.run(["systemctl", "is-active", svc], capture_output=True, text=True, timeout=4)
            first = (r.stdout or "").strip().splitlines()[:1]
            st = first[0][:24] if first and first[0] else "necunoscut"
        except Exception:
            pass
        out.append({"name": svc, "state": st})
    return out


def _gpu():
    g = {"present": False, "name": "", "freq": None, "hw": HW.get("mode", "none"), "detail": HW.get("detail", "")}
    try:
        for card in sorted(Path("/sys/class/drm").glob("card[0-9]")):
            g["present"] = True
            f = card / "gt_cur_freq_mhz"
            if f.exists():
                try:
                    g["freq"] = int(_read(f, "0").strip())
                except ValueError:
                    pass
            v = card / "device/vendor"
            ven = _read(v, "").strip()
            g["name"] = {"0x8086": "Intel", "0x1002": "AMD", "0x10de": "NVIDIA"}.get(ven, ven)
            break
        if not g["present"]:
            g["present"] = os.path.exists("/dev/dri/renderD128")
    except Exception:
        pass
    return g


_SYS_REQ = threading.local()


def is_remote_flag():
    return bool(getattr(_SYS_REQ, "remote", False))


def sysinfo():
    """O fotografie a intregului sistem. Ratele se calculeaza intre doua apeluri."""
    now = time.time()
    with SYS_LOCK:
        prev_t = SYS_PREV["t"]
        dt = max(0.001, now - prev_t) if prev_t else 0

        if IS_WIN:
            return _sysinfo_win(now)

        tot, cores = _cpu_times()
        cpu_pct = _pct(SYS_PREV["cpu"], tot) if prev_t else None
        core_pct = [_pct(a, b) for a, b in zip(SYS_PREV["cores"] or [], cores)] if prev_t else []
        SYS_PREV["cpu"], SYS_PREV["cores"] = tot, cores

        mem = {}
        for line in _read("/proc/meminfo").splitlines():
            k, _, v = line.partition(":")
            mem[k] = int(v.split()[0]) * 1024 if v.split() else 0
        m_total = mem.get("MemTotal", 0)
        m_avail = mem.get("MemAvailable", mem.get("MemFree", 0))
        s_total = mem.get("SwapTotal", 0)
        s_free = mem.get("SwapFree", 0)

        nets = []
        for line in _read("/proc/net/dev").splitlines()[2:]:
            name, _, rest = line.partition(":")
            name = name.strip()
            if name == "lo" or name.startswith(VIRT_IF):
                continue
            f = rest.split()
            if len(f) < 9:
                continue
            rx, tx = int(f[0]), int(f[8])
            p = SYS_PREV["net"].get(name)
            nets.append({"name": name, "rx": rx, "tx": tx,
                         "rx_bps": max(0, int((rx - p[0]) * 8 / dt)) if p and dt else 0,
                         "tx_bps": max(0, int((tx - p[1]) * 8 / dt)) if p and dt else 0})
            SYS_PREV["net"][name] = (rx, tx)

        rd = wr = 0
        for line in _read("/proc/diskstats").splitlines():
            f = line.split()
            if len(f) < 10 or not re.fullmatch(r"(sd[a-z]|nvme\d+n\d+|mmcblk\d+|vd[a-z])", f[2]):
                continue
            rd += int(f[5]) * 512
            wr += int(f[9]) * 512
        pdio = SYS_PREV["disk"]
        dio = {"read_bps": max(0, int((rd - pdio[0]) / dt)) if pdio and dt else 0,
               "write_bps": max(0, int((wr - pdio[1]) / dt)) if pdio and dt else 0}
        SYS_PREV["disk"] = (rd, wr)
        SYS_PREV["t"] = now

    la = _read("/proc/loadavg").split()[:3]
    ncpu = len(cores) or os.cpu_count() or 1
    model = ""
    for line in _read("/proc/cpuinfo").splitlines():
        if line.lower().startswith("model name"):
            model = line.split(":", 1)[1].strip()
            break
    up = float((_read("/proc/uptime", "0").split() or ["0"])[0])
    temps = _hwmon_temps()
    cpu_temp = next((t["c"] for t in temps if re.search(r"package|tctl|tdie|cpu", t["label"], re.I)), None)
    if cpu_temp is None and temps:
        cpu_temp = max(t["c"] for t in temps)

    return {"ok": True, "t": now,
            "host": {"name": socket.gethostname(), "os": _distro(), "kernel": platform_release(),
                     "uptime": up, "cpu_model": model, "cores": ncpu, "py": sys.version.split()[0]},
            "cpu": {"pct": cpu_pct, "per_core": [c for c in core_pct if c is not None],
                    "load": [float(x_) for x_ in la] if len(la) == 3 else [0, 0, 0], "temp": cpu_temp},
            "mem": {"total": m_total, "used": m_total - m_avail, "avail": m_avail,
                    "pct": round((m_total - m_avail) / m_total * 100, 1) if m_total else 0,
                    "swap_total": s_total, "swap_used": s_total - s_free,
                    "swap_pct": round((s_total - s_free) / s_total * 100, 1) if s_total else 0},
            "disks": _mounts(), "diskio": dio, "net": nets, "temps": temps,
            "gpu": _gpu(), "services": _services(), "procs": _top_procs(),
            "app": app_stats(), "remote_ok": S("monitor_remote") == "1", "remote": is_remote_flag()}


def _distro():
    for line in _read("/etc/os-release").splitlines():
        if line.startswith("PRETTY_NAME="):
            return line.split("=", 1)[1].strip().strip('"')
    return "Linux"


def platform_release():
    try:
        return os.uname().release
    except Exception:
        return ""


def app_stats():
    """Cat de ocupat e CineVerse insusi."""
    with ALOCK:
        act = [dict(e) for e in ACTIVE.values()]
    tx = sum(1 for s_ in SESSIONS.values() if s_.proc and s_.proc.poll() is None)
    live = sum(1 for ls in LIVE.values() if ls.alive())
    ff = 0
    try:
        ff = sum(1 for d in os.listdir("/proc") if d.isdigit()
                 and "ffmpeg" in _read(f"/proc/{d}/comm", ""))
    except Exception:
        pass
    return {"version": VERSION, "streams": len(act), "cast": len(CAST_ACTIVE),
            "transcodes": tx, "live_sessions": live, "ffmpeg": ff,
            "remote": sum(1 for a in act if a.get("remote")),
            "bps": sum(real_bps(a) for a in act),
            "items": q("SELECT COUNT(*) c FROM items", one=True)["c"],
            "media": q("SELECT COUNT(*) c FROM media", one=True)["c"],
            "channels": q("SELECT COUNT(*) c FROM live_channels WHERE enabled=1", one=True)["c"],
            "users": q("SELECT COUNT(*) c FROM users", one=True)["c"],
            "scan": dict(scan_state),
            "data_dir": str(DATA)}


def _sysinfo_win(now):
    """Pe Windows ne bazam pe psutil, instalat de instalator."""
    try:
        import psutil
    except Exception:
        return {"ok": False, "error": "Monitorizarea pe Windows are nevoie de pachetul psutil."}
    vm, sw = psutil.virtual_memory(), psutil.swap_memory()
    per = psutil.cpu_percent(percpu=True)
    disks = []
    for pp in psutil.disk_partitions(all=False):
        try:
            u = psutil.disk_usage(pp.mountpoint)
        except Exception:
            continue
        disks.append({"mount": pp.mountpoint, "dev": pp.device, "fs": pp.fstype,
                      "total": u.total, "used": u.used, "free": u.free, "pct": round(u.percent, 1)})
    nets = []
    for nm, c in psutil.net_io_counters(pernic=True).items():
        if nm.lower().startswith(VIRT_IF) or "loopback" in nm.lower():
            continue
        p = SYS_PREV["net"].get(nm)
        dt = max(0.001, now - SYS_PREV["t"]) if SYS_PREV["t"] else 0
        nets.append({"name": nm, "rx": c.bytes_recv, "tx": c.bytes_sent,
                     "rx_bps": max(0, int((c.bytes_recv - p[0]) * 8 / dt)) if p and dt else 0,
                     "tx_bps": max(0, int((c.bytes_sent - p[1]) * 8 / dt)) if p and dt else 0})
        SYS_PREV["net"][nm] = (c.bytes_recv, c.bytes_sent)
    dio = psutil.disk_io_counters()
    pd = SYS_PREV["disk"]
    dt = max(0.001, now - SYS_PREV["t"]) if SYS_PREV["t"] else 0
    io = {"read_bps": max(0, int((dio.read_bytes - pd[0]) / dt)) if pd and dt else 0,
          "write_bps": max(0, int((dio.write_bytes - pd[1]) / dt)) if pd and dt else 0}
    SYS_PREV["disk"] = (dio.read_bytes, dio.write_bytes)
    SYS_PREV["t"] = now
    procs = []
    for pr in psutil.process_iter(["pid", "name", "cpu_percent", "memory_info"]):
        try:
            procs.append({"pid": pr.info["pid"], "name": pr.info["name"] or "",
                          "cpu": round(pr.info["cpu_percent"] or 0, 1),
                          "mem": (pr.info["memory_info"].rss if pr.info["memory_info"] else 0),
                          "cmd": pr.info["name"] or ""})
        except Exception:
            pass
    procs.sort(key=lambda p_: -p_["cpu"])
    temps = []
    try:
        for chip, lst in (psutil.sensors_temperatures() or {}).items():
            for e in lst:
                temps.append({"label": chip + (" · " + e.label if e.label else ""), "c": round(e.current, 1)})
    except Exception:
        pass
    return {"ok": True, "t": now,
            "host": {"name": socket.gethostname(), "os": "Windows", "kernel": platform_release(),
                     "uptime": time.time() - psutil.boot_time(), "cpu_model": "",
                     "cores": psutil.cpu_count() or 1, "py": sys.version.split()[0]},
            "cpu": {"pct": psutil.cpu_percent(), "per_core": per, "load": [0, 0, 0],
                    "temp": (max((t["c"] for t in temps), default=None))},
            "mem": {"total": vm.total, "used": vm.used, "avail": vm.available, "pct": round(vm.percent, 1),
                    "swap_total": sw.total, "swap_used": sw.used, "swap_pct": round(sw.percent, 1)},
            "disks": disks[:8], "diskio": io, "net": nets, "temps": temps[:12],
            "gpu": {"present": False, "name": "", "freq": None, "hw": HW.get("mode", "none"), "detail": HW.get("detail", "")},
            "services": [], "procs": procs[:8], "app": app_stats(),
            "remote_ok": S("monitor_remote") == "1", "remote": is_remote_flag()}


@app.get("/api/admin/system")
def admin_system(req: Request):
    """Monitorizare – doar pentru administrator. Din afara casei, doar daca e permis din setari."""
    need_admin(req)
    rem = is_remote(req)
    if rem and S("monitor_remote") != "1":
        raise HTTPException(403, "Monitorizarea e limitată la reţeaua locală. O poţi deschide din tabul Sistem.")
    _SYS_REQ.remote = rem
    try:
        return sysinfo()
    finally:
        _SYS_REQ.remote = False


@app.post("/api/admin/system/access")
async def admin_system_access(req: Request):
    need_admin(req)
    d = await req.json()
    set_S("monitor_remote", "1" if d.get("remote") else "0")
    return {"ok": True, "remote": S("monitor_remote") == "1"}


# ---------------------------------------------------------------- copii de siguranta
BK = {"running": False, "last": 0.0, "err": "", "last_file": "", "last_size": 0}
BK_LOCK = threading.Lock()
BK_NAME = re.compile(r"^cineverse-\d{8}-\d{4}\.zip$")


# Ce inseamna "doar configurarea": setarile serverului, conturile cu drepturile lor, canalele TV
# si listele M3U. Filmele, serialele, metadatele TMDB si progresul vizionarilor NU intra –
# se refac singure la scanare. Ghidul EPG se redescarca si el, deci nici el nu intra.
CONFIG_TABLES = ("settings", "users", "live_channels", "live_playlists")
LIBRARY_TABLES = ("play_log", "mylist", "progress", "subtitles", "media", "items", "live_epg", "tokens")


def backup_dir():
    d = Path((S("backup_dir") or "").strip() or (DATA / "backups"))
    d.mkdir(parents=True, exist_ok=True)
    return d


def db_snapshot(dest):
    """Copie consistenta a bazei de date, fara sa opresc serverul sau redarile in curs."""
    dest = Path(dest)
    dest.unlink(missing_ok=True)
    try:
        db().execute("VACUUM INTO ?", (str(dest),))        # SQLite >= 3.27
    except Exception:
        con = sqlite3.connect(str(dest))
        try:
            with _wlock:
                db().backup(con)
        finally:
            con.close()
    return dest


def _add_tree(z, root, prefix, budget=None):
    n = 0
    if not root.exists():
        return 0
    for f in sorted(root.rglob("*")):
        if not f.is_file():
            continue
        if budget is not None and budget[0] <= 0:
            break
        try:
            z.write(f, f"{prefix}/{f.relative_to(root).as_posix()}")
            n += 1
            if budget is not None:
                budget[0] -= f.stat().st_size
        except Exception:
            pass
    return n


def make_backup(dest, images=False, scope=None):
    """Scrie o arhiva .zip. scope='config' = doar setari/conturi/TV, 'full' = si biblioteca."""
    import zipfile
    scope = scope or (S("backup_scope") or "config")
    if scope not in ("config", "full"):
        scope = "config"
    dest = Path(dest)
    tmpdb = Path(tempfile.mkdtemp(prefix="cvbk", dir=str(DATA))) / "cineverse.db"
    try:
        db_snapshot(tmpdb)
        con = sqlite3.connect(str(tmpdb))
        if scope == "config":
            con.execute("PRAGMA foreign_keys=OFF")
            for t in LIBRARY_TABLES:
                try:
                    con.execute(f"DELETE FROM {t}")
                except Exception:
                    pass
            con.execute("DELETE FROM sessions")      # sesiunile se leaga de instalarea veche
            con.commit()
            con.execute("VACUUM")
            con.commit()
        counts = {}
        for t in ("users", "items", "media", "live_channels", "live_playlists"):
            try:
                counts[t] = con.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
            except Exception:
                counts[t] = 0
        con.close()
        man = {"app": "CineVerse by NetStreaming", "version": VERSION, "created": time.time(),
               "created_h": time.strftime("%Y-%m-%d %H:%M:%S"), "scope": scope,
               "images": bool(images) and scope == "full",
               "media_dirs": S("media_dirs"), "counts": counts}
        part = dest.with_suffix(".part")
        with zipfile.ZipFile(part, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
            z.writestr("manifest.json", json.dumps(man, ensure_ascii=False, indent=1))
            z.write(tmpdb, "cineverse.db")
            if scope == "full":
                _add_tree(z, SUBS, "subs")
                if images:
                    _add_tree(z, IMG, "images")
        part.replace(dest)
        return man
    finally:
        shutil.rmtree(tmpdb.parent, ignore_errors=True)


def backup_now(images=None, scope=None):
    """Creeaza o copie in folderul de backup si sterge copiile prea vechi."""
    with BK_LOCK:
        if BK["running"]:
            raise HTTPException(409, "O copie de siguranță este deja în curs")
        BK["running"] = True
    try:
        if images is None:
            images = S("backup_images") == "1"
        d = backup_dir()
        dest = d / time.strftime("cineverse-%Y%m%d-%H%M.zip")
        make_backup(dest, images, scope)
        keep = max(1, min(100, int(S("backup_keep") or 7)))
        old = sorted([f for f in d.glob("cineverse-*.zip") if BK_NAME.match(f.name)], key=lambda f: f.stat().st_mtime, reverse=True)
        for f in old[keep:]:
            f.unlink(missing_ok=True)
        BK.update(last=time.time(), err="", last_file=dest.name, last_size=dest.stat().st_size)
        log.info("Copie de siguranță: %s (%s)", dest.name, fmt_size(dest.stat().st_size))
        return dest
    except HTTPException:
        raise
    except Exception as e:
        BK["err"] = str(e)[:200]
        log.warning("Copie de siguranță eșuată: %s", e)
        raise
    finally:
        BK["running"] = False


def restore_backup(zpath):
    """Inlocuieste baza de date si subtitrarile cu cele din arhiva. Nu atinge fisierele video."""
    import zipfile
    zpath = Path(zpath)
    if not zipfile.is_zipfile(zpath):
        raise HTTPException(400, "Fișierul nu este o arhivă de backup validă")
    tmp = Path(tempfile.mkdtemp(prefix="cvrs", dir=str(DATA)))
    try:
        with zipfile.ZipFile(zpath) as z:
            names = z.namelist()
            if "cineverse.db" not in names:
                raise HTTPException(400, "Arhiva nu conține baza de date CineVerse")
            for n in names:                                   # nu extragem cai in afara folderului
                if n.startswith("/") or ".." in Path(n).parts:
                    raise HTTPException(400, "Arhiva conține căi nepermise")
            z.extractall(tmp)
        newdb = tmp / "cineverse.db"
        try:
            man = json.loads((tmp / "manifest.json").read_text(encoding="utf-8"))
        except Exception:
            man = {}
        scope = man.get("scope") or "full"                    # arhivele vechi sunt complete
        con = sqlite3.connect(str(newdb))
        try:
            tabs = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            if not {"users", "settings"} <= tabs:
                raise HTTPException(400, "Baza de date din arhivă nu pare să fie de la CineVerse")
            if not con.execute("SELECT COUNT(*) FROM users WHERE admin=1").fetchone()[0]:
                raise HTTPException(400, "Arhiva nu conține niciun cont de administrator")
            with _wlock:
                for s_ in list(SESSIONS.values()):            # oprim redarile in curs
                    try:
                        s_.kill()
                    except Exception:
                        pass
                SESSIONS.clear()
                with ALOCK:
                    ACTIVE.clear()
                if scope == "config":
                    _restore_config(newdb)                    # pastram biblioteca existenta
                else:
                    con.backup(db())                          # inlocuim tot continutul bazei
                    db().commit()
        finally:
            con.close()
        subs_src = tmp / "subs"
        if subs_src.is_dir():
            SUBS.mkdir(parents=True, exist_ok=True)
            for f in subs_src.rglob("*"):
                if f.is_file():
                    t = SUBS / f.relative_to(subs_src)
                    t.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(f, t)
        img_src = tmp / "images"
        if img_src.is_dir():
            IMG.mkdir(parents=True, exist_ok=True)
            for f in img_src.rglob("*"):
                if f.is_file():
                    t = IMG / f.relative_to(img_src)
                    t.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(f, t)
        init_db()                                             # aplicam migrarile, daca arhiva e mai veche
        _srv_nets.update(t=0)
        log.info("Restaurare din %s reușită", zpath.name)
        return True
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _restore_config(newdb):
    """Aduce inapoi doar setarile, conturile si canalele TV. Biblioteca de pe disc ramane cum e."""
    c = db()
    c.execute("PRAGMA foreign_keys=OFF")
    c.execute("ATTACH DATABASE ? AS bk", (str(newdb),))
    try:
        for t in CONFIG_TABLES:
            have = [r[1] for r in c.execute(f"PRAGMA table_info({t})")]
            src = [r[1] for r in c.execute(f"PRAGMA bk.table_info({t})")]
            cols = [x_ for x_ in have if x_ in src]           # coloanele comune, daca arhiva e mai veche
            if not cols:
                continue
            names = ",".join('"%s"' % x_ for x_ in cols)
            c.execute(f"DELETE FROM {t}")
            c.execute(f"INSERT INTO {t} ({names}) SELECT {names} FROM bk.{t}")
        c.execute("DELETE FROM sessions")                      # conturile s-au schimbat: toata lumea se reconecteaza
        c.execute("DELETE FROM progress WHERE user_id NOT IN (SELECT id FROM users)")
        c.execute("DELETE FROM mylist WHERE user_id NOT IN (SELECT id FROM users)")
        c.commit()
    finally:
        c.execute("DETACH DATABASE bk")
        c.execute("PRAGMA foreign_keys=ON")


def backup_worker():
    time.sleep(90)
    while True:
        try:
            mode = S("backup_auto")
            if mode in ("daily", "weekly"):
                iv = 86400 if mode == "daily" else 7 * 86400
                last = BK["last"] or max([f.stat().st_mtime for f in backup_dir().glob("cineverse-*.zip")] or [0])
                if time.time() - last > iv:
                    backup_now()
        except Exception as e:
            log.warning("backup automat: %s", e)
        time.sleep(900)


def backup_list():
    out = []
    try:
        for f in sorted(backup_dir().glob("cineverse-*.zip"), key=lambda f: f.stat().st_mtime, reverse=True):
            if BK_NAME.match(f.name):
                out.append({"name": f.name, "size": f.stat().st_size, "size_h": fmt_size(f.stat().st_size), "t": f.stat().st_mtime})
    except Exception:
        pass
    return out


@app.get("/api/admin/backup")
def admin_backup_info(req: Request):
    need_admin(req)
    return {"files": backup_list(), "dir": str(backup_dir()), "running": BK["running"], "last": BK["last"],
            "err": BK["err"], "auto": S("backup_auto"), "keep": S("backup_keep"), "images": S("backup_images") == "1",
            "scope": S("backup_scope") or "config"}


@app.post("/api/admin/backup/settings")
async def admin_backup_settings(req: Request):
    need_admin(req)
    d = await req.json()
    if "auto" in d:
        set_S("backup_auto", d["auto"] if d["auto"] in ("off", "daily", "weekly") else "off")
    if "keep" in d:
        set_S("backup_keep", max(1, min(100, int(d["keep"] or 7))))
    if "images" in d:
        set_S("backup_images", "1" if d["images"] else "0")
    if "scope" in d:
        set_S("backup_scope", d["scope"] if d["scope"] in ("config", "full") else "config")
    if "dir" in d:
        nd = (d["dir"] or "").strip()
        if nd:
            try:
                Path(nd).mkdir(parents=True, exist_ok=True)
                (Path(nd) / ".cvtest").write_text("ok")
                (Path(nd) / ".cvtest").unlink()
            except Exception as e:
                raise HTTPException(400, f"Nu pot scrie în folderul ales: {e}")
        set_S("backup_dir", nd)
    return {"ok": True}


@app.post("/api/admin/backup/run")
async def admin_backup_run(req: Request):
    need_admin(req)
    d = await req.json() if req.headers.get("content-length") else {}
    f = await asyncio.to_thread(backup_now, d.get("images"), d.get("scope"))
    return {"ok": True, "name": f.name, "size": f.stat().st_size}


@app.get("/api/admin/backup/download")
async def admin_backup_download(req: Request, name: str = "", images: int = 0, scope: str = ""):
    need_admin(req)
    if name:                                        # o copie deja existenta
        if not BK_NAME.match(name):
            raise HTTPException(400)
        f = backup_dir() / name
        if not f.exists():
            raise HTTPException(404)
        return FileResponse(f, media_type="application/zip", filename=name)
    tmpd = Path(tempfile.mkdtemp(prefix="cvdl", dir=str(DATA)))     # copie proaspata, doar pentru descarcare
    dest = tmpd / time.strftime("cineverse-%Y%m%d-%H%M.zip")
    try:
        await asyncio.to_thread(make_backup, dest, bool(images), scope or None)
    except Exception:
        shutil.rmtree(tmpd, ignore_errors=True)
        raise
    return FileResponse(dest, media_type="application/zip", filename=dest.name,
                        background=BackgroundTask(shutil.rmtree, str(tmpd), True))


@app.delete("/api/admin/backup/{name}")
def admin_backup_del(name: str, req: Request):
    need_admin(req)
    if not BK_NAME.match(name):
        raise HTTPException(400)
    (backup_dir() / name).unlink(missing_ok=True)
    return {"ok": True}


@app.post("/api/admin/backup/{name}/restore")
async def admin_backup_restore_local(name: str, req: Request):
    need_admin(req)
    if not BK_NAME.match(name):
        raise HTTPException(400)
    f = backup_dir() / name
    if not f.exists():
        raise HTTPException(404)
    await asyncio.to_thread(restore_backup, f)
    return {"ok": True}


@app.post("/api/admin/restore")
async def admin_restore_upload(req: Request):
    """Primeste arhiva ca flux brut (fara multipart), ca sa nu avem nevoie de pachete in plus."""
    need_admin(req)
    tmpd = Path(tempfile.mkdtemp(prefix="cvup", dir=str(DATA)))
    up = tmpd / "upload.zip"
    try:
        total = 0
        with open(up, "wb") as f:
            async for chunk in req.stream():
                f.write(chunk)
                total += len(chunk)
                if total > 20 * 1024 ** 3:
                    raise HTTPException(413, "Fișier prea mare")
        if not total:
            raise HTTPException(400, "Nu am primit niciun fișier")
        await asyncio.to_thread(restore_backup, up)
        return {"ok": True}
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)


# ---------------------------------------------------------------- admin
@app.get("/api/admin/network")
def network_status(req: Request):
    need_admin(req)
    return {"ip": client_ip(req), "remote": is_remote(req), "qualities": [{"key": x[0], "label": x[4]} for x in QUALITIES],
            "server_nets": [str(n) for n in server_nets()],
            "cast": {"ok": CAST["ok"], "err": CAST["err"], "devices": cast_devices(), "hosts": cast_hosts()}}


@app.post("/api/admin/cast/rescan")
def cast_rescan(req: Request):
    need_admin(req)
    threading.Thread(target=cast_init, daemon=True).start()
    return {"ok": True}


@app.get("/api/admin/activity")
def admin_activity(req: Request, user: int = 0):
    need_admin(req)
    active_for(-1)
    now = time.time()
    with ALOCK:
        act = [dict(e) for e in ACTIVE.values()]
    out = []
    for e in act:
        out.append({"kind": "play", "uid": e["uid"], "client": e["client"], "user": e.get("user"), "device": e.get("device"), "ip": e.get("ip"),
                    "remote": e.get("remote"), "title": e.get("title"), "item_id": e.get("item_id"), "img": e.get("img"),
                    "pos": e.get("pos", 0), "duration": e.get("duration", 0), "paused": e.get("paused", False),
                    "started": e.get("started"), "idle": now - e.get("last_ping", now),
                    "audio": e.get("audio_label"), "sub": e.get("sub_label", "—"), "details": e.get("details", {}),
                    "bps": real_bps(e), "bw": fmt_bps(real_bps(e)) if real_bps(e) else ""})
    for uid, a in list(CAST_ACTIVE.items()):
        cc = CAST_CC.get(a["device"])
        ms = cc.media_controller.status if cc else None
        st = CAST_STREAMS.get(a["token"])
        m = q("SELECT * FROM media WHERE id=?", (a.get("media_id"),), one=True) if not a.get("live") else None
        un = (q("SELECT username FROM users WHERE id=?", (uid,), one=True) or {"username": "?"})["username"]
        det = playback_details(m, st.info, a["audio"], "transcode", (st.method.split("/")[-1] if st and st.method else ""), None, False) if m and st else (a.get("details") or {})
        sub = (q("SELECT label FROM subtitles WHERE id=?", (a["sub_id"],), one=True) or {"label": "—"})["label"] if a.get("sub_id") else "Fără"
        out.append({"kind": "cast", "uid": uid, "client": "cast", "user": un, "device": f"Chromecast · {a['device_name']}", "ip": "rețea locală",
                    "remote": False, "title": a["title"], "item_id": a["item_id"], "img": a.get("img"),
                    "pos": (ms.adjusted_current_time if ms and ms.adjusted_current_time is not None else a.get("pos", 0)), "duration": a["duration"],
                    "paused": bool(ms and ms.player_state == "PAUSED"), "started": a.get("started"), "idle": 0,
                    "audio": next((LANG_NAMES.get(x_["lang"], x_["lang"]) for x_ in (st.info.get("audio", []) if st else []) if x_["index"] == a.get("audio")), "—"),
                    "sub": sub, "details": det})
    hq = "SELECT * FROM play_log" + (" WHERE user_id=?" if user else "") + " ORDER BY started DESC LIMIT 150"
    hist = [dict(r) for r in q(hq, (user,) if user else ())]
    day0 = time.mktime(time.localtime()[:3] + (0, 0, 0, 0, 0, -1))
    stats = {"now": len(out), "transcoding": sum(1 for o in out if "Transcodare" in (o["details"] or {}).get("method_label", "")),
             "remote": sum(1 for o in out if o["remote"]),
             "today": q("SELECT COUNT(*) c FROM play_log WHERE started>=?", (day0,), one=True)["c"],
             "hours_week": round((q("SELECT SUM(watched) s FROM play_log WHERE started>=?", (now - 7 * 86400,), one=True)["s"] or 0) / 3600, 1)}
    users_ = [{"id": r["id"], "username": r["username"]} for r in q("SELECT id, username FROM users ORDER BY username")]
    return {"now": out, "history": hist, "stats": stats, "users": users_}


@app.post("/api/admin/activity/stop")
async def admin_activity_stop(req: Request):
    need_admin(req)
    d = await req.json()
    uid, client = int(d["uid"]), str(d.get("client") or "")
    if d.get("kind") == "cast":
        await asyncio.to_thread(cast_stop, uid)
        return {"ok": True}
    STOP_REQ.add((uid, client))
    with SLOCK:
        for sid, s_ in list(SESSIONS.items()):
            if s_.user_id == uid and s_.client == client:
                s_.kill()
                SESSIONS.pop(sid, None)
    with ALOCK:
        e = ACTIVE.pop((uid, client), None)
    if e and e.get("log_id"):
        x("UPDATE play_log SET ended=? WHERE id=?", (time.time(), e["log_id"]))
    return {"ok": True}


@app.post("/api/admin/activity/clear")
def admin_activity_clear(req: Request):
    need_admin(req)
    x("DELETE FROM play_log")
    return {"ok": True}


@app.get("/api/admin/status")
def admin_status(req: Request):
    need_admin(req)
    active_for(-1)   # curata intrarile vechi
    with ALOCK:
        act = list(ACTIVE.values())
    sess = [{"user": e.get("user", "?"), "ip": e.get("ip", ""),
             "title": Path((q("SELECT path FROM media WHERE id=?", (e.get("media"),), one=True) or {"path": "?"})["path"]).name,
             "method": e.get("method", ""), "quality": e.get("quality", "orig"), "remote": e.get("remote", False), "paused": False} for e in act]
    return {"version": VERSION, "scan": scan_state, "hw": HW,
            "counts": {"movies": q("SELECT COUNT(*) c FROM items WHERE kind='movie'", one=True)["c"],
                       "series": q("SELECT COUNT(*) c FROM items WHERE kind='series'", one=True)["c"],
                       "files": q("SELECT COUNT(*) c FROM media", one=True)["c"],
                       "unmatched": q("SELECT COUNT(*) c FROM items WHERE matched<>1", one=True)["c"],
                       "with_ro": q("SELECT COUNT(DISTINCT media_id) c FROM subtitles WHERE lang='ro'", one=True)["c"]},
            "subs": {"enabled": opensubs.enabled(), "remaining": opensubs.remaining, "reset": opensubs.reset, "error": opensubs.last_error,
                     "queue": subs_worker.q.qsize() if subs_worker else 0,
                     "logged_in": bool(opensubs.token), "subsro_enabled": subsro.enabled()},
            "sessions": sess}


@app.get("/api/admin/settings")
def get_settings(req: Request):
    need_admin(req)
    d = {k: S(k) for k in DEFAULT_SETTINGS}
    d["os_pass"] = "********" if d["os_pass"] else ""
    d["smtp_pass"] = "********" if d["smtp_pass"] else ""
    d["mail_ready"] = mail_enabled()
    d["mail_err"] = MAIL_STATE["err"]
    return d


@app.post("/api/admin/settings")
async def save_settings(req: Request):
    need_admin(req)
    d = await req.json()
    old_dirs = S("media_dirs")
    old_ch = S("cast_hosts")
    if "remote_max" in d and d["remote_max"] not in QMAP:
        d["remote_max"] = "4M"
    if "download_mode" in d and d["download_mode"] not in ("all", "lan", "off"):
        d["download_mode"] = "all"
    if "session_hours" in d and str(d["session_hours"]) not in SESSION_OPTS:
        raise HTTPException(400, "Valoare invalidă pentru durata sesiunii")
    if "signup_mode" in d and d["signup_mode"] not in ("off", "open", "invite", "approve"):
        d["signup_mode"] = "off"
    if d.get("signup_mode") == "invite" and not (d.get("signup_invite") or S("signup_invite")).strip():
        raise HTTPException(400, "Pentru înscrierea cu invitaţie trebuie să pui un cod.")
    if "smtp_tls" in d and d["smtp_tls"] not in ("starttls", "ssl", "none"):
        d["smtp_tls"] = "starttls"
    if "pw_min" in d:
        try:
            d["pw_min"] = str(max(6, min(64, int(d["pw_min"] or 8))))
        except ValueError:
            d["pw_min"] = "8"
    if d.get("public_url"):
        pu = str(d["public_url"]).strip()
        if pu and not re.match(r"^https?://[^\s/]+", pu):
            raise HTTPException(400, "Adresa publică trebuie să înceapă cu http:// sau https://")
    for part in re.split(r"[\s,;]+", d.get("lan_networks", "")):
        if part:
            try:
                ipaddress.ip_network(part, strict=False)
            except ValueError:
                raise HTTPException(400, f"Rețea invalidă: {part}")
    for k in DEFAULT_SETTINGS:
        if k in d:
            if k in ("os_pass", "smtp_pass") and d[k] == "********":
                continue
            set_S(k, str(d[k]).strip())
    opensubs.token = None
    threading.Thread(target=detect_hw, daemon=True).start()
    if d.get("media_dirs", old_dirs) != old_dirs:
        scan_async()
    if S("cast_hosts") != old_ch:
        threading.Thread(target=cast_init, daemon=True).start()
    _srv_nets["t"] = 0
    return {"ok": True}


@app.post("/api/admin/mail/test")
async def admin_mail_test(req: Request):
    u = need_admin(req)
    d = await req.json()
    to = (d.get("to") or _row(u, "email", "") or S("smtp_from")).strip()
    if not to:
        raise HTTPException(400, "Scrie o adresă la care să trimit mesajul de test.")
    try:
        await asyncio.to_thread(send_mail, to, "Test CineVerse",
                                "Acesta este un mesaj de test de la serverul tău CineVerse.\n"
                                "Dacă l-ai primit, trimiterea de e-mailuri funcţionează.\n")
    except Exception as e:
        raise HTTPException(400, "Nu am putut trimite: " + str(e)[:200])
    return {"ok": True, "to": to}


@app.get("/api/admin/pending")
def admin_pending(req: Request):
    need_admin(req)
    rows = q("SELECT id, username, email, email_ok, created, signup_ip FROM users WHERE active=0 ORDER BY created")
    return {"users": [dict(r) for r in rows]}


@app.post("/api/admin/users/{uid}/approve")
def admin_approve(uid: int, req: Request):
    need_admin(req)
    u = q("SELECT * FROM users WHERE id=?", (uid,), one=True)
    if not u:
        raise HTTPException(404)
    x("UPDATE users SET active=1 WHERE id=?", (uid,))
    if _row(u, "email", "") and mail_enabled():
        mail_bg(u["email"], "Contul tău CineVerse a fost aprobat",
                "Salut, " + u["username"] + "!\n\nContul tău a fost aprobat. Te poţi autentifica aici:\n\n"
                + (public_base(req) or "") + "\n")
    log.info("Cont aprobat: %s", u["username"])
    return {"ok": True}


@app.post("/api/admin/service/restart")
async def restart_service(req: Request):
    need_admin(req)
    b = await req.json()
    svc = b.get("service", "")
    allowed = ["qbittorrent-nox"]
    if svc not in allowed:
        raise HTTPException(400, "Serviciu nepermis")
    subprocess.run(["systemctl", "restart", svc], timeout=15)
    return {"ok": True}


@app.post("/api/admin/scan")
def admin_scan(req: Request):
    need_admin(req)
    scan_async()
    return {"ok": True}


@app.post("/api/admin/refresh-metadata")
def refresh_meta(req: Request):
    need_admin(req)
    x("UPDATE items SET matched=0 WHERE matched=2")
    scan_async()
    return {"ok": True}


@app.post("/api/admin/subs-all")
def subs_all(req: Request):
    need_admin(req)
    x("UPDATE media SET subs_checked=0")
    subs_worker.enqueue_all()
    return {"ok": True, "queue": subs_worker.q.qsize()}


@app.get("/api/admin/users")
def users(req: Request):
    need_admin(req)
    now = time.time()
    out = []
    for r in q("SELECT * FROM users ORDER BY id"):
        devs = q("SELECT ip, ua, created, last_seen FROM sessions WHERE user_id=? AND COALESCE(last_seen, created) > ? ORDER BY last_seen DESC",
                 (r["id"], now - session_ttl() if session_ttl() else 0))
        out.append({"id": r["id"], "username": r["username"], "admin": bool(r["admin"]), "remote_ok": bool(r["remote_ok"]),
                    "max_q": r["max_q"] or "", "max_streams": r["max_streams"] or 0, "can_download": bool(r["can_download"]), "live_ok": bool(r["live_ok"]),
                    "libs": (user_libs(r) if user_libs(r) is not None else [l_["path"] for l_ in libs_all()]),
                    "all_libs": user_libs(r) is None,
                    "email": _row(r, "email", ""), "email_ok": bool(_row(r, "email_ok", 1)),
                    "active": bool(_row(r, "active", 1)), "has_2fa": bool(_row(r, "totp", "")),
                    "devices": [{"ip": dv["ip"], "ua": dv["ua"], "created": dv["created"], "last_seen": dv["last_seen"]} for dv in devs],
                    "playing": len(active_for(r["id"]))})
    return {"users": out, "qualities": [{"key": x_[0], "label": x_[4]} for x_ in QUALITIES], "libraries": libs_all()}


def _user_perms(uid, d):
    if "remote_ok" in d:
        x("UPDATE users SET remote_ok=? WHERE id=?", (1 if d["remote_ok"] else 0, uid))
    if "max_q" in d:
        x("UPDATE users SET max_q=? WHERE id=?", (d["max_q"] if d["max_q"] in QMAP else "", uid))
    if "max_streams" in d:
        x("UPDATE users SET max_streams=? WHERE id=?", (max(0, min(10, int(d["max_streams"] or 0))), uid))
    if "live_ok" in d:
        x("UPDATE users SET live_ok=? WHERE id=?", (1 if d["live_ok"] else 0, uid))
    if "can_download" in d:
        x("UPDATE users SET can_download=? WHERE id=?", (1 if d["can_download"] else 0, uid))
    if "email" in d:
        em = (d["email"] or "").strip().lower()
        if em and not EMAIL_RE.match(em):
            raise HTTPException(400, "Adresa de e-mail nu pare validă.")
        if em and q("SELECT 1 FROM users WHERE email=? AND id<>?", (em, uid), one=True):
            raise HTTPException(400, "Alt cont foloseşte deja această adresă.")
        x("UPDATE users SET email=?, email_ok=1 WHERE id=?", (em, uid))
    if "active" in d:
        x("UPDATE users SET active=? WHERE id=?", (1 if d["active"] else 0, uid))
        if not d["active"]:
            x("DELETE FROM sessions WHERE user_id=?", (uid,))
    if "libs" in d:
        dirs = media_dirs()
        sel = [p_ for p_ in (d["libs"] or []) if p_ in dirs]
        if len(sel) == len(dirs):
            val = ""                   # toate bifate = acces complet, inclusiv la bibliotecile adaugate ulterior
        elif not sel:
            val = "-"                  # niciuna bifata = nu vede nimic
        else:
            val = "\n".join(sel)
        x("UPDATE users SET libs=? WHERE id=?", (val, uid))


@app.post("/api/admin/users")
async def add_user(req: Request):
    need_admin(req)
    d = await req.json()
    if not (d.get("username") or "").strip() or len(d.get("password") or "") < 4:
        raise HTTPException(400, "Nume și parolă (min. 4 caractere) obligatorii")
    try:
        uid = create_user(d["username"], d["password"], False)   # conturile noi sunt mereu utilizatori obisnuiti
    except sqlite3.IntegrityError:
        raise HTTPException(400, "Utilizatorul există deja")
    _user_perms(uid, d)
    return {"ok": True}


@app.post("/api/admin/users/{uid}")
async def edit_user(uid: int, req: Request):
    need_admin(req)
    d = await req.json()
    if d.get("password"):
        x("UPDATE users SET pw=? WHERE id=?", (hash_pw(d["password"]), uid))
        x("DELETE FROM sessions WHERE user_id=?", (uid,))
    if d.get("admin"):
        raise HTTPException(400, "Există un singur cont de administrator")
    _user_perms(uid, d)
    return {"ok": True}


@app.post("/api/admin/users/{uid}/logout")
def admin_logout_user(uid: int, req: Request):
    need_admin(req)
    n = q("SELECT COUNT(*) c FROM sessions WHERE user_id=?", (uid,), one=True)["c"]
    x("DELETE FROM sessions WHERE user_id=?", (uid,))
    with ALOCK:
        for k in [k for k in ACTIVE if k[0] == uid]:
            ACTIVE.pop(k, None)
    with SLOCK:
        for sid, s_ in list(SESSIONS.items()):
            if s_.user_id == uid:
                s_.kill()
                SESSIONS.pop(sid, None)
    return {"ok": True, "closed": n}


@app.get("/api/admin/security")
def security_status(req: Request):
    need_admin(req)
    now = time.time()
    with BF_LOCK:
        blocked = [{"ip": ip, "until": t} for ip, t in BF["blocked"].items() if t > now]
        logl = list(BF["log"])[:60]
    return {"blocked": blocked, "log": logl}


@app.post("/api/admin/security/unblock")
async def security_unblock(req: Request):
    need_admin(req)
    d = await req.json()
    with BF_LOCK:
        if d.get("ip") == "*":
            BF["blocked"].clear()
            BF["fails"].clear()
        else:
            BF["blocked"].pop(d.get("ip"), None)
            BF["fails"].pop(d.get("ip"), None)
    return {"ok": True}


@app.delete("/api/admin/users/{uid}")
def del_user(uid: int, req: Request):
    me_ = need_admin(req)
    if me_["id"] == uid or (q("SELECT admin FROM users WHERE id=?", (uid,), one=True) or {"admin": 0})["admin"]:
        raise HTTPException(400, "Contul de administrator nu poate fi șters")
    x("DELETE FROM users WHERE id=?", (uid,))
    return {"ok": True}


@app.get("/api/admin/tmdb-search")
def tmdb_search(req: Request, kind: str, q_: str = "", query: str = ""):
    need_admin(req)
    term = query or q_
    d = tmdb.get("/search/movie" if kind == "movie" else "/search/tv", query=term, language="ro-RO") or {}
    return {"results": [{"id": r["id"], "title": r.get("title") or r.get("name"),
                         "year": (r.get("release_date") or r.get("first_air_date") or "")[:4], "poster": r.get("poster_path"),
                         "overview": (r.get("overview") or "")[:200]} for r in d.get("results", [])[:12]]}


@app.post("/api/admin/item/{item_id}/match")
async def match_item(item_id: int, req: Request):
    need_admin(req)
    d = await req.json()
    it = q("SELECT * FROM items WHERE id=?", (item_id,), one=True)
    if not it:
        raise HTTPException(404)
    if not apply_tmdb(item_id, it["kind"], int(d["tmdb_id"])):
        raise HTTPException(400, "TMDB nu a răspuns (verifică cheia)")
    return {"ok": True}


# ---------------------------------------------------------------- CLI
def cli():
    ap = argparse.ArgumentParser(description="CineVerse media server")
    sub = ap.add_subparsers(dest="cmd")
    r = sub.add_parser("run")
    r.add_argument("--host", default=os.environ.get("CINEVERSE_HOST", "0.0.0.0"))
    r.add_argument("--port", type=int, default=int(os.environ.get("CINEVERSE_PORT", "8200")))
    s = sub.add_parser("setup")
    s.add_argument("--admin-user")
    s.add_argument("--admin-pass")
    for k in DEFAULT_SETTINGS:
        s.add_argument("--" + k.replace("_", "-"))
    sub.add_parser("scan")
    a = ap.parse_args()
    init_db()
    if a.cmd == "setup":
        for k in DEFAULT_SETTINGS:
            v = getattr(a, k)
            if v is not None and v != "":
                set_S(k, v)
        if a.admin_user and a.admin_pass:
            u = q("SELECT id FROM users WHERE username=?", (a.admin_user,), one=True)
            if u:
                x("UPDATE users SET pw=?, admin=1 WHERE id=?", (hash_pw(a.admin_pass), u["id"]))
                uid = u["id"]
            else:
                uid = create_user(a.admin_user, a.admin_pass, True)
            x("UPDATE users SET admin=0 WHERE id<>?", (uid,))
            x("DELETE FROM sessions WHERE user_id=?", (uid,))
        print("Setări salvate.")
    elif a.cmd == "scan":
        global subs_worker
        subs_worker = SubsWorker()
        scan_library()
        print(scan_state)
    else:
        import uvicorn
        log.info("CineVerse by NetStreaming %s pornit pe portul %s", VERSION, a.port)
        global HTTP_PORT
        HTTP_PORT = a.port
        uvicorn.run(app, host=a.host, port=a.port, log_level="warning", proxy_headers=True, forwarded_allow_ips="127.0.0.1,::1")

if __name__ == "__main__":
    cli()
CINEVERSE_PY_EOF

cat > "$APP/static/index.html" <<'CINEVERSE_HTML_EOF'
<!doctype html>
<html lang="ro" id="htmlroot">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#0d1220">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="apple-touch-icon" href="/static/icon-180.png">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="CineVerse">
<title>CineVerse by NetStreaming</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect width='64' height='64' rx='14' fill='%23e50914'/%3E%3Ctext x='32' y='43' font-family='Arial' font-weight='900' font-size='30' fill='white' text-anchor='middle'%3ECV%3C/text%3E%3C/svg%3E">
<style>
:root{--bg:#0d1220;--bg2:#131a2b;--bg3:#232d45;--fg:#fff;--mut:#b3b3b3;--mut2:#808080;--red:#e50914;--red2:#f40612;--green:#46d369;--pad:4%}
*{box-sizing:border-box;margin:0;padding:0}
html,body{background:var(--bg);color:var(--fg);font-family:"Netflix Sans","Helvetica Neue",Segoe UI,Roboto,Ubuntu,Arial,sans-serif;-webkit-font-smoothing:antialiased;overflow-x:hidden}
body{background:radial-gradient(1100px 700px at 85% -10%,rgba(46,84,170,.20),transparent 60%),radial-gradient(900px 600px at -10% 110%,rgba(120,20,40,.12),transparent 60%),var(--bg);background-attachment:fixed}
a{color:inherit;text-decoration:none}
button{font:inherit;color:inherit;background:none;border:0;cursor:pointer}
input,select,textarea{font:inherit}
.hidden{display:none!important}
::-webkit-scrollbar{width:10px;height:10px}::-webkit-scrollbar-thumb{background:#36415c;border-radius:6px}::-webkit-scrollbar-track{background:transparent}

/* ---------- login */
#login{min-height:100vh;display:flex;align-items:center;justify-content:center;background:radial-gradient(ellipse at top,#1d2e5c 0%,#0d1220 55%,#05070d 100%)}
.lbox{background:rgba(9,13,25,.82);border:1px solid rgba(255,255,255,.06);padding:56px 64px;border-radius:6px;width:min(440px,94vw)}
.lbox h1{font-size:32px;margin-bottom:28px}
.lbox input{width:100%;padding:16px;margin-bottom:14px;background:#28324a;border:1px solid #445070;border-radius:4px;color:#fff}
.lbox input:focus{outline:none;border-color:#fff}
.btn-red{background:var(--red);color:#fff;border-radius:4px;padding:14px;font-weight:700;width:100%;font-size:16px}
.btn-red:hover{background:var(--red2)}
.err{color:#e87c03;margin:6px 0 12px;min-height:18px;font-size:14px}
.lalt{display:flex;justify-content:space-between;gap:14px;margin-top:18px;font-size:14px;flex-wrap:wrap}
.lalt a{color:#9aa3b8}.lalt a:hover{color:#fff;text-decoration:underline}
.lhint{color:#8a93a8;font-size:13px;line-height:1.5;margin-bottom:6px}
.okmsg{color:var(--green);font-size:14px;line-height:1.5;margin:10px 0}
.codes{background:#0b1120;border:1px solid #36415c;border-radius:6px;padding:14px 18px;margin:12px 0;font-family:ui-monospace,monospace;font-size:15px;line-height:1.9;letter-spacing:1px}
.secbox{background:#0b1120;border:1px solid #36415c;border-radius:6px;padding:16px;margin:12px 0;font-family:ui-monospace,monospace;font-size:19px;letter-spacing:3px;text-align:center;word-break:break-all}
.logo{color:var(--red);font-weight:900;letter-spacing:.5px;font-size:30px;text-transform:uppercase;font-family:Impact,"Bebas Neue","Arial Narrow",sans-serif;transform:scaleY(1.1)}

/* ---------- nav */
#nav{position:fixed;top:0;left:0;right:0;z-index:50;display:flex;align-items:center;gap:28px;padding:0 var(--pad);height:68px;
  background:linear-gradient(180deg,rgba(0,0,0,.75) 10%,transparent);transition:background .4s}
#nav.solid{background:#0d1220}
#nav .links{display:flex;gap:20px;font-size:14px}
#nav .links a{color:#e5e5e5;transition:color .3s}#nav .links a:hover{color:#b3b3b3}#nav .links a.on{color:#fff;font-weight:700}
#nav .right{margin-left:auto;display:flex;align-items:center;gap:18px}
.sbox{display:flex;align-items:center;border:1px solid transparent;padding:4px 6px;transition:all .3s}
.sbox.open{border-color:#fff;background:rgba(0,0,0,.75)}
.sbox input{width:0;background:none;border:0;color:#fff;outline:none;transition:width .3s;font-size:14px}
.sbox.open input{width:220px;padding-left:8px}
.avatar{width:32px;height:32px;border-radius:4px;background:linear-gradient(135deg,#e50914,#b20710);display:flex;align-items:center;justify-content:center;font-weight:700;text-transform:uppercase}
.umenu{position:relative}
.umenu .dd{position:absolute;right:0;top:44px;background:rgba(10,15,28,.97);border:1px solid #28324a;min-width:190px;padding:8px 0;display:none}
.umenu:hover .dd,.umenu.open .dd{display:block}
.dd button,.dd a{display:block;width:100%;text-align:left;padding:10px 16px;font-size:14px}.dd button:hover{text-decoration:underline}
.ico{width:24px;height:24px;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}

/* ---------- hero */
#hero{position:relative;height:56.25vw;max-height:88vh;min-height:460px;overflow:hidden}
#hero .bg{position:absolute;inset:0;background-size:cover;background-position:center top;transition:opacity 1s}
#hero .shade{position:absolute;inset:0;background:linear-gradient(77deg,rgba(0,0,0,.75) 0%,rgba(0,0,0,.25) 45%,transparent 70%),linear-gradient(0deg,#0d1220 0%,rgba(13,18,32,.4) 16%,transparent 32%)}
#hero .info{position:absolute;left:var(--pad);bottom:28%;width:38%;min-width:320px}
#hero .tlogo{max-width:90%;max-height:170px;margin-bottom:18px;filter:drop-shadow(0 2px 8px rgba(0,0,0,.6))}
#hero h2{font-size:clamp(34px,4.6vw,72px);font-weight:900;line-height:1;margin-bottom:16px;text-shadow:2px 2px 6px rgba(0,0,0,.5)}
#hero .meta{margin-bottom:12px}
#hero p{font-size:clamp(14px,1.25vw,19px);line-height:1.35;text-shadow:2px 2px 4px rgba(0,0,0,.55);display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden}
.btns{display:flex;gap:12px;margin-top:22px;flex-wrap:wrap}
.bplay{display:inline-flex;align-items:center;gap:10px;background:#fff;color:#000;border-radius:4px;padding:10px 26px 10px 20px;font-weight:700;font-size:clamp(14px,1.3vw,19px)}
.bplay:hover{background:rgba(255,255,255,.75)}
.binfo{display:inline-flex;align-items:center;gap:10px;background:rgba(109,109,110,.7);color:#fff;border-radius:4px;padding:10px 26px 10px 20px;font-weight:700;font-size:clamp(14px,1.3vw,19px)}
.binfo:hover{background:rgba(109,109,110,.4)}
.bplay svg,.binfo svg{width:26px;height:26px}
.cert{border:1px solid rgba(255,255,255,.4);padding:0 6px;font-size:.85em;border-radius:2px}
.match{color:var(--green);font-weight:700}
.meta{display:flex;align-items:center;gap:10px;flex-wrap:wrap;font-size:15px;color:#ddd}
.qual{border:1px solid rgba(255,255,255,.4);border-radius:3px;font-size:11px;padding:0 5px;font-weight:700}

/* ---------- rows */
#rows{position:relative;margin-top:-9vw;z-index:2;padding-bottom:60px}
#rows.nohero{margin-top:90px}
.row{margin:0 0 3.2vw;position:relative;z-index:1}.row:hover{z-index:4}
.row h3{padding:0 var(--pad);font-size:clamp(15px,1.45vw,22px);font-weight:700;margin-bottom:10px;color:#e5e5e5}
.slider{position:relative}
.track{display:flex;gap:6px;overflow-x:auto;overflow-y:visible;padding:40px var(--pad) 170px;margin:-40px 0 -170px;pointer-events:none;scroll-behavior:smooth;scrollbar-width:none}
.track::-webkit-scrollbar{display:none}
.arrow{position:absolute;top:0;height:calc((100vw - 2*var(--pad))/6*9/16);width:var(--pad);z-index:5;background:rgba(13,18,32,.5);display:flex;align-items:center;justify-content:center;opacity:0;transition:opacity .2s}
.slider:hover .arrow{opacity:1}.arrow:hover{background:rgba(13,18,32,.75)}
.arrow.l{left:0}.arrow.r{right:0}.arrow svg{width:34px;height:34px;transition:transform .2s}.arrow:hover svg{transform:scale(1.3)}
.card{pointer-events:auto;flex:0 0 calc((100vw - 2*var(--pad) - 5*6px)/6);position:relative;border-radius:4px;transition:transform .3s .1s,box-shadow .3s .1s;cursor:pointer;z-index:1}
@media(max-width:1400px){.card{flex-basis:calc((100vw - 2*var(--pad) - 4*6px)/5)}}
@media(max-width:1100px){.card{flex-basis:calc((100vw - 2*var(--pad) - 3*6px)/4)}}
@media(max-width:800px){.card{flex-basis:calc((100vw - 2*var(--pad) - 2*6px)/3)}}
@media(max-width:500px){.card{flex-basis:calc((100vw - 2*var(--pad) - 6px)/2.2)}}
.card .thumb{aspect-ratio:16/9;border-radius:4px;overflow:hidden;background:#172036 center/cover no-repeat;position:relative}
.card .thumb .ttl{position:absolute;left:8px;right:8px;bottom:8px;font-weight:800;font-size:clamp(12px,1.1vw,17px);text-shadow:0 1px 4px #000;line-height:1.1}
.card .thumb .ttl img{max-width:70%;max-height:45px;display:block}
.card .thumb .ph{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;padding:10px;text-align:center;font-weight:800;font-size:clamp(13px,1.3vw,20px);background:linear-gradient(135deg,#2d3852,#111827)}
.card .pbar{position:absolute;left:8%;right:8%;bottom:6px;height:3px;background:#4a5675}.card .pbar i{display:block;height:100%;background:var(--red)}
.card .rank{position:absolute;top:0;right:0;background:var(--red);font-size:10px;font-weight:800;padding:3px 5px;border-radius:0 4px 0 4px;line-height:1.1;text-align:center}
.card .more{position:absolute;left:0;right:0;top:100%;background:var(--bg2);padding:12px 12px 14px;border-radius:0 0 6px 6px;opacity:0;pointer-events:none;box-shadow:0 8px 16px rgba(0,0,0,.7);transition:opacity .2s .1s}
.card:hover{transform:scale(1.35) translateY(-12%);z-index:10;box-shadow:0 8px 20px rgba(0,0,0,.75)}
.card:hover .thumb{border-radius:6px 6px 0 0}
.card:hover .more{opacity:1;pointer-events:auto}
.track .card:first-child:hover{transform-origin:left center}.track .card:last-child:hover{transform-origin:right center}
.more .cb{display:flex;gap:8px;align-items:center;margin-bottom:10px}
.circ{width:32px;height:32px;border-radius:50%;border:2px solid rgba(255,255,255,.5);display:flex;align-items:center;justify-content:center;background:rgba(42,42,42,.6);flex:none}
.circ:hover{border-color:#fff}.circ.w{background:#fff;border-color:#fff;color:#000}.circ svg{width:16px;height:16px}
.circ.r{margin-left:auto}
.more .meta{font-size:11px;gap:6px}
.more .gen{font-size:11px;margin-top:8px;color:#fff}.more .gen span+span:before{content:" • ";color:#646464}
.more .sub{font-size:11px;color:#bbb;margin-top:6px}
@media(hover:none){.card:hover{transform:none}.card .more{display:none}}

/* ---------- grid (browse/search) */
.page{padding:100px var(--pad) 60px}
.page .head{display:flex;align-items:center;gap:22px;margin-bottom:24px;flex-wrap:wrap}
.page h2{font-size:34px}
.sel{background:#000;color:#fff;border:1px solid #fff;padding:4px 10px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:40px 6px}
.grid .card{flex:none;width:auto}
.empty{color:var(--mut);padding:40px 0;font-size:18px}

/* ---------- modal details */
#modal{position:fixed;inset:0;z-index:80;background:rgba(0,0,0,.7);overflow-y:auto;display:flex;justify-content:center;align-items:flex-start;padding:30px 12px}
#modal .box{width:min(880px,100%);background:var(--bg2);border-radius:8px;overflow:hidden;box-shadow:0 10px 40px rgba(0,0,0,.8);position:relative;animation:pop .25s ease}
@keyframes pop{from{transform:scale(.92);opacity:0}}
.mhero{position:relative;aspect-ratio:16/9;background:#000 center/cover}
.mhero:after{content:"";position:absolute;inset:0;background:linear-gradient(0deg,#131a2b 0%,transparent 50%)}
.mhero .mi{position:absolute;left:48px;bottom:40px;right:48px;z-index:2}
.mhero .tlogo{max-width:55%;max-height:130px;margin-bottom:20px}
.mhero h2{font-size:clamp(28px,4vw,46px);font-weight:900;margin-bottom:18px;text-shadow:0 2px 8px #000}
.mclose{position:absolute;top:14px;right:14px;z-index:5;width:38px;height:38px;border-radius:50%;background:#131a2b;display:flex;align-items:center;justify-content:center}
.mclose svg{width:22px;height:22px}
.mbody{padding:0 48px 40px}
.mcols{display:grid;grid-template-columns:2fr 1fr;gap:32px}
.mcols p{line-height:1.5;font-size:15px}
.mcols .tag{font-style:italic;color:#ccc;margin-bottom:10px}
.side{font-size:14px;line-height:1.5;color:#ddd}.side b{color:var(--mut2);font-weight:400}.side div{margin-bottom:10px}
.meta .mut{color:var(--mut)}
.eps h3,.cast h3{font-size:24px;margin:34px 0 14px;display:flex;align-items:center;justify-content:space-between;gap:12px}
.ep{display:grid;grid-template-columns:34px 150px 1fr;gap:16px;align-items:center;padding:18px 16px;border-bottom:1px solid #313c57;border-radius:4px;cursor:pointer}
.ep:hover,.ep.cur{background:#28324a}
.ep .n{font-size:24px;color:#d2d2d2;text-align:center}
.ep .st{aspect-ratio:16/9;background:#1e273d center/cover;border-radius:4px;position:relative;overflow:hidden}
.ep .st .pl{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;opacity:0;transition:.2s}
.ep:hover .st .pl{opacity:1}.ep .st .pl span{width:42px;height:42px;border:2px solid #fff;border-radius:50%;background:rgba(30,30,30,.5);display:flex;align-items:center;justify-content:center}
.ep .st .pbar{position:absolute;left:0;right:0;bottom:0;height:4px;background:#4a5675}.ep .st .pbar i{display:block;height:100%;background:var(--red)}
.ep .t{display:flex;justify-content:space-between;font-weight:700;margin-bottom:6px;gap:10px}
.ep .t span:last-child{font-weight:400;color:#ddd;flex:none}
.ep p{font-size:13px;color:var(--mut);line-height:1.4;display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden}
.ep .badge{font-size:10px;border:1px solid #666;border-radius:3px;padding:0 4px;margin-left:6px;color:#bbb;font-weight:400}
.ep .wd{color:var(--green)}
.cast .people{display:grid;grid-template-columns:repeat(auto-fill,minmax(96px,1fr));gap:14px}
.person{text-align:center;font-size:12px}.person .ph{width:84px;height:84px;border-radius:50%;background:#28324a center/cover;margin:0 auto 6px}
.person .ch{color:var(--mut2)}
.adminbar{margin-top:30px;padding-top:18px;border-top:1px solid #28324a;display:flex;gap:10px;flex-wrap:wrap}
.bsm{background:#28324a;border-radius:4px;padding:8px 14px;font-size:13px}.bsm:hover{background:#36415c}
.bsm.red{background:var(--red)}
.resume{margin-top:14px;max-width:360px}.resume .bar{height:4px;background:#445070;border-radius:2px;margin-bottom:6px}.resume .bar i{display:block;height:100%;background:var(--red)}
.resume small{color:#ccc}
@media(max-width:700px){.mcols{grid-template-columns:1fr}.mbody{padding:0 18px 30px}.mhero .mi{left:18px;right:18px;bottom:20px}.ep{grid-template-columns:1fr;}.ep .n{display:none}}

/* ---------- player */
#player{position:fixed;inset:0;z-index:100;background:rgba(4,7,14,.88);-webkit-backdrop-filter:blur(8px);backdrop-filter:blur(8px);
  display:flex;align-items:center;justify-content:center;padding:14px}
.pwin{position:relative;width:min(1100px,94vw,calc((100vh - 28px)*16/9));aspect-ratio:16/9;min-height:min(300px,72vh);background:#000;border-radius:10px;overflow:hidden;
  box-shadow:0 24px 70px rgba(0,0,0,.85),0 0 0 1px rgba(255,255,255,.07);cursor:none;container-type:size}
#player.ui .pwin{cursor:default}
body.fs #player{background:#000;-webkit-backdrop-filter:none;backdrop-filter:none;padding:0}
body.fs .pwin{width:100vw;height:100vh;max-height:none;aspect-ratio:auto;border-radius:0;box-shadow:none}
#player video{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;background:#000}
#subsbox{position:absolute;left:5%;right:5%;bottom:max(8%,14px);text-align:center;pointer-events:none;transition:bottom .25s;z-index:3}
#player.ui #subsbox{bottom:max(17%,66px)}
body.fs #player.ui #subsbox{bottom:17%}
#subsbox span{display:inline;font-size:var(--subsz,4.2vh);line-height:1.25;color:#fff;font-weight:600;
  text-shadow:0 0 4px #000,0 0 4px #000,2px 2px 3px #000,-1px -1px 2px #000;background:var(--subbg,transparent);padding:0 .2em;-webkit-box-decoration-break:clone;box-decoration-break:clone}
.pui{position:absolute;inset:0;opacity:0;transition:opacity .35s;pointer-events:none;z-index:4}
#player.ui .pui{opacity:1;pointer-events:auto}
.ptop{position:absolute;top:0;left:0;right:0;padding:14px 18px;display:flex;align-items:center;gap:18px;background:linear-gradient(180deg,rgba(0,0,0,.7),transparent)}
.ptop svg{width:28px;height:28px}
.pbot{position:absolute;left:0;right:0;bottom:0;padding:0 18px 14px;background:linear-gradient(0deg,rgba(0,0,0,.85),transparent)}
body.fs .ptop{padding:24px 28px}body.fs .ptop svg{width:34px;height:34px}
body.fs .pbot{padding:0 28px 22px}
.seek{position:relative;height:22px;display:flex;align-items:center;cursor:pointer;margin-bottom:6px}
.seek .rail{position:relative;flex:1;height:4px;background:rgba(255,255,255,.25);transition:height .15s}
.seek:hover .rail{height:7px}
.seek .buf{position:absolute;top:0;bottom:0;left:0;background:rgba(255,255,255,.4)}
.seek .done{position:absolute;top:0;bottom:0;left:0;background:var(--red)}
.seek .knob{position:absolute;top:50%;width:16px;height:16px;margin:-8px 0 0 -8px;background:var(--red);border-radius:50%;transform:scale(0);transition:transform .15s}
.seek:hover .knob{transform:scale(1)}
.seek .tip{position:absolute;bottom:26px;transform:translateX(-50%);background:rgba(0,0,0,.85);padding:4px 8px;border-radius:3px;font-size:13px;display:none}
.seek:hover .tip{display:block}
.seek .left{margin-left:16px;font-size:15px;min-width:64px;text-align:right}
.pctrl{display:flex;align-items:center;gap:22px}
.pctrl button svg{width:30px;height:30px;transition:transform .15s}.pctrl button:hover svg{transform:scale(1.2)}
body.fs .pctrl button svg{width:36px;height:36px}
.pctrl .ptitle{flex:1;text-align:center;font-size:17px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pctrl .ptitle b{margin-right:10px}.pctrl .ptitle span{color:#ccc}
.vol{display:flex;align-items:center;gap:8px}
.vol input{width:0;opacity:0;transition:all .2s;accent-color:var(--red)}.vol:hover input{width:90px;opacity:1}
.pspin{position:absolute;left:50%;top:50%;width:64px;height:64px;margin:-32px;border:5px solid rgba(255,255,255,.2);border-top-color:var(--red);border-radius:50%;animation:spin 1s linear infinite;z-index:5}
@keyframes spin{to{transform:rotate(360deg)}}
.pmenu{position:absolute;right:18px;bottom:76px;background:rgba(27,36,56,.97);border-radius:6px;min-width:280px;max-width:min(560px,86%);max-height:74%;overflow:auto;padding:14px 0;z-index:6;box-shadow:0 6px 24px #000}
body.fs .pmenu{right:28px;bottom:96px;min-width:320px;max-width:min(560px,92vw);max-height:65vh}
.pmenu h4{padding:4px 20px 10px;font-size:18px;display:flex;justify-content:space-between;align-items:center}
.pmenu .opt{display:flex;align-items:center;gap:10px;padding:9px 20px 9px 20px;font-size:15px;color:#bbb;width:100%;text-align:left}
.pmenu .opt:hover{background:rgba(255,255,255,.08);color:#fff}
.pmenu .opt.on{color:#fff;font-weight:700}.pmenu .opt.on:before{content:"✓";width:14px}.pmenu .opt:not(.on):before{content:"";width:14px}
.pmenu .opt small{color:#888;font-weight:400;margin-left:auto;font-size:12px;white-space:nowrap}
.pmenu .sep{height:1px;background:#36415c;margin:8px 0}
.pmenu .rowc{display:flex;align-items:center;gap:8px;padding:8px 20px;font-size:14px;color:#ccc}
.pmenu .rowc button{background:#36415c;border-radius:4px;padding:4px 10px}.pmenu .rowc button:hover{background:#445070}
.pmenu .rowc button.on{background:var(--red);color:#fff}
.cols2{display:grid;grid-template-columns:1fr 1fr}
.nextep{position:absolute;right:18px;bottom:88px;z-index:6;display:flex;gap:10px}
body.fs .nextep{right:28px;bottom:110px}
.nextep button{background:#fff;color:#000;font-weight:700;padding:12px 22px;border-radius:4px;font-size:16px}
.nextep button.sec{background:rgba(80,80,80,.8);color:#fff}
.bigplay{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:90px;height:90px;border-radius:50%;background:rgba(0,0,0,.5);display:flex;align-items:center;justify-content:center;z-index:5;animation:fade .7s forwards}
@keyframes fade{0%{opacity:1;transform:translate(-50%,-50%) scale(.8)}100%{opacity:0;transform:translate(-50%,-50%) scale(1.3)}}
.pinfo{position:absolute;left:18px;top:64px;background:rgba(0,0,0,.6);padding:8px 12px;border-radius:4px;font-size:12px;color:#aaa;z-index:6}
#player.live .seek,#player.live #bnext{display:none!important}

/* ---------- TV live */
.chgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:14px}
.chcard{background:#141c2e;border-radius:6px;padding:12px;cursor:pointer;transition:background .15s}
.chcard:hover{background:#1e2942}
.chlogo{height:64px;display:flex;align-items:center;justify-content:center;margin-bottom:10px}
.chlogo img{max-height:100%;max-width:100%;object-fit:contain}
.chlogo .ph{font-weight:800;font-size:15px;text-align:center;color:#ccc}
.chname{font-weight:700;font-size:14px;margin-bottom:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.chnow{font-size:12px;color:#8a93a8;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.chnow .bar{height:2px;background:#36415c;margin-top:5px;border-radius:2px;overflow:hidden}
.chnow .bar i{display:block;height:100%;background:var(--red)}
.chgroup{color:#888;font-size:11px;text-transform:uppercase;letter-spacing:.5px;margin:20px 0 10px}
.pmenu .chopt{display:flex;align-items:center;gap:10px;padding:8px 20px;font-size:14px;color:#bbb;width:100%;text-align:left}
.pmenu .chopt:hover{background:rgba(255,255,255,.08);color:#fff}
.pmenu .chopt.on{color:#fff;font-weight:700;background:rgba(255,255,255,.05)}
.pmenu .chopt img{width:28px;height:20px;object-fit:contain}
.pmenu .chopt .chn{flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pmenu .chopt small{color:#888;font-size:11px}

/* ---------- admin */
.panel{background:#141c2e;border-radius:8px;padding:24px;margin-bottom:22px}
.panel h3{margin-bottom:16px;font-size:20px}
.fg{display:grid;grid-template-columns:230px 1fr;gap:12px 18px;align-items:center}
.fg label{color:#bbb;font-size:14px}
.fg input,.fg select,.fg textarea{background:#1f2940;border:1px solid #36415c;border-radius:4px;color:#fff;padding:10px;width:100%}
.fg textarea{min-height:90px;font-family:ui-monospace,monospace;font-size:13px}
.fg small{grid-column:2;color:#888;margin-top:-6px;font-size:12px}
.fg small a{color:#e87c03}
.stats{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px}
.stat{background:#1e273d;border-radius:6px;padding:14px}.stat b{font-size:26px;display:block}.stat span{color:#aaa;font-size:13px}
table{width:100%;border-collapse:collapse;font-size:14px}td,th{padding:10px;border-bottom:1px solid #28324a;text-align:left}
.tabs{display:flex;gap:6px;margin-bottom:22px}.tabs button{padding:10px 18px;border-radius:4px;background:#172036}.tabs button.on{background:var(--red)}
.pill{display:inline-block;padding:2px 8px;border-radius:10px;font-size:12px;background:#28324a}.pill.ok{background:#1f5f32}.pill.bad{background:#6b1d1d}
.panel h4.sub{margin:24px 0 12px;font-size:15px;color:#e50914;text-transform:uppercase;letter-spacing:.5px}
.netinfo{background:#1b2438;border-radius:6px;padding:12px 14px;font-size:14px;color:#ccc}
.steps{display:flex;gap:6px;flex-wrap:wrap}.steps button{background:#1f2940;border:1px solid #36415c;border-radius:4px;padding:8px 12px;font-size:13px}
.steps button.on{background:var(--red);border-color:var(--red)}
.ucard{background:#1b2438;border-radius:8px;padding:16px;margin-bottom:14px}
.uhead{display:flex;gap:12px;align-items:center;margin-bottom:12px}
.ugrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:10px}
.ugrid label{font-size:12px;color:#999;display:flex;flex-direction:column;gap:4px}
.ugrid select{background:#111827;border:1px solid #36415c;border-radius:4px;color:#fff;padding:8px}
.bsm:disabled{opacity:.4;cursor:default}
/* ---------- monitorizare sistem ---------- */
.sysgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:14px;margin-bottom:18px}
.tile{background:#141c2e;border:1px solid #232d45;border-radius:10px;padding:16px 18px;position:relative;overflow:hidden}
.tile .lab{font-size:11px;letter-spacing:.7px;text-transform:uppercase;color:#7f8aa3;margin-bottom:6px}
.tile .big{font-size:34px;font-weight:700;line-height:1.05;font-variant-numeric:tabular-nums}
.tile .big small{font-size:15px;font-weight:400;color:#8a93a8;margin-left:4px}
.tile .sub{font-size:12px;color:#8a93a8;margin-top:5px;line-height:1.45}
.tile .spark{margin-top:10px;display:block;width:100%;height:42px}
.bar2{height:8px;background:#232d45;border-radius:4px;overflow:hidden;margin-top:10px}
.bar2 i{display:block;height:100%;border-radius:4px;transition:width .4s}
.cores{display:flex;gap:3px;margin-top:8px;height:38px}
.cores u{flex:1;background:#1c2540;border-radius:3px;display:flex;align-items:flex-end;overflow:hidden;text-decoration:none}
.cores i{width:100%;border-radius:3px;min-height:3px;transition:height .4s,background .4s}
.st{display:inline-flex;align-items:center;gap:6px;font-size:12px;font-weight:600}
.st b{width:9px;height:9px;border-radius:50%;display:inline-block;flex:none}
.legend{display:flex;gap:16px;font-size:12px;color:#aab3c5;margin-top:8px}
.legend span{display:inline-flex;align-items:center;gap:6px}
.legend i{width:11px;height:3px;border-radius:2px;display:inline-block}
.systab{width:100%;border-collapse:collapse;font-size:13px}
.systab td,.systab th{padding:8px 10px;border-bottom:1px solid #232d45;text-align:left;white-space:nowrap}
.systab th{color:#7f8aa3;font-weight:400;font-size:11px;text-transform:uppercase;letter-spacing:.6px}
.systab td.num{text-align:right;font-variant-numeric:tabular-nums}
.syswrap{overflow-x:auto}
.sysnote{background:#1b2438;border:1px solid #2d3852;border-radius:8px;padding:14px 16px;font-size:13px;color:#aab3c5;line-height:1.5}
.libs{margin-top:12px}
.libs>b{display:block;font-size:12px;color:#999;text-transform:uppercase;letter-spacing:.6px;margin-bottom:8px}
.libs .chk{display:flex;flex-wrap:wrap;gap:8px}
.libs label{display:flex;align-items:center;gap:7px;background:#111827;border:1px solid #36415c;border-radius:6px;padding:7px 12px;font-size:13px;cursor:pointer}
.libs label:hover{border-color:#55628a}
.libs input{accent-color:#e50914;width:15px;height:15px}
.libs small{display:block;color:#7f8aa3;font-size:11px;margin-top:8px}
.epback{position:absolute;top:14px;left:14px;z-index:5;display:flex;align-items:center;gap:8px;background:rgba(19,26,43,.85);border-radius:20px;padding:8px 16px 8px 10px;font-size:14px;font-weight:600}
.epback svg{width:18px;height:18px}.epback:hover{background:#28324a}
.epnum{color:#e5e5e5;font-size:15px;font-weight:600;margin-bottom:6px;text-shadow:0 2px 6px #000;letter-spacing:.3px}
.epnav{display:flex;justify-content:space-between;gap:10px;margin-top:30px;padding-top:18px;border-top:1px solid #28324a}
.ep .st .pl span{cursor:pointer}.ep .st .pl span:hover{background:rgba(229,9,20,.85);border-color:#e50914}
.brandwrap{display:inline-flex;flex-direction:column;line-height:1;text-decoration:none}
.brandwrap .by{font-size:10px;letter-spacing:2.2px;text-transform:uppercase;color:#b3b3b3;margin-top:3px;font-weight:600;align-self:flex-end}
#nav{padding-top:env(safe-area-inset-top);height:calc(68px + env(safe-area-inset-top));padding-left:max(var(--pad),env(safe-area-inset-left));padding-right:max(var(--pad),env(safe-area-inset-right))}
body.fs .ptop{padding-top:max(24px,env(safe-area-inset-top));padding-left:max(28px,env(safe-area-inset-left))}
body.fs .pbot{padding-bottom:max(22px,env(safe-area-inset-bottom));padding-left:max(28px,env(safe-area-inset-left));padding-right:max(28px,env(safe-area-inset-right))}
#modal{padding-top:max(30px,env(safe-area-inset-top))}
.apphint{position:fixed;left:12px;right:12px;bottom:calc(12px + env(safe-area-inset-bottom));z-index:150;background:#1b2438;border:1px solid #36415c;border-radius:10px;padding:14px 44px 14px 14px;font-size:14px;line-height:1.45;box-shadow:0 8px 30px rgba(0,0,0,.7)}
.apphint b{color:#fff}.apphint .x{position:absolute;right:8px;top:8px;width:28px;height:28px;border-radius:50%;background:#28324a;display:flex;align-items:center;justify-content:center}
.apphint a{color:#e50914;font-weight:700}
.castbtn{display:flex;align-items:center;color:#fff}.castbtn.on{color:#e50914}
.castbtn svg{width:26px;height:26px}.pctrl .castbtn svg{width:28px;height:28px}body.fs .pctrl .castbtn svg{width:32px;height:32px}
.castmenu{position:fixed;z-index:160;background:rgba(19,26,43,.98);border:1px solid #28324a;border-radius:8px;min-width:260px;padding:8px 0;box-shadow:0 10px 30px rgba(0,0,0,.7)}
.castmenu h4{padding:8px 16px 10px;font-size:13px;color:#999;text-transform:uppercase;letter-spacing:1px}
.castmenu button{display:flex;align-items:center;gap:12px;width:100%;padding:11px 16px;text-align:left;font-size:15px;color:#ddd}
.castmenu button:hover{background:#28324a;color:#fff}.castmenu button.on{color:#fff;font-weight:700}.castmenu button.on:after{content:"✓";margin-left:auto;color:#e50914}
.castmenu button small{display:block;color:#888;font-size:11px;font-weight:400}.castmenu .sep{height:1px;background:#28324a;margin:6px 0}
.castmenu svg{width:22px;height:22px;flex:none}
#castbar{position:fixed;left:0;right:0;bottom:0;z-index:90;background:rgba(13,18,32,.97);border-top:1px solid #28324a;padding-bottom:env(safe-area-inset-bottom);box-shadow:0 -8px 24px rgba(0,0,0,.6)}
body.casting{padding-bottom:84px}
.cbseek{position:relative;height:14px;margin-top:-7px;cursor:pointer;display:flex;align-items:center}
.cbseek .rail{flex:1;height:4px;background:#36415c}.cbseek .rail i{display:block;height:100%;width:0;background:#e50914}
.cbseek .tip{position:absolute;bottom:18px;transform:translateX(-50%);background:#000;padding:3px 7px;border-radius:3px;font-size:12px;display:none}.cbseek:hover .tip{display:block}
.cbrow{display:flex;align-items:center;gap:14px;padding:8px var(--pad) 10px}
.cbimg{width:96px;aspect-ratio:16/9;border-radius:4px;background:#28324a center/cover;flex:none}
.cbinfo{flex:1;min-width:0}.cbinfo b{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:15px}
.cbinfo small{color:#e50914;font-size:12px;display:flex;align-items:center;gap:6px}
.cbctl{display:flex;align-items:center;gap:14px}.cbctl button svg{width:28px;height:28px}.cbctl .cbmain svg{width:38px;height:38px}
.cbtime{font-size:13px;color:#bbb;min-width:110px;text-align:center;font-variant-numeric:tabular-nums}
.cbvol{display:flex;align-items:center;gap:6px}.cbvol input{width:90px;accent-color:#e50914}
#cbsub{background:#1f2940;color:#fff;border:1px solid #36415c;border-radius:4px;padding:6px;max-width:170px}
@media(max-width:800px){.cbvol,.cbtime,#cbsub{display:none}.cbimg{width:64px}.cbctl{gap:8px}.cbctl button svg{width:24px;height:24px}.cbctl .cbmain svg{width:32px;height:32px}}
.subpick{margin-top:18px;display:flex;flex-wrap:wrap;align-items:center;gap:10px}
.subpick label{color:#999;font-size:14px}
.subpick select{background:#1f2940;color:#fff;border:1px solid #445070;border-radius:4px;padding:8px 10px;font-size:14px;max-width:100%;min-width:220px}
.subres{flex-basis:100%;display:flex;flex-direction:column;gap:6px}
.subopt{display:flex;justify-content:space-between;gap:10px;text-align:left;background:#1b2438;border:1px solid #2d3852;border-radius:4px;padding:9px 12px;font-size:13px;color:#ddd}
.subopt:hover{border-color:#e50914;color:#fff}.subopt small{color:#888;white-space:nowrap}
.actcard{display:flex;gap:16px;background:#1b2438;border:1px solid #28324a;border-radius:10px;padding:14px;margin-bottom:12px}
.actimg{width:190px;aspect-ratio:16/9;border-radius:6px;background:#28324a center/cover;flex:none;position:relative}
.actstate{position:absolute;left:8px;bottom:8px;background:rgba(0,0,0,.7);border-radius:14px;padding:2px 9px;font-size:13px}
.actmain{flex:1;min-width:0}.acttop{display:flex;justify-content:space-between;gap:12px;align-items:flex-start}
.acttitle{font-size:17px}.actwho{color:#aab3c5;font-size:13px;margin-top:5px;display:flex;align-items:center;gap:6px;flex-wrap:wrap}
.actprog{display:flex;align-items:center;gap:10px;margin:10px 0 12px}.actprog .bar{flex:1;height:5px;background:#36415c;border-radius:3px;overflow:hidden}
.actprog .bar i{display:block;height:100%;background:#e50914}.actprog span{font-size:12px;color:#aab3c5;font-variant-numeric:tabular-nums}
.actgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:8px 18px;font-size:13px;color:#e4e8f0}
.actgrid span{display:block;color:#7f8aa3;font-size:11px;text-transform:uppercase;letter-spacing:.6px;margin-bottom:2px}
.acthist td,.acthist th{font-size:13px;white-space:nowrap}
@media(max-width:700px){.actcard{flex-direction:column}.actimg{width:100%}}
#hero .hpost{display:none}
@media(max-width:800px){
  #hero{height:auto;max-height:none;min-height:0;padding:calc(86px + env(safe-area-inset-top)) 0 6px}
  #hero .bg{filter:blur(26px) brightness(.5) saturate(1.2);transform:scale(1.25)}
  #hero .shade{background:linear-gradient(0deg,var(--bg) 0%,rgba(13,18,32,.35) 45%,rgba(13,18,32,.2) 100%)}
  #hero .hpost{display:block;position:relative;width:min(66vw,330px);aspect-ratio:2/3;margin:0 auto;border-radius:12px;background:#1b2438 center/cover;
    box-shadow:0 14px 40px rgba(0,0,0,.65);border:1px solid rgba(255,255,255,.08);cursor:pointer}
  #hero .hpost.wide{width:calc(100% - 32px);aspect-ratio:16/9}
  #hero .info{position:relative;left:auto;bottom:auto;width:auto;min-width:0;padding:18px 16px 0;text-align:center}
  #hero .tlogo{display:block;max-height:60px;max-width:70%;margin:0 auto 10px}
  #hero h2{font-size:28px;margin-bottom:10px}
  #hero .meta{justify-content:center;font-size:14px}
  #hero p{font-size:14px;-webkit-line-clamp:3}
  #hero .btns{justify-content:center;flex-wrap:nowrap;margin-top:16px}
  #hero .bplay,#hero .binfo{flex:1;justify-content:center;padding:11px 10px;font-size:15px;white-space:nowrap}
  #hero .binfo{font-size:14px}
  #rows,#rows.nohero{margin-top:18px}
}
@media(max-width:700px){
  .mhero{aspect-ratio:auto;background-image:none!important;background-color:transparent}
  .mhero:before{content:"";display:block;aspect-ratio:16/9;background:linear-gradient(0deg,#131a2b 0%,transparent 28%),var(--img) center/cover}
  .mhero:after{display:none}
  .mhero .mi{position:relative;left:auto;right:auto;bottom:auto;padding:14px 18px 4px}
  .mhero .tlogo{max-height:56px;max-width:65%;margin-bottom:12px}
  .mhero h2{font-size:26px;text-shadow:none;margin-bottom:12px}
  .mhero .btns{margin-top:12px;gap:8px;flex-wrap:nowrap;align-items:center}
  .mhero .bplay,.mhero .binfo{padding:10px 14px 10px 12px;font-size:15px;white-space:nowrap;gap:6px;flex:0 1 auto;min-width:0}
  .mhero .bplay svg,.mhero .binfo svg{width:22px;height:22px}
  .mhero .btns .circ{width:40px!important;height:40px!important;flex:none}
  .epnum{text-shadow:none}
  .mhero iframe{aspect-ratio:16/9;height:auto!important;bottom:auto!important}
}
.toast{position:fixed;left:50%;bottom:30px;transform:translateX(-50%);background:#fff;color:#000;padding:12px 22px;border-radius:4px;z-index:200;font-weight:600;box-shadow:0 4px 18px rgba(0,0,0,.5)}
.mlist .mr{display:flex;gap:12px;padding:10px;border-radius:4px;cursor:pointer;align-items:flex-start}.mlist .mr:hover{background:#28324a}
.mlist img{width:60px;border-radius:3px}
@media(max-width:800px){.brandwrap .by{font-size:7px;letter-spacing:1px}#nav{gap:10px;padding:0 12px}#nav .logo{font-size:19px!important}#nav .links{min-width:0;overflow-x:auto;scrollbar-width:none}#nav .links::-webkit-scrollbar{display:none}#nav .links a{white-space:nowrap}#nav .right{gap:10px;flex:none}.avatar{width:28px;height:28px}#nav .links{gap:12px;font-size:12px}#nav .logo{font-size:22px}.sbox.open input{width:120px}.arrow{display:none}#hero .info{width:88%;bottom:18%}.fg{grid-template-columns:1fr}.fg small{grid-column:1}.pctrl{gap:12px}.pctrl .ptitle{display:none}.vol input{display:none}}
</style>
</head>
<body>
<svg style="display:none">
 <symbol id="i-play" viewBox="0 0 24 24"><path d="M6 4l14 8-14 8z" fill="currentColor" stroke="none"/></symbol>
 <symbol id="i-pause" viewBox="0 0 24 24"><path d="M6 4h4v16H6zM14 4h4v16h-4z" fill="currentColor" stroke="none"/></symbol>
 <symbol id="i-info" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><path d="M12 16v-5M12 8h.01"/></symbol>
 <symbol id="i-plus" viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></symbol>
 <symbol id="i-check" viewBox="0 0 24 24"><path d="M5 12l5 5L20 7"/></symbol>
 <symbol id="i-down" viewBox="0 0 24 24"><path d="M6 9l6 6 6-6"/></symbol>
 <symbol id="i-left" viewBox="0 0 24 24"><path d="M15 18l-6-6 6-6"/></symbol>
 <symbol id="i-right" viewBox="0 0 24 24"><path d="M9 18l6-6-6-6"/></symbol>
 <symbol id="i-x" viewBox="0 0 24 24"><path d="M18 6L6 18M6 6l12 12"/></symbol>
 <symbol id="i-back" viewBox="0 0 24 24"><path d="M19 12H5M12 19l-7-7 7-7"/></symbol>
 <symbol id="i-search" viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="M21 21l-4.3-4.3"/></symbol>
 <symbol id="i-rw" viewBox="0 0 24 24"><path d="M3 12a9 9 0 1 0 3-6.7L3 8"/><path d="M3 3v5h5"/><text x="12" y="15.5" font-size="7.5" text-anchor="middle" fill="currentColor" stroke="none" font-weight="700">10</text></symbol>
 <symbol id="i-ff" viewBox="0 0 24 24"><path d="M21 12a9 9 0 1 1-3-6.7L21 8"/><path d="M21 3v5h-5"/><text x="12" y="15.5" font-size="7.5" text-anchor="middle" fill="currentColor" stroke="none" font-weight="700">10</text></symbol>
 <symbol id="i-vol" viewBox="0 0 24 24"><path d="M11 5L6 9H2v6h4l5 4z" fill="currentColor"/><path d="M15.5 8.5a5 5 0 0 1 0 7M19 5a10 10 0 0 1 0 14"/></symbol>
 <symbol id="i-mute" viewBox="0 0 24 24"><path d="M11 5L6 9H2v6h4l5 4z" fill="currentColor"/><path d="M23 9l-6 6M17 9l6 6"/></symbol>
 <symbol id="i-subs" viewBox="0 0 24 24"><rect x="2" y="4" width="20" height="16" rx="2"/><path d="M6 12h4M14 12h4M6 16h8M16 16h2"/></symbol>
 <symbol id="i-next" viewBox="0 0 24 24"><path d="M5 4l10 8-10 8z" fill="currentColor"/><path d="M19 5v14"/></symbol>
 <symbol id="i-fs" viewBox="0 0 24 24"><path d="M3 9V3h6M21 9V3h-6M3 15v6h6M21 15v6h-6"/></symbol>
 <symbol id="i-exfs" viewBox="0 0 24 24"><path d="M9 3v6H3M15 3v6h6M9 21v-6H3M15 21v-6h6"/></symbol>
 <symbol id="i-eps" viewBox="0 0 24 24"><rect x="3" y="7" width="14" height="12" rx="1"/><path d="M7 3h14v12"/></symbol>
 <symbol id="i-device" viewBox="0 0 24 24"><rect x="2" y="4" width="15" height="11" rx="1.5"/><path d="M6 19h7M9.5 15v4"/><rect x="18" y="9" width="4.5" height="10" rx="1"/></symbol>
 <symbol id="i-cast" viewBox="0 0 24 24"><path d="M2 16.1A5 5 0 0 1 5.9 20M2 12.05A9 9 0 0 1 9.95 20M2 8V6a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-6"/><path d="M2 20h.01"/></symbol>
 <symbol id="i-cast-on" viewBox="0 0 24 24"><path d="M2 16.1A5 5 0 0 1 5.9 20M2 12.05A9 9 0 0 1 9.95 20M2 8V6a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-6"/><path d="M2 20h.01"/><path d="M6 8h12v8h-4" fill="currentColor" stroke="none"/><rect x="6" y="8" width="12" height="8" fill="currentColor" stroke="none" opacity=".9"/></symbol>
 <symbol id="i-stop" viewBox="0 0 24 24"><rect x="6" y="6" width="12" height="12" rx="1" fill="currentColor" stroke="none"/></symbol>
 <symbol id="i-share" viewBox="0 0 24 24"><path d="M12 3v12M8 7l4-4 4 4"/><path d="M6 11H5v10h14V11h-1"/></symbol>
 <symbol id="i-dl" viewBox="0 0 24 24"><path d="M12 3v12M7 10l5 5 5-5M5 20h14"/></symbol>
 <symbol id="i-save" viewBox="0 0 24 24"><path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z"/><path d="M17 21v-8H7v8M7 3v5h8"/></symbol>
 <symbol id="i-yt" viewBox="0 0 24 24"><rect x="2" y="5" width="20" height="14" rx="4"/><path d="M10 9l5 3-5 3z" fill="currentColor"/></symbol>
</svg>

<div id="login" class="hidden">
  <form class="lbox" id="lform">
    <div class="brandwrap" style="margin-bottom:30px"><span class="logo" id="lname">CineVerse</span><span class="by">by NetStreaming</span></div>
    <h1>Conectare</h1>
    <input id="lu" placeholder="Utilizator sau e-mail" autocomplete="username" required>
    <input id="lp" type="password" placeholder="Parolă" autocomplete="current-password" required>
    <input id="l2fa" class="hidden" placeholder="Cod din aplicaţia de autentificare" autocomplete="one-time-code" inputmode="numeric">
    <div class="err" id="lerr"></div>
    <button class="btn-red">Conectare</button>
    <div class="lalt">
      <a href="#" id="goforgot">Am uitat parola</a>
      <a href="#" id="gosignup" class="hidden">Creează cont</a>
    </div>
  </form>

  <form class="lbox hidden" id="sform">
    <div class="brandwrap" style="margin-bottom:26px"><span class="logo">CineVerse</span><span class="by">by NetStreaming</span></div>
    <h1>Cont nou</h1>
    <input id="su" placeholder="Nume utilizator" autocomplete="username" required>
    <input id="se" type="email" placeholder="Adresă de e-mail" autocomplete="email" required>
    <input id="sp" type="password" placeholder="Parolă" autocomplete="new-password" required>
    <input id="si" class="hidden" placeholder="Cod de invitaţie">
    <div class="lhint" id="shint"></div>
    <div class="err" id="serr"></div>
    <button class="btn-red">Creează contul</button>
    <div class="lalt"><a href="#" id="backlogin1">Am deja cont</a></div>
  </form>

  <form class="lbox hidden" id="fform">
    <div class="brandwrap" style="margin-bottom:26px"><span class="logo">CineVerse</span><span class="by">by NetStreaming</span></div>
    <h1>Ţi-ai uitat parola?</h1>
    <p class="lhint" style="margin-bottom:16px">Scrie numele contului sau adresa de e-mail. Îţi trimitem un link de unde îţi alegi altă parolă.</p>
    <input id="fu" placeholder="Utilizator sau e-mail" autocomplete="username" required>
    <div class="err" id="ferr"></div>
    <button class="btn-red">Trimite linkul</button>
    <div class="lalt"><a href="#" id="backlogin2">Înapoi la conectare</a></div>
  </form>

  <form class="lbox hidden" id="rform">
    <div class="brandwrap" style="margin-bottom:26px"><span class="logo">CineVerse</span><span class="by">by NetStreaming</span></div>
    <h1>Alege o parolă nouă</h1>
    <input id="rp" type="password" placeholder="Parolă nouă" autocomplete="new-password" required>
    <input id="rp2" type="password" placeholder="Încă o dată" autocomplete="new-password" required>
    <div class="err" id="rerr"></div>
    <button class="btn-red">Salvează parola</button>
    <div class="lalt"><a href="#" id="backlogin3">Înapoi la conectare</a></div>
  </form>
</div>

<div id="app" class="hidden">
  <nav id="nav">
    <a href="#/" class="brandwrap"><span class="logo" id="brand">CineVerse</span><span class="by">by NetStreaming</span></a>
    <div class="links">
      <a href="#/" data-r="home">Acasă</a><a href="#/series" data-r="series">Seriale</a><a href="#/movies" data-r="movies">Filme</a><a href="#/list" data-r="list">Lista mea</a><a href="#/live" data-r="live" id="navlive" class="hidden">TV Live</a>
    </div>
    <div class="right">
      <div class="sbox" id="sbox"><button id="sbtn" aria-label="Caută"><svg class="ico"><use href="#i-search"/></svg></button><input id="sinput" placeholder="Titluri, actori, genuri"></div>

      <button id="castbtn" class="castbtn hidden" title="Google Cast"><svg class="ico"><use href="#i-cast"/></svg></button>
      <div class="umenu" id="umenu"><button class="avatar" id="av"></button>
        <div class="dd"><div style="padding:8px 16px;color:#aaa;font-size:13px" id="uname"></div>
          <a href="#/admin" id="admlink" class="hidden">Administrare server</a>
          <button onclick="changePw()">Schimbă parola</button>
          <button onclick="secDialog()">Securitatea contului</button>
          <button onclick="logoutAll()">Deconectează toate dispozitivele</button>
          <button id="appchg" class="hidden" onclick="CineVerseApp.call('change','',0)">Schimbă serverul (aplicație)</button>
          <a id="appapk" class="hidden" href="/app/android">📱 Aplicația Android (.apk)</a>
          <button onclick="logout()">Deconectare</button></div></div>
    </div>
  </nav>
  <main id="view"></main>
</div>

<div id="modal" class="hidden"></div>

<div id="castmenu" class="castmenu hidden"></div>
<div id="castbar" class="hidden">
  <div class="cbseek" id="cbseek"><div class="rail"><i id="cbdone"></i></div><div class="tip" id="cbtip"></div></div>
  <div class="cbrow">
    <div class="cbimg" id="cbimg"></div>
    <div class="cbinfo"><b id="cbtitle"></b><small id="cbdev"></small></div>
    <div class="cbctl">
      <button onclick="castSkip(-10)" title="Înapoi 10s"><svg class="ico"><use href="#i-rw"/></svg></button>
      <button id="cbpp" class="cbmain" title="Redă / Pauză"><svg class="ico"><use href="#i-pause"/></svg></button>
      <button onclick="castSkip(10)" title="Înainte 10s"><svg class="ico"><use href="#i-ff"/></svg></button>
      <span class="cbtime" id="cbtime"></span>
      <div class="cbvol"><svg class="ico" style="width:20px;height:20px"><use href="#i-vol"/></svg><input type="range" id="cbvol" min="0" max="1" step="0.05"></div>
      <select id="cbsub" title="Subtitrări"></select>
      <button onclick="castCmd('stop')" title="Oprește redarea pe TV"><svg class="ico"><use href="#i-stop"/></svg></button>
    </div>
  </div>
</div>

<div id="player" class="hidden">
 <div class="pwin">
  <video id="vid" playsinline preload="auto"></video>
  <div id="subsbox"></div>
  <div class="pspin hidden" id="pspin"></div>
  <div class="pui">
    <div class="ptop"><button onclick="closePlayer()" title="Înapoi (Esc)"><svg class="ico"><use href="#i-back"/></svg></button></div>
    <div class="pbot">
      <div class="seek" id="seek"><div class="rail"><div class="buf" id="sbuf"></div><div class="done" id="sdone"></div><div class="knob" id="sknob"></div></div><div class="tip" id="stip"></div><div class="left" id="sleft"></div></div>
      <div class="pctrl">
        <button id="bpp" title="Redă / Pauză (Spațiu)"><svg class="ico"><use href="#i-play"/></svg></button>
        <button onclick="skip(-10)" title="Înapoi 10s (←)"><svg class="ico"><use href="#i-rw"/></svg></button>
        <button onclick="skip(10)" title="Înainte 10s (→)"><svg class="ico"><use href="#i-ff"/></svg></button>
        <div class="vol"><button id="bvol" title="Sunet (M)"><svg class="ico"><use href="#i-vol"/></svg></button><input type="range" id="rvol" min="0" max="1" step="0.02" value="1"></div>
        <div class="ptitle" id="ptitle"></div>
        <button id="bnext" class="hidden" title="Episodul următor"><svg class="ico"><use href="#i-next"/></svg></button>
        <button id="pcast" class="castbtn hidden" title="Redă pe TV (Google Cast)"><svg class="ico"><use href="#i-cast"/></svg></button>
        <button id="bch" class="hidden" title="Schimbă canalul"><svg class="ico"><use href="#i-eps"/></svg></button>
        <button id="bsubs" title="Subtitrări și audio"><svg class="ico"><use href="#i-subs"/></svg></button>
        <button id="bfs" title="Ecran complet (F)"><svg class="ico"><use href="#i-fs"/></svg></button>
      </div>
    </div>
  </div>
  <div id="pmenu" class="pmenu hidden"></div>
  <div id="nextep" class="nextep hidden"></div>
  <div id="pinfo" class="pinfo hidden"></div>
 </div>
</div>

<script src="/static/hls.min.js"></script>
<script>window.Hls||document.write('<script src="https://cdn.jsdelivr.net/npm/hls.js@1/dist/hls.min.js"><\/script>')</script>
<script>
"use strict";
const $=s=>document.querySelector(s), $$=s=>[...document.querySelectorAll(s)];
const esc=s=>String(s??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const img=(p,s)=>p?`/img/${s}/${p.replace(/^\//,"")}`:"";
const fmtT=t=>{t=Math.max(0,Math.floor(t||0));const h=Math.floor(t/3600),m=Math.floor(t%3600/60),s=t%60;return (h?h+":"+String(m).padStart(2,"0"):m)+":"+String(s).padStart(2,"0")};
const fmtRun=m=>!m?"":m>=60?`${Math.floor(m/60)} h ${m%60?m%60+" min":""}`:`${m} min`;
const match=r=>r?`<span class="match">${Math.round(r*10)}% potrivire</span>`:"";
let ME=null;
function toast(t,ms=2600){const d=document.createElement("div");d.className="toast";d.textContent=t;document.body.appendChild(d);setTimeout(()=>d.remove(),ms)}
async function api(u,o={}){
  const opt={credentials:"same-origin",headers:{}, ...o};
  if(o.body&&typeof o.body!=="string"){opt.body=JSON.stringify(o.body);opt.headers["Content-Type"]="application/json"}
  const r=await fetch(u,opt);
  if(r.status===401&&!u.includes("/api/login")){sessionExpired();throw new Error("Sesiune expirată")}
  let d=null;try{d=await r.json()}catch(e){}
  if(!r.ok)throw new Error((d&&d.detail)||("Eroare "+r.status));
  return d;
}

/* ================= AUTH ================= */
function showLogin(msg){document.documentElement.style.overflow="";
  if(P.media){saveProgress();clearInterval(saveT);stopStream();P.media=null}
  if(P.live){clearInterval(liveT);stopStream();P.live=false}
  if(document.fullscreenElement)document.exitFullscreen().catch(()=>{});
  $("#app").classList.add("hidden");$("#player").classList.add("hidden");$("#modal").classList.add("hidden");$("#login").classList.remove("hidden");
  $("#lerr").className="err";$("#lerr").textContent=msg||"";
  const m=location.hash.match(/^#\/reset\?t=(.+)$/);
  if(m){RESET_TOK=decodeURIComponent(m[1]);lshow("rform")}else lshow("lform");
  loadSignupInfo();}
let expT=null;
/* Re-verifica la server inainte sa declare sesiunea expirata – expirarea e glisanta,
   deci daca ai fost activ intre timp sesiunea s-a prelungit singura. */
function armExpiry(){
  clearTimeout(expT);
  if(!ME||!ME.expires)return;                       // sesiune fara expirare
  expT=setTimeout(async()=>{
    try{const m=await api("/api/me");if(m&&m.id){ME=m;return armExpiry()}}catch(e){return}
    sessionExpired();
  },Math.max(1000,ME.expires*1000-Date.now()+1500));
}
function sessionExpired(){if(!ME)return showLogin();ME=null;clearTimeout(expT);showLogin("Sesiunea a expirat. Autentifică-te din nou – progresul vizionării a fost salvat.")}
/* ---- conectare, cont nou, parolă uitată ---- */
let SIGNUP={enabled:false};
function lshow(which){
  ["lform","sform","fform","rform"].forEach(f=>$("#"+f).classList.toggle("hidden",f!==which));
  $("#lerr").textContent="";$("#serr").textContent="";$("#ferr").textContent="";$("#rerr").textContent="";
  const first=$("#"+which).querySelector("input:not(.hidden)");if(first)first.focus();
}
async function loadSignupInfo(){
  try{SIGNUP=await api("/api/signup/info")}catch(e){SIGNUP={enabled:false};return}
  $("#gosignup").classList.toggle("hidden",!SIGNUP.enabled);
  $("#si").classList.toggle("hidden",!SIGNUP.need_invite);
  $("#goforgot").classList.toggle("hidden",!SIGNUP.mail);
  $("#shint").innerHTML=`Parola: minim ${SIGNUP.pw_min} caractere.`+
    (SIGNUP.verify?" După înregistrare îţi trimitem un e-mail de confirmare.":"")+
    (SIGNUP.approve?" Contul devine activ după ce îl aprobă administratorul.":"");
}
$("#gosignup").onclick=e=>{e.preventDefault();lshow("sform")};
$("#goforgot").onclick=e=>{e.preventDefault();lshow("fform")};
$("#backlogin1").onclick=$("#backlogin2").onclick=$("#backlogin3").onclick=e=>{e.preventDefault();location.hash="#/";lshow("lform")};

$("#lform").onsubmit=async e=>{e.preventDefault();$("#lerr").textContent="";
  const body={username:$("#lu").value,password:$("#lp").value};
  const code=$("#l2fa").value.trim();if(code)body.code=code;
  try{await api("/api/login",{method:"POST",body});$("#lp").value="";$("#l2fa").value="";$("#l2fa").classList.add("hidden");boot()}
  catch(err){
    if(err.message==="2FA"){
      $("#l2fa").classList.remove("hidden");$("#l2fa").focus();
      $("#lerr").textContent="Scrie codul din aplicaţia de autentificare (sau un cod de rezervă).";
      return;
    }
    $("#lerr").textContent=err.message;
  }};

$("#sform").onsubmit=async e=>{e.preventDefault();$("#serr").textContent="";
  const b=$("#sform").querySelector("button");b.disabled=true;
  try{
    const r=await api("/api/signup",{method:"POST",body:{username:$("#su").value.trim(),email:$("#se").value.trim(),password:$("#sp").value,invite:$("#si").value.trim()}});
    $("#sp").value="";
    lshow("lform");
    $("#lu").value=$("#su").value.trim();
    $("#lerr").className="err okmsg";
    $("#lerr").textContent=r.verify?"Ţi-am trimis un e-mail de confirmare. Deschide linkul din el, apoi conectează-te."
      :r.approve?"Contul a fost creat. Îl activează administratorul – te anunţăm pe e-mail."
      :"Contul a fost creat. Te poţi conecta.";
    setTimeout(()=>{$("#lerr").className="err"},60000);
  }catch(err){$("#serr").textContent=err.message}finally{b.disabled=false}};

$("#fform").onsubmit=async e=>{e.preventDefault();$("#ferr").textContent="";
  const b=$("#fform").querySelector("button");b.disabled=true;
  try{
    await api("/api/forgot",{method:"POST",body:{login:$("#fu").value.trim()}});
    lshow("lform");
    $("#lerr").className="err okmsg";
    $("#lerr").textContent="Dacă există un cont cu datele astea, ţi-am trimis un e-mail cu linkul de resetare. Verifică şi în Spam.";
    setTimeout(()=>{$("#lerr").className="err"},60000);
  }catch(err){$("#ferr").textContent=err.message}finally{b.disabled=false}};

$("#rform").onsubmit=async e=>{e.preventDefault();$("#rerr").textContent="";
  if($("#rp").value!==$("#rp2").value){$("#rerr").textContent="Cele două parole nu sunt la fel.";return}
  const b=$("#rform").querySelector("button");b.disabled=true;
  try{
    await api("/api/reset",{method:"POST",body:{token:RESET_TOK,password:$("#rp").value}});
    RESET_TOK="";location.hash="#/";
    lshow("lform");
    $("#lerr").className="err okmsg";
    $("#lerr").textContent="Parola a fost schimbată. Conectează-te cu ea.";
    setTimeout(()=>{$("#lerr").className="err"},60000);
  }catch(err){$("#rerr").textContent=err.message;b.disabled=false}};
let RESET_TOK="";
async function logout(){await api("/api/logout",{method:"POST"}).catch(()=>{});ME=null;clearTimeout(expT);location.hash="#/";showLogin()}
/* ================= GOOGLE CAST (serverul comandă Chromecast-ul) ================= */
const CAST={devices:[],device:null,name:"",st:null,timer:null,scanT:null,drag:false};
async function castRefresh(){
  if(!ME||ME.remote){CAST.devices=[];return updCastBtns()}
  try{const d=await api("/api/cast/devices");CAST.devices=d.devices||[]}catch(e){CAST.devices=[]}
  updCastBtns();
}
function updCastBtns(){
  const show=CAST.devices.length>0||!!CAST.device;
  ["#castbtn","#pcast"].forEach(sel=>{const b=$(sel);if(!b)return;b.classList.toggle("hidden",!show);b.classList.toggle("on",!!CAST.device);
    b.querySelector("use").setAttribute("href",CAST.device?"#i-cast-on":"#i-cast");b.title=CAST.device?`Conectat la ${CAST.name}`:"Redă pe TV (Google Cast)"});
}
function castMenu(anchor){
  const m=$("#castmenu");if(!m.classList.contains("hidden")){m.classList.add("hidden");return}
  const tv='<svg class="ico"><use href="#i-cast"/></svg>';
  m.innerHTML=`<h4>Redă pe</h4>
    <button data-cd="" class="${!CAST.device?"on":""}"><svg class="ico"><use href="#i-device"/></svg><span>Acest dispozitiv</span></button>
    ${CAST.devices.map(d=>`<button data-cd="${esc(d.id)}" class="${CAST.device===d.id?"on":""}">${tv}<span>${esc(d.name)}<small>${esc(d.model)}</small></span></button>`).join("")}
    ${!CAST.devices.length?'<div style="padding:10px 16px;color:#888;font-size:13px">Niciun Chromecast găsit în rețea.</div>':""}
    ${CAST.st&&CAST.st.active?'<div class="sep"></div><button data-cstop>■ Oprește redarea pe TV</button>':""}`;
  const r=anchor.getBoundingClientRect();m.classList.remove("hidden");
  m.style.top=Math.min(innerHeight-m.offsetHeight-10,r.bottom+8)+"px";m.style.left=Math.max(10,Math.min(innerWidth-m.offsetWidth-10,r.right-m.offsetWidth))+"px";
  if(anchor.id==="pcast"){m.style.top=Math.max(10,r.top-m.offsetHeight-10)+"px"}
  m.querySelectorAll("[data-cd]").forEach(b=>b.onclick=()=>castSelect(b.dataset.cd));
  const st=m.querySelector("[data-cstop]");if(st)st.onclick=()=>{m.classList.add("hidden");castCmd("stop")};
}
document.addEventListener("click",e=>{if(!e.target.closest("#castmenu,#castbtn,#pcast"))$("#castmenu").classList.add("hidden")});
$("#castbtn").onclick=e=>{e.stopPropagation();castMenu($("#castbtn"))};
$("#pcast").onclick=e=>{e.stopPropagation();showUI(true);castMenu($("#pcast"))};
async function castSelect(id){
  $("#castmenu").classList.add("hidden");
  if(!id){if(CAST.st&&CAST.st.active)await castCmd("stop");CAST.device=null;CAST.name="";updCastBtns();return}
  CAST.device=id;CAST.name=(CAST.devices.find(d=>d.id===id)||{}).name||"TV";updCastBtns();
  if(P.live&&!$("#player").classList.contains("hidden")){   // transfer canalul live pe TV
    const cid=P.liveCh;await closePlayer();castPlayLive(cid);
  }else if(P.media&&!$("#player").classList.contains("hidden")){   // transfer: ce rula aici continuă pe TV
    const mid=P.media,t=absT(),a=P.audioIdx,sub=P.subId;await closePlayer();castPlay(mid,t,a,sub??null);
  }else toast(`Conectat la ${CAST.name}. Alege un film sau un canal și apasă Redă.`);
}
async function castPlay(mid,start,audio,sub){
  if(sub===undefined){const ch=String(pref("sub_"+mid,"auto"));sub=ch==="auto"?"auto":ch==="off"?null:+ch}
  showCastBar();$("#cbtitle").textContent=t("cast_starting");$("#cbdev").innerHTML=`<svg class="ico" style="width:14px;height:14px"><use href="#i-cast-on"/></svg> ${esc(CAST.name)}`;
  try{await api("/api/cast/play",{method:"POST",body:{device:CAST.device,media_id:mid,start:start||0,audio:audio??null,sub:sub===undefined?"auto":sub}})}
  catch(e){toast("Cast: "+e.message,6000);return castTick()}
  castPoll();
}
async function castPlayLive(cid){
  showCastBar();$("#cbtitle").textContent=t("cast_starting");$("#cbdev").innerHTML=`<svg class="ico" style="width:14px;height:14px"><use href="#i-cast-on"/></svg> ${esc(CAST.name)}`;
  try{await api("/api/cast/live",{method:"POST",body:{device:CAST.device,channel:cid}})}
  catch(e){toast("Cast: "+e.message,6000);return castTick()}
  castPoll();
}
function showCastBar(){$("#castbar").classList.remove("hidden");document.body.classList.add("casting")}
function hideCastBar(){$("#castbar").classList.add("hidden");document.body.classList.remove("casting")}
function castPoll(){clearInterval(CAST.timer);CAST.timer=setInterval(castTick,1000);castTick()}
async function castTick(){
  let s;try{s=await api("/api/cast/status")}catch(e){return}
  CAST.st=s;
  if(!s.active){hideCastBar();clearInterval(CAST.timer);CAST.timer=null;return}
  CAST.device=s.device;CAST.name=s.device_name;updCastBtns();showCastBar();
  $("#cbtitle").textContent=s.title;
  $("#cbdev").innerHTML=`<svg class="ico" style="width:14px;height:14px"><use href="#i-cast-on"/></svg> ${s.state==="BUFFERING"?t("cast_buffering"):s.state==="PAUSED"?t("cast_paused"):t("cast_playing")} ${esc(s.device_name)}`;
  $("#cbimg").style.backgroundImage=s.img?`url('${img(s.img,"w300")}')`:"";
  if(!CAST.drag)$("#cbdone").style.width=(s.duration?Math.min(100,s.position/s.duration*100):0)+"%";
  $("#cbtime").textContent=`${fmtT(s.position)} / ${fmtT(s.duration)}`;
  $("#cbpp use").setAttribute("href",s.state==="PAUSED"?"#i-play":"#i-pause");
  if(document.activeElement!==$("#cbvol"))$("#cbvol").value=s.muted?0:s.volume;
  const opts=`<option value="">Fără subtitrări</option>`+s.subs.map(x=>`<option value="${x.id}">${esc(x.label)}</option>`).join("");
  if($("#cbsub").dataset.k!==opts){$("#cbsub").innerHTML=opts;$("#cbsub").dataset.k=opts}
  if(document.activeElement!==$("#cbsub"))$("#cbsub").value=s.sub_id||"";
}
async function castCmd(action,extra={}){try{await api("/api/cast/control",{method:"POST",body:{action,...extra}})}catch(e){toast(e.message)}
  if(action==="stop"){hideCastBar()}setTimeout(castTick,400)}
function castSkip(sec){if(CAST.st&&CAST.st.active)castCmd("seek",{pos:CAST.st.position+sec})}
$("#cbpp").onclick=()=>castCmd(CAST.st&&CAST.st.state==="PAUSED"?"play":"pause");
$("#cbvol").onchange=e=>castCmd("volume",{value:+e.target.value});
$("#cbsub").onchange=e=>{t("cast_sub_change");castCmd("sub",{value:e.target.value||null})};
$("#cbseek").addEventListener("click",e=>{const r=$("#cbseek .rail").getBoundingClientRect();const f=Math.max(0,Math.min(1,(e.clientX-r.left)/r.width));
  if(CAST.st&&CAST.st.duration){$("#cbdone").style.width=f*100+"%";castCmd("seek",{pos:f*CAST.st.duration})}});
$("#cbseek").addEventListener("mousemove",e=>{if(!CAST.st)return;const r=$("#cbseek .rail").getBoundingClientRect();const f=Math.max(0,Math.min(1,(e.clientX-r.left)/r.width));
  $("#cbtip").textContent=fmtT(f*CAST.st.duration);$("#cbtip").style.left=(e.clientX-r.left)+"px"});
$("#cbimg").onclick=()=>{if(CAST.st&&CAST.st.item_id)openItem(CAST.st.item_id)};

/* sugestie de instalare: iPhone/iPad (Safari -> ecran principal) și Android (APK) */
function appHint(inApp){
  try{if(inApp||localStorage.getItem("cineverse_hint_off"))return}catch(e){}
  const ua=navigator.userAgent,ios=/iPhone|iPad|iPod/.test(ua)||(/Macintosh/.test(ua)&&navigator.maxTouchPoints>1),and=/Android/i.test(ua);
  const standalone=window.matchMedia("(display-mode: standalone)").matches||navigator.standalone;
  if(standalone||(!ios&&!and))return;
  const d=document.createElement("div");d.className="apphint";
  d.innerHTML=ios?`<b>Instalează CineVerse pe ${/iPad/.test(ua)?"iPad":"iPhone"}:</b> apasă <b>Partajează</b> <svg class="ico" style="width:17px;height:17px;vertical-align:-3px;color:#0a84ff"><use href="#i-share"/></svg> apoi <b>„Adaugă pe ecranul principal”</b>. Se deschide pe tot ecranul, ca o aplicație.`
    :`<b>Aplicația CineVerse pentru Android:</b> redare pe tot ecranul, descărcări și ecran mereu aprins. <a href="/app/android">Descarcă APK</a>`;
  const x=document.createElement("button");x.className="x";x.innerHTML='<svg class="ico" style="width:14px;height:14px"><use href="#i-x"/></svg>';
  x.onclick=()=>{d.remove();try{localStorage.setItem("cineverse_hint_off","1")}catch(e){}};d.appendChild(x);document.body.appendChild(d);
}
async function logoutAll(){if(!confirm(t("confirm_logout_all")))return;
  await api("/api/me/logout-all",{method:"POST"}).catch(()=>{});ME=null;clearTimeout(expT);location.hash="#/";showLogin(t("logged_out_all"))}
async function changePw(){const o=prompt(t("current_pw_prompt"));if(o==null)return;const n=prompt(t("new_pw_prompt"));if(!n)return;
  try{await api("/api/me/password",{method:"POST",body:{old:o,new:n}});t("pw_changed_devices")}catch(e){alert(e.message)}}
/* ---- securitatea contului: adresa de e-mail şi codul în doi paşi ---- */
async function secDialog(){
  const m=$("#modal");m.classList.remove("hidden");
  const draw=async()=>{
    let me;try{me=await api("/api/me")}catch(e){return}
    ME=me;
    m.innerHTML=`<div class="box" style="max-width:620px">
      <button class="mclose" onclick="$('#modal').classList.add('hidden')"><svg class="ico"><use href="#i-x"/></svg></button>
      <div class="mbody" style="padding:34px 40px 36px">
        <h2 style="font-size:28px;margin-bottom:6px">Securitatea contului</h2>
        <p style="color:#8a93a8;font-size:14px;margin-bottom:24px">${esc(me.username)}</p>

        <h4 class="sub" style="margin-top:0">Adresă de e-mail</h4>
        <p style="color:#8a93a8;font-size:13px;margin-bottom:10px">Fără ea nu îţi poţi recupera singur parola.</p>
        <div style="display:flex;gap:10px;flex-wrap:wrap">
          <input id="myemail" value="${esc(me.email||"")}" placeholder="adresa@exemplu.ro" style="flex:1;min-width:230px;background:#1f2940;border:1px solid #36415c;border-radius:4px;color:#fff;padding:11px">
          <button class="bsm red" id="saveemail">Salvează</button>
        </div>

        <h4 class="sub">Cod în doi paşi</h4>
        <div id="tfabox"></div>
      </div></div>`;
    $("#saveemail").onclick=async()=>{
      try{await api("/api/me/email",{method:"POST",body:{email:$("#myemail").value.trim()}});t("email_saved");draw()}
      catch(e){alert(e.message)}};
    drawTfa(me);
  };
  const drawTfa=(me)=>{
    const t=$("#tfabox");
    if(me.has_2fa){
      t.innerHTML=`<p style="color:#46d369;font-size:14px;margin-bottom:12px">✓ Activ. La conectare ţi se cere şi un cod din aplicaţie.</p>
        <button class="bsm" id="tfaoff">Dezactivează</button>`;
      $("#tfaoff").onclick=async()=>{
        const pw=prompt(t("confirm_pw_prompt"));if(!pw)return;
        try{await api("/api/me/2fa/disable",{method:"POST",body:{password:pw}});t("2fa_disabled");draw()}
        catch(e){alert(e.message)}};
      return;
    }
    t.innerHTML=`<p style="color:#8a93a8;font-size:13px;margin-bottom:12px">Pe lângă parolă, la conectare ţi se cere un cod de 6 cifre dintr-o aplicaţie ca Google Authenticator, Aegis sau 1Password. Recomandat mai ales dacă serverul e deschis spre internet.</p>
      <button class="bsm red" id="tfaon">Activează</button>`;
    $("#tfaon").onclick=async()=>{
      let d;try{d=await api("/api/me/2fa/start",{method:"POST"})}catch(e){return alert(e.message)}
      t.innerHTML=`<p style="color:#8a93a8;font-size:13px">1. Deschide aplicaţia de autentificare şi adaugă un cont nou, manual, cu cheia:</p>
        <div class="secbox">${esc(d.secret)}</div>
        <p style="color:#8a93a8;font-size:13px">Pe telefon poţi folosi direct <a href="${esc(d.uri)}" style="color:#e50914">acest link</a>.</p>
        <p style="color:#8a93a8;font-size:13px;margin-top:14px">2. Scrie codul de 6 cifre afişat de aplicaţie:</p>
        <div style="display:flex;gap:10px;margin-top:8px;flex-wrap:wrap">
          <input id="tfacode" inputmode="numeric" maxlength="6" placeholder="000000" style="width:150px;background:#1f2940;border:1px solid #36415c;border-radius:4px;color:#fff;padding:11px;font-size:19px;letter-spacing:4px;text-align:center">
          <button class="bsm red" id="tfaok">Confirmă</button>
        </div>
        <div id="tfaerr" style="color:#e87c03;font-size:13px;min-height:20px;margin-top:8px"></div>`;
      $("#tfacode").focus();
      $("#tfaok").onclick=async()=>{
        try{
          const r=await api("/api/me/2fa/enable",{method:"POST",body:{code:$("#tfacode").value}});
          t.innerHTML=`<p style="color:#46d369;font-size:14px">✓ Gata. De acum ţi se cere codul la fiecare conectare.</p>
            <p style="color:#8a93a8;font-size:13px;margin-top:12px">Păstrează codurile de rezervă de mai jos într-un loc sigur. Fiecare merge o singură dată şi te salvează dacă rămâi fără telefon:</p>
            <div class="codes">${r.codes.map(c=>esc(c)).join("<br>")}</div>`;
          ME.has_2fa=true;
        }catch(e){$("#tfaerr").textContent=e.message}};
    };
  };
  draw();
}
async function boot(){
  if(/^#\/reset\?t=/.test(location.hash)){ME=null;return}   // link de resetare: mergem direct la formular
  try{ME=await api("/api/me")}catch(e){return}
  $("#login").classList.add("hidden");$("#app").classList.remove("hidden");
  document.title=ME.server_name+" by NetStreaming";$("#brand").textContent=ME.server_name;
  $("#av").textContent=ME.username[0];$("#admlink").classList.toggle("hidden",!ME.admin);$("#navlive").classList.toggle("hidden",!ME.live);
  const dev=`${ME.devices} ${ME.devices===1?"dispozitiv":"dispozitive"}`;
  $("#uname").innerHTML=`${esc(ME.username)}<br><small style="color:#777">${ME.expires?`Sesiune valabilă până la ${new Date(ME.expires*1000).toLocaleString("ro-RO",{day:"2-digit",month:"short",hour:"2-digit",minute:"2-digit"})}`:"Sesiune activă"} · ${dev}</small>`;
  const inApp=!!window.CineVerseApp, desk=!!window.cvDesktop;
  $("#appchg").classList.toggle("hidden",!inApp);
  $("#appapk").classList.toggle("hidden",inApp||desk||!/Android/i.test(navigator.userAgent));
  appHint(inApp||desk);
  castRefresh();castTick().then(()=>{if(CAST.st&&CAST.st.active)castPoll()});clearInterval(CAST.scanT);CAST.scanT=setInterval(castRefresh,30000);
  armExpiry();
  route();
}

/* ================= NAV ================= */
addEventListener("scroll",()=>$("#nav").classList.toggle("solid",scrollY>40),{passive:true});
$("#av").onclick=()=>$("#umenu").classList.toggle("open");
document.addEventListener("click",e=>{if(!e.target.closest("#umenu"))$("#umenu").classList.remove("open")});
$("#sbtn").onclick=()=>{$("#sbox").classList.add("open");$("#sinput").focus()};
$("#sinput").onblur=()=>{if(!$("#sinput").value)$("#sbox").classList.remove("open")};
let sT;$("#sinput").oninput=()=>{clearTimeout(sT);sT=setTimeout(()=>{const v=$("#sinput").value.trim();location.hash=v?"#/search/"+encodeURIComponent(v):"#/"},300)};
addEventListener("hashchange",route);
let heroTimer=null;
function route(){
  if(!ME)return;
  clearInterval(heroTimer);
  const h=location.hash.slice(2);const [r,arg]=h.split("/");
  $$("#nav .links a").forEach(a=>a.classList.toggle("on",a.dataset.r===(r||"home")));
  if(r!=="search"&&$("#sinput").value){$("#sinput").value="";$("#sbox").classList.remove("open")}
  scrollTo(0,0);
  if(r==="movies")return viewBrowse("movie","Filme");
  if(r==="series")return viewBrowse("series","Seriale");
  if(r==="list")return viewList();
  if(r==="search")return viewSearch(decodeURIComponent(arg||""));
  if(r==="live")return viewLive();
  if(r==="admin")return viewAdmin();
  return viewHome();
}

/* ================= CARDS ================= */
function cardHTML(it,rowKind,idx){
  const bd=it.backdrop?img(it.backdrop,"w780"):"";
  const logo=it.logo?`<img src="${img(it.logo,"w300")}" alt="" loading="lazy">`:esc(it.title);
  const prog=it.resume_dur&&it.resume_pos?`<div class="pbar"><i style="width:${Math.min(100,it.resume_pos/it.resume_dur*100)}%"></i></div>`:"";
  const thumb=bd?`<div class="thumb" style="background-image:url('${bd}')"><div class="ttl">${logo}</div>${prog}${rowKind==="top"&&idx<10?`<div class="rank">TOP<br>${idx+1}</div>`:""}</div>`
               :`<div class="thumb"><div class="ph">${esc(it.title)}</div>${prog}</div>`;
  const meta=[match(it.rating),it.cert?`<span class="cert">${esc(it.cert)}</span>`:"",it.year?`<span>${it.year}</span>`:"",
              it.kind==="series"?"<span>Serial</span>":it.runtime?`<span>${fmtRun(it.runtime)}</span>`:""].join("");
  return `<div class="card" data-id="${it.id}" data-rm="${it.resume_media||""}" data-rp="${it.resume_pos||0}">${thumb}
    <div class="more"><div class="cb"><button class="circ w" data-act="play" title="Redă"><svg class="ico"><use href="#i-play"/></svg></button>
      <button class="circ" data-act="list" title="Lista mea"><svg class="ico"><use href="#i-plus"/></svg></button>
      <button class="circ r" data-act="info" title="Detalii"><svg class="ico"><use href="#i-down"/></svg></button></div>
      <div class="meta">${meta}</div>
      ${it.resume_label?`<div class="sub">${esc(it.resume_label)}</div>`:""}
      <div class="gen">${(it.genres||[]).map(g=>`<span>${esc(g)}</span>`).join("")}</div></div></div>`;
}
function bindCards(root){
  root.querySelectorAll(".card").forEach(c=>{
    c.onclick=async e=>{
      const act=e.target.closest("[data-act]")?.dataset.act;const id=+c.dataset.id;
      if(act==="play"){e.stopPropagation();
        if(c.dataset.rm)return playMedia(+c.dataset.rm,+c.dataset.rp);
        const d=await api("/api/item/"+id);if(d.next)playMedia(d.next.id,d.next.position||0);return}
      if(act==="list"){e.stopPropagation();const r=await api("/api/mylist/"+id,{method:"POST"});toast(r.in_list?"Adăugat în Lista mea":"Eliminat din Lista mea");return}
      openItem(id);
    }});
}
function rowHTML(r){
  return `<section class="row"><h3>${esc(r.title)}</h3><div class="slider"><button class="arrow l"><svg class="ico"><use href="#i-left"/></svg></button>
    <div class="track">${r.items.map((it,i)=>cardHTML(it,r.kind,i)).join("")}</div>
    <button class="arrow r"><svg class="ico"><use href="#i-right"/></svg></button></div></section>`;
}
function bindRows(root){
  root.querySelectorAll(".slider").forEach(s=>{const t=s.querySelector(".track");
    s.querySelector(".arrow.l").onclick=()=>t.scrollBy({left:-t.clientWidth*.9});
    s.querySelector(".arrow.r").onclick=()=>t.scrollBy({left:t.clientWidth*.9})});
  bindCards(root);
}

/* ================= VIEWS ================= */
async function viewHome(){
  const v=$("#view");v.innerHTML="";
  const d=await api("/api/home");
  if(!d.rows.length){v.innerHTML=`<div class="page"><h2>Biblioteca e goală</h2><p class="empty">${ME.admin?'Adaugă foldere cu filme/seriale din <a href="#/admin" style="color:#e50914">Administrare</a> și pornește o scanare.':'Administratorul nu a adăugat încă nimic.'}</p></div>`;return}
  let html="";
  if(d.hero.length)html+=`<section id="hero"><div class="bg"></div><div class="shade"></div><div class="hpost"></div><div class="info"></div></section>`;
  html+=`<div id="rows" class="${d.hero.length?"":"nohero"}">${d.rows.map(rowHTML).join("")}</div>`;
  v.innerHTML=html;bindRows(v);
  if(d.hero.length){let i=0;const show=()=>{const h=d.hero[i%d.hero.length];i++;renderHero(h)};show();if(d.hero.length>1)heroTimer=setInterval(show,14000)}
}
function renderHero(h){
  const hero=$("#hero");if(!hero)return;
  const bg=hero.querySelector(".bg");bg.style.opacity=0;
  setTimeout(()=>{bg.style.backgroundImage=h.backdrop?`url('${img(h.backdrop,"original")}')`:"linear-gradient(135deg,#28324a,#111)";bg.style.opacity=1},300);
  const hp=hero.querySelector(".hpost");   // pe telefon: posterul intreg, textul sub el
  hp.classList.toggle("wide",!h.poster);
  hp.style.backgroundImage=h.poster?`url('${img(h.poster,"w780")}')`:h.backdrop?`url('${img(h.backdrop,"w780")}')`:"";
  hp.onclick=()=>openItem(h.id);
  hero.querySelector(".info").innerHTML=`${h.logo?`<img class="tlogo" src="${img(h.logo,"w500")}" alt="${esc(h.title)}">`:`<h2>${esc(h.title)}</h2>`}
    <div class="meta">${match(h.rating)}${h.year?`<span>${h.year}</span>`:""}${h.cert?`<span class="cert">${esc(h.cert)}</span>`:""}${h.kind==="series"?"<span>Serial</span>":h.runtime?`<span>${fmtRun(h.runtime)}</span>`:""}</div>
    <p>${esc(h.overview)}</p>
    <div class="btns"><button class="bplay" id="hplay"><svg class="ico"><use href="#i-play"/></svg>Redă</button>
    <button class="binfo" id="hinfo"><svg class="ico"><use href="#i-info"/></svg>Mai multe informații</button></div>`;
  $("#hplay").onclick=async()=>{const d=await api("/api/item/"+h.id);if(d.next)playMedia(d.next.id,d.next.position||0)};
  $("#hinfo").onclick=()=>openItem(h.id);
}
async function viewBrowse(kind,title,genre="",sort="added"){
  const v=$("#view");
  const d=await api(`/api/browse?kind=${kind}&genre=${encodeURIComponent(genre)}&sort=${sort}`);
  v.innerHTML=`<div class="page"><div class="head"><h2>${title}</h2>
    <select class="sel" id="gsel"><option value="">Genuri</option>${d.genres.map(g=>`<option ${g===genre?"selected":""}>${esc(g)}</option>`).join("")}</select>
    <select class="sel" id="ssel">${[["added","Adăugate recent"],["title","Alfabetic"],["year","An apariție"],["rating","Rating"]].map(([k,l])=>`<option value="${k}" ${k===sort?"selected":""}>${l}</option>`).join("")}</select></div>
    ${d.items.length?`<div class="grid">${d.items.map(i=>cardHTML(i)).join("")}</div>`:`<div class="empty">Nimic aici încă.</div>`}</div>`;
  bindCards(v);
  $("#gsel").onchange=e=>viewBrowse(kind,title,e.target.value,$("#ssel").value);
  $("#ssel").onchange=e=>viewBrowse(kind,title,$("#gsel").value,e.target.value);
}
async function viewList(){const d=await api("/api/mylist");const v=$("#view");
  v.innerHTML=`<div class="page"><div class="head"><h2>Lista mea</h2></div>${d.items.length?`<div class="grid">${d.items.map(i=>cardHTML(i)).join("")}</div>`:`<div class="empty">Nu ai adăugat nimic în listă.</div>`}</div>`;bindCards(v)}
async function viewSearch(term){
  if(!$("#sinput").value){$("#sinput").value=term;$("#sbox").classList.add("open")}
  const d=await api("/api/find?q="+encodeURIComponent(term));const v=$("#view");
  v.innerHTML=`<div class="page">${d.items.length?`<div class="head"><h2 style="font-size:20px;color:#aaa">Rezultate pentru „${esc(term)}”</h2></div><div class="grid">${d.items.map(i=>cardHTML(i)).join("")}</div>`:`<div class="empty">Nicio potrivire pentru „${esc(term)}”.</div>`}</div>`;bindCards(v)}

/* ================= TV LIVE ================= */
let LIVECH=[];
function chCardHTML(c){
  const now=c.now?`<div class="chnow">${esc(c.now.title)}<div class="bar"><i style="width:${Math.min(100,Math.max(0,(Date.now()/1000-c.now.start)/(c.now.stop-c.now.start)*100))}%"></i></div></div>`:`<div class="chnow">&nbsp;</div>`;
  return `<div class="chcard" data-ch="${c.id}"><div class="chlogo">${c.logo?`<img src="/api/live/logo/${c.id}" loading="lazy" alt="" onerror="this.parentNode.innerHTML='<div class=ph>'+this.dataset.n+'</div>'" data-n="${esc(c.name)}">`:`<div class="ph">${esc(c.name)}</div>`}</div>
    <div class="chname">${c.num?`${c.num}. `:""}${esc(c.name)}</div>${now}</div>`;
}
async function viewLive(){
  const v=$("#view");let d;
  try{d=await api("/api/live/channels")}catch(e){v.innerHTML=`<div class="page"><div class="empty">${esc(e.message)}</div></div>`;return}
  LIVECH=d.channels;
  if(!d.channels.length){v.innerHTML=`<div class="page"><div class="head"><h2>TV Live</h2></div><div class="empty">${ME.admin?'Niciun canal configurat. Adaugă canale din <a href="#/admin" style="color:#e50914">Administrare → TV Live</a>.':"Niciun canal disponibil momentan."}</div></div>`;return}
  const byGroup={};const noGroup=[];
  d.channels.forEach(c=>{if(c.group){(byGroup[c.group]=byGroup[c.group]||[]).push(c)}else noGroup.push(c)});
  let html=`<div class="page"><div class="head"><h2>TV Live</h2></div>`;
  if(noGroup.length)html+=`<div class="chgrid">${noGroup.map(chCardHTML).join("")}</div>`;
  d.groups.forEach(g=>{if(byGroup[g]&&byGroup[g].length)html+=`<div class="chgroup">${esc(g)}</div><div class="chgrid">${byGroup[g].map(chCardHTML).join("")}</div>`});
  html+="</div>";v.innerHTML=html;
  v.querySelectorAll("[data-ch]").forEach(c=>c.onclick=()=>playLive(+c.dataset.ch));
}

/* ================= DETAILS MODAL ================= */
let CUR=null;
async function openItem(id,season){
  const d=await api("/api/item/"+id);CUR=d;
  const m=$("#modal");m.classList.remove("hidden");document.body.style.overflow="hidden";
  const n=d.next;
  const resume=n&&n.position>20?`<div class="resume"><div class="bar"><i style="width:${Math.min(100,n.position/(n.duration||1)*100)}%"></i></div><small>${d.kind==="series"?`S${n.season}:E${n.episode} · `:""}${fmtT(n.position)} din ${fmtT(n.duration)}</small></div>`:"";
  const playLbl=n&&n.position>20?"Reia":d.kind==="series"&&n?`Redă S${n.season}:E${n.episode}`:"Redă";
  const q=(d.media&&d.media[0])||n||{};
  const cast=d.cast||[];
  m.innerHTML=`<div class="box">
   <button class="mclose" onclick="closeModal()"><svg class="ico"><use href="#i-x"/></svg></button>
   <div class="mhero" style="--img:${d.backdrop?`url('${img(d.backdrop,"w1280")}')`:"linear-gradient(135deg,#28324a,#111)"};background-image:var(--img)">
     <div class="mi">${d.logo?`<img class="tlogo" src="${img(d.logo,"w500")}" alt="${esc(d.title)}">`:`<h2>${esc(d.title)}</h2>`}
      <div class="btns">${n?`<button class="bplay" id="mplay"><svg class="ico"><use href="#i-play"/></svg>${playLbl}</button>`:""}
       ${n&&n.position>20?`<button class="binfo" id="mstart" title="De la început">↺ De la început</button>`:""}
       <button class="circ" style="width:44px;height:44px" id="mlist" title="Lista mea"><svg class="ico"><use href="#${d.in_list?"i-check":"i-plus"}"/></svg></button>
       ${d.trailer?`<button class="circ" style="width:44px;height:44px" id="mtrailer" title="Trailer"><svg class="ico"><use href="#i-yt"/></svg></button>`:""}
       ${d.kind==="movie"&&n?dlBtn(n.id)+offBtn(n.id):""}
      </div>${resume}</div></div>
   <div class="mbody">
    <div class="mcols"><div>
      <div class="meta" style="margin-bottom:14px">${match(d.rating)}${d.year?`<span class="mut">${d.year}</span>`:""}
        ${d.kind==="series"?`<span class="mut">${d.seasons.length} ${d.seasons.length===1?"sezon":"sezoane"}</span>`:d.runtime?`<span class="mut">${fmtRun(d.runtime)}</span>`:""}
        ${q.quality?`<span class="qual">${q.quality}</span>`:""}${q.hdr?`<span class="qual">HDR</span>`:""}${d.cert?`<span class="cert">${esc(d.cert)}</span>`:""}
        ${q.has_ro?`<span class="qual" title="Subtitrare în română disponibilă">RO</span>`:""}</div>
      ${d.tagline?`<p class="tag">${esc(d.tagline)}</p>`:""}
      <p>${esc(d.overview)||`<span style="color:#888">Fără descriere${ME.admin&&!ME.has_tmdb?" – adaugă o cheie TMDB în Administrare":""}.</span>`}</p>
      ${d.kind==="movie"&&n?`<div class="subpick" data-mid="${n.id}"></div>`:""}</div>
     <div class="side">
      ${cast.length?`<div><b>Distribuție: </b>${cast.slice(0,4).map(c=>esc(c.name)).join(", ")}${cast.length>4?`, <a href="#" onclick="document.querySelector('.cast').scrollIntoView({behavior:'smooth'});return false"><i>mai mulți</i></a>`:""}</div>`:""}
      ${d.genres.length?`<div><b>Genuri: </b>${d.genres.map(esc).join(", ")}</div>`:""}
      ${d.director?`<div><b>${d.kind==="series"?"Creat de":"Regia"}: </b>${esc(d.director)}</div>`:""}
      ${d.orig_title&&d.orig_title!==d.title?`<div><b>Titlu original: </b>${esc(d.orig_title)}</div>`:""}
      ${d.audio&&d.audio.filter(a=>a!=="Necunoscută").length?`<div><b>Audio: </b>${[...new Set(d.audio.filter(a=>a!=="Necunoscută"))].map(esc).join(", ")}</div>`:""}
     </div></div>
    ${d.kind==="series"?`<div class="eps"><h3>Episoade ${d.seasons.length>1?`<select class="sel" id="ssel2">${d.seasons.map(s=>`<option value="${s.season}">Sezonul ${s.season}</option>`).join("")}</select>`:`<span style="font-size:16px;color:#aaa">Sezonul ${d.seasons[0]?.season??1}</span>`}</h3><div id="eplist"></div></div>`:""}
    ${d.kind==="movie"&&d.media.length>1?`<div class="eps"><h3>Versiuni</h3>${d.media.map(mm=>`<div class="ep" data-mid="${mm.id}" data-pos="${mm.position}"><div class="n">▶</div><div>${esc(mm.file)}</div><div>${mm.quality} ${fmtT(mm.duration)}</div></div>`).join("")}</div>`:""}
    ${cast.length?`<div class="cast"><h3>Distribuție</h3><div class="people">${cast.map(c=>`<div class="person"><div class="ph" style="${c.profile?`background-image:url('${img(c.profile,"w185")}')`:""}"></div><div>${esc(c.name)}</div><div class="ch">${esc(c.character||"")}</div></div>`).join("")}</div></div>`:""}
    ${ME.admin?`<div class="adminbar"><button class="bsm" id="mfix">✎ Corectează potrivirea (TMDB)</button><span style="color:#666;font-size:12px;align-self:center">${d.tmdb_id?"TMDB #"+d.tmdb_id:"nepotrivit"}</span></div>`:""}
   </div></div>`;
  m.onclick=e=>{if(e.target===m)closeModal()};
  m.querySelectorAll(".subpick").forEach(renderSubPick);
  if(n){$("#mplay").onclick=()=>{closeModal();playMedia(n.id,n.position>20?n.position:0)}}
  if($("#mstart"))$("#mstart").onclick=()=>{closeModal();playMedia(n.id,0)};
  $("#mlist").onclick=async()=>{const r=await api("/api/mylist/"+d.id,{method:"POST"});$("#mlist use").setAttribute("href",r.in_list?"#i-check":"#i-plus");toast(r.in_list?"Adăugat în Lista mea":"Eliminat din Lista mea")};
  if($("#mtrailer"))$("#mtrailer").onclick=()=>showTrailer(d.trailer);
  if(ME.admin){$("#mfix").onclick=()=>fixMatch(d);}
  m.querySelectorAll(".ep[data-mid]").forEach(e=>e.onclick=()=>{closeModal();playMedia(+e.dataset.mid,+e.dataset.pos)});
  if(d.kind==="series"){
    const s0=season??(n?n.season:d.seasons[0]?.season);
    if($("#ssel2")){$("#ssel2").value=s0;$("#ssel2").onchange=e=>renderEps(+e.target.value)}
    renderEps(s0);
  }
}
function renderEps(sn){
  const s=CUR.seasons.find(x=>x.season==sn)||CUR.seasons[0];if(!s)return;
  $("#eplist").innerHTML=s.episodes.map(e=>`<div class="ep ${CUR.next&&CUR.next.id===e.id?"cur":""}" data-mid="${e.id}" data-pos="${e.watched?0:e.position}" title="Clic pentru detalii · ▶ pentru redare">
    <div class="n">${e.episode??""}</div>
    <div class="st" style="${e.still?`background-image:url('${img(e.still,"w300")}')`:CUR.backdrop?`background-image:url('${img(CUR.backdrop,"w300")}')`:""}"><div class="pl"><span><svg class="ico" style="width:18px"><use href="#i-play"/></svg></span></div>
      ${e.watched?`<div class="pbar"><i style="width:100%"></i></div>`:e.position>0?`<div class="pbar"><i style="width:${Math.min(100,e.position/(e.duration||1)*100)}%"></i></div>`:""}</div>
    <div><div class="t"><span>${esc(e.title)}${e.quality?`<span class="badge">${e.quality}</span>`:""}${e.has_ro?`<span class="badge">RO</span>`:""}${e.watched?` <span class="wd" title="Vizionat">✓</span>`:""}</span><span>${e.duration?Math.round(e.duration/60)+" min":""}</span></div>
    <p>${esc(e.overview)}</p></div></div>`).join("");
  $$("#eplist .ep").forEach(e=>e.onclick=ev=>{
    if(ev.target.closest(".pl span")){closeModal();playMedia(+e.dataset.mid,+e.dataset.pos);return}   // butonul ▶ de pe imagine = redare directă
    showEpisode(+e.dataset.mid)});
}

/* ---------- descărcare ---------- */
function dlBtn(mid){
  if(!ME||ME.download==="none")return "";
  const t=ME.download==="throttled"?"Descarcă (din afara casei viteza e limitată la bitrate-ul tău maxim)":"Descarcă fișierul original";
  return `<a class="circ" style="width:44px;height:44px" href="/api/download/${mid}" download title="${t}" onclick="dlStart(event)"><svg class="ico"><use href="#i-dl"/></svg></a>`;
}
function dlStart(){toast(ME.download==="throttled"?"Descărcarea a pornit – viteză limitată (ești în afara rețelei locale)":"Descărcarea a pornit")}

/* ---------- salvare în aplicaţie, pentru vizionare fără internet ---------- */
const OFFHOST=()=> (window.cvDesktop&&window.cvDesktop.saveOffline) ? window.cvDesktop
               : (window.CineVerseApp&&window.CineVerseApp.saveOffline) ? window.CineVerseApp : null;
function offBtn(mid){
  if(!ME||ME.download==="none"||!OFFHOST())return "";
  return `<button class="circ" style="width:44px;height:44px" data-off="${mid}" title="Salvează pe dispozitiv (îl poţi vedea şi fără internet)"><svg class="ico"><use href="#i-save"/></svg></button>`;
}
/* legăm butoanele după ce HTML-ul a fost pus în pagină */
/* un singur ascultător pe document – butoanele apar şi dispar odată cu ferestrele */
document.addEventListener("click",async ev=>{
  const b=ev.target.closest&&ev.target.closest("[data-off]");
  if(!b||b.disabled)return;
  ev.preventDefault();
  const h=OFFHOST(); if(!h)return;
  const mid=b.dataset.off;
  b.disabled=true;
  try{
    const d=await api("/api/media/"+mid+"/details");
    let subs=[];
    try{const sd=await api("/api/media/"+mid+"/subs");subs=(sd.subs||[]).slice(0,4).map(x=>({id:x.id,label:x.label||x.lang}))}catch(e){}
    const meta={id:+mid,title:d.nice_title||d.series||d.title||"Film",
      sub:d.nice_sub||"",
      poster:d.poster?("/img/w342/"+String(d.poster).replace(/^\//,"")):"",
      duration:Math.floor(d.duration||0),subs};
    const r=await (window.CineVerseApp&&h===window.CineVerseApp ? h.saveOffline(JSON.stringify(meta)) : h.saveOffline(meta));
    const ok=(r===true||r==="1"||(r&&r.ok));
    toast(ok?"Se salvează pe dispozitiv – îl găseşti în „Descărcate”":"Nu am putut salva: "+((r&&r.error)||"eroare"),5000);
  }catch(e){toast(t("save_fail")+": "+e.message,5000)}
  finally{b.disabled=false}
});

/* ---------- alegerea subtitrării din fereastra filmului / episodului ---------- */
async function renderSubPick(el){
  const mid=+el.dataset.mid;let d;try{d=await api(`/api/media/${mid}/subs`)}catch(e){return}
  const ch=String(pref("sub_"+mid,"auto"));
  const ro=d.subs.find(x=>x.lang==="ro");
  el.innerHTML=`<label>Subtitrare</label>
    <select>
      <option value="auto">Automat${ro?` – ${esc(ro.label)}`:" – română, dacă există"}</option>
      <option value="off">Fără subtitrare</option>
      ${d.subs.map(x=>`<option value="${x.id}">${esc(x.label)}</option>`).join("")}
    </select>
    ${d.can_search?`<button class="bsm" data-srch>🔍 Caută online (RO)</button>`:""}
    <div class="subres"></div>`;
  const sel=el.querySelector("select");
  sel.value=[...sel.options].some(o=>o.value===ch)?ch:"auto";
  sel.onchange=()=>{setPref("sub_"+mid,sel.value);toast(sel.value==="off"?"Fără subtitrare":"Subtitrare: "+sel.options[sel.selectedIndex].text)};
  const b=el.querySelector("[data-srch]");
  if(b)b.onclick=async()=>{
    const box=el.querySelector(".subres");b.disabled=true;box.innerHTML='<div class="pspin" style="position:static;margin:8px 0;width:26px;height:26px"></div>';
    try{const r=await api(`/api/media/${mid}/subs/search`,{method:"POST"});b.disabled=false;
      box.innerHTML=r.results.length?r.results.map(x=>`<button class="subopt" data-f="${x.file_id}" data-r="${esc(x.release)}" title="${esc(x.file_name)}"><span>${x.hash_match?"⭐ ":""}${esc(x.release||x.file_name)}</span><small>${esc(x.downloads)}⬇${x.hi?" · HI":""}${x.ai?" · AI":""}</small></button>`).join("")
        +(r.remaining!=null?`<div style="color:#777;font-size:12px;margin-top:6px">Descărcări rămase azi: ${esc(r.remaining)} · ⭐ = potrivire exactă cu fișierul</div>`:"")
        :`<div style="color:#888;font-size:13px;padding:6px 0">Nu am găsit subtitrări în română. ${esc(r.error||"")}</div>`;
      box.querySelectorAll("[data-f]").forEach(o=>o.onclick=async()=>{o.disabled=true;o.querySelector("span").textContent="Descarc…";
        try{const dd=await api(`/api/media/${mid}/subs/download`,{method:"POST",body:{file_id:+o.dataset.f,release:o.dataset.r}});
          setPref("sub_"+mid,String(dd.sub.id));t("sub_downloaded");renderSubPick(el)}catch(e){toast(e.message,5000);o.disabled=false}});
    }catch(e){b.disabled=false;box.innerHTML=`<div style="color:#e87c03;font-size:13px">${esc(e.message)}</div>`}};
}

/* ---------- fișa episodului ---------- */
async function showEpisode(mid){
  let d;try{d=await api(`/api/media/${mid}/details`)}catch(e){return toast(e.message)}
  const m=$("#modal");m.classList.remove("hidden");document.body.style.overflow="hidden";
  const x=d.extra||{};const bg=d.still?img(d.still,"w1280"):d.backdrop?img(d.backdrop,"w1280"):"";
  const pct=d.duration?Math.min(100,d.position/d.duration*100):0;
  const resume=!d.watched&&d.position>20;
  const air=d.air_date?new Date(d.air_date).toLocaleDateString("ro-RO",{day:"numeric",month:"long",year:"numeric"}):"";
  const mb=b=>b>1e9?(b/1e9).toFixed(2)+" GB":(b/1e6).toFixed(0)+" MB";
  m.innerHTML=`<div class="box">
   <button class="mclose" onclick="closeModal()"><svg class="ico"><use href="#i-x"/></svg></button>
   <button class="epback" id="epback"><svg class="ico"><use href="#i-back"/></svg>${esc(d.series)}</button>
   <div class="mhero" style="--img:${bg?`url('${bg}')`:"linear-gradient(135deg,#28324a,#111)"};background-image:var(--img)">
    <div class="mi">${d.logo?`<img class="tlogo" style="max-height:70px;margin-bottom:10px" src="${img(d.logo,"w300")}" alt="${esc(d.series)}">`:`<div style="font-weight:700;color:#ddd;margin-bottom:6px;text-shadow:0 2px 6px #000">${esc(d.series)}</div>`}
     <div class="epnum">Sezonul ${d.season} · Episodul ${d.episode}</div>
     <h2 style="margin-bottom:16px">${esc(d.title)}</h2>
     <div class="btns"><button class="bplay" id="eplay"><svg class="ico"><use href="#i-play"/></svg>${resume?"Reia":"Redă"}</button>
      ${resume?`<button class="binfo" id="estart">↺ De la început</button>`:""}
      <button class="circ" style="width:44px;height:44px" id="ewatched" title="${d.watched?"Marchează ca nevizionat":"Marchează ca vizionat"}"><svg class="ico"><use href="#${d.watched?"i-check":"i-plus"}"/></svg></button>
      ${dlBtn(d.id)}${offBtn(d.id)}</div>
     ${resume?`<div class="resume"><div class="bar"><i style="width:${pct}%"></i></div><small>Ai văzut ${fmtT(d.position)} din ${fmtT(d.duration)} · mai sunt ${Math.round((d.duration-d.position)/60)} min</small></div>`:""}
    </div></div>
   <div class="mbody"><div class="mcols"><div>
     <div class="meta" style="margin-bottom:14px">${x.rating?`<span class="match">★ ${x.rating.toFixed(1)}</span>`:""}${air?`<span class="mut">${air}</span>`:""}
      ${d.duration?`<span class="mut">${Math.round(d.duration/60)} min</span>`:""}${d.quality?`<span class="qual">${d.quality}</span>`:""}${d.hdr?`<span class="qual">HDR</span>`:""}
      ${d.has_ro?`<span class="qual" title="Subtitrare în română">RO</span>`:""}${d.watched?`<span style="color:#46d369">✓ Vizionat</span>`:""}</div>
     <p>${esc(d.overview)||'<span style="color:#888">Nu există o descriere pentru acest episod.</span>'}</p>
     <div class="subpick" data-mid="${d.id}"></div>
    </div><div class="side">
     ${x.directors&&x.directors.length?`<div><b>Regia: </b>${x.directors.map(esc).join(", ")}</div>`:""}
     ${x.writers&&x.writers.length?`<div><b>Scenariu: </b>${x.writers.map(esc).join(", ")}</div>`:""}
     ${d.audio.length?`<div><b>Audio: </b>${d.audio.map(esc).join("<br>")}</div>`:""}
     <div><b>Subtitrări: </b>${d.subs.length?d.subs.map(esc).join("<br>"):"—"}</div>
     ${d.video?`<div><b>Video: </b>${esc(d.video)}${d.hdr?" · HDR":""}</div>`:""}
     <div><b>Fișier: </b><span style="word-break:break-all">${esc(d.file)}</span> (${mb(d.size)})</div>
    </div></div>
    ${x.guests&&x.guests.length?`<div class="cast"><h3>Invitați speciali</h3><div class="people">${x.guests.map(c=>`<div class="person"><div class="ph" style="${c.profile?`background-image:url('${img(c.profile,"w185")}')`:""}"></div><div>${esc(c.name)}</div><div class="ch">${esc(c.character||"")}</div></div>`).join("")}</div></div>`:""}
    <div class="epnav">${d.prev?`<button class="bsm" id="eprev">‹ ${esc(d.prev.label)}</button>`:"<span></span>"}${d.next?`<button class="bsm" id="enext">${esc(d.next.label)} ›</button>`:""}</div>

   </div></div>`;
  m.scrollTop=0;m.onclick=e=>{if(e.target===m)closeModal()};
  $("#epback").onclick=()=>openItem(d.item_id,d.season);
  $("#eplay").onclick=()=>{closeModal();playMedia(d.id,resume?d.position:0)};
  if($("#estart"))$("#estart").onclick=()=>{closeModal();playMedia(d.id,0)};
  $("#ewatched").onclick=async()=>{await api(`/api/watched/${d.id}`,{method:"POST",body:{watched:!d.watched}});toast(d.watched?"Marcat ca nevizionat":"Marcat ca vizionat");showEpisode(d.id)};
  if($("#eprev"))$("#eprev").onclick=()=>showEpisode(d.prev.id);
  if($("#enext"))$("#enext").onclick=()=>showEpisode(d.next.id);
  m.querySelectorAll(".subpick").forEach(renderSubPick);
}
function closeModal(){$("#modal").classList.add("hidden");$("#modal").innerHTML="";document.body.style.overflow=""}
function showTrailer(key){
  const m=$("#modal");const box=m.querySelector(".box");if(!box)return;
  const hero=box.querySelector(".mhero");hero.innerHTML=`<iframe style="position:absolute;inset:0;width:100%;height:100%;border:0;z-index:3" src="https://www.youtube-nocookie.com/embed/${encodeURIComponent(key)}?autoplay=1&rel=0" allow="autoplay;fullscreen" allowfullscreen></iframe>`;
}
async function fixMatch(d){
  const term=prompt(t("fix_match_prompt"),d.orig_title||d.title);if(!term)return;
  if(/^\d+$/.test(term.trim())){await doMatch(d.id,+term.trim());return}
  const r=await api(`/api/admin/tmdb-search?kind=${d.kind}&query=${encodeURIComponent(term)}`);
  const m=$("#modal");
  m.innerHTML=`<div class="box" style="padding:26px"><button class="mclose" onclick="closeModal()"><svg class="ico"><use href="#i-x"/></svg></button><h3 style="margin-bottom:14px">Alege potrivirea corectă</h3><div class="mlist">
   ${r.results.map(x=>`<div class="mr" data-id="${x.id}">${x.poster?`<img src="${img(x.poster,"w92")}">`:""}<div><b>${esc(x.title)}</b> (${esc(x.year)})<div style="color:#999;font-size:13px">${esc(x.overview)}</div></div></div>`).join("")||"<p>Niciun rezultat (cheia TMDB e setată?)</p>"}</div></div>`;
  m.querySelectorAll(".mr").forEach(e=>e.onclick=()=>doMatch(d.id,+e.dataset.id));
}
async function doMatch(id,tid){try{await api(`/api/admin/item/${id}/match`,{method:"POST",body:{tmdb_id:tid}});t("meta_updated");closeModal();route()}catch(e){alert(e.message)}}

/* ================= PLAYER ================= */
const V=$("#vid");const P={};let hls=null,uiT=null,saveT=null,liveT=null,cues=[],subOffset=0,lastSubHTML="";
try{for(let i=0;i<localStorage.length;i++){const k=localStorage.key(i);if(k&&k.startsWith("cinemo_")){const n="cineverse_"+k.slice(7);if(localStorage.getItem(n)==null)localStorage.setItem(n,localStorage.getItem(k))}}}catch(e){}
const CLIENT=(()=>{try{let c=localStorage.getItem("cineverse_client");if(!c){c=Math.random().toString(36).slice(2);localStorage.setItem("cineverse_client",c)}return c}catch(e){return "web"}})();
const pref=(k,d)=>{try{const v=localStorage.getItem("cineverse_"+k);return v==null?d:JSON.parse(v)}catch(e){return d}};
const setPref=(k,v)=>{try{localStorage.setItem("cineverse_"+k,JSON.stringify(v))}catch(e){}};
const absT=()=>(P.offset||0)+(V.currentTime||0);

async function playMedia(mid,start=0,audio=null,keepSub=false){
  if(CAST.device){if(!$("#player").classList.contains("hidden"))await closePlayer();return castPlay(mid,start,audio)}
  const pl=$("#player");pl.classList.remove("hidden","live");pl.classList.add("ui");$("#bch").classList.add("hidden");$("#bsubs").classList.remove("hidden");spin(true);document.documentElement.style.overflow="hidden";
  if(!keepSub){cues=[];renderSubs(true);P.subId=null}
  await stopStream();
  let d;
  try{d=await api("/api/play",{method:"POST",body:{media_id:mid,start,audio,client:CLIENT,force_transcode:!!P.forceTx&&P.media===mid,quality:pref("quality","")}})}
  catch(e){spin(false);if(!ME)return;toast(e.message,6000);if(!keepSub){$("#player").classList.add("hidden");if(document.fullscreenElement)document.exitFullscreen().catch(()=>{})}return}
  Object.assign(P,{media:mid,mode:d.mode,sid:d.sid,offset:d.offset||0,duration:d.duration,audioList:d.audio,audioIdx:d.audio_index,method:d.method,avail:0,startAt:start,remote:d.remote,quality:d.quality,qualities:d.qualities||[]});
  if(!keepSub){
    const info=await api(`/api/media/${mid}/info`);P.info=info;
    $("#ptitle").innerHTML=`<b>${esc(info.title)}</b><span>${esc(info.subtitle)}</span>`;
    const nx=await api(`/api/media/${mid}/next`);P.next=nx.next;$("#bnext").classList.toggle("hidden",!nx.next);
    loadSubsList(true);
  }
  $("#nextep").classList.add("hidden");P.nextShown=false;
  if(d.mode==="direct"){V.src=d.url;V.addEventListener("loadedmetadata",()=>{if(start>0)V.currentTime=start},{once:true})}
  else if(window.Hls&&Hls.isSupported()){
    hls=new Hls({startPosition:0,maxBufferLength:60,maxMaxBufferLength:180,backBufferLength:120,liveDurationInfinity:false,
                 manifestLoadingMaxRetry:10,levelLoadingMaxRetry:10,fragLoadingMaxRetry:10,xhrSetup:x=>x.withCredentials=true});
    hls.on(Hls.Events.LEVEL_UPDATED,(e,dd)=>{P.avail=dd.details.totalduration||P.avail});
    hls.on(Hls.Events.LEVEL_LOADED,(e,dd)=>{P.avail=dd.details.totalduration||P.avail});
    hlsErrors(hls,false);
    hls.loadSource(d.url);hls.attachMedia(V);
  } else {V.src=d.url}
  V.volume=pref("vol",1);V.muted=pref("muted",false);$("#rvol").value=V.volume;updVol();
  V.play().catch(()=>{spin(false)});
  showUI();clearInterval(saveT);saveT=setInterval(saveProgress,10000);
}
/* Tratare erori HLS cu limita – fara bucle infinite care ar bombarda serverul */
function hlsErrors(h,live){
  let mediaErr=0,netErr=0,t0=0,dead=false;
  const giveUp=msg=>{if(dead)return;dead=true;spin(false);toast(msg,7000);closePlayer()};
  h.on(Hls.Events.ERROR,(e,dd)=>{
    if(!dd.fatal||dead)return;
    const now=Date.now();
    if(now-t0>30000){mediaErr=0;netErr=0}     // erori izolate la >30s nu se cumuleaza
    t0=now;
    if(dd.type===Hls.ErrorTypes.MEDIA_ERROR){
      if(++mediaErr<=3){try{h.recoverMediaError()}catch(_){giveUp("Eroare la redare.")}return}
      giveUp(live?"Canalul nu poate fi redat pe acest dispozitiv (format sau codec neacceptat)."
                 :"Fișierul nu poate fi redat pe acest dispozitiv (format sau codec neacceptat).");
    }else if(dd.type===Hls.ErrorTypes.NETWORK_ERROR){
      if(++netErr<=6){setTimeout(()=>{if(!dead)try{h.startLoad()}catch(_){}},1500);return}
      giveUp(live?"Sursa canalului nu răspunde. Încearcă din nou mai târziu."
                 :"Conexiunea cu serverul s-a întrerupt.");
    }else giveUp("Eroare la redare.");
  });
}
async function stopStream(){
  if(hls){hls.destroy();hls=null}
  V.removeAttribute("src");V.load();
  if(P.sid){const s=P.sid;P.sid=null;api("/api/play/"+s,{method:"DELETE"}).catch(()=>{})}
}

/* ---- TV Live playback ---- */
async function playLive(cid){
  if(CAST.device){if(!$("#player").classList.contains("hidden"))await closePlayer();return castPlayLive(cid)}
  const pl=$("#player");pl.classList.remove("hidden");pl.classList.add("ui","live");spin(true);document.documentElement.style.overflow="hidden";
  $("#bnext").classList.add("hidden");$("#bsubs").classList.add("hidden");$("#bch").classList.remove("hidden");
  cues=[];renderSubs(true);P.subId=null;P.next=null;
  await stopStream();
  let d;
  try{d=await api("/api/live/play",{method:"POST",body:{channel:cid,client:CLIENT,quality:pref("quality","")}})}
  catch(e){spin(false);if(!ME)return;toast(e.message,6000);pl.classList.add("hidden");pl.classList.remove("live");if(document.fullscreenElement)document.exitFullscreen().catch(()=>{});return}
  Object.assign(P,{live:true,media:null,liveCh:cid,method:d.method,quality:d.quality,qualities:d.qualities||[],remote:d.remote});
  $("#ptitle").innerHTML=`<b>📺 ${esc(d.channel.name)}</b>${d.channel.now?`<span>${esc(d.channel.now.title)}</span>`:""}`;
  $("#nextep").classList.add("hidden");P.nextShown=false;
  if(window.Hls&&Hls.isSupported()){
    hls=new Hls({maxBufferLength:20,maxMaxBufferLength:30,liveDurationInfinity:true,liveSyncDurationCount:3,
                 manifestLoadingMaxRetry:20,levelLoadingMaxRetry:20,fragLoadingMaxRetry:20,xhrSetup:x=>x.withCredentials=true});
    hlsErrors(hls,true);
    hls.on(Hls.Events.MANIFEST_PARSED,()=>{V.play().catch(()=>{spin(false)})});
    hls.loadSource(d.url);hls.attachMedia(V);
  } else {V.src=d.url;V.play().catch(()=>{spin(false)})}
  V.volume=pref("vol",1);V.muted=pref("muted",false);$("#rvol").value=V.volume;updVol();
  showUI();clearInterval(saveT);clearInterval(liveT);liveT=setInterval(livePing,10000);livePing();
}
function livePing(){
  if(!P.live)return;
  api("/api/live/ping",{method:"POST",body:{client:CLIENT,paused:V.paused}})
    .then(r=>{if(r&&r.stop&&P.live){closePlayer();setTimeout(()=>alert(t("live_stop_alert")),300)}}).catch(()=>{});
}
function renderChMenu(){
  const m=$("#pmenu");
  m.innerHTML=`<h4>Canale<button class="circ" onclick="$('#pmenu').classList.add('hidden')"><svg class="ico"><use href="#i-x"/></svg></button></h4>
    ${LIVECH.map(c=>`<button class="chopt ${c.id===P.liveCh?"on":""}" data-lch="${c.id}">${c.logo?`<img src="/api/live/logo/${c.id}" loading="lazy" alt="" onerror="this.remove()">`:""}<span class="chn">${c.num?c.num+". ":""}${esc(c.name)}</span>${c.now?`<small>${esc(c.now.title)}</small>`:""}</button>`).join("")}`;
  m.querySelectorAll("[data-lch]").forEach(b=>b.onclick=()=>{m.classList.add("hidden");const id=+b.dataset.lch;if(id!==P.liveCh)playLive(id)});
}
$("#bch").onclick=async e=>{e.stopPropagation();const m=$("#pmenu");if(!m.classList.contains("hidden")){m.classList.add("hidden");return}
  if(!LIVECH.length){try{const d=await api("/api/live/channels");LIVECH=d.channels}catch(err){return}}
  renderChMenu();m.classList.remove("hidden");showUI(true)};
function saveProgress(beacon){
  if(!P.media||!P.duration)return;const t=absT();if(t<5&&!beacon)return;
  const body=JSON.stringify({media_id:P.media,position:t,duration:P.duration,client:CLIENT,paused:V.paused,sub:P.subId||null});
  if(beacon&&navigator.sendBeacon)navigator.sendBeacon("/api/progress",new Blob([body],{type:"application/json"}));
  else fetch("/api/progress",{method:"POST",headers:{"Content-Type":"application/json"},body,credentials:"same-origin"})
    .then(r=>r.json()).then(j=>{if(j&&j.stop&&P.media){closePlayer();setTimeout(()=>alert(t("live_stop_alert")),300)}}).catch(()=>{});
}
async function closePlayer(){
  if(P.live)clearInterval(liveT);else saveProgress();
  clearInterval(saveT);await stopStream();P.media=null;P.live=false;P.forceTx=false;
  api("/api/play/stop",{method:"POST",body:{client:CLIENT}}).catch(()=>{});
  $("#player").classList.add("hidden");$("#player").classList.remove("live");$("#pmenu").classList.add("hidden");document.documentElement.style.overflow="";
  if(document.fullscreenElement)document.exitFullscreen().catch(()=>{});
  cues=[];renderSubs(true);route();
}
addEventListener("beforeunload",()=>{if(P.media)saveProgress(true)});
function spin(on){$("#pspin").classList.toggle("hidden",!on)}
V.addEventListener("waiting",()=>spin(true));V.addEventListener("playing",()=>spin(false));V.addEventListener("canplay",()=>spin(false));
V.addEventListener("play",()=>{updPP();setTimeout(()=>saveProgress(),300)});V.addEventListener("pause",()=>{updPP();showUI(true);saveProgress()});
V.addEventListener("error",()=>{if(P.mode==="direct"&&P.media&&!P.forceTx){P.forceTx=true;t("incompatible_format");playMedia(P.media,absT(),P.audioIdx,true)}});
V.addEventListener("ended",()=>{if(P.mode==="hls"&&P.avail&&absT()<P.duration-15)return;saveProgress();if(P.next)playNext();else closePlayer()});
function updPP(){$("#bpp use").setAttribute("href",V.paused?"#i-play":"#i-pause")}
function togglePlay(){if(V.paused){V.play()}else V.pause();const b=document.createElement("div");b.className="bigplay";b.innerHTML=`<svg class="ico" style="width:44px;height:44px"><use href="#${V.paused?"i-pause":"i-play"}"/></svg>`;$("#player").appendChild(b);setTimeout(()=>b.remove(),700)}
$("#bpp").onclick=togglePlay;
let _clickT=0;
const _pwin=$(".pwin");
_pwin.addEventListener("click",e=>{if(e.target.closest("button,input,select,a,.seek"))return;if(!$("#pmenu").classList.contains("hidden")){$("#pmenu").classList.add("hidden");return}clearTimeout(_clickT);_clickT=setTimeout(togglePlay,240)});
_pwin.addEventListener("dblclick",e=>{if(e.target.closest("button,input,select,a,.seek"))return;clearTimeout(_clickT);toggleFS()});
function skip(s){seekTo(absT()+s)}
function seekTo(t){
  t=Math.max(0,Math.min(t,(P.duration||1e9)-1));showUI();
  if(P.mode==="direct"||!P.sid){V.currentTime=t;return}
  const rel=t-P.offset;
  if(rel>=0&&rel<=Math.max(0,(P.avail||0)-2)){V.currentTime=rel;return}
  playMedia(P.media,t,P.audioIdx,true);
}
function playNext(){if(!P.next)return;saveProgress();const n=P.next;playMedia(n.id,0)}
$("#bnext").onclick=playNext;
function toggleFS(){if(document.fullscreenElement)document.exitFullscreen();else document.documentElement.requestFullscreen().catch(()=>{})}
$("#bfs").onclick=toggleFS;
document.addEventListener("fullscreenchange",()=>{const f=!!document.fullscreenElement;document.body.classList.toggle("fs",f);$("#bfs use").setAttribute("href",f?"#i-exfs":"#i-fs")});
function updVol(){$("#bvol use").setAttribute("href",V.muted||V.volume===0?"#i-mute":"#i-vol")}
$("#bvol").onclick=()=>{V.muted=!V.muted;setPref("muted",V.muted);updVol()};
$("#rvol").oninput=e=>{V.volume=+e.target.value;V.muted=false;setPref("vol",V.volume);setPref("muted",false);updVol()};
function showUI(stay){const p=$("#player");p.classList.add("ui");clearTimeout(uiT);if(!stay)uiT=setTimeout(()=>{if(!V.paused&&$("#pmenu").classList.contains("hidden"))p.classList.remove("ui")},3200)}
$("#player").addEventListener("mousemove",()=>showUI());$("#player").addEventListener("touchstart",()=>showUI(),{passive:true});

/* seek bar */
const seek=$("#seek");
function seekFrac(e){const r=seek.querySelector(".rail").getBoundingClientRect();return Math.max(0,Math.min(1,(e.clientX-r.left)/r.width))}
seek.addEventListener("mousemove",e=>{const f=seekFrac(e);const tip=$("#stip");tip.textContent=fmtT(f*P.duration);const r=seek.querySelector(".rail").getBoundingClientRect();tip.style.left=(e.clientX-seek.getBoundingClientRect().left)+"px"});
seek.addEventListener("click",e=>seekTo(seekFrac(e)*P.duration));
let drag=false;seek.addEventListener("mousedown",()=>drag=true);addEventListener("mouseup",e=>{drag=false});
addEventListener("mousemove",e=>{if(drag){const f=seekFrac(e);$("#sdone").style.width=f*100+"%";$("#sknob").style.left=f*100+"%"}});
function tick(){
  if(P.media&&!$("#player").classList.contains("hidden")){
    const t=absT(),D=P.duration||1;
    if(!drag){$("#sdone").style.width=(t/D*100)+"%";$("#sknob").style.left=(t/D*100)+"%"}
    let be=0;try{for(let i=0;i<V.buffered.length;i++)if(V.buffered.start(i)<=V.currentTime+1)be=Math.max(be,V.buffered.end(i))}catch(e){}
    $("#sbuf").style.left=(P.offset/D*100)+"%";$("#sbuf").style.width=(Math.max(0,be)/D*100)+"%";
    $("#sleft").textContent=fmtT(D-t);
    renderSubs();
    if(P.next&&!P.nextShown&&D-t<35&&D>120&&!V.paused){P.nextShown=true;const ne=$("#nextep");ne.innerHTML=`<button onclick="playNext()">▶ Episodul următor</button><button class="sec" onclick="this.parentNode.classList.add('hidden')">Vizionează genericul</button>`;ne.classList.remove("hidden")}
  }
  requestAnimationFrame(tick);
}
requestAnimationFrame(tick);

/* keyboard */
document.addEventListener("keydown",e=>{
  if($("#player").classList.contains("hidden")){if(e.key==="Escape"&&!$("#modal").classList.contains("hidden"))closeModal();return}
  if(e.target.tagName==="INPUT"&&e.target.type!=="range")return;
  const k=e.key;
  if(k===" "||k==="k"){e.preventDefault();togglePlay()}
  else if(k==="ArrowLeft"||k==="j"){e.preventDefault();skip(k==="j"?-10:-10)}
  else if(k==="ArrowRight"||k==="l"){e.preventDefault();skip(10)}
  else if(k==="ArrowUp"){e.preventDefault();V.volume=Math.min(1,V.volume+.05);$("#rvol").value=V.volume;setPref("vol",V.volume)}
  else if(k==="ArrowDown"){e.preventDefault();V.volume=Math.max(0,V.volume-.05);$("#rvol").value=V.volume;setPref("vol",V.volume)}
  else if(k==="f")toggleFS();else if(k==="m"){V.muted=!V.muted;updVol()}
  else if(k==="Escape"&&!document.fullscreenElement){if(!$("#pmenu").classList.contains("hidden"))$("#pmenu").classList.add("hidden");else closePlayer()}
  else if(k==="c")cycleSubs();
  else if(k==="g"){subOffset-=.25;toast(`Sincronizare subtitrare: ${subOffset.toFixed(2)}s`,1200)}
  else if(k==="h"){subOffset+=.25;toast(`Sincronizare subtitrare: +${subOffset.toFixed(2)}s`,1200)}
  else if(k==="i"&&ME&&ME.admin){const pi=$("#pinfo");pi.classList.toggle("hidden");pi.textContent=`Mod: ${P.method} · offset ${fmtT(P.offset)} · disponibil ${fmtT(P.avail)}`}
  showUI();
});

/* ================= SUBTITLES ================= */
P.subs=[];
async function loadSubsList(auto){
  const d=await api(`/api/media/${P.media}/subs`);P.subs=d.subs;P.canSearch=d.can_search;
  if(auto){
    const ch=String(pref("sub_"+P.media,"auto"));          // alegerea din fereastra filmului/episodului
    if(ch==="off")return;
    if(ch!=="auto"){const x=d.subs.find(s=>String(s.id)===ch);if(x)return selectSub(x.id)}
    const want=pref("subs_on",true);
    const audioRo=(P.audioList||[]).find(a=>a.index===P.audioIdx&&/^(ro|rum|ron)$/.test(a.lang));
    const ro=d.subs.find(s=>s.lang==="ro");
    if(want&&ro&&!audioRo)selectSub(ro.id);
    else if(want&&!ro&&d.can_search&&!audioRo)autoFetchRo();
  }
}
async function autoFetchRo(){
  const mid=P.media;
  try{const r=await api(`/api/media/${mid}/subs/search`,{method:"POST"});
    if(P.media!==mid||P.subId)return;
    if(r.results.length){const best=r.results[0];const dd=await api(`/api/media/${mid}/subs/download`,{method:"POST",body:{file_id:best.file_id,release:best.release}});
      if(P.media!==mid)return;P.subs.unshift(dd.sub);selectSub(dd.sub.id);t("sub_auto_found");}
  }catch(e){}
}
async function selectSub(id){
  P.subId=id;setTimeout(()=>saveProgress(),200);cues=[];lastSubHTML="";renderSubs(true);
  if(!id){setPref("subs_on",false);return}
  setPref("subs_on",true);
  try{const r=await fetch(`/api/subs/${id}.vtt`,{credentials:"same-origin"});if(!r.ok)throw new Error("HTTP "+r.status);cues=parseVTT(await r.text())}
  catch(e){t("sub_load_fail")}
}
function cycleSubs(){const ids=[null,...P.subs.map(s=>s.id)];const i=ids.indexOf(P.subId??null);const n=ids[(i+1)%ids.length];selectSub(n);toast(n?P.subs.find(s=>s.id===n).label:"Subtitrări dezactivate",1400)}
function parseVTT(t){
  const out=[];const tt=s=>{const p=s.trim().split(":").map(Number);return p.length===3?p[0]*3600+p[1]*60+p[2]:p[0]*60+p[1]};
  t.replace(/\r/g,"").split(/\n\n+/).forEach(b=>{const L=b.split("\n");const i=L.findIndex(l=>l.includes("-->"));if(i<0)return;
    const m=L[i].match(/([\d:.]+)\s*-->\s*([\d:.]+)/);if(!m)return;
    const txt=L.slice(i+1).join("\n").trim();if(!txt)return;
    out.push({s:tt(m[1]),e:tt(m[2]),h:sanitizeCue(txt)})});
  out.sort((a,b)=>a.s-b.s);return out;
}
function sanitizeCue(s){return esc(s.replace(/<(?!\/?(i|b|u)>)[^>]*>/gi,"")).replace(/&lt;(\/?)(i|b|u)&gt;/gi,"<$1$2>").replace(/\n/g,"<br>")}
function renderSubs(clear){
  const box=$("#subsbox");
  if(clear||!cues.length){if(lastSubHTML!==""){box.innerHTML="";lastSubHTML=""}return}
  const t=absT()-subOffset;
  let lo=0,hi=cues.length;while(lo<hi){const m=(lo+hi)>>1;if(cues[m].s<=t)lo=m+1;else hi=m}
  const act=[];for(let i=lo-1;i>=0&&i>lo-20;i--){if(cues[i].s<=t&&cues[i].e>t)act.unshift(cues[i].h)}
  const html=act.length?`<span>${act.join("<br>")}</span>`:"";
  if(html!==lastSubHTML){box.innerHTML=html;lastSubHTML=html}
}
function applySubStyle(){const sz=pref("subsz",1);document.documentElement.style.setProperty("--subsz",(4.6*sz)+"cqh");document.documentElement.style.setProperty("--subbg",pref("subbg",false)?"rgba(0,0,0,.65)":"transparent")}
applySubStyle();

$("#bsubs").onclick=e=>{e.stopPropagation();const m=$("#pmenu");if(!m.classList.contains("hidden")){m.classList.add("hidden");return}renderMenu();m.classList.remove("hidden");showUI(true)};
function renderMenu(){
  const m=$("#pmenu");const sz=pref("subsz",1);
  m.innerHTML=`<div class="cols2"><div><h4>Audio</h4>${(P.audioList||[]).map(a=>`<button class="opt ${a.index===P.audioIdx?"on":""}" data-a="${a.index}">${esc(a.label)}</button>`).join("")||'<div class="rowc">—</div>'}</div>
    <div><h4>Subtitrări</h4><button class="opt ${!P.subId?"on":""}" data-s="">Dezactivate</button>
    ${P.subs.map(s=>`<button class="opt ${s.id===P.subId?"on":""}" data-s="${s.id}">${esc(s.label)}</button>`).join("")}
    ${P.canSearch?`<button class="opt" id="osrch" style="color:#e50914">🔍 Caută online în română</button>`:""}</div></div>
    <div class="sep"></div>
    <div class="rowc">Sincronizare: <button data-o="-0.5">−0.5s</button><button data-o="-0.1">−0.1s</button><b style="min-width:56px;text-align:center">${subOffset>=0?"+":""}${subOffset.toFixed(1)}s</b><button data-o="0.1">+0.1s</button><button data-o="0.5">+0.5s</button><button data-o="0">Reset</button></div>
    <div class="rowc">Mărime: ${[[.75,"Mică"],[1,"Medie"],[1.3,"Mare"],[1.6,"Foarte mare"]].map(([v,l])=>`<button data-z="${v}" class="${sz==v?"on":""}">${l}</button>`).join("")}</div>
    <div class="rowc">Fundal: <button data-bg="0" class="${!pref("subbg",false)?"on":""}">Umbră</button><button data-bg="1" class="${pref("subbg",false)?"on":""}">Casetă neagră</button></div>
    <div class="sep"></div>
    <div class="rowc" style="flex-wrap:wrap">Calitate${P.remote?' <span class="pill bad" style="font-size:11px">extern</span>':""}: ${P.qualities.map(q=>`<button data-ql="${q.key}" class="${q.key===P.quality?"on":""}">${esc(q.label)}</button>`).join("")}</div>
    ${ME&&ME.admin?`<div class="rowc" style="color:#777;font-size:12px">Redare: ${esc(P.method||"")}${P.quality&&P.quality!=="orig"?" · "+esc(P.quality)+"bps":""}${P.mode==="direct"&&!P.remote?` · <a href="#" id="forcetx" style="color:#aaa;text-decoration:underline">forțează transcodarea</a>`:""}</div>`:""}`;
  m.querySelectorAll("[data-a]").forEach(b=>b.onclick=()=>{m.classList.add("hidden");playMedia(P.media,absT(),+b.dataset.a,true)});
  m.querySelectorAll("[data-s]").forEach(b=>b.onclick=()=>{selectSub(b.dataset.s?+b.dataset.s:null);setPref("sub_"+P.media,b.dataset.s||"off");renderMenu()});
  m.querySelectorAll("[data-o]").forEach(b=>b.onclick=()=>{const v=+b.dataset.o;subOffset=v===0?0:Math.round((subOffset+v)*10)/10;renderMenu()});
  m.querySelectorAll("[data-z]").forEach(b=>b.onclick=()=>{setPref("subsz",+b.dataset.z);applySubStyle();renderMenu()});
  m.querySelectorAll("[data-bg]").forEach(b=>b.onclick=()=>{setPref("subbg",b.dataset.bg==="1");applySubStyle();renderMenu()});
  if($("#osrch"))$("#osrch").onclick=()=>onlineSearch();
  m.querySelectorAll("[data-ql]").forEach(b=>b.onclick=()=>{setPref("quality",b.dataset.ql);m.classList.add("hidden");toast(t("quality_set")+": "+b.textContent);playMedia(P.media,absT(),P.audioIdx,true)});
  if($("#forcetx"))$("#forcetx").onclick=e=>{e.preventDefault();P.forceTx=true;m.classList.add("hidden");playMedia(P.media,absT(),P.audioIdx,true)};
}
async function onlineSearch(){
  const m=$("#pmenu");m.innerHTML=`<h4>Caut subtitrări în română…</h4><div class="rowc"><div class="pspin" style="position:static;margin:10px auto;width:36px;height:36px"></div></div>`;
  try{const r=await api(`/api/media/${P.media}/subs/search`,{method:"POST"});
    const srcLabel=x=>x.source==="subsro"?"🇷🇴 Subs.ro":"OpenSubtitles";
    m.innerHTML=`<h4>Subtitrări RO <button class="bsm" id="mback">Înapoi</button></h4>
      ${r.results.length?r.results.map(x=>`<button class="opt" data-f="${x.file_id||''}" data-sid="${x.subtitle_id||''}" data-dl="${esc(x.download_url||'')}" data-src="${esc(x.source||'opensubtitles')}" data-r="${esc(x.release)}" title="${esc(x.file_name)}">${x.hash_match?"⭐ ":""}${esc(x.release||x.file_name)}<small>${srcLabel(x)}${x.downloads?" · "+x.downloads+"⬇":""}${x.hi?" · HI":""}${x.ai?" · AI":""}</small></button>`).join(""):`<div class="rowc">Nu am găsit nimic. ${esc(r.error||"")}</div>`}
      ${r.remaining!=null?`<div class="rowc" style="color:#777;font-size:12px">Descărcări rămase azi (OS): ${esc(r.remaining)} · ⭐ = potrivire exactă cu fișierul</div>`:""}`;
    $("#mback").onclick=renderMenu;
    m.querySelectorAll("[data-src]").forEach(b=>b.onclick=async()=>{b.textContent="Descarc…";
      const body=b.dataset.src==="subsro"?{source:"subsro",subtitle_id:b.dataset.sid,download_url:b.dataset.dl}:{source:"opensubtitles",file_id:+b.dataset.f,release:b.dataset.r};
      try{const dd=await api(`/api/media/${P.media}/subs/download`,{method:"POST",body});P.subs.unshift(dd.sub);await selectSub(dd.sub.id);t("sub_loaded");renderMenu()}
      catch(e){toast(e.message,5000);renderMenu()}});
  }catch(e){m.innerHTML=`<h4>Eroare</h4><div class="rowc">${esc(e.message)}</div>`}
}
async function subsSearchDialog(mid){closeModal();await playMedia(mid,0);V.pause();$("#pmenu").classList.remove("hidden");onlineSearch()}

/* ================= ADMIN ================= */
let admTab="act",admT=null,actUser=0;
async function viewAdmin(){
  if(!ME.admin){location.hash="#/";return}
  const v=$("#view");clearInterval(admT);
  v.innerHTML=`<div class="page" style="max-width:1100px;margin:0 auto"><div class="head"><h2>Administrare</h2></div>
   <div class="tabs">${[["act","▶ Activitate"],["sys","📊 Sistem"],["lib","Bibliotecă"],["set","Setări"],["usr","Utilizatori"],["acc","🔐 Conturi"],["tv","📺 TV Live"],["bk","💾 Backup"]].map(([k,l])=>`<button data-t="${k}" class="${admTab===k?"on":""}">${l}</button>`).join("")}</div><div id="adm"></div></div>`;
  v.querySelectorAll("[data-t]").forEach(b=>b.onclick=()=>{admTab=b.dataset.t;viewAdmin()});
  if(admTab==="act")admAct();else if(admTab==="sys")admSys();else if(admTab==="lib")admLib();else if(admTab==="set")admSet();else if(admTab==="usr")admUsr();else if(admTab==="acc")admAcc();else if(admTab==="bk")admBk();else admTv();
}
async function admAct(){
  const ago=t=>{const m=Math.floor((Date.now()/1000-t)/60);return m<1?"acum":m<60?`acum ${m} min`:m<1440?`acum ${Math.floor(m/60)} h ${m%60} min`:new Date(t*1000).toLocaleString("ro-RO")};
  const dur=s=>{s=Math.round(s||0);const h=Math.floor(s/3600),m=Math.floor(s%3600/60);return h?`${h} h ${m} min`:m?`${m} min`:`${s} s`};
  const draw=async()=>{if(location.hash!=="#/admin"||admTab!=="act"){clearInterval(admT);return}
    let d;try{d=await api("/api/admin/activity"+(actUser?"?user="+actUser:""))}catch(e){return}
    const st=d.stats;
    $("#adm").innerHTML=`<div class="stats" style="margin-bottom:18px">
       <div class="stat"><b>${st.now}</b><span>Redări acum</span></div><div class="stat"><b>${st.transcoding}</b><span>Transcodări active</span></div>
       <div class="stat"><b>${st.remote}</b><span>Din afara casei</span></div><div class="stat"><b>${st.today}</b><span>Redări azi</span></div>
       <div class="stat"><b>${st.hours_week} h</b><span>Vizionate în 7 zile</span></div></div>
     <div class="panel"><h3>Se redă acum</h3>
      ${d.now.length?d.now.map(n=>{const pct=n.duration?Math.min(100,n.pos/n.duration*100):0;const dt=n.details||{};return `<div class="actcard">
        <div class="actimg" style="${n.img?`background-image:url('${img(n.img,"w300")}')`:""}"><span class="actstate">${n.paused?"⏸":"▶"}</span></div>
        <div class="actmain">
          <div class="acttop"><div><b class="acttitle">${esc(n.title)}</b>
            <div class="actwho"><span class="avatar" style="width:22px;height:22px;font-size:12px;display:inline-flex">${esc((n.user||"?")[0])}</span> <b>${esc(n.user)}</b> · ${esc(n.device)} · ${esc(n.ip||"")}
              ${n.kind==="cast"?'<span class="pill ok">Chromecast</span>':n.remote?'<span class="pill bad">extern</span>':'<span class="pill">LAN</span>'} ${n.paused?'<span class="pill">în pauză</span>':""}</div></div>
            <button class="bsm" data-stop='${esc(JSON.stringify({uid:n.uid,client:n.client,kind:n.kind}))}'>⏹ Oprește</button></div>
          <div class="actprog"><div class="bar"><i style="width:${pct}%"></i></div><span>${fmtT(n.pos)} / ${fmtT(n.duration)}</span></div>
          <div class="actgrid">
            <div><span>Redare</span>${esc(dt.method_label||"—")}</div>
            <div><span>Video</span>${esc(dt.src_video||"—")} → ${esc(dt.out_video||"—")}</div>
            <div><span>Audio</span>${esc(dt.src_audio||n.audio||"—")} → ${esc(dt.out_audio||"—")}</div>
            <div><span>Subtitrare</span>${esc(n.sub||"—")}</div>
            <div><span>Calitate / bitrate țintă</span>${esc(dt.quality||"—")} · ${esc(dt.bitrate||"—")}</div>
            <div><span>Bitrate real (ultimul minut)</span>${n.bw?`<b style="color:#46d369">${esc(n.bw)}</b>`:'<span style="color:#7f8aa3">se măsoară…</span>'}</div>
            <div><span>Fișier</span>${esc(dt.container||"")} · ${dt.size?(dt.size/1e9).toFixed(2)+" GB":"—"}</div>
            <div><span>Pornit</span>${n.started?ago(n.started):"—"}</div>
          </div>
        </div></div>`}).join(""):'<p style="color:#8a93a8">Nimeni nu se uită acum.</p>'}
     </div>
     <div class="panel"><h3 style="display:flex;justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap">Istoric vizionări
       <span style="display:flex;gap:8px"><select id="actusr" style="background:#1f2940;color:#fff;border:1px solid #445070;border-radius:4px;padding:6px 8px;font-size:13px"><option value="0">Toți utilizatorii</option>${d.users.map(u=>`<option value="${u.id}" ${u.id===actUser?"selected":""}>${esc(u.username)}</option>`).join("")}</select>
       <button class="bsm" id="actclr">Șterge istoricul</button></span></h3>
      ${d.history.length?`<div style="overflow-x:auto"><table class="acthist"><tr><th>Când</th><th>Utilizator</th><th>Titlu</th><th>Dispozitiv</th><th>IP</th><th>Redare</th><th>Vizionat</th><th>Progres</th></tr>
      ${d.history.map(h=>`<tr><td>${new Date(h.started*1000).toLocaleString("ro-RO",{day:"2-digit",month:"2-digit",hour:"2-digit",minute:"2-digit"})}</td><td>${esc(h.username)}</td><td>${esc(h.title)}</td>
        <td>${esc(h.device||"")}</td><td>${esc(h.ip||"")} ${h.remote?'<span class="pill bad">extern</span>':""}</td>
        <td>${esc(h.method==="direct"?"Directă":/^copy/.test(h.method||"")?"Remux":"Transcodare")}${h.quality&&h.quality!=="orig"?" · "+esc(h.quality):""}</td>
        <td>${dur(h.watched)}</td><td>${h.duration?Math.min(100,Math.round((h.last_pos||0)/h.duration*100)):0}%</td></tr>`).join("")}</table></div>`:'<p style="color:#8a93a8">Nicio vizionare înregistrată încă.</p>'}
     </div>`;
    $$("[data-stop]").forEach(b=>b.onclick=async()=>{if(!confirm(t("confirm_stop_stream")))return;
      await api("/api/admin/activity/stop",{method:"POST",body:JSON.parse(b.dataset.stop)});t("stream_stopped");draw()});
    $("#actusr").onchange=e=>{actUser=+e.target.value;draw()};
    $("#actclr").onclick=async()=>{if(!confirm(t("confirm_clear_history")))return;await api("/api/admin/activity/clear",{method:"POST"});draw()};
  };
  await draw();clearInterval(admT);admT=setInterval(draw,3000);
}
async function admLib(){
  const draw=async()=>{if(location.hash!=="#/admin"||admTab!=="lib"){clearInterval(admT);return}
    const s=await api("/api/admin/status");const c=s.counts;const sc=s.scan;
    $("#adm").innerHTML=`<div class="panel"><h3>Bibliotecă</h3><div class="stats">
      <div class="stat"><b>${c.movies}</b><span>Filme</span></div><div class="stat"><b>${c.series}</b><span>Seriale</span></div>
      <div class="stat"><b>${c.files}</b><span>Fișiere video</span></div><div class="stat"><b>${c.with_ro}</b><span>Cu subtitrare RO</span></div>
      <div class="stat"><b>${c.unmatched}</b><span>Fără metadate</span></div></div>
      <p style="margin:18px 0 12px;color:#bbb">Scanare: ${sc.running?`<span class="pill ok">${esc(sc.phase)} ${sc.done}/${sc.total}</span>`:`<span class="pill">${sc.last?"ultima: "+new Date(sc.last*1000).toLocaleString("ro-RO"):"niciodată"}</span>`} ${sc.error?`<span class="pill bad">${esc(sc.error)}</span>`:""}</p>
      <div class="btns" style="margin-top:0"><button class="bsm red" id="bscan">↻ Scanează acum</button><button class="bsm" id="bmeta">Reîncearcă metadatele lipsă</button><button class="bsm" id="bsubsall">Caută subtitrări RO pentru tot</button></div></div>
     <div class="panel"><h3>Server</h3><table>
      <tr><td>Transcodare</td><td><span class="pill ${s.hw.mode!=="none"?"ok":""}">${esc(s.hw.detail||s.hw.mode)}</span></td></tr>
      <tr><td>TMDB</td><td>${ME.has_tmdb?'<span class="pill ok">configurat</span>':'<span class="pill bad">lipsă cheie</span>'}</td></tr>
      <tr><td>OpenSubtitles</td><td>${s.subs.enabled?`<span class="pill ok">activ${s.subs.logged_in?" (autentificat)":""}</span> ${s.subs.remaining!=null?"· descărcări rămase: "+s.subs.remaining:""} · în coadă: ${s.subs.queue} ${s.subs.error?`<br><small style="color:#e87c03">${esc(s.subs.error)}</small>`:""}`:'<span class="pill bad">lipsă cheie API</span>'}</td></tr>
      <tr><td>Subs.ro</td><td>${s.subs.subsro_enabled?'<span class="pill ok">activ</span>':'<span class="pill" style="background:#333">inactiv (opțional)</span>'}</td></tr>
      <tr><td>Versiune</td><td>${esc(s.version)}</td></tr></table></div>
     <div class="panel"><h3>Redări active (${s.sessions.length})</h3>${s.sessions.length?`<table>${s.sessions.map(x=>`<tr><td>${esc(x.user)}${x.ip?` <small style="color:#777">${esc(x.ip)}</small>`:""}</td><td>${esc(x.title)}</td><td>${esc(x.method)}${x.quality&&x.quality!=="orig"?" · "+esc(x.quality)+"bps":""}${x.remote?' <span class="pill bad">extern</span>':""}${x.paused?" · în așteptare":""}</td></tr>`).join("")}</table>`:'<p style="color:#888">Nimeni nu se uită acum.</p>'}</div>`;
    $("#bscan").onclick=async()=>{await api("/api/admin/scan",{method:"POST"});t("scan_started");setTimeout(draw,600)};
    $("#bmeta").onclick=async()=>{await api("/api/admin/refresh-metadata",{method:"POST"});t("started");setTimeout(draw,600)};
    $("#bsubsall").onclick=async()=>{const r=await api("/api/admin/subs-all",{method:"POST"});toast(`${r.queue} fișiere în coada de subtitrări`)};
  };
  await draw();admT=setInterval(draw,3000);
}
async function admSet(){
  const s=await api("/api/admin/settings");
  $("#adm").innerHTML=`<div class="panel"><h3>Setări</h3><div class="fg">
    <label>Nume server</label><input id="f_server_name" value="${esc(s.server_name)}">
    <label>Foldere media</label><textarea id="f_media_dirs" placeholder="/media/filme&#10;/media/seriale">${esc(s.media_dirs)}</textarea><small>Câte un folder pe linie. Filmele și serialele pot sta împreună – sunt detectate automat după nume (S01E02, 1x02…).</small>
    <label>Cheie TMDB</label><input id="f_tmdb_key" value="${esc(s.tmdb_key)}" placeholder="API key (v3) sau Read Access Token (v4)"><small>Gratuit: <a href="https://www.themoviedb.org/settings/api" target="_blank">themoviedb.org/settings/api</a> – pentru postere, descrieri, actori, trailere.</small>
    <label>OpenSubtitles API key</label><input id="f_os_key" value="${esc(s.os_key)}"><small>Gratuit: <a href="https://www.opensubtitles.com/en/consumers" target="_blank">opensubtitles.com/consumers</a> – subtitrări RO automate.</small>
    <label>OpenSubtitles utilizator</label><input id="f_os_user" value="${esc(s.os_user)}" autocomplete="off"><small>Opțional, dar recomandat: mărește limita de descărcări/zi.</small>
    <label>OpenSubtitles parolă</label><input id="f_os_pass" type="password" value="${esc(s.os_pass)}" autocomplete="new-password">
    <label>Subs.ro API key</label><input id="f_subsro_key" value="${esc(s.subsro_key||'')}"><small>Gratuit: <a href="https://subs.ro/api" target="_blank">subs.ro/api</a> – subtitrări RO de pe cel mai mare site din România. Folosit ca alternativă când OpenSubtitles nu găsește nimic.</small>
    <label>Subtitrări RO automate</label><select id="f_auto_subs"><option value="1">Da – caută în fundal pentru fiecare fișier nou</option><option value="0">Nu – doar la cerere din player</option></select>
    <label>Accelerare hardware</label><select id="f_hwaccel"><option value="auto">Auto-detectare</option><option value="vaapi">VAAPI (Intel / AMD, doar Linux)</option><option value="qsv">Intel QuickSync (QSV)</option><option value="nvenc">NVIDIA NVENC</option><option value="amf">AMD AMF (Windows)</option><option value="none">Fără (doar CPU)</option></select>
    <label>Dispozitiv VAAPI</label><input id="f_vaapi_device" value="${esc(s.vaapi_device)}">
    <label>Tone-mapping HDR → SDR</label><select id="f_tonemap"><option value="1">Activat – filmele HDR/4K arată corect pe ecrane normale</option><option value="0">Dezactivat</option></select><small>Se aplică doar când filmul e transcodat. Pe Intel/AMD se face pe GPU (tonemap_vaapi); altfel pe CPU.</small>
    <label>Algoritm tone-mapping (CPU)</label><select id="f_tonemap_alg"><option value="hable">Hable – cinematic (recomandat)</option><option value="mobius">Mobius – păstrează culorile</option><option value="reinhard">Reinhard – mai luminos</option><option value="clip">Clip – simplu</option></select>
    <label>Rescanare automată (minute)</label><input id="f_scan_interval" type="number" min="1" value="${esc(s.scan_interval)}">
   </div></div>
   <div class="panel"><h3>🌐 Rețea</h3>
    <div class="netinfo" id="netinfo">…</div>
    <h4 class="sub">Rețea locală (LAN)</h4><div class="fg">
    <label>Rețele considerate locale</label><textarea id="f_lan_networks" style="min-height:60px">${esc(s.lan_networks)}</textarea><small>Subrețele CIDR separate prin virgulă. Tot ce nu e aici = <b>extern</b>.</small>
    <label>Detectează automat rețeaua serverului</label><select id="f_lan_auto"><option value="1">Da – inclusiv IPv6 de la provider (recomandat)</option><option value="0">Nu – doar lista de mai sus</option></select><small id="srvnets"></small>
    <label>Rezoluție maximă (LAN)</label><select id="f_max_height"><option value="2160">4K (2160p)</option><option value="1080">1080p</option><option value="720">720p</option><option value="480">480p</option></select>
    <label>Bitrate transcodare (LAN)</label><select id="f_bitrate">${["4M","6M","8M","12M","20M"].map(b=>`<option value="${b}">${b.replace("M"," Mbps")}</option>`).join("")}</select><small>În LAN fișierele compatibile se redau direct, la calitate originală.</small>
    </div>
    <h4 class="sub">Streaming extern (internet)</h4><div class="fg">
    <label>Acces din afara casei</label><select id="f_remote_enabled"><option value="1">Permis</option><option value="0">Blocat</option></select>
    <label>Descărcări</label><select id="f_download_mode"><option value="all">Permise – LAN la viteză maximă, extern limitat la bitrate</option><option value="lan">Doar în rețeaua locală</option><option value="off">Dezactivate</option></select>
    <label>Bitrate maxim extern</label><div class="steps" id="rsteps"></div><small>Limită maximă 4 Mbps. Utilizatorii aleg din player orice treaptă până la limita lor (setarea globală sau cea din contul lor, care e mai mică).</small>
    </div>
    <h4 class="sub">Google Cast</h4>
    <div class="netinfo" id="castinfo">…</div>
    <div class="fg" style="margin-top:12px">
    <label>IP-uri Chromecast (opțional)</label><input id="f_cast_hosts" value="${esc(s.cast_hosts)}" placeholder="ex: 192.168.1.50, 192.168.1.51"><small>Doar dacă un Chromecast nu apare automat (mDNS blocat de router / firewall). Îi dai IP fix din router și îl scrii aici.</small>
    </div>
   </div>
   <div class="panel"><h3>🛡️ Securitate</h3>
    <h4 class="sub">Sesiuni</h4><div class="fg">
    <label>Durata unei sesiuni</label><select id="f_session_hours"><option value="0">Nu expiră (recomandat acasă)</option><option value="4">4 ore</option><option value="12">12 ore</option><option value="24">1 zi</option><option value="168">7 zile</option><option value="720">30 de zile</option><option value="2160">90 de zile</option></select><small>Timpul se măsoară de la <b>ultima activitate</b>, nu de la autentificare – cât timp folosești aplicația nu ești deconectat. „Nu expiră" te ține conectat până ceri tu deconectarea.</small>
    </div>
    <h4 class="sub">Protecție la ghicirea parolei</h4><div class="fg">
    <label>Încercări greșite permise</label><select id="f_bf_attempts">${[3,5,10].map(n=>`<option value="${n}">${n}</option>`).join("")}</select>
    <label>În intervalul de</label><select id="f_bf_window">${[[5,"5 minute"],[10,"10 minute"],[30,"30 minute"],[60,"1 oră"]].map(([v,l])=>`<option value="${v}">${l}</option>`).join("")}</select>
    <label>Blochează IP-ul pentru</label><select id="f_bf_block">${[[5,"5 minute"],[15,"15 minute"],[60,"1 oră"],[1440,"24 ore"]].map(([v,l])=>`<option value="${v}">${l}</option>`).join("")}</select>
    <label>Rețeaua locală</label><select id="f_bf_lan_exempt"><option value="1">Excepție – nu bloca IP-urile din LAN</option><option value="0">Aplică și în LAN</option></select>
    </div>
    <div id="secbox" style="margin-top:16px"></div>
   </div>
   <div class="btns" style="margin-bottom:30px"><button class="bsm red" id="fsave" style="padding:12px 28px">Salvează setările</button></div>`;
  ["auto_subs","hwaccel","max_height","bitrate","remote_enabled","download_mode","lan_auto","tonemap","tonemap_alg","session_hours","bf_attempts","bf_window","bf_block","bf_lan_exempt"].forEach(k=>$("#f_"+k).value=s[k]);
  const drawSec=async()=>{const d=await api("/api/admin/security");
    $("#secbox").innerHTML=`<h4 class="sub" style="margin-top:0">IP-uri blocate (${d.blocked.length})</h4>
     ${d.blocked.length?`<table>${d.blocked.map(b=>`<tr><td>${esc(b.ip)}</td><td>până la ${new Date(b.until*1000).toLocaleString("ro-RO")}</td><td style="text-align:right"><button class="bsm" data-unb="${esc(b.ip)}">Deblochează</button></td></tr>`).join("")}</table><div class="btns"><button class="bsm" data-unb="*">Deblochează tot</button></div>`:'<p style="color:#888;font-size:14px">Niciun IP blocat.</p>'}
     <details style="margin-top:14px"><summary style="cursor:pointer;color:#aaa">Ultimele autentificări (${d.log.length})</summary><table style="margin-top:8px">
     ${d.log.map(l=>`<tr><td>${new Date(l.t*1000).toLocaleString("ro-RO")}</td><td>${esc(l.ip)} ${l.remote?'<span class="pill bad">extern</span>':'<span class="pill">LAN</span>'}</td><td>${esc(l.user)}</td><td>${l.ok?'<span class="pill ok">reușit</span>':'<span class="pill bad">greșit</span>'}</td></tr>`).join("")||"<tr><td>—</td></tr>"}</table></details>`;
    $$("#secbox [data-unb]").forEach(b=>b.onclick=async()=>{await api("/api/admin/security/unblock",{method:"POST",body:{ip:b.dataset.unb}});t("unblocked");drawSec()})};
  drawSec();
  let rmax=s.remote_max;
  const net=await api("/api/admin/network");
  const drawSteps=()=>{$("#rsteps").innerHTML=[...net.qualities].reverse().map(q=>`<button type="button" class="${q.key===rmax?"on":""}" data-q="${q.key}">${esc(q.label)}</button>`).join("");
    $$("#rsteps [data-q]").forEach(b=>b.onclick=()=>{rmax=b.dataset.q;drawSteps()})};
  drawSteps();
  $("#srvnets").textContent=net.server_nets.length?"Rețelele serverului: "+net.server_nets.join(", "):"";
  const drawCast=n=>{const c=n.cast;$("#castinfo").innerHTML=(!c.ok?`<span class="pill bad">indisponibil</span> ${esc(c.err||"")}`
      :c.devices.length?`<span class="pill ok">${c.devices.length} ${c.devices.length===1?"dispozitiv găsit":"dispozitive găsite"}</span> `+c.devices.map(d=>`<b>${esc(d.name)}</b> <small style="color:#8a93a8">${esc(d.model)} · ${esc(d.host)}</small>`).join(" · ")
      :`<span class="pill bad">niciun Chromecast găsit</span> <small style="color:#8a93a8">Verifică să fie pornit și în aceeași rețea cu serverul, sau scrie-i IP-ul mai jos.</small>`)
      +` <button class="bsm" id="castrescan" style="margin-left:8px">↻ Caută din nou</button>`
      +(n.remote?`<div style="color:#e87c03;margin-top:8px;font-size:13px">Tu apari ca <b>extern</b> (${esc(n.ip)}) – de aceea nu vezi iconița de Cast. Adaugă rețeaua ta în lista LAN de mai sus.</div>`:"");
    $("#castrescan").onclick=async()=>{await api("/api/admin/cast/rescan",{method:"POST"});$("#castinfo").innerHTML="Caut dispozitive…";
      setTimeout(async()=>{drawCast(await api("/api/admin/network"));castRefresh()},6000)}};
  drawCast(net);
  $("#netinfo").innerHTML=`Te conectezi din <b>${esc(net.ip)}</b> – ${net.remote?'<span class="pill bad">extern</span> (streaming limitat la treapta aleasă, max 4 Mbps)':'<span class="pill ok">rețea locală</span>'}`;
  $("#fsave").onclick=async()=>{const o={remote_max:rmax};Object.keys(s).forEach(k=>{const el=$("#f_"+k);if(el)o[k]=el.value});
    try{await api("/api/admin/settings",{method:"POST",body:o});ME=await api("/api/me");t("settings_saved");document.title=ME.server_name+" by NetStreaming";$("#brand").textContent=ME.server_name}catch(e){alert(e.message)}};
}
async function admUsr(){
  const d=await api("/api/admin/users");
  const qopt=(sel)=>`<option value="">Limita globală</option>`+d.qualities.map(q=>`<option value="${q.key}" ${q.key===sel?"selected":""}>${esc(q.label)}</option>`).join("");
  const sopt=(n)=>[[0,"Nelimitat"],[1,"1 ecran"],[2,"2 ecrane"],[3,"3 ecrane"],[4,"4 ecrane"],[5,"5 ecrane"]].map(([v,l])=>`<option value="${v}" ${v===n?"selected":""}>${l}</option>`).join("");
  const ago=t=>{if(!t)return"";const m=Math.round((Date.now()/1000-t)/60);return m<1?"acum":m<60?`acum ${m} min`:`acum ${Math.round(m/60)} h`};
  const dev=ua=>{ua=ua||"";return /Android/.test(ua)?"Android":/iPhone|iPad/.test(ua)?"iOS":/Smart-?TV|Tizen|webOS/i.test(ua)?"TV":/Windows/.test(ua)?"Windows":/Mac OS/.test(ua)?"Mac":/Linux/.test(ua)?"Linux":"Browser"};
  $("#adm").innerHTML=`<div class="panel"><h3>Utilizatori și permisiuni</h3>
    ${d.users.map(u=>`<div class="ucard" data-uid="${u.id}">
      <div class="uhead"><div class="avatar" style="width:40px;height:40px;font-size:18px">${esc(u.username[0])}</div>
        <div><b>${esc(u.username)}</b> ${u.admin?'<span class="pill ok">administrator unic</span>':'<span class="pill">utilizator</span>'} ${u.playing?`<span class="pill ok">▶ se uită (${u.playing})</span>`:""}
        ${u.has_2fa?'<span class="pill ok">🔐 cod în doi paşi</span>':""}${!u.active?'<span class="pill bad">dezactivat</span>':""}${u.email&&!u.email_ok?'<span class="pill">e-mail neconfirmat</span>':""}
        <div style="color:#888;font-size:12px">${u.email?esc(u.email):'<span style="color:#e87c03">fără e-mail – nu îşi poate recupera parola</span>'} · ${u.devices.length} ${u.devices.length===1?"dispozitiv conectat":"dispozitive conectate"}</div></div></div>
      <div class="ugrid">
        <label>Acces extern<select data-f="remote_ok"><option value="1" ${u.remote_ok?"selected":""}>Permis</option><option value="0" ${!u.remote_ok?"selected":""}>Doar LAN</option></select></label>
        <label>Bitrate max extern<select data-f="max_q">${qopt(u.max_q)}</select></label>
        <label>Ecrane simultane<select data-f="max_streams">${sopt(u.max_streams)}</select></label>
        <label>Descărcare<select data-f="can_download"><option value="1" ${u.can_download?"selected":""}>Permisă</option><option value="0" ${!u.can_download?"selected":""}>Interzisă</option></select></label>
        <label>TV Live<select data-f="live_ok"><option value="1" ${u.live_ok?"selected":""}>Permis</option><option value="0" ${!u.live_ok?"selected":""}>Interzis</option></select></label>
        ${!u.admin?`<label>Cont<select data-f="active"><option value="1" ${u.active?"selected":""}>Activ</option><option value="0" ${!u.active?"selected":""}>Dezactivat</option></select></label>`:""}
        <label style="grid-column:span 2">E-mail<input data-f="email" value="${esc(u.email||"")}" placeholder="pentru recuperarea parolei" style="background:#111827;border:1px solid #36415c;border-radius:4px;color:#fff;padding:8px"></label>
      </div>
      ${(d.libraries.length&&!u.admin)?`<div class="libs"><b>Biblioteci vizibile</b><div class="chk">${d.libraries.map(l=>`
        <label title="${esc(l.path)}"><input type="checkbox" data-lib="${esc(l.path)}" ${u.libs.includes(l.path)?"checked":""}>${esc(l.name)}</label>`).join("")}</div>
        <small>Nebifat = utilizatorul nu vede acele filme nicăieri: nici pe pagina principală, nici la căutare, nici direct prin link. Toate bifate = vede tot, inclusiv bibliotecile adăugate mai târziu.</small></div>`:""}
      ${u.devices.length?`<details><summary style="cursor:pointer;color:#aaa;font-size:13px;margin:6px 0">Dispozitive</summary><table>${u.devices.map(dv=>`<tr><td>${dev(dv.ua)}</td><td>${esc(dv.ip||"")}</td><td>conectat ${new Date(dv.created*1000).toLocaleTimeString("ro-RO",{hour:"2-digit",minute:"2-digit"})}</td><td>activ ${ago(dv.last_seen)}</td></tr>`).join("")}</table></details>`:""}
      <div class="btns" style="margin-top:10px"><button class="bsm red" data-save>Salvează</button><button class="bsm" data-lo ${!u.devices.length?"disabled":""}>Deconectează de pe toate dispozitivele</button><button class="bsm" data-pw>Resetează parola</button>${!u.admin?`<button class="bsm" data-del>Șterge</button>`:""}</div>
    </div>`).join("")}</div>
   <div class="panel"><h3>Adaugă utilizator</h3><p style="color:#888;font-size:13px;margin:-6px 0 14px">Conturile noi sunt utilizatori obișnuiți: văd și redau filmele, dar nu au acces la administrarea serverului. Există un singur administrator.</p><div class="fg"><label>Nume</label><input id="nu"><label>Parolă</label><input id="np" type="password">
    <label>Acces extern</label><select id="nr"><option value="1">Permis</option><option value="0">Doar LAN</option></select>
    <label>Bitrate max extern</label><select id="nq">${qopt("")}</select>
    <label>Ecrane simultane</label><select id="ns">${sopt(2)}</select>
    <label>Descărcare</label><select id="nd"><option value="1">Permisă</option><option value="0">Interzisă</option></select>
    <label>TV Live</label><select id="nl"><option value="1">Permis</option><option value="0">Interzis</option></select></div>
   ${d.libraries.length?`<div class="libs" id="nlibs"><b>Biblioteci vizibile</b><div class="chk">${d.libraries.map(l=>`
     <label title="${esc(l.path)}"><input type="checkbox" data-lib="${esc(l.path)}" checked>${esc(l.name)}</label>`).join("")}</div></div>`:""}
   <div class="btns"><button class="bsm red" id="nadd" style="padding:12px 28px">Adaugă</button></div></div>`;
  $("#nadd").onclick=async()=>{try{const nl=$("#nlibs");await api("/api/admin/users",{method:"POST",body:{username:$("#nu").value,password:$("#np").value,remote_ok:$("#nr").value==="1",max_q:$("#nq").value,max_streams:+$("#ns").value,can_download:$("#nd").value==="1",live_ok:$("#nl").value==="1",libs:nl?[...nl.querySelectorAll("[data-lib]")].filter(b=>b.checked).map(b=>b.dataset.lib):[]}});t("user_added");admUsr()}catch(e){alert(e.message)}};
  $$(".ucard").forEach(c=>{const uid=c.dataset.uid;const f=k=>c.querySelector(`[data-f=${k}]`).value;
    const libsOf=el=>[...el.querySelectorAll("[data-lib]")].filter(b=>b.checked).map(b=>b.dataset.lib);
    c.querySelector("[data-save]").onclick=async()=>{try{await api("/api/admin/users/"+uid,{method:"POST",body:Object.assign({remote_ok:f("remote_ok")==="1",max_q:f("max_q"),max_streams:+f("max_streams"),can_download:f("can_download")==="1",live_ok:f("live_ok")==="1",libs:libsOf(c),email:f("email")},c.querySelector('[data-f="active"]')?{active:f("active")==="1"}:{})});t("perms_saved")}catch(e){alert(e.message)}};
    c.querySelector("[data-lo]").onclick=async()=>{if(!confirm(t("confirm_logout_user")))return;const r=await api(`/api/admin/users/${uid}/logout`,{method:"POST"});toast(`${r.closed} sesiuni închise`);if(+uid===ME.id)return sessionExpired();admUsr()};
    c.querySelector("[data-pw]").onclick=async()=>{const p=prompt(t("new_pw_user_prompt"));if(!p)return;await api("/api/admin/users/"+uid,{method:"POST",body:{password:p}});t("pw_changed_short");if(+uid===ME.id)return sessionExpired();admUsr()};
    const del=c.querySelector("[data-del]");if(del)del.onclick=async()=>{if(!confirm(t("confirm_del_user")))return;await api("/api/admin/users/"+uid,{method:"DELETE"});admUsr()};
  });
}

/* ================= ADMIN – MONITORIZARE SISTEM ================= */
/* Culorile de stare sunt fixe şi vin mereu însoţite de text, niciodată doar culoare.
   Cele două serii din graficul de reţea au trecut validatorul de paletă pe fundalul închis. */
const SYSC={good:"#0ca30c",warn:"#fab219",crit:"#d03b3b",ink:"#e4e8f0",mut:"#7f8aa3",
            rx:"#3987e5",tx:"#d95926",cpu:"#3987e5",ram:"#199e70",grid:"#232d45"};
let SYSH={cpu:[],ram:[],rx:[],tx:[]}, sysT=null;
const SYSN=60;                       // câte măsurători ţinem (≈3 minute la 3 secunde)

function sysColor(p){return p>=90?SYSC.crit:p>=75?SYSC.warn:SYSC.good}
function sysState(p){return p>=90?"critic":p>=75?"ridicat":"normal"}
function fmtB(n){n=n||0;const u=["B","KB","MB","GB","TB"];let i=0;while(n>=1024&&i<4){n/=1024;i++}return (i?n.toFixed(n<10?1:0):n.toFixed(0))+" "+u[i]}
function fmtbps(n){n=n||0;return n>=1e6?(n/1e6).toFixed(n<1e7?1:0)+" Mbps":n>=1e3?(n/1e3).toFixed(0)+" kbps":n+" bps"}
function fmtUp(sec){const d=Math.floor(sec/86400),h=Math.floor(sec%86400/3600),m=Math.floor(sec%3600/60);
  return d?`${d} z ${h} h`:h?`${h} h ${m} min`:`${m} min`}

/* sparkline: o singură serie, deci fără legendă – titlul plăcii o numeşte */
function spark(vals,color,max,fill){
  const W=300,H=42;
  if(vals.length<2)return `<svg class="spark" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none"></svg>`;
  const n=vals.length;                       // până se umple fereastra, graficul creşte cu datele
  const mx=max||Math.max(1,...vals);
  const X=i=>(i/(n-1))*W, Y=v=>H-2-(Math.min(v,mx)/mx)*(H-4);
  const d=vals.map((v,i)=>(i?"L":"M")+X(i).toFixed(1)+" "+Y(v).toFixed(1)).join(" ");
  const area=fill?`<path d="${d} L ${W} ${H} L 0 ${H} Z" fill="${color}" opacity=".13"/>`:"";
  return `<svg class="spark" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none">${area}
    <path d="${d}" fill="none" stroke="${color}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke"/></svg>`;
}
/* două serii: legendă prezentă + etichete directe pe valoarea curentă */
function spark2(a,b,ca,cb){
  const W=300,H=64,n=Math.max(a.length,b.length);
  if(n<2)return `<svg class="spark" style="height:64px" viewBox="0 0 ${W} ${H}"></svg>`;
  const mx=Math.max(1,...a,...b);
  const line=(vals,c)=>{
    if(vals.length<2)return "";
    const d=vals.map((v,i)=>{const x=(i/(n-1))*W,y=H-3-(v/mx)*(H-6);return (i?"L":"M")+x.toFixed(1)+" "+y.toFixed(1)}).join(" ");
    return `<path d="${d}" fill="none" stroke="${c}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke"/>`;
  };
  return `<svg class="spark" style="height:64px" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none">
    <line x1="0" y1="${H-3}" x2="${W}" y2="${H-3}" stroke="${SYSC.grid}" stroke-width="1" vector-effect="non-scaling-stroke"/>
    ${line(a,ca)}${line(b,cb)}</svg>`;
}

async function admSys(){
  const draw=async()=>{
    if(location.hash!=="#/admin"||admTab!=="sys"){clearInterval(sysT);sysT=null;return}
    let d;
    try{d=await api("/api/admin/system")}
    catch(e){clearInterval(sysT);sysT=null;
      $("#adm").innerHTML=`<div class="panel"><h3>Monitorizare</h3><div class="sysnote">${esc(e.message)}</div></div>`;return}
    if(!d.ok){$("#adm").innerHTML=`<div class="panel"><h3>Monitorizare</h3><div class="sysnote">${esc(d.error||"Indisponibil")}</div></div>`;return}

    const push=(k,v)=>{SYSH[k].push(v);if(SYSH[k].length>SYSN)SYSH[k].shift()};
    push("cpu",d.cpu.pct||0); push("ram",d.mem.pct||0);
    const n0=d.net[0]||{rx_bps:0,tx_bps:0};
    const rx=d.net.reduce((s,n)=>s+n.rx_bps,0), tx=d.net.reduce((s,n)=>s+n.tx_bps,0);
    push("rx",rx); push("tx",tx);

    const h=d.host,c=d.cpu,m=d.mem,a=d.app;
    const st=(p)=>`<span class="st" style="color:${sysColor(p)}"><b style="background:${sysColor(p)}"></b>${sysState(p)}</span>`;

    $("#adm").innerHTML=`
    <div class="sysnote" style="margin-bottom:16px">
      <b>${esc(h.name)}</b> · ${esc(h.os)} · nucleu ${esc(h.kernel)} · pornit de ${fmtUp(h.uptime)}
      ${h.cpu_model?`<br>${esc(h.cpu_model)} · ${h.cores} nuclee`:""} · Python ${esc(h.py)} · CineVerse ${esc(a.version)}
      <br><span style="color:#7f8aa3">Se reîmprospătează la 3 secunde.</span>
      <label style="display:inline-flex;align-items:center;gap:8px;margin-top:10px;cursor:pointer;font-size:13px">
        <input type="checkbox" id="sysrem" ${d.remote_ok?"checked":""} style="accent-color:#e50914;width:15px;height:15px">
        Accesibilă şi din afara reţelei locale${d.remote?' <span class="pill ok">te uiţi din afară acum</span>':""}
      </label>
      <div style="color:#7f8aa3;font-size:12px;margin-top:6px">Oricum o vede doar contul de administrator. Debifat, rămâne vizibilă doar de acasă.</div>
    </div>

    <div class="sysgrid">
      <div class="tile">
        <div class="lab">Procesor</div>
        <div class="big">${(c.pct??0).toFixed(0)}<small>%</small></div>
        <div class="sub">${st(c.pct||0)} · încărcare ${c.load.map(x=>x.toFixed(2)).join(" / ")}${c.temp!=null?` · ${c.temp}°C`:""}</div>
        ${spark(SYSH.cpu,SYSC.cpu,100,true)}
        ${(c.per_core||[]).length?`<div class="lab" style="margin-top:12px;margin-bottom:0">Pe nuclee</div>
        <div class="cores">${c.per_core.map((v,i)=>`<u title="Nucleul ${i+1}: ${v.toFixed(0)}%"><i style="height:${Math.max(3,v)}%;background:${sysColor(v)}"></i></u>`).join("")}</div>`:""}
      </div>

      <div class="tile">
        <div class="lab">Memorie</div>
        <div class="big">${(m.pct??0).toFixed(0)}<small>%</small></div>
        <div class="sub">${fmtB(m.used)} folosiţi din ${fmtB(m.total)} · ${st(m.pct||0)}${m.swap_total?` · swap ${m.swap_pct}%`:""}</div>
        ${spark(SYSH.ram,SYSC.ram,100,true)}
      </div>

      <div class="tile">
        <div class="lab">Reţea</div>
        <div class="big">${fmtbps(rx)}</div>
        <div class="sub">primit acum · trimis ${fmtbps(tx)}</div>
        ${spark2(SYSH.rx,SYSH.tx,SYSC.rx,SYSC.tx)}
        <div class="legend"><span><i style="background:${SYSC.rx}"></i>primit ${fmtbps(rx)}</span><span><i style="background:${SYSC.tx}"></i>trimis ${fmtbps(tx)}</span></div>
      </div>

      <div class="tile">
        <div class="lab">CineVerse</div>
        <div class="big">${a.streams+a.cast}<small>${a.streams+a.cast===1?"redare":"redări"}</small></div>
        <div class="sub">${a.transcodes} transcodări · ${a.live_sessions} canale live pornite · ${a.ffmpeg} procese ffmpeg
        <br>${a.remote} din afara casei · ${fmtbps(a.bps)} livraţi acum</div>
        <div class="sub" style="margin-top:8px">${a.items} titluri · ${a.media} fişiere · ${a.channels} canale · ${a.users} conturi</div>
      </div>
    </div>

    <div class="panel"><h3>Discuri</h3>
      <div class="syswrap"><table class="systab">
        <tr><th>Montat în</th><th>Sistem</th><th class="num">Folosit</th><th class="num">Total</th><th class="num">Liber</th><th style="width:34%">Ocupare</th></tr>
        ${d.disks.map(x=>`<tr><td><b>${esc(x.mount)}</b><div style="color:#7f8aa3;font-size:11px">${esc(x.dev)}</div></td><td>${esc(x.fs)}</td>
          <td class="num">${fmtB(x.used)}</td><td class="num">${fmtB(x.total)}</td><td class="num">${fmtB(x.free)}</td>
          <td><div class="bar2"><i style="width:${x.pct}%;background:${sysColor(x.pct)}"></i></div>
              <div style="font-size:11px;color:#8a93a8;margin-top:4px">${x.pct}% · ${sysState(x.pct)}</div></td></tr>`).join("")}
      </table></div>
      <div class="sub" style="color:#8a93a8;font-size:12px;margin-top:12px">Activitate disc: citire ${fmtB(d.diskio.read_bps)}/s · scriere ${fmtB(d.diskio.write_bps)}/s</div>
    </div>

    <div class="sysgrid">
      <div class="tile"><div class="lab">Accelerare video</div>
        <div class="big" style="font-size:22px">${d.gpu.hw==="none"?"Procesor (software)":esc(d.gpu.hw.toUpperCase())}</div>
        <div class="sub">${esc(d.gpu.detail||"")}${d.gpu.present?`<br>Placă ${esc(d.gpu.name||"detectată")}${d.gpu.freq?` · ${d.gpu.freq} MHz`:""}`:"<br>Nicio placă video detectată"}</div>
      </div>
      <div class="tile"><div class="lab">Servicii</div>
        <div style="margin-top:8px">${d.services.length?d.services.map(x=>{
          const okk=x.state==="active";
          return `<div style="margin-bottom:8px"><span class="st" style="color:${okk?SYSC.good:SYSC.crit}"><b style="background:${okk?SYSC.good:SYSC.crit}"></b>${esc(x.name)} — ${esc(x.state)}</span></div>`}).join("")
          :'<div style="color:#8a93a8;font-size:13px">systemd indisponibil aici</div>'}</div>
      </div>
      <div class="tile"><div class="lab">Temperaturi</div>
        <div style="margin-top:8px">${d.temps.length?d.temps.slice(0,6).map(t=>{
          const cc=t.c>=85?SYSC.crit:t.c>=70?SYSC.warn:SYSC.good;
          return `<div style="display:flex;justify-content:space-between;font-size:13px;margin-bottom:6px;gap:10px">
            <span style="color:#aab3c5;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(t.label)}</span>
            <b style="color:${cc};font-variant-numeric:tabular-nums">${t.c}°C</b></div>`}).join("")
          :'<div style="color:#8a93a8;font-size:13px">Niciun senzor de temperatură</div>'}</div>
      </div>
    </div>

    <div class="panel"><h3>Procese care consumă cel mai mult</h3>
      <div class="syswrap"><table class="systab">
        <tr><th class="num">PID</th><th>Proces</th><th class="num">Procesor</th><th class="num">Memorie</th><th>Comandă</th></tr>
        ${d.procs.map(x=>`<tr><td class="num" style="color:#7f8aa3">${x.pid}</td><td><b>${esc(x.name)}</b></td>
          <td class="num" style="color:${x.cpu>=50?SYSC.warn:SYSC.ink}">${x.cpu}%</td><td class="num">${fmtB(x.mem)}</td>
          <td style="color:#8a93a8;max-width:420px;overflow:hidden;text-overflow:ellipsis">${esc(x.cmd)}</td></tr>`).join("")}
      </table></div>
    </div>

    <div class="panel"><h3>Interfeţe de reţea</h3>
      <div class="syswrap"><table class="systab">
        <tr><th>Interfaţă</th><th class="num">Primit acum</th><th class="num">Trimis acum</th><th class="num">Total primit</th><th class="num">Total trimis</th></tr>
        ${d.net.map(x=>`<tr><td><b>${esc(x.name)}</b></td><td class="num" style="color:${SYSC.rx}">${fmtbps(x.rx_bps)}</td>
          <td class="num" style="color:${SYSC.tx}">${fmtbps(x.tx_bps)}</td><td class="num">${fmtB(x.rx)}</td><td class="num">${fmtB(x.tx)}</td></tr>`).join("")}
      </table></div>
    </div>
    <div class="panel"><h3>Acțiuni servicii</h3>
      <div style="display:flex;gap:12px;flex-wrap:wrap;align-items:center">
        <button class="bsm red" id="btnqbtrestart">↻ Restart qBittorrent</button>
        <span id="qbtmsg" style="font-size:13px;color:#8a93a8"></span>
      </div>
    </div>`;
    $("#sysrem").onchange=async e=>{
      try{await api("/api/admin/system/access",{method:"POST",body:{remote:e.target.checked}});
        toast(e.target.checked?"Monitorizarea e accesibilă şi din afară":"Monitorizarea rămâne doar în reţeaua locală")}
      catch(err){alert(err.message);e.target.checked=!e.target.checked}};
    $("#btnqbtrestart").onclick=async()=>{
      const btn=$("#btnqbtrestart"),msg=$("#qbtmsg");
      btn.disabled=true;msg.textContent="Se repornește…";msg.style.color="#e5c414";
      try{await api("/api/admin/service/restart",{method:"POST",body:{service:"qbittorrent-nox"}});
        msg.textContent="qBittorrent repornit cu succes.";msg.style.color="#4caf82"}
      catch(e){msg.textContent="Eroare: "+e.message;msg.style.color="#e50914"}
      setTimeout(()=>{btn.disabled=false;msg.textContent=""},4000)};
  };
  SYSH={cpu:[],ram:[],rx:[],tx:[]};
  await draw();
  clearInterval(sysT);
  sysT=setInterval(draw,3000);
}

/* ================= ADMIN – CONTURI ŞI E-MAIL ================= */
async function admAcc(){
  const draw=async()=>{
    if(location.hash!=="#/admin"||admTab!=="acc")return;
    let s,pend,libs;
    try{s=await api("/api/admin/settings");pend=await api("/api/admin/pending");libs=(await api("/api/admin/users")).libraries||[]}
    catch(e){$("#adm").innerHTML=`<div class="panel">${esc(e.message)}</div>`;return}
    const qs=["","4M","3M","2M","1.5M","1M","750k","500k"];
    const sel=(id,val,opts)=>`<select id="${id}">${opts.map(([v,l])=>`<option value="${v}" ${String(v)===String(val)?"selected":""}>${l}</option>`).join("")}</select>`;
    $("#adm").innerHTML=`
     <div class="panel"><h3>Cine îşi poate face cont</h3>
      <div class="fg">
        <label>Înregistrare</label>${sel("a_mode",s.signup_mode,[["off","Oprită – doar eu creez conturi"],["open","Deschisă – oricine îşi face cont"],["invite","Cu cod de invitaţie"],["approve","Deschisă, dar o aprob eu"]])}
        <label>Cod de invitaţie</label><input id="a_invite" value="${esc(s.signup_invite)}" placeholder="ex: FAMILIE2026">
        <label>Confirmare e-mail</label>${sel("a_verify",s.signup_verify,[["1","Da – trebuie să confirme adresa"],["0","Nu"]])}
        <small>Fără confirmare, oricine poate scrie o adresă inventată şi nu-şi mai poate recupera parola.</small>
        <label>Doar aceste domenii</label><input id="a_domains" value="${esc(s.signup_domains)}" placeholder="gmail.com yahoo.com (gol = oricare)">
      </div>
      <h4 class="sub">Ce poate face un cont nou</h4>
      <div class="fg">
        <label>Acces din afara casei</label>${sel("a_remote",s.signup_remote,[["1","Permis"],["0","Doar în reţeaua locală"]])}
        <label>Bitrate maxim extern</label>${sel("a_maxq",s.signup_max_q,qs.map(v=>[v,v?v.replace("M"," Mbps").replace("k"," kbps"):"Limita globală"]))}
        <label>TV Live</label>${sel("a_live",s.signup_live,[["1","Permis"],["0","Interzis"]])}
        <label>Descărcări</label>${sel("a_dl",s.signup_download,[["0","Interzise"],["1","Permise"]])}
      </div>
      ${libs.length?`<div class="libs" style="margin-top:16px"><b>Biblioteci vizibile pentru conturile noi</b><div class="chk">${libs.map(l=>`
        <label title="${esc(l.path)}"><input type="checkbox" data-alib="${esc(l.path)}" ${(!s.signup_libs||s.signup_libs.split("\n").indexOf(l.path)>=0)?"checked":""}>${esc(l.name)}</label>`).join("")}</div>
        <small>Poţi schimba oricând drepturile fiecărui cont din tabul Utilizatori.</small></div>`:""}
      <div class="btns" style="margin-top:16px"><button class="bsm red" id="a_save" style="padding:12px 26px">Salvează</button></div>
     </div>

     ${pend.users.length?`<div class="panel"><h3>Aşteaptă aprobarea ta (${pend.users.length})</h3>
      <div style="overflow-x:auto"><table><tr><th>Cont</th><th>E-mail</th><th>Când</th><th>De la</th><th></th></tr>
        ${pend.users.map(u=>`<tr><td><b>${esc(u.username)}</b></td><td>${esc(u.email||"—")} ${u.email_ok?'<span class="pill ok">confirmat</span>':'<span class="pill">neconfirmat</span>'}</td>
          <td>${new Date(u.created*1000).toLocaleString("ro-RO",{day:"2-digit",month:"short",hour:"2-digit",minute:"2-digit"})}</td><td>${esc(u.signup_ip||"")}</td>
          <td style="white-space:nowrap;text-align:right"><button class="bsm red" data-app="${u.id}">Aprobă</button> <button class="bsm" data-rej="${u.id}">Respinge</button></td></tr>`).join("")}</table></div>
     </div>`:""}

     <div class="panel"><h3>Trimitere e-mail</h3>
      <p style="color:#8a93a8;font-size:13px;margin:-8px 0 16px">Necesară pentru confirmarea adresei şi pentru recuperarea parolei. Merge cu orice furnizor: Gmail (cu parolă de aplicaţie), Zoho, Mailgun, sau serverul tău.</p>
      <div class="fg">
        <label>Server SMTP</label><input id="m_host" value="${esc(s.smtp_host)}" placeholder="smtp.gmail.com">
        <label>Port</label><input id="m_port" value="${esc(s.smtp_port)}" style="max-width:140px">
        <label>Criptare</label>${sel("m_tls",s.smtp_tls,[["starttls","STARTTLS (port 587)"],["ssl","SSL/TLS (port 465)"],["none","Fără (doar în reţea locală)"]])}
        <label>Utilizator</label><input id="m_user" value="${esc(s.smtp_user)}" placeholder="contul@gmail.com">
        <label>Parolă</label><input id="m_pass" type="password" value="${esc(s.smtp_pass)}" placeholder="parolă de aplicaţie">
        <label>Expeditor</label><input id="m_from" value="${esc(s.smtp_from)}" placeholder="cineverse@domeniul-tau.ro">
        <label>Adresa publică</label><input id="m_url" value="${esc(s.public_url)}" placeholder="https://testcam.go.ro">
        <small>Adresa la care ajung utilizatorii din afară. Linkurile din e-mailuri o folosesc – fără ea ar duce către IP-ul local şi n-ar funcţiona.</small>
      </div>
      <div class="btns" style="margin-top:16px">
        <button class="bsm red" id="m_save">Salvează</button>
        <button class="bsm" id="m_test">✉ Trimite un test</button>
      </div>
      <div id="m_msg" style="color:#8a93a8;font-size:13px;min-height:20px;margin-top:10px">${s.mail_ready?'<span style="color:#46d369">Configurat.</span>':"Neconfigurat – recuperarea parolei nu va funcţiona."}${s.mail_err?` <span style="color:#e87c03">Ultima eroare: ${esc(s.mail_err)}</span>`:""}</div>
     </div>

     <div class="panel"><h3>Parole şi protecţie</h3>
      <div class="fg">
        <label>Lungime minimă parolă</label><input id="p_min" type="number" min="6" max="64" value="${esc(s.pw_min)}" style="max-width:140px">
        <small>Se aplică la conturile noi şi la resetări. Parolele foarte comune sunt oricum respinse.</small>
        <label>HSTS</label>${sel("p_hsts",s.hsts,[["0","Oprit"],["1","Pornit – browserul foloseşte doar HTTPS"]])}
        <small>Porneşte-l doar dacă HTTPS merge stabil: browserele vor refuza apoi conexiunile HTTP către domeniul tău timp de 180 de zile.</small>
      </div>
      <div class="btns" style="margin-top:16px"><button class="bsm red" id="p_save">Salvează</button></div>
      <div class="netinfo" style="margin-top:16px">Protecţia la ghicirea parolei şi limitele de încercări se reglează în tabul <b>Setări</b>. Codul în doi paşi pentru contul tău se activează din meniul de sus → <b>Securitatea contului</b>.</div>
     </div>`;

    const libsSel=()=>[...document.querySelectorAll("[data-alib]")].filter(b=>b.checked).map(b=>b.dataset.alib);
    $("#a_save").onclick=async()=>{
      const all=[...document.querySelectorAll("[data-alib]")].length, chosen=libsSel();
      try{await api("/api/admin/settings",{method:"POST",body:{
        signup_mode:$("#a_mode").value,signup_invite:$("#a_invite").value.trim(),signup_verify:$("#a_verify").value,
        signup_domains:$("#a_domains").value.trim(),signup_remote:$("#a_remote").value,signup_max_q:$("#a_maxq").value,
        signup_live:$("#a_live").value,signup_download:$("#a_dl").value,
        signup_libs:(all&&chosen.length<all)?chosen.join("\n"):""}});
        t("settings_saved");draw()}catch(e){alert(e.message)}};
    $("#m_save").onclick=async()=>{
      try{await api("/api/admin/settings",{method:"POST",body:{
        smtp_host:$("#m_host").value.trim(),smtp_port:$("#m_port").value.trim(),smtp_tls:$("#m_tls").value,
        smtp_user:$("#m_user").value.trim(),smtp_pass:$("#m_pass").value,smtp_from:$("#m_from").value.trim(),
        public_url:$("#m_url").value.trim()}});t("email_settings_saved");draw()}catch(e){alert(e.message)}};
    $("#m_test").onclick=async()=>{
      const to=prompt(t("acc_email_test_prompt"),ME.email||$("#m_from").value||"");
      if(!to)return;
      $("#m_msg").innerHTML="Trimit…";
      try{const r=await api("/api/admin/mail/test",{method:"POST",body:{to}});
        $("#m_msg").innerHTML=`<span style="color:#46d369">Trimis către ${esc(r.to)}. Verifică şi în Spam.</span>`}
      catch(e){$("#m_msg").innerHTML=`<span style="color:#e87c03">${esc(e.message)}</span>`}};
    $("#p_save").onclick=async()=>{
      try{await api("/api/admin/settings",{method:"POST",body:{pw_min:$("#p_min").value,hsts:$("#p_hsts").value}});
        t("saved");draw()}catch(e){alert(e.message)}};
    $$("[data-app]").forEach(b=>b.onclick=async()=>{
      await api(`/api/admin/users/${b.dataset.app}/approve`,{method:"POST"});t("account_approved");draw()});
    $$("[data-rej]").forEach(b=>b.onclick=async()=>{
      if(!confirm(t("confirm_del_request")))return;
      await api("/api/admin/users/"+b.dataset.rej,{method:"DELETE"});t("request_rejected");draw()});
  };
  draw();
}

/* ================= ADMIN – BACKUP ================= */
async function admBk(){
  const draw=async()=>{
    if(location.hash!=="#/admin"||admTab!=="bk")return;
    let d;try{d=await api("/api/admin/backup")}catch(e){$("#adm").innerHTML=`<div class="panel">${esc(e.message)}</div>`;return}
    const when=t=>t?new Date(t*1000).toLocaleString("ro-RO",{day:"2-digit",month:"short",hour:"2-digit",minute:"2-digit"}):"niciodată";
    $("#adm").innerHTML=`
     <div class="panel"><h3>Copie de siguranță</h3>
      <div class="fg" style="margin-bottom:18px">
        <label>Ce salvez</label><select id="bkscope">
          <option value="config" ${d.scope==="config"?"selected":""}>Doar configurarea – setări, conturi, TV Live</option>
          <option value="full" ${d.scope==="full"?"selected":""}>Tot – şi biblioteca scanată, cu metadate şi progres</option></select>
        <small id="bkdesc"></small>
      </div>
      <div class="btns" style="margin-bottom:6px">
        <button class="bsm red" id="bkdl" style="padding:12px 24px">⬇ Descarcă o copie acum</button>
        <button class="bsm" id="bkrun">💾 Salvează pe server</button>
        <label class="bsm" id="bkimgwrap" style="display:inline-flex;align-items:center;gap:8px;cursor:pointer"><input type="checkbox" id="bkimg" ${d.images?"checked":""} style="accent-color:#e50914">Include și imaginile</label>
      </div>
      <div id="bkmsg" style="color:#8a93a8;font-size:13px;min-height:20px;margin-top:8px"></div>
     </div>

     <div class="panel"><h3>Copii automate</h3>
      <div class="fg">
        <label>Frecvență</label><select id="bkauto"><option value="off" ${d.auto==="off"?"selected":""}>Oprite</option><option value="daily" ${d.auto==="daily"?"selected":""}>Zilnic</option><option value="weekly" ${d.auto==="weekly"?"selected":""}>Săptămânal</option></select>
        <label>Câte copii păstrez</label><input id="bkkeep" type="number" min="1" max="100" value="${esc(d.keep)}">
        <label>Folder</label><input id="bkdir" value="${esc(d.dir)}" placeholder="implicit: lângă baza de date">
        <small>Pune aici calea unui disc extern sau a unui share montat, ca să ai copiile în altă parte decât serverul.</small>
      </div>
      <div class="btns" style="margin-top:14px"><button class="bsm red" id="bksave">Salvează</button></div>
      <div class="netinfo" style="margin-top:14px">Ultima copie: <b>${when(d.last)}</b>${d.err?` · <span style="color:#e87c03">ultima eroare: ${esc(d.err)}</span>`:""}</div>
     </div>

     <div class="panel"><h3>Copii existente pe server (${d.files.length})</h3>
      ${d.files.length?`<div style="overflow-x:auto"><table><tr><th>Fișier</th><th>Când</th><th>Mărime</th><th></th></tr>
        ${d.files.map(f=>`<tr><td>${esc(f.name)}</td><td>${when(f.t)}</td><td>${esc(f.size_h)}</td>
          <td style="white-space:nowrap;text-align:right"><button class="bsm" data-bkd="${esc(f.name)}">⬇ Descarcă</button>
          <button class="bsm" data-bkr="${esc(f.name)}">↺ Restaurează</button>
          <button class="bsm" data-bkx="${esc(f.name)}">Șterge</button></td></tr>`).join("")}</table></div>`
        :'<p style="color:#8a93a8">Nicio copie salvată pe server încă.</p>'}
     </div>

     <div class="panel"><h3>Restaurare dintr-un fișier</h3>
      <p style="color:#8a93a8;font-size:13px;margin:-8px 0 14px">Alege o arhivă descărcată mai devreme. Arhiva îşi poartă singură tipul: una de configurare aduce înapoi doar setările, conturile şi canalele TV, iar una completă înlocuieşte şi biblioteca. Fişierele video nu sunt atinse niciodată.</p>
      <input type="file" id="bkfile" accept=".zip" style="background:#1f2940;border:1px solid #36415c;border-radius:4px;color:#fff;padding:10px;max-width:420px">
      <div class="btns" style="margin-top:12px"><button class="bsm red" id="bkup">↺ Restaurează din fișier</button></div>
      <div id="bkupmsg" style="color:#8a93a8;font-size:13px;min-height:20px;margin-top:10px"></div>
     </div>`;

    const msg=(t,c="#8a93a8")=>{$("#bkmsg").innerHTML=`<span style="color:${c}">${t}</span>`};
    const updScope=()=>{
      const cfg=$("#bkscope").value==="config";
      $("#bkimgwrap").style.display=cfg?"none":"inline-flex";
      $("#bkdesc").innerHTML=cfg
        ? "Arhivă mică, de câţiva KB. Se salvează setările serverului, conturile cu drepturile şi bibliotecile lor, canalele TV Live şi listele M3U. <b>Nu</b> intră filmele, serialele, metadatele TMDB, subtitrările şi progresul – toate se refac singure la scanare. La restaurare, biblioteca existentă pe server rămâne neatinsă."
        : "Include şi biblioteca scanată: metadatele TMDB, subtitrările descărcate, progresul vizionărilor şi istoricul. <b>Înlocuieşte complet</b> biblioteca la restaurare. Util doar dacă muţi serverul cu tot cu filme, pe aceleaşi căi.";
    };
    $("#bkscope").onchange=updScope; updScope();
    $("#bkdl").onclick=()=>{msg("Pregătesc arhiva… descărcarea pornește în câteva momente.");
      location.href="/api/admin/backup/download?scope="+$("#bkscope").value+"&images="+($("#bkimg").checked?1:0);
      setTimeout(()=>msg(""),9000)};
    $("#bkrun").onclick=async()=>{$("#bkrun").disabled=true;msg("Salvez…");
      try{const r=await api("/api/admin/backup/run",{method:"POST",body:{scope:$("#bkscope").value,images:$("#bkimg").checked}});
        toast(`Copie salvată: ${r.name}`);msg("")}
      catch(e){msg(esc(e.message),"#e87c03")}finally{$("#bkrun").disabled=false;draw()}};
    $("#bksave").onclick=async()=>{
      try{await api("/api/admin/backup/settings",{method:"POST",body:{auto:$("#bkauto").value,keep:+$("#bkkeep").value,dir:$("#bkdir").value,images:$("#bkimg").checked,scope:$("#bkscope").value}});
        t("settings_saved");draw()}catch(e){alert(e.message)}};
    $$("[data-bkd]").forEach(b=>b.onclick=()=>{location.href="/api/admin/backup/download?name="+encodeURIComponent(b.dataset.bkd)});
    $$("[data-bkx]").forEach(b=>b.onclick=async()=>{if(!confirm(t("confirm_del_backup")))return;
      await api("/api/admin/backup/"+encodeURIComponent(b.dataset.bkx),{method:"DELETE"});t("backup_deleted");draw()});
    $$("[data-bkr]").forEach(b=>b.onclick=async()=>{
      if(!confirm(`Restaurezi din ${b.dataset.bkr}?\n\nSetările, conturile și canalele TV vor fi înlocuite cu cele din copie, iar redările în curs se opresc. Toată lumea va trebui să se reconecteze. Filmele de pe disc nu sunt atinse.`))return;
      b.disabled=true;
      try{await api(`/api/admin/backup/${encodeURIComponent(b.dataset.bkr)}/restore`,{method:"POST"});
        alert(t("restore_success"));location.reload()}
      catch(e){alert(e.message);b.disabled=false}});
    $("#bkup").onclick=async()=>{
      const f=$("#bkfile").files[0];
      if(!f)return $("#bkupmsg").textContent="Alege întâi un fișier .zip.";
      if(!confirm(`Restaurezi din ${f.name}?\n\nSetările, conturile și canalele TV vor fi înlocuite cu cele din copie. Toată lumea va trebui să se reconecteze. Filmele de pe disc nu sunt atinse.`))return;
      $("#bkup").disabled=true;$("#bkupmsg").textContent="Încarc și restaurez… nu închide pagina.";
      try{
        const r=await fetch("/api/admin/restore",{method:"POST",body:f,credentials:"same-origin",headers:{"Content-Type":"application/octet-stream"}});
        const j=await r.json().catch(()=>({}));
        if(!r.ok)throw new Error(j.detail||"Restaurarea a eșuat");
        alert(t("restore_success"));location.reload();
      }catch(e){$("#bkupmsg").innerHTML=`<span style="color:#e87c03">${esc(e.message)}</span>`;$("#bkup").disabled=false}};
  };
  draw();
}

/* ================= ADMIN – TV LIVE ================= */
async function admTv(){
  const ago=t=>{if(!t)return"niciodată";const m=Math.floor((Date.now()/1000-t)/60);return m<1?"acum":m<60?`acum ${m} min`:m<1440?`acum ${Math.floor(m/60)} h`:new Date(t*1000).toLocaleString("ro-RO")};
  const draw=async()=>{
    let d;try{d=await api("/api/admin/live")}catch(e){$("#adm").innerHTML=`<div class="panel">${esc(e.message)}</div>`;return}
    $("#adm").innerHTML=`
     <div class="panel"><h3 id="chformtitle">Adaugă canal</h3><div class="fg">
       <label>Nume</label><input id="ch_name" placeholder="ex: HD365">
       <label>URL stream</label><input id="ch_url" placeholder="http(s)/rtmp/rtsp/udp/srt://...">
       <label>URL logo</label><input id="ch_logo" placeholder="https://.../logo.png">
       <label>Grup / categorie</label><input id="ch_group" placeholder="ex: Știri">
       <label>Număr canal</label><input id="ch_num" type="number" min="1">
       <label>tvg-id (EPG)</label><input id="ch_tvgid" placeholder="pentru potrivire cu XMLTV">
       <label>User-Agent (opțional)</label><input id="ch_ua" placeholder="lăsat gol = implicit">
       <label>Mod</label><select id="ch_mode"><option value="auto">Automat (remux dacă se poate)</option><option value="copy">Forțează remux (fără transcodare)</option><option value="transcode">Forțează transcodare</option></select>
       <label>Activ</label><select id="ch_enabled"><option value="1">Da</option><option value="0">Nu</option></select>
      </div>
      <div id="chtest" style="margin:12px 0;color:#aaa;font-size:13px"></div>
      <div class="btns"><button class="bsm" id="chtestbtn">Testează</button><button class="bsm red" id="chsavebtn">Salvează canalul</button><button class="bsm hidden" id="chcancelbtn">Anulează editarea</button></div>
     </div>
     <div class="panel" id="chkpanel"><h3>Verificare canale</h3>
      <p style="color:#8a93a8;font-size:13px;margin-bottom:12px">Testează fiecare canal cu ffprobe și dezactivează automat cele care nu răspund. Verificarea automată rulează o dată la 24h.</p>
      <div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap">
       <button class="bsm red" id="chkbtn">▶ Verifică acum canalele active</button>
       <button class="bsm" id="chkallbtn">Verifică toate (inclusiv dezactivate)</button>
       <span id="chkst" style="font-size:13px;color:#8a93a8"></span>
      </div>
      <div id="chkbar" style="display:none;margin-top:12px">
       <div style="background:#1a2236;border-radius:4px;height:8px;overflow:hidden">
        <div id="chkprog" style="height:100%;background:var(--red);transition:width .4s;width:0%"></div>
       </div>
       <p id="chkinfo" style="font-size:13px;color:#aaa;margin-top:6px"></p>
      </div>
     </div>
     <div class="panel"><h3>Canale (${d.channels.length})</h3>
      ${d.channels.length?`<div style="overflow-x:auto"><table class="acthist"><tr><th>#</th><th>Nume</th><th>Grup</th><th>Sursă</th><th>Stare</th><th>EPG</th><th></th></tr>
      ${d.channels.map(c=>`<tr><td>${c.num??""}</td><td>${c.logo?`<img src="/api/live/logo/${c.id}" style="height:20px;vertical-align:-5px;margin-right:6px" alt="" onerror="this.remove()">`:""}${esc(c.name)}</td>
        <td>${esc(c.group||"")}</td><td>${c.source==="manual"?"manual":esc(c.source||"")}</td>
        <td>${c.enabled?(c.running?'<span class="pill ok">pornit</span>':'<span class="pill">oprit</span>'):'<span class="pill bad">dezactivat</span>'} ${c.probe&&!c.probe.ok?`<span class="pill bad" title="${esc(c.probe.error||"")}">eroare sursă</span>`:""}</td>
        <td>${c.epg?c.epg+" prog.":"—"}</td>
        <td style="text-align:right;white-space:nowrap"><button class="bsm" data-edit="${c.id}">Editează</button> <button class="bsm" data-del="${c.id}">Șterge</button></td></tr>`).join("")}</table></div>`:'<p style="color:#8a93a8">Niciun canal încă.</p>'}
     </div>
     <div class="panel"><h3>Import listă M3U</h3>
      <div style="margin-bottom:16px;padding:14px;background:#0b1120;border:1px solid #36415c;border-radius:6px">
       <p style="color:#ccc;margin-bottom:10px;font-size:14px">📁 Încarcă fișier .m3u de pe calculator</p>
       <div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap">
        <input type="file" id="pl_file" accept=".m3u,.m3u8" style="color:#ccc;font-size:13px;flex:1;min-width:200px">
        <input id="pf_name" placeholder="Nume listă (opțional)" style="background:#28324a;border:1px solid #445070;border-radius:4px;color:#fff;padding:8px;font-size:13px;width:180px">
        <button class="bsm red" id="pfuploadbtn">Încarcă</button>
       </div>
       <div id="pfmsg" style="margin-top:8px;font-size:13px;color:#8a93a8"></div>
      </div>
      <div class="fg">
       <label>URL listă M3U</label><input id="pl_url" placeholder="http://.../lista.m3u">
       <label>Nume listă</label><input id="pl_name" placeholder="opțional">
      </div><div class="btns"><button class="bsm red" id="pladdbtn">Adaugă listă din URL</button></div>
      <details style="margin-top:14px"><summary style="cursor:pointer;color:#aaa">Sau lipește text M3U direct</summary>
       <div class="fg" style="margin-top:10px"><label>Nume listă</label><input id="pt_name" placeholder="opțional">
       <label>Conținut M3U</label><textarea id="pt_text" style="min-height:140px" placeholder="#EXTM3U..."></textarea></div>
       <div class="btns"><button class="bsm red" id="ptaddbtn">Importă text lipit</button></div>
      </details>
      ${d.playlists.length?`<h4 class="sub">Liste existente</h4><table style="margin-top:8px">${d.playlists.map(p=>`<tr><td>${esc(p.name||p.url||("Listă #"+p.id))}</td><td>${p.count||0} canale</td><td>ultima: ${ago(p.last)}</td><td>${p.err?`<span class="pill bad" title="${esc(p.err)}">eroare</span>`:""}</td>
       <td style="text-align:right;white-space:nowrap"><button class="bsm" data-plref="${p.id}">↻ Reîmprospătează</button> <button class="bsm" data-pldel="${p.id}">Șterge</button></td></tr>`).join("")}</table>`:""}
     </div>
     <div class="panel"><h3>EPG (ghid de programe – XMLTV)</h3><div class="fg">
       <label>URL-uri XMLTV</label><textarea id="epg_urls" placeholder="câte un URL pe linie, opțional .gz">${esc(d.epg.urls||"")}</textarea>
      </div>
      <p style="color:#bbb;margin:10px 0">${d.epg.running?'<span class="pill ok">se actualizează…</span>':d.epg.last?`Ultima actualizare: ${ago(d.epg.last)} · ${d.epg.count} programe`:"Nicio actualizare încă"} ${d.epg.err?`<span class="pill bad">${esc(d.epg.err)}</span>`:""}</p>
      <div class="btns"><button class="bsm red" id="epgsavebtn">Salvează și reîmprospătează EPG</button></div>
     </div>`;
    function chReset(){["ch_name","ch_url","ch_logo","ch_group","ch_num","ch_tvgid","ch_ua"].forEach(k=>$("#"+k).value="");
      $("#ch_mode").value="auto";$("#ch_enabled").value="1";$("#chformtitle").textContent="Adaugă canal";$("#chcancelbtn").classList.add("hidden");$("#chtest").textContent="";delete $("#chsavebtn").dataset.id}
    $("#chtestbtn").onclick=async()=>{const el=$("#chtest");el.textContent="Se testează…";
      try{const r=await api("/api/admin/live/test",{method:"POST",body:{url:$("#ch_url").value.trim(),ua:$("#ch_ua").value.trim()}});
        el.innerHTML=r.ok?`<span class="pill ok">OK</span> ${esc(r.vcodec||"")} ${r.width&&r.height?esc(r.width)+"×"+esc(r.height):""} ${r.acodec?"· audio "+esc(r.acodec):""}`:`<span class="pill bad">${esc(r.error||"Eșuat")}</span>`}
      catch(e){el.innerHTML=`<span class="pill bad">${esc(e.message)}</span>`}};
    $("#chsavebtn").onclick=async()=>{
      const body={name:$("#ch_name").value.trim(),url:$("#ch_url").value.trim(),logo:$("#ch_logo").value.trim(),group:$("#ch_group").value.trim(),
        num:$("#ch_num").value,tvg_id:$("#ch_tvgid").value.trim(),ua:$("#ch_ua").value.trim(),mode:$("#ch_mode").value,enabled:$("#ch_enabled").value==="1"};
      if($("#chsavebtn").dataset.id)body.id=+$("#chsavebtn").dataset.id;
      try{await api("/api/admin/live/channel",{method:"POST",body:body});toast(body.id?"Canal actualizat":"Canal adăugat");chReset();draw()}catch(e){alert(e.message)}};
    $("#chcancelbtn").onclick=()=>chReset();
    $$("[data-edit]").forEach(b=>b.onclick=()=>{const c=d.channels.find(x=>x.id===+b.dataset.edit);if(!c)return;
      $("#ch_name").value=c.name;$("#ch_url").value=c.url;$("#ch_logo").value=c.logo||"";$("#ch_group").value=c.group||"";
      $("#ch_num").value=c.num||"";$("#ch_tvgid").value=c.tvg_id||"";$("#ch_ua").value=c.ua||"";$("#ch_mode").value=c.mode;$("#ch_enabled").value=c.enabled?"1":"0";
      $("#chsavebtn").dataset.id=c.id;$("#chformtitle").textContent="Editează canal: "+c.name;$("#chcancelbtn").classList.remove("hidden");scrollTo(0,0)});
    $$("[data-del]").forEach(b=>b.onclick=async()=>{if(!confirm(t("confirm_del_channel")))return;await api("/api/admin/live/channel/"+b.dataset.del,{method:"DELETE"});t("channel_deleted");draw()});
    $("#pladdbtn").onclick=async()=>{const url=$("#pl_url").value.trim();if(!url)return;
      try{const r=await api("/api/admin/live/playlist",{method:"POST",body:{url,name:$("#pl_name").value.trim()}});toast(`Listă adăugată – ${r.count} canale`);$("#pl_url").value="";$("#pl_name").value="";draw()}catch(e){alert(e.message)}};
    $("#ptaddbtn").onclick=async()=>{const text=$("#pt_text").value;if(!text.trim())return;
      try{const r=await api("/api/admin/live/playlist",{method:"POST",body:{text,name:$("#pt_name").value.trim()}});toast(`Import reușit – ${r.count} canale`);$("#pt_text").value="";$("#pt_name").value="";draw()}catch(e){alert(e.message)}};
    $("#pfuploadbtn").onclick=async()=>{
      const f=$("#pl_file").files[0],msg=$("#pfmsg"),btn=$("#pfuploadbtn");
      if(!f){msg.textContent="Alege un fișier .m3u mai întâi.";msg.style.color="#e87c03";return}
      btn.disabled=true;msg.textContent="Se încarcă…";msg.style.color="#e5c414";
      try{
        const res=await fetch("/api/admin/live/playlist/upload",{method:"POST",
          credentials:"same-origin",
          headers:{"X-Playlist-Name":$("#pf_name").value.trim()||f.name.replace(/\.m3u8?$/i,"")},
          body:f});
        if(!res.ok){const e=await res.json().catch(()=>({}));throw new Error(e.detail||"Eroare "+res.status)}
        const r=await res.json();
        msg.textContent=`✓ ${r.count} canale importate`;msg.style.color="#4caf82";
        $("#pl_file").value="";$("#pf_name").value="";
        setTimeout(draw,800);
      }catch(e){msg.textContent="Eroare: "+e.message;msg.style.color="#e50914"}
      btn.disabled=false;
    };
    $$("[data-plref]").forEach(b=>b.onclick=async()=>{await api(`/api/admin/live/playlist/${b.dataset.plref}/refresh`,{method:"POST"});t("refresh_started");setTimeout(draw,1200)});
    $$("[data-pldel]").forEach(b=>b.onclick=async()=>{if(!confirm(t("confirm_del_playlist")))return;await api("/api/admin/live/playlist/"+b.dataset.pldel,{method:"DELETE"});t("playlist_deleted");draw()});
    $("#epgsavebtn").onclick=async()=>{await api("/api/admin/live/epg",{method:"POST",body:{urls:$("#epg_urls").value}});t("epg_updating");setTimeout(draw,1500)};

    // verificare canale
    let _chkT=null;
    function chkStop(){clearInterval(_chkT);_chkT=null}
    async function chkPoll(){
      try{
        const s=await api("/api/admin/live/check");
        const pct=s.total?Math.round(s.done/s.total*100):0;
        $("#chkprog").style.width=pct+"%";
        $("#chkinfo").textContent=s.running
          ?`Se verifică: ${s.done}/${s.total} canale… ${s.disabled} dezactivate până acum`
          :`Finalizat: ${s.done} testate, ${s.disabled} dezactivate${s.err?" — eroare: "+s.err:""}${s.last?" · ultima: "+ago(s.last):""}`;
        if(!s.running){
          chkStop();
          $("#chkbtn").disabled=false;$("#chkallbtn").disabled=false;
          $("#chkst").textContent=s.disabled?`✓ ${s.disabled} canale dezactivate`:"✓ Toate canalele sunt OK";
          $("#chkst").style.color=s.disabled?"#e87c03":"#4caf82";
          if(s.disabled)setTimeout(draw,800);
        }
      }catch(e){chkStop();$("#chkst").textContent="Eroare: "+e.message;$("#chkst").style.color="#e50914"}
    }
    async function startCheck(only_enabled){
      try{
        const r=await api("/api/admin/live/check",{method:"POST",body:{only_enabled}});
        if(!r.ok){$("#chkst").textContent=r.msg||"Deja în curs";return}
        $("#chkbtn").disabled=true;$("#chkallbtn").disabled=true;
        $("#chkbar").style.display="";$("#chkst").textContent="";
        $("#chkprog").style.width="0%";$("#chkinfo").textContent="Se pornește…";
        chkStop();_chkT=setInterval(chkPoll,2000);
      }catch(e){$("#chkst").textContent="Eroare: "+e.message;$("#chkst").style.color="#e50914"}
    }
    // verifica starea la deschidere
    api("/api/admin/live/check").then(s=>{
      if(s.last){$("#chkst").textContent=`Ultima verificare: ${ago(s.last)} · ${s.disabled} dezactivate`;$("#chkst").style.color="#8a93a8"}
      if(s.running){$("#chkbar").style.display="";$("#chkbtn").disabled=true;$("#chkallbtn").disabled=true;_chkT=setInterval(chkPoll,2000)}
    }).catch(()=>{});
    $("#chkbtn").onclick=()=>startCheck(true);
    $("#chkallbtn").onclick=()=>startCheck(false);
  };
  await draw();
}

/* ================= TRANSLATIONS ================= */
const LANG={
ro:{
  /* nav */
  nav_home:"Acasă",nav_series:"Seriale",nav_movies:"Filme",nav_list:"Lista mea",nav_live:"TV Live",nav_search:"Caută",
  nav_search_ph:"Titluri, actori, genuri",
  /* login */
  login_title:"Conectare",login_user:"Utilizator sau e-mail",login_pass:"Parolă",login_2fa:"Cod din aplicaţia de autentificare",
  login_btn:"Conectare",login_forgot:"Am uitat parola",login_signup:"Creează cont",
  signup_title:"Cont nou",signup_user:"Nume utilizator",signup_email:"Adresă de e-mail",signup_pass:"Parolă",signup_invite:"Cod de invitaţie",
  signup_btn:"Creează contul",signup_have:"Am deja cont",
  forgot_title:"Ţi-ai uitat parola?",forgot_hint:"Scrie numele contului sau adresa de e-mail. Îţi trimitem un link de unde îţi alegi altă parolă.",
  forgot_ph:"Utilizator sau e-mail",forgot_btn:"Trimite linkul",forgot_back:"Înapoi la conectare",
  reset_title:"Alege o parolă nouă",reset_pass:"Parolă nouă",reset_pass2:"Încă o dată",reset_btn:"Salvează parola",reset_back:"Înapoi la conectare",
  /* user menu */
  menu_admin:"Administrare server",menu_changepw:"Schimbă parola",menu_security:"Securitatea contului",menu_logout_all:"Deconectează toate dispozitivele",
  menu_change_server:"Schimbă serverul (aplicație)",menu_apk:"📱 Aplicația Android (.apk)",menu_logout:"Deconectare",
  /* hero */
  hero_play:"Redă",hero_info:"Mai multe informații",hero_resume:"Reia",
  /* sort */
  sort_added:"Adăugate recent",sort_title:"Alfabetic",sort_year:"An apariție",sort_rating:"Rating",
  /* browse/search */
  genres:"Genuri",empty_browse:"Nimic aici încă.",
  list_title:"Lista mea",list_empty:"Nu ai adăugat nimic în listă.",
  search_results:'Rezultate pentru „{q}"',search_empty:'Nicio potrivire pentru „{q}".',
  /* home */
  lib_empty:"Biblioteca e goală",lib_empty_admin:'Adaugă foldere cu filme/seriale din <a href="#/admin" style="color:#e50914">Administrare</a> și pornești o scanare.',
  lib_empty_user:"Administratorul nu a adăugat încă nimic.",
  /* card actions */
  card_play:"Redă",card_list:"Lista mea",card_info:"Detalii",
  added_list:"Adăugat în Lista mea",removed_list:"Eliminat din Lista mea",
  /* modal */
  modal_from_start:"↺ De la început",modal_list:"Lista mea",modal_series_seasons:"{n} sezon",modal_series_seasons_pl:"{n} sezoane",
  modal_no_desc:"Fără descriere",modal_no_tmdb:" – adaugă o cheie TMDB în Administrare",
  modal_cast:"Distribuție: ",modal_genres:"Genuri: ",modal_dir:"Regia",modal_created:"Creat de",modal_orig:"Titlu original: ",
  modal_audio:"Audio: ",modal_episodes:"Episoade",modal_season:"Sezonul {n}",modal_versions:"Versiuni",modal_more_cast:"mai mulți",
  modal_fix:"✎ Corectează potrivirea (TMDB)",
  /* episode */
  ep_season:"Sezonul {s} · Episodul {e}",ep_watched:"✓ Vizionat",ep_no_desc:"Nu există o descriere pentru acest episod.",
  ep_directors:"Regia: ",ep_writers:"Scenariu: ",ep_audio:"Audio: ",ep_subs:"Subtitrări: ",ep_video:"Video: ",ep_file:"Fișier: ",
  ep_guests:"Invitați speciali",ep_mark_watched:"Marchează ca vizionat",ep_mark_unwatched:"Marchează ca nevizionat",
  ep_marked_watched:"Marcat ca vizionat",ep_marked_unwatched:"Marcat ca nevizionat",
  /* sub pick */
  sub_label:"Subtitrare",sub_auto:"Automat",sub_auto_ro:" – {label}",sub_auto_fallback:" – română, dacă există",sub_off:"Fără subtitrare",
  sub_search:"🔍 Caută online (RO)",sub_download_start:"Descarc…",sub_downloaded:"Subtitrare descărcată și aleasă",
  sub_not_found:"Nu am găsit subtitrări în română. {err}",sub_loaded:"Subtitrare încărcată",sub_load_fail:"Nu am putut încărca subtitrarea",
  sub_auto_found:"Subtitrare în română găsită automat",
  /* player */
  player_back:"Înapoi (Esc)",player_play:"Redă / Pauză (Spațiu)",player_rw:"Înapoi 10s (←)",player_ff:"Înainte 10s (→)",
  player_vol:"Sunet (M)",player_next:"Episodul următor",player_cast:"Redă pe TV (Google Cast)",player_ch:"Schimbă canalul",
  player_subs:"Subtitrări și audio",player_fs:"Ecran complet (F)",
  player_next_btn:"▶ Episodul următor",player_credits:"Vizionează genericul",
  player_audio:"Audio",player_subs_menu:"Subtitrări",player_subs_off:"Dezactivate",
  player_search_ro:"🔍 Caută online în română",player_sync:"Sincronizare: ",player_size:"Mărime: ",player_bg:"Fundal: ",
  player_size_sm:"Mică",player_size_md:"Medie",player_size_lg:"Mare",player_size_xl:"Foarte mare",
  player_bg_shadow:"Umbră",player_bg_box:"Casetă neagră",player_quality:"Calitate",
  player_subs_ro_title:"Subtitrări RO",player_subs_ro_back:"Înapoi",player_subs_searching:"Caut subtitrări în română…",
  player_subs_none:"Nu am găsit nimic. {err}",player_subs_remaining:"Descărcări rămase azi (OS): {n} · ⭐ = potrivire exactă cu fișierul",
  player_err_media:"Eroare la redare.",player_err_codec:"Fișierul nu poate fi redat pe acest dispozitiv (format sau codec neacceptat).",
  player_err_live_codec:"Canalul nu poate fi redat pe acest dispozitiv (format sau codec neacceptat).",
  player_err_net:"Conexiunea cu serverul s-a întrerupt.",player_err_live_net:"Sursa canalului nu răspunde. Încearcă din nou mai târziu.",
  player_incompat:"Format incompatibil cu browserul – pornesc transcodarea",
  player_channels:"Canale",
  /* download */
  dl_title:"Descarcă fișierul original",dl_throttled:"Descarcă (din afara casei viteza e limitată la bitrate-ul tău maxim)",
  dl_started:"Descărcarea a pornit",dl_started_throttled:"Descărcarea a pornit – viteză limitată (ești în afara rețelei locale)",
  dl_save_ok:"Se salvează pe dispozitiv – îl găsești în „Descărcate\"",dl_save_fail:"Nu am putut salva: {err}",
  /* cast */
  cast_this:"Acest dispozitiv",cast_none:"Niciun Chromecast găsit în rețea.",cast_stop:"■ Oprește redarea pe TV",
  cast_play_on:"Redă pe",cast_connected:"Conectat la {name}. Alege un film sau un canal și apasă Redă.",
  cast_sub_change:"Schimb subtitrarea pe TV…",cast_sub_stop:"Opreste redarea pe TV",
  cast_buffering:"Se încarcă pe",cast_paused:"În pauză pe",cast_playing:"Se redă pe",cast_starting:"Se pornește pe TV…",
  cast_rw:"Înapoi 10s",cast_ff:"Înainte 10s",cast_stop_title:"Oprește redarea pe TV",
  cast_no_sub:"Fără subtitrări",
  /* cast bar back */
  cbpp_pause:"Redă / Pauză",
  /* session */
  session_expired:"Sesiunea a expirat. Autentifică-te din nou – progresul vizionării a fost salvat.",
  session_expired_short:"Sesiune expirată",
  /* live */
  live_title:"TV Live",live_no_channels_admin:'Niciun canal configurat. Adaugă canale din <a href="#/admin" style="color:#e50914">Administrare → TV Live</a>.',
  live_no_channels:"Niciun canal disponibil momentan.",live_stop_alert:"Redarea a fost oprită de administratorul serverului.",
  /* admin */
  adm_title:"Administrare",adm_tab_act:"▶ Activitate",adm_tab_sys:"📊 Sistem",adm_tab_lib:"Bibliotecă",
  adm_tab_set:"Setări",adm_tab_usr:"Utilizatori",adm_tab_acc:"🔐 Conturi",adm_tab_tv:"📺 TV Live",adm_tab_bk:"💾 Backup",
  /* activity */
  act_now:"Redări acum",act_transcoding:"Transcodări active",act_remote:"Din afara casei",act_today:"Redări azi",
  act_week:"Vizionate în 7 zile",act_playing:"Se redă acum",act_nobody:"Nimeni nu se uită acum.",
  act_history:"Istoric vizionări",act_all_users:"Toți utilizatorii",act_clear:"Șterge istoricul",
  act_stop:"⏹ Oprește",act_stop_confirm:"Oprești această redare? Utilizatorul va fi anunțat.",
  act_clear_confirm:"Ștergi tot istoricul vizionărilor?",act_stopped:"Redare oprită",
  act_col_when:"Când",act_col_user:"Utilizator",act_col_title:"Titlu",act_col_dev:"Dispozitiv",
  act_col_ip:"IP",act_col_play:"Redare",act_col_watched:"Vizionat",act_col_progress:"Progres",
  act_method_direct:"Directă",act_method_copy:"Remux",act_method_transcode:"Transcodare",
  act_no_history:"Nicio vizionare înregistrată încă.",
  /* library */
  lib_movies:"Filme",lib_series:"Seriale",lib_files:"Fișiere video",lib_ro:"Cu subtitrare RO",lib_unmatched:"Fără metadate",
  lib_scan:"Scanare: ",lib_scan_running:"{phase} {done}/{total}",lib_scan_last:"ultima: {t}",lib_scan_never:"niciodată",
  lib_scan_btn:"↻ Scanează acum",lib_meta_btn:"Reîncearcă metadatele lipsă",lib_subs_btn:"Caută subtitrări RO pentru tot",
  lib_scan_started:"Scanare pornită",lib_meta_started:"Pornit",lib_server:"Server",
  lib_transcoding:"Transcodare",lib_tmdb:"TMDB",lib_tmdb_ok:"configurat",lib_tmdb_bad:"lipsă cheie",
  lib_os:"OpenSubtitles",lib_os_ok:"activ",lib_os_active:"activ (autentificat)",lib_os_dl:"descărcări rămase: {n}",lib_os_queue:"în coadă: {n}",
  lib_os_bad:"lipsă cheie API",lib_subsro:"Subs.ro",lib_subsro_ok:"activ",lib_subsro_off:"inactiv (opțional)",lib_version:"Versiune",
  lib_sessions:"Redări active ({n})",lib_nobody:"Nimeni nu se uită acum.",lib_waiting:"în așteptare",
  /* settings */
  set_title:"Setări",set_server_name:"Nume server",set_media_dirs:"Foldere media",set_media_dirs_hint:"Câte un folder pe linie. Filmele și serialele pot sta împreună – sunt detectate automat după nume (S01E02, 1x02…).",
  set_tmdb:"Cheie TMDB",set_os_key:"OpenSubtitles API key",set_os_user:"OpenSubtitles utilizator",set_os_pass:"OpenSubtitles parolă",
  set_subsro:"Subs.ro API key",set_auto_subs:"Subtitrări RO automate",set_auto_subs_yes:"Da – caută în fundal pentru fiecare fișier nou",
  set_auto_subs_no:"Nu – doar la cerere din player",set_hwaccel:"Accelerare hardware",set_vaapi:"Dispozitiv VAAPI",
  set_tonemap:"Tone-mapping HDR → SDR",set_tonemap_on:"Activat – filmele HDR/4K arată corect pe ecrane normale",set_tonemap_off:"Dezactivat",
  set_tonemap_alg:"Algoritm tone-mapping (CPU)",set_scan_interval:"Rescanare automată (minute)",set_save:"Salvează setările",
  set_saved:"Setări salvate",
  /* network */
  net_title:"🌐 Rețea",net_lan_nets:"Rețele considerate locale",net_lan_nets_hint:"Subrețele CIDR separate prin virgulă. Tot ce nu e aici = <b>extern</b>.",
  net_lan_auto:"Detectează automat rețeaua serverului",net_lan_auto_yes:"Da – inclusiv IPv6 de la provider (recomandat)",net_lan_auto_no:"Nu – doar lista de mai sus",
  net_max_height:"Rezoluție maximă (LAN)",net_bitrate:"Bitrate transcodare (LAN)",net_bitrate_hint:"În LAN fișierele compatibile se redau direct, la calitate originală.",
  net_remote:"Streaming extern (internet)",net_remote_enabled:"Acces din afara casei",net_remote_perm:"Permis",net_remote_block:"Blocat",
  net_download:"Descărcări",net_dl_all:"Permise – LAN la viteză maximă, extern limitat la bitrate",net_dl_lan:"Doar în rețeaua locală",net_dl_off:"Dezactivate",
  net_remote_max:"Bitrate maxim extern",net_remote_max_hint:"Limită maximă 4 Mbps. Utilizatorii aleg din player orice treaptă până la limita lor (setarea globală sau cea din contul lor, care e mai mică).",
  net_cast:"Google Cast",net_cast_hosts:"IP-uri Chromecast (opțional)",
  /* security */
  sec_title:"🛡️ Securitate",sec_sessions:"Sesiuni",sec_session_dur:"Durata unei sesiuni",sec_session_never:"Nu expiră (recomandat acasă)",
  sec_bf_title:"Protecție la ghicirea parolei",sec_bf_attempts:"Încercări greșite permise",sec_bf_window:"În intervalul de",sec_bf_block:"Blochează IP-ul pentru",
  sec_bf_lan:"Rețeaua locală",sec_bf_lan_exempt:"Excepție – nu bloca IP-urile din LAN",sec_bf_lan_apply:"Aplică și în LAN",
  sec_blocked:"IP-uri blocate ({n})",sec_unblock:"Deblochează",sec_unblock_all:"Deblochează tot",sec_no_blocked:"Niciun IP blocat.",
  sec_log:"Ultimele autentificări ({n})",sec_ok:"reușit",sec_fail:"greșit",sec_unblocked:"Deblocat",
  /* users */
  usr_title:"Utilizatori și permisiuni",usr_add:"Adaugă utilizator",usr_add_hint:"Conturile noi sunt utilizatori obișnuiți: văd și redau filmele, dar nu au acces la administrarea serverului. Există un singur administrator.",
  usr_name:"Nume",usr_pass:"Parolă",usr_remote:"Acces extern",usr_remote_ok:"Permis",usr_remote_lan:"Doar LAN",
  usr_max_q:"Bitrate max extern",usr_streams:"Ecrane simultane",usr_download:"Descărcare",usr_dl_ok:"Permisă",usr_dl_no:"Interzisă",
  usr_live:"TV Live",usr_live_ok:"Permis",usr_live_no:"Interzis",usr_active:"Cont",usr_active_yes:"Activ",usr_active_no:"Dezactivat",
  usr_email_ph:"pentru recuperarea parolei",usr_libs:"Biblioteci vizibile",usr_libs_hint:"Nebifat = utilizatorul nu vede acele filme nicăieri: nici pe pagina principală, nici la căutare, nici direct prin link. Toate bifate = vede tot, inclusiv bibliotecile adăugate mai târziu.",
  usr_devices:"Dispozitive",usr_save:"Salvează",usr_logout_all:"Deconectează de pe toate dispozitivele",
  usr_logout_confirm:"Deconectezi acest utilizator de pe toate dispozitivele? Redările în curs se opresc.",
  usr_perm_saved:"Permisiuni salvate",usr_reset_pw:"Resetează parola",usr_delete:"Șterge",
  usr_delete_confirm:"Ștergi utilizatorul?",usr_pw_prompt:"Parola nouă (utilizatorul va fi deconectat de pe toate dispozitivele):",
  usr_pw_changed:"Parolă schimbată",usr_add_btn:"Adaugă",usr_added:"Utilizator adăugat",usr_global_limit:"Limita globală",
  usr_screens_unlimited:"Nelimitat",
  usr_devices_connected:"dispozitiv conectat",usr_devices_connected_pl:"dispozitive conectate",
  /* accounts */
  acc_signup_title:"Cine îşi poate face cont",acc_mode:"Înregistrare",acc_invite:"Cod de invitaţie",acc_verify:"Confirmare e-mail",
  acc_domains:"Doar aceste domenii",acc_default_title:"Ce poate face un cont nou",acc_libs_title:"Biblioteci vizibile pentru conturile noi",
  acc_libs_hint:"Poţi schimba oricând drepturile fiecărui cont din tabul Utilizatori.",
  acc_save:"Salvează",acc_pending_title:"Aşteaptă aprobarea ta ({n})",
  acc_col_account:"Cont",acc_col_email:"E-mail",acc_col_when:"Când",acc_col_from:"De la",
  acc_approve:"Aprobă",acc_reject:"Respinge",acc_reject_confirm:"Ştergi definitiv această cerere de cont?",
  acc_approved:"Cont aprobat",acc_rejected:"Cerere respinsă",
  acc_email_title:"Trimitere e-mail",acc_smtp_host:"Server SMTP",acc_smtp_port:"Port",acc_smtp_tls:"Criptare",
  acc_smtp_user:"Utilizator",acc_smtp_pass:"Parolă",acc_smtp_from:"Expeditor",acc_public_url:"Adresa publică",
  acc_email_save:"Salvează",acc_email_test:"✉ Trimite un test",acc_email_test_prompt:"La ce adresă trimit mesajul de test?",
  acc_email_saved:"Setări e-mail salvate",acc_email_sending:"Trimit…",acc_email_spam:"Verifică şi în Spam.",
  acc_pw_title:"Parole şi protecţie",acc_pw_min:"Lungime minimă parolă",acc_hsts:"HSTS",acc_pw_save:"Salvează",acc_pw_saved:"Salvat",
  acc_email_not_config:"Neconfigurat – recuperarea parolei nu va funcţiona.",acc_email_ok:"Configurat.",acc_email_last_err:"Ultima eroare: {err}",
  /* backup */
  bk_title:"Copie de siguranță",bk_scope:"Ce salvez",bk_scope_config:"Doar configurarea – setări, conturi, TV Live",
  bk_scope_full:"Tot – şi biblioteca scanată, cu metadate şi progres",
  bk_download:"⬇ Descarcă o copie acum",bk_save_server:"💾 Salvează pe server",bk_images:"Include și imaginile",
  bk_auto_title:"Copii automate",bk_freq:"Frecvență",bk_freq_off:"Oprite",bk_freq_daily:"Zilnic",bk_freq_weekly:"Săptămânal",
  bk_keep:"Câte copii păstrez",bk_folder:"Folder",
  bk_folder_hint:"Pune aici calea unui disc extern sau a unui share montat, ca să ai copiile în altă parte decât serverul.",
  bk_save:"Salvează",bk_last:"Ultima copie: ",bk_last_never:"niciodată",bk_last_err:"ultima eroare: {err}",
  bk_files_title:"Copii existente pe server ({n})",bk_no_files:"Nicio copie salvată pe server încă.",
  bk_col_file:"Fișier",bk_col_when:"Când",bk_col_size:"Mărime",
  bk_download_file:"⬇ Descarcă",bk_restore_file:"↺ Restaurează",bk_delete_file:"Șterge",bk_delete_confirm:"Ștergi această copie?",
  bk_deleted:"Copie ștearsă",bk_restore_title:"Restaurare dintr-un fișier",
  bk_restore_hint:"Alege o arhivă descărcată mai devreme. Arhiva îşi poartă singură tipul: una de configurare aduce înapoi doar setările, conturile şi canalele TV, iar una completă înlocuieşte şi biblioteca. Fişierele video nu sunt atinse niciodată.",
  bk_restore_btn:"↺ Restaurează din fișier",bk_restore_confirm:"Restaurezi din {name}?\n\nSetările, conturile și canalele TV vor fi înlocuite cu cele din copie, iar redările în curs se opresc. Toată lumea va trebui să se reconecteze. Filmele de pe disc nu sunt atinse.",
  bk_restore_ok:"Restaurare reușită. Reîncarc pagina.",bk_restore_fail:"Restaurarea a eșuat",
  bk_restoring:"Încarc și restaurez… nu închide pagina.",bk_preparing:"Pregătesc arhiva… descărcarea pornește în câteva momente.",
  bk_saved:"Copie salvată: {name}",bk_no_file:"Alege întâi un fișier .zip.",
  bk_server_restore_confirm:"Restaurezi din {name}?\n\nSetările, conturile și canalele TV vor fi înlocuite cu cele din copie. Toată lumea va trebui să se reconecteze. Filmele de pe disc nu sunt atinse.",
  /* tv live admin */
  tv_add_title:"Adaugă canal",tv_name:"Nume",tv_url:"URL stream",tv_logo:"URL logo",tv_group:"Grup / categorie",tv_num:"Număr canal",
  tv_tvgid:"tvg-id (EPG)",tv_ua:"User-Agent (opțional)",tv_mode:"Mod",tv_mode_auto:"Automat (remux dacă se poate)",
  tv_mode_copy:"Forțează remux (fără transcodare)",tv_mode_transcode:"Forțează transcodare",tv_active:"Activ",
  tv_test:"Testează",tv_save:"Salvează canalul",tv_cancel:"Anulează editarea",tv_testing:"Se testează…",
  tv_channels_title:"Canale ({n})",tv_no_channels:"Niciun canal încă.",
  tv_col_num:"#",tv_col_name:"Nume",tv_col_group:"Grup",tv_col_source:"Sursă",tv_col_status:"Stare",tv_col_epg:"EPG",
  tv_status_on:"pornit",tv_status_off:"oprit",tv_status_disabled:"dezactivat",tv_status_err:"eroare sursă",
  tv_edit:"Editează",tv_delete:"Șterge",tv_delete_confirm:"Ștergi acest canal?",tv_deleted:"Canal șters",
  tv_saved:"Canal adăugat",tv_updated:"Canal actualizat",tv_edit_title:"Editează canal: {name}",
  tv_m3u_title:"Import listă M3U",tv_m3u_url:"URL listă M3U",tv_m3u_name:"Nume listă",tv_m3u_add:"Adaugă listă din URL",
  tv_m3u_paste_title:"Sau lipește text M3U direct",tv_m3u_paste_name:"Nume listă",tv_m3u_paste_content:"Conținut M3U",tv_m3u_paste_btn:"Importă text lipit",
  tv_m3u_added:"Listă adăugată – {n} canale",tv_m3u_imported:"Import reușit – {n} canale",
  tv_m3u_existing:"Liste existente",tv_m3u_refresh:"↻ Reîmprospătează",tv_m3u_delete:"Șterge",
  tv_m3u_refresh_started:"Reîmprospătare pornită",tv_m3u_delete_confirm:"Ștergi lista? Canalele importate din ea (nemodificate manual) vor fi șterse.",tv_m3u_deleted:"Listă ștearsă",
  tv_epg_title:"EPG (ghid de programe – XMLTV)",tv_epg_urls:"URL-uri XMLTV",tv_epg_save:"Salvează și reîmprospătează EPG",tv_epg_updating:"EPG se actualizează…",
  tv_source_manual:"manual",
  /* sys */
  sys_title:"Monitorizare",sys_refresh:"Se reîmprospătează la 3 secunde.",sys_remote_label:"Accesibilă şi din afara reţelei locale",
  sys_cpu:"Procesor",sys_ram:"Memorie",sys_net:"Reţea",sys_app:"CineVerse",
  sys_net_rx:"primit acum · trimis ",sys_net_legend_rx:"primit ",sys_net_legend_tx:"trimis ",
  sys_cores:"Pe nuclee",sys_ram_swap:"swap ",sys_disks:"Discuri",
  sys_col_mount:"Montat în",sys_col_fs:"Sistem",sys_col_used:"Folosit",sys_col_total:"Total",sys_col_free:"Liber",sys_col_occ:"Ocupare",
  sys_disk_act:"Activitate disc: citire {r}/s · scriere {w}/s",
  sys_gpu:"Accelerare video",sys_gpu_sw:"Procesor (software)",sys_no_gpu:"Nicio placă video detectată",
  sys_services:"Servicii",sys_no_services:"systemd indisponibil aici",sys_temps:"Temperaturi",sys_no_temps:"Niciun senzor de temperatură",
  sys_procs:"Procese care consumă cel mai mult",sys_col_pid:"PID",sys_col_proc:"Proces",sys_col_cpu:"Procesor",
  sys_col_mem:"Memorie",sys_col_cmd:"Comandă",
  sys_net_ifaces:"Interfeţe de reţea",sys_col_iface:"Interfaţă",sys_col_rxnow:"Primit acum",sys_col_txnow:"Trimis acum",
  sys_col_rxtot:"Total primit",sys_col_txtot:"Total trimis",
  sys_monitor_on:"Monitorizarea e accesibilă şi din afară",sys_monitor_off:"Monitorizarea rămâne doar în reţeaua locală",
  /* toasts / alerts */
  toast_pw_changed:"Parola a fost schimbată – celelalte dispozitive au fost deconectate",
  toast_email_saved:"Adresă salvată",toast_settings_saved:"Setări salvate",
  toast_logout_all_confirm:"Te deconectezi de pe TOATE dispozitivele (inclusiv acesta)?",
  toast_logged_out_all:"Ai fost deconectat de pe toate dispozitivele.",
  toast_sessions_closed:"{n} sesiuni închise",
  /* signup messages */
  signup_verify:"Ţi-am trimis un e-mail de confirmare. Deschide linkul din el, apoi conectează-te.",
  signup_approve:"Contul a fost creat. Îl activează administratorul – te anunţăm pe e-mail.",
  signup_done:"Contul a fost creat. Te poţi conecta.",
  signup_hint_pw:"Parola: minim {n} caractere.",
  signup_hint_verify:" După înregistrare îţi trimitem un e-mail de confirmare.",
  signup_hint_approve:" Contul devine activ după ce îl aprobă administratorul.",
  forgot_sent:"Dacă există un cont cu datele astea, ţi-am trimis un e-mail cu linkul de resetare. Verifică şi în Spam.",
  reset_done:"Parola a fost schimbată. Conectează-te cu ea.",
  reset_mismatch:"Cele două parole nu sunt la fel.",
  /* 2fa */
  tfa_active:"✓ Activ. La conectare ţi se cere şi un cod din aplicaţie.",
  tfa_disable:"Dezactivează",tfa_enable:"Activează",tfa_disabled:"Cod în doi paşi dezactivat",
  tfa_step1:"1. Deschide aplicaţia de autentificare şi adaugă un cont nou, manual, cu cheia:",
  tfa_step2:"Pe telefon poţi folosi direct <a href=\"{uri}\" style=\"color:#e50914\">acest link</a>.",
  tfa_step3:"2. Scrie codul de 6 cifre afişat de aplicaţie:",
  tfa_confirm:"Confirmă",tfa_done:"✓ Gata. De acum ţi se cere codul la fiecare conectare.",
  tfa_backup:"Păstrează codurile de rezervă de mai jos într-un loc sigur. Fiecare merge o singură dată şi te salvează dacă rămâi fără telefon:",
  tfa_pw_prompt:"Confirmă cu parola contului:",
  tfa_2fa_code:"Scrie codul din aplicaţia de autentificare (sau un cod de rezervă).",
  tfa_sec_title:"Securitatea contului",tfa_email_title:"Adresă de e-mail",
  tfa_email_hint:"Fără ea nu îţi poţi recupera singur parola.",tfa_email_save:"Salvează",
  tfa_2fa_section:"Cod în doi paşi",tfa_2fa_hint:"Pe lângă parolă, la conectare ţi se cere un cod de 6 cifre dintr-o aplicaţie ca Google Authenticator, Aegis sau 1Password. Recomandat mai ales dacă serverul e deschis spre internet.",
  /* fix match */
  fix_match_prompt:"Caută pe TMDB (titlu) sau introdu direct ID-ul TMDB:",fix_match_choose:"Alege potrivirea corectă",
  fix_match_done:"Metadate actualizate",fix_match_none:"Niciun rezultat (cheia TMDB e setată?)",
  /* app hint */
  hint_ios_share:"Partajează",hint_ios_add:"„Adaugă pe ecranul principal\"",hint_android_dl:"Descarcă APK",
  /* misc */
  serial_label:"Serial",sub_ro_badge:"Subtitrare în română disponibilă",sub_ro_ep:"Subtitrare în română",
  resume_time:"{pos} din {dur}",resume_left:"mai sunt {n} min",
  dev_label:"dispozitiv",dev_label_pl:"dispozitive",
  until:"până la",season_label:"Sezonul {n}",episode_label:"Episodul {n}",
  /* new action keys */
  no_subs:"Fără subtitrări",
  pw_changed_devices:"Parola a fost schimbată – celelalte dispozitive au fost deconectate",
  email_saved:"Adresă salvată",
  "2fa_disabled":"Cod în doi paşi dezactivat",
  save_fail:"Nu am putut salva",
  meta_updated:"Metadate actualizate",
  incompatible_format:"Format incompatibil cu browserul – pornesc transcodarea",
  scan_started:"Scanare pornită",started:"Pornit",unblocked:"Deblocat",
  settings_saved:"Setări salvate",user_added:"Utilizator adăugat",perms_saved:"Permisiuni salvate",
  pw_changed_short:"Parolă schimbată",account_approved:"Cont aprobat",
  request_rejected:"Cerere respinsă",saved:"Salvat",
  backup_deleted:"Copie ștearsă",channel_deleted:"Canal șters",
  refresh_started:"Reîmprospătare pornită",playlist_deleted:"Listă ștearsă",
  epg_updating:"EPG se actualizează…",
  confirm_logout_all:"Te deconectezi de pe TOATE dispozitivele (inclusiv acesta)?",
  confirm_stop_stream:"Oprești această redare? Utilizatorul va fi anunțat.",
  confirm_clear_history:"Ștergi tot istoricul vizionărilor?",
  confirm_logout_user:"Deconectezi acest utilizator de pe toate dispozitivele? Redările în curs se opresc.",
  confirm_del_user:"Ștergi utilizatorul?",
  confirm_del_request:"Ştergi definitiv această cerere de cont?",
  confirm_del_backup:"Ștergi această copie?",
  confirm_del_channel:"Ștergi acest canal?",
  confirm_del_playlist:"Ștergi lista? Canalele importate din ea (nemodificate manual) vor fi șterse.",
  restore_success:"Restaurare reușită. Reîncarc pagina.",
  current_pw_prompt:"Parola actuală:",new_pw_prompt:"Parola nouă:",
  new_pw_user_prompt:"Parola nouă (utilizatorul va fi deconectat de pe toate dispozitivele):",
  confirm_pw_prompt:"Confirmă cu parola contului:",
  stream_stopped:"Redare oprită",
  quality_set:"Calitate",
  email_settings_saved:"Setări e-mail salvate",
  logged_out_all:"Ai fost deconectat de pe toate dispozitivele.",
},
en:{
  nav_home:"Home",nav_series:"Series",nav_movies:"Movies",nav_list:"My List",nav_live:"TV Live",nav_search:"Search",
  nav_search_ph:"Titles, actors, genres",
  login_title:"Sign In",login_user:"Username or email",login_pass:"Password",login_2fa:"Code from authenticator app",
  login_btn:"Sign In",login_forgot:"Forgot password",login_signup:"Create account",
  signup_title:"New Account",signup_user:"Username",signup_email:"Email address",signup_pass:"Password",signup_invite:"Invite code",
  signup_btn:"Create account",signup_have:"I already have an account",
  forgot_title:"Forgot your password?",forgot_hint:"Enter your username or email. We'll send you a link to set a new password.",
  forgot_ph:"Username or email",forgot_btn:"Send link",forgot_back:"Back to sign in",
  reset_title:"Choose a new password",reset_pass:"New password",reset_pass2:"Confirm password",reset_btn:"Save password",reset_back:"Back to sign in",
  menu_admin:"Server Administration",menu_changepw:"Change password",menu_security:"Account security",menu_logout_all:"Sign out all devices",
  menu_change_server:"Change server (app)",menu_apk:"📱 Android App (.apk)",menu_logout:"Sign out",
  hero_play:"Play",hero_info:"More Info",hero_resume:"Resume",
  sort_added:"Recently Added",sort_title:"Alphabetical",sort_year:"Release Year",sort_rating:"Rating",
  genres:"Genres",empty_browse:"Nothing here yet.",
  list_title:"My List",list_empty:"You haven't added anything to your list.",
  search_results:'Results for "{q}"',search_empty:'No match for "{q}".',
  lib_empty:"Library is empty",lib_empty_admin:'Add folders from <a href="#/admin" style="color:#e50914">Administration</a> and start a scan.',
  lib_empty_user:"The administrator hasn't added anything yet.",
  card_play:"Play",card_list:"My List",card_info:"Details",
  added_list:"Added to My List",removed_list:"Removed from My List",
  modal_from_start:"↺ From beginning",modal_list:"My List",modal_series_seasons:"{n} season",modal_series_seasons_pl:"{n} seasons",
  modal_no_desc:"No description",modal_no_tmdb:" – add a TMDB key in Administration",
  modal_cast:"Cast: ",modal_genres:"Genres: ",modal_dir:"Director",modal_created:"Created by",modal_orig:"Original title: ",
  modal_audio:"Audio: ",modal_episodes:"Episodes",modal_season:"Season {n}",modal_versions:"Versions",modal_more_cast:"more",
  modal_fix:"✎ Fix match (TMDB)",
  ep_season:"Season {s} · Episode {e}",ep_watched:"✓ Watched",ep_no_desc:"No description available for this episode.",
  ep_directors:"Director: ",ep_writers:"Writer: ",ep_audio:"Audio: ",ep_subs:"Subtitles: ",ep_video:"Video: ",ep_file:"File: ",
  ep_guests:"Special guests",ep_mark_watched:"Mark as watched",ep_mark_unwatched:"Mark as unwatched",
  ep_marked_watched:"Marked as watched",ep_marked_unwatched:"Marked as unwatched",
  sub_label:"Subtitle",sub_auto:"Automatic",sub_auto_ro:" – {label}",sub_auto_fallback:" – Romanian if available",sub_off:"No subtitle",
  sub_search:"🔍 Search online (RO)",sub_download_start:"Downloading…",sub_downloaded:"Subtitle downloaded and selected",
  sub_not_found:"No Romanian subtitles found. {err}",sub_loaded:"Subtitle loaded",sub_load_fail:"Could not load subtitle",
  sub_auto_found:"Romanian subtitle found automatically",
  player_back:"Back (Esc)",player_play:"Play / Pause (Space)",player_rw:"Back 10s (←)",player_ff:"Forward 10s (→)",
  player_vol:"Volume (M)",player_next:"Next episode",player_cast:"Play on TV (Google Cast)",player_ch:"Change channel",
  player_subs:"Subtitles & audio",player_fs:"Fullscreen (F)",
  player_next_btn:"▶ Next episode",player_credits:"Watch credits",
  player_audio:"Audio",player_subs_menu:"Subtitles",player_subs_off:"Off",
  player_search_ro:"🔍 Search online (RO)",player_sync:"Sync: ",player_size:"Size: ",player_bg:"Background: ",
  player_size_sm:"Small",player_size_md:"Medium",player_size_lg:"Large",player_size_xl:"Extra large",
  player_bg_shadow:"Shadow",player_bg_box:"Black box",player_quality:"Quality",
  player_subs_ro_title:"RO Subtitles",player_subs_ro_back:"Back",player_subs_searching:"Searching Romanian subtitles…",
  player_subs_none:"Nothing found. {err}",player_subs_remaining:"Downloads left today (OS): {n} · ⭐ = exact file match",
  player_err_media:"Playback error.",player_err_codec:"This file cannot be played on this device (unsupported format or codec).",
  player_err_live_codec:"This channel cannot be played on this device (unsupported format or codec).",
  player_err_net:"Connection to server interrupted.",player_err_live_net:"Channel source not responding. Try again later.",
  player_incompat:"Format incompatible with browser – starting transcoding",
  player_channels:"Channels",
  dl_title:"Download original file",dl_throttled:"Download (speed limited to your max bitrate outside home network)",
  dl_started:"Download started",dl_started_throttled:"Download started – speed limited (you are outside local network)",
  dl_save_ok:"Saving to device – find it in \"Downloads\"",dl_save_fail:"Could not save: {err}",
  cast_this:"This device",cast_none:"No Chromecast found on network.",cast_stop:"■ Stop TV playback",
  cast_play_on:"Play on",cast_connected:"Connected to {name}. Choose a movie or channel and press Play.",
  cast_sub_change:"Changing subtitle on TV…",cast_sub_stop:"Stop TV playback",
  cast_buffering:"Loading on",cast_paused:"Paused on",cast_playing:"Playing on",cast_starting:"Starting on TV…",
  cast_rw:"Back 10s",cast_ff:"Forward 10s",cast_stop_title:"Stop TV playback",
  cast_no_sub:"No subtitles",cbpp_pause:"Play / Pause",
  session_expired:"Session expired. Please sign in again – your watch progress has been saved.",
  session_expired_short:"Session expired",
  live_title:"TV Live",live_no_channels_admin:'No channels configured. Add channels from <a href="#/admin" style="color:#e50914">Administration → TV Live</a>.',
  live_no_channels:"No channels available at the moment.",live_stop_alert:"Playback was stopped by the server administrator.",
  adm_title:"Administration",adm_tab_act:"▶ Activity",adm_tab_sys:"📊 System",adm_tab_lib:"Library",
  adm_tab_set:"Settings",adm_tab_usr:"Users",adm_tab_acc:"🔐 Accounts",adm_tab_tv:"📺 TV Live",adm_tab_bk:"💾 Backup",
  act_now:"Playing now",act_transcoding:"Active transcodings",act_remote:"From outside home",act_today:"Plays today",
  act_week:"Watched in 7 days",act_playing:"Now playing",act_nobody:"Nobody is watching now.",
  act_history:"Watch history",act_all_users:"All users",act_clear:"Clear history",
  act_stop:"⏹ Stop",act_stop_confirm:"Stop this playback? The user will be notified.",
  act_clear_confirm:"Delete all watch history?",act_stopped:"Playback stopped",
  act_col_when:"When",act_col_user:"User",act_col_title:"Title",act_col_dev:"Device",
  act_col_ip:"IP",act_col_play:"Playback",act_col_watched:"Watched",act_col_progress:"Progress",
  act_method_direct:"Direct",act_method_copy:"Remux",act_method_transcode:"Transcode",
  act_no_history:"No watch history recorded yet.",
  lib_movies:"Movies",lib_series:"Series",lib_files:"Video files",lib_ro:"With RO subtitle",lib_unmatched:"No metadata",
  lib_scan:"Scan: ",lib_scan_running:"{phase} {done}/{total}",lib_scan_last:"last: {t}",lib_scan_never:"never",
  lib_scan_btn:"↻ Scan now",lib_meta_btn:"Retry missing metadata",lib_subs_btn:"Search RO subtitles for all",
  lib_scan_started:"Scan started",lib_meta_started:"Started",lib_server:"Server",
  lib_transcoding:"Transcoding",lib_tmdb:"TMDB",lib_tmdb_ok:"configured",lib_tmdb_bad:"missing key",
  lib_os:"OpenSubtitles",lib_os_ok:"active",lib_os_active:"active (authenticated)",lib_os_dl:"downloads left: {n}",lib_os_queue:"queue: {n}",
  lib_os_bad:"missing API key",lib_subsro:"Subs.ro",lib_subsro_ok:"active",lib_subsro_off:"inactive (optional)",lib_version:"Version",
  lib_sessions:"Active sessions ({n})",lib_nobody:"Nobody is watching now.",lib_waiting:"waiting",
  set_title:"Settings",set_server_name:"Server name",set_media_dirs:"Media folders",set_media_dirs_hint:"One folder per line. Movies and series can coexist – detected automatically by name (S01E02, 1x02…).",
  set_tmdb:"TMDB key",set_os_key:"OpenSubtitles API key",set_os_user:"OpenSubtitles username",set_os_pass:"OpenSubtitles password",
  set_subsro:"Subs.ro API key",set_auto_subs:"Automatic RO subtitles",set_auto_subs_yes:"Yes – search in background for each new file",
  set_auto_subs_no:"No – only on request from player",set_hwaccel:"Hardware acceleration",set_vaapi:"VAAPI device",
  set_tonemap:"HDR → SDR Tone-mapping",set_tonemap_on:"Enabled – HDR/4K movies look correct on standard screens",set_tonemap_off:"Disabled",
  set_tonemap_alg:"Tone-mapping algorithm (CPU)",set_scan_interval:"Auto-rescan (minutes)",set_save:"Save settings",
  set_saved:"Settings saved",
  net_title:"🌐 Network",net_lan_nets:"Networks considered local",net_lan_nets_hint:"CIDR subnets separated by comma. Everything else = <b>external</b>.",
  net_lan_auto:"Auto-detect server network",net_lan_auto_yes:"Yes – including provider IPv6 (recommended)",net_lan_auto_no:"No – only the list above",
  net_max_height:"Max resolution (LAN)",net_bitrate:"Transcoding bitrate (LAN)",net_bitrate_hint:"On LAN, compatible files play directly at original quality.",
  net_remote:"External streaming (internet)",net_remote_enabled:"Access from outside home",net_remote_perm:"Allowed",net_remote_block:"Blocked",
  net_download:"Downloads",net_dl_all:"Allowed – LAN at max speed, external limited to bitrate",net_dl_lan:"LAN only",net_dl_off:"Disabled",
  net_remote_max:"Max external bitrate",net_remote_max_hint:"Maximum limit 4 Mbps. Users can choose any level up to their limit in the player.",
  net_cast:"Google Cast",net_cast_hosts:"Chromecast IPs (optional)",
  sec_title:"🛡️ Security",sec_sessions:"Sessions",sec_session_dur:"Session duration",sec_session_never:"Never expires (recommended at home)",
  sec_bf_title:"Password brute-force protection",sec_bf_attempts:"Failed attempts allowed",sec_bf_window:"Within",sec_bf_block:"Block IP for",
  sec_bf_lan:"Local network",sec_bf_lan_exempt:"Exception – don't block LAN IPs",sec_bf_lan_apply:"Apply to LAN too",
  sec_blocked:"Blocked IPs ({n})",sec_unblock:"Unblock",sec_unblock_all:"Unblock all",sec_no_blocked:"No IPs blocked.",
  sec_log:"Recent logins ({n})",sec_ok:"success",sec_fail:"failed",sec_unblocked:"Unblocked",
  usr_title:"Users & permissions",usr_add:"Add user",usr_add_hint:"New accounts are regular users: they can view and play movies, but have no access to server administration. There is only one administrator.",
  usr_name:"Name",usr_pass:"Password",usr_remote:"External access",usr_remote_ok:"Allowed",usr_remote_lan:"LAN only",
  usr_max_q:"Max external bitrate",usr_streams:"Simultaneous screens",usr_download:"Download",usr_dl_ok:"Allowed",usr_dl_no:"Forbidden",
  usr_live:"TV Live",usr_live_ok:"Allowed",usr_live_no:"Forbidden",usr_active:"Account",usr_active_yes:"Active",usr_active_no:"Disabled",
  usr_email_ph:"for password recovery",usr_libs:"Visible libraries",usr_libs_hint:"Unchecked = user cannot see those movies anywhere: not on home, not in search, not via direct link. All checked = sees everything, including libraries added later.",
  usr_devices:"Devices",usr_save:"Save",usr_logout_all:"Sign out all devices",
  usr_logout_confirm:"Sign out this user from all devices? Ongoing playbacks will stop.",
  usr_perm_saved:"Permissions saved",usr_reset_pw:"Reset password",usr_delete:"Delete",
  usr_delete_confirm:"Delete this user?",usr_pw_prompt:"New password (user will be signed out of all devices):",
  usr_pw_changed:"Password changed",usr_add_btn:"Add",usr_added:"User added",usr_global_limit:"Global limit",
  usr_screens_unlimited:"Unlimited",
  usr_devices_connected:"device connected",usr_devices_connected_pl:"devices connected",
  acc_signup_title:"Who can create an account",acc_mode:"Registration",acc_invite:"Invite code",acc_verify:"Email confirmation",
  acc_domains:"Only these domains",acc_default_title:"What a new account can do",acc_libs_title:"Visible libraries for new accounts",
  acc_libs_hint:"You can change each account's permissions anytime from the Users tab.",
  acc_save:"Save",acc_pending_title:"Awaiting your approval ({n})",
  acc_col_account:"Account",acc_col_email:"Email",acc_col_when:"When",acc_col_from:"From",
  acc_approve:"Approve",acc_reject:"Reject",acc_reject_confirm:"Permanently delete this account request?",
  acc_approved:"Account approved",acc_rejected:"Request rejected",
  acc_email_title:"Email sending",acc_smtp_host:"SMTP server",acc_smtp_port:"Port",acc_smtp_tls:"Encryption",
  acc_smtp_user:"Username",acc_smtp_pass:"Password",acc_smtp_from:"Sender",acc_public_url:"Public URL",
  acc_email_save:"Save",acc_email_test:"✉ Send a test",acc_email_test_prompt:"Send test to which address?",
  acc_email_saved:"Email settings saved",acc_email_sending:"Sending…",acc_email_spam:"Check your Spam folder too.",
  acc_pw_title:"Passwords & protection",acc_pw_min:"Minimum password length",acc_hsts:"HSTS",acc_pw_save:"Save",acc_pw_saved:"Saved",
  acc_email_not_config:"Not configured – password recovery will not work.",acc_email_ok:"Configured.",acc_email_last_err:"Last error: {err}",
  bk_title:"Backup",bk_scope:"What to save",bk_scope_config:"Configuration only – settings, accounts, TV Live",
  bk_scope_full:"Everything – including scanned library with metadata and progress",
  bk_download:"⬇ Download a copy now",bk_save_server:"💾 Save to server",bk_images:"Include images",
  bk_auto_title:"Automatic backups",bk_freq:"Frequency",bk_freq_off:"Disabled",bk_freq_daily:"Daily",bk_freq_weekly:"Weekly",
  bk_keep:"How many copies to keep",bk_folder:"Folder",
  bk_folder_hint:"Set path to an external disk or mounted share to keep copies elsewhere.",
  bk_save:"Save",bk_last:"Last backup: ",bk_last_never:"never",bk_last_err:"last error: {err}",
  bk_files_title:"Backups on server ({n})",bk_no_files:"No backups saved on server yet.",
  bk_col_file:"File",bk_col_when:"When",bk_col_size:"Size",
  bk_download_file:"⬇ Download",bk_restore_file:"↺ Restore",bk_delete_file:"Delete",bk_delete_confirm:"Delete this backup?",
  bk_deleted:"Backup deleted",bk_restore_title:"Restore from file",
  bk_restore_hint:"Choose a previously downloaded archive. The archive carries its own type: a config archive restores only settings, accounts and TV channels, while a full one replaces the library too. Video files are never touched.",
  bk_restore_btn:"↺ Restore from file",bk_restore_confirm:"Restore from {name}?\n\nSettings, accounts and TV channels will be replaced with those from the backup, and ongoing playbacks will stop. Everyone will need to sign in again. Video files on disk are not affected.",
  bk_restore_ok:"Restore successful. Reloading page.",bk_restore_fail:"Restore failed",
  bk_restoring:"Uploading and restoring… do not close this page.",bk_preparing:"Preparing archive… download will start in a moment.",
  bk_saved:"Backup saved: {name}",bk_no_file:"Choose a .zip file first.",
  bk_server_restore_confirm:"Restore from {name}?\n\nSettings, accounts and TV channels will be replaced. Everyone will need to sign in again. Video files on disk are not affected.",
  tv_add_title:"Add channel",tv_name:"Name",tv_url:"Stream URL",tv_logo:"Logo URL",tv_group:"Group / category",tv_num:"Channel number",
  tv_tvgid:"tvg-id (EPG)",tv_ua:"User-Agent (optional)",tv_mode:"Mode",tv_mode_auto:"Auto (remux if possible)",
  tv_mode_copy:"Force remux (no transcoding)",tv_mode_transcode:"Force transcoding",tv_active:"Active",
  tv_test:"Test",tv_save:"Save channel",tv_cancel:"Cancel editing",tv_testing:"Testing…",
  tv_channels_title:"Channels ({n})",tv_no_channels:"No channels yet.",
  tv_col_num:"#",tv_col_name:"Name",tv_col_group:"Group",tv_col_source:"Source",tv_col_status:"Status",tv_col_epg:"EPG",
  tv_status_on:"running",tv_status_off:"stopped",tv_status_disabled:"disabled",tv_status_err:"source error",
  tv_edit:"Edit",tv_delete:"Delete",tv_delete_confirm:"Delete this channel?",tv_deleted:"Channel deleted",
  tv_saved:"Channel added",tv_updated:"Channel updated",tv_edit_title:"Edit channel: {name}",
  tv_m3u_title:"Import M3U playlist",tv_m3u_url:"M3U playlist URL",tv_m3u_name:"Playlist name",tv_m3u_add:"Add playlist from URL",
  tv_m3u_paste_title:"Or paste M3U text directly",tv_m3u_paste_name:"Playlist name",tv_m3u_paste_content:"M3U content",tv_m3u_paste_btn:"Import pasted text",
  tv_m3u_added:"Playlist added – {n} channels",tv_m3u_imported:"Import successful – {n} channels",
  tv_m3u_existing:"Existing playlists",tv_m3u_refresh:"↻ Refresh",tv_m3u_delete:"Delete",
  tv_m3u_refresh_started:"Refresh started",tv_m3u_delete_confirm:"Delete this playlist? Channels imported from it (not manually modified) will be removed.",tv_m3u_deleted:"Playlist deleted",
  tv_epg_title:"EPG (program guide – XMLTV)",tv_epg_urls:"XMLTV URLs",tv_epg_save:"Save and refresh EPG",tv_epg_updating:"EPG updating…",
  tv_source_manual:"manual",
  sys_title:"Monitoring",sys_refresh:"Refreshes every 3 seconds.",sys_remote_label:"Accessible from outside local network",
  sys_cpu:"CPU",sys_ram:"Memory",sys_net:"Network",sys_app:"CineVerse",
  sys_net_rx:"received now · sent ",sys_net_legend_rx:"received ",sys_net_legend_tx:"sent ",
  sys_cores:"Per core",sys_ram_swap:"swap ",sys_disks:"Disks",
  sys_col_mount:"Mount",sys_col_fs:"FS",sys_col_used:"Used",sys_col_total:"Total",sys_col_free:"Free",sys_col_occ:"Usage",
  sys_disk_act:"Disk activity: read {r}/s · write {w}/s",
  sys_gpu:"Video acceleration",sys_gpu_sw:"CPU (software)",sys_no_gpu:"No GPU detected",
  sys_services:"Services",sys_no_services:"systemd not available here",sys_temps:"Temperatures",sys_no_temps:"No temperature sensors",
  sys_procs:"Top CPU/memory processes",sys_col_pid:"PID",sys_col_proc:"Process",sys_col_cpu:"CPU",
  sys_col_mem:"Memory",sys_col_cmd:"Command",
  sys_net_ifaces:"Network interfaces",sys_col_iface:"Interface",sys_col_rxnow:"Received now",sys_col_txnow:"Sent now",
  sys_col_rxtot:"Total received",sys_col_txtot:"Total sent",
  sys_monitor_on:"Monitoring accessible from outside too",sys_monitor_off:"Monitoring stays on local network only",
  toast_pw_changed:"Password changed – other devices have been signed out",
  toast_email_saved:"Address saved",toast_settings_saved:"Settings saved",
  toast_logout_all_confirm:"Sign out of ALL devices (including this one)?",
  toast_logged_out_all:"You have been signed out of all devices.",
  toast_sessions_closed:"{n} sessions closed",
  signup_verify:"We sent you a confirmation email. Open the link in it, then sign in.",
  signup_approve:"Account created. The administrator will activate it – we'll notify you by email.",
  signup_done:"Account created. You can now sign in.",
  signup_hint_pw:"Password: at least {n} characters.",
  signup_hint_verify:" After registration we'll send you a confirmation email.",
  signup_hint_approve:" Account becomes active after administrator approval.",
  forgot_sent:"If an account with those details exists, we've sent you a reset link. Check your Spam folder too.",
  reset_done:"Password changed. Sign in with the new one.",
  reset_mismatch:"The two passwords don't match.",
  tfa_active:"✓ Active. A code from your app is required at sign in.",
  tfa_disable:"Disable",tfa_enable:"Enable",tfa_disabled:"Two-factor code disabled",
  tfa_step1:"1. Open your authenticator app and add a new account manually with this key:",
  tfa_step2:'On your phone you can use <a href="{uri}" style="color:#e50914">this link</a> directly.',
  tfa_step3:"2. Enter the 6-digit code displayed by the app:",
  tfa_confirm:"Confirm",tfa_done:"✓ Done. A code will now be required at every sign in.",
  tfa_backup:"Keep the backup codes below in a safe place. Each can be used once and will save you if you lose your phone:",
  tfa_pw_prompt:"Confirm with account password:",
  tfa_2fa_code:"Enter the code from your authenticator app (or a backup code).",
  tfa_sec_title:"Account security",tfa_email_title:"Email address",
  tfa_email_hint:"Without it you cannot recover your password on your own.",tfa_email_save:"Save",
  tfa_2fa_section:"Two-factor code",tfa_2fa_hint:"In addition to your password, a 6-digit code from an app like Google Authenticator, Aegis or 1Password is required at sign in. Recommended especially if the server is open to the internet.",
  fix_match_prompt:"Search TMDB (title) or enter the TMDB ID directly:",fix_match_choose:"Choose the correct match",
  fix_match_done:"Metadata updated",fix_match_none:"No results (is the TMDB key set?)",
  hint_ios_share:"Share",hint_ios_add:"\"Add to Home Screen\"",hint_android_dl:"Download APK",
  serial_label:"Series",sub_ro_badge:"Romanian subtitle available",sub_ro_ep:"Romanian subtitle",
  resume_time:"{pos} of {dur}",resume_left:"{n} min left",
  dev_label:"device",dev_label_pl:"devices",
  until:"until",season_label:"Season {n}",episode_label:"Episode {n}",
  /* new action keys */
  no_subs:"No subtitles",
  pw_changed_devices:"Password changed – other devices have been signed out",
  email_saved:"Address saved",
  "2fa_disabled":"Two-factor code disabled",
  save_fail:"Could not save",
  meta_updated:"Metadata updated",
  incompatible_format:"Format incompatible with browser – starting transcoding",
  scan_started:"Scan started",started:"Started",unblocked:"Unblocked",
  settings_saved:"Settings saved",user_added:"User added",perms_saved:"Permissions saved",
  pw_changed_short:"Password changed",account_approved:"Account approved",
  request_rejected:"Request rejected",saved:"Saved",
  backup_deleted:"Backup deleted",channel_deleted:"Channel deleted",
  refresh_started:"Refresh started",playlist_deleted:"Playlist deleted",
  epg_updating:"EPG updating…",
  confirm_logout_all:"Sign out of ALL devices (including this one)?",
  confirm_stop_stream:"Stop this playback? The user will be notified.",
  confirm_clear_history:"Delete all watch history?",
  confirm_logout_user:"Sign out this user from all devices? Ongoing playbacks will stop.",
  confirm_del_user:"Delete this user?",
  confirm_del_request:"Permanently delete this account request?",
  confirm_del_backup:"Delete this backup?",
  confirm_del_channel:"Delete this channel?",
  confirm_del_playlist:"Delete this playlist? Channels imported from it (not manually modified) will be removed.",
  restore_success:"Restore successful. Reloading page.",
  current_pw_prompt:"Current password:",new_pw_prompt:"New password:",
  new_pw_user_prompt:"New password (user will be signed out of all devices):",
  confirm_pw_prompt:"Confirm with account password:",
  stream_stopped:"Playback stopped",
  quality_set:"Quality",
  email_settings_saved:"Email settings saved",
  logged_out_all:"You have been signed out of all devices.",
}};
const _lang="ro";
function t(k){return(LANG.ro[k])||k}

boot().then(()=>{if(!ME)showLogin()});
</script>
</body>
</html>
CINEVERSE_HTML_EOF
base64 -d > "$APP/static/icon-180.png" <<'CINEVERSE_B64_EOF'
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
RU5ErkJggg==
CINEVERSE_B64_EOF
base64 -d > "$APP/static/icon-192.png" <<'CINEVERSE_B64_EOF'
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
mYs4AUTpAAAAAElFTkSuQmCC
CINEVERSE_B64_EOF
base64 -d > "$APP/static/icon-512.png" <<'CINEVERSE_B64_EOF'
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
SUVORK5CYII=
CINEVERSE_B64_EOF
base64 -d > "$APP/static/CineVerse.apk" <<'CINEVERSE_B64_EOF'
UEsDBBQAAgAIAAAQIQDyvIILPgQAACQMAAATAAAAQW5kcm9pZE1hbmlmZXN0LnhtbI1VPXMbVRQ9
u3LMOrKxotj5svyB4yTYhg0kTIahYBAeBpIYM4NDki4IfRhPZFuRVolJkwxFhoKhpKKg5AekpGAo
GSYFNNRUKVIw+QPk3Ku72peVNNbunN1959137n333fc2gwBL44CHAr4fBd5Acv3pfJ8i3iE+J+4S
3xI/E4+J34knxFMi7wHvE+vEl8Q+8SPxG/EXseIDIfEBERG/EL8SzwlkgIA4RqwQ68Qj4h8iHAGu
EPvEY+IJ8S+BQ8AcERI14j6RZYRVNNHCNvawizU+K2R6ezZQwo72TPC9TWaTlrdx/SUrIIeIlk1s
kY8G2Izw6aqVsD/AMmCrijtok5Gvik6jzhFfsVVXrW2UzTpLvs57D/fwIb/LVGyjwZ6j+FqjqrCn
pEpF9pZVQzyWGGtHfYojWvxuMRfSJ9bSt8/nNbWs8RafEklE3arNJFCrBr03u2qHNdY2oyvT8tNu
dicsZlHaoieJbldz1tJo72mGKzqTTT5rVLxMpkGtyNF5RcdV6HGPI8TjCrUi3g28h/O8W+q5qllu
IUzZhxrHDu1KHHGb76bGcL5HF+qtYVktaazACTJ1zV5N573DvMta1Tnm+oDKGn5MUnOBxr9Lvqbx
ReRO8qvNGexqpQnX1PXqVOeWzm1be+NKruqaXWDPW8QFtnw+Lyp7ydi31VtcA28SUpfApMM1VE/8
tJxanenJbT+7kOu4wUr6iOfDBp/XOPLckCOLzOIax2zyvmWjb+AzKl1le5OtoioDy0Mq3uDYyzrm
FnGzG1cR66Yo6kV8rKrjTg5qmuuITFPzOt3jMb3jQq1qqXjwBD3YOmJfW6tXali4aneXN7SGZBdK
DMlpIdUp7btEhG90p4XcLyWthGKfXuEjVY50VlKHkeYKGO3qdfRP9UTtjg5fshavRV1riatsJ8yW
Vrx4XjhAKz0i5IoU8QX11vCJrpJcD72APGvP97wCMU40iAw87w7fPxAev33iIb//Jp6NkGI7R8wS
88SqL2Y57k3ZE8D/vI7IP0ra5L9zeLmO60k5Jb8UvfL2lr6AP4E/jPN0n0oGkDlp/VN6BnS4E8ZN
239Txh437pjuqY7djMWxrquSxFGwOHwnDt+JY9q4jMMtStvmmtYSH+/qSZfws+bDc3zI73TOYptz
9NLjYr1gCL1505t39II+epKDsT56fkpvwfQWjDvk5KDg+Bgb4OOww782wMei+Vg0bjTxoSUR+0hr
xT6yQ/g4bT5OH+Aj28fHT3pqJfyS+Rh1fIwnel7oZ7y8s46BlvDIg7yzFh3OV27MiUXeeWeuLpdN
cXFsR53YzhwQG1fwQZyTs5aTs2Y30cfnq856+2Y3mXBH/pvscDmHy1nelmw/xrGds9jiK67rGcfm
9QF1vWyxLjtrlR4X6xUcfmWA3qrprTp66XExP5uaQ8zPpfIe8/OpWon5hdTZ56X4+Kx8AVBLAwQU
AAIACAAAECEAxy6Ho/8KAAD4GAAAEQAAAGFzc2V0cy9zZXR1cC5odG1slVlPb9vIFb/7U0zG2YRs
KIqUJcWmRG2NNEBT7LpB3N2iWCzgETmUZk0NucOhHa0sYIEAvfXUXooeeuux1x56a3PYz7GfoB+h
7w1JiZTtLoog4XD45v39vT+jTJ/EWaTXOSdLvUpnR1N8kJTJRUhVRnGDsxgeK64ZiZZMFVyHtNRJ
75Q225KteEhvBL/NM6UpiTKpuQSyWxHrZRjzGxHxnnlxhBRasLRXRCzloe80p3qJ0GGU3XCFbLXQ
KZ+9EpJ/yUEima/JBdeXWnG2EnIx7VcER9NCr/H5s808e98rxHfwMZhnKuaqBzuTFVMLIQNvkrM4
xm/e9ggtdOZZvN4suVgsdeB73ieTOYuuFyorZRwce7E/GHiTKEszFRwnSTJJwKJeArLTdUAv+SLj
5Is31HmXzTOdOecKLHIKJotewZVIJr1bPr8WcAKPFass00sUziSaLljB4+2R0SAWRZ6ydZCk/P0E
Pi1kT2i+KoII/MfV5Juy0CJZ92qPNtuNNf44f9/WXLEYfbvAJ1BaPE1FDu5jmugsd479eMBHEfE+
cWobyWiE65H30osJ+sHeHrnguE2b6WLOrDPHP3EGI8c9HdmTysGBn78nRZaKmBiSwWjkNH9db2zv
tBx6QDg4RVWryKB6ZRHgjgFFADG1RgMgc86GN7coAIK5ZHF2G3igFhw3PIwYz8E/7thoqpiMd04U
MgXA9Iwv8Z9eLBSPtMhkAKEsV3JivjdRr8EBONE6WwUnIAFYptki29SR5yPvzB9Wwb+tTp15XvUO
WOPGsknKNcSkV+QsQmvdEey18fJmBV+0Qw1KyAVTKrulbbRosKJIMrUKTFL8zvJd31i33uxF+f59
UQN3CJu1svMT/NMYBeEOdorUuo9B9wpjBU8Tg7kel/FE8/e6t1eizHOuIgAppIrf0mCAYOv67BRd
lrsplIjGZ4yxloN8VLDjdXd0wGMwQCYpm/O0be5Jy7L5fNLEeJ5m0fUBhzEyEDIv9aaCk0noXY6M
ujlyPDg9GQzZfRAfD4eYBwcgbXl4VwgqDfdigySLymKTlRpNDWQmecNlfxQDquWma8hD+g53iRI8
pEw7oi87aDTVICpVARLzTJhK0YKDPzwAppBLwJ8GxRSP2xnfAL+lPJIESyzPHcJk6I39AXCAkrPe
PODlNgukeYDHyXjoj6LKPQG4h81TUCdDjOt14I4bk2KesDJFdVfFYgMlo8EUFo6OoYPG0McwOAQm
XKldnp++jLyTrZtdNzvDcXwyPgOqBHXcHHqxU7YfLjULllfpUbEg8xKwKjuG+y8H3sn4ASBWHvnf
QNzBBYwlRimTxia/g5Qn+hAJBw55GAhtXZtQdYBcI6MTaeZD7d4dLlYsTRs/np6ePpy66EqT+G6R
C3lYwjvJgdo2kWvlxuCxxAXWh9p2HDmCZGNSrJgJV0H8gqBQpoiQCY4nfAJ2awG1uHZnb7AHmKpK
Kar+82u+ThTMPgUpNjrb7EuoyjTT3DoZezFf2Fvjm0y3YWSKaa3leDxuR2fQjWXV8oFFliSb+35/
AD4j5icDfmA1yuuUmG4N9U9/KmdG26Npvx63pv16KsQhBh6xuCFRyooipNC6YYAjpLOHbZrOptC3
ZLOHfZbOXr25eP3l63eXr4E1fOySzNd0dm/wq8j6wH0nRcQhBeegurQ5C++UGG1D2oAL6zJtnV36
5qgZJUEV+Bppzr77+KGnOYzABLozAAFs9Q15vlMdbKfmqFnN3kitsrgkLFa8aI6VaSmI/vihJLsp
1iExJ/w9X+VpSabz2VLrPOj3/bOB649PXej6XnB64nnT/nxGClaSOFtxKcrU8HGn/dzoYVolAZzB
GK5SOjs/FDvtGxJDbPqT0RVpCfgh4sssBWCE9DH5lLBSZ6ankSKHGTJa8ug6pAlLC14Ft6oQu0Bp
SaA/VD4xYd37EowxtI8cw55QnVNcq/UjMfvx9/8k7/i//y4jSNPo/2AKA5Wks//89U9/IK/AqI8f
ajdxAsxA5x/+wlnJCJQblh6wbeEX+k3FDhcH4KtJTO2riKrlY2SZbqhg1brh5JDmqiS/FRKm3qI+
3DyKSIlcz476fQAZyzVUDZKXUBfw7qXFDSPnMlYZJL+143ie5zbpzQgEHGQLcv72DYkYyGlkHInE
ujVLt33o2bMn9W508wteXEO1sqGcy0KjjnG42eIYSmToTcC4HemreWiJ2PmmyKQdzuoDSYhHvhLx
15OYwyljZvUOwhM7sX51+esLN8dbpWWO2lvkWp2GmKShtXIYMJT8lrxV2UoAodrxB0e+eCEnDdNQ
TdqWuMgAz9/dUeqI2N7aHZVr68LNguvAAiGGnsIbtR3NCx2UzR6+Uae0HQRUi9bgy3ZAGwT8nr7e
MEcMsFtnKqCDodujyoqnYRHO4BpeQrZr99uSq/UleCuCMFsFqFxR8SJCOiiFUAet4tNPKbVhKjMZ
bfW/ejad0edf9xdOFM6sDX1GA/qMrfIJdegU16nG5QyXC1w+p89h+W2Zmf3nuH98cjah26+ir20Q
ijF+G6Lbv3j32SWm3fItg2ZXWJgs2DrdwuzaziqLefjWBb9ZFNfgkCrLms3qjdoYh8YcSKXQ0k6U
QlZQRMxTix5jftmuyZUL85sCbBD6Aogm+88CXKt++ZvPPws1gOUwmkai7eollxa4YgMBx6Mm3WAb
+uqr+teJq3vJ93QTueBPjT0cdK3zhG7Jv/5BbvAjWFGA5dsrxBEgOHLRXntjPFC9TGrTI7da3N1V
z20dRaU+B8sjHD/v7mr/wLpxTqUt1mrbvWFpycOGzZ4h0mHyGqnhvvfZjbG7DddUU7cuplAcca7a
SdmT7V16BX3psu4kRJZEffxQQKWJOTal6VzNnm4AiFalir3Fnapn13V7fwukNWllMWptb8mP3/+R
3OClV0AVJzGLdhUZxEEcMgXzF/nhzwJLAGQA09iIqzrt1s3/qtG/atzdoNKLkqyAaZ7phgU12DGt
+p5DTHsx3+usfNxjUHsVF9CB4G4M/QNbJIyQDPXzPTAiQi8BXVUcffz5CAOuIYD6DY5wEE4Lq8BG
9nodkR1QHrY6Yj3dyG1hX2HFlNPQg2IMtqgdS21P7uWA4WzB4OnA1dKDbN628RItmVwgXB514mW0
FKt5KzZ0e4TFkxVrGZGklOaqQ+oqZwFcDfbgGeLL3d0BiIG9EivLRhueIDUoWCqJRcACYUrw+8OT
C2XJJEYTbhgsbLe5H4aQr3yC5593Zka8TWDvNUj5HCyoQMC/+/H7vz23971FheyWAdTuua5t08OS
zRhUF4AnCi6NNqqBUFeY1ZmyG8U5EFY2vmqhmb6oaPFXUyDNrqkJ0E5QJqNUwLxlOkatDVDsXQpT
/OsbiNNnooBwcWVRuIiAFZI6HOAFanEXdjDUrxEl1N6x2daMGui1ZT2GoupE1el2BwwSDJprH9Xf
u/GpKi+OQ+0aA/XrJwKHs9qDExqx8LfiUomUExxVHXI6MP969kGAU3DOYzFGXa1ddA8178QX2bgp
lwu97ID2osdWZAHFEfhLEYlS1tDdj/stA1zSAfmKyZKlHYAj06vzHcunm5bgbfcV4up/2vTUoF5w
ug2uGjA1Le/Q8YbJiuUWzBFXzdwcQxHrlSGtC7uLwN9CJOZNqa+AujUNwFzuZx1SCJnZ3A3PV7b7
TSakRStVHh5sznESOm7/3ACaQt99zaKlNQ9n8w40N4dNce6i2lBZ3XLSgLu1Z3AOwwHoVk/OoF11
Ve1X/8/xX1BLAwQUAAAAAAAAECEAMoWQTSkJAAApCQAAIgADAHJlcy9taXBtYXAtaGRwaS12NC9p
Y19sYXVuY2hlci5wbmcAAACJUE5HDQoaCgAAAA1JSERSAAAASAAAAEgIBgAAAFXts0cAAAjwSURB
VHja7ZxbjF1VGcd/31p7n3PmzDCd0jNDdSptHwAD3pCAiJe0PDTGSFDxhg/YGIiGamLQ6GNLguEu
mFiiUGNBri2BUEGQYKrRBwyXgNiKDwq9UNoy0zK9nNvea30+rL07p9M2pU1nZp8ZVnKSyZnJ2Wf/
5vuv9V/f/tYnnPyQlSCrgPUgFHB8HXQVsApUQCf9ggqiYDdCRJcNBZu9TuifKSdyAQHX+d6u6uB8
L2kt8qaSFAxIDDhjW33qR3rrIzs7I+ho93LSgFaCyUN0Hdgl1doyhctT5RIPi4DTYqYifk9Q/0AK
KHpAkK0x8rzBb9jbGH3mbGhloIyAP2lAnaR3VU6/SsT82Ip8rIcQq16VFPDF4wOAAYkAI4IHGgKJ
6uuK3jm/MXo3oMeLJjkenDfKcxb1mvg3ZZFloiCqfrfgX7GYTQbZZpA6xZulFegBhj16nkfPd/j5
iqiIRaCl/O2Ac99b3N7z740QLQ0B994A5XC2VGqf6xXWxyJniNf0TYO5N8Y8HcEWA+3sAyT7QlIg
OPl30mw+WuBhWQrLE/zZHu+NRInqWFO48kP1kaePBemIe1oH9hvgtlQGP9sr+idFqpFq+mBMdHMJ
dhjoVShT0LX9GMDawAGBQYXr2vDdNs6JWIOm+4XLF9dH/ng0ucmEDzKAvlWZuyAW+7JBalbVrSpj
V5egPwPjKOikc5zJ1mag3hVYnsBNTTyCCBxsO71wuD36+sSJ2xzlgxSxaysitUg1XVXG/qoENQ3m
J+1COHkUpRmkIYW1Mfy0gjGKj0X61Mj92S3S6ZUOAdoIkYB/qzLv2/0il4oPslpdCmHpuhTMsUAN
KdwXwz0lrPGazjFywY6e078v4P8SOB4uMQV5CaKhnto/B5Bz3hTVL/Vg9kvAOhPgTJSczyJqQwN/
rkfGlB1R054zn131XE2mY9XSD1QHL+0V+TCqujbG7DBhzplpcOhY3fYKrIkxKL7fyLCruMsENI8i
0xlJ6v0VVUXfEfzTUVitHDN3OKBP4TkL2wxaUhT0CoAlWVzkgJyC8XCJAXnFYrbO4OjpjKISsNPA
CxZjFEmFT70BFQlMxKwMy5ru6h0a9MIir8omg7S7yOecikh6zSApiiAfrJYHF+TKMquyn9rtZMgi
vSmwTWYPnFxG2wVJQHvAIukZZHkukye7oshUomzjWQ/madYMAerBHaoVIVWpZgm3w4yinnCSaIZB
6gChx3TSU2H3u01+UwanDeyTAMm8D+jwixzINohfTWBEoEl3JLbNVEVPApzl4b4m3NWEYYXRTPj2
fYkFSA2Bg8A3E3iyDivawYPkspPZDCi/mAH2CFSBG1rwWAM+n4Y9UbuAspuWuTLK3OuowMcdPNiE
O5shBTEqxVrtpm0xkQzUQYE6cFUCT9XhmiREUp5mkdkKaKLsRgX6gVuasL4BF7vwXjLNsiuMHcnT
uaMCFzp4pAG3NmFuh+zMbAbUKbv9Eh59Xp3AUw34ThJ808FpkF0hDW2+5I8KzFO4owkPN+CTLpjM
dAplV2jHH2UGc6/AZxw82oAbW3BaBs9MwQ0UfkuUL/n7ssi5th1M5pVJkNxky65b9oyHfNGIwHyF
1U14oAEfzWTnJsk7dQ2gTtm1M9ktTYMTv74V8uejk5AJ7TpAnbIby6qiftCGZ+vBbKanWG5dCagT
lCdA6tPwmGoyIrbrhmZ7uX4FJ3B/DLeXYKuB0/XUPqrqOkApYb4ZUPiHhRvL8Fcboqc2CQ86uwZQ
Xo8yT+FtgZ+X4fcxtDIz6Zicp8BRt8jptEw3D8TwixL814R9WlmPUTs3GwA5QoHBgMJLFm4qwZ8j
6MnklDL5tQNRkeU0V4MJvK0Mv4tDynauht+nU/RdoiLKqQ8wCo/GcFsJ/mNCFPVPQ7VJVCQ5RVnU
vGrg5go8E4U5ZqrkVEhAudEb0FBceUMZ1sQhJzSg4yVz07m1mVY59QKRwoYIbi3DJgNzNLyKULwV
TbecNhm4pQJPRhB3mL2iVLZF0xE1czSsSLeU4NelIK0iyGlaAWm2RehXeCgze6/YAGugwLWQ0VTB
iYDtAtf2wG9jKBVQTtMGyGdbhbszszeg4xvPoo8plZilOKvTex1TnjDrtrrrTkCdxxJm3dDDQRx5
mMUZ23LhDelRVGcZnJ7sLJhTBTHNQ4A2ZfCc+ncStBERqr9mEyAf7lljMA3w6tmVszPXZ9mFhfWR
3QbZYkQ4z6PxLJKaAc71YRFRZadvV7YdAgSHzoo5gz7vCQdgF/jxM6kzdeS1k0MeLnJ4FVELL5zJ
9kZ+AsrA+MkWgceagsxXZFkaHuvaGQzIEqpvlzhY5KEtiOAf71y08knaK8hwY/TZ/er/pyJmeYKv
6cyNorzxQJ/CNQleBDPm/e5KlcezX7tDgPIDZAItK3KjCHK2x1/XDhvJmRhFEeFR9YoEPuHwRkQs
3F7bs2ffxkxecJRTz+tBLqnU/t5n5GLvNf1JhWhtHAosZ8K51bxIa7fAV1K4q4mLRexBr5uTZu8F
i9jSpqNbzBGABPzuUu0stbwk0IeiP6tg7o1D/iamu4+F52V+X0vhl018VjqTtoVPD9dHXp54LFyO
YpqsgNtaHvxC1egfPBJZVXd3CXtHKVRV9Gk4qddNI8km5D4NsvphC6eCiUVkv9dvLWyOPHLcxgL5
yNs0bKvWvlhRHopE+q3XdLPBrClhnrPhGGPmvAs7iWtmAg1hiliSwtUJer7DpSKRQ1sNZfmZzZGH
33NriomQtvbO/UjF2Xt6jLlYVUHVbTXwokVeM8h2QepZOZwWSE4KVBhvbnKhQxd5EBErIjTVv9pA
rzmzMfrCCTc3mSi3dWCX9NRWKPyoLLK4nLUmcKokoAVuj0MMxgIqQlug6XU7yOrNzeqdS9nSPOn2
OBMnboB/Mdg3VNHLvMiXU/QihQVlJLIF1ZhTaKEO2BEpL8bIE/vL7ScWj429O/HeThpQ/nfZh7lx
cAsrY+X6gpYwpOqqRUy2i9imeN2dtOPtw7xd71QG4E9547e8yZt2oXdclzWnm7Qmb0eDxfir6Ome
k24T+H9ES7GR1cV9oAAAAABJRU5ErkJgglBLAwQUAAAAAAAAECEA4oZMHusFAADrBQAAIgADAHJl
cy9taXBtYXAtbWRwaS12NC9pY19sYXVuY2hlci5wbmcAAACJUE5HDQoaCgAAAA1JSERSAAAAMAAA
ADAIAwAAAGDcCbUAAAKXUExURQAAAP8AAP8AAKoAAP8AANQKFdUNFNANFMoNE8wKFAAAANsKFOgI
FPEIFPQIE/QIFPQIE/MIFOgKFN0JEtcAE+UKFPUJFOYJFMYODtoJEuoJFK4MFEMRFBMUFAYVFAUV
FBEUFD4RFKkMFOsJFNkHFukAFeUJFHUOFG0PFOcJE+EPD38AAP8AAN8KFHUPFGwPFOAJFNgLFvQJ
FLAMFAgVFKUMFNYJEuEIEjkSFPgJFeMJE78AAFUAAO4IFA8UFO8JFKoAKsEKFPIIFPMIFMgPF38O
FNQKFcQJE/IIFMoPFu4IEw4UFO8JFLYAJOIKFDYSFPYJFeQJFNcKFKoMFJ8MFNkIFN8JFGMPFOAI
FN8PD+cJE+kJFNwLF+wJFKUMFJ8MFOwJFNkGEskNDeUJFOcJFdgIFekJFfMJFPUIFPUIFPMJFOsJ
FN8HE38AANcHF9kKFdgHF/QIFP0JFc0LFZ8NFIoOFJ4NFMsLFfsJFfcJFf8JFv4JFQgVFAkVFBQU
FBcUFAoVFAcVFP8JFQEVFBYUFBUUFAYVFPgJFfwJFQsVFMQLFZQNFAQVFPkIFA4UFIEOFE0RFAMV
FBAUFBgUFLILFPcIFI8OFCETFAUVFKcMFPAIFPEIFNYKFGUQFA0UFKkMFN4JFOkJFPMIFLULFD0S
FBEUFOIJFOQJFIsOFB0UFOUJFNIKFF8QFOEJFOoJFLAMFDgSFBIUFOcJFIUOFBoUFPUIFM4KFFkQ
FAsUFO8IFA8UFOgJFL8LFDwSFNUKFGMQFI8NFCAUFLgLFEASFOMJFNgKFGkPFO4IFO0JFJUNFCMT
FL0LFEURFNwJFG4PFLEMFPoIFJgNFCcTFA4VFIgOFFYQFJMNFMELFfoJFfYJFPkJFYAOFH8OFBWm
pQwAAABxdFJOUwACBAMBGCUmJxkBMpLU9P711pY2DZj9nxIcz/77/f7+/fv91iIM0vr62hECA5n6
+qUu/vz+/DiU+/6gBAPX/eAGGfb8If4wGvci2f3iB5j7/qQz/Pw9ofqtENngFtf9/d4pE6OqPJ3d
+vvfoUAGIC8h5EArWwAAApJJREFUSMdjYIAARiYGvICJGYXLAuKysrFzYAXs7JxcQCNZEOoZGRi4
eXj5+AtxAQFBIWGwMph6EVGxouKSUpygrLyiUlwCpoORQVKqSlpGVk4eJ5BTUFSqUlaB6GBhVFWr
Vq+pravHA+oaGjUqNLUYtYEadBh0m/SaW+rr8IL6+mb9JgMGYOAwMxgaGZu0tNYRAK31babtZkDj
mRjMO2Rq6+sIgvpOC0srBmsGBhvbYtk6YkCrXZe9A9APjk4lcvXEaKiX73Z2AWrgKCyVJ05Dj2uv
GzYNrS2kaWjta6hvJUFDa1//hImTJhOvoaV2ytRp02dgcRcuDQ0zZ82eM3de5+RWYjXMn71g4aLF
S2YsnUy0hmXLl81auGJlW0sLsRpWrVq2qnD1mk4Ud+HXsGrV2nWL1m/o2VhPtIZVy5fN3rR5C8Jd
BDWA3LV12/bGHa1Ea1i1fO26nYs37GolWsOqtbtn79nbR7SGZcsL9+1v6Gwh1tNrd647cHAG0Z5e
u7Dw0OEZSMkQv4YjywuPHutrIDbilq89fuLkqRmt9cQmvt2Fp8+0TSI28c3cOevsuUm19cQm79rz
Fy5emlFXT3QWvXzlas+uyaQUArtq61tIK2bqSSyXCBVk7h5lxBaV15w9gRqYvcoViCuMva/7+ALr
Uwa/G4oNRFjRssM/IBBY3DMzBN0MbqwnWKHUTZ4RciMUWKEAUViTRnM9ATtaJjeHN0WAqixgpRgZ
VaHf1tmKr1Js7ZwRXhkdA64UgXWpSmxVnIWd/IweHGCGvLd/fFNCIqKiTkq+daur+7YrDnDn2vXK
ihRW5KYAQ2paekYvTpCZlZ2D1HQA+YOBITcv3w0HyC/wRW2cgKLPGn/zR0cHygAAqumoOrFhXbsA
AAAASUVORK5CYIJQSwMEFAAAAAAAABAhAO2Y+xmxDAAAsQwAACMAAAByZXMvbWlwbWFwLXhoZHBp
LXY0L2ljX2xhdW5jaGVyLnBuZ4lQTkcNChoKAAAADUlIRFIAAABgAAAAYAgGAAAA4ph3OAAADHhJ
REFUeNrtnWuMXVUVx39rn3NfM9O503n0bSUxKEFMRCXqBxWMYNBEiApKokGjxoABYlQCPkKJGChV
IgES8AWa+KBQLZEiiqb4QTSiBkJjVJQIrUA7M+087+ucs5cf1rmd2yczZZjeOffuZJKZm/Tc0/Vf
+78ee6+1oLtO6pLFfqDaM+WVePZJXgqozP3eNm8lCsFOCDtFa5v/X10EJZOX8RIOEIGk9fOpvjUj
kdZXJUkwlKiGcQYEHoKXMBgX1dFVldG90rIDFIJ0Z/glASBF3TUF/2y5vLK3kX93Inqe97xVhVME
ynkkUxxUR1GYdvCcg8dF9ZE4CH+7dnbvvhYgvCyQnmShWt9Eem9h5DXO+csT5ZIe59YKUAMaqnh7
sM8Y7TgH5EQopoKrqo455f4oSO5YO3tgVxOIw1lhUQDYCeE5EO9kpO/0EtcG6JUlcX1T6okgKYEW
1GgpEqROdhAQoAjkFBXQOviKIAEEZRGqqg2Uu0Zz9etPn54eb8pq0QBoPnB3afBtRdz3+sS9flw9
CnG/EniQpx38OYBdATwnML4QNWjz5YBBhQ0KZ3g4K4HTvAEyJSQewmERKqr/rXv57Pr66G/muxNk
vsLfUxj5ZNHpXQ7JTaFxvxLEgvwqhPtC+EsA+9OnBUCg2fFDFUhSaSpQVjgzgQ/F8IEYehSdEJJe
JAyAivovbqiNf2s+IMhLfHEoEO8uDV+1UuTbk6qagB9Ugj8EcGMB/hiYhvTonB+qZHM1hZUAFYEI
eFMC1zTgPTFMCF6AIRE3pv6GV1XHv9aU4YIBaKL3bGHwE0NBcPekauwh6FPktjx8Mw+xwAqde6lO
Wi79mU69jc81DIgGqId4WCS3z/urN9bGtxzPJsjxvJ3nS0NvySN/jEBicH2KfKkIP8jBUBoIdJrg
jwYEwJjAB2O4owYJqELSJxJOwvkbK6MPH4uO3DH8fP7H2h7gxw4JGyBN4d+dg1UdqvVHWz79Wa2w
PYTLixBadsDVVTXn/T3P960ZAfS6o8jbHQ1UAa+lxldWinvtFBoPKe62vGn+iNpe0q7sD1kRJpuf
h/CNPJQVV4Gk7NzqKIk2C/hNR2EcOUp6QV8oDmx0Ev4jgXxJkb8EyIdLUMi4kV2MFQCTAvdU4fwY
poSkAE5F3rS6MvrEVggubiGPQ3bAo6b9qgRXrRApevCxIDcWzOC6rvDn5bLmFDYXDAgHWhKRSP3V
ABcdi4IU5ByIxxjsV/jYlKqWFferAB4LzNvpcv78bEIv8JSD+0PoV4IJVQ2QC8dKg+sFEm2Ru2vR
/gCgUeI9ZedGIvAJuPtyXc0/ERCKCttyUBHLGPeLlGrIBYfL/eAvZzf/scr5gJYUfTqAxwMLsnxX
rgsCoATscvCkg5IiEaiovPdwM9oEQNKtIcBba4oUwD3u4IB00EnLIscHFbFMQR5cTVUU3vwYG0ot
sjYArrM/9D+9q0cQOaVhAMlTQZd6Xi4IuwJIQCLz79dsXFHd2OqBOoBN6Sd5dLWDFR6IBXku1f4u
CCfuDe0RqIqdjxSQQBusOwKAg/FA4gcLdpLla1hKOehK/4QBCIAJMSoKwecExLnh1OmRI+IApxpK
iyGJyd7VhqVeCYc6MKIaHjMVoYexTVf4r8jO0JfKBXXXEhvqtlqScmcXgJMk/IiDOZSO2J6unV5k
WuD9MVwamfdQxdxg6QKwNNofA2sV7qzCD6rwGrWTJp9hWmo7CmoAUwLvi+GXFbi2PudPBxmkpbY1
wpOpwK9pwAMVO9yYFLt9lyVaaluFCtIAZkzgVLUTpu/W4NUpLWlGaKmtd7Sk2l5NDfSFkdHS5xsG
wGQGaMktl5d0WGq8AGyqw/YqnGuXoQ7SUheAJaClJKWl0z38qGr3cNaltMQypKVlt3ubtFQBZgQ+
EsGOClzRMHCmUlqSLgBLQ0v7xQ7Bb6jDtiq8IzaqaiwTWlr2bnWYBnBjAm9M4Kc1uLVmN9XGpf1z
S5mIa5q0NJumLz4ewYNV+ExkO2Fa2jd2yFRg6VIhjwv0K9xcg/uq8LbEPovakJYymXBs0tK4WDXL
vVXYUoeVLbTkugAsDS1NC9SBTzdgRxU+GRlNzbYJLWU+5R600NKQwi01M9RnprQUn2Ra6pgjyRCz
AfvFXNVtVbixDitScE7WAVBHnQk3XdKpVPMva8CDFbgkMkqaZelpqSMP5ZtxwZjAGrV0xo+r8AYP
e2Vpr+N09K2IEDPQBwTeGcPPq2YjyulVfOkCsDS01KwDLgHDurTXMTsagDilo2GFvzu4pAifKBk1
LRUIHXnzvHlVcFBhn8DNBfhhzi7RDqe1EEu1AzoKAMW4vQ9wCvfnYEse/uVgQC19sdRlWB0DQALk
sHTE3wK4OQ+/CaGgpvUxJ6cGLuwEulFMww8I3FCA7+bsMGcgvSl7Mrt6hVmnm16sUOKBlG7+7szN
LLdJ1WeYVboJU7rZ5WBLER4MDYjhVPDtUnIbZpVupgRuKsB3cnZzoh3oJtMAxEAPZlQfDmFzHp4M
jGoG2rjIPMwC3TSDqX+kdPNAaLVt7UY3mQKgSTdltUzmt/NwR96i2AGd2xXtvsLlSjcloKTwSEo3
fw0skFq5zHpahMuVbv7t4JaCRbMsE7pZtgBoSjn9CjWB2/Nwew72uuVFN8sSgBhrmtqj8PsQbsrD
n9L2OYO6fAXf9gAkWK58SOHZlG62htacuUk3GWkM3n50E2MargLfz5mHsyelG9FsCL4tAVAsY1lW
eCiELQX4QwC9ajshi80Cw3YSfrMY7ytFuDVnO2BQ5/pWZHG1DQA+pZ3toaWKV6hFs1nvU9eWVZID
HdQYti0P5TupO2O3W0oXgC4Ah9hCbeHiLjqLI2A50t84AgCTe+AONGxakCuShvrdtlkn7EwkaUzT
YzGMixVQHQc4O5X5IV0TY9iboLMOm4+yYQnvSGYRgFhgvVraXMHVUO9y+kKr0juA6+0Puacyug/k
uZx1TtQzkm7LypezYqygPAQNAVXdJzO5Z48AANCdEFxv/PR4SWxU01m+fa5vLLelmOa/PYYIfEkE
hSfWsnd2q03TOASAg72jRfXXAlIR5DRvpTwV6RrkhRreKjbq6kwPFUFzJt1HAC5qYXV3ePzTmy89
POl1IgCXU/RDhmDXDiwUAIELY+hX1EMwrdpI1G0/3BNyLUZDFYKBqT37FbYOiMiUkHwgtlFNs123
dEHaf6q3PhbTQjIgIpHy8Kvr+55J6ccfKw5QQApeb5lRjRVcj6LXNOwgpLvmB0BF4IsNa5cQgcQK
gmxO6efYgZhYIOZGGuP/bCh3DYm4CSE5N4bLGzAqlq/vrqOvHFZv8LEIPhzBfiEeFAlm1G/bUBt9
bOtRRlkdodfXgdsETJTL/bV6blcosq6GahHcZQX4RTrGKurK+wjhj6W1Zj+qGZuk3f9nYk3OWF87
sAeb0+CPmwtKXVFZOTk5UVe9NBTEgY9A76ibYXkxox0MT5RyQqy68l0J3F0zv18hXiHiGspnN9QO
7KZlFPBxAUi3RbITwlPq47+b8vqFQZHQQ5yA3lmDKxvWr63ZWNV1sODrWKH3pRH8sGot1eoQj4jL
jatu3lgb+9lOmyeZHCtiPl4wkQ7zHPr6sLivjqsmgJQVtyO0UU1POfvSnuZs75afrKUWpCXHU0td
zVM9fKEBF0UwI6iHZJW4cMz7O9fXxi7bCeHZVoSpCwYgBSEQSP5XHLq6V9zmBlBF4wElnBS7mbYt
tHv4zYAtp3M9GjQDgm8We8SpGhfVgqwLY/hoDKu8Gdw8hCtEmFLdvK46ds1WCC56iTHn83IumyDs
7hl+f9FzV6+T9aOqGoLvV1xFkCedDazZFdjYjomMDXQeUGur/Hpv6YU3WppGpwQfgQyJuJrq/lj1
ijW18Z/MR/jzBgDmBjvv6hlZs1r91xX5VElEJlQRiEs2eUlikKogs9i3L/fwQbGKyh7L7Wja9MNX
BU0gHBAhVkjw9+73wZdfV9/3zELmyssCX+bgg58vDZ0VIleBXtArri8CqgoxioB3dqvkYJS9TIUv
TRB8OiE1BIoi5IEZ1booD8Vw67ra2O8Pl9GiA9DyUq75JS8UyqeELv8+r3qeCmd6WF9EgjBjkXOs
UENVlBcc+oSI/JaEHasaY/9K5eI2zbnxvGIAtADh0sAimftsQ2k0X3sVjrWxyIiohhmxA76gOio5
fTGZCXavZnSmVQ73gVx8skzedeB2Qri1gyaPqJmFUBchBJJFfrGD7vKjGctgn90S4kj3oDA76/+r
YyUb3Yw66AAAAABJRU5ErkJgglBLAwQUAAAAAAAAECEA4FHRL/ETAADxEwAAJAABAHJlcy9taXBt
YXAteHhoZHBpLXY0L2ljX2xhdW5jaGVyLnBuZwCJUE5HDQoaCgAAAA1JSERSAAAAkAAAAJAIBgAA
AOdG4rgAABO4SURBVHja7Z17jF1XdYe/tc+5j5mxZzyesRPbxE7AoTxLQ6IUqKMaWioVhBpoY6ig
VE1bNW2giEeLSItIoAbSJA2hiqAEpYQCKQYMpAkQFWSTJrRNQRUQAuQFsY2dxPZ4Hvbc1zl79Y+1
j2fs2p47D8/kXu8lXdm6M5p7z9nfWb+11l57b4gWLVq0aNE60mSpPljtswWQnSCbgZ1xPNqy4l5t
BiW8xP7tXnsfuB2Q7oA0InDaHspkB6QKris8UPAyLjwhfvrPRvv7V9byZG2SJyubsDZRqaqgXpfO
K3aKJYCKz6rIbpyMpi7Z23/4if3H3/udkGyG/HR6Jzmd4AjkxXsj1cH1GcnLPFwC/KqH80RYWUEo
SaAssjGbe0ym0EDxMCawS+B74uUeUb1vdfPAQ9M909Wg1xz3ED8tAVJICnD2M7Rcqu61Krwhx1/S
J26ZA5oKTZTMft+fERp+eiByAi4BygjlMJqHVZsJ+p8e90Xv3LY1R558qhgbwC/kvZYFvhgP8Ejf
Wav7Nb8C5fIekQ0emFQlN7A0yJoAotHzzHvwZCqQ9griIOkNnv2I6n5R/ewRzT56bmPsZ8c/5E8L
gHZA+nLItkGyuWf4rQ7e3SNy9qS52OKLOkD8NB1Pi5cSA585SFgukDH1KgZUAkweKEOyTIRJ1XGP
/ONIzV/7XA5OBIj8fJ9fmedFCCACfnfP6pdU1d/U6+Tiw6q07JoSAcnDB1WAnvB1DwscEBgReEqg
JsEdRWsLnjKwWmGlwrBCf0i96gK1aW6+YC2BdEAcR1QfzkTfvmbywF0KcjXIfGIjmcdFHJWsvdWh
d5ZFPpwi6WH0GHASYHkIdH7u4DsJ3J/ATxzsE5gQaISnKVr75oCKQh9wtofzPVzkYVNu/y+pPaSt
ImsLIFWRNAXq6PUfqx14zzUWizuZI0QyH3geYmOlv+fQpwfEbRlRVbUALSm+yQqFcYEdCWwvGThP
hU8sK5TCxTmihM3FC/nwagHNQMBKhQtyuDSD38rMS42FgCeA5AV0pUgyrv6esaT0e88+/MT+ucZF
Mld4HqB/5aqe8p3LRF56SKe8TgYsC9Hx9hJ8vAwPBF/aG6ApbkAMoBcmiJVpA5kBk4GEjR4ub8Eb
WxY6jItBhIGXrRBJ66qPjOW8amPzwMNzgUjmAs+Dy5cPDbUq31jm5KJDqi0xj4kCgwr/m8AHy/Ct
1DxN39SXjsAskrwJFgtNClycw1UN2JzDaEjZEiCHrB9Jm+iusZzf3Ng88PA2SLbMAiKZBTwF6OkT
1eFv9zt5ySHVloNS4R6XKdxagr+rmP4O6JSrjbY03inB4kwB3taEdzRN8lrTIFqOpA30ce+Si9cc
efKp94FrN7Bue85kZ0j7ftEz9JmB4+Ap0vF3VuFdVYNmQA3jCM/SxklZeLB7FD5chsurUAeq4WcJ
pBNo1iOyQfPsqwql51sEIgsGUFHn2VMdfseQuMsK2ZoOz1sq8MmSpZSOBapSRVsQK6q3qxXuTOEP
e+AI0DMNojHVbKVzL9lbHb5xC+Q7p8Kl+UlYoYl7e4cvLMN/Z4pm9sfFFfBUYXtq8GRxvJ7WVgIO
Crw0h0/VoBdoTnmSrF8kHdX8d8+pjWxvJ6h27QCmkOD1llQlyaxwKD64xr+pwBciPB1jLWBI4b4E
rqwaAG5aklRT1VTl5tGB9YOAziRlbqasawvke3qGr1zh3AUTaOYgyUK94dYyfKoEZ0V4Og6iVQp3
p3BteSpedeDq4AecO3uiMfn+UFpyc5Kwgrzd/f2DabP8cCqsaIbgqlfhxwlc2jNVMo/peWem+xMC
n65Z0XEs1IkEfAKaJfqCtYcP/pQwXTVbD5QIaNosX7nCycqmVTCPAre1bKl6GuHpaEuArRUrMqZT
Qbf2iSSa61WhbCSzkjA14rJ9nNWncMURVRVwOTY9sb1kRcLC9UXrTCvi2Acc3FKyCdlCysZVNUUu
e6y6YoNAfrI2WXcKMMmq2esGnKytBy1MMVI/UbIKc/Q83ZHiL1f4dAked9YxoZYk5f3iqhVJLj8V
K+4UcCLIm7z1lpAHWnck8MPEpidikbDzTTFo9ji4I4U+PTqurqbgVV4fFkLkbQFUzHft6lm5zqGb
jqgW/c144MulqQ+O1j1SVlUDaGJqwtXVUK2K/NLGnpUXiqX0STseyAE4dZf0O9ebGXlSwfp5/iux
WfUIUHcB1AP8yMEPnP0/jG/eJyDiXnmyrP2kWZg6fr1oj/TYXMp3EtgvVs2MAHVfSl8T2JkeE99K
C8DrJdNDm5kAyhVEvF7csGJQUY3m/iQ2fnVzLFQCvuusLTaA4RqqAC96klXLiqb9kwIU0ncdZcMA
yHktFA3LRo4I/NRZ40/0Pt0JUFnhZ8561YvGvxZoIrIqLyfrTyRjx3sgAWiUauekwkBmgRMl7I/u
jfLV9R7o4LHjLIDvRZwne2bbAPnErywjLjgbSbDVExOx8tz1cVBd4EmxpVZhnDWxtTerAHaeCqCd
U/HO2pIFP16xP/aU2B+PMVB3Ww48MW2cjy4PSnQd2M4gM2ZhudIjx7mlyRCCR4C6X8qOnMBReNXe
k3mtE7wpbaVr0bpXyvj/sc2sZ+OjRZsTbNGiRYCiRYCiRYCW1pKYNUaA5moeW8braXOBU7QIUEg3
aQDP8vDWphXGin7f6I0iQG0BFHbm4v0N2F6DTZnN8bSIewxHgGYB0UGBX8nh9jrcULcFdQdlatOB
aBGgU1qKleXr2D45d03CH7dM4iairEWA2r1ACd5oELi+Dl+owUW5tahkUdYiQO16o1YA6eLcILq2
YWuhClmLRbEI0IyxURrkqwX8WRPuqsGbW9aqciTKWgSoHUumydpqhZvq8LkavHCarMUgOwLUlqw1
sW7LSzL4cg0+0LBFk4fk2K1PokWATiprCVZs9MBfNuHOSXh9yyRtMspaBKhdWQOTsHUKN9fhMzV4
bpC1PMpaBKhdWatj82ivyOArNXhvw9aPj0ZZiwC1e1MSbMMlAd7VhH+btN3fJ8JZFFHWIkBtyZoP
srZB4ZaabUz5TLX34kx/BKitIHu6rP12BndMwrubBs+oTJ33EQGKNqOsjYZVm1c14I4avDrsLVg/
Q2UtAjQPWdvo4dYafLIG64Os6RkmaxGgechaDQuqfyezIPvtTQNo7AyStQjQPG+ew6rWVeDqhqX9
r8xM6hp0/0x/BGiBZC0PsvY8b/suf6wOZ4eZfrpY1iJACyxrk9j+2Ze14M4a/MW0vuxuXCUSATqN
srZcYWsDvlSDX8/svW7ry44AnUZZy5jqy/5cDT5StzNGuqkvOwK0CLJ2JDSr/UELvlaDP2laG0k3
yFoEaBFlbUTsTNnrGrCtZmd2jXR4X3YEaBHt+L7sbZO23Gigg/uyI0BLJGsTYcvAy0O29uaWTYcc
7rAGtgjQEgbZ0/uyP1KHf63Dhbm91yl92RGgp4GsNUPa/2uZpfxbG3aW6UGJAEVrU9aKvuwmttzo
G5Pwp80IULRZguSxyvVqhTUdsCF3XNX7NDAN0PQCFYW7UvhgBR50lvZHgKKd1PIwCIMKP3ZwfQW+
WrLN3Vd1wGnYEaAlMh88z4BaSn99GT5etsB5RfA6nXCUegRoCSzDDnXrUfj31E7A/n5iGz0MdthB
xhGgRZarBBhWeNjBDRU7AVvU3svpvFOwI0CLFCR7zMPUBD5ahpvLdoBNJ8lVBGgJ5apX4VspfKgM
30usV6jT5CoCtMhy5bB9GX/u4MYKfL5k3mioQ+UqArRIcpUHuWoK/FPZJGtvkCvpYLmKAC2CXFUx
UO5NYGvFjklfpuZ1MrrvtMcI0AJYcRDfkMIeB1eX4bMlyGRKrrIuvfYI0ALJVSZwawluKsMuZ16o
R7sXnAjQAshVJcjV/UGu7kmgb5pc5WfAfYgAzUGuCHK1T2zS819K1l3Y7XIVAVoAuVqmFvB8pgQ3
luHRIFf9emaBEwGaheXYli6DakXArWXYkVqMM3wGyVUEaI5yNaiwX2zu6p9LtnProNrPszP8HkWA
TiVXgFP4QsnaLR6aJld5vE0RoJnk6geJzV19I4VqB8+YR4AWSa40pOWHxNLyW0rW7DWo9rMs3qYI
0Mnkqg9rI/1qCteFfuQBtVf0OBGgk8pV0Y/8oIMPVeFrKZSiXEWA2pWrcYHrQj/yoTBjHuUqAnRS
y7DlM2WFr6fw99P6kVdEuYoAnUqupvcjX1uBr5QgiXIVAZopSPZYMDwpNlt+c9kKg53ejxwBWgS5
qmA1nG8Gufpuhy6fiQAtgQ0pPBZWe24rWdNXlKsIUNv2iRL8Q8XaLgajXEWA2k3Rq8AjDt5Ttc0K
hjSCEwGaQ/C8PNZ0IkDz9UbRTq/FDaaiRYCiRYCiRYCiRYCmTE6U1UQ7M0xPDIS0DZATaelxf7Ac
3dUZYYJN/5wAqtaMAG0O8Inmv8ishuIEyMNu6hWNqfGZIEln+6lxLrYedl52A+xsxwPliYw2DCYB
NMfOueoL80gS73NXmsecxGo1pyHmecQr4NzBdiTMA8hkaXeGTqQggvmuYbUzQFsRoK6VrgybM1w7
Nc4KuEnQJOOxoFL+pAAJqIKsZd8IqrtKhopmWAvEs71tmhStOwFqCmzw5oGKUxZKIJnqoVqrZ9eJ
Ymx3whgavIp8r2JuzBcfcKGf2gsnWhcCBFzgbT/HMM6+goDoA+fx+GiIiWcEyNyOyLeDBiLY7hOb
MnNxcXKyO1P3MvDy3PY6CmOvZQFw956MF3eSWArNuWdctekgFdA6cL7Ci3NrDY0pfXd5nzpwvg/j
O6Uyrq6g3n/zRPJ1QoAEvILb0Nj/aIb+Ty+i4T1KCq/NYibWbZZgTuHVmWXbWeCgCu4IuusZjcHv
6FRGP3MaX7wvcHtZEAV12HGMr8xgozdiI0Td4X1a2MEur21NqYuC7xVBVL8sPNIAEmnHAxWlIABf
at1+yOuhkkGqLSxC/6OWHWOdxPvfFd5nTOCyFjzHQy1AJeAmVPPM6yemhzZtARTS+WT9+PiIoLct
FxEgLz7sTS07dXgixkId731qwLkermyZwgTvk/eLuKbq189tjjwYsq/2ASoCJgXJRW+YUJ1Mbasc
zbGdua5q2iEhcZK1c82F2OevmrDWWxovRUqvkIp+YHpmPiuAAnHunNrIniZ6Y7+I0+CFxgU2Z/C2
FoxI3OKjE62Ejd3vt+ANLRgNIYmHfEAkmcR/fk1t5H612Cc/lRc7VW1AANm7Zk2V0daPKsiGOqpi
3oge4PIq3JlabNSK49IRlmLA/HIOX6wZTIEQTa38M5lp5Xnr6nv3YNNZftYeqIiFAFm3b98kIleU
BHFFnShE7zfVYVM467wUx6Yj4BkXeKaHW+q20cS0+c18QMQ14K+fUd+7m1PEPm0BFCDKd0C6bnL/
3eOqNwyKpB6yJHxwH3BbDV6a23rzCNHTW7ZGxYLm22uw3lvRMDXpygZF0hGv2zfUDn5shxWQ8zb4
mNmClDmAfT1DO5fjNo2iWQJpcR7WYeDKKtyd2kK+k+Z90ZYkWHbAAbFK8y11OMdbFh3kK+9Dkib+
0Vo5u+hTY2PjANe0MYRtZeECenXY6MKnzUsn0cf6kTSHLA2pYC9wWx3e3rQvVgtkx2Lj0qbpKZZd
HRR4Y8tinnVqKXspBM1VJMnQ8VqurzlvbGz0+SDXtPn8z2p8t0GyBfJHysPnDyR8s4SsP4xmDtLi
gLWBsHHT1jI8EE7mqwRvFD3S4nqcFla3O9dbqv6GUGluBbDyAI+DicPKqzbU9987U9Y1L4CCnCUy
BdHdFZHzxlVbYlNlR/fiGRf4ZAluK8MesS1WejhaqDr6irYwnqZ4aVCEmlgT4JaWFQnXeot/it/z
kPUhqUdHx1Re86z6/nt3QPryWTZbzElhCoh+1rvq7D7VLy0X97KD6vOQ8rli88p+hccd3JHa60Fn
T0AJ22IuDUBFmZu7FbvlN7GGsAo2V/nqzOa2nuNNrhphTELtNx8USSfVP3wk10vPbY48OBd4mM/Y
FXL2EFRWVIevrzp5S0OhgWZiO8dJju2U0acWF/3Q2RkT33W2b8+IWJ9RHr3RnCzBepgHFTYoXJBb
P8+Lc3uvFmJRN+V18hIk/SIc9vrFA6XGFc+bmDg4W9laEICCJzpaJ9hTHd5SEa7vFTlnVBUPubOC
o/hwsT1qTUt1sYxgr8CTAk/IMbPA0WYYMI95mrND++na0AjfG1oxijgn4ei8pldwgyJSUx3NkL9d
U9t/8/FjuOgATU/xBfKfLFs2PJT1vFdF/7xXpDRuIGVFXFfEPS640zLmqqKMzU++WgEYf2w85BW8
QLpchKaCRz9X8+69GxpPPRZuu8o8n9kFG7fpbvCJvsEXJj55h8KWPnG9dVVqaLEpfFFTkhhIL1wA
zdR+ogq4CuJ6BQ6r5qLcqch1Z9X33wcw13jntAJ0vDcCeLKy6lnO+Tcr8jpBXtAXnpSGajFvlmMu
Nto8xlAgSYEKQkmgoZChj4rqHd65286a3P/9Qq6ubrNAuCQATY+NwoXlRcD9G9XBi3OSV3hhk6q+
SEXW9CGkchq/SJdb4dInVVHlgIj+KMH9B97vHG4su094vD5tPJDTUIqT03yBbie4493l/qGh5a7u
1+eabHDIqrrXcxLRqgf1kaWZioQKiIq0SsguVT9SFvfzw2lj9/rx8ZHpv7sD0s0WB/lOf1Jkm8XL
qcYmxtNm77NEJdVQRlmsGGxJgDo2YYg2TyXThciookWLFi1atDPI/g/CO/l6Q4iV2gAAAABJRU5E
rkJgglBLAwQUAAAAAAAAECEAJJwl9sgaAADIGgAAJQAAAHJlcy9taXBtYXAteHh4aGRwaS12NC9p
Y19sYXVuY2hlci5wbmeJUE5HDQoaCgAAAA1JSERSAAAAwAAAAMAIBgAAAFLcbAcAABqPSURBVHja
7Z17lF31dd8/+3fOfc1DI2kkEJIQEg44hNZOHdw48QoRJHbipAm1GygkhMTGddK1qFNnhTpOHYOW
MfgBdmJsXOPYMX4u3jFgd2WRFWFiG7fFdhtMRLAJL4FA0kgzGmnu65zf7h+/39HcuRqJ0WikGe7d
37UGDfO8c87+7v3dr98Bg8FgMBgMBoPBYDAY+gSy1F+ghtcogDwAstnu2ZLGA8BmUOKbhH8NR2Hw
TiHZCqm+DAhqmNM9Le6nW2r3VJaK0RPe8m6PsYvR4WaZtS51m0rqq03lFWVkqGV2taSQAjm0Rfxj
HmlXE31iNMl3yMTE3lnud3o76EXgWeQIIYto9BKNXiVcCAB2VE7e5Jz/GVH9xRzOUXSjiqwZREgk
fIMgWGRdimpayQGvMIUisBvVZ1XkkZLI1lLiH1o2OfajzvutkAB+saSSLJbhC+TFx8YGV5yd5e43
ROQ3PfybAZFqArQU2ijt8H2FtzDLfxnklQJJCpQQytHK9qtmAo8J3Jdofs9oY+9DxTdthXTzLAqg
pwigkBSG/wzrawO15q979A88nDcskrQU6ig+fI0KiAayvCwSdsMh97tIhL2CCCRVhKpAXZVc+Z4T
/Wwzbd22fnJybDEigpygC1FIHX2YUwZOrbV+H/ijmrgzNXgGFLIOgzdj71FORFJ4IBlEpCQw5fUF
Ef105tKbTjnw4s5uZ/myJsBWSM+DDGBXdfS3RdxVVeHMhkIDzeOLcId7LcXVKt4XCwVLGr7j/shL
3K9C1pYgGRKhrrpTVa//P42xj/8aNE9ENDhutlTU7wX8swOrX11V/VBF5FdawfCzmAe4Ixl80JBQ
jldCCEzKjQFLEk7DPSuI0BZoAe3i84cxuBgV8hKkQ+Koq/6g6XnPuuauvy0URGfivOQJcBskF8Xw
taM6emVJZEtZpLZPNY+kOMTwi1hXAWqR7xMCOwR+7GC7C+/vFNgtgRCGpeX5h4B1HlYrnKpwuof1
HlZGB1YXaEQnNxsZCiIMICkCmddPPNMovfscdkx1KoklTQCFVCD78eDJJy3T/OYh3AXj6skhd112
e1AMAkPR6J9z8J0EHkzghy78/z6Z/suLhoFhSSa9Bx1ZcU/XKJzl4eczODeHTT5E9f0SIsNsRPBB
9jAqzu1T/UEzc5dtaL/4w8K2liwBihf4VHXFzw9L8uWKyMZx1YyQ0Ei3x0+BYQ0G/u0E7k7huwk8
78LFrCiUmZY/dOUCVg9dGpCOe9J9j1tAM4r4VQqvyeGCDM7P4GSFAwJNZo/oHrIhkVSVyf3q/3BD
Y+wrCx0JZKGN/+nqqouGRT4DLDuAZm5aFh4MlQos1yBx7kjhSyXYloQLNhCNvjB0K/y//MlRROw2
MBXJsNHDhRlc2g4yaVym1UCXveRlSEoIdfV/uq4x9qGFTI5lIY3/2erKy4ZdcktDlTZ416VWMmAA
KCncl8L1ZXg0gapCLb4YbwbfF2RoRDKs93BFG363Hexin3R5zGAT6sCPikv2qL9ubX33ny1UJJAF
NX5Jbqmjed6V6BZaf4XC4w4+UIH/mYbpqMH4OW/20XdkSCIRDgi8Lof3NuH1OeyV6XyvM0EWyFaK
lMbUX7e+PvZnD0PpnOki04knwEHNX1v5WytIbp9C8wyc6/i5Pv4hyxTuKMF7y7DLBTKoGb4RIRJh
nwSHeGULrmiFvKHVJYli9ai9UqS0E716w9TuLceaGMsxGH8ikD9ZW/m6Ydz9OQy0OdjUOmj8aXz7
QBk+VQ4av8JxqGcZXtZIYtI8LiFJvr4Bw8DUoSRQB/mASDru/WUbG2NfPJau8bwqileF7/PPDQ2t
GlB3u0OG2iFEzTD+UmTt26pwYzkkvqkZv2EW5NEbr1K4N4W31ELfZ0hnWraA5JA0VP2wyGe3D6z+
aYH8tnm2huZFgM2hM6dklb8eFFl/AM06e1OeUMlR4O3VoPdXxz/EElzDEVQFGaFxti2B366FkvgQ
M0ngQDJQQUqJ+lt3jY4Ox++X404AheQ8yJ6pjv7JSuf+3QTa7ix1FrInBy6vwv1pYLV5fcNckRHU
whMOLqnBcxKqh12RIDmAZiPizqxPyU0XQf7APKKAHKXxO0B3lFeeVUrc93NIs67pTQWqwFs7PH/b
7qlhHkgJvaIzPNxZD4WU1qFeOxsWScc1f8uG+p67jzYfONoIIALqE3djRaQSk17p1HEjCteU4RvR
85vxG44lEowoPObgXZXg3t0sTrmlaAn3Fzs4eZAwci0LToCCWdurqy5eLnL+hOqM2Z6cUNq8oxSq
PaMmewwLRIKVGtTEDeVAiC4p5BpoPiKyoV3L/1ymK+8LJ4EU5GqQy1lfSWqNf6rAaY2Oqo+PsudZ
gd8YCKWr1BJewwLCEQbovlyH87LQN+gQ/OrCW9v75Kw1zRefimrFz+XnzgXJFvBSq1+2XGRjPcxh
zOj0lhWuqYRR5YoZv2GBIUCisKUMk4eOS0gOfkikkkv+bpl9Nm9+BIh6Kn+S06rAn9Y17Op2Sp/l
CveWgu5fbtLHcByQE8ZmfpjAZ8ohIe6uCk2oair83o7KyEbCHrI7ZgI8ELS/VmqTvzYibmMDPej9
tSNTv74UhpnM8xuOJwlGFG4uwTYXBig7NI54yJeJVD3p2wT0gYUgwOb4O3Lknd327Qnz/HekYapz
AJvtMRw/FA53TOCzpTBF3OVw3QFFVeTy5zhlIE6LyrwJUOxiPlce/cky8vr9qhS5hzI9xPSl+GLM
+A0nIgosU/haKazKVjucroBron7EyVpfa74JYOtLNMdeKgK4+N8LhkXSTtnlCXMa305C23rAEl/D
CUKJUGz5ehqGK7scrwqoQ34rKhidNwGuBn8VOEXe0tSZTa8iM787PQGHtxgMXdK7onBPOusCTXJA
VVB5w9MjIysE8iM1xg5LgKvAbQH/juqK9Qm8uh6IdFD+VAgnNTyUzMpCg+G4EqBG6BA/4sIpIh0y
SNrgB0VG00b5tUUh56gJcHVR6ZH0ZwedVHyX/KlpOL1hh5ue/DQYThQc4ZiVv0tntT9fFvD4c6MM
mncOgKj+YjKdhM/Ag4kZvmFxUDRfv5OEDnGXi5e2gjh+ocNnHzUBcg1ndZ7T6tL/Re3/hy5oMSOB
YTEIUAGeFNguh0QB1wBU5ewnWDFSHM47ZwLEk3x1N6NDoJva0znvwWWXHQLPx19s+t+wGARIgXEH
/+Jm2mHIA5SSMFoupRvpsN+5RgABaJblFEROagduHez+luKywoSzIwoNiwchjNv/kwtzQt0KZkAE
l/qNMRF2cyZA8cUuzU8fFKG7yOOAZ90c2mwGwwkgwbNuVhWisWT5yiMlwkfuBKurzpYAS5RABsNi
y6AEeEHCieEyCzkUqR3pZ8xKgIItonJ6NwGE8Mt2xok4S4ANi0oADbNBdWbaY3HKoCivYBYnPqcI
kKsun83R54RWtJ3SbFhsJISzhBrMui6JF5YfdQQ46O1FDjvan9q1NywhEsjhc4Rs3gQ4Uo5r0sew
lKTQfGx4LgQwGHoaRgCDEcBgMAIYDEYAg8EIYDAYAQzTOFKd2WAE6HlMxG6KNf+MAH2F4ik3f9AK
J96NiT2o2wjQZxenBby9Dd+ow4VtOEAYvEpNFhkB+gFCeGznOoVPNeALDfiJGA1me7CzwQjQk0lw
IxLhlzO4Zwre04wreTL7gxsMRoCeu1BJTIgT4N0tuHcKfjOeVW+yyAjQN9HAE/YhTlf4qzp8rh5k
0W6Z3lIyGAF6Oi9IYzI8IfDrURb9cSt8fsJkkRGgn2RRkQe8rwl/U4c3ZtNbStY7MAL0jSwaEzgr
h1vq8D8asCHKIkwWGQH6RRZNSTiq7z+0Q5L8x61AjuKhbpYkGwF6/oK6KIuqwNVNuKMO52ahjNoy
WWQE6BdZlAO7BH46h6804OMNODk20UwWGQH6RhYdkPDs5Evb8PUp+M+tQA6TRUaAvpJFYwLDwLVN
uLNDFrVNFhkB+gEpYax6LMqir9bh+gasiLJITBYZAfpJFh0QeFsbvl6Ht7ahyfRT0E0WGQH6RhaN
KtzQgFvr8G/z8DFbwDEC9I0sagN7BF6Xw211+EjDFnCMAH0oiyZjn+A/teGeOlzSnpZKJouMAD2P
oiS6W0K/4JMN+HIdXpWHj5ksMgL0jSxqEUqkmzO4uw7XNGAoSiWTRUaAvpBFCaFZlgP/pQ33TU3L
oimTRUaAfpFFRFl0isInGvDFOpwZq0U51jswAvSJLGpGWfRLWUiS/3szPCt3r8kiI0C/3KxiL9kB
V7bCJtqb26GCNIXJIiNAn8iiYi95k8LNDfh8HV7pbS/ZCNBHSXLnXvKbsrCO+Set8Dk7rsUI0Fey
qDD49zbha/VACNtLNgL0nSwakyCFPl+Hz9Rho+0lGwH6TRZNEZLifx+Pa7myay/ZbroRoOdvarGX
XImy6K566CrvlVBONVlkBOgLWZQTJNCr8jBX9IlGaKjZXrIRoK9kUTFVekkb7qvDFXEveaLP95KN
AH0mi/YKDCpc0wxDduf1+XEtRoB+lkU+yKKPNmBVn+4lGwH6WRZFafT7cS/57a0QCfrpuBYjgMki
xiScTPGRZljJ/Lks7B30wwKOEcBwcC95TMJS/q2NIIv6YS/ZCGCYIYsmY5/grW24tx5Os9sv4eNi
BDD0Q5IsMRqsVvhYA+6agl/IQpQQI4ChXyJCKxrIGR7WaBin6EX5ZzAchBIMfZlCQ+CmEny8EiLC
Mg2fNwIYehIZ4ZkGgwrfSuCaCnw3CYa/XEP/wCKAoeeQR6kzqvCMg/dV4Ksp5BIaZDm9afxGAJM7
5FHutAX+qgR/WYbtLnh80RAVehlGgD6WOxVCA+wfEvhgBb6dwJCGSJDRe3rfCGA4WMkZVdjh4Noy
3FIKEWA0yp2sj66HEaDP5M6wggp8qQQfLcO/uBAFqtpfhm8E6LMkt0zQ9f87gQ+VYWsKNQ1JbtbD
Sa4RwOQOKxReELi2Al8shfr+itjYyvr8GhkBeljuDAFO4Y4SfDDKnRENVZ/cLpMRoFflTil6/R8k
8OEy/G0aNP5on8sdI0AfyJ1ihPljFfhcKUxyLje5YwTodbkzCKQKd5bghjI8FptZIyZ3jAC9LHfS
KHcedfDhCtxbgor2/giDEaDP5Y5GuTMhoaz56XI4CGt5nNg0uWME6ElkwABQVvh6Grz+I7G6s9zk
jhGgl+VOQpA2jzm4rhoIkJrcMQL0g9wZ0XCEyV+W4ZNl2BWbWSZ3jAA9LXdqhJGF+9Og9b+fhHme
FSZ3jAD9IHced3BDBe6Od2rU5I4RoFfRuY9bF/iLMtwU5c5ynY4KBiNAT8udBxO4rgIPJUH7m9wx
AvS03Cn2cZ92YYTh1hR8PJfH5I4RoGflTk7w8C0JjawbS/BcH+3jGgH6WO4U+7jfTOC6Mnw37b99
XCNAn6FzH/c5B9eUw4JKv+7jGgH6TO4Uiyi3lEKF56kod6omd4wAvS53lmuo6nyoDA/GfVxbUDEC
9J3caQmsNLljBOh1uTNEOGH51lLw+k+a3DEC9Do693G/F+XO/SZ3jAD9IndWaBhbuL4Cny+F6U07
fsQI0PNyp9jHvS3u4z5u+7hGgH6SO484+HBcUKnYaWtGgF6XO8U+7ng8be0zpbCba/u4RoCeljsZ
obpTUrgnhY+U4dHE9nGNAH0gdxxB2vyzg2ur8I00EMH2cY0APe/5l8XJtI+W4dMlGHMmd4wAfaL3
K8DWJJy49pDJHSNAP8FFD//nleDtbUHFCNCXEmggvm9yxwjQt1LI0LtR3mAwAhgMRgCDwQhgMBgB
DAYjgMFgBDAY+pUAoiqH+5zVxg1LBcWI+uHMeN4E8CKtw33TkNrpZYalYfyDGpaTZrXHw9jwEQnw
QPw3Ef9Y1sUiJaz/rY1zMWL3wLBIECATOEnDWmqnPSrhGQvi/bYjRYIjSyBxrcN5+ZPM/RuWAAE8
YScjOYwi0flEgM1R4rfb+VNTqkgg04yws8F3fdBgWCQJdOrstih5UDGPd6qauUaAQKb24POZMp4i
FAQTwmGup2vIA2w02LCYSICf9LMWZVxdFUWeAth1mBTBHSa0qIJ8lu3jTvSpUviYLwjQAtYprNHw
vuUBhsVARnhg4E/EZyx02KGmiDSVSa2XnwS48DCFyyPlAG5L+Kb/WxZmRgBgpQ/Ma4k1EwwnHi46
4g0+vLVmGrOvBFv957XsGFMQOZoI0Jk1q3ffnC2FdsDrc+sHGBYvAW4KvNaHNdVspn7XcrDeb8t0
QYijJUCw7bJ/aL9q1vlDHOEphudm02demgwynEgo4VSON2SzluMlB0SSbx4pAT4iAQS8gqybHHui
rfyoioh25AFN4HQPP5PDlMkgwwmWPw1gkx5qfwqaQDLp/YGM/H9FAvj5RACARCBLhK/VpCMqRAam
wAWZySDDiSdAXeBXs9ADaM903PmgiKrw4Gn1sedvg2TLfAlw+8HEQe+aUqVbBu0XOD+DjT5EBJNB
hhOBnFD9uSALeYCbqdslAREvdwJceCyzQBdBriCn1Me+31D9f4PhZ+WFDGoDJytc2A5HgZsMMhxv
JMA+gV/K4F/nMMVM+VMCN6E6TqnxtQ6+zI8AHTIod8qnSoL4rm8+IHBpBustChhOADzhBO53tMPD
xLuDw7CIeOXWdfv379Zgu3qsBMgVpNnMbh33uqeMuM6eQBNY5+GKGAVsPMJwvJASTuS+OIPX5bC/
y4AF3AFVTXN3k4LcPsd84ogo6qibmBgX1RuHBekMKwnhaPDfbYcXtc9IYDhOiW8jOtt3tWatPGbL
RFxTuWdNe+c/Au6iOUzqzFW25wqi5daNE173lsP3+c6wVFJ4bzOw1KpChuNBgAMC/60V5HajS24L
SFOVxPH+o/25L4kYBdz6ycmxHL12SMRph50nwKSEzvCVTdgrduScYWGlz5jAxW34nXaQQenMvCAf
EUnq8JW1U7u/F7V/Pkfbnhs0fK08CumK6qrv10TOnkLzTsWjhMWEy6twXxqeh2vnaRqOteqzH3il
h7vqUGXm5EGs/Cgw2UB/akN9bAdh9mdOQmTOlcsYBeRfQcurvlOCBjskw24CNzTgbH8oUw2GozX+
BjAMfLIZntMwy/RxPiziWvC+0+pjzwNOjkKFH1XpXiDfCumpzbG/3+f1phUiqe9w8sWo9DDwhTqc
4UNSbCQwzNf4a8AtdTgrDzI76ZY+SLpH/YOn1nd/XMOn/VHa9NEhSiH3LOvLpWr9oZq4V+/vkkLF
k9KfF7ikBj92h07sGQxzMf4v1OHnctjT5UgVfDm8O55p9ppTGuPPHI30mVcE6JBCuoHtdfV6SYZO
pXBIUrwfWOvhqzES7JGwuW8wvFTCu1+mPf9hjF8d+JqIq6NvXdsYf/popc+8CRBJ4LdCura1Z9uU
cnlFRFyYHtXuytAaD3dOwRsz2Bm3dmxkwjCbFEliteeVOdxdh5+dxfjj12YjIul47t9/Wn3snq2Q
yjy3c+fds7oF/MNQOiub+scrklpjtXNvrEMWS1AH2dWSIIfenIX//1YSpFAVO1fIMO31W4R88eI2
fLoRVm4nZzF+hfZqcaUx1S+d2hh7p0K66RjU9TGP7mhgX7a9NnrtqLj37FVt+/Ax6UhWEMLD5e5P
YUsFHnVhoq8ccwYjQ39qfU+YJFjrQ5Prd9qhy9uexTsrtEdFSuNe71rT2P0fo9l4OQbzWZDZtaLx
8Hxt1bUrxb1nTH3uwbmun58TkuF9Ep6ufnM5hLxl8WQvj3WR+0HquGgLkxIG2y7O4L+2wvEm49Fz
ykz7AshWi0v3eH/XmsbuC5meR9NjJeEx42pgM6Svyqbu/8NSjUHk/GjMvnNko1hkSIHz87DOhsAT
DnbHv6QUX5RNlfYOXHwrhicnJUT+N+Xw4SZc3g73fb8ceu81evjlSDKBfvEfGrsvPTv2pGQBhMOC
2tlWSM+D7Pnqysuq4m4GqRxAM9cl5TR6gEGCB/iRC09evzeFbS6QpKzhGb3pLN7A5NLS9e7Fv8L0
g8RbQCMa/SYfNrkuiPP8GgnhZjFGD3kZSWoCB9S//5T62PuuAnc1qCyQGSy4oy1ygmdqo68dQP56
QNzZe9TnkbGu6w9EY0I8EKXRIw7+LoXvJPCkC3NFWUeVIIndDrUosWRQ3AtPOKuzkLIJIc/b4MPp
DW/I4DV5eN5yU8IySxEhun6eAvkyJG2iu1v4d6yr77m7aHTJAvpAOU4XJBHIH1+5ctmyurtxALms
BTQIp0tI1+/Vjgs2oNPhcHuUR9scPOvgBQk5w7hMk8CwNDy/j/fuJA17uqdqmN85I57bMxIbRUWC
e7hyuIe8BMkyEfar/n3dyztOa+56olAXxytqLThug6SYx95RW31hin5wQOT0CVXi+MQhROiMCo4g
gcod/e08XsAG1ktYilGgFGVtokG65oQyeItpy3WHMbp4yqZbLiIN1bEMPrCmvvtjndL6eMq243VR
hNChy59gxciyWvJugT+qigzsi0SQ6Rxp1ovqZ6kgmPEvXRLkHXmacOTGp4YjOL1Ej99SReEL+337
qk3NiaeKCWQ5jsVBOUEX5uB89s7yqjNJeRfKZYMiA1MKTbTo4jmZw2sy6bP0E+Ej3DslTA1QgmRI
hClVFeWuXPz1a+p7vnu8vf4JJ0B3NIhEOCNJ9NIc+b2qyGkCTKnSns6hZK6EMCzpqKAdwVwSSAZF
cOF+jznltpbo59bWxx6OX++uBracoJaQLMIFcTGs5QAvsnqIGr8q6JtV+eWKyEklgXaIDGTT+lAX
5QUbjloGdSrWFKSCUI43fEp1UlQfFCd/o8h9J0/teqHDLpAT3AuVRbxQ7gFwnWFuYnh4NMur52Tq
X69wrqr8lAirB0Rig0TwqEmgJYyis5oDdVVyGEf5sUO/5YRvCvrwqvqe7Z3ymFDXX5QhAFkCHuNg
ntQ90bd3ZGS5ZpVT6z5/BcqZCVLLhVc4ZTi3VsCSQdwMFC/aTjzbcpF2VWRbin86cekzwwde3Dmb
89sMuVhKN5MM8XFPqZpx9xS2hnuaXLXEiniy1AkBSPQWQDjqerN5jSVfCIr3ybOAYwsGg8FgMBgM
BoPBYDAYjgH/H1q8YQrHcF/oAAAAAElFTkSuQmCCUEsDBBQAAAAAAAAQIQBJ0N9wyAYAAMgGAAAO
AAAAcmVzb3VyY2VzLmFyc2MCAAwAyAYAAAEAAAABABwAAAEAAAYAAAAAAAAAAAEAADQAAAAAAAAA
AAAAACUAAABKAAAAcAAAAJcAAAC/AAAAIiJyZXMvbWlwbWFwLW1kcGktdjQvaWNfbGF1bmNoZXIu
cG5nACIicmVzL21pcG1hcC1oZHBpLXY0L2ljX2xhdW5jaGVyLnBuZwAjI3Jlcy9taXBtYXAteGhk
cGktdjQvaWNfbGF1bmNoZXIucG5nACQkcmVzL21pcG1hcC14eGhkcGktdjQvaWNfbGF1bmNoZXIu
cG5nACUlcmVzL21pcG1hcC14eHhoZHBpLXY0L2ljX2xhdW5jaGVyLnBuZwAJCUNpbmVWZXJzZQAA
AAIgAbwFAAB/AAAAZQB1AC4AbgBlAHQAcwB0AHIAZQBhAG0AaQBuAGcALgBjAGkAbgBlAHYAZQBy
AHMAZQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACABAAAFAAAAfAEAAAQAAAAA
AAAAAQAcAFwAAAAFAAAAAAAAAAABAAAwAAAAAAAAAAAAAAAHAAAAEAAAABgAAAAhAAAABARhdHRy
AAYGbWlwbWFwAAUFY29sb3IABgZzdHJpbmcABQVzdHlsZQAAAAABABwAWAAAAAQAAAAAAAAAAAEA
ACwAAAAAAAAAAAAAAA4AAAATAAAAHgAAAAsLaWNfbGF1bmNoZXIAAgJiZwAICGFwcF9uYW1lAAgI
QXBwVGhlbWUAAAAAAgIQABAAAAABAAAAAAAAAAICEAAUAAAAAgAAAAEAAAAAAQAAAQJUAGgAAAAC
AAAAAQAAAFgAAABAAAAAAAAAAAAAAAAAAKAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAAAAAAACAAAAwAAAAABAlQAaAAAAAIAAAABAAAAWAAA
AEAAAAAAAAAAAAAAAAAA8AAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAACAAAAAAAAAAIAAADAQAAAAECVABoAAAAAgAAAAEAAABYAAAAQAAAAAAAAAAA
AAAAAABAAQAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAIAAAAAAAAAAgAAAMCAAAAAQJUAGgAAAACAAAAAQAAAFgAAABAAAAAAAAAAAAAAAAAAOABAAAA
AAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAAAAAAA
CAAAAwMAAAABAlQAaAAAAAIAAAABAAAAWAAAAEAAAAAAAAAAAAAAAAAAgAIAAAAAAAAAAAQAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAAAAAAAAIAAADBAAAAAIC
EAAUAAAAAwAAAAEAAAAAAAAAAQJUAGgAAAADAAAAAQAAAFgAAABAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAABAAAA
CAAAHSASDf8CAhAAFAAAAAQAAAABAAAAAAAAAAECVABoAAAABAAAAAEAAABYAAAAQAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAIAAAAAgAAAAgAAAMFAAAAAgIQABQAAAAFAAAAAQAAAAAAAAABAlQAsAAAAAUAAAABAAAAWAAA
AEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAEAABAAMAAAAuAgMBBgAAAFQAAQEIAAABAAADfzMEAQEIAAAdIBIN/zQEAQEI
AAAdAAAA/zUEAQEIAAAdFAnl/1EEAQEIAAAdIBIN/1IEAQEIAAAdIBIN/1BLAwQUAAIACAAAECEA
CzOAyxkpAAAwUwAACwAAAGNsYXNzZXMuZGV4lXwLYJxVlf+538zk1bSZTNImmTbNJA3tpLR59UHa
pKVpmj7zoklTSFraSfK1+ehkZjozaVNLeapVF7GIIioirqDo6gr7xxUVBG1VdsUVXVZxRRd23RVX
VFBxYWW3/985987kS1pYafr7zr3nnvs6995zz/lmkjF7qqBx1Roa/vLzv77p0n/70svxsyt+O/Kd
tviv596y5qtf/UFjP1GCiKYGVwfI/Du4m+hmpfkR4NocomEuyCNaCrKlkOj7oOm5RCWgr+PxdBvR
vgUoayLaCuwA9gOHgCPAKeCZZqI5q4nmAauAtcA6oA3oBLYDvcBuYC8wBIwAbwOuA94N3AXcB3wB
+BLwFeAbwHeBnwD/BvwKoDVE5cASYAjYD0QAGxgHokAcSAHHgWuBm4B3An8BnAHuAO4CPgF8GXgO
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
OdBPSy5y9BHJWbmx0ByO9qkS0mxNAv5YqAB0hH2jxnyyoO9c1i/9ABIxiX6r2D8OFWJ9XZEQViMb
O816cxUolp2jsjvnL2e+F3s/zX4vNnulpL43W/+mRvkuhqzTrUrek+qzcVOv9uEycXOGf/oN+Le8
Af+2N+Df8Qb8j87i83e33f/GTT7z3TH+fl0avGtnyd0yS67fyN05i7/H8O+dxd9r+A8YfuazEv6+
0iML9PeTmO4z9Nys/p+alX92Vv4Fk/eaPH8/76UF+rt3TK819HpDX51V31s2M++flV80Kx+elV89
K6/M9xmZlhs639AMOg31GtpuPmvpxI+m+l5WEt9rmSKjuxyJbLR8Zq03GpkOI9MpP9NroMz3zHTb
HYZebfo4KN+LVKTf4yjxNTWda2ixqYv43dCgfi9k5lCFHPfokXSlnHVL0p2GXi3yIcPn7/945fO7
TpmrJWkts9bIbJQS/V1RS+aW0c1cQ8uzc83ostP8+FxpKzvvYZG72uQPmn4t+caoClEg1OHE7EE7
mbLbY2PJuDPWQLlLGrc0NTc3kidcN0j+8OVO3dXj6XQidfn6hob65fSMFT40GRtNO/FYuO6kcyh8
3ImNxY/XHzgwemx7PH6kLmmnJ5Ox1lnsDU2txyLJUGLDoUg0ZbdmmghNohEuiGwY3l+fijqjdv1o
JBoNj8VHJyfsWLr+6KSdPNFvR+3RdDzZjpJlx5wxO76srq4+FZ+wpwczVXdSdx2qnqpPRCZT9tjS
pUjasTFOTdUn7cjYif50JG1vbD5V14qhR6o3bEjUnUxsiLROKyKRqE9EIyec2OFwpO7UqeFlnFu2
YplhcoobB5WWmU4k0g5S++sPxZOdkdHx6UHZdSezM4mMjXUeQ6LLSaXtmJ0M2ysmV6STk3bdKfyE
6+iBGapNJ0+weqsvronwsiU8IDu5rK5+NBpJpbjV+tF4LB1xYqnwsnFnbMyOQUsnR6PxlN0nsuG6
VqOiplNv2vREfCwS/fNa7mbRWQ1H46MRnkX9eCQ1vnTpjCxUvmxJw7KLcZfVnRxHX/HkifqRyOgR
d6OnIAu9Qp2nDK9RVIa4Y0nditAYdlBsMpSIJO3QZCyUspPH7OT05q4ntYIUntjeDZGE0zBhk2oi
X3N9Y30zqfXkwd4m1UY5bU7MSW+kBW1pJx21N4aHr27bf2ldW4POkrWxlfLbd2/bfKAF/6iofSxp
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
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPgPAAAAAAAArwUAAAAAAAAahwlxpwUA
AKMFAABlAwAALAAAACgAAAADAQAAIAAAAKj2S6XX+0XomnAUblstpTSjvNnuIjfwYUMxrxj+xAXy
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
giNvVWPMUxD1LTpu6uWbD0W08vWP1oEJdsZJ7hkh/IWHd4rXpeI3+13kxLdlbg31VdFBZmKA7j5v
IXwZdYHZJLJxhRyzPmwmMclGJDdStm4p+gLHaxFiB3idpptrF0B4JBktQ1kOWE/V28tVbwfp7eUC
AwEAAWoEAAAAAAAAd2VyQgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAD4DwAAAAAAAEFQSyBTaWcgQmxvY2sgNDJQSwECFwMUAAIACAAAECEA8ryCCz4EAAAkDAAAEwAA
AAAAAAAAACAAtoEAAAAAQW5kcm9pZE1hbmlmZXN0LnhtbFBLAQIXAxQAAgAIAAAQIQDHLoej/woA
APgYAAARAAAAAAAAAAAAIAC2gW8EAABhc3NldHMvc2V0dXAuaHRtbFBLAQIXAxQAAAAAAAAQIQAy
hZBNKQkAACkJAAAiAAAAAAAAAAAAIAC2gZ0PAAByZXMvbWlwbWFwLWhkcGktdjQvaWNfbGF1bmNo
ZXIucG5nUEsBAhcDFAAAAAAAABAhAOKGTB7rBQAA6wUAACIAAAAAAAAAAAAgALaBCRkAAHJlcy9t
aXBtYXAtbWRwaS12NC9pY19sYXVuY2hlci5wbmdQSwECFwMUAAAAAAAAECEA7Zj7GbEMAACxDAAA
IwAAAAAAAAAAACAAtoE3HwAAcmVzL21pcG1hcC14aGRwaS12NC9pY19sYXVuY2hlci5wbmdQSwEC
FwMUAAAAAAAAECEA4FHRL/ETAADxEwAAJAAAAAAAAAAAACAAtoEpLAAAcmVzL21pcG1hcC14eGhk
cGktdjQvaWNfbGF1bmNoZXIucG5nUEsBAhcDFAAAAAAAABAhACScJfbIGgAAyBoAACUAAAAAAAAA
AAAgALaBXUAAAHJlcy9taXBtYXAteHh4aGRwaS12NC9pY19sYXVuY2hlci5wbmdQSwECFwMUAAAA
AAAAECEASdDfcMgGAADIBgAADgAAAAAAAAAAACAAtoFoWwAAcmVzb3VyY2VzLmFyc2NQSwECFwMU
AAIACAAAECEACzOAyxkpAAAwUwAACwAAAAAAAAAAACAAtoFcYgAAY2xhc3Nlcy5kZXhQSwECFAAU
AAAICAAAECEAccv4njkCAAANBAAAFAAAAAAAAAAAAAAAAACeiwAATUVUQS1JTkYvQ0lORVZFUlMu
U0ZQSwECFAAUAAAICAAAECEAdNKSgDEEAADIBAAAFQAAAAAAAAAAAAAAAAAJjgAATUVUQS1JTkYv
Q0lORVZFUlMuUlNBUEsBAhQAFAAACAgAABAhAOziuDXnAQAAjgMAABQAAAAAAAAAAAAAAAAAbZIA
AE1FVEEtSU5GL01BTklGRVNULk1GUEsFBgAAAAAMAAwAUgMAAACwAAAAAA==
CINEVERSE_B64_EOF

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
