BeforeAll {
    . (Join-Path $PSScriptRoot '../Install-Microsoft365Apps.ps1')
}

Describe 'Microsoft 365 install decisions' {
    It 'skips a matching 64-bit product' {
        $action = Get-MoInstallAction -InstalledProducts @('O365BusinessRetail') -Platform 'x64' -RequestedProduct 'O365BusinessRetail'
        $action.Action | Should -Be 'Skip'
    }

    It 'refuses a different product or 32-bit Office' {
        $other = Get-MoInstallAction -InstalledProducts @('O365ProPlusRetail') -Platform 'x64' -RequestedProduct 'O365BusinessRetail'
        $bitness = Get-MoInstallAction -InstalledProducts @('O365BusinessRetail') -Platform 'x86' -RequestedProduct 'O365BusinessRetail'
        $other.Action | Should -Be 'Stop'
        $bitness.Action | Should -Be 'Stop'
        $bitness.Reason | Should -Match '64-bit'
    }

    It 'installs when Click-to-Run is absent' {
        $action = Get-MoInstallAction -InstalledProducts @() -Platform '' -RequestedProduct 'O365ProPlusRetail'
        $action.Action | Should -Be 'Install'
    }

    It 'writes a 64-bit Current channel configuration' {
        $xml = Format-MoConfigurationXml -ProductId 'O365BusinessRetail' -Language 'en-us' -SharedComputerLicensing $false -ForceAppShutdown $false -RemoveExistingMsi $false -LogPath 'C:\ProgramData\StandardComputer\Tactical\OfficeODT\logs'
        $xml | Should -Match 'OfficeClientEdition="64"'
        $xml | Should -Match 'Channel="Current"'
        $xml | Should -Match 'O365BusinessRetail'
        $xml | Should -Match 'FORCEAPPSHUTDOWN" Value="FALSE"'
        $xml | Should -Not -Match 'RemoveMSI'
    }

    It 'enables app shutdown, shared licensing, and MSI removal only when requested' {
        $xml = Format-MoConfigurationXml -ProductId 'O365ProPlusRetail' -Language 'en-us' -SharedComputerLicensing $true -ForceAppShutdown $true -RemoveExistingMsi $true -LogPath 'C:\logs'
        $xml | Should -Match 'FORCEAPPSHUTDOWN" Value="TRUE"'
        $xml | Should -Match 'SharedComputerLicensing" Value="1"'
        $xml | Should -Match '<RemoveMSI />'
    }

    It 'extracts the Office Deployment Tool download URL' {
        $html = 'href="https://download.microsoft.com/download/2/7/A/example/officedeploymenttool_12345-67890.exe"'
        Get-MoOdtUrlFromHtml -Html $html | Should -Match 'officedeploymenttool_12345-67890\.exe$'
        Get-MoOdtUrlFromHtml -Html 'no link here' | Should -BeNullOrEmpty
    }

    It 'recognizes the Current channel CDN' {
        Test-MoCurrentChannel -Url 'http://officecdn.microsoft.com/pr/492350f6-3a01-4f97-b9c0-c7c6ddf67d60' | Should -BeTrue
        Test-MoCurrentChannel -Url 'http://officecdn.microsoft.com/pr/other' | Should -BeFalse
    }
}
