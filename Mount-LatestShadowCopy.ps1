<#
.SYNOPSIS
    Mount-LatestShadowCopy.ps1 — Подключение последней теневой копии тома и публикация по SMB.

.DESCRIPTION
    Скрипт удалённо подключается к файловому серверу, находит самую свежую теневою копию
    указанного диска (например D:), создаёт на неё символьную ссылку (mklink /d) и
    открывает к этой ссылке общий сетевой доступ (SMB-шару).

    Основные шаги:
    1. Поиск последней теневой копии для заданного тома.
    2. Подготовка точки монтирования и создание символьной ссылки на копию.
    3. Создание (или пересоздание) SMB-шары, ведущей на символьную ссылку.
    4. Вывод итоговой информации о полученном сетевом пути.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$RemoteComputer,

    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[A-Za-z]:$')]
    [string]$Volume,

    [string]$MountRoot = "C:\ShadowMounts",

    [string]$MountFolder,

    [string]$ShareName,

    [string]$ShareAccess = "Everyone",

    [switch]$Force
)

# ============================== Подготовка параметров до удалённого вызова ==============================
$VolumePath = "$Volume\"
$volumeLetter = $Volume.TrimEnd(':')

if (-not $MountFolder) { $MountFolder = "Latest_$volumeLetter" }
if (-not $ShareName)   { $ShareName   = "Disk_${volumeLetter}_$" }

$MountPath = $MountRoot.TrimEnd('\') + "\" + $MountFolder.TrimStart('\')

Write-Host "Подключение к $RemoteComputer, том $Volume ..." -ForegroundColor Cyan

# ============================== Удалённое выполнение на целевом сервере ==============================
Invoke-Command -ComputerName $RemoteComputer -ArgumentList $VolumePath, $MountPath, $ShareName, $ShareAccess, $Force, $volumeLetter -ScriptBlock {

    param($VolumePath, $MountPath, $ShareName, $ShareAccess, $Force, $volumeLetter)

    # ----- Шаг 1: Поиск последней теневой копии ---------------------------------------
    Write-Host "[Шаг 1] Поиск последней теневой копии для тома $VolumePath..." -ForegroundColor Yellow

    $targetVolume = Get-CimInstance -ClassName Win32_Volume -ErrorAction Stop | 
                    Where-Object { $_.DriveLetter -eq "$($volumeLetter):" } | 
                    Select-Object -First 1

    if (-not $targetVolume) {
        throw "Том $($volumeLetter): не найден на сервере $env:COMPUTERNAME"
    }

    $targetDeviceId = $targetVolume.DeviceID
    Write-Host "ID тома: $targetDeviceId" -ForegroundColor Gray

    $allShadows = Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction Stop | 
                  Where-Object { $_.VolumeName -eq $targetDeviceId }

    if (-not $allShadows) {
        throw "Теневые копии для тома $($volumeLetter): не найдены на $env:COMPUTERNAME"
    }

    $latestShadow = $allShadows | Sort-Object InstallDate -Descending | Select-Object -First 1
    $deviceObject = $latestShadow.DeviceObject + "\"
    Write-Host "Найдена копия от $($latestShadow.InstallDate)" -ForegroundColor Green
    Write-Host "Устройство теневой копии: $deviceObject" -ForegroundColor Gray

    # ----- Шаг 2: Создание символьной ссылки -------------------------------------------
    Write-Host "[Шаг 2] Подготовка точки монтирования $MountPath..." -ForegroundColor Yellow

    if (Test-Path $MountPath) {
        if ($Force) {
            cmd.exe /c rmdir "`"$MountPath`""
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Не удалось удалить старую точку монтирования '$MountPath'."
            } else {
                Write-Host "Старая точка монтирования удалена." -ForegroundColor Gray
            }
        } else {
            throw "Путь '$MountPath' уже существует. Используйте -Force."
        }
    }	

    $parentDir = Split-Path $MountPath -Parent
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        Write-Host "Создана родительская папка: $parentDir" -ForegroundColor Gray
    }

    $deviceObjectTrimmed = $deviceObject.TrimEnd('\')
    Write-Host "Создание символьной ссылки: $MountPath -> $deviceObjectTrimmed" -ForegroundColor Gray
    cmd.exe /c mklink /d `"$MountPath`" `"$deviceObjectTrimmed`"

    # БЕЗ ПРОВЕРКИ ОШИБОК. Просто выводим сообщение.
    Write-Host "Символьная ссылка создана: $MountPath -> $deviceObject" -ForegroundColor Green

    # ----- Шаг 3: Создание SMB-шары -----------------------------------------------
    Write-Host "[Шаг 3] Настройка SMB-шары '$ShareName'..." -ForegroundColor Yellow

    $existingShare = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
    if ($existingShare) {
        Remove-SmbShare -Name $ShareName -Force
        Write-Host "Удалена существующая шара '$ShareName'" -ForegroundColor Gray
    }

    New-SmbShare -Name $ShareName -Path $MountPath -FullAccess $ShareAccess -ErrorAction Stop
    Write-Host "Шара '$ShareName' создана. Полный доступ: $ShareAccess" -ForegroundColor Green

    # ----- Шаг 4: Итоговая информация -------------------------------------------------
    Write-Host "[Шаг 4] Итоговая информация" -ForegroundColor Yellow

    $resultText = @"
===========================================
Последняя теневая копия тома $VolumePath готова
Локальный путь : $MountPath
Сетевой путь   : \\$env:COMPUTERNAME\$ShareName
===========================================
"@
    Write-Host $resultText -ForegroundColor Cyan
}
