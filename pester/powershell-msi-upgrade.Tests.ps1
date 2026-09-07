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
                    Subject = "CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US"
                }
            }
        }
    }

    It "upgrades MSI-installed PowerShell successfully" {
        Mock Start-Process {
            [pscustomobject]@{ ExitCode = 0 }
        }

        $result = Update-WinUtilPowerShellMSI

        $result.State | Should -Be "Succeeded"
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

        $result.State | Should -Be "Succeeded"
        Should -Invoke Write-WinUtilLog -ParameterFilter {
            $Message -match "PowerShell MSI upgrade succeeded"
        }
    }

    It "treats MSI exit code 1641 as success" {
        Mock Start-Process {
            [pscustomobject]@{ ExitCode = 1641 }
        }

        $result = Update-WinUtilPowerShellMSI

        $result.State | Should -Be "Succeeded"
        Should -Invoke Write-WinUtilLog -ParameterFilter {
            $Message -match "PowerShell MSI upgrade succeeded"
        }
    }

    It "reports MSI installation failure" {
        Mock Start-Process {
            [pscustomobject]@{ ExitCode = 1603 }
        }

        $result = Update-WinUtilPowerShellMSI

        $result.State | Should -Be "Failed"
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

        $result.State | Should -Be "Succeeded"
        Should -Invoke Invoke-RestMethod -Times 1
        Should -Invoke Invoke-WebRequest -Times 0
        Should -Invoke Get-AuthenticodeSignature -Times 0
        Should -Invoke Start-Process -Times 0
    }

    It "returns NotInstalled when PowerShell is not MSI-installed" {
        Mock Get-ItemProperty {
            $null
        }

        $result = Update-WinUtilPowerShellMSI

        $result.State | Should -Be "NotInstalled"
        Should -Invoke Invoke-RestMethod -Times 0
        Should -Invoke Invoke-WebRequest -Times 0
        Should -Invoke Start-Process -Times 0
    }

    It "rejects a missing signer certificate" {
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{
                Status = "Valid"
                SignerCertificate = $null
            }
        }

        Mock Start-Process {
            [pscustomobject]@{ ExitCode = 0 }
        }

        $result = Update-WinUtilPowerShellMSI

        $result.State | Should -Be "Failed"
        Should -Invoke Start-Process -Times 0
    }

    It "rejects a trusted non-Microsoft certificate containing Microsoft in the subject" {
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{
                Status = "Valid"
                SignerCertificate = [pscustomobject]@{
                    Subject = "CN=Microsoft Malware Research"
                }
            }
        }

        Mock Start-Process {
            [pscustomobject]@{ ExitCode = 0 }
        }

        $result = Update-WinUtilPowerShellMSI

        $result.State | Should -Be "Failed"
        Should -Invoke Start-Process -Times 0
    }

    It "does not run WinGet after a successful MSI PowerShell upgrade" {
        Mock Start-Process {
            [pscustomobject]@{ ExitCode = 0 }
        }

        $result = Install-WinUtilProgramWinget `
            -Action Upgrade `
            -Programs @("Microsoft.PowerShell")

        $result.Outcome | Should -Be "Succeeded"
        $result.Manager | Should -Be "msi"
        Should -Invoke Start-Process -Times 1
    }

    It "does not run WinGet after a failed MSI PowerShell upgrade" {
        Mock Start-Process {
            [pscustomobject]@{ ExitCode = 1603 }
        }

        $result = Install-WinUtilProgramWinget `
            -Action Upgrade `
            -Programs @("Microsoft.PowerShell")

        $result.Outcome | Should -Be "Failed"
        $result.Manager | Should -Be "msi"
        Should -Invoke Start-Process -Times 1
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

        $result.Outcome | Should -Be "Succeeded"
        $result.Manager | Should -Be "winget"
        Should -Invoke Invoke-RestMethod -Times 0
        Should -Invoke Invoke-WebRequest -Times 0
        Should -Invoke Get-AuthenticodeSignature -Times 0
        Should -Invoke Start-Process -Times 1
    }

    It "checks MSI-installed PowerShell during Upgrade All" {
        Mock Start-Process {
            [pscustomobject]@{ ExitCode = 0 }
        }

        $result = Install-WinUtilProgramWinget `
            -Action Upgrade `
            -Programs @("all")

        Should -Invoke Get-ItemProperty -Times 1
        Should -Invoke Get-WinUtilPowerShellVersion -Times 1
        Should -Invoke Invoke-RestMethod -Times 1
    }
}
