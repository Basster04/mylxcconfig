#!/bin/bash

# =========================================================================
# TEMPLATE DE DÉPLOIEMENT POUR SERVEUR WEB PYTHON
# À exécuter sur un conteneur LXC Debian/Ubuntu vierge.
#
# PRÉREQUIS:
#   - Ce script (`deploy.sh`)
#   - Un fichier `template.html` dans le même répertoire.
#
# Ce script installe les dépendances, crée les fichiers nécessaires
# (en copiant le template), et configure un service persistant.
# =========================================================================

# Vérification des privilèges root
if [ "$(id -u)" -ne 0 ]; then
   echo "ERREUR : Ce script doit être exécuté en tant que root." >&2
   exit 1
fi

# --- Variables de configuration ---
WEB_PORT="80" # Le port sur lequel le serveur écoutera. 80 est standard.
APP_DIR="/opt/web-app" # Répertoire d'installation
TEMPLATE_FILE="template.html" # Nom du fichier template à utiliser

# Vérification de la présence du fichier template
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "ERREUR : Le fichier template '$TEMPLATE_FILE' est introuvable." >&2
    echo "Veuillez vous assurer qu'il se trouve dans le même répertoire que ce script." >&2
    exit 1
fi

# --- Début de l'installation ---
set -e # Arrête le script si une commande échoue

echo ">> ÉTAPE 1/5 : Mise à jour du système et installation des dépendances..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3-pip python3-venv

echo ">> ÉTAPE 2/5 : Création de l'environnement et de la structure de l'application..."
mkdir -p "$APP_DIR"
cd "$APP_DIR"

python3 -m venv venv
source venv/bin/activate
pip install requests > /dev/null
deactivate

# Copie du template HTML dans le répertoire de l'application
echo ">> Copie du fichier template..."
cp "../../$TEMPLATE_FILE" "$APP_DIR/" # Copie depuis le répertoire d'origine du script

# --- Création du script du serveur Python ---
echo ">> ÉTAPE 3/5 : Création du serveur web Python..."
cat > "$APP_DIR/server.py" << 'EOF'
import http.server
import socketserver
import requests
import re
import os
from http import HTTPStatus

# Le port est récupéré depuis une variable d'environnement, ou 80 par défaut
PORT = int(os.environ.get('WEB_APP_PORT', 80))
TARGET_URL = "https://www.winds-up.com/spot-le-jaya-windsurf-kitesurf-26-observations-releves-vent.html"

class MyHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        print(f"INFO: Requête reçue pour {self.path}. Tentative de récupération des données...")
        try:
            # Se faire passer pour un navigateur
            headers = {'User-Agent': 'Mozilla/5.0'}
            response = requests.get(TARGET_URL, headers=headers, timeout=10)
            response.raise_for_status()
            html_content = response.text

            # Extraction des données avec des expressions régulières robustes
            obs_match = re.search(r'name:"obs".*?data:\s*(\[.*?\])', html_content, re.DOTALL)
            previs_match = re.search(r'name:"previs".*?data:\s*(\[.*?\])', html_content, re.DOTALL)

            if not obs_match or not previs_match:
                raise ValueError("Impossible d'extraire les données du HTML source.")

            obs_data_str = obs_match.group(1)
            previs_data_str = previs_match.group(1)

            # Lire le template HTML (qui a été copié par le script de déploiement)
            with open('template.html', 'r', encoding='utf-8') as f:
                template = f.read()

            # Injecter les données dans le template
            final_html = template.replace("'__OBS_DATA_PLACEHOLDER__'", obs_data_str)
            final_html = final_html.replace("'__PREVIS_DATA_PLACEHOLDER__'", previs_data_str)

            # Envoyer la page HTML générée
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(final_html.encode('utf-8'))
            print("INFO: Page envoyée avec succès.")

        except requests.exceptions.RequestException as e:
            error_message = f"Erreur réseau lors de la récupération des données de la source: {e}"
            print(f"ERREUR: {error_message}")
            self.send_error(HTTPStatus.INTERNAL_SERVER_ERROR, error_message)
        except Exception as e:
            error_message = f"Erreur interne du serveur: {e}"
            print(f"ERREUR: {error_message}")
            self.send_error(HTTPStatus.INTERNAL_SERVER_ERROR, error_message)

print(f"--- Serveur web démarré sur le port {PORT} ---")
with socketserver.TCPServer(("", PORT), MyHandler) as httpd:
    httpd.serve_forever()
EOF

echo ">> ÉTAPE 4/5 : Création du service systemd pour un fonctionnement continu..."
# Création du service systemd pour le serveur web
cat > /etc/systemd/system/web-app.service << EOF
[Unit]
Description=Serveur Web Python applicatif
After=network.target

[Service]
# Exécute le serveur avec le port configuré
Environment="WEB_APP_PORT=${WEB_PORT}"
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/venv/bin/python3 server.py
Restart=always
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo ">> ÉTAPE 5/5 : Activation et démarrage du service..."
systemctl daemon-reload
systemctl enable --now web-app.service

# Attendre que le service soit actif
sleep 2
systemctl is-active --quiet web-app.service

# Afficher le statut final
IP_ADDR=$(hostname -I | awk '{print $1}')
echo ""
echo "=========================================================="
if systemctl is-active --quiet web-app.service; then
    echo -e " ✅  \033[1;32mInstallation terminée avec succès !\033[0m"
    echo "=========================================================="
    echo " Le serveur est démarré et fonctionnera en continu."
    echo ""
    echo " Pour trouver l'adresse IP de ce conteneur, tapez :"
    echo -e "   \033[1;33mhostname -I\033[0m"
    echo ""
    echo " Adresse IP détectée : \033[1;32m${IP_ADDR}\033[0m"
    echo " URL d'accès direct : \033[1;33mhttp://${IP_ADDR}:${WEB_PORT}\033[0m"
    echo ""
    echo " Pour voir les logs du service, tapez :"
    echo -e "   \033[1;33mjournalctl -u web-app.service -f\033[0m"
else
    echo -e " ❌  \033[1;31mERREUR : Le service n'a pas pu démarrer.\033[0m"
    echo "=========================================================="
    echo " Vérifiez les erreurs avec la commande :"
    echo -e "   \033[1;33mjournalctl -u web-app.service -n 50 --no-pager\033[0m"
fi
echo "=========================================================="
