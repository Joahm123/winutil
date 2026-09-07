Function Install-WinUtilProgramWinget {
    <#

    .SYNOPSIS
        Installs or uninstalls packages with WinGet and reports the outcome of each one

    .DESCRIPTION
        Emits one result object per package so the caller can tell what actually happened.

        Runs one winget command per package so a failure names the package that failed rather
        than the whole batch. Progress moves per package: winget hides its own progress bar once
        its output is redirected, so there is nothing to report from inside a single install.

    #>
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet("Install", "Uninstall", "Upgrade")]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string[]]$Programs
    )

    $adminContextProhibited = -1978335107

    $nothingToDo = @{
        -1978335135 = "already installed"
        -1978335189 = "no applicable update"
    }

    $rebootExitCodes = @{
        3010 = "installed, a restart is needed to finish"
        1641 = "installed, the installer started a restart"
        -1978334967 = "installed, a restart is needed to finish"
        -1978334965 = "installed, the installer started a restart"
    }

    foreach ($program in $Programs) {
        if ([string]::IsNullOrWhiteSpace($program) -or $program -eq "na") {
            continue
        }

        $upgradeAll = $Action -eq "Upgrade" -and $program -eq "all"

        # PowerShell installed through MSI cannot be upgraded by WinGet.
        if ($Action -eq "Upgrade" -and ($program -eq "Microsoft.PowerShell" -or $upgradeAll)) {
            $msi = Get-ItemProperty `
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" ,
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" `
                -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.WindowsInstaller -eq 1 -and
                    $_.DisplayName -match "^PowerShell\s+7" -and
                    $_.InstallLocation
                } |
                Select-Object -First 1

            if ($msi) {
                $pwsh = Join-Path $msi.InstallLocation "pwsh.exe"

                if (Test-Path $pwsh) {
                    try {
                        $installedVersion = & $pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'

                        $architecture = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
                            "Arm64" { "arm64" }
                            "X86"   { "x86" }
                            default { "x64" }
                        }

                        $release = Invoke-RestMethod `
                            "https://api.github.com/repos/PowerShell/PowerShell/releases/latest" `
                            -TimeoutSec 30

                        $latestVersion = ([string]$release.tag_name).TrimStart("v")

                        if (-not $installedVersion -or
                            -not $latestVersion -or
                            [version]$installedVersion -lt [version]$latestVersion) {

                            $asset = $release.assets |
                                Where-Object {
                                    $_.name -match "^PowerShell-.*-win-$architecture\.msi$"
                                } |
                                Select-Object -First 1

                            if (-not $asset) {
                                throw "No PowerShell MSI found for $architecture"
                            }

                            $tempMsi = Join-Path $env:TEMP "PowerShell-$architecture.msi"

                            Invoke-WebRequest `
                                -Uri $asset.browser_download_url `
                                -OutFile $tempMsi `
                                -TimeoutSec 300

                            if ($asset.digest) {
                                $hash = (Get-FileHash $tempMsi -Algorithm SHA256).Hash.ToLower()
                                if ($hash -ne $asset.digest.Replace("sha256:", "").ToLower()) {
                                    throw "PowerShell MSI SHA256 hash verification failed"
                                }
                            }

                            $signature = Get-AuthenticodeSignature $tempMsi
                            if ($signature.Status -ne "Valid" -or
                                $signature.SignerCertificate.Subject -notmatch "Microsoft") {
                                throw "PowerShell MSI signature verification failed"
                            }

                            $install = Start-Process msiexec.exe `
                                -ArgumentList "/i `"$tempMsi`" /qn /norestart" `
                                -Wait -PassThru

                            if ($install.ExitCode -notin @(0, 3010, 1641)) {
                                throw "PowerShell MSI installation failed with exit code $($install.ExitCode)"
                            }

                            Write-WinUtilLog -Component "Package" `
                                -Message "PowerShell MSI upgrade succeeded (exit code $($install.ExitCode))"

                            Remove-Item $tempMsi -Force -ErrorAction SilentlyContinue
                        } else {
                            Write-WinUtilLog -Component "Package" `
                                -Message "PowerShell is already current ($installedVersion)"
                        }
                    }
                    catch {
                        Write-WinUtilLog -Level "ERROR" -Component "Package" `
                            -Message "PowerShell MSI upgrade failed: $($_.Exception.Message)"
                    }
                }
            }
        }

        $source = if ($upgradeAll) { "all configured sources" } else { "winget" }

        if (-not $upgradeAll -and $program.StartsWith("msstore:", [System.StringComparison]::OrdinalIgnoreCase)) {
            $source = "msstore"
            $program = $program.Substring("msstore:".Length)
        }

        Write-WinUtilLog -Component "Package" -Message "$Action winget package: $program (source: $source)"

        $outcome = "Failed"
        $detail = "no result"
        $exitCode = -1

        $arguments = switch ($Action) {
            "Uninstall" { @("uninstall", "--id", $program, "--source", $source, "--silent") }
            "Upgrade" {
                if ($upgradeAll) {
                    @("upgrade", "--all", "--accept-package-agreements", "--accept-source-agreements", "--include-unknown", "--silent")
                } else {
                    @("upgrade", "--id", $program, "--accept-package-agreements", "--accept-source-agreements", "--source", $source, "--include-unknown", "--silent")
                }
            }
            default {
                @("install", "--id", $program, "--accept-package-agreements", "--accept-source-agreements", "--source", $source, "--silent")
            }
        }

        $process = Start-Process -FilePath winget -ArgumentList $arguments -NoNewWindow -Wait -PassThru
        $exitCode = $process.ExitCode

        if ($exitCode -eq 0) {
            $outcome = "Succeeded"
            $detail = "exit code 0"
        } elseif ($rebootExitCodes.ContainsKey($exitCode)) {
            $outcome = "Succeeded"
            $detail = $rebootExitCodes[$exitCode]
        } elseif ($nothingToDo.ContainsKey($exitCode)) {
            $outcome = "Skipped"
            $detail = $nothingToDo[$exitCode]
        } elseif ($exitCode -eq $adminContextProhibited) {
            $outcome = "Skipped"
            $detail = switch ($Action) {
                "Install" { "already installed for the current user; elevated WinUtil cannot update it" }
                "Upgrade" { "not upgraded; installed for the current user and elevated WinUtil cannot modify it" }
                "Uninstall" { "remains installed for the current user; elevated WinUtil cannot uninstall it" }
            }
        } else {
            $outcome = "Failed"
            $detail = "WinGet reported 0x{0:X8}. See https://learn.microsoft.com/windows/package-manager/winget/returnCodes" -f $exitCode
        }

        $level = if ($outcome -eq "Failed") { "ERROR" } else { "INFO" }
        Write-WinUtilLog -Level $level -Component "Package" -Message "$Action winget package $($outcome.ToLowerInvariant()): $program ($detail)"

        [pscustomobject]@{
            Package = $program
            Manager = "winget"
            Action = $Action
            ExitCode = $exitCode
            Outcome = $outcome
            Detail = $detail
        }
    }
}
