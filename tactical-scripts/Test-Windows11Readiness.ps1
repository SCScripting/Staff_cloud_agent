<#
.SYNOPSIS
    Check whether a PC meets the Windows 11 upgrade requirements.

.DESCRIPTION
    Purpose: Report TPM 2.0, Secure Boot, UEFI, CPU, RAM, and system-disk
    readiness before a Windows 11 upgrade. Windows Server is reported as not
    applicable. A machine that is already on Windows 11 passes, and any
    requirement gaps are printed as informational. CPU support is a heuristic,
    not Microsoft's full supported-processor list.

    Parameters:
      -MinRamGB    Installed RAM minimum in GB. Default 4.
      -MinDiskGB   System volume size minimum in GB (1024^3). Default 64.
      -MinFreeGB   System volume free space minimum in GB. Default 20.

.NOTES
    Standard Computer Tactical RMM script. Windows PowerShell 5.1. Run as SYSTEM.
    Idempotent. Does not reboot and does not restart services.
    Does not use credentials. A missing text value prints as n/a.
    The last stdout line is EXITCODE: N. Tactical ad-hoc command output does
    not show the process exit code.

    Exit codes:
      0  Ready, already on Windows 11, or Windows Server (not applicable).
      1  A Windows 10 client is not ready to upgrade.
      2  Readiness could not be collected.

.EXAMPLE
    .\Test-Windows11Readiness.ps1 -MinFreeGB 30
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(1, 1024)]
    [int]$MinRamGB = 4,

    [ValidateRange(1, 100000)]
    [int]$MinDiskGB = 64,

    [ValidateRange(1, 100000)]
    [int]$MinFreeGB = 20
)

function Test-WrWindowsHost {
    $variable = Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue
    if ($null -eq $variable) {
        return $true
    }
    return [bool]$variable.Value
}

function Write-WrResult {
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

function Format-WrText {
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

function ConvertTo-WrByte {
    param([int]$Gigabytes)

    return [uint64]([int64]$Gigabytes * 1073741824L)
}

function Test-WrIsServer {
    param(
        [string]$Caption,
        [int]$ProductType
    )

    if ($ProductType -eq 2 -or $ProductType -eq 3) {
        return $true
    }
    if ($Caption -match 'Windows Server') {
        return $true
    }
    return $false
}

function Test-WrIsWindows11 {
    param(
        [string]$Caption,
        [int]$Build
    )

    if ($Caption -match 'Windows 11') {
        return $true
    }
    if ($Build -ge 22000 -and $Caption -notmatch 'Server') {
        return $true
    }
    return $false
}

function Get-WrIntelGeneration {
    param([string]$Name)

    if ($Name -match '(?i)Core\(TM\)\s+Ultra|Core\s+Ultra') {
        return [pscustomobject]@{ Known = $true; Supported = $true; Detail = 'Intel Core Ultra' }
    }

    $modelMatch = [regex]::Match($Name, '(?i)Core(?:\(TM\))?\s+i[3579]-(\d{4,5})')
    if (-not $modelMatch.Success) {
        return [pscustomobject]@{ Known = $false; Supported = $false; Detail = '' }
    }

    $modelText = $modelMatch.Groups[1].Value
    $model = [int]$modelText
    $generation = 0
    if ($model -ge 10000) {
        $generation = [int]$modelText.Substring(0, 2)
    } elseif ($Name -match '(?i)i[3579]-1\d{3}G\d') {
        $generation = 10
    } else {
        $generation = [int]$modelText.Substring(0, 1)
    }

    [pscustomobject]@{
        Known     = $true
        Supported = ($generation -ge 8)
        Detail    = "Intel Core generation $generation"
    }
}

function Test-WrCpuSupport {
    param(
        [string]$Name,
        [int]$Cores,
        [int]$AddressWidth,
        [int]$MaxClockMHz
    )

    if ($AddressWidth -gt 0 -and $AddressWidth -lt 64) {
        return [pscustomobject]@{ Status = 'Fail'; Detail = 'CPU is not 64-bit' }
    }
    if ($Cores -gt 0 -and $Cores -lt 2) {
        return [pscustomobject]@{ Status = 'Fail'; Detail = 'Fewer than 2 cores' }
    }
    if ($MaxClockMHz -gt 0 -and $MaxClockMHz -lt 1000) {
        return [pscustomobject]@{ Status = 'Fail'; Detail = "CPU reports $MaxClockMHz MHz, below the 1 GHz minimum" }
    }

    if ($Name -match '(?i)Intel') {
        $intel = Get-WrIntelGeneration -Name $Name
        if ($intel.Known -and $intel.Supported) {
            return [pscustomobject]@{ Status = 'Pass'; Detail = $intel.Detail }
        }
        if ($intel.Known) {
            return [pscustomobject]@{ Status = 'Fail'; Detail = "$($intel.Detail) is below Windows 11 (8th generation or newer)" }
        }
        if ($Name -match '(?i)Xeon') {
            if ($Name -match '(?i)Xeon[^A-Za-z0-9]*(E-?2[1-9]\d{2}|W-\d{4})') {
                return [pscustomobject]@{ Status = 'Pass'; Detail = 'Xeon model looks like an 8th-generation equivalent or newer' }
            }
            return [pscustomobject]@{ Status = 'Review'; Detail = 'Xeon support is model-specific. Confirm it on the Microsoft Windows 11 CPU list' }
        }
        if ($Name -match '(?i)Pentium|Celeron|Atom') {
            return [pscustomobject]@{ Status = 'Fail'; Detail = 'Pentium, Celeron, and Atom are treated as not Windows 11 capable by this heuristic' }
        }
        return [pscustomobject]@{ Status = 'Review'; Detail = 'Unrecognized Intel CPU. Confirm it on the Microsoft Windows 11 CPU list' }
    }

    if ($Name -match '(?i)AMD') {
        if ($Name -match '(?i)Ryzen') {
            $ryzen = [regex]::Match($Name, '(?i)Ryzen.*?(\d{4})')
            if ($ryzen.Success) {
                $model = [int]$ryzen.Groups[1].Value
                if ($model -ge 2000) {
                    return [pscustomobject]@{ Status = 'Pass'; Detail = "AMD Ryzen $model" }
                }
                return [pscustomobject]@{ Status = 'Fail'; Detail = "AMD Ryzen $model is below the supported 2000 series" }
            }
            return [pscustomobject]@{ Status = 'Review'; Detail = 'Ryzen model number was not recognized' }
        }
        if ($Name -match '(?i)Threadripper') {
            $threadripper = [regex]::Match($Name, '(?i)Threadripper.*?(\d{4})')
            if ($threadripper.Success) {
                $model = [int]$threadripper.Groups[1].Value
                if ($model -ge 2000) {
                    return [pscustomobject]@{ Status = 'Pass'; Detail = "AMD Threadripper $model" }
                }
                return [pscustomobject]@{ Status = 'Fail'; Detail = "AMD Threadripper $model is below the supported series" }
            }
            return [pscustomobject]@{ Status = 'Review'; Detail = 'Threadripper model number was not recognized' }
        }
        if ($Name -match '(?i)EPYC|Athlon') {
            return [pscustomobject]@{ Status = 'Review'; Detail = 'This AMD model needs a manual check against the Microsoft Windows 11 CPU list' }
        }
        return [pscustomobject]@{ Status = 'Review'; Detail = 'Unrecognized AMD CPU' }
    }

    if ($Name -match '(?i)Virtual|QEMU|KVM|Hyper-V') {
        return [pscustomobject]@{ Status = 'Review'; Detail = 'Virtual CPU. Windows 11 support depends on the host and firmware' }
    }

    return [pscustomobject]@{ Status = 'Review'; Detail = 'Unrecognized CPU vendor' }
}

function Get-WrFirmwareResult {
    param($FirmwareType)

    $text = [string]$FirmwareType
    if ($text -eq '2' -or $text -eq 'UEFI') {
        return [pscustomobject]@{ Status = 'Pass'; Detail = 'UEFI' }
    }
    if ($text -eq '1' -or $text -eq 'BIOS' -or $text -eq 'Legacy') {
        return [pscustomobject]@{ Status = 'Fail'; Detail = 'Legacy BIOS' }
    }
    return [pscustomobject]@{ Status = 'Fail'; Detail = 'Firmware type could not be read' }
}

function Get-WrSecureBootResult {
    param(
        [bool]$Enabled,
        [bool]$Known,
        [string]$ErrorMessage
    )

    if (-not $Known) {
        $detail = 'Secure Boot state could not be read'
        if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
            $detail = '{0}: {1}' -f $detail, $ErrorMessage
        }
        return [pscustomobject]@{ Status = 'Fail'; Detail = $detail }
    }
    if ($Enabled) {
        return [pscustomobject]@{ Status = 'Pass'; Detail = 'Secure Boot is on' }
    }
    return [pscustomobject]@{ Status = 'Fail'; Detail = 'Secure Boot is off' }
}

function Get-WrTpmResult {
    param(
        [bool]$Present,
        [bool]$Ready,
        [string]$SpecVersion,
        [string]$Manufacturer
    )

    if (-not $Present) {
        return [pscustomobject]@{ Status = 'Fail'; Detail = 'TPM is not present' }
    }
    if ($SpecVersion -notmatch '(\d+)\.(\d+)') {
        return [pscustomobject]@{ Status = 'Fail'; Detail = 'TPM is present but the spec version could not be read' }
    }
    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    $vendor = ''
    if (-not [string]::IsNullOrWhiteSpace($Manufacturer)) {
        $vendor = ", $Manufacturer"
    }
    if ($major -lt 2) {
        return [pscustomobject]@{ Status = 'Fail'; Detail = "TPM $major.$minor is below 2.0$vendor" }
    }
    if (-not $Ready) {
        return [pscustomobject]@{ Status = 'Fail'; Detail = "TPM $major.$minor is present but not ready$vendor" }
    }
    return [pscustomobject]@{ Status = 'Pass'; Detail = "TPM $major.$minor is ready$vendor" }
}

function Get-WrMemoryResult {
    param(
        [uint64]$Bytes,
        [int]$MinRamGB
    )

    $gb = [math]::Round(($Bytes / 1073741824), 1)
    $gbText = $gb.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $nominal = [math]::Round(($Bytes / 1073741824), 0, [System.MidpointRounding]::AwayFromZero)
    $detail = "$gbText GB installed (minimum $MinRamGB GB)"
    if ($nominal -ge $MinRamGB) {
        return [pscustomobject]@{ Status = 'Pass'; Detail = $detail }
    }
    return [pscustomobject]@{ Status = 'Fail'; Detail = $detail }
}

function Get-WrDiskResult {
    param(
        [uint64]$Bytes,
        [int]$MinimumGB,
        [string]$Label
    )

    $gb = [math]::Round(($Bytes / 1073741824), 1)
    $text = $gb.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $detail = "$text GB $Label (minimum $MinimumGB GB)"
    $minimum = ConvertTo-WrByte -Gigabytes $MinimumGB
    if ($Bytes -ge $minimum) {
        return [pscustomobject]@{ Status = 'Pass'; Detail = $detail }
    }
    return [pscustomobject]@{ Status = 'Fail'; Detail = $detail }
}

function Get-WrReadiness {
    param(
        [bool]$IsServer,
        [bool]$IsWindows11,
        $Checks
    )

    if ($IsServer) {
        return [pscustomobject]@{
            ExitCode = 0
            Result   = 'Pass'
            Summary  = 'Not applicable. Windows Server is not upgraded to Windows 11.'
        }
    }

    $problems = @()
    foreach ($check in @($Checks)) {
        if ($check.Status -ne 'Pass') {
            $problems += [string]$check.Name
        }
    }

    if ($IsWindows11) {
        if ($problems.Count -eq 0) {
            $summary = 'Already running Windows 11. Readiness checks passed.'
        } else {
            $summary = 'Already running Windows 11. Readiness gaps (informational): ' + ($problems -join ', ') + '.'
        }
        return [pscustomobject]@{ ExitCode = 0; Result = 'Pass'; Summary = $summary }
    }

    if ($problems.Count -eq 0) {
        return [pscustomobject]@{ ExitCode = 0; Result = 'Pass'; Summary = 'Ready for Windows 11.' }
    }
    return [pscustomobject]@{
        ExitCode = 1
        Result   = 'Fail'
        Summary  = ('Not ready for Windows 11: {0}.' -f ($problems -join ', '))
    }
}

function Get-WrRegistryValue {
    param(
        [string]$SubKey,
        [string]$Name
    )

    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $base.OpenSubKey($SubKey)
        if ($null -eq $key) {
            return $null
        }
        try {
            return $key.GetValue($Name)
        } finally {
            $key.Close()
        }
    } finally {
        $base.Close()
    }
}

function Invoke-WrMain {
    param(
        [int]$MinRamGB = 4,
        [int]$MinDiskGB = 64,
        [int]$MinFreeGB = 20
    )

    $script:ScExitCode = 2
    try {
        if (-not (Test-WrWindowsHost)) {
            Write-WrResult -Result Error -Summary 'This script must run on Windows.'
            return
        }

        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
        $caption = [string]$os.Caption
        $build = 0
        [void][int]::TryParse([string]$os.BuildNumber, [ref]$build)
        $productType = 0
        [void][int]::TryParse([string]$os.ProductType, [ref]$productType)
        $isServer = Test-WrIsServer -Caption $caption -ProductType $productType
        $isWin11 = Test-WrIsWindows11 -Caption $caption -Build $build

        Write-Output ('Computer: {0}' -f $env:COMPUTERNAME)
        Write-Output ('Time: {0}' -f (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK'))
        Write-Output ('OS: {0} (build {1}, product type {2})' -f (Format-WrText -Value $caption), $build, $productType)
        if ($isServer) {
            Write-Output 'Applicability: Windows Server is not a Windows 11 upgrade target'
        } elseif ($isWin11) {
            Write-Output 'Applicability: already Windows 11'
        } else {
            Write-Output 'Applicability: Windows client upgrade candidate'
        }

        $checks = @()

        $firmware = Get-WrFirmwareResult -FirmwareType (Get-WrRegistryValue -SubKey 'SYSTEM\CurrentControlSet\Control' -Name 'PEFirmwareType')
        $checks += [pscustomobject]@{ Name = 'Firmware'; Status = $firmware.Status; Detail = $firmware.Detail }

        $secureKnown = $false
        $secureEnabled = $false
        $secureError = ''
        try {
            $secureEnabled = [bool](Confirm-SecureBootUEFI -ErrorAction Stop)
            $secureKnown = $true
        } catch {
            $secureError = $_.Exception.Message
        }
        $secure = Get-WrSecureBootResult -Enabled $secureEnabled -Known $secureKnown -ErrorMessage $secureError
        $checks += [pscustomobject]@{ Name = 'Secure Boot'; Status = $secure.Status; Detail = $secure.Detail }

        $tpmPresent = $false
        $tpmReady = $false
        $tpmSpec = ''
        $tpmVendor = ''
        try {
            $tpm = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName 'Win32_Tpm' -ErrorAction Stop
            if ($null -ne $tpm) {
                $tpmPresent = $true
                $tpmSpec = [string]$tpm.SpecVersion
                $tpmVendor = [string]$tpm.ManufacturerIdTxt
                if ([string]::IsNullOrWhiteSpace($tpmVendor)) {
                    $tpmVendor = [string]$tpm.ManufacturerVersionInfo
                }
                $tpmReady = [bool]$tpm.IsEnabled_InitialValue -and [bool]$tpm.IsActivated_InitialValue
            }
        } catch {
            $tpmSpec = ''
            $tpmPresent = $false
        }
        $tpmResult = Get-WrTpmResult -Present $tpmPresent -Ready $tpmReady -SpecVersion $tpmSpec -Manufacturer $tpmVendor
        $checks += [pscustomobject]@{ Name = 'TPM'; Status = $tpmResult.Status; Detail = $tpmResult.Detail }

        $cores = 0
        $logical = 0
        $width = 0
        $clock = 0
        $cpuName = ''
        foreach ($processor in $processors) {
            $coreCount = 0
            $logicalCount = 0
            $widthCount = 0
            $clockCount = 0
            [void][int]::TryParse([string]$processor.NumberOfCores, [ref]$coreCount)
            [void][int]::TryParse([string]$processor.NumberOfLogicalProcessors, [ref]$logicalCount)
            [void][int]::TryParse([string]$processor.AddressWidth, [ref]$widthCount)
            [void][int]::TryParse([string]$processor.MaxClockSpeed, [ref]$clockCount)
            $cores += $coreCount
            $logical += $logicalCount
            if ($width -eq 0 -or ($widthCount -gt 0 -and $widthCount -lt $width)) {
                $width = $widthCount
            }
            if ($clockCount -gt $clock) {
                $clock = $clockCount
            }
            if ([string]::IsNullOrWhiteSpace($cpuName)) {
                $cpuName = [string]$processor.Name
            }
        }
        $cpu = Test-WrCpuSupport -Name $cpuName -Cores $cores -AddressWidth $width -MaxClockMHz $clock
        $cpuDetail = '{0}; {1} cores, {2} logical, {3}-bit, {4} MHz' -f $cpu.Detail, $cores, $logical, $width, $clock
        $checks += [pscustomobject]@{ Name = 'CPU'; Status = $cpu.Status; Detail = $cpuDetail }

        $ramBytes = [uint64]0
        [void][uint64]::TryParse([string]$computer.TotalPhysicalMemory, [ref]$ramBytes)
        $memory = Get-WrMemoryResult -Bytes $ramBytes -MinRamGB $MinRamGB
        $checks += [pscustomobject]@{ Name = 'RAM'; Status = $memory.Status; Detail = $memory.Detail }

        $systemDisk = $null
        $logicalDisks = @(Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop)
        foreach ($logicalDisk in $logicalDisks) {
            if ([string]$logicalDisk.DeviceID -eq [string]$env:SystemDrive) {
                $systemDisk = $logicalDisk
            }
        }
        if ($null -eq $systemDisk) {
            throw "System drive $env:SystemDrive was not found."
        }
        $sizeBytes = [uint64]0
        $freeBytes = [uint64]0
        [void][uint64]::TryParse([string]$systemDisk.Size, [ref]$sizeBytes)
        [void][uint64]::TryParse([string]$systemDisk.FreeSpace, [ref]$freeBytes)
        $sizeResult = Get-WrDiskResult -Bytes $sizeBytes -MinimumGB $MinDiskGB -Label 'system volume'
        $freeResult = Get-WrDiskResult -Bytes $freeBytes -MinimumGB $MinFreeGB -Label 'free on the system volume'
        $checks += [pscustomobject]@{ Name = 'System disk size'; Status = $sizeResult.Status; Detail = $sizeResult.Detail }
        $checks += [pscustomobject]@{ Name = 'System disk free space'; Status = $freeResult.Status; Detail = $freeResult.Detail }

        Write-Output ''
        foreach ($check in $checks) {
            Write-Output ('{0}: {1} ({2})' -f (Format-WrText -Value $check.Name), (Format-WrText -Value $check.Status), (Format-WrText -Value $check.Detail))
        }
        Write-Output ''
        Write-Output 'CPU support is a heuristic. Review status means the model was not on the built-in workstation list.'

        $decision = Get-WrReadiness -IsServer $isServer -IsWindows11 $isWin11 -Checks $checks
        Write-Output ''
        Write-WrResult -Result $decision.Result -Summary $decision.Summary
        $script:ScExitCode = $decision.ExitCode
    } catch {
        Write-WrResult -Result Error -Summary $_.Exception.Message
        $script:ScExitCode = 2
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $script:ScExitCode = 2
    try {
        Invoke-WrMain -MinRamGB $MinRamGB -MinDiskGB $MinDiskGB -MinFreeGB $MinFreeGB | Out-Host
    } catch {
        Write-Output 'RESULT: Error' | Out-Host
        Write-Output ('Summary: {0}' -f $_.Exception.Message) | Out-Host
        $script:ScExitCode = 2
    }
    Write-Output ('EXITCODE: {0}' -f $script:ScExitCode) | Out-Host
    exit $script:ScExitCode
}
