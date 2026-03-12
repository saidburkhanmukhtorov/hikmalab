# hikmalab — Architecture & Desired State

> This document captures the **desired state** of the system — what it must achieve and why.
> Decided implementation choices are recorded inline and in the Open Decisions Log.
> Remaining unknowns are marked **[OPEN]**.
>
> **Component documents:**
> - [CLIENT_ARCHITECTURE.md](CLIENT_ARCHITECTURE.md) — detailed agent design, enforcement logic, protocol, and open decisions
> - [DIE_WITH_OS.md](DIE_WITH_OS.md) — Supervisor design: zero-downtime hot-swap, self-update, and agent watchdog

---

## Vision

A personal tool for a trusted authority (parent, teacher, mentor) to control
what a student can access on their Ubuntu machine — blocking distractions,
enforcing study schedules, and keeping the device focused on learning.

Built for personal use: family, friends, and close students.
The system must work over the public internet, not require a local network,
and survive student attempts to bypass it.

---

## Core Principles

1. **Agent owns the machine.** The agent runs with root privileges. The student user has no way to stop, modify, or uninstall it without the admin's involvement.
2. **Rules are always enforced.** Whether online or offline, the last known rules must be active. Losing internet connection must not disable restrictions.
3. **Old credentials never leave the device.** The existing sudo password is used locally only, never transmitted. The new root password is sent to the admin via Telegram (over HTTPS) before the change is applied — the admin is the sole holder of emergency root access.
4. **Admin is the single source of truth.** All rule changes originate from the admin. Agents only receive, never decide.
5. **Transparency by contract.** Students and parents agree to this level of control. The system is not hidden — it is a known, agreed-upon tool.

---

## Actors

| Actor            | Description                                                               |
|------------------|---------------------------------------------------------------------------|
| **Admin**        | Parent, teacher, or mentor. Sets rules, manages machines via Telegram.    |
| **Student**      | Uses the managed machine. Has a limited OS user account, no sudo.         |
| **Agent**        | Software running on the student machine. Enforces rules as root.          |
| **Server**       | Central service. Stores rules and state. Relays between admin and agents. |
| **Telegram Bot** | The admin's interface. Receives commands, shows status, sends alerts.     |

---

## System Components

### 1. Server (`hikmalab-server`)

**Desired state:**
- Admin is registered by their Telegram user ID — no separate account or password needed.
- Admin can register, view, and manage client machines.
- Admin can define rules: website blocklists, application blocklists, time schedules.
- Rules are stored reliably in PostgreSQL. If the server restarts, nothing is lost.
- Agents connect to the server via WebSocket and receive commands when pushed.
- Server knows which agents are online, offline, or have not synced recently.
- Server receives batched activity logs (DNS visits, app usage) from agents and stores them.
- Server fetches and distributes domain category lists (Hagezi, OISD) to agents — agents never hit external URLs directly.
- Server must be deployable on a single low-cost VPS.
- Telegram bot runs embedded in the same server process.

**[OPEN]:** How admin Telegram ID is first registered with the server (bot conversation flow vs config).

---

### 2. Client Agent (`hikmalab-agent`)

**Desired state:**
- Runs as a systemd service with root privileges on Ubuntu.
- Starts automatically on boot. Cannot be stopped by the student user.
- A **Supervisor** process sits between systemd and the agent. systemd manages the Supervisor; the Supervisor manages the agent as its child. If the agent is killed, the Supervisor restarts it within 1–2 seconds.
- Caches the latest rules locally. Enforces them even when offline.
- Enforces three types of restrictions:
  - **Web blocking:** Local DNS resolver (dnsmasq) returns nothing for blocked domains. nftables seals DNS port 53 to prevent custom DNS servers. Known DoH server IPs are blocked at the firewall.
  - **App blocking:** Student cannot open or run blacklisted applications.
  - **Time restrictions:** Internet or apps are unavailable outside allowed hours.
- nftables blocks common VPN ports (OpenVPN 1194, WireGuard 51820, L2TP 1723) and known Tor directory IPs.
- Agent detects VPN and proxy process names via app logs and reports them to the server.
- Agent receives rule updates and commands via a **persistent WebSocket connection** to the server. The agent always opens this connection — the server never dials out to agents. The server pushes when it has something to send.
- Heartbeat: a lightweight ping every 10 minutes so the server can detect stale connections.
- DNS queries and app usage events are written to a local log buffer file immediately. The buffer is flushed to the server every **1 hour** over the WebSocket. The file is not cleared until the server acknowledges receipt — logs survive connection drops.
- Agent scans running processes every 60 seconds and logs app usage (process name, executable path, timestamp, blocked/allowed).
- Visited domains are checked against the category database distributed by the server (social media, adult, gambling, gaming, piracy, etc.). This is for monitoring — the admin reviews and decides what to block per child.
- Uncategorized domains visited frequently are surfaced to the admin for manual review.

**Agent identity and authentication:**
- Each machine is identified by its `/etc/machine-id` — a stable, unique Linux-generated identifier.
- During enrollment, the server issues a secret auth token tied to that machine ID.
- The token is stored in `/etc/hikmalab/agent.conf` (owner: root, permissions: 600). The student user cannot read it.
- On every request to the server, the agent presents both: machine ID (identity) and auth token (proof).
- If a machine is decommissioned or compromised, the admin revokes the token. The server rejects all further requests from that machine ID.

**Agent self-update (via Supervisor):**
- The Supervisor polls the server for new version manifests.
- Downloads and verifies the new agent binary, starts it alongside the old one, runs a health check.
- If health check passes: gracefully terminates the old agent, new agent takes over. Zero downtime.
- If health check fails: kills the new binary, old agent keeps running. Automatic rollback.
- See [DIE_WITH_OS.md](DIE_WITH_OS.md) for the full hot-swap design.

---

### 3. Telegram Bot (`hikmalab-bot`)

**Desired state:**
- Runs embedded in the server process.
- Admin interacts with the system entirely through this private bot.
- No software to install — works from any device with Telegram.
- Admin is identified by their Telegram user ID. Bot ignores all messages from any other ID.
- Admin can list all enrolled machines and see their status.
- Admin can create, update, and delete rules.
- Admin can assign rules to specific machines or groups of machines.
- Admin can initiate a remote machine removal (triggers uninstall on agent side).
- Admin can generate enrollment tokens for onboarding new machines.
- Bot sends proactive alerts: machine offline too long, blocked attempt spikes, flagged category visits.
- Bot sends daily or weekly activity summaries per machine: sites visited, apps used, flagged content.
- Admin can block a domain directly from the bot when reviewing an activity report.
- Commands are simple text or inline keyboard buttons — no technical knowledge required.

---

### 4. Onboarding Script

**Desired state:**
- Admin generates an enrollment token from the Telegram bot.
- Admin shares a single install command with the student/parent. The token is embedded in the command.
- The token ties the enrollment to the admin's account on the server.
- Running the command on the Ubuntu machine:
  1. Downloads the onboarding script from the server (authenticated by the enrollment token).
  2. Asks for the current sudo password — used locally to gain root, never transmitted.
  3. Reads `/etc/machine-id` and requests a machine auth token from the server.
  4. Generates a new random root password in memory.
  5. Sends the new password to the server, which forwards it to the admin via Telegram.
  6. Waits for confirmed delivery. Only if confirmed: rotates the sudo/root password.
  7. If delivery fails: aborts. The old password is unchanged. Nothing is left in an unknown state.
  8. Creates a new student user account with no administrative privileges.
  9. Writes machine auth token to `/etc/hikmalab/agent.conf` (root-only, permissions 600).
  10. Installs the agent as a systemd service running as root.
- The old sudo password is used locally only, never transmitted.
- The script must be verifiable (checksum published separately) with clear output at each step.
- Video instructions and written guides accompany the script.

**[OPEN]:** Whether the script also handles agent updates during re-runs.

---

## Data Model (Desired State)

The following entities must exist. Schema is decided later.

- **Admin** — Telegram user ID, contact info
- **Machine** — enrolled device, linked to admin, has auth token, status, and last-seen time
- **Rule** — a restriction definition (web block, app block, time schedule)
- **RuleSet** — a named collection of rules assignable to machines
- **SyncLog** — record of when each machine last pulled its rules
- **VisitLog** — domain, timestamp, machine, blocked (yes/no), category if known
- **AppLog** — process name, executable path, timestamp, machine, blocked (yes/no)

---

## Phases

### Phase 1 — Core (MVP)

**Goal:** One admin can enroll Ubuntu machines, define rules, and have them enforced.

- Admin identity via Telegram ID
- Machine enrollment via onboarding script
- Web blocking (dnsmasq + nftables), app blocking, time restrictions
- Rule updates delivered via WebSocket push; cached rules enforced offline
- Telegram bot: list machines, manage rules, assign rules, generate enrollment tokens
- Basic machine status visibility (online/offline, last sync)
- Activity logging: DNS visit logs and app usage logs batched to server

### Phase 2 — Hardening & Usability

**Goal:** System is reliable and usable at small scale (up to ~30 machines).

- Agent tamper detection and self-recovery
- Domain category monitoring with bot alerts for flagged content (social media, adult, etc.)
- Bot alerts: machine offline too long, blocked attempt spikes, VPN/proxy detected
- Rule templates (presets for common scenarios, selectable in bot)
- Graceful uninstall flow (admin-initiated via bot)
- Group-level rule assignment across multiple machines
- Agent self-update mechanism

### Future — Foundation for Education Projects

This system is intentionally personal-scale. It is the foundation for future education-focused projects. Scaling decisions (multi-tenant, organizations, billing) are deferred until there is a concrete reason to build them.

---

## Security Posture (Desired State)

- No passwords, tokens, or secrets are stored in plaintext anywhere.
- The student cannot disable, modify, or read the agent's configuration.
- All communication between agent and server is encrypted in transit (HTTPS/WSS).
- Admin-to-server communication is authenticated via Telegram identity.
- The onboarding script must be verifiable (checksum or signature) before execution.
- The admin holds the root password for every managed machine. Emergency access requires explicit admin action — not automatic or passive.
- Server compromise must not give an attacker control over client machines beyond what is already possible through the rule system.

---

## Open Decisions Log

| # | Decision | Resolution | Status |
|---|----------|------------|--------|
| 1 | Web blocking mechanism | Local DNS resolver (dnsmasq) + nftables to seal DNS port 53 and block known DoH IPs. Transparent proxy rejected — too complex, breaks apps. | **DECIDED** |
| 2 | Agent-server communication | Single persistent WebSocket. Agent opens it; server pushes when needed (rules, commands). Logs batched to file, flushed hourly over WebSocket. 10-min heartbeat ping. File kept until server ACKs. | **DECIDED** |
| 3 | Agent authentication | `/etc/machine-id` as identity + server-issued secret token stored in root-only `/etc/hikmalab/agent.conf`. | **DECIDED** |
| 4 | Emergency root access | New root password sent to admin via Telegram before being applied. Admin holds it. | **DECIDED** |
| 5 | Agent self-update | Managed by Supervisor. Downloads new binary, starts alongside old, health-checks. Pass → graceful cutover. Fail → automatic rollback, old agent untouched. See DIE_WITH_OS.md. | **DECIDED** |
| 6 | Bot hosting | Embedded in the server process. | **DECIDED** |
| 7 | Database engine | PostgreSQL. | **DECIDED** |
| 8 | VPN/proxy bypass prevention | nftables blocks common VPN ports and Tor IPs. DNS sealed at kernel level. VPN process names detected via app logs. | **DECIDED** |
| 9 | Auth token revocation | Server rejects all requests from a revoked machine ID immediately. | **DECIDED** |
| 10 | Admin Telegram ID registration | How admin first registers their Telegram ID with the server. | **OPEN** |
| 11 | Onboarding script re-runs | Whether re-running the script on an already-enrolled machine updates the agent or re-enrolls. | **OPEN** |
