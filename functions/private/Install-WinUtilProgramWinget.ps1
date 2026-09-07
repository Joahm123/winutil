Function Install-WinUtilProgramWinget {
    <#

    .SYNOPSIS
        Installs or uninstalls packages with WinGet and reports the outcome of each one

    .DESCRIPTION
        Emits one result object per package so the caller can tell what actually happened
        rather than assuming the run succeeded.

        Runs one winget command per package so a failure names the package that failed rather
        than the whole batch. Progress moves per package: winget hides its own progress bar once
        its output is redirected, so there is nothing to report from inside a single install.

        PowerShell 7 has a special upgrade path because WinGet cannot upgrade a PowerShell
        installation that was originally installed using the MSI installer.

    #>
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet("Install", "Uninstall", "Upgrade")]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string[]]$Programs
    )

    # APPINSTALLER_CLI_ERROR_ADMIN_CONTEXT_ACTION_PROHIBITED. WinGet refuses to act on a package
    # that was installed in user scope while it is running elevated, and WinUtil is always
    # elevated, so every per-user app answers this and nothing happens.
    $adminContextProhibited = -1978335107

    # WinGet reports "there was nothing to do" through the exit code rather than as success
    $nothingToDo = @{
        -1978335135 = "already installed"
        -1978335189 = "no applicable update"
    }
    # The installer worked and wants a restart to finish. Windows reports that as its own exit
    # code rather than as zero, and treating it as a failure marks working installs as broken.
    $rebootExitCodes = @{
        3010 = "installed, a restart is needed to finish"
        1641 = "installed, the installer started a restart"
        # WinGet's own equivalents. -1978334966 is deliberately absent: it means a reboot is
        # required before the install can proceed, which is not a completed install.
        -1978334967 = "installed, a restart is needed to finish"
        -1978334965 = "installed, the installer started a restart"
    }

    foreach ($program in $Programs) {
        if ([string]::IsNullOrWhiteSpace($program) -or $program -eq "na") {
            continue
        }

        $upgradeAll = $Action -eq "Upgrade" -and $program -eq "all"
        $source = if ($upgradeAll) { "all configured sources" } else { "winget" }
        if (-not $upgradeAll -and $program.StartsWith("msstore:", [System.StringComparison]::OrdinalIgnoreCase)) {
            $source = "msstore"
            $program = $program.Substring("msstore:".Length)
        }

        Write-WinUtilLog -Component "Package" -Message "$Action winget package: $program (source: $source)"

        $outcome = "Failed"
        $detail = "no result"
        $exitCode = -1

        # PowerShell installed through MSI cannot be upgraded by WinGet because the
        # installation technology does not match. Use the official PowerShell MSI instead.
        if ($Action -eq "Upgrade" -and $program -eq "Microsoft.PowerShell" -and -not $upgradeAll) {
            $powerShellPath = Join-Path ${env:ProgramFiles} "PowerShell\7"
            $powerShellExe = Join-Path $powerShellPath "pwsh.exe"
            $powerShellMsiInstalled = $false

            if (Test-Path -LiteralPath $powerShellExe) {
                $uninstallPaths = @(
                    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
                    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
                )

                foreach ($uninstallPath in $uninstallPaths) {
                    $entries = Get-ItemProperty -Path $uninstallPath -ErrorAction SilentlyContinue

                    foreach ($entry in $entries) {
                        if ($entry.WindowsInstaller -eq 1 -and
                            [string]$entry.DisplayName -match '^PowerShell\s+7' -and
                            [string]$entry.InstallLocation -like "$powerShellPath*") {
                            $powerShellMsiInstalled = $true
                            break
                        }
                    }

                    if ($powerShellMsiInstalled) {
                        break
                    }
                }
            }

            if ($powerShellMsiInstalled) {
                $tempMsi = $null

                try {
                    Write-WinUtilLog -Component "Package" -Message "Detected MSI-installed PowerShell 7. Downloading the latest official PowerShell MSI."

                    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/PowerShell/PowerShell/releases/latest" -Headers @{
                        "Accept" = "application/vnd.github+json"
                        "User-Agent" = "WinUtil"
                    }

                    $msiAsset = $release.assets | Where-Object {
                        $_.name -match '^PowerShell-.*-win-x64\.msi$'
                    } | Select-Object -First 1

                    if (-not $msiAsset) {
                        throw "Could not find the PowerShell win-x64 MSI in the latest GitHub release."
                    }

                    $tempMsi = Join-Path $env:TEMP $msiAsset.name

                    Invoke-WebRequest -Uri $msiAsset.browser_download_url -OutFile $tempMsi -UseBasicParsing -Headers @{
                        "Accept" = "application/octet-stream"
                        "User-Agent" = "WinUtil"
                    }

                    if (-not (Test-Path -LiteralPath $tempMsi)) {
                        throw "PowerShell MSI download failed."
                    }

                    Write-WinUtilLog -Component "Package" -Message "Installing PowerShell MSI: $($msiAsset.name)"

                    $msiProcess = Start-Process -FilePath "msiexec.exe" -ArgumentList @("/i", "`"$tempMsi`"", "/qn", "/norestart") -NoNewWindow -Wait -PassThru
                    $exitCode = $msiProcess.ExitCode

                    if ($exitCode -eq 0) {
                        $outcome = "Succeeded"
                        $detail = "PowerShell MSI installed successfully"
                    } elseif ($exitCode -eq 3010) {
                        $outcome = "Succeeded"
                        $detail = "PowerShell MSI installed successfully; a restart is needed to finish"
                    } elseif ($exitCode -eq 1641) {
                        $outcome = "Succeeded"
                        $detail = "PowerShell MSI installed successfully; the installer requested a restart"
                    } else {
                        $outcome = "Failed"
                        $detail = "PowerShell MSI installer returned exit code $exitCode"
                    }
                }
                catch {
                    $outcome = "Failed"
                    $exitCode = -1
                    $detail = "PowerShell MSI upgrade failed: $($_.Exception.Message)"
                }
                finally {
                    if ($tempMsi -and (Test-Path -LiteralPath $tempMsi)) {
                        Remove-Item -LiteralPath $tempMsi -Force -ErrorAction SilentlyContinue
                    }
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

                continue
            }
        }

        $arguments = switch ($Action) {
            "Uninstall" { @("uninstall", "--id", $program, "--source", $source, "--silent") }
            "Upgrade" {
                if ($upgradeAll) {
                    @("upgrade", "--all", "--accept-package-agreements", "--accept-source-agreements", "--include-unknown", "--silent")
                } else {
                    @("upgrade", "--id", $program, "--accept-package-agreements", "--accept-source-agreements", "--source", $source, "--include-unknown", "--silent")
                }
            }
            default     { @("install", "--id", $program, "--accept-package-agreements", "--accept-source-agreements", "--source", $source, "--silent") }
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
