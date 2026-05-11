<#
.SYNOPSIS
    Mount-LatestShadowCopy.ps1 — Подключение последней теневой копии тома и публикация по SMB.

.DESCRIPTION
    Скрипт удалённо подключается к файловому серверу, находит самую свежую теневою копию
    указанного диска (например D:), создаёт на неё символьную ссылку (mklink /d) и
    открывает к этой ссылке общий сетевой доступ (SMB-шару).

    Это позволяет моментально получить доступ к точке восстановления данных без 
    необходимости вручную монтировать теневые копии на сервере.

    Основные шаги:
    1. Поиск последней теневой копии для заданного тома.
    2. Подготовка точки монтирования и создание символьной ссылки на копию.
    3. Создание (или пересоздание) SMB-шары, ведущей на символьную ссылку.
    4. Вывод итоговой информации о полученном сетевом пути.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$RemoteComputer, # Имя или IP-адрес удаленного сервера (например, "192.168.88.3" или "FS01.domain.local")

    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[A-Za-z]:$')]
    [string]$Volume,          # Буква тома с двоеточием: "D:", "F:" и т.п.

    [string]$MountRoot = "C:\ShadowMounts",   # Корневая папка на сервере для точек монтирования (по умолчанию C:\ShadowMounts).
                                              # Пример: -MountRoot "C:\VSS"

    [string]$MountFolder,     # Имя подпапки, куда будет смонтирована теневая копия.
                              # Если не указано, автоматически формируется как "Latest_<буква>" (например "Latest_D").
                              # Пример: -MountFolder "Snapshot_D"

    [string]$ShareName,       # Имя SMB-шары.
                              # Если не указано, формируется автоматически как "Disk_<буква>_$" (скрытая шара).
                              # Пример: -ShareName "Disk_D_$"

    [string]$ShareAccess = "Everyone",  # Кому предоставить полный доступ к шаре. По умолчанию "Everyone".
                                        # Можно указать группу домена: "DOMAIN\Domain Admins".

    [switch]$Force            # Принудительно удалить существующую точку монтирования перед созданием новой.
                              # Без этого ключа скрипт остановится, если папка уже существует.
)

# ============================== Подготовка параметров до удалённого вызова ==============================
$VolumePath = "$Volume\"                            # Том в формате "D:\"
$volumeLetter = $Volume.TrimEnd(':')                # Буква диска без двоеточия, например "D"

# Автоматическое формирование имён, если они не заданы явно
if (-not $MountFolder) { $MountFolder = "Latest_$volumeLetter" }
if (-not $ShareName)   { $ShareName   = "Disk_${volumeLetter}_$" }

# Собираем путь вручную, т.к. Join-Path может проверять наличие диска локально (актуально, если MountRoot на Z: и т.п.)
$MountPath = $MountRoot.TrimEnd('\') + "\" + $MountFolder.TrimStart('\')

Write-Host "Подключение к $RemoteComputer, том $Volume ..." -ForegroundColor Cyan

# ============================== Удалённое выполнение на целевом сервере ==============================
Invoke-Command -ComputerName $RemoteComputer -ArgumentList $VolumePath, $MountPath, $ShareName, $ShareAccess, $Force, $volumeLetter -ScriptBlock {

    param($VolumePath, $MountPath, $ShareName, $ShareAccess, $Force, $volumeLetter)

    # ----- Шаг 1: Поиск последней теневой копии для заданного тома ---------------------------------------
    Write-Host "[Шаг 1] Поиск последней теневой копии для тома $VolumePath..." -ForegroundColor Yellow

    # 1.1 Получаем DeviceID тома по букве диска (VolumeName в ShadowCopy соответствует DeviceID в Win32_Volume)
    $targetVolume = Get-CimInstance -ClassName Win32_Volume -ErrorAction Stop |
                    Where-Object { $_.DriveLetter -eq "$($volumeLetter):" } |
                    Select-Object -First 1

    if (-not $targetVolume) {
        throw "Том $($volumeLetter): не найден на сервере $env:COMPUTERNAME"
    }

    $targetDeviceId = $targetVolume.DeviceID
    Write-Host "ID тома: $targetDeviceId" -ForegroundColor Gray

    # 1.2 Получаем все теневые копии на сервере и фильтруем по найденному DeviceID
    $allShadows = Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction Stop |
                  Where-Object { $_.VolumeName -eq $targetDeviceId }

    # Если подходящие копии не найдены — аварийно завершаем
    if (-not $allShadows) {
        throw "Теневые копии для тома $($volumeLetter): не найдены на $env:COMPUTERNAME"
    }

    # Сортируем по дате установки (Get-CimInstance уже возвращает InstallDate как DateTime)
    $latestShadow = $allShadows | Sort-Object InstallDate -Descending | Select-Object -First 1

    # Извлекаем путь к устройству теневой копии (например "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy123")
    $deviceObject = $latestShadow.DeviceObject + "\"    # Добавляем слеш, т.к. это каталог
    Write-Host "Найдена копия от $($latestShadow.InstallDate)" -ForegroundColor Green
    Write-Host "Устройство теневой копии: $deviceObject" -ForegroundColor Gray

    # ----- Шаг 2: Подготовка точки монтирования и создание символьной ссылки --------------------------------
    Write-Host "[Шаг 2] Подготовка точки монтирования $MountPath..." -ForegroundColor Yellow

    # Проверяем, существует ли уже конечная папка (симлинк или обычный каталог)
	if (Test-Path $MountPath) {
		if ($Force) {
			# Удаляем старую точку монтирования БЕЗОПАСНО через rmdir.
			# rmdir удаляет только саму directory junction, не затрагивая содержимое целевого тома.
			cmd.exe /c rmdir "`"$MountPath`""   # Внешние кавычки экранированы
			if ($LASTEXITCODE -ne 0) {
				Write-Warning "Не удалось удалить старую точку монтирования '$MountPath'. Проверьте, не используется ли она."
			} else {
				Write-Host "Старая точка монтирования '$MountPath' удалена."
			}
		} else {
			throw "Путь '$MountPath' уже существует. Используйте -Force для перезаписи."
		}
	}	

    # Создаём родительский каталог (C:\ShadowMounts), если его ещё нет
    $parentDir = Split-Path $MountPath -Parent
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        Write-Host "Создана родительская папка: $parentDir" -ForegroundColor Gray
    }

    # Создание символьной ссылки на каталог через cmd /c mklink /d
    # Используем Invoke-Expression, чтобы корректно передать кавычки и спецсимволы
    $cmd = "cmd.exe /c mklink /d `"$MountPath`" `"$deviceObject`""
    Write-Verbose "Выполняется: $cmd" -Verbose:$false   # раскомментируйте для отладки
    Invoke-Expression $cmd

    # Проверяем код возврата команды mklink (0 = успех)
    if ($LASTEXITCODE -ne 0) {
        throw "Ошибка создания символьной ссылки (код $LASTEXITCODE). Проверьте права и доступность теневой копии."
    }
    Write-Host "Символьная ссылка создана: $MountPath -> $deviceObject" -ForegroundColor Green

    # ----- Шаг 3: Создание (или пересоздание) SMB-шары -----------------------------------------------
    Write-Host "[Шаг 3] Настройка SMB-шары '$ShareName'..." -ForegroundColor Yellow

    # Проверяем, существует ли уже такая шара
    $existingShare = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
    if ($existingShare) {
        # Удаляем старую шару, чтобы гарантированно перенаправить её на новую точку монтирования
        Remove-SmbShare -Name $ShareName -Force
        Write-Host "Удалена существующая шара '$ShareName' (путь: $($existingShare.Path))" -ForegroundColor Gray
    }

    # Создаём новую SMB-шару с указанным именем, путём к символьной ссылке и правами доступа
    New-SmbShare -Name $ShareName -Path $MountPath -FullAccess $ShareAccess -ErrorAction Stop
    Write-Host "Шара '$ShareName' создана. Полный доступ: $ShareAccess" -ForegroundColor Green

    # ----- Шаг 4: Вывод итоговой информации ---------------------------------------------------------
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
