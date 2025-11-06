# Roblox Systems Showcase

This repository contains production-style Roblox Lua modules I wrote for action / simulator-style games. The focus is on clean server-side logic, modular services, and safe client → server communication.

## Contents

- `combat/CombatServer.lua`  
  Server combat handler that:
  - validates the player/tool
  - plays weapon-specific combos from a `WeaponsInfo` table
  - fires VFX to all clients
  - uses a HitboxService to apply damage
  - handles dash and special skills with cooldowns
  This shows server-authoritative combat and animation marker syncing.

- `abilities/HoppaService.lua`  
  Large ability service that powers a “launch into the air then glide” mechanic. Includes:
  - environment/raycast checks (can you use this here?)
  - ascent → peak → glide phases
  - VFX/SFX spawning
  - quest + leaderboard hooks
  - anti-spam / cooldown tagging
  This shows long-form service code and game integration.

- `movement/AnimationHandler.lua`  
  Client-side animation coordinator that:
  - separates animations into channels (movement, fall, emote, ability)
  - reacts to Humanoid state changes
  - adjusts animation speed based on velocity
  This shows clean OOP-style Lua and character polish.

## Goals

- Show understanding of Roblox client/server split
- Show ability to organize large modules
- Show ability to integrate services (quests, datastore, leaderboards, VFX)

> Note: Some `require(...)` paths reference the original project structure. In a real project these would point to your own Modules folder.
