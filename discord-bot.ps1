<#
  Discord bot for the Fortnite Ranked leaderboard. Commands: !leaderboard, !points [name],
  !ranked [name], !last10 <name>, !help. See README.md for the full list and setup.
  Leaderboard messages get a refresh reaction that only mods (Manage Messages / Manage Server /
  Administrator, or the server owner) can use.

  Setup: add your bot token to config.json:  "botToken": "..."
  (Developer Portal -> your app -> Bot -> Reset Token. Also turn on "Message Content Intent".)

  Run:   powershell -ExecutionPolicy Bypass -File discord-bot.ps1
  It stays running and reconnects on its own. Activity is logged to bot.log.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'leaderboard-lib.ps1')
$logPath = Join-Path $PSScriptRoot 'bot.log'
# Keep the log small: once it passes 1 MB, keep only the newest 2,000 lines.
if ((Test-Path $logPath) -and (Get-Item $logPath).Length -gt 1MB) {
  $tail = Get-Content -Encoding UTF8 $logPath -Tail 2000
  Set-Content -Encoding UTF8 -Path $logPath -Value $tail
}

$config = Get-LeaderboardConfig
if (-not $config.BotToken) { throw "Set botToken in $($config.Path)" }

$cacheSeconds = 60                  # reuse a fetch for this long so spamming the command is cheap
$intents = 1 + 512 + 1024 + 32768   # GUILDS + GUILD_MESSAGES + GUILD_MESSAGE_REACTIONS + MESSAGE_CONTENT
$script:botUserId = $null
$ct = [Threading.CancellationToken]::None

function Write-Log([string]$msg) {
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
  Write-Host $line
  Add-Content -Encoding UTF8 -Path $logPath -Value $line
}

function Send-Gateway($ws, $obj) {
  $bytes = ConvertTo-Utf8Json $obj
  $ws.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait()
}

$script:cache = $null
$script:cacheTime = [DateTime]::MinValue
function Get-CachedLeaderboard {
  if (((Get-Date) - $script:cacheTime).TotalSeconds -gt $cacheSeconds) {
    $script:cache = Get-FortniteLeaderboard -Mode $config.Mode
    $script:cacheTime = Get-Date
  }
  $script:cache
}

function New-HelpMessage {
  $commands = @(
    '**`!leaderboard`** - Top players on the Unreal leaderboard with their ELO.'
    '**`!points`** - The #1 player''s ELO.'
    '**`!points <name>`** - Any player''s ELO and rank.'
    '**`!ranked`** - How the ranked system works, in short.'
    '**`!ranked <name>`** - A player''s ranked breakdown: placement and zone stats, plus tips to gain ELO. Reload is shown separately.'
    '**`!last10 <name>`** - A player''s last 10 ranked games: result, kills, survival time and ELO change for each. (`!recent` works too.)'
    '**`!help`** - This list.'
  ) -join "`n"
  $notes = @(
    '- Commands must start the message: `!ranked Name`, not `nice !ranked Name`.'
    '- Names aren''t case-sensitive. A normal `!` matches Fortnite''s look-alike in names like `Mitsu!`.'
    '- The leaderboard post updates every 15 minutes. Mods can click the refresh reaction under it to update it right away.'
    '- The ELO post under the leaderboard shows what wins, placements and kills are worth, measured from top players every 6 hours.'
  ) -join "`n"
  @{
    embeds = @(@{
      title  = 'Fortnite Ranked Bot - Commands'
      color  = 0x9D4DFF
      fields = @(
        @{ name = 'Commands'; value = $commands }
        @{ name = 'Good to know'; value = $notes }
      )
      footer = @{ text = 'Data: fortnite.com, myfortnitestats.com, olitracker.com. ELO values are tracker estimates; Epic doesn''t publish exact ratings.' }
    })
    allowed_mentions = @{ parse = @() }
  }
}

# Returns the reply for a chat message, or $null if it isn't one of our commands.
#   !help / !commands       -> list of commands
#   !last10 Name / !recent  -> that player's last 10 ranked games
#   !leaderboard            -> top N players with points
#   !points                 -> the #1 player's points
#   !points Name / "Name"   -> that player's points (top 100 from the leaderboard, anyone else via their profile)
#   !ranked                 -> short explanation of how ranked works
#   !ranked Name            -> that player's ranked breakdown and tips to gain ELO
function Get-CommandReply([string]$content) {
  $content = $content.Trim()
  if ($content -ieq '!help' -or $content -ieq '!commands') { return New-HelpMessage }
  if ($content -ieq '!leaderboard') { return New-LeaderboardMessage (Get-CachedLeaderboard) -Top $config.Top -UpdatedNow }
  if ($content -match '^(?i)!(last10|recent)(\s+|$|(?="))(.*)$') {
    $name = $Matches[3].Trim().Trim('"', [char]0x201C, [char]0x201D).Trim()
    if (-not $name) { return @{ content = 'Add a player name: `!last10 <name>`'; allowed_mentions = @{ parse = @() } } }
    $player = Find-PlayerProfile $name
    if (-not $player) { return @{ content = "Couldn't find a player named **$(Format-DiscordText $name)**. Check the spelling of their Epic display name."; allowed_mentions = @{ parse = @() } } }
    return New-RecentGamesMessage $player (Get-OliTrackerStats $player.AccountId)
  }
  if ($content -match '^(?i)!ranked(\s+|$|(?="))(.*)$') {
    $name = $Matches[2].Trim().Trim('"', [char]0x201C, [char]0x201D).Trim()
    if (-not $name) { return New-RankedExplainerMessage }
    $player = Find-PlayerProfile $name
    if (-not $player) { return @{ content = "Couldn't find a player named **$(Format-DiscordText $name)**. Check the spelling of their Epic display name."; allowed_mentions = @{ parse = @() } } }
    return New-RankedBreakdownMessage $player (Get-OliTrackerStats $player.AccountId)
  }
  if ($content -notmatch '^(?i)!points(\s+|$|(?="))(.*)$') { return $null }
  $name = $Matches[2].Trim().Trim('"', [char]0x201C, [char]0x201D).Trim()

  $data = Get-CachedLeaderboard
  if (-not $name) { return New-PlayerPointsMessage $data.Entries[0] 'Top Player' }
  $key = ConvertTo-NameKey $name
  $entry = $data.Entries | Where-Object { (ConvertTo-NameKey $_.Name) -eq $key } | Select-Object -First 1
  if ($entry) { return New-PlayerPointsMessage $entry 'Player Points' }
  $player = Find-PlayerProfile $name
  if ($player) { return New-PlayerPointsMessage $player 'Player Points' }
  @{ content = "Couldn't find a player named **$(Format-DiscordText $name)**. Check the spelling of their Epic display name."; allowed_mentions = @{ parse = @() } }
}

function Send-Reply($channelId, $messageId, $payload) {
  $payload.message_reference = @{ message_id = $messageId; fail_if_not_exists = $false }
  $msg = Invoke-DiscordApi $config.BotToken Post "/channels/$channelId/messages" $payload
  if ($payload.embeds -and "$($payload.embeds[0].title)" -like 'Unreal Leaderboard*') { Add-RefreshReaction $config.BotToken $channelId $msg.id }
}

# --- Mod-only refresh reaction -----------------------------------------------
$modPermissions = 0x8 -bor 0x20 -bor 0x2000   # ADMINISTRATOR, MANAGE_GUILD, MANAGE_MESSAGES
$script:guildCache = @{}                      # guildId -> @{ Owner; Roles = @{ roleId = permissions }; Time }
$script:lastRefresh = [DateTime]::MinValue
$webhookId = if ($config.WebhookUrl -match '/webhooks/(\d+)/') { $Matches[1] } else { $null }

function Test-IsMod($guildId, $userId, $roleIds) {
  $g = $script:guildCache[$guildId]
  if (-not $g -or ((Get-Date) - $g.Time).TotalMinutes -gt 5) {
    $guild = Invoke-DiscordApi $config.BotToken Get "/guilds/$guildId"
    $roles = @{}; foreach ($r in $guild.roles) { $roles[$r.id] = [long]$r.permissions }
    $g = @{ Owner = $guild.owner_id; Roles = $roles; Time = Get-Date }
    $script:guildCache[$guildId] = $g
  }
  if ($userId -eq $g.Owner) { return $true }
  $perms = [long]$g.Roles[$guildId]            # @everyone's role id is the guild id
  foreach ($id in $roleIds) { $perms = $perms -bor [long]$g.Roles[$id] }
  ($perms -band $modPermissions) -ne 0
}

function Invoke-RefreshReaction($d) {
  $path = "/channels/$($d.channel_id)/messages/$($d.message_id)"
  $authorId = $d.message_author_id
  if (-not $authorId) { $authorId = (Invoke-DiscordApi $config.BotToken Get $path).author.id }   # not always included in the event
  $isWebhookMsg = $webhookId -and "$authorId" -eq "$webhookId"
  if (-not $isWebhookMsg -and "$authorId" -ne "$($script:botUserId)") { return }   # not one of our messages
  Write-Log "Refresh reaction from $($d.member.user.username) on message $($d.message_id)"

  # Take the user's reaction back off so the reaction is ready for the next click (needs Manage Messages).
  try { Invoke-DiscordApi $config.BotToken Delete "$path/reactions/$([Uri]::EscapeDataString($RefreshEmoji))/$($d.user_id)" | Out-Null } catch { }

  if (-not $d.guild_id -or -not (Test-IsMod $d.guild_id $d.user_id $d.member.roles)) {
    Write-Log "Ignored refresh from non-mod $($d.member.user.username)"; return
  }
  if (((Get-Date) - $script:lastRefresh).TotalSeconds -lt 5) { Write-Log 'Skipped refresh (less than 5 seconds since the last one)'; return }
  if (-not $isWebhookMsg) {
    $msg = Invoke-DiscordApi $config.BotToken Get $path
    if ("$($msg.embeds[0].title)" -notlike 'Unreal Leaderboard*') { return }
  }

  $script:lastRefresh = Get-Date
  $script:cacheTime = [DateTime]::MinValue     # always fetch fresh data for a manual refresh
  $payload = New-LeaderboardMessage (Get-CachedLeaderboard) -Top $config.Top -UpdatedNow
  if ($isWebhookMsg) {
    Invoke-RestMethod -Method Patch -Uri "$($config.WebhookUrl.TrimEnd('/'))/messages/$($d.message_id)" `
      -Body (ConvertTo-Utf8Json $payload) -ContentType 'application/json; charset=utf-8' | Out-Null
  } else {
    Invoke-DiscordApi $config.BotToken Patch $path $payload | Out-Null
  }
  Write-Log "Leaderboard refreshed by $($d.member.user.username)"
}

# Make sure the auto-updating webhook message has the refresh reaction too.
function Add-WebhookMessageReaction {
  $statePath = Join-Path $PSScriptRoot 'state.json'
  if (-not $webhookId -or -not (Test-Path $statePath)) { return }
  $state = Get-Content -Raw -Encoding UTF8 $statePath | ConvertFrom-Json
  $channelId = (Invoke-RestMethod -Uri $config.WebhookUrl).channel_id
  Add-RefreshReaction $config.BotToken $channelId $state.messageId
}

# --- Gateway loop ------------------------------------------------------------
while ($true) {
  $ws = New-Object Net.WebSockets.ClientWebSocket
  try {
    $ws.ConnectAsync([Uri]'wss://gateway.discord.gg/?v=10&encoding=json', $ct).Wait()
    Write-Log 'Connected to Discord.'
    $buf = New-Object byte[] 65536
    $ms = New-Object IO.MemoryStream
    $seq = $null
    $beatMs = 0
    $nextBeat = [DateTime]::MaxValue
    $pending = $null

    while ($ws.State -eq 'Open') {
      if (-not $pending) { $pending = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), $ct) }

      if ($pending.Wait(1000)) {
        $r = $pending.Result; $pending = $null
        if ($r.MessageType -eq 'Close') { Write-Log "Discord closed the connection ($($ws.CloseStatus) $($ws.CloseStatusDescription))."; break }
        $ms.Write($buf, 0, $r.Count)
        if (-not $r.EndOfMessage) { continue }
        $text = [Text.Encoding]::UTF8.GetString($ms.ToArray()); $ms.SetLength(0)

        # Only fully parse the events we care about; READY etc. can be large.
        if ($text -match '"s":(\d+)') { $seq = [long]$Matches[1] }
        $op = if ($text -match '"op":(\d+)') { [int]$Matches[1] } else { -1 }

        switch ($op) {
          10 {  # Hello: start heartbeating, then identify
            $beatMs = ($text | ConvertFrom-Json).d.heartbeat_interval
            $nextBeat = (Get-Date).AddMilliseconds($beatMs * (Get-Random -Minimum 0.0 -Maximum 1.0))
            Send-Gateway $ws @{ op = 2; d = @{ token = $config.BotToken; intents = $intents
              properties = @{ os = 'windows'; browser = 'fortnite-leaderboard'; device = 'fortnite-leaderboard' } } }
          }
          1  { $nextBeat = Get-Date }                       # Discord asked for a heartbeat now
          7  { Write-Log 'Discord asked us to reconnect.'; $ws.Abort() }
          9  { Write-Log 'Session invalidated; reconnecting.'; Start-Sleep 3; $ws.Abort() }
          0 {
            if ($text -match '"t":"READY"') {
              $script:botUserId = ($text | ConvertFrom-Json).d.user.id
              Write-Log 'Bot is online. Listening for !help, !leaderboard, !points, !ranked, !last10 and mod refresh reactions.'
              try { Add-WebhookMessageReaction } catch { Write-Log "Couldn't add refresh reaction to the auto-updating message: $($_.Exception.Message)" }
            }
            elseif ($text -match '"t":"MESSAGE_REACTION_ADD"') {
              $d = ($text | ConvertFrom-Json).d
              if ($d.emoji.name -eq $RefreshEmoji -and $d.user_id -ne $script:botUserId) {
                try { Invoke-RefreshReaction $d } catch { Write-Log "Refresh failed: $($_.Exception.Message)" }
              }
            }
            elseif ($text -match '"t":"MESSAGE_CREATE"') {
              $d = ($text | ConvertFrom-Json).d
              $cmd = "$($d.content)".Trim()
              if (-not $d.author.bot -and $cmd.StartsWith('!')) {
                try {
                  $reply = Get-CommandReply $cmd
                  if ($reply) {
                    Write-Log "$cmd from $($d.author.username) in channel $($d.channel_id)"
                    Send-Reply $d.channel_id $d.id $reply
                  }
                } catch { Write-Log "Failed to reply to '$cmd': $($_.Exception.Message) ($([IO.Path]::GetFileName($_.InvocationInfo.ScriptName)) line $($_.InvocationInfo.ScriptLineNumber))" }
              }
            }
          }
        }
      }

      if ((Get-Date) -ge $nextBeat -and $ws.State -eq 'Open') {
        Send-Gateway $ws @{ op = 1; d = $seq }
        $nextBeat = (Get-Date).AddMilliseconds($beatMs)
      }
    }
  } catch {
    $err = $_.Exception
    while ($err.InnerException) { $err = $err.InnerException }
    Write-Log "Connection error: $($err.Message)"
  }
  $closeCode = [int]$ws.CloseStatus
  $ws.Dispose()
  if ($closeCode -eq 4004) { Write-Log 'Discord rejected the bot token. Fix botToken in config.json.'; exit 1 }
  if ($closeCode -eq 4014) { Write-Log 'Turn on "Message Content Intent" in the Developer Portal (Bot page), then restart the bot.'; exit 1 }
  Start-Sleep 10
}

