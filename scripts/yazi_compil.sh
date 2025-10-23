#!/usr/bin/env bash
# ==========================================
# 🚀 Installation rapide de Yazi via binaire précompilé
# Compatible Debian/Ubuntu LXC + zsh
# ==========================================

set -e

echo "=========================================="
echo " ⚡ Installation rapide de Yazi (binaire)"
echo "=========================================="

# --- Vérification root ---
if [ "$EUID" -ne 0 ]; then
  echo "❌ Ce script doit être exécuté en root."
  exit 1
fi

# --- Définir chemins ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY_PATH="$SCRIPT_DIR/binaries/yazi-linux"

# --- Vérification du binaire ---
if [ ! -f "$BINARY_PATH" ]; then
  echo "❌ Binaire Yazi introuvable ! Déposez le fichier dans $SCRIPT_DIR/binaries/yazi-linux"
  exit 1
fi

# --- Copie dans /usr/local/bin ---
echo "🚀 Copie du binaire dans /usr/local/bin..."
install -m 755 "$BINARY_PATH" /usr/local/bin/yazi

# --- Vérification du binaire ---
if command -v /usr/local/bin/yazi &>/dev/null; then
  echo "✅ Yazi installé : $(/usr/local/bin/yazi --version || echo 'version inconnue')"
else
  echo "❌ Erreur : Yazi non détecté après installation."
  exit 1
fi

# --- Vérification de zsh ---
if ! command -v zsh &>/dev/null; then
  echo "💡 zsh n’est pas installé, installation en cours..."
  apt update -y
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

echo ""
echo "=========================================="
echo "🎉 Installation rapide terminée !"
echo "➡️ Lance Yazi avec :  yazi"
echo "=========================================="
