# Windows CKC → Mac key map (special key)

Source: Andrew 2026-10-27 — special key mirrors DigitSource.

## Active special key (DigitSource XOR)
| DigitSource | Special key |
|---|---|
| **小鍵盤 / numpad** | **Num Lock** (KeypadClear 0x47) |
| **鍵盤 / numberRow** | **Number-row Minus** (`-`, 0x1B) |

## Same behavior on the active special key
| State | Action |
|---|---|
| **Idle** (empty buffer) | Open **標點** picker (CandidateWindow by caret) |
| **Composing** | **萬能鍵** — append `?` into marked composition; digits may follow (`1?3`) |
| **標點 open** | Next punct page |

## Other keys
| Key | Behavior |
|---|---|
| Optional `?` / `` `/~ `` | Also 萬能鍵 → marked `?` |
| Keypad Minus (composing) | 向前翻頁 |
| Keypad Plus / number-row `=` | 向後翻頁 |
| Number-row Minus while **numpad** mode + composing | 向前翻頁 (not special) |
| Number-row Minus while **numberRow** mode + composing | special → `?` (not page) |
| Keypad Decimal | 刪碼 |
| Caps Lock | toggle 小鍵盤/鍵盤 |

Inactive special key (e.g. Num Lock in numberRow mode) does not open punct / inject `?`.
