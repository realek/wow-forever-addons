# Realek's World of Warcraft: Forever add-ons

Small quality-of-life add-ons for **World of Warcraft: Forever** (interface `16001`).

## Installation

1. Copy the add-on folders you want into
   `World of Warcraft\_forever_\Interface\AddOns\`.
2. **Restart the game completely.** `/reload` doesn't pick up new add-ons.
3. Check that they're enabled in the **AddOns** list on the character select screen.

Each folder is a separate add-on, so you can install any combination.

---

## Loot Roll Anchor

Lets you move the **group loot roll window** (Need / Greed / Pass) and your **bags** from **Edit Mode**.

- Open Edit Mode. A **Loot Rolls** box and a **Bags** box appear. Drag them where you want the windows.
- Boxes snap to screen edges, the screen center, the Edit Mode grid and nearby Edit Mode elements, with the same guide lines as the built-in elements.
- Each Edit Mode layout remembers its own positions.
- Works with both **combined** and **separate** bags.
- Your bags stay wherever the game puts them until you move the Bags box.
- If a window can't be moved during combat, it moves into place as soon as combat ends.

There are no slash commands; everything is done in Edit Mode.

## Spell Rank Upgrade

When you learn a new rank of a spell (for example *Holy Light Rank 2*), it replaces the lower ranks of that spell on **all your action bars** with the new rank. No macros are involved.

- **Opt-in per spell.** Open the spellbook, turn on **Show auto-rank checkboxes** in the settings dropdown next to the search box, and tick the spells you want upgraded. The checkboxes hide again when the spellbook closes. Ticks are saved per character.
- Upgraded buttons **flash gold** a few times so you can see what changed. Buttons on bar pages you aren't looking at don't flash.
- If you learn a rank during combat, it upgrades your bars when combat ends, because action bars can't be changed in combat.
- If you're holding something on the cursor, it waits until you put it down, so nothing gets dropped.
- Any action bar button holding a spell below your highest known rank gets a **red border**, the same one the game draws in green around equipped items, so you can see at a glance which spells are downranked. This happens whether the spell is ticked or not.
- **Lock a slot to keep a lower rank.** Turn on **Lock action bar slots** in the spellbook's settings dropdown (or type `/spellrankupdate lock`), then click spells on your action bars. Locked slots get a **padlock** and are never upgraded, even if the spell is ticked. Other slots holding the same spell still upgrade as usual. Click again to unlock.
  - While lock mode is on, ranked spells show a faint padlock and other buttons are darkened. Clicking doesn't cast anything, but you can still drop spells onto your bars.
  - Lock mode ends when you turn it off, press **Escape**, close the spellbook or enter combat.
  - A lock holds the exact rank you locked. Drag that rank to another slot and the lock moves with it. Replace it with something else and the lock comes off.
  - Locks are saved per character and per spec.

| Command | What it does |
| --- | --- |
| `/spellrankupdate` | Checks every ticked spell on your bars and upgrades any that aren't your highest known rank. Locked slots are skipped, and it tells you how many. |
| `/spellrankupdate config` | Shows or hides the auto-rank checkboxes in the spellbook. |
| `/spellrankupdate lock` | Turns lock mode on or off. While it's on, clicking a spell on your action bars locks or unlocks its slot. |

## Gear Set Guard

Protects items in your **equipment sets** from being sold to a vendor.

- If you sell an item that belongs to any of your equipment sets, it's **bought straight back** and chat tells you which set it belongs to.
- Buying back costs exactly what the vendor paid, so you lose nothing.
- Works however the item was sold: right-click, drag, or anything else.
- The sale itself can't be blocked. Bag item clicks are protected, and interfering with them would break using items in combat. Undoing the sale is the safe alternative.

No setup is needed; it reads your sets from the Equipment Manager.

## Chat Copy

Lets you highlight chat text and copy it.

1. Hold **Alt** and move the mouse over a chat window.
2. While still holding Alt, **drag over the text** to highlight it. You can let go of Alt once you've started dragging.
3. Press **Ctrl+C**, then paste wherever you like.

**Escape**, **Ctrl+C** or clicking elsewhere returns to the normal chat, where links and names are clickable again.

**How it works:** WoW's chat window can't be selected. Chat Copy covers it with a copy of the chat text in the same font, colors, width and scroll position, and hides the real text underneath while you select. The mouse wheel scrolls back through older messages.

**Limitations:**

- Raid marker icons and other inline pictures don't appear while selecting.
- Battle.net friend names show as `?`, because add-ons can't read them.
- Messages the game hides from add-ons show as `[hidden message]`.

---

## License

[MIT](LICENSE) © 2026 Alex Busnita
