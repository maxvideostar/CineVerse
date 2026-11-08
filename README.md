# CineVerse

**Self-hosted personal media server** with Chromecast support, live TV streaming, and hardware transcoding.

## Features

- 🎬 **Movies & TV shows** with subtitles, audio track selection, TMDB metadata and posters
- 📺 **Live TV** — IPTV channels with EPG
- 📱 **PWA** — installable on Android, Android TV, iOS
- 🎯 **Chromecast** — CAF direct from Chrome browser, pychromecast from PWA/Android TV
- ⚡ **Hardware transcoding** via VAAPI (Intel/AMD) with software fallback
- 🖼️ **Seek bar preview** — thumbnail preview on hover
- 👥 **Multi-user** with authentication and per-user permissions
- 🔒 **HTTPS** with Let's Encrypt (optional)

## Requirements

- Ubuntu 22.04+ (or Debian 12+)
- Python 3.10+
- FFmpeg with VAAPI support (for hardware transcoding)
- Own DNS domain (for HTTPS and Chromecast)
- Ports 80/443 open

## Quick Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/maxvideostar/CineVerse/main/outputs/cineverse-install.sh)
```

The installer will:
1. Install dependencies (Python, FFmpeg, Nginx)
2. Create the `cineverse` systemd service
3. Configure Nginx as a reverse proxy
4. Start the app on port 8000

## Post-install Configuration

Edit `/opt/cineverse/server.py` and update:

```python
SECRET_KEY = "change-this-to-something-random"  # session key
DOMAIN = "example.com"                            # your domain
```

Restart the service:
```bash
systemctl restart cineverse
```

## Project Structure

```
CineVerse/
├── server.py          # FastAPI backend
├── static/
│   ├── index.html     # Frontend (SPA)
│   └── cast-receiver.html  # Custom Chromecast receiver
├── build.sh           # Installer assembly script
├── outputs/
│   └── cineverse-install.sh  # All-in-one installer (generated)
└── LICENSE            # GPL v3
```

## Chromecast

CineVerse uses a hybrid architecture:

| Context | Method | Behavior |
|---------|--------|----------|
| Chrome browser | Cast Application Framework (CAF) | Direct control, no delay |
| PWA / Android TV | pychromecast (server-side) | Works in all contexts |

Custom receiver App ID: `BEE3563A` (registered at `testcam.go.ro/cast-receiver.html`)

## License

[GNU General Public License v3](LICENSE) — Copyright © 2024-2026 Cristian (maxvideostar)
