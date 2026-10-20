<#
.SYNOPSIS
    Install Microsoft 365 Apps with the Office Deployment Tool.

.DESCRIPTION
    Purpose: Install 64-bit Microsoft 365 Apps on the Current channel for a
    dental office PC. Skips the install when the requested product is already
    installed as 64-bit. Does not replace a different product or 32-bit Office.
    Does not close Word, Outlook, or other Office apps unless -AllowAppShutdown
    is passed. Does not reboot unless setup returns 3010 and -AllowReboot is passed.

    Parameters:
      -Product                  O365BusinessRetail or O365ProPlusRetail. Required.
      -Language                 Language ID. Default en-us.
      -OdtUrl                   Direct Office Deployment Tool exe URL. Optional.
      -AllowAppShutdown         Let setup close Office apps. Default off.
      -AllowReboot              Schedule a reboot in 60 seconds when setup
                                returns 3010. Default off.
      -RemoveExistingMsi        Add RemoveMSI so old MSI Office is removed.
                                Default off.
      -SharedComputerLicensing  Turn on shared computer licensing for RDS.
                                Default off.
      -ForceOdtDownload         Download a fresh copy of the deployment tool.

.NOTES
    Standard Computer Tactical RMM script. Windows PowerShell 5.1. Run as SYSTEM.
    Idempotent. Does not use credentials. A missing text value prints as n/a.
    The last stdout line is EXITCODE: N. Tactical ad-hoc command output does
    not show the process exit code. Set the Tactical timeout to at least
    90 minutes. The Office installer may restart the Click-to-Run service.

    Exit codes:
      0  The requested 64-bit product is already installed, or setup finished.
      1  Install was refused, setup failed, or a reboot is still required.
      2  The product id was missing, or the deployment tool could not be downloaded.

.EXAMPLE
    .\Install-Microsoft365Apps.ps1 -Product O365BusinessRetail
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Product,

    [string]$Language = 'en-us',

    [string]$OdtUrl,

    [switch]$AllowAppShutdown,

    [switch]$AllowReboot,

    [switch]$RemoveExistingMsi,

    [switch]$SharedComputerLicensing,

    [switch]$ForceOdtDownload
)

function Test-MoWindowsHost {
    $variable = Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue
    if ($null -eq $variable) {
        return $true
    }
    return [bool]$variable.Value
}

function Write-MoResult {
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

function Format-MoText {
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

function Format-MoXmlText {
    param([string]$Text)

    if ($null -eq $Text) {
        return ''
    }
    return [System.Security.SecurityElement]::Escape($Text)
}

function Get-MoInstallAction {
    param(
        [string[]]$InstalledProducts,
        [string]$Platform,
        [string]$RequestedProduct
    )

    $products = @()
    foreach ($installed in @($InstalledProducts)) {
        if (-not [string]::IsNullOrWhiteSpace($installed)) {
            $products += $installed.Trim()
        }
    }

    $hasRequested = $false
    $others = @()
    foreach ($installed in $products) {
        if ($installed -eq $RequestedProduct) {
            $hasRequested = $true
        } else {
            $others += $installed
        }
    }

    if ($hasRequested -and $Platform -eq 'x64') {
        return [pscustomobject]@{
            Action = 'Skip'
            Reason = "64-bit $RequestedProduct is already installed."
        }
    }
    if ($hasRequested) {
        $shown = $Platform
        if ([string]::IsNullOrWhiteSpace($shown)) {
            $shown = 'unknown bitness'
        }
        return [pscustomobject]@{
            Action = 'Stop'
            Reason = "$RequestedProduct is installed as $shown. This script installs 64-bit only and will not change the architecture."
        }
    }
    if ($others.Count -gt 0) {
        return [pscustomobject]@{
            Action = 'Stop'
            Reason = ('A different Microsoft 365 product is installed ({0}). This script will not replace it.' -f ($others -join ', '))
        }
    }
    if ($Platform -eq 'x86') {
        return [pscustomobject]@{
            Action = 'Stop'
            Reason = '32-bit Office Click-to-Run components are present. This script will not replace them.'
        }
    }
    return [pscustomobject]@{
        Action = 'Install'
        Reason = 'Microsoft 365 Apps is not installed.'
    }
}

function Test-MoCurrentChannel {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $false
    }
    return $Url -match '492350f6-3a01-4f97-b9c0-c7c6ddf67d60'
}

function Format-MoConfigurationXml {
    param(
        [string]$ProductId,
        [string]$Language,
        [bool]$SharedComputerLicensing,
        [bool]$ForceAppShutdown,
        [bool]$RemoveExistingMsi,
        [string]$LogPath
    )

    $productText = Format-MoXmlText -Text $ProductId
    $languageText = Format-MoXmlText -Text $Language
    $logText = Format-MoXmlText -Text $LogPath
    $shared = '0'
    if ($SharedComputerLicensing) {
        $shared = '1'
    }
    $force = 'FALSE'
    if ($ForceAppShutdown) {
        $force = 'TRUE'
    }

    $lines = @(
        '<Configuration>',
        '  <Add OfficeClientEdition="64" Channel="Current" MigrateArch="FALSE">',
        "    <Product ID=`"$productText`">",
        "      <Language ID=`"$languageText`" />",
        '    </Product>',
        '  </Add>',
        "  <Property Name=`"SharedComputerLicensing`" Value=`"$shared`" />",
        "  <Property Name=`"FORCEAPPSHUTDOWN`" Value=`"$force`" />",
        '  <Property Name="DeviceBasedLicensing" Value="0" />',
        '  <Property Name="SCLCacheOverride" Value="0" />',
        '  <Updates Enabled="TRUE" />',
        '  <Display Level="None" AcceptEULA="TRUE" />',
        "  <Logging Level=`"Standard`" Path=`"$logText`" />"
    )
    if ($RemoveExistingMsi) {
        $lines += '  <RemoveMSI />'
    }
    $lines += '</Configuration>'
    return ($lines -join "`r`n")
}

function Get-MoOdtUrlFromHtml {
    param([string]$Html)

    if ([string]::IsNullOrWhiteSpace($Html)) {
        return $null
    }
    $pattern = 'https://download\.microsoft\.com/download/[^"''<>\s]+officedeploymenttool_[^"''<>\s]+\.exe'
    $match = [regex]::Match($Html, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        return $match.Value
    }
    return $null
}

function Get-MoOfficeState {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $base.OpenSubKey('SOFTWARE\Microsoft\Office\ClickToRun\Configuration')
        if ($null -eq $key) {
            return [pscustomobject]@{
                Products   = @()
                Platform   = $null
                Version    = $null
                ChannelUrl = $null
            }
        }
        try {
            $raw = [string]$key.GetValue('ProductReleaseIds')
            $products = @()
            foreach ($item in @($raw -split ',')) {
                if (-not [string]::IsNullOrWhiteSpace($item)) {
                    $products += $item.Trim()
                }
            }
            return [pscustomobject]@{
                Products   = $products
                Platform   = [string]$key.GetValue('Platform')
                Version    = [string]$key.GetValue('VersionToReport')
                ChannelUrl = [string]$key.GetValue('CDNBaseUrl')
            }
        } finally {
            $key.Close()
        }
    } finally {
        $base.Close()
    }
}

function Resolve-MoOdtUrl {
    $pages = @(
        'https://www.microsoft.com/en-us/download/confirmation.aspx?id=49117',
        'https://www.microsoft.com/en-us/download/details.aspx?id=49117'
    )
    $headers = @{
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    }
    foreach ($page in $pages) {
        Write-Output ('Looking up the Office Deployment Tool link: {0}' -f $page)
        $response = Invoke-WebRequest -Uri $page -UseBasicParsing -Headers $headers -MaximumRedirection 5
        $url = Get-MoOdtUrlFromHtml -Html ([string]$response.Content)
        if (-not [string]::IsNullOrWhiteSpace($url)) {
            return $url
        }
        foreach ($link in @($response.Links)) {
            $href = [string]$link.href
            $fromHref = Get-MoOdtUrlFromHtml -Html $href
            if (-not [string]::IsNullOrWhiteSpace($fromHref)) {
                return $fromHref
            }
        }
    }
    return $null
}

function Get-MoRunningOfficeProcess {
    $names = @(
        'WINWORD', 'EXCEL', 'OUTLOOK', 'POWERPNT', 'ONENOTE', 'MSACCESS',
        'MSPUB', 'LYNC', 'WINPROJ', 'VISIO', 'Teams'
    )
    $found = @()
    foreach ($name in $names) {
        $processes = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        foreach ($process in $processes) {
            $found += [pscustomobject]@{
                Name = [string]$process.ProcessName
                Id   = [int]$process.Id
            }
        }
    }
    return $found
}

function Invoke-MoMain {
    param(
        [string]$Product,
        [string]$Language = 'en-us',
        [string]$OdtUrl,
        [bool]$AllowAppShutdown = $false,
        [bool]$AllowReboot = $false,
        [bool]$RemoveExistingMsi = $false,
        [bool]$SharedComputerLicensing = $false,
        [bool]$ForceOdtDownload = $false
    )

    $script:ScExitCode = 2
    try {
        if (-not (Test-MoWindowsHost)) {
            Write-MoResult -Result Error -Summary 'This script must run on Windows.'
            return
        }

        $allowed = @('O365BusinessRetail', 'O365ProPlusRetail')
        if ($allowed -notcontains $Product) {
            Write-MoResult -Result Error -Summary '-Product is required and must be O365BusinessRetail or O365ProPlusRetail.'
            return
        }
        if ($Language -notmatch '^[a-z]{2}-[a-z]{2}$') {
            Write-MoResult -Result Error -Summary '-Language must look like en-us.'
            return
        }

        Write-Output ('Computer: {0}' -f $env:COMPUTERNAME)
        Write-Output ('Time: {0}' -f (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK'))
        Write-Output ('Requested product: {0}' -f $Product)
        Write-Output 'Architecture: 64-bit'
        Write-Output 'Channel: Current'
        Write-Output ('Language: {0}' -f $Language)

        $state = Get-MoOfficeState
        if ($state.Products.Count -gt 0) {
            Write-Output ('Installed products: {0}' -f ($state.Products -join ', '))
            Write-Output ('Platform: {0}' -f (Format-MoText -Value $state.Platform))
            Write-Output ('Version: {0}' -f (Format-MoText -Value $state.Version))
            if (Test-MoCurrentChannel -Url $state.ChannelUrl) {
                Write-Output 'Update channel: Current'
            } elseif (-not [string]::IsNullOrWhiteSpace($state.ChannelUrl)) {
                Write-Output ('Update channel URL: {0}' -f $state.ChannelUrl)
                Write-Output 'Note: the installed channel is not Current. An existing install is left as-is.'
            }
        } else {
            Write-Output 'Installed products: none'
        }

        $action = Get-MoInstallAction -InstalledProducts $state.Products -Platform $state.Platform -RequestedProduct $Product
        Write-Output ('Action: {0}' -f $action.Action)
        Write-Output ('Reason: {0}' -f $action.Reason)
        if ($action.Action -eq 'Skip') {
            Write-MoResult -Result Pass -Summary $action.Reason
            $script:ScExitCode = 0
            return
        }
        if ($action.Action -eq 'Stop') {
            Write-MoResult -Result Fail -Summary $action.Reason
            $script:ScExitCode = 1
            return
        }

        $blocking = @(Get-MoRunningOfficeProcess)
        if ($blocking.Count -gt 0 -and -not $AllowAppShutdown) {
            Write-Output 'Office applications are running:'
            foreach ($process in $blocking) {
                Write-Output ('  {0} (pid {1})' -f $process.Name, $process.Id)
            }
            Write-MoResult -Result Fail -Summary 'Office applications are open. Close them, or pass -AllowAppShutdown.'
            $script:ScExitCode = 1
            return
        }

        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $work = Join-Path $env:ProgramData 'StandardComputer\Tactical\OfficeODT'
        if ([string]::IsNullOrWhiteSpace($env:ProgramData)) {
            $work = 'C:\ProgramData\StandardComputer\Tactical\OfficeODT'
        }
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $logDir = Join-Path $work 'logs'
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null

        $setup = Join-Path $work 'setup.exe'
        $needDownload = $ForceOdtDownload -or -not (Test-Path -LiteralPath $setup)
        if ($needDownload) {
            $url = $OdtUrl
            if ([string]::IsNullOrWhiteSpace($url)) {
                $url = Resolve-MoOdtUrl
            }
            if ([string]::IsNullOrWhiteSpace($url)) {
                Write-MoResult -Result Error -Summary 'Could not resolve the Office Deployment Tool download URL. Pass -OdtUrl.'
                return
            }
            $installer = Join-Path $work 'officedeploymenttool.exe'
            Write-Output ('Downloading Office Deployment Tool: {0}' -f $url)
            Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
            if (Test-Path -LiteralPath $setup) {
                Remove-Item -LiteralPath $setup -Force
            }
            $extractArgs = @('/quiet', '/norestart', ('/extract:{0}' -f $work))
            $extract = Start-Process -FilePath $installer -ArgumentList $extractArgs -Wait -PassThru -WindowStyle Hidden
            $extractCode = $extract.ExitCode
            if ($null -eq $extractCode) {
                $extractCode = 0
            }
            if ($extractCode -ne 0 -or -not (Test-Path -LiteralPath $setup)) {
                Write-MoResult -Result Error -Summary ('Office Deployment Tool extraction failed with exit code {0}.' -f $extractCode)
                return
            }
            Write-Output 'Office Deployment Tool extracted.'
        } else {
            Write-Output ('Reusing Office Deployment Tool: {0}' -f $setup)
        }

        $xml = Format-MoConfigurationXml -ProductId $Product -Language $Language -SharedComputerLicensing ([bool]$SharedComputerLicensing) -ForceAppShutdown ([bool]$AllowAppShutdown) -RemoveExistingMsi ([bool]$RemoveExistingMsi) -LogPath $logDir
        $xmlPath = Join-Path $work 'configuration.xml'
        $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
        [System.IO.File]::WriteAllText($xmlPath, $xml, $utf8)
        Write-Output ('Wrote {0}' -f $xmlPath)

        $stdoutLog = Join-Path $logDir 'setup.stdout.log'
        $stderrLog = Join-Path $logDir 'setup.stderr.log'
        Write-Output 'Starting Office setup. This can take a long time.'
        $proc = Start-Process -FilePath $setup -ArgumentList @('/configure', $xmlPath) -WorkingDirectory $work -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
        Write-Output ('setup.exe exit code: {0}' -f $proc.ExitCode)
        Write-Output ('Setup stdout log: {0}' -f $stdoutLog)
        Write-Output ('Setup stderr log: {0}' -f $stderrLog)

        $after = Get-MoOfficeState
        $confirmed = $false
        foreach ($installed in @($after.Products)) {
            if ($installed -eq $Product -and $after.Platform -eq 'x64') {
                $confirmed = $true
            }
        }
        Write-Output ('Installed products after setup: {0}' -f ($(if ($after.Products.Count -eq 0) { 'none' } else { $after.Products -join ', ' })))
        Write-Output ('Platform after setup: {0}' -f (Format-MoText -Value $after.Platform))

        if ($proc.ExitCode -eq 3010 -and $confirmed) {
            Write-Output 'Office setup reported that a reboot is required (3010).'
            if ($AllowReboot) {
                Write-Output 'Reboot scheduled in 60 seconds because -AllowReboot was specified.'
                $shutdown = Join-Path $env:SystemRoot 'System32\shutdown.exe'
                & $shutdown /r /t 60 /c 'Standard Computer: Microsoft 365 Apps setup requested a reboot.'
                Write-MoResult -Result Pass -Summary "Installed $Product. A reboot is scheduled in 60 seconds."
                $script:ScExitCode = 0
                return
            }
            Write-MoResult -Result Fail -Summary "Installed $Product, but Windows requested a reboot. Pass -AllowReboot only when the office can restart."
            $script:ScExitCode = 1
            return
        }

        if ($confirmed -and $proc.ExitCode -eq 0) {
            Write-MoResult -Result Pass -Summary "Installed 64-bit $Product on the Current channel."
            $script:ScExitCode = 0
            return
        }

        Write-MoResult -Result Fail -Summary ("Microsoft 365 Apps setup did not finish cleanly for {0}. setup.exe returned {1}." -f $Product, $proc.ExitCode)
        $script:ScExitCode = 1
    } catch {
        Write-MoResult -Result Error -Summary $_.Exception.Message
        $script:ScExitCode = 2
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $script:ScExitCode = 2
    try {
        Invoke-MoMain -Product $Product -Language $Language -OdtUrl $OdtUrl -AllowAppShutdown ([bool]$AllowAppShutdown) -AllowReboot ([bool]$AllowReboot) -RemoveExistingMsi ([bool]$RemoveExistingMsi) -SharedComputerLicensing ([bool]$SharedComputerLicensing) -ForceOdtDownload ([bool]$ForceOdtDownload) | Out-Host
    } catch {
        Write-Output 'RESULT: Error' | Out-Host
        Write-Output ('Summary: {0}' -f $_.Exception.Message) | Out-Host
        $script:ScExitCode = 2
    }
    Write-Output ('EXITCODE: {0}' -f $script:ScExitCode) | Out-Host
    exit $script:ScExitCode
}
