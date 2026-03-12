# hikmalab — Client Agent Architecture

> Companion document to [ARCHITECTURE.md](ARCHITECTURE.md).
> This document covers the desired state, responsibilities, and open decisions for `hikmalab-agent` only.
> Security protocol details (signing keys, pinning) are deferred to a separate security document.

---

## Role

The agent is the enforcement arm of the system. It runs as root on the student's Ubuntu machine, applies rules received from the server, and reports activity back. It must work correctly even when the server is unreachable.

---

## Responsibilities

### 1. Web Blocking

- Local DNS resolver (dnsmasq) returns NXDOMAIN for blocked domains.
- nftables seals port 53 — all DNS traffic is forced through the local resolver.
- Known DNS-over-HTTPS server IPs are blocked at the firewall level.
- Common VPN ports (OpenVPN 1194, WireGuard 51820, L2TP 1723) are blocked via nftables.
- Known Tor directory IPs are blocked via nftables.
- VPN and proxy process names are detected via process scan and reported to the server.

**Time constraints on web rules:**
Each web rule can carry zero, one, or both of the following constraints:

| Constraint | Description | Example |
|---|---|---|
| `time_window` | Rule is only active within a clock range | `08:00–20:00` |
| `daily_limit` | Rule is suspended after N minutes of usage in a day | `120 min/day` |
| Both combined | Active only within window AND only until daily limit is reached | `2h within 08:00–20:00` |

With no constraint, the rule is always active.
Usage time is tracked per domain group or globally depending on rule configuration. **[OPEN]:** Whether daily limits are per-domain, per-category, or system-wide.

---

### 2. App Blocking

- Agent scans running processes every 60 seconds.
- Blacklisted process names or executable paths are killed immediately.
- A process that restarts is killed again on the next scan.

**Time constraints on app rules:** Same model as web rules — `time_window`, `daily_limit`, or both. The constraint model is shared between web and app rules to keep admin configuration uniform.

**[OPEN]:** Whether app blocking is purely by process name, by executable path, or both. Path is more tamper-resistant; name is easier to configure.

---

### 3. Activity Logging & Statistics

- DNS queries are logged: domain, timestamp, blocked/allowed, category if known.
- Process scans are logged: process name, executable path, timestamp, blocked/allowed.
- Logs are batched locally and sent to the server on each sync cycle — not in real-time.
- Visited domains are checked against the category database distributed by the server (social media, adult, gambling, gaming, piracy, etc.).
- Uncategorized domains visited frequently are surfaced to the admin for manual review.
- Usage time per app and per domain group is tracked locally for daily limit enforcement and for statistics reporting.

**[OPEN]:** How granular app usage time is tracked — by process name, by window focus, or by process-alive duration.

---

### 4. Rule Caching & Offline Enforcement

- On every successful sync, the agent writes the full rule set to a local cache file.
- Cache location: `/etc/hikmalab/rules.json` (root-only, permissions 600).
- On startup, the agent loads from cache immediately before attempting any network connection. Rules are enforced from the first second of boot.
- If the server is unreachable, the cached rules remain fully active. Loss of internet does not relax any restriction.
- Rules carry a version number. The agent only replaces the cache if the incoming version is newer.

---

### 5. Server Communication Protocol

**Decision: Single persistent WebSocket connection. Client opens it, server pushes when needed.**

The agent opens a WebSocket to the server on startup and keeps it alive. The server does not poll or dial agents — it writes to the open connection when it has something to send (rule update, command, alert). From the server's perspective this is an event-driven push model; no background thread per agent is needed.

```
Agent boots
  └─► opens WSS connection to server
        └─► server registers connection (no polling)
              └─► server pushes when needed (rules, commands)
              └─► agent pushes logs on schedule
```

**Reconnection:** exponential backoff on disconnect, max 5-minute interval. Rules remain enforced from local cache while disconnected.

**Log batching:**
- DNS and process events are written to a local log buffer file immediately as they occur.
- Every **1 hour** the agent attempts to flush the buffer to the server over the open WebSocket.
- If the WebSocket is down: the file is not cleared. It accumulates until the next successful flush.
- File is only cleared after the server acknowledges receipt.
- This means logs are never lost due to a temporary connection drop, and no separate HTTPS channel is needed.

**Heartbeat:** a lightweight ping is sent every 10 minutes over the WebSocket so the server can detect stale connections quickly without waiting for the 1-hour log cycle.

---

### 6. Password Management

#### 6a. Initial enrollment password rotation

1. Onboarding script generates a new random root password in memory.
2. Sends it to the server over HTTPS.
3. Server forwards it to the admin via Telegram and waits for delivery confirmation.
4. Only after confirmed delivery: agent applies the new root password locally.
5. If delivery fails at any step: abort. Old password unchanged. No partial state.

#### 6b. Force password reset from server

- Admin can trigger a password reset from the Telegram bot at any time (e.g., forgotten password, emergency).
- Server sends a signed `reset_password` command via WebSocket.
- Agent generates a new random password, sends it to server for Telegram delivery, waits for confirmation, then applies.
- Same delivery-before-change guarantee as enrollment.

**Decision: Admin must retry.** The server does not queue pending password reset commands. If the agent is offline when the reset is requested, the admin retries from the Telegram bot when the machine comes back online. This avoids a stale reset command executing unexpectedly much later.

---

### 7. Auto-Update (Zero Downtime)

**Decision: Managed by the Supervisor, not by the agent itself.**

See [DIE_WITH_OS.md](DIE_WITH_OS.md) for the full hot-swap design. Summary:

The **Supervisor** (a small, rarely-changing binary) is the only process that orchestrates updates. The agent does not update itself.

**Update flow:**
1. Supervisor polls server for a new version manifest.
2. Supervisor downloads new agent binary and verifies checksum + signature.
3. Supervisor starts the new binary alongside the old one (different health-check port).
4. Supervisor runs health check on the new binary (HTTP `/health`, server connectivity). Waits up to 60 seconds.
5. **If health check passes:** Supervisor sends SIGTERM to old agent. Old agent drains in-flight work and exits. New agent takes over. Supervisor updates the symlink.
6. **If health check fails:** New binary is killed. Old binary continues running. Supervisor reports failure to server. **No downtime, automatic rollback.**
7. Supervisor reports outcome to server.

**This also closes the binary integrity open question (L):** The Supervisor checks agent health on every start. If the agent binary is corrupted or tampered with, the health check fails and the Supervisor reports it and can re-download a clean copy.

**Supervisor self-update** uses a separate swap script that outlives the supervisor process — see [DIE_WITH_OS.md](DIE_WITH_OS.md) for details.

---

### 8. Remote Access for Hotfixes

For cases where a bug prevents normal agent communication, an out-of-band access channel is needed.

**Requirements:**
- Admin-initiated only — never open by default.
- Time-limited — access window closes automatically.
- Auditable — agent logs when access was opened, by whom, and for how long.
- Must not be exploitable by the student.

**Candidates:**

| Option | Notes |
|---|---|
| Temporary SSH key injection | Admin sends public key via signed WebSocket command. Agent adds it to root's `authorized_keys` with an expiry. Removed automatically after timeout. |
| Reverse SSH tunnel | Agent dials out to a relay server. No inbound port needed. More complex infrastructure. |
| WireGuard on-demand | Agent brings up a WireGuard interface only when commanded. Clean, auditable. Requires relay server. |

**[OPEN]:** Which option to use. Temporary SSH key injection is simplest for Phase 1 if the VPS can reach the machine. Reverse tunnel is better when the machine is behind a strict NAT.

**Safety constraints (regardless of option):**
- Access can only be opened via a signed server command — not by local action.
- Maximum session duration is enforced by the agent, not by the admin remembering to close it.
- Agent reports access-open and access-closed events to the server.

---

### 9. Remote Script / Command Execution

Admin can send signed commands to install software or run maintenance operations on the student machine.

**Decision: Whitelist-only. Arbitrary shell execution is never allowed.**

The agent maintains a registry of authorized command types. If a command type is not in the registry, the agent rejects it regardless of signature. To add a new capability, it is added to the agent's command registry in a new release — not sent as a shell string at runtime.

**Example authorized command types:**
```
install_package   <package_name>
remove_package    <package_name>
run_update        (apt update + upgrade)
restart_service   <service_name>
fetch_logs        (returns recent agent logs to server)
```

**Command Signing Protocol: HMAC**

All commands are authenticated using HMAC-SHA256. Both sides are verified:
- **Server → Agent:** Server signs the command payload with its signing key. Agent verifies HMAC before executing. Unsigned or invalid payloads are silently dropped.
- **Agent → Server:** Agent signs its responses (ack, result, log flush) with its machine key. Server verifies before accepting. This prevents a rogue machine from injecting fake results.
- Each payload includes a `nonce` (random) and `timestamp` to prevent replay attacks. Agent rejects payloads older than 60 seconds.

**Constraints:**
- Commands are logged locally and reported to the server (command type, parameters, timestamp, exit code).
- Output (stdout/stderr) is captured and sent back to the server for the admin to review.
- Scripts downloaded from a URL must be from the server's own domain and verified by checksum before execution.

**Future: AI Agent Integration**

The whitelist architecture is intentionally compatible with autonomous AI agents operating the machine. An AI agent running on the server side composes and signs commands from the same whitelist — the client agent does not distinguish between a human admin issuing a command or an AI agent issuing it. The trust boundary stays the same: signed by the server key = accepted; unsigned = rejected.

This enables future use cases:
- AI agent detects an installation error from logs and issues `install_package` / `run_update` to self-heal, without admin involvement.
- AI agent monitors the student's learning environment and installs missing dependencies automatically.

The agent on the machine remains stateless and dumb — it executes authorized commands and reports results. All intelligence stays on the server side. This design does not need to change when AI agents are introduced.

**Future: Personalized Learning AI Agent (Terminal / App)**

A separate component — distinct from the enforcement agent — will run on the student machine as an interactive learning assistant (terminal-first, then a GUI app). This component:
- Runs as the student user, not root.
- Has no ability to modify firewall rules, read agent config, or issue system commands.
- Communicates with the server's AI layer, not with the enforcement agent directly.
- Is installed and updated by the enforcement agent via `install_package` / `run_update` commands.

The enforcement agent and the learning assistant are separate processes with no shared IPC. The learning assistant cannot affect enforcement. This keeps the security model clean.

**[OPEN]:** How the learning AI agent authenticates to the server — whether it shares the machine's auth token (scoped to read-only/student operations) or gets its own separate credential.

---

### 10. Tamper Detection & Self-Recovery

- Agent config and cache files are owned by root, permissions 600. Student user cannot read or write them.
- If the agent process is killed, the **Supervisor** restarts it within 1-2 seconds (not systemd directly — the Supervisor is the systemd service, and the agent is its child process).
- The Supervisor performs a health check on agent startup. If the agent binary is corrupted or tampered with, the Supervisor reports it to the server and can re-download a clean binary automatically. This closes open decision L.
- nftables rules are re-applied on every agent startup. If the agent was killed and restarted, firewall rules are restored.
- dnsmasq config is re-written and dnsmasq reloaded on every rule sync.

---

### 11. System Clock Protection

Time-based rules depend on accurate system time. A student who changes the system clock can defeat time windows and daily limits.

- Agent enforces `timedatectl set-ntp true` and re-applies it if changed.
- Agent compares local time against server time on each heartbeat. If drift exceeds threshold, it alerts the admin and optionally pauses time-window rules conservatively (treats it as outside allowed window).
- **[OPEN]:** Whether to lock `timedatectl` changes via a polkit rule or nftables NTP redirect.

---

### 12. Startup Sequence

Order of operations on boot:

1. systemd starts the **Supervisor**.
2. Supervisor starts the **Agent** (via symlink `/opt/learning/agent/current`).
3. Agent loads cached rules from `/etc/hikmalab/rules.json`.
4. Agent applies nftables rules (web blocking, port sealing, VPN blocking).
5. Agent writes dnsmasq config and starts/reloads dnsmasq.
6. Agent starts process monitor loop.
7. Supervisor runs health check on agent (`/health` endpoint). If fail → restart.
8. Agent attempts WebSocket connection to server (exponential backoff if unreachable).
9. On first successful connection: sync rules, flush buffered logs.

Rules are enforced (steps 4–6) before the WebSocket connection is established — the student cannot access blocked content during the boot window.

---

### 13. Graceful Uninstall

**Decision: Admin sets a new root password before uninstall. Agent applies it, then uninstalls.**

This guarantees the admin can physically access the machine after the agent is gone. The machine is never left in a state where nobody knows the root password.

**Sequence:**
1. Admin initiates uninstall from the Telegram bot and provides a new root password.
2. Server sends a signed `uninstall` command via WebSocket containing the new password (encrypted for the machine).
3. Agent applies the new root password locally.
4. Agent sends confirmation to the server: "password changed, proceeding with uninstall."
5. Agent removes nftables rules, restores original DNS, removes dnsmasq config, stops and disables the systemd service, removes all files under `/etc/hikmalab/`, removes itself.
6. Agent sends a final `uninstall_complete` event to the server before exiting.

If step 3 fails (password change fails), the agent aborts and reports the error — uninstall does not proceed. Admin must investigate before retrying.

---

### 14. Supervisor

The Supervisor is a small, stable, rarely-changing binary that sits between systemd and the agent. See [DIE_WITH_OS.md](DIE_WITH_OS.md) for the full design.

**Responsibilities:**
- Start the agent as a child process on boot.
- Health-check the agent via a local HTTP `/health` endpoint.
- Poll the server for new version manifests.
- Orchestrate zero-downtime hot-swap updates (start new, verify, kill old, or rollback).
- Restart the agent if it crashes unexpectedly.
- Report agent health and update outcomes to the server.
- Never execute arbitrary commands — it only manages the agent lifecycle.

**Why separate from the agent:**
The agent changes frequently (new features, rule engine changes). The Supervisor almost never changes. By separating them, an agent update that crashes does not take down the recovery mechanism. The Supervisor survives and rolls back to the previous agent version automatically.

**systemd manages only the Supervisor.** The agent is the Supervisor's child — not a separate systemd service.

---

## Configuration File Layout

```
/etc/hikmalab/
  agent.conf        # Identity, auth token, server URL, signing pubkey pin  (root:root 600)
  rules.json        # Cached rule set from last successful sync              (root:root 600)
  usage.db          # Local daily usage counters (SQLite or flat file)       (root:root 600)

/opt/learning/
  supervisor/
    supervisor          # Supervisor binary — systemd service entry point    (root:root 755)
    supervisor-new      # Downloaded supervisor update (staging)             (root:root 600)
    supervisor-backup   # Previous supervisor (kept for emergency rollback)  (root:root 755)
    update.sh           # Swap script — launched by supervisor, outlives it  (root:root 700)

  agent/
    current -> agent-v3     # Symlink pointing to active agent binary
    agent-v3                # Active agent binary                            (root:root 755)
    agent-v4                # Downloaded candidate (health-checked, then promoted or deleted)
    logs.buf                # Buffered log file — flushed to server hourly   (root:root 600)
```

---

## What Was Listed vs. What Was Added

### From your list (covered above):
- Web blocking with time window + daily limit rules
- App blocking with same time constraints
- Activity statistics (web visits, app usage time)
- Security model (deferred to security document)
- Auto-update with zero downtime
- Password rotation on new enrollment with delivery confirmation
- Force password reset from server
- Remote hotfix access (SSH or tunnel — open decision)
- Remote command execution (whitelist-only; AI agent compatible; learning assistant as separate process)

### Added (not in your list):
- **Offline rule enforcement** — rules must survive internet loss
- **Startup sequence** — rules applied before network is up
- **System clock protection** — prevents time manipulation to bypass time windows
- **Tamper detection & self-recovery** — student kills the process, systemd restarts it; nftables re-applied on restart
- **WebSocket reconnection** — exponential backoff, not a hard failure
- **Rule versioning** — agent only replaces cache with newer versions
- **Log batching strategy** — not real-time, batched per sync cycle
- **Graceful uninstall** — admin-initiated, cleans up everything
- **Config file layout** — concrete paths and permissions
- **Domain categorization** — received from server, used for monitoring

---

## Open Decisions Log

| # | Decision | Status |
|---|----------|--------|
| A | Daily usage limit scope: per-domain, per-category, or system-wide | **OPEN** |
| B | App blocking: by process name, executable path, or both | **OPEN** |
| C | App usage time tracking granularity | **OPEN** |
| D | Heartbeat interval | 10-minute ping over WebSocket. **DECIDED** |
| E | Log batch interval | 1-hour flush to server. Buffer written to file. File not cleared until server ACKs. **DECIDED** |
| F | Offline force-reset: queue or require admin retry | Admin must retry. Server does not queue stale reset commands. **DECIDED** |
| G | Auto-update rollback mechanism | Supervisor health-checks new binary before cutover. Fails → kill new, keep old. Automatic rollback, no downtime. **DECIDED** |
| H | Remote hotfix access mechanism (SSH key injection vs reverse tunnel vs WireGuard) | **OPEN** |
| I | Remote command execution: whitelist vs arbitrary shell | Whitelist-only. Arbitrary shell never allowed. New capabilities added via agent releases. **DECIDED** |
| J | System clock locking mechanism | **OPEN** |
| K | Root password state after graceful uninstall | Admin provides new root password before uninstall. Agent applies it, then uninstalls. **DECIDED** |
| L | Agent binary integrity check on startup | Supervisor health-checks agent on every start. Corruption detected → re-download clean binary. **DECIDED** |
| M | Learning AI agent authentication to server (shared machine token vs separate credential) | **OPEN** |
| N | Command signing: HMAC-SHA256 both directions (server→agent and agent→server). Nonce + timestamp replay protection. | **DECIDED** |
