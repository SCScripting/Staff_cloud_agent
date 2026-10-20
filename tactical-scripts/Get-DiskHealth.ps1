<#
.SYNOPSIS
    Report physical disk health for Tactical RMM.

.DESCRIPTION
    Purpose: Check SMART-style health for internal disks on a dental office
    workstation or server. Reports Get-PhysicalDisk health, reliability
    counters, corrected and uncorrected read errors, HDD versus SSD, and age.
    A null counter prints as n/a. Wear of 0 prints as n/a because Windows
    uses 0 when the drive does not report wear; that value does not fail
    the disk. Age uses power-on hours when they are greater than zero, then
    the manufacture date, then MSFT_StorageReliabilityCounter power-on hours,
    then the WMI disk install date, then the OS install date labeled as an
    estimate. Fails when a disk is unhealthy. A pass whose wear and read/write
    counters are all n/a prints RESULT: Pass (limited data), because that
    pass uses only the Windows health flag. A pass with a real counter
    stays RESULT: Pass. The exit code is still 0.

    Parameters:
      -MaxWearPercent    Used SSD life percent that fails the disk. Default 90.
      -IncludeRemovable  Also check USB, SD, and MMC disks. Default is internal
                         disks only.

.NOTES
    Standard Computer Tactical RMM script. Windows PowerShell 5.1. Run as SYSTEM.
    Idempotent. Does not reboot and does not restart services.
    Does not use credentials.
    Serial numbers have trailing dots and spaces removed.
    The last stdout line is EXITCODE: N. Tactical ad-hoc command output does
    not show the process exit code.

    Exit codes:
      0  Every in-scope disk is healthy.
      1  One or more in-scope disks are unhealthy.
      2  Disk health could not be queried.

.EXAMPLE
    .\Get-DiskHealth.ps1 -MaxWearPercent 80
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(1, 100)]
    [int]$MaxWearPercent = 90,

    [switch]$IncludeRemovable
)

function Test-DhWindowsHost {
    $variable = Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue
    if ($null -eq $variable) {
        return $true
    }
    return [bool]$variable.Value
}

function Write-DhResult {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Pass', 'Pass (limited data)', 'Fail', 'Error')]
        [string]$Result,

        [Parameter(Mandatory = $true)]
        [string]$Summary
    )

    Write-Output ('RESULT: {0}' -f $Result)
    if ($Result -eq 'Pass (limited data)') {
        Write-Output 'Data: limited, only the Windows health flag is available'
    }
    Write-Output ('Summary: {0}' -f $Summary)
}

function Convert-DhBusType {
    param($BusType)

    $map = @{
        0 = 'Unknown'; 1 = 'SCSI'; 2 = 'ATAPI'; 3 = 'ATA'; 4 = '1394'; 5 = 'SSA'
        6 = 'Fibre'; 7 = 'USB'; 8 = 'RAID'; 9 = 'iSCSI'; 10 = 'SAS'; 11 = 'SATA'
        12 = 'SD'; 13 = 'MMC'; 14 = 'Virtual'; 15 = 'File Backed Virtual'
        16 = 'Storage Spaces'; 17 = 'NVMe'; 18 = 'SCM'; 19 = 'UFS'
    }
    if ($null -eq $BusType) {
        return 'Unknown'
    }
    $text = [string]$BusType
    if ($text -match '^\d+$') {
        $number = [int]$text
        if ($map.ContainsKey($number)) {
            return [string]$map[$number]
        }
    }
    return $text
}

function Convert-DhMediaType {
    param($MediaType)

    $map = @{
        0 = 'Unspecified'
        3 = 'HDD'
        4 = 'SSD'
        5 = 'SCM'
    }
    if ($null -eq $MediaType) {
        return 'Unspecified'
    }
    $text = [string]$MediaType
    if ($text -match '^\d+$') {
        $number = [int]$text
        if ($map.ContainsKey($number)) {
            return [string]$map[$number]
        }
    }
    return $text
}

function Convert-DhHealthStatus {
    param($HealthStatus)

    $map = @{
        0 = 'Healthy'
        1 = 'Warning'
        2 = 'Unhealthy'
        5 = 'Unknown'
    }
    if ($null -eq $HealthStatus) {
        return ''
    }
    $text = [string]$HealthStatus
    if ($text -match '^\d+$') {
        $number = [int]$text
        if ($map.ContainsKey($number)) {
            return [string]$map[$number]
        }
    }
    return $text
}

function Convert-DhOperationalStatus {
    param($Value)

    $map = @{
        0 = 'Unknown'; 1 = 'Other'; 2 = 'OK'; 3 = 'Degraded'; 4 = 'Stressed'
        5 = 'Predictive Failure'; 6 = 'Error'; 7 = 'Non-Recoverable Error'
        8 = 'Starting'; 9 = 'Stopping'; 10 = 'Stopped'; 11 = 'In Service'
        12 = 'No Contact'; 13 = 'Lost Communication'; 14 = 'Aborted'
        15 = 'Dormant'; 16 = 'Supporting Entity in Error'; 17 = 'Completed'
        18 = 'Power Mode'; 19 = 'Relocating'
    }
    $items = @()
    foreach ($entry in @($Value)) {
        if ($null -eq $entry) {
            continue
        }
        $text = [string]$entry
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }
        if ($text -match '^\d+$') {
            $number = [int]$text
            if ($map.ContainsKey($number)) {
                $items += [string]$map[$number]
                continue
            }
        }
        $items += $text.Trim()
    }
    return $items
}

function Test-DhDiskInScope {
    param(
        [string]$BusType,
        [bool]$IncludeRemovable
    )

    if ($IncludeRemovable) {
        return $true
    }
    $removable = @('USB', 'SD', 'MMC')
    return ($removable -notcontains $BusType)
}

function Get-DhMediaKind {
    param(
        $MediaType,
        $SpindleSpeed,
        $BusType
    )

    $media = [string]$MediaType
    if ($media -match 'SSD|SCM') {
        return 'SSD'
    }
    if ($media -match 'HDD') {
        return 'HDD'
    }
    $speedText = [string]$SpindleSpeed
    if ($speedText -match '^\d+$' -and [int]$speedText -gt 0) {
        return 'HDD'
    }
    if ([string]$BusType -eq 'NVMe') {
        return 'SSD'
    }
    if ([string]::IsNullOrWhiteSpace($media) -or $media -eq 'Unspecified') {
        return 'Unspecified'
    }
    return $media
}

function Test-DhPositiveCount {
    param($Value)

    if ($null -eq $Value) {
        return $false
    }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $false
    }
    $number = [int64]0
    if (-not [int64]::TryParse($text, [ref]$number)) {
        return $false
    }
    return ($number -gt 0)
}

function Test-DhDiskState {
    param(
        [string]$HealthStatus,
        [string[]]$OperationalStatus,
        $ReadErrorsUncorrected,
        $WriteErrorsUncorrected,
        $Wear,
        [bool]$ApplyWear,
        [int]$MaxWearPercent
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($HealthStatus) -or $HealthStatus -ne 'Healthy') {
        $shown = $HealthStatus
        if ([string]::IsNullOrWhiteSpace($shown)) {
            $shown = 'missing'
        }
        $reasons.Add("HealthStatus is $shown")
    }

    $healthyOps = @('OK', 'In Service')
    foreach ($status in @($OperationalStatus)) {
        if ([string]::IsNullOrWhiteSpace($status)) {
            continue
        }
        $trimmed = $status.Trim()
        if ($healthyOps -notcontains $trimmed) {
            $reasons.Add("OperationalStatus is $trimmed")
        }
    }

    if (Test-DhPositiveCount -Value $ReadErrorsUncorrected) {
        $reasons.Add("uncorrected read errors = $ReadErrorsUncorrected")
    }
    if (Test-DhPositiveCount -Value $WriteErrorsUncorrected) {
        $reasons.Add("uncorrected write errors = $WriteErrorsUncorrected")
    }
    if ($ApplyWear -and $null -ne $Wear) {
        $wearText = [string]$Wear
        $wearNumber = [int]0
        if ([int]::TryParse($wearText, [ref]$wearNumber) -and $wearNumber -ge $MaxWearPercent) {
            $reasons.Add("wear $wearNumber percent is at or above $MaxWearPercent percent")
        }
    }

    [pscustomobject]@{
        Healthy = ($reasons.Count -eq 0)
        Reasons = @($reasons)
    }
}

function Format-DhCalendarAge {
    param(
        $Value,
        [datetime]$Now,
        [string]$Label
    )

    if ($null -eq $Value) {
        return $null
    }
    $date = [datetime]$Value
    if ($date.Year -le 1990 -or $date -gt $Now) {
        return $null
    }
    $days = [math]::Floor(($Now - $date).TotalDays)
    $ageYears = [math]::Round($days / 365.25, 1)
    $ageText = $ageYears.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    return ('{0} {1} ({2} years ago)' -f $Label, $date.ToString('yyyy-MM-dd'), $ageText)
}

function Test-DhReportedAge {
    param([string[]]$Part)

    foreach ($entry in @($Part)) {
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }
        if ($entry -notmatch 'was unreadable') {
            return $true
        }
    }
    return $false
}

function Format-DhAge {
    param(
        $PowerOnHours,
        $ManufactureDate,
        [datetime]$Now,
        $DiskInstallDate,
        $OsInstallDate
    )

    $parts = @()
    $hourText = [string]$PowerOnHours
    $hours = [int64]0
    if ($hourText -match '^\d+$' -and [int64]::TryParse($hourText, [ref]$hours) -and $hours -gt 0) {
        $years = [math]::Round($hours / 8760, 1)
        $yearText = $years.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $parts += "power-on $hours hours ($yearText years)"
    }

    if ($null -ne $ManufactureDate -and -not [string]::IsNullOrWhiteSpace([string]$ManufactureDate)) {
        try {
            $madeText = Format-DhCalendarAge -Value ([datetime]$ManufactureDate) -Now $Now -Label 'manufactured'
            if ($null -ne $madeText) {
                $parts += $madeText
            }
        } catch {
            $parts += 'manufacture date was unreadable'
        }
    }

    if (-not (Test-DhReportedAge -Part $parts)) {
        if ($null -ne $DiskInstallDate -and -not [string]::IsNullOrWhiteSpace([string]$DiskInstallDate)) {
            try {
                $diskText = Format-DhCalendarAge -Value ([datetime]$DiskInstallDate) -Now $Now -Label 'disk install date'
                if ($null -ne $diskText) {
                    $parts += $diskText
                }
            } catch {
                $parts += 'disk install date was unreadable'
            }
        }
    }

    if (-not (Test-DhReportedAge -Part $parts)) {
        if ($null -ne $OsInstallDate -and -not [string]::IsNullOrWhiteSpace([string]$OsInstallDate)) {
            try {
                $osText = Format-DhCalendarAge -Value ([datetime]$OsInstallDate) -Now $Now -Label 'estimated from OS install date'
                if ($null -ne $osText) {
                    $parts += $osText
                }
            } catch {
                $parts += 'OS install date was unreadable'
            }
        }
    }

    if (-not (Test-DhReportedAge -Part $parts)) {
        return 'n/a'
    }
    return ($parts -join '; ')
}

function Format-DhText {
    param($Value)

    if ($null -eq $Value) {
        return 'n/a'
    }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return 'n/a'
    }
    return $text
}

function Test-DhLimitedData {
    param(
        $ReadTotal,
        $ReadCorrected,
        $ReadUncorrected,
        $WriteTotal,
        $WriteUncorrected,
        $Wear
    )

    if ((Format-DhWear -Wear $Wear) -ne 'n/a') {
        return $false
    }
    foreach ($value in @($ReadTotal, $ReadCorrected, $ReadUncorrected, $WriteTotal, $WriteUncorrected)) {
        if ((Format-DhText -Value $value) -ne 'n/a') {
            return $false
        }
    }
    return $true
}

function Get-DhPassResult {
    param([bool[]]$Limited)

    $sawDisk = $false
    foreach ($item in @($Limited)) {
        $sawDisk = $true
        if (-not $item) {
            return 'Pass'
        }
    }
    if (-not $sawDisk) {
        return 'Pass'
    }
    return 'Pass (limited data)'
}

function Format-DhWear {
    param($Wear)

    if ($null -eq $Wear) {
        return 'n/a'
    }
    $text = ([string]$Wear).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return 'n/a'
    }
    $number = 0.0
    $style = [System.Globalization.NumberStyles]::Float
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if (-not [double]::TryParse($text, $style, $culture, [ref]$number)) {
        return 'n/a'
    }
    if ($number -le 0) {
        return 'n/a'
    }
    return $number.ToString($culture)
}

function Format-DhSerial {
    param($Serial)

    if ($null -eq $Serial) {
        return 'n/a'
    }
    $text = ([string]$Serial).Trim()
    $text = $text -replace '[\s\.]+$', ''
    if ([string]::IsNullOrWhiteSpace($text)) {
        return 'n/a'
    }
    return $text
}

function Format-DhGb {
    param($Bytes)

    if ($null -eq $Bytes -or [string]::IsNullOrWhiteSpace([string]$Bytes)) {
        return 'n/a'
    }
    $number = [double]$Bytes / 1073741824
    return ([math]::Round($number, 1)).ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-DhProperty {
    param(
        $Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-DhPhysicalDisk {
    $command = Get-Command -Name 'Get-PhysicalDisk' -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return @(Get-PhysicalDisk -ErrorAction Stop)
    }
    return @(Get-CimInstance -Namespace 'root\microsoft\windows\storage' -ClassName 'MSFT_PhysicalDisk' -ErrorAction Stop)
}

function Get-DhReliabilityCounter {
    param($Disk)

    $command = Get-Command -Name 'Get-StorageReliabilityCounter' -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return $null
    }
    try {
        return ($Disk | Get-StorageReliabilityCounter -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Get-DhPositiveHour {
    param($Value)

    $text = [string]$Value
    $hours = [int64]0
    if ($text -match '^\d+$' -and [int64]::TryParse($text, [ref]$hours) -and $hours -gt 0) {
        return $hours
    }
    return $null
}

function Get-DhCimReliabilityCounter {
    try {
        return @(Get-CimInstance -Namespace 'root\microsoft\windows\storage' -ClassName 'MSFT_StorageReliabilityCounter' -ErrorAction Stop)
    } catch {
        return @()
    }
}

function Resolve-DhPowerOnHour {
    param(
        $Counter,
        $DeviceId,
        $CimCounter
    )

    $fromCmdlet = Get-DhPositiveHour -Value (Get-DhProperty -Object $Counter -Name 'PowerOnHours')
    if ($null -ne $fromCmdlet) {
        return $fromCmdlet
    }

    $wanted = [string]$DeviceId
    if ([string]::IsNullOrWhiteSpace($wanted)) {
        return $null
    }
    foreach ($cim in @($CimCounter)) {
        $id = [string](Get-DhProperty -Object $cim -Name 'DeviceId')
        if ($id -ne $wanted) {
            continue
        }
        return Get-DhPositiveHour -Value (Get-DhProperty -Object $cim -Name 'PowerOnHours')
    }
    return $null
}

function Get-DhDiskInstallDate {
    param(
        [string]$Serial,
        $DiskDrive
    )

    if ([string]::IsNullOrWhiteSpace($Serial) -or $Serial -eq 'n/a') {
        return $null
    }
    foreach ($drive in @($DiskDrive)) {
        $driveSerial = Format-DhSerial -Serial (Get-DhProperty -Object $drive -Name 'SerialNumber')
        if ($driveSerial -eq 'n/a') {
            continue
        }
        if (-not $driveSerial.Equals($Serial, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        return Get-DhProperty -Object $drive -Name 'InstallDate'
    }
    return $null
}

function Get-DhOsInstallDate {
    try {
        $os = Get-CimInstance -ClassName 'Win32_OperatingSystem' -ErrorAction Stop
        return Get-DhProperty -Object $os -Name 'InstallDate'
    } catch {
        return $null
    }
}

function Get-DhDiskDrive {
    try {
        return @(Get-CimInstance -ClassName 'Win32_DiskDrive' -ErrorAction Stop)
    } catch {
        return @()
    }
}

function Invoke-DhMain {
    param(
        [int]$MaxWearPercent = 90,
        [bool]$IncludeRemovable = $false
    )

    $script:ScExitCode = 2
    try {
        if (-not (Test-DhWindowsHost)) {
            Write-DhResult -Result Error -Summary 'This script must run on Windows.'
            return
        }

        Write-Output ('Computer: {0}' -f $env:COMPUTERNAME)
        Write-Output ('Time: {0}' -f (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK'))
        Write-Output ('Wear fail threshold: {0} percent' -f $MaxWearPercent)
        if ($IncludeRemovable) {
            Write-Output 'Removable disks: included'
        } else {
            Write-Output 'Removable disks: skipped (USB, SD, MMC). Pass -IncludeRemovable to check them.'
        }

        $rawDisks = @(Get-DhPhysicalDisk)
        if ($rawDisks.Count -eq 0) {
            Write-DhResult -Result Error -Summary 'No physical disks were returned.'
            return
        }

        $now = Get-Date
        $cimCounters = @(Get-DhCimReliabilityCounter)
        $diskDrives = @(Get-DhDiskDrive)
        $osInstall = Get-DhOsInstallDate
        $checked = 0
        $limited = New-Object System.Collections.Generic.List[bool]
        $failed = New-Object System.Collections.Generic.List[string]
        $index = 0
        foreach ($raw in $rawDisks) {
            $bus = Convert-DhBusType -BusType (Get-DhProperty -Object $raw -Name 'BusType')
            $media = Convert-DhMediaType -MediaType (Get-DhProperty -Object $raw -Name 'MediaType')
            $health = Convert-DhHealthStatus -HealthStatus (Get-DhProperty -Object $raw -Name 'HealthStatus')
            $ops = @(Convert-DhOperationalStatus -Value (Get-DhProperty -Object $raw -Name 'OperationalStatus'))
            $kind = Get-DhMediaKind -MediaType $media -SpindleSpeed (Get-DhProperty -Object $raw -Name 'SpindleSpeed') -BusType $bus
            $inScope = Test-DhDiskInScope -BusType $bus -IncludeRemovable ([bool]$IncludeRemovable)
            $counter = $null
            if ($inScope) {
                $counter = Get-DhReliabilityCounter -Disk $raw
            }

            $friendly = [string](Get-DhProperty -Object $raw -Name 'FriendlyName')
            if ([string]::IsNullOrWhiteSpace($friendly)) {
                $friendly = [string](Get-DhProperty -Object $raw -Name 'Model')
            }
            if ([string]::IsNullOrWhiteSpace($friendly)) {
                $friendly = 'Disk ' + $index
            }

            $readTotal = Get-DhProperty -Object $counter -Name 'ReadErrorsTotal'
            $readCorrected = Get-DhProperty -Object $counter -Name 'ReadErrorsCorrected'
            $readUncorrected = Get-DhProperty -Object $counter -Name 'ReadErrorsUncorrected'
            $writeTotal = Get-DhProperty -Object $counter -Name 'WriteErrorsTotal'
            $writeUncorrected = Get-DhProperty -Object $counter -Name 'WriteErrorsUncorrected'
            $wear = Get-DhProperty -Object $counter -Name 'Wear'
            $applyWear = ($kind -eq 'SSD')
            $evaluation = $null
            $evaluationText = 'not checked'
            if ($inScope) {
                $checked++
                $limited.Add((Test-DhLimitedData -ReadTotal $readTotal -ReadCorrected $readCorrected -ReadUncorrected $readUncorrected -WriteTotal $writeTotal -WriteUncorrected $writeUncorrected -Wear $wear))
                $evaluation = Test-DhDiskState -HealthStatus $health -OperationalStatus $ops -ReadErrorsUncorrected $readUncorrected -WriteErrorsUncorrected $writeUncorrected -Wear $wear -ApplyWear $applyWear -MaxWearPercent $MaxWearPercent
                if ($evaluation.Healthy) {
                    $evaluationText = 'Pass'
                } else {
                    $evaluationText = 'Fail (' + ($evaluation.Reasons -join '; ') + ')'
                    $failed.Add($friendly)
                }
            }

            $serial = Format-DhSerial -Serial (Get-DhProperty -Object $raw -Name 'SerialNumber')
            $powerOn = Resolve-DhPowerOnHour -Counter $counter -DeviceId (Get-DhProperty -Object $raw -Name 'DeviceId') -CimCounter $cimCounters
            $diskInstall = Get-DhDiskInstallDate -Serial $serial -DiskDrive $diskDrives

            Write-Output ''
            Write-Output ('Disk {0}: {1}' -f $index, $friendly)
            Write-Output ('  Serial: {0}' -f $serial)
            Write-Output ('  Media: {0}' -f (Format-DhText -Value $kind))
            Write-Output ('  Bus: {0}' -f (Format-DhText -Value $bus))
            Write-Output ('  SizeGB: {0}' -f (Format-DhGb -Bytes (Get-DhProperty -Object $raw -Name 'Size')))
            Write-Output ('  Firmware: {0}' -f (Format-DhText -Value (Get-DhProperty -Object $raw -Name 'FirmwareVersion')))
            Write-Output ('  HealthStatus: {0}' -f (Format-DhText -Value $health))
            Write-Output ('  OperationalStatus: {0}' -f ($(if ($ops.Count -eq 0) { 'n/a' } else { $ops -join ', ' })))
            Write-Output ('  ReadErrorsTotal: {0}' -f (Format-DhText -Value $readTotal))
            Write-Output ('  ReadErrorsCorrected: {0}' -f (Format-DhText -Value $readCorrected))
            Write-Output ('  ReadErrorsUncorrected: {0}' -f (Format-DhText -Value $readUncorrected))
            Write-Output ('  WriteErrorsTotal: {0}' -f (Format-DhText -Value $writeTotal))
            Write-Output ('  WriteErrorsUncorrected: {0}' -f (Format-DhText -Value $writeUncorrected))
            Write-Output ('  WearPercent: {0}' -f (Format-DhWear -Wear $wear))
            Write-Output ('  TemperatureC: {0}' -f (Format-DhText -Value (Get-DhProperty -Object $counter -Name 'Temperature')))
            Write-Output ('  Age: {0}' -f (Format-DhAge -PowerOnHours $powerOn -ManufactureDate (Get-DhProperty -Object $counter -Name 'ManufactureDate') -Now $now -DiskInstallDate $diskInstall -OsInstallDate $osInstall))
            if ($null -eq $counter -and $inScope) {
                Write-Output '  Reliability counters: unavailable'
            }
            Write-Output ('  InScope: {0}' -f $inScope)
            Write-Output ('  Evaluation: {0}' -f $evaluationText)
            $index++
        }

        Write-Output ''
        if ($checked -eq 0) {
            Write-DhResult -Result Pass -Summary 'No internal disks were in scope. Removable disks were skipped.'
            $script:ScExitCode = 0
            return
        }
        if ($failed.Count -gt 0) {
            Write-DhResult -Result Fail -Summary ('{0} of {1} in-scope disks unhealthy: {2}' -f $failed.Count, $checked, ($failed -join ', '))
            $script:ScExitCode = 1
            return
        }
        $passResult = Get-DhPassResult -Limited @($limited.ToArray())
        Write-DhResult -Result $passResult -Summary ('{0} in-scope disks healthy.' -f $checked)
        $script:ScExitCode = 0
    } catch {
        Write-DhResult -Result Error -Summary $_.Exception.Message
        $script:ScExitCode = 2
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $script:ScExitCode = 2
    try {
        Invoke-DhMain -MaxWearPercent $MaxWearPercent -IncludeRemovable ([bool]$IncludeRemovable) | Out-Host
    } catch {
        Write-Output 'RESULT: Error' | Out-Host
        Write-Output ('Summary: {0}' -f $_.Exception.Message) | Out-Host
        $script:ScExitCode = 2
    }
    Write-Output ('EXITCODE: {0}' -f $script:ScExitCode) | Out-Host
    exit $script:ScExitCode
}
