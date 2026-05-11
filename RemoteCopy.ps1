<#
.SYNOPSIS
    RemoteCopy.ps1 — Резервное копирование выбранных путей из VSS-шары на локальный диск.

.DESCRIPTION
    Скрипт формирует сетевые пути к объектам внутри временной VSS-шары на удалённом сервере
    и последовательно запускает robocopy для их копирования.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$RemoteComputer,

    [Parameter(Mandatory=$true)]
    [string]$ShareName,

    [Parameter(Mandatory=$true)]
    [string[]]$VssSourcePaths,

    [Parameter(Mandatory=$true)]
    [string]$DestinationLocal,

    [Parameter(Mandatory=$true)]
    [string]$LogPath
)

# [Шаг 1] Инициализация процесса копирования
Write-Host "[Шаг 1] Инициализация процесса копирования..." -ForegroundColor Yellow

# Валидация входных путей
if ($null -eq $VssSourcePaths -or $VssSourcePaths.Count -eq 0) {
    Write-Host "ОШИБКА: Не указаны исходные пути для копирования ($VssSourcePaths)." -ForegroundColor Red
    exit 8
}

$BaseShare = "\\$RemoteComputer\$ShareName"
$Timer = [System.Diagnostics.Stopwatch]::StartNew()
$OverallExitCode = 0

Write-Host "VSS-шара: $BaseShare"
Write-Host "Локальное назначение: $DestinationLocal"
Write-Host "Время начала: $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Cyan

# [Шаг 2] Проверка доступности базовой шары и подготовка логов
Write-Host "[Шаг 2] Проверка доступности инфраструктуры..." -ForegroundColor Yellow

if (-not (Test-Path -LiteralPath $BaseShare)) {
    Write-Host "Ошибка: Сетевая шара '$BaseShare' недоступна." -ForegroundColor Red
    exit 8
}

# Проверяем и создаем папку для лога, если она отсутствует
$LogDir = Split-Path -Path $LogPath -Parent
if ($LogDir -and -not (Test-Path -Path $LogDir)) {
    try {
        New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction Stop | Out-Null
        Write-Host "Создана папка для логов: $LogDir" -ForegroundColor Gray
    } catch {
        Write-Warning "Не удалось создать папку для логов: $($_.Exception.Message)"
    }
}

# Очищаем лог-файл перед началом новой сессии
if (Test-Path -Path $LogPath) {
    Remove-Item -Path $LogPath -Force -ErrorAction SilentlyContinue
}

# [Шаг 3] Итерационное копирование путей
Write-Host "`n[Шаг 3] Обработка списка путей..." -ForegroundColor Yellow

foreach ($Path in $VssSourcePaths) {
    Write-Host "`n--- Обработка: $Path ---" -ForegroundColor Cyan

    # Проверка формата пути (должен начинаться с буквы диска, например F:\)
    if ($Path.Length -lt 2 -or $Path[1] -ne ':') {
        Write-Host "ОШИБКА: Некорректный формат пути '$Path'. Ожидается абсолютный путь (например 'F:\Folder')." -ForegroundColor Red
        $OverallExitCode = 8
        continue
    }

    # 1. Формируем путь внутри шары.
    # Входной формат: "F:\Folder" -> результат "\\Server\Share\Folder"
    # Извлекаем часть после буквы диска и двоеточия (например, "\Folder")
    $RelativePath = $Path.Substring(2).TrimStart('\')
    $FullSourcePath = if ([string]::IsNullOrWhiteSpace($RelativePath)) { $BaseShare } else { Join-Path $BaseShare $RelativePath }

    # 2. Проверяем существование исходного объекта (используем -LiteralPath для корректной обработки спецсимволов)
    if (-not (Test-Path -LiteralPath $FullSourcePath)) {
        Write-Host "ОШИБКА: Путь '$Path' не найден в теневой копии (проверялся '$FullSourcePath')." -ForegroundColor Red
        $OverallExitCode = 8
        continue
    }

    # 3. Определяем, файл это или папка, и формируем параметры robocopy
    $IsDirectory = Test-Path -LiteralPath $FullSourcePath -PathType Container

    if ($IsDirectory) {
        # Для папки: Robocopy "Источник" "Назначение\Подпапка"
        $CurrentDest = if ([string]::IsNullOrWhiteSpace($RelativePath)) { $DestinationLocal } else { Join-Path $DestinationLocal $RelativePath }
        $SourceDir = $FullSourcePath
        $FilesSpec = "*"
    } else {
        # Для файла: Robocopy "Источник_папка" "Назначение_папка" "Имя_файла"
        $FileInfo = Get-Item -LiteralPath $FullSourcePath
        $SourceDir = $FileInfo.DirectoryName
        $FilesSpec = $FileInfo.Name
        $CurrentDest = if ([string]::IsNullOrWhiteSpace($RelativePath)) { $DestinationLocal } else { Join-Path $DestinationLocal (Split-Path $RelativePath -Parent) }
    }

    Write-Host "Копирование в: $CurrentDest" -ForegroundColor Gray

    # 4. Запуск Robocopy
    # Параметры:
    # /MIR - Зеркальное отображение (только для папок)
    # /COPYALL - Копировать всю информацию
    # /MT:12 - 12 потоков
    # /R:3 /W:5 - Повторы при ошибках
    # /LOG+ - Дозапись в лог
    # /NP - Без прогресса

    if ($IsDirectory) {
        robocopy "$SourceDir" "$CurrentDest" /MIR /COPYALL /MT:12 /R:3 /W:5 /LOG+:"$LogPath" /NP
    } else {
        robocopy "$SourceDir" "$CurrentDest" "$FilesSpec" /COPYALL /MT:12 /R:3 /W:5 /LOG+:"$LogPath" /NP
    }

    $CurrentExitCode = $LASTEXITCODE
    if ($CurrentExitCode -ge 8) {
        Write-Host "Ошибка при копировании '$Path' (код $CurrentExitCode)." -ForegroundColor Red
        $OverallExitCode = $CurrentExitCode
    } else {
        Write-Host "Копирование завершено успешно (код $CurrentExitCode)." -ForegroundColor Green
    }
}

# [Шаг 4] Итоги выполнения
$Timer.Stop()
$Elapsed = $Timer.Elapsed
$TimeMessage = "Время выполнения: $($Elapsed.Hours)ч $($Elapsed.Minutes)м $($Elapsed.Seconds)с"

Write-Host "`n--------------------------------"
if ($OverallExitCode -lt 8) {
    Write-Host "Процесс копирования успешно завершен." -ForegroundColor Green
} else {
    Write-Host "Процесс завершен с ошибками." -ForegroundColor Red
}
Write-Host $TimeMessage
Write-Host "Подробный лог: $LogPath"

exit $OverallExitCode
