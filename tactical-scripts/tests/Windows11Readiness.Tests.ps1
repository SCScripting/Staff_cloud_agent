BeforeAll {
    . (Join-Path $PSScriptRoot '../Test-Windows11Readiness.ps1')
}

Describe 'Windows 11 readiness rules' {
    It 'converts the 64 GB disk minimum without overflowing' {
        ConvertTo-WrByte -Gigabytes 64 | Should -Be 68719476736
    }

    It 'accepts supported Intel and AMD workstation CPUs' {
        (Test-WrCpuSupport -Name 'Intel(R) Core(TM) i5-10500 CPU @ 3.10GHz' -Cores 6 -AddressWidth 64 -MaxClockMHz 3100).Status | Should -Be 'Pass'
        (Test-WrCpuSupport -Name 'Intel(R) Core(TM) i5-1035G1 CPU @ 1.00GHz' -Cores 4 -AddressWidth 64 -MaxClockMHz 1000).Status | Should -Be 'Pass'
        (Test-WrCpuSupport -Name 'Intel(R) Core(TM) Ultra 7 155H' -Cores 16 -AddressWidth 64 -MaxClockMHz 1400).Status | Should -Be 'Pass'
        (Test-WrCpuSupport -Name 'AMD Ryzen 5 5600X 6-Core Processor' -Cores 6 -AddressWidth 64 -MaxClockMHz 3700).Status | Should -Be 'Pass'
    }

    It 'rejects old CPUs, 32-bit CPUs, and single-core CPUs' {
        (Test-WrCpuSupport -Name 'Intel(R) Core(TM) i7-7700 CPU @ 3.60GHz' -Cores 4 -AddressWidth 64 -MaxClockMHz 3600).Status | Should -Be 'Fail'
        (Test-WrCpuSupport -Name 'AMD Ryzen 5 1400 Quad-Core Processor' -Cores 4 -AddressWidth 64 -MaxClockMHz 3200).Status | Should -Be 'Fail'
        (Test-WrCpuSupport -Name 'Intel(R) Core(TM) i5-10500 CPU @ 3.10GHz' -Cores 6 -AddressWidth 32 -MaxClockMHz 3100).Status | Should -Be 'Fail'
        (Test-WrCpuSupport -Name 'Intel(R) Core(TM) i5-10500 CPU @ 3.10GHz' -Cores 1 -AddressWidth 64 -MaxClockMHz 3100).Status | Should -Be 'Fail'
    }

    It 'leaves uncommon Xeon and virtual CPUs for review' {
        (Test-WrCpuSupport -Name 'Intel(R) Xeon(R) CPU E5-2670 0 @ 2.60GHz' -Cores 8 -AddressWidth 64 -MaxClockMHz 2600).Status | Should -Be 'Review'
        (Test-WrCpuSupport -Name 'QEMU Virtual CPU' -Cores 2 -AddressWidth 64 -MaxClockMHz 2000).Status | Should -Be 'Review'
    }

    It 'requires TPM 2.0, UEFI, and Secure Boot' {
        (Get-WrTpmResult -Present $true -Ready $true -SpecVersion '2.0, 0, 1.38' -Manufacturer 'IFX').Status | Should -Be 'Pass'
        (Get-WrTpmResult -Present $true -Ready $true -SpecVersion '1.2, 2, 3' -Manufacturer 'IFX').Status | Should -Be 'Fail'
        (Get-WrTpmResult -Present $false -Ready $false -SpecVersion '' -Manufacturer '').Status | Should -Be 'Fail'
        (Get-WrFirmwareResult -FirmwareType 2).Status | Should -Be 'Pass'
        (Get-WrFirmwareResult -FirmwareType 1).Status | Should -Be 'Fail'
        (Get-WrSecureBootResult -Enabled $true -Known $true -ErrorMessage '').Status | Should -Be 'Pass'
        (Get-WrSecureBootResult -Enabled $false -Known $true -ErrorMessage '').Status | Should -Be 'Fail'
    }

    It 'accepts a 4 GB stick that reports slightly under 4 GiB' {
        $bytes = [uint64]4200000000
        (Get-WrMemoryResult -Bytes $bytes -MinRamGB 4).Status | Should -Be 'Pass'
        (Get-WrMemoryResult -Bytes ([uint64]3000000000) -MinRamGB 4).Status | Should -Be 'Fail'
    }

    It 'checks system disk size and free space in gibibytes' {
        (Get-WrDiskResult -Bytes (ConvertTo-WrByte -Gigabytes 64) -MinimumGB 64 -Label 'system volume').Status | Should -Be 'Pass'
        (Get-WrDiskResult -Bytes (ConvertTo-WrByte -Gigabytes 63) -MinimumGB 64 -Label 'system volume').Status | Should -Be 'Fail'
    }

    It 'does not fail servers or PCs that are already on Windows 11' {
        $checks = @(
            [pscustomobject]@{ Name = 'TPM'; Status = 'Fail'; Detail = 'missing' }
        )
        $server = Get-WrReadiness -IsServer $true -IsWindows11 $false -Checks $checks
        $already = Get-WrReadiness -IsServer $false -IsWindows11 $true -Checks $checks
        $client = Get-WrReadiness -IsServer $false -IsWindows11 $false -Checks $checks
        $server.ExitCode | Should -Be 0
        $already.ExitCode | Should -Be 0
        $already.Summary | Should -Match 'informational'
        $client.ExitCode | Should -Be 1
    }

    It 'detects Windows Server and Windows 11 from the caption and build' {
        Test-WrIsServer -Caption 'Microsoft Windows Server 2022 Standard' -ProductType 3 | Should -BeTrue
        Test-WrIsServer -Caption 'Microsoft Windows 10 Pro' -ProductType 1 | Should -BeFalse
        Test-WrIsWindows11 -Caption 'Microsoft Windows 11 Pro' -Build 22631 | Should -BeTrue
        Test-WrIsWindows11 -Caption 'Microsoft Windows Server 2025 Standard' -Build 26100 | Should -BeFalse
        Test-WrIsWindows11 -Caption 'Microsoft Windows 10 Pro' -Build 19045 | Should -BeFalse
    }
}
