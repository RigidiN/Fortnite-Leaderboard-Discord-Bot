# Registers a Windows scheduled task that starts discord-bot.ps1 when you log in
# (and starts it right now). Remove it later with:
#   Unregister-ScheduledTask -TaskName 'Fortnite Leaderboard Bot' -Confirm:$false
$script = Join-Path $PSScriptRoot 'discord-bot.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`"" `
  -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'Fortnite Leaderboard Bot' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'Fortnite Leaderboard Bot'
Write-Host 'Bot started. It will also start automatically when you log in. See bot.log for activity.'
