<#
.SYNOPSIS
    Audit the local Administrators group.

.DESCRIPTION
    Purpose: List every member of the local Administrators group and fail when
    an unexpected account or group is present. The built-in Administrator
    account (RID 500) and Domain Admins (RID 512) are expected. Pass extra
    approved MSP accounts with -AllowedPrincipal. The built-in Administrator
    account is reported when it is enabled, and fails the audit only when
    -FailOnBuiltInAdminEnabled is passed.

    Parameters:
      -AllowedPrincipal            Extra approved names or SIDs. A value
                                   without a slash matches the account leaf.
      -FailOnBuiltInAdminEnabled   Fail when the RID 500 user account is enabled.

.NOTES
    Standard Computer Tactical RMM script. Windows PowerShell 5.1. Run as SYSTEM.
    Idempotent. Does not reboot, remove members, or restart services.
    Does not use credentials. A missing text value prints as n/a.
    The last stdout line is EXITCODE: N. Tactical ad-hoc command output does
    not show the process exit code.

    Exit codes:
      0  Every member is expected.
      1  An unexpected member is present, or the built-in admin is enabled
         and -FailOnBuiltInAdminEnabled was passed.
      2  The Administrators group could not be enumerated.

.EXAMPLE
    .\Get-LocalAdminAudit.ps1 -AllowedPrincipal 'CONTOSO\Tech'
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string[]]$AllowedPrincipal = @(),

    [switch]$FailOnBuiltInAdminEnabled
)

function Test-LaWindowsHost {
    $variable = Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue
    if ($null -eq $variable) {
        return $true
    }
    return [bool]$variable.Value
}

function Write-LaResult {
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

function Format-LaText {
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

function Test-LaNameMatch {
    param(
        [string]$MemberName,
        [string]$Allowed
    )

    if ([string]::IsNullOrWhiteSpace($MemberName) -or [string]::IsNullOrWhiteSpace($Allowed)) {
        return $false
    }
    if ($MemberName -eq $Allowed) {
        return $true
    }
    $memberLeaf = ($MemberName -split '\\')[-1]
    if ($Allowed -notmatch '\\' -and $memberLeaf -eq $Allowed) {
        return $true
    }
    return $false
}

function Test-LaMemberAllowed {
    param(
        [string]$Sid,
        [string]$Name,
        [string[]]$AllowedPrincipal
    )

    if ([string]::IsNullOrWhiteSpace($Sid) -and [string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }
    if ($Sid -match '-500$') {
        return $true
    }
    if ($Sid -match '-512$') {
        return $true
    }
    foreach ($allowed in @($AllowedPrincipal)) {
        if ([string]::IsNullOrWhiteSpace($allowed)) {
            continue
        }
        if ($Sid -eq $allowed) {
            return $true
        }
        if (Test-LaNameMatch -MemberName $Name -Allowed $allowed) {
            return $true
        }
    }
    return $false
}

function Split-LaAdsPath {
    param([string]$Path)

    if ($Path -match '^WinNT://([^/]+)/([^,/]+)') {
        return [pscustomobject]@{
            Domain = $Matches[1]
            Name   = $Matches[2]
        }
    }
    return $null
}

function Get-LaAudit {
    param(
        $Members,
        [string[]]$AllowedPrincipal,
        [bool]$FailOnBuiltInAdminEnabled
    )

    $rows = @()
    $unexpected = @()
    $builtinEnabled = $false
    foreach ($member in @($Members)) {
        if ($null -eq $member) {
            continue
        }
        $sid = [string]$member.Sid
        $name = [string]$member.Name
        $class = [string]$member.Class
        $account = 'Unknown'
        $enabled = $false
        if ($member.Disabled -eq $true) {
            $account = 'Disabled'
        } elseif ($member.Disabled -eq $false) {
            $account = 'Enabled'
            $enabled = $true
        }

        $allowed = Test-LaMemberAllowed -Sid $sid -Name $name -AllowedPrincipal $AllowedPrincipal
        $note = ''
        $builtin = ($sid -match '-500$') -and ($class -eq 'User') -and $enabled
        if ($builtin) {
            $builtinEnabled = $true
            $note = 'Built-in Administrator account is enabled'
            if ($FailOnBuiltInAdminEnabled) {
                $allowed = $false
            }
        }
        if (-not $allowed) {
            if ([string]::IsNullOrWhiteSpace($name)) {
                $unexpected += $sid
            } else {
                $unexpected += $name
            }
        }
        $rows += [pscustomobject]@{
            Name     = $name
            Sid      = $sid
            Class    = $class
            Account  = $account
            Expected = $allowed
            Note     = $note
        }
    }

    if ($unexpected.Count -gt 0) {
        $summary = 'Unexpected local administrators: ' + ($unexpected -join ', ') + '.'
        if ($builtinEnabled -and $FailOnBuiltInAdminEnabled) {
            $summary = 'Built-in Administrator is enabled. ' + $summary
        }
        return [pscustomobject]@{
            Rows                = $rows
            BuiltInAdminEnabled = $builtinEnabled
            ExitCode            = 1
            Result              = 'Fail'
            Summary             = $summary
        }
    }

    $summary = 'Local Administrators matches the allow list.'
    if ($builtinEnabled) {
        $summary += ' Built-in Administrator is enabled.'
    }
    [pscustomobject]@{
        Rows                = $rows
        BuiltInAdminEnabled = $builtinEnabled
        ExitCode            = 0
        Result              = 'Pass'
        Summary             = $summary
    }
}

function Get-LaUserDisabled {
    param(
        [string]$Domain,
        [string]$Name
    )

    try {
        $computer = [string]$env:COMPUTERNAME
        if ($Domain -ne $computer -and $Domain -ne '.') {
            return $null
        }
        $user = [ADSI]('WinNT://./{0},user' -f $Name)
        $flags = [int]$user.UserFlags.Value
        return (($flags -band 2) -eq 2)
    } catch {
        return $null
    }
}

function Get-LaAdminGroupName {
    $sid = New-Object System.Security.Principal.SecurityIdentifier -ArgumentList @('S-1-5-32-544')
    $account = $sid.Translate([System.Security.Principal.NTAccount])
    $value = [string]$account.Value
    return ($value -split '\\')[-1]
}

function Get-LaMembersFromAdsi {
    $groupName = Get-LaAdminGroupName
    $group = [ADSI]('WinNT://./{0},group' -f $groupName)
    $rawMembers = @($group.Invoke('Members'))
    $results = @()
    $flags = [System.Reflection.BindingFlags]::GetProperty
    foreach ($member in $rawMembers) {
        $type = $member.GetType()
        $name = [string]$type.InvokeMember('Name', $flags, $null, $member, $null)
        $class = [string]$type.InvokeMember('Class', $flags, $null, $member, $null)
        $path = [string]$type.InvokeMember('ADsPath', $flags, $null, $member, $null)
        $sidObject = $type.InvokeMember('ObjectSID', $flags, $null, $member, $null)
        $sid = (New-Object System.Security.Principal.SecurityIdentifier -ArgumentList @($sidObject, 0)).Value
        $parsed = Split-LaAdsPath -Path $path
        $domain = $env:COMPUTERNAME
        $full = $name
        if ($null -ne $parsed) {
            $domain = $parsed.Domain
            $full = '{0}\{1}' -f $parsed.Domain, $parsed.Name
        }
        $disabled = $null
        if ($class -eq 'User') {
            $disabled = Get-LaUserDisabled -Domain $domain -Name $name
        }
        $results += [pscustomobject]@{
            Name     = $full
            Sid      = $sid
            Class    = $class
            Disabled = $disabled
        }
    }
    return $results
}

function Get-LaMembersFromCim {
    $group = Get-CimInstance -ClassName Win32_Group -Filter "SID='S-1-5-32-544' AND LocalAccount=True" -ErrorAction Stop
    if ($null -eq $group) {
        throw 'Local Administrators group was not found.'
    }
    $groupName = [string]$group.Name
    $needle = 'Name="{0}"' -f [regex]::Escape($groupName)
    $links = @(Get-CimInstance -ClassName Win32_GroupUser -ErrorAction Stop)
    $results = @()
    foreach ($link in $links) {
        $groupComponent = [string]$link.GroupComponent
        if ($groupComponent -notmatch $needle) {
            continue
        }
        $part = [string]$link.PartComponent
        $class = 'Unknown'
        if ($part -match 'Win32_UserAccount') {
            $class = 'User'
        } elseif ($part -match 'Win32_Group') {
            $class = 'Group'
        }
        $domain = $null
        $name = $null
        if ($part -match 'Domain="([^"]+)",Name="([^"]+)"') {
            $domain = $Matches[1]
            $name = $Matches[2]
        }
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }
        $sid = $null
        try {
            $account = New-Object System.Security.Principal.NTAccount -ArgumentList @($domain, $name)
            $sid = $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
        } catch {
            $sid = $null
        }
        $disabled = $null
        if ($class -eq 'User') {
            $disabled = Get-LaUserDisabled -Domain $domain -Name $name
        }
        $results += [pscustomobject]@{
            Name     = ('{0}\{1}' -f $domain, $name)
            Sid      = $sid
            Class    = $class
            Disabled = $disabled
        }
    }
    return $results
}

function Get-LaMember {
    try {
        return @(Get-LaMembersFromAdsi)
    } catch {
        Write-Output ('ADSI enumeration failed ({0}). Falling back to CIM.' -f $_.Exception.Message)
        return @(Get-LaMembersFromCim)
    }
}

function Invoke-LaMain {
    param(
        [string[]]$AllowedPrincipal = @(),
        [bool]$FailOnBuiltInAdminEnabled = $false
    )

    $script:ScExitCode = 2
    try {
        if (-not (Test-LaWindowsHost)) {
            Write-LaResult -Result Error -Summary 'This script must run on Windows.'
            return
        }

        Write-Output ('Computer: {0}' -f $env:COMPUTERNAME)
        Write-Output ('Time: {0}' -f (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK'))
        Write-Output 'Expected by default: built-in Administrator (RID 500), Domain Admins (RID 512).'
        if (@($AllowedPrincipal).Count -eq 0) {
            Write-Output 'Extra allowed principals: none'
        } else {
            Write-Output ('Extra allowed principals: {0}' -f ($AllowedPrincipal -join ', '))
        }

        $members = @(Get-LaMember)
        if ($members.Count -eq 0) {
            Write-LaResult -Result Error -Summary 'No members were returned for the local Administrators group.'
            return
        }

        $audit = Get-LaAudit -Members $members -AllowedPrincipal $AllowedPrincipal -FailOnBuiltInAdminEnabled ([bool]$FailOnBuiltInAdminEnabled)
        Write-Output 'Members:'
        foreach ($row in @($audit.Rows)) {
            $expected = 'No'
            if ($row.Expected) {
                $expected = 'Yes'
            }
            $line = '  {0}  SID {1}  {2}  {3}  expected {4}' -f (Format-LaText -Value $row.Name), (Format-LaText -Value $row.Sid), (Format-LaText -Value $row.Class), (Format-LaText -Value $row.Account), $expected
            if (-not [string]::IsNullOrWhiteSpace([string]$row.Note)) {
                $line = '{0}  {1}' -f $line, $row.Note
            }
            Write-Output $line
        }
        Write-Output ''
        Write-LaResult -Result $audit.Result -Summary $audit.Summary
        $script:ScExitCode = $audit.ExitCode
    } catch {
        Write-LaResult -Result Error -Summary $_.Exception.Message
        $script:ScExitCode = 2
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $script:ScExitCode = 2
    try {
        Invoke-LaMain -AllowedPrincipal $AllowedPrincipal -FailOnBuiltInAdminEnabled ([bool]$FailOnBuiltInAdminEnabled) | Out-Host
    } catch {
        Write-Output 'RESULT: Error' | Out-Host
        Write-Output ('Summary: {0}' -f $_.Exception.Message) | Out-Host
        $script:ScExitCode = 2
    }
    Write-Output ('EXITCODE: {0}' -f $script:ScExitCode) | Out-Host
    exit $script:ScExitCode
}
