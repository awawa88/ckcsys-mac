# ckcsys 縱橫輸入法 for mac

Native macOS Input Method Kit input source for **縱橫 / CKC / Ckcsys** (not Cangjie).
Digit keys only. Display name: **Ckcsys**.

## Status

- [x] Swift IMK app → `~/Library/Input Methods/Ckcsys.app`
- [x] Full Windows lexicon (`cht_zimb_VISTA.tsv` + `cht_cimb_VISTA.tsv`)
- [x] Custom phrases: Ctrl+= / menu **新增詞語…** → `~/Library/Application Support/CKC縱橫/user_phrases.tsv`
- [x] Native floating **candidate popup** (vibrancy HUD, rounded, accent highlight, dark mode)
- [x] App / Input Source icon (`AppIcon.icns` — keypad + stroke glyphs)
- [ ] Add **Ckcsys** once in System Settings → Keyboard → Input Sources (human one-time)

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

## Candidate popup UX

While typing digits, a compact floating panel appears near the caret:

| Area | Content |
|------|---------|
| Top | Composition code (e.g. `0307`) + page `1/N −/=翻頁` |
| Body | Numbered candidates 1–9, accent highlight on selection |
| Footer | `↑↓選  −/=翻頁  Tab+1–9  Space確認` |

### Keys

| Action | Behavior |
|--------|----------|
| `0`–`9` (top row / numpad) | Append digit (max 6) |
| `↑` / `↓` | Move highlight |
| `-` / `=` | Previous / next **page** (Windows CKC) |
| `PageUp` / `PageDown` | Same paging |
| `,` `[` `←` / `.` `]` `→` | Also page prev / next |
| Space / Return | Commit **highlighted** candidate |
| Tab then `1`–`9` | Pick by index (select mode) |
| Option/Ctrl + `1`–`9` | Pick without Tab |
| Esc | Dismiss / clear |
| Ctrl+= | Add Phrase… (even while composing) |

**Try:** type `0` → popup shows 的/香港/… → press `=` for next page → `↓` to move → Space to commit.

## Proof sequences

| Code | Result |
|------|--------|
| `0307` + Space | 我 |
| `289449` + Space | 縱橫 |
| `0` + Space | 的 (or another page-1 pick) |

## Project layout

```
Sources/   main, DictionaryStore, CandidateWindow, AddPhrasePanel, CKCInputController
Resources/ Info.plist, AppIcon.icns, *.lproj/InfoPlist.strings, tables/
scripts/   build.sh, install.sh, make-installer.sh
build/     Ckcsys.app
```

## Bundle

- App: `Ckcsys.app`
- Display name: **Ckcsys**
- Bundle ID: `com.andrewlam.inputmethod.ckc` (internal only — UI must show Ckcsys)
- Icon: `AppIcon`
