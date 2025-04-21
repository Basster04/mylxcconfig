#!/bin/bash

set -e

# Fonction : Menu principal avec retour possible
menu_with_return() {
  local title="$1"
  local prompt="$2"
  shift 2
  local options=($(echo "$@"))
  local menu=("Retour" "Revenir à l'étape précédente")
  menu+=("${options[@]}")
  whiptail --title "$title" --menu "$prompt" 20 78 10 "${menu[@]}" 3>&1 1>&2 2>&3
}

# Étape 1 : Choix du template
while true; do
  TEMPLATE=$(menu_with_return "Choix du template" "Sélectionne un template à installer :" \
    "debian-12-standard" "Debian 12 (standard)" \
    "ubuntu-22.04-standard" "Ubuntu 22.04 (standard)")
  [[ "$TEMPLATE" == "Retour" ]] && exit 0 || break
done

# Étape 2 : Sélection du stockage (sauf si local détecté)
if pvesm status | grep -q '^local '; then
  STORAGE="local"
else
  while true; do
    STORAGE=$(menu_with_return "Sélection du stockage" "Choisis un stockage :" $(pvesm status | awk 'NR>1 {print $1, $1}'))
    [[ "$STORAGE" == "Retour" ]] && exit 0 || break
  done
fi

# Étape 3 : Choix des ressources
while true; do
  CORES=$(whiptail --title "Nombre de cœurs" --inputbox "Nombre de vCPU ?" 10 60 2 3>&1 1>&2 2>&3)
  [[ -z "$CORES" ]] && continue || break
  [[ "$CORES" == "Retour" ]] && exit 0
  [[ "$CORES" =~ ^[0-9]+$ ]] && break
done

while true; do
  MEMORY=$(whiptail --title "Mémoire (en Mo)" --inputbox "Mémoire RAM ?" 10 60 2048 3>&1 1>&2 2>&3)
  [[ -z "$MEMORY" ]] && continue || break
  [[ "$MEMORY" == "Retour" ]] && exit 0
  [[ "$MEMORY" =~ ^[0-9]+$ ]] && break
  
done

# Étape 4 : Mot de passe root
while true; do
  PASSWORD=$(whiptail --title "Mot de passe" --passwordbox "Mot de passe root ?" 10 60 3>&1 1>&2 2>&3)
  [[ "$PASSWORD" == "Retour" ]] && exit 0 || break
  [[ -n "$PASSWORD" ]] && break
  
done

# Étape 5 : Choix bridge réseau
while true; do
  BRIDGE=$(whiptail --title "Bridge réseau" --inputbox "Bridge (ex : vmbr0) ?" 10 60 vmbr0 3>&1 1>&2 2>&3)
  [[ "$BRIDGE" == "Retour" ]] && exit 0 || break
  [[ -n "$BRIDGE" ]] && break
  
done

# Étape 6 : IP fixe ou DHCP
while true; do
  IP_MODE=$(menu_with_return "Configuration IP" "Mode d'adresse IP ?" \
    "dhcp" "Adresse IP automatique (DHCP)" \
    "static" "Adresse IP fixe")
  [[ "$IP_MODE" == "Retour" ]] && exit 0 || break

done

if [ "$IP_MODE" == "static" ]; then
  IP_ADDRESS=$(whiptail --title "Adresse IP" --inputbox "Entrez l'adresse IP avec masque (ex : 192.168.1.100/24)" 10 60 3>&1 1>&2 2>&3)
  GATEWAY=$(whiptail --title "Passerelle" --inputbox "Entrez l'adresse de la passerelle" 10 60 3>&1 1>&2 2>&3)
  NET_CONFIG="ip=$IP_ADDRESS,gw=$GATEWAY"
else
  NET_CONFIG="ip=dhcp"
fi

# Préparation
CTID=$(pvesh get /cluster/nextid)
HOSTNAME="ct-$TEMPLATE"

# Téléchargement template si non dispo
pveam update
if ! pveam available | grep -q $TEMPLATE; then
  echo "Téléchargement du template..."
  pveam download $STORAGE $TEMPLATE
fi

# Création du conteneur
pct create $CTID \
  $STORAGE:vztmpl/$TEMPLATE.tar.xz \
  -hostname $HOSTNAME \
  -storage $STORAGE \
  -cores $CORES \
  -memory $MEMORY \
  -net0 name=eth0,bridge=$BRIDGE,$NET_CONFIG \
  -password $PASSWORD \
  -features nesting=1 \
  -unprivileged 1

# Démarrage
pct start $CTID
sleep 5

# Mise à jour et installation depuis dépôt personnel
pct exec $CTID -- bash -c "apt update && apt -y upgrade"
pct exec $CTID -- bash -c "curl -fsSL https://raw.githubusercontent.com/Basster04/mylxcconfig/refs/heads/main/lxc-packages.txt -o /tmp/lxc-packages.txt && xargs apt install -y < /tmp/lxc-packages.txt"

# Création du script de montage virtiofs
MOUNT_SCRIPT="#!/bin/bash
mount -t virtiofs Echanges_PVE1 /mnt/pve_echanges1
mount -t virtiofs Echanges_PVE2 /mnt/pve_echanges2"

pct exec $CTID -- bash -c "mkdir -p /mnt/pve_echanges1 /mnt/pve_echanges2"
pct exec $CTID -- bash -c "echo '$MOUNT_SCRIPT' > /etc/init.d/mount_echanges && chmod +x /etc/init.d/mount_echanges && ln -s /etc/init.d/mount_echanges /etc/rc2.d/S99mount_echanges"

# Affichage des infos
IP=$(pct exec $CTID -- hostname -I | awk '{print $1}')
echo "\nConteneur créé avec succès :"
echo " - ID : $CTID"
echo " - Hostname : $HOSTNAME"
echo " - Mot de passe root : $PASSWORD"
echo " - IP : $IP"
echo "\nMontages virtiofs activés au démarrage."
echo "\nFin."
