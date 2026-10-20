BeforeAll {
    . (Join-Path $PSScriptRoot '../Test-GpuVram.ps1')
}

Describe 'GPU VRAM rules' {
    It 'prefers the qwMemorySize registry value over the hardware-information alias' {
        $values = @{
            'qwMemorySize' = [uint64]4294967296
            'HardwareInformation.qwMemorySize' = [uint64]2147483648
        }
        $vram = Get-GvQwMemorySize -Values $values
        $vram.Source | Should -Be 'qwMemorySize'
        $vram.Bytes | Should -Be ([uint64]4294967296)
    }

    It 'reads HardwareInformation.qwMemorySize when qwMemorySize is absent' {
        $values = @{ 'HardwareInformation.qwMemorySize' = [uint64]8589934592 }
        $vram = Get-GvQwMemorySize -Values $values
        $vram.Source | Should -Be 'HardwareInformation.qwMemorySize'
        $vram.Bytes | Should -Be ([uint64]8589934592)
    }

    It 'classifies dedicated and integrated adapters' {
        Test-GvDedicatedGpu -Name 'NVIDIA GeForce RTX 3060' -PnpDeviceId 'PCI\VEN_10DE&DEV_2504' | Should -BeTrue
        Test-GvDedicatedGpu -Name 'Intel(R) UHD Graphics 630' -PnpDeviceId 'PCI\VEN_8086&DEV_3E92' | Should -BeFalse
        Test-GvDedicatedGpu -Name 'Intel(R) Arc(TM) A770 Graphics' -PnpDeviceId 'PCI\VEN_8086&DEV_56A0' | Should -BeTrue
        Test-GvDedicatedGpu -Name 'AMD Radeon RX 570' -PnpDeviceId 'PCI\VEN_1002&DEV_67DF' | Should -BeTrue
        Test-GvDedicatedGpu -Name 'AMD Radeon(TM) Graphics' -PnpDeviceId 'PCI\VEN_1002&DEV_1638' | Should -BeFalse
        Test-GvDedicatedGpu -Name 'Microsoft Basic Display Adapter' -PnpDeviceId 'PCI\VEN_10DE&DEV_0000' | Should -BeFalse
    }

    It 'passes 4 GB and fails 2 GB after tenth-of-a-gigabyte rounding' {
        (Test-GvVramMinimum -Bytes ([uint64]4294967296) -MinVRAMGB 4).MeetsMinimum | Should -BeTrue
        (Test-GvVramMinimum -Bytes ([uint64]2147483648) -MinVRAMGB 4).MeetsMinimum | Should -BeFalse
    }

    It 'fails closed when no dedicated GPU is present' {
        $adapters = @(
            [pscustomobject]@{ Name = 'Intel(R) UHD Graphics'; Dedicated = $false; Bytes = [uint64]0; Source = $null }
        )
        $decision = Get-GvVramDecision -Adapters $adapters -MinVRAMGB 4
        $decision.ExitCode | Should -Be 1
        $decision.Summary | Should -Match 'No dedicated GPU'
    }

    It 'errors when dedicated VRAM cannot be read and passes the largest known card' {
        $unknown = @(
            [pscustomobject]@{ Name = 'NVIDIA GeForce GTX 1650'; Dedicated = $true; Bytes = [uint64]0; Source = $null }
        )
        (Get-GvVramDecision -Adapters $unknown -MinVRAMGB 4).ExitCode | Should -Be 2

        $cards = @(
            [pscustomobject]@{ Name = 'NVIDIA GeForce GTX 1650'; Dedicated = $true; Bytes = [uint64]4294967296; Source = 'qwMemorySize' }
            [pscustomobject]@{ Name = 'NVIDIA GeForce RTX 3060'; Dedicated = $true; Bytes = [uint64]12884901888; Source = 'HardwareInformation.qwMemorySize' }
        )
        $decision = Get-GvVramDecision -Adapters $cards -MinVRAMGB 4
        $decision.ExitCode | Should -Be 0
        $decision.Summary | Should -Match 'RTX 3060'
    }

    It 'matches a display adapter to its registry key' {
        Test-GvDeviceMatch -PnpDeviceId 'PCI\VEN_10DE&DEV_2504&SUBSYS_1' -MatchingDeviceId 'PCI\VEN_10DE&DEV_2504' -Name 'NVIDIA' -DriverDesc 'Other' | Should -BeTrue
        Test-GvDeviceMatch -PnpDeviceId 'PCI\VEN_10DE&DEV_9999' -MatchingDeviceId 'PCI\VEN_1002' -Name 'Same' -DriverDesc 'Same' | Should -BeTrue
        Test-GvDeviceMatch -PnpDeviceId 'PCI\VEN_10DE&DEV_9999' -MatchingDeviceId '' -Name 'One' -DriverDesc 'Two' | Should -BeFalse
    }
}
