#!/bin/bash
#####################################################
#        LaboBox-VPN - Multi users v3.3.0           #
#    Multi-User rtorrent/ruTorrent + WireGuard      #
#               By CLusmi - 2026                    #
#####################################################

# Ne pas utiliser "set -e" car le script est interactif et gère les erreurs manuellement

###########################################
# CONFIGURATION
###########################################
INSTALL_DIR="/opt/laboboxvpn"
CLIENTS_DIR="${INSTALL_DIR}/clients"
UTILS_DIR="${INSTALL_DIR}/utils"
VERSION="3.3.0"

# Délais de démarrage séquentiel (en secondes)
STARTUP_DELAY=10                    # Délai entre chaque client
STARTUP_HEALTHCHECK_TIMEOUT=60      # Timeout max pour healthcheck Gluetun
SHUTDOWN_DELAY=3                    # Délai entre chaque client à l'arrêt
CONFIG_FILE="${INSTALL_DIR}/laboboxvpn.conf"

# Valeurs par défaut
DEFAULT_SERVER_IP="A_CONFIGURER"
DEFAULT_SSH_PORT="22"
DEFAULT_NAS_IP="A_CONFIGURER"

# Configuration réseau VM
SERVER_IP="$DEFAULT_SERVER_IP"
SSH_PORT="$DEFAULT_SSH_PORT"

# Configuration NAS
NAS_IP="$DEFAULT_NAS_IP"
NAS_MOUNT="/mnt/nas"
NAS_SHARE_PREFIX="SEEDBOX_"

# Disque temporaire (SSD) pour les téléchargements : vide = désactivé.
# Chaque client actif y reçoit ${TEMP_DIR}/<client>, monté sur /temp dans
# son conteneur ; les torrents y sont téléchargés puis déplacés vers le
# NAS à la complétion (voir entrypoint.sh).
TEMP_DIR=""

# Taille maximale d'un torrent accepté à l'ajout (garde-fou), en octets.
# Un torrent plus gros est refusé (stoppé + effacé, journalisé). 0 = illimité.
# Défaut : 6 To (6 * 1024^4). Modifiable via le menu Monitoring.
MAX_TORRENT_SIZE="6597069766656"

# Charger la configuration si elle existe
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
}

# Sauvegarder la configuration
save_config() {
    # Le fichier vit dans INSTALL_DIR, qui n'existe pas encore lors de la
    # toute première configuration (dans le menu, « Configurer le réseau »
    # passe AVANT « Initialiser le système ») : on crée le dossier au lieu
    # d'échouer. Retourne 1 si l'écriture est impossible — l'appelant ne
    # doit pas annoncer une sauvegarde qui n'a pas eu lieu.
    mkdir -p "$INSTALL_DIR" 2>/dev/null
    cat > "$CONFIG_FILE" << EOF || return 1
# Configuration LaboBox-VPN Manager - Généré automatiquement
# Ne pas modifier manuellement

SERVER_IP="${SERVER_IP}"
SSH_PORT="${SSH_PORT}"
NAS_IP="${NAS_IP}"
TEMP_DIR="${TEMP_DIR}"
MAX_TORRENT_SIZE="${MAX_TORRENT_SIZE}"
EOF
    chmod 600 "$CONFIG_FILE"
}

# Charger la config au démarrage
load_config

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

###########################################
# FONCTIONS D'AFFICHAGE
###########################################

# Marge gauche commune à toute l'interface (deux espaces, comme
# Network-WireGuard-Manager) : lignes, titres et textes partent tous
# de la même colonne.
line() {
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────────────${NC}"
}

double_line() {
    echo -e "  ${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
}

print_header() {
    echo ""
    double_line
    echo -e "  ${WHITE}LaboBox-VPN - Multi users${NC}                                    ${CYAN}v${VERSION}${NC}"
    double_line
}

print_header_with_title() {
    local title=$1
    local extra=$2
    echo ""
    double_line
    echo -e "  ${WHITE}${title}${NC}${extra}"
    double_line
}

print_footer() {
    double_line
    echo ""
}

print_footer_with_summary() {
    local summary=$1
    double_line
    echo -e "  ${DIM}${summary}${NC}"
    double_line
    echo ""
}

print_section() {
    local title=$1
    echo -e "  ${WHITE}${title}${NC}"
    line
}

print_item() {
    local label=$1
    local value=$2
    local label_clean=$(echo -e "$label" | sed 's/\x1b\[[0-9;]*m//g')
    local label_len=${#label_clean}
    local dots_needed=$((22 - label_len))
    [ $dots_needed -lt 1 ] && dots_needed=1
    local dots=""
    for ((i=0; i<dots_needed; i++)); do dots+="."; done
    echo -e "  ├─ ${label} ${dots} ${value}"
}

print_item_last() {
    local label=$1
    local value=$2
    local label_clean=$(echo -e "$label" | sed 's/\x1b\[[0-9;]*m//g')
    local label_len=${#label_clean}
    local dots_needed=$((22 - label_len))
    [ $dots_needed -lt 1 ] && dots_needed=1
    local dots=""
    for ((i=0; i<dots_needed; i++)); do dots+="."; done
    echo -e "  └─ ${label} ${dots} ${value}"
}

print_step() {
    local current=$1
    local total=$2
    local message=$3
    local status=${4:-""}
    
    if [ "$status" == "wait" ]; then
        echo -ne "  ${DIM}[${current}/${total}]${NC} ${message} ${DIM}...${NC}"
    else
        echo -e "  ${DIM}[${current}/${total}]${NC} ${message}"
    fi
}

print_step_item() {
    local label=$1
    local value=$2
    echo -e "       ${DIM}├─${NC} ${label}: ${value}"
}

print_step_item_last() {
    local label=$1
    local value=$2
    echo -e "       ${DIM}└─${NC} ${label}: ${value}"
}

print_success_box() {
    local message=$1
    echo ""
    echo -e "  ${GREEN}┌─────────────────────────────────────────────────────────────────┐${NC}"
    printf "  ${GREEN}│${NC}  ✔ %-60s ${GREEN}│${NC}\n" "$message"
    echo -e "  ${GREEN}└─────────────────────────────────────────────────────────────────┘${NC}"
}

print_warning_box() {
    local message=$1
    echo ""
    echo -e "  ${YELLOW}┌─────────────────────────────────────────────────────────────────┐${NC}"
    printf "  ${YELLOW}│${NC}  ⚠ %-60s ${YELLOW}│${NC}\n" "$message"
    echo -e "  ${YELLOW}└─────────────────────────────────────────────────────────────────┘${NC}"
}

print_error_box() {
    local message=$1
    local hint=$2
    echo ""
    echo -e "  ${RED}┌─────────────────────────────────────────────────────────────────┐${NC}"
    printf "  ${RED}│${NC}  ✗ %-60s ${RED}│${NC}\n" "$message"
    echo -e "  ${RED}└─────────────────────────────────────────────────────────────────┘${NC}"
    if [ -n "$hint" ]; then
        echo ""
        echo -e "  ${DIM}Solutions possibles:${NC}"
        echo -e "  $hint"
    fi
}

print_success() {
    echo -e "  ${GREEN}✔${NC} $1"
}

print_error() {
    echo -e "  ${RED}✗${NC} $1"
}

print_warning() {
    echo -e "  ${YELLOW}⚠${NC} $1"
}

progress_bar() {
    local percent=$1
    local width=20
    local filled=$((percent * width / 100))
    local empty=$((width - filled))
    
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    
    local color=$GREEN
    [ $percent -ge 80 ] && color=$YELLOW
    [ $percent -ge 95 ] && color=$RED
    
    echo -e "${color}[${bar}]${NC} ${percent}%"
}

###########################################
# FONCTIONS MENU INTERACTIF
###########################################

clear_screen() {
    clear
}

print_menu_header() {
    clear_screen
    echo ""
    double_line
    echo -e "  ${WHITE}LaboBox-VPN - Multi users${NC}                                    ${CYAN}v${VERSION}${NC}"
    echo -e "  ${DIM}Gestionnaire multi-clients rtorrent/ruTorrent + WireGuard${NC}"
    double_line
    echo ""
}

print_menu_option() {
    local num=$1
    local icon=$2
    local label=$3
    # Format: marge de 2 espaces, numéro aligné à droite sur 2 chars, tiret, label.
    # Le label est imprime avec %b pour interpreter d'eventuels codes couleur
    # (ex. ${DIM}...${NC}), comme le fait « echo -e » ailleurs dans le script.
    printf "  %2s  %s  %b\n" "$num" "$icon" "$label"
}

print_menu_separator() {
    echo ""
}

# Variable globale pour stocker le choix
MENU_CHOICE=""

read_choice() {
    local prompt=$1
    local default=$2
    echo ""
    if [ -n "$default" ]; then
        echo -ne "  ${CYAN}▶${NC} ${prompt} [${default}]: "
    else
        echo -ne "  ${CYAN}▶${NC} ${prompt}: "
    fi
    read MENU_CHOICE
    [ -z "$MENU_CHOICE" ] && MENU_CHOICE="$default"
}

read_input() {
    local prompt=$1
    local default=$2
    local is_password=$3
    
    if [ -n "$default" ]; then
        echo -ne "  ${prompt} [${default}]: "
    else
        echo -ne "  ${prompt}: "
    fi
    
    if [ "$is_password" == "password" ]; then
        read -s MENU_CHOICE
        echo ""
    else
        read MENU_CHOICE
    fi
    
    [ -z "$MENU_CHOICE" ] && MENU_CHOICE="$default"
}

confirm() {
    local prompt=$1
    echo -ne "  ${YELLOW}▶${NC} ${prompt} (oui/non): "
    read answer
    [ "$answer" == "oui" ] || [ "$answer" == "o" ]
}

press_enter() {
    echo ""
    echo -ne "  ${DIM}Appuyez sur ENTRÉE pour continuer...${NC}"
    read
}

###########################################
# FONCTIONS UTILITAIRES
###########################################

check_root() {
    if [ "$(id -u)" != "0" ]; then
        print_error_box "Ce script doit être exécuté en root"
        exit 1
    fi
}

# Vérifie si le système est initialisé
is_system_initialized() {
    # Vérifie Docker, NFS et IP NAS configurée
    if command -v docker &> /dev/null && \
       command -v mount.nfs &> /dev/null && \
       [ "$NAS_IP" != "A_CONFIGURER" ]; then
        return 0
    else
        return 1
    fi
}

# Vérifie si l'image Docker est buildée
is_image_built() {
    if docker images 2>/dev/null | grep -q "laboboxvpn/rtorrent-rutorrent"; then
        return 0
    else
        return 1
    fi
}

# Vérifie si la configuration réseau est faite (premier lancement)
is_network_configured() {
    if [ "$SERVER_IP" != "A_CONFIGURER" ] && [ "$NAS_IP" != "A_CONFIGURER" ]; then
        return 0
    else
        return 1
    fi
}

# Vérifie si c'est le premier lancement (rien n'est configuré)
is_first_run() {
    if [ "$SERVER_IP" = "A_CONFIGURER" ] || [ "$NAS_IP" = "A_CONFIGURER" ]; then
        return 0
    else
        return 1
    fi
}

###########################################
# FONCTIONS NFS / NAS
###########################################

check_install_nfs() {
    if ! command -v mount.nfs &> /dev/null; then
        echo -e "  ${YELLOW}Installation de nfs-common...${NC}"
        apt-get update -qq
        apt-get install -y nfs-common -qq
        echo -e "  ${GREEN}✔ nfs-common installé${NC}"
    fi
}

get_nas_share_name() {
    local client=$1
    echo "${NAS_SHARE_PREFIX}$(echo $client | tr '[:lower:]' '[:upper:]')"
}

get_client_mount_path() {
    local client=$1
    echo "${NAS_MOUNT}/$(get_nas_share_name $client)"
}

get_client_docker_apps_path() {
    local client=$1
    echo "$(get_client_mount_path $client)/docker_apps"
}

get_client_data_path() {
    local client=$1
    echo "$(get_client_mount_path $client)/data"
}

check_nas_mounted_for_client() {
    local client=$1
    local mount_path=$(get_client_mount_path $client)
    mountpoint -q "$mount_path" 2>/dev/null
}

mount_nas_for_client() {
    local client=$1
    local share_name=$(get_nas_share_name $client)
    local mount_path=$(get_client_mount_path $client)
    
    check_install_nfs
    mkdir -p "$mount_path"
    
    if check_nas_mounted_for_client "$client"; then
        return 0
    fi
    
    if mount -t nfs "${NAS_IP}:/volume1/${share_name}" "$mount_path" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

umount_nas_for_client() {
    local client=$1
    local mount_path=$(get_client_mount_path $client)
    
    if mountpoint -q "$mount_path" 2>/dev/null; then
        umount "$mount_path" 2>/dev/null || umount -l "$mount_path" 2>/dev/null || true
    fi
}

add_fstab_for_client() {
    local client=$1
    local share_name=$(get_nas_share_name $client)
    local mount_path=$(get_client_mount_path $client)
    
    if ! grep -q "${share_name}" /etc/fstab 2>/dev/null; then
        echo "${NAS_IP}:/volume1/${share_name} ${mount_path} nfs vers=4.1,rsize=1048576,wsize=1048576,hard,async,noatime,nconnect=4,_netdev 0 0" >> /etc/fstab
        systemctl daemon-reload 2>/dev/null || true
    fi
}

remove_fstab_for_client() {
    local client=$1
    local share_name=$(get_nas_share_name $client)
    sed -i "/${share_name}/d" /etc/fstab 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
}

mount_all_nas_shares() {
    check_install_nfs
    mkdir -p "$NAS_MOUNT"
    
    [ ! -d "$CLIENTS_DIR" ] && return
    for client_dir in "$CLIENTS_DIR"/*/; do
        [ -f "$client_dir/docker-compose.yml" ] || continue
        local client=$(basename "$client_dir")
        mount_nas_for_client "$client" 2>/dev/null || true
    done
}

###########################################
# FONCTIONS QUOTA NAS
###########################################

get_nas_quota_bytes() {
    local client=$1
    local mount_path=$(get_client_mount_path $client)
    
    if mountpoint -q "$mount_path" 2>/dev/null; then
        df -k "$mount_path" 2>/dev/null | tail -1 | awk '{print $2 * 1024}'
    else
        echo "0"
    fi
}

get_nas_used_bytes() {
    local client=$1
    local mount_path=$(get_client_mount_path $client)
    
    if mountpoint -q "$mount_path" 2>/dev/null; then
        df -k "$mount_path" 2>/dev/null | tail -1 | awk '{print $3 * 1024}'
    else
        echo "0"
    fi
}

format_bytes() {
    local bytes=$1
    
    if [ $bytes -ge 1099511627776 ]; then
        local tb=$((bytes / 1099511627776))
        local remainder=$(((bytes % 1099511627776) * 10 / 1099511627776))
        echo "${tb}.${remainder} TB"
    elif [ $bytes -ge 1073741824 ]; then
        local gb=$((bytes / 1073741824))
        local remainder=$(((bytes % 1073741824) * 10 / 1073741824))
        echo "${gb}.${remainder} GB"
    elif [ $bytes -ge 1048576 ]; then
        local mb=$((bytes / 1048576))
        echo "${mb} MB"
    elif [ $bytes -ge 1024 ]; then
        local kb=$((bytes / 1024))
        echo "${kb} KB"
    else
        echo "${bytes} B"
    fi
}

###########################################
# ROTATION AUTOMATIQUE DES LOGS (logrotate)
###########################################
# Remplace l'ancien menu « Rotation des logs » : logrotate est lancé chaque
# jour par Debian (cron/systemd), plus rien à faire à la main. copytruncate
# est obligatoire : rtorrent garde son fichier de log ouvert en permanence.
# Couvre les logs sur disque local (volume /local) ET les anciens chemins
# NFS des clients pas encore migrés.

install_logrotate() {
    cat > /etc/logrotate.d/laboboxvpn << EOF
# LaboBox-VPN - rotation automatique des logs rtorrent (généré)
${CLIENTS_DIR}/*/local/log/*.log ${NAS_MOUNT}/${NAS_SHARE_PREFIX}*/docker_apps/rtorrent/log/*.log {
    size 10M
    rotate 3
    missingok
    notifempty
    copytruncate
    compress
    delaycompress
    su root root
}
EOF
}

###########################################
# FONCTIONS CLIENTS
###########################################

parse_args() {
    ARG_USER=""
    ARG_PASSWORD=""
    ARG_PORT_WEBUI=""
    ARG_PORT_RT=""
    ARG_UID=""
    ARG_VPN_CONFIG=""
    ARG_TEMP=""
    OTHER_ARGS=()

    for arg in "$@"; do
        case $arg in
            --USER=*)                   ARG_USER="${arg#*=}" ;;
            --PASSWORD=*)               ARG_PASSWORD="${arg#*=}" ;;
            --PORT_RUTORRENT_WEBUI=*)   ARG_PORT_WEBUI="${arg#*=}" ;;
            --PORT_RTORRENT_VPN=*)      ARG_PORT_RT="${arg#*=}" ;;
            --UID=*)                    ARG_UID="${arg#*=}" ;;
            --VPN_CONFIG=*)             ARG_VPN_CONFIG="${arg#*=}" ;;
            --TEMP=*)                   ARG_TEMP="${arg#*=}" ;;
            *)                          OTHER_ARGS+=("$arg") ;;
        esac
    done
}

get_next_port() {
    local port_type=$1
    
    # Convention :
    # - WebUI ruTorrent : 100X (1001, 1002, 1003...)
    # - Port rtorrent/VPN : 110X (1101, 1102, 1103...)
    # Où X est le numéro du client
    
    local base_port
    case "$port_type" in
        webui)   base_port=1000 ;;
        rt)      base_port=1100 ;;
        *)       base_port=1000 ;;
    esac
    
    # Trouver le prochain numéro disponible
    local next_num=1
    if [ -d "$CLIENTS_DIR" ]; then
        for client_dir in "$CLIENTS_DIR"/*/; do
            if [ -f "$client_dir/info.txt" ]; then
                local used_port
                case "$port_type" in
                    webui)   used_port=$(grep "PORT_RUTORRENT_WEBUI" "$client_dir/info.txt" 2>/dev/null | cut -d: -f2 | tr -d ' ') ;;
                    rt)      used_port=$(grep "PORT_RTORRENT_VPN" "$client_dir/info.txt" 2>/dev/null | cut -d: -f2 | tr -d ' ') ;;
                esac
                if [ -n "$used_port" ]; then
                    local used_num=$((used_port - base_port))
                    if [ "$used_num" -ge "$next_num" ]; then
                        next_num=$((used_num + 1))
                    fi
                fi
            fi
        done
    fi
    
    echo $((base_port + next_num))
}

get_suggested_uid() {
    # Convention UID/GID : 120X (1201, 1202, 1203...)
    # Où X est le numéro du client
    
    local base_uid=1200
    local next_num=1
    
    if [ -d "$CLIENTS_DIR" ]; then
        for client_dir in "$CLIENTS_DIR"/*/; do
            if [ -f "$client_dir/info.txt" ]; then
                local used_uid=$(grep "^UID:" "$client_dir/info.txt" 2>/dev/null | cut -d: -f2 | tr -d ' ')
                if [ -n "$used_uid" ]; then
                    local used_num=$((used_uid - base_uid))
                    if [ "$used_num" -ge "$next_num" ]; then
                        next_num=$((used_num + 1))
                    fi
                fi
            fi
        done
    fi
    
    echo $((base_uid + next_num))
}

client_exists() {
    [ -d "$CLIENTS_DIR/$1" ] && [ -f "$CLIENTS_DIR/$1/docker-compose.yml" ]
}

get_clients() {
    [ ! -d "$CLIENTS_DIR" ] && return
    for dir in "$CLIENTS_DIR"/*/; do
        [ -f "$dir/docker-compose.yml" ] && basename "$dir"
    done
}

get_server_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost"
}

get_vpn_ip() {
    local client=$1
    # timeout : un tunnel pas encore établi ne doit pas geler l'affichage
    timeout 10 docker exec gluetun-$client wget -qO- https://api.ipify.org 2>/dev/null
}

get_container_uptime() {
    local container=$1
    local started=$(docker inspect --format='{{.State.StartedAt}}' "$container" 2>/dev/null)
    [ -z "$started" ] && echo "-" && return
    
    local start_ts=$(date -d "$started" +%s 2>/dev/null)
    [ -z "$start_ts" ] && echo "-" && return
    
    local now_ts=$(date +%s)
    local diff=$((now_ts - start_ts))
    
    if [ $diff -lt 60 ]; then
        echo "${diff}s"
    elif [ $diff -lt 3600 ]; then
        echo "$((diff / 60))m"
    elif [ $diff -lt 86400 ]; then
        echo "$((diff / 3600))h $((diff % 3600 / 60))m"
    else
        echo "$((diff / 86400))j $((diff % 86400 / 3600))h"
    fi
}

setup_sftp_chroot() {
    # Toujours créer le groupe s'il n'existe pas
    if ! getent group laboboxvpn >/dev/null 2>&1; then
        groupadd laboboxvpn
    fi
    
    # Ajouter la config SSH si elle n'existe pas
    if ! grep -q "^Match Group laboboxvpn" /etc/ssh/sshd_config 2>/dev/null; then
        cat >> /etc/ssh/sshd_config << 'EOF'

# SFTP Chroot pour laboboxvpn
Match Group laboboxvpn
    ChrootDirectory /home/%u
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
EOF
        systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
    fi
}

create_linux_user() {
    local USER=$1
    local PASSWORD=$2
    local USER_UID=${3:-}
    local MOUNT_PATH=$(get_client_mount_path $USER)
    local DATA_PATH=$(get_client_data_path $USER)
    
    if ! id "$USER" &>/dev/null; then
        if [ -n "$USER_UID" ]; then
            # Créer le groupe avec le GID spécifié
            groupadd -g "$USER_UID" "$USER" 2>/dev/null || true
            # Créer l'utilisateur avec l'UID/GID spécifié
            useradd -M -d "/home/$USER" -s /bin/false -u "$USER_UID" -g "$USER_UID" -G laboboxvpn "$USER"
        else
            useradd -M -d "/home/$USER" -s /bin/false -G laboboxvpn "$USER"
        fi
        echo "$USER:$PASSWORD" | chpasswd
    else
        usermod -aG laboboxvpn "$USER" 2>/dev/null || true
    fi
    
    # Créer le home avec les bonnes permissions pour chroot SFTP
    mkdir -p "/home/$USER/data"
    chown root:root "/home/$USER"
    chmod 755 "/home/$USER"
    
    # Créer les dossiers sur le NAS si montage OK
    if check_nas_mounted_for_client "$USER"; then
        mkdir -p "${DATA_PATH}/torrents/films"
        mkdir -p "${DATA_PATH}/torrents/series"
        mkdir -p "${DATA_PATH}/torrents/autres"
        mkdir -p "${DATA_PATH}/watch/films"
        mkdir -p "${DATA_PATH}/watch/series"
        mkdir -p "${DATA_PATH}/watch/autres"
        
        # Note: Les permissions sont gérées côté NAS via NFS squash
        # On ne fait pas de chown ici car NFS "Mapper sur admin" le gère
    fi
    
    # Utiliser bind mount au lieu de lien symbolique (nécessaire pour SFTP chrooté)
    if ! mountpoint -q "/home/$USER/data" 2>/dev/null; then
        mount --bind "${DATA_PATH}" "/home/$USER/data" 2>/dev/null || true
    fi
}

add_bindmount_to_fstab() {
    local USER=$1
    local DATA_PATH=$(get_client_data_path $USER)
    local NFS_MOUNT_PATH=$(get_client_mount_path $USER)

    # Ajouter le bind mount au fstab s'il n'existe pas
    if ! grep -q "/home/$USER/data" /etc/fstab 2>/dev/null; then
        echo "${DATA_PATH} /home/$USER/data none bind,x-systemd.requires-mounts-for=${NFS_MOUNT_PATH},_netdev 0 0" >> /etc/fstab
        systemctl daemon-reload 2>/dev/null || true
    fi
}

remove_bindmount_from_fstab() {
    local USER=$1
    sed -i "\|/home/$USER/data|d" /etc/fstab 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
}

remove_linux_user() {
    local USER=$1
    if id "$USER" &>/dev/null; then
        userdel "$USER" 2>/dev/null || true
    fi
}

###########################################
# COMMANDE: ADD
###########################################
cmd_add() {
    local CLIENT="$1"
    local PASSWORD="$2"
    local VPN_CONFIG="$3"
    local PORT_WEBUI="${4:-$(get_next_port webui)}"
    local PORT_RT="${5:-$(get_next_port rt)}"
    local USER_UID="${6:-}"
    local USE_TEMP="${7:-}"

    # Disque SSD temporaire : actif par défaut quand TEMP_DIR est configuré
    if [ -z "$USE_TEMP" ]; then
        USE_TEMP="no"
        [ -n "$TEMP_DIR" ] && USE_TEMP="yes"
    fi
    [ -z "$TEMP_DIR" ] && USE_TEMP="no"

    local NAS_SHARE_NAME=$(get_nas_share_name $CLIENT)
    local CLIENT_MOUNT_PATH=$(get_client_mount_path $CLIENT)
    local DOCKER_APPS_PATH=$(get_client_docker_apps_path $CLIENT)
    local DATA_PATH=$(get_client_data_path $CLIENT)
    
    local total_steps=7
    
    # Header
    print_header_with_title "CRÉATION DU CLIENT: ${CLIENT}"
    
    # Étape 1: WireGuard
    print_step 1 $total_steps "Lecture configuration WireGuard"
    
    WG_PRIVATE_KEY=$(grep -i "PrivateKey" "$VPN_CONFIG" | cut -d'=' -f2- | tr -d ' ')
    WG_ADDRESS=$(grep -i "Address" "$VPN_CONFIG" | cut -d'=' -f2- | tr -d ' ')
    WG_PUBLIC_KEY=$(grep -i "PublicKey" "$VPN_CONFIG" | cut -d'=' -f2- | tr -d ' ')
    WG_PRESHARED_KEY=$(grep -i "PresharedKey" "$VPN_CONFIG" | cut -d'=' -f2- | tr -d ' ' || echo "")
    WG_ENDPOINT=$(grep -i "Endpoint" "$VPN_CONFIG" | cut -d'=' -f2- | tr -d ' ')
    WG_ENDPOINT_IP=$(echo "$WG_ENDPOINT" | cut -d':' -f1)
    WG_ENDPOINT_PORT=$(echo "$WG_ENDPOINT" | cut -d':' -f2)
    
    if [ -z "$WG_PRIVATE_KEY" ] || [ -z "$WG_PUBLIC_KEY" ]; then
        print_step_item_last "Status" "${RED}✗ Fichier invalide${NC}"
        print_footer
        return 1
    fi
    
    print_step_item "Fichier" "$VPN_CONFIG"
    print_step_item "Endpoint" "${WG_ENDPOINT_IP}:${WG_ENDPOINT_PORT}"
    print_step_item "Adresse VPN" "$WG_ADDRESS"
    print_step_item_last "Status" "${GREEN}✔ Valide${NC}"
    echo ""
    
    # Étape 2: Instructions NAS avec pause
    print_step 2 $total_steps "Configuration NAS Synology"
    echo ""
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}📋 CRÉEZ LE DOSSIER PARTAGÉ SUR LE NAS${NC}"
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${WHITE}1. Panneau de configuration → Dossier partagé → Créer${NC}"
    echo ""
    echo -e "    Nom : ${CYAN}${NAS_SHARE_NAME}${NC}"
    echo ""
    echo -e "  ${WHITE}2. Onglet Avancés :${NC}"
    echo -e "    ✔ Activer le quota du dossier partagé"
    echo -e "    Quota : ${CYAN}[Définir la taille souhaitée]${NC}"
    echo ""
    echo -e "  ${WHITE}3. Onglet Autorisations NFS → Créer :${NC}"
    echo -e "    Nom d'hôte : ${CYAN}$(hostname -I | awk '{print $1}')${NC}"
    echo -e "    Privilège : ${CYAN}Lecture/Écriture${NC}"
    echo -e "    Squash : ${CYAN}Mapper tous les utilisateurs sur admin${NC}"
    echo ""
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -ne "  ${WHITE}Appuyez sur ENTRÉE une fois le dossier partagé créé...${NC}"
    read
    echo ""
    
    # Étape 3: Montage NAS
    print_step 3 $total_steps "Montage NAS" "wait"
    
    if mount_nas_for_client "$CLIENT"; then
        echo -e "\r  ${DIM}[3/7]${NC} Montage NAS ${DIM}...${NC} ${GREEN}✔${NC}"
        print_step_item "Partage" "$NAS_SHARE_NAME"
        print_step_item_last "Montage" "$CLIENT_MOUNT_PATH"
        add_fstab_for_client "$CLIENT"
    else
        echo -e "\r  ${DIM}[3/7]${NC} Montage NAS ${DIM}...${NC} ${RED}✗${NC}"
        echo ""
        echo -e "  ${RED}Impossible de monter le NAS. Vérifiez :${NC}"
        echo -e "  ├─ Le dossier partagé '${NAS_SHARE_NAME}' existe"
        echo -e "  ├─ NFS est activé sur le NAS"
        echo -e "  └─ Les permissions NFS sont configurées"
        print_footer
        return 1
    fi
    echo ""
    
    # Étape 4: Création arborescence NAS
    print_step 4 $total_steps "Création arborescence NAS"
    
    # Créer docker_apps sur le NAS
    mkdir -p "${DOCKER_APPS_PATH}/gluetun"
    mkdir -p "${DOCKER_APPS_PATH}/rtorrent/.session"
    mkdir -p "${DOCKER_APPS_PATH}/rtorrent/log"
    mkdir -p "${DOCKER_APPS_PATH}/rutorrent"
    
    # Créer data sur le NAS
    mkdir -p "${DATA_PATH}/torrents/films"
    mkdir -p "${DATA_PATH}/torrents/series"
    mkdir -p "${DATA_PATH}/torrents/autres"
    mkdir -p "${DATA_PATH}/watch/films"
    mkdir -p "${DATA_PATH}/watch/series"
    mkdir -p "${DATA_PATH}/watch/autres"
    
    print_step_item "docker_apps" "${DOCKER_APPS_PATH}"
    print_step_item_last "data" "${DATA_PATH}"
    echo ""
    
    # Étape 5: Utilisateur système
    print_step 5 $total_steps "Création utilisateur système"
    setup_sftp_chroot
    create_linux_user "$CLIENT" "$PASSWORD" "$USER_UID"
    USER_UID=$(id -u "$CLIENT")
    USER_GID=$(id -g "$CLIENT")
    
    # Ajouter le bind mount au fstab pour persistance
    add_bindmount_to_fstab "$CLIENT"
    
    print_step_item "Login" "$CLIENT"
    print_step_item "UID/GID" "${USER_UID}:${USER_GID}"
    print_step_item "Home" "/home/${CLIENT}"
    print_step_item "SFTP" "/data (bind mount)"
    print_step_item_last "Status" "${GREEN}✔ Créé${NC}"
    echo ""
    
    # Étape 6: Docker compose
    print_step 6 $total_steps "Génération docker-compose.yml"

    mkdir -p "$CLIENTS_DIR/$CLIENT"

    # Disque SSD temporaire : dossier hôte + volume /temp du conteneur
    # (la variable embarque son propre saut de ligne pour ne rien laisser
    #  dans le compose quand l'option est désactivée)
    local TEMP_VOLUME_LINE=""
    if [ "$USE_TEMP" = "yes" ]; then
        mkdir -p "${TEMP_DIR}/${CLIENT}"
        chown "${USER_UID}:${USER_GID}" "${TEMP_DIR}/${CLIENT}" 2>/dev/null || true
        TEMP_VOLUME_LINE=$'\n'"      - ${TEMP_DIR}/${CLIENT}:/temp"
    fi

    cat > "$CLIENTS_DIR/$CLIENT/docker-compose.yml" << EOF
###############################################
# CLIENT: $CLIENT
# Créé le: $(date '+%Y-%m-%d %H:%M')
# NAS: ${NAS_SHARE_NAME}
# WebUI: $PORT_WEBUI | RT: $PORT_RT
###############################################

services:

  gluetun-$CLIENT:
    image: qmcgaw/gluetun:latest
    container_name: gluetun-$CLIENT
    restart: no
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      - $PORT_WEBUI:8080
      - $PORT_RT:$PORT_RT
      - $PORT_RT:$PORT_RT/udp
    environment:
      - VPN_SERVICE_PROVIDER=custom
      - VPN_TYPE=wireguard
      - WIREGUARD_ENDPOINT_IP=$WG_ENDPOINT_IP
      - WIREGUARD_ENDPOINT_PORT=$WG_ENDPOINT_PORT
      - WIREGUARD_PUBLIC_KEY=$WG_PUBLIC_KEY
      - WIREGUARD_PRIVATE_KEY=$WG_PRIVATE_KEY
      - WIREGUARD_PRESHARED_KEY=$WG_PRESHARED_KEY
      - WIREGUARD_ADDRESSES=$WG_ADDRESS
      - FIREWALL_VPN_INPUT_PORTS=$PORT_RT
      - WIREGUARD_PERSISTENT_KEEPALIVE_INTERVAL=25s
      - DOT=off
      - DNS_ADDRESS=1.1.1.1
      - TZ=Europe/Paris
    volumes:
      - ${DOCKER_APPS_PATH}/gluetun:/gluetun
    healthcheck:
      test: ["CMD", "/gluetun-entrypoint", "healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 3

  rtorrent-$CLIENT:
    image: laboboxvpn/rtorrent-rutorrent:latest
    container_name: rtorrent-$CLIENT
    restart: no
    network_mode: "service:gluetun-$CLIENT"
    depends_on:
      gluetun-$CLIENT:
        condition: service_healthy
    environment:
      - PUID=$USER_UID
      - PGID=$USER_GID
      - TZ=Europe/Paris
      - RT_PORT=$PORT_RT
      - RT_DHT=off
      - RT_PEX=no
      - RT_ENCRYPTION=allow_incoming,try_outgoing,enable_retry
      - RT_CHECK_HASH=no
      - RU_USER=$CLIENT
      - RU_PASSWORD=$PASSWORD
      - TOP_DIR=/data/
      - RU_DISABLED_PLUGINS=throttle,dump,log_history
      - RT_MAX_TORRENT_SIZE=${MAX_TORRENT_SIZE:-0}
    volumes:
      - ${DOCKER_APPS_PATH}/rtorrent:/config/rtorrent
      - ${DOCKER_APPS_PATH}/rutorrent:/config/rutorrent
      - ${DATA_PATH}:/data
      - ${CLIENTS_DIR}/${CLIENT}/local:/local${TEMP_VOLUME_LINE}
    ulimits:
      nproc: 65535
      nofile:
        soft: 32000
        hard: 40000
EOF
    
    # Sauvegarder les infos
    cat > "$CLIENTS_DIR/$CLIENT/info.txt" << EOF
CLIENT: $CLIENT
DATE: $(date '+%Y-%m-%d %H:%M')
PORT_RUTORRENT_WEBUI: $PORT_WEBUI
PORT_RTORRENT_VPN: $PORT_RT
PASSWORD: $PASSWORD
UID: $USER_UID
GID: $USER_GID
VPN_ENDPOINT: $WG_ENDPOINT_IP:$WG_ENDPOINT_PORT
VPN_ADDRESS: $WG_ADDRESS
NAS_SHARE: $NAS_SHARE_NAME
MOUNT_PATH: $CLIENT_MOUNT_PATH
DOCKER_APPS: $DOCKER_APPS_PATH
DATA_PATH: $DATA_PATH
TEMP_PATH: $([ "$USE_TEMP" = "yes" ] && echo "${TEMP_DIR}/${CLIENT}" || echo "-")
EOF
    
    print_step_item "Conteneur VPN" "gluetun-${CLIENT}"
    print_step_item "Conteneur rtorrent" "rtorrent-${CLIENT}"
    print_step_item_last "Status" "${GREEN}✔ Généré${NC}"
    echo ""
    
    # Étape 7: Démarrage
    print_step 7 $total_steps "Démarrage des services"
    
    cd "$CLIENTS_DIR/$CLIENT"
    docker compose up -d >/dev/null 2>&1
    
    sleep 8
    
    local gluetun_ok=""
    local rtorrent_ok=""
    local vpn_ip=""
    
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "gluetun-$CLIENT"; then
        gluetun_ok="1"
        vpn_ip=$(get_vpn_ip "$CLIENT")
    fi
    
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "rtorrent-$CLIENT"; then
        rtorrent_ok="1"
    fi
    
    if [ -n "$gluetun_ok" ]; then
        print_step_item "Gluetun" "${GREEN}✔ Démarré${NC}"
    else
        print_step_item "Gluetun" "${RED}✗ Erreur${NC}"
    fi
    
    if [ -n "$vpn_ip" ]; then
        print_step_item "Connexion VPN" "${GREEN}✔ Connecté (${vpn_ip})${NC}"
    else
        print_step_item "Connexion VPN" "${YELLOW}⏳ En attente...${NC}"
        vpn_ip="En attente..."
    fi
    
    if [ -n "$rtorrent_ok" ]; then
        print_step_item "rtorrent" "${GREEN}✔ Démarré${NC}"
        print_step_item_last "ruTorrent" "${GREEN}✔ Accessible${NC}"
    else
        print_step_item "rtorrent" "${RED}✗ Erreur${NC}"
        print_step_item_last "ruTorrent" "${RED}✗ Inaccessible${NC}"
    fi
    
    # Résultat final
    local SERVER_IP=$(get_server_ip)
    
    print_success_box "CLIENT CRÉÉ AVEC SUCCÈS"
    echo ""
    print_section "ACCÈS RUTORRENT"
    print_item "URL" "http://${SERVER_IP}:${PORT_WEBUI}"
    print_item "Identifiant" "$CLIENT"
    print_item_last "Mot de passe" "$PASSWORD"
    echo ""
    print_section "ACCÈS SFTP"
    print_item "Hôte" "$SERVER_IP"
    print_item "Port" "$SSH_PORT"
    print_item "Identifiant" "$CLIENT"
    print_item "Mot de passe" "$PASSWORD"
    print_item_last "Répertoire" "/data"
    echo ""
    print_section "INFORMATIONS VPN"
    print_item "IP publique" "$vpn_ip"
    print_item "Port torrent" "$PORT_RT"
    print_item_last "Kill switch" "Actif"
    echo ""
    print_section "STOCKAGE"
    print_item "Dossier partagé" "$NAS_SHARE_NAME"
    print_item "Configs Docker" "${DOCKER_APPS_PATH}"
    print_item "Données client" "${DATA_PATH}"
    if [ "$USE_TEMP" = "yes" ]; then
        print_item_last "Téléchargements" "${TEMP_DIR}/${CLIENT} ${DIM}(SSD → NAS à la complétion)${NC}"
    else
        print_item_last "Téléchargements" "directs sur le NAS"
    fi
    
    # Synchroniser les bibliothèques Plex/Jellyfin/Resilio si installées
    local synced_apps=""
    if is_jellyfin_installed 2>/dev/null; then
        cmd_update_media_libs_silent "jellyfin" 2>/dev/null
        synced_apps="${synced_apps}Jellyfin "
    fi
    if is_plex_installed 2>/dev/null; then
        cmd_update_media_libs_silent "plex" 2>/dev/null
        synced_apps="${synced_apps}Plex "
    fi
    if is_resilio_installed 2>/dev/null; then
        cmd_update_media_libs_silent "resilio" 2>/dev/null
        synced_apps="${synced_apps}Resilio"
    fi
    if [ -n "$synced_apps" ]; then
        echo ""
        print_section "STREAMING & SYNC"
        print_item_last "Bibliothèques" "Synchronisées (${synced_apps})"
    fi
    
    print_footer
}

###########################################
# COMMANDE: REMOVE
###########################################
cmd_remove() {
    local CLIENT=$1
    
    if ! client_exists "$CLIENT"; then
        print_error_box "Le client '${CLIENT}' n'existe pas."
        return 1
    fi
    
    local CLIENT_MOUNT_PATH=$(get_client_mount_path $CLIENT)
    local NAS_SHARE_NAME=$(get_nas_share_name $CLIENT)
    
    local quota_bytes=$(get_nas_quota_bytes "$CLIENT")
    local used_bytes=$(get_nas_used_bytes "$CLIENT")
    local used_human=$(format_bytes $used_bytes)
    local user_uid=$(id -u "$CLIENT" 2>/dev/null || echo "?")
    
    # Vérifier si des apps sont installées
    local has_apps=""
    is_jellyfin_installed && has_apps="1"
    is_plex_installed && has_apps="1"
    is_resilio_installed && has_apps="1"
    
    local total_steps=4
    [ -n "$has_apps" ] && total_steps=5
    
    print_header_with_title "⚠ SUPPRESSION DU CLIENT: ${CLIENT}"
    
    echo "  Cette action va supprimer:"
    print_item "Conteneurs Docker" "gluetun-${CLIENT}, rtorrent-${CLIENT}"
    print_item "Configuration locale" "${CLIENTS_DIR}/${CLIENT}/"
    print_item "Utilisateur système" "${CLIENT} (UID ${user_uid})"
    print_item_last "Montage NAS" "${CLIENT_MOUNT_PATH}"
    
    echo ""
    if ! confirm "Voulez-vous continuer ?"; then
        echo ""
        echo -e "  ${YELLOW}Opération annulée.${NC}"
        print_footer
        return 0
    fi
    
    echo ""
    echo -e "  ${YELLOW}Les données sur le NAS (${NAS_SHARE_NAME}) contiennent ${used_human}.${NC}"
    echo -e "  ${DIM}Le dossier partagé doit être supprimé manuellement via DSM si souhaité.${NC}"
    line
    
    echo ""
    
    # Étape 1
    print_step 1 $total_steps "Arrêt des conteneurs" "wait"
    cd "$CLIENTS_DIR/$CLIENT" 2>/dev/null || cd "$INSTALL_DIR"
    docker compose down >/dev/null 2>&1 || true
    echo -e "\r  ${DIM}[1/${total_steps}]${NC} Arrêt des conteneurs ${DIM}...${NC} ${GREEN}✔${NC}"
    
    # Étape 2
    print_step 2 $total_steps "Suppression conteneurs" "wait"
    docker rm -f gluetun-$CLIENT rtorrent-$CLIENT >/dev/null 2>&1 || true
    echo -e "\r  ${DIM}[2/${total_steps}]${NC} Suppression conteneurs ${DIM}...${NC} ${GREEN}✔${NC}"
    
    # Étape 3
    print_step 3 $total_steps "Démontage et nettoyage" "wait"
    # Démonter le bind mount d'abord
    if mountpoint -q "/home/$CLIENT/data" 2>/dev/null; then
        umount "/home/$CLIENT/data" 2>/dev/null || umount -l "/home/$CLIENT/data" 2>/dev/null || true
    fi
    remove_bindmount_from_fstab "$CLIENT"
    # Puis le NAS
    umount_nas_for_client "$CLIENT"
    remove_fstab_for_client "$CLIENT"
    rm -rf "$CLIENT_MOUNT_PATH" 2>/dev/null || true
    # Dossier du disque SSD temporaire (téléchargements en cours compris)
    if [ -n "$TEMP_DIR" ] && [ -d "${TEMP_DIR}/${CLIENT}" ]; then
        rm -rf "${TEMP_DIR:?}/${CLIENT:?}" 2>/dev/null || true
    fi
    echo -e "\r  ${DIM}[3/${total_steps}]${NC} Démontage et nettoyage ${DIM}...${NC} ${GREEN}✔${NC}"
    
    # Étape 4
    print_step 4 $total_steps "Suppression configuration" "wait"
    rm -rf "$CLIENTS_DIR/$CLIENT"
    remove_linux_user "$CLIENT"
    rm -rf "/home/$CLIENT"
    echo -e "\r  ${DIM}[4/${total_steps}]${NC} Suppression configuration ${DIM}...${NC} ${GREEN}✔${NC}"
    
    # Étape 5 - Synchroniser les bibliothèques si apps installées
    if [ -n "$has_apps" ]; then
        print_step 5 $total_steps "Synchronisation bibliothèques" "wait"
        local synced=""
        if is_jellyfin_installed; then
            cmd_update_media_libs_silent "jellyfin"
            synced="${synced}Jellyfin "
        fi
        if is_plex_installed; then
            cmd_update_media_libs_silent "plex"
            synced="${synced}Plex "
        fi
        if is_resilio_installed; then
            cmd_update_media_libs_silent "resilio"
            synced="${synced}Resilio "
        fi
        echo -e "\r  ${DIM}[5/${total_steps}]${NC} Synchronisation bibliothèques ${DIM}...${NC} ${GREEN}✔${NC} ${DIM}(${synced})${NC}"
    fi
    
    print_success_box "CLIENT SUPPRIMÉ"
    echo ""
    echo -e "  ${DIM}Pour supprimer les données du NAS :${NC}"
    echo -e "  ${DIM}DSM → File Station → Supprimer ${NAS_SHARE_NAME}${NC}"
    
    print_footer
}

###########################################
# COMMANDE: LIST
###########################################
cmd_list() {
    print_header
    
    local clients_active=()
    local clients_stopped=()
    local total_clients=0
    local total_used=0
    
    for client in $(get_clients); do
        ((total_clients++))
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "gluetun-$client"; then
            clients_active+=("$client")
        else
            clients_stopped+=("$client")
        fi
    done
    
    if [ $total_clients -eq 0 ]; then
        echo -e "  ${DIM}Aucun client configuré.${NC}"
        echo ""
        echo -e "  ${DIM}Créez votre premier client :${NC}"
        echo -e "  ${DIM}./laboboxvpn-manager.sh add --USER=xxx --PASSWORD=xxx --VPN_CONFIG=xxx${NC}"
        print_footer
        return
    fi
    
    # Clients actifs
    if [ ${#clients_active[@]} -gt 0 ]; then
        echo -e "  ${WHITE}CLIENTS ACTIFS${NC}                                               ${GREEN}${#clients_active[@]}${NC} / ${total_clients}"
        line
        echo ""
        
        for CLIENT in "${clients_active[@]}"; do
            local info_file="$CLIENTS_DIR/$CLIENT/info.txt"
            local PORT_WEBUI=$(grep "PORT_RUTORRENT_WEBUI" "$info_file" 2>/dev/null | cut -d: -f2 | tr -d ' ')
            local PORT_RT=$(grep "PORT_RTORRENT_VPN" "$info_file" 2>/dev/null | cut -d: -f2 | tr -d ' ')
            
            local VPN_IP=$(get_vpn_ip "$CLIENT")
            [ -z "$VPN_IP" ] && VPN_IP="-"
            
            local SERVER_IP=$(get_server_ip)
            local uptime=$(get_container_uptime "gluetun-$CLIENT")
            
            local quota_bytes=$(get_nas_quota_bytes "$CLIENT")
            local used_bytes=$(get_nas_used_bytes "$CLIENT")
            local quota_human=$(format_bytes $quota_bytes)
            local used_human=$(format_bytes $used_bytes)
            local percent=0
            [ $quota_bytes -gt 0 ] && percent=$((used_bytes * 100 / quota_bytes))
            [ $percent -gt 100 ] && percent=100
            
            total_used=$((total_used + used_bytes))
            
            echo -e "  ${GREEN}●${NC} ${WHITE}${CLIENT}${NC}"
            print_item "ruTorrent" "http://${SERVER_IP}:${PORT_WEBUI}"
            print_item "Port torrent" "${PORT_RT} ${DIM}(via VPN)${NC}"
            print_item "IP VPN" "$VPN_IP"
            print_item "Espace disque" "${used_human} / ${quota_human} (${percent}%)"
            print_item_last "Uptime" "$uptime"
            echo ""
        done
    fi
    
    # Clients arrêtés
    if [ ${#clients_stopped[@]} -gt 0 ]; then
        echo -e "  ${WHITE}CLIENTS ARRÊTÉS${NC}                                              ${RED}${#clients_stopped[@]}${NC} / ${total_clients}"
        line
        echo ""
        
        for CLIENT in "${clients_stopped[@]}"; do
            local info_file="$CLIENTS_DIR/$CLIENT/info.txt"
            local PORT_WEBUI=$(grep "PORT_RUTORRENT_WEBUI" "$info_file" 2>/dev/null | cut -d: -f2 | tr -d ' ')
            local DATE=$(grep "^DATE:" "$info_file" 2>/dev/null | cut -d: -f2- | tr -d ' ')
            
            local SERVER_IP=$(get_server_ip)
            
            local quota_bytes=$(get_nas_quota_bytes "$CLIENT")
            local used_bytes=$(get_nas_used_bytes "$CLIENT")
            local quota_human=$(format_bytes $quota_bytes)
            local used_human=$(format_bytes $used_bytes)
            
            total_used=$((total_used + used_bytes))
            
            echo -e "  ${RED}○${NC} ${WHITE}${CLIENT}${NC}"
            print_item "ruTorrent" "http://${SERVER_IP}:${PORT_WEBUI}"
            if [ $quota_bytes -gt 0 ]; then
                print_item "Espace disque" "${used_human} / ${quota_human}"
            else
                print_item "Espace disque" "${DIM}NAS non monté${NC}"
            fi
            print_item_last "Créé le" "${DATE:-Inconnue}"
            echo ""
        done
    fi
    
    local total_used_human=$(format_bytes $total_used)
    print_footer_with_summary "Résumé: ${total_clients} clients │ ${#clients_active[@]} actifs │ ${#clients_stopped[@]} arrêtés │ ${total_used_human} utilisés"
}

###########################################
# COMMANDE: STATUS
###########################################
cmd_status() {
    local CLIENT=$1
    
    if ! client_exists "$CLIENT"; then
        print_error_box "Le client '${CLIENT}' n'existe pas."
        return 1
    fi
    
    local info_file="$CLIENTS_DIR/$CLIENT/info.txt"
    local DATE=$(grep "^DATE:" "$info_file" 2>/dev/null | cut -d: -f2- | xargs)
    local PORT_WEBUI=$(grep "PORT_RUTORRENT_WEBUI" "$info_file" 2>/dev/null | cut -d: -f2 | tr -d ' ')
    local PORT_RT=$(grep "PORT_RTORRENT_VPN" "$info_file" 2>/dev/null | cut -d: -f2 | tr -d ' ')
    local VPN_ENDPOINT=$(grep "VPN_ENDPOINT" "$info_file" 2>/dev/null | cut -d: -f2- | tr -d ' ')
    local USER_UID=$(grep "^UID:" "$info_file" 2>/dev/null | cut -d: -f2 | tr -d ' ')
    local USER_GID=$(grep "^GID:" "$info_file" 2>/dev/null | cut -d: -f2 | tr -d ' ')
    local NAS_SHARE=$(grep "^NAS_SHARE:" "$info_file" 2>/dev/null | cut -d: -f2 | tr -d ' ')
    
    local is_running=""
    local status_text="${RED}○ Arrêté${NC}"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "gluetun-$CLIENT"; then
        is_running="1"
        status_text="${GREEN}● Actif${NC}"
    fi
    
    print_header_with_title "STATUS: ${CLIENT}" "                                                    ${status_text}"
    
    local SERVER_IP=$(get_server_ip)
    
    # Informations générales
    print_section "INFORMATIONS"
    print_item "Date création" "$DATE"
    print_item "UID/GID" "${USER_UID}:${USER_GID}"
    print_item_last "Configuration" "${CLIENTS_DIR}/${CLIENT}/"
    echo ""
    
    # Services
    print_section "SERVICES"
    local gluetun_status="${RED}✗ Arrêté${NC}"
    local rtorrent_status="${RED}✗ Arrêté${NC}"
    
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "gluetun-$CLIENT"; then
        local uptime=$(get_container_uptime "gluetun-$CLIENT")
        gluetun_status="${GREEN}✔ Actif${NC} ${DIM}(uptime: ${uptime})${NC}"
    fi
    
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "rtorrent-$CLIENT"; then
        local uptime=$(get_container_uptime "rtorrent-$CLIENT")
        rtorrent_status="${GREEN}✔ Actif${NC} ${DIM}(uptime: ${uptime})${NC}"
    fi
    
    print_item "gluetun-${CLIENT}" "$gluetun_status"
    print_item_last "rtorrent-${CLIENT}" "$rtorrent_status"
    echo ""
    
    # Réseau
    print_section "RÉSEAU"
    local VPN_IP="-"
    [ -n "$is_running" ] && VPN_IP=$(get_vpn_ip "$CLIENT")
    [ -z "$VPN_IP" ] && VPN_IP="-"
    
    print_item "ruTorrent" "http://${SERVER_IP}:${PORT_WEBUI}"
    print_item "Port torrent" "$PORT_RT"
    print_item "IP VPN" "$VPN_IP"
    print_item_last "Endpoint VPN" "$VPN_ENDPOINT"
    echo ""
    
    # Stockage NAS
    print_section "STOCKAGE NAS"
    local CLIENT_MOUNT_PATH=$(get_client_mount_path $CLIENT)
    local quota_bytes=$(get_nas_quota_bytes "$CLIENT")
    local used_bytes=$(get_nas_used_bytes "$CLIENT")
    local quota_human=$(format_bytes $quota_bytes)
    local used_human=$(format_bytes $used_bytes)
    local available_bytes=$((quota_bytes - used_bytes))
    [ $available_bytes -lt 0 ] && available_bytes=0
    local available_human=$(format_bytes $available_bytes)
    local percent=0
    [ $quota_bytes -gt 0 ] && percent=$((used_bytes * 100 / quota_bytes))
    [ $percent -gt 100 ] && percent=100
    
    print_item "Dossier partagé" "${NAS_SHARE:-$(get_nas_share_name $CLIENT)}"
    print_item "Point de montage" "$CLIENT_MOUNT_PATH"
    if [ $quota_bytes -gt 0 ]; then
        print_item "Espace utilisé" "$used_human"
        print_item "Quota NAS" "$quota_human"
        print_item "Disponible" "$available_human"
        print_item_last "Utilisation" "$(progress_bar $percent)"
    else
        print_item_last "Status" "${RED}NAS non monté${NC}"
    fi
    echo ""
    
    # SFTP
    print_section "ACCÈS SFTP"
    print_item "Hôte" "$SERVER_IP"
    print_item "Port" "$SSH_PORT"
    print_item "Identifiant" "$CLIENT"
    print_item_last "Répertoire" "/data"
    
    print_footer
}

###########################################
# COMMANDE: START
###########################################
cmd_start() {
    local CLIENT=$1
    
    if [ -z "$CLIENT" ]; then
        # Démarrer tous
        print_header_with_title "DÉMARRAGE DE TOUS LES CLIENTS"
        
        local count=0
        for client in $(get_clients); do
            mount_nas_for_client "$client" 2>/dev/null || true
            cd "$CLIENTS_DIR/$client"
            echo -ne "  ${DIM}Démarrage de ${client}...${NC}"
            docker compose up -d >/dev/null 2>&1
            echo -e "\r  ${GREEN}✔${NC} ${client} démarré                    "
            ((count++))
        done
        
        print_success_box "${count} client(s) démarré(s)"
        print_footer
        return
    fi
    
    if ! client_exists "$CLIENT"; then
        print_error_box "Le client '${CLIENT}' n'existe pas."
        return 1
    fi
    
    print_header_with_title "DÉMARRAGE: ${CLIENT}"
    
    mount_nas_for_client "$CLIENT" 2>/dev/null || true
    
    cd "$CLIENTS_DIR/$CLIENT"
    echo -ne "  ${DIM}Démarrage des conteneurs...${NC}"
    docker compose up -d >/dev/null 2>&1
    echo -e "\r  ${GREEN}✔${NC} Conteneurs démarrés              "
    
    sleep 5
    
    local vpn_ip=$(get_vpn_ip "$CLIENT")
    if [ -n "$vpn_ip" ]; then
        echo -e "  ${GREEN}✔${NC} VPN connecté: ${vpn_ip}"
    else
        echo -e "  ${YELLOW}⏳${NC} VPN en cours de connexion..."
    fi
    
    print_success_box "CLIENT DÉMARRÉ"
    print_footer
}

###########################################
# COMMANDE: STOP
###########################################
cmd_stop() {
    local CLIENT=$1
    
    if [ -z "$CLIENT" ]; then
        # Arrêter tous
        print_header_with_title "ARRÊT DE TOUS LES CLIENTS"
        
        local count=0
        for client in $(get_clients); do
            cd "$CLIENTS_DIR/$client"
            echo -ne "  ${DIM}Arrêt de ${client}...${NC}"
            docker compose down >/dev/null 2>&1
            echo -e "\r  ${GREEN}✔${NC} ${client} arrêté                    "
            ((count++))
        done
        
        print_success_box "${count} client(s) arrêté(s)"
        print_footer
        return
    fi
    
    if ! client_exists "$CLIENT"; then
        print_error_box "Le client '${CLIENT}' n'existe pas."
        return 1
    fi
    
    print_header_with_title "ARRÊT: ${CLIENT}"
    
    cd "$CLIENTS_DIR/$CLIENT"
    echo -ne "  ${DIM}Arrêt des conteneurs...${NC}"
    docker compose down >/dev/null 2>&1
    echo -e "\r  ${GREEN}✔${NC} Conteneurs arrêtés              "
    
    print_success_box "CLIENT ARRÊTÉ"
    print_footer
}

###########################################
# COMMANDE: RESTART
###########################################
cmd_restart() {
    local CLIENT=$1
    
    if [ -z "$CLIENT" ]; then
        # Redémarrer tous
        print_header_with_title "REDÉMARRAGE DE TOUS LES CLIENTS"
        
        local count=0
        for client in $(get_clients); do
            mount_nas_for_client "$client" 2>/dev/null || true
            cd "$CLIENTS_DIR/$client"
            echo -ne "  ${DIM}Redémarrage de ${client}...${NC}"
            docker compose down >/dev/null 2>&1
            docker compose up -d >/dev/null 2>&1
            echo -e "\r  ${GREEN}✔${NC} ${client} redémarré                    "
            ((count++))
        done
        
        print_success_box "${count} client(s) redémarré(s)"
        print_footer
        return
    fi
    
    if ! client_exists "$CLIENT"; then
        print_error_box "Le client '${CLIENT}' n'existe pas."
        return 1
    fi
    
    print_header_with_title "REDÉMARRAGE: ${CLIENT}"
    
    mount_nas_for_client "$CLIENT" 2>/dev/null || true
    
    cd "$CLIENTS_DIR/$CLIENT"
    echo -ne "  ${DIM}Arrêt des conteneurs...${NC}"
    docker compose down >/dev/null 2>&1
    echo -e "\r  ${GREEN}✔${NC} Conteneurs arrêtés              "
    
    echo -ne "  ${DIM}Démarrage des conteneurs...${NC}"
    docker compose up -d >/dev/null 2>&1
    echo -e "\r  ${GREEN}✔${NC} Conteneurs démarrés              "
    
    sleep 5
    
    local vpn_ip=$(get_vpn_ip "$CLIENT")
    if [ -n "$vpn_ip" ]; then
        echo -e "  ${GREEN}✔${NC} VPN connecté: ${vpn_ip}"
    else
        echo -e "  ${YELLOW}⏳${NC} VPN en cours de connexion..."
    fi
    
    print_success_box "CLIENT REDÉMARRÉ"
    print_footer
}

###########################################
# COMMANDE: LOGS
###########################################
cmd_logs() {
    local CLIENT=$1
    local SERVICE=${2:-rtorrent}

    if ! client_exists "$CLIENT"; then
        print_error_box "Le client '${CLIENT}' n'existe pas."
        return 1
    fi

    local container="rtorrent-${CLIENT}"
    [ "$SERVICE" = "gluetun" ] && container="gluetun-${CLIENT}"

    echo ""
    echo -e "  ${DIM}══════════════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${WHITE}LOGS: ${container}${NC}"
    echo -e "  ${DIM}══════════════════════════════════════════════════════════════════════${NC}"
    echo ""

    # Le conteneur existe-t-il (demarre OU arrete mais pas supprime) ?
    # Un `docker compose down` supprime le conteneur : `docker logs` echouait
    # alors avec « No such container ». On bascule sur le fichier de log.
    if docker inspect "$container" >/dev/null 2>&1; then
        local running
        running=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)
        if [ "$running" = "true" ]; then
            echo -e "  ${DIM}Flux en direct — Ctrl-C pour quitter.${NC}"
            echo ""
            docker logs -f --tail 150 "$container"
        else
            echo -e "  ${YELLOW}Conteneur arrêté — 150 dernières lignes :${NC}"
            echo ""
            docker logs --tail 150 "$container" 2>&1
        fi
        return 0
    fi

    # Conteneur inexistant : lire directement le fichier de log sur l'hote.
    echo -e "  ${YELLOW}Conteneur non démarré${NC} ${DIM}(client arrêté).${NC}"
    if [ "$SERVICE" = "gluetun" ]; then
        echo -e "  ${DIM}Les logs VPN ne sont visibles que conteneur démarré (menu → démarrer).${NC}"
        return 0
    fi

    local logdir="${CLIENTS_DIR}/${CLIENT}/local/log"
    if [ -f "${logdir}/rtorrent.log" ]; then
        echo -e "  ${DIM}Lecture de ${logdir}/rtorrent.log (150 dernières lignes)${NC}"
        echo ""
        tail -n 150 "${logdir}/rtorrent.log"
        if [ -f "${logdir}/mover.log" ]; then
            echo ""
            echo -e "  ${WHITE}— Journal des déplacements SSD → NAS (mover.log) —${NC}"
            tail -n 20 "${logdir}/mover.log"
        fi
    else
        print_error_box "Aucun log disponible" "└─ Conteneur arrêté et aucun rtorrent.log dans ${logdir}"
    fi
}

###########################################
# COMMANDE: QUOTA
###########################################
cmd_quota() {
    print_header
    echo -e "  ${WHITE}UTILISATION DISQUE${NC}"
    line
    echo ""
    
    local total_used=0
    local total_available=0
    local total_quota=0
    
    for CLIENT in $(get_clients); do
        local NAS_SHARE_NAME=$(get_nas_share_name $CLIENT)
        
        local quota_bytes=$(get_nas_quota_bytes "$CLIENT")
        local used_bytes=$(get_nas_used_bytes "$CLIENT")
        local quota_human=$(format_bytes $quota_bytes)
        local used_human=$(format_bytes $used_bytes)
        local available_bytes=$((quota_bytes - used_bytes))
        [ $available_bytes -lt 0 ] && available_bytes=0
        local available_human=$(format_bytes $available_bytes)
        local percent=0
        [ $quota_bytes -gt 0 ] && percent=$((used_bytes * 100 / quota_bytes))
        [ $percent -gt 100 ] && percent=100
        
        total_used=$((total_used + used_bytes))
        total_available=$((total_available + available_bytes))
        total_quota=$((total_quota + quota_bytes))
        
        echo -e "  ${WHITE}${CLIENT}${NC} ${DIM}(${NAS_SHARE_NAME})${NC}"
        if [ $quota_bytes -gt 0 ]; then
            print_item "Utilisé" "${used_human} / ${quota_human}"
            print_item "Disponible" "$available_human"
            print_item_last "" "$(progress_bar $percent)"
        else
            print_item_last "Status" "${RED}NAS non monté${NC}"
        fi
        echo ""
    done
    
    local total_used_human=$(format_bytes $total_used)
    local total_available_human=$(format_bytes $total_available)
    local total_quota_human=$(format_bytes $total_quota)
    
    print_footer_with_summary "Total: ${total_used_human} utilisés │ ${total_available_human} disponibles │ ${total_quota_human} alloués"
}

###########################################
# COMMANDE: PASSWD
###########################################
cmd_passwd() {
    local CLIENT=$1
    local NEW_PASS=$2
    
    if ! client_exists "$CLIENT"; then
        print_error_box "Le client '${CLIENT}' n'existe pas."
        return 1
    fi
    
    if [ -z "$NEW_PASS" ]; then
        print_error_box "Nouveau mot de passe requis."
        return 1
    fi
    
    print_header_with_title "MODIFICATION MOT DE PASSE: ${CLIENT}"
    
    # Mettre à jour le mot de passe Linux
    echo -ne "  ${DIM}Mise à jour utilisateur système...${NC}"
    echo "$CLIENT:$NEW_PASS" | chpasswd
    echo -e "\r  ${GREEN}✔${NC} Utilisateur système mis à jour        "
    
    # Mettre à jour le mot de passe ruTorrent (htpasswd sur le NAS)
    local DOCKER_APPS=$(get_client_docker_apps_path $CLIENT)
    echo -ne "  ${DIM}Mise à jour ruTorrent...${NC}"
    local HASH=$(openssl passwd -apr1 "$NEW_PASS")
    echo "${CLIENT}:${HASH}" > "${DOCKER_APPS}/rutorrent/.htpasswd"
    echo -e "\r  ${GREEN}✔${NC} ruTorrent mis à jour                  "
    
    # Mettre à jour le fichier info.txt
    echo -ne "  ${DIM}Mise à jour configuration...${NC}"
    sed -i "s/^PASSWORD:.*/PASSWORD: $NEW_PASS/" "$CLIENTS_DIR/$CLIENT/info.txt"
    echo -e "\r  ${GREEN}✔${NC} Configuration mise à jour             "
    
    # Mettre à jour le docker-compose
    sed -i "s/RU_PASSWORD=.*/RU_PASSWORD=$NEW_PASS/" "$CLIENTS_DIR/$CLIENT/docker-compose.yml"
    
    print_success_box "MOT DE PASSE MODIFIÉ"
    echo ""
    echo -e "  ${DIM}Nouveau mot de passe : ${NEW_PASS}${NC}"
    echo -e "  ${DIM}Utilisable pour ruTorrent et SFTP${NC}"
    
    print_footer
}

###########################################
# COMMANDE: MOUNT
###########################################
cmd_mount() {
    local CLIENT=$1
    
    if [ -z "$CLIENT" ]; then
        print_header_with_title "MONTAGE DES PARTAGES NAS"
        
        mount_all_nas_shares
        
        local mounted=0
        local total=0
        
        for client in $(get_clients); do
            ((total++))
            local mount_path=$(get_client_mount_path $client)
            local share_name=$(get_nas_share_name $client)
            
            if mountpoint -q "$mount_path" 2>/dev/null; then
                echo -e "  ${GREEN}●${NC} ${client} → ${share_name}"
                ((mounted++))
            else
                echo -e "  ${RED}○${NC} ${client} → ${share_name} ${DIM}(échec)${NC}"
            fi
        done
        
        print_footer_with_summary "${mounted}/${total} partages montés"
        return
    fi
    
    local NAS_SHARE_NAME=$(get_nas_share_name $CLIENT)
    local CLIENT_MOUNT_PATH=$(get_client_mount_path $CLIENT)
    
    print_header_with_title "MONTAGE NAS: ${CLIENT}"
    
    echo -e "  Partage NAS ........ ${NAS_SHARE_NAME}"
    echo -e "  Point de montage ... ${CLIENT_MOUNT_PATH}"
    echo ""
    
    if mount_nas_for_client "$CLIENT"; then
        echo -e "  ${GREEN}✔ Montage réussi${NC}"
        
        echo ""
        if confirm "Ajouter au fstab (montage au démarrage) ?"; then
            add_fstab_for_client "$CLIENT"
            echo -e "  ${GREEN}✔ Ajouté à /etc/fstab${NC}"
        fi
        
        # Créer les dossiers
        local DATA_PATH=$(get_client_data_path $CLIENT)
        local DOCKER_APPS=$(get_client_docker_apps_path $CLIENT)
        
        if [ -d "$CLIENT_MOUNT_PATH" ]; then
            mkdir -p "${DOCKER_APPS}/gluetun"
            mkdir -p "${DOCKER_APPS}/rtorrent/.session"
            mkdir -p "${DOCKER_APPS}/rtorrent/log"
            mkdir -p "${DOCKER_APPS}/rutorrent"
            mkdir -p "${DATA_PATH}/torrents/films"
            mkdir -p "${DATA_PATH}/torrents/series"
            mkdir -p "${DATA_PATH}/torrents/autres"
            mkdir -p "${DATA_PATH}/watch/films"
            mkdir -p "${DATA_PATH}/watch/series"
            mkdir -p "${DATA_PATH}/watch/autres"
            
            # Remonter le bind mount pour SFTP si l'utilisateur existe
            if id "$CLIENT" &>/dev/null; then
                mkdir -p "/home/$CLIENT/data"
                if ! mountpoint -q "/home/$CLIENT/data" 2>/dev/null; then
                    mount --bind "${DATA_PATH}" "/home/$CLIENT/data" 2>/dev/null || true
                fi
            fi
            echo -e "  ${GREEN}✔ Arborescence créée${NC}"
        fi
        
        print_success_box "NAS MONTÉ"
    else
        echo -e "  ${RED}✗ Erreur de montage${NC}"
        echo ""
        echo -e "  ${YELLOW}Vérifiez sur le NAS Synology :${NC}"
        echo -e "  ├─ Le dossier partagé '${NAS_SHARE_NAME}' existe"
        echo -e "  ├─ NFS est activé"
        echo -e "  └─ Les permissions NFS autorisent $(hostname -I | awk '{print $1}')"
        print_footer
        return 1
    fi
    
    print_footer
}

###########################################
# COMMANDE: HEALTH
###########################################
cmd_health() {
    print_header_with_title "DIAGNOSTIC SYSTÈME"
    
    local errors=0
    local warnings=0
    local alerts=()
    
    # Section Système
    print_section "SYSTÈME"
    
    # Dépendances de base
    local deps_ok=true
    for cmd in curl wget openssl; do
        if ! command -v $cmd &> /dev/null; then
            deps_ok=false
            alerts+=("$cmd n'est pas installé")
        fi
    done
    
    if [ "$deps_ok" = true ]; then
        print_item "Dépendances" "${GREEN}✔ Installées${NC}"
    else
        print_item "Dépendances" "${RED}✗ Manquantes${NC}"
        ((errors++))
    fi
    
    # Docker
    if command -v docker &> /dev/null && docker info &> /dev/null; then
        local docker_version=$(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)
        print_item "Docker" "${GREEN}✔ Actif${NC} ${DIM}(${docker_version})${NC}"
    else
        print_item "Docker" "${RED}✗ Non disponible${NC}"
        ((errors++))
        alerts+=("Docker n'est pas installé ou ne fonctionne pas")
    fi
    
    # Docker Compose
    if docker compose version &> /dev/null; then
        local compose_version=$(docker compose version | grep -oP '\d+\.\d+\.\d+' | head -1)
        print_item "Docker Compose" "${GREEN}✔ Installé${NC} ${DIM}(${compose_version})${NC}"
    else
        print_item "Docker Compose" "${RED}✗ Non disponible${NC}"
        ((errors++))
        alerts+=("Docker Compose n'est pas installé")
    fi
    
    # NFS
    if command -v mount.nfs &> /dev/null; then
        print_item "NFS Client" "${GREEN}✔ Installé${NC}"
    else
        print_item "NFS Client" "${RED}✗ Non installé${NC}"
        ((errors++))
        alerts+=("nfs-common n'est pas installé")
    fi
    
    # Image Docker
    if docker images 2>/dev/null | grep -q "laboboxvpn/rtorrent-rutorrent"; then
        print_item "Image Docker" "${GREEN}✔ Présente${NC}"
    else
        print_item "Image Docker" "${YELLOW}⚠ Non buildée${NC}"
        ((warnings++))
        alerts+=("Image Docker non buildée - Exécutez: ./laboboxvpn-manager.sh build")
    fi
    
    # Espace disque VM
    local vm_used_percent=$(df / 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
    if [ -n "$vm_used_percent" ]; then
        if [ $vm_used_percent -ge 90 ]; then
            print_item_last "Disque VM" "${RED}✗ ${vm_used_percent}% utilisé${NC}"
            ((errors++))
            alerts+=("Disque VM critique: ${vm_used_percent}% utilisé")
        elif [ $vm_used_percent -ge 80 ]; then
            print_item_last "Disque VM" "${YELLOW}⚠ ${vm_used_percent}% utilisé${NC}"
            ((warnings++))
        else
            print_item_last "Disque VM" "${GREEN}✔ ${vm_used_percent}% utilisé${NC}"
        fi
    else
        print_item_last "Disque VM" "${DIM}Inconnu${NC}"
    fi
    echo ""
    
    # Section NAS
    print_section "CONNEXION NAS"
    
    if [ "$NAS_IP" != "A_CONFIGURER" ]; then
        if ping -c 1 -W 2 "$NAS_IP" &> /dev/null; then
            print_item "NAS ($NAS_IP)" "${GREEN}✔ Accessible${NC}"
        else
            print_item "NAS ($NAS_IP)" "${RED}✗ Inaccessible${NC}"
            ((errors++))
            alerts+=("NAS ${NAS_IP} ne répond pas au ping")
        fi
    else
        print_item "NAS" "${YELLOW}⚠ Non configuré${NC}"
        ((warnings++))
        alerts+=("IP du NAS non configurée - Exécutez: ./laboboxvpn-manager.sh init")
    fi
    
    # Vérifier les montages
    local nas_mounted=0
    local nas_total=0
    for client in $(get_clients); do
        ((nas_total++))
        local share_name=$(get_nas_share_name $client)
        local mount_path=$(get_client_mount_path $client)
        if mountpoint -q "$mount_path" 2>/dev/null; then
            print_item "$share_name" "${GREEN}✔ Monté${NC}"
            ((nas_mounted++))
        else
            print_item "$share_name" "${RED}✗ Non monté${NC}"
            ((errors++))
            alerts+=("${share_name} non monté pour ${client}")
        fi
    done
    
    if [ $nas_total -eq 0 ]; then
        print_item_last "Partages" "${DIM}Aucun client configuré${NC}"
    else
        echo ""
    fi
    echo ""
    
    # Section Clients
    print_section "CLIENTS"
    
    local clients_ok=0
    local clients_total=0
    
    for CLIENT in $(get_clients); do
        ((clients_total++))
        local client_status="${GREEN}✔${NC}"
        local client_issues=""
        
        # Vérifier Gluetun
        local gluetun_running=""
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "gluetun-$CLIENT"; then
            gluetun_running="1"
        else
            client_status="${RED}✗${NC}"
            client_issues+="Gluetun arrêté, "
        fi
        
        # Vérifier rtorrent
        local rtorrent_running=""
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "rtorrent-$CLIENT"; then
            rtorrent_running="1"
        else
            client_status="${RED}✗${NC}"
            client_issues+="rtorrent arrêté, "
        fi
        
        # Vérifier VPN
        local vpn_connected=""
        if [ -n "$gluetun_running" ]; then
            local vpn_ip=$(get_vpn_ip "$CLIENT" 2>/dev/null)
            if [ -n "$vpn_ip" ]; then
                vpn_connected="$vpn_ip"
            else
                client_status="${YELLOW}⚠${NC}"
                client_issues+="VPN non connecté, "
            fi
        fi
        
        # Vérifier quota
        local quota_bytes=$(get_nas_quota_bytes "$CLIENT")
        local used_bytes=$(get_nas_used_bytes "$CLIENT")
        local percent=0
        [ $quota_bytes -gt 0 ] && percent=$((used_bytes * 100 / quota_bytes))
        
        if [ $percent -ge 95 ]; then
            client_status="${RED}✗${NC}"
            client_issues+="Quota critique (${percent}%), "
            alerts+=("${CLIENT}: Quota critique à ${percent}%")
        elif [ $percent -ge 80 ]; then
            [ "$client_status" != "${RED}✗${NC}" ] && client_status="${YELLOW}⚠${NC}"
            client_issues+="Quota élevé (${percent}%), "
            alerts+=("${CLIENT}: Quota à ${percent}%")
        fi
        
        # Affichage
        echo -e "  ${client_status} ${WHITE}${CLIENT}${NC}"
        
        if [ -n "$gluetun_running" ]; then
            local uptime=$(get_container_uptime "gluetun-$CLIENT")
            print_item "Gluetun" "${GREEN}✔ Actif${NC} ${DIM}(${uptime})${NC}"
        else
            print_item "Gluetun" "${RED}✗ Arrêté${NC}"
        fi
        
        if [ -n "$rtorrent_running" ]; then
            local uptime=$(get_container_uptime "rtorrent-$CLIENT")
            print_item "rtorrent" "${GREEN}✔ Actif${NC} ${DIM}(${uptime})${NC}"
        else
            print_item "rtorrent" "${RED}✗ Arrêté${NC}"
        fi
        
        if [ -n "$vpn_connected" ]; then
            print_item "VPN" "${GREEN}✔ Connecté${NC} ${DIM}(${vpn_connected})${NC}"
        elif [ -n "$gluetun_running" ]; then
            print_item "VPN" "${YELLOW}⚠ En attente${NC}"
        else
            print_item "VPN" "${DIM}--${NC}"
        fi
        
        if [ $quota_bytes -gt 0 ]; then
            local used_human=$(format_bytes $used_bytes)
            local quota_human=$(format_bytes $quota_bytes)
            if [ $percent -ge 95 ]; then
                print_item_last "Quota" "${RED}${percent}%${NC} ${DIM}(${used_human} / ${quota_human})${NC}"
            elif [ $percent -ge 80 ]; then
                print_item_last "Quota" "${YELLOW}${percent}%${NC} ${DIM}(${used_human} / ${quota_human})${NC}"
            else
                print_item_last "Quota" "${GREEN}${percent}%${NC} ${DIM}(${used_human} / ${quota_human})${NC}"
            fi
        else
            print_item_last "Quota" "${DIM}NAS non monté${NC}"
        fi
        
        echo ""
        
        # Compter si OK
        if [ "$client_status" == "${GREEN}✔${NC}" ]; then
            ((clients_ok++))
        elif [ "$client_status" == "${YELLOW}⚠${NC}" ]; then
            ((warnings++))
        else
            ((errors++))
        fi
    done
    
    if [ $clients_total -eq 0 ]; then
        echo -e "  ${DIM}Aucun client configuré${NC}"
        echo ""
    fi
    
    # Résumé
    double_line
    local summary_color=$GREEN
    [ $warnings -gt 0 ] && summary_color=$YELLOW
    [ $errors -gt 0 ] && summary_color=$RED
    
    echo -e "  ${summary_color}RÉSUMÉ: ${clients_ok}/${clients_total} clients OK │ ${warnings} avertissement(s) │ ${errors} erreur(s)${NC}"
    double_line
    
    # Alertes
    if [ ${#alerts[@]} -gt 0 ]; then
        echo ""
        echo -e "  ${YELLOW}⚠ ALERTES:${NC}"
        for alert in "${alerts[@]}"; do
            echo -e "  ${DIM}├─${NC} ${alert}"
        done
    fi
    
    echo ""
}

###########################################
# COMMANDE: CHECK-PORTS
###########################################
# Teste la chaîne complète depuis l'extérieur du tunnel : la connexion part
# de la VM vers l'IP publique de sortie VPN (portée par le serveur dédié
# NWM), y est redirigée dans le tunnel WireGuard, traverse Gluetun et
# atteint rtorrent. Un port fermé = seedbox invisible pour les peers
# entrants → ratios en chute silencieuse.
# Test TCP uniquement (le port rtorrent écoute en TCP ; l'UDP ne se teste
# pas par simple connexion, et le DHT est désactivé sur cette seedbox).

cmd_check_ports() {
    local ONLY_CLIENT="$1"
    print_header_with_title "VÉRIFICATION DU PORT FORWARDING"

    echo -e "  ${DIM}Connexion TCP réelle : VM → IP de sortie VPN → serveur VPN (NWM)${NC}"
    echo -e "  ${DIM}→ tunnel WireGuard → Gluetun → rtorrent.${NC}"
    echo ""

    local ok=0 ko=0 skipped=0 tested=0
    for CLIENT in $(get_clients); do
        [ -n "$ONLY_CLIENT" ] && [ "$CLIENT" != "$ONLY_CLIENT" ] && continue
        tested=1
        local port_rt=$(grep "PORT_RTORRENT_VPN" "$CLIENTS_DIR/$CLIENT/info.txt" 2>/dev/null | cut -d: -f2 | tr -d ' ')

        if [ -z "$port_rt" ]; then
            echo -e "  ${YELLOW}⚠${NC} ${CLIENT} ${DIM}(port rtorrent introuvable dans info.txt)${NC}"
            ((ko++)); continue
        fi
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "gluetun-$CLIENT"; then
            echo -e "  ${DIM}○${NC} ${CLIENT} ${DIM}(arrêté — non testé)${NC}"
            ((skipped++)); continue
        fi

        local vpn_ip=$(get_vpn_ip "$CLIENT")
        if [ -z "$vpn_ip" ]; then
            echo -e "  ${YELLOW}⚠${NC} ${CLIENT} ${DIM}(IP de sortie inconnue — tunnel pas encore établi ?)${NC}"
            ((ko++)); continue
        fi

        if timeout 5 bash -c "</dev/tcp/${vpn_ip}/${port_rt}" 2>/dev/null; then
            echo -e "  ${GREEN}✔${NC} ${CLIENT} — ${vpn_ip}:${port_rt} ${GREEN}ouvert${NC}"
            ((ok++))
        else
            echo -e "  ${RED}✗${NC} ${CLIENT} — ${vpn_ip}:${port_rt} ${RED}fermé ou injoignable${NC}"
            ((ko++))
        fi
    done

    if [ $tested -eq 0 ]; then
        if [ -n "$ONLY_CLIENT" ]; then
            echo -e "  ${DIM}Client '${ONLY_CLIENT}' introuvable.${NC}"
        else
            echo -e "  ${DIM}Aucun client configuré.${NC}"
        fi
    fi

    if [ $ko -gt 0 ]; then
        echo ""
        echo -e "  ${YELLOW}En cas d'échec, vérifier dans l'ordre :${NC}"
        echo -e "    1. rtorrent démarré pour ce client (menu Monitoring → Vue d'ensemble)"
        echo -e "    2. côté serveur VPN (nwm) : le port est bien redirigé vers ce client"
        echo -e "    3. le fichier .conf du client correspond au bon port (${DIM}1101 ↔ 1101.conf${NC})"
    fi

    print_footer_with_summary "${ok} ouvert(s) │ ${ko} en échec │ ${skipped} non testé(s)"
}

###########################################
# COMMANDE: BENCH (NFS / VPN)
###########################################
# Mesures chronométrées maison (date +%s%N) plutôt que le résumé de dd,
# dont le format dépend de la locale.

# bench_speed <octets> <nanosecondes> → « X.X Mo/s (Y Mbit/s) »
bench_speed() {
    awk -v b="$1" -v ns="$2" 'BEGIN{
        s = ns / 1000000000
        if (s <= 0) s = 0.001
        printf "%.1f Mo/s (%.0f Mbit/s)", (b/1048576)/s, (b*8/1000000)/s
    }'
}

# bench_fmt_size <octets> → « 1.0 Gio » / « 954 Mio »
bench_fmt_size() {
    awk -v b="$1" 'BEGIN{
        if (b >= 1073741824) printf "%.1f Gio", b/1073741824
        else printf "%.0f Mio", b/1048576
    }'
}

# Sonde rapide d'une source (1 Mo, timeout court). Le préfixe « RANGE: »
# signifie que le miroir n'a pas de petit fichier : on demande alors le
# premier Mo du gros fichier par en-tête HTTP Range (206), vérifié honoré.
bench_probe_direct() {
    case "$1" in
        RANGE:*) timeout 25 wget -4 -q -T 15 -t 1 --header="Range: bytes=0-1048575" -O /dev/null "${1#RANGE:}" 2>/dev/null ;;
        *)       timeout 25 wget -4 -q -T 15 -t 1 -O /dev/null "$1" 2>/dev/null ;;
    esac
}

# Même sonde mais depuis le conteneur Gluetun (wget busybox : pas de -4,
# inutile de toute façon — le tunnel est en IPv4).
bench_probe_tunnel() {
    local client="$1" spec="$2"
    case "$spec" in
        RANGE:*) timeout 30 docker exec "gluetun-$client" wget -q -T 15 --header "Range: bytes=0-1048575" -O /dev/null "${spec#RANGE:}" 2>/dev/null ;;
        *)       timeout 30 docker exec "gluetun-$client" wget -q -T 15 -O /dev/null "$spec" 2>/dev/null ;;
    esac
}

cmd_bench_nfs() {
    local CLIENT="$1"
    local SIZE_MB="${2:-512}"

    print_header_with_title "BENCHMARK NFS"

    if [ -z "$CLIENT" ] || ! client_exists "$CLIENT"; then
        print_error_box "Client requis : bench-nfs <client> [taille_mo]"
        return 1
    fi
    case "$SIZE_MB" in ''|*[!0-9]*) SIZE_MB=512 ;; esac
    [ "$SIZE_MB" -lt 64 ] && SIZE_MB=64

    local mount_path=$(get_client_mount_path "$CLIENT")
    if ! mountpoint -q "$mount_path" 2>/dev/null; then
        print_error_box "Le partage NAS de '${CLIENT}' n'est pas monté" "└─ Menu Maintenance → Monter tous les partages NAS"
        return 1
    fi

    # Le fichier de test compte sur le quota du partage pendant la mesure :
    # on vérifie qu'il reste au moins 2x la taille demandée.
    local quota_bytes=$(get_nas_quota_bytes "$CLIENT")
    local used_bytes=$(get_nas_used_bytes "$CLIENT")
    local need_bytes=$((SIZE_MB * 1024 * 1024 * 2))
    if [ "$quota_bytes" -gt 0 ] && [ $((quota_bytes - used_bytes)) -lt $need_bytes ]; then
        print_error_box "Pas assez d'espace libre sur ${CLIENT} pour un test de ${SIZE_MB} Mo"
        return 1
    fi

    local target="${mount_path}/.labobox-bench.tmp"
    local bytes=$((SIZE_MB * 1024 * 1024))
    local start end

    # Nettoyage GARANTI du fichier de test : à la fin de la fonction comme
    # sur Ctrl+C en plein transfert (le signal est ré-émis après ménage).
    trap 'rm -f "$target" 2>/dev/null; trap - RETURN INT TERM' RETURN
    trap 'rm -f "$target" 2>/dev/null; trap - RETURN INT TERM; kill -s INT "$$"' INT TERM

    echo -e "  ${DIM}Partage : $(get_nas_share_name $CLIENT) — fichier de test : ${SIZE_MB} Mo${NC}"
    echo -e "  ${DIM}(supprimé automatiquement à la fin, même sur Ctrl+C)${NC}"
    echo ""

    # 1. Écriture DIRECTE (O_DIRECT) : débit brut NAS + réseau, sans le
    #    cache de la VM — c'est la vitesse que les disques encaissent.
    echo -e "  ${DIM}1/3 Écriture directe, sans cache (progression de dd) :${NC}"
    start=$(date +%s%N)
    if dd if=/dev/zero of="$target" bs=1M count="$SIZE_MB" oflag=direct conv=fdatasync status=progress >/dev/null; then
        end=$(date +%s%N)
        echo -e "  ${GREEN}✔${NC} Écriture directe (sans cache) .... $(bench_speed $bytes $((end - start)))"
    else
        echo -e "  ${YELLOW}⚠${NC} Écriture directe refusée (O_DIRECT non supporté ici)"
    fi
    echo ""

    # 2. Écriture via le cache + fdatasync : le chemin réel des applis
    #    (rtorrent) — c'est ici que le writeback en bytes fait son effet.
    echo -e "  ${DIM}2/3 Écriture via cache, fdatasync :${NC}"
    start=$(date +%s%N)
    if dd if=/dev/zero of="$target" bs=1M count="$SIZE_MB" conv=fdatasync status=progress >/dev/null; then
        end=$(date +%s%N)
        echo -e "  ${GREEN}✔${NC} Écriture via cache (fdatasync) ... $(bench_speed $bytes $((end - start)))"
    else
        echo -e "  ${RED}✗${NC} Écriture via cache : échec"
    fi
    echo ""

    # 3. Lecture directe (sans le cache local, sinon on mesure la RAM).
    echo -e "  ${DIM}3/3 Lecture directe :${NC}"
    start=$(date +%s%N)
    if dd if="$target" of=/dev/null bs=1M iflag=direct status=progress; then
        end=$(date +%s%N)
        echo -e "  ${GREEN}✔${NC} Lecture directe .................. $(bench_speed $bytes $((end - start)))"
    else
        echo -e "  ${YELLOW}⚠${NC} Lecture directe non supportée ici (mesure sautée)"
    fi

    rm -f "$target" 2>/dev/null

    echo ""
    echo -e "  ${DIM}Repère : un lien 1 Gb/s plafonne vers ~110 Mo/s ; en dessous, le${NC}"
    echo -e "  ${DIM}goulot est côté NAS (disques/RAID) ou réseau, pas côté VM.${NC}"
    print_footer
}

cmd_bench_vpn() {
    local CLIENT="$1"
    local start end

    print_header_with_title "BENCHMARK DÉBIT VPN"

    if [ -z "$CLIENT" ] || ! client_exists "$CLIENT"; then
        print_error_box "Client requis : bench-vpn <client>"
        return 1
    fi
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "gluetun-$CLIENT"; then
        print_error_box "Le client '${CLIENT}' est arrêté — tunnel indisponible"
        return 1
    fi

    # Sources de test (~1 Go) essayées dans l'ordre : url|sonde|octets|nom.
    # Uniquement des FICHIERS STATIQUES : les endpoints dynamiques de
    # speedtest (speed.cloudflare.com/__down) acceptent une petite sonde
    # mais coupent les gros transferts faits au wget — vérifié en réel.
    # Tailles vérifiées par Content-Length : chez Free, « 1048576.rnd »
    # fait en réalité 1 Gio (et il n'y a pas de petit fichier → sonde par
    # en-tête Range sur le même fichier). La MESURE elle-même bascule sur
    # la source suivante si le transfert casse en route. En direct, IPv4
    # est forcé (-4) — pas dans le tunnel (busybox, et IPv4 de toute façon).
    local sources=(
        "http://test-debit.free.fr/1048576.rnd|RANGE:http://test-debit.free.fr/1048576.rnd|1073741824|Free"
        "https://scaleway.testdebit.info/1G.iso|https://scaleway.testdebit.info/1M.iso|1000000000|Scaleway"
        "http://ping.online.net/1000Mo.dat|http://ping.online.net/1Mo.dat|1000000000|Online.net"
        "https://rbx.proof.ovh.net/files/1Gb.dat|https://rbx.proof.ovh.net/files/1Mb.dat|1073741824|OVH (RBX)"
    )

    echo -e "  ${DIM}Deux passes de ~1 Go sur la même source : en direct depuis la VM${NC}"
    echo -e "  ${DIM}(référence), puis via le tunnel du client. Rien n'est écrit sur le${NC}"
    echo -e "  ${DIM}disque : le flux part dans /dev/null.${NC}"
    echo ""

    # 1. Trouver une source qui livre RÉELLEMENT son fichier en direct :
    #    la sonde puis la mesure — un échec de mesure passe à la suivante.
    local src url probe bytes lbl label="" size_h="" vpn_ns="" direct_ns=""
    for src in "${sources[@]}"; do
        IFS='|' read -r url probe bytes lbl <<< "$src"
        echo -ne "\r  ${DIM}Sonde de la source ${lbl}...${NC}                                        "
        bench_probe_direct "$probe" || continue
        size_h=$(bench_fmt_size "$bytes")
        echo -e "\r  ${GREEN}✔${NC} Source : ${lbl} — ${size_h} par passe                                "
        echo ""
        echo -e "  ${DIM}Mesure en direct depuis la VM (progression de wget) :${NC}"
        start=$(date +%s%N)
        if timeout 900 wget -4 -q --show-progress -T 60 -t 1 -O /dev/null "$url"; then
            end=$(date +%s%N)
            direct_ns=$((end - start))
            label="$lbl"
            break
        fi
        echo -e "  ${YELLOW}⚠${NC} Échec en cours de transfert via ${lbl} — source suivante."
        echo ""
    done
    if [ -z "$label" ]; then
        echo -e "\r  ${RED}✗${NC} Aucune source n'a pu livrer son fichier en direct depuis la VM.         "
        echo ""
        echo -e "  ${DIM}Sources tentées : Free, Scaleway, Online.net, OVH. Diagnostic manuel :${NC}"
        echo -e "  ${DIM}  wget -4 -O /dev/null https://scaleway.testdebit.info/1G.iso${NC}"
        print_footer
        return 1
    fi
    echo -e "  ${GREEN}✔${NC} En direct (sans VPN) ...... $(bench_speed $bytes $direct_ns) ${DIM}via ${label}${NC}"

    # 3. Sonde du tunnel (1 Mo) : distingue « tunnel mort » de « débit faible »
    echo -ne "  ${DIM}Sonde du tunnel de ${CLIENT}...${NC}"
    if ! bench_probe_tunnel "$CLIENT" "$probe"; then
        echo -e "\r  ${RED}✗${NC} Le tunnel de ${CLIENT} ne joint pas ${label} (tunnel coupé ?)          "
        echo -e "  ${DIM}Vérifier : docker logs gluetun-${CLIENT}, et l'IP de sortie (Monitoring).${NC}"
        print_footer
        return 1
    fi
    echo -e "\r  ${GREEN}✔${NC} Sonde du tunnel : OK                    "

    # 4. Mesure via le tunnel. « docker exec -t » alloue un pseudo-terminal :
    #    le wget busybox de Gluetun affiche alors sa progression (avec %).
    echo ""
    echo -e "  ${DIM}Mesure via le tunnel de ${CLIENT} (progression de wget) :${NC}"
    start=$(date +%s%N)
    if timeout 900 docker exec -t "gluetun-$CLIENT" wget -T 60 -O /dev/null "$url"; then
        end=$(date +%s%N)
        vpn_ns=$((end - start))
        echo -e "  ${GREEN}✔${NC} Via le tunnel VPN ......... $(bench_speed $bytes $vpn_ns)"
    else
        echo -e "  ${RED}✗${NC} Mesure via le tunnel : échec en cours de transfert"
        echo -e "  ${DIM}La même source vient de livrer ${size_h} en direct : le transfert casse${NC}"
        echo -e "  ${DIM}DANS le tunnel. Réessaie ; si ça persiste → CPU du dédié, MTU côté nwm.${NC}"
    fi

    if [ -n "$vpn_ns" ] && [ -n "$direct_ns" ] && [ "$vpn_ns" -gt 0 ]; then
        echo ""
        echo -e "  Coût du tunnel : $(awk -v v="$vpn_ns" -v d="$direct_ns" 'BEGIN{
            if (v <= d) { print "négligeable sur ce test" }
            else printf "%.0f %% plus lent que le direct", (v - d) * 100 / v
        }')"
        echo -e "  ${DIM}(chiffrement WireGuard + trajet via le serveur dédié : un écart${NC}"
        echo -e "  ${DIM}modéré est normal ; un gros écart → voir CPU du dédié et MTU côté nwm)${NC}"
    fi
    print_footer
}

# Liste de sources ~1 Go (fichiers STATIQUES, miroirs FR). Partagee par les
# benchmarks. Format : url|sonde|octets|nom.
bench_sources_list() {
    printf '%s\n' \
        "http://test-debit.free.fr/1048576.rnd|RANGE:http://test-debit.free.fr/1048576.rnd|1073741824|Free" \
        "https://scaleway.testdebit.info/1G.iso|https://scaleway.testdebit.info/1M.iso|1000000000|Scaleway" \
        "http://ping.online.net/1000Mo.dat|http://ping.online.net/1Mo.dat|1000000000|Online.net" \
        "https://rbx.proof.ovh.net/files/1Gb.dat|https://rbx.proof.ovh.net/files/1Mb.dat|1073741824|OVH (RBX)"
}

# Choisit la 1re source qui repond a la sonde en direct. Remplit les globales
# BENCH_URL / BENCH_BYTES / BENCH_LABEL. Retour 1 si aucune.
bench_pick_source() {
    local url probe bytes lbl
    BENCH_URL=""; BENCH_BYTES=""; BENCH_LABEL=""
    while IFS='|' read -r url probe bytes lbl; do
        [ -n "$url" ] || continue
        echo -ne "\r  ${DIM}Sonde de ${lbl}...${NC}                                        "
        if bench_probe_direct "$probe"; then
            BENCH_URL="$url"; BENCH_BYTES="$bytes"; BENCH_LABEL="$lbl"
            echo -e "\r  ${GREEN}✔${NC} Source retenue : ${lbl} — $(bench_fmt_size "$bytes") par passe        "
            return 0
        fi
    done < <(bench_sources_list)
    echo -e "\r  ${RED}✗${NC} Aucune source de test joignable en direct.                              "
    return 1
}

# dd ecriture (fdatasync) puis lecture (directe) sur un dossier. Affiche la
# progression et renseigne les variables passees par nom (write/read).
# Usage : bench_dd_dir <dossier> <taille_mo> <var_write> <var_read>
bench_dd_dir() {
    local dir="$1" mb="$2" __w="$3" __r="$4"
    local target="${dir}/.labobox-bench.tmp" bytes=$((mb * 1024 * 1024)) s e
    mkdir -p "$dir" 2>/dev/null
    echo -e "  ${DIM}  écriture ${mb} Mo (fdatasync) :${NC}"
    s=$(date +%s%N)
    if dd if=/dev/zero of="$target" bs=1M count="$mb" conv=fdatasync status=progress 2>&1 >/dev/null; then
        e=$(date +%s%N); printf -v "$__w" '%s' "$(bench_speed "$bytes" $((e - s)))"
    else
        printf -v "$__w" '%s' "échec"
    fi
    echo -e "  ${DIM}  lecture directe :${NC}"
    s=$(date +%s%N)
    if dd if="$target" of=/dev/null bs=1M iflag=direct status=progress 2>&1; then
        e=$(date +%s%N); printf -v "$__r" '%s' "$(bench_speed "$bytes" $((e - s)))"
    else
        printf -v "$__r" '%s' "n/a"
    fi
    rm -f "$target" 2>/dev/null
}

# Telechargement d'un fichier ~1 Go À TRAVERS LE TUNNEL, ecrit sur un disque.
# Le wget tourne dans le conteneur rtorrent (il partage le reseau de Gluetun
# ET voit /data et /temp). Renseigne la variable passee par nom.
# Usage : bench_vpn_to_disk <client> <chemin_dans_conteneur> <hote_a_nettoyer> <var_res>
bench_vpn_to_disk() {
    local client="$1" inpath="$2" hostclean="$3" __res="$4"
    local s e
    s=$(date +%s%N)
    if timeout 900 docker exec -t "rtorrent-${client}" sh -c "wget -T 60 -O '$inpath' '$BENCH_URL'" ; then
        e=$(date +%s%N); printf -v "$__res" '%s' "$(bench_speed "$BENCH_BYTES" $((e - s)))"
    else
        printf -v "$__res" '%s' "échec"
    fi
    rm -f "$hostclean" 2>/dev/null
    docker exec "rtorrent-${client}" rm -f "$inpath" 2>/dev/null || true
}

# BENCHMARK 4 VOIES : disque NFS direct, disque SSD direct, VPN->NFS, VPN->SSD.
cmd_bench_all() {
    local CLIENT="$1"
    local SIZE_MB=1024

    print_header_with_title "BENCHMARK COMPLET — DISQUES & VPN"

    if [ -z "$CLIENT" ] || ! client_exists "$CLIENT"; then
        print_error_box "Client requis : bench <client>"
        return 1
    fi

    local mount_path ssd_host="" have_nfs="no" have_ssd="no" have_vpn="no"
    mount_path=$(get_client_mount_path "$CLIENT")
    mountpoint -q "$mount_path" 2>/dev/null && have_nfs="yes"
    if [ -n "$TEMP_DIR" ] && [ -d "${TEMP_DIR}/${CLIENT}" ]; then
        ssd_host="${TEMP_DIR}/${CLIENT}"; have_ssd="yes"
    fi
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "rtorrent-${CLIENT}" && have_vpn="yes"

    echo -e "  ${DIM}Fichiers de test ~1 Go, supprimés à la fin. Disques : dd local.${NC}"
    echo -e "  ${DIM}VPN : téléchargement réel à travers le tunnel, écrit sur le disque.${NC}"
    echo ""
    echo -e "  ${DIM}NAS monté : ${have_nfs} │ SSD temp : ${have_ssd} │ conteneur (VPN) : ${have_vpn}${NC}"
    echo ""

    local nfs_w="—" nfs_r="—" ssd_w="—" ssd_r="—" vpn_nfs="—" vpn_ssd="—"

    # --- Disque NFS (direct, sans VPN) ---
    if [ "$have_nfs" = "yes" ]; then
        echo -e "  ${WHITE}1/4 · Disque NAS (NFS), en direct${NC}"
        bench_dd_dir "$mount_path" "$SIZE_MB" nfs_w nfs_r
        echo ""
    else
        echo -e "  ${YELLOW}1/4 · Disque NAS ignoré (partage non monté)${NC}"; echo ""
    fi

    # --- Disque SSD (direct, sans VPN) ---
    if [ "$have_ssd" = "yes" ]; then
        echo -e "  ${WHITE}2/4 · Disque SSD temporaire, en direct${NC}"
        bench_dd_dir "$ssd_host" "$SIZE_MB" ssd_w ssd_r
        echo ""
    else
        echo -e "  ${YELLOW}2/4 · Disque SSD ignoré (non configuré/monté)${NC}"; echo ""
    fi

    # --- VPN -> disques (téléchargement réel dans le conteneur) ---
    if [ "$have_vpn" = "yes" ]; then
        echo -e "  ${WHITE}Sélection d'une source de test (~1 Go)…${NC}"
        if bench_pick_source; then
            echo ""
            echo -e "  ${WHITE}3/4 · VPN → NAS (téléchargement tunnel, écriture NFS)${NC}"
            bench_vpn_to_disk "$CLIENT" "/data/.labobox-bench.tmp" "${mount_path}/.labobox-bench.tmp" vpn_nfs
            echo ""
            if [ "$have_ssd" = "yes" ]; then
                echo -e "  ${WHITE}4/4 · VPN → SSD (téléchargement tunnel, écriture SSD)${NC}"
                bench_vpn_to_disk "$CLIENT" "/temp/.labobox-bench.tmp" "${ssd_host}/.labobox-bench.tmp" vpn_ssd
                echo ""
            else
                echo -e "  ${YELLOW}4/4 · VPN → SSD ignoré (SSD non actif)${NC}"; echo ""
            fi
        else
            echo -e "  ${YELLOW}Volets VPN ignorés (aucune source joignable).${NC}"; echo ""
        fi
    else
        echo -e "  ${YELLOW}3-4/4 · Volets VPN ignorés (client arrêté)${NC}"; echo ""
    fi

    # --- Récapitulatif ---
    line
    echo -e "  ${WHITE}Récapitulatif${NC}"
    line
    printf "  %-26s %-22s %-22s\n" "" "écriture" "lecture"
    printf "  %-26s ${GREEN}%-22s${NC} ${GREEN}%-22s${NC}\n" "Disque NAS (NFS) direct" "$nfs_w" "$nfs_r"
    printf "  %-26s ${GREEN}%-22s${NC} ${GREEN}%-22s${NC}\n" "Disque SSD direct" "$ssd_w" "$ssd_r"
    printf "  %-26s ${CYAN}%-22s${NC}\n" "VPN → NAS (download)" "$vpn_nfs"
    printf "  %-26s ${CYAN}%-22s${NC}\n" "VPN → SSD (download)" "$vpn_ssd"
    echo ""
    echo -e "  ${DIM}Lecture : si « VPN → SSD » > « VPN → NAS », l'écriture NFS bridait le${NC}"
    echo -e "  ${DIM}download → le SSD apporte un vrai gain. S'ils sont proches, le tunnel${NC}"
    echo -e "  ${DIM}est le facteur limitant (le SSD protège quand même le NAS).${NC}"
    print_footer
}

###########################################
# DÉMARRAGE AUTOMATIQUE AU BOOT
###########################################
# Les docker-compose sont volontairement en « restart: no » : l'ordre
# compte (NFS monté → Gluetun healthy → rtorrent). Ce service rejoue donc
# le démarrage séquentiel complet après le réseau, les montages distants
# et Docker — la seedbox redevient opérationnelle seule après une coupure.

SEEDBOX_SERVICE_FILE="/etc/systemd/system/labobox-seedbox.service"

is_autostart_enabled() {
    systemctl is-enabled --quiet labobox-seedbox.service 2>/dev/null
}

cmd_autostart_enable() {
    print_header_with_title "DÉMARRAGE AUTO AU BOOT"

    cat > "$SEEDBOX_SERVICE_FILE" << EOF
[Unit]
Description=LaboBox-VPN — démarrage séquentiel de la seedbox au boot
# Après le réseau, les montages _netdev (NFS) et Docker. Le démarrage
# séquentiel remonte de toute façon lui-même les partages manquants.
After=network-online.target remote-fs.target docker.service
Wants=network-online.target remote-fs.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
# Chaque client attend son healthcheck Gluetun : marge large.
TimeoutStartSec=1800
ExecStart=/bin/bash ${INSTALL_DIR}/laboboxvpn-manager.sh sequential-start

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null
    if systemctl enable labobox-seedbox.service >/dev/null 2>&1; then
        print_item "Service" "labobox-seedbox.service"
        print_item "Déclenchement" "à chaque boot, après réseau + NFS + Docker"
        print_item_last "Suivi" "journalctl -u labobox-seedbox"
        print_success_box "DÉMARRAGE AUTO ACTIVÉ"
    else
        print_error_box "Impossible d'activer le service (systemd indisponible ?)"
        rm -f "$SEEDBOX_SERVICE_FILE"
        return 1
    fi
    print_footer
}

cmd_autostart_disable() {
    print_header_with_title "DÉMARRAGE AUTO AU BOOT"
    systemctl disable labobox-seedbox.service >/dev/null 2>&1 || true
    rm -f "$SEEDBOX_SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null || true
    print_success "Démarrage auto désactivé (les clients ne démarreront plus seuls au boot)."
    print_footer
}

###########################################
# COMMANDE: INIT
###########################################
cmd_init() {
    print_header_with_title "INITIALISATION DU SYSTÈME"
    
    local total_steps=6
    
    # Étape 1: Mise à jour système
    print_step 1 $total_steps "Mise à jour du système" "wait"
    apt-get update -qq >/dev/null 2>&1
    echo -e "\r  ${DIM}[1/${total_steps}]${NC} Mise à jour du système ${DIM}...${NC} ${GREEN}✔${NC}"
    
    # Étape 2: Dépendances de base
    print_step 2 $total_steps "Installation des dépendances" "wait"
    apt-get install -y -qq \
        curl \
        wget \
        ca-certificates \
        gnupg \
        openssl \
        lsb-release \
        sudo \
        htop \
        nano \
        >/dev/null 2>&1
    echo -e "\r  ${DIM}[2/${total_steps}]${NC} Installation des dépendances ${DIM}...${NC} ${GREEN}✔${NC}"
    
    # Étape 3: Docker
    print_step 3 $total_steps "Installation de Docker" "wait"
    if ! command -v docker &> /dev/null; then
        # Ajouter le repo Docker
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc 2>/dev/null
        chmod a+r /etc/apt/keyrings/docker.asc
        
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
          tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1
        
        systemctl start docker
        systemctl enable docker >/dev/null 2>&1
        
        echo -e "\r  ${DIM}[3/${total_steps}]${NC} Installation de Docker ${DIM}...${NC} ${GREEN}✔ Installé${NC}"
    else
        echo -e "\r  ${DIM}[3/${total_steps}]${NC} Installation de Docker ${DIM}...${NC} ${GREEN}✔ Déjà installé${NC}"
    fi
    
    local docker_version=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
    print_step_item "Version" "${docker_version}"
    local compose_version=$(docker compose version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
    print_step_item_last "Compose" "${compose_version}"
    echo ""
    
    # Étape 4: NFS
    print_step 4 $total_steps "Installation de NFS" "wait"
    if ! command -v mount.nfs &> /dev/null; then
        apt-get install -y -qq nfs-common >/dev/null 2>&1
        echo -e "\r  ${DIM}[4/${total_steps}]${NC} Installation de NFS ${DIM}...${NC} ${GREEN}✔ Installé${NC}"
    else
        echo -e "\r  ${DIM}[4/${total_steps}]${NC} Installation de NFS ${DIM}...${NC} ${GREEN}✔ Déjà installé${NC}"
    fi
    
    # Étape 5: Configuration réseau
    print_step 5 $total_steps "Vérification configuration réseau"
    echo ""
    
    if [ "$NAS_IP" = "A_CONFIGURER" ] || [ "$SERVER_IP" = "A_CONFIGURER" ]; then
        echo -e "       ${YELLOW}⚠ Configuration réseau incomplète${NC}"
        echo -e "       ${DIM}Utilisez les options du menu Maintenance pour configurer${NC}"
    else
        echo -e "       ${GREEN}✔ Configuration réseau OK${NC}"
    fi
    
    print_step_item "IP VM" "$SERVER_IP"
    print_step_item "Port SSH" "$SSH_PORT"
    print_step_item "IP NAS" "$NAS_IP"
    print_step_item_last "Préfixe partages" "${NAS_SHARE_PREFIX}<USERNAME>"
    echo ""
    
    # Étape 6: Création des répertoires
    print_step 6 $total_steps "Création des répertoires" "wait"
    mkdir -p "$NAS_MOUNT"
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$CLIENTS_DIR"
    mkdir -p "$UTILS_DIR"
    mkdir -p "$INSTALL_DIR/apps"
    install_logrotate
    echo -e "\r  ${DIM}[6/${total_steps}]${NC} Création des répertoires ${DIM}...${NC} ${GREEN}✔${NC}"
    
    # Monter les partages existants
    mount_all_nas_shares 2>/dev/null || true
    
    print_success_box "SYSTÈME INITIALISÉ"
    echo ""
    echo -e "  ${WHITE}Résumé des installations :${NC}"
    line
    print_item "Docker" "$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')"
    print_item "Docker Compose" "$(docker compose version 2>/dev/null | cut -d' ' -f4)"
    print_item "NFS Client" "$(dpkg -l nfs-common 2>/dev/null | grep -q '^ii' && echo 'Installé' || echo 'Non')"
    print_item "Rotation logs" "Automatique (logrotate, quotidienne)"
    print_item_last "Répertoire" "$INSTALL_DIR"
    echo ""
    echo -e "  ${WHITE}Prochaine étape :${NC}"
    echo -e "  ${CYAN}./laboboxvpn-manager.sh build${NC}"
    
    print_footer
}

###########################################
# COMMANDE: BUILD
###########################################
cmd_build() {
    print_header_with_title "BUILD IMAGE DOCKER"
    
    if [ ! -f "$INSTALL_DIR/Dockerfile" ]; then
        print_error_box "Dockerfile introuvable dans $INSTALL_DIR"
        return 1
    fi
    
    echo -e "  ${DIM}Construction de l'image rtorrent + ruTorrent...${NC}"
    echo -e "  ${DIM}Cela peut prendre plusieurs minutes.${NC}"
    echo ""
    
    cd "$INSTALL_DIR"
    
    if docker build -t laboboxvpn/rtorrent-rutorrent:latest . ; then
        print_success_box "IMAGE CONSTRUITE"
        echo ""
        echo -e "  ${DIM}Image : laboboxvpn/rtorrent-rutorrent:latest${NC}"
    else
        print_error_box "Erreur lors du build"
        return 1
    fi
    
    print_footer
}

###########################################
# OPTIMISATION RESEAU & STOCKAGE
###########################################
# Tout vit dans utils/network-optimize.sh (portage de l'optimiseur de
# Network-WireGuard-Manager) : reseau ET writeback NFS dans UN SEUL fichier
# sysctl — les deux anciens fichiers separes se contredisaient (le fichier
# reseau, applique apres le fichier stockage, remettait vm.dirty_ratio et
# annulait le writeback en bytes).

cmd_optimize() {
    local opt="$UTILS_DIR/network-optimize.sh"
    if [ ! -f "$opt" ]; then
        print_error_box "Script d'optimisation non trouvé" "└─ Copiez network-optimize.sh dans $UTILS_DIR"
        return 1
    fi
    # Garde-fou CRLF : si le fichier a été récupéré avec des fins de ligne
    # Windows (git core.autocrlf, éditeur…), bash le rejette avec des erreurs
    # « $'\r' : commande introuvable ». On normalise en LF une bonne fois
    # (le dépôt est en LF : après ça, aucun diff git).
    if grep -q $'\r' "$opt" 2>/dev/null; then
        sed -i 's/\r$//' "$opt" 2>/dev/null || true
    fi
    bash "$opt" "$@"
}

###########################################
# MIGRATION SESSION VERS DISQUE LOCAL
###########################################
# Les clients crees avant la v3.1.0 n'ont pas le volume /local dans leur
# docker-compose.yml. Cette fonction l'ajoute et prepare les dossiers.
# La copie des donnees de session est faite par l'entrypoint au premier
# demarrage : on ne touche pas aux fichiers ici.

migrate_client_session() {
    local CLIENT=$1
    local compose_file="$CLIENTS_DIR/$CLIENT/docker-compose.yml"

    if [ ! -f "$compose_file" ]; then
        echo -e "  ${RED}✗${NC} $CLIENT ${DIM}(docker-compose.yml introuvable)${NC}"
        return 1
    fi

    if grep -q ":/local" "$compose_file"; then
        echo -e "  ${DIM}-${NC} $CLIENT ${DIM}(deja migre)${NC}"
        return 0
    fi

    local USER_UID=$(id -u "$CLIENT" 2>/dev/null)
    local USER_GID=$(id -g "$CLIENT" 2>/dev/null)

    if [ -z "$USER_UID" ]; then
        echo -e "  ${RED}✗${NC} $CLIENT ${DIM}(utilisateur systeme introuvable)${NC}"
        return 1
    fi

    mkdir -p "$CLIENTS_DIR/$CLIENT/local/session"
    mkdir -p "$CLIENTS_DIR/$CLIENT/local/log"
    chown -R "${USER_UID}:${USER_GID}" "$CLIENTS_DIR/$CLIENT/local"

    cp "$compose_file" "${compose_file}.bak-$(date +%Y%m%d%H%M%S)"

    # Inserer le volume juste apres la ligne du bind mount /data
    sed -i "\|:/data\$|a\\      - ${CLIENTS_DIR}/${CLIENT}/local:/local" "$compose_file"

    if grep -q ":/local" "$compose_file"; then
        echo -e "  ${GREEN}✔${NC} $CLIENT"
        return 0
    else
        echo -e "  ${RED}✗${NC} $CLIENT ${DIM}(insertion du volume echouee)${NC}"
        return 1
    fi
}

cmd_migrate_sessions() {
    print_header_with_title "MIGRATION SESSION VERS DISQUE LOCAL"

    echo -e "  ${DIM}Ajoute le volume /local au docker-compose de chaque client.${NC}"
    echo -e "  ${DIM}La session est ensuite recopiee depuis le NAS par l'entrypoint${NC}"
    echo -e "  ${DIM}au premier demarrage. Aucune donnee n'est supprimee.${NC}"
    echo ""
    echo -e "  ${YELLOW}Les clients doivent etre redemarres apres cette operation.${NC}"
    echo ""

    read -p "  Continuer ? [o/N] " confirm
    if [ "$confirm" != "o" ] && [ "$confirm" != "O" ]; then
        echo ""
        echo -e "  ${DIM}Annule${NC}"
        print_footer
        return
    fi

    echo ""
    local count=0

    if [ -d "$CLIENTS_DIR" ]; then
        for client_dir in "$CLIENTS_DIR"/*/; do
            [ -d "$client_dir" ] || continue
            local client=$(basename "$client_dir")
            migrate_client_session "$client"
            count=$((count + 1))
        done
    fi

    echo ""
    if [ "$count" -eq 0 ]; then
        echo -e "  ${DIM}Aucun client trouve${NC}"
    else
        # Les logs partent aussi sur /local : la rotation automatique doit
        # couvrir le nouveau chemin (idempotent, réécrit le drop-in complet).
        install_logrotate
        echo -e "  ${DIM}$count client(s) traite(s). Une sauvegarde .bak a ete creee${NC}"
        echo -e "  ${DIM}pour chaque docker-compose.yml modifie.${NC}"
        echo -e "  ${DIM}Rotation automatique des logs installee (logrotate).${NC}"
        echo ""
        echo -e "  ${WHITE}Etape suivante :${NC}"
        echo -e "  ${DIM}  cd $CLIENTS_DIR/<client> && docker compose down && docker compose up -d${NC}"
    fi

    print_footer
}

###########################################
# DISQUE SSD TEMPORAIRE — bascule interactive
###########################################
# La session rtorrent vit TOUJOURS sur le NAS (voir entrypoint) : plus de
# choix d'emplacement. Ce petit menu active ou desactive le disque SSD
# temporaire pour les clients.
interactive_temp_toggle() {
    print_menu_header

    echo -e "  ${WHITE}DISQUE SSD TEMPORAIRE${NC}"
    line
    echo ""
    if [ -n "$TEMP_DIR" ]; then
        echo -e "  Dossier SSD configuré : ${CYAN}${TEMP_DIR}${NC}"
    else
        echo -e "  ${DIM}Aucun dossier SSD configuré (menu « Configurer le réseau »).${NC}"
    fi
    echo ""
    print_menu_option "1" "-" "Activer  ${DIM}(télécharger sur le SSD puis déplacer vers le NAS)${NC}"
    print_menu_option "2" "-" "Désactiver  ${DIM}(télécharger directement sur le NAS)${NC}"
    print_menu_separator
    print_menu_option "0" "-" "Retour"

    read_choice "Votre choix" ""

    case $MENU_CHOICE in
        1) cmd_temp_enable; press_enter ;;
        2) cmd_temp_disable; press_enter ;;
        *) ;;
    esac
}

###########################################
# DISQUE SSD TEMPORAIRE (clients existants)
###########################################
# Ajoute (ou retire) le volume /temp au docker-compose des clients, sur le
# modèle de la migration des sessions. La logique de déplacement à la
# complétion vit dans l'entrypoint de l'image : après un git pull, l'image
# doit être reconstruite (menu Maintenance → 3) AVANT d'activer ceci.

temp_enable_client() {
    local CLIENT=$1
    local compose_file="$CLIENTS_DIR/$CLIENT/docker-compose.yml"

    if [ ! -f "$compose_file" ]; then
        echo -e "  ${RED}✗${NC} $CLIENT ${DIM}(docker-compose.yml introuvable)${NC}"
        return 1
    fi
    if grep -q ":/temp" "$compose_file"; then
        echo -e "  ${DIM}-${NC} $CLIENT ${DIM}(déjà activé)${NC}"
        return 0
    fi

    local USER_UID=$(id -u "$CLIENT" 2>/dev/null)
    local USER_GID=$(id -g "$CLIENT" 2>/dev/null)
    if [ -z "$USER_UID" ]; then
        echo -e "  ${RED}✗${NC} $CLIENT ${DIM}(utilisateur système introuvable)${NC}"
        return 1
    fi

    mkdir -p "${TEMP_DIR}/${CLIENT}"
    chown "${USER_UID}:${USER_GID}" "${TEMP_DIR}/${CLIENT}" 2>/dev/null || true

    cp "$compose_file" "${compose_file}.bak-$(date +%Y%m%d%H%M%S)"

    # Insérer le volume après la ligne /local (clients migrés), sinon /data
    if grep -q ":/local\$" "$compose_file"; then
        sed -i "\|:/local\$|a\\      - ${TEMP_DIR}/${CLIENT}:/temp" "$compose_file"
    else
        sed -i "\|:/data\$|a\\      - ${TEMP_DIR}/${CLIENT}:/temp" "$compose_file"
    fi

    if grep -q ":/temp" "$compose_file"; then
        echo -e "  ${GREEN}✔${NC} $CLIENT"
        return 0
    else
        echo -e "  ${RED}✗${NC} $CLIENT ${DIM}(insertion du volume échouée)${NC}"
        return 1
    fi
}

cmd_temp_enable() {
    local ONLY_CLIENT="$1"
    print_header_with_title "DISQUE SSD TEMPORAIRE"

    if [ -z "$TEMP_DIR" ]; then
        print_error_box "Aucun disque temporaire configuré" "└─ Menu Maintenance → Configurer le réseau (dossier SSD)"
        return 1
    fi
    if [ ! -d "$TEMP_DIR" ]; then
        print_error_box "Le dossier ${TEMP_DIR} n'existe pas" "└─ Monte le SSD dessus avant d'activer"
        return 1
    fi

    echo -e "  ${DIM}Ajoute le volume /temp au docker-compose des clients : téléchargements${NC}"
    echo -e "  ${DIM}sur ${TEMP_DIR}, déplacés vers le NAS à la complétion.${NC}"
    echo ""
    echo -e "  ${YELLOW}Prérequis : image reconstruite après mise à jour (menu 3), puis${NC}"
    echo -e "  ${YELLOW}redémarrage des clients concernés après cette opération.${NC}"
    echo ""

    read -p "  Continuer ? [o/N] " confirm
    if [ "$confirm" != "o" ] && [ "$confirm" != "O" ]; then
        echo ""
        echo -e "  ${DIM}Annulé${NC}"
        print_footer
        return
    fi

    echo ""
    local count=0
    for CLIENT in $(get_clients); do
        [ -n "$ONLY_CLIENT" ] && [ "$CLIENT" != "$ONLY_CLIENT" ] && continue
        temp_enable_client "$CLIENT"
        count=$((count + 1))
    done

    echo ""
    if [ "$count" -eq 0 ]; then
        echo -e "  ${DIM}Aucun client trouvé${NC}"
    else
        echo -e "  ${DIM}$count client(s) traité(s) — une sauvegarde .bak a été créée pour${NC}"
        echo -e "  ${DIM}chaque docker-compose.yml modifié.${NC}"
        echo ""
        echo -e "  ${WHITE}Étape suivante :${NC} redémarrer les clients (menu Maintenance → 4)"
    fi
    print_footer
}

cmd_temp_disable() {
    local ONLY_CLIENT="$1"
    print_header_with_title "DISQUE SSD TEMPORAIRE — DÉSACTIVATION"

    echo -e "  ${YELLOW}⚠ Les téléchargements EN COURS d'un client vivent sur son disque${NC}"
    echo -e "  ${YELLOW}temporaire : désactiver pendant qu'ils tournent les rendrait invisibles${NC}"
    echo -e "  ${YELLOW}au conteneur. Termine ou supprime les téléchargements en cours d'abord.${NC}"
    echo ""

    read -p "  Continuer ? [o/N] " confirm
    if [ "$confirm" != "o" ] && [ "$confirm" != "O" ]; then
        echo ""
        echo -e "  ${DIM}Annulé${NC}"
        print_footer
        return
    fi

    echo ""
    local count=0
    for CLIENT in $(get_clients); do
        [ -n "$ONLY_CLIENT" ] && [ "$CLIENT" != "$ONLY_CLIENT" ] && continue
        local compose_file="$CLIENTS_DIR/$CLIENT/docker-compose.yml"
        [ -f "$compose_file" ] || continue
        if grep -q ":/temp\$" "$compose_file"; then
            cp "$compose_file" "${compose_file}.bak-$(date +%Y%m%d%H%M%S)"
            sed -i "\|:/temp\$|d" "$compose_file"
            echo -e "  ${GREEN}✔${NC} $CLIENT ${DIM}(les fichiers de ${TEMP_DIR:-?}/${CLIENT} sont conservés)${NC}"
            count=$((count + 1))
        else
            echo -e "  ${DIM}-${NC} $CLIENT ${DIM}(déjà désactivé)${NC}"
        fi
    done

    echo ""
    [ "$count" -gt 0 ] && echo -e "  ${WHITE}Étape suivante :${NC} redémarrer les clients concernés"
    print_footer
}

###########################################
# COMMANDE: SEQUENTIAL-START
###########################################
cmd_sequential_start() {
    local start_time=$(date +%s)
    
    print_header_with_title "DÉMARRAGE COMPLET DE LA SEEDBOX"
    
    # Collecter les clients triés par port WebUI croissant
    local clients_sorted=""
    local client_count=0
    
    if [ -d "$CLIENTS_DIR" ]; then
        for client_dir in "$CLIENTS_DIR"/*/; do
            if [ -f "$client_dir/info.txt" ]; then
                local cname=$(basename "$client_dir")
                local cport=$(grep "PORT_RUTORRENT_WEBUI" "$client_dir/info.txt" 2>/dev/null | cut -d: -f2 | tr -d ' ')
                if [ -n "$cport" ]; then
                    clients_sorted="${clients_sorted}${cport}|${cname}\n"
                    ((client_count++))
                fi
            fi
        done
    fi
    
    if [ $client_count -eq 0 ]; then
        echo -e "  ${YELLOW}Aucun client configuré.${NC}"
        print_footer
        return 0
    fi
    
    # Compter les apps installées
    local apps_count=0
    local apps_list=""
    is_plex_installed && ((apps_count++)) && apps_list="${apps_list}Plex "
    is_jellyfin_installed && ((apps_count++)) && apps_list="${apps_list}Jellyfin "
    is_resilio_installed && ((apps_count++)) && apps_list="${apps_list}Resilio "
    is_watchtower_installed && ((apps_count++)) && apps_list="${apps_list}Watchtower "
    
    echo -e "  ${WHITE}Configuration :${NC}"
    print_item "Clients" "$client_count"
    print_item "Applications" "${apps_count} (${apps_list:-aucune})"
    print_item "Délai inter-client" "${STARTUP_DELAY}s"
    print_item_last "Timeout healthcheck" "${STARTUP_HEALTHCHECK_TIMEOUT}s"
    echo ""
    
    # ─────────────────────────────────────────────────────────────────────
    # ÉTAPE 1 : ARRÊT DE TOUT
    # ─────────────────────────────────────────────────────────────────────
    echo -e "  ${CYAN}► ÉTAPE 1/4 : Arrêt de tous les services${NC}"
    line
    
    # Arrêter les apps communes d'abord
    if [ $apps_count -gt 0 ]; then
        echo -ne "  ${DIM}Arrêt des applications communes...${NC}"
        for app in watchtower resilio jellyfin plex; do
            if [ -f "$APPS_DIR/$app/docker-compose.yml" ]; then
                cd "$APPS_DIR/$app"
                docker compose down >/dev/null 2>&1 || true
            fi
        done
        echo -e "\r  ${GREEN}✔${NC} Applications communes arrêtées           "
    fi
    
    # Arrêter tous les clients
    echo -ne "  ${DIM}Arrêt de tous les clients...${NC}"
    for client in $(get_clients); do
        cd "$CLIENTS_DIR/$client" 2>/dev/null
        docker compose down >/dev/null 2>&1 || true
    done
    echo -e "\r  ${GREEN}✔${NC} Tous les clients arrêtés                "
    echo ""
    
    # ─────────────────────────────────────────────────────────────────────
    # ÉTAPE 2 : MONTAGE NFS
    # ─────────────────────────────────────────────────────────────────────
    echo -e "  ${CYAN}► ÉTAPE 2/4 : Montage des partages NFS${NC}"
    line
    
    local nfs_ok=0
    local nfs_fail=0
    
    for client in $(get_clients); do
        local share_name=$(get_nas_share_name $client)
        echo -ne "  ${DIM}Montage ${share_name}...${NC}"
        if mount_nas_for_client "$client" 2>/dev/null; then
            echo -e "\r  ${GREEN}✔${NC} ${share_name}                              "
            ((nfs_ok++))
        else
            echo -e "\r  ${RED}✗${NC} ${share_name} (échec)                       "
            ((nfs_fail++))
        fi
    done
    
    if [ $nfs_fail -gt 0 ]; then
        echo ""
        echo -e "  ${YELLOW}⚠ ${nfs_fail} montage(s) en échec - certains clients pourraient ne pas fonctionner${NC}"
    fi
    echo ""
    
    # ─────────────────────────────────────────────────────────────────────
    # ÉTAPE 3 : DÉMARRAGE SÉQUENTIEL DES CLIENTS
    # ─────────────────────────────────────────────────────────────────────
    echo -e "  ${CYAN}► ÉTAPE 3/4 : Démarrage des clients (par port croissant)${NC}"
    line
    echo ""
    
    local current=0
    local clients_ok=0
    local clients_fail=0
    
    # Trier et parcourir
    echo -e "$clients_sorted" | sort -t'|' -k1 -n | while IFS='|' read -r port client; do
        [ -z "$client" ] && continue
        ((current++))
        
        local port_rt=$(grep "PORT_RTORRENT_VPN" "$CLIENTS_DIR/$client/info.txt" 2>/dev/null | cut -d: -f2 | tr -d ' ')
        
        echo -e "  ${WHITE}[${current}/${client_count}] ${client}${NC} ${DIM}(WebUI: ${port}, RT: ${port_rt})${NC}"
        
        # Démarrer le client
        cd "$CLIENTS_DIR/$client"
        docker compose up -d >/dev/null 2>&1
        
        # Attendre le healthcheck de Gluetun
        echo -ne "       Gluetun: ${DIM}attente healthcheck...${NC}"
        
        local healthy=false
        local elapsed=0
        
        while [ $elapsed -lt $STARTUP_HEALTHCHECK_TIMEOUT ]; do
            local health=$(docker inspect --format='{{.State.Health.Status}}' "gluetun-$client" 2>/dev/null)
            if [ "$health" = "healthy" ]; then
                healthy=true
                break
            fi
            sleep 2
            ((elapsed+=2))
            echo -ne "\r       Gluetun: ${DIM}attente healthcheck... ${elapsed}s${NC}   "
        done
        
        if [ "$healthy" = true ]; then
            local vpn_ip=$(get_vpn_ip "$client" 2>/dev/null)
            [ -z "$vpn_ip" ] && vpn_ip="connecté"
            echo -e "\r       Gluetun: ${GREEN}✔${NC} healthy (IP: ${vpn_ip})              "
        else
            echo -e "\r       Gluetun: ${RED}✗${NC} timeout après ${STARTUP_HEALTHCHECK_TIMEOUT}s    "
        fi
        
        # Vérifier rtorrent
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "rtorrent-$client"; then
            echo -e "       rtorrent: ${GREEN}✔${NC} démarré"
        else
            echo -e "       rtorrent: ${RED}✗${NC} non démarré"
        fi
        
        # Délai avant le prochain client (sauf le dernier)
        if [ $current -lt $client_count ]; then
            echo -e "       ${DIM}⏳ Délai ${STARTUP_DELAY}s avant prochain client...${NC}"
            sleep $STARTUP_DELAY
        fi
        echo ""
    done
    
    # ─────────────────────────────────────────────────────────────────────
    # ÉTAPE 4 : DÉMARRAGE DES APPLICATIONS COMMUNES
    # ─────────────────────────────────────────────────────────────────────
    echo -e "  ${CYAN}► ÉTAPE 4/4 : Démarrage des applications communes${NC}"
    line
    
    if [ $apps_count -eq 0 ]; then
        echo -e "  ${DIM}Aucune application installée${NC}"
    else
        local app_current=0
        
        # Plex en premier
        if is_plex_installed; then
            ((app_current++))
            echo -ne "  [${app_current}/${apps_count}] Plex... "
            cd "$APPS_DIR/plex"
            docker compose up -d >/dev/null 2>&1
            if is_plex_running; then
                echo -e "${GREEN}✔${NC}"
            else
                echo -e "${RED}✗${NC}"
            fi
        fi
        
        # Jellyfin ensuite
        if is_jellyfin_installed; then
            ((app_current++))
            echo -ne "  [${app_current}/${apps_count}] Jellyfin... "
            cd "$APPS_DIR/jellyfin"
            docker compose up -d >/dev/null 2>&1
            if is_jellyfin_running; then
                echo -e "${GREEN}✔${NC}"
            else
                echo -e "${RED}✗${NC}"
            fi
        fi
        
        # Resilio
        if is_resilio_installed; then
            ((app_current++))
            echo -ne "  [${app_current}/${apps_count}] Resilio Sync... "
            cd "$APPS_DIR/resilio"
            docker compose up -d >/dev/null 2>&1
            if is_resilio_running; then
                echo -e "${GREEN}✔${NC}"
            else
                echo -e "${RED}✗${NC}"
            fi
        fi
        
        # Watchtower en dernier
        if is_watchtower_installed; then
            ((app_current++))
            echo -ne "  [${app_current}/${apps_count}] Watchtower... "
            cd "$APPS_DIR/watchtower"
            docker compose up -d >/dev/null 2>&1
            if is_watchtower_running; then
                echo -e "${GREEN}✔${NC}"
            else
                echo -e "${RED}✗${NC}"
            fi
        fi
    fi
    
    # ─────────────────────────────────────────────────────────────────────
    # RÉSUMÉ FINAL
    # ─────────────────────────────────────────────────────────────────────
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))
    
    echo ""
    double_line
    echo -e "  ${GREEN}✅ SEEDBOX OPÉRATIONNELLE${NC}"
    double_line
    echo ""
    
    # Compter les clients actifs
    local active_clients=0
    for client in $(get_clients); do
        docker ps --format '{{.Names}}' 2>/dev/null | grep -q "gluetun-$client" && ((active_clients++))
    done
    
    # Compter les apps actives
    local active_apps=0
    is_plex_running && ((active_apps++))
    is_jellyfin_running && ((active_apps++))
    is_resilio_running && ((active_apps++))
    is_watchtower_running && ((active_apps++))
    
    print_item "Clients actifs" "${active_clients}/${client_count}"
    print_item "Applications actives" "${active_apps}/${apps_count}"
    print_item_last "Durée totale" "${minutes}m ${seconds}s"
    
    print_footer
}

###########################################
# COMMANDE: SEQUENTIAL-STOP
###########################################
cmd_sequential_stop() {
    print_header_with_title "ARRÊT COMPLET DE LA SEEDBOX"
    
    local client_count=$(get_clients | wc -l)
    
    echo -e "  ${WHITE}Arrêt en cours...${NC}"
    echo ""
    
    # ─────────────────────────────────────────────────────────────────────
    # ÉTAPE 1 : ARRÊT DES APPLICATIONS COMMUNES
    # ─────────────────────────────────────────────────────────────────────
    echo -e "  ${CYAN}► ÉTAPE 1/2 : Arrêt des applications communes${NC}"
    line
    
    for app in watchtower resilio jellyfin plex; do
        if [ -f "$APPS_DIR/$app/docker-compose.yml" ]; then
            local app_name=$(echo "$app" | sed 's/.*/\u&/')
            echo -ne "  Arrêt ${app_name}... "
            cd "$APPS_DIR/$app"
            docker compose down >/dev/null 2>&1
            echo -e "${GREEN}✔${NC}"
        fi
    done
    echo ""
    
    # ─────────────────────────────────────────────────────────────────────
    # ÉTAPE 2 : ARRÊT DES CLIENTS
    # ─────────────────────────────────────────────────────────────────────
    echo -e "  ${CYAN}► ÉTAPE 2/2 : Arrêt des clients${NC}"
    line
    
    local current=0
    for client in $(get_clients); do
        ((current++))
        echo -ne "  [${current}/${client_count}] Arrêt ${client}... "
        cd "$CLIENTS_DIR/$client" 2>/dev/null
        docker compose down >/dev/null 2>&1
        echo -e "${GREEN}✔${NC}"
        
        if [ $current -lt $client_count ]; then
            sleep $SHUTDOWN_DELAY
        fi
    done
    
    print_success_box "SEEDBOX ARRÊTÉE"
    print_footer
}

###########################################
# COMMANDE: CONFIG-NETWORK
###########################################
cmd_config_network() {
    print_header_with_title "CONFIGURATION RÉSEAU"
    
    # Détecter l'IP actuelle
    local current_ip=$(grep "address " /etc/network/interfaces 2>/dev/null | grep -v "#" | awk '{print $2}' | head -1)
    [ -z "$current_ip" ] && current_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    
    # Détecter le port SSH actuel
    local current_ssh_port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    [ -z "$current_ssh_port" ] && current_ssh_port="22"
    
    echo -e "  ${WHITE}Configuration actuelle :${NC}"
    line
    print_item "IP de la VM" "$current_ip"
    print_item "Port SSH" "$current_ssh_port"
    print_item "IP du NAS" "$NAS_IP"
    print_item_last "Disque SSD temp." "${TEMP_DIR:-désactivé}"
    echo ""
    
    echo -e "  ${WHITE}Nouvelle configuration :${NC}"
    line
    echo ""
    
    # IP de la VM
    echo -ne "  Nouvelle IP de cette VM [${current_ip}] : "
    read input_server_ip
    [ -z "$input_server_ip" ] && input_server_ip="$current_ip"
    
    # Port SSH
    echo -ne "  Nouveau port SSH [${current_ssh_port}] : "
    read input_ssh_port
    [ -z "$input_ssh_port" ] && input_ssh_port="$current_ssh_port"
    
    # IP du NAS
    local current_nas_ip="$NAS_IP"
    [ "$current_nas_ip" = "A_CONFIGURER" ] && current_nas_ip=""
    echo -ne "  IP du NAS Synology [${current_nas_ip}] : "
    read input_nas_ip
    [ -z "$input_nas_ip" ] && input_nas_ip="$current_nas_ip"

    # Disque SSD temporaire (optionnel)
    echo ""
    echo -e "  ${DIM}Disque SSD temporaire (optionnel) : les torrents y sont téléchargés${NC}"
    echo -e "  ${DIM}puis déplacés automatiquement vers le NAS une fois terminés.${NC}"
    echo -ne "  Dossier du SSD temporaire [${TEMP_DIR:-aucun}] (« aucun » = désactiver) : "
    read input_temp_dir
    if [ -z "$input_temp_dir" ]; then
        input_temp_dir="$TEMP_DIR"
    elif [ "$input_temp_dir" = "aucun" ]; then
        input_temp_dir=""
    fi
    if [ -n "$input_temp_dir" ] && [ ! -d "$input_temp_dir" ]; then
        echo -e "  ${YELLOW}⚠ ${input_temp_dir} n'existe pas encore (monte le SSD dessus) — enregistré quand même.${NC}"
    fi

    # Taille maximale d'un torrent (garde-fou), saisie en To
    echo ""
    local cur_size_to
    cur_size_to=$(awk -v b="${MAX_TORRENT_SIZE:-0}" 'BEGIN{ if(b+0==0) print 0; else printf "%.0f", b/1099511627776 }')
    echo -e "  ${DIM}Taille maximale d'un torrent accepté à l'ajout (garde-fou).${NC}"
    echo -ne "  Taille max en To [${cur_size_to}] (0 = illimité) : "
    read input_max_to
    local input_max_size="${MAX_TORRENT_SIZE:-0}"
    if [ -n "$input_max_to" ]; then
        case "$input_max_to" in
            0) input_max_size="0" ;;
            *[!0-9]*) echo -e "  ${YELLOW}⚠ Valeur ignorée (nombre entier de To attendu).${NC}" ;;
            *) input_max_size=$((input_max_to * 1099511627776)) ;;
        esac
    fi

    echo ""
    echo -e "  ${WHITE}Résumé des modifications :${NC}"
    line
    
    local changes_made=0
    
    # Afficher les changements prévus
    if [ "$input_server_ip" != "$current_ip" ] && [ -n "$input_server_ip" ]; then
        print_item "IP VM" "${current_ip} → ${input_server_ip}"
        changes_made=1
    else
        print_item "IP VM" "${current_ip} (inchangé)"
    fi
    
    if [ "$input_ssh_port" != "$current_ssh_port" ]; then
        print_item "Port SSH" "${current_ssh_port} → ${input_ssh_port}"
        changes_made=1
    else
        print_item "Port SSH" "${current_ssh_port} (inchangé)"
    fi
    
    if [ "$input_nas_ip" != "$NAS_IP" ] && [ -n "$input_nas_ip" ]; then
        print_item "IP NAS" "${NAS_IP} → ${input_nas_ip}"
        changes_made=1
    else
        print_item "IP NAS" "${NAS_IP} (inchangé)"
    fi

    if [ "$input_temp_dir" != "$TEMP_DIR" ]; then
        print_item "Disque SSD temp." "${TEMP_DIR:-désactivé} → ${input_temp_dir:-désactivé}"
    else
        print_item "Disque SSD temp." "${TEMP_DIR:-désactivé} (inchangé)"
    fi

    local old_size_h new_size_h
    old_size_h=$(awk -v b="${MAX_TORRENT_SIZE:-0}" 'BEGIN{ if(b+0==0) print "illimité"; else printf "%.0f To", b/1099511627776 }')
    new_size_h=$(awk -v b="${input_max_size:-0}" 'BEGIN{ if(b+0==0) print "illimité"; else printf "%.0f To", b/1099511627776 }')
    if [ "$input_max_size" != "${MAX_TORRENT_SIZE:-0}" ]; then
        print_item_last "Taille max torrent" "${old_size_h} → ${new_size_h}"
    else
        print_item_last "Taille max torrent" "${old_size_h} (inchangé)"
    fi

    echo ""

    # La config stockée doit-elle être (ré)écrite ? Au premier lancement,
    # une valeur affichée « (inchangé) » (IP ou port SSH détectés) n'a
    # encore JAMAIS été enregistrée dans laboboxvpn.conf : sans cette
    # écriture, is_network_configured() reste faux et bloque l'init.
    local config_changed=0
    [ -n "$input_server_ip" ] && [ "$SERVER_IP" != "$input_server_ip" ] && config_changed=1
    [ -n "$input_ssh_port" ] && [ "$SSH_PORT" != "$input_ssh_port" ] && config_changed=1
    [ -n "$input_nas_ip" ] && [ "$NAS_IP" != "$input_nas_ip" ] && config_changed=1
    [ "$input_temp_dir" != "$TEMP_DIR" ] && config_changed=1
    [ "$input_max_size" != "${MAX_TORRENT_SIZE:-0}" ] && config_changed=1

    if [ $changes_made -eq 0 ] && [ $config_changed -eq 0 ]; then
        echo -e "  ${DIM}Aucune modification à appliquer.${NC}"
        print_footer
        return 0
    fi
    
    # Avertissement si changement d'IP
    if [ "$input_server_ip" != "$current_ip" ] && [ -n "$input_server_ip" ]; then
        echo -e "  ${YELLOW}⚠ ATTENTION : Changer l'IP nécessite un redémarrage réseau.${NC}"
        echo -e "  ${YELLOW}  Vous pourriez perdre la connexion SSH !${NC}"
        echo ""
    fi
    
    if ! confirm "Appliquer ces modifications ?"; then
        echo ""
        echo -e "  ${DIM}Opération annulée.${NC}"
        print_footer
        return 0
    fi
    
    echo ""
    
    # Appliquer les modifications
    local need_network_restart=0
    local need_ssh_restart=0

    # Persister TOUTES les valeurs acceptées — y compris celles affichées
    # « (inchangé) » : la valeur détectée (IP de la VM, port SSH) doit finir
    # dans laboboxvpn.conf même quand le système, lui, n'a rien à changer.
    local old_nas_ip="$NAS_IP"
    local old_temp_dir="$TEMP_DIR"
    local old_max_size="${MAX_TORRENT_SIZE:-0}"
    [ -n "$input_server_ip" ] && SERVER_IP="$input_server_ip"
    [ -n "$input_ssh_port" ] && SSH_PORT="$input_ssh_port"
    [ -n "$input_nas_ip" ] && NAS_IP="$input_nas_ip"
    TEMP_DIR="$input_temp_dir"
    MAX_TORRENT_SIZE="$input_max_size"

    # 1. Modifier l'IP dans /etc/network/interfaces
    if [ "$input_server_ip" != "$current_ip" ] && [ -n "$input_server_ip" ]; then
        echo -e "  ${DIM}Modification de /etc/network/interfaces...${NC}"

        if [ -f /etc/network/interfaces ]; then
            sed -i "s/address ${current_ip}/address ${input_server_ip}/g" /etc/network/interfaces
            need_network_restart=1
            echo -e "  ${GREEN}✔ IP modifiée : ${input_server_ip}${NC}"
        else
            echo -e "  ${RED}✗ Fichier /etc/network/interfaces non trouvé${NC}"
        fi
    fi

    # 2. Modifier le port SSH
    if [ "$input_ssh_port" != "$current_ssh_port" ]; then
        echo -e "  ${DIM}Modification de /etc/ssh/sshd_config...${NC}"

        if [ -f /etc/ssh/sshd_config ]; then
            if grep -q "^Port " /etc/ssh/sshd_config; then
                sed -i "s/^Port .*/Port ${input_ssh_port}/" /etc/ssh/sshd_config
            elif grep -q "^#Port " /etc/ssh/sshd_config; then
                sed -i "s/^#Port .*/Port ${input_ssh_port}/" /etc/ssh/sshd_config
            else
                echo "Port ${input_ssh_port}" >> /etc/ssh/sshd_config
            fi
            need_ssh_restart=1
            echo -e "  ${GREEN}✔ Port SSH modifié : ${input_ssh_port}${NC}"
        else
            echo -e "  ${RED}✗ Fichier /etc/ssh/sshd_config non trouvé${NC}"
        fi
    fi

    # 3. Modifier l'IP du NAS
    if [ "$NAS_IP" != "$old_nas_ip" ]; then
        echo -e "  ${GREEN}✔ IP NAS enregistrée : ${NAS_IP}${NC}"
    fi

    # 4. Disque SSD temporaire
    if [ "$TEMP_DIR" != "$old_temp_dir" ]; then
        if [ -n "$TEMP_DIR" ]; then
            echo -e "  ${GREEN}✔ Disque SSD temporaire : ${TEMP_DIR}${NC}"
            echo -e "  ${DIM}  Active-le pour les clients existants : menu Maintenance →${NC}"
            echo -e "  ${DIM}  « Activer le disque SSD temporaire » (ou temp-enable en CLI).${NC}"
        else
            echo -e "  ${GREEN}✔ Disque SSD temporaire désactivé pour les futurs clients${NC}"
        fi
    fi

    # 5. Taille max des torrents — propagée aux compose des clients existants
    if [ "$MAX_TORRENT_SIZE" != "$old_max_size" ]; then
        local _c _cf _n=0
        for _c in $(get_clients); do
            _cf="$CLIENTS_DIR/$_c/docker-compose.yml"
            [ -f "$_cf" ] || continue
            if grep -q "RT_MAX_TORRENT_SIZE=" "$_cf"; then
                sed -i "s|      - RT_MAX_TORRENT_SIZE=.*|      - RT_MAX_TORRENT_SIZE=${MAX_TORRENT_SIZE}|" "$_cf"
            else
                sed -i "\|- RU_DISABLED_PLUGINS=|a\\      - RT_MAX_TORRENT_SIZE=${MAX_TORRENT_SIZE}" "$_cf"
            fi
            _n=$((_n + 1))
        done
        echo -e "  ${GREEN}✔ Taille max des torrents : ${new_size_h}${NC}"
        [ "$_n" -gt 0 ] && echo -e "  ${DIM}  Appliquée à ${_n} client(s) — redémarre-les pour l'activer.${NC}"
    fi

    # Sauvegarder la configuration
    if save_config; then
        echo -e "  ${GREEN}✔ Configuration sauvegardée dans ${CONFIG_FILE}${NC}"
    else
        echo -e "  ${RED}✗ Impossible d'écrire ${CONFIG_FILE} — configuration NON sauvegardée${NC}"
    fi
    
    echo ""
    
    # Redémarrer les services si nécessaire
    if [ $need_ssh_restart -eq 1 ]; then
        echo -e "  ${DIM}Redémarrage du service SSH...${NC}"
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service ssh restart 2>/dev/null
        echo -e "  ${GREEN}✔ Service SSH redémarré${NC}"
    fi
    
    if [ $need_network_restart -eq 1 ]; then
        echo ""
        echo -e "  ${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "  ${CYAN}║               REDÉMARRAGE DU SERVEUR REQUIS                    ║${NC}"
        echo -e "  ${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  La nouvelle configuration réseau nécessite un redémarrage"
        echo -e "  du serveur pour être appliquée."
        echo ""
        echo -e "  ${WHITE}Nouvelles informations de connexion :${NC}"
        line
        print_item "Adresse IP" "${input_server_ip}"
        print_item "Port SSH" "${SSH_PORT}"
        print_item_last "Commande" "ssh root@${input_server_ip} -p ${SSH_PORT}"
        echo ""
        
        if confirm "Redémarrer le serveur maintenant ?"; then
            echo ""
            echo -e "  ${WHITE}Le serveur va redémarrer dans 5 secondes...${NC}"
            sleep 5
            reboot
        else
            echo ""
            echo -e "  ${YELLOW}Redémarrage annulé.${NC}"
            echo -e "  ${DIM}N'oubliez pas de redémarrer le serveur manuellement : reboot${NC}"
        fi
    fi
    
    print_success_box "CONFIGURATION ENREGISTRÉE"
    
    print_footer
}

###########################################
# COMMANDE: UNINSTALL
###########################################
cmd_uninstall() {
    print_header_with_title "⚠ DÉSINSTALLATION COMPLÈTE"
    
    local clients=$(get_clients)
    local client_count=$(echo "$clients" | grep -c . 2>/dev/null || echo "0")
    [ -z "$clients" ] && client_count=0
    
    echo -e "  ${RED}Cette action va supprimer :${NC}"
    echo ""
    print_item "Clients" "${client_count} client(s) et leurs conteneurs"
    print_item "Image Docker" "laboboxvpn/rtorrent-rutorrent"
    print_item "Apps communes" "Plex, Jellyfin, Resilio, Watchtower"
    print_item "Dashboard" "Service et configuration"
    print_item "Configuration" "${INSTALL_DIR}/"
    print_item "Montages NAS" "Tous les bind mounts et montages NFS"
    print_item "Utilisateurs" "Tous les utilisateurs laboboxvpn"
    print_item_last "Groupe" "laboboxvpn"
    echo ""
    echo -e "  ${YELLOW}Les données sur le NAS ne seront PAS supprimées.${NC}"
    echo -e "  ${YELLOW}La configuration SSH/SFTP sera conservée.${NC}"
    echo ""
    
    if ! confirm "Voulez-vous vraiment tout désinstaller ?"; then
        echo ""
        echo -e "  ${GREEN}Opération annulée.${NC}"
        print_footer
        return 0
    fi
    
    echo ""
    echo -e "  ${RED}Êtes-vous VRAIMENT sûr ? Tapez 'SUPPRIMER' pour confirmer :${NC}"
    echo -ne "  > "
    read confirmation
    
    if [ "$confirmation" != "SUPPRIMER" ]; then
        echo ""
        echo -e "  ${GREEN}Opération annulée.${NC}"
        print_footer
        return 0
    fi
    
    echo ""
    local step=1
    local total_steps=7
    
    # Étape 1: Arrêter le dashboard
    print_step $step $total_steps "Arrêt du dashboard" "wait"
    if systemctl is-active --quiet labobox-dashboard 2>/dev/null; then
        systemctl stop labobox-dashboard 2>/dev/null || true
    fi
    if systemctl is-enabled --quiet labobox-dashboard 2>/dev/null; then
        systemctl disable labobox-dashboard --quiet 2>/dev/null || true
    fi
    rm -f /etc/systemd/system/labobox-dashboard.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    rm -f "${UTILS_DIR}/config.json" 2>/dev/null || true
    echo -e "\r  ${DIM}[${step}/${total_steps}]${NC} Arrêt du dashboard ${DIM}...${NC} ${GREEN}✔${NC}"
    ((step++))
    
    # Étape 2: Arrêter tous les conteneurs
    print_step $step $total_steps "Arrêt de tous les conteneurs" "wait"
    for client in $clients; do
        cd "$CLIENTS_DIR/$client" 2>/dev/null && docker compose down >/dev/null 2>&1 || true
        docker rm -f gluetun-$client rtorrent-$client >/dev/null 2>&1 || true
    done
    # Arrêter les apps communes
    docker rm -f jellyfin plex resilio watchtower >/dev/null 2>&1 || true
    echo -e "\r  ${DIM}[${step}/${total_steps}]${NC} Arrêt de tous les conteneurs ${DIM}...${NC} ${GREEN}✔${NC}"
    ((step++))
    
    # Étape 3: Démonter tous les bind mounts
    print_step $step $total_steps "Démontage des bind mounts" "wait"
    for client in $clients; do
        if mountpoint -q "/home/$client/data" 2>/dev/null; then
            umount "/home/$client/data" 2>/dev/null || umount -l "/home/$client/data" 2>/dev/null || true
        fi
        remove_bindmount_from_fstab "$client"
    done
    echo -e "\r  ${DIM}[${step}/${total_steps}]${NC} Démontage des bind mounts ${DIM}...${NC} ${GREEN}✔${NC}"
    ((step++))
    
    # Étape 4: Démonter tous les partages NAS
    print_step $step $total_steps "Démontage des partages NAS" "wait"
    for client in $clients; do
        umount_nas_for_client "$client"
        remove_fstab_for_client "$client"
    done
    rm -rf "$NAS_MOUNT"/SEEDBOX_* 2>/dev/null || true
    echo -e "\r  ${DIM}[${step}/${total_steps}]${NC} Démontage des partages NAS ${DIM}...${NC} ${GREEN}✔${NC}"
    ((step++))
    
    # Étape 5: Supprimer les utilisateurs
    print_step $step $total_steps "Suppression des utilisateurs" "wait"
    for client in $clients; do
        remove_linux_user "$client"
        rm -rf "/home/$client" 2>/dev/null || true
    done
    echo -e "\r  ${DIM}[${step}/${total_steps}]${NC} Suppression des utilisateurs ${DIM}...${NC} ${GREEN}✔${NC}"
    ((step++))
    
    # Étape 6: Supprimer l'image Docker
    print_step $step $total_steps "Suppression de l'image Docker" "wait"
    docker rmi laboboxvpn/rtorrent-rutorrent:latest >/dev/null 2>&1 || true
    echo -e "\r  ${DIM}[${step}/${total_steps}]${NC} Suppression de l'image Docker ${DIM}...${NC} ${GREEN}✔${NC}"
    ((step++))
    
    # Étape 7: Supprimer la configuration
    print_step $step $total_steps "Suppression de la configuration" "wait"
    for client in $clients; do
        rm -rf "$CLIENTS_DIR/$client" 2>/dev/null || true
    done
    rm -rf "$INSTALL_DIR/apps" 2>/dev/null || true
    rm -f /etc/logrotate.d/laboboxvpn 2>/dev/null || true
    # Service de démarrage auto (s'il avait été activé)
    systemctl disable --now labobox-seedbox.service >/dev/null 2>&1 || true
    rm -f "$SEEDBOX_SERVICE_FILE" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    echo -e "\r  ${DIM}[${step}/${total_steps}]${NC} Suppression de la configuration ${DIM}...${NC} ${GREEN}✔${NC}"
    
    print_success_box "DÉSINSTALLATION TERMINÉE"
    echo ""
    echo -e "  ${WHITE}Ce qui a été supprimé :${NC}"
    print_item "Dashboard" "Service arrêté et config supprimée"
    print_item "Conteneurs" "Tous arrêtés et supprimés"
    print_item "Montages" "Tous démontés"
    print_item "Utilisateurs" "Tous supprimés"
    print_item "Image Docker" "Supprimée"
    print_item_last "Config clients" "Supprimée"
    echo ""
    echo -e "  ${WHITE}Ce qui reste :${NC}"
    print_item "Script" "$INSTALL_DIR/laboboxvpn-manager.sh"
    print_item "Dockerfile" "$INSTALL_DIR/Dockerfile"
    print_item "Dashboard binaire" "$UTILS_DIR/labobox-dashboard"
    print_item_last "Données NAS" "Intactes (à supprimer manuellement via DSM)"
    
    print_footer
}

###########################################
# COMMANDE: HELP
###########################################
cmd_help() {
    print_header
    echo -e "  ${DIM}Gestionnaire multi-clients rtorrent/ruTorrent + WireGuard${NC}"
    double_line
    echo ""
    echo -e "  ${WHITE}UTILISATION${NC}"
    line
    echo ""
    echo "  ./laboboxvpn-manager.sh [commande] [options]"
    echo "  ./laboboxvpn-manager.sh              ← Mode interactif"
    echo ""
    echo -e "  ${WHITE}COMMANDES${NC}"
    line
    echo ""
    echo -e "  ${WHITE}init${NC}            Initialiser le système"
    echo -e "  ${WHITE}build${NC}           Construire l'image Docker"
    echo -e "  ${WHITE}add${NC}             Ajouter un client"
    echo -e "  ${WHITE}remove${NC}          Supprimer un client"
    echo -e "  ${WHITE}list${NC}            Lister les clients"
    echo -e "  ${WHITE}status${NC}          Status détaillé d'un client"
    echo -e "  ${WHITE}start${NC}           Démarrer un/tous les clients"
    echo -e "  ${WHITE}stop${NC}            Arrêter un/tous les clients"
    echo -e "  ${WHITE}restart${NC}         Redémarrer un/tous les clients"
    echo -e "  ${WHITE}logs${NC}            Afficher les logs"
    echo -e "  ${WHITE}quota${NC}           Utilisation disque"
    echo -e "  ${WHITE}passwd${NC}          Modifier un mot de passe"
    echo -e "  ${WHITE}mount${NC}           Monter les partages NAS"
    echo -e "  ${WHITE}health${NC}          Diagnostic complet"
    echo -e "  ${WHITE}check-ports${NC}     Vérifier le port forwarding [client]"
    echo -e "  ${WHITE}autostart-enable${NC}   Démarrage auto de la seedbox au boot"
    echo -e "  ${WHITE}autostart-disable${NC}  Désactiver le démarrage auto"
    echo ""
    echo -e "  ${WHITE}PERFORMANCE${NC}"
    line
    echo ""
    echo -e "  ${WHITE}optimize${NC}          Optimisation réseau & stockage NFS (profil auto)"
    echo -e "  ${WHITE}optimize-status${NC}   Voir les paramètres actifs"
    echo -e "  ${WHITE}optimize-restore${NC}  Restaurer les valeurs d'origine"
    echo -e "  ${WHITE}migrate-sessions${NC}  Ajouter le volume /local aux anciens clients"
    echo -e "  ${WHITE}temp-enable${NC}       Téléchargements sur disque SSD temporaire [client]"
    echo -e "  ${WHITE}temp-disable${NC}      Revenir aux téléchargements directs NAS [client]"
    echo -e "  ${WHITE}bench${NC}             Benchmark complet 4 voies (NFS/SSD × direct/VPN) <client>"
    echo -e "  ${WHITE}bench-nfs${NC}         Benchmark écriture/lecture NAS <client> [mo]"
    echo -e "  ${WHITE}bench-vpn${NC}         Benchmark débit du tunnel VPN <client>"
    echo ""
    echo -e "  ${WHITE}APPLICATIONS${NC}"
    line
    echo ""
    echo -e "  ${WHITE}install-dashboard${NC}    Installer le dashboard web"
    echo -e "  ${WHITE}uninstall-dashboard${NC}  Désinstaller le dashboard"
    echo -e "  ${WHITE}install-plex${NC}         Installer Plex"
    echo -e "  ${WHITE}install-jellyfin${NC}     Installer Jellyfin"
    echo -e "  ${WHITE}install-resilio${NC}      Installer Resilio Sync"
    echo -e "  ${WHITE}install-watchtower${NC}   Installer Watchtower"
    echo -e "  ${WHITE}config-network${NC}  Configurer IP VM, SSH, NAS"
    echo -e "  ${RED}uninstall${NC}       Désinstaller complètement"
    echo ""
    echo -e "  ${WHITE}CONFIGURATION ACTUELLE${NC}"
    line
    echo ""
    echo -e "  IP de la VM ............ ${SERVER_IP}"
    echo -e "  Port SSH ............... ${SSH_PORT}"
    echo -e "  IP NAS ................. ${NAS_IP}"
    echo -e "  Préfixe partages ....... ${NAS_SHARE_PREFIX}<USERNAME>"
    echo -e "  Répertoire montages .... ${NAS_MOUNT}"
    echo ""
    double_line
    echo -e "  ${DIM}https://github.com/CLusmi/laboboxvpn${NC}"
    double_line
    echo ""
}

###########################################
# APPLICATIONS COMMUNES
###########################################

# Chemins pour les apps communes
APPS_DIR="$INSTALL_DIR/apps"
JELLYFIN_PORT=32500
PLEX_PORT=32400
RESILIO_PORT=33000
RESILIO_SYNC_PORT=55555

is_jellyfin_installed() {
    [ -f "$APPS_DIR/jellyfin/docker-compose.yml" ]
}

is_plex_installed() {
    [ -f "$APPS_DIR/plex/docker-compose.yml" ]
}

is_resilio_installed() {
    [ -f "$APPS_DIR/resilio/docker-compose.yml" ]
}

is_watchtower_installed() {
    [ -f "$APPS_DIR/watchtower/docker-compose.yml" ]
}

is_jellyfin_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^jellyfin$"
}

is_plex_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^plex$"
}

is_resilio_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^resilio$"
}

is_watchtower_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^watchtower$"
}

cmd_install_jellyfin() {
    print_header_with_title "INSTALLATION JELLYFIN"
    
    if is_jellyfin_installed; then
        print_warning_box "Jellyfin est déjà installé"
        print_footer
        return 0
    fi
    
    print_step 1 3 "Création des dossiers"
    mkdir -p "$APPS_DIR/jellyfin/config"
    mkdir -p "$APPS_DIR/jellyfin/cache"
    print_step_item_last "Status" "${GREEN}✔ Créés${NC}"
    echo ""
    
    print_step 2 3 "Génération docker-compose.yml"
    
    # Collecter les chemins de données de tous les clients
    local volume_mounts=""
    for client in $(get_clients); do
        local data_path=$(get_client_data_path "$client")
        if [ -d "$data_path" ]; then
            volume_mounts="${volume_mounts}      - ${data_path}:/media/${client}:ro\n"
        fi
    done
    
    cat > "$APPS_DIR/jellyfin/docker-compose.yml" << EOF
###############################################
# JELLYFIN - Application commune
# Port: $JELLYFIN_PORT
# Créé le: $(date '+%Y-%m-%d %H:%M')
###############################################

services:
  jellyfin:
    image: linuxserver/jellyfin:latest
    container_name: jellyfin
    restart: no
    ports:
      - ${JELLYFIN_PORT}:8096
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Paris
    volumes:
      - ${APPS_DIR}/jellyfin/config:/config
      - ${APPS_DIR}/jellyfin/cache:/cache
$(echo -e "$volume_mounts")
EOF
    
    print_step_item "Port" "$JELLYFIN_PORT"
    print_step_item_last "Status" "${GREEN}✔ Généré${NC}"
    echo ""
    
    print_step 3 3 "Démarrage de Jellyfin"
    cd "$APPS_DIR/jellyfin"
    docker compose up -d >/dev/null 2>&1
    sleep 5
    
    if is_jellyfin_running; then
        print_step_item_last "Status" "${GREEN}✔ Démarré${NC}"
    else
        print_step_item_last "Status" "${RED}✗ Erreur${NC}"
    fi
    
    local SERVER_IP=$(get_server_ip)
    print_success_box "JELLYFIN INSTALLÉ"
    echo ""
    print_section "ACCÈS"
    print_item "URL" "http://${SERVER_IP}:${JELLYFIN_PORT}"
    print_item_last "Info" "Créez un compte admin lors de la 1ère connexion"
    echo ""
    print_section "BIBLIOTHÈQUES"
    print_item_last "Dossiers" "Un dossier par client dans /media/<client>"
    
    print_footer
}

cmd_uninstall_jellyfin() {
    print_header_with_title "DÉSINSTALLATION JELLYFIN"
    
    if ! is_jellyfin_installed; then
        print_warning_box "Jellyfin n'est pas installé"
        print_footer
        return 0
    fi
    
    echo ""
    echo -e "  ${YELLOW}⚠ Cette action va supprimer :${NC}"
    echo -e "    • Le conteneur Jellyfin"
    echo -e "    • La configuration (comptes, paramètres)"
    echo -e "    • Le cache"
    echo ""
    echo -e "  ${DIM}Les données des clients ne seront PAS supprimées.${NC}"
    echo ""
    
    if ! confirm "Confirmer la désinstallation ?"; then
        echo -e "  ${YELLOW}Annulé.${NC}"
        print_footer
        return 0
    fi
    
    print_step 1 2 "Arrêt et suppression du conteneur"
    cd "$APPS_DIR/jellyfin" 2>/dev/null
    docker compose down -v >/dev/null 2>&1
    docker rm -f jellyfin >/dev/null 2>&1
    print_step_item_last "Status" "${GREEN}✔ Conteneur supprimé${NC}"
    echo ""
    
    print_step 2 2 "Suppression des fichiers"
    rm -rf "$APPS_DIR/jellyfin"
    print_step_item_last "Status" "${GREEN}✔ Fichiers supprimés${NC}"
    
    print_success_box "JELLYFIN DÉSINSTALLÉ"
    print_footer
}

cmd_install_plex() {
    print_header_with_title "INSTALLATION PLEX"
    
    if is_plex_installed; then
        print_warning_box "Plex est déjà installé"
        print_footer
        return 0
    fi
    
    # Étape 1 : Récupération du Plex Claim Token
    echo ""
    echo -e "  ${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${CYAN}║               PLEX CLAIM TOKEN REQUIS                          ║${NC}"
    echo -e "  ${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Pour associer ce serveur Plex à votre compte, vous devez"
    echo -e "  obtenir un token de réclamation (Claim Token)."
    echo ""
    echo -e "  ${WHITE}Étapes :${NC}"
    echo -e "  ${CYAN}1.${NC} Ouvrez votre navigateur"
    echo -e "  ${CYAN}2.${NC} Allez sur ${GREEN}https://www.plex.tv/claim/${NC}"
    echo -e "  ${CYAN}3.${NC} Connectez-vous à votre compte Plex"
    echo -e "  ${CYAN}4.${NC} Copiez le token affiché (format: ${DIM}claim-xxxxxxxxxxxx${NC})"
    echo ""
    echo -e "  ${YELLOW}⚠ IMPORTANT : Le token expire après 4 minutes !${NC}"
    echo ""
    line
    echo ""
    
    local plex_claim=""
    while true; do
        echo -ne "  ${WHITE}Plex Claim Token :${NC} "
        read plex_claim
        
        if [ -z "$plex_claim" ]; then
            echo ""
            echo -e "  ${YELLOW}Token vide. Voulez-vous continuer sans token ?${NC}"
            if confirm "Continuer sans token ?"; then
                plex_claim=""
                break
            fi
            echo ""
            continue
        fi
        
        if [[ "$plex_claim" =~ ^claim-[a-zA-Z0-9_-]+$ ]]; then
            echo -e "  ${GREEN}✔ Token valide${NC}"
            break
        else
            echo -e "  ${RED}✗ Format invalide. Le token doit commencer par 'claim-'${NC}"
            echo ""
        fi
    done
    
    echo ""
    
    print_step 1 3 "Création des dossiers"
    mkdir -p "$APPS_DIR/plex/config"
    mkdir -p "$APPS_DIR/plex/transcode"
    print_step_item_last "Status" "${GREEN}✔ Créés${NC}"
    echo ""
    
    print_step 2 3 "Génération docker-compose.yml"
    
    local volume_mounts=""
    for client in $(get_clients); do
        local data_path=$(get_client_data_path "$client")
        if [ -d "$data_path" ]; then
            volume_mounts="${volume_mounts}      - ${data_path}:/media/${client}:ro\n"
        fi
    done
    
    cat > "$APPS_DIR/plex/docker-compose.yml" << EOF
###############################################
# PLEX - Application commune
# Port: $PLEX_PORT
# Créé le: $(date '+%Y-%m-%d %H:%M')
###############################################

services:
  plex:
    image: linuxserver/plex:latest
    container_name: plex
    restart: no
    network_mode: host
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Paris
      - VERSION=docker
      - PLEX_CLAIM=${plex_claim}
    volumes:
      - ${APPS_DIR}/plex/config:/config
      - ${APPS_DIR}/plex/transcode:/transcode
$(echo -e "$volume_mounts")
EOF
    
    print_step_item "Port" "$PLEX_PORT"
    if [ -n "$plex_claim" ]; then
        print_step_item "Claim Token" "Configuré"
    else
        print_step_item "Claim Token" "${YELLOW}Non configuré${NC}"
    fi
    print_step_item_last "Status" "${GREEN}✔ Généré${NC}"
    echo ""
    
    print_step 3 3 "Démarrage de Plex"
    cd "$APPS_DIR/plex"
    docker compose up -d >/dev/null 2>&1
    sleep 5
    
    if is_plex_running; then
        print_step_item_last "Status" "${GREEN}✔ Démarré${NC}"
    else
        print_step_item_last "Status" "${RED}✗ Erreur${NC}"
    fi
    
    local SERVER_IP=$(get_server_ip)
    print_success_box "PLEX INSTALLÉ"
    echo ""
    print_section "ACCÈS"
    print_item "URL" "http://${SERVER_IP}:${PLEX_PORT}/web"
    if [ -n "$plex_claim" ]; then
        print_item_last "Compte" "Associé automatiquement à votre compte Plex"
    else
        print_item_last "Info" "Connectez-vous pour associer le serveur"
    fi
    echo ""
    print_section "BIBLIOTHÈQUES"
    print_item_last "Dossiers" "Un dossier par client dans /media/<client>"
    
    print_footer
}

cmd_uninstall_plex() {
    print_header_with_title "DÉSINSTALLATION PLEX"
    
    if ! is_plex_installed; then
        print_warning_box "Plex n'est pas installé"
        print_footer
        return 0
    fi
    
    echo ""
    echo -e "  ${YELLOW}⚠ Cette action va supprimer :${NC}"
    echo -e "    • Le conteneur Plex"
    echo -e "    • La configuration (comptes, paramètres)"
    echo -e "    • Le cache de transcodage"
    echo ""
    
    if ! confirm "Confirmer la désinstallation ?"; then
        echo -e "  ${YELLOW}Annulé.${NC}"
        print_footer
        return 0
    fi
    
    print_step 1 2 "Arrêt et suppression du conteneur"
    cd "$APPS_DIR/plex" 2>/dev/null
    docker compose down -v >/dev/null 2>&1
    docker rm -f plex >/dev/null 2>&1
    print_step_item_last "Status" "${GREEN}✔ Conteneur supprimé${NC}"
    echo ""
    
    print_step 2 2 "Suppression des fichiers"
    rm -rf "$APPS_DIR/plex"
    print_step_item_last "Status" "${GREEN}✔ Fichiers supprimés${NC}"
    
    print_success_box "PLEX DÉSINSTALLÉ"
    print_footer
}

cmd_install_resilio() {
    print_header_with_title "INSTALLATION RESILIO SYNC"
    
    if is_resilio_installed; then
        print_warning_box "Resilio Sync est déjà installé"
        print_footer
        return 0
    fi
    
    print_step 1 3 "Création des dossiers"
    mkdir -p "$APPS_DIR/resilio/config"
    print_step_item_last "Status" "${GREEN}✔ Créés${NC}"
    echo ""
    
    print_step 2 3 "Génération docker-compose.yml"
    
    # Collecter les chemins - pas de :ro pour Resilio (lecture/écriture)
    local volume_mounts=""
    for client in $(get_clients); do
        local data_path=$(get_client_data_path "$client")
        if [ -d "$data_path" ]; then
            volume_mounts="${volume_mounts}      - ${data_path}:/sync/${client}\n"
        fi
    done
    
    cat > "$APPS_DIR/resilio/docker-compose.yml" << EOF
###############################################
# RESILIO SYNC - Application commune
# WebUI: $RESILIO_PORT | Sync: $RESILIO_SYNC_PORT
# Créé le: $(date '+%Y-%m-%d %H:%M')
###############################################

services:
  resilio:
    image: linuxserver/resilio-sync:latest
    container_name: resilio
    restart: no
    ports:
      - ${RESILIO_PORT}:8888
      - ${RESILIO_SYNC_PORT}:55555
      - ${RESILIO_SYNC_PORT}:55555/udp
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Paris
    volumes:
      - ${APPS_DIR}/resilio/config:/config
$(echo -e "$volume_mounts")
EOF
    
    print_step_item "Port WebUI" "$RESILIO_PORT"
    print_step_item "Port Sync" "$RESILIO_SYNC_PORT"
    print_step_item_last "Status" "${GREEN}✔ Généré${NC}"
    echo ""
    
    print_step 3 3 "Démarrage de Resilio Sync"
    cd "$APPS_DIR/resilio"
    docker compose up -d >/dev/null 2>&1
    sleep 5
    
    if is_resilio_running; then
        print_step_item_last "Status" "${GREEN}✔ Démarré${NC}"
    else
        print_step_item_last "Status" "${RED}✗ Erreur${NC}"
    fi
    
    local SERVER_IP=$(get_server_ip)
    print_success_box "RESILIO SYNC INSTALLÉ"
    echo ""
    print_section "ACCÈS"
    print_item "URL WebUI" "http://${SERVER_IP}:${RESILIO_PORT}"
    print_item_last "Info" "Configurez un compte lors de la 1ère connexion"
    echo ""
    print_section "SYNCHRONISATION"
    print_item "Port sync" "$RESILIO_SYNC_PORT (TCP+UDP)"
    print_item_last "Dossiers" "Un dossier par client dans /sync/<client>"
    
    print_footer
}

cmd_uninstall_resilio() {
    print_header_with_title "DÉSINSTALLATION RESILIO SYNC"
    
    if ! is_resilio_installed; then
        print_warning_box "Resilio Sync n'est pas installé"
        print_footer
        return 0
    fi
    
    echo ""
    echo -e "  ${YELLOW}⚠ Cette action va supprimer :${NC}"
    echo -e "    • Le conteneur Resilio Sync"
    echo -e "    • La configuration"
    echo ""
    
    if ! confirm "Confirmer la désinstallation ?"; then
        echo -e "  ${YELLOW}Annulé.${NC}"
        print_footer
        return 0
    fi
    
    print_step 1 2 "Arrêt et suppression du conteneur"
    cd "$APPS_DIR/resilio" 2>/dev/null
    docker compose down -v >/dev/null 2>&1
    docker rm -f resilio >/dev/null 2>&1
    print_step_item_last "Status" "${GREEN}✔ Conteneur supprimé${NC}"
    echo ""
    
    print_step 2 2 "Suppression des fichiers"
    rm -rf "$APPS_DIR/resilio"
    print_step_item_last "Status" "${GREEN}✔ Fichiers supprimés${NC}"
    
    print_success_box "RESILIO SYNC DÉSINSTALLÉ"
    print_footer
}

cmd_install_watchtower() {
    print_header_with_title "INSTALLATION WATCHTOWER"
    
    if is_watchtower_installed; then
        print_warning_box "Watchtower est déjà installé"
        print_footer
        return 0
    fi
    
    print_step 1 2 "Génération docker-compose.yml"
    mkdir -p "$APPS_DIR/watchtower"
    
    cat > "$APPS_DIR/watchtower/docker-compose.yml" << EOF
###############################################
# WATCHTOWER - Mise à jour automatique
# Créé le: $(date '+%Y-%m-%d %H:%M')
###############################################

services:
  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    environment:
      - TZ=Europe/Paris
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_POLL_INTERVAL=86400
      - WATCHTOWER_INCLUDE_STOPPED=false
      - DOCKER_API_VERSION=1.44
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
EOF
    
    print_step_item "Intervalle" "Toutes les 24 heures"
    print_step_item "Cleanup" "Anciennes images supprimées"
    print_step_item_last "Status" "${GREEN}✔ Généré${NC}"
    echo ""
    
    print_step 2 2 "Démarrage de Watchtower"
    cd "$APPS_DIR/watchtower"
    docker compose up -d >/dev/null 2>&1
    sleep 3
    
    if is_watchtower_running; then
        print_step_item_last "Status" "${GREEN}✔ Démarré${NC}"
    else
        print_step_item_last "Status" "${RED}✗ Erreur${NC}"
    fi
    
    print_success_box "WATCHTOWER INSTALLÉ"
    echo ""
    print_section "FONCTIONNEMENT"
    print_item "Vérification" "Toutes les 24 heures"
    print_item "Scope" "Tous les conteneurs"
    print_item_last "Nettoyage" "Anciennes images supprimées automatiquement"
    
    print_footer
}

cmd_uninstall_watchtower() {
    print_header_with_title "DÉSINSTALLATION WATCHTOWER"
    
    if ! is_watchtower_installed; then
        print_warning_box "Watchtower n'est pas installé"
        print_footer
        return 0
    fi
    
    if ! confirm "Confirmer la désinstallation ?"; then
        echo -e "  ${YELLOW}Annulé.${NC}"
        print_footer
        return 0
    fi
    
    print_step 1 2 "Arrêt et suppression du conteneur"
    cd "$APPS_DIR/watchtower" 2>/dev/null
    docker compose down -v >/dev/null 2>&1
    docker rm -f watchtower >/dev/null 2>&1
    print_step_item_last "Status" "${GREEN}✔ Conteneur supprimé${NC}"
    echo ""
    
    print_step 2 2 "Suppression des fichiers"
    rm -rf "$APPS_DIR/watchtower"
    print_step_item_last "Status" "${GREEN}✔ Fichiers supprimés${NC}"
    
    print_success_box "WATCHTOWER DÉSINSTALLÉ"
    print_footer
}

cmd_update_media_libs() {
    local app=$1
    
    print_header_with_title "MISE À JOUR BIBLIOTHÈQUES ${app^^}"
    
    local app_dir="$APPS_DIR/$app"
    local compose_file="$app_dir/docker-compose.yml"
    
    if [ ! -f "$compose_file" ]; then
        print_error_box "${app^} n'est pas installé"
        print_footer
        return 1
    fi
    
    print_step 1 2 "Collecte des clients"
    
    local volume_mounts=""
    local count=0
    for client in $(get_clients); do
        local data_path=$(get_client_data_path "$client")
        if [ -d "$data_path" ]; then
            case "$app" in
                jellyfin|plex)
                    volume_mounts="${volume_mounts}      - ${data_path}:/media/${client}:ro\n"
                    ;;
                resilio)
                    volume_mounts="${volume_mounts}      - ${data_path}:/sync/${client}\n"
                    ;;
            esac
            print_step_item "$client" "$data_path"
            ((count++))
        fi
    done
    
    if [ $count -eq 0 ]; then
        print_step_item_last "Status" "${YELLOW}Aucun client trouvé${NC}"
        print_footer
        return 0
    fi
    
    print_step_item_last "Total" "${count} clients"
    echo ""
    
    print_step 2 2 "Mise à jour docker-compose.yml"
    
    # Régénérer le docker-compose selon l'app
    case "$app" in
        jellyfin)
            cat > "$compose_file" << EOF
###############################################
# JELLYFIN - Application commune
# Port: $JELLYFIN_PORT
# Mis à jour: $(date '+%Y-%m-%d %H:%M')
###############################################

services:
  jellyfin:
    image: linuxserver/jellyfin:latest
    container_name: jellyfin
    restart: no
    ports:
      - ${JELLYFIN_PORT}:8096
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Paris
    volumes:
      - ${app_dir}/config:/config
      - ${app_dir}/cache:/cache
$(echo -e "$volume_mounts")
EOF
            ;;
        plex)
            local plex_claim=$(grep "PLEX_CLAIM=" "$compose_file" 2>/dev/null | cut -d'=' -f2 || echo "")
            cat > "$compose_file" << EOF
###############################################
# PLEX - Application commune
# Port: $PLEX_PORT
# Mis à jour: $(date '+%Y-%m-%d %H:%M')
###############################################

services:
  plex:
    image: linuxserver/plex:latest
    container_name: plex
    restart: no
    network_mode: host
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Paris
      - VERSION=docker
      - PLEX_CLAIM=${plex_claim}
    volumes:
      - ${app_dir}/config:/config
      - ${app_dir}/transcode:/transcode
$(echo -e "$volume_mounts")
EOF
            ;;
        resilio)
            cat > "$compose_file" << EOF
###############################################
# RESILIO SYNC - Application commune
# WebUI: $RESILIO_PORT | Sync: $RESILIO_SYNC_PORT
# Mis à jour: $(date '+%Y-%m-%d %H:%M')
###############################################

services:
  resilio:
    image: linuxserver/resilio-sync:latest
    container_name: resilio
    restart: no
    ports:
      - ${RESILIO_PORT}:8888
      - ${RESILIO_SYNC_PORT}:55555
      - ${RESILIO_SYNC_PORT}:55555/udp
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Paris
    volumes:
      - ${app_dir}/config:/config
$(echo -e "$volume_mounts")
EOF
            ;;
    esac
    
    print_step_item_last "Status" "${GREEN}✔ Mis à jour${NC}"
    echo ""
    
    # Redémarrer le conteneur
    cd "$app_dir"
    docker compose down >/dev/null 2>&1
    docker compose up -d >/dev/null 2>&1
    
    print_success_box "Bibliothèques mises à jour - ${app^} redémarré"
    print_footer
}

# Version silencieuse pour appel automatique
cmd_update_media_libs_silent() {
    local app=$1
    
    local app_dir="$APPS_DIR/$app"
    local compose_file="$app_dir/docker-compose.yml"
    
    [ ! -f "$compose_file" ] && return 1
    
    local volume_mounts=""
    for client in $(get_clients); do
        local data_path=$(get_client_data_path "$client")
        if [ -d "$data_path" ]; then
            case "$app" in
                jellyfin|plex)
                    volume_mounts="${volume_mounts}      - ${data_path}:/media/${client}:ro\n"
                    ;;
                resilio)
                    volume_mounts="${volume_mounts}      - ${data_path}:/sync/${client}\n"
                    ;;
            esac
        fi
    done
    
    case "$app" in
        jellyfin)
            cat > "$compose_file" << EOF
###############################################
# JELLYFIN - Application commune
# Port: $JELLYFIN_PORT
# Mis à jour: $(date '+%Y-%m-%d %H:%M')
###############################################

services:
  jellyfin:
    image: linuxserver/jellyfin:latest
    container_name: jellyfin
    restart: no
    ports:
      - ${JELLYFIN_PORT}:8096
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Paris
    volumes:
      - ${app_dir}/config:/config
      - ${app_dir}/cache:/cache
$(echo -e "$volume_mounts")
EOF
            ;;
        plex)
            local plex_claim=$(grep "PLEX_CLAIM=" "$compose_file" 2>/dev/null | cut -d'=' -f2 || echo "")
            cat > "$compose_file" << EOF
###############################################
# PLEX - Application commune
# Port: $PLEX_PORT
# Mis à jour: $(date '+%Y-%m-%d %H:%M')
###############################################

services:
  plex:
    image: linuxserver/plex:latest
    container_name: plex
    restart: no
    network_mode: host
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Paris
      - VERSION=docker
      - PLEX_CLAIM=${plex_claim}
    volumes:
      - ${app_dir}/config:/config
      - ${app_dir}/transcode:/transcode
$(echo -e "$volume_mounts")
EOF
            ;;
        resilio)
            cat > "$compose_file" << EOF
###############################################
# RESILIO SYNC - Application commune
# WebUI: $RESILIO_PORT | Sync: $RESILIO_SYNC_PORT
# Mis à jour: $(date '+%Y-%m-%d %H:%M')
###############################################

services:
  resilio:
    image: linuxserver/resilio-sync:latest
    container_name: resilio
    restart: no
    ports:
      - ${RESILIO_PORT}:8888
      - ${RESILIO_SYNC_PORT}:55555
      - ${RESILIO_SYNC_PORT}:55555/udp
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Paris
    volumes:
      - ${app_dir}/config:/config
$(echo -e "$volume_mounts")
EOF
            ;;
    esac
    
    cd "$app_dir"
    docker compose down >/dev/null 2>&1
    docker compose up -d >/dev/null 2>&1
}

cmd_apps_status() {
    print_header_with_title "STATUS APPLICATIONS COMMUNES"
    
    local SERVER_IP=$(get_server_ip)
    
    # Jellyfin
    print_section "JELLYFIN"
    if is_jellyfin_installed; then
        if is_jellyfin_running; then
            local uptime=$(get_container_uptime "jellyfin")
            print_item "Status" "${GREEN}✔ Actif${NC} ${DIM}(uptime: ${uptime})${NC}"
        else
            print_item "Status" "${RED}✗ Arrêté${NC}"
        fi
        print_item "URL" "http://${SERVER_IP}:${JELLYFIN_PORT}"
        print_item_last "Config" "${APPS_DIR}/jellyfin/"
    else
        print_item_last "Status" "${DIM}Non installé${NC}"
    fi
    echo ""
    
    # Plex
    print_section "PLEX"
    if is_plex_installed; then
        if is_plex_running; then
            local uptime=$(get_container_uptime "plex")
            print_item "Status" "${GREEN}✔ Actif${NC} ${DIM}(uptime: ${uptime})${NC}"
        else
            print_item "Status" "${RED}✗ Arrêté${NC}"
        fi
        print_item "URL" "http://${SERVER_IP}:${PLEX_PORT}/web"
        print_item_last "Config" "${APPS_DIR}/plex/"
    else
        print_item_last "Status" "${DIM}Non installé${NC}"
    fi
    echo ""
    
    # Resilio
    print_section "RESILIO SYNC"
    if is_resilio_installed; then
        if is_resilio_running; then
            local uptime=$(get_container_uptime "resilio")
            print_item "Status" "${GREEN}✔ Actif${NC} ${DIM}(uptime: ${uptime})${NC}"
        else
            print_item "Status" "${RED}✗ Arrêté${NC}"
        fi
        print_item "URL" "http://${SERVER_IP}:${RESILIO_PORT}"
        print_item_last "Config" "${APPS_DIR}/resilio/"
    else
        print_item_last "Status" "${DIM}Non installé${NC}"
    fi
    echo ""
    
    # Watchtower
    print_section "WATCHTOWER"
    if is_watchtower_installed; then
        if is_watchtower_running; then
            local uptime=$(get_container_uptime "watchtower")
            print_item "Status" "${GREEN}✔ Actif${NC} ${DIM}(uptime: ${uptime})${NC}"
        else
            print_item "Status" "${RED}✗ Arrêté${NC}"
        fi
        print_item_last "Schedule" "Tous les jours à 4h"
    else
        print_item_last "Status" "${DIM}Non installé${NC}"
    fi
    
    print_footer
}

cmd_configure_hw_transcoding() {
    local app=$1
    
    print_header_with_title "CONFIGURATION HARDWARE TRANSCODING - ${app^^}"
    
    local app_dir="$APPS_DIR/$app"
    local compose_file="$app_dir/docker-compose.yml"
    
    if [ ! -f "$compose_file" ]; then
        print_error_box "${app^} n'est pas installé"
        print_footer
        return 1
    fi
    
    echo ""
    echo -e "  ${WHITE}Le hardware transcoding permet d'utiliser le GPU pour${NC}"
    echo -e "  ${WHITE}décoder/encoder les vidéos, réduisant la charge CPU.${NC}"
    echo ""
    
    # Vérifier si /dev/dri existe
    if [ ! -d "/dev/dri" ]; then
        print_error_box "/dev/dri non trouvé - Pas de GPU disponible"
        echo ""
        echo -e "  ${DIM}Vérifiez que votre VM/serveur a un GPU avec les drivers installés.${NC}"
        print_footer
        return 1
    fi
    
    print_section "GPU DÉTECTÉ"
    ls -la /dev/dri/ 2>/dev/null | while read line; do
        echo -e "  ${DIM}$line${NC}"
    done
    echo ""
    
    # Vérifier si déjà configuré
    if grep -q "/dev/dri" "$compose_file" 2>/dev/null; then
        echo -e "  ${GREEN}✔ Hardware transcoding déjà activé${NC}"
        echo ""
        if confirm "Voulez-vous le désactiver ?"; then
            sed -i '/devices:/,/\/dev\/dri/d' "$compose_file"
            cd "$app_dir"
            docker compose down >/dev/null 2>&1
            docker compose up -d >/dev/null 2>&1
            print_success_box "Hardware transcoding désactivé"
        fi
    else
        echo -e "  ${YELLOW}⚠ Hardware transcoding non activé${NC}"
        echo ""
        if confirm "Voulez-vous l'activer ?"; then
            # Ajouter la section devices avant volumes
            sed -i '/volumes:/i\    devices:\n      - /dev/dri:/dev/dri' "$compose_file"
            cd "$app_dir"
            docker compose down >/dev/null 2>&1
            docker compose up -d >/dev/null 2>&1
            print_success_box "Hardware transcoding activé"
            echo ""
            echo -e "  ${DIM}N'oubliez pas de configurer ${app^} pour utiliser le transcodage matériel${NC}"
            echo -e "  ${DIM}dans les paramètres de l'application.${NC}"
        fi
    fi
    
    print_footer
}

###########################################
# MODE INTERACTIF
###########################################

interactive_main_menu() {
    # Vérifier si c'est le premier lancement
    if is_first_run; then
        print_menu_header
        echo ""
        echo -e "  ${YELLOW}╔═══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "  ${YELLOW}║              PREMIÈRE CONFIGURATION REQUISE                  ║${NC}"
        echo -e "  ${YELLOW}╚═══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${WHITE}Bienvenue dans LaboBox-VPN Manager !${NC}"
        echo ""
        echo -e "  Avant de pouvoir utiliser le système, vous devez :"
        echo ""
        echo -e "  ${CYAN}1.${NC} Configurer le réseau (IP VM, Port SSH, IP NAS)"
        echo -e "  ${CYAN}2.${NC} Initialiser le système (Docker, NFS)"
        echo -e "  ${CYAN}3.${NC} Construire l'image Docker"
        echo ""
        echo -e "  ${DIM}Vous allez être redirigé vers le menu Maintenance...${NC}"
        echo ""
        press_enter
        interactive_maintenance_menu
    fi
    
    while true; do
        print_menu_header
        
        # Vérifier le statut du système
        local network_status="${RED}✗${NC}"
        local init_status="${RED}✗${NC}"
        local build_status="${RED}✗${NC}"
        local network_label="Non configuré"
        local init_label="Non initialisé"
        local build_label="Non buildée"
        local system_ready="no"
        
        if is_network_configured; then
            network_status="${GREEN}✔${NC}"
            network_label="OK"
        fi
        
        if is_system_initialized; then
            init_status="${GREEN}✔${NC}"
            init_label="OK"
        fi
        
        if is_image_built; then
            build_status="${GREEN}✔${NC}"
            build_label="OK"
        fi
        
        if is_network_configured && is_system_initialized && is_image_built; then
            system_ready="yes"
        fi
        
        # Afficher le statut système
        echo -e "  ${WHITE}STATUT SYSTÈME${NC}"
        line
        echo -e "  ${network_status}  Configuration réseau .... ${network_label}"
        echo -e "  ${init_status}  Initialisation .......... ${init_label}"
        echo -e "  ${build_status}  Image Docker ............ ${build_label}"
        echo ""
        
        # Si système non prêt, afficher un avertissement
        if [ "$system_ready" = "no" ]; then
            echo -e "  ${YELLOW}⚠ Configuration requise avant utilisation${NC}"
            echo ""
        fi
        
        echo -e "  ${WHITE}MENU PRINCIPAL${NC}"
        line
        echo ""
        print_menu_option "1" "-" "Gestion des clients"
        print_menu_option "2" "-" "Applications communes"
        print_menu_option "3" "-" "Monitoring"
        print_menu_option "4" "-" "Maintenance"
        print_menu_option "5" "-" "Aide"
        print_menu_separator
        print_menu_option "0" "-" "Quitter"
        
        read_choice "Votre choix" ""
        
        case $MENU_CHOICE in
            1) 
                if [ "$system_ready" = "no" ]; then
                    echo ""
                    echo -e "  ${YELLOW}⚠ Le système n'est pas prêt.${NC}"
                    echo -e "  ${DIM}Allez dans Maintenance pour configurer.${NC}"
                    press_enter
                else
                    interactive_clients_menu
                fi
                ;;
            2)
                if [ "$system_ready" = "no" ]; then
                    echo ""
                    echo -e "  ${YELLOW}⚠ Le système n'est pas prêt.${NC}"
                    press_enter
                else
                    interactive_apps_menu
                fi
                ;;
            3) interactive_monitoring_menu ;;
            4) interactive_maintenance_menu ;;
            5) cmd_help; press_enter ;;
            0|q|Q) echo ""; echo -e "  ${DIM}À bientôt !${NC}"; echo ""; exit 0 ;;
            *) ;;
        esac
    done
}

###########################################
# MENU MONITORING
###########################################

interactive_monitoring_menu() {
    local system_ready="yes"
    [ ! -f "$CONFIG_FILE" ] && system_ready="no"
    
    while true; do
        print_menu_header
        
        echo -e "  ${WHITE}MONITORING${NC}"
        line
        echo ""
        print_menu_option "1" "-" "Vue d'ensemble"
        print_menu_option "2" "-" "Diagnostic système"
        print_menu_option "3" "-" "Utilisation disque"
        print_menu_option "4" "-" "Vérifier le port forwarding (tous les clients)"
        print_menu_option "5" "-" "Benchmarks (NFS / VPN)"
        print_menu_separator
        print_menu_option "0" "-" "Retour"

        read_choice "Votre choix" ""

        case $MENU_CHOICE in
            1)
                if [ "$system_ready" = "no" ]; then
                    echo ""
                    echo -e "  ${YELLOW}⚠ Le système n'est pas prêt.${NC}"
                    press_enter
                else
                    cmd_list
                    press_enter
                fi
                ;;
            2) cmd_health; press_enter ;;
            3)
                if [ "$system_ready" = "no" ]; then
                    echo ""
                    echo -e "  ${YELLOW}⚠ Le système n'est pas prêt.${NC}"
                    press_enter
                else
                    cmd_quota
                    press_enter
                fi
                ;;
            4) cmd_check_ports; press_enter ;;
            5) interactive_bench_menu ;;
            0|q|Q) return ;;
            *) ;;
        esac
    done
}

interactive_bench_menu() {
    while true; do
        print_menu_header

        echo -e "  ${WHITE}BENCHMARKS${NC}"
        line
        echo ""
        echo -e "  ${DIM}Mesures réelles pour valider les réglages. Le « complet » couvre les${NC}"
        echo -e "  ${DIM}4 voies : disque NAS et disque SSD en direct, puis téléchargement à${NC}"
        echo -e "  ${DIM}travers le tunnel VPN écrit sur le NAS puis sur le SSD.${NC}"
        echo ""

        print_menu_option "1" "-" "Benchmark complet 4 voies (NFS/SSD × direct/VPN)"
        print_menu_option "2" "-" "Écriture / lecture NFS seule (partage d'un client)"
        print_menu_option "3" "-" "Débit VPN seul (vs direct, vers /dev/null)"
        print_menu_separator
        print_menu_option "0" "-" "Retour"

        read_choice "Votre choix" ""

        local clients bench_client bench_size
        case $MENU_CHOICE in
            1)
                clients=$(get_clients)
                if [ -z "$clients" ]; then
                    echo -e "  ${DIM}Aucun client configuré.${NC}"; press_enter; continue
                fi
                echo ""
                echo -e "  ${DIM}Clients : $(echo $clients | tr '\n' ' ')${NC}"
                echo ""
                echo -ne "  Nom du client : "
                read bench_client
                [ -z "$bench_client" ] && continue
                cmd_bench_all "$bench_client"
                press_enter
                ;;
            2)
                clients=$(get_clients)
                if [ -z "$clients" ]; then
                    echo -e "  ${DIM}Aucun client configuré.${NC}"; press_enter; continue
                fi
                echo ""
                echo -e "  ${DIM}Clients : $(echo $clients | tr '\n' ' ')${NC}"
                echo ""
                echo -ne "  Nom du client : "
                read bench_client
                [ -z "$bench_client" ] && continue
                echo -ne "  Taille du test en Mo [512] : "
                read bench_size
                cmd_bench_nfs "$bench_client" "${bench_size:-512}"
                press_enter
                ;;
            3)
                clients=$(get_clients)
                if [ -z "$clients" ]; then
                    echo -e "  ${DIM}Aucun client configuré.${NC}"; press_enter; continue
                fi
                echo ""
                echo -e "  ${DIM}Clients : $(echo $clients | tr '\n' ' ')${NC}"
                echo ""
                echo -ne "  Nom du client : "
                read bench_client
                [ -z "$bench_client" ] && continue
                cmd_bench_vpn "$bench_client"
                press_enter
                ;;
            0|q|Q) return ;;
            *) ;;
        esac
    done
}

###########################################
# DASHBOARD WEB
###########################################

DASHBOARD_DIR="${UTILS_DIR}/dashboard"
DASHBOARD_GITHUB_SRC="https://github.com/CLusmi/Labobox-VPN-Manager/releases/latest/download/dashboard-src.tar.gz"

is_dashboard_installed() {
    # Installé = config.json existe ET service systemd existe
    [ -f "${DASHBOARD_DIR}/config.json" ] && [ -f "/etc/systemd/system/labobox-dashboard.service" ]
}

is_dashboard_binary_present() {
    [ -f "${DASHBOARD_DIR}/labobox-dashboard" ]
}

is_dashboard_sources_present() {
    [ -f "${DASHBOARD_DIR}/main.go" ] && [ -f "${DASHBOARD_DIR}/go.mod" ]
}

is_dashboard_running() {
    systemctl is-active --quiet labobox-dashboard 2>/dev/null
}

is_go_installed() {
    command -v go &> /dev/null
}

install_go() {
    echo -e "  ${CYAN}Installation de Go...${NC}"
    
    local GO_VERSION="1.21.5"
    local GO_ARCH="amd64"
    local GO_URL="https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
    
    # Télécharger Go
    echo -ne "       Téléchargement de Go ${GO_VERSION}..."
    if curl -fsSL -o /tmp/go.tar.gz "$GO_URL" 2>/dev/null; then
        echo -e " ${GREEN}OK${NC}"
    else
        echo -e " ${RED}ÉCHEC${NC}"
        return 1
    fi
    
    # Installer Go
    echo -ne "       Installation..."
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz 2>/dev/null
    rm -f /tmp/go.tar.gz
    
    # Ajouter au PATH si pas déjà fait
    if ! grep -q "/usr/local/go/bin" /etc/profile.d/go.sh 2>/dev/null; then
        echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
        chmod +x /etc/profile.d/go.sh
    fi
    export PATH=$PATH:/usr/local/go/bin
    
    if is_go_installed; then
        echo -e " ${GREEN}OK${NC}"
        echo -e "       Version : $(go version | cut -d' ' -f3)"
        return 0
    else
        echo -e " ${RED}ÉCHEC${NC}"
        return 1
    fi
}

status_dashboard() {
    if ! is_dashboard_installed; then
        if is_dashboard_sources_present; then
            echo -e "${YELLOW}Sources présentes (non configuré)${NC}"
        elif is_dashboard_binary_present; then
            echo -e "${YELLOW}Binaire présent (non configuré)${NC}"
        else
            echo -e "${DIM}Non installé${NC}"
        fi
        return
    fi
    
    if is_dashboard_running; then
        echo -e "${GREEN}● Actif${NC}"
    else
        echo -e "${RED}○ Arrêté${NC}"
    fi
}

cmd_install_dashboard() {
    print_header_with_title "INSTALLATION DU DASHBOARD WEB v3.0"
    echo ""

    # Vérifier si déjà configuré
    if is_dashboard_installed; then
        print_warning "Le dashboard est déjà installé et configuré."
        echo ""
        if ! confirm "Voulez-vous le reconfigurer ?"; then
            return 0
        fi
        is_dashboard_running && systemctl stop labobox-dashboard
    fi

    local total_steps=5
    local step=1

    # Étape 1: Vérifier Go
    print_step $step $total_steps "Vérification de Go"
    export PATH=$PATH:/usr/local/go/bin
    if is_go_installed; then
        print_success "Go installé ($(go version | cut -d' ' -f3))"
    else
        print_warning "Go n'est pas installé"
        echo ""
        if confirm "Installer Go automatiquement ?"; then
            if ! install_go; then
                print_error "Impossible d'installer Go"
                print_footer
                return 1
            fi
        else
            print_error "Go est requis pour compiler le dashboard"
            echo -e "  ${DIM}Installez Go manuellement : https://go.dev/dl/${NC}"
            print_footer
            return 1
        fi
    fi
    ((step++))

    # Étape 2: Vérifier/télécharger les sources
    print_step $step $total_steps "Vérification des sources"
    mkdir -p "${DASHBOARD_DIR}"
    
    if is_dashboard_sources_present; then
        print_success "Sources déjà présentes"
    else
        echo -ne "       Téléchargement des sources..."
        if curl -fsSL -o /tmp/dashboard-src.tar.gz "${DASHBOARD_GITHUB_SRC}" 2>/dev/null; then
            tar -xzf /tmp/dashboard-src.tar.gz -C "${DASHBOARD_DIR}" --strip-components=1 2>/dev/null
            rm -f /tmp/dashboard-src.tar.gz
            if is_dashboard_sources_present; then
                echo -e " ${GREEN}OK${NC}"
            else
                echo -e " ${RED}ÉCHEC${NC}"
                print_error "Les sources n'ont pas été extraites correctement"
                print_footer
                return 1
            fi
        else
            echo -e " ${RED}ÉCHEC${NC}"
            print_error "Impossible de télécharger les sources"
            echo -e "  ${DIM}Téléchargez manuellement dans ${DASHBOARD_DIR}/${NC}"
            print_footer
            return 1
        fi
    fi
    ((step++))

    # Étape 3: Configuration
    print_step $step $total_steps "Configuration"
    echo ""
    echo -e "  ${WHITE}Configuration du dashboard :${NC}"
    echo ""

    # Port
    read_input "Port d'écoute" "8888"
    local DASHBOARD_PORT="$MENU_CHOICE"

    if ss -tuln 2>/dev/null | grep -q ":${DASHBOARD_PORT} "; then
        print_warning "Le port ${DASHBOARD_PORT} semble déjà utilisé"
    fi

    # Admin user
    echo ""
    echo -e "  ${DIM}L'admin utilise les identifiants de sa seedbox.${NC}"
    echo -e "  ${DIM}Les autres clients pourront aussi se connecter avec leurs identifiants.${NC}"
    echo ""
    read_input "Utilisateur admin (doit être un client existant)" "clusmi"
    local ADMIN_USER="$MENU_CHOICE"

    # Vérifier que le client existe
    if [ ! -f "${CLIENTS_DIR}/${ADMIN_USER}/info.txt" ]; then
        print_warning "Le client '${ADMIN_USER}' n'existe pas encore."
        echo -e "  ${DIM}Créez ce client avant d'utiliser le dashboard, ou choisissez un autre admin.${NC}"
    fi

    # Configuration domaine et SFTP
    echo ""
    echo -e "  ${WHITE}Configuration domaine et accès :${NC}"
    echo -e "  ${DIM}(Utilisé pour les liens ruTorrent et les infos SFTP)${NC}"
    echo ""
    
    read_input "Domaine principal" "inseedious.ovh"
    local DOMAIN="$MENU_CHOICE"
    
    read_input "Port SFTP" "22"
    local SFTP_PORT="$MENU_CHOICE"

    # Options débits live
    echo ""
    echo -e "  ${WHITE}Options débits en temps réel :${NC}"
    echo -e "  ${DIM}(Affiche download/upload sur le dashboard - admin seulement)${NC}"
    echo ""
    
    read_input "Activer les débits live ? (oui/non)" "oui"
    local LIVE_ENABLED="true"
    if [ "$MENU_CHOICE" == "non" ] || [ "$MENU_CHOICE" == "n" ]; then
        LIVE_ENABLED="false"
    fi
    
    local LIVE_INTERVAL="500"
    if [ "$LIVE_ENABLED" == "true" ]; then
        echo -e "  ${DIM}(100ms = très réactif, 1000ms = moins de charge CPU)${NC}"
        read_input "Intervalle rafraîchissement (ms)" "500"
        LIVE_INTERVAL="$MENU_CHOICE"
        if [ "$LIVE_INTERVAL" -lt 100 ] 2>/dev/null; then
            LIVE_INTERVAL="100"
            print_warning "Intervalle minimum : 100ms"
        fi
    fi

    # Créer config.json
    cat > "${DASHBOARD_DIR}/config.json" << EOF
{
    "port": "${DASHBOARD_PORT}",
    "admin_user": "${ADMIN_USER}",
    "domain": "${DOMAIN}",
    "sftp_port": "${SFTP_PORT}",
    "live_enabled": ${LIVE_ENABLED},
    "live_interval": ${LIVE_INTERVAL}
}
EOF
    chmod 600 "${DASHBOARD_DIR}/config.json"
    print_success "Configuration créée"
    ((step++))

    # Étape 4: Compilation
    print_step $step $total_steps "Compilation du dashboard"
    echo -ne "       go build..."
    cd "${DASHBOARD_DIR}"
    if go build -o labobox-dashboard . 2>/dev/null; then
        chmod +x "${DASHBOARD_DIR}/labobox-dashboard"
        echo -e " ${GREEN}OK${NC}"
    else
        echo -e " ${RED}ÉCHEC${NC}"
        print_error "La compilation a échoué"
        echo -e "  ${DIM}Vérifiez les sources dans ${DASHBOARD_DIR}/${NC}"
        print_footer
        return 1
    fi
    ((step++))

    # Étape 5: Service systemd
    print_step $step $total_steps "Création du service systemd"
    cat > /etc/systemd/system/labobox-dashboard.service << EOF
[Unit]
Description=LaboBox Dashboard
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
User=root
WorkingDirectory=${DASHBOARD_DIR}
ExecStart=${DASHBOARD_DIR}/labobox-dashboard
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable labobox-dashboard --quiet
    systemctl start labobox-dashboard
    print_success "Service créé et démarré"

    sleep 2
    if is_dashboard_running; then
        local IP=$(hostname -I | awk '{print $1}')
        echo ""
        print_success_box "Dashboard installé avec succès !"
        echo ""
        echo -e "  ${WHITE}Accès :${NC}"
        print_item "URL" "${CYAN}http://${IP}:${DASHBOARD_PORT}${NC}"
        print_item "Admin" "${ADMIN_USER} (vue complète)"
        print_item "Clients" "login seedbox (vue limitée)"
        if [ "$LIVE_ENABLED" == "true" ]; then
            print_item "Débits live" "Activés (${LIVE_INTERVAL}ms)"
        else
            print_item "Débits live" "Désactivés"
        fi
        print_item_last "Sources" "${DASHBOARD_DIR}/"
        echo ""
        echo -e "  ${DIM}Chaque client peut se connecter avec ses identifiants ruTorrent.${NC}"
        echo -e "  ${DIM}Seul ${ADMIN_USER} a accès à la vue admin complète.${NC}"
        echo ""
        echo -e "  ${DIM}Pour modifier le dashboard :${NC}"
        echo -e "  ${DIM}  cd ${DASHBOARD_DIR}${NC}"
        echo -e "  ${DIM}  nano templates/index.html  # ou main.go${NC}"
        echo -e "  ${DIM}  go build -o labobox-dashboard .${NC}"
        echo -e "  ${DIM}  systemctl restart labobox-dashboard${NC}"
    else
        print_error "Le dashboard n'a pas démarré"
        echo -e "  ${DIM}Vérifiez les logs : journalctl -u labobox-dashboard -f${NC}"
    fi

    print_footer
}

cmd_uninstall_dashboard() {
    print_header_with_title "DÉSINSTALLATION DU DASHBOARD"
    echo ""

    if ! is_dashboard_installed; then
        print_warning_box "Le dashboard n'est pas installé"
        return 0
    fi

    echo -e "  Cette action va supprimer :"
    echo -e "    • Le fichier config.json"
    echo -e "    • Le binaire compilé"
    echo -e "    • Le service systemd"
    echo ""
    echo -e "  ${DIM}Les sources (main.go, templates/) seront conservées.${NC}"
    echo ""

    if ! confirm "Confirmer la désinstallation ?"; then
        print_warning "Annulé"
        return 0
    fi

    echo ""

    if is_dashboard_running; then
        print_step 1 3 "Arrêt du service"
        systemctl stop labobox-dashboard
        print_success "Service arrêté"
    fi

    print_step 2 3 "Suppression du service"
    systemctl disable labobox-dashboard --quiet 2>/dev/null
    rm -f /etc/systemd/system/labobox-dashboard.service
    systemctl daemon-reload
    print_success "Service supprimé"

    print_step 3 3 "Suppression de la configuration"
    rm -f "${DASHBOARD_DIR}/config.json"
    rm -f "${DASHBOARD_DIR}/labobox-dashboard"
    print_success "Configuration et binaire supprimés"

    echo ""
    print_success_box "Dashboard désinstallé"
    echo ""
    echo -e "  ${DIM}Les sources sont conservées dans ${DASHBOARD_DIR}/${NC}"
    print_footer
}

interactive_dashboard_menu() {
    while true; do
        print_menu_header
        
        local dashboard_status=$(status_dashboard)
        
        echo -e "  ${WHITE}DASHBOARD WEB${NC}"
        line
        echo -e "  Status : ${dashboard_status}"
        
        if is_dashboard_installed && [ -f "${DASHBOARD_DIR}/config.json" ]; then
            local PORT=$(grep -oP '"port"\s*:\s*"\K[^"]+' "${DASHBOARD_DIR}/config.json" 2>/dev/null)
            local ADMIN=$(grep -oP '"admin_user"\s*:\s*"\K[^"]+' "${DASHBOARD_DIR}/config.json" 2>/dev/null)
            local LIVE_ON=$(grep -oP '"live_enabled"\s*:\s*\K[^,}]+' "${DASHBOARD_DIR}/config.json" 2>/dev/null)
            local LIVE_INT=$(grep -oP '"live_interval"\s*:\s*\K[0-9]+' "${DASHBOARD_DIR}/config.json" 2>/dev/null)
            local IP=$(hostname -I | awk '{print $1}')
            echo -e "  URL    : ${CYAN}http://${IP}:${PORT}${NC}"
            echo -e "  Admin  : ${ADMIN}"
            if [ "$LIVE_ON" == "true" ]; then
                echo -e "  Débits : ${GREEN}Activés${NC} (${LIVE_INT}ms)"
            else
                echo -e "  Débits : ${DIM}Désactivés${NC}"
            fi
        fi
        if is_dashboard_sources_present; then
            echo -e "  Sources: ${DASHBOARD_DIR}/"
        fi
        echo ""
        
        if is_dashboard_installed; then
            # Dashboard installé et configuré
            print_menu_option "1" "-" "Arrêter le dashboard"
            print_menu_option "2" "-" "Démarrer le dashboard"
            print_menu_option "3" "-" "Recompiler (après modif sources)"
            print_menu_option "4" "-" "Voir les logs"
            print_menu_option "5" "-" "Reconfigurer"
            print_menu_option "6" "-" "Désinstaller"
        else
            # Pas installé ou sources présentes mais pas configuré
            if is_dashboard_sources_present; then
                print_menu_option "1" "-" "Configurer et compiler"
            else
                print_menu_option "1" "-" "Installer le dashboard"
            fi
        fi
        print_menu_separator
        print_menu_option "0" "-" "Retour"
        
        read_choice "Votre choix" ""
        
        if is_dashboard_installed; then
            case $MENU_CHOICE in
                1)
                    systemctl stop labobox-dashboard
                    print_success "Dashboard arrêté"
                    sleep 2
                    ;;
                2)
                    systemctl start labobox-dashboard
                    print_success "Dashboard démarré"
                    sleep 2
                    ;;
                3)
                    # Recompiler
                    echo ""
                    echo -e "  ${CYAN}Recompilation du dashboard...${NC}"
                    export PATH=$PATH:/usr/local/go/bin
                    cd "${DASHBOARD_DIR}"
                    if go build -o labobox-dashboard . 2>&1; then
                        print_success "Compilation réussie"
                        systemctl restart labobox-dashboard
                        print_success "Dashboard redémarré"
                    else
                        print_error "Échec de la compilation"
                    fi
                    press_enter
                    ;;
                4)
                    echo ""
                    echo -e "  ${WHITE}Logs du dashboard :${NC}"
                    line
                    journalctl -u labobox-dashboard -n 50 --no-pager
                    press_enter
                    ;;
                5) cmd_install_dashboard; press_enter ;;
                6) cmd_uninstall_dashboard; press_enter ;;
                0|q|Q) return ;;
                *) ;;
            esac
        else
            case $MENU_CHOICE in
                1) cmd_install_dashboard; press_enter ;;
                0|q|Q) return ;;
                *) ;;
            esac
        fi
    done
}

###########################################
# MENU APPLICATIONS COMMUNES
###########################################

interactive_apps_menu() {
    while true; do
        print_menu_header
        
        # Vérifier les statuts
        local jellyfin_status="${DIM}Non installé${NC}"
        local plex_status="${DIM}Non installé${NC}"
        local resilio_status="${DIM}Non installé${NC}"
        local watchtower_status="${DIM}Non installé${NC}"
        local dashboard_status=$(status_dashboard)
        
        if is_jellyfin_installed; then
            if is_jellyfin_running; then
                jellyfin_status="${GREEN}● Actif${NC}"
            else
                jellyfin_status="${RED}○ Arrêté${NC}"
            fi
        fi
        
        if is_plex_installed; then
            if is_plex_running; then
                plex_status="${GREEN}● Actif${NC}"
            else
                plex_status="${RED}○ Arrêté${NC}"
            fi
        fi
        
        if is_resilio_installed; then
            if is_resilio_running; then
                resilio_status="${GREEN}● Actif${NC}"
            else
                resilio_status="${RED}○ Arrêté${NC}"
            fi
        fi
        
        if is_watchtower_installed; then
            if is_watchtower_running; then
                watchtower_status="${GREEN}● Actif${NC}"
            else
                watchtower_status="${RED}○ Arrêté${NC}"
            fi
        fi
        
        echo -e "  ${WHITE}APPLICATIONS COMMUNES${NC}"
        line
        echo -e "  Plex: ${plex_status}  │  Jellyfin: ${jellyfin_status}"
        echo -e "  Resilio: ${resilio_status}  │  Watchtower: ${watchtower_status}"
        echo -e "  Dashboard: ${dashboard_status}"
        echo ""
        
        print_menu_option "1" "-" "Plex"
        print_menu_option "2" "-" "Jellyfin"
        print_menu_option "3" "-" "Resilio Sync"
        print_menu_option "4" "-" "Watchtower"
        print_menu_option "5" "-" "Dashboard Web"
        print_menu_separator
        print_menu_option "6" "-" "Status des applications"
        print_menu_option "7" "-" "Démarrer/Arrêter une application"
        print_menu_separator
        print_menu_option "0" "-" "Retour"
        
        read_choice "Votre choix" ""
        
        case $MENU_CHOICE in
            1) interactive_plex_menu ;;
            2) interactive_jellyfin_menu ;;
            3) interactive_resilio_menu ;;
            4) interactive_watchtower_menu ;;
            5) interactive_dashboard_menu ;;
            6) cmd_apps_status; press_enter ;;
            7) interactive_app_control ;;
            0|q|Q) return ;;
            *) ;;
        esac
    done
}

interactive_plex_menu() {
    while true; do
        print_menu_header
        
        local plex_status="${DIM}Non installé${NC}"
        if is_plex_installed; then
            if is_plex_running; then
                plex_status="${GREEN}● Actif${NC}"
            else
                plex_status="${RED}○ Arrêté${NC}"
            fi
        fi
        
        echo -e "  ${WHITE}PLEX${NC}"
        line
        echo -e "  ${DIM}Status : ${plex_status}${NC}"
        echo ""
        
        print_menu_option "1" "-" "Installer Plex"
        print_menu_option "2" "-" "Désinstaller Plex"
        print_menu_option "3" "-" "Synchroniser les bibliothèques"
        print_menu_option "4" "-" "Configurer hardware transcoding"
        print_menu_separator
        print_menu_option "0" "-" "Retour"
        
        read_choice "Votre choix" ""
        
        case $MENU_CHOICE in
            1) cmd_install_plex; press_enter ;;
            2) cmd_uninstall_plex; press_enter ;;
            3) 
                if is_plex_installed; then
                    cmd_update_media_libs "plex"
                else
                    echo -e "  ${RED}Plex n'est pas installé${NC}"
                fi
                press_enter
                ;;
            4)
                if is_plex_installed; then
                    cmd_configure_hw_transcoding "plex"
                else
                    echo -e "  ${RED}Plex n'est pas installé${NC}"
                fi
                press_enter
                ;;
            0|q|Q) return ;;
            *) ;;
        esac
    done
}

interactive_jellyfin_menu() {
    while true; do
        print_menu_header
        
        local jellyfin_status="${DIM}Non installé${NC}"
        if is_jellyfin_installed; then
            if is_jellyfin_running; then
                jellyfin_status="${GREEN}● Actif${NC}"
            else
                jellyfin_status="${RED}○ Arrêté${NC}"
            fi
        fi
        
        echo -e "  ${WHITE}JELLYFIN${NC}"
        line
        echo -e "  ${DIM}Status : ${jellyfin_status}${NC}"
        echo ""
        
        print_menu_option "1" "-" "Installer Jellyfin"
        print_menu_option "2" "-" "Désinstaller Jellyfin"
        print_menu_option "3" "-" "Synchroniser les bibliothèques"
        print_menu_option "4" "-" "Configurer hardware transcoding"
        print_menu_separator
        print_menu_option "0" "-" "Retour"
        
        read_choice "Votre choix" ""
        
        case $MENU_CHOICE in
            1) cmd_install_jellyfin; press_enter ;;
            2) cmd_uninstall_jellyfin; press_enter ;;
            3) 
                if is_jellyfin_installed; then
                    cmd_update_media_libs "jellyfin"
                else
                    echo -e "  ${RED}Jellyfin n'est pas installé${NC}"
                fi
                press_enter
                ;;
            4)
                if is_jellyfin_installed; then
                    cmd_configure_hw_transcoding "jellyfin"
                else
                    echo -e "  ${RED}Jellyfin n'est pas installé${NC}"
                fi
                press_enter
                ;;
            0|q|Q) return ;;
            *) ;;
        esac
    done
}

interactive_resilio_menu() {
    while true; do
        print_menu_header
        
        local resilio_status="${DIM}Non installé${NC}"
        if is_resilio_installed; then
            if is_resilio_running; then
                resilio_status="${GREEN}● Actif${NC}"
            else
                resilio_status="${RED}○ Arrêté${NC}"
            fi
        fi
        
        echo -e "  ${WHITE}RESILIO SYNC${NC}"
        line
        echo -e "  ${DIM}Status : ${resilio_status}${NC}"
        echo ""
        
        print_menu_option "1" "-" "Installer Resilio Sync"
        print_menu_option "2" "-" "Désinstaller Resilio Sync"
        print_menu_option "3" "-" "Synchroniser les dossiers clients"
        print_menu_separator
        print_menu_option "0" "-" "Retour"
        
        read_choice "Votre choix" ""
        
        case $MENU_CHOICE in
            1) cmd_install_resilio; press_enter ;;
            2) cmd_uninstall_resilio; press_enter ;;
            3) 
                if is_resilio_installed; then
                    cmd_update_media_libs "resilio"
                else
                    echo -e "  ${RED}Resilio Sync n'est pas installé${NC}"
                fi
                press_enter
                ;;
            0|q|Q) return ;;
            *) ;;
        esac
    done
}

interactive_watchtower_menu() {
    while true; do
        print_menu_header
        
        local watchtower_status="${DIM}Non installé${NC}"
        if is_watchtower_installed; then
            if is_watchtower_running; then
                watchtower_status="${GREEN}● Actif${NC}"
            else
                watchtower_status="${RED}○ Arrêté${NC}"
            fi
        fi
        
        echo -e "  ${WHITE}WATCHTOWER${NC}"
        line
        echo -e "  ${DIM}Status : ${watchtower_status}${NC}"
        echo -e "  ${DIM}Mise à jour automatique des conteneurs à 4h du matin${NC}"
        echo ""
        
        print_menu_option "1" "-" "Installer Watchtower"
        print_menu_option "2" "-" "Désinstaller Watchtower"
        print_menu_separator
        print_menu_option "0" "-" "Retour"
        
        read_choice "Votre choix" ""
        
        case $MENU_CHOICE in
            1) cmd_install_watchtower; press_enter ;;
            2) cmd_uninstall_watchtower; press_enter ;;
            0|q|Q) return ;;
            *) ;;
        esac
    done
}

interactive_app_control() {
    while true; do
        print_menu_header
        
        echo -e "  ${WHITE}DÉMARRER / ARRÊTER${NC}"
        line
        echo ""
        
        local apps_found=0
        
        if is_plex_installed; then
            ((apps_found++))
            if is_plex_running; then
                print_menu_option "1" "-" "Arrêter Plex"
            else
                print_menu_option "1" "-" "Démarrer Plex"
            fi
        else
            echo -e "   ${DIM}1  -  Plex non installé${NC}"
        fi
        
        if is_jellyfin_installed; then
            ((apps_found++))
            if is_jellyfin_running; then
                print_menu_option "2" "-" "Arrêter Jellyfin"
            else
                print_menu_option "2" "-" "Démarrer Jellyfin"
            fi
        else
            echo -e "   ${DIM}2  -  Jellyfin non installé${NC}"
        fi
        
        if is_resilio_installed; then
            ((apps_found++))
            if is_resilio_running; then
                print_menu_option "3" "-" "Arrêter Resilio Sync"
            else
                print_menu_option "3" "-" "Démarrer Resilio Sync"
            fi
        else
            echo -e "   ${DIM}3  -  Resilio Sync non installé${NC}"
        fi
        
        if is_watchtower_installed; then
            ((apps_found++))
            if is_watchtower_running; then
                print_menu_option "4" "-" "Arrêter Watchtower"
            else
                print_menu_option "4" "-" "Démarrer Watchtower"
            fi
        else
            echo -e "   ${DIM}4  -  Watchtower non installé${NC}"
        fi
        
        print_menu_separator
        print_menu_option "0" "-" "Retour"
        
        read_choice "Votre choix" ""
        
        case $MENU_CHOICE in
            1)
                if is_plex_installed; then
                    cd "$APPS_DIR/plex"
                    if is_plex_running; then
                        docker compose down >/dev/null 2>&1
                        echo -e "  ${GREEN}✔ Plex arrêté${NC}"
                    else
                        docker compose up -d >/dev/null 2>&1
                        echo -e "  ${GREEN}✔ Plex démarré${NC}"
                    fi
                    sleep 1
                fi
                ;;
            2)
                if is_jellyfin_installed; then
                    cd "$APPS_DIR/jellyfin"
                    if is_jellyfin_running; then
                        docker compose down >/dev/null 2>&1
                        echo -e "  ${GREEN}✔ Jellyfin arrêté${NC}"
                    else
                        docker compose up -d >/dev/null 2>&1
                        echo -e "  ${GREEN}✔ Jellyfin démarré${NC}"
                    fi
                    sleep 1
                fi
                ;;
            3)
                if is_resilio_installed; then
                    cd "$APPS_DIR/resilio"
                    if is_resilio_running; then
                        docker compose down >/dev/null 2>&1
                        echo -e "  ${GREEN}✔ Resilio Sync arrêté${NC}"
                    else
                        docker compose up -d >/dev/null 2>&1
                        echo -e "  ${GREEN}✔ Resilio Sync démarré${NC}"
                    fi
                    sleep 1
                fi
                ;;
            4)
                if is_watchtower_installed; then
                    cd "$APPS_DIR/watchtower"
                    if is_watchtower_running; then
                        docker compose down >/dev/null 2>&1
                        echo -e "  ${GREEN}✔ Watchtower arrêté${NC}"
                    else
                        docker compose up -d >/dev/null 2>&1
                        echo -e "  ${GREEN}✔ Watchtower démarré${NC}"
                    fi
                    sleep 1
                fi
                ;;
            0|q|Q) return ;;
            *) ;;
        esac
    done
}

###########################################
# MENU CLIENTS
###########################################

interactive_clients_menu() {
    while true; do
        print_menu_header
        
        # Afficher les clients existants
        local clients_list=$(get_clients | tr '\n' ', ' | sed 's/,$//')
        
        echo -e "  ${WHITE}GESTION DES CLIENTS${NC}"
        line
        if [ -n "$clients_list" ]; then
            echo -e "  ${DIM}Clients : ${clients_list}${NC}"
        else
            echo -e "  ${DIM}Aucun client configuré${NC}"
        fi
        echo ""
        print_menu_option "1" "-" "Ajouter un client"
        print_menu_option "2" "-" "Supprimer un client"
        print_menu_option "3" "-" "Status d'un client"
        print_menu_option "4" "-" "Démarrer un client"
        print_menu_option "5" "-" "Arrêter un client"
        print_menu_option "6" "-" "Redémarrer un client"
        print_menu_option "7" "-" "Modifier un mot de passe"
        print_menu_option "8" "-" "Voir les logs"
        print_menu_separator
        print_menu_option "0" "-" "Retour"
        
        read_choice "Votre choix" ""
        
        case $MENU_CHOICE in
            1) interactive_add_client ;;
            2) interactive_remove_client ;;
            3) interactive_status_client ;;
            4) interactive_start_client ;;
            5) interactive_stop_client ;;
            6) interactive_restart_client ;;
            7) interactive_passwd_client ;;
            8) interactive_logs_client ;;
            0|q|Q) return ;;
            *) ;;
        esac
    done
}

interactive_add_client() {
    print_menu_header
    
    echo -e "  ${WHITE}NOUVEAU CLIENT${NC}"
    line
    echo ""
    
    # Nom du client
    echo -ne "  Nom du client : "
    read client_name
    
    if [ -z "$client_name" ]; then
        echo -e "  ${RED}Nom requis.${NC}"
        press_enter
        return
    fi
    
    if client_exists "$client_name"; then
        echo -e "  ${RED}Ce client existe déjà.${NC}"
        press_enter
        return
    fi
    
    # Mot de passe
    echo -ne "  Mot de passe : "
    read -s client_pass
    echo ""
    
    if [ -z "$client_pass" ]; then
        echo -e "  ${RED}Mot de passe requis.${NC}"
        press_enter
        return
    fi
    
    # Ports et UID (AVANT le fichier VPN)
    local port_webui=$(get_next_port webui)
    local port_rt=$(get_next_port rt)
    local user_uid=$(get_suggested_uid)
    
    echo ""
    echo -e "  ${WHITE}Ports suggérés :${NC}"
    line
    echo -e "  Port WebUI ruTorrent : ${port_webui}"
    echo -e "  Port rtorrent VPN    : ${port_rt}"
    echo -e "  UID/GID              : ${user_uid}"
    echo ""
    
    echo -e "  Port WebUI [${port_webui}] : \c"
    read custom_webui
    [ -n "$custom_webui" ] && port_webui=$custom_webui
    
    echo -e "  Port rtorrent [${port_rt}] : \c"
    read custom_rt
    [ -n "$custom_rt" ] && port_rt=$custom_rt
    
    echo -e "  UID/GID [${user_uid}] : \c"
    read custom_uid
    [ -n "$custom_uid" ] && user_uid=$custom_uid

    # Disque SSD temporaire (si configuré) : le choix par client
    local use_temp="no"
    if [ -n "$TEMP_DIR" ]; then
        use_temp="yes"
        echo ""
        echo -e "  ${DIM}Disque SSD temporaire configuré : téléchargements sur ${TEMP_DIR},${NC}"
        echo -e "  ${DIM}déplacés vers le NAS à la complétion.${NC}"
        echo -ne "  L'utiliser pour ce client ? (oui/non) [oui] : "
        read temp_choice
        if [ "$temp_choice" = "non" ] || [ "$temp_choice" = "n" ]; then
            use_temp="no"
        fi
    fi

    # Fichier VPN (EN DERNIER - pour choisir selon le port)
    echo ""
    echo -e "  ${DIM}Astuce: le fichier VPN correspond souvent au port rtorrent (ex: ${port_rt}.conf)${NC}"
    echo -ne "  Fichier VPN (.conf) : "
    read vpn_config
    
    if [ ! -f "$vpn_config" ]; then
        echo -e "  ${RED}Fichier introuvable: ${vpn_config}${NC}"
        press_enter
        return
    fi
    
    # Résumé
    echo ""
    line
    echo -e "  ${WHITE}Résumé :${NC}"
    echo -e "  ├─ Client ............. ${client_name}"
    echo -e "  ├─ Partage NAS ........ $(get_nas_share_name $client_name)"
    echo -e "  ├─ Port WebUI ......... ${port_webui}"
    echo -e "  ├─ Port rtorrent ...... ${port_rt}"
    echo -e "  ├─ UID/GID ............ ${user_uid}"
    echo -e "  └─ Disque SSD temp. ... $([ "$use_temp" = "yes" ] && echo "oui (${TEMP_DIR}/${client_name})" || echo "non")"
    echo ""
    
    if confirm "Créer ce client ?"; then
        echo ""
        cmd_add "$client_name" "$client_pass" "$vpn_config" "$port_webui" "$port_rt" "$user_uid" "$use_temp"
    else
        echo -e "  ${YELLOW}Annulé.${NC}"
    fi
    
    press_enter
}

interactive_remove_client() {
    print_menu_header
    
    echo -e "  ${WHITE}SUPPRIMER UN CLIENT${NC}"
    line
    echo ""
    
    local clients=$(get_clients)
    if [ -z "$clients" ]; then
        echo -e "  ${DIM}Aucun client à supprimer.${NC}"
        press_enter
        return
    fi
    
    echo -e "  ${DIM}Clients disponibles : $(echo $clients | tr '\n' ' ')${NC}"
    echo ""
    echo -ne "  Nom du client à supprimer : "
    read client_name
    
    if [ -z "$client_name" ]; then
        return
    fi
    
    cmd_remove "$client_name"
    press_enter
}

interactive_status_client() {
    print_menu_header
    
    local clients=$(get_clients)
    if [ -z "$clients" ]; then
        echo -e "  ${DIM}Aucun client configuré.${NC}"
        press_enter
        return
    fi
    
    echo -e "  ${DIM}Clients : $(echo $clients | tr '\n' ' ')${NC}"
    echo ""
    echo -ne "  Nom du client : "
    read client_name
    
    if [ -n "$client_name" ]; then
        cmd_status "$client_name"
    fi
    
    press_enter
}

interactive_start_client() {
    print_menu_header
    
    local clients=$(get_clients)
    if [ -z "$clients" ]; then
        echo -e "  ${DIM}Aucun client configuré.${NC}"
        press_enter
        return
    fi
    
    echo -e "  ${DIM}Clients : $(echo $clients | tr '\n' ' ')${NC}"
    echo -e "  ${DIM}(laisser vide pour démarrer tous)${NC}"
    echo ""
    echo -ne "  Nom du client : "
    read client_name
    
    cmd_start "$client_name"
    press_enter
}

interactive_stop_client() {
    print_menu_header
    
    local clients=$(get_clients)
    if [ -z "$clients" ]; then
        echo -e "  ${DIM}Aucun client configuré.${NC}"
        press_enter
        return
    fi
    
    echo -e "  ${DIM}Clients : $(echo $clients | tr '\n' ' ')${NC}"
    echo -e "  ${DIM}(laisser vide pour arrêter tous)${NC}"
    echo ""
    echo -ne "  Nom du client : "
    read client_name
    
    cmd_stop "$client_name"
    press_enter
}

interactive_restart_client() {
    print_menu_header
    
    local clients=$(get_clients)
    if [ -z "$clients" ]; then
        echo -e "  ${DIM}Aucun client configuré.${NC}"
        press_enter
        return
    fi
    
    echo -e "  ${DIM}Clients : $(echo $clients | tr '\n' ' ')${NC}"
    echo -e "  ${DIM}(laisser vide pour redémarrer tous)${NC}"
    echo ""
    echo -ne "  Nom du client : "
    read client_name
    
    cmd_restart "$client_name"
    press_enter
}

interactive_passwd_client() {
    print_menu_header
    
    local clients=$(get_clients)
    if [ -z "$clients" ]; then
        echo -e "  ${DIM}Aucun client configuré.${NC}"
        press_enter
        return
    fi
    
    echo -e "  ${DIM}Clients : $(echo $clients | tr '\n' ' ')${NC}"
    echo ""
    echo -ne "  Nom du client : "
    read client_name
    
    if [ -z "$client_name" ]; then
        return
    fi
    
    if ! client_exists "$client_name"; then
        echo -e "  ${RED}Client inexistant.${NC}"
        press_enter
        return
    fi
    
    echo -ne "  Nouveau mot de passe : "
    read -s new_pass
    echo ""
    
    if [ -z "$new_pass" ]; then
        echo -e "  ${RED}Mot de passe requis.${NC}"
        press_enter
        return
    fi
    
    cmd_passwd "$client_name" "$new_pass"
    press_enter
}

interactive_logs_client() {
    print_menu_header
    
    local clients=$(get_clients)
    if [ -z "$clients" ]; then
        echo -e "  ${DIM}Aucun client configuré.${NC}"
        press_enter
        return
    fi
    
    echo -e "  ${DIM}Clients : $(echo $clients | tr '\n' ' ')${NC}"
    echo ""
    echo -ne "  Nom du client : "
    read client_name
    
    if [ -z "$client_name" ]; then
        return
    fi
    
    if ! client_exists "$client_name"; then
        echo -e "  ${RED}Client inexistant.${NC}"
        press_enter
        return
    fi
    
    echo ""
    echo -e "  ${DIM}1. rtorrent (défaut)${NC}"
    echo -e "  ${DIM}2. gluetun (VPN)${NC}"
    echo ""
    echo -ne "  Service [1]: "
    read service_choice
    
    local service="rtorrent"
    [ "$service_choice" == "2" ] && service="gluetun"
    
    echo ""
    echo -e "  ${DIM}Appuyez sur Ctrl+C pour quitter les logs${NC}"
    sleep 2
    
    cmd_logs "$client_name" "$service"
}

###########################################
# MENU MAINTENANCE
###########################################

interactive_maintenance_menu() {
    while true; do
        print_menu_header
        
        # Vérifier les statuts
        local network_status="${RED}✗${NC}"
        local init_status="${RED}✗${NC}"
        local build_status="${RED}✗${NC}"
        local network_done="no"
        local init_done="no"
        local build_done="no"
        
        if is_network_configured; then
            network_status="${GREEN}✔${NC}"
            network_done="yes"
        fi
        
        if is_system_initialized; then
            init_status="${GREEN}✔${NC}"
            init_done="yes"
        fi
        
        if is_image_built; then
            build_status="${GREEN}✔${NC}"
            build_done="yes"
        fi
        
        echo -e "  ${WHITE}MAINTENANCE${NC}"
        line
        echo ""
        
        echo -e "  ${CYAN}Configuration initiale :${NC}"
        echo ""
        
        # 1. Configuration réseau
        if [ "$network_done" = "yes" ]; then
            printf "   ${WHITE}1${NC}   ${network_status}   Configurer le réseau ${DIM}(VM: ${SERVER_IP}, NAS: ${NAS_IP})${NC}\n"
        else
            printf "   ${WHITE}1${NC}   ${network_status}   Configurer le réseau ${YELLOW}← À faire en premier${NC}\n"
        fi

        # 2. Init
        if [ "$init_done" = "yes" ]; then
            printf "   ${WHITE}2${NC}   ${init_status}   Initialiser le système ${DIM}(fait)${NC}\n"
        elif [ "$network_done" = "yes" ]; then
            printf "   ${WHITE}2${NC}   ${init_status}   Initialiser le système ${YELLOW}← À faire${NC}\n"
        else
            printf "   ${WHITE}2${NC}   ${init_status}   Initialiser le système ${DIM}(après réseau)${NC}\n"
        fi

        # 3. Build
        if [ "$build_done" = "yes" ]; then
            printf "   ${WHITE}3${NC}   ${build_status}   Construire l'image Docker ${DIM}(fait)${NC}\n"
        elif [ "$init_done" = "yes" ]; then
            printf "   ${WHITE}3${NC}   ${build_status}   Construire l'image Docker ${YELLOW}← À faire${NC}\n"
        else
            printf "   ${WHITE}3${NC}   ${build_status}   Construire l'image Docker ${DIM}(après init)${NC}\n"
        fi

        echo ""
        echo -e "  ${CYAN}Opérations :${NC}"
        print_menu_separator
        print_menu_option "4" "-" "Redémarrer tous les clients"
        print_menu_option "5" "-" "Arrêter tous les clients"
        print_menu_option "6" "-" "Démarrer tous les clients"
        print_menu_separator
        print_menu_option "7" "-" "Démarrage complet séquentiel"
        print_menu_option "8" "-" "Arrêt complet séquentiel"
        print_menu_separator
        local autostart_label="Activer le démarrage auto au boot"
        is_autostart_enabled && autostart_label="Désactiver le démarrage auto au boot ${GREEN}(actif)${NC}"

        print_menu_option "9" "-" "Monter tous les partages NAS"
        print_menu_option "10" "-" "Optimisation réseau & stockage NFS"
        print_menu_option "11" "-" "Activer / Désactiver le disque SSD temporaire"
        print_menu_option "12" "-" "$(echo -e "$autostart_label")"
        print_menu_separator
        print_menu_option "13" "-" "Désinstaller tout"
        print_menu_separator
        print_menu_option "0" "-" "Retour"

        read_choice "Votre choix" ""

        case $MENU_CHOICE in
            1) cmd_config_network; press_enter ;;
            2)
                if [ "$network_done" = "no" ]; then
                    echo ""
                    echo -e "  ${YELLOW}⚠ Veuillez d'abord configurer le réseau (option 1)${NC}"
                    press_enter
                else
                    cmd_init
                    press_enter
                fi
                ;;
            3)
                if [ "$init_done" = "no" ]; then
                    echo ""
                    echo -e "  ${YELLOW}⚠ Veuillez d'abord initialiser le système (option 2)${NC}"
                    press_enter
                else
                    cmd_build
                    press_enter
                fi
                ;;
            4) cmd_restart; press_enter ;;
            5) cmd_stop; press_enter ;;
            6) cmd_start; press_enter ;;
            7) cmd_sequential_start; press_enter ;;
            8) cmd_sequential_stop; press_enter ;;
            9) cmd_mount; press_enter ;;
            10) interactive_network_optimize_menu ;;
            11) interactive_temp_toggle ;;
            12)
                if is_autostart_enabled; then
                    cmd_autostart_disable
                else
                    cmd_autostart_enable
                fi
                press_enter
                ;;
            13) cmd_uninstall; press_enter ;;
            0|q|Q) return ;;
            *) ;;
        esac
    done
}

interactive_network_optimize_menu() {
    while true; do
        print_menu_header

        echo -e "  ${WHITE}OPTIMISATION RÉSEAU & STOCKAGE NFS${NC}"
        line
        echo ""
        echo -e "  ${DIM}Analyse le matériel (CPU, RAM, carte réseau) et applique le profil${NC}"
        echo -e "  ${DIM}adapté : BBR, buffers dimensionnés, conntrack, tuning de la carte${NC}"
        echo -e "  ${DIM}rejoué au boot, et writeback NFS en flux continu (plus de rafales${NC}"
        echo -e "  ${DIM}d'écriture qui saturent le NAS et gèlent rtorrent).${NC}"
        echo ""

        # Vérifier si déjà optimisé
        local optimize_status="${DIM}Non appliquée${NC}"
        if [ -f "/etc/sysctl.d/99-labobox-network.conf" ]; then
            optimize_status="${GREEN}✔ Active${NC}"
        elif [ -f "/etc/sysctl.d/99-labobox-ultimate.conf" ] || [ -f "/etc/sysctl.d/99-labobox-storage.conf" ]; then
            optimize_status="${YELLOW}⚠ Ancienne version — relancer l'application${NC}"
        fi

        echo -e "  Optimisation : ${optimize_status}"
        echo ""

        print_menu_option "1" "-" "Appliquer l'optimisation"
        print_menu_option "2" "-" "Voir le statut actuel"
        print_menu_option "3" "-" "Restaurer les paramètres d'origine"
        print_menu_separator
        print_menu_option "0" "-" "Retour"

        read_choice "Votre choix" ""

        case $MENU_CHOICE in
            1) cmd_optimize; press_enter ;;
            2) cmd_optimize --status; press_enter ;;
            3) cmd_optimize --restore; press_enter ;;
            0|q|Q) return ;;
            *) ;;
        esac
    done
}

###########################################
# MAIN
###########################################

check_root

# Charger la config au démarrage
load_config

# Si pas d'arguments, mode interactif
if [ $# -eq 0 ]; then
    interactive_main_menu
    exit 0
fi

# Mode ligne de commande
case "${1}" in
    init)
        cmd_init
        ;;
    build)
        cmd_build
        ;;
    add)
        shift
        parse_args "$@"
        
        if [ -z "$ARG_USER" ] || [ -z "$ARG_PASSWORD" ] || [ -z "$ARG_VPN_CONFIG" ]; then
            print_header
            echo -e "  ${WHITE}UTILISATION${NC}"
            line
            echo ""
            echo "  ./laboboxvpn-manager.sh add \\"
            echo "      --USER=<nom> \\"
            echo "      --PASSWORD=<pass> \\"
            echo "      --VPN_CONFIG=<fichier.conf> \\"
            echo "      [--PORT_RUTORRENT_WEBUI=<port>] \\"
            echo "      [--PORT_RTORRENT_VPN=<port>] \\"
            echo "      [--UID=<uid>] \\"
            echo "      [--TEMP=yes|no]   (disque SSD temporaire, défaut: yes si configuré)"
            print_footer
            exit 1
        fi
        
        if client_exists "$ARG_USER"; then
            print_error_box "Le client '${ARG_USER}' existe déjà."
            exit 1
        fi
        
        if [ ! -f "$ARG_VPN_CONFIG" ]; then
            print_error_box "Fichier VPN introuvable: ${ARG_VPN_CONFIG}"
            exit 1
        fi
        
        PORT_WEBUI="${ARG_PORT_WEBUI:-$(get_next_port webui)}"
        PORT_RT="${ARG_PORT_RT:-$(get_next_port rt)}"
        USER_UID="${ARG_UID:-}"

        cmd_add "$ARG_USER" "$ARG_PASSWORD" "$ARG_VPN_CONFIG" "$PORT_WEBUI" "$PORT_RT" "$USER_UID" "$ARG_TEMP"
        ;;
    remove)
        shift
        parse_args "$@"
        CLIENT="${ARG_USER:-${OTHER_ARGS[0]}}"
        
        if [ -z "$CLIENT" ]; then
            print_error_box "Client requis: --USER=<nom>"
            exit 1
        fi
        
        cmd_remove "$CLIENT"
        ;;
    list)
        cmd_list
        ;;
    status)
        shift
        parse_args "$@"
        CLIENT="${ARG_USER:-${OTHER_ARGS[0]}}"
        
        if [ -z "$CLIENT" ]; then
            cmd_list
        else
            cmd_status "$CLIENT"
        fi
        ;;
    start)
        shift
        parse_args "$@"
        CLIENT="${ARG_USER:-${OTHER_ARGS[0]}}"
        cmd_start "$CLIENT"
        ;;
    stop)
        shift
        parse_args "$@"
        CLIENT="${ARG_USER:-${OTHER_ARGS[0]}}"
        cmd_stop "$CLIENT"
        ;;
    restart)
        shift
        parse_args "$@"
        CLIENT="${ARG_USER:-${OTHER_ARGS[0]}}"
        cmd_restart "$CLIENT"
        ;;
    logs)
        shift
        parse_args "$@"
        CLIENT="${ARG_USER:-${OTHER_ARGS[0]}}"
        SERVICE="${OTHER_ARGS[1]:-rtorrent}"
        
        if [ -z "$CLIENT" ]; then
            print_error_box "Client requis: --USER=<nom>"
            exit 1
        fi
        
        cmd_logs "$CLIENT" "$SERVICE"
        ;;
    quota)
        cmd_quota
        ;;
    passwd)
        shift
        parse_args "$@"
        CLIENT="${ARG_USER:-${OTHER_ARGS[0]}}"
        NEW_PASS="${ARG_PASSWORD:-${OTHER_ARGS[1]}}"
        
        if [ -z "$CLIENT" ] || [ -z "$NEW_PASS" ]; then
            print_error_box "Usage: ./laboboxvpn-manager.sh passwd --USER=<nom> --PASSWORD=<nouveau>"
            exit 1
        fi
        
        cmd_passwd "$CLIENT" "$NEW_PASS"
        ;;
    mount)
        shift
        parse_args "$@"
        CLIENT="${ARG_USER:-${OTHER_ARGS[0]}}"
        cmd_mount "$CLIENT"
        ;;
    health)
        cmd_health
        ;;
    optimize)
        shift
        cmd_optimize "$@"
        ;;
    optimize-status)
        cmd_optimize --status
        ;;
    optimize-restore)
        cmd_optimize --restore
        ;;
    migrate-sessions)
        cmd_migrate_sessions
        ;;
    check-ports)
        shift
        parse_args "$@"
        cmd_check_ports "${ARG_USER:-${OTHER_ARGS[0]:-}}"
        ;;
    bench)
        shift
        parse_args "$@"
        cmd_bench_all "${ARG_USER:-${OTHER_ARGS[0]:-}}"
        ;;
    bench-nfs)
        shift
        parse_args "$@"
        if [ -n "$ARG_USER" ]; then
            cmd_bench_nfs "$ARG_USER" "${OTHER_ARGS[0]:-}"
        else
            cmd_bench_nfs "${OTHER_ARGS[0]:-}" "${OTHER_ARGS[1]:-}"
        fi
        ;;
    bench-vpn)
        shift
        parse_args "$@"
        cmd_bench_vpn "${ARG_USER:-${OTHER_ARGS[0]:-}}"
        ;;
    autostart-enable)
        cmd_autostart_enable
        ;;
    autostart-disable)
        cmd_autostart_disable
        ;;
    temp-enable)
        shift
        parse_args "$@"
        cmd_temp_enable "${ARG_USER:-${OTHER_ARGS[0]:-}}"
        ;;
    temp-disable)
        shift
        parse_args "$@"
        cmd_temp_disable "${ARG_USER:-${OTHER_ARGS[0]:-}}"
        ;;
    config-network)
        cmd_config_network
        ;;
    apps-status)
        cmd_apps_status
        ;;
    install-jellyfin)
        cmd_install_jellyfin
        ;;
    install-plex)
        cmd_install_plex
        ;;
    install-resilio)
        cmd_install_resilio
        ;;
    install-watchtower)
        cmd_install_watchtower
        ;;
    uninstall-jellyfin)
        cmd_uninstall_jellyfin
        ;;
    uninstall-plex)
        cmd_uninstall_plex
        ;;
    uninstall-resilio)
        cmd_uninstall_resilio
        ;;
    uninstall-watchtower)
        cmd_uninstall_watchtower
        ;;
    install-dashboard)
        cmd_install_dashboard
        ;;
    uninstall-dashboard)
        cmd_uninstall_dashboard
        ;;
    sync-libs)
        shift
        APP="${1:-}"
        if [ -z "$APP" ]; then
            print_error_box "Usage: ./laboboxvpn-manager.sh sync-libs <jellyfin|plex|resilio>"
            exit 1
        fi
        cmd_update_media_libs "$APP"
        ;;
    hw-transcoding)
        shift
        APP="${1:-}"
        if [ -z "$APP" ]; then
            print_error_box "Usage: ./laboboxvpn-manager.sh hw-transcoding <jellyfin|plex>"
            exit 1
        fi
        cmd_configure_hw_transcoding "$APP"
        ;;
    uninstall)
        cmd_uninstall
        ;;
    help|--help|-h)
        cmd_help
        ;;
    *)
        print_error_box "Commande inconnue: $1" "└─ Tapez ./laboboxvpn-manager.sh help"
        exit 1
        ;;
esac