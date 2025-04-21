#!/usr/bin/env bash

# Script personnalisé pour créer des conteneurs LXC Proxmox
# Basé sur les scripts community-scripts/ProxmoxVE avec modifications spécifiques :
# - Sélection automatique du stockage 'local-lvm' si disponible
# - Bouton <Retour> ajouté (fonctionne comme Annuler pour l'instant)
# - Mise à jour systématique du LXC après création (apt)
# - Installation de paquets depuis une URL externe après mise à jour (apt)
# - Configuration automatique de montages virtiofs (Echanges_PVE1, Echanges_PVE2)

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
    exit 1
}

# --- Vérification des dépendances ---
for cmd in curl whiptail pveam pct pvesm; do
    if ! command -v $cmd &> /dev/null; then
        msg_error "La commande '$cmd' est requise mais n'est pas installée. Veuillez l'installer."
    fi
done

# --- Fonctions Whiptail avec bouton Retour ---
# Modifie un appel whiptail pour ajouter le bouton Retour et gérer sa sortie (comme Annuler)
# Usage: run_whiptail TYPE "Titre" "Texte" HAUTEUR LARGEUR [OPTIONS_SPECIFIQUES...] --variable VAR_NAME
# Ex: run_whiptail --inputbox "Hostname" "Entrez le nom d'hôte:" 10 60 --variable CT_HOSTNAME
run_whiptail() {
    local type="$1"
    local title="$2"
    local text="$3"
    local height="$4"
    local width="$5"
    shift 5
    local var_name=""
    local args=()
    # Séparer les options whiptail de --variable
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --variable)
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
        result=$(whiptail "$type" "$title" "$text" "$height" "$width" "${args[@]}" \
            --ok-button "OK" \
            --cancel-button "Annuler" \
            --extra-button \
            --extra-label "Retour" \
            3>&1 1>&2 2>&3)
        status=$?

        case $status in
            0) # OK
               if [[ "$type" == "--passwordbox" ]] && [[ -z "$result" ]]; then
                  whiptail --msgbox "Le mot de passe ne peut pas être vide." 8 40
                  continue # Redemander
               elif [[ "$type" == "--inputbox" ]] && [[ -z "$result" ]]; then
                  whiptail --msgbox "L'entrée ne peut pas être vide." 8 40
                  continue # Redemander
               fi
               # Si --variable est spécifié, assigner la valeur
               if [[ -n "$var_name" ]]; then
                   printf -v "$var_name" '%s' "$result"
               else
                    # Si pas de variable, juste retourner 0 (succès)
                    return 0
               fi
               msg_ok "Sélection/Entrée acceptée."
               return 0 # Succès
               ;;
            1) # Annuler
               msg_error "Opération annulée par l'utilisateur."
               # La fonction msg_error quitte le script
               ;;
            3) # Retour (traité comme Annuler pour l'instant)
               msg_warn "Fonctionnalité 'Retour' sélectionnée. Opération annulée."
               exit 1 # Quitter le script
               ;;
            *) # Echap ou autre erreur
               msg_error "Erreur Whiptail ou Echap pressé. Abandon."
               # La fonction msg_error quitte le script
               ;;
        esac
    done
}

# --- Début du Script ---
msg_info "Début du script de création de conteneur LXC personnalisé."

# Mise à jour de la liste des templates
msg_info "Mise à jour de la liste des templates disponibles..."
if pveam update; then
    msg_ok "Liste des templates mise à jour."
else
    msg_error "Impossible de mettre à jour la liste des templates. Vérifiez la configuration réseau et PVE."
fi

# Sélection du Template LXC
msg_info "Récupération des templates LXC disponibles..."
mapfile -t TEMPLATES < <(pveam available --section system | awk 'NR>1 {print $1}')
if [ ${#TEMPLATES[@]} -eq 0 ]; then
    msg_error "Aucun template LXC système trouvé. Exécutez 'pveam update'."
fi

TEMPLATE_MENU=()
for template in "${TEMPLATES[@]}"; do
    TEMPLATE_MENU+=("$template" "")
done

run_whiptail --menu "Sélection du Template LXC" "Choisissez le template LXC à utiliser:" 20 70 12 "${TEMPLATE_MENU[@]}" --variable SELECTED_TEMPLATE
# SELECTED_TEMPLATE est défini par run_whiptail

# Sélection du Stockage (avec auto-sélection de local-lvm)
msg_info "Vérification des pools de stockage disponibles..."
STORAGE=""
# Vérifier si local-lvm existe et supporte les images de conteneur
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
        STORAGE_MENU+=("$pool" "")
    done
    run_whiptail --menu "Sélection du Pool de Stockage" "Choisissez le pool de stockage pour le conteneur:" 15 60 5 "${STORAGE_MENU[@]}" --variable STORAGE
    # STORAGE est défini par run_whiptail
fi

# Téléchargement du template (si nécessaire)
msg_info "Vérification si le template '$SELECTED_TEMPLATE' est déjà téléchargé sur '$STORAGE'..."
if ! pveam list "$STORAGE" | grep -q "$SELECTED_TEMPLATE"; then
    msg_info "Template non trouvé. Téléchargement en cours..."
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
msg_ok "Utilisation de l'ID de conteneur : $CTID"

# Configuration du Conteneur
msg_info "Configuration des paramètres du conteneur..."
CT_HOSTNAME=""
CT_PASSWORD=""
CT_CPUS=2
CT_RAM=2048 # Mo
CT_DISK_SIZE=8 # Go
CT_BRIDGE="vmbr0" # Pont réseau par défaut, à adapter si besoin
CT_IP_MODE="dhcp" # ou "static"
CT_IP_ADDR="" # ex: 192.168.1.100/24
CT_GATEWAY="" # ex: 192.168.1.1

# Demander le nom d'hôte
run_whiptail --inputbox "Nom d'hôte" "Entrez le nom d'hôte du conteneur (ex: mon-lxc):" 10 60 --variable CT_HOSTNAME

# Demander le mot de passe root
run_whiptail --passwordbox "Mot de Passe Root" "Entrez le mot de passe pour l'utilisateur root:" 10 60 --variable CT_PASSWORD

# --- Ici, on pourrait ajouter d'autres questions pour CPU, RAM, Disque, Réseau si besoin ---
# Exemple pour le réseau statique (à décommenter et adapter si besoin)
# if run_whiptail --yesno "Configuration Réseau" "Voulez-vous configurer une adresse IP statique ?" 10 60; then
#     CT_IP_MODE="static"
#     run_whiptail --inputbox "Adresse IP Statique" "Entrez l'adresse IP et le masque CIDR (ex: 192.168.1.100/24):" 10 60 --variable CT_IP_ADDR
#     run_whiptail --inputbox "Passerelle" "Entrez l'adresse IP de la passerelle (ex: 192.168.1.1):" 10 60 --variable CT_GATEWAY
# else
#     CT_IP_MODE="dhcp"
# fi

# Création du Conteneur
msg_info "Création du conteneur LXC $CTID ($CT_HOSTNAME)..."
pct create $CTID "$TEMPLATE_PATH" \
    --hostname "$CT_HOSTNAME" \
    --storage "$STORAGE" \
    --cores $CT_CPUS \
    --memory $CT_RAM \
    --swap 0 \
    --rootfs "${STORAGE}:${CT_DISK_SIZE}" \
    --password "$CT_PASSWORD" \
    --onboot 1 \
    --features nesting=1 # Activer nesting (utile pour Docker etc.)
    # Ajouter --unprivileged 1 si vous voulez un conteneur non privilégié (recommandé)
    # --unprivileged 1 \

if [ $? -ne 0 ]; then
    msg_error "Échec de la création du conteneur $CTID."
fi

# Configuration réseau
msg_info "Configuration du réseau..."
if [ "$CT_IP_MODE" == "dhcp" ]; then
    pct set $CTID --net0 name=eth0,bridge=$CT_BRIDGE,ip=dhcp
else
    pct set $CTID --net0 name=eth0,bridge=$CT_BRIDGE,ip=$CT_IP_ADDR,gw=$CT_GATEWAY
fi
if [ $? -ne 0 ]; then
    msg_error "Échec de la configuration réseau pour le conteneur $CTID."
fi

msg_ok "Conteneur LXC $CTID créé avec succès."

# Démarrage du conteneur
msg_info "Démarrage du conteneur $CTID..."
if ! pct start $CTID; then
    msg_error "Impossible de démarrer le conteneur $CTID."
fi
msg_ok "Conteneur $CTID démarré."

# Attendre l'IP et la récupérer
msg_info "Attente de l'adresse IP du conteneur (max 30 secondes)..."
CT_IP=""
for i in {1..15}; do
    CT_IP=$(pct exec $CTID -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
    if [ -n "$CT_IP" ]; then
        msg_ok "Adresse IP obtenue : $CT_IP"
        break
    fi
    sleep 2
done

if [ -z "$CT_IP" ]; then
    msg_warn "Impossible de récupérer l'adresse IP du conteneur automatiquement."
    msg_warn "La mise à jour et l'installation des paquets risquent d'échouer."
    # On continue quand même, mais l'utilisateur est prévenu.
fi

# Mise à jour du système dans le conteneur
msg_info "Tentative de mise à jour du système dans le conteneur $CTID (apt update && apt upgrade)..."
# Vérifier si apt-get existe
if pct exec $CTID -- command -v apt-get >/dev/null 2>&1; then
    if pct exec $CTID -- apt-get update && pct exec $CTID -- env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade; then
        msg_ok "Mise à jour du système (apt) terminée avec succès dans le conteneur $CTID."
    else
        msg_error "Échec de la mise à jour (apt) du conteneur $CTID. Vérifiez la connectivité réseau interne et les logs."
        # Note: msg_error quitte le script ici. Ajuster si on veut continuer malgré l'échec.
    fi
else
    msg_warn "Gestionnaire de paquets 'apt-get' non trouvé. La mise à jour automatique est ignorée."
fi

# Installation des paquets personnalisés
msg_info "Tentative d'installation des paquets personnalisés depuis $PACKAGE_URL..."
TMP_PACKAGES_FILE=$(mktemp)
if curl -fsSL "$PACKAGE_URL" -o "$TMP_PACKAGES_FILE"; then
    # Lire les paquets, ignorer commentaires/vides, joindre avec espaces
    PACKAGES_TO_INSTALL=$(grep -vE '^\s*#|^\s*$' "$TMP_PACKAGES_FILE" | paste -sd ' ')
    rm "$TMP_PACKAGES_FILE" # Nettoyer le fichier temporaire

    if [ -n "$PACKAGES_TO_INSTALL" ]; then
        msg_info "Paquets à installer : $PACKAGES_TO_INSTALL"
        # Utiliser apt si disponible
        if pct exec $CTID -- command -v apt-get >/dev/null 2>&1; then
            if pct exec $CTID -- env DEBIAN_FRONTEND=noninteractive apt-get install -y $PACKAGES_TO_INSTALL; then
                msg_ok "Paquets personnalisés installés avec succès via apt."
            else
                msg_error "Échec de l'installation des paquets personnalisés via apt."
                # Note: msg_error quitte le script ici.
            fi
        else
            msg_warn "Gestionnaire de paquets 'apt-get' non trouvé. L'installation des paquets personnalisés est ignorée."
        fi
    else
        msg_ok "Aucun paquet valide trouvé dans le fichier $PACKAGE_URL ou fichier vide."
    fi
else
    msg_error "Impossible de télécharger la liste des paquets depuis $PACKAGE_URL."
    rm "$TMP_PACKAGES_FILE" # Nettoyer même en cas d'échec curl
fi

# Configuration des montages VirtioFS
msg_info "Configuration des points de montage virtiofs pour $MOUNT_TAG1 et $MOUNT_TAG2..."

# 1. Créer les répertoires de montage à l'intérieur du conteneur
msg_info "Création des répertoires $MOUNT_POINT_INTERNAL1 et $MOUNT_POINT_INTERNAL2 dans le conteneur $CTID..."
if pct exec $CTID -- mkdir -p "$MOUNT_POINT_INTERNAL1" && pct exec $CTID -- mkdir -p "$MOUNT_POINT_INTERNAL2"; then
    msg_ok "Répertoires de montage créés dans le LXC."

    # 2. Configurer les points de montage dans la configuration PVE du conteneur
    msg_info "Application de la configuration via 'pct set'..."
    if pct set $CTID -mp${MP_INDEX1} ${MOUNT_TAG1},mp=${MOUNT_POINT_INTERNAL1} && \
       pct set $CTID -mp${MP_INDEX2} ${MOUNT_TAG2},mp=${MOUNT_POINT_INTERNAL2}; then
        msg_ok "Points de montage virtiofs configurés dans PVE pour le conteneur $CTID."
        msg_warn "Un redémarrage du conteneur (pct stop $CTID && pct start $CTID) est nécessaire pour activer ces montages."
        # Optionnel: Proposer le redémarrage
        if whiptail --yesno "Voulez-vous redémarrer le conteneur $CTID maintenant pour activer les montages virtiofs ?" 10 70 --defaultno; then
             msg_info "Redémarrage du conteneur $CTID..."
             if pct stop $CTID && pct start $CTID; then
                 msg_ok "Conteneur redémarré."
                 # Retenter de récupérer l'IP après redémarrage
                 sleep 5 # Donner du temps au redémarrage
                 CT_IP=$(pct exec $CTID -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1) || CT_IP="Non récupérée"
             else
                 msg_error "Échec du redémarrage du conteneur $CTID."
             fi
        fi
    else
        msg_error "Échec de la configuration des points de montage virtiofs via 'pct set'."
    fi
else
    msg_error "Échec de la création des répertoires de montage dans le LXC $CTID."
fi

# --- Résumé Final ---
msg_info "--- Création du conteneur terminée ---"
echo -e "${BL}ID du Conteneur :${CL} $CTID"
echo -e "${BL}Nom d'hôte      :${CL} $CT_HOSTNAME"
echo -e "${BL}Template utilisé:${CL} $SELECTED_TEMPLATE"
echo -e "${BL}Stockage        :${CL} $STORAGE"
echo -e "${BL}Adresse IP      :${CL} ${CT_IP:-"Non disponible / DHCP"}"
echo -e "${BL}Utilisateur Root  :${CL} root"
echo -e "${BL}Mot de Passe Root:${CL} (Celui que vous avez défini)"
echo -e "${BL}Montages VirtioFS:${CL}"
echo -e "  - ${MOUNT_TAG1} -> ${MOUNT_POINT_INTERNAL1} (Index ${MP_INDEX1}, nécessite redémarrage si non fait)"
echo -e "  - ${MOUNT_TAG2} -> ${MOUNT_POINT_INTERNAL2} (Index ${MP_INDEX2}, nécessite redémarrage si non fait)"
echo -e "${GN}---------------------------------------${CL}"
msg_ok "Script terminé."

exit 0