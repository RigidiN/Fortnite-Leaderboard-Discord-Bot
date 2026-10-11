# One-step install: checks config.json, then sets up both background tasks:
#   - "Fortnite Leaderboard to Discord": updates the leaderboard + ELO posts every 15 minutes
#   - "Fortnite Leaderboard Bot": the command bot, started now and at every login
# Safe to run again (it replaces the existing tasks). Undo with uninstall.ps1.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'leaderboard-lib.ps1')

$config = Get-LeaderboardConfig
if (-not (Test-Path $config.Path)) { throw "config.json not found. Copy config.example.json to config.json and fill it in." }
if ($config.WebhookUrl -notmatch '^https://(\w+\.)?discord(app)?\.com/api/webhooks/') { throw 'Set webhookUrl in config.json (Discord channel settings > Integrations > Webhooks).' }
if ("$($config.BotToken)" -notmatch '^[\w-]{20,}\.[\w-]{4,}\.[\w-]{20,}$') { throw 'Set botToken in config.json (Developer Portal > your app > Bot > Reset Token).' }

Write-Host 'Config looks good. Posting the leaderboard...'
& (Join-Path $PSScriptRoot 'fortnite-leaderboard.ps1')

Write-Host 'Scheduling 15-minute updates...'
& (Join-Path $PSScriptRoot 'schedule-every-15-min.ps1') | Out-Null

Write-Host 'Starting the command bot...'
& (Join-Path $PSScriptRoot 'start-bot-at-login.ps1')

Write-Host "`nAll set. Type !help in your Discord channel to see the commands."
