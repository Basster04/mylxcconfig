#!/bin/bash

set -e

echo "🔧 Installation des dépendances..."
apt update
apt install -y python3 python3-venv python3-full

echo "📦 Création d'un environnement virtuel..."
mkdir -p /opt/ip_web_service
python3 -m venv /opt/ip_web_service/venv

echo "📦 Activation de l'environnement et installation de Flask..."
/opt/ip_web_service/venv/bin/pip install --upgrade pip
/opt/ip_web_service/venv/bin/pip install flask

echo "📝 Création de l'application Flask..."
cat <<EOF > /opt/ip_web_service/app.py
from flask import Flask, request

app = Flask(__name__)

@app.route("/")
def show_ip():
    ip_address = request.headers.get('X-Forwarded-For', request.remote_addr)
    return f"<h1>IP Vue par le Serveur : {ip_address}</h1>"

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
EOF

echo "🔧 Création du service systemd..."
cat <<EOF > /etc/systemd/system/ip-web.service
[Unit]
Description=Flask IP Viewer Web Service
After=network.target

[Service]
WorkingDirectory=/opt/ip_web_service
ExecStart=/opt/ip_web_service/venv/bin/python /opt/ip_web_service/app.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

echo "🚀 Démarrage du service..."
systemctl daemon-reload
systemctl enable ip-web
systemctl start ip-web

echo "✅ Service opérationnel sur http://<IP_LXC>:5000"
