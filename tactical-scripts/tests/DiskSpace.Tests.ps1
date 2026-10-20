BeforeAll {
    . (Join-Path $PSScriptRoot '../Test-DiskSpace.ps1')
}

Describe 'Disk space rules' {
    It 'converts gigabytes without overflowing' {
        ConvertTo-DsByte -Gigabytes 64 | Should -Be 68719476736
    }

    It 'passes free space at the threshold and fails below it' {
        $exact = Test-DsFreeSpace -SizeBytes 1000 -FreeBytes 150 -MinFreePercent 15
        $low = Test-DsFreeSpace -SizeBytes 1000 -FreeBytes 149 -MinFreePercent 15
        $exact.Sufficient | Should -BeTrue
        $low.Sufficient | Should -BeFalse
        $exact.FreePercent | Should -Be 15
    }

    It 'selects a requested drive and skips small volumes by default' {
        Test-DsVolumeSelected -DeviceId 'C:' -SizeBytes 10GB -RequestedLetter 'C' -MinVolumeGB 20 | Should -BeTrue
        Test-DsVolumeSelected -DeviceId 'D:' -SizeBytes 10GB -RequestedLetter 'C' -MinVolumeGB 20 | Should -BeFalse
        Test-DsVolumeSelected -DeviceId 'D:' -SizeBytes (5GB) -RequestedLetter $null -MinVolumeGB 20 | Should -BeFalse
        Test-DsVolumeSelected -DeviceId 'D:' -SizeBytes (40GB) -RequestedLetter $null -MinVolumeGB 20 | Should -BeTrue
    }

    It 'rejects a drive letter that is not one character' {
        { Resolve-DsDriveLetter -Value 'CDE' } | Should -Throw
        Resolve-DsDriveLetter -Value 'c:' | Should -Be 'C'
        Resolve-DsDriveLetter -Value '' | Should -BeNullOrEmpty
    }
}
