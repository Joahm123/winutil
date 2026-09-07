Function Get-WinUtilPowerShellVersion {
    param ([string]$Path)
    & $Path -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
}

Function Update-WinUtilPowerShellMSI {
    $msi = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*","HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.WindowsInstaller -eq 1 -and $_.DisplayName -match "^PowerShell\s+7" -and $_.InstallLocation -and (Test-Path (Join-Path $_.InstallLocation "pwsh.exe")) } |
        Select-Object -First 1

    if (-not $msi) {
        return $false
    }

    try {
        $installed = Get-WinUtilPowerShellVersion (Join-Path $msi.InstallLocation "pwsh.exe")
        $arch = ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture).ToString().ToLowerInvariant()
        $release = Invoke-RestMethod "https://api.github.com/repos/PowerShell/PowerShell/releases/latest" -TimeoutSec 30
        $latest = ([string]$release.tag_name).TrimStart("v")

        if ($installed -and $latest -and [version]$installed -ge [version]$latest) {
            Write-WinUtilLog -Component "Package" -Message "PowerShell is already current ($installed)"
            return $true
        }

        $asset = $release.assets | Where-Object { $_.name -match "^PowerShell-.*-win-$arch\.msi$" } | Select-Object -First 1
        if (-not $asset) {
            throw "No PowerShell MSI found for $arch"
        }

        $msiPath = Join-Path $env:TEMP "PowerShell-$arch.msi"

        try {
            Invoke-WebRequest $asset.browser_download_url -OutFile $msiPath -TimeoutSec 300

            if ($asset.digest) {
                $hash = (Get-FileHash $msiPath -Algorithm SHA256).Hash.ToLower()
                if ($hash -ne $asset.digest.Replace("sha256:","").ToLower()) {
                    throw "PowerShell MSI SHA256 verification failed"
                }
            }

            $signature = Get-AuthenticodeSignature $msiPath
            if ($signature.Status -ne "Valid" -or $signature.SignerCertificate.Subject -notmatch "Microsoft") {
                throw "PowerShell MSI signature verification failed"
            }

            $install = Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /qn /norestart" -Wait -PassThru
            if ($install.ExitCode -notin @(0,3010,1641)) {
                throw "PowerShell MSI installation failed with exit code $($install.ExitCode)"
            }

            Write-WinUtilLog -Component "Package" -Message "PowerShell MSI upgrade succeeded (exit code $($install.ExitCode))"
            return $true
        }
        finally {
            Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "PowerShell MSI upgrade failed: $($_.Exception.Message)"
        return $false
    }
}

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

        if ($Action -eq "Upgrade" -and ($program -eq "Microsoft.PowerShell" -or $upgradeAll)) {
            Update-WinUtilPowerShellMSI
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
                    # --include-unknown because the scan that found these ran with it: without it winget
                    # refuses every package whose installed version it could not read
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
