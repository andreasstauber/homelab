# Runbook: Wöchentliche Wartung einrichten bzw. aktualisieren

## Vorbedingungen

- Repo auf dem Pi unter `~/homelab` (Deploy-Key, nur lesend)
- `docker buildx` vorhanden (Paket `docker-buildx-plugin`) für die Update-Meldungen
- `dig` für den DNS-Healthcheck (Paket `dnsutils`)
- Paketsystem in Ordnung (`docs/runbooks/dpkg-unterbrochen.md`)

## 1. Alte Routine finden (lesend)

Auf dem Pi läuft bereits eine Wartung (samstags 04:00, Mail „Raspberry Pi
Wartung …“). Sie muss gefunden, ins Repo gesichert und abgeschaltet werden,
sonst laufen beide.

```bash
ssh pi "systemctl list-timers --all"
ssh pi "crontab -l; sudo -n crontab -l"
ssh pi "ls -la /etc/cron.d /etc/cron.weekly"
```

Gefundene Unit/Skript-Dateien nach `system/` kopieren (`scp pi:/etc/… system/…`)
und committen. Daraus übernehmen: wie die Mail verschickt wird (msmtp, sendmail,
mail …) -> `MAIL_COMMAND` in `system/etc/pi-maintenance.conf`.

## 2. Konfiguration im Repo vervollständigen

`system/etc/pi-maintenance.conf`: alle `TODO` (MAIL_TO, MAIL_COMMAND,
REPO_SERVICES_DIR). Commit `wartung: Konfiguration vervollständigt`, Push.

## 3. Deploy (Nutzer führt sudo-Befehle selbst aus)

```bash
ssh pi "cd ~/homelab && git pull --ff-only"
# auf dem Pi:
sudo ~/homelab/scripts/install-maintenance.sh
sudo pi-maintenance --dry-run --no-mail
sudo pi-maintenance                     # echter Lauf mit Mail
```

## 4. Umschalten (nach OK)

```bash
ssh pi "sudo systemctl disable --now <alte-routine>.timer"
ssh pi "sudo systemctl enable --now pi-maintenance.timer"
ssh pi "systemctl list-timers pi-maintenance.timer"
```

## Rückgängig machen

```bash
ssh pi "sudo systemctl disable --now pi-maintenance.timer"
ssh pi "sudo systemctl enable --now <alte-routine>.timer"
```
Vom Installer überschriebene Dateien liegen als `*.bak-<datum>` daneben.
