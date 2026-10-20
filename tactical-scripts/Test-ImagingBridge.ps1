<#
.SYNOPSIS
    Report dental imaging apps and flag a known bridge conflict.

.DESCRIPTION
    Purpose: List installed imaging software on a dental workstation, including
    Clever One, EzDent-i, Ez3D-i, and EzServer versions. Also reports Dentrix,
    VixWin, Carestream, DEXIS, Sidexis, and Romexis when those uninstall entries
    exist. Fails when Clever One and EzDent-i are both installed. Imaging
    services are reported and are not stopped.

    Parameters: none.

    Per-user installs that are not in HKLM are not visible when this runs as
    SYSTEM. The script does not load user registry hives.

.NOTES
    Standard Computer Tactical RMM script. Windows PowerShell 5.1. Run as SYSTEM.
    Idempotent. Does not reboot and does not restart services.
    Does not use credentials.

    Exit codes:
      0  The scan finished and Clever One is not installed beside EzDent-i.
      1  Clever One and EzDent-i are both installed.
      2  The uninstall registry could not be read.

.EXAMPLE
    .\Test-ImagingBridge.ps1
#>
#Requires -Version 5.1
[CmdletBinding()]
param()

function Test-IbWindowsHost {
    $variable = Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue
    if ($null -eq $variable) {
        return $true
    }
    return [bool]$variable.Value
}

function Write-IbResult {
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

function Get-IbCatalog {
    return @(
        [pscustomobject]@{ Key = 'CleverOne'; Label = 'Clever One'; Pattern = '(?i)Clever\s*One' }
        [pscustomobject]@{ Key = 'EzDentI'; Label = 'EzDent-i'; Pattern = '(?i)EzDent-?\s*i' }
        [pscustomobject]@{ Key = 'Ez3DI'; Label = 'Ez3D-i'; Pattern = '(?i)Ez3D-?\s*i' }
        [pscustomobject]@{ Key = 'EzServer'; Label = 'EzServer'; Pattern = '(?i)\bEzServer\b' }
        [pscustomobject]@{ Key = 'Dentrix'; Label = 'Dentrix'; Pattern = '(?i)\bDentrix\b' }
        [pscustomobject]@{ Key = 'VixWin'; Label = 'VixWin'; Pattern = '(?i)Vix\s*Win' }
        [pscustomobject]@{ Key = 'Carestream'; Label = 'Carestream'; Pattern = '(?i)Carestream|CS\s+Imaging|CS\s+3D' }
        [pscustomobject]@{ Key = 'Dexis'; Label = 'DEXIS'; Pattern = '(?i)\bDEXIS\b' }
        [pscustomobject]@{ Key = 'Sidexis'; Label = 'Sidexis'; Pattern = '(?i)\bSidexis\b' }
        [pscustomobject]@{ Key = 'Romexis'; Label = 'Romexis'; Pattern = '(?i)\bRomexis\b' }
    )
}

function Select-IbUniqueEntry {
    param($Entries)

    $seen = @{}
    $unique = @()
    foreach ($entry in @($Entries)) {
        $name = [string]$entry.DisplayName
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }
        $id = '{0}|{1}|{2}' -f $name.ToUpperInvariant(), ([string]$entry.DisplayVersion).ToUpperInvariant(), ([string]$entry.InstallLocation).ToUpperInvariant()
        if ($seen.ContainsKey($id)) {
            continue
        }
        $seen[$id] = $true
        $unique += $entry
    }
    return $unique
}

function Find-IbInstalledApp {
    param($Entries)

    $catalog = @(Get-IbCatalog)
    $found = @()
    foreach ($entry in @(Select-IbUniqueEntry -Entries $Entries)) {
        foreach ($item in $catalog) {
            if ([string]$entry.DisplayName -match $item.Pattern) {
                $version = [string]$entry.DisplayVersion
                if ([string]::IsNullOrWhiteSpace($version)) {
                    $version = 'unknown'
                }
                $found += [pscustomobject]@{
                    Label           = $item.Label
                    Key             = $item.Key
                    DisplayName     = [string]$entry.DisplayName
                    Version         = $version
                    Publisher       = [string]$entry.Publisher
                    InstallLocation = [string]$entry.InstallLocation
                }
                break
            }
        }
    }
    return $found
}

function Test-IbCleverEzDentConflict {
    param([string[]]$Labels)

    $clever = $false
    $ezDent = $false
    foreach ($label in @($Labels)) {
        if ($label -eq 'Clever One') {
            $clever = $true
        }
        if ($label -eq 'EzDent-i') {
            $ezDent = $true
        }
    }
    return ($clever -and $ezDent)
}

function Get-IbExecutablePath {
    param([string]$PathName)

    if ([string]::IsNullOrWhiteSpace($PathName)) {
        return $null
    }
    $text = $PathName.Trim()
    if ($text.StartsWith('"')) {
        $end = $text.IndexOf('"', 1)
        if ($end -gt 1) {
            return $text.Substring(1, $end - 1)
        }
    }
    $parts = $text -split ' '
    return $parts[0]
}

function Test-IbServiceInterest {
    param(
        [string]$Name,
        [string]$DisplayName
    )

    $text = '{0} {1}' -f $Name, $DisplayName
    return [bool]($text -match '(?i)EzServer|EzDent|Ez3D|Vatech|Clever\s*One|Carestream|Dentrix|Vix\s*Win|DEXIS|Sidexis|Romexis')
}

function Get-IbUninstallEntry {
    $views = @(
        [Microsoft.Win32.RegistryView]::Registry64,
        [Microsoft.Win32.RegistryView]::Registry32
    )
    $subkeys = @(
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $entries = @()
    foreach ($view in $views) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
        try {
            foreach ($sub in $subkeys) {
                $key = $base.OpenSubKey($sub)
                if ($null -eq $key) {
                    continue
                }
                try {
                    foreach ($childName in @($key.GetSubKeyNames())) {
                        $child = $key.OpenSubKey($childName)
                        if ($null -eq $child) {
                            continue
                        }
                        try {
                            $display = [string]$child.GetValue('DisplayName')
                            if ([string]::IsNullOrWhiteSpace($display)) {
                                continue
                            }
                            $entries += [pscustomobject]@{
                                DisplayName     = $display
                                DisplayVersion  = [string]$child.GetValue('DisplayVersion')
                                Publisher       = [string]$child.GetValue('Publisher')
                                InstallLocation = [string]$child.GetValue('InstallLocation')
                            }
                        } finally {
                            $child.Close()
                        }
                    }
                } finally {
                    $key.Close()
                }
            }
        } finally {
            $base.Close()
        }
    }
    return $entries
}

function Get-IbImagingService {
    $services = @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue)
    $found = @()
    foreach ($service in $services) {
        $name = [string]$service.Name
        $display = [string]$service.DisplayName
        if (-not (Test-IbServiceInterest -Name $name -DisplayName $display)) {
            continue
        }
        $exe = Get-IbExecutablePath -PathName ([string]$service.PathName)
        $version = $null
        if (-not [string]::IsNullOrWhiteSpace($exe) -and (Test-Path -LiteralPath $exe)) {
            $version = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exe).FileVersion
        }
        $found += [pscustomobject]@{
            Name        = $name
            DisplayName = $display
            State       = [string]$service.State
            StartMode   = [string]$service.StartMode
            Version     = $version
            Path        = $exe
        }
    }
    return $found
}

function Invoke-IbMain {
    $script:ScExitCode = 2
    try {
        if (-not (Test-IbWindowsHost)) {
            Write-IbResult -Result Error -Summary 'This script must run on Windows.'
            return
        }

        Write-Output ('Computer: {0}' -f $env:COMPUTERNAME)
        Write-Output ('Time: {0}' -f (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK'))

        $entries = @(Get-IbUninstallEntry)
        $apps = @(Find-IbInstalledApp -Entries $entries)
        $tracked = @('Clever One', 'EzDent-i', 'Ez3D-i', 'EzServer')
        Write-Output 'Tracked imaging apps:'
        foreach ($label in $tracked) {
            $foundApps = @($apps | Where-Object { $_.Label -eq $label })
            if ($foundApps.Count -eq 0) {
                Write-Output ('  {0}: not installed' -f $label)
                continue
            }
            foreach ($app in $foundApps) {
                Write-Output ('  {0}: {1}  version {2}  publisher {3}' -f $label, $app.DisplayName, $app.Version, $app.Publisher)
                if (-not [string]::IsNullOrWhiteSpace($app.InstallLocation)) {
                    Write-Output ('    Location: {0}' -f $app.InstallLocation)
                }
            }
        }

        $otherLabels = @('Dentrix', 'VixWin', 'Carestream', 'DEXIS', 'Sidexis', 'Romexis')
        Write-Output 'Other imaging apps:'
        $otherCount = 0
        foreach ($app in $apps) {
            if ($otherLabels -notcontains $app.Label) {
                continue
            }
            $otherCount++
            Write-Output ('  {0}: {1}  version {2}  publisher {3}' -f $app.Label, $app.DisplayName, $app.Version, $app.Publisher)
        }
        if ($otherCount -eq 0) {
            Write-Output '  none found in HKLM uninstall keys'
        }

        Write-Output 'Imaging services:'
        $services = @(Get-IbImagingService)
        if ($services.Count -eq 0) {
            Write-Output '  none found'
        }
        foreach ($service in $services) {
            $version = $service.Version
            if ([string]::IsNullOrWhiteSpace([string]$version)) {
                $version = 'n/a'
            }
            Write-Output ('  {0} ({1}) state {2} start {3} version {4}' -f $service.DisplayName, $service.Name, $service.State, $service.StartMode, $version)
        }

        $labels = @()
        foreach ($app in $apps) {
            $labels += [string]$app.Label
        }
        Write-Output ''
        if (Test-IbCleverEzDentConflict -Labels $labels) {
            Write-IbResult -Result Fail -Summary 'Clever One and EzDent-i are both installed. These imaging bridges conflict; only one should remain.'
            $script:ScExitCode = 1
            return
        }
        Write-IbResult -Result Pass -Summary 'No Clever One and EzDent-i conflict was found.'
        $script:ScExitCode = 0
    } catch {
        Write-IbResult -Result Error -Summary $_.Exception.Message
        $script:ScExitCode = 2
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $script:ScExitCode = 2
    try {
        Invoke-IbMain | Out-Host
    } catch {
        Write-Output 'RESULT: Error' | Out-Host
        Write-Output ('Summary: {0}' -f $_.Exception.Message) | Out-Host
        $script:ScExitCode = 2
    }
    exit $script:ScExitCode
}
