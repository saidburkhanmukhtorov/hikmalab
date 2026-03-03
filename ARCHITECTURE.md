# hikmalab — Architecture & Desired State

> This document captures the **desired state** of the system — what it must achieve and why.
> Implementation decisions (protocols, tools, specific algorithms) are made per phase, not here.
> When something is undecided, it is marked as **[OPEN]**.

---

## Vision

A centralized management system that allows a trusted authority (parent, teacher, mentor)
to control what a student can access on their Ubuntu machine — blocking distractions,
enforcing study schedules, and keeping the device focused on learning.

The system must work over the public internet, not require a local network,
and survive student attempts to bypass it.

---

## Core Principles

1. **Agent owns the machine.** The agent runs with root privileges. The student user has no way to stop, modify, or uninstall it without the admin's involvement.
2. **Rules are always enforced.** Whether online or offline, the last known rules must be active. Losing internet connection must not disable restrictions.
3. **Passwords never leave the device.** During onboarding, credentials are used locally to configure the machine. They are never transmitted to or stored on the server.
4. **Admin is the single source of truth.** All rule changes originate from the admin. Agents only receive, never decide.
5. **Transparency by contract.** Students and parents agree to this level of control. The system is not hidden — it is a known, agreed-upon tool.

---

## Actors

| Actor         | Description                                                         |
|---------------|---------------------------------------------------------------------|
| **Admin**     | Parent, teacher, or mentor. Sets rules, manages machines via CLI.   |
| **Student**   | Uses the managed machine. Has a limited OS user account, no sudo.   |
| **Agent**     | Software running on the student machine. Enforces rules as root.    |
| **Server**    | Central service. Stores rules and state. Relays between admin and agents. |

---

## System Components

### 1. Server (`hikmalab-server`)

**Desired state:**
- Admin creates an account and logs in securely. No plaintext passwords stored anywhere.
- Admin can register, view, and manage client machines.
- Admin can define rules: website blocklists, application blocklists, time schedules.
- Rules are stored reliably. If the server restarts, nothing is lost.
- Agents connect to the server and receive their assigned rules.
- Server knows which agents are online, offline, or have not synced recently.
- Server must be deployable on a single low-cost VPS.

**[OPEN]:** Database engine. Likely PostgreSQL, but not decided.
**[OPEN]:** How agents connect — polling vs persistent connection.
**[OPEN]:** Authentication mechanism for admin login.
**[OPEN]:** Authentication mechanism for agent-to-server identity.

---

### 2. Client Agent (`hikmalab-agent`)

**Desired state:**
- Runs as a system-level service with root privileges on Ubuntu.
- Starts automatically on boot. Cannot be stopped by the student user.
- If the agent process is killed by any means, it restarts immediately.
- Periodically syncs rules from the server when internet is available.
- Caches the latest rules locally. Enforces them even when offline.
- Enforces three types of restrictions:
  - **Web blocking:** Student cannot access blacklisted websites or domains.
  - **App blocking:** Student cannot open or run blacklisted applications.
  - **Time restrictions:** Internet or apps are unavailable outside allowed hours.
- Any attempt to bypass restrictions (changing DNS, using a proxy, VPN) should be detectable or preventable.
- Agent sends basic status back to server: last sync time, rule version active, online/offline.

**[OPEN]:** Web blocking mechanism — DNS, firewall rules, or proxy.
**[OPEN]:** How agent detects and blocks VPN/proxy bypass attempts.
**[OPEN]:** How the agent updates itself when a new version is released.

---

### 3. Admin CLI (`hikmalab-admin`)

**Desired state:**
- Admin installs this tool on their own machine (any OS, ideally).
- Admin logs in once, stays authenticated across sessions.
- Admin can list all enrolled machines and see their status.
- Admin can create, update, and delete rules.
- Admin can assign rules to specific machines or groups of machines.
- Admin can initiate a remote machine removal (triggers uninstall on agent side).
- Commands are simple, predictable, and scriptable.

**[OPEN]:** Target OS for admin CLI — Linux only or cross-platform.

---

### 4. Onboarding Script

**Desired state:**
- Admin shares a single command or script file with the student/parent.
- Running the script on the Ubuntu machine:
  1. Asks for the current sudo password.
  2. Immediately rotates the sudo password to something unknown to the student.
  3. Creates a new student user account with no administrative privileges.
  4. Installs the agent as a system service.
  5. Registers the machine with the admin's server account.
- The old sudo password is used locally only, never transmitted.
- The new sudo/root credentials are stored securely — accessible to the admin in emergencies, but not to the student.
- The script must be safe to run: verifiable, from a trusted source, with clear output at each step.
- Video instructions and written guides accompany the script.

**[OPEN]:** How emergency root access is stored and retrieved safely.
**[OPEN]:** Whether the script also handles agent updates during re-runs.

---

## Data Model (Desired State)

The following entities must exist. Schema is decided later.

- **Admin** — account, credentials, contact info
- **Organization** — optional grouping of machines under one admin (Phase 2+)
- **Machine** — enrolled client device, linked to admin, has status and last-seen time
- **Rule** — a restriction definition (web block, app block, time schedule)
- **RuleSet** — a named collection of rules assignable to machines
- **SyncLog** — record of when each machine last pulled its rules

---

## Phases

### Phase 1 — Core (MVP)

**Goal:** One admin can enroll Ubuntu machines, define rules, and have them enforced.

Must have:
- Admin account creation and login
- Machine enrollment via onboarding script
- Web blocking, app blocking, time restrictions
- Rule sync: online agents pull latest rules; cached rules enforced offline
- Admin CLI: login, list machines, manage rules
- Basic machine status visibility (online/offline, last sync)

### Phase 2 — Hardening & Usability

**Goal:** System is reliable and usable at small scale (up to ~30 machines).

- Agent tamper detection and self-recovery
- Admin alerts: machine offline too long, blocked attempt spikes
- Block attempt logs per machine
- Rule templates (presets for common scenarios)
- Graceful uninstall flow (admin-initiated only)
- Multiple machines per admin with group-level rules

### Phase 3 — Web Dashboard & Organizations

**Goal:** Non-technical users can manage machines without a CLI.

- Web dashboard replaces CLI for day-to-day management
- Multi-admin organizations (e.g., a school with multiple teachers)
- Per-group rule assignment
- Usage and block reports (weekly summaries, trends)

### Phase 4 — SaaS & Scale

**Goal:** Schools and education centers can sign up and manage themselves.

- Multi-tenant server
- Self-serve organization onboarding
- Subscription and billing
- AI-assisted learning CLI on the student machine
- Remote lesson video player on the student machine

---

## Security Posture (Desired State)

- No passwords, tokens, or secrets are stored in plaintext anywhere.
- The student cannot disable, modify, or read the agent's configuration.
- All communication between agent and server is encrypted in transit.
- Admin-to-server communication is authenticated and encrypted.
- The onboarding script must be verifiable (checksum or signature) before execution.
- Emergency root access to a machine must be possible for the admin, but must require explicit action — not automatic or passive.
- Server compromise must not give an attacker control over client machines beyond what is already possible through the rule system.

---

## Open Decisions Log

| # | Decision | Options Considered | Status |
|---|----------|--------------------|--------|
| 1 | Web blocking mechanism | DNS, iptables, transparent proxy | OPEN |
| 2 | Agent-server communication model | Polling, WebSocket, long-poll | OPEN |
| 3 | Agent authentication to server | Pre-shared token, mTLS, signed JWT | OPEN |
| 4 | Emergency root access storage | Encrypted vault, admin-held key, split key | OPEN |
| 5 | Agent self-update mechanism | Server-pushed binary, package manager, manual | OPEN |
| 6 | Admin CLI target platform | Linux only, cross-platform binary | OPEN |
| 7 | Database engine | PostgreSQL, SQLite, file-based | OPEN |
| 8 | VPN/proxy bypass prevention | Kill-switch rules, network monitoring | OPEN |
