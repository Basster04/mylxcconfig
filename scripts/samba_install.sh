#!/bin/bash
set -e

# Variables (modifie si besoin)
REALM="HOMELAB.LAN"
DOMAIN="HOMELAB"
HOSTNAME="srv-ad"
ADMIN_PASS="Admin123!"  # Tu peux le changer après installation

# Vérifications initiales
if [ "$(id -u)" != "0" ]; then
    echo "Ce script doit être lancé en tant que root."
    exit 1
fi

echo "Mise à jour du système..."
apt update && apt upgrade -y

echo "Installation des paquets requis..."
apt install -y samba krb5-config winbind smbclient dnsutils ldb-tools

echo "Définition du nom d’hôte..."
hostnamectl set-hostname $HOSTNAME

echo "Suppression de la configuration Samba par défaut..."
mv /etc/samba/smb.conf /etc/samba/smb.conf.bak || true

echo "Provisionnement du domaine Samba AD..."
samba-tool domain provision --use-rfc2307 --realm=$REALM --domain=$DOMAIN \
    --server-role=dc --dns-backend=SAMBA_INTERNAL --adminpass=$ADMIN_PASS

echo "Configuration de Kerberos..."
cat <<EOF > /etc/krb5.conf
[libdefaults]
 default_realm = $REALM
 dns_lookup_realm = false
 dns_lookup_kdc = true
EOF

echo "Activation du service samba-ad-dc..."
systemctl unmask samba-ad-dc
systemctl enable samba-ad-dc --now

echo "Configuration du DNS local..."
echo "nameserver 127.0.0.1" > /etc/resolv.conf

echo "Test d’authentification Kerberos..."
echo $ADMIN_PASS | kinit administrator
klist

echo "Installation terminée. Domaine $REALM actif."
