<#
.SYNOPSIS
    Report whether Windows is waiting to reboot.

.DESCRIPTION
    Purpose: Check the reboot signals a dental office PC can pick up during
    the day: Component Based Servicing, Windows Update, pending file rename
    operations, and a pending computer rename. This script only reports the
    state. It does not reboot the PC.

    Parameters: none.

.NOTES
    Standard Computer Tactical RMM script. Windows PowerShell 5.1. Run as SYSTEM.
    Idempotent. Does not reboot and does not restart services.
    Does not use credentials. A missing text value prints as n/a.
    The last stdout line is EXITCODE: N. Tactical ad-hoc command output does
    not show the process exit code.

    Pending file rename operations are included because Windows uses them to
    finish updates and driver installs. Some application installers set the
    same value, so read the signal name in the output before rebooting.

    Exit codes:
      0  No reboot is pending.
      1  A reboot is pending.
      2  The reboot state could not be read.

.EXAMPLE
    .\Test-PendingReboot.ps1
#>
#Requires -Version 5.1
[CmdletBinding()]
param()

function Test-PrWindowsHost {
    $variable = Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue
    if ($null -eq $variable) {
        return $true
    }
    return [bool]$variable.Value
}

function Write-PrResult {
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

function Format-PrText {
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

function Test-PrRebootPendingState {
    param(
        [bool]$ComponentBasedServicing,
        [bool]$WindowsUpdate,
        [bool]$PendingFileRename,
        [bool]$ComputerRename
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    if ($ComponentBasedServicing) {
        $reasons.Add('Component Based Servicing')
    }
    if ($WindowsUpdate) {
        $reasons.Add('Windows Update')
    }
    if ($PendingFileRename) {
        $reasons.Add('pending file rename operations')
    }
    if ($ComputerRename) {
        $reasons.Add('computer rename')
    }
    [pscustomobject]@{
        Pending = ($reasons.Count -gt 0)
        Reasons = @($reasons)
    }
}

function Test-PrRegistryKey {
    param([string]$SubKey)

    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $base.OpenSubKey($SubKey)
        if ($null -eq $key) {
            return $false
        }
        $key.Close()
        return $true
    } finally {
        $base.Close()
    }
}

function Get-PrRegistryValue {
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

function Test-PrPendingFileRename {
    $value = Get-PrRegistryValue -SubKey 'SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations'
    if ($null -eq $value) {
        return $false
    }
    $items = @($value)
    foreach ($item in $items) {
        if (-not [string]::IsNullOrWhiteSpace([string]$item)) {
            return $true
        }
    }
    return $false
}

function Test-PrComputerRename {
    $active = [string](Get-PrRegistryValue -SubKey 'SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name 'ComputerName')
    $pending = [string](Get-PrRegistryValue -SubKey 'SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name 'ComputerName')
    if ([string]::IsNullOrWhiteSpace($active) -or [string]::IsNullOrWhiteSpace($pending)) {
        return $false
    }
    return ($active -ne $pending)
}

function Invoke-PrMain {
    $script:ScExitCode = 2
    try {
        if (-not (Test-PrWindowsHost)) {
            Write-PrResult -Result Error -Summary 'This script must run on Windows.'
            return
        }

        $cbs = Test-PrRegistryKey -SubKey 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        $wu = Test-PrRegistryKey -SubKey 'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        $renameFiles = Test-PrPendingFileRename
        $renameComputer = Test-PrComputerRename
        $state = Test-PrRebootPendingState -ComponentBasedServicing $cbs -WindowsUpdate $wu -PendingFileRename $renameFiles -ComputerRename $renameComputer

        Write-Output ('Computer: {0}' -f (Format-PrText -Value $env:COMPUTERNAME))
        Write-Output ('Time: {0}' -f (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK'))
        Write-Output ('Component Based Servicing: {0}' -f ($(if ($cbs) { 'PENDING' } else { 'clear' })))
        Write-Output ('Windows Update reboot required: {0}' -f ($(if ($wu) { 'PENDING' } else { 'clear' })))
        Write-Output ('Pending file rename: {0}' -f ($(if ($renameFiles) { 'PENDING' } else { 'clear' })))
        Write-Output ('Computer rename: {0}' -f ($(if ($renameComputer) { 'PENDING' } else { 'clear' })))
        Write-Output ''
        if ($state.Pending) {
            Write-PrResult -Result Fail -Summary ('Reboot pending: {0}.' -f ($state.Reasons -join ', '))
            $script:ScExitCode = 1
            return
        }
        Write-PrResult -Result Pass -Summary 'No reboot is pending.'
        $script:ScExitCode = 0
    } catch {
        Write-PrResult -Result Error -Summary $_.Exception.Message
        $script:ScExitCode = 2
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $script:ScExitCode = 2
    try {
        Invoke-PrMain | Out-Host
    } catch {
        Write-Output 'RESULT: Error' | Out-Host
        Write-Output ('Summary: {0}' -f $_.Exception.Message) | Out-Host
        $script:ScExitCode = 2
    }
    Write-Output ('EXITCODE: {0}' -f $script:ScExitCode) | Out-Host
    exit $script:ScExitCode
}
