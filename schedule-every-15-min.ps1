# Registers a Windows scheduled task that runs fortnite-leaderboard.ps1 every 15 minutes
# while you're logged in. Remove it later with:
#   Unregister-ScheduledTask -TaskName 'Fortnite Leaderboard to Discord' -Confirm:$false
$script = Join-Path $PSScriptRoot 'fortnite-leaderboard.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`"" `
  -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName 'Fortnite Leaderboard to Discord' -Action $action -Trigger $trigger -Settings $settings -Force
