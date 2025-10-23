#!/usr/bin/env bash

# Script pour installer Oh My Zsh, le plugin zsh-autosuggestions et définir le thème crcandy.

# Arrêter le script si une commande échoue
set -e

# --- Configuration ---
ZSHRC_FILE="$HOME/.zshrc"
OHMYZSH_DIR="$HOME/.oh-my-zsh"
PLUGIN_NAME="zsh-autosuggestions"
PLUGIN_REPO="https://github.com/zsh-users/zsh-autosuggestions.git"
# Détermine le répertoire custom des plugins (utilise ZSH_CUSTOM si défini, sinon le défaut)
PLUGIN_DIR="${ZSH_CUSTOM:-$OHMYZSH_DIR/custom}/plugins/$PLUGIN_NAME"
DESIRED_THEME="crcandy"

# --- Fonctions Utilitaires ---
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# --- Vérification des prérequis ---
echo "Vérification des prérequis..."
if ! command_exists git; then
    echo "ERREUR : 'git' n'est pas installé. Veuillez l'installer et relancer le script." >&2
    exit 1
fi
if ! command_exists curl; then
    echo "ERREUR : 'curl' n'est pas installé. Veuillez l'installer et relancer le script." >&2
    exit 1
fi
if ! command_exists zsh; then
    echo "ATTENTION : 'zsh' n'a pas été trouvé. Oh My Zsh nécessite Zsh pour fonctionner."
    # On continue quand même, l'installation d'Oh My Zsh pourrait échouer plus tard.
fi
echo "Prérequis OK."
echo

# --- Étape 1: Installer Oh My Zsh ---
if [ -d "$OHMYZSH_DIR" ]; then
    echo "Oh My Zsh semble déjà installé dans '$OHMYZSH_DIR'."
else
    echo "Installation de Oh My Zsh..."
    # Exécute l'installeur Oh My Zsh de manière non interactive
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    echo "Oh My Zsh installé."
    # Vérifie si le fichier .zshrc a été créé
    if [ ! -f "$ZSHRC_FILE" ]; then
        echo "ERREUR : Le fichier '$ZSHRC_FILE' n'a pas été créé par l'installeur Oh My Zsh." >&2
        exit 1
    fi
fi
echo

# --- Étape 2: Cloner le plugin zsh-autosuggestions ---
if [ -d "$PLUGIN_DIR" ]; then
    echo "Le plugin '$PLUGIN_NAME' semble déjà cloné dans '$PLUGIN_DIR'."
    # Optionnel: Mettre à jour le plugin existant
    # echo "Mise à jour du plugin '$PLUGIN_NAME'..."
    # git -C "$PLUGIN_DIR" pull || echo "Impossible de mettre à jour le plugin (ignorer si hors ligne)."
else
    echo "Clonage du plugin '$PLUGIN_NAME'..."
    # Crée le répertoire parent si nécessaire (normalement fait par Oh My Zsh)
    mkdir -p "$(dirname "$PLUGIN_DIR")"
    git clone "$PLUGIN_REPO" "$PLUGIN_DIR"
    echo "Plugin '$PLUGIN_NAME' cloné."
fi
echo

# --- Étape 3 & 4: Modifier ~/.zshrc ---
echo "Configuration de '$ZSHRC_FILE'..."
echo "(Un backup sera créé sous ${ZSHRC_FILE}.bak avant les modifications)"

# 4: Définir le thème
echo "- Vérification/Définition du thème..."
if grep -q "^ZSH_THEME=\"$DESIRED_THEME\"" "$ZSHRC_FILE"; then
    echo "  Le thème est déjà défini sur '$DESIRED_THEME'."
else
    # Utilise sed pour remplacer la ligne ZSH_THEME
    sed -i.bak "s/^ZSH_THEME=\".*\"/ZSH_THEME=\"$DESIRED_THEME\"/" "$ZSHRC_FILE"
    echo "  Thème mis à jour à '$DESIRED_THEME'."
fi

# 3: Ajouter le plugin à la liste
echo "- Vérification/Ajout du plugin '$PLUGIN_NAME'..."
# Vérifie si le plugin est DÉJÀ dans la liste, en ignorant les commentaires et en gérant les espaces
# Regex: commence par 'plugins=(', contient éventuellement d'autres plugins, puis le nom du plugin recherché, puis d'autres choses jusqu'à ')'
if grep -qE "^\s*plugins=\([^)]*\b${PLUGIN_NAME}\b[^)]*\)" "$ZSHRC_FILE"; then
    echo "  Le plugin '$PLUGIN_NAME' est déjà dans la liste des plugins."
else
    # Ajoute le plugin à la fin de la liste, juste avant le ')'
    # Utilise sed pour trouver la ligne commençant par 'plugins=(' et ajoute le nom avant le ')' final
    sed -i.bak "/^\s*plugins=(/ s/)\$/ $PLUGIN_NAME)/" "$ZSHRC_FILE"

    # Vérification après modification
    if grep -qE "^\s*plugins=\([^)]*\b${PLUGIN_NAME}\b[^)]*\)" "$ZSHRC_FILE"; then
        echo "  Plugin '$PLUGIN_NAME' ajouté à la liste."
    else
        echo "  ATTENTION : Impossible d'ajouter automatiquement le plugin '$PLUGIN_NAME'." >&2
        echo "  Veuillez éditer '$ZSHRC_FILE' manuellement et ajouter '$PLUGIN_NAME' dans 'plugins=(...)'." >&2
        # On ne sort pas en erreur, mais on prévient l'utilisateur
    fi
fi
echo

# --- Étape 5: Instructions finales ---
echo "-----------------------------------------------------"
echo "Configuration terminée !"
echo
echo "IMPORTANT : Pour que les changements prennent effet :"
echo "1. Fermez et rouvrez votre terminal."
echo "   OU"
echo "2. Exécutez la commande : zsh"
echo "-----------------------------------------------------"

# Vérifie si Zsh est le shell par défaut et suggère comment le changer si ce n'est pas le cas
if [ "$(basename "$SHELL")" != "zsh" ]; then
    echo
    echo "NOTE : Votre shell par défaut n'est pas Zsh. Pour en profiter pleinement,"
    echo "vous pouvez le changer avec la commande :"
    if command_exists chsh && command_exists zsh; then
         echo "  chsh -s \"$(which zsh)\""
         echo "(Vous devrez peut-être vous déconnecter/reconnecter pour que cela prenne effet partout)."
    else
         echo "  (Impossible de déterminer la commande 'chsh' ou le chemin de 'zsh' automatiquement)."
    fi
fi

exit 0
