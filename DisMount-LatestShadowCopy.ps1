<#
.SYNOPSIS
    DisMount-LatestShadowCopy.ps1 — Безопасное удаление временной VSS-шары и точки монтирования.

.DESCRIPTION
    Скрипт удалённо подключается к серверу и выполняет очистку:
    1. Удаляет SMB-шару.
    2. Удаляет символическую ссылку (junction point).
    3. При необходимости удаляет пустую родительскую папку.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$RemoteComputer,

    [Parameter(Mandatory=$true)]
    [string]$ShareName,

    [Parameter(Mandatory=$true)]
    [string]$MountRoot,

    [Parameter(Mandatory=$true)]
    [string]$MountFolder
)

# Собираем путь вручную, т.к. Join-Path может проверять наличие диска локально (актуально, если MountRoot на Z: и т.п.)
$MountPath = $MountRoot.TrimEnd('\') + "\" + $MountFolder.TrimStart('\')

Write-Host "Запуск очистки на $RemoteComputer..." -ForegroundColor Cyan

Invoke-Command -ComputerName $RemoteComputer -ArgumentList $ShareName, $MountPath, $MountRoot -ScriptBlock {
    param($ShareName, $MountPath, $MountRoot)

    # [Шаг 1] Удаление SMB-шары
    Write-Host "[Шаг 1] Удаление SMB-шары '$ShareName'..." -ForegroundColor Yellow
    if (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue) {
        try {
            Remove-SmbShare -Name $ShareName -Force -ErrorAction Stop
            Write-Host "SMB-шара '$ShareName' успешно удалена." -ForegroundColor Green
        } catch {
            Write-Warning "Не удалось удалить SMB-шару '$ShareName': $($_.Exception.Message)"
        }
    } else {
        Write-Host "SMB-шара '$ShareName' не найдена, пропуск."
    }

    # [Шаг 2] Удаление символической ссылки
    Write-Host "[Шаг 2] Удаление символической ссылки '$MountPath'..." -ForegroundColor Yellow
    if (Test-Path $MountPath) {
        try {
            # Используем rmdir для безопасного удаления точки монтирования (не затрагивая файлы)
            cmd /c rmdir "`"$MountPath`""
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Точка монтирования '$MountPath' успешно удалена." -ForegroundColor Green
            } else {
                Write-Warning "Ошибка при выполнении rmdir (код $LASTEXITCODE)."
            }
        } catch {
            Write-Warning "Не удалось удалить точку монтирования: $($_.Exception.Message)"
        }
    } else {
        Write-Host "Точка монтирования '$MountPath' не найдена, пропуск."
    }

    # [Шаг 3] Очистка родительской папки
    Write-Host "[Шаг 3] Проверка родительской папки '$MountRoot'..." -ForegroundColor Yellow
    if (Test-Path $MountRoot) {
        $items = Get-ChildItem -Path $MountRoot -ErrorAction SilentlyContinue
        if ($null -eq $items -or $items.Count -eq 0) {
            try {
                Remove-Item -Path $MountRoot -Force -ErrorAction Stop
                Write-Host "Пустая родительская папка '$MountRoot' удалена." -ForegroundColor Green
            } catch {
                Write-Warning "Не удалось удалить родительскую папку: $($_.Exception.Message)"
            }
        } else {
            Write-Host "Родительская папка не пуста, оставляем."
        }
    }
}

Write-Host "Очистка завершена." -ForegroundColor Cyan
