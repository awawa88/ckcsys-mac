# Ckcsys macOS IMK — STATUS

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
