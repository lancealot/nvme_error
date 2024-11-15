#!/bin/bash

# =============================================================================
# NVME Error Monitor
# =============================================================================
#
# Description:
#   This script monitors PCIe Advanced Error Reporting (AER) for NVME devices.
#   It displays real-time error counts and maintains cumulative error totals
#   for each device. The script maps NVME devices to their PCI addresses and
#   displays their serial numbers for easy identification.
#
# Operation:
#   - Maps PCI addresses to NVME device numbers using udevadm
#   - Retrieves serial numbers using 'nvme list' command
#   - Monitors AER registers using setpci
#   - Tracks both current and cumulative errors
#   - Resets error counters after each read
#
# Output Columns:
#   - Device:       NVME device number (e.g., nvme0)
#   - BUS:DEV.FNC:  PCI address of the device
#   - Serial:       Device serial number
#   - Current Error: Current error count in AER register
#   - Cumm Err:     Cumulative error count since script start
#
# Dependencies:
#   - nvme-cli package (for nvme list command)
#   - setpci command
#   - udevadm command
#   - Standard Linux utilities (awk, sed, grep)
# =============================================================================

# Function to display help message
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Monitor NVME device errors using PCIe Advanced Error Reporting (AER).

Options:
    -d    Display current status and exit (single run mode)
    -j    Output data in JSON format and exit
    -h    Display this help message and exit

When run without options, the script continuously monitors errors,
updating the display every 2 seconds.
EOF
    exit 0
}

# Check for help flag
if [[ "$1" == "-h" ]]; then
    show_help
fi

# Check for flags
SINGLE_RUN=false
JSON_OUTPUT=false
if [[ "$1" == "-d" ]]; then
    SINGLE_RUN=true
elif [[ "$1" == "-j" ]]; then
    JSON_OUTPUT=true
elif [[ "$1" != "" ]]; then
    echo "Invalid option: $1" >&2
    echo "Use -h for help" >&2
    exit 1
else
    clear
fi

# Initialize an associative array to track cumulative errors
declare -A CUMM_ERR
declare -A DEVICE_MAP
declare -A SERIAL_MAP

# Function to build device mapping
build_device_mapping() {
    local nvme_devices=($(ls /dev/nvme[0-9] 2>/dev/null))
    for nvme_dev in "${nvme_devices[@]}"; do
        # Extract PCI address from udevadm
        local pci_path=$(udevadm info --query=path --name="$nvme_dev")
        if [[ $pci_path =~ /0000:([0-9a-f]{2}:[0-9]{2}\.[0-9])/nvme ]]; then
            local pci_addr=${BASH_REMATCH[1]}
            local nvme_name=$(basename "$nvme_dev")
            DEVICE_MAP[$pci_addr]=$nvme_name
        fi
    done
}

# Function to build serial number mapping
build_serial_mapping() {
    while IFS= read -r line; do
        # Use awk to properly split fields and get device and serial number
        local device=$(echo "$line" | awk '{print $1}' | sed 's/\/dev\/\(nvme[0-9]\+\)n1/\1/')
        local serial=$(echo "$line" | awk '{print $3}')
        if [[ ! -z "$device" && ! -z "$serial" ]]; then
            SERIAL_MAP[$device]=$serial
        fi
    done < <(nvme list | grep -v "Node")
}

# Function to display JSON output
display_json() {
    # Start JSON array
    echo "{"
    echo "  \"timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\","
    echo "  \"devices\": ["
    
    local first=true
    for DEVICE in $(lspci | grep "Non-Volatile memory controller" | awk '{print $1}'); do
        # Read current error count
        CURRENT_ERR=$(setpci -s $DEVICE ECAP_AER+10.l)
        
        # Update cumulative errors
        if [[ -z ${CUMM_ERR[$DEVICE]} ]]; then
            CUMM_ERR[$DEVICE]=0
        fi
        CUMM_ERR[$DEVICE]=$((CUMM_ERR[$DEVICE] + 0x$CURRENT_ERR))
        
        # Reset current error counter
        setpci -s $DEVICE ECAP_AER+10.l=31c1
        
        # Get the NVME device name and serial number
        NVME_DEV="${DEVICE_MAP[$DEVICE]:-N/A}"
        SERIAL="${SERIAL_MAP[$NVME_DEV]:-N/A}"
        
        # Add comma if not first entry
        if [ "$first" = true ]; then
            first=false
        else
            echo ","
        fi
        
        # Print device info as JSON object
        cat << EOF
    {
      "device": "$NVME_DEV",
      "pci_address": "$DEVICE",
      "serial": "$SERIAL",
      "current_error": "$CURRENT_ERR",
      "cumulative_errors": ${CUMM_ERR[$DEVICE]}
    }
EOF
    done
    
    # Close JSON array and object
    echo -e "\n  ]"
    echo "}"
}

# Function to display regular output
display_output() {
    # Print title
    echo "Current NVME device errors:"
    echo
    
    # Print the header
    printf "%-15s %-15s %-20s %-20s %-15s\n" "Device" "BUS:DEV.FNC" "Serial" "Current Error" "Cumm Err"
    printf "%s\n" "$(printf '%.0s-' {1..85})"

    for DEVICE in $(lspci | grep "Non-Volatile memory controller" | awk '{print $1}'); do
        # Read current error count
        CURRENT_ERR=$(setpci -s $DEVICE ECAP_AER+10.l)
        
        # Update cumulative errors
        if [[ -z ${CUMM_ERR[$DEVICE]} ]]; then
            CUMM_ERR[$DEVICE]=0
        fi
        CUMM_ERR[$DEVICE]=$((CUMM_ERR[$DEVICE] + 0x$CURRENT_ERR))
        
        # Reset current error counter
        setpci -s $DEVICE ECAP_AER+10.l=31c1
        
        # Get the NVME device name and serial number
        NVME_DEV="${DEVICE_MAP[$DEVICE]:-N/A}"
        SERIAL="${SERIAL_MAP[$NVME_DEV]:-N/A}"
        
        # Print the information in neatly arranged columns
        printf "%-15s %-15s %-20s %-20s %-15s\n" \
            "$NVME_DEV" \
            "$DEVICE" \
            "$SERIAL" \
            "$CURRENT_ERR" \
            "${CUMM_ERR[$DEVICE]}"
    done
}

# Build initial mappings
build_device_mapping
build_serial_mapping

if [ "$JSON_OUTPUT" = true ]; then
    # JSON output mode
    display_json
elif [ "$SINGLE_RUN" = true ]; then
    # Single run mode
    display_output
else
    # Continuous monitoring mode
    while true; do
        # Move the cursor to the top
        echo -en \\033[H
        display_output
        sleep 2
    done
fi
