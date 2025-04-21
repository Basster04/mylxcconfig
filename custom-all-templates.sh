#!/usr/bin/env bash
# Copyright (c) 2021-2025 tteck
# Author: tteck (tteckster)
# License: MIT
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# --- MODIFIED VERSION - Step 1: Adding Back Button Placeholder ---

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

function error_exit() {
  trap - ERR
  local DEFAULT='Unknown failure occured.'
  local REASON="\e[97m${1:-$DEFAULT}\e[39m"
  local FLAG="\e[91m[ERROR] \e[93m$EXIT@$LINE"
  msg "$FLAG $REASON" 1>&2
  [ ! -z ${CTID-} ] && cleanup_ctid # Try to cleanup CT if defined
  exit $EXIT
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
function cleanup_ctid() {
  if [[ "${CTID:-}" =~ ^[0-9]+$ ]] && pct status $CTID &>/dev/null; then
    if [ "$(pct status $CTID | awk '{print $2}')" == "running" ]; then
      pct stop $CTID || true
    fi
    pct destroy $CTID || true
  fi
}
# --- End Function Definitions ---

# --- Script State Variables ---
# These will be used later for the full Back logic
CURRENT_STEP="start"
TEMPLATE=""
HN=""
TEMPLATE_STORAGE=""
CONTAINER_STORAGE=""
SELECTED_MOUNTS=()
PASS=""
CTID=""

# --- Main Script Loop (Preparation for State Machine) ---
while true; do

  # --- Initial Confirmation ---
  if [[ "$CURRENT_STEP" == "start" ]]; then
    header_info
    # Using --yesno here, simple proceed or cancel
    if whiptail --backtitle "Proxmox VE Helper Scripts" --title "Custom LXC Creation" --yesno "This script will guide you through creating a customized LXC container.\n\nProceed?" 10 68; then
      CURRENT_STEP="select_template" # Move to next step
    else
      info "User aborted at start."
      exit 0 # Exit cleanly
    fi
  fi

  # --- Template Selection ---
  if [[ "$CURRENT_STEP" == "select_template" ]]; then
    header_info
    echo "Loading templates..."
    pveam update >/dev/null 2>&1 # Ensure list is fresh

    TEMPLATE_MENU=()
    MSG_MAX_LENGTH=0
    # Consider filtering templates, e.g., system templates: pveam available -section system
    while read -r TAG ITEM; do
      OFFSET=2
      ((${#ITEM} + OFFSET > MSG_MAX_LENGTH)) && MSG_MAX_LENGTH=${#ITEM}+OFFSET
      TEMPLATE_MENU+=("$ITEM" "$TAG " "OFF")
    done < <(pveam available | awk 'NR>1') # Or use -section filter

    if [ ${#TEMPLATE_MENU[@]} -eq 0 ]; then
        die "No LXC templates found. Update PVE templates ('pveam update')."
    fi

    # --radiolist only has OK/Cancel. Cancel here means exit the script.
    SELECTED_ITEM=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Select LXC Template" --radiolist "\nSelect a Template LXC to create:\n(Use Arrow Keys, Space to Select, Enter to Confirm)" 20 $((MSG_MAX_LENGTH + 58)) 15 "${TEMPLATE_MENU[@]}" 3>&1 1>&2 2>&3)

    if [ $? -eq 0 ] && [ -n "$SELECTED_ITEM" ]; then # OK pressed and item selected
        TEMPLATE=$(echo "$SELECTED_ITEM" | tr -d '"') # Store selection
        info "Selected Template: $TEMPLATE"
        CURRENT_STEP="set_hostname" # Move to next step
    else # Cancel pressed or no selection
        info "Template selection cancelled. Aborting."
        exit 0
    fi
  fi

  # --- Set Hostname ---
  if [[ "$CURRENT_STEP" == "set_hostname" ]]; then
      header_info
      DEFAULT_NAME=$(echo "$TEMPLATE" | cut -d'/' -f2 | cut -d'-' -f1)-$(echo "$TEMPLATE" | cut -d'/' -f2 | cut -d'-' -f2) # Basic name from template
      # --inputbox only has OK/Cancel. We can simulate "Back" by going to previous step on Cancel.
      USER_HN=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Enter Hostname" 10 60 "$DEFAULT_NAME" --ok-button "Next" --cancel-button "Back" 3>&1 1>&2 2>&3)
      EXIT_STATUS=$?

      if [ $EXIT_STATUS -eq 0 ]; then # Next pressed
          HN="${USER_HN:-$DEFAULT_NAME}" # Use user input or default if empty
          info "Using hostname: $HN"
          CURRENT_STEP="select_template_storage" # Move to next step
      else # Back pressed (Exit Status 1 for Cancel/Back)
          info "Returning to Template Selection."
          CURRENT_STEP="select_template" # <<<< Go back logic
          continue # Re-loop immediately
      fi
  fi

  # --- Storage Selection Function (Modified slightly for flow) ---
  # We'll embed the logic more directly later, for now keep the function call
  function select_storage_step() {
    local CLASS=$1 # 'container' or 'template'
    local CURRENT_STORAGE_VAR_NAME=$2 # Name of the variable to set (e.g., TEMPLATE_STORAGE)
    local NEXT_STEP_ON_SUCCESS=$3
    local PREVIOUS_STEP=$4

    local CONTENT
    local CONTENT_LABEL
    local AUTO_STORAGE="local" # Define the storage to check for automatically

    case $CLASS in
    container) CONTENT='rootdir'; CONTENT_LABEL='Container RootFS' ;;
    template) CONTENT='vztmpl'; CONTENT_LABEL='Container Template' ;;
    *) die "Internal error: Invalid storage class '$CLASS'." ;;
    esac

    header_info
    info "Selecting storage for $CONTENT_LABEL..."

    # MODIFICATION: Check if 'local' storage exists and supports the content type
    if pvesm status -storage "$AUTO_STORAGE" -content "$CONTENT" &>/dev/null; then
      info "Automatic selection: Found valid storage '$AUTO_STORAGE' for $CONTENT_LABEL."
      eval "$CURRENT_STORAGE_VAR_NAME=\"$AUTO_STORAGE\"" # Set the appropriate variable
      CURRENT_STEP="$NEXT_STEP_ON_SUCCESS" # Move to next step defined by caller
      return 0 # Indicate success
    else
      info "Storage '$AUTO_STORAGE' not found or doesn't support '$CONTENT'. Proceeding with manual selection."
    fi

    # --- Manual Selection (if 'local' wasn't suitable) ---
    local -a MENU=()
    local STORAGE_LIST
    STORAGE_LIST=$(pvesm status -content $CONTENT | awk 'NR>1')
    if [ -z "$STORAGE_LIST" ]; then
        whiptail --msgbox "Error: No storage location found with content type '$CONTENT'.\nPlease enable '$CONTENT' for at least one storage in Datacenter > Storage." 12 70
        CURRENT_STEP="$PREVIOUS_STEP" # Go back if no storage found
        return 1 # Indicate failure/back
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
    # --radiolist has OK/Cancel. Map Cancel to "Back"
    SELECTED_STORAGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Storage Selection: $CONTENT_LABEL" --radiolist \
        "Which storage pool for the ${CONTENT_LABEL}?\n(Storage '$AUTO_STORAGE' was not suitable or not found)\n\n" \
        20 $(($MSG_MAX_LENGTH + 25)) 10 \
        "${MENU[@]}" --ok-button "Next" --cancel-button "Back" 3>&1 1>&2 2>&3)
    EXIT_STATUS=$?

    if [ $EXIT_STATUS -eq 0 ] && [ -n "$SELECTED_STORAGE" ]; then # Next pressed
        info "Selected storage for $CONTENT_LABEL: $SELECTED_STORAGE"
        eval "$CURRENT_STORAGE_VAR_NAME=\"$SELECTED_STORAGE\"" # Set the appropriate variable
        CURRENT_STEP="$NEXT_STEP_ON_SUCCESS" # Move to next step
        return 0 # Indicate success
    else # Back pressed or no selection
        info "Returning to previous step."
        CURRENT_STEP="$PREVIOUS_STEP" # Go back logic
        return 1 # Indicate failure/back
    fi
  }

  # --- Select Template Storage ---
  if [[ "$CURRENT_STEP" == "select_template_storage" ]]; then
      # Call function: select storage for 'template', set TEMPLATE_STORAGE, next step is 'select_container_storage', previous is 'set_hostname'
      select_storage_step "template" "TEMPLATE_STORAGE" "select_container_storage" "set_hostname" || continue # If it returns failure/back, re-loop
      info "Using '$TEMPLATE_STORAGE' for template storage."
      sleep 1
  fi

  # --- Select Container Storage ---
  if [[ "$CURRENT_STEP" == "select_container_storage" ]]; then
      # Call function: select storage for 'container', set CONTAINER_STORAGE, next step is 'select_mounts', previous is 'select_template_storage'
      select_storage_step "container" "CONTAINER_STORAGE" "select_mounts" "select_template_storage" || continue # If it returns failure/back, re-loop
      info "Using '$CONTAINER_STORAGE' for container storage."
      sleep 1
  fi

  # --- Optional VirtIOFS Mounts ---
  if [[ "$CURRENT_STEP" == "select_mounts" ]]; then
      header_info
      SELECTED_MOUNTS=() # Reset choices
      declare -A MOUNT_OPTIONS
      MOUNT_OPTIONS["Echanges_PVE1"]="/mnt/pve_echanges1"
      MOUNT_OPTIONS["Echanges_PVE2"]="/mnt/pve_echanges2"

      AVAILABLE_MOUNTS_MENU=()
      for host_path in "${!MOUNT_OPTIONS[@]}"; do
          if [ -d "/$host_path" ]; then
              guest_path="${MOUNT_OPTIONS[$host_path]}"
              AVAILABLE_MOUNTS_MENU+=("$host_path" "Mount host /$host_path to $guest_path" "OFF")
          else
              warn "Host path /$host_path not found or is not a directory. Skipping option."
          fi
      done

      if [ ${#AVAILABLE_MOUNTS_MENU[@]} -gt 0 ]; then
          # --checklist has OK/Cancel. Map Cancel to "Back"
          CHOICES=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "VirtIOFS Mounts" --checklist \
          "\nSelect VirtIOFS shares to mount automatically:\n(Requires VirtIOFS support)\n(Space to toggle, Enter to confirm)" \
          15 70 5 "${AVAILABLE_MOUNTS_MENU[@]}" --ok-button "Next" --cancel-button "Back" 3>&1 1>&2 2>&3)
          EXIT_STATUS=$?

          if [ $EXIT_STATUS -eq 0 ]; then # Next pressed
              readarray -t SELECTED_MOUNTS <<< "$(echo "$CHOICES" | sed 's/"//g')"
              if [ ${#SELECTED_MOUNTS[@]} -gt 0 ]; then
                  info "Selected VirtIOFS mounts:"
                  for mount in "${SELECTED_MOUNTS[@]}"; do info "- Host: /$mount -> Guest: ${MOUNT_OPTIONS[$mount]}"; done
              else
                  info "No VirtIOFS mounts selected."
              fi
              CURRENT_STEP="confirm_summary" # Move to confirmation
          else # Back pressed
              info "Returning to Container Storage selection."
              CURRENT_STEP="select_container_storage" # Go back logic
              continue # Re-loop
          fi
      else
          info "No VirtIOFS host paths found or configured. Skipping mount selection."
          CURRENT_STEP="confirm_summary" # Skip to confirmation
      fi
      sleep 1
  fi

  # --- Confirmation Before Creation ---
  if [[ "$CURRENT_STEP" == "confirm_summary" ]]; then
      header_info
      CTID=$(pvesh get /cluster/nextid) # Get potential next ID for display
      PASS="$(openssl rand -base64 12)" # Generate password for display

      SUMMARY="=== LXC Configuration Summary ===\n\n"
      SUMMARY+="Template:        $TEMPLATE\n"
      SUMMARY+="Potential CT ID: $CTID\n"
      SUMMARY+="Hostname:        $HN\n"
      SUMMARY+="Root Password:   $PASS (will be set)\n"
      SUMMARY+="Template Storage: $TEMPLATE_STORAGE\n"
      SUMMARY+="RootFS Storage:  $CONTAINER_STORAGE\n"
      SUMMARY+="VirtIOFS Mounts:\n"
      if [ ${#SELECTED_MOUNTS[@]} -gt 0 ]; then
          for mount in "${SELECTED_MOUNTS[@]}"; do
              SUMMARY+="  - Host: /${mount} -> Guest: ${MOUNT_OPTIONS[$mount]}\n"
          done
      else
          SUMMARY+="  (None selected)\n"
      fi
      SUMMARY+="\nSystem Update:   YES (after creation)\n"
      SUMMARY+="Install Packages: YES (tree, curl, git - after update)\n"
      SUMMARY+="\n--------------------------------------\n"
      SUMMARY+="Ready to create this LXC?"

      # Use yesnocancel. Yes (0) -> Proceed. No (1) -> Go Back. Cancel (2) -> Exit Script.
      whiptail --backtitle "Proxmox VE Helper Scripts" --title "Confirm Creation" --yesno "$SUMMARY" 25 78 --yes-button "Create LXC" --no-button "Go Back" --cancel-button "Exit Script"
      EXIT_STATUS=$?

      case $EXIT_STATUS in
          0) # Yes (Create LXC)
              info "Configuration confirmed. Proceeding with creation..."
              CURRENT_STEP="create_lxc" # Move to the final creation step
              ;;
          1) # No (Go Back)
              info "Returning to VirtIOFS Mount selection."
              CURRENT_STEP="select_mounts" # <<< Go back logic
              PASS="" # Clear password as it might be regenerated
              CTID="" # Clear CTID as it might change
              continue # Re-loop immediately
              ;;
          2|255) # Cancel (Exit Script) or ESC
              info "Creation cancelled by user."
              exit 0
              ;;
      esac
  fi

  # --- Break Loop for Creation ---
  # If we reached the create step, exit the loop to perform actions
  if [[ "$CURRENT_STEP" == "create_lxc" ]]; then
      break # Exit the while loop
  fi

  # Safety net for unknown state
  if [[ ! "$CURRENT_STEP" =~ ^(start|select_template|set_hostname|select_template_storage|select_container_storage|select_mounts|confirm_summary|create_lxc)$ ]]; then
      die "Error: Unknown script state '$CURRENT_STEP'."
  fi

done # End of the main while loop

# --- Proceed with Actual Creation (Outside the loop) ---
# Variables (TEMPLATE, HN, TEMPLATE_STORAGE, CONTAINER_STORAGE, SELECTED_MOUNTS, PASS, CTID) should be set correctly now.
# Regenerate CTID and Password just in case, although confirmation showed them.
CTID=$(pvesh get /cluster/nextid)
PASS="$(openssl rand -base64 12)"

header_info
info "Starting LXC Creation Process..."

# --- Download Template ---
msg "Downloading LXC template '$TEMPLATE' from storage '$TEMPLATE_STORAGE'..."
pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null || die "Failed to download LXC template."

# --- Define PCT Options ---
PCT_OPTIONS=(
    -hostname "$HN" -net0 name=eth0,bridge=vmbr0,ip=dhcp
    -cores 2 -memory 2048 -onboot 0 -password "$PASS"
    -tags proxmox-helper-scripts,custom -unprivileged 1
    -features keyctl=1,nesting=1 -rootfs "$CONTAINER_STORAGE":8
    -arch $(dpkg --print-architecture)
)

# --- Create LXC ---
msg "Creating LXC container $CTID..."
pct create $CTID "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" "${PCT_OPTIONS[@]}" >/dev/null ||
  die "Failed to create LXC container $CTID."
info "LXC Container $CTID created."

# --- Configure VirtIOFS Mounts (if selected) ---
# (Keep the existing mount logic here)
declare -A MOUNT_OPTIONS # Re-declare for this scope if needed
MOUNT_OPTIONS["Echanges_PVE1"]="/mnt/pve_echanges1"
MOUNT_OPTIONS["Echanges_PVE2"]="/mnt/pve_echanges2"
MOUNT_INDEX=0
for mount_host_path in "${SELECTED_MOUNTS[@]}"; do
    mount_guest_path="${MOUNT_OPTIONS[$mount_host_path]}"
    info "Configuring mount point mp${MOUNT_INDEX}: Host='${mount_host_path}', Guest='${mount_guest_path}'"
    pct set $CTID -mp${MOUNT_INDEX} "${mount_host_path},mp=${mount_guest_path}" || warn "Failed to set mount point mp${MOUNT_INDEX} for $CTID."
    ((MOUNT_INDEX++))
done

# --- Save Credentials ---
# (Keep existing logic)
CREDS_FILE=~/"${HN}_${CTID}.creds"
echo "LXC Hostname: ${HN}" > "$CREDS_FILE"
echo "LXC ID: ${CTID}" >> "$CREDS_FILE"
echo "Root Password: ${PASS}" >> "$CREDS_FILE"
info "Credentials saved to $CREDS_FILE"

# --- Start Container ---
# (Keep existing logic)
msg "Starting LXC Container $CTID..."
pct start "$CTID" || die "Failed to start LXC container $CTID."
info "Waiting for container to boot..."
sleep 8

# --- Post-Start Operations ---
# (Keep existing logic: Create mount dirs, get IP, update, install packages)
msg "Creating mount point directories inside LXC (if needed)..."
for mount_host_path in "${SELECTED_MOUNTS[@]}"; do
    mount_guest_path="${MOUNT_OPTIONS[$mount_host_path]}"
    info "Creating directory '$mount_guest_path' inside LXC $CTID..."
    pct exec $CTID -- mkdir -p "$mount_guest_path" || warn "Failed to create directory '$mount_guest_path' inside LXC $CTID."
done

set +eEuo pipefail # Temporarily disable strict error checking for IP loop
max_attempts=6; attempt=1; IP=""
while [[ $attempt -le $max_attempts ]]; do
  IP=$(pct exec $CTID -- ip -4 addr show dev eth0 | grep -oP 'inet \K\d{1,3}(\.\d{1,3}){3}')
  [[ -n $IP ]] && { info "LXC IP Address found: $IP"; break; }
  warn "Attempt $attempt/$max_attempts: IP address not yet found. Waiting 5 seconds..."
  sleep 5; ((attempt++))
done
set -eEuo pipefail
[[ -z $IP ]] && { warn "Could not retrieve IP address for LXC $CTID."; IP="NOT FOUND"; }

header_info
info "Performing system update (apt update && apt upgrade -y) inside LXC $CTID..."
pct exec $CTID -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get -y upgrade' || warn "System update failed inside LXC $CTID."
info "System update completed."

info "Installing base packages (tree, curl, git) inside LXC $CTID..."
BASE_PACKAGES="tree curl git"
pct exec $CTID -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get install -y $BASE_PACKAGES" || warn "Failed to install base packages ($BASE_PACKAGES) inside LXC $CTID."
info "Base packages installation completed."

# --- Success Message ---
# (Keep existing logic)
header_info; echo
info "LXC container '$HN' (ID: $CTID) was successfully created and configured."
echo
info "IP Address: $IP"
info "Root Password: $PASS (also saved in $CREDS_FILE)"
echo
if [ ${#SELECTED_MOUNTS[@]} -gt 0 ]; then
    info "VirtIOFS Mounts configured:"
    for mount in "${SELECTED_MOUNTS[@]}"; do info "  - Host: /$mount -> Guest: ${MOUNT_OPTIONS[$mount]}"; done
    info "(Mounts should be active. Check with 'df -h' inside the LXC)."
fi
echo
info "LXC is updated and includes: tree, curl, git."
info "You can now access the LXC via console or SSH (if enabled)."
echo; msg "Done."

exit 0
