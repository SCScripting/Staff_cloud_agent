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

    It 'prints null counters as n/a and keeps a real zero' {
        Format-DhText -Value $null | Should -Be 'n/a'
        Format-DhText -Value '' | Should -Be 'n/a'
        Format-DhText -Value '   ' | Should -Be 'n/a'
        Format-DhText -Value 0 | Should -Be '0'
        Format-DhText -Value 4 | Should -Be '4'
    }

    It 'prints unreported wear as n/a and still passes wear of zero' {
        Format-DhWear -Wear $null | Should -Be 'n/a'
        Format-DhWear -Wear 0 | Should -Be 'n/a'
        Format-DhWear -Wear '0' | Should -Be 'n/a'
        Format-DhWear -Wear 12 | Should -Be '12'
        $result = Test-DhDiskState -HealthStatus 'Healthy' -OperationalStatus @('OK') -ReadErrorsUncorrected 0 -WriteErrorsUncorrected 0 -Wear 0 -ApplyWear $true -MaxWearPercent 90
        $result.Healthy | Should -BeTrue
    }

    It 'trims trailing dots and spaces from the serial' {
        Format-DhSerial -Serial 'CT500P3SSD8. ' | Should -Be 'CT500P3SSD8'
        Format-DhSerial -Serial '  ABC.  ' | Should -Be 'ABC'
        Format-DhSerial -Serial 'AB.C' | Should -Be 'AB.C'
        Format-DhSerial -Serial '...' | Should -Be 'n/a'
        Format-DhSerial -Serial $null | Should -Be 'n/a'
    }

    It 'falls back from missing power-on hours to a disk date, then an OS estimate' {
        $now = [datetime]'2026-01-15'
        $fromDisk = Format-DhAge -PowerOnHours 0 -ManufactureDate $null -Now $now -DiskInstallDate '2024-01-15' -OsInstallDate '2020-01-15'
        $fromDisk | Should -Match 'disk install date 2024-01-15'
        $fromDisk | Should -Not -Match 'estimated from OS'
        $fromDisk | Should -Not -Match 'power-on'

        $fromOs = Format-DhAge -PowerOnHours $null -ManufactureDate $null -Now $now -DiskInstallDate $null -OsInstallDate '2020-01-15'
        $fromOs | Should -Be 'estimated from OS install date 2020-01-15 (6 years ago)'

        $fromHours = Format-DhAge -PowerOnHours 100 -ManufactureDate $null -Now $now -DiskInstallDate '2024-01-15' -OsInstallDate '2020-01-15'
        $fromHours | Should -Match 'power-on 100 hours'
        $fromHours | Should -Not -Match 'estimated from OS'
        $fromHours | Should -Not -Match 'disk install date'
    }

    It 'uses reliability-counter hours and the disk install date when the cmdlet hours are missing' {
        $counter = [pscustomobject]@{ PowerOnHours = 0 }
        $cim = @(
            [pscustomobject]@{ DeviceId = '0'; PowerOnHours = 0 }
            [pscustomobject]@{ DeviceId = '1'; PowerOnHours = 1000 }
        )
        Resolve-DhPowerOnHour -Counter $counter -DeviceId '1' -CimCounter $cim | Should -Be 1000
        Resolve-DhPowerOnHour -Counter $counter -DeviceId '0' -CimCounter $cim | Should -BeNullOrEmpty
        Resolve-DhPowerOnHour -Counter ([pscustomobject]@{ PowerOnHours = 50 }) -DeviceId '1' -CimCounter $cim | Should -Be 50

        $drives = @(
            [pscustomobject]@{ SerialNumber = 'CT500P3SSD8. '; InstallDate = [datetime]'2022-06-01' }
        )
        $installed = Get-DhDiskInstallDate -Serial 'ct500p3ssd8' -DiskDrive $drives
        $installed | Should -Be ([datetime]'2022-06-01')
        Get-DhDiskInstallDate -Serial 'n/a' -DiskDrive $drives | Should -BeNullOrEmpty
    }
}
