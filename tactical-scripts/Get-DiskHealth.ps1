<#
.SYNOPSIS
    Report physical disk health for Tactical RMM.

.DESCRIPTION
    Purpose: Check SMART-style health for internal disks on a dental office
    workstation or server. Reports Get-PhysicalDisk health, reliability
    counters, corrected and uncorrected read errors, HDD versus SSD, and age
    when the drive exposes it. Fails when a disk is unhealthy.

    Parameters:
      -MaxWearPercent    Used SSD life percent that fails the disk. Default 90.
      -IncludeRemovable  Also check USB, SD, and MMC disks. Default is internal
                         disks only.

.NOTES
    Standard Computer Tactical RMM script. Windows PowerShell 5.1. Run as SYSTEM.
    Idempotent. Does not reboot and does not restart services.
    Does not use credentials.

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
        [ValidateSet('Pass', 'Fail', 'Error')]
        [string]$Result,

        [Parameter(Mandatory = $true)]
        [string]$Summary
    )

    Write-Output ('RESULT: {0}' -f $Result)
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

function Format-DhAge {
    param(
        $PowerOnHours,
        $ManufactureDate,
        [datetime]$Now
    )

    $parts = @()
    $hourText = [string]$PowerOnHours
    if ($hourText -match '^\d+$') {
        $hours = [int64]$hourText
        $years = [math]::Round($hours / 8760, 1)
        $yearText = $years.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $parts += "power-on $hours hours ($yearText years)"
    }

    if ($null -ne $ManufactureDate -and -not [string]::IsNullOrWhiteSpace([string]$ManufactureDate)) {
        try {
            $made = [datetime]$ManufactureDate
            if ($made.Year -gt 1990 -and $made -le $Now) {
                $days = [math]::Floor(($Now - $made).TotalDays)
                $ageYears = [math]::Round($days / 365.25, 1)
                $ageText = $ageYears.ToString([System.Globalization.CultureInfo]::InvariantCulture)
                $parts += ('manufactured {0} ({1} years ago)' -f $made.ToString('yyyy-MM-dd'), $ageText)
            }
        } catch {
            $parts += 'manufacture date was unreadable'
        }
    }

    if ($parts.Count -eq 0) {
        return 'n/a'
    }
    return ($parts -join '; ')
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
        $checked = 0
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

            $readUncorrected = Get-DhProperty -Object $counter -Name 'ReadErrorsUncorrected'
            $writeUncorrected = Get-DhProperty -Object $counter -Name 'WriteErrorsUncorrected'
            $wear = Get-DhProperty -Object $counter -Name 'Wear'
            $applyWear = ($kind -eq 'SSD')
            $evaluation = $null
            $evaluationText = 'not checked'
            if ($inScope) {
                $checked++
                $evaluation = Test-DhDiskState -HealthStatus $health -OperationalStatus $ops -ReadErrorsUncorrected $readUncorrected -WriteErrorsUncorrected $writeUncorrected -Wear $wear -ApplyWear $applyWear -MaxWearPercent $MaxWearPercent
                if ($evaluation.Healthy) {
                    $evaluationText = 'Pass'
                } else {
                    $evaluationText = 'Fail (' + ($evaluation.Reasons -join '; ') + ')'
                    $failed.Add($friendly)
                }
            }

            Write-Output ''
            Write-Output ('Disk {0}: {1}' -f $index, $friendly)
            Write-Output ('  Serial: {0}' -f (Get-DhProperty -Object $raw -Name 'SerialNumber'))
            Write-Output ('  Media: {0}' -f $kind)
            Write-Output ('  Bus: {0}' -f $bus)
            Write-Output ('  SizeGB: {0}' -f (Format-DhGb -Bytes (Get-DhProperty -Object $raw -Name 'Size')))
            Write-Output ('  Firmware: {0}' -f (Get-DhProperty -Object $raw -Name 'FirmwareVersion'))
            Write-Output ('  HealthStatus: {0}' -f $health)
            Write-Output ('  OperationalStatus: {0}' -f ($(if ($ops.Count -eq 0) { 'n/a' } else { $ops -join ', ' })))
            Write-Output ('  ReadErrorsTotal: {0}' -f (Get-DhProperty -Object $counter -Name 'ReadErrorsTotal'))
            Write-Output ('  ReadErrorsCorrected: {0}' -f (Get-DhProperty -Object $counter -Name 'ReadErrorsCorrected'))
            Write-Output ('  ReadErrorsUncorrected: {0}' -f $readUncorrected)
            Write-Output ('  WriteErrorsTotal: {0}' -f (Get-DhProperty -Object $counter -Name 'WriteErrorsTotal'))
            Write-Output ('  WriteErrorsUncorrected: {0}' -f $writeUncorrected)
            Write-Output ('  WearPercent: {0}' -f $wear)
            Write-Output ('  TemperatureC: {0}' -f (Get-DhProperty -Object $counter -Name 'Temperature'))
            Write-Output ('  Age: {0}' -f (Format-DhAge -PowerOnHours (Get-DhProperty -Object $counter -Name 'PowerOnHours') -ManufactureDate (Get-DhProperty -Object $counter -Name 'ManufactureDate') -Now $now))
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
        Write-DhResult -Result Pass -Summary ('{0} in-scope disks healthy.' -f $checked)
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
    exit $script:ScExitCode
}
