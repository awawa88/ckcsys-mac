# ckcsys 縱橫輸入法 for mac

Native macOS **IMK Input Source** for **縱橫 / CKC / Ckcsys** (digit codes — not Cangjie).
Display name: **Ckcsys**.

Public home: https://github.com/awawa88/ckcsys-mac

## Status

- [x] Swift IMK → `~/Library/Input Methods/Ckcsys.app`
- [x] Full Windows lexicon TSVs (`cht_zimb_VISTA.tsv` + `cht_cimb_VISTA.tsv`)
- [x] Custom phrases: Ctrl+= / menu **新增詞語…** → `~/Library/Application Support/CKC縱橫/user_phrases.tsv`
- [x] Native floating candidate popup — two columns **選字** | **選詞**
- [x] Floating StatusConsole (draggable short strip: **縱 · 繁 · 小鍵盤/鍵盤**)
- [x] DigitSource modes: numpad **XOR** number-row (one at a time; prefer numpad on full keyboards)
- [x] Menu bar icon: blue **縱** on dark gray rounded square (`menuIcon`)
- [x] Special keys / 標點 / 萬能鍵 `?`
- [ ] Add **Ckcsys** once in System Settings → Keyboard → Input Sources (human one-time)
- [ ] Settings stub (定)

## Download

Prebuilt installer (GitHub Releases):

- **Latest release:** https://github.com/awawa88/ckcsys-mac/releases/latest
- **v0.2.1 pkg:** https://github.com/awawa88/ckcsys-mac/releases/download/v0.2.1/Ckcsys-Installer-0.2.1.pkg

Double-click the `.pkg` to install into `~/Library/Input Methods/Ckcsys.app`, then add **Ckcsys** under System Settings → Keyboard → Input Sources. The package is ad-hoc signed (not notarized); if Gatekeeper blocks it, right-click → Open.

## Build / install

```bash
cd ~/Projects/ckcsys-mac
./scripts/build.sh
./scripts/install.sh
./scripts/make-installer.sh            # → ~/Desktop/Ckcsys-Installer.pkg
./scripts/make-installer.sh --rebuild
```

## Enable (one-time)

1. System Settings → Keyboard → Input Sources → +
2. Search **Ckcsys** (Chinese / Others if needed) → Add
3. Switch via the menu bar input menu
4. Allow **Input Monitoring** if prompted

## Digit modes

Only **one** digit source is active at a time (XOR). Toggle with the StatusConsole **小鍵盤/鍵盤** button, the input-menu item **切換碼元來源（小鍵盤／鍵盤）**, or **Caps Lock**.

| Mode | Label | Digits that compose | Typical use |
|------|-------|---------------------|-------------|
| Numpad (default) | **小鍵盤** | Keypad `0`–`9` | Full keyboards — QWERTY stays English |
| Number-row | **鍵盤** | Top-row `0`–`9` | Laptops / no keypad |

Digits from the inactive source pass through as English.

## Composition / candidates

- Max **6** digit code units.
- 萬能鍵 `?` (and optional `` ` ``/`~` in numpad mode) appends a wildcard **only while already composing** — never as the first keystroke.
- Marked composition shows `[選字]` / `[選詞]` when filtered to that column.
- Floating popup: headers **選字** (left) | **選詞** (right); pick with numbers **1–9** only (no letter shortcuts).
- After **Y** or keypad **`/`** → `1`–`9` picks **字**.
- After **T** or keypad **`*`** → `1`–`9` picks **詞**.
- After a full **6-digit** phrase code → `1`–`9` can pick a phrase directly (no T/* required).
- **Minus** (− / keypad −) = page back; **`=`** / keypad **`+`** = page forward (also PageUp/PageDown, `,`/`[`, `.`/`]`).
- ↑↓ move highlight; ←→ or **Tab** switch column; Space/Return commit; Esc clear.
- Option/Ctrl+`1`–`9` pick from the **選字** column.

## Special keys

Active special key follows DigitSource:

| DigitSource | Special key |
|-------------|-------------|
| **小鍵盤** (numpad) | **Num Lock** (KeypadClear) |
| **鍵盤** (number-row) | **Grave / backtick** `` ` `` (left of `1`; also `~`) |

| State | Special-key action |
|-------|--------------------|
| Idle (empty buffer) | Open **標點** only (no leading `?`) — `1`–`9` commit that punctuation |
| 標點 open + special again | Next 標點 page |
| Already composing | Append 萬能鍵 `?` only (no 標點) |

Other keys:

| Key | Behavior |
|-----|----------|
| Optional keyboard `?` | 萬能鍵 → marked `?` only when buffer non-empty |
| Optional `` ` ``/`~` while **小鍵盤** | Same (in **鍵盤** mode they are the special key) |
| Number-row Minus | Page back when candidates visible — **not** special when idle |
| Keypad Decimal `.` | 輸入碼刪除鍵 — delete last code digit |
| 標點 UI | Same candidate popup by the caret (title `標點 N/M`) |

## Proof sequences

| Code | Result |
|------|--------|
| `0307` + Space | 我 |
| `289449` + Space | 縱橫 |
| `0` + Space | 的 (or another page-1 pick) |

## Project layout

```
Sources/   main, DictionaryStore, CandidateWindow, StatusConsole,
           AddPhrasePanel, CKCInputController
Resources/ Info.plist, AppIcon.icns, menuIcon.*, *.lproj/, tables/
scripts/   build.sh, install.sh, make-installer.sh, check_lexicon.py
build/     Ckcsys.app (gitignored)
```

## Bundle

- App: `Ckcsys.app`
- Display name: **Ckcsys**
- Bundle ID: `com.andrewlam.inputmethod.ckc` (internal — UI shows Ckcsys)
- App icon: `AppIcon` · menu bar: `menuIcon`

