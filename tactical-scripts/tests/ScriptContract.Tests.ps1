BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Scripts = @(
        'Get-DiskHealth.ps1',
        'Test-DiskSpace.ps1',
        'Install-Microsoft365Apps.ps1',
        'Test-Windows11Readiness.ps1',
        'Get-HardwareInventory.ps1',
        'Test-GpuVram.ps1',
        'Test-PendingReboot.ps1',
        'Get-WindowsUpdateStatus.ps1',
        'Test-ImagingBridge.ps1',
        'Get-LocalAdminAudit.ps1',
        'Get-ReplacementSurvey.ps1'
    )
}

Describe 'Tactical script contract' {
    It 'has the expected script files' {
        foreach ($name in $script:Scripts) {
            Test-Path -LiteralPath (Join-Path $script:Root $name) | Should -BeTrue
        }
    }

    It 'parses, documents purpose and exit codes, and guards dot-sourcing for <Name>' -ForEach @(
        @{ Name = 'Get-DiskHealth.ps1' }
        @{ Name = 'Test-DiskSpace.ps1' }
        @{ Name = 'Install-Microsoft365Apps.ps1' }
        @{ Name = 'Test-Windows11Readiness.ps1' }
        @{ Name = 'Get-HardwareInventory.ps1' }
        @{ Name = 'Test-GpuVram.ps1' }
        @{ Name = 'Test-PendingReboot.ps1' }
        @{ Name = 'Get-WindowsUpdateStatus.ps1' }
        @{ Name = 'Test-ImagingBridge.ps1' }
        @{ Name = 'Get-LocalAdminAudit.ps1' }
        @{ Name = 'Get-ReplacementSurvey.ps1' }
    ) {
        $path = Join-Path $script:Root $Name
        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
        $parseErrors.Count | Should -Be 0

        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -Match 'Purpose:'
        $content | Should -Match 'Exit codes:'
        $content.Contains("if (`$MyInvocation.InvocationName -ne '.') {") | Should -BeTrue
        $content | Should -Not -Match 'Restart-Computer'
        $content | Should -Not -Match 'Stop-Computer'
        $content | Should -Not -Match 'ConvertTo-SecureString'
        $content | Should -Not -Match '(?i)(password|pwd|api[_-]?key|secret)\s*=\s*[''"][^''"]+[''"]'

        $content | Should -Match 'Parameters:'
        $content | Should -Match 'EXITCODE: \{0\}'

        if ($Name -ne 'Install-Microsoft365Apps.ps1') {
            $content | Should -Not -Match 'shutdown\.exe'
        }
        if ($content -match 'Stop-Service') {
            $content | Should -Match 'AllowServiceRestart'
        }
        if ($content -match 'shutdown\.exe') {
            $content | Should -Match 'AllowReboot'
        }

        $bytes = [System.IO.File]::ReadAllBytes($path)
        $high = @($bytes | Where-Object { $_ -gt 127 })
        $high.Count | Should -Be 0
    }

    It 'exits 2 on a non-Windows host for <Name>' -ForEach @(
        @{ Name = 'Get-DiskHealth.ps1' }
        @{ Name = 'Test-DiskSpace.ps1' }
        @{ Name = 'Install-Microsoft365Apps.ps1' }
        @{ Name = 'Test-Windows11Readiness.ps1' }
        @{ Name = 'Get-HardwareInventory.ps1' }
        @{ Name = 'Test-GpuVram.ps1' }
        @{ Name = 'Test-PendingReboot.ps1' }
        @{ Name = 'Get-WindowsUpdateStatus.ps1' }
        @{ Name = 'Test-ImagingBridge.ps1' }
        @{ Name = 'Get-LocalAdminAudit.ps1' }
        @{ Name = 'Get-ReplacementSurvey.ps1' }
    ) {
        $path = Join-Path $script:Root $Name
        $output = & pwsh -NoProfile -NonInteractive -File $path 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 2
        $output | Should -Match 'RESULT: Error'
        $output | Should -Match 'must run on Windows'
        $lines = @($output -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $lines[-1] | Should -Be 'EXITCODE: 2'
    }
}
