<#
.SYNOPSIS
    Check dedicated GPU VRAM for dental CBCT viewers.

.DESCRIPTION
    Purpose: Fail when the best dedicated GPU has less VRAM than the CBCT
    viewer minimum. VRAM is read from the qwMemorySize registry value under
    the display class key. HardwareInformation.qwMemorySize is used when the
    exact qwMemorySize name is absent. Win32_VideoController.AdapterRAM is not
    used because it is a 32-bit field and caps at 4 GB.

    Integrated Intel and AMD graphics, the Microsoft Basic Display Adapter,
    and remote-display drivers do not count as dedicated VRAM. Assign this
    script to CBCT and imaging PCs. A front-desk PC with no discrete GPU fails.

    Parameters:
      -MinVRAMGB  Dedicated VRAM minimum in GB. Default 4.
                  Values are rounded to 0.1 GB before the comparison.

.NOTES
    Standard Computer Tactical RMM script. Windows PowerShell 5.1. Run as SYSTEM.
    Idempotent. Does not reboot and does not restart services.
    Does not use credentials. A missing text value prints as n/a.
    The last stdout line is EXITCODE: N. Tactical ad-hoc command output does
    not show the process exit code.

    Exit codes:
      0  A dedicated GPU meets the VRAM minimum.
      1  No dedicated GPU was found, or dedicated VRAM is under the minimum.
      2  A dedicated GPU is present but qwMemorySize could not be read.

.EXAMPLE
    .\Test-GpuVram.ps1 -MinVRAMGB 4
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(1, 64)]
    [int]$MinVRAMGB = 4
)

function Test-GvWindowsHost {
    $variable = Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue
    if ($null -eq $variable) {
        return $true
    }
    return [bool]$variable.Value
}

function Write-GvResult {
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

function Format-GvText {
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

function Get-GvQwMemorySize {
    param([hashtable]$Values)

    if ($null -eq $Values) {
        return [pscustomobject]@{ Bytes = [uint64]0; Source = $null }
    }
    if ($Values.ContainsKey('qwMemorySize') -and $null -ne $Values['qwMemorySize']) {
        $exact = [uint64]0
        if ([uint64]::TryParse([string]$Values['qwMemorySize'], [ref]$exact) -and $exact -gt 0) {
            return [pscustomobject]@{ Bytes = $exact; Source = 'qwMemorySize' }
        }
    }

    $chosen = [uint64]0
    $source = $null
    foreach ($key in @($Values.Keys)) {
        if ($key -notlike '*.qwMemorySize') {
            continue
        }
        $parsed = [uint64]0
        if ([uint64]::TryParse([string]$Values[$key], [ref]$parsed) -and $parsed -gt $chosen) {
            $chosen = $parsed
            $source = [string]$key
        }
    }
    if ($null -eq $source) {
        return [pscustomobject]@{ Bytes = [uint64]0; Source = $null }
    }
    return [pscustomobject]@{ Bytes = $chosen; Source = $source }
}

function Test-GvDedicatedGpu {
    param(
        [string]$Name,
        [string]$PnpDeviceId
    )

    $adapterName = ''
    if ($null -ne $Name) {
        $adapterName = $Name.ToUpperInvariant()
    }
    $pnp = ''
    if ($null -ne $PnpDeviceId) {
        $pnp = $PnpDeviceId.ToUpperInvariant()
    }

    if ($adapterName -match 'BASIC DISPLAY|REMOTE DISPLAY|VIRTUAL|MIRROR DRIVER|PARSEC|TEAMVIEWER|ANYDESK') {
        return $false
    }
    if ($pnp -match 'VEN_10DE') {
        return $true
    }
    if ($pnp -match 'VEN_1002') {
        if ($adapterName -match 'RADEON(\(TM\))? GRAPHICS') {
            return $false
        }
        return $true
    }
    if ($pnp -match 'VEN_8086') {
        if ($adapterName -match '\bARC\b') {
            return $true
        }
        return $false
    }
    return $false
}

function Test-GvDeviceMatch {
    param(
        [string]$PnpDeviceId,
        [string]$MatchingDeviceId,
        [string]$Name,
        [string]$DriverDesc
    )

    if (-not [string]::IsNullOrWhiteSpace($MatchingDeviceId) -and -not [string]::IsNullOrWhiteSpace($PnpDeviceId)) {
        if ($PnpDeviceId.StartsWith($MatchingDeviceId, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Name) -and $Name -eq $DriverDesc) {
        return $true
    }
    return $false
}

function Test-GvVramMinimum {
    param(
        [uint64]$Bytes,
        [int]$MinVRAMGB
    )

    $tenths = [math]::Round((($Bytes / 1073741824) * 10), 0, [System.MidpointRounding]::AwayFromZero)
    $reported = [math]::Round(($tenths / 10), 1)
    [pscustomobject]@{
        VramGB       = $reported.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        MeetsMinimum = ($tenths -ge ($MinVRAMGB * 10))
    }
}

function Get-GvVramDecision {
    param(
        $Adapters,
        [int]$MinVRAMGB
    )

    $dedicated = @()
    foreach ($adapter in @($Adapters)) {
        if ($adapter.Dedicated) {
            $dedicated += $adapter
        }
    }
    if ($dedicated.Count -eq 0) {
        return [pscustomobject]@{
            ExitCode = 1
            Result   = 'Fail'
            Summary  = "No dedicated GPU was found. CBCT viewers need at least $MinVRAMGB GB of dedicated VRAM."
        }
    }

    $known = @()
    foreach ($adapter in $dedicated) {
        if (-not [string]::IsNullOrWhiteSpace([string]$adapter.Source)) {
            $known += $adapter
        }
    }
    if ($known.Count -eq 0) {
        return [pscustomobject]@{
            ExitCode = 2
            Result   = 'Error'
            Summary  = 'A dedicated GPU is present, but qwMemorySize could not be read from the display class registry key.'
        }
    }

    $best = $known[0]
    foreach ($adapter in $known) {
        if ([uint64]$adapter.Bytes -gt [uint64]$best.Bytes) {
            $best = $adapter
        }
    }
    $check = Test-GvVramMinimum -Bytes ([uint64]$best.Bytes) -MinVRAMGB $MinVRAMGB
    if ($check.MeetsMinimum) {
        return [pscustomobject]@{
            ExitCode = 0
            Result   = 'Pass'
            Summary  = ('{0} has {1} GB dedicated VRAM (minimum {2} GB).' -f $best.Name, $check.VramGB, $MinVRAMGB)
        }
    }
    return [pscustomobject]@{
        ExitCode = 1
        Result   = 'Fail'
        Summary  = ('{0} has {1} GB dedicated VRAM, under the {2} GB minimum.' -f $best.Name, $check.VramGB, $MinVRAMGB)
    }
}

function Get-GvRegistryAdapter {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $classKey = $base.OpenSubKey('SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}')
        if ($null -eq $classKey) {
            return @()
        }
        try {
            $list = @()
            foreach ($subName in @($classKey.GetSubKeyNames())) {
                if ($subName -notmatch '^\d{4}$') {
                    continue
                }
                $sub = $classKey.OpenSubKey($subName)
                if ($null -eq $sub) {
                    continue
                }
                try {
                    $values = @{}
                    foreach ($valueName in @($sub.GetValueNames())) {
                        $values[$valueName] = $sub.GetValue($valueName)
                    }
                    $vram = Get-GvQwMemorySize -Values $values
                    $list += [pscustomobject]@{
                        Key              = $subName
                        DriverDesc       = [string]$sub.GetValue('DriverDesc')
                        MatchingDeviceId = [string]$sub.GetValue('MatchingDeviceId')
                        Bytes            = $vram.Bytes
                        Source           = $vram.Source
                    }
                } finally {
                    $sub.Close()
                }
            }
            return $list
        } finally {
            $classKey.Close()
        }
    } finally {
        $base.Close()
    }
}

function Get-GvAdapter {
    $controllers = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
    $registry = @(Get-GvRegistryAdapter)
    $results = @()
    foreach ($controller in $controllers) {
        $name = [string]$controller.Name
        $pnp = [string]$controller.PNPDeviceID
        $match = $null
        foreach ($entry in $registry) {
            $matched = Test-GvDeviceMatch -PnpDeviceId $pnp -MatchingDeviceId $entry.MatchingDeviceId -Name $name -DriverDesc $entry.DriverDesc
            if ($matched) {
                $match = $entry
                break
            }
        }
        $bytes = [uint64]0
        $source = $null
        if ($null -ne $match) {
            $bytes = [uint64]$match.Bytes
            $source = $match.Source
        }
        $results += [pscustomobject]@{
            Name          = $name
            PnpDeviceId   = $pnp
            Dedicated     = (Test-GvDedicatedGpu -Name $name -PnpDeviceId $pnp)
            Bytes         = $bytes
            Source        = $source
            DriverVersion = [string]$controller.DriverVersion
        }
    }
    return $results
}

function Invoke-GvMain {
    param(
        [int]$MinVRAMGB = 4
    )

    $script:ScExitCode = 2
    try {
        if (-not (Test-GvWindowsHost)) {
            Write-GvResult -Result Error -Summary 'This script must run on Windows.'
            return
        }

        Write-Output ('Computer: {0}' -f $env:COMPUTERNAME)
        Write-Output ('Time: {0}' -f (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK'))
        Write-Output ('Minimum dedicated VRAM: {0} GB' -f $MinVRAMGB)
        Write-Output 'VRAM source: qwMemorySize (Win32_VideoController.AdapterRAM is ignored).'

        $adapters = @(Get-GvAdapter)
        if ($adapters.Count -eq 0) {
            Write-GvResult -Result Error -Summary 'No display adapters were returned.'
            return
        }

        foreach ($adapter in $adapters) {
            $kind = 'integrated or virtual'
            if ($adapter.Dedicated) {
                $kind = 'dedicated'
            }
            $check = Test-GvVramMinimum -Bytes ([uint64]$adapter.Bytes) -MinVRAMGB $MinVRAMGB
            $source = $adapter.Source
            if ([string]::IsNullOrWhiteSpace([string]$source)) {
                $source = 'not found'
            }
            Write-Output ('{0} | {1} | {2} GB | source {3} | driver {4} | {5}' -f (Format-GvText -Value $adapter.Name), $kind, $check.VramGB, (Format-GvText -Value $source), (Format-GvText -Value $adapter.DriverVersion), (Format-GvText -Value $adapter.PnpDeviceId))
        }

        $decision = Get-GvVramDecision -Adapters $adapters -MinVRAMGB $MinVRAMGB
        Write-Output ''
        Write-GvResult -Result $decision.Result -Summary $decision.Summary
        $script:ScExitCode = $decision.ExitCode
    } catch {
        Write-GvResult -Result Error -Summary $_.Exception.Message
        $script:ScExitCode = 2
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $script:ScExitCode = 2
    try {
        Invoke-GvMain -MinVRAMGB $MinVRAMGB | Out-Host
    } catch {
        Write-Output 'RESULT: Error' | Out-Host
        Write-Output ('Summary: {0}' -f $_.Exception.Message) | Out-Host
        $script:ScExitCode = 2
    }
    Write-Output ('EXITCODE: {0}' -f $script:ScExitCode) | Out-Host
    exit $script:ScExitCode
}
