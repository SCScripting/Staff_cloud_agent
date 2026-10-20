BeforeAll {
    . (Join-Path $PSScriptRoot '../Get-HardwareInventory.ps1')
}

Describe 'Hardware inventory' {
    It 'keeps a one-element array as JSON' {
        $disks = ConvertTo-HiList -Items @(
            [pscustomobject]@{ name = 'Samsung SSD' }
        )
        $document = [pscustomobject]@{
            result = 'Pass'
            ok     = $true
            note   = 'quote " and slash \'
            disks  = $disks
            empty  = (ConvertTo-HiList)
        }
        $json = ConvertTo-HiJson -Value $document
        $json | Should -Match '"disks": \['
        $json | Should -Match '"empty": \[\]'
        $parsed = $json | ConvertFrom-Json
        @($parsed.disks).Count | Should -Be 1
        $parsed.disks[0].name | Should -Be 'Samsung SSD'
        $parsed.ok | Should -BeTrue
        $parsed.note | Should -Match 'quote'
    }

    It 'describes memory channel layouts' {
        $dual = Get-HiMemoryLayout -Modules @(
            [pscustomobject]@{ DeviceLocator = 'ChannelA-DIMM0'; BankLabel = 'BANK 0'; CapacityBytes = 8GB }
            [pscustomobject]@{ DeviceLocator = 'ChannelB-DIMM0'; BankLabel = 'BANK 2'; CapacityBytes = 8GB }
        )
        $single = Get-HiMemoryLayout -Modules @(
            [pscustomobject]@{ DeviceLocator = 'DIMM 1'; BankLabel = ''; CapacityBytes = 16GB }
        )
        $guess = Get-HiMemoryLayout -Modules @(
            [pscustomobject]@{ DeviceLocator = 'DIMM 1'; BankLabel = ''; CapacityBytes = 8GB }
            [pscustomobject]@{ DeviceLocator = 'DIMM 2'; BankLabel = ''; CapacityBytes = 8GB }
        )
        $uneven = Get-HiMemoryLayout -Modules @(
            [pscustomobject]@{ DeviceLocator = 'DIMM 1'; BankLabel = ''; CapacityBytes = 8GB }
            [pscustomobject]@{ DeviceLocator = 'DIMM 2'; BankLabel = ''; CapacityBytes = 16GB }
        )
        $dual.Mode | Should -Be 'Dual'
        $single.Mode | Should -Be 'Single'
        $guess.Mode | Should -Be 'Dual'
        $uneven.Mode | Should -Be 'Asymmetric'
    }

    It 'reads qwMemorySize the same way as the GPU check' {
        $values = @{
            'qwMemorySize' = [uint64]4294967296
            'HardwareInformation.qwMemorySize' = [uint64]1
        }
        (Get-HiQwMemorySize -Values $values).Source | Should -Be 'qwMemorySize'
        Test-HiDedicatedGpu -Name 'NVIDIA GeForce RTX 3060' -PnpDeviceId 'PCI\VEN_10DE&DEV_2504' | Should -BeTrue
        Test-HiDedicatedGpu -Name 'Intel(R) UHD Graphics 630' -PnpDeviceId 'PCI\VEN_8086&DEV_3E92' | Should -BeFalse
    }

    It 'prints blank text as n/a and treats zero wear as unreported' {
        Format-HiText -Value $null | Should -Be 'n/a'
        Format-HiText -Value '   ' | Should -Be 'n/a'
        Format-HiText -Value 'OptiPlex' | Should -Be 'OptiPlex'
        Format-HiSerial -Value 'CT500P3SSD8. ' | Should -Be 'CT500P3SSD8'
        Format-HiSerial -Value '...' | Should -Be ''
        Format-HiText -Value (Format-HiSerial -Value '...') | Should -Be 'n/a'
        ConvertTo-HiReportedCount -Value 0 | Should -BeNullOrEmpty
        ConvertTo-HiReportedCount -Value $null | Should -BeNullOrEmpty
        ConvertTo-HiReportedCount -Value 12 | Should -Be 12
    }
}
