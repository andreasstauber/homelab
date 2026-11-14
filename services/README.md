# Services

Je Service ein Ordner `services/<name>/` mit `docker-compose.yml`, `.env.example`
und `README.md` (Zweck, Ports, Update-Weg, Backup-Hinweise). Siehe CLAUDE.md §8.

Noch kein Service ist im Repo. Home Assistant (`/opt/compose/homeassistant/`)
und Pi-hole (Portainer-Stack) laufen außerhalb des Repos. Die Übernahme beginnt
mit der Ist-Aufnahme (`docs/runbooks/ist-aufnahme.md`). Compose-Dateien,
Volumes, Bind-Mounts, Netzwerke und Variablen werden zuerst dokumentiert und
gesichert, nichts wird blind verschoben.
