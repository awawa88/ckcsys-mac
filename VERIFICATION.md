# Verification Guide: Chrome/Docs First-Shot Caret Placement Fix

## Overview
This guide helps verify the fix for the candidate panel appearing at the wrong position (top-left corner) in Google Docs and Chrome when starting a new composition.

## What Was Fixed

### Before
- ❌ First keystroke → panel at top-left corner (wrong)
- ❌ Subsequent keystrokes → panel stays at wrong place unless you click
- ❌ Click new caret → panel at top-left again (issue repeats)
- ✅ Mouse movement → panel doesn't follow (correct, from PR #3)

### After
- ✅ First keystroke → panel near caret (may use suspicious rect initially)
- ✅ Subsequent keystrokes → panel upgrades to good position quickly
- ✅ Click new caret → panel near new caret (not stuck at old position)
- ✅ Mouse movement → panel stays anchored (preserved from PR #3)

## Build Instructions

1. **Clone and checkout the fix branch:**
   ```bash
   git clone https://github.com/awawa88/ckcsys-mac.git
   cd ckcsys-mac
   git checkout cursor/fix-chrome-docs-first-caret-rect-b29b
   ```

2. **Ensure lexicon tables are in place:**
   - Place `cht_zimb_VISTA.tsv` and `cht_cimb_VISTA.tsv` in `Resources/tables/`
   - Or copy from an existing installation

3. **Build the IME:**
   ```bash
   ./scripts/build.sh
   ```

4. **Install:**
   ```bash
   ./scripts/install.sh
   ```

5. **Enable in System Settings:**
   - System Settings → Keyboard → Input Sources
   - Click `+` → Chinese, Traditional → Ckcsys
   - Log out and log back in (or restart)

## Test Scenarios

### Test 1: Google Docs First Composition
**Goal:** Verify panel appears near caret on first keystroke without clicking.

1. Open Google Docs in Chrome
2. Click once in the document to set insertion point
3. **WITHOUT clicking again**, start typing CKC digits: `21213`
4. **Expected:** Candidate panel (選詞×) appears **near the caret**, NOT at top-left corner
5. Continue typing: `2121399`
6. **Expected:** Panel stays near caret, updates position as needed
7. Move mouse around the screen
8. **Expected:** Panel does NOT follow mouse (stays anchored to caret)

**Debug:** Check `/tmp/ckc-ime.log` for:
- `fresh caret rect is SUSPICIOUS` = detected bad rect but using it temporarily
- `fresh caret rect is GOOD` = found good rect, panel should be well-positioned
- Messages should show upgrading from suspicious to good rect

### Test 2: Multiple Caret Positions (Critical!)
**Goal:** Verify panel tracks new caret positions, not stuck at old ones.

1. In Google Docs, click at the **beginning** of a line
2. Type some digits: `1234`
3. **Expected:** Panel near caret at line start
4. Press Esc to cancel composition
5. Click at the **end** of the same line (different caret position)
6. **WITHOUT clicking again**, type digits: `5678`
7. **Expected:** Panel appears near the **new caret** at line end
8. **NOT expected:** Panel stuck at old position (line start) or top-left

### Test 3: Rapid Caret Switching
**Goal:** Verify issue doesn't reappear after switching between multiple carets.

1. Click at position A in the document, type `111`
2. Esc to cancel
3. Click at position B (far from A), type `222`
4. Esc to cancel
5. Click back at position A, type `333`
6. **Expected:** Panel appears correctly at position A (not top-left)
7. Esc to cancel
8. Click at position B, type `444`
9. **Expected:** Panel appears correctly at position B

### Test 4: Other Applications
**Goal:** Ensure fix works across all apps, not just Docs.

Test the same scenarios in:
- ✅ **Microsoft Word** (if installed)
- ✅ **Apple Notes**
- ✅ **TextEdit**
- ✅ **Chrome address bar**
- ✅ **Any other web editor in Chrome**

For each app:
1. Click to set caret
2. Type digits without clicking again
3. Verify panel near caret (not corners)
4. Switch caret positions, verify panel follows

### Test 5: Existing Features Still Work
**Goal:** Verify PR #3 fixes and other features preserved.

1. **Mouse doesn't affect panel position:**
   - Start typing, panel appears near caret
   - Move mouse around screen → panel stays put ✅
   
2. **Click to select candidate:**
   - Panel shows candidates
   - Click on a candidate with mouse
   - Candidate is selected and committed ✅
   
3. **Hand cursor over candidates:**
   - Hover mouse over candidate rows
   - Cursor changes to pointing hand ✅
   
4. **All keyboard shortcuts:**
   - ↑↓ to move selection ✅
   - ←→ to switch columns ✅
   - Space to commit ✅
   - T/* for phrases, Y// for characters ✅
   - −/= to page ✅

## What to Look For

### ✅ Success Indicators
- Panel appears within reasonable distance of actual caret (not corners)
- Panel updates to better position within a few keystrokes
- Panel tracks new caret positions correctly
- Log shows "fresh caret rect is GOOD" messages after initial keystrokes
- No jumping to top-left on new compositions

### ❌ Failure Indicators
- Panel stuck at top-left corner for multiple keystrokes
- Panel doesn't update from bad position to good position
- Panel stuck at old caret position after clicking new location
- Panel follows mouse movement (regression of PR #3)
- Log shows only "SUSPICIOUS" messages, never "GOOD"

## Debugging

### Check Logs
```bash
tail -f /tmp/ckc-ime.log
```

Look for:
- `fresh caret rect is SUSPICIOUS (near corner/edge): {{x, y}, {w, h}} - will keep trying to upgrade`
- `fresh caret rect is GOOD: {{x, y}, {w, h}}`
- `using cached caret rect (suspicious, but no fresh rect available)`

### Expected Log Pattern for Successful Fix

**First keystroke (may be suspicious):**
```
fresh caret rect is SUSPICIOUS (near corner/edge): {{8, 758}, {1, 20}} - will keep trying to upgrade
```

**Subsequent keystrokes (should upgrade to good):**
```
fresh caret rect is GOOD: {{234, 456}, {1, 22}}
```

**If stuck showing only suspicious rects:**
This indicates Chrome/Docs is still returning bad rects even after marked text.
File an issue with the log snippet.

## Known Limitations

1. **First keystroke may be slightly off:** If Chrome returns a suspicious rect on the very first keystroke, the panel will use it but keep trying to upgrade. This is acceptable as long as it corrects within 1-2 more keystrokes.

2. **Some apps may always return corner rects:** If an app consistently returns corner/edge rects even for marked text, the suspicious rect will be used. This is better than a frozen fallback position.

3. **Very fast typing:** If you type extremely fast (faster than IMKit can query caret positions), you might see brief positioning delays. Normal typing speed should be fine.

## Reporting Issues

If you find the fix doesn't work:

1. **Capture the scenario:**
   - Which app (Google Docs, Word, Notes, etc.)
   - Exact steps to reproduce
   - Where did panel appear (screenshot helpful)

2. **Collect logs:**
   ```bash
   tail -100 /tmp/ckc-ime.log > ckc-debug.log
   ```

3. **File issue at:** https://github.com/awawa88/ckcsys-mac/issues
   - Include: app, steps, screenshot, log file
   - Mention PR #4 (first-shot caret placement fix)

## Success Criteria

The fix is considered successful if:

✅ First keystroke in Google Docs (without clicking) places panel reasonably near caret  
✅ Subsequent keystrokes improve position if initial was suspicious  
✅ Clicking new caret positions updates panel location correctly  
✅ Panel never gets permanently stuck at corners/edges  
✅ Mouse movement doesn't affect panel position (PR #3 preserved)  
✅ Click-to-select and all keyboard shortcuts still work  
✅ Fix works across all apps (Docs, Word, Notes, TextEdit, etc.)

---

**Build date:** 2026-10-27  
**PR:** #4  
**Branch:** `cursor/fix-chrome-docs-first-caret-rect-b29b`
