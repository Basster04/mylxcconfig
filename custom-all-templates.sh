#!/usr/bin/env bash
# vim: set ft=sh:

# Script personnalisé pour créer des conteneurs LXC Proxmox
# Basé sur les scripts community-scripts/ProxmoxVE avec modifications spécifiques :
# - Sélection automatique du stockage 'local-lvm' si disponible
# - Bouton <Retour> ajouté (fonctionne comme Annuler pour l'instant)
# - Mise à jour systématique du LXC après création (apt)
# - Installation de paquets depuis une URL externe après mise à jour (apt)
# - Configuration automatique de montages virtiofs (Echanges_PVE1, Echanges_PVE2)
# - **Correction de l'extraction du nom de template (awk print $2)**

# --- Configuration ---
# URL pour la liste des paquets personnalisés à installer
PACKAGE_URL="https://raw.githubusercontent.com/Basster04/mylxcconfig/refs/heads/main/lxc-packages.txt"
# Tags et points de montage internes pour VirtioFS
MOUNT_TAG1="Echanges_PVE1"
MOUNT_POINT_INTERNAL1="/mnt/pve_echanges1"
MOUNT_TAG2="Echanges_PVE2"
MOUNT_POINT_INTERNAL2="/mnt/pve_echanges2"
MP_INDEX1=99 # Index de point de montage Proxmox (utiliser des numéros hauts pour éviter conflits)
MP_INDEX2=98

# --- Couleurs et Fonctions Helper ---
YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
BGN=$(echo "\033[4;92m")
GN=$(echo "\033[1;92m")
DGN=$(echo "\033[32m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

# Fonction pour afficher des messages d'information
msg_info() {
    echo -e "${BL}❯ $1${CL}"
}

# Fonction pour afficher des messages de succès
msg_ok() {
    echo -e "${GN}✓ $1${CL}"
}

# Fonction pour afficher des messages d'avertissement
msg_warn() {
    echo -e "${YW}⚠ $1${CL}"
}

# Fonction pour afficher des messages d'erreur et quitter
msg_error() {
    echo -e "${RD}✗ $1${CL}" >&2
    # Nettoyage éventuel avant de quitter
    # rm -f $TMP_PACKAGES_FILE &>/dev/null
    exit 1
}

# --- Vérification des dépendances ---
check_dependencies() {
    local missed=""
    for cmd in curl whiptail pveam pct pvesm awk grep sed head cut paste mktemp; do
        if ! command -v $cmd &> /dev/null; then
            missed+=" $cmd"
        fi
    done
    if [[ -n "$missed" ]]; then
       msg_error "Dépendances manquantes :$missed. Veuillez les installer."
       exit 1
    fi
    msg_ok "Toutes les dépendances nécessaires sont présentes."
}

# --- Fonctions Whiptail avec bouton Retour ---
run_whiptail() {
    local type="$1"
    local title="$2"
    local text="$3"
    local height="$4"
    local width="$5"
    shift 5
    local var_name=""
    local args=()
    local default_val=""

    if [[ "$type" == "--inputbox" || "$type" == "--passwordbox" ]]; then
        if [[ $# -gt 0 && "$1" != "--variable" ]]; then
            default_val="$1"
            shift
        fi
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --variable)
                if [[ -z "$2" ]]; then
                   echo "Erreur interne: --variable nécessite un argument" >&2
                   exit 1
                fi
                var_name="$2"
                shift 2
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    local result
    local status

    while true; do
        if [[ "$type" == "--inputbox" ]]; then
           result=$(whiptail --title "$title" "$type" "$text" "$height" "$width" "$default_val" "${args[@]}" \
                --ok-button "OK" --cancel-button "Annuler" --extra-button --extra-label "Retour" \
                3>&1 1>&2 2>&3)
        elif [[ "$type" == "--passwordbox" ]]; then
           result=$(whiptail --title "$title" "$type" "$text" "$height" "$width" "$default_val" "${args[@]}" \
                --ok-button "OK" --cancel-button "Annuler" --extra-button --extra-label "Retour" \
                3>&1 1>&2 2>&3)
        else # Pour --menu, --yesno etc.
           result=$(whiptail --title "$title" "$type" "$text" "$height" "$width" "${args[@]}" \
                --ok-button "OK" --cancel-button "Annuler" --extra-button --extra-label "Retour" \
                3>&1 1>&2 2>&3)
        fi
        status=$?

        case $status in
            0) # OK
               if [[ "$type" == "--passwordbox" ]] && [[ -z "$result" ]]; then
                  whiptail --msgbox "Le mot de passe ne peut pas être vide." 8 40
                  continue
               elif [[ "$type" == "--inputbox" ]] && [[ -z "$result" ]]; then
                  whiptail --msgbox "L'entrée ne peut pas être vide." 8 40
                  continue
               fi
               if [[ -n "$var_name" ]]; then
                   printf -v "$var_name" '%s' "$result"
               fi
               return 0
               ;;
            1) # Annuler
               msg_error "Opération annulée par l'utilisateur."
               ;;
            3) # Retour
               msg_warn "Fonctionnalité 'Retour' sélectionnée. Opération annulée."
               exit 1
               ;;
            *) # Echap ou autre erreur
               msg_error "Erreur Whiptail (Code: $status) ou Echap pressé. Abandon."
               ;;
        esac
    done
}

# --- Début du Script ---
trap 'echo -e "${RD}Interruption détectée. Nettoyage et sortie...${CL}"; exit 1' SIGINT SIGTERM

msg_info "Début du script de création de conteneur LXC personnalisé."
check_dependencies

# Mise à jour de la liste des templates
msg_info "Mise à jour de la liste des templates disponibles via 'pveam update'..."
if pveam update >/dev/null; then
    msg_ok "Liste des templates mise à jour."
else
    if ! pveam update; then
        msg_error "Impossible de mettre à jour la liste des templates. Vérifiez la configuration réseau/PVE et la sortie ci-dessus."
    else
       msg_ok "Liste des templates mise à jour (2ème tentative)."
    fi
fi

# Sélection du Template LXC
msg_info "Récupération des templates LXC 'system' disponibles..."
# !!! CORRECTION ICI: Utilisation de {print $2} au lieu de {print $1} !!!
mapfile -t TEMPLATES < <(pveam available --section system | awk 'NR > 1 {print $2}' | grep -v 'turnkeylinux')

if [ ${#TEMPLATES[@]} -eq 0 ]; then
    msg_error "Aucun template LXC système trouvé (après filtrage éventuel). Exécutez 'pveam update' ou vérifiez la source."
fi

TEMPLATE_MENU=()
for template in "${TEMPLATES[@]}"; do
    if [[ -n "$template" ]]; then
        # Utiliser le nom du template comme tag ET comme description (item) pour whiptail
        TEMPLATE_MENU+=("$template" "$template")
    fi
done

if [ ${#TEMPLATE_MENU[@]} -eq 0 ]; then
    msg_error "Impossible de construire le menu des templates (liste vide ou invalide après traitement)."
fi

# Le bloc de débogage est conservé mais commenté pour le moment.
# Décommentez-le si le problème persiste après la correction.
# # --- !!! DEBUG INTENSIF AVANT L'APPEL WHIPTAIL !!! ---
# echo -e "\n${YW}--- DEBUG INFO: Menu Template LXC ---${CL}"
# echo "Nombre de templates bruts trouvés: ${#TEMPLATES[@]}"
# echo "Nombre d'éléments dans TEMPLATE_MENU (devrait être le double): ${#TEMPLATE_MENU[@]}"
# echo -e "\n${YW}Contenu COMPLET de TEMPLATE_MENU (chaque élément sur une nouvelle ligne):${CL}"
# printf "ELEMENT: '%s'\n" "${TEMPLATE_MENU[@]}"
# echo -e "\n${YW}Commande whiptail qui SERAIT exécutée par run_whiptail:${CL}"
# echo "whiptail --title \"Sélection du Template LXC\" --menu \"Choisissez le template LXC à utiliser:\" 20 70 12 "
# printf "'%s' '%s' " "${TEMPLATE_MENU[@]}"
# echo "--ok-button \"OK\" --cancel-button \"Annuler\" --extra-button --extra-label \"Retour\" 3>&1 1>&2 2>&3"
# echo -e "\n${YW}Test DIRECT de whiptail --menu simple:${CL}"
# TEST_MENU=("item1" "Description 1" "item2" "Description 2")
# if whiptail --title "Test Menu Simple" --menu "Est-ce que ce menu s'affiche ?" 15 60 5 "${TEST_MENU[@]}" 3>&1 1>&2 2>&3; then
#     echo -e "${GN}Succès : Whiptail --menu simple a fonctionné.${CL}"
# else
#     local whiptail_simple_exit_code=$?
#     echo -e "${RD}ÉCHEC : Whiptail --menu simple a échoué (Code retour: $whiptail_simple_exit_code). Problème avec whiptail/terminal ?${CL}"
# fi
# echo -e "\n${YW}--- FIN DEBUG INFO ---${CL}"
# read -p "Appuyez sur Entrée pour continuer et tenter d'afficher le VRAI menu des templates via run_whiptail..." ENTER_KEY
# # --- FIN DU DEBUG INTENSIF ---

SELECTED_TEMPLATE="" # Initialiser la variable
msg_info "Tentative d'affichage du menu des templates via run_whiptail..."
# Note: Utilisation de TEMPLATE_MENU qui contient maintenant 'nom_template' 'nom_template'
run_whiptail --menu "Sélection du Template LXC" "Choisissez le template LXC à utiliser:" 20 70 12 "${TEMPLATE_MENU[@]}" --variable SELECTED_TEMPLATE
msg_ok "Template sélectionné : $SELECTED_TEMPLATE"


# Sélection du Stockage (avec auto-sélection de local-lvm)
msg_info "Vérification des pools de stockage disponibles pour les images de conteneur..."
STORAGE=""
if pvesm status --storage local-lvm --content images >/dev/null 2>&1; then
    STORAGE="local-lvm"
    msg_ok "Stockage 'local-lvm' détecté et automatiquement sélectionné."
else
    msg_warn "Stockage 'local-lvm' non trouvé ou invalide pour les images. Sélection manuelle requise."
    mapfile -t STORAGE_POOLS < <(pvesm status --content images | awk 'NR>1 {print $1}')
    if [ ${#STORAGE_POOLS[@]} -eq 0 ]; then
        msg_error "Aucun pool de stockage valide pour les images de conteneur n'a été trouvé!"
    fi
    STORAGE_MENU=()
    for pool in "${STORAGE_POOLS[@]}"; do
        if [[ -n "$pool" ]]; then
            STORAGE_MENU+=("$pool" "") # Pour le stockage, le nom suffit comme tag, description vide ok.
        fi
    done
     if [ ${#STORAGE_MENU[@]} -eq 0 ]; then
        msg_error "Impossible de construire le menu des stockages."
     fi

    run_whiptail --menu "Sélection du Pool de Stockage" "Choisissez le pool de stockage pour le conteneur:" 15 60 5 "${STORAGE_MENU[@]}" --variable STORAGE
    msg_ok "Stockage sélectionné : $STORAGE"
fi

# Téléchargement du template (si nécessaire)
msg_info "Vérification si le template '$SELECTED_TEMPLATE' est déjà téléchargé sur '$STORAGE'..."
# Échapper les points dans le nom du template pour grep
escaped_template=$(sed 's/[.]/\\./g' <<< "$SELECTED_TEMPLATE")
if ! pveam list "$STORAGE" | grep -q "^${escaped_template}\$"; then
    msg_info "Template non trouvé localement. Téléchargement en cours (peut prendre du temps)..."
    if pveam download "$STORAGE" "$SELECTED_TEMPLATE"; then
        msg_ok "Template '$SELECTED_TEMPLATE' téléchargé avec succès sur '$STORAGE'."
    else
        msg_error "Échec du téléchargement du template '$SELECTED_TEMPLATE'."
    fi
else
    msg_ok "Template '$SELECTED_TEMPLATE' déjà disponible sur '$STORAGE'."
fi
TEMPLATE_PATH="$STORAGE:vztmpl/$SELECTED_TEMPLATE"

# Obtenir le prochain ID de CT disponible
msg_info "Recherche du prochain ID de conteneur disponible..."
CTID=$(pvesh get /cluster/nextid)
if ! [[ "$CTID" =~ ^[0-9]+$ ]]; then
    msg_error "Impossible d'obtenir un ID de conteneur valide. Vérifiez la configuration PVE."
fi
msg_ok "Utilisation de l'ID de conteneur : $CTID"

# Configuration du Conteneur
msg_info "Configuration des paramètres du conteneur..."
CT_HOSTNAME=""
CT_PASSWORD=""
CT_CPUS=2
CT_RAM=2048
CT_DISK_SIZE=8
CT_BRIDGE="vmbr0"
CT_IP_MODE="dhcp"
CT_IP_ADDR=""
CT_GATEWAY=""
CT_UNPRIVILEGED=1
CT_NESTING=1

run_whiptail --inputbox "Nom d'hôte" "Entrez le nom d'hôte du conteneur (ex: mon-lxc):" 10 60 "" --variable CT_HOSTNAME
msg_ok "Nom d'hôte défini : $CT_HOSTNAME"
run_whiptail --passwordbox "Mot de Passe Root" "Entrez le mot de passe pour l'utilisateur root:" 10 60 "" --variable CT_PASSWORD
msg_ok "Mot de passe root défini (ne sera pas affiché)."

# Création du Conteneur
msg_info "Création du conteneur LXC $CTID ($CT_HOSTNAME)..."
cmd_create=(pct create "$CTID" "$TEMPLATE_PATH" \
    --hostname "$CT_HOSTNAME" \
    --storage "$STORAGE" \
    --cores "$CT_CPUS" \
    --memory "$CT_RAM" \
    --swap 0 \
    --rootfs "${STORAGE}:${CT_DISK_SIZE}" \
    --password "$CT_PASSWORD" \
    --onboot 1)

features=""
if [ "$CT_UNPRIVILEGED" -eq 1 ]; then cmd_create+=(--unprivileged 1); features+="unprivileged,"; fi
if [ "$CT_NESTING" -eq 1 ]; then features+="nesting,"; fi
if [ "$CT_UNPRIVILEGED" -eq 1 ]; then features+="keyctl,"; fi
if [ -n "$features" ]; then cmd_create+=(--features "${features%,}"); fi

if [ "$CT_IP_MODE" == "dhcp" ]; then
    cmd_create+=(--net0 "name=eth0,bridge=$CT_BRIDGE,ip=dhcp")
else
    cmd_create+=(--net0 "name=eth0,bridge=$CT_BRIDGE,ip=$CT_IP_ADDR,gw=$CT_GATEWAY")
fi

msg_info "Exécution: ${cmd_create[*]}"
if ! "${cmd_create[@]}"; then
    msg_error "Échec de la création du conteneur $CTID. Vérifiez la commande et les logs PVE."
fi
msg_ok "Conteneur LXC $CTID créé avec succès."

# Démarrage du conteneur
msg_info "Démarrage du conteneur $CTID..."
if ! pct start "$CTID"; then
    sleep 5
    if ! pct start "$CTID"; then
       msg_error "Impossible de démarrer le conteneur $CTID. Vérifiez la configuration et les logs."
    fi
fi
msg_ok "Conteneur $CTID démarré."

# Attendre l'IP et la récupérer
msg_info "Attente de l'adresse IP du conteneur via 'pct exec' (max 60 secondes)..."
CT_IP=""
for i in {1..30}; do
    CT_IP=$(pct exec $CTID -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
    if [ -n "$CT_IP" ]; then
        msg_ok "Adresse IP obtenue : $CT_IP"
        break
    fi
    echo -n "."
    sleep 2
done
echo

if [ -z "$CT_IP" ]; then
    msg_warn "Impossible de récupérer l'adresse IP du conteneur via 'pct exec'."
    msg_warn "Tentative via 'pct guest ip $CTID'..."
    CT_IP=$(pct guest ip $CTID 2>/dev/null | grep -oP '\d+(\.\d+){3}')
     if [ -n "$CT_IP" ]; then
        msg_ok "Adresse IP obtenue via 'pct guest ip': $CT_IP"
     else
        msg_warn "Échec de la récupération de l'IP. La mise à jour et l'installation des paquets risquent d'échouer."
     fi
fi

# Fonction pour exécuter une commande dans le CT avec gestion d'erreur
run_in_ct() {
    local ct_id="$1"
    shift
    local cmd_desc="$1"
    shift
    msg_info "Exécution dans CT $ct_id: $cmd_desc..."
    if ! pct exec "$ct_id" -- "$@"; then
        msg_error "Échec de l'exécution '$cmd_desc' dans le conteneur $ct_id."
        return 1
    fi
    msg_ok "$cmd_desc terminé avec succès."
    return 0
}

# Mise à jour du système dans le conteneur
msg_info "Vérification de la présence de 'apt-get' dans le conteneur..."
if pct exec $CTID -- command -v apt-get >/dev/null 2>&1; then
    msg_ok "'apt-get' trouvé. Procédure de mise à jour APT lancée."
    run_in_ct $CTID "apt-get update" apt-get update -y
    run_in_ct $CTID "apt-get upgrade" env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
else
    msg_warn "Gestionnaire de paquets 'apt-get' non trouvé. La mise à jour automatique est ignorée."
fi

# Installation des paquets personnalisés
msg_info "Tentative d'installation des paquets personnalisés depuis $PACKAGE_URL..."
TMP_PACKAGES_FILE=$(mktemp)
if curl -fsSL --connect-timeout 10 -m 30 "$PACKAGE_URL" -o "$TMP_PACKAGES_FILE"; then
    PACKAGES_TO_INSTALL=$(grep -vE '^\s*#|^\s*$' "$TMP_PACKAGES_FILE" | sed 's/#.*//; s/^[ \t]*//; s/[ \t]*$//' | awk 'NF > 0' | paste -sd ' ')
    rm "$TMP_PACKAGES_FILE"

    if [ -n "$PACKAGES_TO_INSTALL" ]; then
        msg_info "Paquets à installer : $PACKAGES_TO_INSTALL"
        if pct exec $CTID -- command -v apt-get >/dev/null 2>&1; then
             run_in_ct $CTID "apt-get install ${PACKAGES_TO_INSTALL}" env DEBIAN_FRONTEND=noninteractive apt-get install -y $PACKAGES_TO_INSTALL
        else
            msg_warn "Gestionnaire de paquets 'apt-get' non trouvé. L'installation des paquets personnalisés est ignorée."
        fi
    else
        msg_ok "Aucun paquet valide trouvé dans le fichier $PACKAGE_URL ou fichier vide."
    fi
else
    local curl_exit_code=$?
    msg_error "Impossible de télécharger la liste des paquets depuis $PACKAGE_URL (curl exit code: $curl_exit_code)."
    rm "$TMP_PACKAGES_FILE"
fi

# Configuration des montages VirtioFS
msg_info "Configuration des points de montage virtiofs pour $MOUNT_TAG1 et $MOUNT_TAG2..."
if run_in_ct $CTID "Création répertoire $MOUNT_POINT_INTERNAL1" mkdir -p "$MOUNT_POINT_INTERNAL1" && \
   run_in_ct $CTID "Création répertoire $MOUNT_POINT_INTERNAL2" mkdir -p "$MOUNT_POINT_INTERNAL2"; then

    msg_info "Application de la configuration via 'pct set'..."
    if pct set $CTID -mp${MP_INDEX1} ${MOUNT_TAG1},mp=${MOUNT_POINT_INTERNAL1},ro=0 && \
       pct set $CTID -mp${MP_INDEX2} ${MOUNT_TAG2},mp=${MOUNT_POINT_INTERNAL2},ro=0; then
        msg_ok "Points de montage virtiofs configurés dans PVE pour le conteneur $CTID."
        msg_warn "Un redémarrage du conteneur ('pct stop $CTID && pct start $CTID') est nécessaire pour activer ces montages."

        if whiptail --yesno "Voulez-vous redémarrer le conteneur $CTID maintenant pour activer les montages virtiofs ?" 10 70 --defaultno 3>&1 1>&2 2>&3; then
             msg_info "Redémarrage du conteneur $CTID..."
             if pct stop "$CTID"; then
                sleep 2
                if pct start "$CTID"; then
                   msg_ok "Conteneur redémarré."
                   sleep 5
                   CT_IP=$(pct exec $CTID -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1) || CT_IP="Non récupérée après redémarrage"
                else
                   msg_warn "Échec du démarrage ('pct start') après l'arrêt. Vérifiez l'état du conteneur."
                fi
             else
                 msg_warn "Échec de l'arrêt ('pct stop') du conteneur $CTID. Redémarrage annulé."
             fi
        else
            msg_info "Redémarrage non effectué. Faites-le manuellement pour activer les montages."
        fi
    else
        msg_warn "Échec de la configuration des points de montage virtiofs via 'pct set'. Vérifiez les index mp et les tags."
    fi
else
    msg_warn "Échec de la création des répertoires de montage dans le LXC $CTID. Les montages virtiofs ne seront pas configurés."
fi

# --- Résumé Final ---
echo -e "${GN}--- Création du conteneur terminée ---${CL}"
echo -e "${BL}ID du Conteneur :${CL} $CTID"
echo -e "${BL}Nom d'hôte      :${CL} $CT_HOSTNAME"
echo -e "${BL}Template utilisé:${CL} $SELECTED_TEMPLATE"
echo -e "${BL}Stockage        :${CL} $STORAGE"
echo -e "${BL}Adresse IP      :${CL} ${CT_IP:-"Non disponible / DHCP"}"
echo -e "${BL}Privilégié      :${CL} $( [ "$CT_UNPRIVILEGED" -eq 0 ] && echo "Oui" || echo "Non (Recommandé)" )"
echo -e "${BL}Nesting         :${CL} $( [ "$CT_NESTING" -eq 1 ] && echo "Activé" || echo "Désactivé" )"
echo -e "${BL}Utilisateur Root  :${CL} root"
echo -e "${BL}Mot de Passe Root:${CL} (Celui que vous avez défini)"
echo -e "${BL}Montages VirtioFS:${CL}"
echo -e "  - Hôte: ${MOUNT_TAG1} -> Conteneur: ${MOUNT_POINT_INTERNAL1} (Index ${MP_INDEX1})"
echo -e "  - Hôte: ${MOUNT_TAG2} -> Conteneur: ${MOUNT_POINT_INTERNAL2} (Index ${MP_INDEX2})"
echo -e "  ${YW}(Nécessite un redémarrage du conteneur s'il n'a pas été fait)${CL}"
echo -e "${GN}---------------------------------------${CL}"
msg_ok "Script terminé."

exit 0
