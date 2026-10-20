<#
.SYNOPSIS
    Report the last Windows Update install and the pending count.

.DESCRIPTION
    Purpose: Show when Windows last installed a quality update and how many
    software updates are still pending. Defender security-intelligence and
    other definition updates are excluded so a daily definition does not hide
    a missing cumulative update. The script does not install updates.

    Parameters:
      -MaxPending           Pending quality updates that still pass. Default 0.
      -MaxDaysSinceInstall  Oldest successful install that still passes.
                            Default 45.

.NOTES
    Standard Computer Tactical RMM script. Windows PowerShell 5.1. Run as SYSTEM.
    Idempotent. Does not reboot and does not restart services.
    Does not use credentials. The Windows Update search can take several
    minutes and uses the PC's configured source (Windows Update or WSUS).
    Set the Tactical timeout to at least 20 minutes.

    Exit codes:
      0  Pending updates are within the maximum and the last install is recent.
      1  Too many updates are pending, or the last install is too old.
      2  The pending count or install history could not be queried.

.EXAMPLE
    .\Get-WindowsUpdateStatus.ps1 -MaxPending 0 -MaxDaysSinceInstall 45
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(0, 10000)]
    [int]$MaxPending = 0,

    [ValidateRange(1, 3650)]
    [int]$MaxDaysSinceInstall = 45
)

function Test-WuWindowsHost {
    $variable = Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue
    if ($null -eq $variable) {
        return $true
    }
    return [bool]$variable.Value
}

function Write-WuResult {
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

function Test-WuDefinitionUpdate {
    param(
        [string]$Title,
        [string[]]$CategoryNames
    )

    if ($Title -match '(?i)Security Intelligence Update|Defender Antivirus definition|Definition Update') {
        return $true
    }
    foreach ($name in @($CategoryNames)) {
        if ($name -eq 'Definition Updates') {
            return $true
        }
    }
    return $false
}

function Convert-WuRegistryTime {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    $styles = [System.Globalization.DateTimeStyles]::AssumeLocal
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $formats = @(
        'yyyy-MM-dd HH:mm:ss',
        'yyyy-MM-ddTHH:mm:ss',
        'M/d/yyyy h:mm:ss tt',
        'MM/dd/yyyy HH:mm:ss'
    )
    $parsed = [datetime]::MinValue
    foreach ($format in $formats) {
        if ([datetime]::TryParseExact($Text, $format, $culture, $styles, [ref]$parsed)) {
            return $parsed
        }
    }
    if ([datetime]::TryParse($Text, $culture, $styles, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Get-WuCategoryName {
    param($Categories)

    $names = @()
    foreach ($category in @($Categories)) {
        if ($null -eq $category) {
            continue
        }
        if ($category -is [string]) {
            $names += $category
            continue
        }
        $property = $category.PSObject.Properties['Name']
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            $names += [string]$property.Value
        }
    }
    return $names
}

function Get-WuLastQualityInstall {
    param($Entries)

    $best = $null
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) {
            continue
        }
        $operation = 0
        $resultCode = 0
        if (-not [int]::TryParse([string]$entry.Operation, [ref]$operation)) {
            continue
        }
        if (-not [int]::TryParse([string]$entry.ResultCode, [ref]$resultCode)) {
            continue
        }
        if ($operation -ne 1 -or $resultCode -ne 2) {
            continue
        }
        $title = [string]$entry.Title
        $categories = @(Get-WuCategoryName -Categories $entry.Categories)
        if (Test-WuDefinitionUpdate -Title $title -CategoryNames $categories) {
            continue
        }
        $dateText = [string]$entry.Date
        $date = $null
        try {
            $date = [datetime]$entry.Date
        } catch {
            $date = Convert-WuRegistryTime -Text $dateText
        }
        if ($null -eq $date) {
            continue
        }
        if ($null -eq $best -or $date -gt $best.Date) {
            $best = [pscustomobject]@{ Date = $date; Title = $title }
        }
    }
    return $best
}

function Get-WuCompliance {
    param(
        $LastInstall,
        [int]$PendingCount,
        [int]$MaxPending,
        [int]$MaxDaysSinceInstall,
        [datetime]$Now
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    if ($PendingCount -gt $MaxPending) {
        $reasons.Add("pending software updates = $PendingCount (allowed $MaxPending)")
    }

    $days = $null
    if ($null -eq $LastInstall) {
        $reasons.Add('no successful quality-update install date was found')
    } else {
        $installed = [datetime]$LastInstall
        $days = [math]::Floor(($Now.ToUniversalTime() - $installed.ToUniversalTime()).TotalDays)
        if ($days -lt 0) {
            $days = 0
        }
        if ($days -gt $MaxDaysSinceInstall) {
            $reasons.Add("last successful quality update was $days days ago (allowed $MaxDaysSinceInstall)")
        }
    }

    [pscustomobject]@{
        Compliant        = ($reasons.Count -eq 0)
        Reasons          = @($reasons)
        DaysSinceInstall = $days
    }
}

function Get-WuRegistryLastSuccess {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Install')
        if ($null -eq $key) {
            return $null
        }
        try {
            return Convert-WuRegistryTime -Text ([string]$key.GetValue('LastSuccessTime'))
        } finally {
            $key.Close()
        }
    } finally {
        $base.Close()
    }
}

function Invoke-WuMain {
    param(
        [int]$MaxPending = 0,
        [int]$MaxDaysSinceInstall = 45
    )

    $script:ScExitCode = 2
    try {
        if (-not (Test-WuWindowsHost)) {
            Write-WuResult -Result Error -Summary 'This script must run on Windows.'
            return
        }

        Write-Output ('Computer: {0}' -f $env:COMPUTERNAME)
        Write-Output ('Time: {0}' -f (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK'))
        Write-Output ('Pending maximum: {0}' -f $MaxPending)
        Write-Output ('Install age maximum: {0} days' -f $MaxDaysSinceInstall)

        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $history = @()
        $historyCount = 0
        try {
            $historyCount = [int]$searcher.GetTotalHistoryCount()
        } catch {
            $historyCount = 0
            Write-Output ('Update history could not be read: {0}' -f $_.Exception.Message)
        }
        $take = $historyCount
        if ($take -gt 1000) {
            $take = 1000
        }
        if ($take -gt 0) {
            $history = @($searcher.QueryHistory(0, $take))
        }
        $last = Get-WuLastQualityInstall -Entries $history
        $registryLast = Get-WuRegistryLastSuccess
        if ($null -eq $last -and $null -ne $registryLast) {
            $last = [pscustomobject]@{ Date = $registryLast; Title = 'Windows Update last success time (registry)' }
        } elseif ($null -ne $last -and $null -ne $registryLast -and $registryLast -gt $last.Date) {
            $last = [pscustomobject]@{ Date = $registryLast; Title = 'Windows Update last success time (registry)' }
        }

        if ($null -eq $last) {
            Write-Output 'Last successful quality install: unknown'
        } else {
            Write-Output ('Last successful quality install: {0}' -f $last.Date.ToString('yyyy-MM-dd HH:mm:ss'))
            Write-Output ('Last install title: {0}' -f $last.Title)
        }

        $searchOk = $true
        $searchError = ''
        $pendingTitles = New-Object System.Collections.Generic.List[string]
        $definitionCount = 0
        try {
            $result = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
            foreach ($update in @($result.Updates)) {
                $title = [string]$update.Title
                $categories = @(Get-WuCategoryName -Categories $update.Categories)
                if (Test-WuDefinitionUpdate -Title $title -CategoryNames $categories) {
                    $definitionCount++
                    continue
                }
                $pendingTitles.Add($title)
            }
        } catch {
            $searchOk = $false
            $searchError = $_.Exception.Message
        }

        Write-Output ('Definition updates excluded: {0}' -f $definitionCount)
        if (-not $searchOk) {
            Write-Output ('Pending update search failed: {0}' -f $searchError)
            Write-Output ''
            Write-WuResult -Result Error -Summary 'The pending update count could not be queried.'
            return
        }

        Write-Output ('Pending software updates: {0}' -f $pendingTitles.Count)
        $shown = 0
        foreach ($title in $pendingTitles) {
            if ($shown -ge 20) {
                break
            }
            Write-Output ('  - {0}' -f $title)
            $shown++
        }
        if ($pendingTitles.Count -gt 20) {
            Write-Output ('  ... and {0} more' -f ($pendingTitles.Count - 20))
        }

        $lastDate = $null
        if ($null -ne $last) {
            $lastDate = $last.Date
        }
        $compliance = Get-WuCompliance -LastInstall $lastDate -PendingCount $pendingTitles.Count -MaxPending $MaxPending -MaxDaysSinceInstall $MaxDaysSinceInstall -Now (Get-Date)
        if ($null -ne $compliance.DaysSinceInstall) {
            Write-Output ('Days since last quality install: {0}' -f $compliance.DaysSinceInstall)
        }
        Write-Output ''
        if ($compliance.Compliant) {
            Write-WuResult -Result Pass -Summary ('{0} pending quality updates. Last install is within {1} days.' -f $pendingTitles.Count, $MaxDaysSinceInstall)
            $script:ScExitCode = 0
            return
        }
        Write-WuResult -Result Fail -Summary ($compliance.Reasons -join '; ')
        $script:ScExitCode = 1
    } catch {
        Write-WuResult -Result Error -Summary $_.Exception.Message
        $script:ScExitCode = 2
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $script:ScExitCode = 2
    try {
        Invoke-WuMain -MaxPending $MaxPending -MaxDaysSinceInstall $MaxDaysSinceInstall | Out-Host
    } catch {
        Write-Output 'RESULT: Error' | Out-Host
        Write-Output ('Summary: {0}' -f $_.Exception.Message) | Out-Host
        $script:ScExitCode = 2
    }
    exit $script:ScExitCode
}
