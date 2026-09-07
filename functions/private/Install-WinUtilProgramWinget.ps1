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
        installation that was originally installed using the MSI installer. In that case,
        the latest official PowerShell x64 MSI is downloaded from the PowerShell GitHub
        release and installed directly with Windows Installer.

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

    # The installer worked and wants a restart to finish.
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
        $source = if ($upgradeAll) { "all configured sources" } else { "winget" }

        if (-not $upgradeAll -and $program.StartsWith("msstore:", [System.StringComparison]::OrdinalIgnoreCase)) {
            $source = "msstore"
            $program = $program.Substring("msstore:".Length)
        }

        Write-WinUtilLog -Component "Package" -Message "$Action winget package: $program (source: $source)"

        $outcome = "Failed"
        $detail = "no result"
        $exitCode = -1

        # ============================================================
        # PowerShell 7 MSI upgrade workaround
        # ============================================================
        #
        # WinGet cannot upgrade PowerShell when the existing installation
        # was installed using the MSI installer.
        #
        # Detect the Windows Installer registration rather than relying
        # only on the PowerShell installation path.
        #
        $powerShellMsiUpgrade = $Action -eq "Upgrade" -and
            $program -eq "Microsoft.PowerShell" -and
            -not $upgradeAll

        if ($powerShellMsiUpgrade) {
            $powerShellExe = Join-Path ${env:ProgramFiles} "PowerShell\7\pwsh.exe"
            $powerShellInstallPath = Join-Path ${env:ProgramFiles} "PowerShell\7"

            $powerShellMsiInstalled = $false

            if ((Test-Path -LiteralPath $powerShellExe) -and
                (Test-Path -LiteralPath $powerShellInstallPath)) {

                try {
                    # Check both normal and 32-bit uninstall registry locations.
                    # A machine-wide MSI installation registers itself with
                    # WindowsInstaller=1.
                    $uninstallPaths = @(
                        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
                        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
                    )

                    foreach ($uninstallPath in $uninstallPaths) {
                        $entries = Get-ItemProperty -Path $uninstallPath -ErrorAction SilentlyContinue

                        foreach ($entry in $entries) {
                            if ($entry.WindowsInstaller -ne 1) {
                                continue
                            }

                            $displayName = [string]$entry.DisplayName
                            $installLocation = [string]$entry.InstallLocation

                            $isPowerShell = $displayName -match '^PowerShell\s+7'
                            $isPowerShellInstallPath = $false

                            if (-not [string]::IsNullOrWhiteSpace($installLocation)) {
                                try {
                                    $normalizedInstallLocation = [System.IO.Path]::GetFullPath(
                                        $installLocation.TrimEnd('\') + '\'
                                    )

                                    $normalizedPowerShellPath = [System.IO.Path]::GetFullPath(
                                        $powerShellInstallPath.TrimEnd('\') + '\'
                                    )

                                    $isPowerShellInstallPath =
                                        $normalizedInstallLocation.Equals(
                                            $normalizedPowerShellPath,
                                            [System.StringComparison]::OrdinalIgnoreCase
                                        )
                                }
                                catch {
                                    $isPowerShellInstallPath = $false
                                }
                            }

                            if ($isPowerShell -and $isPowerShellInstallPath) {
                                $powerShellMsiInstalled = $true
                                break
                            }
                        }

                        if ($powerShellMsiInstalled) {
                            break
                        }
                    }
                }
                catch {
                    Write-WinUtilLog `
                        -Level "WARN" `
                        -Component "Package" `
                        -Message "Could not inspect the Windows Installer registry for PowerShell: $($_.Exception.Message)"
                }
            }

            if ($powerShellMsiInstalled) {
                Write-WinUtilLog `
                    -Component "Package" `
                    -Message "Detected MSI-installed PowerShell 7 through the Windows Installer registry. Using the PowerShell MSI upgrade path."

                $tempMsi = $null
                $tempDirectory = $null

                try {
                    $installedVersion = $null

                    try {
                        $installedVersion = & $powerShellExe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null

                        if ($installedVersion) {
                            $installedVersion = $installedVersion.Trim()
                        }
                    }
                    catch {
                        Write-WinUtilLog `
                            -Level "WARN" `
                            -Component "Package" `
                            -Message "Could not determine the installed PowerShell version: $($_.Exception.Message)"
                    }

                    # Official PowerShell GitHub releases API.
                    $releaseApi = "https://api.github.com/repos/PowerShell/PowerShell/releases/latest"

                    Write-WinUtilLog `
                        -Component "Package" `
                        -Message "Checking the latest PowerShell release from GitHub."

                    $release = Invoke-RestMethod `
                        -Uri $releaseApi `
                        -Method Get `
                        -Headers @{
                            "Accept" = "application/vnd.github+json"
                            "User-Agent" = "WinUtil"
                        }

                    if (-not $release -or -not $release.assets) {
                        throw "The latest PowerShell GitHub release did not contain any downloadable assets."
                    }

                    # Find the official Windows x64 MSI.
                    $msiAsset = $release.assets |
                        Where-Object {
                            $_.name -match '^PowerShell-.*-win-x64\.msi$'
                        } |
                        Select-Object -First 1

                    if (-not $msiAsset) {
                        throw "Could not find the PowerShell win-x64 MSI in the latest GitHub release."
                    }

                    if ([string]::IsNullOrWhiteSpace($msiAsset.browser_download_url)) {
                        throw "The PowerShell MSI release asset did not contain a download URL."
                    }

                    Write-WinUtilLog `
                        -Component "Package" `
                        -Message "Latest PowerShell MSI found: $($msiAsset.name)"

                    # Create a temporary directory specifically for this upgrade.
                    $tempDirectory = Join-Path $env:TEMP "WinUtil-PowerShell"

                    if (-not (Test-Path -LiteralPath $tempDirectory)) {
                        New-Item -ItemType Directory -Path $tempDirectory -Force | Out-Null
                    }

                    $tempMsi = Join-Path $tempDirectory $msiAsset.name

                    if (Test-Path -LiteralPath $tempMsi) {
                        Remove-Item -LiteralPath $tempMsi -Force -ErrorAction SilentlyContinue
                    }

                    Write-WinUtilLog `
                        -Component "Package" `
                        -Message "Downloading PowerShell MSI to $tempMsi"

                    Invoke-WebRequest `
                        -Uri $msiAsset.browser_download_url `
                        -OutFile $tempMsi `
                        -UseBasicParsing `
                        -Headers @{
                            "Accept" = "application/octet-stream"
                            "User-Agent" = "WinUtil"
                        }

                    if (-not (Test-Path -LiteralPath $tempMsi)) {
                        throw "PowerShell MSI download did not produce an installer file."
                    }

                    $downloadedFile = Get-Item -LiteralPath $tempMsi -ErrorAction Stop

                    if ($downloadedFile.Length -le 0) {
                        throw "The downloaded PowerShell MSI is empty."
                    }

                    Write-WinUtilLog `
                        -Component "Package" `
                        -Message "Installing PowerShell MSI: $($msiAsset.name)"

                    # Install silently without automatically restarting Windows.
                    $msiProcess = Start-Process `
                        -FilePath "msiexec.exe" `
                        -ArgumentList @(
                            "/i"
                            "`"$tempMsi`""
                            "/qn"
                            "/norestart"
                        ) `
                        -NoNewWindow `
                        -Wait `
                        -PassThru

                    $exitCode = $msiProcess.ExitCode

                    if ($exitCode -eq 0) {
                        $outcome = "Succeeded"
                        $detail = "PowerShell MSI installed successfully"

                        if ($installedVersion) {
                            $detail = "$detail; previous version $installedVersion"
                        }
                    }
                    elseif ($exitCode -eq 3010) {
                        $outcome = "Succeeded"
                        $detail = "PowerShell MSI installed successfully; a restart is needed to finish"
                    }
                    elseif ($exitCode -eq 1641) {
                        $outcome = "Succeeded"
                        $detail = "PowerShell MSI installed successfully; the installer requested a restart"
                    }
                    else {
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
                    # Always remove the downloaded MSI, even if installation fails.
                    if ($tempMsi -and (Test-Path -LiteralPath $tempMsi)) {
                        try {
                            Remove-Item -LiteralPath $tempMsi -Force -ErrorAction Stop

                            Write-WinUtilLog `
                                -Component "Package" `
                                -Message "Removed temporary PowerShell MSI: $tempMsi"
                        }
                        catch {
                            Write-WinUtilLog `
                                -Level "WARN" `
                                -Component "Package" `
                                -Message "Could not remove temporary PowerShell MSI $tempMsi`: $($_.Exception.Message)"
                        }
                    }

                    # Remove the temporary directory if it is empty.
                    if ($tempDirectory -and (Test-Path -LiteralPath $tempDirectory)) {
                        try {
                            Remove-Item -LiteralPath $tempDirectory -Force -ErrorAction SilentlyContinue
                        }
                        catch {
                            # The directory is only temporary cleanup, so don't
                            # turn a successful upgrade into a failed operation.
                        }
                    }
                }

                $level = if ($outcome -eq "Failed") { "ERROR" } else { "INFO" }

                Write-WinUtilLog `
                    -Level $level `
                    -Component "Package" `
                    -Message "$Action winget package $($outcome.ToLowerInvariant()): $program ($detail)"

                [pscustomobject]@{
                    Package = $program
                    Manager = "winget"
                    Action = $Action
                    ExitCode = $exitCode
                    Outcome = $outcome
                    Detail = $detail
                }

                # The PowerShell MSI path has completely handled this package.
                continue
            }

            Write-WinUtilLog `
                -Component "Package" `
                -Message "PowerShell 7 was not detected as an MSI installation. Falling back to WinGet."
        }

        # ============================================================
        # Normal WinGet path
        # ============================================================

        $arguments = switch ($Action) {
            "Uninstall" {
                @(
                    "uninstall"
                    "--id"
                    $program
                    "--source"
                    $source
                    "--silent"
                )
            }

            # --include-unknown because the scan that found these ran with it:
            # without it winget refuses every package whose installed version
            # it could not read.
            "Upgrade" {
                if ($upgradeAll) {
                    @(
                        "upgrade"
                        "--all"
                        "--accept-package-agreements"
                        "--accept-source-agreements"
                        "--include-unknown"
                        "--silent"
                    )
                }
                else {
                    @(
                        "upgrade"
                        "--id"
                        $program
                        "--accept-package-agreements"
                        "--accept-source-agreements"
                        "--source"
                        $source
                        "--include-unknown"
                        "--silent"
                    )
                }
            }

            default {
                @(
                    "install"
                    "--id"
                    $program
                    "--accept-package-agreements"
                    "--accept-source-agreements"
                    "--source"
                    $source
                    "--silent"
                )
            }
        }

        $process = Start-Process `
            -FilePath winget `
            -ArgumentList $arguments `
            -NoNewWindow `
            -Wait `
            -PassThru

        $exitCode = $process.ExitCode

        if ($exitCode -eq 0) {
            $outcome = "Succeeded"
            $detail = "exit code 0"
        }
        elseif ($rebootExitCodes.ContainsKey($exitCode)) {
            $outcome = "Succeeded"
            $detail = $rebootExitCodes[$exitCode]
        }
        elseif ($nothingToDo.ContainsKey($exitCode)) {
            $outcome = "Skipped"
            $detail = $nothingToDo[$exitCode]
        }
        elseif ($exitCode -eq $adminContextProhibited) {
            $outcome = "Skipped"

            $detail = switch ($Action) {
                "Install" {
                    "already installed for the current user; elevated WinUtil cannot update it"
                }

                "Upgrade" {
                    "not upgraded; installed for the current user and elevated WinUtil cannot modify it"
                }

                "Uninstall" {
                    "remains installed for the current user; elevated WinUtil cannot uninstall it"
                }
            }
        }
        else {
            $outcome = "Failed"

            # The client module reports the same failure as a bare HRESULT,
            # so the hex form and Microsoft's own list serve both paths.
            $detail = "WinGet reported 0x{0:X8}. See https://learn.microsoft.com/windows/package-manager/winget/returnCodes" -f $exitCode
        }

        $level = if ($outcome -eq "Failed") { "ERROR" } else { "INFO" }

        Write-WinUtilLog `
            -Level $level `
            -Component "Package" `
            -Message "$Action winget package $($outcome.ToLowerInvariant()): $program ($detail)"

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
