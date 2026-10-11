# Stops the bot and removes both background tasks. Your files, config and Discord posts are left alone.
foreach ($name in 'Fortnite Leaderboard Bot', 'Fortnite Leaderboard to Discord') {
  $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  if ($task) {
    Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
    Write-Host "Removed task: $name"
  } else {
    Write-Host "Not installed: $name"
  }
}
Write-Host 'Done. Run setup.ps1 to install again.'
