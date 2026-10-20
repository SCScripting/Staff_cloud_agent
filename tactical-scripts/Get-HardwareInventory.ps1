<#
.SYNOPSIS
    Collect warranty and hardware inventory as JSON.

.DESCRIPTION
    Purpose: Print a JSON inventory for a dental office PC: model, serial,
    CPU, RAM and channel layout, GPU and VRAM, disks, OS build, and the
    identifiers needed for a warranty lookup. Vendor warranty APIs are not
    called. GPU VRAM uses qwMemorySize from the display class registry because
    Win32_VideoController.AdapterRAM caps at 4 GB.

    Parameters: none.

.NOTES
    Standard Computer Tactical RMM script. Windows PowerShell 5.1. Run as SYSTEM.
    Idempotent. Does not reboot and does not restart services.
    Does not use credentials. Blank text fields print as n/a. Wear and
    power-on hours of 0 stay JSON null because Windows uses 0 when a drive
    does not report them. The last stdout line is EXITCODE: N. Tactical
    ad-hoc command output does not show the process exit code.

    Exit codes:
      0  Inventory was collected, including model and serial number.
      1  Inventory was collected, but model or serial number is missing.
      2  Inventory could not be collected.

.EXAMPLE
    .\Get-HardwareInventory.ps1
#>
#Requires -Version 5.1
[CmdletBinding()]
param()

function Test-HiWindowsHost {
    $variable = Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue
    if ($null -eq $variable) {
        return $true
    }
    return [bool]$variable.Value
}

function Write-HiResult {
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

function Format-HiTrim {
    param($Value)

    if ($null -eq $Value) {
        return ''
    }
    return ([string]$Value).Trim()
}

function Format-HiText {
    param($Value)

    $text = Format-HiTrim -Value $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return 'n/a'
    }
    return $text
}

function Format-HiSerial {
    param($Value)

    $text = Format-HiTrim -Value $Value
    $text = ($text -replace '[\s\.]+$', '').Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ''
    }
    return $text
}

function ConvertTo-HiReportedCount {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }
    $text = Format-HiTrim -Value $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    $number = 0.0
    $style = [System.Globalization.NumberStyles]::Float
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if (-not [double]::TryParse($text, $style, $culture, [ref]$number)) {
        return $null
    }
    if ($number -le 0) {
        return $null
    }
    return $number
}

function Format-HiGb {
    param($Bytes)

    if ($null -eq $Bytes -or [string]::IsNullOrWhiteSpace([string]$Bytes)) {
        return $null
    }
    $number = [double]$Bytes / 1073741824
    return [math]::Round($number, 2)
}

function Format-HiTimestamp {
    param($Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    try {
        return ([datetime]$Value).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    } catch {
        return [string]$Value
    }
}

function Format-HiFormFactor {
    param($Value)

    $map = @{
        '8'  = 'DIMM'
        '12' = 'SODIMM'
        '0'  = 'Unknown'
    }
    $text = [string]$Value
    if ($map.ContainsKey($text)) {
        return [string]$map[$text]
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        return 'Unknown'
    }
    return $text
}

function ConvertTo-HiList {
    param($Items)

    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in @($Items)) {
        if ($null -ne $item) {
            $list.Add($item)
        }
    }
    # Windows PowerShell 5.1 returns $null from Write-Output -NoEnumerate
    # when this list is empty. The unary comma returns the list itself.
    return ,$list
}

function Get-HiChannelToken {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    if ($Text -match '(?i)Channel\s*([A-H])') {
        return $Matches[1].ToUpperInvariant()
    }
    if ($Text -match '(?i)\bDIMM[\s_\-]*([A-H])') {
        return $Matches[1].ToUpperInvariant()
    }
    if ($Text -match '(?i)\bBANK[\s_\-]*([A-H])') {
        return $Matches[1].ToUpperInvariant()
    }
    if ($Text -match '(?i)\b([A-H])\d\b') {
        return $Matches[1].ToUpperInvariant()
    }
    return $null
}

function Get-HiMemoryLayout {
    param($Modules)

    $list = @($Modules | Where-Object { $null -ne $_ })
    $tokens = @()
    foreach ($module in $list) {
        $token = Get-HiChannelToken -Text ([string]$module.DeviceLocator)
        if ($null -eq $token) {
            $token = Get-HiChannelToken -Text ([string]$module.BankLabel)
        }
        if ($null -ne $token) {
            $tokens += $token
        }
    }
    $distinct = @($tokens | Select-Object -Unique)
    $mode = 'Unknown'
    $basis = 'no channel labels were exposed'
    if ($distinct.Count -gt 0) {
        $mode = switch ($distinct.Count) {
            1 { 'Single' }
            2 { 'Dual' }
            3 { 'Triple' }
            4 { 'Quad' }
            6 { 'Hex' }
            8 { 'Octa' }
            default { '{0}-channel' -f $distinct.Count }
        }
        $basis = 'channel labels {0}' -f ($distinct -join ', ')
    } elseif ($list.Count -eq 1) {
        $mode = 'Single'
        $basis = 'one populated module'
    } elseif ($list.Count -eq 2) {
        $first = [uint64]0
        $second = [uint64]0
        [void][uint64]::TryParse([string]$list[0].CapacityBytes, [ref]$first)
        [void][uint64]::TryParse([string]$list[1].CapacityBytes, [ref]$second)
        if ($first -gt 0 -and $first -eq $second) {
            $mode = 'Dual'
            $basis = 'two equal modules and no channel labels'
        } else {
            $mode = 'Asymmetric'
            $basis = 'two unequal modules and no channel labels'
        }
    } elseif ($list.Count -eq 0) {
        $mode = 'Empty'
        $basis = 'no memory modules reported'
    }

    [pscustomobject]@{
        Mode      = $mode
        Basis     = $basis
        Populated = $list.Count
        Channels  = (ConvertTo-HiList -Items $distinct)
    }
}

function Get-HiQwMemorySize {
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

function Test-HiDedicatedGpu {
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

function Format-HiJsonString {
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

function Write-HiIndent {
    param(
        [System.Text.StringBuilder]$Builder,
        [int]$Level
    )

    [void]$Builder.Append("`n")
    if ($Level -gt 0) {
        [void]$Builder.Append(('  ' * $Level))
    }
}

function Write-HiJsonValue {
    param(
        [System.Text.StringBuilder]$Builder,
        $Value,
        [int]$Indent
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
        [void]$Builder.Append((Format-HiJsonString -Text $Value))
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
        [void]$Builder.Append((Format-HiJsonString -Text $candidate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')))
        return
    }
    if ($candidate -is [enum]) {
        [void]$Builder.Append((Format-HiJsonString -Text ([string]$candidate)))
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
        if ($dictionary.Count -eq 0) {
            [void]$Builder.Append('{}')
            return
        }
        [void]$Builder.Append('{')
        $index = 0
        foreach ($key in @($dictionary.Keys)) {
            if ($index -gt 0) {
                [void]$Builder.Append(',')
            }
            Write-HiIndent -Builder $Builder -Level ($Indent + 1)
            [void]$Builder.Append((Format-HiJsonString -Text ([string]$key)))
            [void]$Builder.Append(': ')
            Write-HiJsonValue -Builder $Builder -Value $dictionary[$key] -Indent ($Indent + 1)
            $index++
        }
        Write-HiIndent -Builder $Builder -Level $Indent
        [void]$Builder.Append('}')
        return
    }

    $list = $candidate -as [System.Collections.IList]
    if ($null -ne $list -and -not ($candidate -is [string])) {
        if ($list.Count -eq 0) {
            [void]$Builder.Append('[]')
            return
        }
        [void]$Builder.Append('[')
        for ($index = 0; $index -lt $list.Count; $index++) {
            if ($index -gt 0) {
                [void]$Builder.Append(',')
            }
            Write-HiIndent -Builder $Builder -Level ($Indent + 1)
            Write-HiJsonValue -Builder $Builder -Value $list[$index] -Indent ($Indent + 1)
        }
        Write-HiIndent -Builder $Builder -Level $Indent
        [void]$Builder.Append(']')
        return
    }

    if ($Value -is [pscustomobject]) {
        $properties = @($Value.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' })
        if ($properties.Count -eq 0) {
            [void]$Builder.Append('{}')
            return
        }
        [void]$Builder.Append('{')
        $index = 0
        foreach ($property in $properties) {
            if ($index -gt 0) {
                [void]$Builder.Append(',')
            }
            Write-HiIndent -Builder $Builder -Level ($Indent + 1)
            [void]$Builder.Append((Format-HiJsonString -Text ([string]$property.Name)))
            [void]$Builder.Append(': ')
            Write-HiJsonValue -Builder $Builder -Value $property.Value -Indent ($Indent + 1)
            $index++
        }
        Write-HiIndent -Builder $Builder -Level $Indent
        [void]$Builder.Append('}')
        return
    }

    [void]$Builder.Append((Format-HiJsonString -Text ([string]$Value)))
}

function ConvertTo-HiJson {
    param($Value)

    $builder = New-Object System.Text.StringBuilder
    Write-HiJsonValue -Builder $builder -Value $Value -Indent 0
    [void]$builder.Append("`n")
    return $builder.ToString()
}

function Get-HiRegistryValue {
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

function Get-HiGpuRecord {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    $registry = @()
    try {
        $classKey = $base.OpenSubKey('SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}')
        if ($null -ne $classKey) {
            try {
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
                        $vram = Get-HiQwMemorySize -Values $values
                        $registry += [pscustomobject]@{
                            DriverDesc       = [string]$sub.GetValue('DriverDesc')
                            MatchingDeviceId = [string]$sub.GetValue('MatchingDeviceId')
                            Bytes            = $vram.Bytes
                            Source           = $vram.Source
                        }
                    } finally {
                        $sub.Close()
                    }
                }
            } finally {
                $classKey.Close()
            }
        }
    } finally {
        $base.Close()
    }

    $records = ConvertTo-HiList
    foreach ($controller in @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue)) {
        $name = [string]$controller.Name
        $pnp = [string]$controller.PNPDeviceID
        $match = $null
        foreach ($entry in $registry) {
            $idMatch = -not [string]::IsNullOrWhiteSpace($entry.MatchingDeviceId) -and $pnp.StartsWith($entry.MatchingDeviceId, [System.StringComparison]::OrdinalIgnoreCase)
            $nameMatch = -not [string]::IsNullOrWhiteSpace($name) -and $name -eq $entry.DriverDesc
            if ($idMatch -or $nameMatch) {
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
        $vramGb = $null
        if ($bytes -gt 0) {
            $vramGb = Format-HiGb -Bytes $bytes
        }
        $records.Add([pscustomobject]@{
            name          = (Format-HiText -Value $name)
            pnpDeviceId   = (Format-HiText -Value $pnp)
            dedicated     = (Test-HiDedicatedGpu -Name $name -PnpDeviceId $pnp)
            vramGB        = $vramGb
            vramSource    = (Format-HiText -Value $source)
            driverVersion = (Format-HiText -Value $controller.DriverVersion)
        })
    }
    return $records
}

function Get-HiDiskRecord {
    $records = ConvertTo-HiList
    $command = Get-Command -Name 'Get-PhysicalDisk' -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        foreach ($disk in @(Get-PhysicalDisk -ErrorAction Stop)) {
            $counter = $null
            try {
                $counter = $disk | Get-StorageReliabilityCounter -ErrorAction Stop
            } catch {
                $counter = $null
            }
            $powerOn = $null
            $wear = $null
            if ($null -ne $counter) {
                $powerOn = $counter.PowerOnHours
                $wear = $counter.Wear
            }
            $records.Add([pscustomobject]@{
                friendlyName  = Format-HiText -Value $disk.FriendlyName
                model         = Format-HiText -Value $disk.Model
                serialNumber  = Format-HiText -Value (Format-HiSerial -Value $disk.SerialNumber)
                sizeGB        = Format-HiGb -Bytes $disk.Size
                mediaType     = Format-HiText -Value $disk.MediaType
                busType       = Format-HiText -Value $disk.BusType
                healthStatus  = Format-HiText -Value $disk.HealthStatus
                firmware      = Format-HiText -Value $disk.FirmwareVersion
                powerOnHours  = ConvertTo-HiReportedCount -Value $powerOn
                wearPercent   = ConvertTo-HiReportedCount -Value $wear
            })
        }
        return $records
    }

    foreach ($disk in @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop)) {
        $records.Add([pscustomobject]@{
            friendlyName = Format-HiText -Value $disk.Caption
            model        = Format-HiText -Value $disk.Model
            serialNumber = Format-HiText -Value (Format-HiSerial -Value $disk.SerialNumber)
            sizeGB       = Format-HiGb -Bytes $disk.Size
            mediaType    = Format-HiText -Value $disk.MediaType
            busType      = Format-HiText -Value $disk.InterfaceType
            healthStatus = Format-HiText -Value $disk.Status
            firmware     = Format-HiText -Value $disk.FirmwareRevision
            powerOnHours = $null
            wearPercent  = $null
        })
    }
    return $records
}

function Invoke-HiMain {
    $script:ScExitCode = 2
    try {
        if (-not (Test-HiWindowsHost)) {
            Write-HiResult -Result Error -Summary 'This script must run on Windows.'
            return
        }

        $errors = New-Object System.Collections.Generic.List[string]
        $computer = $null
        $bios = $null
        $product = $null
        $board = $null
        $enclosure = $null
        $os = $null
        $processors = @()
        try {
            $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
            $product = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop
            $board = @(Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue) | Select-Object -First 1
            $enclosure = @(Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction SilentlyContinue) | Select-Object -First 1
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
        } catch {
            $errors.Add($_.Exception.Message)
        }

        $modules = @()
        $slotCount = $null
        try {
            $modules = @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop)
            $arrays = @(Get-CimInstance -ClassName Win32_PhysicalMemoryArray -ErrorAction SilentlyContinue)
            $slotTotal = 0
            $sawSlots = $false
            foreach ($array in $arrays) {
                $count = 0
                if ([int]::TryParse([string]$array.MemoryDevices, [ref]$count)) {
                    $slotTotal += $count
                    $sawSlots = $true
                }
            }
            if ($sawSlots) {
                $slotCount = $slotTotal
            }
        } catch {
            $errors.Add($_.Exception.Message)
        }

        $layoutInput = @()
        foreach ($module in $modules) {
            $layoutInput += [pscustomobject]@{
                DeviceLocator = [string]$module.DeviceLocator
                BankLabel     = [string]$module.BankLabel
                CapacityBytes = $module.Capacity
            }
        }
        $layout = Get-HiMemoryLayout -Modules $layoutInput
        $moduleRecords = ConvertTo-HiList
        foreach ($module in $modules) {
            $configured = $null
            $configuredProperty = $module.PSObject.Properties['ConfiguredClockSpeed']
            if ($null -ne $configuredProperty) {
                $configured = $configuredProperty.Value
            }
            $moduleRecords.Add([pscustomobject]@{
                bankLabel     = Format-HiText -Value $module.BankLabel
                deviceLocator = Format-HiText -Value $module.DeviceLocator
                capacityGB    = Format-HiGb -Bytes $module.Capacity
                speedMHz      = $module.Speed
                configuredMHz = $configured
                manufacturer  = Format-HiText -Value $module.Manufacturer
                partNumber    = Format-HiText -Value $module.PartNumber
                serialNumber  = Format-HiText -Value (Format-HiSerial -Value $module.SerialNumber)
                formFactor    = Format-HiText -Value (Format-HiFormFactor -Value $module.FormFactor)
            })
        }

        $gpuRecords = ConvertTo-HiList
        try {
            $gpuRecords = Get-HiGpuRecord
        } catch {
            $errors.Add($_.Exception.Message)
        }

        $diskRecords = ConvertTo-HiList
        try {
            $diskRecords = Get-HiDiskRecord
        } catch {
            $errors.Add($_.Exception.Message)
        }

        $cores = 0
        $logical = 0
        $clock = 0
        $width = 0
        $cpuName = ''
        $cpuVendor = ''
        foreach ($processor in $processors) {
            $coreCount = 0
            $logicalCount = 0
            $clockCount = 0
            $widthCount = 0
            [void][int]::TryParse([string]$processor.NumberOfCores, [ref]$coreCount)
            [void][int]::TryParse([string]$processor.NumberOfLogicalProcessors, [ref]$logicalCount)
            [void][int]::TryParse([string]$processor.MaxClockSpeed, [ref]$clockCount)
            [void][int]::TryParse([string]$processor.AddressWidth, [ref]$widthCount)
            $cores += $coreCount
            $logical += $logicalCount
            if ($clockCount -gt $clock) {
                $clock = $clockCount
            }
            if ($widthCount -gt $width) {
                $width = $widthCount
            }
            if ([string]::IsNullOrWhiteSpace($cpuName)) {
                $cpuName = Format-HiTrim -Value $processor.Name
                $cpuVendor = Format-HiTrim -Value $processor.Manufacturer
            }
        }

        $model = ''
        $serial = ''
        $manufacturer = ''
        if ($null -ne $computer) {
            $model = Format-HiTrim -Value $computer.Model
            $manufacturer = Format-HiTrim -Value $computer.Manufacturer
        }
        if ($null -ne $bios) {
            $serial = Format-HiSerial -Value $bios.SerialNumber
        }
        $asset = ''
        if ($null -ne $enclosure) {
            $asset = Format-HiTrim -Value $enclosure.SMBIOSAssetTag
        }
        $boardMaker = ''
        $boardProduct = ''
        $boardSerial = ''
        if ($null -ne $board) {
            $boardMaker = Format-HiTrim -Value $board.Manufacturer
            $boardProduct = Format-HiTrim -Value $board.Product
            $boardSerial = Format-HiTrim -Value $board.SerialNumber
        }
        $uuid = ''
        if ($null -ne $product) {
            $uuid = Format-HiTrim -Value $product.UUID
        }

        $displayVersion = [string](Get-HiRegistryValue -SubKey 'SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'DisplayVersion')
        $ubr = [string](Get-HiRegistryValue -SubKey 'SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'UBR')
        $osCaption = ''
        $osVersion = ''
        $osBuild = ''
        $osArch = ''
        $installDate = $null
        $productType = ''
        if ($null -ne $os) {
            $osCaption = [string]$os.Caption
            $osVersion = [string]$os.Version
            $osBuild = [string]$os.BuildNumber
            $osArch = [string]$os.OSArchitecture
            $installDate = Format-HiTimestamp -Value $os.InstallDate
            if ([string]$os.ProductType -eq '1') {
                $productType = 'Workstation'
            } elseif ([string]$os.ProductType -eq '2') {
                $productType = 'DomainController'
            } elseif ([string]$os.ProductType -eq '3') {
                $productType = 'Server'
            } else {
                $productType = [string]$os.ProductType
            }
        }

        $result = 'Pass'
        $summary = 'Inventory collected.'
        $exitCode = 0
        if ([string]::IsNullOrWhiteSpace($model) -or [string]::IsNullOrWhiteSpace($serial)) {
            $result = 'Fail'
            $summary = 'Inventory is missing the model or serial number needed for a warranty lookup.'
            $exitCode = 1
        }
        if ($null -eq $computer -and $null -eq $bios) {
            $result = 'Error'
            $summary = 'Inventory could not be collected.'
            $exitCode = 2
        }

        $totalGb = $null
        if ($null -ne $computer) {
            $totalGb = Format-HiGb -Bytes $computer.TotalPhysicalMemory
        }
        $domainJoined = $false
        $domain = ''
        $family = ''
        $sku = ''
        if ($null -ne $computer) {
            $domainJoined = [bool]$computer.PartOfDomain
            $domain = [string]$computer.Domain
            $family = Format-HiTrim -Value $computer.SystemFamily
            $sku = Format-HiTrim -Value $computer.SystemSKUNumber
        }

        $document = [pscustomobject]@{
            result         = $result
            summary        = $summary
            collectedAtUtc = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            computer       = [pscustomobject]@{
                name         = (Format-HiText -Value $env:COMPUTERNAME)
                manufacturer = (Format-HiText -Value $manufacturer)
                model        = (Format-HiText -Value $model)
                family       = (Format-HiText -Value $family)
                sku          = (Format-HiText -Value $sku)
                domain       = (Format-HiText -Value $domain)
                partOfDomain = $domainJoined
            }
            warranty       = [pscustomobject]@{
                manufacturer          = (Format-HiText -Value $manufacturer)
                model                 = (Format-HiText -Value $model)
                systemSku             = (Format-HiText -Value $sku)
                serialNumber          = (Format-HiText -Value $serial)
                assetTag              = (Format-HiText -Value $asset)
                biosVersion           = $(if ($null -eq $bios) { 'n/a' } else { Format-HiText -Value $bios.SMBIOSBIOSVersion })
                biosReleaseDate       = $(if ($null -eq $bios) { $null } else { Format-HiTimestamp -Value $bios.ReleaseDate })
                baseboardManufacturer = (Format-HiText -Value $boardMaker)
                baseboardProduct      = (Format-HiText -Value $boardProduct)
                baseboardSerial       = (Format-HiText -Value (Format-HiSerial -Value $boardSerial))
                uuid                  = (Format-HiText -Value $uuid)
                note                  = 'Identifiers only. Warranty status is not queried because vendor APIs need per-client credentials.'
            }
            cpu            = [pscustomobject]@{
                name               = (Format-HiText -Value $cpuName)
                manufacturer       = (Format-HiText -Value $cpuVendor)
                cores              = $cores
                logicalProcessors  = $logical
                maxClockMHz        = $clock
                addressWidth       = $width
                sockets            = @($processors).Count
            }
            memory         = [pscustomobject]@{
                totalGB     = $totalGb
                slots       = $slotCount
                populated   = $layout.Populated
                channelMode = $layout.Mode
                channelBasis = $layout.Basis
                modules     = $moduleRecords
            }
            gpus           = $gpuRecords
            disks          = $diskRecords
            os             = [pscustomobject]@{
                caption        = (Format-HiText -Value $osCaption)
                version        = (Format-HiText -Value $osVersion)
                build          = (Format-HiText -Value $osBuild)
                ubr            = (Format-HiText -Value $ubr)
                displayVersion = (Format-HiText -Value $displayVersion)
                architecture   = (Format-HiText -Value $osArch)
                installDate    = $installDate
                productType    = (Format-HiText -Value $productType)
            }
            errors         = (ConvertTo-HiList -Items @($errors))
        }

        Write-Output (ConvertTo-HiJson -Value $document)
        $script:ScExitCode = $exitCode
    } catch {
        Write-HiResult -Result Error -Summary $_.Exception.Message
        $script:ScExitCode = 2
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $script:ScExitCode = 2
    try {
        Invoke-HiMain | Out-Host
    } catch {
        Write-Output 'RESULT: Error' | Out-Host
        Write-Output ('Summary: {0}' -f $_.Exception.Message) | Out-Host
        $script:ScExitCode = 2
    }
    Write-Output ('EXITCODE: {0}' -f $script:ScExitCode) | Out-Host
    exit $script:ScExitCode
}
