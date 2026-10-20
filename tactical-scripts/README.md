# Tactical RMM scripts for Standard Computer

PowerShell 5.1 scripts for dental-office workstations and servers (Windows 10, Windows 11, and Windows Server). The Tactical RMM agent runs each script non-interactively as `NT AUTHORITY\SYSTEM`.

Each script is self-contained. Paste one file into Script Manager. Do not expect it to load a shared module from this folder.

Safety rules for every script:

- Exit `0` when the check passes. Exit non-zero when it fails or cannot run. Tactical raises an alert from the exit code.
- The last line of stdout is `EXITCODE: N`. Tactical's ad-hoc command runner does not show the process exit code. Script checks still use the real exit code.
- A text field that is null or blank prints as `n/a`. A numeric zero stays `0` when zero is a real measurement.
- Idempotent. Running a script again does not pile on changes.
- No reboot unless that script is given `-AllowReboot`.
- No service stop or start unless that script is given `-AllowServiceRestart`.
- No stored passwords, API keys, or vendor warranty credentials.
- Cleanup never deletes dental images, Dentrix data, or user documents.

## Import into Tactical

1. Open the Tactical RMM dashboard.
2. Go to **Settings > Script Manager**.
3. Click **Add Script**.
4. Set **Shell** to **PowerShell**. Leave "run as logged-in user" off so the agent runs as SYSTEM.
5. Paste the full contents of the `.ps1` file into the script body.
6. Set the name, description, category (`Standard Computer`), timeout, and default arguments from the table below.
7. Save.

Run it from an agent with **Run Script**, or alert on it with a **Script Check** (a non-zero exit code fails the check). For Microsoft 365 and Windows Update, raise the timeout on the check as well as on the script.

Default arguments are optional. Switches are off unless you add them, for example `-Cleanup` or `-AllowReboot`.

## Scripts

| Script | Purpose | Parameters | Exit 0 | Exit 1 | Exit 2 | Timeout |
| --- | --- | --- | --- | --- | --- | --- |
| `Get-DiskHealth.ps1` | SMART / `Get-PhysicalDisk` health, reliability counters, read errors, HDD vs SSD, and age. Fails when a disk is unhealthy. | `-MaxWearPercent` (default `90`), `-IncludeRemovable` | All in-scope disks are healthy | One or more disks are unhealthy | Disk health could not be queried | 120 seconds |
| `Test-DiskSpace.ps1` | Free-space threshold. `-Cleanup` removes aged temp files, the Windows Update download cache, and recycle bins. | `-MinFreePercent` (default `15`), `-DriveLetter`, `-MinVolumeGB` (default `20`), `-Cleanup`, `-MinFileAgeDays` (default `1`), `-AllowServiceRestart` | Selected volumes are at or above the threshold | A volume is below the threshold | Space could not be queried, or a service did not restart | 300 seconds. Use 600 with `-Cleanup` |
| `Install-Microsoft365Apps.ps1` | Install 64-bit Microsoft 365 Apps with the Office Deployment Tool on the Current channel. Skips a matching install. | `-Product` (`O365BusinessRetail` or `O365ProPlusRetail`, required), `-Language` (default `en-us`), `-OdtUrl`, `-AllowAppShutdown`, `-AllowReboot`, `-RemoveExistingMsi`, `-SharedComputerLicensing`, `-ForceOdtDownload` | Requested 64-bit product is already installed, or setup finished | Install refused, setup failed, or a reboot is still required | Product id missing, or the deployment tool could not be downloaded | 5400 seconds |
| `Test-Windows11Readiness.ps1` | TPM 2.0, Secure Boot, UEFI, CPU, RAM, and system disk. | `-MinRamGB` (default `4`), `-MinDiskGB` (default `64`), `-MinFreeGB` (default `20`) | Ready, already on Windows 11, or Windows Server | A Windows 10 client is not ready | Readiness data could not be collected | 180 seconds |
| `Get-HardwareInventory.ps1` | JSON inventory: model, serial, CPU, RAM and channel layout, GPU and VRAM, disks, OS build, warranty identifiers. | None | Model and serial were collected | Inventory ran, but model or serial is missing | Inventory could not be collected | 180 seconds |
| `Test-GpuVram.ps1` | Dedicated VRAM for CBCT viewers. Reads `qwMemorySize` because WMI caps at 4 GB. | `-MinVRAMGB` (default `4`) | A dedicated GPU meets the minimum | No dedicated GPU, or VRAM is under the minimum | Dedicated GPU present, but `qwMemorySize` was not readable | 120 seconds |
| `Test-PendingReboot.ps1` | Component Based Servicing, Windows Update, pending file rename, and computer rename. Does not reboot. | None | No reboot is pending | A reboot is pending | Reboot state could not be read | 60 seconds |
| `Get-WindowsUpdateStatus.ps1` | Last quality-update install and the pending software-update count. Definition updates are excluded. Does not install updates. | `-MaxPending` (default `0`), `-MaxDaysSinceInstall` (default `45`) | Pending count and install age are within limits | Too many pending updates, or the last install is too old | Pending count or history could not be queried | 1200 seconds |
| `Test-ImagingBridge.ps1` | Reports Clever One, EzDent-i, Ez3D-i, EzServer, and other imaging apps. Fails when Clever One and EzDent-i are both installed. | None | No Clever One / EzDent-i conflict | Both bridges are installed | Uninstall registry could not be read | 120 seconds |
| `Get-LocalAdminAudit.ps1` | Lists local Administrators. RID 500 and Domain Admins (RID 512) are expected. | `-AllowedPrincipal`, `-FailOnBuiltInAdminEnabled` | Every member is expected | An unexpected admin is present | The group could not be enumerated | 120 seconds |
| `Get-ReplacementSurvey.ps1` | Read-only survey for a replacement PC or server. Prints a summary, then one JSON line, and saves both under ProgramData. | `-OutputPath` | Survey collected and both files saved | Survey collected, but a file could not be saved | Computer and OS details could not be read, or the host is not Windows | 300 seconds |

GB in these scripts is a gibibyte (`1024^3`), which is what PowerShell means by `GB`.

## What each script is for

### Disk health

Checks internal physical disks. USB, SD, and MMC disks are skipped unless `-IncludeRemovable` is set. A disk fails when health is not `Healthy`, operational status is not `OK` or `In Service`, uncorrected read or write errors are greater than zero, or SSD wear is at or above `-MaxWearPercent`. Read and write counters that come back null print as `n/a`. Wear of `0` also prints as `n/a`, because Windows uses 0 when the drive does not expose wear; that display does not fail the disk. When every in-scope disk has wear and all read/write counters as `n/a`, the result line is `RESULT: Pass (limited data)` and the next line is `Data: limited, only the Windows health flag is available`. The exit code stays `0`. A pass that includes a real counter, including a real zero, stays `RESULT: Pass`. Trailing dots and spaces are removed from the serial number.

Age uses the first source that has a real value: power-on hours greater than zero from `Get-StorageReliabilityCounter`, the manufacture date, power-on hours from `MSFT_StorageReliabilityCounter` matched by device id, the WMI disk install date, then the OS install date. The OS date is labeled `estimated from OS install date` so it is not mistaken for SMART age. Power-on hours of 0 are treated as not reported. Hardware RAID and some storage controllers do not expose reliability counters; the script still uses the Windows health status and says when counters are missing.

### Disk space

Checks fixed volumes that have a drive letter and are at least `-MinVolumeGB`. Volumes smaller than that are usually recovery partitions and are skipped unless you pass `-DriveLetter`.

`-Cleanup` only removes:

- files older than `-MinFileAgeDays` in `C:\Windows\Temp` and each profile's `AppData\Local\Temp`
- files in `C:\Windows\SoftwareDistribution\Download`
- the contents of `\$Recycle.Bin` on each fixed drive

Locked files and reparse points are skipped. The running script file is left in place. BITS and Windows Update are stopped and started again only when `-Cleanup` and `-AllowServiceRestart` are both set. Without that switch, the cache is still cleaned as far as Windows allows while the services stay up.

### Microsoft 365 Apps

`-Product O365BusinessRetail` is Microsoft 365 Apps for business. `-Product O365ProPlusRetail` is Microsoft 365 Apps for enterprise. The configuration is 64-bit, Current channel, silent, and EULA accepted. Shared computer licensing stays off unless `-SharedComputerLicensing` is set for an RDS server. `RemoveMSI` stays off unless `-RemoveExistingMsi` is set, so an existing volume-license Office install is not removed by surprise.

If the requested product is already installed as 64-bit, the script does not download or reinstall. A different product or a 32-bit install is left alone and the script exits `1`. Office desktop apps that are open block setup unless `-AllowAppShutdown` is passed. `-AllowReboot` schedules `shutdown.exe /r /t 60` only when setup returns 3010.

The deployment tool is downloaded from the Microsoft download page (id 49117), or from `-OdtUrl` when you already have a direct link. A previously extracted `setup.exe` under `C:\ProgramData\StandardComputer\Tactical\OfficeODT` is reused. The Office installer can restart the Click-to-Run service. This script does not stop Windows Update, imaging, or other Windows services.

### Windows 11 readiness

Reports firmware, Secure Boot, TPM, CPU, RAM, system-volume size, and free space. Windows Server exits `0` with `Not applicable` because it is not a Windows 11 upgrade. A PC already on Windows 11 exits `0`; requirement gaps are printed as informational.

CPU support is a heuristic for common workstation processors (Intel Core 8th generation and newer, including Core Ultra, and AMD Ryzen / Threadripper 2000 series and newer). Xeon, Athlon, EPYC, and virtual CPUs come back as `Review`, which fails a Windows 10 client closed so the tech confirms the Microsoft supported-CPU list before an upgrade. Pentium, Celeron, and Atom are treated as not supported by this heuristic.

### Hardware inventory

Prints one JSON document to standard output, then `EXITCODE: N` on the next line. Warranty fields are the manufacturer, model, SKU, serial, asset tag, BIOS version and date, baseboard identity, and SMBIOS UUID. The script does not call Dell, HP, or Lenovo warranty APIs. VRAM uses the same `qwMemorySize` registry value as the GPU check. Memory channel mode is inferred from SMBIOS locators such as `ChannelA-DIMM0`. When those labels are missing, two equal modules are reported as dual channel and the basis line says that it was inferred.

Blank text fields are `n/a`. Numeric fields that were not collected stay JSON `null`. Disk wear and power-on hours of 0 are stored as `null` because Windows uses 0 when the drive does not report them. Trailing dots and spaces are removed from serial numbers.

Exit `1` means the inventory ran but model or serial is blank, so a warranty lookup would not have a key. The JSON still shows `n/a` for that field. The exit decision uses the raw value, before `n/a` is substituted.

### GPU / VRAM

For CBCT and imaging PCs. The pass/fail decision uses `qwMemorySize` on the display-class registry key (`HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}`). If that exact name is missing, `HardwareInformation.qwMemorySize` is used. `Win32_VideoController.AdapterRAM` is ignored.

NVIDIA, AMD Radeon RX / Pro, and Intel Arc count as dedicated. Intel UHD / Iris, AMD `Radeon(TM) Graphics`, the Basic Display Adapter, and remote-display drivers do not. The largest dedicated adapter is compared with `-MinVRAMGB` after rounding to 0.1 GB. A front desk PC with only integrated graphics fails. Assign the script to imaging machines.

### Pending reboot

Prints each signal as `PENDING` or `clear`. Pending file rename can be set by application installers as well as Windows Update, so read which signal fired before sending someone on site to reboot. This script never reboots.

### Windows Update status

Uses the Windows Update Agent COM API and the PC's configured source (Microsoft Update or WSUS). Definition updates, including Defender security intelligence, are excluded from the pending count and from the "last quality install" date. The registry `LastSuccessTime` value is a fallback when history does not contain a quality update. The script does not download or install anything. Give it a long timeout; the search often takes several minutes.

### Imaging bridge

Reads both 32-bit and 64-bit HKLM uninstall keys and reports version, publisher, and install location for Clever One, EzDent-i, Ez3D-i, and EzServer. Dentrix, VixWin, Carestream / CS Imaging, DEXIS, Sidexis, and Romexis are reported when present. Matching imaging services are listed with state and file version. Services are not stopped. Exit `1` only for the Clever One plus EzDent-i conflict. A PC with no imaging software exits `0`. Per-user installs are not visible to SYSTEM, and this script does not load user hives.

### Local admin audit

Enumerates the local Administrators group (SID `S-1-5-32-544`) through ADSI, and falls back to CIM if ADSI throws. Built-in Administrator (any SID ending in `-500`) and Domain Admins (SID ending in `-512`) are expected. Add MSP accounts with `-AllowedPrincipal 'CONTOSO\Tech'`. A value without a slash matches the account name only. `-FailOnBuiltInAdminEnabled` fails the audit when the RID 500 user is enabled. The script does not remove anyone.

### Replacement survey

Collects the facts a tech needs to order a replacement workstation or server: identity, form factor, display outputs, monitors, GPU and VRAM, CPU, RAM, disks, network, USB and COM ports, connected USB devices, printers, OS, dental software, and laptop battery health. It is read-only. It does not prompt. Tactical runs it as SYSTEM. SimpleHelp can run it as SYSTEM or as an administrator. Registry reads use the 64-bit view, so a 32-bit PowerShell host still sees 64-bit uninstall keys and `qwMemorySize`.

Stdout is the full summary, then one compact JSON line, then `EXITCODE: N`. Tactical and SimpleHelp both show stdout. The same summary is written to a `.txt` file and the JSON line to a `.json` file. The default folder is `C:\ProgramData\StandardComputer\Survey`, created if needed. The names are `<COMPUTERNAME>_<yyyyMMdd>.txt` and `.json`. Characters outside letters, digits, `.`, `_`, and `-` in the computer name become `_`. Running it again the same day overwrites those two files.

`-OutputPath` overrides that location. A directory, including one with a trailing slash, keeps the default file names. A path that ends in `.json` or `.txt` uses that base name for both files.

Ship dates from an HP serial, a Dell PPID, or the SMBIOS BIOS release date are labeled estimates. Lenovo serials are not decoded. GPU port counts taken from the model name are labeled estimated and are not treated as connected ports. A `Needs VGA output` note is set only when VGA is reported or a monitor is connected with VGA. `Uses N monitors` counts external monitors. `Dedicated GPU required (CBCT)` is set only when a dedicated GPU and imaging software are both present. Windows 11 readiness is informational and does not change the survey exit code.

Exit `1` means the summary and JSON were still printed, but saving a file failed. Exit `2` means the host is not Windows, or both the computer and the operating system could not be read. Missing WMI values stay `n/a` and are listed as collection gaps; they still exit `0` when the files save.

Name this script `Get-ReplacementSurvey` in Script Manager. The PC script does not contain an API key or any cloud address.

### Collect surveys on the box

`collector/collect_surveys.py` runs on the Standard Computer box. It reads the latest `Get-ReplacementSurvey` result from Tactical script history and writes files you can upload to OneDrive yourself. This tool does not upload anywhere.

Install the only dependency, then set the API values in the environment. The key is sent as the `X-API-KEY` header and is not written into the PC script:

```bash
pip install -r tactical-scripts/collector/requirements.txt
export TACTICAL_API_URL='https://api.standardcomputer.com'
export TACTICAL_API_KEY='paste-the-key-here'
```

`TACTICAL_API_URL` defaults to `https://api.standardcomputer.com` when it is unset. Pass a client, or pass agent ids:

```bash
python tactical-scripts/collector/collect_surveys.py --client "Front Desk Dental" --out ./surveys
python tactical-scripts/collector/collect_surveys.py --out ./surveys AGENTID1 AGENTID2
```

`--client` accepts the client name or the numeric client id. Repeat `--agent` if you prefer flags to positional ids.

The folder receives one JSON file per PC, plus `surveys.csv` and `surveys.xlsx`. Each spreadsheet row is one PC. Columns include identity, form factor, displays, CPU, RAM, disks, network, ports, dental software, and `replacement_notes`.

History is read with GET `/agents/scripthistory/?scriptname=Get-ReplacementSurvey`. Client and agent lookups use GET `/clients/`, GET `/agents/`, and GET `/agents/<agent_id>/`. The Script Manager name must match `--script-name` (default `Get-ReplacementSurvey`).

`--run` is the only request that changes anything, and only for agents whose latest history has no survey JSON. It POSTs `/agents/<agent_id>/runscript/` for that script alone, with `output` set to `wait`, empty arguments, and `run_as_user` false. It does not reboot, shut down, run a command, or edit the agent. Omit `--run` and the tool stays on GET.

Exit `0` means every matched agent was saved. Exit `1` means at least one agent had no usable survey; the other PCs are still written. Exit `2` means the key is missing, the client or script name was not found, or the API could not be read.

## Checks that could not be executed here

CI runs on Linux. It parses every script, runs PSScriptAnalyzer for errors, and runs Pester against the decision logic (thresholds, CPU heuristic, VRAM registry selection, Office XML, imaging conflict, admin allow list, reboot signals, JSON shape). It does not have a Windows disk, TPM, Office Click-to-Run, Windows Update Agent, or Tactical agent. These paths still need a Windows 10/11 or Server machine:

- `Get-PhysicalDisk` / `Get-StorageReliabilityCounter` output and RAID controllers that hide SMART. A Windows 11 24H2 run on a Crucial P3 500 GB NVMe returned Pass with null error counters, wear 0, no power-on hours, and a serial that ended in a dot. The display fixes for that output are covered by Pester. The CIM power-on-hour, disk-install-date, and OS-install-date fallbacks still need a Windows machine that lacks SMART hours.
- temp, Windows Update cache, and recycle-bin deletion, including the `-AllowServiceRestart` service stop and start
- Office Deployment Tool download, extract, and `setup.exe /configure`, including a 3010 reboot
- `Win32_Tpm`, `Confirm-SecureBootUEFI`, and the firmware registry on real hardware
- `qwMemorySize` on NVIDIA, AMD, and Intel Arc drivers versus the 4 GB WMI cap
- Windows Update COM search against Microsoft Update or WSUS
- HKLM uninstall entries and Vatech / Clever One service image paths
- ADSI local-group enumeration, including orphaned SIDs and a renamed built-in Administrator
- JSON field population from WMI on a physical dental PC
- `Get-ReplacementSurvey.ps1` live WMI, EDID, display-config, and `C:\ProgramData\StandardComputer\Survey` writes. Chassis, port, serial-date, software, note, path, and JSON mapping are covered by Pester.
- A live call from `collector/collect_surveys.py` to the Tactical API. Parsing, the GET-only path, the `--run` fallback, and the CSV/XLSX files are covered by `collector/test_collect_surveys.py`.
