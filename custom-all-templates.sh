#!/usr/bin/env bash
# Copyright (c) 2021-2025 tteck
# Author: tteck (tteckster)
# License: MIT
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# --- MODIFIED VERSION - Step 6: Removed Initial Permission Warning ---
# --- MODIFIED VERSION - Added Git Repo Script Copy Feature ---

# --- Function Definitions (header_info, error_exit, warn, info, msg, cleanup_ctid) ---
function header_info {
  clear
  cat <<"EOF"
   ___   ____  ______               __     __
  / _ | / / / /_  __/__ __ _  ___  / /__ _/ /____ ___
 / __ |/ / /   / / / -_)  ' \/ _ \/ / _ `/ __/ -_|_-<
/_/ |_/_/_/   /_/  \__/_/_/_/ .__/_/\_,_/\__/\__/___/
                           /_/

     Custom LXC Creation Script
EOF
}

set -eEuo pipefail
shopt -s expand_aliases
alias die='EXIT=$? LINE=$LINENO error_exit'
trap die ERR

# --- Temporary File Handling ---
TEMP_PACKAGE_LIST=$(mktemp)
function cleanup_temp_files() {
  rm -f "$TEMP_PACKAGE_LIST"
}
trap cleanup_temp_files EXIT

function error_exit() {
  trap - ERR # Disable error trap to avoid recursion
  cleanup_temp_files # Ensure temp file is removed on error
  local DEFAULT='Unknown failure occured.'
  local REASON="\e[97m${1:-$DEFAULT}\e[39m"
  local FLAG="\e[91m[ERROR] \e[93m$EXIT@$LINE"
  msg "$FLAG $REASON" 1>&2
  # Attempt cleanup only if CTID appears valid and exists
  if [[ "${CTID:-}" =~ ^[0-9]+$ ]] && pct status "$CTID" &>/dev/null; then
      if pct status "$CTID" | grep -q "status: running"; then
          pct stop "$CTID" || msg "\e[93m[WARNING]\e[39m Failed to stop CT $CTID during cleanup."
      fi
      pct destroy "$CTID" --purge || msg "\e[93m[WARNING]\e[39m Failed to destroy CT $CTID during cleanup."
  # Else if CTID is set but not a valid container, clear it
  elif [[ -n "${CTID:-}" ]]; then
      CTID=""
  fi
  exit "$EXIT"
}
function warn() {
  local REASON="\e[97m$1\e[39m"
  local FLAG="\e[93m[WARNING]\e[39m"
  msg "$FLAG $REASON"
}
function info() {
  local REASON="$1"
  local FLAG="\e[36m[INFO]\e[39m"
  msg "$FLAG $REASON"
}
function msg() {
  local TEXT="$1"
  echo -e "$TEXT"
}
function cleanup_ctid() { # Specific cleanup function called before exit in some cases
  if [[ "${CTID:-}" =~ ^[0-9]+$ ]] && pct status $CTID &>/dev/null; then
    if [ "$(pct status $CTID | awk '{print $2}')" == "running" ]; then
      pct stop $CTID || true
    fi
    pct destroy $CTID || true
  fi
  CTID="" # Clear CTID after attempt
}
# --- End Function Definitions ---

# --- Script State Variables ---
CURRENT_STEP="start"
TEMPLATE=""
HN=""
TEMPLATE_STORAGE=""
CONTAINER_STORAGE=""
SELECTED_PACKAGES=()
PASS=""
CTID=""
PACKAGE_LIST_URL="https://raw.githubusercontent.com/Basster04/mylxcconfig/refs/heads/main/lxc-packages.txt"
HOST_SSH_KEY_PATH="${HOME}/.ssh/lxc.pub"
HOST_SSH_KEY_CONTENT=""
MANDATORY_HOST_PATH="/mnt/Echanges"
MANDATORY_GUEST_PATH="/mnt/Echanges"

# --- NOUVEAU: Variables pour le clonage Git ---
GIT_REPO_URL="https://github.com/Basster04/mylxcconfig.git"
GIT_REPO_SOURCE_DIR="scripts" # Le dossier à copier DANS le dépôt cloné
LXC_SCRIPT_DEST="/root/scripts" # Le dossier de destination DANS le LXC
LXC_TEMP_CLONE_PATH="/tmp/mylxcconfig_clone_$$" # Dossier temporaire pour le clonage
GIT_CLONE_SCRIPT_SUCCESS=false # Suivi du succès de l'opération

# --- Main Script Loop (State Machine) ---
while true; do

  # --- Initial Confirmation ---
  if [[ "$CURRENT_STEP" == "start" ]]; then
    header_info

    # Check SSH Key
    SSH_KEY_INFO="SSH key injection: No key found at $HOST_SSH_KEY_PATH."
    if [[ -f "$HOST_SSH_KEY_PATH" ]]; then
        HOST_SSH_KEY_CONTENT=$(cat "$HOST_SSH_KEY_PATH")
        if [[ -n "$HOST_SSH_KEY_CONTENT" ]]; then
            SSH_KEY_INFO="SSH key injection: Found key at $HOST_SSH_KEY_PATH. Will be added to LXC root."
        else
            SSH_KEY_INFO="SSH key injection: Key file $HOST_SSH_KEY_PATH found but is empty. Skipping."
            HOST_SSH_KEY_CONTENT=""
        fi
    fi

    # Check Mandatory Mount Host Path
    MANDATORY_MOUNT_INFO="Mandatory mount: '$MANDATORY_HOST_PATH' (Host) -> '$MANDATORY_GUEST_PATH' (Guest) will be configured."
    if [ ! -d "$MANDATORY_HOST_PATH" ]; then
        MANDATORY_MOUNT_INFO+="\n\e[93m[WARNING]\e[39m Host path '$MANDATORY_HOST_PATH' not found! Mount config will be added but may fail."
    fi

    # NOUVEAU: Info sur le clonage Git
    GIT_CLONE_INFO="Git Repo Scripts: Will clone '$GIT_REPO_URL', copy '$GIT_REPO_SOURCE_DIR' to '$LXC_SCRIPT_DEST', and make scripts executable."

    # Confirmation Dialog (Permission Warning Removed)
    if whiptail --backtitle "Proxmox VE Helper Scripts" --title "Custom LXC Creation" --yesno "This script will create a customized LXC container.\n\nContainer RootFS Storage Default: Data_VM\nPackages offered from: $PACKAGE_LIST_URL\n\n$MANDATORY_MOUNT_INFO\n\n$SSH_KEY_INFO\n\n$GIT_CLONE_INFO\n\nProceed?" 22 78; then
      CURRENT_STEP="select_template"
    else
      info "User aborted at start."
      exit 0
    fi
  fi

  # --- Template Selection ---
  if [[ "$CURRENT_STEP" == "select_template" ]]; then
    header_info
    echo "Loading templates..."
    pveam update >/dev/null 2>&1

    TEMPLATE_MENU=()
    MSG_MAX_LENGTH=0
    while read -r TAG ITEM; do
      OFFSET=2
      ((${#ITEM} + OFFSET > MSG_MAX_LENGTH)) && MSG_MAX_LENGTH=${#ITEM}+OFFSET
      TEMPLATE_MENU+=("$ITEM" "$TAG " "OFF")
    done < <(pveam available -section system | awk 'NR>1')

    if [ ${#TEMPLATE_MENU[@]} -eq 0 ]; then
        die "No 'system' LXC templates found. Update PVE templates ('pveam update')."
    fi

    SELECTED_ITEM=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Select LXC Template" --radiolist "\nSelect a System Template LXC to create:\n(Use Arrow Keys, Space to Select, Enter to Confirm)" 20 $((MSG_MAX_LENGTH + 58)) 15 "${TEMPLATE_MENU[@]}" 3>&1 1>&2 2>&3)

    if [ $? -eq 0 ] && [ -n "$SELECTED_ITEM" ]; then
        TEMPLATE=$(echo "$SELECTED_ITEM" | tr -d '"')
        info "Selected Template: $TEMPLATE"
        CURRENT_STEP="set_hostname"
    else
        info "Template selection cancelled. Aborting."
        exit 0
    fi
  fi

  # --- Set Hostname ---
  if [[ "$CURRENT_STEP" == "set_hostname" ]]; then
      header_info
      DEFAULT_NAME=$(echo "$TEMPLATE" | cut -d'/' -f2 | cut -d'-' -f1)-$(echo "$TEMPLATE" | cut -d'/' -f2 | cut -d'-' -f2)
      USER_HN=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Enter Hostname" 10 60 "$DEFAULT_NAME" --ok-button "Next" --cancel-button "Back" 3>&1 1>&2 2>&3)
      EXIT_STATUS=$?

      if [ $EXIT_STATUS -eq 0 ]; then
          HN="${USER_HN:-$DEFAULT_NAME}"
          if [[ ! "$HN" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]$|^[a-zA-Z0-9]$ ]]; then
              whiptail --msgbox "Invalid hostname format. Use alphanumeric characters and hyphens (not at start/end)." 10 60
          else
              info "Using hostname: $HN"
              CURRENT_STEP="select_template_storage"
          fi
      else
          info "Returning to Template Selection."
          CURRENT_STEP="select_template"
          continue
      fi
  fi

  # --- Storage Selection Function ---
  function select_storage_step() {
    local CLASS=$1
    local CURRENT_STORAGE_VAR_NAME=$2
    local NEXT_STEP_ON_SUCCESS=$3
    local PREVIOUS_STEP=$4
    local CONTENT; local CONTENT_LABEL;
    local AUTO_STORAGE

    case $CLASS in
    container)
        CONTENT='rootdir'; CONTENT_LABEL='Container RootFS'; AUTO_STORAGE="Data_VM" ;;
    template)
        CONTENT='vztmpl'; CONTENT_LABEL='Container Template'; AUTO_STORAGE="local" ;;
    *) die "Internal error: Invalid storage class '$CLASS'." ;;
    esac

    header_info
    info "Selecting storage for $CONTENT_LABEL..."

    if pvesm status -storage "$AUTO_STORAGE" -content "$CONTENT" &>/dev/null; then
      info "Automatic selection: Found valid storage '$AUTO_STORAGE' for $CONTENT_LABEL."
      eval "$CURRENT_STORAGE_VAR_NAME=\"$AUTO_STORAGE\""
      CURRENT_STEP="$NEXT_STEP_ON_SUCCESS"
      return 0
    else
      info "Preferred storage '$AUTO_STORAGE' not found or doesn't support '$CONTENT'. Manual selection needed."
    fi

    local -a MENU=()
    local STORAGE_LIST
    STORAGE_LIST=$(pvesm status -content $CONTENT | awk 'NR>1')
    if [ -z "$STORAGE_LIST" ]; then
        if [[ "$CLASS" == "container" ]]; then
             whiptail --msgbox "Error: No storage found for Container RootFS (content '$CONTENT').\nPreferred 'Data_VM' failed. Check Datacenter > Storage." 12 70
        else
             whiptail --msgbox "Error: No storage found for $CONTENT_LABEL (content '$CONTENT').\nPreferred '$AUTO_STORAGE' failed. Check Datacenter > Storage." 12 70
        fi
        CURRENT_STEP="$PREVIOUS_STEP"
        return 1
    fi

    local MSG_MAX_LENGTH=0
    while read -r line; do
      local TAG=$(echo $line | awk '{print $1}')
      local TYPE=$(echo $line | awk '{printf "%-10s", $2}')
      local FREE_BYTES=$(pvesh get /storage/$TAG --output-format=json | grep -oP '"avail":\K[0-9]+' || echo 0)
      local FREE=$(numfmt --to=iec --format %.2f $FREE_BYTES | awk '{printf( "%9sB", $1)}')
      local ITEM="  Type: $TYPE Free: $FREE "
      local OFFSET=2
      if [[ $((${#ITEM} + $OFFSET)) -gt ${MSG_MAX_LENGTH:-0} ]]; then
        local MSG_MAX_LENGTH=$((${#ITEM} + $OFFSET))
      fi
      MENU+=("$TAG" "$ITEM" "OFF")
    done <<< "$STORAGE_LIST"

    local SELECTED_STORAGE
    SELECTED_STORAGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Storage Selection: $CONTENT_LABEL" --radiolist \
        "Which storage pool for the ${CONTENT_LABEL}?\n(Preferred '$AUTO_STORAGE' was not suitable or not found)\n\n" \
        20 $(($MSG_MAX_LENGTH + 25)) 10 \
        "${MENU[@]}" --ok-button "Next" --cancel-button "Back" 3>&1 1>&2 2>&3)
    EXIT_STATUS=$?

    if [ $EXIT_STATUS -eq 0 ] && [ -n "$SELECTED_STORAGE" ]; then
        info "Selected storage for $CONTENT_LABEL: $SELECTED_STORAGE"
        eval "$CURRENT_STORAGE_VAR_NAME=\"$SELECTED_STORAGE\""
        CURRENT_STEP="$NEXT_STEP_ON_SUCCESS"
        return 0
    else
        info "Returning to previous step."
        CURRENT_STEP="$PREVIOUS_STEP"
        return 1
    fi
  }

  # --- Select Template Storage ---
  if [[ "$CURRENT_STEP" == "select_template_storage" ]]; then
      select_storage_step "template" "TEMPLATE_STORAGE" "select_container_storage" "set_hostname" || continue
      info "Using '$TEMPLATE_STORAGE' for template storage."
      sleep 1
  fi

  # --- Select Container Storage ---
  if [[ "$CURRENT_STEP" == "select_container_storage" ]]; then
      select_storage_step "container" "CONTAINER_STORAGE" "select_packages" "select_template_storage" || continue
      info "Using '$CONTAINER_STORAGE' for container storage."
      sleep 1
  fi

  # --- Select Packages ---
  if [[ "$CURRENT_STEP" == "select_packages" ]]; then
      header_info
      info "Fetching package list from $PACKAGE_LIST_URL..."
      if ! curl -sSL "$PACKAGE_LIST_URL" -o "$TEMP_PACKAGE_LIST"; then
          warn "Failed to download package list from $PACKAGE_LIST_URL."
          if whiptail --yesno "Failed to fetch the package list. \nSkip optional package installation?" 10 60 --yes-button "Skip Packages" --no-button "Go Back"; then
             SELECTED_PACKAGES=()
             info "Skipping optional package installation."
             CURRENT_STEP="confirm_summary"
          else
             info "Returning to Container Storage selection."
             CURRENT_STEP="select_container_storage"
             continue
          fi
      elif ! [ -s "$TEMP_PACKAGE_LIST" ]; then
           warn "Package list file downloaded but is empty."
           if whiptail --yesno "Fetched package list is empty. \nSkip optional package installation?" 10 60 --yes-button "Skip Packages" --no-button "Go Back"; then
             SELECTED_PACKAGES=()
             info "Skipping optional package installation (list was empty)."
             CURRENT_STEP="confirm_summary"
          else
             info "Returning to Container Storage selection."
             CURRENT_STEP="select_container_storage"
             continue
          fi
      else
          PACKAGE_MENU=()
          while IFS= read -r pkg_name; do
              [[ -z "$pkg_name" ]] || [[ "$pkg_name" =~ ^#.* ]] && continue
              PACKAGE_MENU+=("$pkg_name" "$pkg_name" "ON") # Default ON
          done < "$TEMP_PACKAGE_LIST"

          if [ ${#PACKAGE_MENU[@]} -eq 0 ]; then
              info "No valid packages found in the list. Skipping selection."
              SELECTED_PACKAGES=()
              CURRENT_STEP="confirm_summary"
              sleep 1
          else
              CHOICES=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Select Optional Packages" --checklist \
              "\nAll packages below are pre-selected. Deselect any you DO NOT want:\n(Source: $PACKAGE_LIST_URL)\n(Space to toggle, Enter to confirm)" \
              20 70 12 "${PACKAGE_MENU[@]}" --ok-button "Next" --cancel-button "Back" 3>&1 1>&2 2>&3)
              EXIT_STATUS=$?

              if [ $EXIT_STATUS -eq 0 ]; then
                  readarray -t SELECTED_PACKAGES <<< "$(echo "$CHOICES" | sed 's/"//g')"
                  if [ ${#SELECTED_PACKAGES[@]} -gt 0 ]; then
                      info "Selected packages for installation:"
                      for pkg in "${SELECTED_PACKAGES[@]}"; do info "- $pkg"; done
                  else
                      info "All optional packages were deselected."
                  fi
                  CURRENT_STEP="confirm_summary"
              else
                  info "Returning to Container Storage selection."
                  CURRENT_STEP="select_container_storage"
                  continue
              fi
          fi
      fi
      sleep 1
  fi


  # --- Confirmation Before Creation ---
  if [[ "$CURRENT_STEP" == "confirm_summary" ]]; then
      header_info
      CTID_POTENTIAL=$(pvesh get /cluster/nextid)
      PASS_POTENTIAL="$(openssl rand -base64 12)"

      SUMMARY="=== LXC Configuration Summary ===\n\n"
      SUMMARY+="Template:         $TEMPLATE\n"
      SUMMARY+="Potential CT ID:  $CTID_POTENTIAL\n"
      SUMMARY+="Hostname:         $HN\n"
      SUMMARY+="Root Password:    $PASS_POTENTIAL (will be set)\n"
      SUMMARY+="Template Storage: $TEMPLATE_STORAGE\n"
      SUMMARY+="RootFS Storage:   $CONTAINER_STORAGE\n"
      SUMMARY+="Mandatory Mount:\n"
      SUMMARY+="  - Host: $MANDATORY_HOST_PATH -> Guest: $MANDATORY_GUEST_PATH\n"
      SUMMARY+="  (Note: Requires correct host permissions for access)\n"
      SUMMARY+="System Update:    YES (after creation)\n"
      SUMMARY+="Packages to Install:\n"
      if [ ${#SELECTED_PACKAGES[@]} -gt 0 ]; then
          for pkg in "${SELECTED_PACKAGES[@]}"; do
              SUMMARY+="  - $pkg\n"
          done
      else
          SUMMARY+="  (None selected/deselected)\n"
      fi
      SUMMARY+="SSH Key Injection:\n"
      if [[ -n "$HOST_SSH_KEY_CONTENT" ]]; then
           SUMMARY+="  - Will add key from host ($HOST_SSH_KEY_PATH) to /root/.ssh/authorized_keys\n"
      else
           SUMMARY+="  - Skipped (Host key $HOST_SSH_KEY_PATH not found or empty)\n"
      fi
      # NOUVEAU: Info sur le clonage Git dans le résumé
      SUMMARY+="Git Repo Scripts:\n"
      SUMMARY+="  - Will clone '$GIT_REPO_URL'\n"
      SUMMARY+="  - Copy '$GIT_REPO_SOURCE_DIR' dir to '$LXC_SCRIPT_DEST'\n"
      SUMMARY+="  - Make scripts executable\n"
      SUMMARY+="\n--------------------------------------\n"
      SUMMARY+="Ready to create this LXC?"

      whiptail --backtitle "Proxmox VE Helper Scripts" --title "Confirm Creation" --yesno "$SUMMARY" 33 78 --yes-button "Create LXC" --no-button "Go Back" --cancel-button "Exit Script"
      EXIT_STATUS=$?

      case $EXIT_STATUS in
          0) # Yes (Create LXC)
              info "Configuration confirmed. Proceeding with creation..."
              CTID="$CTID_POTENTIAL"
              PASS="$PASS_POTENTIAL"
              CURRENT_STEP="create_lxc"
              ;;
          1) # No (Go Back)
              info "Returning to Package selection."
              CURRENT_STEP="select_packages"
              PASS=""
              CTID=""
              continue
              ;;
          2|255) # Cancel (Exit Script) or ESC
              info "Creation cancelled by user."
              exit 0
              ;;
      esac
  fi

  # --- Break Loop for Creation ---
  if [[ "$CURRENT_STEP" == "create_lxc" ]]; then
      if [[ -z "$CTID" ]] || [[ -z "$PASS" ]]; then
          die "Internal Error: CTID or Password not set before creation step."
      fi
      break
  fi

  # Safety net for unknown state
  if [[ ! "$CURRENT_STEP" =~ ^(start|select_template|set_hostname|select_template_storage|select_container_storage|select_packages|confirm_summary|create_lxc)$ ]]; then
      die "Error: Unknown script state '$CURRENT_STEP'."
  fi

done # End of the main while loop

# --- Proceed with Actual Creation (Outside the loop) ---
# CTID and PASS are set

header_info
info "Starting LXC Creation Process for CT $CTID..."

# --- Download Template ---
msg "Downloading LXC template '$TEMPLATE' to storage '$TEMPLATE_STORAGE'..."
pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null || die "Failed to download LXC template '$TEMPLATE'."

# --- Define PCT Options ---
HOST_ARCH=$(dpkg --print-architecture)
PCT_OPTIONS=(
    -hostname "$HN" -net0 name=eth0,bridge=vmbr0,ip=dhcp
    -cores 2 -memory 2048 -onboot 1
    -password "$PASS"
    -tags proxmox-helper-scripts,custom -unprivileged 1
    -features keyctl=1,nesting=1
    -rootfs "$CONTAINER_STORAGE":8
    -arch "$HOST_ARCH"
)

# --- Create LXC ---
msg "Creating LXC container $CTID..."
eval pct create "$CTID" \"${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}\" "${PCT_OPTIONS[@]}" >/dev/null ||
  die "Failed to create LXC container $CTID."
info "LXC Container $CTID created."

# --- Configure Mandatory Mount Point ---
info "Configuring mandatory mount point: Host='${MANDATORY_HOST_PATH}' -> Guest='${MANDATORY_GUEST_PATH}'"
mp_index_set="?" # Variable to store the index used
if [ -d "$MANDATORY_HOST_PATH" ]; then
    mp_index=0
    while pct config $CTID | grep -q -E "^mp${mp_index}:"; do
        ((mp_index++))
    done
    info "Using mount point index mp${mp_index} for mandatory mount."
    pct set $CTID -mp${mp_index} "${MANDATORY_HOST_PATH},mp=${MANDATORY_GUEST_PATH},backup=0" || warn "Failed to set mandatory mount point mp${mp_index} for $CTID."
    mp_index_set=$mp_index # Store the index that was actually used
else
    warn "Host path '${MANDATORY_HOST_PATH}' not found. Skipping configuration of mandatory mount point."
    warn "Mount will likely fail inside the container. Create the host path and potentially restart the container or re-run 'pct set $CTID -mpX ...' manually."
fi

# --- Save Credentials ---
CREDS_DIR=~/.config/proxmox-helper-scripts
mkdir -p "$CREDS_DIR"
CREDS_FILE="${CREDS_DIR}/${HN}_${CTID}.creds"
echo "LXC Hostname: ${HN}" > "$CREDS_FILE"
echo "LXC ID: ${CTID}" >> "$CREDS_FILE"
echo "Root Password: ${PASS}" >> "$CREDS_FILE"
echo "Mandatory Mount: Host ${MANDATORY_HOST_PATH} -> Guest ${MANDATORY_GUEST_PATH} (configured as mp${mp_index_set})" >> "$CREDS_FILE" # Use stored index
if [[ -n "$HOST_SSH_KEY_CONTENT" ]]; then
    echo "SSH Key Added: Yes (from $HOST_SSH_KEY_PATH)" >> "$CREDS_FILE"
else
    echo "SSH Key Added: No (file not found or empty)" >> "$CREDS_FILE"
fi
# NOUVEAU: Info Git dans le fichier creds (sera mis à jour plus tard avec le succès/échec)
echo "Git Scripts ($GIT_REPO_SOURCE_DIR from $GIT_REPO_URL): Attempting copy to $LXC_SCRIPT_DEST" >> "$CREDS_FILE"
chmod 600 "$CREDS_FILE"
info "Credentials saved to $CREDS_FILE"

# --- Start Container ---
msg "Starting LXC Container $CTID..."
pct start "$CTID" || die "Failed to start LXC container $CTID."
info "Waiting for container to boot and network..."
sleep 8

# --- Post-Start Operations ---

# --- Ensure Mandatory Mount Directory Exists ---
info "Ensuring mandatory mount directory exists inside LXC: ${MANDATORY_GUEST_PATH}"
pct exec $CTID -- mkdir -p "${MANDATORY_GUEST_PATH}" || warn "Attempt to create directory '${MANDATORY_GUEST_PATH}' inside LXC failed."

# Get IP Address
set +eEuo pipefail
max_attempts=8; attempt=1; IP=""
while [[ $attempt -le $max_attempts ]]; do
  IP=$(pct exec $CTID -- ip -4 addr show dev eth0 | grep -oP 'inet \K\d{1,3}(\.\d{1,3}){3}')
  if [[ -n "$IP" ]]; then
      info "LXC IP Address found: $IP"
      break
  fi
  warn "Attempt $attempt/$max_attempts: IP address not yet found for eth0. Waiting 5 seconds..."
  sleep 5; ((attempt++))
done
set -eEuo pipefail

if [[ -z "$IP" ]]; then
    warn "Could not retrieve IPv4 address for eth0 on LXC $CTID."
    IP="NOT FOUND"
fi

# Update LXC System
header_info
info "Performing system update (apt update && apt upgrade -y) inside LXC $CTID..."
pct exec $CTID -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get -y upgrade' || warn "System update/upgrade failed inside LXC $CTID."
info "System update completed."

# Install Selected Packages
if [ ${#SELECTED_PACKAGES[@]} -gt 0 ]; then
    PACKAGES_TO_INSTALL=$(echo "${SELECTED_PACKAGES[@]}" | tr '\n' ' ')
    info "Installing selected packages ($PACKAGES_TO_INSTALL) inside LXC $CTID..."
    pct exec $CTID -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get install -y $PACKAGES_TO_INSTALL" || warn "Failed to install selected packages inside LXC $CTID."
    info "Selected packages installation attempt completed."
else
    info "No optional packages were selected for installation."
fi

# --- Inject Host SSH Key if found ---
SSH_KEY_ADDED_SUCCESS=false
if [[ -n "$HOST_SSH_KEY_CONTENT" ]]; then
    info "Adding host SSH key ($HOST_SSH_KEY_PATH) to LXC $CTID root user..."
    echo "$HOST_SSH_KEY_CONTENT" | pct exec $CTID -- bash -c 'umask 077; mkdir -p /root/.ssh && cat >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && chmod 700 /root/.ssh'
    if [ $? -eq 0 ]; then
        info "Host SSH key added successfully to /root/.ssh/authorized_keys."
        SSH_KEY_ADDED_SUCCESS=true
    else
        warn "Failed to add host SSH key to LXC $CTID."
    fi
else
    info "Skipping SSH key addition (key file not found or empty)."
fi

# --- NOUVEAU: Clone Git Repo, Copy Scripts, Set Permissions ---
info "Attempting Git operations: Clone '$GIT_REPO_URL', copy '$GIT_REPO_SOURCE_DIR' to '$LXC_SCRIPT_DEST'..."

# Définir les commandes à exécuter dans le conteneur
# Utilisation de && pour chaîner les commandes : si une échoue, les suivantes ne s'exécutent pas.
COMMANDS_TO_RUN=$(cat <<EOF
export DEBIAN_FRONTEND=noninteractive;
echo '>>> [GitOps] Installing git...';
apt-get update > /dev/null && apt-get install -y git;
if [ \$? -ne 0 ]; then echo 'ERROR: Failed to install git.' >&2; exit 1; fi;

echo '>>> [GitOps] Removing previous temporary clone directory (if any)...';
rm -rf '$LXC_TEMP_CLONE_PATH';

echo '>>> [GitOps] Cloning repository $GIT_REPO_URL...';
git clone --depth 1 '$GIT_REPO_URL' '$LXC_TEMP_CLONE_PATH';
if [ \$? -ne 0 ]; then echo 'ERROR: Failed to clone repository $GIT_REPO_URL.' >&2; rm -rf '$LXC_TEMP_CLONE_PATH'; exit 1; fi;

echo '>>> [GitOps] Checking if source directory exists: ${LXC_TEMP_CLONE_PATH}/${GIT_REPO_SOURCE_DIR}';
if [ ! -d '${LXC_TEMP_CLONE_PATH}/${GIT_REPO_SOURCE_DIR}' ]; then
    echo 'ERROR: Source directory ${GIT_REPO_SOURCE_DIR} not found in the cloned repository.' >&2;
    rm -rf '$LXC_TEMP_CLONE_PATH'; # Nettoyer le clone temporaire
    exit 1;
fi;

echo '>>> [GitOps] Creating destination directory $LXC_SCRIPT_DEST...';
mkdir -p '$LXC_SCRIPT_DEST';
if [ \$? -ne 0 ]; then echo 'ERROR: Failed to create destination directory $LXC_SCRIPT_DEST.' >&2; rm -rf '$LXC_TEMP_CLONE_PATH'; exit 1; fi;

echo '>>> [GitOps] Copying directory contents from ${LXC_TEMP_CLONE_PATH}/${GIT_REPO_SOURCE_DIR} to $LXC_SCRIPT_DEST...';
# Copie le contenu du dossier source vers la destination. Le /.' est important.
cp -r '${LXC_TEMP_CLONE_PATH}/${GIT_REPO_SOURCE_DIR}/.' '$LXC_SCRIPT_DEST/';
if [ \$? -ne 0 ]; then echo 'ERROR: Failed to copy script directory.' >&2; rm -rf '$LXC_TEMP_CLONE_PATH'; exit 1; fi;

echo '>>> [GitOps] Setting execute permissions on files in $LXC_SCRIPT_DEST...';
find '$LXC_SCRIPT_DEST' -type f -exec chmod +x {} \; ;
if [ \$? -ne 0 ]; then echo 'WARNING: Failed to set execute permissions on some scripts.' >&2; fi; # Peut-être juste un avertissement ici?

echo '>>> [GitOps] Cleaning up temporary clone directory $LXC_TEMP_CLONE_PATH...';
rm -rf '$LXC_TEMP_CLONE_PATH';

echo '>>> [GitOps] Script copy and permission setting completed.';
exit 0; # Succès global des opérations Git
EOF
)

# Exécuter les commandes dans le conteneur
# Désactiver temporairement l'arrêt sur erreur pour capturer le code de sortie de pct exec
set +e
pct exec $CTID -- bash -c "$COMMANDS_TO_RUN"
EXEC_STATUS=$?
set -e # Réactiver l'arrêt sur erreur

# Vérifier le succès de l'opération Git
if [ $EXEC_STATUS -eq 0 ]; then
    info "Successfully cloned repo, copied '$GIT_REPO_SOURCE_DIR' to '$LXC_SCRIPT_DEST', and set permissions."
    GIT_CLONE_SCRIPT_SUCCESS=true
    # Mettre à jour le fichier creds pour indiquer le succès
    sed -i "/^Git Scripts/c\Git Scripts ($GIT_REPO_SOURCE_DIR from $GIT_REPO_URL): Successfully copied to $LXC_SCRIPT_DEST" "$CREDS_FILE"
else
    warn "Git operations failed (clone, copy, or chmod). Check logs above for details."
    GIT_CLONE_SCRIPT_SUCCESS=false
    # Mettre à jour le fichier creds pour indiquer l'échec
    sed -i "/^Git Scripts/c\Git Scripts ($GIT_REPO_SOURCE_DIR from $GIT_REPO_URL): FAILED to copy to $LXC_SCRIPT_DEST" "$CREDS_FILE"
    # Ne pas mourir ici, l'échec du clonage n'est peut-être pas critique pour l'utilisateur
fi
# --- Fin de la section Git ---


# --- Success Message ---
header_info; echo
info "LXC container '$HN' (ID: $CTID) was successfully created and configured."
echo
info "Status: $(pct status $CTID | awk '{print $2}')"
info "IP Address: $IP"
info "Root Password: $PASS (also saved in $CREDS_FILE)"
if [[ -n "$HOST_SSH_KEY_CONTENT" ]]; then
    if [[ "$SSH_KEY_ADDED_SUCCESS" == true ]]; then
        info "SSH Access: Key from $HOST_SSH_KEY_PATH added. Try: ssh root@$IP"
    else
        info "SSH Access: Failed to add key from $HOST_SSH_KEY_PATH."
    fi
else
    info "SSH Access: Key injection skipped."
fi
echo

info "Mandatory Mount Configured:"
info "  - Host: ${MANDATORY_HOST_PATH} -> Guest: ${MANDATORY_GUEST_PATH}"
if [ ! -d "$MANDATORY_HOST_PATH" ]; then
     info "  \e[93m[WARNING]\e[39m Host path was not found during script run. Mount will likely fail."
fi
info "  (For mount to work, requires correct permissions on \e[93mHOST\e[39m path '$MANDATORY_HOST_PATH' for UID 100000)."
info "  (Check mount status inside LXC with: df -h | grep $MANDATORY_GUEST_PATH )"
echo

if [ ${#SELECTED_PACKAGES[@]} -gt 0 ]; then
    info "Installed optional packages:"
    for pkg in "${SELECTED_PACKAGES[@]}"; do info "  - $pkg"; done
    echo
fi

# NOUVEAU: Message sur le statut des scripts Git
info "Git Repository Scripts:"
if [[ "$GIT_CLONE_SCRIPT_SUCCESS" == true ]]; then
    info "  - Successfully cloned '$GIT_REPO_URL'"
    info "  - Copied '$GIT_REPO_SOURCE_DIR' content to '$LXC_SCRIPT_DEST' inside the LXC."
    info "  - Scripts within '$LXC_SCRIPT_DEST' should be executable."
else
    info "  \e[93m[WARNING]\e[39m Failed to clone/copy/set permissions for scripts from '$GIT_REPO_URL'."
    info "  - Check the script output above for error messages from inside the container."
fi
echo

info "LXC is updated and set to start on boot. Access via console ('pct enter $CTID') or SSH (if key added)."
echo; msg "Done."

exit 0