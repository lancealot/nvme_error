NVME Error Monitor

Description:
   This script monitors PCIe Advanced Error Reporting (AER) for NVME devices.
   It displays real-time error counts and maintains cumulative error totals
   for each device. The script maps NVME devices to their PCI addresses and
   displays their serial numbers for easy identification.

 Operation:
   - Maps PCI addresses to NVME device numbers using udevadm
   - Retrieves serial numbers using 'nvme list' command
   - Monitors AER registers using setpci
   - Tracks both current and cumulative errors
   - Resets error counters after each read

 Output Columns:
   - Device:       NVME device number (e.g., nvme0)
   - BUS:DEV.FNC:  PCI address of the device
   - Serial:       Device serial number
   - Current Error: Current error count in AER register
   - Cumm Err:     Cumulative error count since script start

 Dependencies:
   - nvme-cli package (for nvme list command)
   - setpci command
   - udevadm command
   - Standard Linux utilities (awk, sed, grep)

Example output:

Current NVME device errors:

Device          BUS:DEV.FNC     Serial               Current Error        Cumm Err       
-------------------------------------------------------------------------------------
nvme9           01:00.0				3224104941F2         00000081             129            
nvme2           02:00.0				32241049423D         00000081             129            
nvme3           03:00.0         3224104941F1         00000001             1              
nvme4           04:00.0         312410457617         00000000             0              
nvme6           05:00.0         MSA250901BW          00000000             0              
nvme5           06:00.0         MSA250901BX          00000000             0              
nvme0           c1:00.0         32241049428A         00000081             129            
nvme1           c2:00.0         322410494289         00000081             129            
nvme8           c3:00.0         32241049428B         00000000             0              
nvme7           c4:00.0         312410457603         00000000             0 
