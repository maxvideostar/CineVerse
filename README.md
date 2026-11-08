# CineVerse

**Server media personal** cu suport Chromecast, streaming live TV, și transcodare hardware.

## Funcționalități

- 🎬 **Redare filme/seriale** cu subtitluri, selectare audio, rezumat și poster TMDB
- 📺 **Live TV** — canale IPTV cu EPG
- 📱 **PWA** — instalabil pe Android, Android TV, iOS
- 🎯 **Chromecast** — CAF direct din browser Chrome, pychromecast din PWA/Android TV
- ⚡ **Transcodare hardware** VAAPI (Intel/AMD) sau software fallback
- 🖼️ **Preview seek bar** — miniaturi la hover pe bara de progres
- 👥 **Multi-utilizator** cu autentificare și permisiuni per utilizator
- 🔒 **HTTPS** cu Let's Encrypt (opțional)

## Cerințe

- Ubuntu 22.04+ (sau Debian 12+)
- Python 3.10+
- FFmpeg cu suport VAAPI (pentru transcodare hardware)
- Domeniu DNS propriu (pentru HTTPS și Chromecast)
- Port 80/443 deschis

## Instalare rapidă

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/maxvideostar/CineVerse/main/outputs/cineverse-install.sh)
```

Instalatorul:
1. Instalează dependențele (Python, FFmpeg, Nginx)
2. Creează serviciul systemd `cineverse`
3. Configurează Nginx reverse proxy
4. Pornește aplicația pe portul 8000

## Configurare post-instalare

Editează `/opt/cineverse/server.py` și modifică:

```python
SECRET_KEY = "schimba-asta-cu-ceva-random"  # cheie sesiune
DOMAIN = "exemplu.ro"                         # domeniul tău
```

Repornește serviciul:
```bash
systemctl restart cineverse
```

## Structura proiectului

```
CineVerse/
├── server.py          # Backend FastAPI
├── static/
│   ├── index.html     # Frontend (SPA)
│   └── cast-receiver.html  # Receiver Chromecast personalizat
├── build.sh           # Script asamblare installer
├── outputs/
│   └── cineverse-install.sh  # Installer all-in-one (generat)
└── LICENSE            # GPL v3
```

## Chromecast

CineVerse folosește o arhitectură hibridă:

| Context | Metodă | Comportament |
|---------|--------|--------------|
| Browser Chrome | Cast Application Framework (CAF) | Control direct, fără delay |
| PWA / Android TV | pychromecast (server-side) | Compatibil cu toate contextele |

App ID receiver personalizat: `BEE3563A` (înregistrat la `testcam.go.ro/cast-receiver.html`)

## Licență

[GNU General Public License v3](LICENSE) — Copyright © 2024-2026 Cristian (maxvideostar)
