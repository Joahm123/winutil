Describe "PowerShell MSI upgrade" {
    BeforeAll {
        . "$PSScriptRoot/../functions/private/Install-WinUtilProgramWinget.ps1"

        Mock Write-WinUtilLog {}
        Mock Test-Path { $true }
        Mock Remove-Item {}

        Mock Get-ItemProperty {
            [pscustomobject]@{
                WindowsInstaller = 1
                DisplayName = "PowerShell 7"
                InstallLocation = "C:\Program Files\PowerShell\7"
            }
        }

        Mock Get-WinUtilPowerShellVersion {
            "7.5.2"
        }

        Mock Invoke-RestMethod {
            [pscustomobject]@{
                tag_name = "v7.5.3"
                assets = @(
                    [pscustomobject]@{
                        name = "PowerShell-7.5.3-win-x64.msi"
                        browser_download_url = "https://example.com/PowerShell.msi"
                        digest = $null
                    }
                )
            }
        }

        Mock Invoke-WebRequest {}

        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{
                Status = "Valid"
                SignerCertificate = [pscustomobject]@{
                    Subject = "CN=Microsoft Corporation"
                }
            }
        }
    }

    It "upgrades MSI-installed PowerShell successfully" {
        Mock Start-Process {
            [pscustomobject]@{ ExitCode = 0 }
        }

        $result = Update-WinUtilPowerShellMSI

        $result | Should -BeTrue
        Should -Invoke Get-ItemProperty -Times 1
        Should -Invoke Get-WinUtilPowerShellVersion -Times 1
        Should -Invoke Invoke-RestMethod -Times 1
        Should -Invoke Invoke-WebRequest -Times 1
        Should -Invoke Get-AuthenticodeSignature -Times 1
        Should -Invoke Start-Process -Times 1
    }

    It "treats MSI exit code 3010 as success" {
        Mock Start-Process {
            [pscustomobject]@{ ExitCode = 3010 }
        }

        $result = Update-WinUtilPowerShellMSI

        $result | Should -BeTrue
        Should -Invoke Write-WinUtilLog -ParameterFilter {
            $Message -match "PowerShell MSI upgrade succeeded"
        }
    }

    It "treats MSI exit code 1641 as success" {
        Mock Start-Process {
            [pscustomobject]@{ ExitCode = 1641 }
        }

        $result = Update-WinUtilPowerShellMSI

        $result | Should -BeTrue
        Should -Invoke Write-WinUtilLog -ParameterFilter {
            $Message -match "PowerShell MSI upgrade succeeded"
        }
    }

    It "reports MSI installation failure" {
        Mock Start-Process {
            [pscustomobject]@{ ExitCode = 1603 }
        }

        $result = Update-WinUtilPowerShellMSI

        $result | Should -BeFalse
        Should -Invoke Write-WinUtilLog -ParameterFilter {
            $Level -eq "ERROR" -and
            $Message -match "PowerShell MSI upgrade failed"
        }
    }

    It "does not download when PowerShell is already current" {
        Mock Get-WinUtilPowerShellVersion {
            "7.5.3"
        }

        $result = Update-WinUtilPowerShellMSI

        $result | Should -BeTrue
        Should -Invoke Invoke-RestMethod -Times 1
        Should -Invoke Invoke-WebRequest -Times 0
        Should -Invoke Get-AuthenticodeSignature -Times 0
        Should -Invoke Start-Process -Times 0
    }

    It "returns false when PowerShell is not MSI-installed" {
        Mock Get-ItemProperty {
            $null
        }

        $result = Update-WinUtilPowerShellMSI

        $result | Should -BeFalse
        Should -Invoke Invoke-RestMethod -Times 0
        Should -Invoke Invoke-WebRequest -Times 0
        Should -Invoke Start-Process -Times 0
    }

    It "checks MSI-installed PowerShell during Upgrade All" {
        Mock Start-Process {
            [pscustomobject]@{ ExitCode = 0 }
        }

        Install-WinUtilProgramWinget -Action Upgrade -Programs @("all")

        Should -Invoke Get-ItemProperty -Times 1
        Should -Invoke Get-WinUtilPowerShellVersion -Times 1
        Should -Invoke Invoke-RestMethod -Times 1
    }

    It "falls back to WinGet when PowerShell is not MSI-installed" {
        Mock Get-ItemProperty {
            $null
        }

        Mock Start-Process {
            [pscustomobject]@{ ExitCode = 0 }
        }

        $result = Install-WinUtilProgramWinget `
            -Action Upgrade `
            -Programs @("Microsoft.PowerShell")

        Should -Invoke Invoke-RestMethod -Times 0
        Should -Invoke Invoke-WebRequest -Times 0
        Should -Invoke Get-AuthenticodeSignature -Times 0
        Should -Invoke Start-Process -Times 1
    }
}
