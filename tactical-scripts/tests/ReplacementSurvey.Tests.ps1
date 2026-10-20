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

        $nuc = Get-RsFormFactor -ChassisType 3 -Model 'Intel NUC 12'
        $nuc.Size | Should -Be 'Small'

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
