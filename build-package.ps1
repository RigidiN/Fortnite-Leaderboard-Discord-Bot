# Builds dist/fortnite-ranked-bot.zip: everything needed to run the bot, without secrets or generated files.
# Only the files listed here go in, so config.json (bot token, webhook) can never slip in.
$ErrorActionPreference = 'Stop'
$files = @(
  'README.md', '.gitignore', 'config.example.json',
  'discord-bot.ps1', 'fortnite-leaderboard.ps1', 'leaderboard-lib.ps1',
  'setup.ps1', 'uninstall.ps1', 'schedule-every-15-min.ps1', 'start-bot-at-login.ps1', 'build-package.ps1'
)
$dist = Join-Path $PSScriptRoot 'dist'
$stage = Join-Path $dist 'fortnite-ranked-bot'
$zip = Join-Path $dist 'fortnite-ranked-bot.zip'

if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null
foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) -Destination $stage }

# Safety net: refuse to build if a secret from config.json ended up in any packaged file
$configPath = Join-Path $PSScriptRoot 'config.json'
if (Test-Path $configPath) {
  $c = Get-Content -Raw -Encoding UTF8 $configPath | ConvertFrom-Json
  $secrets = @($c.botToken, (("$($c.webhookUrl)" -split '/') | Select-Object -Last 1)) | Where-Object { $_ -and $_.Length -ge 20 }
  foreach ($f in Get-ChildItem -File $stage) {
    $text = Get-Content -Raw -Encoding UTF8 $f.FullName
    foreach ($s in $secrets) { if ($text.Contains($s)) { Remove-Item -LiteralPath $stage -Recurse -Force; throw "Secret found in $($f.Name); package not built." } }
  }
}

if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Remove-Item -LiteralPath $stage -Recurse -Force
Write-Host "Built $zip ($([Math]::Round((Get-Item $zip).Length / 1KB)) KB, $($files.Count) files). It contains no config.json; share it freely."
