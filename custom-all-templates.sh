#!/usr/bin/env bash
# Copyright (c) 2021-2025 tteck
# Author: tteck (tteckster)
# License: MIT
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# --- MODIFIED VERSION - Step 2: Dynamic Package Selection ---

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
SELECTED_MOUNTS=()
SELECTED_PACKAGES=() # <-- New variable for selected packages
PASS=""
CTID=""
PACKAGE_LIST_URL="https://raw.githubusercontent.com/Basster04/mylxcconfig/refs/heads/main/lxc-packages.txt"

# --- Main Script Loop (State Machine) ---
while true; do

  # --- Initial Confirmation ---
  if [[ "$CURRENT_STEP" == "start" ]]; then
    header_info
    if whiptail --backtitle "Proxmox VE Helper Scripts" --title "Custom LXC Creation" --yesno "This script will guide you through creating a customized LXC container.\n\nPackages will be offered from:\n$PACKAGE_LIST_URL\n\nProceed?" 12 78; then
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
    pveam update >/dev/null 2>&1 # Ensure list is fresh

    TEMPLATE_MENU=()
    MSG_MAX_LENGTH=0
    while read -r TAG ITEM; do
      OFFSET=2
      ((${#ITEM} + OFFSET > MSG_MAX_LENGTH)) && MSG_MAX_LENGTH=${#ITEM}+OFFSET
      TEMPLATE_MENU+=("$ITEM" "$TAG " "OFF")
    done < <(pveam available -section system | awk 'NR>1') # Filter for system templates

    if [ ${#TEMPLATE_MENU[@]} -eq 0 ]; then
        die "No 'system' LXC templates found. Update PVE templates ('pveam update') or check filters."
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
          # Basic hostname validation
          if [[ ! "$HN" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]$|^[a-zA-Z0-9]$ ]]; then
              whiptail --msgbox "Invalid hostname format. Please use alphanumeric characters and hyphens (not at start/end)." 10 60
              # Stay in the current step
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
    local CONTENT; local CONTENT_LABEL; local AUTO_STORAGE="local";

    case $CLASS in
    container) CONTENT='rootdir'; CONTENT_LABEL='Container RootFS' ;;
    template) CONTENT='vztmpl'; CONTENT_LABEL='Container Template' ;;
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
      info "Storage '$AUTO_STORAGE' not found or doesn't support '$CONTENT'. Proceeding with manual selection."
    fi

    local -a MENU=()
    local STORAGE_LIST
    STORAGE_LIST=$(pvesm status -content $CONTENT | awk 'NR>1')
    if [ -z "$STORAGE_LIST" ]; then
        whiptail --msgbox "Error: No storage location found with content type '$CONTENT'.\nPlease enable '$CONTENT' for at least one storage in Datacenter > Storage." 12 70
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
        "Which storage pool for the ${CONTENT_LABEL}?\n(Storage '$AUTO_STORAGE' was not suitable or not found)\n\n" \
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
      select_storage_step "container" "CONTAINER_STORAGE" "select_mounts" "select_template_storage" || continue
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
      # Add more potential mounts here if needed

      AVAILABLE_MOUNTS_MENU=()
      for host_path in "${!MOUNT_OPTIONS[@]}"; do
          if [ -d "/${host_path}" ]; then
              guest_path="${MOUNT_OPTIONS[$host_path]}"
              AVAILABLE_MOUNTS_MENU+=("$host_path" "Mount host /${host_path} to ${guest_path}" "OFF")
          else
              warn "Host path /${host_path} not found or is not a directory. Skipping option."
          fi
      done

      if [ ${#AVAILABLE_MOUNTS_MENU[@]} -gt 0 ]; then
          CHOICES=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "VirtIOFS Mounts" --checklist \
          "\nSelect VirtIOFS shares to mount automatically:\n(Requires VirtIOFS support in kernel/LXC config)\n(Space to toggle, Enter to confirm)" \
          15 70 5 "${AVAILABLE_MOUNTS_MENU[@]}" --ok-button "Next" --cancel-button "Back" 3>&1 1>&2 2>&3)
          EXIT_STATUS=$?

          if [ $EXIT_STATUS -eq 0 ]; then
              # Process choices even if empty
              readarray -t SELECTED_MOUNTS <<< "$(echo "$CHOICES" | sed 's/"//g')"
              if [ ${#SELECTED_MOUNTS[@]} -gt 0 ]; then
                  info "Selected VirtIOFS mounts:"
                  for mount in "${SELECTED_MOUNTS[@]}"; do info "- Host: /${mount} -> Guest: ${MOUNT_OPTIONS[$mount]}"; done
              else
                  info "No VirtIOFS mounts selected."
              fi
              CURRENT_STEP="select_packages" # <<< Move to package selection
          else
              info "Returning to Container Storage selection."
              CURRENT_STEP="select_container_storage"
              continue
          fi
      else
          info "No valid VirtIOFS host paths found or configured. Skipping mount selection."
          CURRENT_STEP="select_packages" # <<< Move to package selection
      fi
      sleep 1
  fi

  # --- Select Packages ---
  if [[ "$CURRENT_STEP" == "select_packages" ]]; then
      header_info
      info "Fetching package list from $PACKAGE_LIST_URL..."
      # Download the package list to the temp file
      if ! curl -sSL "$PACKAGE_LIST_URL" -o "$TEMP_PACKAGE_LIST"; then
          warn "Failed to download package list from $PACKAGE_LIST_URL."
          # Ask user if they want to proceed without package selection or go back
          if whiptail --yesno "Failed to fetch the package list. \nDo you want to skip optional package installation and proceed?" 10 60 --yes-button "Skip Packages" --no-button "Go Back"; then
             SELECTED_PACKAGES=() # Ensure package list is empty
             info "Skipping optional package installation."
             CURRENT_STEP="confirm_summary" # Proceed to summary
          else
             info "Returning to VirtIOFS Mount selection."
             CURRENT_STEP="select_mounts" # Go back
             continue
          fi
      elif ! [ -s "$TEMP_PACKAGE_LIST" ]; then # Check if file is empty
           warn "Package list file downloaded but is empty."
           if whiptail --yesno "The fetched package list is empty. \nDo you want to skip optional package installation and proceed?" 10 60 --yes-button "Skip Packages" --no-button "Go Back"; then
             SELECTED_PACKAGES=()
             info "Skipping optional package installation as list was empty."
             CURRENT_STEP="confirm_summary"
          else
             info "Returning to VirtIOFS Mount selection."
             CURRENT_STEP="select_mounts"
             continue
          fi
      else
          # Build whiptail checklist menu from the downloaded file
          PACKAGE_MENU=()
          while IFS= read -r pkg_name; do
              # Skip empty lines or lines starting with # (comments)
              [[ -z "$pkg_name" ]] || [[ "$pkg_name" =~ ^#.* ]] && continue
              # Use package name for both tag and description, add OFF state
              PACKAGE_MENU+=("$pkg_name" "$pkg_name" "OFF")
          done < "$TEMP_PACKAGE_LIST"

          if [ ${#PACKAGE_MENU[@]} -eq 0 ]; then
              info "No valid packages found in the list. Skipping selection."
              SELECTED_PACKAGES=()
              CURRENT_STEP="confirm_summary"
              sleep 1 # Give user time to see message
          else
              CHOICES=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Select Optional Packages" --checklist \
              "\nSelect packages to install after OS update:\n(Source: $PACKAGE_LIST_URL)\n(Space to toggle, Enter to confirm)" \
              20 70 12 "${PACKAGE_MENU[@]}" --ok-button "Next" --cancel-button "Back" 3>&1 1>&2 2>&3)
              EXIT_STATUS=$?

              if [ $EXIT_STATUS -eq 0 ]; then # Next pressed
                  readarray -t SELECTED_PACKAGES <<< "$(echo "$CHOICES" | sed 's/"//g')"
                  if [ ${#SELECTED_PACKAGES[@]} -gt 0 ]; then
                      info "Selected packages for installation:"
                      for pkg in "${SELECTED_PACKAGES[@]}"; do info "- $pkg"; done
                  else
                      info "No optional packages selected."
                  fi
                  CURRENT_STEP="confirm_summary" # Move to confirmation
              else # Back pressed
                  info "Returning to VirtIOFS Mount selection."
                  CURRENT_STEP="select_mounts" # Go back logic
                  continue # Re-loop
              fi
          fi
      fi
      sleep 1
  fi


  # --- Confirmation Before Creation ---
  if [[ "$CURRENT_STEP" == "confirm_summary" ]]; then
      header_info
      CTID=$(pvesh get /cluster/nextid)
      PASS="$(openssl rand -base64 12)"

      SUMMARY="=== LXC Configuration Summary ===\n\n"
      SUMMARY+="Template:         $TEMPLATE\n"
      SUMMARY+="Potential CT ID:  $CTID\n"
      SUMMARY+="Hostname:         $HN\n"
      SUMMARY+="Root Password:    $PASS (will be set)\n"
      SUMMARY+="Template Storage: $TEMPLATE_STORAGE\n"
      SUMMARY+="RootFS Storage:   $CONTAINER_STORAGE\n"
      SUMMARY+="VirtIOFS Mounts:\n"
      if [ ${#SELECTED_MOUNTS[@]} -gt 0 ]; then
          for mount in "${SELECTED_MOUNTS[@]}"; do
              SUMMARY+="  - Host: /${mount} -> Guest: ${MOUNT_OPTIONS[$mount]}\n"
          done
      else
          SUMMARY+="  (None selected)\n"
      fi
      SUMMARY+="System Update:    YES (after creation)\n"
      SUMMARY+="Selected Packages:\n" # <-- Modified section
      if [ ${#SELECTED_PACKAGES[@]} -gt 0 ]; then
          for pkg in "${SELECTED_PACKAGES[@]}"; do
              SUMMARY+="  - $pkg\n"
          done
      else
          SUMMARY+="  (None selected)\n"
      fi
      SUMMARY+="\n--------------------------------------\n"
      SUMMARY+="Ready to create this LXC?"

      whiptail --backtitle "Proxmox VE Helper Scripts" --title "Confirm Creation" --yesno "$SUMMARY" 28 78 --yes-button "Create LXC" --no-button "Go Back" --cancel-button "Exit Script"
      EXIT_STATUS=$?

      case $EXIT_STATUS in
          0) # Yes (Create LXC)
              info "Configuration confirmed. Proceeding with creation..."
              CURRENT_STEP="create_lxc"
              ;;
          1) # No (Go Back)
              info "Returning to Package selection."
              CURRENT_STEP="select_packages" # <<< Go back logic to packages step
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
      break
  fi

  # Safety net for unknown state
  if [[ ! "$CURRENT_STEP" =~ ^(start|select_template|set_hostname|select_template_storage|select_container_storage|select_mounts|select_packages|confirm_summary|create_lxc)$ ]]; then
      die "Error: Unknown script state '$CURRENT_STEP'."
  fi

done # End of the main while loop

# --- Proceed with Actual Creation (Outside the loop) ---
# Regenerate CTID and Password for security, although confirmation showed potential ones.
CTID=$(pvesh get /cluster/nextid)
PASS="$(openssl rand -base64 12)"

header_info
info "Starting LXC Creation Process..."

# --- Download Template ---
msg "Downloading LXC template '$TEMPLATE' to storage '$TEMPLATE_STORAGE'..."
pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null || die "Failed to download LXC template '$TEMPLATE'."

# --- Define PCT Options ---
# Ensure architecture matches host unless cross-compiling is intended/supported
HOST_ARCH=$(dpkg --print-architecture)
PCT_OPTIONS=(
    -hostname "$HN" -net0 name=eth0,bridge=vmbr0,ip=dhcp
    -cores 2 -memory 2048 -onboot 0 -password "$PASS"
    -tags proxmox-helper-scripts,custom -unprivileged 1
    -features keyctl=1,nesting=1 -rootfs "$CONTAINER_STORAGE":8
    -arch "$HOST_ARCH"
)
# Add specific template architecture if needed, e.g. for arm64 on x86 host via emulation (less common for LXC)
# if [[ "$TEMPLATE" == *"arm64"* ]]; then PCT_OPTIONS+=(-arch arm64); fi

# --- Create LXC ---
msg "Creating LXC container $CTID..."
# Use eval to handle potential spaces in arguments correctly (though less likely here)
eval pct create "$CTID" \"${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}\" "${PCT_OPTIONS[@]}" >/dev/null ||
  die "Failed to create LXC container $CTID."
info "LXC Container $CTID created."

# --- Configure VirtIOFS Mounts (if selected) ---
declare -A MOUNT_OPTIONS # Re-declare for this scope if needed
MOUNT_OPTIONS["Echanges_PVE1"]="/mnt/pve_echanges1"
MOUNT_OPTIONS["Echanges_PVE2"]="/mnt/pve_echanges2"
MOUNT_INDEX=0
if [ ${#SELECTED_MOUNTS[@]} -gt 0 ]; then
    info "Configuring VirtIOFS mount points..."
    for mount_host_path_key in "${SELECTED_MOUNTS[@]}"; do
        # Ensure the key exists in MOUNT_OPTIONS before using it
        if [[ -v MOUNT_OPTIONS["$mount_host_path_key"] ]]; then
            mount_guest_path="${MOUNT_OPTIONS[$mount_host_path_key]}"
            host_full_path="/${mount_host_path_key}" # Assuming keys are relative paths from /
            info "Configuring mount point mp${MOUNT_INDEX}: Host='${host_full_path}', Guest='${mount_guest_path}'"
            # Ensure host path exists before setting mount
            if [ -d "$host_full_path" ]; then
                pct set $CTID -mp${MOUNT_INDEX} "${host_full_path},mp=${mount_guest_path},backup=0" || warn "Failed to set mount point mp${MOUNT_INDEX} for $CTID."
                ((MOUNT_INDEX++))
            else
                warn "Host path '${host_full_path}' for mount point mp${MOUNT_INDEX} does not exist or is not a directory. Skipping."
            fi
        else
             warn "Mount key '$mount_host_path_key' not found in MOUNT_OPTIONS definition. Skipping."
        fi
    done
fi

# --- Save Credentials ---
CREDS_DIR=~/.config/proxmox-helper-scripts # Store creds in a hidden dir
mkdir -p "$CREDS_DIR"
CREDS_FILE="${CREDS_DIR}/${HN}_${CTID}.creds"
echo "LXC Hostname: ${HN}" > "$CREDS_FILE"
echo "LXC ID: ${CTID}" >> "$CREDS_FILE"
echo "Root Password: ${PASS}" >> "$CREDS_FILE"
chmod 600 "$CREDS_FILE" # Secure permissions
info "Credentials saved to $CREDS_FILE"

# --- Start Container ---
msg "Starting LXC Container $CTID..."
pct start "$CTID" || die "Failed to start LXC container $CTID."
info "Waiting for container to boot and network..."
sleep 8

# --- Post-Start Operations ---

# Create mount point directories inside LXC if needed
if [ ${#SELECTED_MOUNTS[@]} -gt 0 ]; then
    msg "Creating mount point directories inside LXC (if needed)..."
    for mount_host_path_key in "${SELECTED_MOUNTS[@]}"; do
         if [[ -v MOUNT_OPTIONS["$mount_host_path_key"] ]]; then
            mount_guest_path="${MOUNT_OPTIONS[$mount_host_path_key]}"
            info "Creating directory '$mount_guest_path' inside LXC $CTID..."
            # Use -p to avoid errors if it already exists
            pct exec $CTID -- mkdir -p "$mount_guest_path" || warn "Attempt to create directory '$mount_guest_path' inside LXC $CTID failed (may already exist)."
        fi
    done
fi

# Get IP Address
set +eEuo pipefail # Temporarily disable strict error checking for IP loop
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
    warn "Could not retrieve IPv4 address for eth0 on LXC $CTID. Check network configuration."
    IP="NOT FOUND"
fi

# Update LXC System
header_info
info "Performing system update (apt update && apt upgrade -y) inside LXC $CTID..."
pct exec $CTID -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get -y upgrade' || warn "System update failed inside LXC $CTID."
info "System update completed."

# Install Selected Packages <--- MODIFIED SECTION
if [ ${#SELECTED_PACKAGES[@]} -gt 0 ]; then
    PACKAGES_TO_INSTALL=$(echo "${SELECTED_PACKAGES[@]}" | tr '\n' ' ') # Join array with spaces
    info "Installing selected packages ($PACKAGES_TO_INSTALL) inside LXC $CTID..."
    pct exec $CTID -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get install -y $PACKAGES_TO_INSTALL" || warn "Failed to install selected packages inside LXC $CTID."
    info "Selected packages installation completed."
else
    info "No optional packages were selected for installation."
fi

# --- Success Message ---
header_info; echo
info "LXC container '$HN' (ID: $CTID) was successfully created and configured."
echo
info "IP Address: $IP"
info "Root Password: $PASS (also saved in $CREDS_FILE)"
echo
if [ ${#SELECTED_MOUNTS[@]} -gt 0 ]; then
    info "VirtIOFS Mounts configured:"
    for mount_key in "${SELECTED_MOUNTS[@]}"; do
        if [[ -v MOUNT_OPTIONS["$mount_key"] ]]; then
             info "  - Host: /${mount_key} -> Guest: ${MOUNT_OPTIONS[$mount_key]}"
         fi
    done
    info "(Mounts should be active. Check with 'df -h' inside the LXC)."
    echo
fi
if [ ${#SELECTED_PACKAGES[@]} -gt 0 ]; then
    info "Installed optional packages:"
    for pkg in "${SELECTED_PACKAGES[@]}"; do info "  - $pkg"; done
    echo
fi
info "LXC is updated. You can now access the LXC via console or SSH (if enabled)."
echo; msg "Done."

exit 0
