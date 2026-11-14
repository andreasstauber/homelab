#!/usr/bin/env bash
# Installiert die Wartung aus dem Repo auf dem Pi (CLAUDE.md §4 Deploy).
# Braucht volles sudo -> wird vom Nutzer selbst ausgeführt (CLAUDE.md §7):
#   cd ~/homelab && git pull --ff-only && sudo scripts/install-maintenance.sh
# Aktiviert den Timer NICHT – das ist ein bewusster eigener Schritt.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Bitte mit sudo ausführen: sudo scripts/install-maintenance.sh" >&2
    exit 1
fi
repo=$(cd "$(dirname "$0")/.." && pwd)
stamp=$(date +%Y%m%d-%H%M%S)

# Abweichende Zieldateien sichern statt still überschreiben
install_file() {
    local mode=$1 src=$2 dst=$3
    if [ -e "$dst" ] && cmp -s "$src" "$dst"; then
        echo "Unverändert: $dst"
        return
    fi
    if [ -e "$dst" ]; then
        cp -a "$dst" "$dst.bak-$stamp"
        echo "Gesichert:   $dst -> $dst.bak-$stamp"
    fi
    install -m "$mode" "$src" "$dst"
    echo "Installiert: $dst"
}

if grep -q '<empfaenger@example.com>\|<benutzername>' "$repo/system/etc/pi-maintenance.conf"; then
    echo "WARNUNG: system/etc/pi-maintenance.conf enthält noch Platzhalter (TODO)." >&2
fi

install_file 0755 "$repo/scripts/pi-maintenance.sh"                          /usr/local/sbin/pi-maintenance
install_file 0644 "$repo/system/etc/pi-maintenance.conf"                     /etc/pi-maintenance.conf
install_file 0644 "$repo/system/etc/systemd/system/pi-maintenance.service"   /etc/systemd/system/pi-maintenance.service
install_file 0644 "$repo/system/etc/systemd/system/pi-maintenance.timer"     /etc/systemd/system/pi-maintenance.timer

systemctl daemon-reload
echo
echo "Fertig. Testlauf ohne Änderungen:  sudo pi-maintenance --dry-run --no-mail"
echo "Timer-Status:                      systemctl list-timers pi-maintenance.timer"
