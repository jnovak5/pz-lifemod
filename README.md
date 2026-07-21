# AuroraLife – Limited Lives Reimagined

> A server-authoritative finite lives system for **Project Zomboid Build 42** multiplayer.

[![PZ Version](https://img.shields.io/badge/PZ-Build%2042-red)](https://projectzomboid.com)
[![Mod Version](https://img.shields.io/badge/Mod-1.0.0-blue)](https://github.com/jnovak5/pz-lifemod/releases)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

## Overview

AuroraLife gives your multiplayer server a **seasonal life system** — players start each season with a finite pool of lives. Death matters, but a single mistake won't permanently remove someone from the server. Once all lives are exhausted the player is **eliminated**, optionally kicked and/or removed from the whitelist.

Lives are tracked by **username** and persist across restarts, character recreations, and username changes. The system is fully **server-authoritative**, so clients cannot manipulate their own life count.

---

## Features

| Feature | Details |
|---|---|
| 🎯 Finite lives per season | Configurable starting count (1–99) |
| 🔒 Server-authoritative | All life changes happen server-side |
| 🪪 Username tracking | Survives character resets and restarts |
| 💀 Elimination system | Kick and/or whitelist removal on last life |
| 🔧 Sandbox options | Full in-game configuration panel |
| 🛡️ Admin commands | View, add, remove, set, and restore lives |
| 📢 Private death messages | Whispered notifications so only the dying player sees them |
| 🚫 Anti-exploit cooldown | Duplicate `OnPlayerDeath` events suppressed within 5 seconds |
| 📋 Server logging | All life changes written to the server log with timestamps |

---

## Installation

1. Copy the `42/` folder into your Project Zomboid **mods** directory:
   ```
   %HomePath%\Zomboid\mods\AuroraLife\
   ```
   The final layout should look like:
   ```
   mods/
   └── AuroraLife/
       ├── mod.info
       └── media/
           └── lua/
               ├── client/
               ├── server/
               ├── shared/
               └── scripts/
   ```
2. Enable **AuroraLife** in the Mods menu when creating or managing your server.
3. Configure via **Sandbox Settings → AuroraLife** (see [Configuration](#configuration) below).

---

## Configuration

All options are exposed in the in-game **Sandbox Settings** panel under the *AuroraLife* page. They can also be set directly in the server's `SandboxVars.lua`.

| Option | Type | Default | Description |
|---|---|---|---|
| `EnableSystem` | boolean | `true` | Enable or disable the entire life system |
| `StartingLives` | integer | `5` | Lives each player begins the season with (1–99) |
| `KickOnElimination` | boolean | `true` | Kick the player when their last life is used |
| `EnablePrivateDeathMessage` | boolean | `true` | Send a whispered life-count message on death |
| `RemoveFromWhitelistOnElimination` | boolean | `false` | Remove from server whitelist on elimination |
| `RestoreLives` | integer | `1` | Lives returned by the `/lifes restore` admin command (1–99) |

---

## Admin Commands

Admins and Moderators can manage lives via the in-game chat:

| Command | Description |
|---|---|
| `/lifes view <username>` | View a player's current lives |
| `/lifes add <username> <n>` | Add *n* lives to a player |
| `/lifes remove <username> <n>` | Remove *n* lives from a player |
| `/lifes set <username> <n>` | Set a player's lives to exactly *n* |
| `/lifes restore <username>` | Restore lives using the configured `RestoreLives` amount |

---

## File Structure

```
AuroraLife/
├── common/
│   └── mod.info                        # Mod metadata
└── 42/
    └── media/
        ├── lua/
        │   ├── client/
        │   │   ├── AuroraLife_Client.lua  # Client-side life HUD & networking
        │   │   └── AuroraLife_UI.lua      # UI panel / life display
        │   ├── server/
        │   │   ├── AuroraLife_Server.lua  # Core server logic & event hooks
        │   │   ├── AuroraLife_DataStore.lua # Username-keyed persistent storage
        │   │   ├── AuroraLife_DeathHandler.lua # OnPlayerDeath with cooldown guard
        │   │   ├── AuroraLife_Commands.lua # Admin slash-command parsing
        │   │   ├── AuroraLife_Admin.lua   # Admin action handlers
        │   │   └── AuroraLife_Logger.lua  # Structured server logging
        │   └── shared/
        │       ├── AuroraLife_Shared.lua  # Constants, utilities, version
        │       └── Translate/EN/
        │           └── Translate_EN.txt # English translations
        └── scripts/
            └── AuroraLife_SandboxVars.lua # Sandbox option definitions
```

---

## Compatibility

- **Project Zomboid**: Build 42 (multiplayer)
- **Singleplayer**: The system auto-disables itself in singleplayer sessions
- **Other Mods**: Compatible with most mods; uses a namespaced network module (`AuroraLife`) to avoid conflicts

---

## License

MIT — see [LICENSE](LICENSE) for details.
