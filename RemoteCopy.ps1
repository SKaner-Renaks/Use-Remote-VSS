<#
.SYNOPSIS
    RemoteCopy.ps1 — Резервное копирование данных из VSS-шары на локальный диск.

.DESCRIPTION
    Скрипт формирует сетевой путь к временной VSS-шаре на удалённом сервере
    и запускает robocopy для синхронизации данных.
#>

param(
    [string]$RemoteComputer,
    [string]$ShareName,
    [string]$DestinationLocal,
    [string]$LogPath
)

# [Шаг 1] Формирование путей и инициализация таймера
Write-Host "[Шаг 1] Инициализация процесса копирования..." -ForegroundColor Yellow

$Source = "\\$RemoteComputer\$ShareName"
$Timer = [System.Diagnostics.Stopwatch]::StartNew()

Write-Host "Источник: $Source"
Write-Host "Назначение: $DestinationLocal"
Write-Host "Время начала: $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Cyan

# [Шаг 2] Проверка доступности источника
if (-not (Test-Path $Source)) {
    Write-Host "Ошибка: Сетевой путь '$Source' недоступен." -ForegroundColor Red
    exit 8
}

# [Шаг 3] Запуск robocopy
Write-Host "[Шаг 3] Запуск robocopy..." -ForegroundColor Yellow

# Используем проверенный набор ключей из test_public.ps1
# /MIR - Зеркальное отображение
# /COPYALL - Копировать всю информацию о файлах
# /MT:12 - Многопоточность (12 потоков)
# /R:3 - 3 попытки при ошибке
# /W:5 - 5 секунд ожидания между попытками
# /LOG - Запись в лог
# /NP - Без отображения прогресса в консоли (для чистоты вывода)
robocopy "$Source" "$DestinationLocal" /MIR /COPYALL /MT:12 /R:3 /W:5 /LOG:"$LogPath" /NP

# robocopy возвращает специфичные коды (0-7 — успех или мелкие изменения, 8+ — критические ошибки)
$ExitCode = $LASTEXITCODE
Write-Host "Robocopy завершился с кодом: $ExitCode"

# [Шаг 4] Итоги выполнения
$Timer.Stop()
$Elapsed = $Timer.Elapsed
$TimeMessage = "Время выполнения копирования: $($Elapsed.Hours)ч $($Elapsed.Minutes)м $($Elapsed.Seconds)с"

if ($ExitCode -lt 8) {
    Write-Host "--------------------------------"
    Write-Host "Копирование успешно завершено!" -ForegroundColor Green
    Write-Host $TimeMessage -ForegroundColor Green
} else {
    Write-Host "--------------------------------"
    Write-Host "Копирование завершилось с ошибками (код $ExitCode)." -ForegroundColor Red
    Write-Host $TimeMessage -ForegroundColor Red
}

Write-Host "Подробный лог: $LogPath"
