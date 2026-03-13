## Layer 1 — systemd
```
# /etc/systemd/system/learning-supervisor.service
[Unit]
Description=Learning Device Supervisor
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/opt/learning/supervisor/supervisor
Restart=always
RestartSec=2
User=root

# This is critical — supervisor survives agent crashes
KillMode=process      # only kills the supervisor PID, not its children
                      # so agent keeps running during supervisor restart

[Install]
WantedBy=multi-user-target
```

`KillMode=process` is important — if systemd restarts the supervisor, the agent child process keeps running uninterrupted.

---

## Layer 2 — The Supervisor (small, stable Go/Rust/C binary)

This process does only a few things and almost never changes:
```
Supervisor responsibilities:
  - Start the agent as a child process
  - Health check agent via local HTTP /health endpoint
  - Poll server for new version manifest
  - Orchestrate the hot-swap (described below)
  - Restart agent if it dies unexpectedly
  - Never update itself (or very rarely, with extra caution)
```

Keep it **small and boring** — a few hundred lines. The less it does, the less it can break.

---

## The Hot-Swap Flow

This is your zero-downtime update sequence:
```
Server releases v2
       │
       ▼
Supervisor polls, sees new version manifest
       │
       ▼
Download v2 binary to /opt/learning/agent/agent-v2
Verify checksum + signature
       │
       ▼
Start v2 alongside v1 (different port, e.g. 9001 vs 9000)
       │
       ▼
Supervisor runs health check against v2:
  - HTTP /health returns 200?
  - Connected to server?
  - Core functions responding?
  Wait up to 60 seconds
       │
      ┌┴─────────────┐
   PASS             FAIL
      │               │
      ▼               ▼
Supervisor      Kill v2, keep v1
sends SIGTERM   Report failure to server
to v1           Supervisor can auto-downgrade
      │
      ▼
v1 finishes in-flight work (graceful drain)
      │
      ▼
v1 exits, v2 now sole agent
Supervisor updates symlink:
/opt/learning/agent/current -> agent-v2
      │
      ▼
Report success to server


## Updating the Supervisor Safely
The supervisor can update itself, but it can't replace its own running binary directly — the OS locks it. The pattern is:
```
/opt/learning/supervisor/
  supervisor          ← currently running (locked by OS)
  supervisor-new      ← downloaded, verified
  update.sh           ← does the actual swap
```

#### The swap script, launched by the supervisor as a child:
```bash
#!/bin/bash
# update.sh — runs as separate process, outlives supervisor

SUPERVISOR_PID=$1
NEW_BINARY=$2

# Wait for supervisor to exit
while kill -0 $SUPERVISOR_PID 2>/dev/null; do
  sleep 0.5
done

# Swap binaries
cp /opt/learning/supervisor/supervisor \
   /opt/learning/supervisor/supervisor-backup
mv /opt/learning/supervisor/supervisor-new \
   /opt/learning/supervisor/supervisor

# systemd restarts supervisor automatically
# agent kept running the whole time (KillMode=process)
echo "swap complete"
```

The flow:
```
Server signals: new supervisor version available
        │
        ▼
Supervisor downloads + verifies new binary → supervisor-new
        │
        ▼
Supervisor forks update.sh (now independent process)
        │
        ▼
Supervisor calls systemctl stop on itself → exits
        │
        ▼
update.sh detects exit → swaps binary
        │
        ▼
systemd restarts supervisor (new version)
Agent was running the entire time — zero downtime
```