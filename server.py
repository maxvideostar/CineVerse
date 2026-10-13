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
