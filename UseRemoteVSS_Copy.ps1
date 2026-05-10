<#
.SYNOPSIS
    UseRemoteVSS_Copy.ps1 — Оркестратор процесса резервного копирования из VSS.

.DESCRIPTION
    1. Загружает конфигурацию из config.ps1.
    2. Вызывает Mount-LatestShadowCopy.ps1 для подготовки VSS-шары.
    3. При успехе вызывает RemoteCopy.ps1 для копирования данных.
    4. В любом случае вызывает DisMount-LatestShadowCopy.ps1 для очистки.
#>

# Подключаем конфигурацию
$ConfigPath = Join-Path $PSScriptRoot "config.ps1"
if (Test-Path $ConfigPath) {
    . $ConfigPath
} else {
    Write-Error "Файл конфигурации '$ConfigPath' не найден!"
    exit 1
}

$GlobalTimer = [System.Diagnostics.Stopwatch]::StartNew()
$Success = $false

Write-Host "=== Запуск процесса VSS-копирования: $(Get-Date) ===" -ForegroundColor Magenta

try {
    # [Шаг 1] Монтирование теневой копии
    Write-Host "`n[Оркестратор] Шаг 1: Монтирование теневой копии..." -ForegroundColor Cyan
    & "$PSScriptRoot\Mount-LatestShadowCopy.ps1" `
        -RemoteComputer $RemoteComputer `
        -Volume $Volume `
        -MountRoot $MountRoot `
        -MountFolder $MountFolder `
        -ShareName $ShareName `
        -ShareAccess $ShareAccess `
        -Force

    if ($LASTEXITCODE -ne 0) {
        throw "Ошибка при монтировании теневой копии."
    }

    # [Шаг 2] Резервное копирование
    Write-Host "`n[Оркестратор] Шаг 2: Запуск копирования..." -ForegroundColor Cyan
    & "$PSScriptRoot\RemoteCopy.ps1" `
        -RemoteComputer $RemoteComputer `
        -ShareName $ShareName `
        -DestinationLocal $DestinationLocal `
        -LogPath $LogPath

    if ($LASTEXITCODE -ge 8) {
        throw "Критическая ошибка robocopy (код $LASTEXITCODE)."
    }

    $Success = $true
}
catch {
    Write-Host "`n[КРИТИЧЕСКАЯ ОШИБКА]: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    # [Шаг 3] Очистка (выполняется всегда)
    Write-Host "`n[Оркестратор] Шаг 3: Очистка ресурсов..." -ForegroundColor Cyan
    & "$PSScriptRoot\DisMount-LatestShadowCopy.ps1" `
        -RemoteComputer $RemoteComputer `
        -ShareName $ShareName `
        -MountRoot $MountRoot `
        -MountFolder $MountFolder

    $GlobalTimer.Stop()
    $Elapsed = $GlobalTimer.Elapsed

    Write-Host "`n=======================================================" -ForegroundColor Magenta
    if ($Success) {
        Write-Host "Задание успешно выполнено!" -ForegroundColor Green
    } else {
        Write-Host "Задание завершено с ошибками." -ForegroundColor Red
    }
    Write-Host "Общее время выполнения: $($Elapsed.Hours)ч $($Elapsed.Minutes)м $($Elapsed.Seconds)с" -ForegroundColor Magenta
    Write-Host "=======================================================" -ForegroundColor Magenta
}
