# Определяем пути
$Source = "\\192.168.88.3\Public"
$Destination = "D:\BackUp\Public"
$LogPath = "D:\Log\backup_Public.log"

# Создаем таймер
$Timer = [System.Diagnostics.Stopwatch]::StartNew()

Write-Host "Запуск копирования: $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Cyan

# Выполнение Robocopy
# Используем --% для корректной передачи путей с пробелами и спецсимволов
robocopy "$Source" "$Destination" /MIR /COPYALL /MT:12 /R:3 /W:5 /LOG:"$LogPath" /NP

# Останавливаем таймер
$Timer.Stop()

# Форматируем вывод времени
$Elapsed = $Timer.Elapsed
$TimeMessage = "Время выполнения: $($Elapsed.Hours)ч $($Elapsed.Minutes)м $($Elapsed.Seconds)с $($Elapsed.Milliseconds)мс"

Write-Host "--------------------------------"
Write-Host $TimeMessage -ForegroundColor Green
Write-Host "Лог сохранен в: $LogPath"
