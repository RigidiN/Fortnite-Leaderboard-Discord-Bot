<#
  Posts the Fortnite Ranked (Unreal) global leaderboard to a Discord channel via webhook.

  Setup: put your webhook URL in config.json next to this script:
    { "webhookUrl": "https://discord.com/api/webhooks/...", "top": 25, "mode": "battle-royale" }

  Run:      powershell -ExecutionPolicy Bypass -File fortnite-leaderboard.ps1
  Preview:  powershell -ExecutionPolicy Bypass -File fortnite-leaderboard.ps1 -DryRun

  The script keeps a single Discord message up to date (edits it each run) instead of
  posting a new one every time. Delete state.json to force a fresh message.
#>
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'leaderboard-lib.ps1')
$statePath = Join-Path $PSScriptRoot 'state.json'

$config = Get-LeaderboardConfig
if (-not $DryRun -and $config.WebhookUrl -notmatch '^https://(\w+\.)?discord(app)?\.com/api/webhooks/') { throw "Set webhookUrl in $($config.Path)" }

$data = Get-FortniteLeaderboard -Mode $config.Mode
$payload = New-LeaderboardMessage $data -Top $config.Top -UpdatedNow
$payload.username = 'Fortnite Ranked'
if ($DryRun) { $payload | ConvertTo-Json -Depth 8; return }

# --- Send (edit the existing messages if we have them) -----------------------
# Always edit, even if nothing changed, so "Leaderboard updated" resets every run.
$state = if (Test-Path $statePath) { Get-Content -Raw -Encoding UTF8 $statePath | ConvertFrom-Json } else { $null }
$hook = $config.WebhookUrl.TrimEnd('/')

# The ELO system post sits directly under the leaderboard. Its measurements are cached for 6 hours;
# if they can't be made, the leaderboard still updates on its own.
$eloPost = $null
try {
  $eloPost = New-EloSystemMessage $data (Get-EloModel)
  $eloPost.username = 'Fortnite Ranked'
} catch { Write-Host "Skipping ELO system post: $($_.Exception.Message)" }

function Edit-WebhookMessage($payload, $id) {
  if (-not $id) { return $null }
  try { Invoke-RestMethod -Method Patch -Uri "$hook/messages/$id" -Body (ConvertTo-Utf8Json $payload) -ContentType 'application/json; charset=utf-8' }
  catch { Write-Host "Couldn't edit message $id ($($_.Exception.Message))."; $null }
}
function Send-WebhookMessage($payload) {
  Invoke-RestMethod -Method Post -Uri "$hook`?wait=true" -Body (ConvertTo-Utf8Json $payload) -ContentType 'application/json; charset=utf-8'
}

$msg = Edit-WebhookMessage $payload $state.messageId
$eloMsg = if ($eloPost) { Edit-WebhookMessage $eloPost $state.eloMessageId } else { $null }

# If either message is missing (first run, or one was deleted), post both again as a pair
# so the ELO post stays directly under the leaderboard.
if (-not $msg -or ($eloPost -and -not $eloMsg)) {
  $msg = Send-WebhookMessage $payload
  # Webhooks can't react, so the bot adds the refresh button to the new leaderboard message.
  if ($config.BotToken) {
    try { Add-RefreshReaction $config.BotToken $msg.channel_id $msg.id } catch { Write-Host "Couldn't add refresh reaction: $($_.Exception.Message)" }
  }
  if ($eloPost) { $eloMsg = Send-WebhookMessage $eloPost }
  Write-Host 'Posted a new leaderboard + ELO system pair.'
}

@{ messageId = $msg.id; eloMessageId = $(if ($eloMsg) { $eloMsg.id } else { $state.eloMessageId }) } | ConvertTo-Json | Set-Content -Encoding UTF8 $statePath
Write-Host ("Updated leaderboard (message $($msg.id))" + $(if ($eloMsg) { " and ELO system post (message $($eloMsg.id))." } else { '.' }))
