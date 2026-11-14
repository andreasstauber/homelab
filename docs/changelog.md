# Changelog

## 2026-11-14

- repo: Struktur nach CLAUDE.md angelegt (CLAUDE.md, scripts/, system/, services/, docs/).
- wartung: Neues Wartungsskript `scripts/pi-maintenance.sh` v2.0.0 mit systemd-Timer (Sa 04:00).
  - repariert unterbrochene dpkg-Läufe selbst (Auslöser: Lauf vom 14.11.2026 mit „dpkg was interrupted“)
  - apt upgrade automatisch, Container-Updates nur gemeldet (statt automatisch, Fehler vom 22.08.2026 mit `/data/compose/1/docker-compose.yml` entfällt)
  - Gesundheitscheck (Speicher, RAM, Temperatur, Unterspannung, fehlgeschlagene Units, Container-Status), Status pro Schritt, Exitcode 1 bei Fehler
  - v2.1.0: Mail an dieselbe Adresse wie bisher, Versand automatisch über msmtp/sendmail; fehlgeschlagener Versand = Exitcode 1
  - **noch nicht auf dem Pi installiert**, siehe `docs/runbooks/wartung-einrichten.md`
