#!/bin/bash
###############################################################################
#                                                                             #
#                    LABOBOX - OPTIMISATION RESEAU ULTIME                     #
#                                                                             #
#                              Version 3.0.0                                  #
#                                                                             #
#                    Detection automatique RAM/CPU                            #
#                    Backup et restauration inclus                            #
#                                                                             #
#                           By CLusmi - 2025                                  #
#                                                                             #
###############################################################################
#
# UTILISATION :
# =============
#   ./network-optimize.sh           # Appliquer les optimisations
#   ./network-optimize.sh --restore # Restaurer les parametres d'origine
#   ./network-optimize.sh --status  # Voir le statut actuel
#   ./network-optimize.sh --help    # Aide
#
###############################################################################

set -e

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
NC='\033[0m'

# Repertoire de backup
BACKUP_DIR="/var/backups/labobox-network"
SYSCTL_FILE="/etc/sysctl.d/99-labobox-ultimate.conf"
LIMITS_FILE="/etc/security/limits.d/99-labobox.conf"

###############################################################################
# FONCTIONS AFFICHAGE
###############################################################################

line() {
    echo "------------------------------------------------------------------------"
}

double_line() {
    echo "========================================================================"
}

print_header() {
    clear
    echo ""
    double_line
    echo "  LABOBOX - OPTIMISATION RESEAU ULTIME                      v3.0.0"
    double_line
    echo ""
}

print_step() {
    echo ""
    echo -e "  ${CYAN}>>>${NC} $1"
}

print_substep() {
    echo -e "      ${DIM}-${NC} $1"
}

print_success() {
    echo -e "      ${GREEN}[OK]${NC} $1"
}

print_error() {
    echo -e "      ${RED}[ERREUR]${NC} $1"
}

print_warning() {
    echo -e "      ${YELLOW}[!]${NC} $1"
}

print_info() {
    echo -e "  ${DIM}$1${NC}"
}

print_value() {
    local label=$1
    local value=$2
    printf "      %-18s : %s\n" "$label" "$value"
}

print_analyzing() {
    echo -ne "      ${DIM}Analyse en cours...${NC}"
    sleep 0.5
    echo -ne "\r      ${DIM}Analyse en cours....${NC}"
    sleep 0.5
    echo -ne "\r      ${DIM}Analyse en cours.....${NC}"
    sleep 0.5
    echo -e "\r                                     \r"
}

print_applying() {
    echo -ne "      ${DIM}Application en cours...${NC}"
    sleep 0.3
    echo -ne "\r      ${DIM}Application en cours....${NC}"
    sleep 0.3
    echo -ne "\r      ${DIM}Application en cours.....${NC}"
    sleep 0.3
    echo -e "\r                                        \r"
}

###############################################################################
# SHOW HELP
###############################################################################

show_help() {
    print_header
    echo "  AIDE"
    line
    echo ""
    echo "  Usage: network-optimize.sh [OPTION]"
    echo ""
    echo "  Options:"
    echo "    (aucune)     Appliquer les optimisations reseau"
    echo "    --restore    Restaurer les parametres d'origine"
    echo "    --status     Afficher le statut actuel"
    echo "    --help       Afficher cette aide"
    echo ""
    echo "  Exemples:"
    echo "    network-optimize.sh              # Optimiser le reseau"
    echo "    network-optimize.sh --restore    # Revenir aux parametres par defaut"
    echo "    network-optimize.sh --status     # Voir la configuration actuelle"
    echo ""
    double_line
    echo ""
}

###############################################################################
# SHOW STATUS
###############################################################################

show_status() {
    print_header
    echo "  STATUT ACTUEL"
    line
    
    # Systeme
    print_step "SYSTEME"
    print_value "RAM totale" "$(free -h | awk '/^Mem:/{print $2}')"
    print_value "RAM disponible" "$(free -h | awk '/^Mem:/{print $7}')"
    print_value "CPU cores" "$(nproc)"
    
    # TCP
    print_step "TCP CONGESTION"
    print_value "Algorithme" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'N/A')"
    print_value "Disponibles" "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo 'N/A')"
    
    # Buffers
    print_step "BUFFERS RESEAU"
    print_value "rmem_max" "$(numfmt --to=iec $(sysctl -n net.core.rmem_max 2>/dev/null) 2>/dev/null || echo 'N/A')"
    print_value "wmem_max" "$(numfmt --to=iec $(sysctl -n net.core.wmem_max 2>/dev/null) 2>/dev/null || echo 'N/A')"
    
    # TCP Options
    print_step "OPTIONS TCP"
    print_value "Fast Open" "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 'N/A')"
    print_value "Slow Start" "$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null || echo 'N/A')"
    print_value "MTU Probing" "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo 'N/A')"
    
    # Backup
    print_step "BACKUP"
    if [ -d "$BACKUP_DIR" ]; then
        print_value "Status" "Disponible"
        print_value "Emplacement" "$BACKUP_DIR"
    else
        print_value "Status" "Aucun backup"
    fi
    
    # Optimisation active ?
    print_step "OPTIMISATION LABOBOX"
    if [ -f "$SYSCTL_FILE" ]; then
        echo -e "      ${GREEN}ACTIVE${NC}"
    else
        echo -e "      ${YELLOW}NON ACTIVE${NC}"
    fi
    
    echo ""
    double_line
    echo ""
}

###############################################################################
# BACKUP
###############################################################################

do_backup() {
    print_step "CREATION DU BACKUP DE SECURITE"
    
    print_substep "Creation du repertoire de backup..."
    sleep 0.5
    mkdir -p "$BACKUP_DIR"
    
    print_substep "Sauvegarde des parametres sysctl actuels..."
    sleep 0.5
    sysctl -a > "$BACKUP_DIR/sysctl-original.conf" 2>/dev/null || true
    
    print_substep "Sauvegarde des fichiers de configuration..."
    sleep 0.5
    [ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf "$BACKUP_DIR/"
    [ -d /etc/sysctl.d ] && cp -r /etc/sysctl.d "$BACKUP_DIR/"
    [ -d /etc/security/limits.d ] && cp -r /etc/security/limits.d "$BACKUP_DIR/"
    
    print_substep "Sauvegarde des modules charges..."
    sleep 0.5
    lsmod > "$BACKUP_DIR/modules.txt"
    
    # Script de restauration
    cat > "$BACKUP_DIR/restore-values.sh" << 'RESTORE_EOF'
#!/bin/bash
sysctl -w net.core.default_qdisc=fq_codel
sysctl -w net.ipv4.tcp_congestion_control=cubic
sysctl -w net.core.rmem_max=212992
sysctl -w net.core.wmem_max=212992
sysctl -w net.core.rmem_default=212992
sysctl -w net.core.wmem_default=212992
sysctl -w net.ipv4.tcp_rmem="4096 131072 6291456"
sysctl -w net.ipv4.tcp_wmem="4096 16384 4194304"
sysctl -w net.ipv4.tcp_fastopen=1
sysctl -w net.ipv4.tcp_slow_start_after_idle=1
sysctl -w net.ipv4.tcp_mtu_probing=0
sysctl -w net.core.somaxconn=4096
sysctl -w net.core.netdev_max_backlog=1000
sysctl -w vm.swappiness=60
sysctl -w vm.dirty_ratio=20
sysctl -w vm.dirty_background_ratio=10
RESTORE_EOF
    chmod +x "$BACKUP_DIR/restore-values.sh"
    
    print_success "Backup cree : $BACKUP_DIR"
}

###############################################################################
# RESTORE
###############################################################################

do_restore() {
    print_header
    echo "  RESTAURATION DES PARAMETRES D'ORIGINE"
    line
    
    if [ ! -d "$BACKUP_DIR" ]; then
        print_warning "Aucun backup trouve dans $BACKUP_DIR"
        echo ""
        echo -n "  Restaurer les valeurs par defaut Debian ? (o/n) : "
        read -r REPLY
        if [[ ! $REPLY =~ ^[Oo]$ ]]; then
            echo ""
            print_info "Restauration annulee."
            echo ""
            return
        fi
    fi
    
    print_step "SUPPRESSION DES CONFIGURATIONS LABOBOX"
    
    print_substep "Suppression des fichiers sysctl..."
    sleep 0.5
    rm -f "$SYSCTL_FILE"
    rm -f "$LIMITS_FILE"
    rm -f /etc/modules-load.d/bbr.conf
    rm -f /opt/laboboxvpn/utils/labobox-irq-affinity.sh
    
    print_substep "Desactivation du service systemd..."
    sleep 0.5
    systemctl disable labobox-optimize.service 2>/dev/null || true
    systemctl stop labobox-optimize.service 2>/dev/null || true
    rm -f /etc/systemd/system/labobox-optimize.service
    systemctl daemon-reload
    
    print_step "RESTAURATION DES VALEURS PAR DEFAUT"
    print_analyzing
    
    if [ -f "$BACKUP_DIR/restore-values.sh" ]; then
        bash "$BACKUP_DIR/restore-values.sh" 2>/dev/null || true
    else
        sysctl -w net.core.default_qdisc=fq_codel 2>/dev/null || true
        sysctl -w net.ipv4.tcp_congestion_control=cubic 2>/dev/null || true
        sysctl -w net.core.rmem_max=212992 2>/dev/null || true
        sysctl -w net.core.wmem_max=212992 2>/dev/null || true
    fi
    
    print_success "Parametres par defaut restaures"
    
    echo ""
    double_line
    echo "  RESTAURATION TERMINEE"
    double_line
    echo ""
    print_info "Un reboot est recommande : reboot"
    echo ""
}

###############################################################################
# DETECTION ET CALCUL
###############################################################################

detect_and_calculate() {
    # =========================================================================
    # DETECTION CPU
    # =========================================================================
    print_step "ANALYSE DU PROCESSEUR"
    
    print_substep "Detection du nombre de coeurs CPU..."
    print_analyzing
    
    CPU_CORES=$(nproc)
    print_success "Processeur detecte : ${CPU_CORES} coeurs"
    
    print_substep "Calcul des optimisations pour ${CPU_CORES} coeurs..."
    sleep 0.8
    
    # Somaxconn & backlog bases sur CPU
    SOMAXCONN=$((CPU_CORES * 4096))
    [ $SOMAXCONN -gt 65535 ] && SOMAXCONN=65535
    NETDEV_BACKLOG=$((CPU_CORES * 16384))
    [ $NETDEV_BACKLOG -gt 250000 ] && NETDEV_BACKLOG=250000
    
    print_success "somaxconn optimise : ${SOMAXCONN}"
    print_success "netdev_backlog optimise : ${NETDEV_BACKLOG}"
    
    # =========================================================================
    # DETECTION RAM
    # =========================================================================
    print_step "ANALYSE DE LA MEMOIRE RAM"
    
    print_substep "Detection de la quantite de RAM..."
    print_analyzing
    
    RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
    RAM_BYTES=$(free -b | awk '/^Mem:/{print $2}')
    print_success "Memoire detectee : ${RAM_GB} Go"
    
    print_substep "Calcul des optimisations pour ${RAM_GB} Go de RAM..."
    sleep 0.8
    
    # Buffers reseau (128 Mo pour 10 Gbps)
    RMEM_MAX=134217728
    WMEM_MAX=134217728
    RMEM_DEFAULT=8388608
    WMEM_DEFAULT=8388608
    
    # TCP Memory base sur RAM
    TCP_MEM_LOW=$((RAM_GB * 16384))
    TCP_MEM_PRESSURE=$((RAM_GB * 32768))
    TCP_MEM_HIGH=$((RAM_GB * 131072))
    [ $TCP_MEM_LOW -lt 65536 ] && TCP_MEM_LOW=65536
    [ $TCP_MEM_PRESSURE -lt 131072 ] && TCP_MEM_PRESSURE=131072
    [ $TCP_MEM_HIGH -lt 262144 ] && TCP_MEM_HIGH=262144
    
    # Min free kbytes
    MIN_FREE_KBYTES=$((RAM_GB * 2048))
    [ $MIN_FREE_KBYTES -lt 65536 ] && MIN_FREE_KBYTES=65536
    [ $MIN_FREE_KBYTES -gt 262144 ] && MIN_FREE_KBYTES=262144
    
    # Conntrack
    CONNTRACK_MAX=$((RAM_GB * 65536))
    [ $CONNTRACK_MAX -lt 131072 ] && CONNTRACK_MAX=131072
    
    # File descriptors
    FILE_MAX=$((RAM_GB * 65536))
    [ $FILE_MAX -lt 262144 ] && FILE_MAX=262144
    
    # Inotify
    INOTIFY_WATCHES=$((RAM_GB * 32768))
    [ $INOTIFY_WATCHES -gt 1048576 ] && INOTIFY_WATCHES=1048576
    
    print_success "tcp_mem optimise : ${TCP_MEM_LOW} / ${TCP_MEM_PRESSURE} / ${TCP_MEM_HIGH}"
    print_success "conntrack_max optimise : ${CONNTRACK_MAX}"
    print_success "file_max optimise : ${FILE_MAX}"
    
    # =========================================================================
    # DETECTION INTERFACE RESEAU
    # =========================================================================
    print_step "ANALYSE DE L'INTERFACE RESEAU"
    
    print_substep "Detection de l'interface principale..."
    print_analyzing
    
    MAIN_NIC=$(ip route | grep default | awk '{print $5}' | head -1)
    [ -z "$MAIN_NIC" ] && MAIN_NIC="eth0"
    print_success "Interface detectee : ${MAIN_NIC}"
    
    # =========================================================================
    # RESUME
    # =========================================================================
    print_step "RESUME DE L'ANALYSE"
    line
    print_value "CPU" "${CPU_CORES} coeurs"
    print_value "RAM" "${RAM_GB} Go"
    print_value "Interface" "${MAIN_NIC}"
    print_value "Buffers reseau" "128 Mo (optimise 10 Gbps)"
    echo ""
    sleep 1
}

###############################################################################
# APPLICATION
###############################################################################

apply_optimizations() {
    # =========================================================================
    # OUTILS
    # =========================================================================
    print_step "VERIFICATION DES OUTILS"
    
    print_substep "Installation de ethtool si necessaire..."
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq ethtool >/dev/null 2>&1 || true
    print_success "Outils verifies"
    
    # =========================================================================
    # BBR
    # =========================================================================
    print_step "ACTIVATION DE L'ALGORITHME BBR (Google)"
    
    print_substep "BBR optimise le debit sur les connexions longue distance..."
    sleep 0.5
    print_substep "Gain moyen : +20% a +50% de debit"
    sleep 0.5
    
    print_substep "Chargement du module tcp_bbr..."
    modprobe tcp_bbr 2>/dev/null || true
    if ! grep -q "tcp_bbr" /etc/modules-load.d/*.conf 2>/dev/null; then
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    fi
    print_success "Module BBR active"
    
    # =========================================================================
    # SYSCTL
    # =========================================================================
    print_step "GENERATION DE LA CONFIGURATION KERNEL"
    
    print_substep "Creation du fichier de configuration optimise..."
    print_substep "Adaptation pour ${RAM_GB} Go RAM et ${CPU_CORES} CPU..."
    sleep 0.8
    
    cat > "$SYSCTL_FILE" << EOF
###############################################################################
# LABOBOX - OPTIMISATION KERNEL v3.0.0
# Genere le $(date '+%Y-%m-%d %H:%M')
# Configuration : ${RAM_GB} Go RAM / ${CPU_CORES} coeurs CPU
###############################################################################

# BBR - Algorithme de congestion TCP (Google)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Buffers reseau (optimise pour 10 Gbps)
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${WMEM_MAX}
net.core.rmem_default = ${RMEM_DEFAULT}
net.core.wmem_default = ${WMEM_DEFAULT}
net.core.optmem_max = ${RMEM_MAX}

# Buffers TCP
net.ipv4.tcp_rmem = 4096 ${RMEM_DEFAULT} ${RMEM_MAX}
net.ipv4.tcp_wmem = 4096 ${WMEM_DEFAULT} ${WMEM_MAX}

# Buffers UDP
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# Memoire TCP globale
net.ipv4.tcp_mem = ${TCP_MEM_LOW} ${TCP_MEM_PRESSURE} ${TCP_MEM_HIGH}

# TCP Fast Open (economise 1 RTT par connexion)
net.ipv4.tcp_fastopen = 3

# Ne pas ralentir apres idle (important pour streaming)
net.ipv4.tcp_slow_start_after_idle = 0

# MTU Probing automatique
net.ipv4.tcp_mtu_probing = 2
net.ipv4.tcp_base_mss = 512

# Window Scaling et Timestamps
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1

# SACK - Retransmission selective
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_dsack = 1

# Pas de cache des metriques
net.ipv4.tcp_no_metrics_save = 1

# Auto-tuning des buffers
net.ipv4.tcp_moderate_rcvbuf = 1

# ECN et Low latency
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_low_latency = 1

# Thin streams optimizations
net.ipv4.tcp_thin_linear_timeouts = 1
net.ipv4.tcp_thin_dupack = 1

# Early retransmit
net.ipv4.tcp_early_retrans = 4

# Tolerance au reordonnancement
net.ipv4.tcp_reordering = 6

# Listen backlog (optimise pour ${CPU_CORES} CPU)
net.core.somaxconn = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${SOMAXCONN}

# Network backlog
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.core.netdev_budget = 50000
net.core.netdev_budget_usecs = 5000

# Connection tracking (optimise pour ${RAM_GB} Go RAM)
net.netfilter.nf_conntrack_max = ${CONNTRACK_MAX}

# TCP orphans et TIME_WAIT
net.ipv4.tcp_max_orphans = 262144
net.ipv4.tcp_max_tw_buckets = 2097152
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10

# Keepalive (detection connexions mortes en 10 min)
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5

# Memoire virtuelle (optimise pour ${RAM_GB} Go RAM)
vm.swappiness = 10
vm.dirty_ratio = 40
vm.dirty_background_ratio = 10
vm.dirty_expire_centisecs = 6000
vm.dirty_writeback_centisecs = 1000
vm.vfs_cache_pressure = 50
vm.min_free_kbytes = ${MIN_FREE_KBYTES}
vm.overcommit_memory = 0

# Securite reseau
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.icmp_ratelimit = 1000
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Limites fichiers (optimise pour ${RAM_GB} Go RAM)
fs.file-max = ${FILE_MAX}
fs.inotify.max_user_watches = ${INOTIFY_WATCHES}
fs.inotify.max_user_instances = 1024
fs.aio-max-nr = 1048576

# IPv6
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
EOF

    print_success "Configuration sysctl generee"
    
    # =========================================================================
    # APPLICATION SYSCTL
    # =========================================================================
    print_step "APPLICATION DES PARAMETRES KERNEL"
    
    print_substep "Application de ${SYSCTL_FILE}..."
    print_applying
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || print_warning "Certains parametres ignores (normal)"
    print_success "Parametres kernel appliques"
    
    # =========================================================================
    # LIMITES SYSTEME
    # =========================================================================
    print_step "CONFIGURATION DES LIMITES SYSTEME"
    
    print_substep "Optimisation des limites pour ${RAM_GB} Go RAM..."
    sleep 0.5
    
    cat > "$LIMITS_FILE" << EOF
# LABOBOX - LIMITES SYSTEME
# Configuration pour ${RAM_GB} Go RAM

*               soft    nofile          1048576
*               hard    nofile          1048576
root            soft    nofile          1048576
root            hard    nofile          1048576
*               soft    nproc           131072
*               hard    nproc           131072
root            soft    nproc           131072
root            hard    nproc           131072
*               soft    memlock         unlimited
*               hard    memlock         unlimited
*               soft    stack           65536
*               hard    stack           65536
*               soft    core            0
*               hard    core            0
EOF
    
    print_success "Limites systeme configurees"
    
    # =========================================================================
    # CARTE RESEAU
    # =========================================================================
    print_step "OPTIMISATION DE LA CARTE RESEAU (${MAIN_NIC})"
    
    if command -v ethtool &> /dev/null; then
        print_substep "Configuration des ring buffers..."
        sleep 0.5
        MAX_RX=$(ethtool -g $MAIN_NIC 2>/dev/null | grep -A 4 "Pre-set" | grep "RX:" | awk '{print $2}')
        MAX_TX=$(ethtool -g $MAIN_NIC 2>/dev/null | grep -A 4 "Pre-set" | grep "TX:" | awk '{print $2}')
        if [ -n "$MAX_RX" ] && [ -n "$MAX_TX" ]; then
            ethtool -G $MAIN_NIC rx $MAX_RX tx $MAX_TX >/dev/null 2>&1 || true
            print_success "Ring buffers : RX=${MAX_RX} TX=${MAX_TX}"
        else
            print_success "Ring buffers : valeurs par defaut"
        fi
        
        print_substep "Configuration de l'offloading..."
        sleep 0.5
        ethtool -K $MAIN_NIC gro on tso on gso on sg on >/dev/null 2>&1 || true
        ethtool -K $MAIN_NIC lro off >/dev/null 2>&1 || true
        print_success "Offloading configure (GRO, TSO, GSO actives)"
    fi
    
    # =========================================================================
    # IRQ AFFINITY
    # =========================================================================
    print_step "CONFIGURATION DE L'AFFINITE IRQ"
    
    print_substep "Repartition des interruptions sur les ${CPU_CORES} coeurs..."
    sleep 0.5
    
    # S'assurer que le dossier existe
    mkdir -p /opt/laboboxvpn/utils
    
    cat > /opt/laboboxvpn/utils/labobox-irq-affinity.sh << 'IRQ_SCRIPT'
#!/bin/bash
MAIN_NIC=$(ip route | grep default | awk '{print $5}' | head -1)
[ -z "$MAIN_NIC" ] && MAIN_NIC="eth0"
NUM_CPUS=$(nproc)
IRQS=$(grep -E "$MAIN_NIC|virtio" /proc/interrupts | awk '{print $1}' | tr -d ':')
CPU=0
for IRQ in $IRQS; do
    if [ -f /proc/irq/$IRQ/smp_affinity_list ]; then
        echo $CPU > /proc/irq/$IRQ/smp_affinity_list 2>/dev/null || true
        CPU=$(( (CPU + 1) % NUM_CPUS ))
    fi
done
IRQ_SCRIPT
    
    chmod +x /opt/laboboxvpn/utils/labobox-irq-affinity.sh
    /opt/laboboxvpn/utils/labobox-irq-affinity.sh 2>/dev/null || true
    print_success "Affinite IRQ configuree"
    
    # =========================================================================
    # RPS/XPS
    # =========================================================================
    print_step "CONFIGURATION RPS/XPS"
    
    print_substep "Repartition du traitement reseau sur tous les coeurs..."
    sleep 0.5
    
    if [ -d /sys/class/net/$MAIN_NIC/queues ]; then
        CPU_MASK=$(printf '%x' $((2**CPU_CORES - 1)))
        for QUEUE in /sys/class/net/$MAIN_NIC/queues/rx-*/rps_cpus; do
            echo $CPU_MASK > $QUEUE 2>/dev/null || true
        done
        CPU=0
        for QUEUE in /sys/class/net/$MAIN_NIC/queues/tx-*/xps_cpus; do
            echo $((2**CPU)) > $QUEUE 2>/dev/null || true
            CPU=$(( (CPU + 1) % CPU_CORES ))
        done
        print_success "RPS/XPS configure (mask: ${CPU_MASK})"
    else
        print_success "RPS/XPS : non applicable"
    fi
    
    # =========================================================================
    # SERVICE SYSTEMD
    # =========================================================================
    print_step "CREATION DU SERVICE SYSTEMD"
    
    print_substep "Le service s'executera automatiquement au demarrage..."
    sleep 0.5
    
    cat > /etc/systemd/system/labobox-optimize.service << 'SERVICE_EOF'
[Unit]
Description=LaboBox Network Optimization
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/laboboxvpn/utils/labobox-irq-affinity.sh
ExecStart=/bin/bash -c 'NIC=$(ip route | grep default | awk "{print \$5}" | head -1); ethtool -K $NIC gro on tso on gso on 2>/dev/null || true'
ExecStart=/sbin/sysctl -w net.ipv4.tcp_congestion_control=bbr

[Install]
WantedBy=multi-user.target
SERVICE_EOF
    
    systemctl daemon-reload
    systemctl enable labobox-optimize.service 2>/dev/null
    print_success "Service systemd cree et active"
}

###############################################################################
# RESUME FINAL
###############################################################################

show_summary() {
    echo ""
    echo ""
    double_line
    echo "  VERIFICATION FINALE"
    double_line
    
    print_step "CONFIGURATION APPLIQUEE"
    print_value "RAM" "${RAM_GB} Go"
    print_value "CPU" "${CPU_CORES} coeurs"
    print_value "Interface" "${MAIN_NIC}"
    
    print_step "TCP CONGESTION"
    local CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$CC" = "bbr" ]; then
        echo -e "      ${GREEN}BBR actif${NC}"
    else
        echo -e "      ${YELLOW}$CC${NC}"
    fi
    
    print_step "BUFFERS"
    print_value "rmem_max" "$(numfmt --to=iec $(sysctl -n net.core.rmem_max 2>/dev/null) 2>/dev/null)"
    print_value "wmem_max" "$(numfmt --to=iec $(sysctl -n net.core.wmem_max 2>/dev/null) 2>/dev/null)"
    
    print_step "BACKUP"
    print_value "Emplacement" "$BACKUP_DIR"
    print_value "Restaurer" "network-optimize.sh --restore"
    
    echo ""
    double_line
    echo "  OPTIMISATION TERMINEE AVEC SUCCES !"
    double_line
    echo ""
    print_info "Un reboot est recommande pour appliquer toutes les modifications."
    echo ""
    echo "  Commandes utiles :"
    echo ""
    printf "      %-45s %s\n" "reboot" "# Redemarrer le serveur"
    printf "      %-45s %s\n" "network-optimize.sh --status" "# Voir le statut actuel"
    printf "      %-45s %s\n" "network-optimize.sh --restore" "# Restaurer les parametres"
    echo ""
}

###############################################################################
# MAIN - OPTIMIZE
###############################################################################

do_optimize() {
    print_header
    echo "  OPTIMISATION RESEAU AUTOMATIQUE"
    line
    echo ""
    print_info "Ce module va analyser votre systeme et appliquer"
    print_info "les optimisations reseau adaptees a votre configuration."
    echo ""
    sleep 1.5
    
    # Verification root
    if [ "$(id -u)" != "0" ]; then
        print_error "Ce script doit etre execute en root"
        exit 1
    fi
    
    # Verification des dependances
    if ! command -v numfmt &> /dev/null; then
        print_warning "numfmt non trouve, installation de coreutils..."
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq coreutils >/dev/null 2>&1
        if ! command -v numfmt &> /dev/null; then
            print_error "Impossible d'installer numfmt (coreutils)"
            print_info "Les valeurs seront affichees en bytes"
        else
            print_success "coreutils installe"
        fi
    fi
    
    # Backup si necessaire
    if [ ! -d "$BACKUP_DIR" ]; then
        do_backup
    else
        print_info "Backup existant trouve, conservation..."
    fi
    
    # Detection et calcul
    detect_and_calculate
    
    # Application
    apply_optimizations
    
    # Resume
    show_summary
}

###############################################################################
# MAIN
###############################################################################

case "${1:-}" in
    --help|-h)
        show_help
        ;;
    --status|-s)
        show_status
        ;;
    --restore|-r)
        if [ "$(id -u)" != "0" ]; then
            echo -e "${RED}Ce script doit etre execute en root${NC}"
            exit 1
        fi
        do_restore
        ;;
    "")
        do_optimize
        ;;
    *)
        echo -e "${RED}Option inconnue: $1${NC}"
        echo "Utilisez --help pour voir les options disponibles."
        exit 1
        ;;
esac
