<#
.SYNOPSIS
    Collect a replacement-PC survey for Tactical RMM and SimpleHelp.

.DESCRIPTION
    Purpose: Read the hardware, ports, displays, and dental software a tech
    needs to spec a replacement workstation or server. Prints a full summary
    on stdout, then one line of JSON, because Tactical and SimpleHelp both
    show stdout and Tactical ad-hoc command output does not show the process
    exit code.

    The same summary is saved as text and the JSON line is saved as JSON.
    The default folder is C:\ProgramData\StandardComputer\Survey. The file
    names are COMPUTERNAME_yyyyMMdd.txt and COMPUTERNAME_yyyyMMdd.json.
    -OutputPath replaces that location. A directory gets the default names.
    A path that ends in .json or .txt uses that base name for both files.

    The script is read-only. It works when the host is SYSTEM (Tactical or
    SimpleHelp) or an administrator (SimpleHelp). Registry reads use the
    64-bit view so a 32-bit PowerShell host still sees 64-bit software and
    qwMemorySize.

    Unknown text is n/a. A queried list that is empty is none. Each survey
    section runs in its own try/catch. A probe that throws records n/a for
    that section and a collection gap named "<section>: line <number>:
    <message>". One failed probe does not abort the rest of the survey.
    Ship dates decoded from a BIOS release date or a vendor serial are
    labeled estimates. GPU port layouts taken from the model name are
    labeled estimated.

    Parameters:
      -OutputPath  Optional file or directory for the saved .txt and .json.
                   Default is C:\ProgramData\StandardComputer\Survey.

.NOTES
    Standard Computer Tactical RMM script. Windows PowerShell 5.1. Run as SYSTEM
    or as an administrator. Idempotent. Does not reboot and does not restart
    services. Does not use credentials. Running it again on the same day
    overwrites that day's survey files.
    The last stdout line is EXITCODE: N. Tactical ad-hoc command output does
    not show the process exit code.

    Exit codes:
      0  The survey was collected and both files were saved.
      1  The survey was collected, but a file could not be saved.
      2  The survey could not be collected.
    The process exit code is the same number printed on the EXITCODE line.

.EXAMPLE
    .\Get-ReplacementSurvey.ps1

.EXAMPLE
    .\Get-ReplacementSurvey.ps1 -OutputPath 'D:\Surveys'
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputPath
)

function Test-RsWindowsHost {
    $variable = Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue
    if ($null -eq $variable) {
        return $true
    }
    return [bool]$variable.Value
}

function Write-RsResult {
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

function Format-RsText {
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

function Format-RsSerial {
    param($Value)

    $text = ([string]$Value).Trim()
    $text = ($text -replace '[\s\.]+$', '').Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return 'n/a'
    }
    if ($text -match '(?i)^(to be filled.*|default string|none|not specified|system serial number|chassis serial number)$') {
        return 'n/a'
    }
    return $text
}

function Format-RsGb {
    param($Bytes)

    if ($null -eq $Bytes -or [string]::IsNullOrWhiteSpace([string]$Bytes)) {
        return 'n/a'
    }
    $number = 0.0
    if (-not [double]::TryParse([string]$Bytes, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return 'n/a'
    }
    if ($number -lt 0) {
        return 'n/a'
    }
    $gb = [math]::Round($number / 1073741824, 1)
    return $gb.ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-RsProperty {
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

function ConvertTo-RsList {
    param($Item)

    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in @($Item)) {
        if ($null -ne $entry) {
            $list.Add($entry)
        }
    }
    Write-Output -NoEnumerate -InputObject $list
}

function ConvertTo-RsChassisName {
    param($ChassisType)

    $code = ([string]$ChassisType).Trim()
    $table = @{
        '3'  = 'Medium|Desktop'
        '4'  = 'Medium|SFF'
        '5'  = 'Medium|Desktop'
        '6'  = 'Large|Mini tower'
        '7'  = 'Large|Tower'
        '8'  = 'Laptop|Laptop'
        '9'  = 'Laptop|Laptop'
        '10' = 'Laptop|Laptop'
        '11' = 'Laptop|Handheld'
        '13' = 'All-in-one|All-in-one'
        '14' = 'Laptop|Laptop'
        '15' = 'Medium|SFF'
        '16' = 'Large|Tower'
        '17' = 'Rack server|Rack server'
        '23' = 'Rack server|Rack server'
        '24' = 'Small|USFF'
        '28' = 'Rack server|Blade server'
        '29' = 'Rack server|Blade enclosure'
        '30' = 'Laptop|Tablet'
        '31' = 'Laptop|Convertible'
        '32' = 'Laptop|Detachable'
        '35' = 'Small|Mini PC'
        '36' = 'Small|Stick PC'
    }
    if (-not $table.ContainsKey($code)) {
        return [pscustomobject]@{ Size = 'Other'; Name = 'Unknown' }
    }
    $parts = $table[$code] -split '\|', 2
    return [pscustomobject]@{ Size = $parts[0]; Name = $parts[1] }
}

function Get-RsModelChassisHint {
    param([string]$Model)

    if ([string]::IsNullOrWhiteSpace($Model)) {
        return $null
    }
    if ($Model -match '(?i)\b(NUC|USFF|Micro|Tiny|Elite\s*Mini|ProDesk\s*Mini|ThinkCentre\s*Tiny|OptiPlex\s*Micro|Mini\s*PC)\b') {
        return 'Small'
    }
    if ($Model -match '(?i)\b(SFF|Small\s*Form\s*Factor)\b') {
        return 'Medium'
    }
    if ($Model -match '(?i)\bTower\b') {
        return 'Large'
    }
    if ($Model -match '(?i)\b(Laptop|Notebook)\b') {
        return 'Laptop'
    }
    if ($Model -match '(?i)All[- ]in[- ]One') {
        return 'All-in-one'
    }
    if ($Model -match '(?i)\b(PowerEdge|ProLiant|ThinkSystem|ThinkServer)\b') {
        return 'Rack server'
    }
    return $null
}

function Get-RsFormFactor {
    param(
        $ChassisType,
        [string]$Model,
        $PcSystemType
    )

    $chosen = $null
    foreach ($entry in @($ChassisType)) {
        if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry)) {
            continue
        }
        $mapped = ConvertTo-RsChassisName -ChassisType $entry
        if ($mapped.Size -ne 'Other') {
            $chosen = $mapped
            break
        }
    }
    if ($null -eq $chosen) {
        $chosen = [pscustomobject]@{ Size = 'Other'; Name = 'Unknown' }
    }

    $size = [string]$chosen.Size
    $name = [string]$chosen.Name
    $fixed = @('Laptop', 'All-in-one', 'Rack server')
    $hint = Get-RsModelChassisHint -Model $Model
    if ($fixed -notcontains $size -and -not [string]::IsNullOrWhiteSpace($hint)) {
        $size = $hint
    }
    if ($size -eq 'Other' -and [string]$PcSystemType -eq '2') {
        $size = 'Laptop'
        $name = 'Laptop'
    }

    $detail = $name
    if (-not [string]::IsNullOrWhiteSpace($hint) -and $hint -eq $size -and $name -ne $size) {
        $detail = '{0}; model indicates {1}' -f $name, $hint
    }
    return [pscustomobject]@{
        Size   = $size
        Name   = $name
        Detail = $detail
    }
}

function ConvertTo-RsVideoOutput {
    param($Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return 'n/a'
    }
    $text = ([string]$Value).Trim()
    $map = @{
        '-2'         = 'n/a'
        '-1'         = 'Other'
        '0'          = 'VGA'
        '1'          = 'S-Video'
        '2'          = 'Composite'
        '3'          = 'Component'
        '4'          = 'DVI'
        '5'          = 'HDMI'
        '6'          = 'LVDS'
        '7'          = 'D-JPN'
        '8'          = 'SDI'
        '9'          = 'DisplayPort'
        '10'         = 'DisplayPort'
        '11'         = 'UDI'
        '12'         = 'UDI'
        '13'         = 'SDTV dongle'
        '14'         = 'Miracast'
        '15'         = 'Indirect wired'
        '16'         = 'Indirect virtual'
        '2147483648' = 'Internal'
        '4294967294' = 'n/a'
        '4294967295' = 'Other'
    }
    if ($map.ContainsKey($text)) {
        return [string]$map[$text]
    }
    if ($text -match '^(?i)HDMI|DisplayPort|VGA|DVI|USB-C|Thunderbolt|Internal|LVDS$') {
        return $text
    }
    return 'n/a'
}

function Format-RsPortTally {
    param([string[]]$Type)

    $counts = @{}
    $order = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($Type)) {
        $name = Format-RsText -Value $entry
        if ($name -eq 'n/a' -or $name -eq 'Uninitialized' -or $name -eq 'Other') {
            continue
        }
        if (-not $counts.ContainsKey($name)) {
            $counts[$name] = 0
            $order.Add($name)
        }
        $counts[$name] = [int]$counts[$name] + 1
    }
    if ($order.Count -eq 0) {
        return 'n/a'
    }
    $parts = @()
    foreach ($name in $order) {
        $parts += ('{0} x{1}' -f $name, $counts[$name])
    }
    return ($parts -join ', ')
}

function Get-RsOutputHint {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }
    $found = New-Object System.Collections.Generic.List[string]
    $patterns = @(
        @{ Pattern = '(?i)mini\s*DisplayPort'; Name = 'mini DisplayPort' }
        @{ Pattern = '(?i)DisplayPort'; Name = 'DisplayPort' }
        @{ Pattern = '(?i)HDMI'; Name = 'HDMI' }
        @{ Pattern = '(?i)USB-C|Thunderbolt'; Name = 'USB-C/Thunderbolt' }
        @{ Pattern = '(?i)\bVGA\b|\bHD15\b'; Name = 'VGA' }
        @{ Pattern = '(?i)\bDVI\b'; Name = 'DVI' }
    )
    foreach ($item in $patterns) {
        if ($Text -match $item.Pattern) {
            if (-not $found.Contains($item.Name)) {
                $found.Add($item.Name)
            }
        }
    }
    return @($found.ToArray())
}

function Get-RsGpuOutputEstimate {
    param([string]$Name)

    $empty = [pscustomobject]@{
        Estimated = $false
        Note      = 'n/a'
        Port      = @()
    }
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $empty
    }
    $table = @(
        @{ Pattern = '(?i)\bT400\b'; Port = @(@{ Type = 'mini DisplayPort'; Count = 3 }) }
        @{ Pattern = '(?i)\bT600\b'; Port = @(@{ Type = 'mini DisplayPort'; Count = 4 }) }
        @{ Pattern = '(?i)\bT1000\b'; Port = @(@{ Type = 'mini DisplayPort'; Count = 4 }) }
        @{ Pattern = '(?i)\bP620\b'; Port = @(@{ Type = 'mini DisplayPort'; Count = 4 }) }
        @{ Pattern = '(?i)\bP1000\b'; Port = @(@{ Type = 'mini DisplayPort'; Count = 4 }) }
        @{ Pattern = '(?i)\bP2000\b'; Port = @(@{ Type = 'DisplayPort'; Count = 4 }) }
        @{ Pattern = '(?i)\bA2000\b'; Port = @(@{ Type = 'mini DisplayPort'; Count = 4 }) }
        @{ Pattern = '(?i)\b(3060|3070|4060|4070)\b'; Port = @(@{ Type = 'HDMI'; Count = 1 }, @{ Type = 'DisplayPort'; Count = 3 }) }
    )
    foreach ($row in $table) {
        if ($Name -match $row.Pattern) {
            $ports = ConvertTo-RsList
            foreach ($port in @($row.Port)) {
                $ports.Add([pscustomobject]@{
                    Type  = [string]$port.Type
                    Count = [int]$port.Count
                })
            }
            return [pscustomobject]@{
                Estimated = $true
                Note      = 'estimated from GPU model; reference layout, board partners vary'
                Port      = $ports
            }
        }
    }
    return $empty
}

function Format-RsEstimatedPort {
    param($Estimate)

    if ($null -eq $Estimate -or -not [bool]$Estimate.Estimated) {
        return 'n/a'
    }
    $parts = @()
    foreach ($port in $Estimate.Port) {
        $parts += ('{0} x{1}' -f $port.Type, $port.Count)
    }
    if ($parts.Count -eq 0) {
        return 'n/a'
    }
    return ($parts -join ', ')
}

function ConvertTo-RsMonitorVendor {
    param([string]$Code)

    $text = ([string]$Code).Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return 'n/a'
    }
    $map = @{
        'DEL' = 'Dell'
        'SAM' = 'Samsung'
        'SEC' = 'Samsung'
        'GSM' = 'LG'
        'HWP' = 'HP'
        'HPN' = 'HP'
        'LEN' = 'Lenovo'
        'AUS' = 'ASUS'
        'ACR' = 'Acer'
        'VSC' = 'ViewSonic'
        'PHL' = 'Philips'
        'BNQ' = 'BenQ'
        'ENC' = 'EIZO'
        'MEI' = 'Panasonic'
        'IVM' = 'Iiyama'
        'MST' = 'MSI'
        'AOC' = 'AOC'
    }
    if ($map.ContainsKey($text)) {
        return [string]$map[$text]
    }
    return $text
}

function Get-RsPanelInch {
    param(
        $WidthCm,
        $HeightCm
    )

    $width = 0.0
    $height = 0.0
    $style = [System.Globalization.NumberStyles]::Float
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if (-not [double]::TryParse([string]$WidthCm, $style, $culture, [ref]$width)) {
        return $null
    }
    if (-not [double]::TryParse([string]$HeightCm, $style, $culture, [ref]$height)) {
        return $null
    }
    if ($width -le 0 -or $height -le 0) {
        return $null
    }
    $cm = [math]::Sqrt(($width * $width) + ($height * $height))
    return [math]::Round($cm / 2.54, 1)
}

function Get-RsEdidResolution {
    param([byte[]]$Block)

    if ($null -eq $Block -or $Block.Length -lt 126) {
        return $null
    }
    for ($index = 0; $index -lt 4; $index++) {
        $offset = 54 + ($index * 18)
        if ($Block[$offset] -eq 0 -and $Block[$offset + 1] -eq 0) {
            continue
        }
        $horizontal = [int]$Block[$offset + 2] + ((([int]$Block[$offset + 4] -band 0xF0) -shl 4))
        $vertical = [int]$Block[$offset + 5] + ((([int]$Block[$offset + 7] -band 0xF0) -shl 4))
        if ($horizontal -ge 640 -and $vertical -ge 480) {
            return ('{0}x{1}' -f $horizontal, $vertical)
        }
    }
    return $null
}

function ConvertTo-RsAsciiWord {
    param($Value)

    if ($null -eq $Value) {
        return ''
    }
    $chars = New-Object System.Collections.Generic.List[char]
    foreach ($code in @($Value)) {
        $number = 0
        if (-not [int]::TryParse([string]$code, [ref]$number)) {
            continue
        }
        if ($number -eq 0) {
            break
        }
        if ($number -ge 32 -and $number -le 126) {
            $chars.Add([char]$number)
        }
    }
    # WmiMonitorID stores a blank name as a UInt16 array of zeros, not $null.
    # Windows PowerShell 5.1 returns $null from -join of an empty collection,
    # and calling Trim() on that null aborts the survey.
    if ($chars.Count -eq 0) {
        return ''
    }
    $text = -join @($chars.ToArray())
    if ([string]::IsNullOrEmpty($text)) {
        return ''
    }
    return $text.Trim()
}

function Get-RsMonitorKey {
    param([string]$InstanceName)

    $found = [regex]::Match([string]$InstanceName, '(?i)^(DISPLAY\\[^\\]+\\[^_]+)')
    if ($found.Success) {
        return $found.Groups[1].Value.ToUpperInvariant()
    }
    return ([string]$InstanceName).ToUpperInvariant()
}

function Test-RsDedicatedGpu {
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

function Get-RsQwMemorySize {
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

function ConvertTo-RsMemoryType {
    param($Value)

    $code = ([string]$Value).Trim()
    $map = @{
        '20' = 'DDR'
        '21' = 'DDR2'
        '22' = 'DDR2 FB-DIMM'
        '24' = 'DDR3'
        '26' = 'DDR4'
        '34' = 'DDR5'
    }
    if ($map.ContainsKey($code)) {
        return [string]$map[$code]
    }
    if ($code -match '(?i)^DDR[0-9]?') {
        return $code
    }
    return 'n/a'
}

function ConvertTo-RsMaxRamGb {
    param($Kilobyte)

    $number = 0.0
    $style = [System.Globalization.NumberStyles]::Float
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if (-not [double]::TryParse([string]$Kilobyte, $style, $culture, [ref]$number)) {
        return $null
    }
    if ($number -le 0) {
        return $null
    }
    $bytes = $number * 1024
    return [math]::Round($bytes / 1073741824, 1)
}

function Get-RsMediaKind {
    param(
        $MediaType,
        $BusType,
        [string]$Model
    )

    $media = ([string]$MediaType).Trim()
    $bus = ([string]$BusType).Trim()
    if ($bus -eq '17' -or $bus -eq 'NVMe' -or $Model -match '(?i)NVMe') {
        return 'NVMe'
    }
    if ($media -eq '4' -or $media -eq 'SSD' -or $media -match '(?i)\bSSD\b') {
        return 'SSD'
    }
    if ($media -eq '3' -or $media -eq 'HDD' -or $media -match '(?i)\bHDD\b') {
        return 'HDD'
    }
    return 'Unspecified'
}

function Get-RsDiskIndex {
    param([string]$Text)

    $found = [regex]::Match([string]$Text, 'Disk #(\d+)|PHYSICALDRIVE(\d+)')
    if (-not $found.Success) {
        return $null
    }
    if ($found.Groups[1].Success) {
        return [int]$found.Groups[1].Value
    }
    return [int]$found.Groups[2].Value
}

function ConvertTo-RsLinkSpeed {
    param($BitsPerSecond)

    $bits = [uint64]0
    if (-not [uint64]::TryParse([string]$BitsPerSecond, [ref]$bits) -or $bits -eq 0) {
        return 'n/a'
    }
    if ($bits -eq 10000000000) { return '10 Gbps' }
    if ($bits -eq 5000000000) { return '5 Gbps' }
    if ($bits -eq 2500000000) { return '2.5 Gbps' }
    if ($bits -eq 1000000000) { return '1 Gbps' }
    if ($bits -eq 100000000) { return '100 Mbps' }
    if ($bits -eq 10000000) { return '10 Mbps' }
    if ($bits -ge 1000000000) {
        $gbps = [math]::Round($bits / 1000000000, 1)
        return ($gbps.ToString([System.Globalization.CultureInfo]::InvariantCulture) + ' Gbps')
    }
    $mbps = [math]::Round($bits / 1000000, 0)
    return ($mbps.ToString([System.Globalization.CultureInfo]::InvariantCulture) + ' Mbps')
}

function ConvertTo-RsWifiStandard {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return 'n/a'
    }
    if ($Name -match '(?i)Wi-?Fi\s*7|\b802\.11be\b|\bBE\d{3}\b') { return 'Wi-Fi 7' }
    if ($Name -match '(?i)Wi-?Fi\s*6E|\b6E\b') { return 'Wi-Fi 6E' }
    if ($Name -match '(?i)Wi-?Fi\s*6|\b802\.11ax\b|\bAX\d{3}\b') { return 'Wi-Fi 6' }
    if ($Name -match '(?i)Wi-?Fi\s*5|\b802\.11ac\b|\bAC\d{3}\b') { return 'Wi-Fi 5' }
    if ($Name -match '(?i)\b802\.11n\b') { return 'Wi-Fi 4' }
    return 'n/a'
}

function Test-RsVirtualAdapter {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $true
    }
    return [bool]($Name -match '(?i)Virtual|Hyper-V|VMware|VirtualBox|VPN|WAN Miniport|Teredo|isatap|Loopback|Pseudo|Npcap|Kernel Debug|Bluetooth Device \(Personal')
}

function Test-RsEthernetAdapter {
    param(
        [string]$Name,
        [string]$AdapterType
    )

    if (Test-RsVirtualAdapter -Name $Name) {
        return $false
    }
    if ($Name -match '(?i)Wi-?Fi|Wireless|802\.11|Bluetooth') {
        return $false
    }
    if ($Name -match '(?i)Ethernet' -or $AdapterType -match '(?i)Ethernet') {
        return $true
    }
    return $false
}

function Test-RsWifiAdapter {
    param([string]$Name)

    if (Test-RsVirtualAdapter -Name $Name) {
        return $false
    }
    return [bool]($Name -match '(?i)Wi-?Fi|Wireless|802\.11|WLAN')
}

function ConvertTo-RsUsbGeneration {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return 'n/a'
    }
    if ($Name -match '(?i)USB\s*4|USB4') { return 'USB4' }
    if ($Name -match '(?i)USB-C|USB\s*C|Type-C') { return 'USB-C' }
    if ($Name -match '(?i)USB\s*3|xHCI|XHCI|SuperSpeed') { return 'USB 3.x' }
    if ($Name -match '(?i)USB\s*2|EHCI') { return 'USB 2.0' }
    if ($Name -match '(?i)USB\s*1|UHCI|OHCI') { return 'USB 1.1' }
    if ($Name -match '(?i)\bUSB\b') { return 'USB' }
    return 'n/a'
}

function Test-RsUsbLeaf {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }
    if ($Name -match '(?i)Root Hub|Host Controller|USB Hub') {
        return $false
    }
    return $true
}

function Test-RsComDevice {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }
    if ($Name -match '(?i)^COM\d+$') {
        return $true
    }
    return [bool]($Name -match '(?i)USB[ -]?Serial|Prolific|FTDI|CH34[01]|Serial Adapter')
}

function Get-RsPrinterKind {
    param(
        [string]$PortName,
        $Network
    )

    if ($Network -eq $true) {
        return 'network'
    }
    if ($PortName -match '(?i)^(IP_|WSD|\\\\)|TCP|http') {
        return 'network'
    }
    return 'local'
}

function Test-RsIgnoredPrinter {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $true
    }
    return [bool]($Name -match '(?i)Microsoft Print to PDF|Microsoft XPS|OneNote|Fax|^Send To')
}

function Get-RsBatteryHealthPercent {
    param(
        $Design,
        $Full
    )

    $design = 0.0
    $full = 0.0
    $style = [System.Globalization.NumberStyles]::Float
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if (-not [double]::TryParse([string]$Design, $style, $culture, [ref]$design)) {
        return $null
    }
    if (-not [double]::TryParse([string]$Full, $style, $culture, [ref]$full)) {
        return $null
    }
    if ($design -le 0 -or $full -le 0) {
        return $null
    }
    return [int][math]::Round((100.0 * $full) / $design, 0)
}

function ConvertTo-RsWeekDate {
    param(
        [int]$Year,
        [int]$Week
    )

    if ($Week -lt 1 -or $Week -gt 53) {
        return $null
    }
    if ($Year -lt 1995 -or $Year -gt 2100) {
        return $null
    }
    return (Get-Date -Year $Year -Month 1 -Day 1).Date.AddDays(($Week - 1) * 7)
}

function Resolve-RsCodedDate {
    param(
        [string]$Code,
        [int]$Week,
        [datetime]$Now
    )

    $years = @()
    if ($Code -match '^[0-9]$') {
        $digit = [int]$Code
        $years += 2010 + $digit
        $years += 2020 + $digit
    } else {
        $letters = @{
            'A' = 2020; 'B' = 2021; 'C' = 2022; 'D' = 2023
            'E' = 2024; 'F' = 2025; 'G' = 2026; 'H' = 2027
        }
        if ($letters.ContainsKey($Code)) {
            $years += [int]$letters[$Code]
        }
    }
    $best = $null
    foreach ($year in $years) {
        $date = ConvertTo-RsWeekDate -Year $year -Week $Week
        if ($null -eq $date) {
            continue
        }
        if ($date -gt $Now.Date.AddDays(14)) {
            continue
        }
        if ($null -eq $best -or $date -gt $best) {
            $best = $date
        }
    }
    return $best
}

function Get-RsHpSerialDate {
    param(
        [string]$Serial,
        [datetime]$Now
    )

    $text = ([string]$Serial).Trim().ToUpperInvariant()
    if ($text.Length -lt 10 -or $text.Length -gt 12) {
        return $null
    }
    if ($text -notmatch '^[A-Z0-9]+$') {
        return $null
    }
    $week = 0
    if (-not [int]::TryParse($text.Substring(4, 2), [ref]$week)) {
        return $null
    }
    $date = Resolve-RsCodedDate -Code $text.Substring(3, 1) -Week $week -Now $Now
    if ($null -eq $date) {
        return $null
    }
    return [pscustomobject]@{
        Date = $date.ToString('yyyy-MM-dd')
        Week = $week
    }
}

function Get-RsDellPpidDate {
    param(
        [string]$Serial,
        [datetime]$Now
    )

    $text = ([string]$Serial).Trim().ToUpperInvariant()
    if ($text.Length -ne 23) {
        return $null
    }
    if ($text -notmatch '^[A-Z0-9]+$') {
        return $null
    }
    $week = 0
    if (-not [int]::TryParse($text.Substring(13, 2), [ref]$week)) {
        return $null
    }
    $date = Resolve-RsCodedDate -Code $text.Substring(12, 1) -Week $week -Now $Now
    if ($null -eq $date) {
        return $null
    }
    return [pscustomobject]@{
        Date = $date.ToString('yyyy-MM-dd')
        Week = $week
    }
}

function ConvertTo-RsBiosDate {
    param(
        $Value,
        [datetime]$Now
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    try {
        $date = [datetime]$Value
    } catch {
        return $null
    }
    if ($date.Year -lt 1995 -or $date -gt $Now.AddYears(2)) {
        return $null
    }
    return $date.ToString('yyyy-MM-dd')
}

function Get-RsShipDateEstimate {
    param(
        [string]$Manufacturer,
        [string]$Serial,
        $BiosReleaseDate,
        [datetime]$Now
    )

    $lines = @()
    if ($Manufacturer -match '(?i)Hewlett-Packard|\bHP\b|HPE') {
        $hp = Get-RsHpSerialDate -Serial $Serial -Now $Now
        if ($null -ne $hp) {
            $lines += ('estimated from HP serial {0} (week {1})' -f $hp.Date, $hp.Week)
        }
    }
    if ($Manufacturer -match '(?i)\bDell\b') {
        $dell = Get-RsDellPpidDate -Serial $Serial -Now $Now
        if ($null -ne $dell) {
            $lines += ('estimated from Dell PPID {0} (week {1})' -f $dell.Date, $dell.Week)
        }
    }
    $bios = ConvertTo-RsBiosDate -Value $BiosReleaseDate -Now $Now
    if (-not [string]::IsNullOrWhiteSpace($bios)) {
        $lines += ('estimated from SMBIOS BIOS release date {0}' -f $bios)
    }
    if ($lines.Count -eq 0) {
        return 'n/a'
    }
    return ($lines -join '; ')
}

function Get-RsSoftwareCatalog {
    return @(
        [pscustomobject]@{ Label = 'Dentrix'; Pattern = '(?i)\bDentrix\b' }
        [pscustomobject]@{ Label = 'Eaglesoft'; Pattern = '(?i)\bEaglesoft\b' }
        [pscustomobject]@{ Label = 'SoftDent'; Pattern = '(?i)\bSoftDent\b' }
        [pscustomobject]@{ Label = 'Open Dental'; Pattern = '(?i)Open\s*Dental' }
        [pscustomobject]@{ Label = 'CareStack'; Pattern = '(?i)\bCareStack\b' }
        [pscustomobject]@{ Label = 'VixWin'; Pattern = '(?i)Vix\s*Win' }
        [pscustomobject]@{ Label = 'Carestream'; Pattern = '(?i)Carestream|CS\s+Imaging|CS\s+3D' }
        [pscustomobject]@{ Label = 'Clever One'; Pattern = '(?i)Clever\s*One' }
        [pscustomobject]@{ Label = 'Ez3D-i'; Pattern = '(?i)Ez3D-?\s*i' }
        [pscustomobject]@{ Label = 'EzDent'; Pattern = '(?i)EzDent' }
        [pscustomobject]@{ Label = 'EzServer'; Pattern = '(?i)\bEzServer\b' }
        [pscustomobject]@{ Label = 'Sidexis'; Pattern = '(?i)\bSidexis\b' }
        [pscustomobject]@{ Label = 'Schick'; Pattern = '(?i)\bSchick\b' }
        [pscustomobject]@{ Label = 'Romexis'; Pattern = '(?i)\bRomexis\b' }
        [pscustomobject]@{ Label = 'XrayVision'; Pattern = '(?i)X-?ray\s*Vision' }
        [pscustomobject]@{ Label = 'Apteryx'; Pattern = '(?i)\bApteryx\b' }
        [pscustomobject]@{ Label = 'Planmeca'; Pattern = '(?i)\bPlanmeca\b' }
        [pscustomobject]@{ Label = 'DEXIS'; Pattern = '(?i)\bDEXIS\b|\bDexis\b' }
    )
}

function Find-RsInstalledApp {
    param($Entry)

    $catalog = @(Get-RsSoftwareCatalog)
    $found = ConvertTo-RsList
    $seen = @{}
    foreach ($item in @($Entry)) {
        $display = [string](Get-RsProperty -Object $item -Name 'DisplayName')
        if ([string]::IsNullOrWhiteSpace($display)) {
            continue
        }
        foreach ($product in $catalog) {
            if ($display -match $product.Pattern) {
                $version = Format-RsText -Value (Get-RsProperty -Object $item -Name 'DisplayVersion')
                $key = '{0}|{1}' -f $product.Label, $display.ToUpperInvariant()
                if ($seen.ContainsKey($key)) {
                    break
                }
                $seen[$key] = $true
                $found.Add([pscustomobject]@{
                    Label   = [string]$product.Label
                    Name    = $display.Trim()
                    Version = $version
                })
                break
            }
        }
    }
    Write-Output -NoEnumerate -InputObject $found
}

function Test-RsImagingLabel {
    param([string]$Label)

    $imaging = @(
        'Clever One', 'EzDent', 'Ez3D-i', 'EzServer', 'Carestream', 'Sidexis',
        'Romexis', 'DEXIS', 'Schick', 'Planmeca', 'Apteryx', 'XrayVision', 'VixWin'
    )
    return $imaging -contains $Label
}

function Get-RsIntelGeneration {
    param([string]$Name)

    if ($Name -match '(?i)Core\(TM\)\s+Ultra|Core\s+Ultra') {
        return [pscustomobject]@{ Known = $true; Supported = $true; Detail = 'Intel Core Ultra' }
    }
    $modelMatch = [regex]::Match([string]$Name, '(?i)Core(?:\(TM\))?\s+i[3579]-(\d{4,5})')
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
    return [pscustomobject]@{
        Known     = $true
        Supported = ($generation -ge 8)
        Detail    = "Intel Core generation $generation"
    }
}

function Test-RsCpuSupport {
    param(
        [string]$Name,
        [int]$Core,
        [int]$AddressWidth,
        [int]$MaxClockMHz
    )

    if ($AddressWidth -gt 0 -and $AddressWidth -lt 64) {
        return [pscustomobject]@{ Status = 'Fail'; Detail = 'CPU is not 64-bit' }
    }
    if ($Core -gt 0 -and $Core -lt 2) {
        return [pscustomobject]@{ Status = 'Fail'; Detail = 'Fewer than 2 cores' }
    }
    if ($MaxClockMHz -gt 0 -and $MaxClockMHz -lt 1000) {
        return [pscustomobject]@{ Status = 'Fail'; Detail = "CPU reports $MaxClockMHz MHz, below the 1 GHz minimum" }
    }
    if ($Name -match '(?i)Intel') {
        $intel = Get-RsIntelGeneration -Name $Name
        if ($intel.Known -and $intel.Supported) {
            return [pscustomobject]@{ Status = 'Pass'; Detail = $intel.Detail }
        }
        if ($intel.Known) {
            return [pscustomobject]@{ Status = 'Fail'; Detail = "$($intel.Detail) is below Windows 11 (8th generation or newer)" }
        }
        if ($Name -match '(?i)Pentium|Celeron|Atom') {
            return [pscustomobject]@{ Status = 'Fail'; Detail = 'Pentium, Celeron, and Atom are treated as not Windows 11 capable by this heuristic' }
        }
        if ($Name -match '(?i)Xeon') {
            return [pscustomobject]@{ Status = 'Review'; Detail = 'Xeon support is model-specific' }
        }
        return [pscustomobject]@{ Status = 'Review'; Detail = 'Unrecognized Intel CPU' }
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
        }
        return [pscustomobject]@{ Status = 'Review'; Detail = 'Confirm this AMD CPU on the Microsoft Windows 11 list' }
    }
    return [pscustomobject]@{ Status = 'Review'; Detail = 'Unrecognized CPU' }
}

function Test-RsServer {
    param(
        [string]$Caption,
        [int]$ProductType
    )

    if ($ProductType -eq 2 -or $ProductType -eq 3) {
        return $true
    }
    return [bool]($Caption -match 'Windows Server')
}

function Test-RsWindows11 {
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

function Get-RsReadinessLine {
    param(
        [bool]$IsServer,
        [bool]$IsWindows11,
        [string[]]$Gap
    )

    if ($IsServer) {
        return 'Not applicable. Windows Server is not a Windows 11 upgrade target.'
    }
    $problems = @()
    foreach ($entry in @($Gap)) {
        if (-not [string]::IsNullOrWhiteSpace($entry)) {
            $problems += $entry
        }
    }
    if ($IsWindows11) {
        if ($problems.Count -eq 0) {
            return 'Already Windows 11. Readiness checks passed.'
        }
        return ('Already Windows 11. Informational gaps: {0}.' -f ($problems -join ', '))
    }
    if ($problems.Count -eq 0) {
        return 'Ready for Windows 11 by this summary.'
    }
    return ('Not ready for Windows 11: {0}.' -f ($problems -join ', '))
}

function Get-RsReplacementNote {
    param(
        [string[]]$VideoOutput,
        [int]$ExternalMonitor = 0,
        [bool]$VgaConnected = $false,
        [bool]$ComPort = $false,
        [bool]$Wifi = $false,
        [bool]$DedicatedGpu = $false,
        [bool]$ImagingSoftware = $false,
        [string]$FormFactor = '',
        [bool]$Bluetooth = $false,
        [bool]$Thunderbolt = $false,
        [int]$BatteryHealth = -1
    )

    $notes = New-Object System.Collections.Generic.List[string]
    $sawVga = $VgaConnected
    foreach ($output in @($VideoOutput)) {
        if ($output -eq 'VGA') {
            $sawVga = $true
        }
    }
    if ($sawVga) {
        $notes.Add('Needs VGA output')
    }
    if ($ExternalMonitor -ge 1) {
        $notes.Add(('Uses {0} monitors' -f $ExternalMonitor))
    }
    if ($ComPort) {
        $notes.Add('Needs COM port')
    }
    if ($Wifi) {
        $notes.Add('Needs WiFi')
    }
    if ($DedicatedGpu -and $ImagingSoftware) {
        $notes.Add('Dedicated GPU required (CBCT)')
    } elseif ($DedicatedGpu) {
        $notes.Add('Dedicated GPU present')
    } elseif ($ImagingSoftware) {
        $notes.Add('Imaging software present; confirm dedicated GPU before ordering')
    }
    if ($FormFactor -eq 'Small') {
        $notes.Add('Small chassis')
    } elseif ($FormFactor -eq 'Laptop') {
        $notes.Add('Laptop')
    } elseif ($FormFactor -eq 'Rack server') {
        $notes.Add('Rack server')
    }
    if ($Bluetooth) {
        $notes.Add('Needs Bluetooth')
    }
    if ($Thunderbolt) {
        $notes.Add('Has USB4 or Thunderbolt')
    }
    if ($BatteryHealth -ge 0 -and $BatteryHealth -lt 70) {
        $notes.Add('Battery health is under 70 percent')
    }
    if ($notes.Count -eq 0) {
        $notes.Add('No special replacement flags')
    }
    return @($notes.ToArray())
}

function Resolve-RsSurveyFile {
    param(
        [string]$OutputPath,
        [string]$ComputerName,
        [datetime]$Now,
        [string]$ProgramDataRoot
    )

    $safeName = ([string]$ComputerName).Trim()
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        $safeName = 'UNKNOWN'
    }
    $safeName = [regex]::Replace($safeName, '[^A-Za-z0-9._-]', '_')
    $baseName = '{0}_{1}' -f $safeName, $Now.ToString('yyyyMMdd')

    $root = $ProgramDataRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = [string]$env:ProgramData
    }
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = 'C:\ProgramData'
    }
    $root = $root.TrimEnd('\', '/')
    $defaultDirectory = $root + '\StandardComputer\Survey'

    $directory = $defaultDirectory
    $base = $baseName
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $text = $OutputPath.Trim() -replace '/', '\'
        $isDirectory = $text.EndsWith('\')
        $text = $text.TrimEnd('\')
        $leaf = $text
        $parent = ''
        $slash = $text.LastIndexOf('\')
        if ($slash -ge 0) {
            $parent = $text.Substring(0, $slash)
            $leaf = $text.Substring($slash + 1)
        }
        $extension = ''
        $dot = $leaf.LastIndexOf('.')
        if ($dot -gt 0) {
            $extension = $leaf.Substring($dot)
        }
        if ($isDirectory -or [string]::IsNullOrWhiteSpace($extension)) {
            $directory = $text
        } else {
            $directory = $parent
            if ([string]::IsNullOrWhiteSpace($directory)) {
                $directory = '.'
            }
            $base = $leaf.Substring(0, $leaf.Length - $extension.Length)
            if ([string]::IsNullOrWhiteSpace($base)) {
                $base = $baseName
            }
        }
    }

    return [pscustomobject]@{
        Directory = $directory
        JsonPath  = ($directory.TrimEnd('\') + '\' + $base + '.json')
        TextPath  = ($directory.TrimEnd('\') + '\' + $base + '.txt')
    }
}

function Format-RsJsonString {
    param([string]$Text)

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    if ($null -ne $Text) {
        foreach ($char in $Text.ToCharArray()) {
            $code = [int]$char
            if ($code -eq 8) {
                [void]$builder.Append('\b')
            } elseif ($code -eq 9) {
                [void]$builder.Append('\t')
            } elseif ($code -eq 10) {
                [void]$builder.Append('\n')
            } elseif ($code -eq 12) {
                [void]$builder.Append('\f')
            } elseif ($code -eq 13) {
                [void]$builder.Append('\r')
            } elseif ($code -eq 34) {
                [void]$builder.Append('\"')
            } elseif ($code -eq 92) {
                [void]$builder.Append('\\')
            } elseif ($code -lt 32) {
                [void]$builder.Append(('\u{0:x4}' -f $code))
            } else {
                [void]$builder.Append($char)
            }
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Write-RsJsonValue {
    param(
        [System.Text.StringBuilder]$Builder,
        $Value
    )

    if ($null -eq $Value) {
        [void]$Builder.Append('null')
        return
    }
    $candidate = $Value
    if ($Value -is [System.Management.Automation.PSObject]) {
        $inner = $Value.PSObject.BaseObject
        if ($inner -is [System.Collections.IList] -or $inner -is [System.Collections.IDictionary]) {
            $candidate = $inner
        }
    }
    if ($candidate -is [string]) {
        [void]$Builder.Append((Format-RsJsonString -Text $candidate))
        return
    }
    if ($candidate -is [bool]) {
        if ($candidate) {
            [void]$Builder.Append('true')
        } else {
            [void]$Builder.Append('false')
        }
        return
    }
    if ($candidate -is [datetime]) {
        [void]$Builder.Append((Format-RsJsonString -Text $candidate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')))
        return
    }
    if ($candidate -is [byte] -or $candidate -is [int16] -or $candidate -is [int32] -or $candidate -is [int64] -or $candidate -is [uint16] -or $candidate -is [uint32] -or $candidate -is [uint64] -or $candidate -is [decimal] -or $candidate -is [single] -or $candidate -is [double]) {
        $double = [double]$candidate
        if ([double]::IsNaN($double) -or [double]::IsInfinity($double)) {
            [void]$Builder.Append('null')
            return
        }
        [void]$Builder.Append(([System.Convert]::ToString($candidate, [System.Globalization.CultureInfo]::InvariantCulture)))
        return
    }
    $dictionary = $candidate -as [System.Collections.IDictionary]
    if ($null -ne $dictionary -and -not ($candidate -is [string])) {
        [void]$Builder.Append('{')
        $index = 0
        foreach ($key in @($dictionary.Keys)) {
            if ($index -gt 0) {
                [void]$Builder.Append(',')
            }
            [void]$Builder.Append((Format-RsJsonString -Text ([string]$key)))
            [void]$Builder.Append(':')
            Write-RsJsonValue -Builder $Builder -Value $dictionary[$key]
            $index++
        }
        [void]$Builder.Append('}')
        return
    }
    $list = $candidate -as [System.Collections.IList]
    if ($null -ne $list -and -not ($candidate -is [string])) {
        [void]$Builder.Append('[')
        for ($index = 0; $index -lt $list.Count; $index++) {
            if ($index -gt 0) {
                [void]$Builder.Append(',')
            }
            Write-RsJsonValue -Builder $Builder -Value $list[$index]
        }
        [void]$Builder.Append(']')
        return
    }
    if ($Value -is [pscustomobject]) {
        $properties = @($Value.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' })
        [void]$Builder.Append('{')
        $index = 0
        foreach ($property in $properties) {
            if ($index -gt 0) {
                [void]$Builder.Append(',')
            }
            [void]$Builder.Append((Format-RsJsonString -Text ([string]$property.Name)))
            [void]$Builder.Append(':')
            Write-RsJsonValue -Builder $Builder -Value $property.Value
            $index++
        }
        [void]$Builder.Append('}')
        return
    }
    [void]$Builder.Append((Format-RsJsonString -Text ([string]$Value)))
}

function ConvertTo-RsJson {
    param($Value)

    $builder = New-Object System.Text.StringBuilder
    Write-RsJsonValue -Builder $builder -Value $Value
    return $builder.ToString()
}

function Format-RsSummary {
    param($Survey)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Replacement survey')
    $lines.Add(('Computer: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $Survey -Name 'computer'))))
    $lines.Add(('Time: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $Survey -Name 'time'))))
    $lines.Add(('Saved text: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $Survey -Name 'savedText'))))
    $lines.Add(('Saved JSON: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $Survey -Name 'savedJson'))))
    $lines.Add('')

    $identity = Get-RsProperty -Object $Survey -Name 'identity'
    $lines.Add('Identity')
    $lines.Add(('  Manufacturer: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $identity -Name 'manufacturer'))))
    $lines.Add(('  Model: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $identity -Name 'model'))))
    $lines.Add(('  Serial / service tag: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $identity -Name 'serial'))))
    $lines.Add(('  SKU: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $identity -Name 'sku'))))
    $lines.Add(('  BIOS: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $identity -Name 'biosVersion'))))
    $lines.Add(('  BIOS date: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $identity -Name 'biosDate'))))
    $lines.Add(('  SMBIOS: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $identity -Name 'smbiosVersion'))))
    $lines.Add(('  Ship date: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $identity -Name 'shipDate'))))
    $lines.Add('')

    $form = Get-RsProperty -Object $Survey -Name 'formFactor'
    $lines.Add('Form factor')
    $lines.Add(('  {0} ({1})' -f (Format-RsText -Value (Get-RsProperty -Object $form -Name 'size')), (Format-RsText -Value (Get-RsProperty -Object $form -Name 'detail'))))
    $lines.Add('')

    $display = Get-RsProperty -Object $Survey -Name 'display'
    $lines.Add('Display outputs')
    $lines.Add(('  Reported connections: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $display -Name 'reported'))))
    $source = Format-RsText -Value (Get-RsProperty -Object $display -Name 'source')
    if ($source -ne 'n/a') {
        $lines.Add(('  Reported source: {0}' -f $source))
    }
    $gpuSeen = $false
    foreach ($gpu in @(Get-RsProperty -Object $display -Name 'gpu')) {
        $gpuSeen = $true
        $lines.Add(('  {0} ({1}) VRAM {2} via {3}' -f (Format-RsText -Value $gpu.name), (Format-RsText -Value $gpu.kind), (Format-RsText -Value $gpu.vram), (Format-RsText -Value $gpu.vramSource)))
        $lines.Add(('    Estimated ports: {0}' -f (Format-RsText -Value $gpu.estimated)))
        $estimateNote = Format-RsText -Value $gpu.estimateNote
        if ($estimateNote -ne 'n/a') {
            $lines.Add(('    Estimate note: {0}' -f $estimateNote))
        }
    }
    if (-not $gpuSeen) {
        $lines.Add('  GPU: n/a')
    }
    $lines.Add('')

    $monitor = Get-RsProperty -Object $Survey -Name 'monitor'
    $lines.Add('Monitors')
    $lines.Add(('  Count: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $monitor -Name 'count'))))
    $lines.Add(('  External: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $monitor -Name 'external'))))
    $monitorSeen = $false
    foreach ($item in @(Get-RsProperty -Object $monitor -Name 'item')) {
        $monitorSeen = $true
        $lines.Add(('  - {0} {1} serial {2} size {3} in connection {4} resolution {5}' -f (Format-RsText -Value $item.make), (Format-RsText -Value $item.model), (Format-RsText -Value $item.serial), (Format-RsText -Value $item.sizeInch), (Format-RsText -Value $item.connection), (Format-RsText -Value $item.resolution)))
    }
    if (-not $monitorSeen) {
        $lines.Add('  none')
    }
    $lines.Add('')

    $cpu = Get-RsProperty -Object $Survey -Name 'cpu'
    $lines.Add('CPU')
    $cpuSeen = $false
    foreach ($item in @($cpu)) {
        $cpuSeen = $true
        $lines.Add(('  {0} | {1} cores | {2} logical | {3} MHz | {4}' -f (Format-RsText -Value $item.name), (Format-RsText -Value $item.core), (Format-RsText -Value $item.logical), (Format-RsText -Value $item.mhz), (Format-RsText -Value $item.readiness)))
    }
    if (-not $cpuSeen) {
        $lines.Add('  n/a')
    }
    $lines.Add('')

    $memory = Get-RsProperty -Object $Survey -Name 'memory'
    $lines.Add('Memory')
    $lines.Add(('  Total GB: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $memory -Name 'total'))))
    $lines.Add(('  Slots: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $memory -Name 'slots'))))
    $lines.Add(('  Max supported GB: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $memory -Name 'max'))))
    $dimmSeen = $false
    foreach ($dimm in @(Get-RsProperty -Object $memory -Name 'dimm')) {
        $dimmSeen = $true
        $lines.Add(('  - {0}: {1} GB {2} {3} MHz' -f (Format-RsText -Value $dimm.locator), (Format-RsText -Value $dimm.size), (Format-RsText -Value $dimm.type), (Format-RsText -Value $dimm.speed)))
    }
    if (-not $dimmSeen) {
        $lines.Add('  DIMMs: n/a')
    }
    $lines.Add('')

    $storage = Get-RsProperty -Object $Survey -Name 'storage'
    $lines.Add('Storage')
    $diskSeen = $false
    foreach ($disk in @(Get-RsProperty -Object $storage -Name 'disk')) {
        $diskSeen = $true
        $lines.Add(('  Disk {0}: {1} | {2} GB | {3} | {4} | free {5} GB | serial {6}' -f (Format-RsText -Value $disk.index), (Format-RsText -Value $disk.model), (Format-RsText -Value $disk.size), (Format-RsText -Value $disk.media), (Format-RsText -Value $disk.health), (Format-RsText -Value $disk.free), (Format-RsText -Value $disk.serial)))
    }
    if (-not $diskSeen) {
        $lines.Add('  Disks: n/a')
    }
    foreach ($volume in @(Get-RsProperty -Object $storage -Name 'volume')) {
        $lines.Add(('  Volume {0}: {1} GB size, {2} GB free' -f (Format-RsText -Value $volume.letter), (Format-RsText -Value $volume.size), (Format-RsText -Value $volume.free)))
    }
    $lines.Add('')

    $network = Get-RsProperty -Object $Survey -Name 'network'
    $lines.Add('Network')
    $ethernetSeen = $false
    foreach ($adapter in @(Get-RsProperty -Object $network -Name 'ethernet')) {
        $ethernetSeen = $true
        $lines.Add(('  Ethernet: {0} | {1} | MAC {2} | IP {3}' -f (Format-RsText -Value $adapter.name), (Format-RsText -Value $adapter.speed), (Format-RsText -Value $adapter.mac), (Format-RsText -Value $adapter.ip)))
    }
    if (-not $ethernetSeen) {
        $lines.Add('  Ethernet: none')
    }
    $wifiSeen = $false
    foreach ($adapter in @(Get-RsProperty -Object $network -Name 'wifi')) {
        $wifiSeen = $true
        $lines.Add(('  WiFi: {0} | {1} | MAC {2} | IP {3}' -f (Format-RsText -Value $adapter.name), (Format-RsText -Value $adapter.standard), (Format-RsText -Value $adapter.mac), (Format-RsText -Value $adapter.ip)))
    }
    if (-not $wifiSeen) {
        $lines.Add('  WiFi: none')
    }
    $lines.Add(('  Bluetooth: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $network -Name 'bluetooth'))))
    $lines.Add('')

    $port = Get-RsProperty -Object $Survey -Name 'port'
    $lines.Add('Ports')
    $lines.Add(('  USB controllers: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $port -Name 'usb'))))
    $lines.Add(('  COM: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $port -Name 'com'))))
    $lines.Add(('  Parallel: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $port -Name 'parallel'))))
    $lines.Add(('  USB4 or Thunderbolt: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $port -Name 'thunderbolt'))))
    $lines.Add('  USB devices:')
    $deviceSeen = 0
    $deviceTotal = 0
    foreach ($device in @(Get-RsProperty -Object $port -Name 'device')) {
        $deviceTotal++
        if ($deviceSeen -ge 80) {
            continue
        }
        $lines.Add(('    - {0}' -f (Format-RsText -Value $device)))
        $deviceSeen++
    }
    if ($deviceTotal -eq 0) {
        $lines.Add('    none')
    } elseif ($deviceTotal -gt 80) {
        $lines.Add(('    ... and {0} more' -f ($deviceTotal - 80)))
    }
    $lines.Add('')

    $lines.Add('Printers')
    $printerSeen = $false
    foreach ($printer in @(Get-RsProperty -Object $Survey -Name 'printer')) {
        $printerSeen = $true
        $lines.Add(('  - {0} ({1}, {2})' -f (Format-RsText -Value $printer.name), (Format-RsText -Value $printer.kind), (Format-RsText -Value $printer.port)))
    }
    if (-not $printerSeen) {
        $lines.Add('  none')
    }
    $lines.Add('')

    $os = Get-RsProperty -Object $Survey -Name 'os'
    $lines.Add('OS')
    $lines.Add(('  Edition: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $os -Name 'caption'))))
    $lines.Add(('  Build: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $os -Name 'build'))))
    $lines.Add(('  Membership: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $os -Name 'membership'))))
    $lines.Add(('  Windows 11 readiness: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $os -Name 'readiness'))))
    $lines.Add(('  Windows Server: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $os -Name 'server'))))
    $roleSeen = $false
    foreach ($role in @(Get-RsProperty -Object $os -Name 'role')) {
        $roleSeen = $true
        $lines.Add(('  Role: {0}' -f (Format-RsText -Value $role)))
    }
    if (-not $roleSeen) {
        $lines.Add('  Roles: none')
    }
    $lines.Add('  Dental software:')
    $softwareSeen = $false
    foreach ($app in @(Get-RsProperty -Object $os -Name 'software')) {
        $softwareSeen = $true
        $lines.Add(('    - {0} {1}' -f (Format-RsText -Value $app.Label), (Format-RsText -Value $app.Version)))
    }
    if (-not $softwareSeen) {
        $lines.Add('    none')
    }
    $lines.Add('')

    $lines.Add('Power')
    $lines.Add(('  {0}' -f (Format-RsText -Value (Get-RsProperty -Object $Survey -Name 'power'))))
    $lines.Add('')

    $lines.Add('Replacement notes')
    $noteSeen = $false
    foreach ($note in @(Get-RsProperty -Object $Survey -Name 'note')) {
        $text = Format-RsText -Value $note
        if ($text -eq 'n/a') {
            continue
        }
        $noteSeen = $true
        $lines.Add(('  - {0}' -f $text))
    }
    if (-not $noteSeen) {
        $lines.Add('  - No special replacement flags')
    }
    $problems = @(Get-RsProperty -Object $Survey -Name 'problem')
    if ($problems.Count -gt 0) {
        $lines.Add('')
        $lines.Add('Collection gaps')
        foreach ($problem in $problems) {
            $lines.Add(('  - {0}' -f (Format-RsText -Value $problem)))
        }
    }
    $lines.Add('')
    $lines.Add(('RESULT: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $Survey -Name 'result'))))
    $lines.Add(('Summary: {0}' -f (Format-RsText -Value (Get-RsProperty -Object $Survey -Name 'summary'))))
    return ($lines -join "`n")
}

function Get-RsSectionError {
    param(
        [string]$Section,
        $ErrorRecord
    )

    $line = 0
    $message = 'n/a'
    if ($null -ne $ErrorRecord) {
        if ($null -ne $ErrorRecord.InvocationInfo) {
            $line = [int]$ErrorRecord.InvocationInfo.ScriptLineNumber
        }
        if ($null -ne $ErrorRecord.Exception -and -not [string]::IsNullOrWhiteSpace([string]$ErrorRecord.Exception.Message)) {
            $message = [string]$ErrorRecord.Exception.Message
        }
    }
    if ([string]::IsNullOrWhiteSpace($Section)) {
        $Section = 'survey'
    }
    return ('{0}: line {1}: {2}' -f $Section, $line, $message)
}

function Get-RsCim {
    param(
        [string]$ClassName,
        [string]$Namespace = 'root\cimv2'
    )

    try {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($item in @(Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop)) {
            if ($null -ne $item) {
                $items.Add($item)
            }
        }
        return @($items.ToArray())
    } catch {
        return @()
    }
}

function Get-RsRegistryValue {
    param(
        [string]$SubKey,
        [string]$Name
    )

    $base = $null
    $key = $null
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64)
        $key = $base.OpenSubKey($SubKey)
        if ($null -eq $key) {
            return $null
        }
        return $key.GetValue($Name)
    } finally {
        if ($null -ne $key) {
            $key.Close()
        }
        if ($null -ne $base) {
            $base.Close()
        }
    }
}

function Get-RsUninstallEntry {
    $views = @(
        [Microsoft.Win32.RegistryView]::Registry64,
        [Microsoft.Win32.RegistryView]::Registry32
    )
    $subkeys = @(
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $entries = ConvertTo-RsList
    foreach ($view in $views) {
        $base = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
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
                            $entries.Add([pscustomobject]@{
                                DisplayName    = $display
                                DisplayVersion = [string]$child.GetValue('DisplayVersion')
                            })
                        } finally {
                            if ($null -ne $child) {
                                $child.Close()
                            }
                        }
                    }
                } finally {
                    if ($null -ne $key) {
                        $key.Close()
                    }
                }
            }
        } finally {
            if ($null -ne $base) {
                $base.Close()
            }
        }
    }
    return @($entries.ToArray())
}

function Get-RsRegistryGpu {
    $base = $null
    $records = ConvertTo-RsList
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64)
        $classKey = $base.OpenSubKey('SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}')
        if ($null -eq $classKey) {
            return @($records.ToArray())
        }
        try {
            foreach ($subName in @($classKey.GetSubKeyNames())) {
                if ([string]::IsNullOrWhiteSpace([string]$subName) -or $subName -notmatch '^\d{4}$') {
                    continue
                }
                $sub = $classKey.OpenSubKey($subName)
                if ($null -eq $sub) {
                    continue
                }
                try {
                    $values = @{}
                    $hints = New-Object System.Collections.Generic.List[string]
                    foreach ($valueName in @($sub.GetValueNames())) {
                        if ([string]::IsNullOrWhiteSpace([string]$valueName)) {
                            continue
                        }
                        $raw = $sub.GetValue($valueName)
                        $values[$valueName] = $raw
                        foreach ($hint in @(Get-RsOutputHint -Text $valueName)) {
                            if (-not [string]::IsNullOrWhiteSpace([string]$hint) -and -not $hints.Contains($hint)) {
                                $hints.Add($hint)
                            }
                        }
                        if ($raw -is [string]) {
                            foreach ($hint in @(Get-RsOutputHint -Text $raw)) {
                                if (-not [string]::IsNullOrWhiteSpace([string]$hint) -and -not $hints.Contains($hint)) {
                                    $hints.Add($hint)
                                }
                            }
                        }
                    }
                    $vram = Get-RsQwMemorySize -Values $values
                    $bytes = [uint64]0
                    $source = $null
                    if ($null -ne $vram) {
                        $bytes = [uint64]$vram.Bytes
                        $source = $vram.Source
                    }
                    $records.Add([pscustomobject]@{
                        DriverDesc       = [string]$sub.GetValue('DriverDesc')
                        MatchingDeviceId = [string]$sub.GetValue('MatchingDeviceId')
                        Bytes            = $bytes
                        Source           = $source
                        Hint             = @($hints.ToArray())
                    })
                } finally {
                    if ($null -ne $sub) {
                        $sub.Close()
                    }
                }
            }
        } finally {
            if ($null -ne $classKey) {
                $classKey.Close()
            }
        }
    } finally {
        if ($null -ne $base) {
            $base.Close()
        }
    }
    return @($records.ToArray())
}

function Get-RsEdidBlock {
    $base = $null
    $records = ConvertTo-RsList
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64)
        $display = $base.OpenSubKey('SYSTEM\CurrentControlSet\Enum\DISPLAY')
        if ($null -eq $display) {
            return @($records.ToArray())
        }
        try {
            foreach ($vendor in @($display.GetSubKeyNames())) {
                if ([string]::IsNullOrWhiteSpace([string]$vendor)) {
                    continue
                }
                $vendorKey = $display.OpenSubKey($vendor)
                if ($null -eq $vendorKey) {
                    continue
                }
                try {
                    foreach ($instance in @($vendorKey.GetSubKeyNames())) {
                        if ([string]::IsNullOrWhiteSpace([string]$instance)) {
                            continue
                        }
                        $parameter = $vendorKey.OpenSubKey($instance + '\Device Parameters')
                        if ($null -eq $parameter) {
                            continue
                        }
                        try {
                            $bytes = $parameter.GetValue('EDID')
                            if ($bytes -is [byte[]] -and $bytes.Length -ge 128) {
                                $records.Add([pscustomobject]@{
                                    Key   = ('DISPLAY\' + $vendor + '\' + $instance).ToUpperInvariant()
                                    Block = $bytes
                                })
                            }
                        } finally {
                            if ($null -ne $parameter) {
                                $parameter.Close()
                            }
                        }
                    }
                } finally {
                    if ($null -ne $vendorKey) {
                        $vendorKey.Close()
                    }
                }
            }
        } finally {
            if ($null -ne $display) {
                $display.Close()
            }
        }
    } finally {
        if ($null -ne $base) {
            $base.Close()
        }
    }
    return @($records.ToArray())
}

function Get-RsDisplayTechnology {
    $code = @'
using System;
using System.Runtime.InteropServices;

public static class RsNativeDisplay {
    [StructLayout(LayoutKind.Sequential)]
    public struct Luid {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SourceInfo {
        public Luid AdapterId;
        public uint Id;
        public uint ModeInfoIdx;
        public uint StatusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Rational {
        public uint Numerator;
        public uint Denominator;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct TargetInfo {
        public Luid AdapterId;
        public uint Id;
        public uint ModeInfoIdx;
        public uint OutputTechnology;
        public uint Rotation;
        public uint Scaling;
        public Rational RefreshRate;
        public uint ScanLineOrdering;
        [MarshalAs(UnmanagedType.Bool)]
        public bool TargetAvailable;
        public uint StatusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PathInfo {
        public SourceInfo Source;
        public TargetInfo Target;
        public uint Flags;
    }

    [DllImport("user32.dll")]
    public static extern int GetDisplayConfigBufferSizes(uint flags, out uint pathCount, out uint modeCount);

    [DllImport("user32.dll")]
    public static extern int QueryDisplayConfig(uint flags, ref uint pathCount, IntPtr pathArray, ref uint modeCount, IntPtr modeArray, IntPtr topology);

    public static int[] GetOutputTechnology(uint flags) {
        uint pathCount;
        uint modeCount;
        int result = GetDisplayConfigBufferSizes(flags, out pathCount, out modeCount);
        if (result != 0 || pathCount == 0) {
            return new int[0];
        }
        int pathBytes = Marshal.SizeOf(typeof(PathInfo));
        IntPtr pathPointer = Marshal.AllocHGlobal(pathBytes * (int)pathCount);
        IntPtr modePointer = Marshal.AllocHGlobal(256 * Math.Max(1, (int)modeCount));
        try {
            result = QueryDisplayConfig(flags, ref pathCount, pathPointer, ref modeCount, modePointer, IntPtr.Zero);
            if (result != 0) {
                return new int[0];
            }
            int[] values = new int[pathCount];
            for (int index = 0; index < pathCount; index++) {
                IntPtr item = new IntPtr(pathPointer.ToInt64() + (index * pathBytes));
                PathInfo path = (PathInfo)Marshal.PtrToStructure(item, typeof(PathInfo));
                values[index] = unchecked((int)path.Target.OutputTechnology);
            }
            return values;
        } finally {
            Marshal.FreeHGlobal(pathPointer);
            Marshal.FreeHGlobal(modePointer);
        }
    }
}
'@
    try {
        if (-not ('RsNativeDisplay' -as [type])) {
            Add-Type -TypeDefinition $code -ErrorAction Stop
        }
        $active = [RsNativeDisplay]::GetOutputTechnology(2)
        $known = @()
        $unknown = 0
        foreach ($value in @($active)) {
            $name = ConvertTo-RsVideoOutput -Value $value
            if ($name -eq 'n/a') {
                $unknown++
            } else {
                $known += $name
            }
        }
        if ($known.Count -eq 0 -or $unknown -gt $known.Count) {
            return @()
        }
        return @($known)
    } catch {
        return @()
    }
}

function Write-RsSurveyFile {
    param(
        [string]$Path,
        [string]$Content
    )

    $full = $Path
    if (-not [System.IO.Path]::IsPathRooted($full)) {
        $full = [System.IO.Path]::GetFullPath($full)
    }
    $folder = [System.IO.Path]::GetDirectoryName($full)
    if (-not [string]::IsNullOrWhiteSpace($folder)) {
        [void][System.IO.Directory]::CreateDirectory($folder)
    }
    $utf8 = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
    [System.IO.File]::WriteAllText($full, $Content, $utf8)
}

function Get-RsCollectedSurvey {
    param([datetime]$Now)

    $problem = New-Object System.Collections.Generic.List[string]
    $computer = $null
    $bios = $null
    $enclosure = $null
    $os = $null
    try {
        $computer = @(Get-RsCim -ClassName 'Win32_ComputerSystem') | Select-Object -First 1
    } catch {
        $problem.Add((Get-RsSectionError -Section 'identity' -ErrorRecord $_))
    }
    try {
        $bios = @(Get-RsCim -ClassName 'Win32_BIOS') | Select-Object -First 1
    } catch {
        $problem.Add((Get-RsSectionError -Section 'identity' -ErrorRecord $_))
    }
    try {
        $enclosure = @(Get-RsCim -ClassName 'Win32_SystemEnclosure') | Select-Object -First 1
    } catch {
        $problem.Add((Get-RsSectionError -Section 'identity' -ErrorRecord $_))
    }
    try {
        $os = @(Get-RsCim -ClassName 'Win32_OperatingSystem') | Select-Object -First 1
    } catch {
        $problem.Add((Get-RsSectionError -Section 'identity' -ErrorRecord $_))
    }
    if ($null -eq $computer -and $null -eq $os) {
        return $null
    }

    $manufacturer = 'n/a'
    $model = 'n/a'
    $serial = 'n/a'
    $sku = 'n/a'
    $biosVersion = 'n/a'
    $biosDate = 'n/a'
    $smbiosVersion = 'n/a'
    $shipDate = 'n/a'
    $form = [pscustomobject]@{ Size = 'n/a'; Name = 'n/a'; Detail = 'n/a' }
    try {
        $manufacturer = Format-RsText -Value (Get-RsProperty -Object $computer -Name 'Manufacturer')
        $model = Format-RsText -Value (Get-RsProperty -Object $computer -Name 'Model')
        $serial = Format-RsSerial -Value (Get-RsProperty -Object $bios -Name 'SerialNumber')
        if ($serial -eq 'n/a') {
            $serial = Format-RsSerial -Value (Get-RsProperty -Object $enclosure -Name 'SerialNumber')
        }
        $sku = Format-RsText -Value (Get-RsProperty -Object $computer -Name 'SystemSKUNumber')
        $biosVersion = Format-RsText -Value (Get-RsProperty -Object $bios -Name 'SMBIOSBIOSVersion')
        $biosDate = Format-RsText -Value (ConvertTo-RsBiosDate -Value (Get-RsProperty -Object $bios -Name 'ReleaseDate') -Now $Now)
        $smbiosMajor = Format-RsText -Value (Get-RsProperty -Object $bios -Name 'SMBIOSMajorVersion')
        $smbiosMinor = Format-RsText -Value (Get-RsProperty -Object $bios -Name 'SMBIOSMinorVersion')
        $smbiosVersion = 'n/a'
        if ($smbiosMajor -ne 'n/a') {
            $smbiosVersion = $smbiosMajor
            if ($smbiosMinor -ne 'n/a') {
                $smbiosVersion = '{0}.{1}' -f $smbiosMajor, $smbiosMinor
            }
        }
        $shipDate = Get-RsShipDateEstimate -Manufacturer $manufacturer -Serial $serial -BiosReleaseDate (Get-RsProperty -Object $bios -Name 'ReleaseDate') -Now $Now
        $form = Get-RsFormFactor -ChassisType (Get-RsProperty -Object $enclosure -Name 'ChassisTypes') -Model $model -PcSystemType (Get-RsProperty -Object $computer -Name 'PCSystemType')
    } catch {
        $problem.Add((Get-RsSectionError -Section 'identity' -ErrorRecord $_))
        $manufacturer = 'n/a'
        $model = 'n/a'
        $serial = 'n/a'
        $sku = 'n/a'
        $biosVersion = 'n/a'
        $biosDate = 'n/a'
        $smbiosVersion = 'n/a'
        $shipDate = 'n/a'
        $form = [pscustomobject]@{ Size = 'n/a'; Name = 'n/a'; Detail = 'n/a' }
    }

    $registryGpu = @()
    $registryHints = New-Object System.Collections.Generic.List[string]
    try {
        $registryGpu = @(Get-RsRegistryGpu)
        foreach ($hintGroup in $registryGpu) {
            if ($null -eq $hintGroup) {
                continue
            }
            foreach ($hint in @($hintGroup.Hint)) {
                $hintText = [string]$hint
                if (-not [string]::IsNullOrWhiteSpace($hintText) -and -not $registryHints.Contains($hintText)) {
                    $registryHints.Add($hintText)
                }
            }
        }
    } catch {
        $problem.Add((Get-RsSectionError -Section 'gpu' -ErrorRecord $_))
        $registryGpu = @()
        $registryHints = New-Object System.Collections.Generic.List[string]
    }
    $gpuItems = ConvertTo-RsList
    $dedicated = $false
    try {
        foreach ($controller in @(Get-RsCim -ClassName 'Win32_VideoController')) {
            if ($null -eq $controller) {
                continue
            }
            $name = Format-RsText -Value (Get-RsProperty -Object $controller -Name 'Name')
            $pnp = [string](Get-RsProperty -Object $controller -Name 'PNPDeviceID')
            if ([string]::IsNullOrWhiteSpace($pnp)) {
                $pnp = ''
            }
            $isDedicated = Test-RsDedicatedGpu -Name $name -PnpDeviceId $pnp
            if ($isDedicated) {
                $dedicated = $true
            }
            $kind = 'integrated'
            if ($isDedicated) {
                $kind = 'dedicated'
            }
            $bytes = [uint64]0
            $vramSource = 'n/a'
            foreach ($entry in $registryGpu) {
                if ($null -eq $entry) {
                    continue
                }
                $id = [string]$entry.MatchingDeviceId
                $desc = [string]$entry.DriverDesc
                $idMatch = $false
                if (-not [string]::IsNullOrWhiteSpace($id) -and -not [string]::IsNullOrWhiteSpace($pnp)) {
                    $idMatch = $pnp.StartsWith($id, [System.StringComparison]::OrdinalIgnoreCase)
                }
                $nameMatch = $name -ne 'n/a' -and $name -eq $desc
                if ($idMatch -or $nameMatch) {
                    if ($null -ne $entry.Bytes) {
                        $bytes = [uint64]$entry.Bytes
                    }
                    if (-not [string]::IsNullOrWhiteSpace([string]$entry.Source)) {
                        $vramSource = [string]$entry.Source
                    }
                    break
                }
            }
            $vramText = 'n/a'
            if ($bytes -gt 0) {
                $vramGb = [math]::Round(($bytes / 1073741824), 1)
                $vramText = $vramGb.ToString([System.Globalization.CultureInfo]::InvariantCulture)
            }
            $estimate = Get-RsGpuOutputEstimate -Name $name
            $estimated = 'n/a'
            $estimateNote = 'n/a'
            if ($null -ne $estimate -and $estimate.Estimated) {
                $estimated = Format-RsEstimatedPort -Estimate $estimate
                $estimateNote = [string]$estimate.Note
            }
            $gpuItems.Add([pscustomobject]@{
                name         = $name
                kind         = $kind
                vram         = $vramText
                vramSource   = $vramSource
                estimated    = $estimated
                estimateNote = $estimateNote
            })
        }
    } catch {
        $problem.Add((Get-RsSectionError -Section 'gpu' -ErrorRecord $_))
        $gpuItems = ConvertTo-RsList
        $dedicated = $false
    }

    $connectionByKey = @{}
    $sizeByKey = @{}
    $edidByKey = @{}
    $reportedNames = New-Object System.Collections.Generic.List[string]
    $reportedSource = 'n/a'
    $monitorItems = ConvertTo-RsList
    $external = 0
    try {
        foreach ($connection in @(Get-RsCim -ClassName 'WmiMonitorConnectionParams' -Namespace 'root\wmi')) {
            if ($null -eq $connection) {
                continue
            }
            $key = Get-RsMonitorKey -InstanceName (Get-RsProperty -Object $connection -Name 'InstanceName')
            $connectionByKey[$key] = ConvertTo-RsVideoOutput -Value (Get-RsProperty -Object $connection -Name 'VideoOutputTechnology')
        }
        foreach ($basic in @(Get-RsCim -ClassName 'WmiMonitorBasicDisplayParams' -Namespace 'root\wmi')) {
            if ($null -eq $basic) {
                continue
            }
            $key = Get-RsMonitorKey -InstanceName (Get-RsProperty -Object $basic -Name 'InstanceName')
            $inch = Get-RsPanelInch -WidthCm (Get-RsProperty -Object $basic -Name 'MaxHorizontalImageSize') -HeightCm (Get-RsProperty -Object $basic -Name 'MaxVerticalImageSize')
            if ($null -ne $inch) {
                $sizeByKey[$key] = $inch.ToString([System.Globalization.CultureInfo]::InvariantCulture)
            }
        }
    } catch {
        $problem.Add((Get-RsSectionError -Section 'monitors' -ErrorRecord $_))
        $connectionByKey = @{}
        $sizeByKey = @{}
    }
    try {
        foreach ($edid in @(Get-RsEdidBlock)) {
            if ($null -eq $edid) {
                continue
            }
            $edidByKey[[string]$edid.Key] = $edid.Block
        }
    } catch {
        $problem.Add((Get-RsSectionError -Section 'monitors' -ErrorRecord $_))
        $edidByKey = @{}
    }
    try {
        foreach ($key in @($connectionByKey.Keys)) {
            $reportedNames.Add([string]$connectionByKey[$key])
        }
        if ($reportedNames.Count -gt 0) {
            $reportedSource = 'WmiMonitorConnectionParams'
        } else {
            foreach ($name in @(Get-RsDisplayTechnology)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$name)) {
                    $reportedNames.Add([string]$name)
                }
            }
            if ($reportedNames.Count -gt 0) {
                $reportedSource = 'display config'
            }
        }
        if ($registryHints.Count -gt 0 -and $reportedNames.Count -eq 0) {
            foreach ($hint in $registryHints) {
                $reportedNames.Add($hint)
            }
            $reportedSource = 'display class registry'
        }
        foreach ($screen in @(Get-RsCim -ClassName 'WmiMonitorID' -Namespace 'root\wmi')) {
            if ($null -eq $screen) {
                continue
            }
            $active = Get-RsProperty -Object $screen -Name 'Active'
            if ($active -eq $false) {
                continue
            }
            $key = Get-RsMonitorKey -InstanceName (Get-RsProperty -Object $screen -Name 'InstanceName')
            $make = ConvertTo-RsMonitorVendor -Code (ConvertTo-RsAsciiWord -Value (Get-RsProperty -Object $screen -Name 'ManufacturerName'))
            $friendly = [string](ConvertTo-RsAsciiWord -Value (Get-RsProperty -Object $screen -Name 'UserFriendlyName'))
            if ([string]::IsNullOrWhiteSpace($friendly)) {
                $friendly = [string](ConvertTo-RsAsciiWord -Value (Get-RsProperty -Object $screen -Name 'ProductCodeID'))
            }
            $screenSerial = ConvertTo-RsAsciiWord -Value (Get-RsProperty -Object $screen -Name 'SerialNumberID')
            $connection = 'n/a'
            if ($connectionByKey.ContainsKey($key)) {
                $connection = [string]$connectionByKey[$key]
            }
            $sizeText = 'n/a'
            if ($sizeByKey.ContainsKey($key)) {
                $sizeText = [string]$sizeByKey[$key]
            }
            $resolution = 'n/a'
            if ($edidByKey.ContainsKey($key)) {
                $decoded = Get-RsEdidResolution -Block $edidByKey[$key]
                if (-not [string]::IsNullOrWhiteSpace($decoded)) {
                    $resolution = $decoded
                }
            }
            $year = 0
            if ([int]::TryParse([string](Get-RsProperty -Object $screen -Name 'YearOfManufacture'), [ref]$year) -and $year -ge 1995) {
                if (-not [string]::IsNullOrEmpty($friendly)) {
                    $friendly = '{0} (made {1})' -f $friendly, $year
                }
            }
            if ($connection -ne 'Internal' -and $connection -ne 'LVDS') {
                $external++
            }
            $monitorItems.Add([pscustomobject]@{
                make       = (Format-RsText -Value $make)
                model      = (Format-RsText -Value $friendly)
                serial     = (Format-RsText -Value $screenSerial)
                sizeInch   = $sizeText
                connection = (Format-RsText -Value $connection)
                resolution = $resolution
            })
        }
    } catch {
        $problem.Add((Get-RsSectionError -Section 'monitors' -ErrorRecord $_))
        $reportedNames = New-Object System.Collections.Generic.List[string]
        $reportedSource = 'n/a'
        $monitorItems = ConvertTo-RsList
        $external = 0
    }

    $cpuItems = ConvertTo-RsList
    try {
        foreach ($processor in @(Get-RsCim -ClassName 'Win32_Processor')) {
            if ($null -eq $processor) {
                continue
            }
            $cpuName = Format-RsText -Value (Get-RsProperty -Object $processor -Name 'Name')
            $core = 0
            $logical = 0
            $mhz = 0
            $width = 0
            [void][int]::TryParse([string](Get-RsProperty -Object $processor -Name 'NumberOfCores'), [ref]$core)
            [void][int]::TryParse([string](Get-RsProperty -Object $processor -Name 'NumberOfLogicalProcessors'), [ref]$logical)
            [void][int]::TryParse([string](Get-RsProperty -Object $processor -Name 'MaxClockSpeed'), [ref]$mhz)
            [void][int]::TryParse([string](Get-RsProperty -Object $processor -Name 'AddressWidth'), [ref]$width)
            $support = Test-RsCpuSupport -Name $cpuName -Core $core -AddressWidth $width -MaxClockMHz $mhz
            $status = 'n/a'
            $detail = 'n/a'
            if ($null -ne $support) {
                $status = [string]$support.Status
                $detail = [string]$support.Detail
            }
            $cpuItems.Add([pscustomobject]@{
                name       = $cpuName
                core       = $(if ($core -gt 0) { [string]$core } else { 'n/a' })
                logical    = $(if ($logical -gt 0) { [string]$logical } else { 'n/a' })
                mhz        = $(if ($mhz -gt 0) { [string]$mhz } else { 'n/a' })
                readiness  = ('{0}: {1}' -f $status, $detail)
            })
        }
    } catch {
        $problem.Add((Get-RsSectionError -Section 'cpu' -ErrorRecord $_))
        $cpuItems = ConvertTo-RsList
    }

    $dimmItems = ConvertTo-RsList
    $slotText = 'n/a'
    $maxText = 'n/a'
    try {
    $modules = @(Get-RsCim -ClassName 'Win32_PhysicalMemory')
    $arrays = @(Get-RsCim -ClassName 'Win32_PhysicalMemoryArray')
    $slotTotal = 0
    $maxKb = 0.0
    foreach ($array in $arrays) {
        if ($null -eq $array) {
            continue
        }
        $count = 0
        if ([int]::TryParse([string](Get-RsProperty -Object $array -Name 'MemoryDevices'), [ref]$count)) {
            $slotTotal += $count
        }
        $capacity = ConvertTo-RsMaxRamGb -Kilobyte (Get-RsProperty -Object $array -Name 'MaxCapacityEx')
        if ($null -eq $capacity) {
            $capacity = ConvertTo-RsMaxRamGb -Kilobyte (Get-RsProperty -Object $array -Name 'MaxCapacity')
        }
        if ($null -ne $capacity -and $capacity -gt $maxKb) {
            $maxKb = $capacity
        }
    }
    foreach ($module in $modules) {
        if ($null -eq $module) {
            continue
        }
        $locator = Format-RsText -Value (Get-RsProperty -Object $module -Name 'DeviceLocator')
        if ($locator -eq 'n/a') {
            $locator = Format-RsText -Value (Get-RsProperty -Object $module -Name 'BankLabel')
        }
        $speed = Get-RsProperty -Object $module -Name 'ConfiguredClockSpeed'
        if ($null -eq $speed -or [string]$speed -eq '0') {
            $speed = Get-RsProperty -Object $module -Name 'Speed'
        }
        $dimmItems.Add([pscustomobject]@{
            locator = $locator
            size    = (Format-RsGb -Bytes (Get-RsProperty -Object $module -Name 'Capacity'))
            type    = (ConvertTo-RsMemoryType -Value (Get-RsProperty -Object $module -Name 'SMBIOSMemoryType'))
            speed   = $(if ($null -eq $speed -or [string]$speed -eq '0') { 'n/a' } else { [string]$speed })
        })
    }
    if ($slotTotal -gt 0) {
        $slotText = '{0} of {1}' -f $dimmItems.Count, $slotTotal
    } elseif ($dimmItems.Count -gt 0) {
        $slotText = '{0} populated, total n/a' -f $dimmItems.Count
    }
    if ($maxKb -gt 0) {
        $maxText = $maxKb.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    } catch {
        $problem.Add((Get-RsSectionError -Section 'memory' -ErrorRecord $_))
        $dimmItems = ConvertTo-RsList
        $slotText = 'n/a'
        $maxText = 'n/a'
    }

    $diskItems = ConvertTo-RsList
    $volumeItems = ConvertTo-RsList
    try {
    $freeByDisk = @{}
    foreach ($link in @(Get-RsCim -ClassName 'Win32_LogicalDiskToPartition')) {
        if ($null -eq $link) {
            continue
        }
        $partitionText = [string](Get-RsProperty -Object $link -Name 'Antecedent')
        $logicalText = [string](Get-RsProperty -Object $link -Name 'Dependent')
        $diskIndex = Get-RsDiskIndex -Text $partitionText
        $letterMatch = [regex]::Match($logicalText, 'DeviceID="([A-Z]:)"')
        if ($null -eq $diskIndex -or -not $letterMatch.Success) {
            continue
        }
        if (-not $freeByDisk.ContainsKey([int]$diskIndex)) {
            $freeByDisk[[int]$diskIndex] = New-Object System.Collections.Generic.List[string]
        }
        $freeByDisk[[int]$diskIndex].Add($letterMatch.Groups[1].Value)
    }
    $volumeFree = @{}
    foreach ($logical in @(Get-RsCim -ClassName 'Win32_LogicalDisk')) {
        if ($null -eq $logical) {
            continue
        }
        if ([string](Get-RsProperty -Object $logical -Name 'DriveType') -ne '3') {
            continue
        }
        $letter = Format-RsText -Value (Get-RsProperty -Object $logical -Name 'DeviceID')
        $free = Get-RsProperty -Object $logical -Name 'FreeSpace'
        $size = Get-RsProperty -Object $logical -Name 'Size'
        $volumeFree[$letter] = $free
        $volumeItems.Add([pscustomobject]@{
            letter = $letter
            size   = (Format-RsGb -Bytes $size)
            free   = (Format-RsGb -Bytes $free)
        })
    }

    $physical = @(Get-RsCim -ClassName 'MSFT_PhysicalDisk' -Namespace 'root\microsoft\windows\storage')
    if ($physical.Count -eq 0) {
        $physical = @(Get-RsCim -ClassName 'Win32_DiskDrive')
    }
    $diskPosition = 0
    foreach ($disk in $physical) {
        if ($null -eq $disk) {
            continue
        }
        $diskModel = Format-RsText -Value (Get-RsProperty -Object $disk -Name 'FriendlyName')
        if ($diskModel -eq 'n/a') {
            $diskModel = Format-RsText -Value (Get-RsProperty -Object $disk -Name 'Model')
        }
        $indexValue = Get-RsProperty -Object $disk -Name 'DeviceId'
        if ($null -eq $indexValue) {
            $indexValue = Get-RsProperty -Object $disk -Name 'Index'
        }
        $indexNumber = $null
        $parsedIndex = 0
        if ([int]::TryParse([string]$indexValue, [ref]$parsedIndex)) {
            $indexNumber = $parsedIndex
        }
        $freeBytes = $null
        if ($null -ne $indexNumber -and $freeByDisk.ContainsKey([int]$indexNumber)) {
            $sum = [uint64]0
            $saw = $false
            $letterList = $freeByDisk[[int]$indexNumber]
            $letters = @()
            if ($null -ne $letterList) {
                $letters = @($letterList.ToArray())
            }
            foreach ($letter in $letters) {
                if ($volumeFree.ContainsKey([string]$letter)) {
                    $part = [uint64]0
                    if ([uint64]::TryParse([string]$volumeFree[[string]$letter], [ref]$part)) {
                        $sum += $part
                        $saw = $true
                    }
                }
            }
            if ($saw) {
                $freeBytes = $sum
            }
        }
        $health = Format-RsText -Value (Get-RsProperty -Object $disk -Name 'HealthStatus')
        if ($health -eq 'n/a') {
            $health = Format-RsText -Value (Get-RsProperty -Object $disk -Name 'Status')
        }
        $diskItems.Add([pscustomobject]@{
            index  = $(if ($null -eq $indexNumber) { [string]$diskPosition } else { [string]$indexNumber })
            model  = $diskModel
            size   = (Format-RsGb -Bytes (Get-RsProperty -Object $disk -Name 'Size'))
            media  = (Get-RsMediaKind -MediaType (Get-RsProperty -Object $disk -Name 'MediaType') -BusType (Get-RsProperty -Object $disk -Name 'BusType') -Model $diskModel)
            health = $health
            free   = (Format-RsGb -Bytes $freeBytes)
            serial = (Format-RsSerial -Value (Get-RsProperty -Object $disk -Name 'SerialNumber'))
        })
        $diskPosition++
    }
    } catch {
        $problem.Add((Get-RsSectionError -Section 'storage' -ErrorRecord $_))
        $diskItems = ConvertTo-RsList
        $volumeItems = ConvertTo-RsList
    }

    $ethernetItems = ConvertTo-RsList
    $wifiItems = ConvertTo-RsList
    try {
        $configByMac = @{}
        foreach ($config in @(Get-RsCim -ClassName 'Win32_NetworkAdapterConfiguration')) {
            if ($null -eq $config) {
                continue
            }
            $mac = [string](Get-RsProperty -Object $config -Name 'MACAddress')
            if ([string]::IsNullOrWhiteSpace($mac)) {
                continue
            }
            $macKey = $mac.ToUpperInvariant()
            $ips = @()
            foreach ($ip in @(Get-RsProperty -Object $config -Name 'IPAddress')) {
                if (-not [string]::IsNullOrWhiteSpace([string]$ip)) {
                    $ips += [string]$ip
                }
            }
            $configByMac[$macKey] = $(if ($ips.Count -eq 0) { 'n/a' } else { $ips -join ', ' })
        }
        foreach ($adapter in @(Get-RsCim -ClassName 'Win32_NetworkAdapter')) {
            if ($null -eq $adapter) {
                continue
            }
            $adapterName = [string](Get-RsProperty -Object $adapter -Name 'Name')
            $mac = Format-RsText -Value (Get-RsProperty -Object $adapter -Name 'MACAddress')
            $ip = 'n/a'
            if ($mac -ne 'n/a') {
                $macKey = $mac.ToUpperInvariant()
                if ($configByMac.ContainsKey($macKey)) {
                    $ip = [string]$configByMac[$macKey]
                }
            }
            $speed = ConvertTo-RsLinkSpeed -BitsPerSecond (Get-RsProperty -Object $adapter -Name 'Speed')
            if (Test-RsEthernetAdapter -Name $adapterName -AdapterType ([string](Get-RsProperty -Object $adapter -Name 'AdapterType'))) {
                $ethernetItems.Add([pscustomobject]@{
                    name  = (Format-RsText -Value $adapterName)
                    speed = $speed
                    mac   = $mac
                    ip    = $ip
                })
            } elseif (Test-RsWifiAdapter -Name $adapterName) {
                $wifiItems.Add([pscustomobject]@{
                    name     = (Format-RsText -Value $adapterName)
                    standard = (ConvertTo-RsWifiStandard -Name $adapterName)
                    mac      = $mac
                    ip       = $ip
                })
            }
        }
    } catch {
        $problem.Add((Get-RsSectionError -Section 'network' -ErrorRecord $_))
        $ethernetItems = ConvertTo-RsList
        $wifiItems = ConvertTo-RsList
    }

    $bluetoothText = 'n/a'
    $bluetoothOn = $false
    try {
        $bluetoothText = 'none'
        foreach ($device in @(Get-RsCim -ClassName 'Win32_PnPEntity')) {
            if ($null -eq $device) {
                continue
            }
            $deviceName = [string](Get-RsProperty -Object $device -Name 'Name')
            $deviceClass = [string](Get-RsProperty -Object $device -Name 'PNPClass')
            if ($deviceClass -ne 'Bluetooth' -and $deviceName -notmatch '(?i)Bluetooth') {
                continue
            }
            if ($deviceName -match '(?i)Enumerator|RFCOMM|Personal Area|Service|Profile|Device \(') {
                continue
            }
            $errorCode = 0
            [void][int]::TryParse([string](Get-RsProperty -Object $device -Name 'ConfigManagerErrorCode'), [ref]$errorCode)
            $state = 'radio state n/a'
            if ($errorCode -eq 22) {
                $state = 'radio off'
            } elseif ([string](Get-RsProperty -Object $device -Name 'Status') -eq 'OK') {
                $state = 'radio on'
                $bluetoothOn = $true
            }
            $bluetoothText = '{0} ({1})' -f (Format-RsText -Value $deviceName), $state
            break
        }
    } catch {
        $problem.Add((Get-RsSectionError -Section 'bluetooth' -ErrorRecord $_))
        $bluetoothText = 'n/a'
        $bluetoothOn = $false
    }

    $usbText = 'n/a'
    $comText = 'n/a'
    $parallelText = 'n/a'
    $thunderbolt = $false
    $usbDevices = ConvertTo-RsList
    $comNames = New-Object System.Collections.Generic.List[string]
    try {
    $usbNames = New-Object System.Collections.Generic.List[string]
    $usbCounts = @{}
    $parallelNames = New-Object System.Collections.Generic.List[string]
    foreach ($controller in @(Get-RsCim -ClassName 'Win32_USBController')) {
        if ($null -eq $controller) {
            continue
        }
        $controllerName = [string](Get-RsProperty -Object $controller -Name 'Name')
        $generation = ConvertTo-RsUsbGeneration -Name $controllerName
        if ($generation -eq 'n/a') {
            continue
        }
        if (-not $usbCounts.ContainsKey($generation)) {
            $usbCounts[$generation] = 0
            $usbNames.Add($generation)
        }
        $usbCounts[$generation] = [int]$usbCounts[$generation] + 1
        if ($controllerName -match '(?i)USB4|Thunderbolt|USB-C') {
            $thunderbolt = $true
        }
    }
    foreach ($entity in @(Get-RsCim -ClassName 'Win32_PnPEntity')) {
        if ($null -eq $entity) {
            continue
        }
        $entityName = [string](Get-RsProperty -Object $entity -Name 'Name')
        $entityId = [string](Get-RsProperty -Object $entity -Name 'PNPDeviceID')
        if ($entityName -match '(?i)Thunderbolt|USB4') {
            $thunderbolt = $true
        }
        if ($entityId -like 'USB\*' -and (Test-RsUsbLeaf -Name $entityName)) {
            $usbDevices.Add((Format-RsText -Value $entityName))
        }
    }
    foreach ($com in @(Get-RsCim -ClassName 'Win32_SerialPort')) {
        if ($null -eq $com) {
            continue
        }
        $comName = Format-RsText -Value (Get-RsProperty -Object $com -Name 'DeviceID')
        if ($comName -ne 'n/a') {
            $comNames.Add($comName)
        }
    }
    foreach ($deviceName in $usbDevices) {
        if (Test-RsComDevice -Name ([string]$deviceName)) {
            $comNames.Add([string]$deviceName)
        }
    }
    foreach ($parallel in @(Get-RsCim -ClassName 'Win32_ParallelPort')) {
        if ($null -eq $parallel) {
            continue
        }
        $parallelName = Format-RsText -Value (Get-RsProperty -Object $parallel -Name 'DeviceID')
        if ($parallelName -eq 'n/a') {
            $parallelName = Format-RsText -Value (Get-RsProperty -Object $parallel -Name 'Name')
        }
        if ($parallelName -ne 'n/a') {
            $parallelNames.Add($parallelName)
        }
    }
    $usbText = 'none'
    if ($usbNames.Count -gt 0) {
        $usbParts = @()
        foreach ($generation in $usbNames) {
            $usbParts += ('{0} x{1}' -f $generation, $usbCounts[$generation])
        }
        $usbText = $usbParts -join ', '
    }
    $comText = 'none'
    if ($comNames.Count -gt 0) {
        $comText = ($comNames -join ', ')
    }
    $parallelText = 'none'
    if ($parallelNames.Count -gt 0) {
        $parallelText = ($parallelNames -join ', ')
    }
    } catch {
        $problem.Add((Get-RsSectionError -Section 'ports' -ErrorRecord $_))
        $usbText = 'n/a'
        $comText = 'n/a'
        $parallelText = 'n/a'
        $thunderbolt = $false
        $usbDevices = ConvertTo-RsList
        $comNames = New-Object System.Collections.Generic.List[string]
    }

    $printerItems = ConvertTo-RsList
    try {
        foreach ($printer in @(Get-RsCim -ClassName 'Win32_Printer')) {
            if ($null -eq $printer) {
                continue
            }
            $printerName = [string](Get-RsProperty -Object $printer -Name 'Name')
            if (Test-RsIgnoredPrinter -Name $printerName) {
                continue
            }
            $portName = [string](Get-RsProperty -Object $printer -Name 'PortName')
            $printerItems.Add([pscustomobject]@{
                name = (Format-RsText -Value $printerName)
                kind = (Get-RsPrinterKind -PortName $portName -Network (Get-RsProperty -Object $printer -Name 'Network'))
                port = (Format-RsText -Value $portName)
            })
        }
    } catch {
        $problem.Add((Get-RsSectionError -Section 'printers' -ErrorRecord $_))
        $printerItems = ConvertTo-RsList
    }

    $caption = 'n/a'
    $buildText = 'n/a'
    $membership = 'n/a'
    $readiness = 'n/a'
    $serverText = 'n/a'
    $roleItems = ConvertTo-RsList
    try {
    $caption = Format-RsText -Value (Get-RsProperty -Object $os -Name 'Caption')
    $buildNumber = 0
    [void][int]::TryParse([string](Get-RsProperty -Object $os -Name 'BuildNumber'), [ref]$buildNumber)
    $productType = 0
    [void][int]::TryParse([string](Get-RsProperty -Object $os -Name 'ProductType'), [ref]$productType)
    $ubr = 'n/a'
    $displayVersion = 'n/a'
    try {
        $ubr = Format-RsText -Value (Get-RsRegistryValue -SubKey 'SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'UBR')
        $displayVersion = Format-RsText -Value (Get-RsRegistryValue -SubKey 'SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'DisplayVersion')
    } catch {
        $problem.Add((Get-RsSectionError -Section 'operating system' -ErrorRecord $_))
    }
    $buildText = [string]$buildNumber
    if ($ubr -ne 'n/a') {
        $buildText = '{0}.{1}' -f $buildNumber, $ubr
    }
    if ($displayVersion -ne 'n/a') {
        $buildText = '{0} ({1})' -f $buildText, $displayVersion
    }
    $isServer = Test-RsServer -Caption $caption -ProductType $productType
    $isWin11 = Test-RsWindows11 -Caption $caption -Build $buildNumber
    $gap = New-Object System.Collections.Generic.List[string]
    if (-not $isServer) {
        $firmware = ''
        try {
            $firmware = [string](Get-RsRegistryValue -SubKey 'SYSTEM\CurrentControlSet\Control' -Name 'PEFirmwareType')
        } catch {
            $problem.Add((Get-RsSectionError -Section 'operating system' -ErrorRecord $_))
        }
        if ($firmware -eq '1') {
            $gap.Add('Legacy BIOS')
        }
        $secure = $false
        $secureKnown = $false
        try {
            $secure = [bool](Confirm-SecureBootUEFI -ErrorAction Stop)
            $secureKnown = $true
        } catch {
            $secureKnown = $false
        }
        if (-not $secureKnown -or -not $secure) {
            $gap.Add('Secure Boot')
        }
        $tpm = @(Get-RsCim -ClassName 'Win32_Tpm' -Namespace 'root\cimv2\Security\MicrosoftTpm') | Select-Object -First 1
        $spec = [string](Get-RsProperty -Object $tpm -Name 'SpecVersion')
        $specMatch = [regex]::Match($spec, '(\d+)\.(\d+)')
        if ($null -eq $tpm -or -not $specMatch.Success -or [int]$specMatch.Groups[1].Value -lt 2) {
            $gap.Add('TPM 2.0')
        }
        if ($cpuItems.Count -gt 0 -and [string]$cpuItems[0].readiness -match '^Fail') {
            $gap.Add('CPU')
        }
    }
    $readiness = Get-RsReadinessLine -IsServer $isServer -IsWindows11 $isWin11 -Gap @($gap)
    $membership = 'n/a'
    if ($null -ne $computer) {
        if ([bool](Get-RsProperty -Object $computer -Name 'PartOfDomain')) {
            $membership = 'Domain ' + (Format-RsText -Value (Get-RsProperty -Object $computer -Name 'Domain'))
        } else {
            $workgroup = Get-RsProperty -Object $computer -Name 'Workgroup'
            if ([string]::IsNullOrWhiteSpace([string]$workgroup)) {
                $workgroup = Get-RsProperty -Object $computer -Name 'Domain'
            }
            $membership = 'Workgroup ' + (Format-RsText -Value $workgroup)
        }
    }
    $roleItems = ConvertTo-RsList
    $serverText = 'no'
    if ($isServer) {
        $serverText = 'yes'
        foreach ($feature in @(Get-RsCim -ClassName 'Win32_ServerFeature')) {
            $roleName = Format-RsText -Value (Get-RsProperty -Object $feature -Name 'Name')
            if ($roleName -ne 'n/a') {
                $roleItems.Add($roleName)
            }
        }
    }
    } catch {
        $problem.Add((Get-RsSectionError -Section 'operating system' -ErrorRecord $_))
        $caption = 'n/a'
        $buildText = 'n/a'
        $membership = 'n/a'
        $readiness = 'n/a'
        $serverText = 'n/a'
        $roleItems = ConvertTo-RsList
    }
    $software = ConvertTo-RsList
    $imaging = $false
    try {
        $software = Find-RsInstalledApp -Entry @(Get-RsUninstallEntry)
        foreach ($app in $software) {
            if ($null -eq $app) {
                continue
            }
            if (Test-RsImagingLabel -Label ([string]$app.Label)) {
                $imaging = $true
            }
        }
    } catch {
        $problem.Add((Get-RsSectionError -Section 'software' -ErrorRecord $_))
        $software = ConvertTo-RsList
        $imaging = $false
    }

    $power = 'n/a'
    $batteryHealth = -1
    try {
        $battery = @(Get-RsCim -ClassName 'Win32_Battery') | Select-Object -First 1
        $power = 'No battery'
        if ($null -ne $battery) {
            $health = Get-RsBatteryHealthPercent -Design (Get-RsProperty -Object $battery -Name 'DesignCapacity') -Full (Get-RsProperty -Object $battery -Name 'FullChargeCapacity')
            $charge = Format-RsText -Value (Get-RsProperty -Object $battery -Name 'EstimatedChargeRemaining')
            $healthText = 'n/a'
            if ($null -ne $health) {
                $batteryHealth = [int]$health
                $healthText = [string]$health
            }
            $power = 'Battery {0}, health {1} percent, charge {2} percent' -f (Format-RsText -Value (Get-RsProperty -Object $battery -Name 'Name')), $healthText, $charge
        }
    } catch {
        $problem.Add((Get-RsSectionError -Section 'battery' -ErrorRecord $_))
        $power = 'n/a'
        $batteryHealth = -1
    }

    $notes = @()
    try {
        $vga = $false
        foreach ($name in @($reportedNames)) {
            if ($name -eq 'VGA') {
                $vga = $true
            }
        }
        foreach ($item in $monitorItems) {
            if ($null -ne $item -and [string]$item.connection -eq 'VGA') {
                $vga = $true
            }
        }
        $formSize = 'n/a'
        if ($null -ne $form) {
            $formSize = [string]$form.Size
        }
        $notes = @(Get-RsReplacementNote -VideoOutput @($reportedNames) -ExternalMonitor $external -VgaConnected $vga -ComPort ($comNames.Count -gt 0) -Wifi ($wifiItems.Count -gt 0) -DedicatedGpu $dedicated -ImagingSoftware $imaging -FormFactor $formSize -Bluetooth $bluetoothOn -Thunderbolt $thunderbolt -BatteryHealth $batteryHealth)
    } catch {
        $problem.Add((Get-RsSectionError -Section 'notes' -ErrorRecord $_))
        $notes = @()
    }

    return [pscustomobject]@{
        computer   = (Format-RsText -Value $env:COMPUTERNAME)
        time       = $Now.ToString('yyyy-MM-ddTHH:mm:ss')
        savedText  = 'n/a'
        savedJson  = 'n/a'
        result     = 'Pass'
        summary    = 'Replacement survey collected.'
        identity   = [pscustomobject]@{
            manufacturer  = $manufacturer
            model         = $model
            serial        = $serial
            sku           = $sku
            biosVersion   = $biosVersion
            biosDate      = $biosDate
            smbiosVersion = $smbiosVersion
            shipDate      = $shipDate
        }
        formFactor = $form
        display    = [pscustomobject]@{
            reported = (Format-RsPortTally -Type @($reportedNames))
            source   = $reportedSource
            gpu      = $gpuItems
        }
        monitor    = [pscustomobject]@{
            count    = $monitorItems.Count
            external = $external
            item     = $monitorItems
        }
        cpu        = $cpuItems
        memory     = [pscustomobject]@{
            total = (Format-RsGb -Bytes (Get-RsProperty -Object $computer -Name 'TotalPhysicalMemory'))
            slots = $slotText
            max   = $maxText
            dimm  = $dimmItems
        }
        storage    = [pscustomobject]@{
            disk   = $diskItems
            volume = $volumeItems
        }
        network    = [pscustomobject]@{
            ethernet  = $ethernetItems
            wifi      = $wifiItems
            bluetooth = $bluetoothText
        }
        port       = [pscustomobject]@{
            usb         = $usbText
            com         = $comText
            parallel    = $parallelText
            thunderbolt = $(if ($thunderbolt) { 'yes' } else { 'no' })
            device      = $usbDevices
        }
        printer    = $printerItems
        os         = [pscustomobject]@{
            caption    = $caption
            build      = $buildText
            membership = $membership
            readiness  = $readiness
            server     = $serverText
            role       = $roleItems
            software   = $software
        }
        power      = $power
        note       = (ConvertTo-RsList -Item $notes)
        problem    = (ConvertTo-RsList -Item @($problem))
    }
}

function Invoke-RsMain {
    param([string]$OutputPath)

    $script:ScExitCode = 2
    $ProgressPreference = 'SilentlyContinue'
    try {
        if (-not (Test-RsWindowsHost)) {
            Write-RsResult -Result Error -Summary 'This script must run on Windows.'
            return
        }

        $now = Get-Date
        $survey = Get-RsCollectedSurvey -Now $now
        if ($null -eq $survey) {
            Write-RsResult -Result Error -Summary 'Computer and operating system details could not be read.'
            return
        }

        $files = Resolve-RsSurveyFile -OutputPath $OutputPath -ComputerName ([string]$env:COMPUTERNAME) -Now $now
        $survey.savedText = $files.TextPath
        $survey.savedJson = $files.JsonPath
        $summaryText = Format-RsSummary -Survey $survey
        $json = ConvertTo-RsJson -Value $survey
        $saveError = $null
        try {
            Write-RsSurveyFile -Path $files.TextPath -Content ($summaryText + [Environment]::NewLine)
            Write-RsSurveyFile -Path $files.JsonPath -Content $json
        } catch {
            $saveError = Get-RsSectionError -Section 'files' -ErrorRecord $_
        }
        if (-not [string]::IsNullOrWhiteSpace($saveError)) {
            $survey.result = 'Fail'
            $survey.summary = 'Replacement survey collected, but the files could not be saved. ' + $saveError
            $survey.savedText = 'failed'
            $survey.savedJson = 'failed'
            $summaryText = Format-RsSummary -Survey $survey
            $json = ConvertTo-RsJson -Value $survey
            $script:ScExitCode = 1
        } else {
            $script:ScExitCode = 0
        }

        Write-Output $summaryText
        Write-Output $json
    } catch {
        Write-RsResult -Result Error -Summary (Get-RsSectionError -Section 'survey' -ErrorRecord $_)
        $script:ScExitCode = 2
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $script:ScExitCode = 2
    try {
        Invoke-RsMain -OutputPath $OutputPath | Out-Host
    } catch {
        $line = 0
        if ($null -ne $_.InvocationInfo) {
            $line = [int]$_.InvocationInfo.ScriptLineNumber
        }
        $message = 'n/a'
        if ($null -ne $_.Exception -and -not [string]::IsNullOrWhiteSpace([string]$_.Exception.Message)) {
            $message = [string]$_.Exception.Message
        }
        Write-Output 'RESULT: Error' | Out-Host
        Write-Output ('Summary: survey: line {0}: {1}' -f $line, $message) | Out-Host
        $script:ScExitCode = 2
    }
    $code = [int]$script:ScExitCode
    Write-Output ('EXITCODE: {0}' -f $code) | Out-Host
    $Error.Clear()
    try {
        $host.SetShouldExit($code)
    } catch {
        Write-Verbose $_.Exception.Message
    }
    exit $code
}
