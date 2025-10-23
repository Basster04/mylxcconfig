#!/usr/bin/env bash
# ==========================================
# 🚀 Script prêt à l'emploi : installation automatique de Yazi
# Compatible Debian/Ubuntu LXC + zsh + swap
# ==========================================

set -e

echo "=========================================="
echo " 🦀 Installation de Yazi sur ce conteneur "
echo "=========================================="

# --- Vérification root ---
if [ "$EUID" -ne 0 ]; then
  echo "❌ Ce script doit être exécuté en root."
  exit 1
fi

# --- Vérification RAM et swap ---
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
SWAP_NEEDED=2000000   # 2 Go minimum
if [ "$RAM_KB" -lt "$SWAP_NEEDED" ]; then
  echo "💾 RAM insuffisante (<2Go), création d'un fichier swap de 2Go..."
  if ! swapon --show | grep -q "swapfile"; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  else
    echo "✅ Swap déjà activé."
  fi
else
  echo "✅ RAM suffisante : $(($RAM_KB/1024)) Mo"
fi

# --- Mise à jour système ---
echo "🧩 Mise à jour des paquets..."
apt update -y && apt upgrade -y

# --- Installation dépendances ---
echo "🛠️ Installation des dépendances système..."
apt install -y curl git build-essential pkg-config libssl-dev unzip

# --- Vérification et installation de Rust ---
if ! command -v cargo &>/dev/null; then
  echo "🦀 Installation de Rust..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  source $HOME/.cargo/env
else
  echo "✅ Rust déjà présent."
  source $HOME/.cargo/env
fi

# --- Téléchargement et compilation de Yazi ---
WORKDIR=$(mktemp -d)
echo "📦 Téléchargement du dépôt Yazi dans $WORKDIR ..."
git clone --depth 1 https://github.com/sxyazi/yazi.git "$WORKDIR"
cd "$WORKDIR"

echo "⚙️ Compilation de Yazi (cela peut prendre plusieurs minutes)..."
cargo build --release --locked -j1

# --- Installation du binaire ---
BIN_PATH=$(find target/release -type f -name yazi -perm -111 | head -n1)
if [ -n "$BIN_PATH" ]; then
  echo "🚀 Installation du binaire depuis $BIN_PATH ..."
  install -m 755 "$BIN_PATH" /usr/local/bin/yazi
else
  echo "❌ Erreur : binaire Yazi non trouvé après compilation."
  exit 1
fi

# --- Vérification du binaire ---
if command -v /usr/local/bin/yazi &>/dev/null; then
  echo "✅ Yazi installé : $(/usr/local/bin/yazi --version)"
else
  echo "❌ Yazi n’est pas détecté dans le PATH."
  exit 1
fi

# --- Vérification de zsh ---
if ! command -v zsh &>/dev/null; then
  echo "💡 zsh n’est pas installé, installation en cours..."
  apt install -y zsh
  chsh -s "$(command -v zsh)" root
else
  echo "✅ zsh déjà installé."
fi

# --- Mise à jour du PATH pour bash et zsh ---
for shellrc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [ ! -f "$shellrc" ] && touch "$shellrc"
  if ! grep -q "/usr/local/bin" "$shellrc"; then
    echo 'export PATH="/usr/local/bin:$PATH"' >> "$shellrc"
  fi
done

# --- Rechargement du shell actif ---
if [ -n "$ZSH_VERSION" ]; then
  source ~/.zshrc
elif [ -n "$BASH_VERSION" ]; then
  source ~/.bashrc
fi

# --- Nettoyage ---
rm -rf "$WORKDIR"

echo ""
echo "=========================================="
echo "🎉 Installation terminée !"
echo "➡️ Lance Yazi avec :  yazi"
echo "=========================================="
