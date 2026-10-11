# Shared code: fetches the Fortnite Ranked (Unreal) leaderboard and builds Discord messages.
# Dot-sourced by fortnite-leaderboard.ps1 (webhook) and discord-bot.ps1 (!leaderboard / !points).

function Get-LeaderboardConfig {
  $path = Join-Path $PSScriptRoot 'config.json'
  $c = if (Test-Path $path) { Get-Content -Raw -Encoding UTF8 $path | ConvertFrom-Json } else { [pscustomobject]@{} }
  [pscustomobject]@{
    Path       = $path
    WebhookUrl = $c.webhookUrl
    BotToken   = $c.botToken
    Top        = $(if ($c.top) { [int]$c.top } else { 25 })
    Mode       = $(if ($c.mode) { $c.mode } else { 'battle-royale' })
  }
}

# Both sites sit behind Cloudflare; curl with browser-like headers gets through,
# while PowerShell's own web client gets a 403 challenge.
function Get-WebText([string]$Url) {
  $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
  $tmp = [IO.Path]::GetTempFileName()
  try {
    $code = & curl.exe -s -L -A $ua -H 'Accept: */*' -H 'Accept-Language: en-US' -o $tmp -w '%{http_code}' $Url
    if ($code -ne '200') { throw "Request to $Url failed with HTTP $code" }
    [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
  } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

# Epic doesn't publish points, so ELO comes from myfortnitestats.com (Battle Royale only).
# Returns a list of (Rank, Name, Elo); empty if the site is unavailable or its layout changed.
function Get-PlayerPoints {
  $points = New-Object Collections.Generic.List[object]
  try {
    Add-Type -AssemblyName System.Web
    $html = Get-WebText 'https://myfortnitestats.com/leaderboard'
    $start = $html.IndexOf('id="rankedTable"')
    if ($start -lt 0) { return $points }
    $table = $html.Substring($start, $html.IndexOf('</table>', $start) - $start)
    $rows = [regex]::Matches($table, '(?s)rank-cell[^"]*">(\d+)</td>.*?class="player-name"[^>]*>\s*(.*?)\s*</a>.*?elo-inline">([\d,]+)<')
    foreach ($m in $rows) {
      $points.Add([pscustomobject]@{ Rank = [int]$m.Groups[1].Value; Name = [Web.HttpUtility]::HtmlDecode($m.Groups[2].Value); Elo = [int]($m.Groups[3].Value -replace ',') })
    }
  } catch { }
  , $points
}

# Match ELO to Epic's entries by name; if a name isn't found (e.g. the player renamed),
# use the tracker's player at the same rank as long as that player isn't elsewhere on Epic's list.
function Add-PlayerPoints($Entries, $Points) {
  $byName = @{}; $byRank = @{}
  foreach ($p in $Points) { $byName[$p.Name] = $p.Elo; $byRank[$p.Rank] = $p }
  $epicNames = @{}; foreach ($e in $Entries) { $epicNames[$e.Name] = $true }
  foreach ($e in $Entries) {
    if ($byName.ContainsKey($e.Name)) { $e.Points = $byName[$e.Name] }
    elseif ($byRank.ContainsKey($e.Rank) -and -not $epicNames.ContainsKey($byRank[$e.Rank].Name)) { $e.Points = $byRank[$e.Rank].Elo }
  }
}

# Returns the leaderboard as data: UpdatedTime, Season, ModeName, Mode, Entries (Rank, Name, Points)
function Get-FortniteLeaderboard([string]$Mode = 'battle-royale') {
  $raw = Get-WebText "https://www.fortnite.com/ranked/leaderboard.data?mode=$Mode"

  # The response is Remix "turbo-stream": a flat JSON array where objects look like
  # {"_<keyIndex>": <valueIndex>} and arrays hold indexes. Negative indexes are null-ish.
  $flat = ($raw -split "`n")[0] | ConvertFrom-Json
  function Expand-Node([int]$i) {
    if ($i -lt 0) { return $null }
    $v = $flat[$i]
    if ($v -is [pscustomobject]) {
      $o = @{}
      foreach ($p in $v.PSObject.Properties) { $o[$flat[[int]$p.Name.Substring(1)]] = Expand-Node $p.Value }
      return $o
    }
    if ($v -is [array]) { return ,@($v | ForEach-Object { Expand-Node $_ }) }
    return $v
  }
  $data = (Expand-Node 0)['routes/ranked.leaderboard._index']['data']
  $board = $data['leaderboard']
  if (-not $board -or -not $board['entries']) { throw 'Leaderboard data not found; the page format may have changed.' }

  $entries = @(foreach ($e in $board['entries']) { [pscustomobject]@{ Rank = [int]$e['rank']; Name = $e['displayName']; Points = $null } })
  if ($Mode -eq 'battle-royale') { Add-PlayerPoints $entries (Get-PlayerPoints) }
  [pscustomobject]@{
    UpdatedTime = $board['updatedTime']
    TotalPages  = [int]$board['totalPages']        # 100 players per page
    Season      = $data['selectedLeaderboard']['season']['viewValue']
    ModeName    = $data['selectedLeaderboard']['selectedMode']['viewValue']
    Mode        = $Mode
    Entries     = $entries
  }
}

function Format-Points($p) { if ($null -eq $p) { '?' } else { ([int]$p).ToString('N0', [Globalization.CultureInfo]::InvariantCulture) } }
function Format-DiscordText([string]$s) { $s -replace '([\\*_~`|>#\[\]()-])', '\$1' }

# Looks a player up on myfortnitestats.com. Returns $null if the player doesn't exist,
# otherwise Name, Rank (e.g. "Unreal Legends (#19)" or "Unranked"), Points (Skill Rating, may be $null), Url.
function Get-PlayerProfile([string]$Name) {
  $url = 'https://myfortnitestats.com/profile/' + [Uri]::EscapeDataString($Name)
  $html = Get-WebText $url
  if ($html -notmatch 'Account ID:\s*(<[^>]*>\s*)*[0-9a-f]{32}') { return $null }   # unknown players have no account ID
  $rank = 'Unranked'; $points = $null
  $start = $html.IndexOf('class="rank-label">Battle Royale<')
  if ($start -ge 0) {
    $end = $html.IndexOf('class="rank-item"', $start); if ($end -lt 0) { $end = [Math]::Min($html.Length, $start + 2000) }
    $block = $html.Substring($start, $end - $start)
    if ($block -match 'class="rank-progress">\s*(.*?)\s*</div>') { $rank = $Matches[1] }
    if ($block -match 'rank-rr-val">([\d,]+)<') { $points = [int]($Matches[1] -replace ',') }
  }
  $accountId = [regex]::Match($html, 'Account ID:\s*(?:<[^>]*>\s*)*([0-9a-f]{32})').Groups[1].Value
  [pscustomobject]@{ Name = $Name; Rank = $rank; Points = $points; Url = $url; AccountId = $accountId }
}

# Epic names can't contain "!", so players use the look-alike letter U+01C3 instead. People type a normal "!",
# so treat the two as the same when matching names.
function ConvertTo-NameKey([string]$Name) { $Name.Replace([string][char]0x01C3, '!').ToLowerInvariant() }

function Find-PlayerProfile([string]$Name) {
  $player = Get-PlayerProfile $Name
  if (-not $player -and $Name.Contains('!')) { $player = Get-PlayerProfile ($Name.Replace('!', [string][char]0x01C3)) }
  $player
}

# One player's points. $Player needs Name, Points, Rank (number = Epic leaderboard position, or text) and optionally Url.
function New-PlayerPointsMessage($Player, [string]$Title) {
  $rank = if ($Player.Rank -is [int]) { "#$($Player.Rank) on the Unreal leaderboard" } else { $Player.Rank }
  $points = if ($null -eq $Player.Points) { 'No Battle Royale Skill Rating' } else { "**$(Format-Points $Player.Points)** ELO" }
  @{
    embeds = @(@{
      title       = $Title
      url         = $(if ($Player.Url) { $Player.Url } else { 'https://www.fortnite.com/ranked/leaderboard' })
      color       = 0x9D4DFF
      description = "**$(Format-DiscordText $Player.Name)**`n$points`n$rank"
      footer      = @{ text = 'ELO from myfortnitestats.com' }
    })
    allowed_mentions = @{ parse = @() }
  }
}

# -UpdatedNow: show "updated" as the time of this check rather than Epic's last update time.
function New-LeaderboardMessage($Data, [int]$Top = 25, [switch]$UpdatedNow) {
  $entries = $Data.Entries | Select-Object -First $Top
  $updated = if ($UpdatedNow) { [DateTime]::UtcNow } else { [DateTime]::Parse($Data.UpdatedTime).ToUniversalTime() }
  $unix = [int][double]::Parse((Get-Date $updated -UFormat %s))
  $hasPoints = @($entries | Where-Object { $null -ne $_.Points }).Count -gt 0

  $title = "Unreal Leaderboard - $($Data.ModeName) ($($Data.Season))"
  $medals = @{ 1 = ':first_place:'; 2 = ':second_place:'; 3 = ':third_place:' }
  $rows = foreach ($e in $entries) {
    $prefix = if ($medals.ContainsKey($e.Rank)) { $medals[$e.Rank] } else { "``#$($e.Rank)``" }
    $name = Format-DiscordText $e.Name
    if ($hasPoints) { "$prefix  $name - **$(Format-Points $e.Points)**" } else { "$prefix  $name" }
  }
  $body = $rows -join "`n"
  $source = if ($hasPoints) { 'Ranks from fortnite.com, ELO from myfortnitestats.com' } else { 'Data from fortnite.com' }

  @{
    embeds = @(@{
      title       = $title
      url         = "https://www.fortnite.com/ranked/leaderboard?mode=$($Data.Mode)"
      color       = 0x9D4DFF
      description = $body + "`n`nLeaderboard updated <t:$($unix):R>"
      footer      = @{ text = $source }
      timestamp   = $updated.ToString('yyyy-MM-ddTHH:mm:ssZ')
    })
    allowed_mentions = @{ parse = @() }
  }
}

# --- !ranked: how the system works + a personal breakdown --------------------
$RankedExplainer = @(
  '- Every ranked match moves you up or down. **Placement counts most**, eliminations less, and **stronger lobbies pay more**.'
  '- **Top 30%** earns extra, **top 5%** earns a big bonus. **Bottom 40%** loses rank.'
  '- Your **first match each day** is loss-protected.'
  '- In **Unreal**, players are ordered by **ELO** (Skill Rating). **Unreal Legends** = 2,500+ ELO and top 500.'
  '- New season = soft reset: your rank drops a bit, your ELO carries over.'
) -join "`n"

function Get-DivisionName([int]$Division) {
  if ($Division -ge 21) { return 'Unreal' }
  $ranks = 'Bronze', 'Silver', 'Gold', 'Platinum', 'Diamond', 'Elite', 'Champion'
  "$($ranks[[Math]::Floor($Division / 3)]) $(@('I', 'II', 'III')[$Division % 3])"
}

# Player stats from OliTracker (needs the Epic account ID). $null if the player isn't tracked.
function Get-OliTrackerStats([string]$AccountId) {
  if (-not $AccountId) { return $null }
  try { Get-WebText "https://olitracker.com/api/stats/$AccountId" | ConvertFrom-Json } catch { $null }
}

function Format-Percent([double]$x) { '{0:0}%' -f ($x * 100) }
function Format-Signed([double]$x, [string]$unit) { $s = if ($x -ge 0) { '+' } else { '-' }; "$s$([Math]::Abs([Math]::Round($x)).ToString('N0', [Globalization.CultureInfo]::InvariantCulture))$unit" }

# Game phases by how long the player survived. Minutes follow the Battle Royale storm schedule
# (zone 2 closes ~6:45, zone 5 ~13:30, zone 8 ~18:25). Wins always count as endgame.
$ZonePhases = @(
  [pscustomobject]@{ Key = 'Early'; Label = 'Zones 1-2'; MaxMinutes = 6 }
  [pscustomobject]@{ Key = 'Mid';   Label = 'Zones 3-5'; MaxMinutes = 13 }
  [pscustomobject]@{ Key = 'Late';  Label = 'Zones 6-8'; MaxMinutes = 18 }
  [pscustomobject]@{ Key = 'End';   Label = 'Zone 9+';   MaxMinutes = [int]::MaxValue }
)

function Get-ZonePhase($Match) {
  if ($Match.wins -ge 1) { return 'End' }
  foreach ($p in $ZonePhases) { if ($Match.time_played -le $p.MaxMinutes) { return $p.Key } }
}

function Get-ModeName([string]$Playlist) {
  $build = if ($Playlist -match 'nobuild') { 'Zero Build' } else { 'Build' }
  $team = switch -Regex ($Playlist) { 'solo' { 'Solo' } 'duo' { 'Duos' } 'trio' { 'Trios' } 'squad' { 'Squads' } default { '' } }
  "$build $team".Trim()
}

# One record per recent ranked match: rating change, game phase it ended in, kills, survival, mode, time.
# Unreal players are measured in ELO; everyone else in rank progress (%), since ELO is only tracked in Unreal.
function Measure-RankedMatches($Oli) {
  # Each entry's ranked_data is the rating *after* it. Some entries bundle several matches;
  # they're kept in the sequence (so the next match's change is measured correctly) but not scored.
  $games = @($Oli.match_history | ForEach-Object { $_.matches } |
    Where-Object { $_.ranked_data -and $_.ranked_data.ranking_id -eq 'ranked-br-combined' } |
    Sort-Object last_modified)
  $useElo = $games.Count -gt 0 -and @($games | Where-Object { $null -ne $_.ranked_data.elo }).Count -eq $games.Count
  $records = for ($i = 1; $i -lt $games.Count; $i++) {
    $m = $games[$i]
    if ($m.matches -ne 1) { continue }
    $a = $games[$i - 1].ranked_data; $b = $m.ranked_data
    $delta = if ($useElo) { $b.elo - $a.elo } else { ($b.division * 100 + $b.promotion_progression) - ($a.division * 100 + $a.promotion_progression) }
    if ([Math]::Abs($delta) -gt 100) { continue }   # no single match moves this much; it's a data glitch (e.g. a rating sync)
    [pscustomobject]@{
      Delta     = $delta
      Phase     = Get-ZonePhase $m
      Kills     = [int]$m.kills
      Minutes   = [Math]::Max(1, [int]$m.time_played)
      Outlived  = [int]$m.outlived
      Win       = $m.wins -ge 1
      Top       = $m.top_3_5_10 -ge 1                                  # ~top 10% (top 10 solo / 5 duos / 3 trios & squads)
      Top25     = ($m.top_3_5_10 -ge 1) -or ($m.top_6_12_25 -ge 1)      # ~top 25% (top 25 solo / 12 duos / 6 trios & squads)
      Mode      = Get-ModeName $m.playlist_id
      ZeroBuild = $m.playlist_id -match 'nobuild'
      Time      = [long]$m.last_modified
    }
  }
  [pscustomobject]@{ Unit = $(if ($useElo) { ' ELO' } else { '%' }); Games = @($records) }
}

function Get-Average($values) { if (@($values).Count) { (@($values) | Measure-Object -Average).Average } else { 0 } }

# Extra patterns in the match list: landing deaths, early trades, kill rate, session fatigue, tilt.
function Measure-PlayPatterns($Games) {
  $n = $Games.Count
  $early = @($Games | Where-Object Phase -eq 'Early')
  $landing = @($early | Where-Object Kills -eq 0)
  $traded = @($early | Where-Object Kills -ge 1)

  # Kills per minute alive, early (zones 1-5) vs late (zone 6+)
  $kpmOf = { param($set) $min = ($set | Measure-Object Minutes -Sum).Sum; if ($min) { ($set | Measure-Object Kills -Sum).Sum / $min } else { 0 } }
  $kpmEarly = & $kpmOf @($Games | Where-Object { $_.Phase -in 'Early', 'Mid' })
  $kpmLate = & $kpmOf @($Games | Where-Object { $_.Phase -in 'Late', 'End' })

  # Sessions: a gap of 45+ minutes between matches starts a new one
  $sessionIndex = @(); $idx = 0
  for ($i = 0; $i -lt $n; $i++) {
    if ($i -eq 0 -or ($Games[$i].Time - $Games[$i - 1].Time) -gt 2700) { $idx = 0 }
    $idx++; $sessionIndex += $idx
  }
  $fresh = @(for ($i = 0; $i -lt $n; $i++) { if ($sessionIndex[$i] -le 3) { $Games[$i].Delta } })
  $tired = @(for ($i = 0; $i -lt $n; $i++) { if ($sessionIndex[$i] -ge 6) { $Games[$i].Delta } })

  # Tilt: the match right after two non-top finishes in a row (same session)
  $afterBad = @(for ($i = 2; $i -lt $n; $i++) {
    if (-not $Games[$i - 1].Top -and -not $Games[$i - 2].Top -and $sessionIndex[$i] -ge 3) { $Games[$i].Delta }
  })

  [pscustomobject]@{
    LandingShare = $(if ($n) { $landing.Count / $n } else { 0 }); LandingDelta = Get-Average ($landing | ForEach-Object Delta); LandingCount = $landing.Count
    TradedShare  = $(if ($n) { $traded.Count / $n } else { 0 });  TradedDelta  = Get-Average ($traded | ForEach-Object Delta);  TradedCount = $traded.Count
    TradedKills  = Get-Average ($traded | ForEach-Object Kills)
    KpmEarly = $kpmEarly; KpmLate = $kpmLate
    Fresh = Get-Average $fresh; FreshCount = $fresh.Count; Tired = Get-Average $tired; TiredCount = $tired.Count
    AfterBad = Get-Average $afterBad; AfterBadCount = $afterBad.Count
    Overall = Get-Average ($Games | ForEach-Object Delta)
    ZeroBuild = @($Games | Where-Object ZeroBuild).Count -ge ($n / 2)
  }
}

# --- Season-long analysis, for players without enough recent matches ----------

# Minute marks where each zone finishes closing (Battle Royale storm schedule); used to turn
# average survival time into "dies around zone N".
$ZoneCloseMinutes = 4.25, 6.75, 9.75, 11.9, 13.5, 15.25, 17, 18.4, 19.6
function Get-ZoneAtMinute([double]$Minutes) { $z = 1; foreach ($c in $ZoneCloseMinutes) { if ($Minutes -gt $c) { $z++ } }; $z }

# Rates from one OliTracker seasonal stats block. Placement flags are cumulative (top 25% includes top 10%).
function Get-SeasonRates($s) {
  $n = [int]$s.matches_played
  if ($n -lt 1) { return $null }
  [pscustomobject]@{
    Matches = $n
    Win     = [double]$s.wins / $n
    Top10   = [double]$s.top_3_5_10 / $n
    Top25   = [Math]::Max([double]$s.top_6_12_25, [double]$s.top_3_5_10) / $n
    Kills   = [double]$s.kills / $n
    KillsPerMinute = $(if ($s.time_played) { [double]$s.kills / $s.time_played } else { 0 })
    Minutes = [double]$s.time_played / $n
  }
}

# The cached ELO model (top players' numbers) without triggering a slow re-measure; $null if none yet.
function Get-CachedEloModel {
  $path = Join-Path $PSScriptRoot 'elo-model.json'
  if (Test-Path $path) { try { Get-Content -Raw -Encoding UTF8 $path | ConvertFrom-Json } catch { $null } } else { $null }
}

# --- Battle Royale vs Reload --------------------------------------------------
# OliTracker's seasonal "ranked" total covers every ranked playlist, Reload included. Players who haven't
# played Reload ranked get it as-is (pure Battle Royale); anyone who has gets all their Battle Royale
# matches instead (ranked + unranked), so Reload never mixes into the Battle Royale numbers.
function Test-PlaysRankedReload($Oli) {
  @(@($Oli.ranked_stats.PSObject.Properties.Name) -match 'blastberry').Count -gt 0 -or
    @($Oli.match_history | ForEach-Object { $_.matches } | Where-Object { $_.ranked_data.ranking_id -match 'blastberry' }).Count -gt 0
}
function Get-BrSeasonSource($Oli) {
  if (Test-PlaysRankedReload $Oli) { [pscustomobject]@{ Stats = $Oli.stats.seasonal.br; Label = 'Battle Royale, ranked + unranked' } }
  else { [pscustomobject]@{ Stats = $Oli.stats.seasonal.ranked; Label = 'Battle Royale ranked' } }
}

# Reload shown on its own: rank, recent ranked matches, and season stats (all Reload matches).
function Get-ReloadField($Oli) {
  $rankKey = $Oli.ranked_stats.PSObject.Properties.Name | Where-Object { $_ -match 'blastberry' } | Select-Object -First 1
  $season = Get-SeasonRates $Oli.stats.seasonal.reload.both.overall
  if (-not $rankKey -and -not $season) { return $null }
  $lines = @()
  if ($rankKey) {
    $rr = $Oli.ranked_stats.$rankKey
    $rank = if ($rr.division -ge 21) { "Unreal #$(Format-Points $rr.current_unreal_placement)" } else { "$(Get-DivisionName $rr.division) ($($rr.promotion_progression)%)" }
    $lines += "Rank: **$rank**" + $(if ($null -ne $rr.elo) { " - **$(Format-Points $rr.elo)** ELO" } else { '' })
  }
  $recent = @($Oli.match_history | ForEach-Object { $_.matches } | Where-Object { $_.ranked_data.ranking_id -match 'blastberry' })
  if ($recent.Count) { $rn = ($recent | Measure-Object matches -Sum).Sum; $rw = ($recent | Measure-Object wins -Sum).Sum; $lines += "Last 7 days: **$rn** ranked $(if ($rn -eq 1) { 'match' } else { 'matches' }), **$rw** $(if ($rw -eq 1) { 'win' } else { 'wins' })" }
  if ($season) { $lines += "Season (ranked + unranked): $(Format-Points $season.Matches) matches, $(Format-Percent $season.Win) wins, $(Format-Percent $season.Top10) top 10%, $('{0:0.0}' -f $season.Kills) kills/match" }
  @{ name = 'Reload (separate rank)'; value = ($lines -join "`n") }
}
# Returns @{ Field; Tips } built from this season's ranked stats, or $null if there are too few matches.
function Get-SeasonAnalysis($Oli) {
  $src = Get-BrSeasonSource $Oli
  $all = Get-SeasonRates $src.Stats.both.overall
  if (-not $all -or $all.Matches -lt 10) { return $null }
  $build = Get-SeasonRates $src.Stats.builds.overall
  $zero = Get-SeasonRates $src.Stats.zerobuild.overall
  $zb = $zero -and (-not $build -or $zero.Matches -gt $build.Matches)
  $below = 1 - $all.Top25
  $zone = Get-ZoneAtMinute $all.Minutes
  $pct = { param($x) Format-Percent $x }

  # Top-player benchmark from the ELO post's measurements (cumulative placement shares, ELO per bracket)
  $model = Get-CachedEloModel
  $bench = $null; $value = @{}
  if ($model -and $model.Placement) {
    foreach ($b in $model.Placement) { $value[$b.Label] = [double]$b.Delta }
    $sh = @{}; foreach ($b in $model.Placement) { $sh[$b.Label] = [double]$b.Share }
    $bench = [pscustomobject]@{ Win = $sh['Win']; Top10 = $sh['Win'] + $sh['Top ~10%']; Top25 = $sh['Win'] + $sh['Top ~10%'] + $sh['Top 10-25%'] }
  }

  $lines = @(
    "- Avg survival: **$('{0:0.0}' -f $all.Minutes) min** (most games end around **zone $zone**)"
    "- Placement: **$(& $pct $all.Win)** wins | **$(& $pct $all.Top10)** top 10% | **$(& $pct $all.Top25)** top 25% | **$(& $pct $below)** below"
    "- Kills: **$('{0:0.0}' -f $all.Kills)**/match | **$('{0:0.00}' -f $all.KillsPerMinute)**/min alive"
  )
  if ($bench) { $lines += "- Top-player benchmark: $(& $pct $bench.Win) wins | $(& $pct $bench.Top10) top 10% | $(& $pct $bench.Top25) top 25%" }
  if ($build -and $zero -and $build.Matches -ge 5 -and $zero.Matches -ge 5) {
    $lines += "- Build ($($build.Matches)): $(& $pct $build.Top25) top 25%, $('{0:0.0}' -f $build.Kills) kills | Zero Build ($($zero.Matches)): $(& $pct $zero.Top25) top 25%, $('{0:0.0}' -f $zero.Kills) kills"
  }
  $field = @{ name = "Season breakdown - $($all.Matches) matches ($($src.Label))"; value = ($lines -join "`n") }

  # --- Tips (score = rough rating at stake) ---
  $tips = New-Object Collections.Generic.List[object]
  $add = { param($score, $text) $tips.Add([pscustomobject]@{ Score = $score; Text = $text }) }
  $swing = if ($value.Count) { [Math]::Max(1, $value['Top 10-25%'] - $value['Below top 25%']) } else { 7 }

  if ($below -ge 0.2) {
    $vs = if ($bench) { " (top players: $(& $pct (1 - $bench.Top25)))" } else { '' }
    & $add ($below * $swing) "**Below-top-25% finishes: $(& $pct $below) of your games**$vs. That's the bracket that loses rank; each game you move into the top 25% is worth about **+$([Math]::Round($swing))** ELO for top players. Focus on surviving longer into the match rather than on fighting."
  }
  if ($all.Minutes -lt 9 -and $zone -le 3) {
    & $add ((9 - $all.Minutes) * 0.8 + 1) "**Short games: $('{0:0.0}' -f $all.Minutes) min average**, so most end in zones 1-$zone. Avoid dying early: early kills are worth little, and an early death can cost you more ELO than a kill gains. Land somewhere quieter and play safe until the first zones close."
  }
  if ($all.Top25 -ge 0.4 -and $all.Top10 -lt 0.6 * $all.Top25) {
    & $add (($all.Top25 - $all.Top10) * 4) "**Top 25% -> top 10%: $(& $pct $all.Top25) reach the top 25%, but only $(& $pct $all.Top10) the top 10%.** You're getting to the mid-late game but going out before the end. Stay patient there: positioning and staying alive matter more than kills."
  }
  if ($all.Top10 -ge 0.15 -and $all.Win -lt 0.3 * $all.Top10) {
    & $add (($all.Top10 - $all.Win) * 5) "**Endgame conversion: $(& $pct ($all.Win / $all.Top10)) of top-10% finishes become wins.** You often reach the endgame but don't close it out. Wins are worth the most ELO, so play the final circles carefully and let the other players fight each other first."
  }
  if ($all.KillsPerMinute -lt 0.15 -and $all.Top25 -ge 0.5) {
    & $add 1.5 "**Low kill rate: $('{0:0.00}' -f $all.KillsPerMinute) kills/min alive.** You survive well; kills late in the match add ELO at every placement, so take more fights once you're deep into the game."
  }
  if ($all.Kills -ge 4 -and $below -ge 0.35) {
    & $add 2 "**Over-fighting: $('{0:0.0}' -f $all.Kills) kills/match but $(& $pct $below) of games below the top 25%.** You're taking too many fights. A kill is worth less than surviving, so pick fewer fights and focus on staying alive."
  }
  if ($build -and $zero -and $build.Matches -ge 10 -and $zero.Matches -ge 10 -and [Math]::Abs($build.Top25 - $zero.Top25) -ge 0.15) {
    $better = if ($build.Top25 -gt $zero.Top25) { 'Build' } else { 'Zero Build' }
    & $add ([Math]::Abs($build.Top25 - $zero.Top25) * 3) "**Mode efficiency:** top 25% in $(& $pct $build.Top25) of Build games vs $(& $pct $zero.Top25) of Zero Build. They share one rank, so queue $better when climbing."
  }
  [pscustomobject]@{ Field = $field; Tips = $tips }
}

function New-RankedBreakdownMessage($Player, $Oli) {
  if (-not $Oli) {
    return @{ content = "**$(Format-DiscordText $Player.Name)** ($($Player.Rank), $(Format-Points $Player.Points) ELO): OliTracker has no match data for this player yet, so there's nothing to analyse. Their stats appear once OliTracker has tracked some of their matches."; allowed_mentions = @{ parse = @() } }
  }
  $fields = New-Object Collections.Generic.List[object]

  # --- Player summary ---
  $rs = $Oli.ranked_stats.'ranked-br-combined'
  $elo = if ($null -ne $rs.elo) { [int]$rs.elo } else { $Player.Points }
  $rankText = if (-not $rs) { $Player.Rank }
    elseif ($rs.division -ge 21) { "Unreal #$(Format-Points $rs.current_unreal_placement)" + $(if ($rs.peak_unreal_placement) { " (peak #$(Format-Points $rs.peak_unreal_placement))" } else { '' }) }
    else { "$(Get-DivisionName $rs.division) ($($rs.promotion_progression)%)" }
  $you = @("**$rankText** - **$(Format-Points $elo)** ELO")
  $brSource = Get-BrSeasonSource $Oli
  $s = $brSource.Stats.both.overall
  $n = [int]$s.matches_played
  if ($n -gt 0) {
    $winRate = $s.wins / $n; $topRate = $s.top_3_5_10 / $n; $kpm = $s.kills / $n
    $you += "Season ($($brSource.Label)): $(Format-Points $n) matches, $(Format-Percent $winRate) wins, $(Format-Percent $topRate) top finishes, $('{0:0.0}' -f $kpm) kills/match"
  }
  $week = @($Oli.match_history | ForEach-Object { $_.elo.'ranked-br-combined'.change } | Where-Object { $null -ne $_ })
  $weekChange = ($week | Measure-Object -Sum).Sum
  if ($week.Count) { $you += "Last 7 days: **$(Format-Signed $weekChange ' ELO')**" }
  $fields.Add(@{ name = "$($Player.Name) - Battle Royale"; value = ($you -join "`n") })

  # --- Zone breakdown + patterns ---
  $r = Measure-RankedMatches $Oli
  $g = $r.Games
  $u = $r.Unit
  $phase = @{}
  foreach ($p in $ZonePhases) {
    $set = @($g | Where-Object Phase -eq $p.Key)
    $phase[$p.Key] = [pscustomobject]@{ Label = $p.Label; Count = $set.Count; Share = $(if ($g.Count) { $set.Count / $g.Count } else { 0 })
      Kills = Get-Average ($set | ForEach-Object Kills); Delta = Get-Average ($set | ForEach-Object Delta) }
  }
  $topWins = @($g | Where-Object Win).Count
  $topCount = @($g | Where-Object Top).Count      # top finishes: the matches where a win was in reach
  $pat = Measure-PlayPatterns $g
  if ($g.Count -ge 8) {
    $col = if ($u -eq ' ELO') { 'ELO' } else { 'Rank' }
    $sfx = if ($col -eq 'Rank') { '%' } else { '' }
    $rows = foreach ($p in $ZonePhases) {
      $x = $phase[$p.Key]
      '{0,-10}{1,5}{2,7}{3,7}' -f $x.Label, (Format-Percent $x.Share), $('{0:0.0}' -f $x.Kills), $(if ($x.Count) { Format-Signed $x.Delta $sfx } else { '-' })
    }
    $table = @('{0,-10}{1,5}{2,7}{3,7}' -f 'Died in', 'Games', 'Kills', $col) + $rows
    $extra = @()
    if ($topCount) { $extra += "Top finishes converted to wins: **$(Format-Percent ($topWins / $topCount))** ($topWins/$topCount)" }
    $extra += "Kills per minute alive: **$('{0:0.00}' -f $pat.KpmEarly)** in zones 1-5, **$('{0:0.00}' -f $pat.KpmLate)** in zones 6+"
    if ($pat.FreshCount -ge 5 -and $pat.TiredCount -ge 5) { $extra += "Session: games 1-3 **$(Format-Signed $pat.Fresh $u)**, games 6+ **$(Format-Signed $pat.Tired $u)** per match" }
    $fields.Add(@{ name = "By zone - last $($g.Count) matches ($col per match)"; value = "``````" + "`n" + ($table -join "`n") + "`n" + "``````" + "`n" + ($extra -join "`n") })
  }

  # --- Tips: each candidate gets a score (roughly, rating lost to that weakness); the top 3 are shown ---
  $tips = New-Object Collections.Generic.List[object]
  $add = { param($score, $text) $tips.Add([pscustomobject]@{ Score = $score; Text = $text }) }
  $zb = $pat.ZeroBuild
  $f1 = { param($x) '{0:0.0}' -f $x }

  if ($g.Count -ge 8) {
    $bestPhase = $ZonePhases | ForEach-Object { $phase[$_.Key] } | Where-Object Count -ge 3 | Sort-Object Delta -Descending | Select-Object -First 1
    $gap = { param($d) [Math]::Max(1, $bestPhase.Delta - $d) }
    $vs = { param($d) if ($d -lt 0) { "costing **$(Format-Signed $d $u)** each" } else { "$(Format-Signed $d $u) each vs $(Format-Signed $bestPhase.Delta $u) at $($bestPhase.Label.ToLower())" } }

    if ($pat.LandingCount -ge 3 -and $pat.LandingShare -ge 0.06) {
      & $add ($pat.LandingShare * (& $gap $pat.LandingDelta) * 1.2) "**Landing deaths: $(Format-Percent $pat.LandingShare) of games end in zones 1-2 with 0 kills** ($(& $vs $pat.LandingDelta)). Avoid dying early: land somewhere quieter and play safe until the first zones close."
    }
    if ($pat.TradedCount -ge 3 -and $pat.TradedShare -ge 0.08) {
      & $add ($pat.TradedShare * (& $gap $pat.TradedDelta)) "**Early fights: $(Format-Percent $pat.TradedShare) of games end in zones 1-2 after you got kills** (avg $(& $f1 $pat.TradedKills), $(& $vs $pat.TradedDelta)). Early kills are worth little, and dying early can cost you more ELO than the kills gain. Take fewer early fights and focus on surviving."
    }
    $mid = $phase['Mid']
    if ($mid.Count -ge 3 -and $mid.Share -ge 0.15) {
      & $add ($mid.Share * (& $gap $mid.Delta)) "**Mid-game deaths: $(Format-Percent $mid.Share) end in zones 3-5** ($(& $vs $mid.Delta)). Try to survive longer into the match: every zone you outlast is worth more ELO than a mid-game kill."
    }
    $late = $phase['Late']
    if ($late.Count -ge 3 -and $late.Share -ge 0.12) {
      $style = if ($late.Kills -ge 4) { "You average $(& $f1 $late.Kills) kills before dying here, so you may be taking too many fights. Be pickier about which fights you take." }
               else { 'Stay patient here: positioning and staying alive matter more than kills.' }
      & $add ($late.Share * (& $gap $late.Delta)) "**Late-game deaths: $(Format-Percent $late.Share) end in zones 6-8** ($(& $vs $late.Delta)). $style"
    }
    if ($topCount -ge 5 -and ($topWins / $topCount) -lt 0.5) {
      & $add ((1 - $topWins / $topCount) * ($topCount / $g.Count) * 10) "**Endgame conversion: $(Format-Percent ($topWins / $topCount))** of top finishes become wins. Wins are worth the most ELO, so play the final circles carefully and let the other players fight each other first."
    }
    if ($pat.KpmLate -gt 0 -and $pat.KpmEarly -gt 1.6 * $pat.KpmLate -and $phase['Early'].Share + $mid.Share -ge 0.3) {
      & $add 2 "**Early aggression:** you take kills $('{0:0.0}' -f ($pat.KpmEarly / $pat.KpmLate))x faster in zones 1-5 than in zones 6+. Early kills are worth little; save your fights for later in the match, where kills pay more and dying costs less."
    }
    if ($pat.FreshCount -ge 5 -and $pat.TiredCount -ge 5 -and ($pat.Fresh - $pat.Tired) -ge 2) {
      & $add (($pat.Fresh - $pat.Tired) * $pat.TiredCount / $g.Count) "**Session fatigue:** your first 3 games average $(Format-Signed $pat.Fresh $u), but games 6+ only $(Format-Signed $pat.Tired $u). Play shorter ranked sessions and take breaks."
    }
    if ($pat.AfterBadCount -ge 4 -and ($pat.Overall - $pat.AfterBad) -ge 2) {
      & $add (($pat.Overall - $pat.AfterBad) * $pat.AfterBadCount / $g.Count) "**Tilt:** after two non-top finishes in a row, your next game averages $(Format-Signed $pat.AfterBad $u) vs $(Format-Signed $pat.Overall $u) overall. Make two bad games in a row your cue to stop or take a break."
    }
    $modes = @($g | Group-Object Mode | Where-Object Count -ge 5 | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Delta = Get-Average ($_.Group | ForEach-Object Delta); Count = $_.Count } } | Sort-Object Delta -Descending)
    if ($modes.Count -ge 2 -and ($modes[0].Delta - $modes[-1].Delta) -ge 3) {
      & $add (($modes[0].Delta - $modes[-1].Delta) * $modes[-1].Count / $g.Count) "**Mode efficiency:** $(Format-Signed $modes[0].Delta $u)/match in $($modes[0].Name) vs $(Format-Signed $modes[-1].Delta $u) in $($modes[-1].Name) ($($modes[-1].Count) games). Queue $($modes[0].Name) when climbing."
    }
  } elseif ($n -ge 10) {
    # Not enough recent matches for a zone breakdown: analyse the whole season instead.
    $season = Get-SeasonAnalysis $Oli
    if ($season) {
      $fields.Add($season.Field)
      foreach ($tip in $season.Tips) { & $add $tip.Score $tip.Text }
    }
  }
  if ($week.Count -and $weekChange -lt 0) {
    & $add 1.5 "**Down $(Format-Signed $weekChange ' ELO') this week.** Stop after two bad games in a row, and warm up before your first match, since that one is loss-protected."
  }
  if ($n -lt 10 -and $g.Count -lt 8) {
    & $add 10 'Play more ranked matches first. With this few, your rank is still settling and there isn''t enough data for detailed advice.'
  }
  if ($tips.Count -eq 0) {
    if ($g.Count -ge 8) { & $add 0 'Strong across every zone. Remaining gains come from converting more top finishes into wins: hold the best position in the final circles rather than chasing kills.' }
    else { & $add 0 'Season numbers are strong across the board. Remaining gains come from converting more top-10% finishes into wins: hold the best position in the final circles rather than chasing kills.' }
  }
  $shown = @($tips | Sort-Object Score -Descending | Select-Object -First 3 | ForEach-Object { "- $($_.Text)" })
  while ($shown.Count -gt 1 -and ($shown -join "`n").Length -gt 1024) { $shown = $shown[0..($shown.Count - 2)] }   # Discord's per-field limit
  $fields.Add(@{ name = 'How to gain more ELO (Battle Royale)'; value = ($shown -join "`n") })
  $reload = Get-ReloadField $Oli
  if ($reload) { $fields.Add($reload) }

  @{
    embeds = @(@{
      title       = "$($Player.Name) - Ranked Breakdown"
      url         = "https://olitracker.com/stats/$($Player.AccountId)"
      color       = 0x9D4DFF
      description = 'Placement earns the most, kills less, and tougher lobbies pay more. Top 30% gains rank; bottom 40% loses it. Type `!ranked` for the full rules.'
      fields      = $fields.ToArray()
      footer      = @{ text = 'Zones estimated from survival time. Top finish = top 10 solo / 5 duos / 3 trios. Data: olitracker.com, myfortnitestats.com' }
      timestamp   = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    })
    allowed_mentions = @{ parse = @() }
  }
}

# --- ELO system post: measured from the top players' recent matches -----------

# Top 100 Battle Royale players with account IDs, from myfortnitestats.com's embedded page data.
function Get-TopRankedAccounts {
  $html = Get-WebText 'https://myfortnitestats.com/leaderboard'
  $m = [regex]::Match($html, 'const _ssrRankedData = (\{.*?\});\s*\n')
  if (-not $m.Success) { throw 'Top player data not found on myfortnitestats.com; the page format may have changed.' }
  @(($m.Groups[1].Value | ConvertFrom-Json).players)
}

# Least-squares slope of y on x (how much y changes per unit of x).
function Get-Slope($xs, $ys) {
  $n = @($xs).Count; if ($n -lt 3) { return $null }
  $mx = ($xs | Measure-Object -Average).Average; $my = ($ys | Measure-Object -Average).Average
  $num = 0.0; $den = 0.0
  for ($i = 0; $i -lt $n; $i++) { $num += ($xs[$i] - $mx) * ($ys[$i] - $my); $den += ($xs[$i] - $mx) * ($xs[$i] - $mx) }
  if ($den -eq 0) { $null } else { $num / $den }
}

# Pools the last 7 days of ranked matches from the top $Sample players and measures what each outcome is worth.
# Cached to elo-model.json for $MaxAgeHours, since it makes one request per player.
$EloModelVersion = 4
function Get-EloModel([int]$Sample = 25, [double]$MaxAgeHours = 6) {
  $cachePath = Join-Path $PSScriptRoot 'elo-model.json'
  if (Test-Path $cachePath) {
    $cached = Get-Content -Raw -Encoding UTF8 $cachePath | ConvertFrom-Json
    $age = ((Get-Date).ToUniversalTime() - [DateTime]::Parse($cached.Measured).ToUniversalTime()).TotalHours
    if ($cached.Version -eq $EloModelVersion -and $age -lt $MaxAgeHours) { return $cached }
  }

  $games = New-Object Collections.Generic.List[object]
  $players = 0
  foreach ($p in (Get-TopRankedAccounts | Select-Object -First $Sample)) {
    $oli = Get-OliTrackerStats $p.accountId
    Start-Sleep -Milliseconds 500
    if (-not $oli) { continue }
    $r = Measure-RankedMatches $oli
    if ($r.Unit -ne ' ELO' -or $r.Games.Count -eq 0) { continue }
    $players++
    foreach ($g in $r.Games) { $games.Add($g) }
  }
  if ($games.Count -lt 30) { throw "Only $($games.Count) matches found in the sample; not enough to measure." }

  $avg = { param($set) [Math]::Round((Get-Average ($set | ForEach-Object Delta)), 1) }
  $share = { param($set) [Math]::Round(@($set).Count / $games.Count, 3) }
  $bracket = { param($label, $set) [pscustomobject]@{ Label = $label; Delta = & $avg $set; Share = & $share $set } }
  $nonWin = @($games | Where-Object { -not $_.Win })

  [pscustomobject]@{
    Version   = $EloModelVersion
    Measured  = [DateTime]::UtcNow.ToString('o')
    Players   = $players
    Matches   = $games.Count
    Placement = @(
      & $bracket 'Win' @($games | Where-Object Win)
      & $bracket 'Top ~10%' @($games | Where-Object { $_.Top -and -not $_.Win })
      & $bracket 'Top 10-25%' @($games | Where-Object { $_.Top25 -and -not $_.Top })
      & $bracket 'Below top 25%' @($games | Where-Object { -not $_.Top25 })
    )
    Zones     = @(foreach ($z in $ZonePhases) {
      $set = @($games | Where-Object Phase -eq $z.Key)
      [pscustomobject]@{
        Label = $z.Label; Delta = & $avg $set; Share = & $share $set
        Kills = [Math]::Round((Get-Average ($set | ForEach-Object Kills)), 1)
        PerKill = Get-Slope @($set | ForEach-Object Kills) @($set | ForEach-Object Delta)
      }
    })
    # ELO by kill count at the same placement, so kills aren't mixed up with placing better
    KillValue = @(foreach ($b in @(
        @{ Label = 'Win'; Test = { $_.Win } }
        @{ Label = 'Top ~10%'; Test = { $_.Top -and -not $_.Win } }
        @{ Label = 'Top 10-25%'; Test = { $_.Top25 -and -not $_.Top } }
        @{ Label = 'Below top 25%'; Test = { -not $_.Top25 } })) {
      $set = @($games | Where-Object $b.Test)
      [pscustomobject]@{ Label = $b.Label; Ranges = @(foreach ($k in @(@(0, 2), @(3, 5), @(6, 9), @(10, 999))) {
        $s = @($set | Where-Object { $_.Kills -ge $k[0] -and $_.Kills -le $k[1] })
        if ($s.Count -ge 5) { [pscustomobject]@{ Kills = $(if ($k[1] -ge 999) { "$($k[0])+" } else { "$($k[0])-$($k[1])" }); Delta = & $avg $s; Count = $s.Count } }
      }) }
    })
    PerKill   = Get-Slope @($nonWin | ForEach-Object Kills) @($nonWin | ForEach-Object Delta)
    PerMinute = Get-Slope @($nonWin | ForEach-Object Minutes) @($nonWin | ForEach-Object Delta)
    LossShare = [Math]::Round(@($games | Where-Object { $_.Delta -lt 0 }).Count / $games.Count, 3)
  } | Tee-Object -Variable model | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $cachePath
  $model
}

function New-EloSystemMessage($Data, $Model) {
  $num = { param($x) '{0:+0.0;-0.0;0.0}' -f [double]$x }
  $int = { param($x) Format-Signed $x '' }

  $rules = @(
    '- Hidden **ELO** sets your rank; Unreal is sorted by it'
    '- **Placement** counts most, then **kills**, scaled by **lobby strength**'
    '- **Top 30%** = bonus, **top 5%** = big bonus, **bottom 40%** = loss'
    '- First match each day is **loss-protected**; each season is a **soft reset** (ELO carries over)'
    '- **Unreal Legends:** 2,500+ ELO and top 500'
  ) -join "`n"

  $placement = ($Model.Placement | ForEach-Object { "- $($_.Label): **$(& $int $_.Delta)** ($(Format-Percent $_.Share) of games)" }) -join "`n"

  $kills = @(foreach ($b in $Model.KillValue) {
    $r = @($b.Ranges); if ($r.Count -lt 2) { continue }
    "- $($b.Label): **$(& $int $r[0].Delta)** with $($r[0].Kills) kills -> **$(& $int $r[-1].Delta)** with $($r[-1].Kills)"
  })
  $early = $Model.Zones | Where-Object Label -eq 'Zones 1-2'
  if ($null -ne $early.PerKill) { $kills += "- Early kills matter most: **$(& $num $early.PerKill)**/kill in zones 1-2, where even one kill can turn a loss into a gain" }
  $kills = $kills -join "`n"
  $survival = ($Model.Zones | ForEach-Object { "- $(if ($_.Label -eq 'Zone 9+') { 'Reached zone 9+ (incl. wins)' } else { "Died in $($_.Label.ToLower())" }): **$(& $int $_.Delta)** per game ($(Format-Percent $_.Share) of games)" }) -join "`n"

  $other = @(
    "- Each extra minute alive: **$(& $num $Model.PerMinute)**"
    "- Games that lost ELO: **$(Format-Percent $Model.LossShare)**"
  ) -join "`n"

  $byRank = @{}; foreach ($e in $Data.Entries) { $byRank[$e.Rank] = $e }
  $cut = { param($r) if ($byRank.ContainsKey($r) -and $null -ne $byRank[$r].Points) { Format-Points $byRank[$r].Points } else { '?' } }
  $cutoffs = "#1 **$(& $cut 1)** | #10 **$(& $cut 10)** | #50 **$(& $cut 50)** | #100 **$(& $cut 100)** | ~$(Format-Points ([Math]::Max(0, $Data.TotalPages - 1) * 100))+ players in Unreal"

  $measuredAt = [DateTimeOffset]::Parse($Model.Measured).ToUnixTimeSeconds()
  @{
    embeds = @(@{
      title       = "How the ELO System Works - $($Data.Season)"
      color       = 0x9D4DFF
      description = "From **$(Format-Points $Model.Matches)** ranked games by the top **$($Model.Players)** players (last 7 days), measured <t:$($measuredAt):R>. Values are average ELO per game."
      fields      = @(
        @{ name = 'Rules'; value = $rules }
        @{ name = 'Placement value'; value = $placement }
        @{ name = 'Survival value (where the game ended)'; value = $survival }
        @{ name = 'Kill value (same placement, fewest -> most kills)'; value = $kills }
        @{ name = 'Other'; value = $other }
        @{ name = 'ELO cutoffs'; value = $cutoffs }
      )
      footer      = @{ text = 'Top ~10% = top 10 solo / 5 duos / 3 trios. Top Unreal players only; lower ranks move at different rates. Zones estimated from survival time. Refreshed every 6h. !ranked <name> for your own breakdown.' }
    })
    allowed_mentions = @{ parse = @() }
  }
}

# --- !last10: a player's most recent ranked games ------------------------------

# Newest-first rows covering a player's last $Count Battle Royale ranked games, from OliTracker's 7-day history.
# Most rows are single games; OliTracker sometimes stores several games as one bundle, shown as one row.
# Change is $null for the oldest row (nothing to compare with) and for glitched readings.
function Get-RecentRankedGames($Oli, [int]$Count = 10) {
  $entries = @($Oli.match_history | ForEach-Object { $_.matches } |
    Where-Object { $_.ranked_data -and $_.ranked_data.ranking_id -eq 'ranked-br-combined' } |
    Sort-Object last_modified)
  $useElo = $entries.Count -gt 0 -and @($entries | Where-Object { $null -ne $_.ranked_data.elo }).Count -eq $entries.Count
  $rows = for ($i = 0; $i -lt $entries.Count; $i++) {
    $m = $entries[$i]
    $n = [Math]::Max(1, [int]$m.matches)
    $delta = $null
    if ($i -gt 0) {
      $a = $entries[$i - 1].ranked_data; $b = $m.ranked_data
      $d = if ($useElo) { $b.elo - $a.elo } else { ($b.division * 100 + $b.promotion_progression) - ($a.division * 100 + $a.promotion_progression) }
      if ($n -eq 1 -and [Math]::Abs($d) -le 100) { $delta = $d }   # bundles' ratings aren't reliable, so no change is shown for them
    }
    [pscustomobject]@{
      Time = [long]$m.last_modified; Mode = Get-ModeName $m.playlist_id; Games = $n
      Kills = [int]$m.kills; Minutes = [int]$m.time_played
      Wins = [int]$m.wins; Top10 = [int]$m.top_3_5_10; Top25 = [Math]::Max([int]$m.top_3_5_10, [int]$m.top_6_12_25)
      Delta = $delta
    }
  }
  $picked = New-Object Collections.Generic.List[object]; $games = 0
  foreach ($row in (@($rows) | Sort-Object Time -Descending)) {
    if ($games -ge $Count) { break }
    $picked.Add($row); $games += $row.Games
  }
  [pscustomobject]@{ Unit = $(if ($useElo) { 'ELO' } else { 'Rank' }); Rows = $picked.ToArray(); Games = $games }
}

# Older games from myfortnitestats.com, newest first. It stores games in batches whenever it checks a
# player, so many entries cover several games; for those only wins are known (Top10/Top25 = $null).
# No survival time or rating change either way.
function Get-MfsRecentRankedGames([string]$AccountId, [int]$Count = 10) {
  if (-not $AccountId) { return @() }
  try { $j = Get-WebText "https://myfortnitestats.com/api/match-history/$AccountId" | ConvertFrom-Json } catch { return @() }
  # Battle Royale ranked playlists only (Reload is "sourspawn"; other ranked modes have their own names)
  $brRanked = '^playlist_(nobuildbr_)?habanero(_nobuild)?_?(solo|duo|duos|trio|trios|squad|squads)$'
  @($j.matches | Where-Object { $_.playlist_id -match $brRanked } |
    Sort-Object recorded_at -Descending | Select-Object -First $Count | ForEach-Object {
      $n = [Math]::Max(1, [int]$_.matches_count)
      $single = $n -eq 1
      [pscustomobject]@{
        Time = [DateTimeOffset]::Parse($_.recorded_at).ToUnixTimeSeconds(); Mode = Get-ModeName $_.playlist_id
        Games = $n; Kills = [int]$_.kills; Minutes = $null; Wins = [int]$_.wins; Delta = $null
        Top10 = $(if ($single) { [int]($_.wins -ge 1 -or $_.result -match '^Top (1|3|5|10)$') } else { $null })
        Top25 = $(if ($single) { [int]($_.wins -ge 1 -or $_.result -match '^Top (1|3|5|6|10|12|25)$') } else { $null })
        Result = $(if (-not $single) { $null } elseif ($_.wins -ge 1) { 'Win' } elseif ($_.result -match '^Top') { $_.result } else { 'Lower' })
      }
    })
}
function New-RecentGamesMessage($Player, $Oli) {
  $r = if ($Oli) { Get-RecentRankedGames $Oli 10 } else { [pscustomobject]@{ Unit = 'ELO'; Rows = @(); Games = 0 } }
  $rows = $r.Rows
  $source = 'olitracker'
  if ($r.Games -lt 10) {
    # OliTracker keeps 7 days at most; myfortnitestats keeps months for players it follows.
    # Fill in games older than OliTracker's oldest one until there are 10.
    $oldest = if ($rows.Count) { ($rows | Measure-Object Time -Minimum).Minimum - 60 } else { [long]::MaxValue }
    $older = @(Get-MfsRecentRankedGames $Player.AccountId 50 | Where-Object { $_.Time -lt $oldest })
    $extra = New-Object Collections.Generic.List[object]; $games = $r.Games
    foreach ($row in $older) { if ($games -ge 10) { break }; $extra.Add($row); $games += $row.Games }
    if ($extra.Count) {
      $source = if ($rows.Count) { 'both' } else { 'myfortnitestats' }
      $rows = @($rows) + $extra.ToArray()
      $r = [pscustomobject]@{ Unit = $(if ($rows.Count -gt $extra.Count) { $r.Unit } else { 'ELO' }); Rows = $rows; Games = $games }
    }
  }
  if ($rows.Count -eq 0) {
    return @{ content = "Neither tracker has recorded recent ranked games for **$(Format-DiscordText $Player.Name)**. They only record individual games once they start following a player, and a lookup like this one usually starts that, so try again after their next few games."; allowed_mentions = @{ parse = @() } }
  }

  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $ago = { param($t) $s = $now - $t; if ($s -lt 3600) { "$([Math]::Max(1, [int]($s / 60)))m" } elseif ($s -lt 86400) { "$([int]($s / 3600))h" } else { "$([int]($s / 86400))d" } }
  $shortMode = { param($m) ($m -replace 'Zero Build', 'ZB' -replace 'Squads', 'Squad' -replace 'Duos', 'Duo' -replace 'Trios', 'Trio') }
  $result = { param($x)
    if ($x.Games -gt 1) { "$($x.Games) games" }
    elseif ($x.Wins) { 'Win' } elseif ($x.Result) { $x.Result } elseif ($x.Top10) { 'Top 10%' } elseif ($x.Top25) { 'Top 25%' }
    elseif ($null -eq $x.Minutes) { 'Lower' } else { "Out Z$(Get-ZoneAtMinute $x.Minutes)" } }
  $sfx = if ($r.Unit -eq 'Rank') { '%' } else { '' }
  $chg = { param($d) if ($null -eq $d) { '-' } else { Format-Signed $d $sfx } }

  $fmt = '{0,-4}{1,-11}{2,-9}{3,4}{4,4}{5,6}'
  $table = @($fmt -f 'Ago', 'Mode', 'Result', 'K', 'Min', $r.Unit)
  $table += $rows | ForEach-Object { $fmt -f (& $ago $_.Time), (& $shortMode $_.Mode), (& $result $_), $_.Kills, $(if ($null -eq $_.Minutes) { '-' } else { [int]($_.Minutes / $_.Games) }), (& $chg $_.Delta) }

  $n = $r.Games
  $sum = { param($prop) ($rows | Measure-Object $prop -Sum).Sum }
  $top25 = & $sum Top25
  $placed = @($rows | Where-Object { $null -ne $_.Top25 })
  $placedGames = ($placed | Measure-Object Games -Sum).Sum
  $known = @($rows | Where-Object { $null -ne $_.Delta })
  $summary = @(
    "**$(& $sum Wins)** wins | **$(& $sum Top10)** top 10% | **$top25** top 25% | **$($placedGames - $top25)** lower" + $(if ($placedGames -lt $n) { " (placement known for $placedGames of $n)" } else { '' })
    "**$(& $sum Kills)** kills ($('{0:0.0}' -f ((& $sum Kills) / $n))/game)" + $(if ($source -ne 'myfortnitestats' -and @($rows | Where-Object { $null -eq $_.Minutes }).Count -eq 0) { " | avg **$('{0:0.0}' -f ((& $sum Minutes) / $n)) min** alive" } else { '' })
  )
  if ($known.Count) {
    $knownGames = ($known | Measure-Object Games -Sum).Sum
    $summary += "Net change: **$(Format-Signed (($known | Measure-Object Delta -Sum).Sum) $(if ($sfx) { '% rank progress' } else { ' ELO' }))** over $knownGames $(if ($knownGames -eq 1) { 'game' } else { 'games' })"
  }
  $notes = @()
  if ($source -eq 'myfortnitestats') { $notes += 'OliTracker has no recent games for this player, so these come from myfortnitestats (no survival time or rating change).' }
  elseif ($source -eq 'both') { $notes += 'Rows with - for Min and rating are older games from myfortnitestats (no survival time or rating change).' }
  if (@($rows | Where-Object { $_.Games -gt 1 -and $null -eq $_.Top25 }).Count) { $notes += 'Trackers record games in batches when they check a player, so older days often show as grouped rows; only wins are known inside those.' }
  if ($n -lt 10) { $notes += "Only $n ranked games have been recorded; trackers only log games once they start following a player." }
  if (@($rows | Where-Object { $_.Games -gt 1 }).Count) { $notes += 'Rows marked "N games" are games OliTracker stored together: kills are totals, Min is the average, and the rating change isn''t recorded.' }

  @{
    embeds = @(@{
      title       = "$($Player.Name) - Last $n Ranked Games"
      url         = "https://olitracker.com/stats/$($Player.AccountId)"
      color       = 0x9D4DFF
      description = ($summary -join "`n") + "`n``````" + "`n" + ($table -join "`n") + "`n" + "``````" + $(if ($notes) { "`n-# " + ($notes -join ' ') } else { '' })
      footer      = @{ text = "Battle Royale ranked, newest first. Ago: m/h/d. Min = minutes survived. Lower = below the top 25%. Out Z# = lower, died in zone # (estimated).$(if ($sfx) { ' Rank = % progress (ELO shows in Unreal).' } else { '' })" }
    })
    allowed_mentions = @{ parse = @() }
  }
}
function New-RankedExplainerMessage {
  @{
    embeds = @(@{
      title       = 'How Fortnite Ranked Works'
      color       = 0x9D4DFF
      description = $RankedExplainer + "`n`nType ``!ranked <player name>`` for a personal breakdown and tips."
    })
    allowed_mentions = @{ parse = @() }
  }
}

# --- Discord REST ------------------------------------------------------------
$RefreshEmoji = [char]::ConvertFromUtf32(0x1F504)   # the clickable refresh reaction

function Invoke-DiscordApi([string]$Token, [string]$Method, [string]$Path, $Body) {
  $p = @{
    Method      = $Method
    Uri         = "https://discord.com/api/v10$Path"
    Headers     = @{ Authorization = "Bot $Token"; 'User-Agent' = 'DiscordBot (fortnite-leaderboard, 1.0)' }
  }
  if ($Method -in 'Post', 'Put', 'Patch') {
    $p.ContentType = 'application/json; charset=utf-8'
    $p.Body = if ($null -ne $Body) { ConvertTo-Utf8Json $Body } else { , [byte[]]@() }   # PUT needs a Content-Length
  }
  Invoke-RestMethod @p
}

function Add-RefreshReaction([string]$Token, $ChannelId, $MessageId) {
  Invoke-DiscordApi $Token Put "/channels/$ChannelId/messages/$MessageId/reactions/$([Uri]::EscapeDataString($RefreshEmoji))/@me" | Out-Null
}

function ConvertTo-Utf8Json($obj) { , [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 8 -Compress)) }
