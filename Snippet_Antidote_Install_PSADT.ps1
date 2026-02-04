# All files are in Files folder and we will use names only
    $msiAntidote = 'Antidote11.msi'
    $msiModFr = 'Antidote11-Module-francais.msi'
    $msiModEn = 'Antidote11-English-module.msi'
    $msiConnectix = 'Antidote-Connectix11.msi'

    $mstReseauAntidote = 'ReseauAntidote.mst'
    $mstReseauConnectix = 'ReseauConnectix.mst'

    $mstAntidoteIFR = 'Antidote11-Interface-fr.mst'
    $mstModFrIFR = 'Antidote11-Module-francais-Interface-fr.mst'
    $mstModEnIFR = 'Antidote11-English-module-Interface-fr.mst'
    $mstConnectixIFR = 'Antidote-Connectix11-Interface-fr.mst'

    Write-ADTLogEntry -Message "Antidote 11 install starting. All MSI/MST/MSP expected under Files directory." -Severity 1

    # Fail fast if required MSIs are missing (packaging issue)
    $required = @($msiAntidote, $msiConnectix)
    $missingRequired = $required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $dirFiles $_)) }
    if ($missingRequired) {
        Write-ADTLogEntry -Message ("Required MSI missing from Files: {0}" -f ($missingRequired -join ', ')) -Severity 3
        throw "Required MSI missing from Files."
    }

    # Optional modules
    $hasFr = Test-Path -LiteralPath (Join-Path $dirFiles $msiModFr)
    $hasEn = Test-Path -LiteralPath (Join-Path $dirFiles $msiModEn)
    Write-ADTLogEntry -Message ("Modules detected: FR={0}, EN={1}" -f $hasFr, $hasEn) -Severity 1

    # MSP patches (names only), sorted
    $mspPatchNames = Get-ChildItem -LiteralPath $dirFiles -Filter 'Diff_*.msp' -File -ErrorAction SilentlyContinue |
    Sort-Object -Property Name |
    Select-Object -ExpandProperty Name

    if ($mspPatchNames) {
        Write-ADTLogEntry -Message ("MSP patches found (alpha order): {0}" -f ($mspPatchNames -join ' | ')) -Severity 1
    }
    else {
        Write-ADTLogEntry -Message "No MSP patches found (Diff_*.msp) in Files." -Severity 2
    }

    ##================================================
    ## MARK: Install
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    ## Handle Zero-Config MSI installations.
    if ($adtSession.UseDefaultMsi) {
        $ExecuteDefaultMSISplat = @{ Action = $adtSession.DeploymentType; FilePath = $adtSession.DefaultMsiFile }
        if ($adtSession.DefaultMstFile) {
            $ExecuteDefaultMSISplat.Add('Transforms', $adtSession.DefaultMstFile)
        }
        Start-ADTMsiProcess @ExecuteDefaultMSISplat
        if ($adtSession.DefaultMspFiles) {
            $adtSession.DefaultMspFiles | Start-ADTMsiProcess -Action Patch
        }
    }

    # Transforms are passed as names (same folder as MSI: Files)
    $antidoteTransforms = @($mstReseauAntidote, $mstAntidoteIFR)
    $connectixTransforms = @($mstReseauConnectix, $mstConnectixIFR)
    $frTransforms = @($mstModFrIFR)
    $enTransforms = @($mstModEnIFR)

    Write-ADTLogEntry -Message "Installing Antidote core: $msiAntidote" -Severity 1
    Start-ADTMsiProcess -Action Install -FilePath $msiAntidote -Transforms $antidoteTransforms

    if ($hasFr) {
        Write-ADTLogEntry -Message "Installing FR module: $msiModFr" -Severity 1
        Start-ADTMsiProcess -Action Install -FilePath $msiModFr -Transforms $frTransforms
    }

    if ($hasEn) {
        Write-ADTLogEntry -Message "Installing EN module: $msiModEn" -Severity 1
        Start-ADTMsiProcess -Action Install -FilePath $msiModEn -Transforms $enTransforms
    }

    Write-ADTLogEntry -Message "Installing Connectix: $msiConnectix" -Severity 1
    Start-ADTMsiProcess -Action Install -FilePath $msiConnectix -Transforms $connectixTransforms

    # Apply patches once after base installs (cleanest)
    if ($mspPatchNames) {
        foreach ($msp in $mspPatchNames) {
            try {
                Write-ADTLogEntry -Message "Applying patch: $msp" -Severity 1
                Start-ADTMspProcess -FilePath $msp
            }
            catch {
                $msg = $_.Exception.Message
                if ($msg -match '(?i)\b(1633|1642|17025)\b' -or $msg -match '(?i)not applicable|does not apply|supersed') {
                    Write-ADTLogEntry -Message "Patch skipped (not applicable): $msp | $msg" -Severity 2
                    continue
                }
                if ($msg -match '(?i)\b3010\b|reboot') {
                    Write-ADTLogEntry -Message "Patch requires reboot: $msp | $msg" -Severity 2
                    continue
                }
                Write-ADTLogEntry -Message "Patch FAILED: $msp | $msg" -Severity 3
                throw
            }
        }
    }


    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    # Pick a reasonable exe to validate install before writing detection key.
    # Update these if your environment uses different paths.
    $exeCandidates = @(
        'C:\Program Files\Druide\Antidote 11\Application\Bin64\Antidote.exe',
        'C:\Program Files\Druide\Connectix 11\Application\Bin64\Connectix.exe'
    )
    $exePath = $exeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $exeName = if ($exePath) { Split-Path -Path $exePath -Leaf } else { '<not found>' }

    # Test to see if exe exsist before written to registry
    if (Test-Path $exePath) {
        Set-AppDetectionKey -AppName $adtSession.AppName -ExePath $exePath -ScriptVersion $adtSession.AppScriptVersion
    }
    else {
        Write-ADTLogEntry -Message "Install ran but $exeName not found — registry key NOT written." -Severity 1
    }


    ## Display a message at the end of the install.
    if (!$adtSession.UseDefaultMsi) {
        Show-ADTInstallationPrompt -Message 'You can customize text to appear at the end of an install or remove it completely for unattended installations.' -ButtonRightText 'OK' -NoWait
    }
}

function Uninstall-ADTDeployment {
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Uninstall
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    ## If there are processes to close, show Welcome Message with a 60 second countdown before automatically closing.
    if ($adtSession.AppProcessesToClose.Count -gt 0) {
        Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 60
    }

    ## Show Progress Message (with the default message).
    Show-ADTInstallationProgress

    Write-ADTLogEntry -Message "Antidote 11 uninstall starting." -Severity 1

    # Product codes from Desinstaller-Antidote.ps1
    $products = @(
        [PSCustomObject]@{ Name = 'Antidote 11 - English Module'; Code = '{2643823D-D15F-4046-8388-401756A5C923}' },
        [PSCustomObject]@{ Name = 'Antidote 11 - Module Français'; Code = '{2643823D-D15F-4046-8388-401756A5C922}' },
        [PSCustomObject]@{ Name = 'Antidote 11'; Code = '{2643823D-D15F-4046-8388-401756A5C921}' },
        [PSCustomObject]@{ Name = 'Antidote - Connectix 11'; Code = '{2643823D-D15F-4046-8388-401756A5C924}' }
    )


    ##================================================
    ## MARK: Uninstall
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    ## Handle Zero-Config MSI uninstallations.
    if ($adtSession.UseDefaultMsi) {
        $ExecuteDefaultMSISplat = @{ Action = $adtSession.DeploymentType; FilePath = $adtSession.DefaultMsiFile }
        if ($adtSession.DefaultMstFile) {
            $ExecuteDefaultMSISplat.Add('Transforms', $adtSession.DefaultMstFile)
        }
        Start-ADTMsiProcess @ExecuteDefaultMSISplat
    }

    foreach ($p in $products) {
        try {
            Write-ADTLogEntry -Message "Uninstalling $($p.Name) ($($p.Code))" -Severity 1
            Start-ADTMsiProcess -Action Uninstall -ProductCode $p.Code
        }
        catch {
            # If it’s not installed, MSI typically returns “unknown product” (1605). PSADT may throw — we treat as non-fatal.
            $msg = $_.Exception.Message
            if ($msg -match '1605|unknown product|not installed|ERROR_UNKNOWN_PRODUCT') {
                Write-ADTLogEntry -Message "Product not present; skipping: $($p.Name) ($($p.Code)) | $msg" -Severity 2
                continue
            }
            Write-ADTLogEntry -Message "Uninstall failed for $($p.Name) ($($p.Code)): $msg" -Severity 3
            throw
        }
    }
