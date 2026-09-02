#!/bin/bash
#===============================================================================
#
#  LaboBox-VPN — Optimisation réseau & stockage NFS
#
#  Portage de l'optimiseur de Network-WireGuard-Manager, adapté à la seedbox :
#    - paramètres kernel (sysctl) dimensionnés d'après le CPU et la RAM,
#      profil adapté à l'environnement détecté (bare-metal / VM / hôte Proxmox),
#    - BBR + fq (repli automatique sur cubic si le noyau ne propose pas BBR),
#    - writeback disque en BYTES et non en ratio : le flush vers le NAS
#      devient continu au lieu d'explosif (l'ex-menu « Optimisation
#      stockage NFS » est intégré ici, il n'existe plus séparément),
#    - conntrack dimensionné + hashsize aligné (NAT Docker/Gluetun),
#    - tuning matériel de la carte réseau rejoué à chaque boot : files
#      multiqueue, ring buffers, offloads (dont UDP-GRO forwarding, décisif
#      pour le trafic WireGuard), affinité IRQ, RPS/XPS,
#    - limites système raisonnées (pas de memlock illimité pour tous),
#    - réversible d'un seul geste (--restore).
#
#  UTILISATION :
#    ./network-optimize.sh            Appliquer l'optimisation (profil auto)
#    ./network-optimize.sh --yes      Appliquer sans confirmation (scriptable)
#    ./network-optimize.sh --status   Voir le statut actuel
#    ./network-optimize.sh --restore  Restaurer les paramètres d'origine
#    ./network-optimize.sh --help     Aide
#
#===============================================================================

# Pas de 'set -e' : un retour non nul anodin (grep sans résultat, clé sysctl
# refusée par le noyau…) ne doit pas interrompre une application en cours.
set -o pipefail

# Locale C forcée : sur un système en locale française, awk/printf formatent
# les décimaux avec une virgule et free/df traduisent leurs en-têtes. La
# locale C garantit des parsings identiques partout ; les textes du script,
# écrits en dur en français, ne sont pas concernés.
export LC_ALL=C

VERSION="4.0.0"

#--- Chemins -------------------------------------------------------------------
INSTALL_DIR="/opt/laboboxvpn"
UTILS_DIR="${INSTALL_DIR}/utils"
SYSCTL_FILE="/etc/sysctl.d/99-labobox-network.conf"
LIMITS_FILE="/etc/security/limits.d/99-labobox.conf"
MODPROBE_FILE="/etc/modprobe.d/99-labobox.conf"
MODULES_FILE="/etc/modules-load.d/labobox.conf"
NIC_TUNE_FILE="${UTILS_DIR}/labobox-nic-tune.sh"
SERVICE_FILE="/etc/systemd/system/labobox-optimize.service"
STATE_FILE="${UTILS_DIR}/network-optimize.state"
BACKUP_DIR="/var/backups/labobox-network"

# Fichiers laissés par les versions précédentes du script : retirés à
# l'application comme à la restauration. En particulier, les deux anciens
# fichiers sysctl se contredisaient (99-labobox-ultimate.conf, appliqué
# après 99-labobox-storage.conf, remettait vm.dirty_ratio et annulait donc
# le writeback en bytes) : tout vit désormais dans UN SEUL fichier.
LEGACY_FILES=(
    "/etc/sysctl.d/99-labobox-ultimate.conf"
    "/etc/sysctl.d/99-labobox-storage.conf"
    "/etc/modules-load.d/bbr.conf"
    "${UTILS_DIR}/labobox-irq-affinity.sh"
)

#--- Affichage (marge commune de deux espaces, comme Network-WireGuard-Manager)
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[0;34m'; C_CYAN=$'\033[0;36m'; C_WHITE=$'\033[1;37m'
    C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_NC=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
    C_WHITE=""; C_DIM=""; C_BOLD=""; C_NC=""
fi

MARGIN="  "

msg_ok()   { echo "${MARGIN}${C_GREEN}✔${C_NC} $*"; }
msg_err()  { echo "${MARGIN}${C_RED}✗${C_NC} $*"; }
msg_warn() { echo "${MARGIN}${C_YELLOW}⚠${C_NC} $*"; }
msg_info() { echo "${MARGIN}${C_CYAN}ℹ${C_NC} $*"; }

print_header() {
    echo ""
    echo "${MARGIN}${C_CYAN}══════════════════════════════════════════════════════════════════════${C_NC}"
    # Titre en ASCII : printf %-58s compte les octets, pas les caractères —
    # un accent décalerait l'alignement de la version à droite.
    printf "${MARGIN}${C_BOLD}${C_WHITE}%-58s${C_NC}${C_CYAN}%10s${C_NC}\n" "LABOBOX - OPTIMISATION RESEAU & STOCKAGE" "v${VERSION}"
    echo "${MARGIN}${C_CYAN}══════════════════════════════════════════════════════════════════════${C_NC}"
    echo ""
}

# print_section "Titre" ["explication courte affichée en dessous"]
print_section() {
    echo ""
    echo "${MARGIN}${C_BLUE}══════════════════════════════════════════════════════════════════════${C_NC}"
    echo "${MARGIN}${C_BOLD}${C_WHITE}$1${C_NC}"
    [[ -n "${2:-}" ]] && echo "${MARGIN}${C_DIM}$2${C_NC}"
    echo "${MARGIN}${C_BLUE}══════════════════════════════════════════════════════════════════════${C_NC}"
    echo ""
}

# Question oui/non avec valeur par défaut. ask_yn "Question ?" "o" → 0 si oui.
ask_yn() {
    local prompt="$1" default="${2:-n}" reply
    local hint="o/N"; [[ "$default" == "o" ]] && hint="O/n"
    printf '%s%s (%s) : ' "$MARGIN" "$prompt" "$hint"
    if ! read -r reply; then
        # Fin d'entrée (stdin fermé, usage non interactif) : ne JAMAIS
        # valider par défaut une modification système — --yes existe pour ça.
        echo ""
        return 1
    fi
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[oOyY]$ ]]
}

fmt_bytes() {
    # Octets → unité lisible (o / Ko / Mo / Go / To)
    awk -v b="${1:-0}" 'BEGIN{
        split("o Ko Mo Go To", u, " "); i=1
        while (b>=1024 && i<5){ b=b/1024; i++ }
        printf "%.2f %s", b, u[i]
    }'
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        msg_err "Ce script doit être exécuté en root."
        exit 1
    fi
}

# Écriture atomique : le fichier n'est jamais visible à moitié écrit.
# write_file <chemin> <mode> ← contenu sur stdin
write_file() {
    local path="$1" mode="${2:-644}"
    mkdir -p "$(dirname "$path")"
    if cat > "${path}.tmp" && chmod "$mode" "${path}.tmp" && mv "${path}.tmp" "$path"; then
        return 0
    fi
    rm -f "${path}.tmp"
    msg_err "Échec d'écriture de $path"
    return 1
}

# Installe des paquets apt s'ils sont absents, en une seule passe apt-get.
apt_ensure() {
    local missing=() pkg
    for pkg in "$@"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0
    msg_info "Installation des paquets : ${missing[*]}"
    apt-get update -qq >/dev/null 2>&1 || true
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1; then
        msg_ok "Paquets installés : ${missing[*]}"
        return 0
    fi
    msg_warn "Échec d'installation : ${missing[*]} — on continue sans."
    return 1
}

#--- Détection de l'environnement ----------------------------------------------
# baremetal | vm | pve-host. Un hôte Proxmox se reconnaît à /etc/pve ET à
# pveversion. La seedbox est prévue pour tourner dans une VM, mais chaque
# profil applique le tuning adapté à sa situation.
OPT_ENV=""
OPT_VIRT=""

detect_env() {
    [[ -n "$OPT_ENV" ]] && return 0
    OPT_VIRT=$(systemd-detect-virt 2>/dev/null)
    [[ -z "$OPT_VIRT" ]] && OPT_VIRT="none"
    if [[ -d /etc/pve ]] && command -v pveversion >/dev/null 2>&1; then
        OPT_ENV="pve-host"
    elif [[ "$OPT_VIRT" != "none" ]]; then
        OPT_ENV="vm"
    else
        OPT_ENV="baremetal"
    fi
    return 0
}

env_label() {
    detect_env
    case "$OPT_ENV" in
        pve-host)  echo "hôte Proxmox" ;;
        vm)        echo "VM ($OPT_VIRT)" ;;
        baremetal) echo "bare-metal" ;;
    esac
}

# Interface de sortie vers Internet : interface de la route par défaut, sinon
# première carte active plausible. Sont exclues : lo, wg*, docker*, br-*,
# veth*, ifb*, tun/tap, vir*. Les bridges vmbr* ne sont PAS exclus (hôte PVE).
WAN_IF=""
WAN_DRIVER=""

detect_interface() {
    if [[ -z "$WAN_IF" ]]; then
        WAN_IF=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
        if [[ -z "$WAN_IF" ]]; then
            WAN_IF=$(ip -o link show up 2>/dev/null \
                | awk -F': ' '$2 !~ /^(lo|wg|docker|br-|veth|ifb|tun|tap|vir)/{print $2; exit}')
        fi
    fi
    [[ -z "$WAN_IF" ]] && WAN_IF="eth0"
    WAN_DRIVER=$(basename "$(readlink -f "/sys/class/net/$WAN_IF/device/driver" 2>/dev/null)" 2>/dev/null || true)
    [[ "$WAN_DRIVER" == "." ]] && WAN_DRIVER=""
    return 0
}

#--- Calculs dimensionnés sur les ressources -----------------------------------
opt_compute() {
    OPT_CPU_CORES=$(nproc)
    OPT_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
    OPT_RAM_GB=${OPT_RAM_GB:-1}
    (( OPT_RAM_GB < 1 )) && OPT_RAM_GB=1

    # Files d'attente : proportionnelles au CPU, plafonnées (des valeurs
    # extrêmes immobilisent de la mémoire par cœur sans gain sous 10 Gb/s).
    OPT_SOMAXCONN=$((OPT_CPU_CORES * 4096))
    (( OPT_SOMAXCONN > 65535 )) && OPT_SOMAXCONN=65535
    OPT_NETDEV_BACKLOG=$((OPT_CPU_CORES * 2048))
    (( OPT_NETDEV_BACKLOG > 65536 )) && OPT_NETDEV_BACKLOG=65536

    # Buffers réseau : plafond d'auto-tuning à 128 Mo, valeur initiale 4 Mo.
    # rmem/wmem_default s'appliquent aussi aux sockets UDP, donc au tunnel
    # WireGuard de Gluetun : 4 Mo suffisent à éviter les pertes UDP en
    # multi-gigabit sans gaspiller. Ces plafonds garantissent aussi que les
    # network.receive_buffer / send_buffer de rtorrent ne sont pas plafonnés
    # silencieusement par le noyau.
    OPT_RMEM_MAX=134217728
    OPT_WMEM_MAX=134217728
    OPT_RMEM_DEFAULT=4194304
    OPT_WMEM_DEFAULT=4194304
    OPT_TCP_RMEM_DEFAULT=1048576
    OPT_TCP_WMEM_DEFAULT=1048576
    OPT_OPTMEM_MAX=65536

    # Réserve mémoire du kernel : 2 Mo par Go de RAM, bornée [64 Mo, 256 Mo]
    OPT_MIN_FREE_KBYTES=$((OPT_RAM_GB * 2048))
    (( OPT_MIN_FREE_KBYTES < 65536 ))  && OPT_MIN_FREE_KBYTES=65536
    (( OPT_MIN_FREE_KBYTES > 262144 )) && OPT_MIN_FREE_KBYTES=262144

    # Table conntrack : chaque connexion de peer qui traverse le NAT Docker
    # y consomme une entrée. Plafonnée à 1M (~350 Mo de RAM). Le hashsize
    # doit suivre (max/4), sinon les buckets débordent et le temps de
    # recherche s'effondre.
    OPT_CONNTRACK_MAX=$((OPT_RAM_GB * 16384))
    (( OPT_CONNTRACK_MAX < 131072 ))  && OPT_CONNTRACK_MAX=131072
    (( OPT_CONNTRACK_MAX > 1048576 )) && OPT_CONNTRACK_MAX=1048576
    OPT_CONNTRACK_BUCKETS=$((OPT_CONNTRACK_MAX / 4))

    OPT_FILE_MAX=$((OPT_RAM_GB * 65536))
    (( OPT_FILE_MAX < 262144 )) && OPT_FILE_MAX=262144

    OPT_INOTIFY_WATCHES=$((OPT_RAM_GB * 32768))
    (( OPT_INOTIFY_WATCHES > 1048576 )) && OPT_INOTIFY_WATCHES=1048576
    (( OPT_INOTIFY_WATCHES < 65536 ))   && OPT_INOTIFY_WATCHES=65536

    # Writeback en BYTES (ex-« Optimisation stockage NFS », intégrée ici).
    # Par défaut le noyau raisonne en ratio de la RAM (dirty_ratio = 20) :
    # avec beaucoup de RAM, des gigaoctets de pages sales s'accumulent puis
    # partent d'un coup vers le NAS — un array mécanique encaisse la rafale
    # pendant des dizaines de secondes et rtorrent gèle. En bytes, le flush
    # démarre tôt et reste continu. Dimensionné sur la RAM et borné :
    #   - seuil de flush en tâche de fond : 32 Mo/Go, borné [64 Mo, 256 Mo]
    #   - plafond bloquant : 4× le seuil, borné [256 Mo, 1 Go]
    OPT_DIRTY_BG_BYTES=$((OPT_RAM_GB * 33554432))
    (( OPT_DIRTY_BG_BYTES < 67108864 ))  && OPT_DIRTY_BG_BYTES=67108864
    (( OPT_DIRTY_BG_BYTES > 268435456 )) && OPT_DIRTY_BG_BYTES=268435456
    OPT_DIRTY_BYTES=$((OPT_DIRTY_BG_BYTES * 4))
    (( OPT_DIRTY_BYTES > 1073741824 )) && OPT_DIRTY_BYTES=1073741824
    return 0
}

# BBR disponible sur ce noyau ? Charge le module et vérifie.
# Affiche « bbr », ou « cubic » en repli.
opt_cc_algo() {
    modprobe tcp_bbr 2>/dev/null || true
    if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        echo "bbr"
    else
        echo "cubic"
    fi
}

#--- Rendu sysctl (fonction pure : calculs faits, profil et algo en argument) --
opt_render_sysctl() {
    local profile="$1" cc_algo="$2"
    cat << EOF
###############################################################################
# LaboBox-VPN v${VERSION} — optimisation kernel GÉNÉRÉE, ne pas éditer.
# Profil : ${profile} — ${OPT_RAM_GB} Go RAM / ${OPT_CPU_CORES} CPU
# Regénéré par : network-optimize.sh
###############################################################################

# --- Congestion TCP : ${cc_algo} + fq (pacing kernel, requis par BBR) --------
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${cc_algo}

# --- Routage (NAT Docker/Gluetun) --------------------------------------------
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1

# --- Buffers sockets ---------------------------------------------------------
# max = plafond d'auto-tuning ; default = valeur initiale (UDP inclus, donc
# le tunnel WireGuard de Gluetun). Ne pas mettre default = max : chaque
# socket réserverait 128 Mo.
net.core.rmem_max = ${OPT_RMEM_MAX}
net.core.wmem_max = ${OPT_WMEM_MAX}
net.core.rmem_default = ${OPT_RMEM_DEFAULT}
net.core.wmem_default = ${OPT_WMEM_DEFAULT}
net.core.optmem_max = ${OPT_OPTMEM_MAX}

# --- Buffers TCP (min / default / max) ---------------------------------------
net.ipv4.tcp_rmem = 4096 ${OPT_TCP_RMEM_DEFAULT} ${OPT_RMEM_MAX}
net.ipv4.tcp_wmem = 4096 ${OPT_TCP_WMEM_DEFAULT} ${OPT_WMEM_MAX}
net.ipv4.tcp_moderate_rcvbuf = 1

# --- Buffers UDP (WireGuard) -------------------------------------------------
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# NOTE : net.ipv4.tcp_mem volontairement NON défini — le kernel le calcule
# d'après la RAM au boot ; le forcer expose à l'épuisement mémoire sous flood.

# --- Options TCP -------------------------------------------------------------
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_early_retrans = 4
net.ipv4.tcp_reordering = 6

# MTU probing mode 1 : ne s'active QUE si un trou noir PMTU est détecté
# (fréquent derrière un tunnel WireGuard, MTU 1420).
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024

# ECN mode 2 : accepté si le pair le demande, jamais demandé
# (le mode 1 pose problème avec certains middleboxes).
net.ipv4.tcp_ecn = 2

# --- Backlog et files --------------------------------------------------------
net.core.somaxconn = ${OPT_SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${OPT_SOMAXCONN}
net.core.netdev_max_backlog = ${OPT_NETDEV_BACKLOG}
# 300 (défaut kernel) est court en multi-gigabit ; des valeurs très élevées
# provoquent des stalls RCU — 1000 est le bon compromis.
net.core.netdev_budget = 1000
# netdev_budget_usecs : volontairement non défini (plancher dépendant de
# CONFIG_HZ, la valeur par défaut est déjà au plancher).

# --- Connection tracking (NAT Docker : chaque peer = une entrée) -------------
net.netfilter.nf_conntrack_max = ${OPT_CONNTRACK_MAX}
# Le timeout par défaut d'une session TCP établie est de 5 jours : la table
# d'une passerelle NAT se remplirait de connexions de peers mortes. 24 h.
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180

# --- TIME_WAIT et orphelins --------------------------------------------------
net.ipv4.tcp_max_orphans = 262144
net.ipv4.tcp_max_tw_buckets = 1048576
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# --- Keepalive ---------------------------------------------------------------
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5

# --- Plage de ports source ---------------------------------------------------
net.ipv4.ip_local_port_range = 10240 65000

# --- Mémoire virtuelle & writeback NFS ---------------------------------------
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.min_free_kbytes = ${OPT_MIN_FREE_KBYTES}
vm.max_map_count = 262144

# Writeback en BYTES et non en ratio (ces clés remplacent vm.dirty_ratio /
# vm.dirty_background_ratio, mises à zéro automatiquement par le noyau) :
# le flush vers le NAS démarre à $(fmt_bytes "$OPT_DIRTY_BG_BYTES") en tâche de fond et ne peut
# jamais accumuler plus de $(fmt_bytes "$OPT_DIRTY_BYTES") — continu au lieu d'explosif, les
# disques mécaniques du NAS ne prennent plus de rafale et rtorrent ne gèle
# plus pendant les gros flushs.
vm.dirty_background_bytes = ${OPT_DIRTY_BG_BYTES}
vm.dirty_bytes = ${OPT_DIRTY_BYTES}
# Pages sales écrites au plus tard après 10 s, flusher réveillé chaque
# seconde (défauts : 30 s / 5 s) : la file d'écriture reste courte.
vm.dirty_expire_centisecs = 1000
vm.dirty_writeback_centisecs = 100

# --- Sécurité réseau ---------------------------------------------------------
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.icmp_ratelimit = 1000
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# rp_filter loose (2) et NON strict (1) : le mode strict casse le routage
# asymétrique des bridges Docker (trafic Gluetun compris).
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# log_martians coupé : bridges Docker + tunnels génèrent des faux positifs
# qui satureraient /var/log.
net.ipv4.conf.all.log_martians = 0
net.ipv4.conf.default.log_martians = 0

# --- Limites fichiers --------------------------------------------------------
fs.file-max = ${OPT_FILE_MAX}
fs.inotify.max_user_watches = ${OPT_INOTIFY_WATCHES}
fs.inotify.max_user_instances = 1024
fs.aio-max-nr = 1048576

# --- IPv6 --------------------------------------------------------------------
# Durcissement uniquement — pas de net.ipv6.conf.all.forwarding = 1 ici :
# la seedbox ne route pas d'IPv6 (Docker travaille en IPv4), et l'activer
# ferait ignorer les Router Advertisements par le noyau → une VM dont
# l'IPv6 est auto-configurée (SLAAC) perdrait sa connectivité IPv6.
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
EOF

    if [[ "$profile" == "pve-host" ]]; then
        cat << 'EOF'

# --- Spécifique hôte Proxmox -------------------------------------------------
# Les clés net.bridge.bridge-nf-call-* ne sont PAS touchées : pve-firewall
# en dépend pour filtrer le trafic des VM.
EOF
    fi
}

#--- Rendu du script de tuning NIC (rejoué à chaque boot) ----------------------
# Attend que le lien soit réellement négocié, puis règle : files matérielles
# (multiqueue), ring buffers, offloads (dont UDP-GRO forwarding, décisif pour
# le trafic WireGuard routé vers Gluetun), affinité des IRQ, RPS/XPS.
# Conscient du profil : sur un hôte Proxmox, il vise la carte physique sous
# le bridge et laisse irqbalance répartir les IRQ entre les VM.
opt_render_nic_tune() {
    local profile="$1"
    cat << 'TUNE_HEAD'
#!/bin/bash
###############################################################################
# LaboBox-VPN — tuning matériel de la carte réseau (généré, rejoué au boot).
# Best effort : aucune erreur ne doit empêcher le démarrage de la machine.
###############################################################################
TUNE_HEAD
    echo "PROFILE=\"$profile\""
    cat << 'TUNE_EOF'

# --- Attente que le lien soit RÉELLEMENT opérationnel ------------------------
# network-online.target ne garantit pas que la négociation du lien soit
# terminée, et plusieurs pilotes réinitialisent leurs ring buffers au
# link-up : on attend donc operstate=up nous-mêmes (30 s max).
NIC=""
for _try in $(seq 1 30); do
    NIC=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
    if [ -z "$NIC" ]; then
        NIC=$(ip -o link show up 2>/dev/null \
              | awk -F': ' '$2 !~ /^(lo|wg|docker|br-|veth|ifb|tun|tap|vir)/{print $2; exit}')
    fi
    if [ -n "$NIC" ] && [ "$(cat "/sys/class/net/$NIC/operstate" 2>/dev/null)" = "up" ]; then
        break
    fi
    sleep 1
done
[ -z "$NIC" ] || [ ! -d "/sys/class/net/$NIC" ] && { echo "nic-tune: aucune interface exploitable" >&2; exit 0; }

# Hôte Proxmox : la route passe par le bridge vmbr0, le matériel à régler est
# la carte physique membre du bridge.
if [ -d "/sys/class/net/$NIC/brif" ]; then
    for port in "/sys/class/net/$NIC/brif"/*; do
        [ -e "$port" ] || continue
        port=$(basename "$port")
        if [ -d "/sys/class/net/$port/device" ]; then
            NIC="$port"
            break
        fi
    done
fi

sleep 2   # laisse le pilote terminer sa séquence de link-up
echo "nic-tune: interface ${NIC} (profil ${PROFILE})"
NUM_CPUS=$(nproc)

if command -v ethtool >/dev/null 2>&1; then
    # --- Files matérielles (channels) : une par cœur, AVANT les rings --------
    # Réglage crucial et souvent oublié : une carte 10G — ou une vNIC virtio
    # dont le Multiqueue est configuré côté Proxmox — expose souvent moins
    # de files ACTIVES que possible. Sans « ethtool -L », le multiqueue
    # n'est tout simplement pas utilisé. À faire avant les ring buffers :
    # changer les channels peut les réinitialiser.
    MAX_COMB=$(ethtool -l "$NIC" 2>/dev/null | awk '/Pre-set/,/Current/' | awk '/^Combined:/{print $2; exit}')
    CUR_COMB=$(ethtool -l "$NIC" 2>/dev/null | awk '/Current/,0'      | awk '/^Combined:/{print $2; exit}')
    if [ -n "$MAX_COMB" ] && [ "$MAX_COMB" != "n/a" ] && [ "$MAX_COMB" -ge 1 ] 2>/dev/null; then
        TARGET_COMB=$MAX_COMB
        [ "$NUM_CPUS" -lt "$TARGET_COMB" ] && TARGET_COMB=$NUM_CPUS
        if [ -n "$CUR_COMB" ] && [ "$CUR_COMB" != "$TARGET_COMB" ]; then
            if ethtool -L "$NIC" combined "$TARGET_COMB" >/dev/null 2>&1; then
                echo "nic-tune: files combinées ${CUR_COMB} → ${TARGET_COMB}"
            fi
        fi
    fi

    # --- Ring buffers : au maximum supporté par le pilote --------------------
    MAX_RX=$(ethtool -g "$NIC" 2>/dev/null | awk '/Pre-set/,/Current/' | awk '/^RX:/{print $2; exit}')
    MAX_TX=$(ethtool -g "$NIC" 2>/dev/null | awk '/Pre-set/,/Current/' | awk '/^TX:/{print $2; exit}')
    CUR_RX=$(ethtool -g "$NIC" 2>/dev/null | awk '/Current/,0'      | awk '/^RX:/{print $2; exit}')
    CUR_TX=$(ethtool -g "$NIC" 2>/dev/null | awk '/Current/,0'      | awk '/^TX:/{print $2; exit}')
    # On ne touche la carte que si la valeur change : un ethtool -G inutile
    # peut provoquer un reset du lien pour rien.
    if [ -n "$MAX_RX" ] && [ "$MAX_RX" != "n/a" ] && [ "$MAX_RX" != "$CUR_RX" ]; then
        ethtool -G "$NIC" rx "$MAX_RX" >/dev/null 2>&1 || echo "nic-tune: ethtool -G rx refusé (normal sur certains virtio)" >&2
    fi
    if [ -n "$MAX_TX" ] && [ "$MAX_TX" != "n/a" ] && [ "$MAX_TX" != "$CUR_TX" ]; then
        ethtool -G "$NIC" tx "$MAX_TX" >/dev/null 2>&1 || echo "nic-tune: ethtool -G tx refusé" >&2
    fi

    # --- Offloads ------------------------------------------------------------
    # GRO/TSO/GSO/SG : indispensables pour du multi-gigabit sans brûler le CPU.
    ethtool -K "$NIC" gro on tso on gso on sg on >/dev/null 2>&1 || true
    # LRO : fusionne les paquets de façon irréversible → corrompt le trafic
    # ROUTÉ (donc tout ce qui part vers les conteneurs). Toujours coupé.
    ethtool -K "$NIC" lro off >/dev/null 2>&1 || true
    # UDP GRO forwarding : gros gain pour le trafic UDP routé/chiffré comme
    # le WireGuard des Gluetun. rx-gro-list doit être coupé en même temps.
    ethtool -K "$NIC" rx-udp-gro-forwarding on rx-gro-list off >/dev/null 2>&1 || true

    # Coalescing adaptatif : compromis débit/latence géré par le pilote.
    ethtool -C "$NIC" adaptive-rx on adaptive-tx on >/dev/null 2>&1 || true
fi

# --- Affinité IRQ / RPS / XPS ------------------------------------------------
# Hôte Proxmox : irqbalance reste en charge (répartition entre les VM) — on
# ne touche ni aux IRQ ni à RPS/XPS.
if [ "$PROFILE" != "pve-host" ]; then
    # Une file par cœur, en round-robin, uniquement les IRQ de la carte.
    # Sur une vNIC virtio (VM Proxmox), les IRQ n'apparaissent pas sous le
    # nom de l'interface (ens18) mais sous celui du périphérique
    # (virtio0-input.N / virtio0-output.N) : on résout le bon motif.
    IRQ_PAT="$NIC"
    VDEV=$(basename "$(readlink -f "/sys/class/net/$NIC/device" 2>/dev/null)" 2>/dev/null)
    case "$VDEV" in virtio*) IRQ_PAT="$VDEV" ;; esac
    IRQS=$(grep -E "[[:space:]]${IRQ_PAT}(-|\.|$|[[:space:]])" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ')
    CPU=0
    for IRQ in $IRQS; do
        if [ -w "/proc/irq/$IRQ/smp_affinity_list" ]; then
            echo "$CPU" > "/proc/irq/$IRQ/smp_affinity_list" 2>/dev/null || true
            CPU=$(( (CPU + 1) % NUM_CPUS ))
        fi
    done

    # RPS : utile UNIQUEMENT en mono-file. Sur du multi-file (RSS matériel ou
    # virtio multiqueue), l'activer ajouterait du travail inter-cœurs.
    RX_QUEUES=$(ls -d /sys/class/net/"$NIC"/queues/rx-* 2>/dev/null | wc -l)
    if [ "$RX_QUEUES" -le 1 ]; then
        if [ "$NUM_CPUS" -le 32 ]; then
            MASK=$(printf '%x' $(( (1 << NUM_CPUS) - 1 )))
        else
            MASK="ffffffff,ffffffff"
        fi
        for Q in /sys/class/net/"$NIC"/queues/rx-*/rps_cpus; do
            [ -w "$Q" ] && echo "$MASK" > "$Q" 2>/dev/null
        done
        [ -w /proc/sys/net/core/rps_sock_flow_entries ] && \
            echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
        for Q in /sys/class/net/"$NIC"/queues/rx-*/rps_flow_cnt; do
            [ -w "$Q" ] && echo 32768 > "$Q" 2>/dev/null
        done
    fi

    # XPS : une file TX par cœur.
    CPU=0
    for Q in /sys/class/net/"$NIC"/queues/tx-*/xps_cpus; do
        [ -w "$Q" ] || continue
        if [ "$NUM_CPUS" -le 32 ]; then
            printf '%x' $(( 1 << CPU )) > "$Q" 2>/dev/null || true
        fi
        CPU=$(( (CPU + 1) % NUM_CPUS ))
    done
fi

exit 0
TUNE_EOF
}

#--- Fichier de limites système ------------------------------------------------
# « * » concerne TOUS les comptes (donc les clients SFTP) : ni memlock
# illimité (DoS mémoire), ni nproc quasi infini (fork bomb) — seuls les
# plafonds de root sont larges. Les conteneurs rtorrent gardent par ailleurs
# leurs propres ulimits dans docker-compose.yml.
opt_render_limits() {
    cat << EOF
# LaboBox-VPN — limites système (générées)
*               soft    nofile          262144
*               hard    nofile          524288
root            soft    nofile          524288
root            hard    nofile          1048576
*               soft    nproc           8192
*               hard    nproc           16384
root            soft    nproc           65536
root            hard    nproc           65536
*               soft    memlock         65536
*               hard    memlock         65536
root            soft    memlock         unlimited
root            hard    memlock         unlimited
*               soft    stack           65536
*               hard    stack           65536
*               soft    core            0
*               hard    core            0
EOF
}

#--- Service de boot -----------------------------------------------------------
# Les clés sysctl sont rejouées au boot par systemd-sysctl (fichier dans
# /etc/sysctl.d) et les modules par systemd-modules-load : le service ne
# rejoue donc que le tuning matériel de la carte, perdu à chaque démarrage.
opt_render_service() {
    cat << EOF
[Unit]
Description=LaboBox-VPN — tuning carte réseau au boot (files, rings, offloads, IRQ)
After=network-online.target systemd-modules-load.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=120
ExecStart=${NIC_TUNE_FILE}

[Install]
WantedBy=multi-user.target
EOF
}

#--- Application ---------------------------------------------------------------
# do_apply [--yes] [--profile baremetal|vm|pve-host]
do_apply() {
    local assume_yes="no" profile=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes) assume_yes="yes"; shift ;;
            --profile)
                profile="${2:-}"
                if [[ -z "$profile" ]]; then
                    msg_err "--profile attend une valeur : baremetal | vm | pve-host"
                    return 1
                fi
                shift 2 ;;
            *) msg_err "Option inconnue : $1"; return 1 ;;
        esac
    done

    require_root
    detect_env
    [[ -z "$profile" ]] && profile="$OPT_ENV"
    case "$profile" in baremetal|vm|pve-host) ;; *) msg_err "Profil inconnu : $profile"; return 1 ;; esac

    print_header
    print_section "Optimisation réseau & stockage — profil : $profile" \
        "Analyse le matériel (CPU, RAM, carte réseau) et règle réseau + writeback NFS"
    opt_compute
    detect_interface
    echo "  Machine : $(env_label)   CPU : ${OPT_CPU_CORES} cœurs   RAM : ${OPT_RAM_GB} Go"
    echo "  Interface : ${WAN_IF} ${WAN_DRIVER:+($WAN_DRIVER)}"
    echo "  Writeback NFS : flush dès $(fmt_bytes "$OPT_DIRTY_BG_BYTES"), plafond $(fmt_bytes "$OPT_DIRTY_BYTES")"
    echo ""

    if [[ "$profile" == "pve-host" ]]; then
        msg_warn "Hôte Proxmox détecté : la seedbox est prévue pour tourner dans une VM."
        msg_info "Le profil pve-host reste applicable (tuning adapté, irqbalance conservé)."
        echo ""
    fi

    if [[ "$assume_yes" != "yes" ]]; then
        msg_warn "Le réglage des ring buffers peut réinitialiser brièvement le lien réseau."
        msg_warn "En SSH, lance ceci depuis tmux/screen."
        ask_yn "Appliquer l'optimisation ?" "o" || { msg_info "Annulé."; return 0; }
        echo ""
    fi

    apt_ensure ethtool conntrack || true

    # Sauvegarde unique de l'état sysctl d'origine, jamais écrasée par les
    # applications suivantes : c'est LA référence d'avant toute optimisation.
    mkdir -p "$BACKUP_DIR" "$UTILS_DIR"
    if [[ ! -d "$BACKUP_DIR/sysctl-origin" ]]; then
        mkdir -p "$BACKUP_DIR/sysctl-origin"
        sysctl -a > "$BACKUP_DIR/sysctl-origin/sysctl-all.txt" 2>/dev/null || true
        [[ -f /etc/sysctl.conf ]] && cp /etc/sysctl.conf "$BACKUP_DIR/sysctl-origin/" 2>/dev/null
        msg_ok "État sysctl d'origine sauvegardé ($BACKUP_DIR/sysctl-origin)."
    fi

    # Fichiers des anciennes versions : retirés AVANT d'appliquer, sinon les
    # deux générations de réglages se marchent dessus au prochain boot.
    local legacy removed=""
    for legacy in "${LEGACY_FILES[@]}"; do
        [[ -f "$legacy" ]] && { rm -f "$legacy"; removed="${removed}${legacy} "; }
    done
    [[ -n "$removed" ]] && msg_ok "Anciens fichiers retirés : $removed"

    # nf_conntrack doit être chargé MAINTENANT, sinon le kernel refuse les
    # clés nf_conntrack_* au moment du sysctl -p.
    modprobe nf_conntrack 2>/dev/null || true
    write_file "$MODPROBE_FILE" 644 << EOF
# LaboBox-VPN — hashsize conntrack aligné sur nf_conntrack_max (généré)
options nf_conntrack hashsize=${OPT_CONNTRACK_BUCKETS}
EOF
    if [[ -w /sys/module/nf_conntrack/parameters/hashsize ]]; then
        echo "$OPT_CONNTRACK_BUCKETS" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
    fi
    local mod
    for mod in tcp_bbr nf_conntrack; do
        grep -qx "$mod" "$MODULES_FILE" 2>/dev/null || echo "$mod" >> "$MODULES_FILE"
    done

    # BBR, ou repli sur cubic si le noyau ne le propose pas
    local cc_algo
    cc_algo=$(opt_cc_algo)
    [[ "$cc_algo" == "bbr" ]] || msg_warn "BBR indisponible sur ce noyau : cubic conservé."

    # Rendus + application
    opt_render_sysctl "$profile" "$cc_algo" | write_file "$SYSCTL_FILE" 644 || return 1
    opt_render_limits | write_file "$LIMITS_FILE" 644 || return 1
    opt_render_nic_tune "$profile" | write_file "$NIC_TUNE_FILE" 755 || return 1

    local errors
    errors=$(sysctl -p "$SYSCTL_FILE" 2>&1 >/dev/null | grep -v '^$' || true)
    if [[ -n "$errors" ]]; then
        msg_warn "Clés refusées par ce noyau (sans conséquence) :"
        echo "$errors" | sed 's/^/    /'
    fi
    msg_ok "Paramètres kernel appliqués."

    local active_cc
    active_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$active_cc" == "bbr" ]]; then
        msg_ok "Contrôle de congestion actif : bbr"
    else
        msg_warn "Contrôle de congestion actif : ${active_cc:-inconnu}"
    fi

    # Tuning NIC immédiat (le même script sera rejoué à chaque boot).
    # Sa sortie, pensée pour le journal systemd, est réalignée sur la marge
    # de l'interface quand elle s'affiche ici.
    "$NIC_TUNE_FILE" 2>/dev/null | sed 's/^/  /' || true
    msg_ok "Tuning carte réseau appliqué (offloads, UDP-GRO forwarding, files)."

    # irqbalance : désactivé quand le script fixe lui-même l'affinité des IRQ
    # (il l'écraserait en continu) ; conservé sur un hôte Proxmox. On mémorise
    # si c'est NOUS qui l'avons coupé : --restore ne le réactivera que dans ce
    # cas (un irqbalance volontairement désactivé avant nous le restera).
    local irqb_disabled="no"
    if [[ -r "$STATE_FILE" ]] && grep -q '^OPT_IRQBALANCE_DISABLED="yes"' "$STATE_FILE" 2>/dev/null; then
        irqb_disabled="yes"   # coupé par une application précédente
    fi
    if [[ "$profile" == "pve-host" ]]; then
        msg_info "Hôte Proxmox : irqbalance conservé (répartition multi-VM)."
    elif systemctl is-active --quiet irqbalance 2>/dev/null; then
        systemctl disable --now irqbalance >/dev/null 2>&1 || true
        irqb_disabled="yes"
        msg_ok "irqbalance désactivé (il écraserait l'affinité IRQ fixée). Rétabli par --restore."
    fi

    # Service de boot (rejoue le tuning NIC à chaque démarrage)
    opt_render_service | write_file "$SERVICE_FILE" 644 || return 1
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable labobox-optimize.service >/dev/null 2>&1 || true
    msg_ok "Service de boot installé : labobox-optimize.service"

    # Mémorise l'état de l'optimiseur
    write_file "$STATE_FILE" 600 << EOF
# LaboBox-VPN — état de l'optimiseur (généré)
OPT_APPLIED="yes"
OPT_PROFILE="$profile"
OPT_DATE="$(date '+%Y-%m-%d %H:%M')"
OPT_CPU_CORES="$OPT_CPU_CORES"
OPT_RAM_GB="$OPT_RAM_GB"
OPT_IRQBALANCE_DISABLED="$irqb_disabled"
EOF

    # Conseils que le script ne peut pas appliquer lui-même (côté hyperviseur)
    if [[ "$OPT_ENV" == "vm" ]]; then
        local queues
        queues=$(ls -d "/sys/class/net/$WAN_IF/queues/rx-"* 2>/dev/null | wc -l)
        if [[ "$queues" -le 1 && "$OPT_CPU_CORES" -gt 1 ]]; then
            echo ""
            msg_warn "Cette VM n'a qu'UNE file réseau pour ${OPT_CPU_CORES} vCPU."
            msg_info "Côté Proxmox : Hardware → Network Device → Multiqueue = ${OPT_CPU_CORES}"
            msg_info "(et CPU type 'host' pour AES-NI/AVX → chiffrement WireGuard bien plus rapide)."
        fi
    fi

    echo ""
    msg_ok "Optimisation appliquée (profil $profile). Un reboot est conseillé pour les limites."
    echo ""
    return 0
}

#--- Restauration --------------------------------------------------------------
# Retire tous les fichiers générés (anciennes versions comprises) et remet
# les valeurs par défaut de Debian pour les clés les plus impactantes.
do_restore() {
    require_root
    print_header
    print_section "Restauration des paramètres d'origine"

    rm -f "$SYSCTL_FILE" "$LIMITS_FILE" "$MODPROBE_FILE" "$NIC_TUNE_FILE"
    local legacy
    for legacy in "${LEGACY_FILES[@]}"; do
        rm -f "$legacy"
    done
    if [[ -f "$MODULES_FILE" ]]; then
        sed -i '/^tcp_bbr$/d;/^nf_conntrack$/d' "$MODULES_FILE"
        [[ -s "$MODULES_FILE" ]] || rm -f "$MODULES_FILE"
    fi

    systemctl disable --now labobox-optimize.service >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null || true

    # irqbalance : réactivé UNIQUEMENT si c'est l'optimiseur qui l'avait
    # coupé (mémorisé dans l'état) — un service volontairement désactivé
    # avant toute optimisation n'est pas touché.
    if [[ -r "$STATE_FILE" ]] && grep -q '^OPT_IRQBALANCE_DISABLED="yes"' "$STATE_FILE" 2>/dev/null; then
        if systemctl list-unit-files 2>/dev/null | grep -q '^irqbalance.service'; then
            systemctl enable --now irqbalance >/dev/null 2>&1 || true
            msg_ok "irqbalance réactivé."
        fi
    fi

    # Valeurs par défaut de Debian pour les clés les plus impactantes.
    # Remettre dirty_ratio / dirty_background_ratio remet aussi à zéro les
    # clés *_bytes (elles sont mutuellement exclusives dans le noyau).
    sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
    sysctl -w net.core.rmem_max=212992 >/dev/null 2>&1 || true
    sysctl -w net.core.wmem_max=212992 >/dev/null 2>&1 || true
    sysctl -w net.core.rmem_default=212992 >/dev/null 2>&1 || true
    sysctl -w net.core.wmem_default=212992 >/dev/null 2>&1 || true
    sysctl -w vm.swappiness=60 >/dev/null 2>&1 || true
    sysctl -w vm.dirty_ratio=20 >/dev/null 2>&1 || true
    sysctl -w vm.dirty_background_ratio=10 >/dev/null 2>&1 || true
    sysctl -w vm.dirty_expire_centisecs=3000 >/dev/null 2>&1 || true
    sysctl -w vm.dirty_writeback_centisecs=500 >/dev/null 2>&1 || true

    write_file "$STATE_FILE" 600 << EOF
OPT_APPLIED="no"
OPT_PROFILE=""
EOF

    # Le forwarding IP reste requis tant que Docker fait tourner les clients
    if command -v docker >/dev/null 2>&1; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
        msg_info "Forwarding IP conservé (Docker/Gluetun en dépendent)."
    fi

    msg_ok "Paramètres d'origine restaurés. Un reboot est recommandé."
    echo ""
    return 0
}

#--- Statut --------------------------------------------------------------------
do_status() {
    print_header
    OPT_APPLIED="no"; OPT_PROFILE=""; OPT_DATE=""
    # shellcheck disable=SC1090
    [[ -r "$STATE_FILE" ]] && source "$STATE_FILE"

    echo "  ${C_BOLD}Optimisation réseau & stockage :${C_NC}"
    echo "    Machine     : $(env_label) — $(nproc) CPU, $(free -h | awk '/^Mem:/{print $2}') RAM"
    if [[ "$OPT_APPLIED" == "yes" && -f "$SYSCTL_FILE" ]]; then
        echo "    État        : ${C_GREEN}appliquée${C_NC} (profil $OPT_PROFILE, le $OPT_DATE)"
    elif [[ -f "$SYSCTL_FILE" ]]; then
        # Le fichier sysctl (lisible par tous) existe mais l'état détaillé
        # (600, root) n'est pas lisible : exécution sans droits root.
        echo "    État        : ${C_GREEN}appliquée${C_NC} ${C_DIM}(détails complets en root)${C_NC}"
    elif [[ -f "/etc/sysctl.d/99-labobox-ultimate.conf" || -f "/etc/sysctl.d/99-labobox-storage.conf" ]]; then
        echo "    État        : ${C_YELLOW}ancienne version détectée${C_NC} — relance l'application"
    else
        echo "    État        : ${C_YELLOW}non appliquée${C_NC}"
    fi
    echo "    Congestion  : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?') / qdisc $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
    echo "    rmem_max    : $(fmt_bytes "$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)")"
    echo "    conntrack   : $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo '?') / $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo '?')"
    echo "    swappiness  : $(sysctl -n vm.swappiness 2>/dev/null || echo '?')"
    echo ""

    echo "  ${C_BOLD}Writeback disque (flush vers le NAS) :${C_NC}"
    local dbg db dr dbr
    dbg=$(sysctl -n vm.dirty_background_bytes 2>/dev/null || echo 0)
    db=$(sysctl -n vm.dirty_bytes 2>/dev/null || echo 0)
    dr=$(sysctl -n vm.dirty_ratio 2>/dev/null || echo '?')
    dbr=$(sysctl -n vm.dirty_background_ratio 2>/dev/null || echo '?')
    if [[ "$db" != "0" && -n "$db" ]]; then
        echo "    Mode        : ${C_GREEN}bytes (flush continu)${C_NC}"
        echo "    Seuil fond  : $(fmt_bytes "$dbg")"
        echo "    Plafond     : $(fmt_bytes "$db")"
    else
        echo "    Mode        : ${C_YELLOW}ratio (défaut noyau — flush par rafales)${C_NC}"
        echo "    Ratios      : background ${dbr}% / plafond ${dr}% de la RAM"
    fi
    echo "    En attente  : $(awk '/^Dirty:/{print $2" "$3}' /proc/meminfo 2>/dev/null || echo '?') sales, $(awk '/^Writeback:/{print $2" "$3}' /proc/meminfo 2>/dev/null || echo '?') en écriture"
    echo ""

    echo "  ${C_BOLD}Boot :${C_NC}"
    if systemctl is-enabled --quiet labobox-optimize.service 2>/dev/null; then
        echo "    Service     : ${C_GREEN}labobox-optimize.service activé${C_NC} (tuning NIC rejoué au boot)"
    else
        echo "    Service     : ${C_YELLOW}non installé${C_NC}"
    fi
    if [[ -d "$BACKUP_DIR/sysctl-origin" ]]; then
        echo "    Sauvegarde  : $BACKUP_DIR/sysctl-origin (état d'avant optimisation)"
    fi
    echo ""
    return 0
}

#--- Aide ----------------------------------------------------------------------
show_help() {
    print_header
    echo "  Usage : network-optimize.sh [OPTION]"
    echo ""
    echo "    (aucune)     Appliquer l'optimisation (profil auto, confirmation demandée)"
    echo "    --yes        Appliquer sans confirmation"
    echo "    --profile P  Forcer le profil : baremetal | vm | pve-host"
    echo "    --status     Afficher le statut actuel"
    echo "    --restore    Restaurer les paramètres d'origine"
    echo "    --help       Afficher cette aide"
    echo ""
    echo "  Ce que règle l'application, dimensionné sur le CPU et la RAM :"
    echo "    - BBR + fq (repli cubic), buffers réseau, backlog, conntrack + hashsize"
    echo "    - writeback disque en bytes : flush continu vers le NAS (ex-menu"
    echo "      « Optimisation stockage NFS », intégré ici)"
    echo "    - carte réseau : files multiqueue, ring buffers, offloads (UDP-GRO"
    echo "      forwarding), affinité IRQ, RPS/XPS — rejoué à chaque boot"
    echo "    - limites système (nofile, nproc) raisonnées"
    echo ""
}

#--- Main ----------------------------------------------------------------------
case "${1:-}" in
    --help|-h)
        show_help
        ;;
    --status|-s)
        do_status
        ;;
    --restore|-r)
        do_restore
        ;;
    ""|--yes|--profile)
        do_apply "$@"
        ;;
    *)
        msg_err "Option inconnue : $1"
        echo "  Utilise --help pour voir les options disponibles."
        exit 1
        ;;
esac
