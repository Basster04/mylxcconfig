#!/bin/bash
set -e

echo "🔧 Installation de Yazi sur Debian/Ubuntu"

# Étape 1 : dépendances système
echo "📦 Installation des dépendances..."
apt update -y
apt install -y curl git build-essential pkg-config libssl-dev unzip

# Étape 2 : installation de Rust (si non déjà présent)
if ! command -v cargo >/dev/null 2>&1; then
  echo "🦀 Installation de Rust..."
  curl https://sh.rustup.rs -sSf | sh -s -- -y
  . "$HOME/.cargo/env"
else
  echo "✅ Rust est déjà installé"
  . "$HOME/.cargo/env"
fi

# Étape 3 : clonage du dépôt Yazi
cd /tmp
if [ -d "yazi" ]; then
  rm -rf yazi
fi
echo "📥 Clonage du dépôt Yazi..."
git clone https://github.com/sxyazi/yazi.git
cd yazi

# Étape 4 : compilation
echo "⚙️ Compilation de Yazi (cela peut prendre 1-2 minutes)..."
cargo build --release --locked

# Étape 5 : installation du binaire
echo "🚀 Installation du binaire..."
install -m 755 target/release/yazi /usr/local/bin/yazi

# Étape 6 : nettoyage
echo "🧹 Nettoyage..."
cd ~
rm -rf /tmp/yazi

# Étape 7 : test
if command -v yazi >/dev/null 2>&1; then
  echo "✅ Yazi est installé avec succès ! Lance-le avec : yazi"
else
  echo "❌ Erreur : Yazi ne semble pas installé correctement."
fi
