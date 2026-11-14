# CLAUDE.md – Homelab Raspberry Pi

Diese Datei beschreibt, wie Claude Code den Raspberry Pi wartet und neue Services installiert.
Claude läuft auf dem **Mac** und erreicht den Pi ausschließlich per **SSH**. Dieses Repo ist die einzige Quelle der Wahrheit (Single Source of Truth).

---

## 1. Umgebung

| Komponente | Wert |
|---|---|
| Steuer-Rechner | MacBook (Claude Code CLI, Repo lokal unter `~/homelab`) |
| Zielsystem | Raspberry Pi 5 `<RAM-Größe>`, Hostname `stauberpi` |
| Betriebssystem | Raspberry Pi OS 64-Bit (Debian 12 Bookworm), Paketquellen: Debian, Raspberry Pi, Docker |
| SSH-Alias | `pi` (definiert in `~/.ssh/config` auf dem Mac) |
| IP im Heimnetz | `<192.168.x.x>` (fest per DHCP-Reservierung im UniFi) |
| Benutzer auf dem Pi | `<benutzername>` |
| Repo auf dem Pi | `~/homelab` (nur lesend geklont über GitHub-Deploy-Key) |
| GitHub-Repo | `github.com/andreasstauber/homelab` (privat) |
| Netzwerk | Nur Heimnetz, **keine** Portfreigaben ins Internet. Fernzugriff nur über UniFi-VPN. |

## 2. Laufende Services

> Pflege diese Tabelle bei jeder Änderung.

| Service | Art | Pfad im Repo | Port(s) | Zweck |
|---|---|---|---|---|
| `homeassistant` | Docker Compose (Host-Datei `/opt/compose/homeassistant/compose.yaml`) | – noch nicht im Repo | 8123 | Hausautomation |
| `pihole` | Portainer-Stack (`/data/compose/1/` im Portainer-Container) | – noch nicht im Repo | 53, `<Web-Port>` | DNS-Filter, DNS für das UniFi-LAN |
| `portainer` | `<Einzelcontainer?>` | – noch nicht im Repo | `<Port>` | Container-Verwaltung |
| `pi-maintenance` | systemd-Timer (Sa 04:00) | `scripts/`, `system/etc/` | – | Wöchentliche Wartung, siehe §11 |

> Ist-Aufnahme der Container steht noch aus (`docs/runbooks/ist-aufnahme.md`). Bis dahin sind die Angaben zu pihole/portainer unbestätigt.

## 3. Repo-Struktur

```
homelab/
├── CLAUDE.md              # diese Datei
├── services/<name>/       # je Service: docker-compose.yml, .env.example, README.md
├── system/                # Systemdateien vom Pi (z. B. /etc/…), 1:1-Kopien
├── scripts/               # Wartungs- und Deploy-Skripte
└── docs/
    ├── changelog.md       # jede Änderung mit Datum, kurz
    └── runbooks/          # Anleitungen für Wiederherstellung/Störungen
```

## 4. Arbeitsweise (verbindlich)

1. **Erst lesen, dann ändern.** Vor jeder Änderung den Ist-Zustand prüfen, z. B. `ssh pi "docker ps"`, `ssh pi "systemctl --failed"`, `ssh pi "df -h"`.
2. **Plan vorlegen.** Vor jeder Änderung kurz beschreiben: was, warum, welche Befehle, wie rückgängig machen. Erst nach meinem OK ausführen.
3. **Änderungen nur über das Repo:**
   - Dateien lokal im Mac-Repo bearbeiten → `git commit` → `git push`.
   - Deploy auf den Pi: `ssh pi "cd ~/homelab && git pull --ff-only"` und dann den betroffenen Service neu starten, z. B. `ssh pi "cd ~/homelab/services/<name> && docker compose up -d"`.
   - **Keine** direkten Dateiänderungen auf dem Pi (kein `nano`/`sed` auf dem Pi). Ausnahme: Notfall – dann sofort ins Repo zurückholen und committen.
4. **Systemdateien** (unter `/etc/…`) werden in `system/` gespiegelt. Vor einer Änderung die aktuelle Version vom Pi holen (`scp pi:/etc/… system/…`), im Repo ändern, dann zurückkopieren.
5. **Commit-Nachrichten** auf Deutsch, im Format `<bereich>: <was>`, z. B. `pihole: Update auf 2026.11`.
6. **Changelog:** Jede Änderung mit Datum in `docs/changelog.md` eintragen.
7. **Verifizieren:** Nach jeder Änderung prüfen, ob der Service läuft (Status, Logs, Port erreichbar) und das Ergebnis berichten.

## 5. Harte Regeln – nie ohne ausdrückliche Rückfrage

- Kein `reboot`, `shutdown`, kein Neustart des SSH-Dienstes.
- Keine Änderungen an SSH-, Firewall- oder Netzwerkkonfiguration (Gefahr des Aussperrens).
- Kein `apt full-upgrade` / `dist-upgrade`, kein Wechsel der Distribution.
- Nichts löschen: keine Volumes, Datenbanken, Backups (`docker volume rm`, `rm -rf`, `docker system prune -a`).
- Keine Ports ins Internet öffnen, keine Tunnel-Dienste (z. B. Cloudflare Tunnel, ngrok) einrichten.
- Keine Secrets ins Repo: Passwörter/Tokens nur in `.env` auf dem Pi (in `.gitignore`), im Repo nur `.env.example`.
- Kein `git push --force`.

## 6. Erlaubt ohne Rückfrage (nur lesend)

- `ssh pi "<befehl>"` für: `uptime`, `df -h`, `free -h`, `docker ps`, `docker compose ps`, `docker logs --tail 200 <c>`, `systemctl status <s>`, `journalctl -u <s> -n 200`, `apt list --upgradable`, `vcgencmd measure_temp`.
- `git status`, `git diff`, `git log` im Repo.

## 7. Sudo

Sudo ohne Passwort ist auf dem Pi nur für folgende Befehle erlaubt (`/etc/sudoers.d/claude`):
`systemctl`, `apt`, `apt-get`, `journalctl`.
Alles andere mit sudo: Befehl nennen, ich führe ihn selbst aus.

## 8. Neuen Service installieren – Ablauf

1. Anforderungen klären (Zweck, Ports, Datenpfade, Ressourcenbedarf auf dem Pi, ARM64-Image vorhanden?).
2. Port-Konflikte prüfen: `ssh pi "sudo ss -tulpn"`.
3. Ordner `services/<name>/` anlegen mit `docker-compose.yml`, `.env.example`, `README.md` (Zweck, Ports, Update-Weg, Backup-Hinweise).
4. Images mit fester Version taggen (kein `latest`), `restart: unless-stopped`.
5. Commit, Push, Deploy (siehe Abschnitt 4), verifizieren.
6. Tabelle in Abschnitt 2 und `docs/changelog.md` aktualisieren.

## 9. Routine-Wartung

Auf Anfrage („Wartung“) in dieser Reihenfolge:
1. Gesundheitscheck: Speicher, RAM, Temperatur, fehlgeschlagene Units, Container-Status.
2. Verfügbare Updates auflisten (`apt list --upgradable`, neue Image-Versionen der Services).
3. Bericht mit Empfehlung → nach OK: `sudo apt update && sudo apt upgrade -y`, Images in Compose-Dateien hochziehen, deployen, prüfen.
4. Changelog-Eintrag, Commit, Push.

## 10. Backup

- Vor größeren Eingriffen erinnern: Image-Backup der SD/SSD erstellen.
- Daten-Volumes der Services: `<Backup-Ziel/Methode eintragen, z. B. NAS>`.

## 11. Automatische Wartung (Timer)

- `pi-maintenance.timer` läuft **samstags 04:00** und schickt einen Bericht per Mail (Betreff `OK` / `WARNUNG` / `FEHLGESCHLAGEN`).
- **Automatisch:** Gesundheitscheck, Reparatur unterbrochener dpkg-Läufe, `apt update` + `apt upgrade`, Healthchecks.
- **Nur Meldung:** neue Container-Images/-Versionen, zurückgehaltene Pakete, nötiger Neustart. Container-Updates laufen ausschließlich über das Repo (§4, §9) nach OK.
- Dateien: `scripts/pi-maintenance.sh`, `system/etc/pi-maintenance.conf`, `system/etc/systemd/system/pi-maintenance.{service,timer}`.
- Deploy: `ssh pi "cd ~/homelab && git pull --ff-only"`, danach führt der Nutzer `sudo scripts/install-maintenance.sh` selbst aus (§7).
- Protokolle auf dem Pi: `/var/log/pi-maintenance/`, `journalctl -u pi-maintenance -n 200`.
- Störungen: `docs/runbooks/`.

## 12. Cloud-Sitzungen

Claude-Code-Sitzungen in der Cloud (claude.ai/code) haben **keinen** SSH-Zugriff auf den Pi. Dort nur Repo-Arbeit (Dateien, Commits auf einem Branch); alles, was den Pi berührt, läuft über den Mac.
