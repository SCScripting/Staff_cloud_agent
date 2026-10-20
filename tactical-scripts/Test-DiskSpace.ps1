<#
.SYNOPSIS
    Check free disk space and optionally clean safe caches.

.DESCRIPTION
    Purpose: Alert when a fixed volume drops below a free-space threshold.
    With -Cleanup, delete aged temp files, the Windows Update download cache,
    and recycle bin contents. Patient data, images, and Dentrix folders are
    not deleted. The Windows Update services are stopped only when -Cleanup
    and -AllowServiceRestart are both passed.

    Parameters:
      -MinFreePercent       Free space percent that still passes. Default 15.
      -DriveLetter          Check one drive letter. Default is every fixed volume.
      -MinVolumeGB          Skip unlabeled tiny volumes below this size when
                            no drive letter is requested. Default 20.
      -Cleanup              Delete temp files, the Windows Update download
                            cache, and recycle bins.
      -MinFileAgeDays       Temp files newer than this are kept. Default 1.
                            The Windows Update download cache ignores age.
      -AllowServiceRestart  Stop and restart BITS and Windows Update while the
                            download cache is cleared. Default off.

.NOTES
    Standard Computer Tactical RMM script. Windows PowerShell 5.1. Run as SYSTEM.
    Idempotent. Does not reboot. Does not use credentials.
    A missing text value prints as n/a.
    The last stdout line is EXITCODE: N. Tactical ad-hoc command output does
    not show the process exit code.

    Exit codes:
      0  Every selected volume is at or above the free-space threshold.
      1  A selected volume is below the threshold after optional cleanup.
      2  Free space could not be queried, or a requested service restart failed.

.EXAMPLE
    .\Test-DiskSpace.ps1 -MinFreePercent 15 -Cleanup
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(1, 99)]
    [int]$MinFreePercent = 15,

    [string]$DriveLetter,

    [ValidateRange(0, 100000)]
    [int]$MinVolumeGB = 20,

    [switch]$Cleanup,

    [ValidateRange(0, 3650)]
    [int]$MinFileAgeDays = 1,

    [switch]$AllowServiceRestart
)

function Test-DsWindowsHost {
    $variable = Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue
    if ($null -eq $variable) {
        return $true
    }
    return [bool]$variable.Value
}

function Write-DsResult {
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

function Format-DsText {
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

function ConvertTo-DsByte {
    param([int]$Gigabytes)

    return [uint64]([int64]$Gigabytes * 1073741824L)
}

function Resolve-DsDriveLetter {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }
    $letter = $Value.Trim().TrimEnd('\').TrimEnd(':')
    if ($letter -notmatch '^[A-Za-z]$') {
        throw "DriveLetter must be a single letter. Received '$Value'."
    }
    return $letter.ToUpperInvariant()
}

function Get-DsFreePercent {
    param(
        [uint64]$SizeBytes,
        [uint64]$FreeBytes
    )

    if ($SizeBytes -eq 0) {
        return 0
    }
    $percent = (100.0 * [double]$FreeBytes) / [double]$SizeBytes
    return [math]::Round($percent, 1)
}

function Test-DsFreeSpace {
    param(
        [uint64]$SizeBytes,
        [uint64]$FreeBytes,
        [int]$MinFreePercent
    )

    $percent = Get-DsFreePercent -SizeBytes $SizeBytes -FreeBytes $FreeBytes
    [pscustomobject]@{
        FreePercent = $percent
        Sufficient  = ($percent -ge $MinFreePercent)
    }
}

function Test-DsVolumeSelected {
    param(
        [string]$DeviceId,
        [uint64]$SizeBytes,
        [string]$RequestedLetter,
        [int]$MinVolumeGB
    )

    $letter = $null
    if ($DeviceId -match '^([A-Za-z]):') {
        $letter = $Matches[1].ToUpperInvariant()
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestedLetter)) {
        return ($letter -eq $RequestedLetter.ToUpperInvariant())
    }
    $minimum = ConvertTo-DsByte -Gigabytes $MinVolumeGB
    if ($SizeBytes -lt $minimum) {
        return $false
    }
    return ($null -ne $letter)
}

function Format-DsGb {
    param([uint64]$Bytes)

    $number = [double]$Bytes / 1073741824
    return ([math]::Round($number, 2)).ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function Invoke-DsFileCleanup {
    param(
        [string]$Root,
        [datetime]$Cutoff,
        [bool]$IgnoreAge,
        [string[]]$ProtectedPath
    )

    $removed = 0
    $skipped = 0
    $bytes = [int64]0
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) {
        return [pscustomobject]@{ Removed = 0; Skipped = 0; Bytes = [int64]0; Missing = $true }
    }

    $protected = @{}
    foreach ($path in @($ProtectedPath)) {
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $protected[$path.ToUpperInvariant()] = $true
        }
    }

    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    $directories = New-Object System.Collections.Generic.List[string]

    while ($stack.Count -gt 0) {
        $current = [string]$stack.Pop()
        $directories.Add($current)
        try {
            $children = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)
        } catch {
            $skipped++
            continue
        }
        foreach ($child in $children) {
            $isLink = ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            if ($isLink) {
                $skipped++
                continue
            }
            if ($child.PSIsContainer) {
                $stack.Push($child.FullName)
                continue
            }
            if ($protected.ContainsKey($child.FullName.ToUpperInvariant())) {
                $skipped++
                continue
            }
            $oldEnough = $IgnoreAge -or ($child.LastWriteTime -lt $Cutoff)
            if (-not $oldEnough) {
                continue
            }
            try {
                $length = [int64]$child.Length
                Remove-Item -LiteralPath $child.FullName -Force -ErrorAction Stop
                $removed++
                $bytes += $length
            } catch {
                $skipped++
            }
        }
    }

    $ordered = @($directories | Sort-Object -Property Length -Descending)
    foreach ($dir in $ordered) {
        if ($dir -eq $Root) {
            continue
        }
        try {
            $remaining = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)
            if ($remaining.Count -eq 0) {
                Remove-Item -LiteralPath $dir -Force -ErrorAction Stop
            }
        } catch {
            $skipped++
        }
    }

    [pscustomobject]@{
        Removed = $removed
        Skipped = $skipped
        Bytes   = $bytes
        Missing = $false
    }
}

function Get-DsTempRoot {
    $roots = New-Object System.Collections.Generic.List[string]
    $windowsTemp = Join-Path $env:SystemRoot 'Temp'
    if (Test-Path -LiteralPath $windowsTemp) {
        $roots.Add($windowsTemp)
    }
    $users = @(Get-ChildItem -LiteralPath 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue)
    foreach ($user in $users) {
        $temp = Join-Path $user.FullName 'AppData\Local\Temp'
        if (Test-Path -LiteralPath $temp) {
            $roots.Add($temp)
        }
    }
    return @($roots)
}

function Invoke-DsRecycleBinCleanup {
    $removed = 0
    $skipped = 0
    $drives = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)
    foreach ($drive in $drives) {
        $root = '{0}\$Recycle.Bin' -f $drive.DeviceID
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }
        $children = @(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue)
        foreach ($child in $children) {
            if ($child.Name -eq 'desktop.ini') {
                continue
            }
            $isLink = ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            if ($isLink) {
                $skipped++
                continue
            }
            try {
                Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
                $removed++
            } catch {
                $skipped++
            }
        }
    }
    [pscustomobject]@{ Removed = $removed; Skipped = $skipped }
}

function Get-DsFixedVolume {
    return @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop)
}

function Write-DsVolumeReport {
    param($Volumes, [string]$RequestedLetter, [int]$MinimumPercent, [int]$MinimumVolumeGB)

    $selected = 0
    $low = New-Object System.Collections.Generic.List[string]
    foreach ($volume in @($Volumes)) {
        $deviceId = [string]$volume.DeviceID
        $size = [uint64]$volume.Size
        $free = [uint64]$volume.FreeSpace
        $include = Test-DsVolumeSelected -DeviceId $deviceId -SizeBytes $size -RequestedLetter $RequestedLetter -MinVolumeGB $MinimumVolumeGB
        $check = Test-DsFreeSpace -SizeBytes $size -FreeBytes $free -MinFreePercent $MinimumPercent
        $state = 'skipped'
        if ($include) {
            $selected++
            if ($check.Sufficient) {
                $state = 'Pass'
            } else {
                $state = 'Fail'
                $low.Add($deviceId)
            }
        }
        $percentText = $check.FreePercent.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        Write-Output ('{0}  size {1} GB  free {2} GB  free {3}%  {4}' -f (Format-DsText -Value $deviceId), (Format-DsGb -Bytes $size), (Format-DsGb -Bytes $free), $percentText, $state)
    }
    [pscustomobject]@{
        Selected = $selected
        Low      = @($low)
    }
}

function Invoke-DsMain {
    param(
        [int]$MinFreePercent = 15,
        [string]$DriveLetter,
        [int]$MinVolumeGB = 20,
        [bool]$Cleanup = $false,
        [int]$MinFileAgeDays = 1,
        [bool]$AllowServiceRestart = $false
    )

    $script:ScExitCode = 2
    $stoppedServices = @()
    try {
        if (-not (Test-DsWindowsHost)) {
            Write-DsResult -Result Error -Summary 'This script must run on Windows.'
            return
        }

        $requested = Resolve-DsDriveLetter -Value $DriveLetter
        Write-Output ('Computer: {0}' -f $env:COMPUTERNAME)
        Write-Output ('Time: {0}' -f (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK'))
        Write-Output ('Threshold: {0}% free' -f $MinFreePercent)
        if ($null -eq $requested) {
            Write-Output ('Drive filter: all fixed volumes of at least {0} GB' -f $MinVolumeGB)
        } else {
            Write-Output ('Drive filter: {0}:' -f $requested)
        }

        $before = @(Get-DsFixedVolume)
        if ($null -ne $requested) {
            $found = $false
            foreach ($volume in $before) {
                if ([string]$volume.DeviceID -eq ($requested + ':')) {
                    $found = $true
                }
            }
            if (-not $found) {
                Write-DsResult -Result Error -Summary "Drive $requested`: was not found."
                return
            }
        }

        Write-Output 'Before:'
        $beforeReport = Write-DsVolumeReport -Volumes $before -RequestedLetter $requested -MinimumPercent $MinFreePercent -MinimumVolumeGB $MinVolumeGB

        if ($Cleanup) {
            $cutoff = (Get-Date).AddDays(-1 * $MinFileAgeDays)
            $protected = @()
            if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
                $protected += $PSCommandPath
            }
            Write-Output ''
            Write-Output ('Cleanup: temp files older than {0} days, Windows Update download cache, recycle bins.' -f $MinFileAgeDays)
            $tempRemoved = 0
            $tempSkipped = 0
            $tempBytes = [int64]0
            foreach ($root in @(Get-DsTempRoot)) {
                $result = Invoke-DsFileCleanup -Root $root -Cutoff $cutoff -IgnoreAge $false -ProtectedPath $protected
                $tempRemoved += $result.Removed
                $tempSkipped += $result.Skipped
                $tempBytes += $result.Bytes
                Write-Output ('  Temp {0}: removed {1}, skipped {2}' -f $root, $result.Removed, $result.Skipped)
            }

            $cache = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
            if ($AllowServiceRestart) {
                Write-Output 'Windows Update service restart: requested'
                foreach ($serviceName in @('bits', 'wuauserv')) {
                    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
                    if ($null -eq $service) {
                        Write-Output ('  Service {0} was not found.' -f $serviceName)
                        continue
                    }
                    if ($service.Status -eq 'Running') {
                        Stop-Service -Name $serviceName -ErrorAction Stop
                        $stoppedServices += $serviceName
                        Write-Output ('  Stopped {0}' -f $serviceName)
                    } else {
                        Write-Output ('  {0} was {1} and was left alone.' -f $serviceName, $service.Status)
                    }
                }
            } else {
                Write-Output 'Windows Update service restart: not requested. Locked cache files are skipped.'
            }

            $cacheResult = Invoke-DsFileCleanup -Root $cache -Cutoff $cutoff -IgnoreAge $true -ProtectedPath $protected
            Write-Output ('  Update cache: removed {0}, skipped {1}, {2} GB' -f $cacheResult.Removed, $cacheResult.Skipped, (Format-DsGb -Bytes ([uint64]$cacheResult.Bytes)))
            $binResult = Invoke-DsRecycleBinCleanup
            Write-Output ('  Recycle bins: removed {0}, skipped {1}' -f $binResult.Removed, $binResult.Skipped)
            Write-Output ('  Temp total: removed {0}, skipped {1}, {2} GB' -f $tempRemoved, $tempSkipped, (Format-DsGb -Bytes ([uint64]$tempBytes)))

            Write-Output ''
            Write-Output 'After:'
            $after = @(Get-DsFixedVolume)
            $afterReport = Write-DsVolumeReport -Volumes $after -RequestedLetter $requested -MinimumPercent $MinFreePercent -MinimumVolumeGB $MinVolumeGB
            $beforeReport = $afterReport
        }

        Write-Output ''
        if ($beforeReport.Selected -eq 0) {
            Write-DsResult -Result Error -Summary 'No fixed volumes matched the drive filter.'
            return
        }
        if ($beforeReport.Low.Count -gt 0) {
            Write-DsResult -Result Fail -Summary ('Low free space on {0}. Threshold is {1}%.' -f ($beforeReport.Low -join ', '), $MinFreePercent)
            $script:ScExitCode = 1
            return
        }
        Write-DsResult -Result Pass -Summary ('{0} volume(s) at or above {1}% free.' -f $beforeReport.Selected, $MinFreePercent)
        $script:ScExitCode = 0
    } catch {
        Write-DsResult -Result Error -Summary $_.Exception.Message
        $script:ScExitCode = 2
    } finally {
        foreach ($serviceName in @('wuauserv', 'bits')) {
            if ($stoppedServices -contains $serviceName) {
                try {
                    Start-Service -Name $serviceName -ErrorAction Stop
                    Write-Output ('Restarted {0}' -f $serviceName)
                } catch {
                    Write-Output ('Could not restart {0}: {1}' -f $serviceName, $_.Exception.Message)
                    $script:ScExitCode = 2
                }
            }
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $script:ScExitCode = 2
    try {
        Invoke-DsMain -MinFreePercent $MinFreePercent -DriveLetter $DriveLetter -MinVolumeGB $MinVolumeGB -Cleanup ([bool]$Cleanup) -MinFileAgeDays $MinFileAgeDays -AllowServiceRestart ([bool]$AllowServiceRestart) | Out-Host
    } catch {
        Write-Output 'RESULT: Error' | Out-Host
        Write-Output ('Summary: {0}' -f $_.Exception.Message) | Out-Host
        $script:ScExitCode = 2
    }
    Write-Output ('EXITCODE: {0}' -f $script:ScExitCode) | Out-Host
    exit $script:ScExitCode
}
