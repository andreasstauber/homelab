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
und committen.

## 2. Mailversand prüfen

Die Konfiguration übernimmt Absender und Empfänger der bisherigen Mail.
Den Versand erkennt das Skript selbst (`MAIL_COMMAND="auto"`: msmtp, sonst
sendmail). Nur wenn die alte Routine anders verschickt (z. B. ein eigenes
msmtp-Konto `msmtp -a <konto>` oder Python/curl), `MAIL_COMMAND` in
`system/etc/pi-maintenance.conf` entsprechend setzen. Prüfen:

```bash
ssh pi "grep -nE 'msmtp|sendmail|mail |smtp' <altes-skript>"
```

## 3. Deploy (Nutzer führt sudo-Befehle selbst aus)

```bash
ssh pi "cd ~/homelab && git pull --ff-only"
# auf dem Pi:
sudo ~/homelab/scripts/install-maintenance.sh
sudo pi-maintenance --dry-run --no-mail   # Prüfungen, keine Mail
sudo pi-maintenance --dry-run             # Testmail "… (DRY-RUN): stauberpi"
sudo pi-maintenance                       # echter Lauf mit Mail
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
