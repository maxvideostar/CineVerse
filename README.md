# CineVerse by NetStreaming

Platformă self-hosted de streaming media, concepută pentru rețele locale și servere dedicate.

## Funcționalități

- **Bibliotecă media** — filme și seriale cu metadate automate din TMDB (poster, descriere, rating, genuri)
- **Player HLS** — transcodare hardware (VAAPI/NVENC) prin FFmpeg, cu suport audio AAC/EAC3/DD+
- **Subtitrări** — descărcare automată din OpenSubtitles în română, sincronizare offset
- **TV Live** — suport canale IPTV
- **Google Cast** — redare pe Chromecast din browser
- **Autentificare** — utilizatori cu parole, 2FA (TOTP), sesiuni multiple
- **Admin panel** — scanare bibliotecă, gestionare utilizatori, setări server, restart servicii
- **PWA** — instalabil pe Android/iOS, aplicație Android nativă inclusă (`.apk`)
- **Interfață în română**

## Stack tehnic

| Component | Tehnologie |
|-----------|-----------|
| Backend | Python 3 · FastAPI · SQLite |
| Frontend | HTML/CSS/JS vanilla (fără framework) |
| Transcodare | FFmpeg · VAAPI (Intel/AMD) · NVENC (NVIDIA) |
| HLS | hls.js |
| Metadate | TMDB API |
| Subtitrări | OpenSubtitles API |

## Instalare

Descarcă și rulează installer-ul all-in-one (generat cu `build.sh`):

```bash
bash cineverse-install.sh
```

Installer-ul instalează automat dependențele (Python, FFmpeg, etc.), creează serviciul systemd și pornește serverul.

Accesează interfața la: `http://IP-SERVER:8000`

## Cerințe

- Linux (Debian/Ubuntu recomandat)
- Python 3.10+
- FFmpeg cu suport VAAPI sau NVENC (pentru transcodare hardware)
- Cheie API TMDB (gratuit la [themoviedb.org](https://www.themoviedb.org/settings/api))
- Cheie API OpenSubtitles (opțional, pentru subtitrări automate)

## Build installer

```bash
bash build.sh
# generează: outputs/cineverse-install.sh
```

## Licență

Proiect privat — [NetStreaming](https://netstreaming.eu)
