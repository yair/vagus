# Vagus — Heartbeat Control Plane

*Named after the vagus nerve, which regulates heartbeat rhythm.*

## What Vagus Is

A Perl-based deterministic state machine that runs on cron, checks system health,
and wakes the right agent at the right time with the right context.
It replaces the current `heartbeat-gate.sh` + gated heartbeat system.

**Vagus is not an AI agent.** It's infrastructure. It makes zero LLM calls itself.
It reads state files, applies rules, and sends wake commands to OC agents
or Telegram alerts. The intelligence lives in the agents it wakes.

## What It Replaces

Currently:
```
cron (10min) → heartbeat-gate.sh (bash, checks cron/disk/usage)
  → score > threshold → fire OC heartbeat → loads FULL compacted context on Opus
  → agent reads HEARTBEAT.md, checks everything again, replies HEARTBEAT_OK
  → burned 2-5K Opus tokens to say "nothing to do"
```

After Vagus:
```
cron (10min) → vagus (Perl, all checks + state + routing)
  → nothing to do → exit 0 (zero tokens)
  → fire detected → wake specific agent with specific task on appropriate model
  → batch work window → wake worker agent with specific todo on cheap model
```

## Architecture

```
                          ┌─────────────────────┐
                          │     vagus.conf       │
                          │  (all constants,     │
                          │   thresholds, paths) │
                          └──────────┬──────────┘
                                     │
┌──────────┐              ┌──────────▼──────────┐
│  cron    │──(10 min)──▶ │      vagus.pl       │
└──────────┘              │                     │
                          │  1. Load config     │
                          │  2. Run checks      │
                          │  3. Read state       │
                          │  4. Apply rules     │
                          │  5. Take action     │
                          │  6. Update state    │
                          │  7. Log & exit      │
                          └──────────┬──────────┘
                                     │
                    ┌────────────────┼────────────────┐
                    │                │                │
              ┌─────▼─────┐  ┌──────▼──────┐  ┌─────▼─────┐
              │  Telegram  │  │  OC Agent   │  │  OC Agent │
              │  (alerts)  │  │  (worker)   │  │  (main)   │
              └───────────┘  └─────────────┘  └───────────┘
```

## Directory Structure

```
vagus/
├── PLAN.md              # This file
├── vagus.conf           # All configuration (YAML or JSON)
├── vagus.pl             # Main entry point
├── lib/
│   ├── Vagus/Config.pm  # Config loader
│   ├── Vagus/State.pm   # State file management
│   ├── Vagus/Checks.pm  # Health check modules
│   ├── Vagus/Rules.pm   # Decision rules engine
│   ├── Vagus/Actions.pm # Wake agents, send alerts
│   └── Vagus/Log.pm     # Structured logging
├── state/               # Runtime state (gitignored, persists across reboots)
│   └── .gitkeep
├── t/                   # Tests
│   ├── 00-config.t
│   ├── 01-state.t
│   ├── 02-checks.t
│   └── 03-rules.t
└── .gitignore
```

## Configuration: vagus.conf

Single source of truth for all constants. No magic numbers in code.

```yaml
# --- Paths ---
state_dir: /home/oc/.vagus/state
log_file: /home/oc/.openclaw/logs/vagus.log

# --- Telegram ---
telegram:
  zeresh_bot_token: "8362453428:AAEPKBsYCMyj3BvnsbPZpuRlqs8r_J4gYqs"
  jay_chat_id: "6554979373"

# --- OpenClaw ---
openclaw:
  gateway_url: "http://127.0.0.1:18789"
  gateway_token: "43a9c99d6a1ced2eda39adc598dc4f9b747ebed17acdabe8"

# --- Agents (who to wake for what) ---
agents:
  main:        { name: "main",    model: "anthropic/claude-opus-4-6" }
  worker:      { name: "worker",  model: "openrouter/hunter-alpha" }
  triage_mail: { name: "triage",  model: "openrouter/hunter-alpha" }

# --- Thresholds ---
thresholds:
  mail_stale_hours: 4           # Wake Junior if no mail processed in N hours
  mail_stale_escalate_hours: 6  # Wake Zeresh if Junior didn't fix it
  no_mail_hours: 48             # Alert if no mail received at all in N hours
  usage_scrape_fail_max: 6      # Alert Jay if scraper fails N consecutive times
  usage_5hr_warn: 70            # Warn threshold for 5-hour usage %
  usage_weekly_warn: 80         # Warn threshold for weekly usage %
  batch_work_cooldown_min: 60   # Min minutes between batch work wakes

# --- Quiet Hours ---
quiet_hours:
  start: 23    # 23:00 local
  end: 8       # 08:00 local
  # During quiet hours: only critical alerts (cron errors, system down)
  # No batch work, no non-urgent wakes

# --- Working Hours ---
working_hours:
  start: 10
  end: 19
  # During working hours: conservative token use
  # Batch work only on cheap models, short tasks
```

## State Files

All state lives in `~/.vagus/state/`. JSON files, human-readable, greppable.

### state/health.json
```json
{
  "last_check": "2026-03-14T14:00:00+01:00",
  "cron_errors": [],
  "usage": {
    "5hr_pct": 18,
    "weekly_pct": 29,
    "last_scrape": "2026-03-14T13:50:00+01:00",
    "consecutive_scrape_failures": 0
  },
  "mail": {
    "last_unread_check": "2026-03-14T13:45:00+01:00",
    "unread_count": 0,
    "last_new_mail": "2026-03-14T10:23:00+01:00"
  }
}
```

### state/wakes.json
```json
{
  "last_wake": {
    "junior": { "ts": "2026-03-14T09:15:00+01:00", "reason": "mail_stale" },
    "zeresh": { "ts": "2026-03-14T08:00:00+01:00", "reason": "cron_error" },
    "worker": { "ts": "2026-03-14T03:00:00+01:00", "reason": "batch_work" }
  }
}
```

### state/escalations.jsonl
Append-only log. One line per action taken.
```jsonl
{"ts":"2026-03-14T14:00:00+01:00","check":"cron","result":"clean"}
{"ts":"2026-03-14T14:00:00+01:00","check":"mail","result":"stale","action":"wake_junior"}
{"ts":"2026-03-14T14:10:00+01:00","check":"mail","result":"still_stale","action":"wake_zeresh","note":"junior did not resolve"}
```

## Check Modules

Each check is a pure function: takes config + current state, returns a verdict.

### check_cron()
- Runs `crontab -l`, checks for syntax errors
- Runs each job's last log line looking for ERROR/FAIL
- Verdict: `{status: "ok"}` or `{status: "error", errors: [...]}`

### check_usage()
- Runs `scripts/check-usage.sh` (the existing scraper)
- Parses output, updates state/health.json
- Tracks consecutive failures
- Verdict: `{status: "ok", 5hr: N, weekly: N}` or `{status: "scrape_failed", consecutive: N}`

### check_mail()
- Reads state file from Junior/IMAP watcher (NOT running its own IMAP check)
- Looks at timestamps: last unread check, last new mail
- Verdict: `{status: "ok"}` or `{status: "stale", hours: N}`

## Rules Engine

Deterministic. No AI. A priority-ordered list of rules.
First matching rule fires. One action per run (prevents storm).

```
Rule 1: CRON ERROR (critical)
  IF cron_errors not empty
  AND not already woken zeresh for this error in last 2 hours
  THEN wake zeresh-main with "cron error: {details}. Fix it permanently."
  
Rule 2: CRON ERROR PERSISTS (escalate)
  IF cron_errors not empty
  AND already woken zeresh for this error > 2 hours ago
  AND error still present
  THEN telegram Jay: "Cron error persists after automated fix attempt: {details}"

Rule 3: USAGE SCRAPER BROKEN (alert)
  IF consecutive_scrape_failures >= threshold
  AND not alerted in last 6 hours
  THEN telegram Jay: "Usage scraper broken for {N} checks. Flying blind."

Rule 4: USAGE HIGH (warn)
  IF 5hr_pct >= warn_threshold OR weekly_pct >= warn_threshold
  AND not alerted in last 30 min (5hr) or 6 hours (weekly)
  THEN telegram Jay + update /tmp/usage-warning flag

Rule 5: MAIL STALE (escalate ladder)
  IF mail stale > threshold hours
  AND Junior not woken in last 2 hours
  THEN wake Junior: "Mail appears stale. Check IMAP watcher and triage."
  
  IF mail stale > escalate_threshold hours
  AND Junior was woken > 2 hours ago
  AND zeresh not woken for this in last 4 hours
  THEN wake zeresh: "Mail system appears broken. Junior couldn't fix it. Diagnose and tell Jay."

Rule 6: BATCH WORK (low priority, only when coast is clear)
  IF no rules above fired
  AND not quiet hours (unless explicitly allowed)
  AND usage healthy (5hr < 50% during working hours, or any% off-hours)
  AND last batch wake > cooldown
  THEN wake worker agent with next eligible task
  (For now: hardcoded list or tagged brain todos. AI selection deferred.)

Rule 0: ALL CLEAR
  IF no rules fired
  THEN log "all clear", update state, exit 0
```

## Actions

### wake_agent(agent, message)
Sends a message to an OC agent session via the gateway API.
```
POST http://127.0.0.1:18789/api/sessions/{agent}/messages
Authorization: Bearer {gateway_token}
{"message": "..."}
```
If gateway is down, falls back to Telegram alert.

### telegram_alert(chat_id, message)
Direct Telegram Bot API call. Zero OC tokens. Hardcoded bot token.
```
POST https://api.telegram.org/bot{token}/sendMessage
```

### log_action(event)
Appends to `state/escalations.jsonl` and writes to log file.

## Migration Plan

### Phase 1: Replace heartbeat gate (immediate)
1. Implement vagus.pl with checks + rules + state
2. Test with `--dry-run` flag (logs what it would do, does nothing)
3. Replace cron entry: `heartbeat-gate.sh` → `vagus.pl`
4. Keep existing heartbeat system as fallback (disable after 48hrs if stable)

### Phase 2: Tune thresholds (week 1)
- Observe escalation log, adjust thresholds
- Add/remove rules based on real patterns
- Add batch work support once todo system is improved

### Phase 3: Extend (later)
- Add Assaf/Shiri agent routing
- Add batch work todo selection (deterministic first, AI later)
- Add self-healing: if a check script is broken, try to fix it before alerting

## Testing

Perl has `Test::More` built in. Each module gets unit tests.

```bash
prove -l t/     # Run all tests
prove -l t/02-checks.t  # Run specific test
```

Tests use mock state files. No network calls in tests.

## Non-Goals (for now)

- AI-powered todo selection (deferred until todo system is fixed)
- Persistent AI session for Vagus itself (state files are enough)
- Complex multi-step reasoning (that's what the agents it wakes are for)
- Web dashboard (that's a separate project)

## Dependencies

Perl core only + JSON::PP (core since 5.14). No CPAN installs needed.
- `JSON::PP` — JSON parsing (core)
- `HTTP::Tiny` — HTTP requests (core)  
- `File::Path` — directory creation (core)
- `POSIX` — time functions (core)
- `Getopt::Long` — CLI args (core)

## Open Questions

1. **How does Vagus know about Assaf/Shiri agents?** Config file lists all agents.
   Gate scoring for them is a separate concern — Vagus routes, doesn't score.

2. **What about the existing heartbeat-gate.sh logic?** Vagus subsumes it entirely.
   The bash scripts for individual checks (check-usage.sh etc.) stay as-is;
   Vagus calls them and interprets output.

3. **How to handle OC gateway being down?** Vagus detects connection refused,
   falls back to Telegram for critical alerts, logs everything else for retry.

4. **State directory permissions?** `~/.vagus/state/` owned by `oc`, mode 700.
   State files are 600. Not world-readable (contains no secrets, but principle of least).
