# NVME Error Monitor
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
