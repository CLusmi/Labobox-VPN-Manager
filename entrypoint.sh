#!/bin/bash
###############################################
# ENTRYPOINT - rtorrent + ruTorrent v3.3.0    #
# Genere les configs depuis les variables ENV #
# LaboBox-VPN - 2026                          #
#                                             #
# v3.3.0 : SSD miroir categorie + garde-fou   #
#          taille, profil download agressif   #
# v3.2.0 : ruTorrent 5.2.10, php simplexml    #
# v3.1.0 : optimisation stockage NFS          #
#  - session + logs hors NFS (si volume local)#
#  - chmod recursifs supprimes (storm NFS)    #
#  - peers/slots de seed reduits              #
#  - cache de descripteurs de fichiers elargi #
#  - schedules moins agressifs                #
###############################################

set -e

echo "================================================"
echo "  RTORRENT + RUTORRENT v3.3.0 - laboboxvpn"
echo "================================================"

###########################################
# VALEURS PAR DEFAUT DES VARIABLES ENV
###########################################
# Toutes surchargeables depuis docker run / le manager.
# Permet de tuner un client precis sans reconstruire l'image.

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# --- Reseau / protocole ---
RT_PORT="${RT_PORT:-51413}"
RT_DHT="${RT_DHT:-off}"
RT_PEX="${RT_PEX:-no}"
RT_ENCRYPTION="${RT_ENCRYPTION:-allow_incoming,try_outgoing,enable_retry}"

# --- IMPORTANT : rehash a la completion ---
# "yes" relit l'integralite du torrent via NFS a chaque fin de download.
# Sur un fichier de 50 Go c'est 50 Go de lecture aleatoire sur l'array.
RT_CHECK_HASH="${RT_CHECK_HASH:-no}"

# --- Memoire / descripteurs ---
# RT_MEMORY_MAX : espace d'adressage pour le mapping des chunks (PAS de la RAM).
#   Sature = rtorrent se fige le temps de synchroniser sur disque.
RT_MEMORY_MAX="${RT_MEMORY_MAX:-4096M}"
# RT_MAX_OPEN_FILES : ces fd ne passent pas par le select(), on peut monter haut.
#   Evite de refermer/rouvrir les fichiers en permanence (couteux sur NFS).
RT_MAX_OPEN_FILES="${RT_MAX_OPEN_FILES:-3072}"
# RT_MAX_OPEN_SOCKETS : celles-ci SONT dans le select(), rester serre.
RT_MAX_OPEN_SOCKETS="${RT_MAX_OPEN_SOCKETS:-900}"

# --- Peers (par torrent) ---
# Deux profils distincts :
#  * NORMAL (torrent EN TELECHARGEMENT) : les ecritures vont sur le SSD, on
#    peut donc lacher les chevaux pour saturer la connexion (beaucoup de peers).
#  * SEED (torrent TERMINE) : les lectures se font sur le NAS (disques
#    mecaniques). Genereux mais borne, pour ne pas noyer l'array en lectures
#    aleatoires. C'etait tout l'interet du disque temporaire.
RT_MIN_PEERS="${RT_MIN_PEERS:-20}"
RT_MAX_PEERS="${RT_MAX_PEERS:-100}"
RT_MIN_PEERS_SEED="${RT_MIN_PEERS_SEED:-5}"
RT_MAX_PEERS_SEED="${RT_MAX_PEERS_SEED:-50}"

# --- Slots (= flux d'IO simultanes) ---
# En download c'est du SSD (rapide) : on ouvre grand. Les uploads restent
# raisonnables par torrent (le seed lit sur le NAS).
RT_MAX_UPLOADS_GLOBAL="${RT_MAX_UPLOADS_GLOBAL:-250}"
RT_MAX_DOWNLOADS_GLOBAL="${RT_MAX_DOWNLOADS_GLOBAL:-250}"
RT_MAX_UPLOADS="${RT_MAX_UPLOADS:-8}"
RT_MAX_DOWNLOADS="${RT_MAX_DOWNLOADS:-16}"

# --- Taille max d'un torrent accepte (garde-fou) ---
# Un torrent dont la taille totale depasse cette valeur est refuse a l'ajout
# (stoppe + efface, journalise). 6 To par defaut. 0 = aucune limite.
# En octets ; 6 To = 6 * 1024^4.
RT_MAX_TORRENT_SIZE="${RT_MAX_TORRENT_SIZE:-6597069766656}"

# --- Bande passante (0 = illimite, en KiB/s) ---
RT_DOWN_RATE="${RT_DOWN_RATE:-0}"
RT_UP_RATE="${RT_UP_RATE:-0}"

# --- Schedules ---
RT_WATCH_INTERVAL="${RT_WATCH_INTERVAL:-30}"
RT_SESSION_SAVE_INTERVAL="${RT_SESSION_SAVE_INTERVAL:-14400}"

# --- ruTorrent ---
RU_USER="${RU_USER:-admin}"
TOP_DIR="${TOP_DIR:-/data}"

# --- Maintenance ---
# Mettre a "yes" UNE SEULE FOIS apres un changement de PUID/PGID.
# Sinon laisser a "no" : un chmod -R sur /data parcourt tout l'arbre via NFS.
FIX_PERMS_RECURSIVE="${FIX_PERMS_RECURSIVE:-no}"

###########################################
# CREATION UTILISATEUR
###########################################
echo "> Configuration utilisateur (PUID=$PUID, PGID=$PGID)..."

if ! getent group rtorrent > /dev/null 2>&1; then
    addgroup -g "$PGID" rtorrent
fi

if ! getent passwd rtorrent > /dev/null 2>&1; then
    adduser -D -u "$PUID" -G rtorrent -h /config rtorrent
else
    usermod -u "$PUID" rtorrent 2>/dev/null || true
    groupmod -g "$PGID" rtorrent 2>/dev/null || true
fi

###########################################
# LIMITE DE DESCRIPTEURS DE FICHIERS
###########################################
# network.max_open_files + network.max_open_sockets doivent tenir sous ulimit -n.
# Sans ca, rtorrent plafonne SILENCIEUSEMENT a 1024 et se met a fermer/rouvrir
# les fichiers en boucle : chaque cycle coute LOOKUP + OPEN + GETATTR + CLOSE
# sur NFS.
echo "> Reglage de la limite de descripteurs..."

for LIMIT in 65536 32768 16384 8192; do
    if ulimit -n "$LIMIT" 2>/dev/null; then
        break
    fi
done

CURRENT_NOFILE=$(ulimit -n)
NEEDED=$((RT_MAX_OPEN_FILES + RT_MAX_OPEN_SOCKETS + 256))

echo "  ulimit -n = $CURRENT_NOFILE (besoin estime : $NEEDED)"

if [ "$CURRENT_NOFILE" != "unlimited" ] && [ "$CURRENT_NOFILE" -lt "$NEEDED" ]; then
    echo "  [!] Limite trop basse. Ajout de --ulimit nofile=65536:65536 au docker run"
    echo "      recommande. Reduction automatique des valeurs rtorrent."
    RT_MAX_OPEN_FILES=$(( (CURRENT_NOFILE - 256) * 2 / 3 ))
    RT_MAX_OPEN_SOCKETS=$(( (CURRENT_NOFILE - 256) / 3 ))
    echo "      -> max_open_files=$RT_MAX_OPEN_FILES max_open_sockets=$RT_MAX_OPEN_SOCKETS"
fi

###########################################
# EMPLACEMENT SESSION + LOGS
###########################################
# rtorrent est MONOTHREAD : toute operation disque bloquante gele le client
# entier, downloads compris. La sauvegarde de session reecrit un fichier par
# torrent modifie.
#
# POLITIQUE : la session (liste des torrents, etat des seeds) vit TOUJOURS
# sur le NAS (/config/rtorrent/.session). Elle survit ainsi a la perte de la
# VM : en cas de crash, on repart sur une autre VM sans rien perdre. Les logs,
# sans valeur pour les seeds, restent sur le disque local (/local) quand il
# existe, pour ne pas bavarder inutilement sur le NFS.

echo "> Emplacement de la session rtorrent (NAS)..."

if grep -q " /local " /proc/mounts 2>/dev/null; then
    LOCAL_MOUNTED="yes"
    LOG_PATH="/local/log"
else
    LOCAL_MOUNTED="no"
    LOG_PATH="/config/rtorrent/log"
fi

SESSION_PATH="/config/rtorrent/.session"
echo "  [OK] session sur le NAS ${SESSION_PATH}"
[ "$LOCAL_MOUNTED" = "yes" ] && echo "       logs sur le volume local (${LOG_PATH})"

mkdir -p "$SESSION_PATH"
mkdir -p "$LOG_PATH"

# Migration one-shot : un client qui avait sa session sur le disque local
# (ancienne politique) la voit rapatriee sur le NAS au demarrage. La session
# VIVANTE est celle de /local/session ; une eventuelle ancienne session NFS
# est PERIMEE (elle ressusciterait une vieille liste de torrents) : on
# l'ecarte au lieu de la melanger. Rien n'est supprime, tout est horodate.
if [ -n "$(ls -A /local/session 2>/dev/null)" ]; then
    STAMP=$(date +%Y%m%d%H%M%S)
    echo "  -> Rapatriement de la session locale vers le NAS..."
    if [ -n "$(ls -A "$SESSION_PATH" 2>/dev/null)" ]; then
        mv "$SESSION_PATH" "${SESSION_PATH}.perimee-${STAMP}"
        echo "     ancienne session NFS ecartee : .session.perimee-${STAMP}"
    fi
    mkdir -p "$SESSION_PATH"
    cp -a /local/session/. "$SESSION_PATH"/
    chown -R rtorrent:rtorrent "$SESSION_PATH" 2>/dev/null || true
    mv /local/session "/local/session.rapatriee-${STAMP}"
    echo "     [OK] $(ls -1 "$SESSION_PATH" | wc -l) fichiers sur le NAS (copie locale conservee)"
fi

###########################################
# DISQUE TEMPORAIRE (SSD) POUR LES TELECHARGEMENTS
###########################################
# Si un volume est monte sur /temp (SSD local de la VM), chaque nouveau
# torrent est telecharge sur le SSD dans un sous-dossier qui REFLETE sa
# categorie (/data/torrents/films -> /temp/films) — ecritures aleatoires
# absorbees par le SSD, NAS au repos — puis DEPLACE a la completion vers la
# destination que l'utilisateur a choisie a l'ajout (repertoire de la
# fenetre ruTorrent ou dossier watch), memorisee dans le custom
# "labobox_dest" par l'interception inserted_new.
#
# rtorrent etant MONOTHREAD, le deplacement ne se fait JAMAIS en synchrone
# (un mv de 50 Go vers le NFS gelerait le client entier) : a la completion,
# le torrent est stoppe, un script en ARRIERE-PLAN copie vers le NAS, puis
# re-pointe le torrent sur sa destination via XML-RPC et le relance en seed.
#
# Cote manager : volume  - ${TEMP_DIR}/${CLIENT}:/temp

echo "> Disque temporaire de telechargement..."

if grep -q " /temp " /proc/mounts 2>/dev/null; then
    TEMP_ENABLED="yes"
    echo "  [OK] Volume /temp detecte -> telechargements sur disque temporaire,"
    echo "       deplacement automatique vers le NAS a la completion"
else
    TEMP_ENABLED="no"
    echo "  [-] Pas de volume /temp : telechargements directement sur /data (NAS)"
fi

###########################################
# CREATION DES DOSSIERS
###########################################
echo "> Creation des dossiers..."

mkdir -p /config/rtorrent
mkdir -p /config/rutorrent
mkdir -p /data/torrents/films
mkdir -p /data/torrents/series
mkdir -p /data/torrents/autres
mkdir -p /data/watch/films
mkdir -p /data/watch/series
mkdir -p /data/watch/autres
mkdir -p /var/run/rtorrent
mkdir -p /run/nginx
mkdir -p /run/php

if [ "$TEMP_ENABLED" = "yes" ]; then
    # Les sous-dossiers SSD par categorie (/temp/films, /temp/series, ...)
    # sont crees a la volee par labobox-ssdpath au moment de l'ajout.
    mkdir -p /temp
fi

###########################################
# GENERATION RTORRENT.RC
###########################################
echo "> Generation de rtorrent.rc..."

# L'utilisateur choisit toujours sa destination FINALE (repertoire de la
# fenetre d'ajout ruTorrent, ou dossier watch). Quand le disque temporaire
# est actif, cette destination est memorisee a l'ajout et le telechargement
# est redirige vers le SSD (miroir categorie) ; le deplacement se fait a la
# completion (voir le bloc DISQUE TEMPORAIRE plus bas). Sans /temp, le
# telechargement va directement dans la destination : memes chemins,
# memes dossiers watch dans les deux modes.
RT_DEFAULT_DIR="/data/torrents"

cat > /tmp/rtorrent.rc << EOF
##############################################
# RTORRENT.RC - Genere automatiquement
# NE PAS MODIFIER - Regenere au demarrage
# Profil : stockage NFS, forte densite de torrents
##############################################

# Mode daemon
system.daemon.set = true

# Chemins
directory.default.set = ${RT_DEFAULT_DIR}
session.path.set = ${SESSION_PATH}

# Ports
network.port_range.set = ${RT_PORT}-${RT_PORT}
network.port_random.set = no

# Protocole
dht.mode.set = ${RT_DHT}
dht.port.set = ${RT_PORT}
protocol.pex.set = ${RT_PEX}
protocol.encryption.set = ${RT_ENCRYPTION}
trackers.use_udp.set = yes

##############################################
# MEMOIRE / MMAP
##############################################
# Espace d'adressage utilise pour mapper les chunks de fichiers.
# Ce n'est PAS de la RAM allouee : le RES de rtorrent restera bien en dessous.
# Quand cet espace sature, rtorrent BLOQUE le temps de synchroniser sur disque
# -> c'est une des causes classiques de chute de debit avec beaucoup de torrents.
pieces.memory.max.set = ${RT_MEMORY_MAX}

##############################################
# DESCRIPTEURS DE FICHIERS
##############################################
# Cache de fichiers ouverts. Sur NFS, chaque fermeture/reouverture coute
# un aller-retour reseau complet (LOOKUP + OPEN + GETATTR + CLOSE).
# Avec plusieurs centaines de torrents en seed, un cache trop petit passe
# son temps a thrash. Ces fd ne sont PAS scannes par le select() : les monter
# n'a pas de cout CPU.
network.max_open_files.set = ${RT_MAX_OPEN_FILES}

# Les sockets, elles, SONT dans le fd_set parcouru a chaque poll.
# Chaque socket en plus coute du CPU sur toutes les iterations : rester serre.
network.max_open_sockets.set = ${RT_MAX_OPEN_SOCKETS}
network.http.max_open.set = 32

##############################################
# PEERS (par torrent)
##############################################
# En seed, une poignee de peers suffit a trouver des leechers. Multiplier
# les peers multiplie surtout les lectures aleatoires sur l'array.
throttle.min_peers.normal.set = ${RT_MIN_PEERS}
throttle.max_peers.normal.set = ${RT_MAX_PEERS}
throttle.min_peers.seed.set = ${RT_MIN_PEERS_SEED}
throttle.max_peers.seed.set = ${RT_MAX_PEERS_SEED}

# Nombre de peers demandes au tracker a chaque annonce (profil agressif :
# le SSD encaisse le download, on va chercher large).
trackers.numwant.set = 100

##############################################
# SLOTS = FLUX D'IO SIMULTANES
##############################################
# Un slot d'upload actif = un flux de lecture aleatoire sur les disques.
# Un slot de download actif = un flux d'ecriture a un offset different.
# C'est le levier le plus direct sur la charge disque : chaque slot en moins
# est une tete de lecture en moins qui se deplace.
throttle.max_uploads.global.set = ${RT_MAX_UPLOADS_GLOBAL}
throttle.max_downloads.global.set = ${RT_MAX_DOWNLOADS_GLOBAL}
throttle.max_uploads.set = ${RT_MAX_UPLOADS}
throttle.max_downloads.set = ${RT_MAX_DOWNLOADS}

# Bande passante (0 = illimite)
throttle.global_down.max_rate.set_kb = ${RT_DOWN_RATE}
throttle.global_up.max_rate.set_kb = ${RT_UP_RATE}

##############################################
# IO DISQUE
##############################################
# Rehash complet a la completion : relit tout le torrent via NFS. A eviter.
pieces.hash.on_completion.set = ${RT_CHECK_HASH}

# Preload : 1 = madvise. Le noyau prefetch le chunk en une lecture NFS groupee.
# Le type 2 (direct paging) touche chaque page une par une pour forcer le
# chargement : excellent sur disque local, desastreux sur NFS ou chaque page
# manquante declenche un aller-retour reseau.
pieces.preload.type.set = 1
pieces.preload.min_size.set = 262144
pieces.preload.min_rate.set = 5120

# Sync : laisse au writeback noyau. Un msync bloquant par chunk gelerait le
# thread unique de rtorrent. La regularite des ecritures se pilote cote hote
# avec vm.dirty_bytes (voir NOTES-DEPLOIEMENT.md).
pieces.sync.always_safe.set = no

# NOTE : system.file.allocate reste a sa valeur par defaut (desactive).
# L'activer sur NFS ferait ecrire des zeros sur toute la taille du fichier
# (fallocate n'y est pas disponible) = trafic reseau double.

# Buffers socket : c'est de la memoire NOYAU, multipliee par le nombre de
# peers. Avec des peers reduits, 2M/4M est confortable pour du 10 GbE.
network.receive_buffer.size.set = 4M
network.send_buffer.size.set = 8M

network.xmlrpc.size_limit.set = 16777216
network.http.ssl_verify_peer.set = 0
network.http.dns_cache_timeout.set = 25

##############################################
# LOGS
##############################################
log.open_file = "rtorrent", ${LOG_PATH}/rtorrent.log
log.add_output = "info", "rtorrent"

##############################################
# SCGI POUR RUTORRENT
##############################################
network.scgi.open_local = /var/run/rtorrent/scgi.socket
schedule2 = scgi_permission,0,0,"execute.nothrow=chmod,\"g+w,o=\",/var/run/rtorrent/scgi.socket"

##############################################
# SCHEDULES
##############################################
# Watch directories : chaque passage = un readdir NFS par dossier.
# A 5 secondes c'etait 36 readdir par minute pour rien.
schedule2 = watch_films,10,${RT_WATCH_INTERVAL},"load.start=/data/watch/films/*.torrent,d.directory.set=/data/torrents/films"
schedule2 = watch_series,15,${RT_WATCH_INTERVAL},"load.start=/data/watch/series/*.torrent,d.directory.set=/data/torrents/series"
schedule2 = watch_autres,20,${RT_WATCH_INTERVAL},"load.start=/data/watch/autres/*.torrent,d.directory.set=/data/torrents/autres"

# Sauvegarde de session : 20 minutes par defaut, operation BLOQUANTE qui
# reecrit un fichier par torrent modifie. Avec beaucoup de torrents c'est
# un gel cyclique du client. 4h suffit largement.
schedule2 = session_save, 1800, ${RT_SESSION_SAVE_INTERVAL}, ((session.save))

# Securite espace disque
schedule2 = low_diskspace,60,300,close_low_diskspace=1024M

# Umask
system.umask.set = 0022

# Encodage
encoding.add = UTF-8
EOF

# Disque temporaire : interception a l'ajout + deplacement a la completion.
# Heredoc QUOTE : les $d.* sont des variables rtorrent, pas bash.
#
# A l'ajout (inserted_new : jamais au rechargement de session) :
#  - garde-fou : un torrent plus gros que la limite est refuse (labobox-guard) ;
#  - la destination FINALE choisie par l'utilisateur est memorisee
#    (custom "labobox_dest") ;
#  - le download est redirige vers le SSD en REFLETANT la categorie :
#    /data/torrents/films -> /temp/films (calcule par labobox-ssdpath).
#    L'utilisateur choisit sa destination finale comme toujours, le SSD
#    s'intercale et reste lisible par categorie.
#
# A la completion, le torrent est stoppe puis FERME (d.close libere les
# fichiers, requis pour changer son repertoire), et le gros du travail part
# en ARRIERE-PLAN via execute.throw.bg : rtorrent (monothread) ne gele
# jamais pendant la copie. Le seed depuis le SSD continue PENDANT le
# download (natif BitTorrent) ; apres deplacement il seede depuis le NAS.
if [ "$TEMP_ENABLED" = "yes" ]; then
cat >> /tmp/rtorrent.rc << 'TEMPEOF'

##############################################
# DISQUE TEMPORAIRE : SSD PUIS DEPLACEMENT
##############################################
# Garde-fou taille (refuse a l'ajout un torrent trop gros).
method.set_key = event.download.inserted_new, labobox_guard, "execute.throw.bg=/usr/local/bin/labobox-guard,$d.hash=,$d.size_bytes="
# Memorise la destination finale, redirige le download vers le SSD (miroir categorie).
method.set_key = event.download.inserted_new, labobox_grab, "d.custom.set=labobox_dest,(d.directory) ; d.directory.set=(execute.capture,/usr/local/bin/labobox-ssdpath,(d.directory))"
# d.data_path : dossier du torrent (multi-fichiers) ou fichier (mono).
method.insert = d.data_path, simple, "if=(d.is_multi_file), (cat,(d.directory)), (cat,(d.directory),/,(d.name))"
# A la completion : on lance UNIQUEMENT le deplaceur en arriere-plan. On NE
# stoppe NI ne ferme le torrent ici : il continue de seeder depuis le SSD
# pendant la copie, et rtorrent (monothread) ne gele donc pas au moment de la
# completion. C'est le deplaceur qui, une fois la copie finie, stoppe/ferme/
# re-pointe/relance via XML-RPC — a ce moment les donnees sont deja a plat
# (plus rien a vider), donc le bref arret est independant de la taille.
method.set_key = event.download.finished, labobox_move, "execute.throw.bg=/usr/local/bin/labobox-mover,$d.hash=,$d.data_path=,$d.custom=labobox_dest"
TEMPEOF
fi

cp /tmp/rtorrent.rc /config/rtorrent/rtorrent.rc
chmod 644 /config/rtorrent/rtorrent.rc 2>/dev/null || true

if [ ! -f /config/rtorrent/rtorrent.rc ]; then
    echo "ERREUR: Impossible de creer rtorrent.rc"
    echo "Verifiez les permissions NFS sur le dossier partage"
    exit 1
fi

echo "  [OK] rtorrent.rc cree"

###########################################
# SCRIPTS DU DISQUE TEMPORAIRE
###########################################
# Generes a chaque demarrage (comme les configs) : pas de rebuild d'image
# pour les faire evoluer, il suffit de recreer le conteneur.

if [ "$TEMP_ENABLED" = "yes" ]; then
    echo "> Generation des scripts de deplacement..."

    # Client XML-RPC minimal vers rtorrent (protocole SCGI sur socket unix).
    # PHP est deja dans l'image pour ruTorrent : autant s'en servir.
    cat > /usr/local/bin/labobox-xmlrpc << 'XMLRPCEOF'
#!/usr/bin/php
<?php
// Usage: labobox-xmlrpc <methode> [param...]
// Envoie un appel XML-RPC a rtorrent via son socket SCGI.
$sock = '/var/run/rtorrent/scgi.socket';
$args = array_slice($argv, 1);
if (count($args) < 1) {
    fwrite(STDERR, "usage: labobox-xmlrpc <methode> [param...]\n");
    exit(2);
}
$method = array_shift($args);
$params = '';
foreach ($args as $a) {
    $params .= '<param><value><string>' . htmlspecialchars($a, ENT_XML1) . '</string></value></param>';
}
$xml = '<?xml version="1.0"?><methodCall><methodName>'
     . htmlspecialchars($method, ENT_XML1)
     . '</methodName><params>' . $params . '</params></methodCall>';
$headers = "CONTENT_LENGTH\x00" . strlen($xml) . "\x00SCGI\x001\x00";
$payload = strlen($headers) . ':' . $headers . ',' . $xml;
$fp = @stream_socket_client('unix://' . $sock, $errno, $errstr, 10);
if (!$fp) {
    fwrite(STDERR, "labobox-xmlrpc: connexion SCGI impossible: $errstr\n");
    exit(1);
}
fwrite($fp, $payload);
$resp = '';
while (!feof($fp)) {
    $resp .= fread($fp, 8192);
}
fclose($fp);
if (strpos($resp, '<fault>') !== false) {
    fwrite(STDERR, $resp . "\n");
    exit(1);
}
exit(0);
XMLRPCEOF
    chmod 755 /usr/local/bin/labobox-xmlrpc

    # Calcul du chemin SSD miroir : /data/torrents/films -> /temp/films.
    # Appele SYNCHRONE par rtorrent a l'ajout (execute.capture) : imprime le
    # chemin et cree le dossier a la volee. Toujours un chemin valide en sortie.
    cat > /usr/local/bin/labobox-ssdpath << 'SSDPATHEOF'
#!/bin/bash
# labobox-ssdpath <destination_finale>  ->  imprime le chemin SSD miroir
DEST="${1%/}"
case "$DEST" in
    /data/torrents/*) SSD="/temp/${DEST#/data/torrents/}" ;;
    /data/torrents)   SSD="/temp" ;;
    /data/*)          SSD="/temp/${DEST#/data/}" ;;
    *)                SSD="/temp/autres" ;;
esac
mkdir -p "$SSD" 2>/dev/null
printf '%s' "$SSD"
SSDPATHEOF
    chmod 755 /usr/local/bin/labobox-ssdpath

    # Garde-fou taille : lance en arriere-plan a l'ajout. Refuse (close+erase)
    # un torrent dont la taille totale depasse la limite. La limite est gelee
    # ici depuis RT_MAX_TORRENT_SIZE (0 = desactive).
    cat > /usr/local/bin/labobox-guard << GUARDEOF
#!/bin/bash
# labobox-guard <hash> <taille_octets>
HASH="\$1"
SIZE="\$2"
LIMIT="${RT_MAX_TORRENT_SIZE:-0}"
LOG="${LOG_PATH}/mover.log"
[ "\$LIMIT" = "0" ] && exit 0
# SIZE=0 : magnet sans metadata encore -> on ne bloque pas a ce stade.
[ "\$SIZE" -gt 0 ] 2>/dev/null || exit 0
if [ "\$SIZE" -gt "\$LIMIT" ] 2>/dev/null; then
    echo "\$(date '+%Y-%m-%d %H:%M:%S') [\$HASH] REFUSE: \$SIZE octets > limite \$LIMIT" >> "\$LOG"
    /usr/local/bin/labobox-xmlrpc d.close "\$HASH" 2>>"\$LOG"
    /usr/local/bin/labobox-xmlrpc d.erase "\$HASH" 2>>"\$LOG"
fi
exit 0
GUARDEOF
    chmod 755 /usr/local/bin/labobox-guard

    # Deplaceur : lance en arriere-plan a la completion, torrent TOUJOURS EN
    # SEED depuis le SSD. Copie SSD -> NAS (sequentiel, le cas ideal du NAS)
    # SANS interrompre le seed. Une fois la copie terminee seulement, bref
    # basculement via XML-RPC : stop -> close -> re-pointe -> start. A ce
    # moment les donnees sont deja a plat (le torrent seedait, rien a vider),
    # donc l'arret est de l'ordre de la milliseconde, quelle que soit la
    # taille du fichier. En cas d'echec de copie : le seed continue depuis le
    # SSD, rien n'est touche (aucune perte).
    cat > /usr/local/bin/labobox-mover << MOVEREOF
#!/bin/bash
# labobox-mover <hash> <chemin_donnees> <destination_finale>
HASH="\$1"
SRC="\$2"
DEST="\$3"
LOG="${LOG_PATH}/mover.log"

rpc() { /usr/local/bin/labobox-xmlrpc "\$@" 2>>"\$LOG"; }
log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') \$*" >> "\$LOG"; }

# Destination : celle choisie a l'ajout (custom labobox_dest).
# Vide ou hors /data (securite) -> /data/torrents/autres.
DEST="\${DEST%/}"
case "\$DEST" in
    /data/*) ;;
    *) DEST="/data/torrents/autres" ;;
esac

# Torrent d'avant l'activation du disque temporaire (donnees deja hors /temp) :
# rien a deplacer, il seede deja sur place -> on ne touche a rien.
case "\$SRC" in
    /temp/*) ;;
    *) exit 0 ;;
esac

BASE="\$(basename "\$SRC")"

if [ ! -e "\$SRC" ]; then
    log "[\$HASH] ERREUR: source absente (\$SRC) - seed inchange"
    exit 1
fi

# Emplacement final. Un torrent MULTI-FICHIERS possede un dossier racine (son
# nom) ; rtorrent avait deja ajoute ce nom a d.directory a l'ajout, donc
# labobox_dest vaut categorie/Nom. Copier la source DANS labobox_dest donnerait
# categorie/Nom/Nom/... (dossier en double). On retire donc le nom quand il est
# deja present : on copie au niveau de la CATEGORIE, comme un torrent normal
# (categorie/Nom/fichiers), a l'identique d'un download direct sur le NAS.
#  - CAT       : dossier categorie qui doit CONTENIR l'entree du torrent.
#  - FINAL_DIR : dossier que rtorrent doit pointer (d.directory).
if [ -d "\$SRC" ]; then
    if [ "\$(basename "\$DEST")" = "\$BASE" ]; then
        CAT="\$(dirname "\$DEST")"
    else
        CAT="\$DEST"
    fi
    FINAL_DIR="\$CAT/\$BASE"
else
    CAT="\$DEST"
    FINAL_DIR="\$CAT"
fi

mkdir -p "\$CAT"
log "[\$HASH] copie SSD -> NAS (seed en cours): \$SRC -> \$CAT/"

# Copie SSD -> NAS. On PRESERVE UNIQUEMENT LE MTIME :
#  - mtime preserve => le fast-resume de rtorrent valide (taille + mtime) et NE
#    re-hash PAS le torrent apres le deplacement (sinon il relit tout, inutile) ;
#  - on ne preserve NI le proprietaire (un chown echoue sur NFS en non-root) NI
#    le mode : les fichiers/dossiers crees heritent des droits et du GROUPE du
#    dossier parent sur le NAS (bit setgid du partage), exactement comme un
#    download direct -> proprietaire/groupe identiques aux autres torrents.
# cp GNU (coreutils) le fait via --preserve=timestamps. ATTENTION : sur Alpine,
# coreutils installe cp en /bin/cp (PAS /usr/bin/cp) -> on appelle « cp » via le
# PATH, jamais un chemin en dur (un /usr/bin/cp code en dur = "not found" =>
# copie ratee => fichier non deplace). A defaut de cp GNU : copie simple puis
# restauration des mtime avec touch -r (100% portable busybox).
# Mesure taille + duree pour le journal (taille lue sur la source SSD).
SIZE_KB=\$(du -sk "\$SRC" 2>/dev/null | awk '{print \$1}')
T0=\$(date +%s)
copy_ok=1
if cp --version 2>/dev/null | grep -qi coreutils; then
    cp -r --preserve=timestamps "\$SRC" "\$CAT/" 2>>"\$LOG" && copy_ok=0
elif cp -r "\$SRC" "\$CAT/" 2>>"\$LOG"; then
    if [ -d "\$SRC" ]; then
        ( cd "\$SRC" && find . -exec touch -r "{}" "\$CAT/\$BASE/{}" \; ) 2>>"\$LOG"
    else
        touch -r "\$SRC" "\$CAT/\$BASE" 2>>"\$LOG"
    fi
    copy_ok=0
fi
T1=\$(date +%s)
if [ "\$copy_ok" = 0 ]; then
    # Debit de la copie SSD -> NAS (temps de la copie seule, hors bascule RPC).
    # C'est le debit d'ECRITURE cote NAS (HDD via NFS), quasi toujours le
    # goulot ; la lecture depuis le SSD est bien plus rapide. Pour un bench
    # brut SSD vs NAS separement, voir le menu Benchmarks.
    ELAPSED=\$((T1 - T0)); [ "\$ELAPSED" -lt 1 ] && ELAPSED=1
    log "[\$HASH] copie SSD->NAS: \$(awk -v k="\$SIZE_KB" -v t="\$ELAPSED" 'BEGIN{gb=k/1048576;mb=k/1024;printf "%.2f Go en %ds (%.0f Mo/s ecriture NAS)", gb, t, mb/t}')"
    # Donnees a plat sur le NAS : bascule breve (torrent seedait -> rien a vider)
    rpc d.stop "\$HASH"
    rpc d.close "\$HASH"
    rpc d.directory.set "\$HASH" "\$FINAL_DIR"
    rpc d.start "\$HASH"
    rpc d.save_full_session "\$HASH"
    rm -rf "\$SRC"
    log "[\$HASH] OK: seed depuis \$CAT/\$BASE"
else
    # Copie partielle nettoyee ; le torrent continue de seeder depuis le SSD
    # (il n'a jamais ete stoppe) : aucune perte, on retentera au besoin.
    rm -rf "\${CAT:?}/\${BASE:?}" 2>/dev/null
    log "[\$HASH] ERREUR: copie vers le NAS echouee (place disque ? montage ?)"
    log "[\$HASH]         le torrent seede depuis le disque temporaire en attendant"
fi
exit 0
MOVEREOF
    chmod 755 /usr/local/bin/labobox-mover

    echo "  [OK] scripts installes : mover, xmlrpc, ssdpath, guard"
fi

###########################################
# GENERATION CONFIG RUTORRENT
###########################################
echo "> Generation de la config ruTorrent..."

if [ -n "$RU_DISABLED_PLUGINS" ]; then
    echo "  -> Suppression des plugins: $RU_DISABLED_PLUGINS"
    for plugin in $(echo "$RU_DISABLED_PLUGINS" | tr ',' ' '); do
        if [ -d "/var/www/rutorrent/plugins/$plugin" ]; then
            rm -rf "/var/www/rutorrent/plugins/$plugin"
            echo "    [OK] $plugin supprime"
        else
            echo "    [X] $plugin non trouve"
        fi
    done
fi

cat > /var/www/rutorrent/conf/config.php << 'PHPEOF'
<?php
// Configuration ruTorrent - Generee automatiquement

$httpUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';
$httpTimeOut = 30;
$httpUseGzip = true;

$rpcTimeOut = 15;
$rpcLogCalls = false;
$rpcLogFaults = true;

$phpUseGzip = false;
$phpGzipLevel = 2;

// Etalement des requetes periodiques des clients connectes.
// Avec plusieurs onglets ouverts, evite les rafales de XMLRPC simultanees.
$schedule_rand = 30;

$do_diagnostic = true;
$log_file = 'LOG_PATH_PLACEHOLDER/rutorrent.log';

$saveUploadedTorrents = true;
$overwriteUploadedTorrents = false;

// IMPORTANT: Restriction de navigation
$topDirectory = 'TOP_DIR_PLACEHOLDER';

$forbidUserSettings = false;

$scgi_port = 0;
$scgi_host = "unix:///var/run/rtorrent/scgi.socket";

$XMLRPCMountPoint = "/RPC2";

$pathToExternals = array(
    "php"       => '/usr/bin/php',
    "curl"      => '/usr/bin/curl',
    "gzip"      => '/usr/bin/gzip',
    "id"        => '/usr/bin/id',
    "stat"      => '/usr/bin/stat',
    "mediainfo" => '/usr/bin/mediainfo',
    "ffmpeg"    => '/usr/bin/ffmpeg',
);

$localhosts = array(
    "127.0.0.1",
    "localhost",
);

$profilePath = '/config/rutorrent';
$profileMask = 0777;
PHPEOF

sed -i "s|TOP_DIR_PLACEHOLDER|${TOP_DIR}|g" /var/www/rutorrent/conf/config.php
sed -i "s|LOG_PATH_PLACEHOLDER|${LOG_PATH}|g" /var/www/rutorrent/conf/config.php

mkdir -p "/config/rutorrent/users/${RU_USER}/torrents"
mkdir -p "/config/rutorrent/users/${RU_USER}/settings"

###########################################
# PATCH RUTORRENT POUR RTORRENT 0.16.x (i8/to_kb)
###########################################
# ruTorrent 5.2.10 envoie to_kb avec un seul argument, refuse par rtorrent
# compile avec le support i8 (entiers 64 bits). Le sed corrige la signature.
# (Devenu inutile en ruTorrent 5.3.x, mais on est en 5.2.10.) Sans effet si
# la ligne n'existe pas : pas d'echec.
if [ -f /var/www/rutorrent/php/settings.php ]; then
    sed -i 's/new rXMLRPCCommand("to_kb", floatval(1024))/new rXMLRPCCommand("to_kb", array("", floatval(1024)))/' /var/www/rutorrent/php/settings.php
    echo "> Patch rtorrent 0.16.x (to_kb) applique"
fi

###########################################
# CONFIGURATION NGINX
###########################################
echo "> Configuration nginx..."

cat > /etc/nginx/nginx.conf << 'EOF'
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /run/nginx/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    keepalive_timeout 65;
    client_max_body_size 128M;

    server {
        listen 8080;
        server_name _;

        root /var/www/rutorrent;
        index index.html index.php;

        # Authentification HTTP Basic
        auth_basic "ruTorrent";
        auth_basic_user_file /config/rutorrent/.htpasswd;

        location / {
            try_files $uri $uri/ =404;
        }

        location ~ \.php$ {
            fastcgi_pass unix:/run/php/php-fpm.sock;
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            include fastcgi_params;

            # Les appels XMLRPC vers rtorrent peuvent etre lents quand le
            # client est occupe : eviter les 504 dans l'interface.
            fastcgi_read_timeout 300;
            fastcgi_send_timeout 300;
        }

        location /RPC2 {
            include scgi_params;
            scgi_pass unix:/var/run/rtorrent/scgi.socket;
            scgi_read_timeout 300;
        }

        location ~ /\.ht {
            deny all;
        }
    }
}
EOF

###########################################
# CONFIGURATION PHP-FPM
###########################################
echo "> Configuration php-fpm..."

cat > /etc/php83/php-fpm.d/www.conf << EOF
[www]
user = rtorrent
group = rtorrent
listen = /run/php/php-fpm.sock
listen.owner = rtorrent
listen.group = rtorrent
listen.mode = 0660
pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 5
pm.max_requests = 500
EOF

# Limites d'upload PHP (defaut 2M/8M : trop bas pour les gros .torrent)
cat > /etc/php83/conf.d/99-uploads.ini << EOF
upload_max_filesize = 128M
post_max_size = 128M
memory_limit = 256M
max_execution_time = 300
max_input_time = 300
EOF

###########################################
# GENERATION .htpasswd
###########################################
echo "> Generation du fichier .htpasswd..."

HASH=$(openssl passwd -apr1 "$RU_PASSWORD")
echo "${RU_USER}:${HASH}" > /tmp/.htpasswd
cp /tmp/.htpasswd /config/rutorrent/.htpasswd
chmod 644 /config/rutorrent/.htpasswd 2>/dev/null || true

###########################################
# PERMISSIONS
###########################################
echo "> Application des permissions..."

# Permissions locales (hors NFS) : recursif sans risque, peu de fichiers.
chown -R rtorrent:rtorrent /var/www/rutorrent 2>/dev/null || true
chown -R rtorrent:rtorrent /var/run/rtorrent 2>/dev/null || true
chown -R rtorrent:rtorrent /run/php 2>/dev/null || true

if [ "$LOCAL_MOUNTED" = "yes" ]; then
    chown -R rtorrent:rtorrent /local 2>/dev/null || true
fi

# Disque temporaire : local (SSD), le chown recursif ne coute rien —
# et rtorrent doit pouvoir y ecrire avec le PUID du client.
if [ "$TEMP_ENABLED" = "yes" ]; then
    chown -R rtorrent:rtorrent /temp 2>/dev/null || true
fi

# ATTENTION : PAS de chmod -R sur /config ni /data.
# Un chmod recursif parcourt l'integralite de l'arbre via NFS : avec des
# dizaines de milliers de fichiers, c'est plusieurs minutes de martelage du
# NAS a CHAQUE demarrage de conteneur, pendant lesquelles rien d'autre
# n'avance. On ne touche que les points d'entree.
chmod 777 /config 2>/dev/null || true
chmod 777 /config/rtorrent 2>/dev/null || true
chmod 777 /config/rutorrent 2>/dev/null || true
chmod 777 /config/rutorrent/users 2>/dev/null || true
chmod 777 /data 2>/dev/null || true
chmod 777 /data/torrents /data/torrents/* 2>/dev/null || true
chmod 777 /data/watch /data/watch/* 2>/dev/null || true

# Reparation complete, uniquement sur demande explicite
if [ "$FIX_PERMS_RECURSIVE" = "yes" ]; then
    echo "  [!] FIX_PERMS_RECURSIVE=yes : chmod recursif en cours."
    echo "      Cela peut prendre plusieurs minutes et charger le NAS."
    chmod -R 777 /config 2>/dev/null || true
    chmod -R 777 /data 2>/dev/null || true
    echo "  [OK] Permissions reparees. Repassez la variable a 'no'."
fi

chmod 644 /config/rutorrent/.htpasswd 2>/dev/null || true
chmod 777 /var/run/rtorrent
chmod 777 /run/php

###########################################
# DEMARRAGE DES SERVICES
###########################################
echo "> Demarrage des services..."

# Supprimer le fichier lock s'il existe (crash precedent)
rm -f "${SESSION_PATH}/rtorrent.lock"

echo "  -> php-fpm..."
php-fpm83

echo "  -> nginx..."
nginx

echo "  -> rtorrent..."
su-exec rtorrent rtorrent -n -o import=/config/rtorrent/rtorrent.rc &
RTORRENT_PID=$!

###########################################
# VERIFICATION DU DEMARRAGE
###########################################
# rtorrent REFUSE de demarrer si une seule commande du .rc est inconnue,
# et le message part sur stderr avant que le log ne soit ouvert.
# Sans ce controle, le conteneur semble tourner alors que rtorrent est mort.

echo "> Verification du demarrage de rtorrent..."

RT_OK=0
for i in $(seq 1 20); do
    if [ -S /var/run/rtorrent/scgi.socket ]; then
        RT_OK=1
        break
    fi
    if ! kill -0 "$RTORRENT_PID" 2>/dev/null; then
        break
    fi
    sleep 1
done

if [ "$RT_OK" != "1" ]; then
    echo ""
    echo "################################################"
    echo "  ERREUR : rtorrent n'a pas demarre"
    echo "################################################"
    echo ""
    echo "Cause la plus probable : une commande du rtorrent.rc n'existe pas"
    echo "dans cette version de rtorrent. Le client refuse alors de demarrer."
    echo ""
    echo "Commandes a commenter en premier en cas de doute :"
    echo "  - trackers.numwant.set"
    echo "  - pieces.preload.min_size.set / pieces.preload.min_rate.set"
    echo "  - pieces.sync.always_safe.set"
    echo "  - schedule2 = session_save, ... ((session.save))"
    echo ""
    echo "Test manuel dans le conteneur :"
    echo "  su-exec rtorrent rtorrent -n -o import=/config/rtorrent/rtorrent.rc"
    echo ""
    tail -30 "${LOG_PATH}/rtorrent.log" 2>/dev/null || true
    exit 1
fi

chmod 777 /var/run/rtorrent/scgi.socket 2>/dev/null || true
chmod 777 /run/php/php-fpm.sock 2>/dev/null || true

echo ""
echo "================================================"
echo "  RTORRENT + RUTORRENT DEMARRE !"
echo "================================================"
echo "  WebUI       : http://IP:8080"
echo "  User        : $RU_USER"
echo "  Top Dir     : $TOP_DIR"
echo "  RT Port     : $RT_PORT"
echo "  Session     : $SESSION_PATH"
echo "  Logs        : $LOG_PATH"
echo "  Temp DL     : $TEMP_ENABLED"
echo "  Open files  : $RT_MAX_OPEN_FILES / sockets : $RT_MAX_OPEN_SOCKETS"
echo "  Peers seed  : $RT_MIN_PEERS_SEED-$RT_MAX_PEERS_SEED"
echo "  Slots       : U $RT_MAX_UPLOADS_GLOBAL / D $RT_MAX_DOWNLOADS_GLOBAL"
echo "  Rehash fin  : $RT_CHECK_HASH"
echo "================================================"
echo ""

# Garder le conteneur en vie et afficher les logs
tail -f "${LOG_PATH}/rtorrent.log" 2>/dev/null || tail -f /var/log/nginx/access.log