# Ckcsys macOS IMK — STATUS

Time: 2026-10-27 13:15 Asia/Hong_Kong (UTC+8)
Machine: Andrews-Mac-mini (machineId 78fe0a68-08f2-44f8-a752-9508b4a15be8)

## Local 0.2.24 (build 26) — longer phrase overrides shorter auto-shortlist

Ask (t249u–t252u): after adding a longer phrase (e.g. 58834→輸入法), typing only the shorter prefix `5883` must **not** auto-enter 選詞 / auto-show 中等／責令. Shorter 詞 only after explicit 選詞 (T/×). At the full longer code, user-added phrase ranks first. General for every future Add Phrase save (user or stock longer code under the buffer), not a 58834 special case.

Root cause: `shouldAutoSelectMode` still returned true when `hasExactPhrase(buffer)` && no 字 even if `hasLongerCode(buffer)` — so 5883 locked ` **` and shortlisted 中等／責令.

Fix:
- `shouldAutoSelectMode`: **only** auto-enter when `!hasLongerCode(buffer)` and candidates exist. Longer user/stock codes under the buffer override shorter exact-詞 auto-shortlist.
- Keep 0.2.22 `hasCode(withPrefix:)` compose-over-pick when a digit extends a longer code.
- Keep dead-end auto-選詞 (e.g. 00259+1 → 像素 when no longer prefix).
- Ranking unchanged: `candidates()` already puts `userExact` first at the exact code (輸入法 before stock 整人法／贅文 at 58834).

Install path (ONLY): `~/Library/Input Methods/Ckcsys.app`
No GitHub push/merge/release.

Retest: type `5883` → no auto 選詞 list / no ` **`; press 選詞 (T/×) → 中等／責令; type `58834` → 輸入法 first; dead-end `00259`+1 still → 像素.

---

# Ckcsys macOS IMK — STATUS

Time: 2026-10-27 13:03 Asia/Hong_Kong (UTC+8)
Machine: Andrews-Mac-mini (machineId 78fe0a68-08f2-44f8-a752-9508b4a15be8)

## Local 0.2.23 (build 25) — save-time shorter-詞 check (Add Phrase)

Ask: when saving a new phrase, IME should also check whether shorter 詞 exist on that code’s prefixes, so display/typing expectations are clear (follow-up to 58834→輸入法 / 5883→中等／責令).

Keep: type-time `hasCode(withPrefix:)` compose fix from 0.2.22 — unchanged.

Save-time:
- `DictionaryStore.shorterExactPhrases(for:)` — every proper shorter prefix that already has an exact 詞 (user or stock).
- Add Phrase UI (`AddPhrasePanel`): on auto-code, manual code edit, and after save, show a short note e.g. `較短碼已有詞：5883→中等／責令。打字會穿過它們到本詞（正常，可儲存）。`
- Not an error — save always allowed; in-memory exact/userExact + prefixIndex still update immediately on save.
- Auto-code path runs the same check on the generated code.

Install path (ONLY): `~/Library/Input Methods/Ckcsys.app`
No GitHub push/merge/release.

Retest: Add Phrase → 輸入法 (or code 58834) → note lists 5883→中等／責令; save OK; numpad `58834` still composes through 5883 to 輸入法.

---

# Ckcsys macOS IMK — STATUS

Time: 2026-10-27 12:55 Asia/Hong_Kong (UTC+8)
Machine: Andrews-Mac-mini (machineId 78fe0a68-08f2-44f8-a752-9508b4a15be8)

## Local 0.2.22 (build 24) — 58834 → 輸入法 (custom/system phrase compose)

Ask: added custom phrase `58834` → `輸入法`; typing 58834 did not show it.

Root cause:
1. Phrase **was saved** and loaded (`~/Library/Application Support/CKC縱橫/user_phrases.tsv`; activateServer `+ 2 user`).
2. `58834` is also the correct auto-code for 輸入法 (3字 2+2+2 from 輸/入/法 → `58`+`8`+`34`; 入 primary is only `8`) and already exists in stock `cht_cimb_VISTA.tsv`.
3. Typing stopped at `5883`: system exact 詞 (中等/責令) + no 字 → `shouldAutoSelectMode` locked 選詞 (` **`) even though longer keys exist (`58834`, …). Digit `4` was treated as candidate pick #4, so buffer never became `58834`.

Fix:
- `DictionaryStore.hasCode(withPrefix:)` — prefix-index hit test.
- In phrase/char filter and the before-append auto-select gate: if `buffer+digit` is a known longer (or exact) code prefix, **compose** instead of pick (log `extends … → compose` / `auto-select skipped`).
- Keeps dead-end auto-選詞 (e.g. 00259+1 → 像素). At an exact 詞 that still has longer keys, digits that extend keep composing; digits that do not still pick. At `58834`, digit `1` does not extend → picks 輸入法. For `06177`, digit `1` extends to `061771` so it appends — use Space (or a non-extending digit) / 選詞 path for 自己.

Evidence: user_phrases.tsv contains `58834\t輸入法`; system cimb has the same mapping.

Install path (ONLY): `~/Library/Input Methods/Ckcsys.app`
No GitHub push/merge/release.

Retest: numpad `58834` → 選詞 shows 輸入法 (user phrase first); `1` commits 輸入法.

---

# Ckcsys macOS IMK — STATUS

Time: 2026-10-27 12:25 Asia/Hong_Kong (UTC+8)
Machine: Andrews-Mac-mini (machineId 78fe0a68-08f2-44f8-a752-9508b4a15be8)

## Local 0.2.21 (build 23) — StatusConsole right-corner haze

Ask: still a light semi-transparent rectangular layer at the right corner(s) outside the rounded strip.

Cause: white soft glow was on `chromeView.layer` with no `shadowPath`, so Core Animation cast from the rectangular chrome bounds (plus NSVisualEffectView sometimes ignoring parent clip).

Fix:
- Set rounded `shadowPath` matching strip bounds + cornerRadius; refresh on show/resize.
- Also round-mask `effectView` itself (`cornerRadius` + `masksToBounds`).
- Keep glow, left grip, BR resize, thin border.

Installed locally to `~/Library/Input Methods/Ckcsys.app` only — not pushed/released.

Retest: open console on dark background; right corners should have no light semi square.

## Local 0.2.20 (build 22) — association commit inserts suffix only (no seed double)

Keeps 0.2.19 選詞 marked ` **`. Fix: picking an association/guess phrase after a committed 字 no longer re-inserts the seed character (習 + 習慣 was 習習慣).

Strip logic (`associationSuffixToInsert` in `commit`):
1. Candidate list still shows **full** phrases (習慣) for readability.
2. On association commit (`associationSeed` non-empty): insert only the **suffix** after the stored seed (習慣 → 慣).
3. If phrase equals seed alone → insert nothing / dismiss.
4. Seed is stored in Traditional lexicon form (same as phrase lookup). Strip Traditional `hasPrefix(seed)` first; on 繁/簡 mismatch, match via `convertToSimplified` then drop the same character count from the Traditional phrase; convert only the remaining suffix for simplified outputMode.
5. Non-association commits unchanged; do not begin 聯想 again on an association suffix commit.

Retest:
- Commit 習 → T/× → pick 習慣 → document has **習慣** once (not 習習慣).
- Same under 簡: 习 + pick 習慣 → 习惯 once.
- Phrase == seed → no extra insert; guesses dismiss.

Install path (ONLY): `~/Library/Input Methods/Ckcsys.app`
No GitHub push/merge/release.

---

# Ckcsys macOS IMK — STATUS

Time: 2026-10-27 12:20 Asia/Hong_Kong (UTC+8)
Machine: Andrews-Mac-mini (machineId 78fe0a68-08f2-44f8-a752-9508b4a15be8)

## Local 0.2.19 (build 21) — association 選詞 shows marked ` **` at caret

Keeps 0.2.18 聯想 after any 字 + pick only after 選詞. Fix: when guesses are visible and user presses 選詞 (T / ×), the **text-field marked composition** now shows ` **` (same as normal phrase mode), not only CandidateWindow chrome `字 **`.

Behavior:
1. Commit 字 → guess list (聯想) still appears; digits without 選詞 still dismiss guesses and start a fresh code.
2. 選詞 (T / ×) arms picks **and** sets marked caret to ` **` via `updateMarked` (empty buffer + lookKind=.phrases).
3. Digit / Space after 選詞 still picks a phrase. Esc / Backspace / unarmed dismiss clears the caret mark.
4. Candidate chrome still shows `字 **` when armed.

Retest:
- Commit 習 → guess list → press T or × → caret shows ` **` → digit picks phrase.
- Commit 習 → digit without T/× → new code (no forced pick; no leftover ` **`).

Install path (ONLY): `~/Library/Input Methods/Ckcsys.app`
No GitHub push/merge/release.

---

# Ckcsys macOS IMK — STATUS

Time: 2026-10-27 12:15 Asia/Hong_Kong (UTC+8)
Machine: Andrews-Mac-mini (machineId 78fe0a68-08f2-44f8-a752-9508b4a15be8)

## Local 0.2.18 (build 20) — 聯想 after any single 字 + 選詞 to pick

Keeps 0.2.17 inactive-digit passthrough. Adds phrase guessing for **every** committed single character (習 is only the acceptance example — no hardcode).

Behavior:
1. After any 字 commit → CandidateWindow shows lexicon phrases that **start with that character** (`DictionaryStore.phrasesStarting`, cht_cimb / user phrases, pd-ranked, cap 90).
2. Digits without 選詞 start a **fresh** CKC code (guess list dismissed; never steals 1–9).
3. 選詞 (T / × by DigitSource) **arms** association → then 1–9 / Space pick a phrase; chrome shows `字 **`.
4. Esc / Backspace dismisses guesses. Mouse click still an explicit pick.

Retest:
- Commit 習 → see 習慣/習俗/… → press T or × → 1 commits 習慣.
- Commit 習 → without T/× type digits → new code composes (no forced phrase pick).
- Same for other 字 (的/我/…).
- Inactive digit row still types ASCII 0–9 (0.2.17).

Install path (ONLY): `~/Library/Input Methods/Ckcsys.app`
No GitHub push/merge/release.

---

# Ckcsys macOS IMK — STATUS

Time: 2026-10-27 12:10 Asia/Hong_Kong (UTC+8)
Machine: Andrews-Mac-mini (machineId 78fe0a68-08f2-44f8-a752-9508b4a15be8)

## Local 0.2.17 (build 19) — inactive digits always pass through

Andrew: numpad feels locked in number-row mode. 0.2.16 swallowed inactive-row digits while composing/標點 (`return true`); idle only passed through.

Change (`handle` DigitSource gate + punct inactive gate):
- Inactive-source digits **always** `return false` / unhandled → type regular `0`–`9` into the app (prefer real pass-through over swallow, including while composing if IMK allows).
- Still: no buffer append, no DigitSource flip, mode sticky (Caps Lock / StatusConsole only).
- Active side unchanged: compose / auto-選詞 / picks as in 0.2.16.

Retest:
- Number-row mode: top-row composes; numpad types 0–9 into the text field (idle and while composing).
- Numpad mode: pad composes; top-row types 0–9.
- Mode sticky — inactive side never auto-switches DigitSource.

Install path (ONLY): `~/Library/Input Methods/Ckcsys.app`
No GitHub push/merge/release.

---

# Ckcsys macOS IMK — STATUS

Time: 2026-10-27 12:05 Asia/Hong_Kong (UTC+8)
Machine: Andrews-Mac-mini (machineId 78fe0a68-08f2-44f8-a752-9508b4a15be8)

## Local 0.2.16 (build 18) — DigitSource gates compose (one active row)

Andrew rejected 0.2.15 “both numpad and number-row always compose regardless of mode.”

Behavior:
1. DigitSource still sticky — digits from the other physical row never call `setDigitSource` (Caps Lock / StatusConsole only).
2. Mode gates compose + candidate pick:
   - Numpad mode → only numpad digits (and designed pad special/選字/選詞 keys) feed codes / picks.
   - Number-row mode → only main number-row digits feed codes / picks.
3. Inactive-row digits: no buffer append, no mode flip. Idle → `return false` (pass through as typed `1`/`2`/…). Composing or 標點 → `return true` (swallow; safer than inserting into marked text).
4. Auto 選詞 / `06177` → ` **` → `1` → 自己 still works for **active-source** digits only. Punct 1–9 pick also gated.

Retest:
- Numpad mode: numpad `06177` + `1` → 自己; top-row `1` does not append/switch (passthrough or ignore).
- Number-row mode: top-row digits compose; numpad digits do not flip mode or compose.
- Caps Lock / console still toggles mode and headers (÷× vs Y/T).

Install path (ONLY): `~/Library/Input Methods/Ckcsys.app`
No GitHub push/merge/release.

---

Time: 2026-10-27 11:55 Asia/Hong_Kong (UTC+8)
Machine: Andrews-Mac-mini (machineId 78fe0a68-08f2-44f8-a752-9508b4a15be8)

## Local 0.2.15 (build 17) — 06177 → ** → 1 commits 自己

Root cause (retest log): `06177` still has longer keys (`061770`/`061771`/`061777`), so digit `1` **appended** to `061771` and then showed ` **` — it never picked 自己. Felt like "1 only enters phrase mode".

Gate now (after refreshing .all candidates):
- `!hasLongerCode(buffer)`, OR
- `hasExactPhrase(buffer) && charCandidates.isEmpty && !phraseCandidates.isEmpty`
  (exact 詞 code with no 字 left — 06177 qualifies; short prefixes like `0`/`06` still have 字 so they keep composing)

Behavior:
1. As soon as buffer becomes `06177`, auto-enter 選詞 → marked `06177 **`, phrases 自己/零星股/看己/…
2. Digit `1` commits 自己 (sync CandidateWindow before pick so digit never only toggles **).
3. DigitSource still sticky (no auto-switch either direction).

Acceptance: type `06177` → see ` **` → press `1` → 自己.
Also: `00259` → ` **` → `1` → 像素. Numpad/number-row digits do not flip mode.

Install path (ONLY): `~/Library/Input Methods/Ckcsys.app`
No GitHub push/merge/release.

---

# Prior STATUS
Time: 2026-10-27 11:30 Asia/Hong_Kong (UTC+8)
Machine: Andrews-Mac-mini (machineId 78fe0a68-08f2-44f8-a752-9508b4a15be8)

## Local 0.2.13 (build 15) — auto 選詞 when no further code extensions

Andrew: after digits, if there are no more code choices for another digit, the next digit key should switch into phrase-select (選詞) and use that digit as the picker — no need to press T / × / 選詞 first. Not only at length 5: any composition length < 6.

Rule:
- While composing (buffer non-empty, no `?` wildcard), before appending a digit:
  - If `DictionaryStore.hasLongerCode(buffer)` (any lexicon key with that prefix and longer length) → append digit as today.
  - Else → log `auto-phrase-no-extension buffer=… digit=…`, enter phrase mode (marked ` **`), and treat digit 1–9 as phrase pick (commit if valid). Digit 0 / out-of-range still enters phrase mode without committing.
- At length 6, existing phrase-select-by-digit behavior unchanged.
- Normal 6-digit codes with extensions still append.

Retest: type `00259` (5-digit, no 6th extension; phrases 像素/偏東/季績) then `1` → expect commit 像素 (or pick 2/3). Type a 5-digit that *has* a 6th extension (e.g. `00000`) then a digit → still appends toward 6. Optional: `0967` (4-digit no longer codes) then `1` → auto phrase pick.

Install path (ONLY): `~/Library/Input Methods/Ckcsys.app`
No GitHub push/merge/release.

---

# Prior STATUS

Time: 2026-10-27 11:30 Asia/Hong_Kong (UTC+8)
Machine: Andrews-Mac-mini (machineId 78fe0a68-08f2-44f8-a752-9508b4a15be8)

## Local 0.2.12 (build 14) — inactive-panel cursor push/pop + hover chrome

Andrew: pointing-hand over candidates never worked. Root cause: LSUIElement + `.nonactivatingPanel` — AppKit ignores `NSCursor.set()` while inactive (SO 18132778). Prior local mouseMoved monitor was ineffective.

Change (local only — not pushed):
1. Per-row `NSTrackingArea` `[.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect]`.
2. `NSCursor.pointingHand.push()` once on enter/moved over non-empty row; matching `pop()` on exit (tracked to avoid stack spam).
3. On hover: `makeKeyAndOrderFront` the candidate panel (no `NSApp.activate` yet — next lever if push still ignored).
4. Distinct hover background (`labelColor` 12% alpha) vs selected (accent 22%) so clickability is visible even if cursor stays arrow.
5. `acceptsFirstMouse` true on rows; removed ineffective local mouseMoved `.set()` monitor.
6. Throttled `ckcLog` for push/pop/hover/makeKey → `/tmp/ckc-ime.log`.

Prove: hover a candidate in Chrome — expect hand **or** clear hover chrome. If still arrow-only, next lever is carefully scoped activate-on-hover.

Install path (ONLY): `~/Library/Input Methods/Ckcsys.app`

---

## Local 0.2.11 (build 13) — single install; Notes/iMessage init + shared hide; BR resize kept

Andrew: too many Ckcsys installs — wiped all, one local build only.

Wiped before this install:
- `~/Library/Input Methods/Ckcsys.app` (was 0.2.10)
- `Projects/ckcsys-mac/build/Ckcsys.app` (rebuild product)
- No copies in `/Library/Input Methods/`, Downloads, or Desktop

Fixes (local only — not pushed):
1. **Bare `init()` + `construct(client:)`** (vChewing / Shiki Suen): both inits log client bundle id and async `activateServer(theClient ?? client())`.
2. **Shared deferred-hide** on `StatusConsole` (static work item + generation). activate / ensure / show cancel shared pending hide; only matching generation may hide. Fixes cross-controller race seen in `/tmp/ckc-ime.log`.
3. Optional **`setValue(_:forTag:client:)`** re-activates when mode arrives with no client / strip missing.
4. Clear log: `ACTIVATE Notes/Messages client=com.apple.Notes|com.apple.MobileSMS`.

Kept from 0.2.8–0.2.10:
- Digit-from-either-source + buffer-across-deactivate
- 光/錨, left drag grip
- BR resize grip (width-first, persisted)

Install path (ONLY): `~/Library/Input Methods/Ckcsys.app`

After install: click Notes and iMessage message field with Ckcsys selected; type digits. If still dead, remove Ckcsys from System Settings → Keyboard → Input Sources and add it again (known Squirrel/macOS dead-session fix).

---

# Prior STATUS


Time: 2026-10-27 11:09 Asia/Hong_Kong (UTC+8)
Machine: Andrews-Mac-mini (machineId 78fe0a68-08f2-44f8-a752-9508b4a15be8)

## Local 0.2.10 (build 12) — StatusConsole BR resize grip

Ask: resize StatusConsole from lower-right corner (ATC FIDS-style diagonal hatch).

Change (local only — not pushed):
- `ResizeGripView` (~14pt) bottom-right of StatusConsole; tertiary diagonal lines; cursor `NSCursor.resizeLeftRight`.
- Drag resizes **width-first** (min 160 / max 400). Optional height within 24–40 if vertical drag >4pt.
- Persists `ckc.statusConsole.width` / `.height` in UserDefaults.
- `placeUsingSavedOrDefault` / `clampedOrigin` use live persisted size (not fixed constant only).
- Dedicated BR zone — left DragGripView + 繁/簡 / 鍵盤 / 光/錨 unchanged.
- On resize end, if `candidateAnchor == .console`, calls `CandidateWindow.repositionForCurrentAnchor()`.
- Keeps all 0.2.9 behavior (deferred hide, 光/錨, left 3×6 drag grip).

Install: `~/Library/Input Methods/Ckcsys.app` relaunched after `scripts/build.sh` + `scripts/install.sh`.

Note: Notes/Messages IMK console visibility is **out of scope** for this bump; parent researching separately.

---

# Prior STATUS
Time: 2026-10-27 11:00 Asia/Hong_Kong (UTC+8)
Machine: Andrews-Mac-mini (machineId 78fe0a68-08f2-44f8-a752-9508b4a15be8)

## Local 0.2.9 (build 11) — StatusConsole missing in iMessage

Problem: console doesn’t show after clicking the iMessage caret.
Cause: Messages/Notes/Chrome churn activate↔deactivate; `deactivateServer` called `StatusConsole.shared.hide()` immediately, so the strip was ordered out right after activate showed it.

Fix (local only — not pushed):
- `deactivateServer` schedules deferred StatusConsole hide (~0.30s) with generation token / `DispatchWorkItem`; activate / ensure-visible cancel it.
- Candidate hide on deactivate unchanged (buffer kept; restore on activate).
- Belt-and-suspenders: `ensureStatusConsoleVisible` on keyDown / special-key / digit compose if strip not visible.
- ckcLog lines: `StatusConsole show (activate|ensure-key)`, `schedule-deferred-hide`, `deferred-hide fire` with client bundle id.

- StatusConsole **光/錨** toggle (`ckc.candidateAnchor` = caret|console, default caret): 錨 parks candidate popup immediately above the strip (Google Docs/Chrome); 光 keeps caret placement. Repositions live on toggle and while dragging the strip in 錨 mode.

- Left **drag grip** (3×6 tertiary dots, airport-board style): primary drag handle; buttons stay clickable (ChromeView no longer claims empty chrome for drag).

---

---

# Prior STATUS

Time: 2026-10-27 02:20 Asia/Hong_Kong (UTC+8)
Machine: Andrews-Mac-mini (machineId 78fe0a68-08f2-44f8-a752-9508b4a15be8)

## Fixed this build (two bugs)

### 1) Keypad digits not composing
Root cause:
- Saved `ckc.digitSource` was `numberRow` (鍵盤), so XOR gate rejected all numpad 0–9 (pass-through English).
- Caps Lock `flagsChanged` could fire twice per press (same lock state) → DigitSource toggled even times and appeared “stuck”.

Fixes:
- Caps Lock edge-detect (`lastCapsLockOn`); sync on activate without spurious toggle.
- `classifyDigit` takes `rawFlags`; char fallback honors `.numericPad`.
- Keycode matches use `Int(kVK_ANSI_Keypad*)`.
- Log `digit compose …` / `digit … REJECTED …` to `/tmp/ckc-ime.log`.
- Pref reset to `numpad` (小鍵盤).

### 2) 標點 panel parked by StatusConsole
Root cause:
- `showPunctuationPage` / `positionPunctPanel` deliberately anchored above StatusConsole.

Fixes:
- Idle 標點 uses the same `CandidateWindow.show(…)` path as 字/詞 (title `標點 N/M`, numbered 1–9).
- Removed park-above-console positioning; caret/client geometry first, then mouse, never StatusConsole as primary.

## Product rules (unchanged)
- Idle special: Num Lock (小鍵盤) or Grave/`/`~ (鍵盤) → 標點 only (no marked `?`); Minus = page-prev when composing.
- After T/* or full 6-digit: 1–9 phrases; after Y//: 1–9 chars.
- DigitSource XOR; StatusConsole 縱·繁·小鍵盤/鍵盤.
- Keypad Decimal = 刪碼; optional wildcard `?` always; `` `/~ `` optional wildcard only in 小鍵盤 (in 鍵盤 they are the special key).

## Install
`~/Library/Input Methods/Ckcsys.app` — enabled as `com.andrewlam.inputmethod.ckc`.
Debug log: `/tmp/ckc-ime.log`

## 萬能鍵 (2026-10-27 01:55 HKT)
- Both **`?`** (Shift+/) and `` `/~ `` append `?` into the **marked** composition buffer **only when already composing** (1st key cannot be wildcard).
- Digits may continue after `?` (e.g. `1?` → `1?3`); cap 6; wildcard lookup updates. Leading `?` alone is blocked.
- `return true` so `?` is never inserted as committed document text until Space/pick.
- Handled **before** 字-end so Shift+/ is not mistaken for bare `/`.
- Num Lock remains 標點 only.

## Key map fix (2026-10-27 02:00 HKT)
- **Num Lock = 萬能鍵** → `NumLock → wildcard marked '?'` in composition (idle or mid-code). NOT 標點.
- **Minus** (number-row + idle keypad) = 標點 picker (CandidateWindow by caret).
- Optional `?` / `` `/~ `` also wildcard.
- Prior bug: Num Lock while composing was swallowed — fixed.

## Special key (2026-10-27 02:03 HKT)
DigitSource-gated mirror:
- **小鍵盤** → Num Lock: idle=標點, composing=`?`
- **鍵盤** → number-row Minus: idle=標點, composing=`?`
Log: `specialKey src=…`, `NumLock/Minus special → punctMode ON (idle)`, `NumLock/Minus → wildcard marked`.

## Special key → Grave in 鍵盤 (2026-10-27 02:12 HKT)
- **小鍵盤** special stays **Num Lock**.
- **鍵盤** special is **Grave / backtick** (`` ` `` and `~`, kVK_ANSI_Grave 0x32).
- **Minus** = **向前翻頁** when candidates visible; idle Minus is not special.
- Log label: `Grave special → …` in numberRow mode.

## Idle special = 標點 only (2026-10-27 02:20 HKT)
Andrew: **1st key cannot be a wildcard.**
- Idle / first keystroke of active special (Num Lock if 小鍵盤, Grave if 鍵盤) → **標點 only**; buffer stays empty — **no** marked `?` in the text field. `enterIdleSpecialDual` removed.
- While 標點 open: digits **1–9** commit that punctuation mark (not wildcard-continue).
- Already composing (buffer non-empty) + special → append `?` only, no 標點.
- Optional keyboard `?` / `` `/~ ``: `appendWildcardMarked` requires `!buffer.isEmpty`; idle `?` does not start composition.
- punctMode special key → next 標點 page.
