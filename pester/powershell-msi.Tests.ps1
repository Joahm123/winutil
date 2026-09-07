Describe "PowerShell MSI upgrade" {
    BeforeAll {
        . "$PSScriptRoot/../functions/private/Install-WinUtilProgramWinget.ps1"

        Mock Write-WinUtilLog {}
        Mock Test-Path { $true }
        Mock Remove-Item {}
        Mock Get-WinUtilPowerShellVersion { "7.5.2" }

        Mock Get-ItemProperty {
            [pscustomobject]@{
                WindowsInstaller = 1
                DisplayName = "PowerShell 7"
                InstallLocation = "C:\Program Files\PowerShell\7"
            }
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

    It "upgrades MSI-installed PowerShell" {
        Mock Start-Process {
            [pscustomobject]@{ ExitCode = 0 }
        }

        Install-WinUtilProgramWinget -Action Upgrade -Programs @("Microsoft.PowerShell")

        Should -Invoke Get-ItemProperty -Times 1
        Should -Invoke Get-WinUtilPowerShellVersion -Times 1
        Should -Invoke Invoke-RestMethod -Times 1
        Should -Invoke Invoke-WebRequest -Times 1
        Should -Invoke Get-AuthenticodeSignature -Times 1
        Should -Invoke Start-Process -Times 2
    }

    It "does not download when PowerShell is current" {
        Mock Get-WinUtilPowerShellVersion { "7.5.3" }
        Mock Start-Process {
            [pscustomobject]@{ ExitCode = 0 }
        }

        Install-WinUtilProgramWinget -Action Upgrade -Programs @("Microsoft.PowerShell")

        Should -Invoke Invoke-RestMethod -Times 1
        Should -Invoke Invoke-WebRequest -Times 0
    }

    It "checks MSI PowerShell during Upgrade All" {
        Mock Start-Process {
            [pscustomobject]@{ ExitCode = 0 }
        }

        Install-WinUtilProgramWinget -Action Upgrade -Programs @("all")

        Should -Invoke Get-WinUtilPowerShellVersion -Times 1
        Should -Invoke Invoke-RestMethod -Times 1
    }
}
