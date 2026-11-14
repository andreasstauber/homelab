# Runbook: Ist-Aufnahme (nur lesend)

Ziel: Zustand des Pi erfassen, bevor Services ins Repo übernommen werden
(CLAUDE.md §4.1). Ergebnis in `CLAUDE.md` §1/§2 und `services/<name>/README.md` eintragen.

```bash
ssh pi "cat /etc/os-release; uname -m; hostname; hostname -I"
ssh pi "uptime; df -h; free -h; vcgencmd measure_temp; vcgencmd get_throttled"
ssh pi "systemctl --failed"
ssh pi "docker --version; docker compose version; docker buildx version"
ssh pi "docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"
ssh pi "docker compose ls"
ssh pi "docker network ls; docker volume ls"
# je Container: Mounts, Netzwerke, Compose-Herkunft
ssh pi "docker inspect -f '{{.Name}} {{json .Mounts}} {{index .Config.Labels \"com.docker.compose.project.config_files\"}}' \$(docker ps -q)"
```

Portainer-Stacks: Compose-Datei und Variablen in Portainer unter
Stacks -> <Stack> -> Editor ablesen (die Datei liegt nicht unter `/data/compose`
auf dem Host). Variablen mit Secrets nur in `.env` auf dem Pi, im Repo `.env.example`.
