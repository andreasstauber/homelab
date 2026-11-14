# Runbook: „dpkg was interrupted“

**Symptom:** Wartungsmail `FEHLGESCHLAGEN`, im Protokoll:
`E: dpkg was interrupted, you must manually run 'dpkg --configure -a' to correct the problem.`

Ab Skript v2.0.0 wird das automatisch repariert (Status WARNUNG). Dieses
Runbook gilt, wenn die automatische Reparatur fehlschlägt.

## 1. Lesen (ohne Rückfrage erlaubt)

```bash
ssh pi "ps aux | grep -E '[a]pt|[d]pkg'"        # läuft noch etwas?
ssh pi "tail -n 30 /var/log/dpkg.log"           # welches Paket war dran?
ssh pi "df -h /"                                 # SD-Karte voll?
ssh pi "vcgencmd get_throttled"                  # 0x0 = keine Unterspannung
ssh pi "journalctl --list-boots | tail -n 5"     # unerwarteter Neustart?
```

## 2. Reparieren (nach OK)

```bash
ssh pi "sudo apt-get -f install"                 # erlaubt (§7)
# dpkg --configure -a braucht volles sudo -> Nutzer führt selbst aus:
sudo dpkg --configure -a
```

Scheitert das an einem Paket: Ausgabe sichern und das Paket gezielt prüfen.
Nichts deinstallieren ohne Rückfrage.

## 3. Prüfen

```bash
ssh pi "sudo apt-get update && apt list --upgradable"
sudo pi-maintenance --dry-run --no-mail
```

## Ursachen vorbeugen

- Netzteil: offizielles 27-W-Netzteil für den Pi 5 (`get_throttled` muss `0x0` sein)
- Updates nie abbrechen; der Service nutzt `KillMode=process`, damit ein Stop
  kein laufendes dpkg beendet
- Kein Neustart während der Wartung (Sa 04:00)
