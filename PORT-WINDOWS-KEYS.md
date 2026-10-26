# Windows CKC → Mac key map (special key)

Source: Andrew 2026-10-27 — special key mirrors DigitSource.

## Active special key (DigitSource XOR)
| DigitSource | Special key |
|---|---|
| **小鍵盤 / numpad** | **Num Lock** (KeypadClear 0x47) |
| **鍵盤 / numberRow** | **Grave / backtick** (`` ` `` / `~`, kVK_ANSI_Grave 0x32) |

## Same behavior on the active special key
| State | Action |
|---|---|
| **Idle** (empty buffer) | Marked `?` **and** **標點** picker together (`enterIdleSpecialDual`) |
| **Composing** | Append another `?` only (no 標點) |
| **標點 open** | Next punct page |

## Other keys
| Key | Behavior |
|---|---|
| Optional `?` | Also 萬能鍵 → marked `?` (always) |
| Optional `` `/~ `` while **numpad** mode | Also 萬能鍵 → marked `?` |
| Number-row Minus / keypad Minus (composing / candidates) | 向前翻頁 |
| Keypad Plus / number-row `=` | 向後翻頁 |
| Keypad Decimal | 刪碼 |
| Caps Lock | toggle 小鍵盤/鍵盤 |

Idle Minus does **not** open dual special (pass-through). Inactive special key (e.g. Num Lock in numberRow mode) does not open punct / inject `?`.
