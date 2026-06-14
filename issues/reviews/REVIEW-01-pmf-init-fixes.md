# REVIEW-01: Vision Review — pmf-init-fixes

**Date:** 2026-06-14
**Reviewer:** same-model (in-process, subagent unavailable due to capacity)
**Source:** docs/testing/2026-06-14-real-machine/test-report.md
**CSV:** issues/2026-06-14_20-40-05-pmf-init-fixes.csv

## Review Summary

| FIX | Bug Ref | Verdict | Evidence |
|-----|---------|---------|----------|
| FIX-01 | BUG-01 | ✅ PASS | `ensure_apt_updated()` at L325-340, `APT_UPDATED` cache at L25, `sudo -E` on all apt cmds (L331,412,424,436) |
| FIX-02 | BUG-02 | ✅ PASS | `npm_global_cmd_prefix()` at L369-405: detects root/nvm/$HOME-prefix/writable/sudo; fallback msg at L400 |
| FIX-03 | BUG-03 | ✅ PASS | agy uses `curl -fsSL https://antigravity.google/cli/install.sh | bash` (L463); fallback msg (L360-361); tier4_check_cmds updated (L775) |
| FIX-04 | BUG-04 | ✅ PASS | `has_api_key` check at L992-995; --yes auto-skips (L1002); interactive asks (L1006); existing path unchanged (L1015+) |
| FIX-05 | — | ✅ PASS | `log_skip()` helper at L27-37; 14 call sites + 2 inline ⏭️; consistent `⏭️ [comp]: 用户跳过` format |

## Task-Specific Checks

### (1) BUG-01: apt-get update runs exactly once, -E preserves proxy vars
- **PASS**: `APT_UPDATED=false` (L25) ensures single execution. `ensure_apt_updated()` sets `APT_UPDATED=true` after success (L332). All `apt-get install` commands use `sudo -E` (L412, L424, L436). `ensure_apt_updated` called before install_tool apt path (L347).

### (2) BUG-02: npm global install for non-root/nvm
- **PASS**: `npm_global_cmd_prefix()` handles:
  - Root user: returns empty (L373)
  - nvm-managed ($HOME prefix): returns empty (L382)
  - Writable prefix: returns empty (L386)
  - sudo available: returns "sudo" (L392)
  - No sudo: returns error with nvm suggestion (L397-403)
- Applied to codex (L452) and claude (L457) npm installs.

### (3) BUG-03: agy install with actionable fallback
- **PASS**: Install uses curl installer, NOT npm (L463). Failure message provides manual install URL (L360-361). tier4_check_cmds uses `agy --version` instead of `npm outdated -g @google/agy` (L775).

### (4) BUG-04: graphify . SKIPPED when no API key
- **PASS**: Checks 4 API keys (GEMINI, OPENAI, ANTHROPIC, GOOGLE) at L993-994. When none set:
  - --yes mode: auto-skips with SKIPPED status (L1002-1004)
  - Interactive: warns and asks, user can force or skip (L1006-1019)
  - graphify . is NOT retried blindly — it's skipped or explicitly opted-in

## Gaps / Follow-ups
- **No follow-up issues needed.** All 5 fixes address their respective bugs correctly.
- **Validation limitation:** All fixes have `test_mcp: MANUAL` — cannot be auto-tested in agent environment. Manual testing on a real Ubuntu machine is recommended.

## Final Verdict
**CLOSE** — All non-review issues are complete with code evidence. No overstated claims detected. CSV can be closed.
