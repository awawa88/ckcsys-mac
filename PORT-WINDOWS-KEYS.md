# Windows CKC → Mac key map (special key)

Source: Andrew 2026-10-27 — special key mirrors DigitSource.
Update: 1st key cannot be a wildcard (idle special → 標點 only, no marked `?`).

## Active special key (DigitSource XOR)
| DigitSource | Special key |
|---|---|
| **小鍵盤 / numpad** | **Num Lock** (KeypadClear 0x47) |
| **鍵盤 / numberRow** | **Grave / backtick** (`` ` `` / `~`, kVK_ANSI_Grave 0x32) |

## Same behavior on the active special key
| State | Action |
|---|---|
| **Idle** (empty buffer) | **標點** picker only — no marked `?` (`enterPunctMode`) |
| **標點 open** + digits 1–9 | Commit that punctuation mark |
| **Composing** | Append `?` only (no 標點) |
| **標點 open** + special again | Next punct page |

## Other keys
| Key | Behavior |
|---|---|
| Optional `?` | 萬能鍵 → marked `?` **only when already composing** (blocked if buffer empty) |
| Optional `` `/~ `` while **numpad** mode | Same — append `?` only when buffer non-empty |
| Number-row Minus / keypad Minus (composing / candidates) | 向前翻頁 |
| Keypad Plus / number-row `=` | 向後翻頁 |
| Keypad Decimal | 刪碼 |
| Caps Lock | toggle 小鍵盤/鍵盤 |

Idle Minus does **not** open punct (pass-through). Inactive special key (e.g. Num Lock in numberRow mode) does not open punct / inject `?`.
