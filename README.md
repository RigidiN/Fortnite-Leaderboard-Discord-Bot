# Fortnite Ranked Discord Bot

Posts the Fortnite Ranked (Unreal) leaderboard to a Discord channel, keeps it updated, and answers commands about any player's ranked stats.

## What it does

- **Leaderboard post** - the top players on the Unreal leaderboard with their ELO, updated every 15 minutes. Mods can click 🔄 under it to update it immediately.
- **ELO system post** - sits directly under the leaderboard: the rules, plus what wins, placements, kills and survival are worth, measured from the top players' recent matches every 6 hours.
- **Commands** - anyone in the server can look up players (below).

## Requirements

- Windows 10 or 11. Everything else is built in (PowerShell 5.1 and curl); nothing to install.
- A Discord server where you can add bots and webhooks.
- The PC must stay on and logged in for the bot to work (see [Hosting](#hosting)).

## Commands

| Command | What it does |
|---|---|
| `!leaderboard` | Top players on the Unreal leaderboard with their ELO |
| `!points` | The #1 player's ELO |
| `!points <name>` | Any player's ELO and rank |
| `!ranked` | Short explanation of how ranked works |
| `!ranked <name>` | A player's ranked breakdown: placement and zone stats, tips to gain ELO, and their Reload rank shown separately |
| `!last10 <name>` (or `!recent <name>`) | A player's last 10 Battle Royale ranked games: result, kills, survival time and ELO change for each, with a summary |
| `!help` (or `!commands`) | Lists the commands in Discord |

- Commands must **start** the message: `!ranked Name` works, `nice !ranked Name` doesn't.
- Names aren't case-sensitive. A normal `!` matches the look-alike character Fortnite names use (`Mitsu!` finds `Mitsuǃ`).
- 🔄 refresh on leaderboard messages only works for **mods**: Manage Messages, Manage Server or Administrator, or the server owner. Other clicks are ignored and removed.

## Setup (new computer or fresh install)

1. **Webhook:** in Discord, open the channel's settings > **Integrations** > **Webhooks** > **New Webhook**, and copy its URL.
2. **Bot:** at https://discord.com/developers/applications create an application. On the **Bot** tab:
   - click **Reset Token** and copy it
   - turn on **Message Content Intent** and save
3. **Invite the bot** with this link (replace `APP_ID` with your application's ID from the **General Information** tab):
   `https://discord.com/oauth2/authorize?client_id=APP_ID&scope=bot&permissions=93248`
   That grants View Channels, Send Messages, Embed Links, Read Message History, Add Reactions and Manage Messages.
4. **Config:** copy `config.example.json` to `config.json` and fill in `webhookUrl` and `botToken`. Set `top` to how many players the leaderboard should show.
5. **Install:** in this folder, run:
   ```
   powershell -ExecutionPolicy Bypass -File setup.ps1
   ```
   This posts the leaderboard, schedules the 15-minute updates, and starts the bot (it also starts automatically at every login).

To remove everything: `powershell -ExecutionPolicy Bypass -File uninstall.ps1`. Your files and Discord posts are left in place.

## Settings (`config.json`)

| Setting | Meaning |
|---|---|
| `webhookUrl` | Discord webhook for the leaderboard channel |
| `botToken` | The bot's token. **Keep it secret**: anyone with it can control the bot. Never share `config.json`. |
| `top` | How many players the leaderboard shows (10-50 works well) |
| `mode` | Leaderboard mode on fortnite.com. Leave as `battle-royale` (ELO data is Battle Royale only). |

Leaderboard and ELO post changes apply within 15 minutes. For bot command changes, restart the bot (see below).

## Files

| File | Purpose |
|---|---|
| `discord-bot.ps1` | The command bot (always running) |
| `fortnite-leaderboard.ps1` | Updates the leaderboard + ELO posts (runs every 15 min) |
| `leaderboard-lib.ps1` | Shared code: data fetching, analysis and message building |
| `setup.ps1` / `uninstall.ps1` | Install / remove the background tasks |
| `schedule-every-15-min.ps1`, `start-bot-at-login.ps1` | Used by `setup.ps1` to create each task |
| `config.json` | Your settings and secrets |
| `config.example.json` | Template for `config.json` |
| `state.json` | IDs of the leaderboard and ELO posts. Delete it to post a fresh pair. |
| `elo-model.json` | Cached ELO measurements (refreshed every 6 hours) |
| `bot.log` | Bot activity and errors (trimmed automatically) |
| `build-package.ps1` | Makes a shareable zip in `dist/` without your secrets |
| `.gitignore` | Keeps secrets and generated files out of git/GitHub |

## Troubleshooting

- **Bot doesn't reply:** check `bot.log`. The last line should be "Bot is online". To restart the bot:
  ```
  powershell -Command "Stop-ScheduledTask 'Fortnite Leaderboard Bot'; Start-ScheduledTask 'Fortnite Leaderboard Bot'"
  ```
- **"Discord rejected the bot token"** in the log: reset the token in the Developer Portal and update `config.json`.
- **"Message Content Intent"** in the log: turn it on in the Developer Portal (Bot tab), then restart the bot.
- **🔄 doesn't remove reactions:** the bot's role needs **Manage Messages**.
- **Leaderboard and ELO post separated:** delete `state.json`, and the next update posts a fresh pair together. Delete the old posts in Discord.
- **Player not found:** the name must match their Epic display name.
- **"No match data" for a player:** OliTracker hasn't tracked that player yet.
- **`!last10` shows few games or grouped rows:** the trackers only record games once they start following a player, and often save several games at once (shown as "N games"). A lookup usually starts tracking, so it fills in over time.
- **Everything stops when the PC is off:** the bot runs on this computer, so it only works while the PC is on and you're logged in.

## Where the data comes from

- **fortnite.com** - official Unreal leaderboard (rank order, season)
- **myfortnitestats.com** - ELO (Skill Rating) estimates, player lookup, top-100 account IDs
- **olitracker.com** - match history (last 7 days), season stats, Reload rank
- **myfortnitestats.com match history** - older games for `!last10` when OliTracker has fewer than 10

Epic doesn't publish exact ELO, so all ELO values are tracker estimates. Zones are estimated from survival time using the storm schedule. If any of these sites change their format, the affected feature stops working until the code is updated.

## Hosting

The bot runs on whichever Windows PC it's installed on. For it to be online all the time, install it on a PC or Windows server that stays on, such as a spare computer or a cloud Windows VM. Follow the same setup steps there.

## Sharing

- **Share the bot with your community:** give people the invite link from setup step 3. In the Developer Portal, turn on **Public Bot** (Bot tab) if people outside your team should be able to add it. Commands work in any server it's added to; the automatic leaderboard and ELO posts only go to the channel in your `config.json`.
- **Share the code:** run `powershell -ExecutionPolicy Bypass -File build-package.ps1`. It creates `dist/fortnite-ranked-bot.zip` without `config.json` or any generated files, ready to send or upload to GitHub. Whoever receives it follows the setup steps above with their own bot and webhook.
- **Never share `config.json`.** If your bot token or webhook URL leaks, reset them in Discord.

## Disclaimer

Not affiliated with or endorsed by Epic Games. Fortnite is a trademark of Epic Games, Inc. Data comes from fortnite.com and third-party trackers (myfortnitestats.com, olitracker.com) and may be incomplete or change without notice. If you run this for many servers, keep request volume reasonable and check those sites' terms.