BeforeAll {
    . (Join-Path $PSScriptRoot '../Get-DiskHealth.ps1')
}

Describe 'Disk health rules' {
    It 'passes a healthy SSD with no uncorrected errors' {
        $result = Test-DhDiskState -HealthStatus 'Healthy' -OperationalStatus @('OK') -ReadErrorsUncorrected 0 -WriteErrorsUncorrected 0 -Wear 10 -ApplyWear $true -MaxWearPercent 90
        $result.Healthy | Should -BeTrue
    }

    It 'fails uncorrected read errors' {
        $result = Test-DhDiskState -HealthStatus 'Healthy' -OperationalStatus @('OK') -ReadErrorsUncorrected 4 -WriteErrorsUncorrected 0 -Wear 1 -ApplyWear $true -MaxWearPercent 90
        $result.Healthy | Should -BeFalse
        $result.Reasons -join ' ' | Should -Match 'uncorrected read errors'
    }

    It 'fails warning health and predictive failure' {
        $result = Test-DhDiskState -HealthStatus 'Warning' -OperationalStatus @('OK', 'Predictive Failure') -ReadErrorsUncorrected 0 -WriteErrorsUncorrected 0 -Wear $null -ApplyWear $false -MaxWearPercent 90
        $result.Healthy | Should -BeFalse
        ($result.Reasons -join ' ') | Should -Match 'HealthStatus'
        ($result.Reasons -join ' ') | Should -Match 'Predictive Failure'
    }

    It 'applies wear only to SSDs and only at the threshold' {
        $under = Test-DhDiskState -HealthStatus 'Healthy' -OperationalStatus @('OK') -ReadErrorsUncorrected 0 -WriteErrorsUncorrected 0 -Wear 89 -ApplyWear $true -MaxWearPercent 90
        $at = Test-DhDiskState -HealthStatus 'Healthy' -OperationalStatus @('OK') -ReadErrorsUncorrected 0 -WriteErrorsUncorrected 0 -Wear 90 -ApplyWear $true -MaxWearPercent 90
        $hdd = Test-DhDiskState -HealthStatus 'Healthy' -OperationalStatus @('OK') -ReadErrorsUncorrected 0 -WriteErrorsUncorrected 0 -Wear 100 -ApplyWear $false -MaxWearPercent 90
        $under.Healthy | Should -BeTrue
        $at.Healthy | Should -BeFalse
        $hdd.Healthy | Should -BeTrue
    }

    It 'skips USB disks unless removable disks are included' {
        Test-DhDiskInScope -BusType 'USB' -IncludeRemovable $false | Should -BeFalse
        Test-DhDiskInScope -BusType 'NVMe' -IncludeRemovable $false | Should -BeTrue
        Test-DhDiskInScope -BusType 'USB' -IncludeRemovable $true | Should -BeTrue
    }

    It 'classifies HDD, SSD, and NVMe media' {
        Get-DhMediaKind -MediaType 'SSD' -SpindleSpeed 0 -BusType 'SATA' | Should -Be 'SSD'
        Get-DhMediaKind -MediaType 'HDD' -SpindleSpeed 7200 -BusType 'SATA' | Should -Be 'HDD'
        Get-DhMediaKind -MediaType 'Unspecified' -SpindleSpeed 0 -BusType 'NVMe' | Should -Be 'SSD'
        $media = Convert-DhMediaType -MediaType 4
        $bus = Convert-DhBusType -BusType 17
        Get-DhMediaKind -MediaType $media -SpindleSpeed 0 -BusType $bus | Should -Be 'SSD'
    }

    It 'maps storage enumeration values' {
        Convert-DhBusType -BusType 17 | Should -Be 'NVMe'
        Convert-DhHealthStatus -HealthStatus 1 | Should -Be 'Warning'
        (Convert-DhOperationalStatus -Value @(2, 5)) -join ',' | Should -Be 'OK,Predictive Failure'
    }

    It 'formats power-on age and manufacture date' {
        $text = Format-DhAge -PowerOnHours 17520 -ManufactureDate '2024-01-15' -Now ([datetime]'2026-01-15')
        $text | Should -Match '17520 hours'
        $text | Should -Match '2 years'
        $text | Should -Match '2024-01-15'
    }
}
