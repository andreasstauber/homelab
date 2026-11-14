#!/usr/bin/env bash
# =============================================================================
# Wöchentliche Raspberry-Pi-Wartung (systemd-Timer, siehe system/etc/systemd/)
#
# Automatisch:
#   - Gesundheitscheck: Speicher, RAM, Temperatur/Unterspannung,
#     fehlgeschlagene Units, Container-Status
#   - unterbrochene dpkg-Installationen reparieren
#   - apt update + apt upgrade (kein full-upgrade, kein Neustart)
#   - Healthchecks (HTTP, DNS)
# Nur melden (keine Änderung):
#   - neue Container-Images bzw. -Versionen -> Update per Repo-Commit nach OK
#   - zurückgehaltene Pakete, nötiger Neustart
#
# Jeder Schritt bekommt OK / WARNUNG / FEHLER. Bei einem FEHLER: Exitcode 1
# und Mail-Betreff "FEHLGESCHLAGEN".
#
# Aufruf:  pi-maintenance [--dry-run] [--no-mail]
# Konfig:  /etc/pi-maintenance.conf (Repo: system/etc/pi-maintenance.conf)
# =============================================================================
set -uo pipefail

VERSION="2.0.0"
CONFIG_FILE="${PI_MAINT_CONFIG:-/etc/pi-maintenance.conf}"
DRY_RUN=0
NO_MAIL=0

usage() {
    cat <<EOF
Aufruf: $(basename "$0") [--dry-run] [--no-mail]

  -n, --dry-run   Nichts verändern: kein dpkg-Reparaturlauf, kein apt upgrade.
                  Prüfungen und Update-Meldungen laufen trotzdem.
      --no-mail   Keine Mail verschicken.
  -h, --help      Diese Hilfe.

Konfiguration: $CONFIG_FILE
EOF
}

for arg in "$@"; do
    case "$arg" in
        -n|--dry-run) DRY_RUN=1 ;;
        --no-mail)    NO_MAIL=1 ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "Unbekannte Option: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

# --- Standardwerte (Konfigurationsdatei überschreibt sie) ---------------------
MAIL_TO=""
MAIL_FROM=""
MAIL_COMMAND="/usr/sbin/sendmail -t"
LOG_DIR="/var/log/pi-maintenance"
LOG_KEEP_DAYS=90
MIN_FREE_MB=2048
MIN_AVAIL_RAM_MB=300
MAX_TEMP_C=75
APT_LOCK_TIMEOUT=600
REPO_SERVICES_DIR=""
CHECK_CONTAINER_UPDATES=1
declare -A WATCH_TAGS=()
HTTP_CHECKS=()
DNS_CHECKS=()

CONFIG_LOADED=0
if [ -r "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
    CONFIG_LOADED=1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Bitte als root ausführen (sudo)." >&2
    exit 2
fi

# --- Nur ein Lauf gleichzeitig -------------------------------------------------
exec 9>/run/pi-maintenance.lock
if ! flock -n 9; then
    echo "Wartung läuft bereits – Abbruch." >&2
    exit 1
fi

# --- Protokoll: Terminal/Journal + Datei ----------------------------------------
HOST="$(hostname)"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d_%H%M%S).log"
exec 3>&1 4>&2
exec > >(tee -a "$LOG_FILE") 2>&1
TEE_PID=$!

log()     { printf '%s\n' "$*"; }
section() { printf '\n### %s\n' "$*"; }

# Verändernde Befehle – im Dry-Run nur anzeigen.
run() {
    log "+ $*"
    if (( DRY_RUN )); then
        return 0
    fi
    "$@"
}

# --- Statusverwaltung ----------------------------------------------------------
STEP_STATES=()
STEP_NAMES=()
STEP_NOTES=()
OVERALL=0          # 0 = OK, 1 = WARNUNG, 2 = FEHLER

record() {
    local state=$1 name=$2 note=${3:-}
    STEP_STATES+=("$state")
    STEP_NAMES+=("$name")
    STEP_NOTES+=("$note")
    case "$state" in
        WARNUNG) (( OVERALL < 1 )) && OVERALL=1 ;;
        FEHLER)  OVERALL=2 ;;
    esac
    log ">> [$state] $name${note:+ – $note}"
}

docker_available() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# =============================================================================
# 1. Gesundheitscheck
# =============================================================================

step_health() {
    section "Gesundheitscheck"
    if (( ! CONFIG_LOADED )); then
        record WARNUNG "Konfiguration" "$CONFIG_FILE nicht gefunden – Standardwerte aktiv"
    fi

    local free_mb avail_mb temp throttled failed
    free_mb=$(df -Pm / | awk 'NR==2 {print $4}')
    if [ -n "$free_mb" ] && (( free_mb < MIN_FREE_MB )); then
        record WARNUNG "Speicherplatz" "nur ${free_mb} MB frei auf /"
    else
        record OK "Speicherplatz" "${free_mb:-?} MB frei auf /"
    fi

    avail_mb=$(free -m | awk '/^Mem:/ {print $7}')
    if [ -n "$avail_mb" ] && (( avail_mb < MIN_AVAIL_RAM_MB )); then
        record WARNUNG "RAM" "nur ${avail_mb} MB verfügbar"
    else
        record OK "RAM" "${avail_mb:-?} MB verfügbar"
    fi

    if command -v vcgencmd >/dev/null 2>&1; then
        temp=$(vcgencmd measure_temp 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?')
        if [ -n "$temp" ] && (( ${temp%.*} >= MAX_TEMP_C )); then
            record WARNUNG "Temperatur" "${temp} °C"
        else
            record OK "Temperatur" "${temp:-?} °C"
        fi
        # Unterspannung/Drosselung seit dem Boot – häufige Ursache für
        # abgebrochene Updates und SD-Karten-Fehler.
        throttled=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
        if [ -n "$throttled" ] && [ "$throttled" != "0x0" ]; then
            record WARNUNG "Stromversorgung" "get_throttled=$throttled (Unterspannung/Drosselung seit Boot – Netzteil prüfen)"
        else
            record OK "Stromversorgung" "keine Unterspannung"
        fi
    fi

    failed=$(systemctl list-units --failed --plain --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
    if [ -n "${failed// /}" ]; then
        record WARNUNG "systemd" "fehlgeschlagene Units: $failed"
    else
        record OK "systemd" "keine fehlgeschlagenen Units"
    fi

    if docker_available; then
        local bad
        bad=$(docker ps -a --format '{{.Names}} {{.Status}}' \
            | grep -E 'Restarting|unhealthy|Exited \([1-9][0-9]*\)|Dead' | tr '\n' ';' || true)
        if [ -n "$bad" ]; then
            record WARNUNG "Container-Status" "$bad"
        else
            record OK "Container-Status" "$(docker ps -q | wc -l) Container laufen"
        fi
    elif command -v docker >/dev/null 2>&1; then
        record FEHLER "Docker" "Docker-Daemon antwortet nicht"
    fi
}

# =============================================================================
# 2. Debian-Pakete
# =============================================================================

wait_for_package_managers() {
    local waited=0
    while pgrep -x 'apt|apt-get|aptitude|dpkg|unattended-upgr' >/dev/null; do
        if (( waited >= APT_LOCK_TIMEOUT )); then
            record FEHLER "Paketverwaltung" "nach ${APT_LOCK_TIMEOUT}s noch durch anderen Prozess belegt"
            return 1
        fi
        (( waited == 0 )) && log "Andere Paketverwaltung läuft – warte bis zu ${APT_LOCK_TIMEOUT}s ..."
        sleep 10
        (( waited += 10 ))
    done
    return 0
}

step_dpkg_repair() {
    section "Paketsystem prüfen"
    local audit pending=0
    audit=$(dpkg --audit 2>&1)
    if [ -d /var/lib/dpkg/updates ] && [ -n "$(ls -A /var/lib/dpkg/updates 2>/dev/null)" ]; then
        pending=1
    fi
    if [ -z "$audit" ] && (( ! pending )); then
        record OK "Paketsystem" "keine unterbrochenen Installationen"
        return 0
    fi

    [ -n "$audit" ] && log "$audit"
    log "dpkg wurde unterbrochen – Reparatur wird versucht."
    if (( DRY_RUN )); then
        record WARNUNG "Paketsystem" "unterbrochene Installation gefunden (Dry-Run: keine Reparatur)"
        return 1
    fi
    if run env DEBIAN_FRONTEND=noninteractive dpkg --force-confdef --force-confold --configure -a \
        && run env DEBIAN_FRONTEND=noninteractive apt-get -y -q \
               -o "DPkg::Lock::Timeout=$APT_LOCK_TIMEOUT" \
               -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
               -f install; then
        record WARNUNG "Paketsystem" "unterbrochene Installation repariert (dpkg --configure -a)"
        return 0
    fi
    record FEHLER "Paketsystem" "Reparatur fehlgeschlagen – siehe docs/runbooks/dpkg-unterbrochen.md"
    return 1
}

step_apt() {
    section "Debian-Pakete aktualisieren"
    local out held count
    out=$(mktemp)

    if ! env LANG=C.UTF-8 apt-get -q -o "DPkg::Lock::Timeout=$APT_LOCK_TIMEOUT" update; then
        record FEHLER "apt update" "Paketlisten konnten nicht geladen werden"
        rm -f "$out"
        return 1
    fi
    record OK "apt update"

    if (( DRY_RUN )); then
        env LANG=C.UTF-8 apt-get -s upgrade 2>&1 | grep -E '^(Inst|[0-9]+ upgraded)' | tee "$out"
        count=$(grep -oE '^[0-9]+ upgraded' "$out" | cut -d' ' -f1)
        record OK "apt upgrade" "Dry-Run: ${count:-?} Pakete würden aktualisiert"
    else
        if ! env LANG=C.UTF-8 DEBIAN_FRONTEND=noninteractive apt-get -y -q \
                -o "DPkg::Lock::Timeout=$APT_LOCK_TIMEOUT" \
                -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
                upgrade 2>&1 | tee "$out"; then
            record FEHLER "apt upgrade" "fehlgeschlagen – siehe Protokoll"
            rm -f "$out"
            return 1
        fi
        count=$(grep -oE '^[0-9]+ upgraded' "$out" | cut -d' ' -f1)
        record OK "apt upgrade" "${count:-?} Pakete aktualisiert"
        apt-get -y -q autoclean >/dev/null 2>&1 || true
    fi
    rm -f "$out"

    # Zurückgehaltene Pakete brauchen full-upgrade -> nur nach Rückfrage (CLAUDE.md §5)
    held=$(env LANG=C.UTF-8 apt list --upgradable 2>/dev/null | grep -v '^Listing' || true)
    if [ -n "$held" ] && (( ! DRY_RUN )); then
        log "Zurückgehaltene Pakete:"
        log "$held"
        record WARNUNG "Zurückgehaltene Pakete" \
            "$(printf '%s\n' "$held" | wc -l) Pakete – nur nach Prüfung mit 'apt full-upgrade'"
    fi
    return 0
}

# =============================================================================
# 3. Container-Updates (nur melden)
# =============================================================================

PLATFORM=""
case "$(uname -m)" in
    aarch64|arm64) PLATFORM="linux/arm64" ;;
    armv7l)        PLATFORM="linux/arm/v7" ;;
    x86_64)        PLATFORM="linux/amd64" ;;
esac

declare -A REMOTE_DIGEST_CACHE=()
declare -A REMOTE_VERSION_CACHE=()

# Digest des Tags in der Registry – ohne das Image herunterzuladen.
remote_digest() {
    local ref=$1
    if [ -z "${REMOTE_DIGEST_CACHE[$ref]+x}" ]; then
        REMOTE_DIGEST_CACHE[$ref]=$(timeout 60 docker buildx imagetools inspect "$ref" \
            --format '{{.Manifest.Digest}}' 2>/dev/null)
    fi
    printf '%s' "${REMOTE_DIGEST_CACHE[$ref]}"
}

# Versions-Label (org.opencontainers.image.version) des Tags in der Registry.
remote_version() {
    local ref=$1 v
    if [ -z "${REMOTE_VERSION_CACHE[$ref]+x}" ]; then
        v=$(timeout 60 docker buildx imagetools inspect "$ref" --format \
            "{{ with index .Image \"$PLATFORM\" }}{{ index .Config.Labels \"org.opencontainers.image.version\" }}{{ end }}" 2>/dev/null) \
        || v=$(timeout 60 docker buildx imagetools inspect "$ref" --format \
            '{{ index .Image.Config.Labels "org.opencontainers.image.version" }}' 2>/dev/null)
        REMOTE_VERSION_CACHE[$ref]=$v
    fi
    printf '%s' "${REMOTE_VERSION_CACHE[$ref]}"
}

step_container_updates() {
    (( CHECK_CONTAINER_UPDATES )) || return 0
    docker_available || return 0
    section "Container-Updates prüfen (nur Meldung, keine Änderung)"

    if ! docker buildx version >/dev/null 2>&1; then
        record WARNUNG "Container-Updates" "docker buildx fehlt (Paket docker-buildx-plugin) – keine Prüfung möglich"
        return 0
    fi

    local updates=() failures=()
    local id cname ref cur_img cfg project origin track lv rv rd digests
    for id in $(docker ps -q); do
        IFS='|' read -r cname ref cur_img cfg project < <(docker inspect -f \
            '{{.Name}}|{{.Config.Image}}|{{.Image}}|{{index .Config.Labels "com.docker.compose.project.config_files"}}|{{index .Config.Labels "com.docker.compose.project"}}' "$id")
        cname=${cname#/}

        if [ -n "$REPO_SERVICES_DIR" ] && [[ $cfg == "$REPO_SERVICES_DIR"/* ]]; then
            origin="Repo-Service"
        elif [[ $cfg == /data/compose/* ]]; then
            origin="Portainer-Stack '$project'"
        elif [ -n "$project" ]; then
            origin="Compose '$project'"
        else
            origin="Einzelcontainer"
        fi

        lv=$(docker image inspect -f '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$cur_img" 2>/dev/null)
        track=${WATCH_TAGS[$cname]:-}

        if [ -n "$track" ]; then
            # Fester Tag: Version mit dem beobachteten Tag (z. B. :stable) vergleichen
            rv=$(remote_version "$track")
            if [ -z "$rv" ] || [ -z "$lv" ]; then
                failures+=("$cname")
                log "$cname: $origin, $ref (Version ${lv:-?}) – Version von $track nicht ermittelbar"
            elif [ "$rv" != "$lv" ]; then
                updates+=("$cname: $lv -> $rv")
                log "$cname: $origin, $ref – NEUE VERSION $rv verfügbar (läuft: $lv)"
            else
                log "$cname: $origin, $ref (Version $lv) – aktuell"
            fi
            continue
        fi

        if [[ $ref == *@sha256:* || $ref == sha256:* ]]; then
            log "$cname: $origin, per Digest fixiert – übersprungen (ggf. WATCH_TAGS setzen)"
            continue
        fi

        # Gleicher Tag neu gebaut? Registry-Digest mit lokalem RepoDigest vergleichen.
        rd=$(remote_digest "$ref")
        if [ -z "$rd" ]; then
            failures+=("$cname")
            log "$cname: $origin, $ref – Registry nicht abfragbar"
            continue
        fi
        digests=$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$cur_img" 2>/dev/null)
        if grep -qF "@$rd" <<<"$digests"; then
            log "$cname: $origin, $ref${lv:+ (Version $lv)} – aktuell"
        else
            updates+=("$cname: neues Image für $ref")
            log "$cname: $origin, $ref${lv:+ (Version $lv)} – NEUES IMAGE verfügbar"
        fi
        if [[ ${ref##*:} =~ [0-9] ]]; then
            log "   Hinweis: fester Tag – neue Versionen nur mit WATCH_TAGS[$cname] erkennbar"
        fi
    done

    if (( ${#failures[@]} )); then
        record WARNUNG "Update-Prüfung" "nicht prüfbar: ${failures[*]}"
    fi
    if (( ${#updates[@]} )); then
        record WARNUNG "Container-Updates verfügbar" \
            "$(printf '%s; ' "${updates[@]}")Update per Repo-Commit nach OK"
    else
        record OK "Container-Updates" "keine Updates gefunden"
    fi
}

# =============================================================================
# 4. Healthchecks
# =============================================================================

step_healthchecks() {
    if (( ${#HTTP_CHECKS[@]} == 0 && ${#DNS_CHECKS[@]} == 0 )); then
        return 0
    fi
    section "Healthchecks"
    local entry name url server query result

    for entry in "${HTTP_CHECKS[@]}"; do
        IFS='|' read -r name url <<<"$entry"
        if curl -fsS -o /dev/null -m 15 "$url"; then
            record OK "Health: $name" "$url erreichbar"
        else
            record FEHLER "Health: $name" "$url nicht erreichbar"
        fi
    done

    for entry in "${DNS_CHECKS[@]}"; do
        IFS='|' read -r name server query <<<"$entry"
        if command -v dig >/dev/null 2>&1; then
            result=$(dig +short +time=3 +tries=2 "@$server" "$query" 2>/dev/null | head -n1)
        elif command -v nslookup >/dev/null 2>&1; then
            result=$(nslookup -timeout=3 "$query" "$server" 2>/dev/null | awk '/^Address/ && NR>2 {print $2; exit}')
        else
            record WARNUNG "Health: $name" "weder dig noch nslookup installiert (Paket dnsutils)"
            continue
        fi
        if [ -n "$result" ]; then
            record OK "Health: $name" "$query über $server -> $result"
        else
            record FEHLER "Health: $name" "DNS-Auflösung von $query über $server fehlgeschlagen"
        fi
    done
}

# =============================================================================
# 5. Neustart-Bedarf (nie automatisch neu starten)
# =============================================================================

reboot_needed() {
    REBOOT_REASON=""
    if [ -f /run/reboot-required ]; then
        REBOOT_REASON="/run/reboot-required vorhanden"
        [ -f /run/reboot-required.pkgs ] && \
            REBOOT_REASON+=" ($(tr '\n' ' ' </run/reboot-required.pkgs))"
        return 0
    fi
    # Raspberry Pi OS legt dafür kein reboot-required an: neuesten installierten
    # Kernel derselben Variante mit dem laufenden vergleichen.
    local running flavor newest
    running=$(uname -r)
    flavor=${running##*-}
    newest=$(find /lib/modules -mindepth 1 -maxdepth 1 -name "*-${flavor}" -printf '%f\n' 2>/dev/null | sort -V | tail -n1)
    if [ -n "$newest" ] && [ "$newest" != "$running" ]; then
        REBOOT_REASON="neuer Kernel installiert ($newest, läuft: $running)"
        return 0
    fi
    return 1
}

# =============================================================================
# Abschluss: Zusammenfassung + Mail
# =============================================================================

STATUS_TEXT=(OK WARNUNG FEHLGESCHLAGEN)

summary() {
    local i
    printf '========================================\n'
    printf 'Ergebnis: %s\n' "${STATUS_TEXT[$OVERALL]}"
    printf '========================================\n'
    for i in "${!STEP_NAMES[@]}"; do
        printf '%-8s %s%s\n' "${STEP_STATES[$i]}" "${STEP_NAMES[$i]}" \
            "${STEP_NOTES[$i]:+ – ${STEP_NOTES[$i]}}"
    done
    printf '\n%s\n' "$REBOOT_LINE"
}

send_mail() {
    (( NO_MAIL )) && return 0
    if [ -z "$MAIL_TO" ]; then
        echo "MAIL_TO nicht gesetzt – keine Mail verschickt." >&2
        return 0
    fi
    local subject dry=""
    (( DRY_RUN )) && dry=" (DRY-RUN)"
    subject="Raspberry Pi Wartung ${STATUS_TEXT[$OVERALL]}${dry}: $HOST"
    {
        printf 'To: %s\n' "$MAIL_TO"
        [ -n "$MAIL_FROM" ] && printf 'From: %s\n' "$MAIL_FROM"
        printf 'Subject: %s\n' "$subject"
        printf 'MIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n'
        summary
        printf '\n\n---------------- Vollständiges Protokoll ----------------\n'
        cat "$LOG_FILE"
    } | $MAIL_COMMAND || echo "Mailversand mit '$MAIL_COMMAND' fehlgeschlagen." >&2
}

# =============================================================================
# Ablauf
# =============================================================================

printf '========================================\n'
printf 'Wöchentliche Raspberry-Pi-Wartung v%s%s\n' "$VERSION" "$( (( DRY_RUN )) && echo ' (DRY-RUN)')"
printf 'Host: %s\n' "$HOST"
printf 'Start: %s\n' "$(date --iso-8601=seconds)"
printf '========================================\n'

step_health

if wait_for_package_managers && step_dpkg_repair; then
    step_apt
else
    record FEHLER "Debian-Pakete" "übersprungen, weil das Paketsystem nicht bereit ist"
fi

step_container_updates
step_healthchecks

if reboot_needed; then
    REBOOT_LINE="NEUSTART ERFORDERLICH: $REBOOT_REASON – bitte manuell neu starten."
    (( OVERALL < 1 )) && OVERALL=1
else
    REBOOT_LINE="Kein Neustart erforderlich."
fi

find "$LOG_DIR" -name '*.log' -type f -mtime +"$LOG_KEEP_DAYS" -delete 2>/dev/null

printf '\nEnde: %s\n\n' "$(date --iso-8601=seconds)"
summary

# Protokoll abschließen, dann Mail senden
exec 1>&3 2>&4
wait "$TEE_PID" 2>/dev/null
send_mail

(( OVERALL == 2 )) && exit 1
exit 0
