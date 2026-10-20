BeforeAll {
    . (Join-Path $PSScriptRoot '../Test-PendingReboot.ps1')
    . (Join-Path $PSScriptRoot '../Get-WindowsUpdateStatus.ps1')
    . (Join-Path $PSScriptRoot '../Test-ImagingBridge.ps1')
    . (Join-Path $PSScriptRoot '../Get-LocalAdminAudit.ps1')
}

Describe 'Pending reboot' {
    It 'passes when every signal is clear' {
        $state = Test-PrRebootPendingState -ComponentBasedServicing $false -WindowsUpdate $false -PendingFileRename $false -ComputerRename $false
        $state.Pending | Should -BeFalse
    }

    It 'fails when any reboot signal is set' {
        $state = Test-PrRebootPendingState -ComponentBasedServicing $false -WindowsUpdate $true -PendingFileRename $true -ComputerRename $false
        $state.Pending | Should -BeTrue
        ($state.Reasons -join ', ') | Should -Match 'Windows Update'
        ($state.Reasons -join ', ') | Should -Match 'pending file rename'
    }
}

Describe 'Windows Update compliance' {
    It 'ignores definition updates' {
        Test-WuDefinitionUpdate -Title 'Security Intelligence Update for Microsoft Defender Antivirus' -CategoryNames @() | Should -BeTrue
        Test-WuDefinitionUpdate -Title '2026-10 Cumulative Update' -CategoryNames @('Definition Updates') | Should -BeTrue
        Test-WuDefinitionUpdate -Title '2026-10 Cumulative Update for Windows 11' -CategoryNames @('Security Updates') | Should -BeFalse
    }

    It 'keeps the newest successful quality install' {
        $entries = @(
            [pscustomobject]@{ Operation = 1; ResultCode = 2; Title = 'Security Intelligence Update'; Date = [datetime]'2026-10-19'; Categories = @() }
            [pscustomobject]@{ Operation = 1; ResultCode = 4; Title = 'Failed cumulative'; Date = [datetime]'2026-10-18'; Categories = @() }
            [pscustomobject]@{ Operation = 1; ResultCode = 2; Title = '2026-09 Cumulative Update'; Date = [datetime]'2026-09-12'; Categories = @('Security Updates') }
        )
        $last = Get-WuLastQualityInstall -Entries $entries
        $last.Title | Should -Be '2026-09 Cumulative Update'
    }

    It 'fails stale or pending quality updates' {
        $now = [datetime]'2026-10-20T00:00:00Z'
        $stale = Get-WuCompliance -LastInstall ([datetime]'2026-08-01') -PendingCount 0 -MaxPending 0 -MaxDaysSinceInstall 45 -Now $now
        $pending = Get-WuCompliance -LastInstall ([datetime]'2026-10-01') -PendingCount 2 -MaxPending 0 -MaxDaysSinceInstall 45 -Now $now
        $ok = Get-WuCompliance -LastInstall ([datetime]'2026-10-01') -PendingCount 0 -MaxPending 0 -MaxDaysSinceInstall 45 -Now $now
        $stale.Compliant | Should -BeFalse
        $pending.Compliant | Should -BeFalse
        $ok.Compliant | Should -BeTrue
    }

    It 'parses the Windows Update registry timestamp' {
        (Convert-WuRegistryTime -Text '2026-10-01 12:30:00').ToString('yyyy-MM-dd HH:mm:ss') | Should -Be '2026-10-01 12:30:00'
        Convert-WuRegistryTime -Text '' | Should -BeNullOrEmpty
    }
}

Describe 'Imaging bridge' {
    It 'reports tracked apps and flags Clever One beside EzDent-i' {
        $entries = @(
            [pscustomobject]@{ DisplayName = 'Clever One'; DisplayVersion = '1.2.3'; Publisher = 'Example'; InstallLocation = 'C:\Clever' }
            [pscustomobject]@{ DisplayName = 'EzDent-i'; DisplayVersion = '4.5'; Publisher = 'Vatech'; InstallLocation = 'C:\Vatech\EzDent-i' }
            [pscustomobject]@{ DisplayName = 'Ez3D-i'; DisplayVersion = '5.0'; Publisher = 'Vatech'; InstallLocation = '' }
            [pscustomobject]@{ DisplayName = 'EzServer'; DisplayVersion = '3.1'; Publisher = 'Vatech'; InstallLocation = '' }
            [pscustomobject]@{ DisplayName = 'Dentrix G7'; DisplayVersion = '24.1'; Publisher = 'Henry Schein'; InstallLocation = '' }
            [pscustomobject]@{ DisplayName = 'EzDent-i'; DisplayVersion = '4.5'; Publisher = 'Vatech'; InstallLocation = 'C:\Vatech\EzDent-i' }
        )
        $apps = @(Find-IbInstalledApp -Entries $entries)
        @($apps | Where-Object { $_.Label -eq 'EzDent-i' }).Count | Should -Be 1
        @($apps.Label) | Should -Contain 'Ez3D-i'
        @($apps.Label) | Should -Contain 'EzServer'
        @($apps.Label) | Should -Contain 'Dentrix'
        Test-IbCleverEzDentConflict -Labels @($apps.Label) | Should -BeTrue
    }

    It 'does not treat Ez3D-i as EzDent-i' {
        $entries = @(
            [pscustomobject]@{ DisplayName = 'Ez3D-i'; DisplayVersion = '5'; Publisher = 'Vatech'; InstallLocation = '' }
        )
        $apps = @(Find-IbInstalledApp -Entries $entries)
        Test-IbCleverEzDentConflict -Labels @($apps.Label) | Should -BeFalse
        $apps[0].Label | Should -Be 'Ez3D-i'
    }

    It 'parses a quoted service image path' {
        Get-IbExecutablePath -PathName '"C:\Program Files\Vatech\EzServer.exe" -service' | Should -Be 'C:\Program Files\Vatech\EzServer.exe'
    }
}

Describe 'Local admin audit' {
    It 'allows the built-in administrator and Domain Admins only by default' {
        Test-LaMemberAllowed -Sid 'S-1-5-21-1-2-3-500' -Name 'PC\Administrator' -AllowedPrincipal @() | Should -BeTrue
        Test-LaMemberAllowed -Sid 'S-1-5-21-9-9-9-512' -Name 'CONTOSO\Domain Admins' -AllowedPrincipal @() | Should -BeTrue
        Test-LaMemberAllowed -Sid 'S-1-5-21-1-2-3-1100' -Name 'PC\FrontDesk' -AllowedPrincipal @() | Should -BeFalse
    }

    It 'matches an extra principal by full name, leaf, or SID' {
        Test-LaMemberAllowed -Sid 'S-1-5-21-1-2-3-1100' -Name 'CONTOSO\Tech' -AllowedPrincipal @('Tech') | Should -BeTrue
        Test-LaMemberAllowed -Sid 'S-1-5-21-1-2-3-1100' -Name 'CONTOSO\Tech' -AllowedPrincipal @('CONTOSO\Tech') | Should -BeTrue
        Test-LaMemberAllowed -Sid 'S-1-5-21-1-2-3-1100' -Name 'CONTOSO\Tech' -AllowedPrincipal @('S-1-5-21-1-2-3-1100') | Should -BeTrue
        Test-LaNameMatch -MemberName 'CONTOSO\Tech' -Allowed 'OTHER\Tech' | Should -BeFalse
    }

    It 'fails unexpected members and an enabled built-in admin only when asked' {
        $members = @(
            [pscustomobject]@{ Name = 'PC\Administrator'; Sid = 'S-1-5-21-1-2-3-500'; Class = 'User'; Disabled = $false }
            [pscustomobject]@{ Name = 'PC\FrontDesk'; Sid = 'S-1-5-21-1-2-3-1100'; Class = 'User'; Disabled = $false }
        )
        $open = Get-LaAudit -Members $members -AllowedPrincipal @() -FailOnBuiltInAdminEnabled $false
        $strict = Get-LaAudit -Members @($members[0]) -AllowedPrincipal @() -FailOnBuiltInAdminEnabled $true
        $clean = Get-LaAudit -Members @($members[0]) -AllowedPrincipal @() -FailOnBuiltInAdminEnabled $false
        $open.ExitCode | Should -Be 1
        $open.Summary | Should -Match 'FrontDesk'
        $strict.ExitCode | Should -Be 1
        $clean.ExitCode | Should -Be 0
        $clean.Summary | Should -Match 'Built-in Administrator is enabled'
    }

    It 'splits an ADSI member path' {
        $parsed = Split-LaAdsPath -Path 'WinNT://CONTOSO/Tech'
        $parsed.Domain | Should -Be 'CONTOSO'
        $parsed.Name | Should -Be 'Tech'
    }
}
