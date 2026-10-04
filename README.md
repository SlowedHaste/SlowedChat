# slowedchat

A World of Warcraft–style chat replacement for **Final Fantasy XI** on **Ashita v4**.

slowedchat replaces the game's chat log with resizable, tabbed ImGui windows. Lines are colored by what they say, the input bar remembers your channel, and the chat moves out of the way of game menus instead of covering them.

Built and tested on the PhoenixXI private server with Ashita v4.3.

> [!WARNING]
> **Use at your own risk.** slowedchat was built as a personal addon for my own setup, and it's shared as-is.
>
> - **It's tuned to one setup.** Some behavior was tuned by hand for one screen size, game setup and play style, and may need adjusting for yours.
> - **Many settings are complicated.** Several interact with each other (sliding vs. fading, hiding the game's chat, the input bar) and can take some trial and error to get right.
> - **Some features modify game memory.** Hiding the game's chat windows, compass and clock, and reading menu sizes, change or read the game client's memory. They're built to fail safe, but there's no guarantee they won't misbehave on another client or server.
>
> No support is promised. If something goes wrong, unload it with `/addon unload slowedchat`.

---

## Features

**Tabs and layouts**
- **One window:** tabs for **All**, **Combat**, **Messages** (party, tells, linkshells) and **System**.
- **Split layout:** a **Chat** window (General, Messages) and a separate **Log** window (Combat, System).
- **Unread marker:** the Messages tab shows a pulsing dot when something new arrives while you're on another tab.
- **Jump to latest:** scrolling up shows a "N new" button that takes you back to the latest line.

**Readable, colored chat**
- **Channel colors:** WoW-style colors for Say, Party, Linkshell, Tell, Shout and the rest.
- **Combat colors:** combat lines are colored by what happened: damage dealt or taken, misses, heals, buffs, spells, weapon skills, crits, skillchains and defeats.
- **System colors:** loot, gil, experience and error messages each get their own color.
- **Game colors kept:** the game's own colors for items and key items show through, and numbers in combat lines are highlighted.
- **Names your way:** speaker names can be shown WoW-style (`[Party] Name: hi`, `Name says: hi`) or the game's way (`(Name) hi`).
- **Mentions:** lines where someone says your name get a soft gold highlight.
- **Text options:** choice of font (Segoe UI, Tahoma, Verdana, Calibri, Arial and more), size, outline or shadow, and optional timestamps.
- **Custom colors:** every color can be changed in the settings window.

**Typing**
- **Input bar:** pressing **Enter** or **/** opens slowedchat's own input bar instead of the game's.
- **Sticky channels:** `/p`, `/l`, `/t Name` and so on switch your channel and keep it. `/r` replies to your last tell.
- **Auto-translate:** type `{Phrase}` to send a real auto-translate phrase. **Tab** completes phrase names, and a suggestion list appears as you type.
- **History:** Up and Down scroll through what you've sent.
- **Commands work as usual:** game commands, Ashita commands, addon commands and Shorthand (`//provoke`) all work from the bar.

**Out of the way of game menus**
- **Slides aside:** when a game menu opens (player menu, abilities, magic, Mog House, Yes/No prompts…), the chat slides right just far enough to clear it, then slides back when the menu closes.
- **Item lists:** item lists slide the chat further, to clear the item details box.
- **Fade or hide instead:** if you'd rather, the chat can fade or hide for menus instead of sliding.
- **NPC dialogue:** the chat stays visible during NPC conversations, so you can read the dialogue.

**Window look**
- **Background on hover:** the window's background and frame only show while you hover over it or type, with a light shade kept behind the text.
- **Saved layout:** position and size are saved per character.
- **Vana'diel time:** the current Vana'diel day and time are shown in the tab row.

**Optional game UI hiding**
- **Game chat:** hide the game's own chat log windows.
- **Compass and clock:** hide the game's compass and clock.

---

## Requirements

- **Ashita v4.3 or newer.** slowedchat uses the ImGui 1.92 that ships with Ashita 4.3.
- **FFXI with an English client.** Auto-translate phrases and speaker detection assume English.

---

## Installation

1. Download this repository and place the folder at `Ashita/addons/slowedchat/`. The folder must be named `slowedchat`, and `slowedchat.lua` must be directly inside it.
2. In game, run:
   ```
   /addon load slowedchat
   ```
3. To load it automatically, add the line below to your Ashita startup script (for example `scripts/default.txt`):
   ```
   /addon load slowedchat
   ```

Open the settings with `/schat`, or with the ☰ button in the chat window's tab row.

---

## Using the input bar

| Type | Does |
|---|---|
| `hello` | Sends to your current channel. |
| `/p hello` | Sends to party, and party becomes your channel. |
| `/p` | Switches to party without sending. |
| `/s` `/sh` `/yell` `/l` `/l2` `/u` | Say, Shout, Yell, Linkshell, Linkshell 2, Unity. |
| `/t Name hello` | Sends a tell; tells to that person become your channel. |
| `/r hello` | Replies to the last person who sent you a tell. |
| `/em waves` | Emote (doesn't change your channel). |
| `{Looking for Party}` | Sends an auto-translate phrase. |
| **Tab** | Completes the auto-translate phrase you're typing. |
| **Up / Down** | Scrolls through what you've sent. |
| **Escape** | Closes the bar. |

Any other command (`/ma`, `/addon`, `//provoke`, `<t>`, `<job>` …) is passed through exactly as typed. Your channel is remembered per character.

---

## Commands

| Command | Description |
|---|---|
| `/schat` | Opens or closes the settings window. |
| `/schat help` | Lists commands in game. |
| `/schat layout single` \| `dual` | One tabbed window, or Chat + Log windows. |
| `/schat lock` | Locks or unlocks the windows in place. |
| `/schat clear` | Clears all tabs. |
| `/schat input` | Switches between slowedchat's input bar and the game's. |
| `/schat native` | Hides or shows lines in the game's own chat log. |
| `/schat window` | Hides or shows the game's chat windows themselves. |
| `/schat fade` | With a game menu open: changes whether that menu moves the chat. |
| `/schat debug` | Shows each line's chat mode number (for `/schat map`). |
| `/schat map <mode> <category>` | Moves a chat mode to another category, e.g. `/schat map 122 combat`. |
| `/schat unmap <mode>` | Removes a `/schat map` override. |
| `/schat status` | Prints diagnostic information. |

Categories for `/schat map`: `say`, `shout`, `yell`, `emote`, `tell`, `party`, `linkshell`, `linkshell2`, `unity`, `npc`, `combat`, `system`.

---

## Settings

Everything is in the settings window (`/schat`). Settings are saved per character.

- **Layout:** one window or split; lock windows.
- **Appearance:** background only on hover, background opacity, shade behind text.
- **Text:**
  - font, size (`0` matches Ashita's size), line spacing, outline or shadow
  - name style, bold speaker names, mention highlight, timestamps, game item colors
- **Behavior:**
  - input bar on or off
  - what menus do to the chat (slide, fade, hide or stay)
  - fit the slide to the menu, gap after the menu, slide distance in item lists
  - lines kept per tab
- **Game chat:**
  - hide the game's chat windows
  - hide lines from the game's log (NPC dialogue can be left in)
  - hide the compass and clock
  - show Vana'diel time
- **Colors:** every color, with a reset button.

---

## Tips and troubleshooting

- **A line is in the wrong tab.** Run `/schat debug` to see each line's mode number, then move it with `/schat map <mode> <category>`.
- **A game menu moves the chat when it shouldn't (or doesn't when it should).** Open that menu, press `/`, and run `/schat fade` to switch it.
- **The game's chat line opens instead of slowedchat's.** Press Enter once from where it happened; slowedchat learns that spot. `/schat status` shows why Enter was left to the game.
- **Japanese text shows as `?`.** The Windows fonts lack Japanese characters. Try the **Default** font.
- **Something broke.** slowedchat records errors in `addons/slowedchat/error.log` instead of failing silently. Please include that file when reporting a problem.

---

## Known limitations

- **Game menus can't be drawn on top of the chat.** Ashita draws ImGui windows over the game's UI, so slowedchat slides or fades the chat out of the way instead.
- **The item details box needs a fixed slide.** It's a display rather than a menu, so its size can't be read. Item lists slide by a fixed distance, adjustable in settings.
- **Some features modify game memory in place.** Hiding the game's chat windows and compass, and reading menu sizes, rely on memory signatures. A client update could break them; when slowedchat can't find what it needs, it turns the feature off rather than guessing.

---

## Credits

- **Hiding the game's chat windows:** adapted from [HXIUIBegone](https://github.com/ryuutatsuo23-max/HXIUIBegone) by DragoHorse, which builds on Ashita's `hideparty` by atom0s (GPL-3.0-or-later).
- **Hiding the compass and clock:**
  - compass signature and Vana'diel time reading from [FancyCompass](https://github.com/purya-mochimochi/FancyCompass), with the time signature originally from GlamourUI
  - compass patch safety rules from HXIUIBegone
- **Game menu detection:** signature from [XIUI](https://github.com/tirem/XIUI) (thanks to Velyn).
- **Auto-translate phrase list:** from [Windower Resources](https://github.com/Windower/Resources).
- **Packet research:** [XiPackets](https://github.com/atom0s/XiPackets) by atom0s.

## License

slowedchat includes code adapted from GPL-3.0-or-later projects (see Credits), so it is distributed under the **GNU General Public License v3.0 or later**.
