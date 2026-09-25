---
date: 2026-09-24
topic: macd-menu-bar
---

# mac'd — Menu Bar Health + One-Click Cleanup

## Summary

A minimal macOS menu bar app that shows CPU temperature, RAM use, and free disk space at a glance, and turns Mole's cleaning into a friendly preview → confirm → "you freed X GB" flow. A disktree-style treemap window shows what is taking up the disk and lets users mark, review, and remove it. Mole ships inside the app, so no one ever opens a terminal.

---

## Problem Frame

Mole (`mo`) is an effective Mac cleaner, but it is a CLI. Most Mac users will never install Homebrew, type `mo clean`, or read a terminal preview of what is about to be deleted. They notice a problem only when macOS says the disk is full or the machine feels hot and slow, and at that moment there is no approachable tool in reach. Stats apps (iStat Menus, Stats) show numbers but do not fix anything; cleaner apps (CleanMyMac) fix things but are heavy, subscription-priced, and opaque about what they delete.

The gap is a lightweight, transparent bridge: glanceable health, and when space is short, a one-click cleanup whose preview a non-technical person can read and trust.

---

## Key Decisions

- **Mole GUI first, stats second.** The stats are the hook that tells users when to act; the reason the app exists is making Mole usable without a terminal.
- **Menu bar first, one main window.** Monitoring and cleaning live in the menu bar panel. The disk map gets a window, because a treemap needs room.
- **The disk map can remove things, disktree-style.** Mark → review → Move to Trash by default, or delete permanently behind a confirmation that names what goes and how much comes back. Safety rules refuse anything that would break the system or reach outside the scan. Modeled on tobi/disktree (MIT).
- **Bundle Mole inside the app.** Zero setup for users. The app owns which Mole version it ships and when it updates.
- **Distribute outside the Mac App Store.** Built for the author first, shared later as a notarized download. The App Store sandbox would block temperature sensors and running Mole.
- **Preview is mandatory and all-or-nothing.** No "clean without looking" action exists. Every cleanup shows what will be removed and how much space it frees, then cleans everything shown or nothing. Mole cannot clean a subset of categories.
- **No admin password in v1.** Cleanup covers only what does not need elevated privileges, and says what it skipped.

---

## Requirements

**Menu bar glance**

- R1. The menu bar item shows CPU temperature, RAM use, and free disk space in a compact form.
- R2. The user can choose which of the three metrics appear in the menu bar item.
- R3. Metrics refresh on a cadence that keeps the app's own CPU and energy use negligible.
- R4. CPU temperature works on Apple Silicon Macs, independently of Mole (Mole reports `0` on an M2 Max).
- R5. When a metric cannot be read, the app shows it as unavailable rather than a wrong number.

**Panel**

- R6. Clicking the menu bar item opens a panel with the three metrics in more detail (for example, used vs total RAM, free vs total disk).
- R7. The panel offers two actions: Free up space and Analyze disk.

**Cleanup**

- R8. Free up space first runs a preview that lists what would be removed, grouped into plain-language categories with sizes and a total.
- R9. The preview offers exactly two choices: Clean all shown, or Cancel.
- R10. Nothing is deleted until the user confirms the preview.
- R11. After cleanup, the app reports how much space was freed and anything it skipped, including items that need admin rights.
- R12. The app shows progress during preview and cleanup, and handles cancellation or failure without leaving the user guessing.

**Disk map**

- R13. Analyze disk opens a treemap of the home folder, where each tile's area is its size on disk, with drill-down into folders.
- R14. From the disk map, the user can reveal any item in Finder.
- R19. Tile colour shows the kind of data (code, agent scratch, toolchains, synced, git, media, documents, cache), and a hatch marks space that can be had back.
- R20. The map can rank by size, file count, or age (last write), and toggle hidden files, apparent size, and the depth drawn.
- R21. A side panel shows the selection (size, share, files, last write, kind), a "Worth a look" list of the largest plausible removals, and disk free space now and after the marks.
- R22. The user can filter tiles by name, and zoom toward the pointer with scroll or pinch, going into a folder once it fills the view.
- R23. The user can mark and unmark tiles. Marking a folder absorbs marks inside it, and no space is counted twice.
- R24. A review screen lists everything marked. Move to Trash is the default. Delete permanently always asks first, naming what goes and how much comes back.
- R25. After removal the app rescans and reports the free space actually gained.
- R26. Removal refuses the filesystem root, the scanned root, the home folder, `~/Library` itself, system folders, anything on another volume, and anything inside an app bundle or library package.
- R27. Folders macOS will not let the app read are shown as unreadable, with a way to grant Full Disk Access, never guessed at.
- R28. Scanning never downloads cloud-only iCloud files, and counts hardlinked files once.
- R29. The user can widen the scan to the whole data volume.

**Nudges**

- R15. The app sends a notification when free disk space drops below a threshold, and offers Free up space from the notification.
- R16. The user can set or turn off the low-space threshold.

**Packaging**

- R17. The app includes its own copy of Mole and never requires Homebrew or a terminal.
- R18. The app launches at login when the user enables that option.

---

## Acceptance Examples

- AE1. **Covers R8, R10.** Given free space is 12 GB, when the user clicks Free up space, a preview lists categories such as "Browser caches — 3.1 GB" and "App logs — 400 MB" with a total. Nothing is removed until they press Clean.
- AE2. **Covers R9, R11.** Given the preview totals 4.2 GB, when the user presses Clean, every listed category is cleaned and the result says "Freed 4.2 GB" (or the actual freed amount if it differs).
- AE3. **Covers R11.** Given some items need admin rights, when cleanup finishes, the result lists them as skipped with a short reason instead of prompting for a password.
- AE4. **Covers R15, R16.** Given the threshold is 20 GB and free space falls to 18 GB, a notification appears once, and clicking it opens the cleanup preview. It does not repeat every refresh.
- AE5. **Covers R5.** Given the temperature sensor cannot be read, the menu bar shows "—°" instead of 0°.
- AE6. **Covers R23.** Given `~/src/app/node_modules` is marked, when the user marks `~/src/app`, the inner mark is absorbed and the marked total counts `node_modules` once.
- AE7. **Covers R24, R25.** Given 12 GB is marked, when the user chooses Move to Trash on the review screen, the items go to the Trash, the map rescans, and the result shows the measured gain.
- AE8. **Covers R26.** Given the user tries to mark a folder inside `Photos Library.photoslibrary`, the app refuses and says why.
- AE9. **Covers R27.** Given `~/Library/Mail` cannot be read, its tile shows as unreadable, and the panel offers to open the Full Disk Access settings.

---

## Key Flows

- F1. Low space to freed space
  - **Trigger:** Free disk space falls below the threshold, or the user notices it in the menu bar.
  - **Steps:** Notification or panel → Free up space → preview with categories and total → Clean → progress → result.
  - **Outcome:** The user sees how much space was freed and what was skipped.
  - **Covered by:** R8–R12, R15
- F2. Where did my space go?
  - **Trigger:** The user clicks Analyze disk.
  - **Steps:** Window opens → scan with progress → treemap coloured by kind → drill in or zoom → select to see details → reveal in Finder.
  - **Outcome:** The user understands what is taking space.
  - **Covered by:** R13, R14, R19–R22
- F3. Mark, review, remove
  - **Trigger:** The user spots something in the map or the Worth a look list.
  - **Steps:** Mark tiles → free-after updates → Review → unmark any → Move to Trash, or Delete permanently and confirm → rescan → measured gain.
  - **Outcome:** Space comes back, and the map matches the disk.
  - **Covered by:** R23–R26

---

## Scope Boundaries

**Deferred for later**

- Choosing individual categories in the cleanup preview (needs an upstream Mole feature).
- Uninstalling apps with their leftovers (`mo uninstall`).
- Purging old project folders and leftover installer files (`mo purge`, `mo installer`).
- Cleanup that needs admin rights, including `mo optimize`.
- Scheduled or automatic cleaning.
- High-temperature and memory-pressure alerts.
- History charts of metrics or past cleanups.

**Outside this product's identity**

- A full dashboard of every system metric (GPU, network, battery, fans). Stats and iStat Menus already cover this.
- Mac App Store distribution.

---

## Dependencies / Assumptions

- Mole is GPL-3.0. The app bundles it as a separate program it launches, never linking its code. That requires shipping Mole's license text and a link to its source, but it does not make the app itself GPL.
- The bundled Mole runs from inside a signed, notarized app bundle without extra user steps (unverified).
- `mo status --json` and `mo analyze --json` provide machine-readable metrics and disk analysis. `mo clean` does not provide JSON, so its preview output must be interpreted from text.
- Reading CPU temperature on Apple Silicon requires the app's own sensor access, as the Stats app does.
- tobi/disktree is MIT-licensed. Porting its algorithms and rules requires keeping its copyright notice.
- On APFS, cloned files and local snapshots can make the space actually freed smaller than the marked total. The measured gain after removal is the honest number.

---

## Outstanding Questions

**Deferred to Planning**

- How to get a structured cleanup preview from `mo clean --dry-run` without fragile text parsing: parse its output, contribute a JSON mode upstream to Mole, or both.
- How the bundled Mole gets updated: with each app release, or through its own mechanism.
- Default low-space threshold and refresh cadence.

---

## Sources / Research

- Mole v1.49.2 (installed via Homebrew): commands `clean`, `analyze`, `status`, `uninstall`, `purge`, `installer`, `optimize`, `history --json`; `--dry-run` on destructive commands; `--json` on `status` and `analyze`. https://github.com/tw93/Mole
- `mo status --json` on the author's M2 Max (macOS 26.6.2) returned `thermal.cpu_temp: 0`, with RAM and disk populated.
- Stats (exelban/stats), an open-source menu bar monitor and reference for reading Apple Silicon temperature sensors. https://github.com/exelban/stats
- disktree (tobi/disktree), a Linux treemap disk tool and the model for the disk map. https://github.com/tobi/disktree
