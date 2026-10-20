BeforeAll {
    . (Join-Path $PSScriptRoot '../Get-ReplacementSurvey.ps1')
}

Describe 'Replacement survey mapping' {
    It 'maps chassis codes and lets a model hint override a desktop chassis' {
        (ConvertTo-RsChassisName -ChassisType 7).Size | Should -Be 'Large'
        (ConvertTo-RsChassisName -ChassisType 7).Name | Should -Be 'Tower'
        (ConvertTo-RsChassisName -ChassisType 4).Size | Should -Be 'Medium'
        (ConvertTo-RsChassisName -ChassisType 4).Name | Should -Be 'SFF'
        (ConvertTo-RsChassisName -ChassisType 13).Size | Should -Be 'All-in-one'
        (ConvertTo-RsChassisName -ChassisType 23).Size | Should -Be 'Rack server'
        (ConvertTo-RsChassisName -ChassisType 9).Size | Should -Be 'Laptop'
        (ConvertTo-RsChassisName -ChassisType 35).Size | Should -Be 'Small'
        (ConvertTo-RsChassisName -ChassisType 35).Name | Should -Be 'Mini PC'

        (ConvertTo-RsChassisName -ChassisType 36).Size | Should -Be 'Small'
        (ConvertTo-RsChassisName -ChassisType 36).Name | Should -Be 'Stick PC'

        $nuc = Get-RsFormFactor -ChassisType 3 -Model 'Intel NUC 12'
        $nuc.Size | Should -Be 'Small'
        $nuc.name | Should -Be 'Mini PC'

        $eq = Get-RsFormFactor -ChassisType 3 -Model 'EQ'
        $eq.size | Should -Be 'Small'
        $eq.name | Should -Be 'Mini PC'
        $eq.detail | Should -Match 'model indicates Small'

        $compact = Get-RsFormFactor -ChassisType 3 -Model 'AZW' -WidthInch 5 -HeightInch 1.9 -DepthInch 5
        $compact.size | Should -Be 'Small'
        $compact.name | Should -Be 'Mini PC'
        $compact.detail | Should -Match 'dimensions indicate Small'

        $sff = Get-RsFormFactor -ChassisType 3 -Model 'OptiPlex' -WidthInch 3.7 -HeightInch 11.5 -DepthInch 11.4
        $sff.size | Should -Be 'Medium'

        $tower = Get-RsFormFactor -ChassisType 6 -Model 'Mini Tower'
        $tower.size | Should -Be 'Large'

        $laptop = Get-RsFormFactor -ChassisType 9 -Model 'Intel NUC 12'
        $laptop.Size | Should -Be 'Laptop'
    }

    It 'names display outputs and estimates known GPU port layouts' {
        ConvertTo-RsVideoOutput -Value 5 | Should -Be 'HDMI'
        ConvertTo-RsVideoOutput -Value 0 | Should -Be 'VGA'
        ConvertTo-RsVideoOutput -Value 9 | Should -Be 'DisplayPort'
        ConvertTo-RsVideoOutput -Value 2147483648 | Should -Be 'Internal'
        ConvertTo-RsVideoOutput -Value $null | Should -Be 'n/a'

        $t1000 = Get-RsGpuOutputEstimate -Name 'NVIDIA T1000'
        $t1000.Estimated | Should -BeTrue
        (Format-RsEstimatedPort -Estimate $t1000) | Should -Be 'mini DisplayPort x4'

        $uhd = Get-RsGpuOutputEstimate -Name 'Intel(R) UHD Graphics 770'
        $uhd.Estimated | Should -BeFalse
    }

    It 'converts panel size and prefers the first EDID timing descriptor' {
        Get-RsPanelInch -WidthCm 53 -HeightCm 30 | Should -Be 24

        $block = New-Object byte[] 128
        $block[54] = 1
        $block[55] = 1
        $block[56] = 0x80
        $block[58] = 0x70
        $block[59] = 0x38
        $block[61] = 0x40
        Get-RsEdidResolution -Block $block | Should -Be '1920x1080'

        $skipped = New-Object byte[] 128
        $skipped[54] = 0
        $skipped[55] = 0
        $skipped[72] = 1
        $skipped[73] = 1
        $skipped[74] = 0x80
        $skipped[76] = 0x70
        $skipped[77] = 0x38
        $skipped[79] = 0x40
        Get-RsEdidResolution -Block $skipped | Should -Be '1920x1080'
    }

    It 'estimates HP and Dell ship dates and leaves Lenovo serials alone' {
        $now = Get-Date -Year 2026 -Month 10 -Day 20
        (ConvertTo-RsWeekDate -Year 2023 -Week 1).ToString('yyyy-MM-dd') | Should -Be '2023-01-01'
        (ConvertTo-RsWeekDate -Year 2023 -Week 2).ToString('yyyy-MM-dd') | Should -Be '2023-01-08'
        $week48 = (ConvertTo-RsWeekDate -Year 2023 -Week 48).ToString('yyyy-MM-dd')

        $hp = Get-RsShipDateEstimate -Manufacturer 'HP' -Serial 'CND3480XYZ' -BiosReleaseDate $null -Now $now
        $hp | Should -Be ('estimated from HP serial {0} (week 48)' -f $week48)

        $dell = Get-RsShipDateEstimate -Manufacturer 'Dell Inc.' -Serial 'CN0ABCDEFGHI34812345678' -BiosReleaseDate $null -Now $now
        $dell | Should -Be ('estimated from Dell PPID {0} (week 48)' -f $week48)

        $lenovo = Get-RsShipDateEstimate -Manufacturer 'LENOVO' -Serial 'PF2ABCDE' -BiosReleaseDate '2024-05-01' -Now $now
        $lenovo | Should -Be 'estimated from SMBIOS BIOS release date 2024-05-01'
    }

    It 'classifies Wi-Fi, USB, memory, disks, links, GPUs, and printers' {
        ConvertTo-RsWifiStandard -Name 'Intel Wi-Fi 6E AX210' | Should -Be 'Wi-Fi 6E'
        ConvertTo-RsWifiStandard -Name 'Intel Wi-Fi 6 AX201' | Should -Be 'Wi-Fi 6'
        ConvertTo-RsWifiStandard -Name '802.11ac' | Should -Be 'Wi-Fi 5'

        ConvertTo-RsUsbGeneration -Name 'USB 3.1 eXtensible Host Controller' | Should -Be 'USB 3.x'
        ConvertTo-RsUsbGeneration -Name 'USB4 Root Router' | Should -Be 'USB4'
        ConvertTo-RsUsbGeneration -Name 'Intel(R) USB 3.0 eXtensible Host Controller' | Should -Be 'USB 3.x'
        ConvertTo-RsUsbGeneration -Name 'EHCI USB 2.0' | Should -Be 'USB 2.0'

        ConvertTo-RsMemoryType -Value 26 | Should -Be 'DDR4'
        ConvertTo-RsMaxRamGb -Kilobyte 67108864 | Should -Be 64
        ConvertTo-RsMaxRamGb -Kilobyte 0 | Should -Be $null

        Get-RsMediaKind -BusType 17 -Model 'Disk' | Should -Be 'NVMe'
        Get-RsMediaKind -MediaType 4 -Model 'Disk' | Should -Be 'SSD'
        Get-RsMediaKind -MediaType 3 -Model 'Disk' | Should -Be 'HDD'
        Get-RsMediaKind -MediaType 0 -Model 'CT500P3PSSD8 NVMe' | Should -Be 'NVMe'

        ConvertTo-RsLinkSpeed -BitsPerSecond 1000000000 | Should -Be '1 Gbps'

        Test-RsDedicatedGpu -Name 'NVIDIA GeForce RTX 3060' -PnpDeviceId 'PCI\VEN_10DE&DEV_2504' | Should -BeTrue
        Test-RsDedicatedGpu -Name 'Intel(R) UHD Graphics 770' -PnpDeviceId 'PCI\VEN_8086&DEV_4680' | Should -BeFalse
        Test-RsDedicatedGpu -Name 'Intel(R) Arc(TM) A380 Graphics' -PnpDeviceId 'PCI\VEN_8086&DEV_56A5' | Should -BeTrue

        Get-RsPrinterKind -PortName 'IP_192.168.1.20' -Network $false | Should -Be 'network'
        Get-RsPrinterKind -PortName 'USB001' -Network $false | Should -Be 'local'
        Get-RsPrinterKind -PortName 'USB001' -Network $true | Should -Be 'network'

        Format-RsSerial -Value 'To be filled by O.E.M.' | Should -Be 'n/a'
        Format-RsSerial -Value 'Default string' | Should -Be 'n/a'
        Format-RsSerial -Value 'ABC123.' | Should -Be 'ABC123'

        $vram = Get-RsQwMemorySize -Values @{
            'qwMemorySize' = [uint64]4294967296
            'HardwareInformation.qwMemorySize' = [uint64]2147483648
        }
        $vram.Source | Should -Be 'qwMemorySize'
        $vram.Bytes | Should -Be ([uint64]4294967296)
    }

    It 'matches dental software without labeling Ez3D-i as EzDent' {
        $found = Find-RsInstalledApp -Entry @(
            [pscustomobject]@{ DisplayName = 'Dentrix G7'; DisplayVersion = '17.0' }
            [pscustomobject]@{ DisplayName = 'Ez3D-i'; DisplayVersion = '5.1' }
            [pscustomobject]@{ DisplayName = 'Eaglesoft'; DisplayVersion = '21' }
        )
        $labels = New-Object System.Collections.Generic.List[string]
        foreach ($app in $found) {
            $labels.Add([string]$app.Label)
        }
        $labels | Should -Contain 'Dentrix'
        $labels | Should -Contain 'Ez3D-i'
        $labels | Should -Contain 'Eaglesoft'
        $labels | Should -Not -Contain 'EzDent'
        Test-RsImagingLabel -Label 'Ez3D-i' | Should -BeTrue
        Test-RsImagingLabel -Label 'Dentrix' | Should -BeFalse
    }

    It 'builds replacement notes from connected ports and imaging software' {
        $notes = @(Get-RsReplacementNote -VideoOutput @('HDMI') -ExternalMonitor 2 -VgaConnected $true -ComPort $true -Wifi $true -DedicatedGpu $true -ImagingSoftware $true -FormFactor 'Large' -BatteryHealth -1)
        $notes | Should -Contain 'Needs VGA output'
        $notes | Should -Contain 'Uses 2 monitors'
        $notes | Should -Contain 'Needs COM port'
        $notes | Should -Contain 'Needs WiFi'
        $notes | Should -Contain 'Dedicated GPU required (CBCT)'

        $present = @(Get-RsReplacementNote -DedicatedGpu $true -ImagingSoftware $false -BatteryHealth -1)
        $present | Should -Contain 'Dedicated GPU present'
        $present | Should -Not -Contain 'Dedicated GPU required (CBCT)'

        $plain = @(Get-RsReplacementNote -VideoOutput @('HDMI', 'DisplayPort') -ExternalMonitor 0 -VgaConnected $false -BatteryHealth -1)
        $plain | Should -Contain 'No special replacement flags'
        $plain | Should -Not -Contain 'Needs VGA output'
        $plain | Should -Not -Contain 'Needs Bluetooth'
    }

    It 'resolves the default survey folder and an OutputPath override' {
        $now = Get-Date -Year 2026 -Month 10 -Day 20
        $frontDesk = 'FRONT DESK'
        $front = 'FRONT'
        $files = Resolve-RsSurveyFile -ComputerName $frontDesk -Now $now -ProgramDataRoot 'C:\ProgramData'
        $files.JsonPath | Should -Be 'C:\ProgramData\StandardComputer\Survey\FRONT_DESK_20261020.json'
        $files.TextPath | Should -Be 'C:\ProgramData\StandardComputer\Survey\FRONT_DESK_20261020.txt'

        $named = Resolve-RsSurveyFile -OutputPath 'D:\Out\pc.json' -ComputerName $front -Now $now -ProgramDataRoot 'C:\ProgramData'
        $named.JsonPath | Should -Be 'D:\Out\pc.json'
        $named.TextPath | Should -Be 'D:\Out\pc.txt'

        $directory = Resolve-RsSurveyFile -OutputPath 'D:\Out' -ComputerName $frontDesk -Now $now -ProgramDataRoot 'C:\ProgramData'
        $directory.JsonPath | Should -Be 'D:\Out\FRONT_DESK_20261020.json'
        $directory.TextPath | Should -Be 'D:\Out\FRONT_DESK_20261020.txt'

        $slash = Resolve-RsSurveyFile -OutputPath 'D:\Out\' -ComputerName $frontDesk -Now $now -ProgramDataRoot 'C:\ProgramData'
        $slash.JsonPath | Should -Be 'D:\Out\FRONT_DESK_20261020.json'
        $slash.TextPath | Should -Be 'D:\Out\FRONT_DESK_20261020.txt'
    }

    It 'keeps a one-element list as a JSON array and prints the summary without EXITCODE' {
        $one = ConvertTo-RsList
        $one.Add([pscustomobject]@{ Name = 'Front' })
        $json = ConvertTo-RsJson -Value $one
        $json | Should -Be '[{"Name":"Front"}]'
        $json.Contains([Environment]::NewLine) | Should -BeFalse

        $empty = ConvertTo-RsList
        ConvertTo-RsJson -Value $empty | Should -Be '[]'

        $survey = [pscustomobject]@{
            computer = 'FRONT'
            time     = '2026-10-20T00:00:00'
            result   = 'Pass'
            summary  = 'Replacement survey collected.'
            note     = @('Needs VGA output')
        }
        $summary = Format-RsSummary -Survey $survey
        $summary | Should -Match 'Replacement survey'
        $summary | Should -Match 'Replacement notes'
        $summary | Should -Match 'Needs VGA output'
        $summary | Should -Not -Match 'EXITCODE'
    }
}

Describe 'Replacement survey Windows PowerShell 5.1 lists' {
    It 'keeps an empty list when Write-Output -NoEnumerate would return null' {
        foreach ($name in @('ConvertTo-RsList', 'Find-RsInstalledApp')) {
            $definition = (Get-Command -Name $name).Definition
            $code = @($definition -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
            $code | Should -Not -Match 'Write-Output\s+-NoEnumerate'
            $code | Should -Match 'return\s+,'
            # Windows PowerShell 5.1 turns that no-enumerate output of an empty
            # List[object] into $null, so .Add() throws. Force that result when
            # the function still uses it, including on PowerShell 7.
            $list = & $name
            if ($code -match 'Write-Output\s+-NoEnumerate') {
                $list = $null
            }
            { $list.Add([pscustomobject]@{ Name = 'row' }) } | Should -Not -Throw
            $list.Count | Should -BeGreaterThan 0
        }

        $empty = ConvertTo-RsList
        $null -eq $empty | Should -BeFalse
        $empty.Count | Should -Be 0
        ConvertTo-RsJson -Value $empty | Should -Be '[]'
    }
}

Describe 'Replacement survey null probes' {
    BeforeAll {
        if (-not (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue)) {
            function script:Get-CimInstance {
                [CmdletBinding()]
                param(
                    [string]$ClassName,
                    [string]$Namespace
                )

                # Linux CI has no CIM cmdlet. Tests mock this stub. The parameters
                # stay in the signature so the mock can filter on ClassName.
                if ([string]::IsNullOrWhiteSpace($ClassName) -and [string]::IsNullOrWhiteSpace($Namespace)) {
                    return $null
                }
                return $null
            }
        }
    }

    It 'turns a blank WMI monitor name into an empty string' {
        ConvertTo-RsAsciiWord -Value $null | Should -Be ''
        ConvertTo-RsAsciiWord -Value ([uint16[]]@(0, 0, 0)) | Should -Be ''
        ConvertTo-RsAsciiWord -Value ([uint16[]]@(65, 85, 79, 0, 0)) | Should -Be 'AUO'
        (Get-RsSectionError -Section 'monitors' -ErrorRecord $null) | Should -Be 'monitors: line 0: n/a'
    }

    It 'keeps collecting when CIM results are null and a monitor name is blank' {
        Mock Get-CimInstance -MockWith {
            param($ClassName)
            switch ($ClassName) {
                'Win32_ComputerSystem' {
                    return [pscustomobject]@{
                        Manufacturer        = 'HP'
                        Model               = 'HP EliteDesk 800 G6'
                        SystemSKUNumber     = 'SKU1'
                        PCSystemType        = 1
                        TotalPhysicalMemory = 17179869184
                        PartOfDomain        = $false
                        Workgroup           = 'WORKGROUP'
                        Domain              = 'WORKGROUP'
                    }
                }
                'Win32_BIOS' {
                    return [pscustomobject]@{
                        SerialNumber       = 'CND3480XYZ'
                        SMBIOSBIOSVersion  = 'R01'
                        ReleaseDate        = '2024-05-01'
                        SMBIOSMajorVersion = 3
                        SMBIOSMinorVersion = 2
                    }
                }
                'Win32_SystemEnclosure' {
                    return [pscustomobject]@{
                        ChassisTypes = 3
                        SerialNumber = 'CND3480XYZ'
                    }
                }
                'Win32_OperatingSystem' {
                    return [pscustomobject]@{
                        Caption      = 'Microsoft Windows 11 Pro'
                        BuildNumber  = '26100'
                        ProductType  = 1
                    }
                }
                'Win32_VideoController' {
                    return [pscustomobject]@{
                        Name        = 'Intel(R) UHD Graphics 770'
                        PNPDeviceID = $null
                    }
                }
                'WmiMonitorID' {
                    return [pscustomobject]@{
                        Active             = $true
                        InstanceName       = 'DISPLAY\AUO1234\5&123_0'
                        ManufacturerName   = [uint16[]]@(65, 85, 79, 0)
                        UserFriendlyName   = [uint16[]]@(0, 0, 0)
                        ProductCodeID      = [uint16[]]@(0, 0)
                        SerialNumberID     = [uint16[]]@(0, 0)
                        YearOfManufacture  = 0
                    }
                }
                default {
                    return $null
                }
            }
        }

        $survey = Get-RsCollectedSurvey -Now (Get-Date -Year 2026 -Month 10 -Day 20)
        $survey | Should -Not -BeNullOrEmpty
        $survey.result | Should -Be 'Pass'
        $survey.identity.manufacturer | Should -Be 'HP'
        $survey.monitor.count | Should -Be 1

        $model = 'missing'
        $make = 'missing'
        foreach ($item in $survey.monitor.item) {
            $model = [string]$item.model
            $make = [string]$item.make
        }
        $model | Should -Be 'n/a'
        $make | Should -Be 'AUO'

        $gpuName = 'missing'
        foreach ($gpu in $survey.display.gpu) {
            $gpuName = [string]$gpu.name
        }
        $gpuName | Should -Be 'Intel(R) UHD Graphics 770'

        $gpuProblem = @($survey.problem | Where-Object { $_ -like 'gpu: line *' })
        $gpuProblem.Count | Should -BeGreaterThan 0
        $gpuProblem[0] | Should -Match '^gpu: line [0-9]+: .+'
    }

    It 'records the section name and line when one probe throws' {
        Mock Get-CimInstance -MockWith {
            param($ClassName)
            switch ($ClassName) {
                'Win32_ComputerSystem' {
                    return [pscustomobject]@{
                        Manufacturer = 'Dell Inc.'
                        Model        = 'OptiPlex 7080'
                        PCSystemType = 1
                        PartOfDomain = $false
                        Workgroup    = 'WORKGROUP'
                    }
                }
                'Win32_OperatingSystem' {
                    return [pscustomobject]@{
                        Caption     = 'Microsoft Windows 10 Pro'
                        BuildNumber = '19045'
                        ProductType = 1
                    }
                }
                'Win32_Printer' {
                    return [pscustomobject]@{
                        Name     = 'Front Desk Laser'
                        PortName = 'USB001'
                        Network  = $false
                    }
                }
                default {
                    return $null
                }
            }
        }
        Mock Get-RsPrinterKind { throw 'printer method failed' }

        $survey = Get-RsCollectedSurvey -Now (Get-Date -Year 2026 -Month 10 -Day 20)
        $survey | Should -Not -BeNullOrEmpty
        $survey.identity.model | Should -Be 'OptiPlex 7080'
        $printerCount = 0
        foreach ($printer in $survey.printer) {
            $printerCount++
        }
        $printerCount | Should -Be 0
        $printerProblem = @($survey.problem | Where-Object { $_ -like 'printers: line *printer method failed*' })
        $printerProblem.Count | Should -Be 1
        $printerProblem[0] | Should -Match '^printers: line [0-9]+: printer method failed'
    }

    It 'prints EXITCODE and exits with that same code' {
        $path = Join-Path $PSScriptRoot '../Get-ReplacementSurvey.ps1'
        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -Match '\$code = \[int\]\$script:ScExitCode'
        $content | Should -Match 'SetShouldExit\(\$code\)'
        $content | Should -Match 'exit \$code'
    }
}

Describe 'Replacement survey accuracy' {
    BeforeAll {
        if (-not (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue)) {
            function script:Get-CimInstance {
                [CmdletBinding()]
                param(
                    [string]$ClassName,
                    [string]$Namespace
                )

                if ([string]::IsNullOrWhiteSpace($ClassName) -and [string]::IsNullOrWhiteSpace($Namespace)) {
                    return $null
                }
                return $null
            }
        }
    }

    It 'reads Intel generation from the NNth Gen label and from the model number' {
        $named = Get-RsIntelGeneration -Name '12th Gen Intel(R) Core(TM) i3-1220P'
        $named.Detail | Should -Be 'Intel Core generation 12'
        $named.Supported | Should -BeTrue

        (Get-RsIntelGeneration -Name 'Intel Core i3-1220P').Detail | Should -Be 'Intel Core generation 12'
        (Get-RsIntelGeneration -Name 'Intel(R) Core(TM) i7-8700 CPU @ 3.20GHz').Detail | Should -Be 'Intel Core generation 8'
        (Get-RsIntelGeneration -Name 'Intel Core i5-10400').Detail | Should -Be 'Intel Core generation 10'
        (Get-RsIntelGeneration -Name 'Intel Core i7-1165G7').Detail | Should -Be 'Intel Core generation 11'
        (Get-RsIntelGeneration -Name 'Intel Core i5-7400').Detail | Should -Be 'Intel Core generation 7'
        (Get-RsIntelGeneration -Name 'Intel(R) Core(TM) Ultra 7 155H').Detail | Should -Be 'Intel Core Ultra'
        (Get-RsIntelGeneration -Name 'Intel(R) Core(TM) Ultra 7 155H').Supported | Should -BeTrue

        $ready = Test-RsCpuSupport -Name '12th Gen Intel(R) Core(TM) i3-1220P' -Core 10 -AddressWidth 64 -MaxClockMHz 1500
        $ready.Status | Should -Be 'Pass'
        $ready.Detail | Should -Be 'Intel Core generation 12'

        $older = Test-RsCpuSupport -Name 'Intel Core i5-7400' -Core 4 -AddressWidth 64 -MaxClockMHz 3000
        $older.Status | Should -Be 'Fail'
    }

    It 'treats soldered LPDDR as not upgradeable and ignores a max below installed' {
        ConvertTo-RsMemoryType -Value 35 | Should -Be 'LPDDR5'
        ConvertTo-RsMemoryType -Value 30 | Should -Be 'LPDDR4'
        ConvertTo-RsMemoryType -Value 26 | Should -Be 'DDR4'

        Test-RsSolderedMemory -FormFactor 0 -MemoryType 35 | Should -BeTrue
        Test-RsSolderedMemory -FormFactor 8 -MemoryType 35 | Should -BeTrue
        Test-RsSolderedMemory -FormFactor 'Row of chips' -MemoryType 26 | Should -BeTrue
        Test-RsSolderedMemory -FormFactor 'Row-of-chips' -MemoryType 0 | Should -BeTrue
        Test-RsSolderedMemory -FormFactor 8 -MemoryType 26 | Should -BeFalse
        Test-RsSolderedMemory -FormFactor 11 -MemoryType 26 | Should -BeFalse

        Get-RsMemorySlotSummary -Populated 8 -Soldered 8 -SlotTotal 8 | Should -Be 'Soldered (not upgradeable)'
        Get-RsMemorySlotSummary -Populated 2 -Soldered 0 -SlotTotal 4 | Should -Be '2 of 4'

        Get-RsMemoryMaxText -MaxGb 24 -InstalledGb 23.8 -Soldered $true | Should -Be 'n/a'
        Get-RsMemoryMaxText -MaxGb 16 -InstalledGb 32 -Soldered $false | Should -Be 'n/a'
        Get-RsMemoryMaxText -MaxGb 64 -InstalledGb 32 -Soldered $false | Should -Be '64'
    }

    It 'prints no link for an unlinked NIC and keeps a real gigabit link' {
        ConvertTo-RsLinkSpeed -BitsPerSecond '9223372036854775807' | Should -Be 'no link'
        ConvertTo-RsLinkSpeed -BitsPerSecond 0 | Should -Be 'n/a'
        ConvertTo-RsLinkSpeed -BitsPerSecond 1000000000 | Should -Be '1 Gbps'
    }

    It 'names disk health 0 and maps a partition to its logical disk' {
        ConvertTo-RsDiskHealth -Value 0 | Should -Be 'Healthy'
        ConvertTo-RsDiskHealth -Value 1 | Should -Be 'Warning'
        ConvertTo-RsDiskHealth -Value 'OK' | Should -Be 'OK'

        $pathLink = Get-RsDiskLetterMap -Link @(
            [pscustomobject]@{
                Antecedent = 'Win32_DiskPartition.DeviceID="Disk #0, Partition #0"'
                Dependent  = 'Win32_LogicalDisk.DeviceID="C:"'
            }
        )
        $objectLink = Get-RsDiskLetterMap -Link @(
            [pscustomobject]@{
                Antecedent = [pscustomobject]@{ DeviceID = 'Disk #0, Partition #0' }
                Dependent  = [pscustomobject]@{ DeviceID = 'C:' }
            }
        )
        $free = @{ 'C:' = [uint64]10737418240 }
        Get-RsDiskFreeSpace -Index 0 -LetterMap $pathLink -VolumeFree $free -DiskCount 1 | Should -Be ([uint64]10737418240)
        Get-RsDiskFreeSpace -Index 0 -LetterMap $objectLink -VolumeFree $free -DiskCount 1 | Should -Be ([uint64]10737418240)
        Get-RsDiskFreeSpace -Index 'DISK-GUID' -LetterMap $objectLink -VolumeFree $free -DiskCount 1 | Should -Be ([uint64]10737418240)

        $blank = Get-RsDiskLetterMap -Link @([pscustomobject]@{ Antecedent = ''; Dependent = '' })
        Get-RsDiskFreeSpace -Index 0 -LetterMap $blank -VolumeFree $free -DiskCount 1 | Should -Be ([uint64]10737418240)
        Get-RsDiskFreeSpace -Index 0 -LetterMap $blank -VolumeFree $free -DiskCount 2 | Should -Be $null
    }

    It 'collapses duplicate placeholder monitors unless the outputs differ' {
        $hdmiA = [pscustomobject]@{
            make = 'BBY'; model = 'INSIGNIA-TV (made 2023)'; product = 'ABCD'; serial = '16843009'
            sizeInch = '49.7'; connection = 'HDMI'; resolution = '3840x2160'; outputKey = 'DISPLAY\BBY0A1B\1'
        }
        $hdmiB = [pscustomobject]@{
            make = 'BBY'; model = 'INSIGNIA-TV (made 2023)'; product = 'ABCD'; serial = '16843009'
            sizeInch = '49.7'; connection = 'HDMI'; resolution = '3840x2160'; outputKey = 'DISPLAY\BBY0A1B\2'
        }
        $collapsed = Select-RsUniqueMonitor -Monitor @($hdmiA, $hdmiB)
        $collapsed.Count | Should -Be 1
        $collapsed[0].serial | Should -Be '16843009 (placeholder)'
        Get-RsExternalMonitorCount -Monitor $collapsed.ToArray() | Should -Be 1

        $displayPort = [pscustomobject]@{
            make = 'BBY'; model = 'INSIGNIA-TV (made 2023)'; product = 'ABCD'; serial = 'CN123456'
            sizeInch = '49.7'; connection = 'DisplayPort'; resolution = '3840x2160'; outputKey = 'DISPLAY\BBY0A1B\3'
        }
        $hdmiReal = [pscustomobject]@{
            make = 'BBY'; model = 'INSIGNIA-TV (made 2023)'; product = 'ABCD'; serial = 'CN123456'
            sizeInch = '49.7'; connection = 'HDMI'; resolution = '3840x2160'; outputKey = 'DISPLAY\BBY0A1B\1'
        }
        (Select-RsUniqueMonitor -Monitor @($hdmiReal, $displayPort)).Count | Should -Be 2

        Test-RsPlaceholderSerial -Serial '16843009' | Should -BeTrue
        Test-RsPlaceholderSerial -Serial '01010101' | Should -BeTrue
        Test-RsPlaceholderSerial -Serial '00000000' | Should -BeTrue
        Test-RsPlaceholderSerial -Serial 'CN123456' | Should -BeFalse
        Format-RsMonitorSerial -Serial '' | Should -Be 'n/a'

        $one = @(Get-RsReplacementNote -ExternalMonitor 1 -BatteryHealth -1)
        $one | Should -Contain 'Uses 1 monitor'
        $one | Should -Not -Contain 'Uses 1 monitors'
    }

    It 'does not require a COM port for the built-in UART alone' {
        Test-RsBuiltInCom -PnpDeviceId 'ACPI\PNP0501\0' | Should -BeTrue
        Test-RsBuiltInCom -PnpDeviceId 'ACPI\PNP0500\0' | Should -BeTrue
        Test-RsComNeeded -Name 'COM1' -PnpDeviceId 'ACPI\PNP0501\0' | Should -BeFalse
        Test-RsComNeeded -Name 'USB Serial Device' -PnpDeviceId '' | Should -BeTrue
        Test-RsComNeeded -Name 'COM3' -PnpDeviceId 'USB\VID_0403&PID_6001\FTDI' | Should -BeTrue
        Test-RsComNeeded -Name 'COM1' -PnpDeviceId 'ACPI\PNP0501\0' -InUse $true | Should -BeTrue

        $biosOnly = @(Get-RsReplacementNote -ComPort $false -ExternalMonitor 0 -BatteryHealth -1)
        $biosOnly | Should -Not -Contain 'Needs COM port'
        $needed = @(Get-RsReplacementNote -ComPort $true -ExternalMonitor 0 -BatteryHealth -1)
        $needed | Should -Contain 'Needs COM port'
    }

    It 'collects the TV04 readings without the false failures' {
        Mock Get-CimInstance -MockWith {
            param($ClassName)
            switch ($ClassName) {
                'Win32_ComputerSystem' {
                    return [pscustomobject]@{
                        Manufacturer        = 'AZW'
                        Model               = 'EQ'
                        SystemSKUNumber     = 'SKU'
                        PCSystemType        = 1
                        TotalPhysicalMemory = 25555000000
                        PartOfDomain        = $false
                        Workgroup           = 'WORKGROUP'
                        Domain              = 'WORKGROUP'
                    }
                }
                'Win32_BIOS' {
                    return [pscustomobject]@{
                        SerialNumber       = 'Y12204LH60189'
                        SMBIOSBIOSVersion  = 'EQI12204'
                        ReleaseDate        = '2024-06-27'
                        SMBIOSMajorVersion = 3
                        SMBIOSMinorVersion = 6
                    }
                }
                'Win32_SystemEnclosure' {
                    return [pscustomobject]@{ ChassisTypes = 35; SerialNumber = 'Y12204LH60189' }
                }
                'Win32_OperatingSystem' {
                    return [pscustomobject]@{
                        Caption     = 'Microsoft Windows 11 Pro'
                        BuildNumber = '26100'
                        ProductType = 1
                    }
                }
                'Win32_Processor' {
                    return [pscustomobject]@{
                        Name                        = '12th Gen Intel(R) Core(TM) i3-1220P'
                        NumberOfCores               = 10
                        NumberOfLogicalProcessors   = 12
                        MaxClockSpeed               = 1500
                        AddressWidth                = 64
                    }
                }
                'Win32_PhysicalMemoryArray' {
                    return [pscustomobject]@{ MemoryDevices = 8; MaxCapacity = 25165824; MaxCapacityEx = $null }
                }
                'Win32_PhysicalMemory' {
                    Write-Output ([pscustomobject]@{
                        DeviceLocator = 'Controller0-ChannelA'; Capacity = 3221225472; SMBIOSMemoryType = 35; FormFactor = 0; Speed = 5200
                    })
                    Write-Output ([pscustomobject]@{
                        DeviceLocator = 'Controller0-ChannelB'; Capacity = 3221225472; SMBIOSMemoryType = 35; FormFactor = 0; Speed = 5200
                    })
                    return
                }
                'MSFT_PhysicalDisk' {
                    return [pscustomobject]@{
                        DeviceId     = '0'
                        FriendlyName = 'CT500P3SSD8'
                        Size         = 500000000000
                        BusType      = 17
                        MediaType    = 4
                        HealthStatus = 0
                        SerialNumber = '0000_0000_0000_0001.'
                    }
                }
                'Win32_LogicalDisk' {
                    return [pscustomobject]@{ DeviceID = 'C:'; DriveType = 3; Size = 499000000000; FreeSpace = 10737418240 }
                }
                'Win32_LogicalDiskToPartition' {
                    return [pscustomobject]@{
                        Antecedent = [pscustomobject]@{ DeviceID = 'Disk #0, Partition #0' }
                        Dependent  = [pscustomobject]@{ DeviceID = 'C:' }
                    }
                }
                'Win32_NetworkAdapter' {
                    Write-Output ([pscustomobject]@{ Name = 'Realtek PCIe GbE Family Controller'; AdapterType = 'Ethernet'; Speed = 1000000000; MACAddress = 'E8:FF:1E:D4:E3:38' })
                    Write-Output ([pscustomobject]@{ Name = 'Realtek PCIe GbE Family Controller #2'; AdapterType = 'Ethernet'; Speed = '9223372036854775807'; MACAddress = 'E8:FF:1E:D4:E3:37' })
                    Write-Output ([pscustomobject]@{ Name = 'Intel(R) Wi-Fi 6 AX101'; AdapterType = 'Wireless'; Speed = 0; MACAddress = 'E0:8F:4C:79:16:A7' })
                    return
                }
                'Win32_SerialPort' {
                    return [pscustomobject]@{ DeviceID = 'COM1'; PNPDeviceID = 'ACPI\PNP0501\0' }
                }
                'WmiMonitorConnectionParams' {
                    Write-Output ([pscustomobject]@{ InstanceName = 'DISPLAY\BBY0A1B\1&111_0'; VideoOutputTechnology = 5 })
                    Write-Output ([pscustomobject]@{ InstanceName = 'DISPLAY\BBY0A1B\2&222_0'; VideoOutputTechnology = 5 })
                    return
                }
                'WmiMonitorID' {
                    $name = [uint16[]]@(73, 78, 83, 73, 71, 78, 73, 65, 45, 84, 86, 0)
                    $make = [uint16[]]@(66, 66, 89, 0)
                    $product = [uint16[]]@(65, 66, 67, 68, 0)
                    $serial = [uint16[]]@(49, 54, 56, 52, 51, 48, 48, 57, 0)
                    Write-Output ([pscustomobject]@{
                        Active = $true; InstanceName = 'DISPLAY\BBY0A1B\1&111_0'; ManufacturerName = $make
                        UserFriendlyName = $name; ProductCodeID = $product; SerialNumberID = $serial; YearOfManufacture = 2023
                    })
                    Write-Output ([pscustomobject]@{
                        Active = $true; InstanceName = 'DISPLAY\BBY0A1B\2&222_0'; ManufacturerName = $make
                        UserFriendlyName = $name; ProductCodeID = $product; SerialNumberID = $serial; YearOfManufacture = 2023
                    })
                    return
                }
                default { return $null }
            }
        }

        $survey = Get-RsCollectedSurvey -Now (Get-Date -Year 2026 -Month 10 -Day 20)
        $survey.result | Should -Be 'Pass'
        [string]$survey.cpu[0].readiness | Should -Be 'Pass: Intel Core generation 12'
        $survey.memory.slots | Should -Be 'Soldered (not upgradeable)'
        $survey.memory.max | Should -Be 'n/a'
        [string]$survey.memory.dimm[0].type | Should -Be 'LPDDR5'
        [string]$survey.storage.disk[0].health | Should -Be 'Healthy'
        [string]$survey.storage.disk[0].free | Should -Be '10'
        [string]$survey.storage.disk[0].health | Should -Not -Be '0'
        $speeds = New-Object System.Collections.Generic.List[string]
        foreach ($adapter in $survey.network.ethernet) {
            $speeds.Add([string]$adapter.speed)
        }
        $speeds | Should -Contain '1 Gbps'
        $speeds | Should -Contain 'no link'
        $survey.monitor.count | Should -Be 1
        $survey.monitor.external | Should -Be 1
        [string]$survey.monitor.item[0].serial | Should -Be '16843009 (placeholder)'
        $survey.port.com | Should -Be 'COM1'
        $survey.note | Should -Contain 'Uses 1 monitor'
        $survey.note | Should -Not -Contain 'Needs COM port'
        $survey.os.readiness | Should -Not -Match 'CPU'
    }
}
