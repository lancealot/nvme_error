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

An example output from the interface:
```
Current NVME device errors:

Device          BUS:DEV.FNC     Serial               Current Error        Cumm Err       
-------------------------------------------------------------------------------------
nvme9           01:00.0         32241049XXXX         00000000             1              
nvme2           02:00.0         32241049XXXX         00000081             4354           
nvme3           03:00.0         32241049XXXX         00000000             0              
nvme4           04:00.0         31241045XXXX         00000000             0              
nvme6           05:00.0         MSA2509XXXX          00000000             0              
nvme5           06:00.0         MSA2509XXXX          00000000             0              
nvme0           c1:00.0         32241049XXXX         00000001             130            
nvme1           c2:00.0         32241049XXXX         00000081             322            
nvme8           c3:00.0         32241049XXXX         00000000             0              
nvme7           c4:00.0         31241045XXXX         00000000             0
```
