#!/bin/bash
# =============================================================================
# LaboBox - Collecteur de statistiques de bande passante
# Exécution: toutes les 5 minutes via cron
# Crontab: */5 * * * * /opt/laboboxvpn/utils/dashboard/stats-collector.sh
# =============================================================================

STATS_FILE="/opt/laboboxvpn/utils/dashboard/bandwidth-stats.json"
LOCK_FILE="/tmp/bandwidth-collector.lock"
MAX_HISTORY_DAYS=30

# Éviter les exécutions concurrentes
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE")
    if ps -p "$pid" > /dev/null 2>&1; then
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"
trap "rm -f $LOCK_FILE" EXIT

# Créer le fichier s'il n'existe pas
if [ ! -f "$STATS_FILE" ]; then
    echo '{}' > "$STATS_FILE"
fi

# Fonction pour convertir les unités Docker en bytes
convert_to_bytes() {
    local value=$1
    local num=$(echo "$value" | sed 's/[^0-9.]//g')
    local unit=$(echo "$value" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')
    
    case "$unit" in
        B)   echo "$num" | awk '{printf "%.0f", $1}' ;;
        KB)  echo "$num" | awk '{printf "%.0f", $1 * 1024}' ;;
        MB)  echo "$num" | awk '{printf "%.0f", $1 * 1024 * 1024}' ;;
        GB)  echo "$num" | awk '{printf "%.0f", $1 * 1024 * 1024 * 1024}' ;;
        TB)  echo "$num" | awk '{printf "%.0f", $1 * 1024 * 1024 * 1024 * 1024}' ;;
        KIB) echo "$num" | awk '{printf "%.0f", $1 * 1024}' ;;
        MIB) echo "$num" | awk '{printf "%.0f", $1 * 1048576}' ;;
        GIB) echo "$num" | awk '{printf "%.0f", $1 * 1073741824}' ;;
        TIB) echo "$num" | awk '{printf "%.0f", $1 * 1099511627776}' ;;
        *)   echo "$num" | awk '{printf "%.0f", $1}' ;;
    esac
}

# Date du jour (pour l'historique journalier)
TODAY=$(date +%Y-%m-%d)
NOW=$(date -Iseconds)

# Récupérer les stats Docker pour tous les conteneurs rtorrent
docker_stats=$(docker stats --no-stream --format "{{.Name}}:{{.NetIO}}" 2>/dev/null | grep "^rtorrent-")

# Lire le fichier JSON actuel
current_json=$(cat "$STATS_FILE")

# Traitement avec Python (plus fiable pour le JSON)
python3 << EOF
import json
import sys
from datetime import datetime, timedelta

# Charger les données actuelles
try:
    with open('$STATS_FILE', 'r') as f:
        data = json.load(f)
except:
    data = {}

today = '$TODAY'
now = '$NOW'
max_days = $MAX_HISTORY_DAYS

# Parser les stats Docker
docker_output = '''$docker_stats'''

for line in docker_output.strip().split('\n'):
    if not line or ':' not in line:
        continue
    
    # Format: rtorrent-clientname:DOWNLOAD / UPLOAD
    parts = line.split(':')
    if len(parts) < 2:
        continue
    
    container_name = parts[0]
    client_name = container_name.replace('rtorrent-', '')
    
    # Parser NetIO (ex: "137GB / 54.6GB")
    net_io = ':'.join(parts[1:]).strip()
    if ' / ' not in net_io:
        continue
    
    dl_str, ul_str = net_io.split(' / ')
    
    # Convertir en bytes
    def to_bytes(val):
        val = val.strip().upper()
        num = float(''.join(c for c in val if c.isdigit() or c == '.'))
        if 'TB' in val or 'TIB' in val:
            return int(num * 1024**4)
        elif 'GB' in val or 'GIB' in val:
            return int(num * 1024**3)
        elif 'MB' in val or 'MIB' in val:
            return int(num * 1024**2)
        elif 'KB' in val or 'KIB' in val:
            return int(num * 1024)
        else:
            return int(num)
    
    current_dl = to_bytes(dl_str)
    current_ul = to_bytes(ul_str)
    
    # Initialiser le client s'il n'existe pas
    if client_name not in data:
        data[client_name] = {
            'current': {'download': 0, 'upload': 0},
            'last_raw': {'download': 0, 'upload': 0},
            'today_delta': {'download': 0, 'upload': 0},
            'today_date': today,
            'updated': now,
            'history': []
        }
    
    client = data[client_name]
    
    # Récupérer les anciennes valeurs brutes
    last_dl = client.get('last_raw', {}).get('download', 0)
    last_ul = client.get('last_raw', {}).get('upload', 0)
    
    # Calculer les deltas (gérer le redémarrage du conteneur)
    if current_dl >= last_dl:
        delta_dl = current_dl - last_dl
    else:
        # Conteneur redémarré, on prend la valeur actuelle comme delta
        delta_dl = current_dl
    
    if current_ul >= last_ul:
        delta_ul = current_ul - last_ul
    else:
        delta_ul = current_ul
    
    # Vérifier si on a changé de jour
    client_today = client.get('today_date', today)
    if client_today != today:
        # Archiver les données d'hier dans l'historique
        yesterday_delta = client.get('today_delta', {'download': 0, 'upload': 0})
        if yesterday_delta['download'] > 0 or yesterday_delta['upload'] > 0:
            client['history'].insert(0, {
                'date': client_today,
                'download': yesterday_delta['download'],
                'upload': yesterday_delta['upload']
            })
        
        # Reset pour le nouveau jour
        client['today_delta'] = {'download': 0, 'upload': 0}
        client['today_date'] = today
    
    # Ajouter les deltas au cumul du jour
    client['today_delta']['download'] = client.get('today_delta', {}).get('download', 0) + delta_dl
    client['today_delta']['upload'] = client.get('today_delta', {}).get('upload', 0) + delta_ul
    
    # Ajouter les deltas au total courant
    client['current']['download'] = client.get('current', {}).get('download', 0) + delta_dl
    client['current']['upload'] = client.get('current', {}).get('upload', 0) + delta_ul
    
    # Mettre à jour les valeurs brutes
    client['last_raw'] = {'download': current_dl, 'upload': current_ul}
    client['updated'] = now
    
    # Nettoyer l'historique (garder seulement les X derniers jours)
    cutoff_date = (datetime.now() - timedelta(days=max_days)).strftime('%Y-%m-%d')
    client['history'] = [h for h in client['history'] if h['date'] > cutoff_date][:max_days]
    
    data[client_name] = client

# Sauvegarder
with open('$STATS_FILE', 'w') as f:
    json.dump(data, f, indent=2)

print(f"Stats mises à jour pour {len([l for l in docker_output.strip().split(chr(10)) if l])} clients")
EOF

# Vérifier les permissions
chmod 644 "$STATS_FILE"
