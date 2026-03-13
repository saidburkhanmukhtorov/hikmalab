# Hikmalab Supervisor — Implementation Guide

The supervisor is a small, stable binary that manages the client agent lifecycle on
learning devices: starts it, health-checks it, hot-swaps new versions, and recovers
from crashes. It is intentionally boring — a few hundred lines, almost never changes.

> **Scope of this document:** v1 implementation only.
> Phase 2 (two-key hierarchy) and Phase 3 (HSM) are documented in [Future Versions](#future-versions).

---

## Table of Contents

1. [System Architecture](#1-system-architecture)
2. [Project Structure](#2-project-structure)
3. [Key Setup](#3-key-setup)
4. [CI/CD: Build, Sign & Publish](#4-cicd-build-sign--publish)
5. [Implementation](#5-implementation)
   - [verify.go — signature + checksum verification](#verifygo)
   - [update.go — supervisor update flow](#updatego)
   - [agent_update.go — agent hot-swap `[OPEN]`](#agent_updatego)
   - [update.sh — atomic binary swap](#updatesh)
   - [health.go — health check server `[OPEN]`](#healthgo)
   - [supervisor.conf — config format `[OPEN]`](#supervisorconf)
6. [Agent Hot-Swap Flow](#6-agent-hot-swap-flow)
7. [Supervisor Self-Update Flow](#7-supervisor-self-update-flow)
8. [Deployment](#8-deployment)
9. [Open Items](#9-open-items)
10. [Future Versions](#future-versions)

---

## 1. System Architecture

Two layers keep the agent alive and up to date.

### Layer 1 — systemd

systemd ensures the supervisor itself never stays dead. `Restart=always` brings it back
within 2 seconds of any crash. `KillMode=process` is the critical setting: when systemd
stops or restarts the supervisor, it kills only the supervisor PID — the agent child
process keeps running uninterrupted.

### Layer 2 — The Supervisor

```
Supervisor responsibilities:
  - Start the agent as a child process
  - Health-check the agent via local HTTP /health endpoint
  - Poll the update server for new version manifests (supervisor + agent)
  - Orchestrate agent hot-swap (zero downtime)
  - Orchestrate supervisor self-update (via update.sh)
  - Restart agent if it dies unexpectedly
  - Report update success/failure back to server
```

Keep it small and boring. The less it does, the less it can break.

---

## 2. Project Structure

```
supervisor/
  cmd/
    supervisor/
      main.go
  internal/
    updater/
      verify.go           ← signature + checksum verification (shared by supervisor and agent)
      update.go           ← supervisor manifest fetch, download, self-update orchestration
      agent_update.go     ← [OPEN] agent manifest fetch, download, hot-swap orchestration
    health/
      health.go           ← [OPEN] health check HTTP server
  build-public.pem        ← committed to repo (public key, safe to commit)
  go.mod
```

---

## 3. Key Setup

Run once on your build machine. Store the private key in your secrets manager immediately.

```bash
#!/bin/bash
# Generate RSA-4096 keypair — run once

# Private key — never commit, never share
openssl genrsa -out build-private.pem 4096

# Public key — committed to repo, baked into binary at compile time
openssl rsa -in build-private.pem -pubout -out build-public.pem

echo "Store build-private.pem in your secrets manager NOW"
echo "Commit build-public.pem to repo"
```

### Key Rotation (v1)

When the private key is compromised in v1, rotation is a race condition — the attacker
also holds the old key and can sign a malicious binary before you push the rotation.
This is the known v1 limitation. Mitigate by acting fast:

```bash
# 1. Generate new keypair immediately
openssl genrsa -out build-private-v2.pem 4096
openssl rsa -in build-private-v2.pem -pubout -out build-public-v2.pem

# 2. Replace public key in repo
cp build-public-v2.pem build-public.pem

# 3. Build and sign a new supervisor release with the new private key.
#    This binary has the new public key baked in.
VERSION="emergency-$(date +%Y%m%d)" ./sign-release.sh

# 4. Push to all devices as priority update.
#    Devices accept it because it is signed by the old private key.
#    Race window: between push and attacker. Act fast.
```

> Proper race-free rotation is solved in [Phase 2](#phase-2--two-key-hierarchy).

---

## 4. CI/CD: Build, Sign & Publish

`sign-release.sh` runs in CI. The private key is injected from the secrets manager
at build time — never stored in the repo or on build machines.

Both the supervisor and the agent use the same signing pattern with their own
separate bucket paths and manifest URLs.

```bash
#!/bin/bash
# sign-release.sh — runs in CI pipeline
# Usage: ./sign-release.sh <version> <target>
# target: "supervisor" or "agent"
set -e

VERSION=$1
TARGET=$2   # "supervisor" or "agent"
BINARY="${TARGET}-${VERSION}"
PRIVATE_KEY="build-private.pem"   # injected from secrets manager

# Build
echo "Building ${BINARY}..."
go build -o "${BINARY}" "./cmd/${TARGET}"

# Checksum
sha256sum "${BINARY}" > "${BINARY}.sha256"

# Sign
openssl dgst -sha256 \
  -sign "${PRIVATE_KEY}" \
  -out "${BINARY}.sig" \
  "${BINARY}"

echo "Signed: ${BINARY}.sig"

# Upload
aws s3 cp "${BINARY}"        "s3://your-updates-bucket/${TARGET}/"
aws s3 cp "${BINARY}.sig"    "s3://your-updates-bucket/${TARGET}/"
aws s3 cp "${BINARY}.sha256" "s3://your-updates-bucket/${TARGET}/"

# Publish manifest
cat > manifest.json <<EOF
{
  "version": "${VERSION}",
  "binary_url": "https://updates.yourapp.com/${TARGET}/${BINARY}",
  "sig_url":    "https://updates.yourapp.com/${TARGET}/${BINARY}.sig",
  "checksum_sha256": "$(cat ${BINARY}.sha256 | awk '{print $1}')",
  "released_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

aws s3 cp manifest.json "s3://your-updates-bucket/${TARGET}/manifest.json"

echo "Release ${VERSION} for ${TARGET} published"
```

---

## 5. Implementation

### verify.go

Shared by both supervisor and agent update paths. The public key is baked into the
binary at compile time via `//go:embed` — no file to misconfigure on the device.

Verification always does both checks in order:
1. SHA256 checksum against the manifest value
2. RSA signature against the embedded public key

```go
// internal/updater/verify.go

package updater

import (
    _ "embed"
    "crypto"
    "crypto/rsa"
    "crypto/sha256"
    "crypto/x509"
    "encoding/hex"
    "encoding/pem"
    "fmt"
    "os"
)

//go:embed ../../build-public.pem
var embeddedPublicKey []byte

func loadPublicKey() (*rsa.PublicKey, error) {
    block, _ := pem.Decode(embeddedPublicKey)
    if block == nil {
        return nil, fmt.Errorf("failed to decode embedded public key PEM")
    }
    pub, err := x509.ParsePKIXPublicKey(block.Bytes)
    if err != nil {
        return nil, fmt.Errorf("failed to parse public key: %w", err)
    }
    rsaKey, ok := pub.(*rsa.PublicKey)
    if !ok {
        return nil, fmt.Errorf("public key is not RSA")
    }
    return rsaKey, nil
}

// VerifyBinary checks the downloaded binary against its SHA256 checksum and RSA
// signature. Returns nil only if both pass.
// On failure: caller must delete the binary and abort the update.
func VerifyBinary(binaryPath, sigPath, expectedChecksum string) error {
    binaryData, err := os.ReadFile(binaryPath)
    if err != nil {
        return fmt.Errorf("failed to read binary %s: %w", binaryPath, err)
    }

    // 1. Checksum check first — fast, no crypto
    hash := sha256.Sum256(binaryData)
    actualChecksum := hex.EncodeToString(hash[:])
    if actualChecksum != expectedChecksum {
        return fmt.Errorf("checksum mismatch for %s: got %s, expected %s",
            binaryPath, actualChecksum, expectedChecksum)
    }

    // 2. Signature check
    rsaKey, err := loadPublicKey()
    if err != nil {
        return err
    }
    signature, err := os.ReadFile(sigPath)
    if err != nil {
        return fmt.Errorf("failed to read signature %s: %w", sigPath, err)
    }
    if err := rsa.VerifyPKCS1v15(rsaKey, crypto.SHA256, hash[:], signature); err != nil {
        return fmt.Errorf("SIGNATURE INVALID for %s: %w", binaryPath, err)
    }

    return nil
}
```

---

### update.go

Supervisor self-update path. Fetches the supervisor manifest, downloads the new
binary, verifies it, then delegates the swap to `update.sh` before exiting.

```go
// internal/updater/update.go

package updater

import (
    "encoding/json"
    "fmt"
    "io"
    "net/http"
    "os"
    "os/exec"
    "path/filepath"
)

type Manifest struct {
    Version        string `json:"version"`
    BinaryURL      string `json:"binary_url"`
    SigURL         string `json:"sig_url"`
    ChecksumSHA256 string `json:"checksum_sha256"`
}

const (
    supervisorDir = "/opt/learning/supervisor"
)

// CheckAndUpdate checks the supervisor manifest and performs a self-update if a
// new version is available. Does not return on success — calls os.Exit(0) to hand
// off to update.sh.
func CheckAndUpdate(currentVersion, manifestURL string) error {
    manifest, err := fetchManifest(manifestURL)
    if err != nil {
        return fmt.Errorf("failed to fetch manifest: %w", err)
    }
    if manifest.Version == currentVersion {
        return nil
    }

    newBinaryPath := filepath.Join(supervisorDir, "supervisor-"+manifest.Version)
    newSigPath := newBinaryPath + ".sig"

    if err := downloadFile(manifest.BinaryURL, newBinaryPath); err != nil {
        return err
    }
    if err := downloadFile(manifest.SigURL, newSigPath); err != nil {
        os.Remove(newBinaryPath)
        return err
    }

    if err := VerifyBinary(newBinaryPath, newSigPath, manifest.ChecksumSHA256); err != nil {
        os.Remove(newBinaryPath)
        os.Remove(newSigPath)
        reportFailure("supervisor_sig_verification_failed", err) // [OPEN] #2
        return err
    }

    os.Chmod(newBinaryPath, 0755)

    // Fork update.sh as an independent process, then exit.
    // update.sh detects our exit and swaps the binary.
    // systemd Restart=always brings the new binary up automatically.
    cmd := exec.Command("/bin/bash",
        filepath.Join(supervisorDir, "update.sh"),
        fmt.Sprintf("%d", os.Getpid()),
        newBinaryPath,
    )
    cmd.Start() // fire and forget — do not Wait()
    os.Exit(0)

    return nil
}

func fetchManifest(url string) (*Manifest, error) {
    resp, err := http.Get(url)
    if err != nil {
        return nil, err
    }
    defer resp.Body.Close()

    var m Manifest
    if err := json.NewDecoder(resp.Body).Decode(&m); err != nil {
        return nil, err
    }
    return &m, nil
}

func downloadFile(url, dest string) error {
    resp, err := http.Get(url)
    if err != nil {
        return fmt.Errorf("download failed for %s: %w", url, err)
    }
    defer resp.Body.Close()

    f, err := os.Create(dest)
    if err != nil {
        return err
    }
    defer f.Close()

    _, err = io.Copy(f, resp.Body)
    return err
}
```

---

### agent_update.go

`[OPEN]` — needs implementation. See [Open Items #1](#9-open-items).

Contract:

```go
// internal/updater/agent_update.go

package updater

const (
    agentDir = "/opt/learning/agent"
)

// CheckAndUpdateAgent checks the agent manifest and performs a hot-swap if a new
// version is available. Unlike CheckAndUpdate, this does NOT exit the supervisor —
// it runs v1 and v2 side by side, validates v2 health, then gracefully shuts down v1.
func CheckAndUpdateAgent(currentVersion, manifestURL string) error {
    // [OPEN] implement:
    //   1. fetchManifest(manifestURL)
    //   2. download new agent binary + sig to agentDir
    //   3. VerifyBinary(newBinaryPath, newSigPath, manifest.ChecksumSHA256)
    //   4. start v2 on alternate port (config: agent_next_port)
    //   5. poll GET http://localhost:{agent_next_port}/health — up to 60s
    //   6a. PASS: SIGTERM v1, wait for drain, update symlink current -> v2, report success
    //   6b. FAIL: kill v2, delete binary, reportFailure, keep v1
    return nil
}
```

---

### update.sh

Runs as an independent process that outlives the supervisor. The OS unlocks the binary
file once the supervisor process exits, so `mv` succeeds.

```bash
#!/bin/bash
# /opt/learning/supervisor/update.sh
# Launched by supervisor before it exits. Swaps binary, systemd restarts supervisor.

set -e

SUPERVISOR_PID=$1
NEW_BINARY=$2
SUPERVISOR_BIN="/opt/learning/supervisor/supervisor"
BACKUP_BIN="/opt/learning/supervisor/supervisor-backup"

echo "[update.sh] waiting for supervisor PID ${SUPERVISOR_PID} to exit..."
while kill -0 "$SUPERVISOR_PID" 2>/dev/null; do
  sleep 0.5
done

echo "[update.sh] supervisor exited, swapping binary..."

# Keep previous version for emergency rollback
cp "$SUPERVISOR_BIN" "$BACKUP_BIN"

# Atomic swap
mv "$NEW_BINARY" "$SUPERVISOR_BIN"

echo "[update.sh] swap complete — systemd will restart supervisor automatically"
# Agent process was running the entire time (KillMode=process)
```

---

### health.go

`[OPEN]` — needs implementation. See [Open Items #3](#9-open-items).

Contract:

```
Endpoint:  GET http://localhost:{port}/health
Success:   200 OK
           { "status": "ok", "version": "1.2.3", "uptime_seconds": 42 }
Failure:   any non-200, connection refused, or timeout = unhealthy

Used by:
  - Supervisor to validate agent v2 during hot-swap (polls up to 60s)
  - Supervisor exposes its own /health for external monitoring
```

---

### supervisor.conf

`[OPEN]` — format needs to be defined. See [Open Items #4](#9-open-items).

Minimum required fields:

```
supervisor_manifest_url   string   URL to poll for supervisor updates
agent_manifest_url        string   URL to poll for agent updates
poll_interval_seconds     int      how often to check both manifests
agent_port                int      port agent v1 listens on (default: 9000)
agent_next_port           int      port agent v2 uses during hot-swap (default: 9001)
health_check_timeout_sec  int      max wait for v2 /health during hot-swap (default: 60)
log_level                 string   debug | info | warn | error
```

---

## 6. Agent Hot-Swap Flow

Zero-downtime update. Both versions run side by side during the health check window.

```
Supervisor polls agent manifest, sees new version
       │
       ▼
Download agent-vN binary + .sig to /opt/learning/agent/
Verify checksum + signature (VerifyBinary)
       │
  FAIL ┤ → delete binary, reportFailure, keep current agent running
       │
       ▼
Start agent-vN on agent_next_port (e.g. 9001)
       │
       ▼
Poll GET http://localhost:9001/health every 2s — up to 60s
       │
      ┌┴────────────────┐
   PASS                FAIL
      │                  │
      ▼                  ▼
Send SIGTERM          Kill agent-vN process
to current agent      Delete agent-vN binary
      │               reportFailure to server
      ▼               Keep current agent running
Current agent drains
in-flight work
      │
      ▼
Current agent exits cleanly
Supervisor atomically updates symlink:
  /opt/learning/agent/current -> agent-vN
      │
      ▼
Report success to server
```

---

## 7. Supervisor Self-Update Flow

The OS locks a running binary, so the supervisor cannot replace itself directly.
It delegates the swap to `update.sh` (an independent process) and exits.

```
Supervisor polls supervisor manifest, sees new version
        │
        ▼
Download supervisor-vN + .sig
Verify checksum + signature (VerifyBinary)
        │
   FAIL ┤ → delete binary, reportFailure, continue running
        │
        ▼
Fork update.sh as independent process (cmd.Start, no Wait)
        │
        ▼
Supervisor calls os.Exit(0)
        │
        ▼
update.sh detects exit
  → cp supervisor supervisor-backup
  → mv supervisor-vN supervisor
        │
        ▼
systemd Restart=always → starts new supervisor binary
Agent was running the entire time (KillMode=process)
```

---

## 8. Deployment

### systemd Unit

```ini
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

# Critical: only kills supervisor PID, not its children.
# Agent keeps running during supervisor restart or self-update.
KillMode=process

[Install]
WantedBy=multi-user.target
```

### File Layout

```
/opt/learning/
  supervisor/
    supervisor              ← running binary
    supervisor-backup       ← previous version, kept for emergency rollback
    update.sh               ← swap script (must be present before first run)
    supervisor.conf         ← [OPEN] config file
  agent/
    current -> agent-1.4.2  ← symlink, atomically updated by supervisor
    agent-1.4.2             ← running version
    agent-1.4.1             ← previous version, kept for rollback
  state/
    agent.state             ← persisted agent state, survives restarts
```

### Install

```bash
sudo systemctl daemon-reload
sudo systemctl enable learning-supervisor
sudo systemctl start learning-supervisor

# Verify
sudo systemctl status learning-supervisor
```

---

## 9. Open Items

Unresolved v1 gaps. Solve one at a time — each is self-contained.

| # | Item | File | What's needed |
|---|---|---|---|
| 1 | Agent update implementation | `internal/updater/agent_update.go` | `CheckAndUpdateAgent()` — manifest fetch, download, verify, start v2 on next port, health-check loop, SIGTERM v1 or rollback v2, update symlink |
| 2 | `reportFailure` definition | `internal/updater/update.go` | Decide: HTTP POST to server, local log, or both. Define function signature and error contract |
| 3 | `health.go` implementation | `internal/health/health.go` | HTTP server on configurable port, `GET /health → 200 + JSON`. Must be embedded in both supervisor and agent |
| 4 | `supervisor.conf` format | `/opt/learning/supervisor/supervisor.conf` | Define schema and parsing. Recommend TOML or JSON. Fields listed in §5 above |
| 5 | Key rotation runbook | ops documentation | Step-by-step for compromised key in v1 race-condition scenario. Who does what, in what order, how fast |

---

## Future Versions

Features below are intentionally deferred. Do not implement until v1 is stable and
deployed.

---

### Phase 2 — Two-Key Hierarchy

**Solves:** key rotation race condition in v1.

Introduces root key (offline) + intermediate key (CI/CD). If the intermediate key leaks,
the root key rotates it with no race — the attacker cannot sign a valid chain without
the root key.

**Key hierarchy:**
```
Root Key (RSA-4096 / Ed25519)
  Private: offline cold storage / HSM — used 1-2x per year
  Public:  hardcoded in supervisor binary at compile time

  Root signs Intermediate Certificate (X.509)

Intermediate Key (RSA-4096)
  Private: AWS Secrets Manager / Vault — CI/CD only
  Public:  distributed as signed X.509 cert

  Intermediate signs each release binary
```

**Verification chain:**
```
Supervisor receives: binary + binary.sig + intermediate.crt

  1. Verify intermediate.crt signed by hardcoded root public key
  2. Check intermediate.crt not expired
  3. Extract intermediate public key from cert
  4. Verify binary.sig with that key
  5. Accept or reject
```

**Key rotation (no race):**
```
Intermediate key compromised
  → Take root key out of cold storage
  → Generate new intermediate keypair
  → Sign new intermediate cert with root key
     (attacker has no root key — cannot do this)
  → Ship supervisor release with new intermediate cert baked in
  → Old intermediate cert expires → attacker signatures invalid
```

**Storage:**

| Key | Storage | Access |
|---|---|---|
| Root private | HSM or encrypted offline USB | Manual, 1-2x/year |
| Intermediate private | AWS Secrets Manager / Vault | CI/CD only |
| Intermediate cert | S3 update bucket | Read by all devices |
| Root public | Compiled into binary | Read-only |

Algorithm upgrade: RSA-PSS with SHA-256 (upgrade from v1 PKCS1v15), or move to Ed25519.

---

### Phase 3 — HSM + Full SaaS

**Solves:** root key still on USB/cold storage in Phase 2. Phase 3 moves root key into
an HSM — key is generated inside hardware and can never be exported.

**Certificate chain:**
```
Root CA (HSM)
  ├── Platform Intermediate CA  → supervisor + platform agent updates
  └── Per-Organization CA       → org-specific policy bundles, org-scoped configs
```

**HSM options:**

| Option | Use case | Examples |
|---|---|---|
| Cloud HSM | SaaS, always online | AWS CloudHSM, Google Cloud HSM |
| HSM as a Service | Simpler, managed | AWS KMS with custom key store |
| Physical HSM | Air-gapped root CA | Thales Luna, YubiHSM |

Recommendation: AWS KMS for intermediate keys, YubiHSM for root CA.

**Other additions in Phase 3:**
- Algorithm: Ed25519 for binary signatures, ECDSA P-256 for X.509 certs
- Full audit trail for every signing operation (CloudTrail or append-only log)
- Automated certificate lifecycle (90-day intermediate rotation via CI/CD)
- Multi-region update server resilience (CDN + GeoDNS)
- Canary rollout control in manifest:
  ```json
  { "rollout": { "strategy": "canary", "canary_percentage": 5,
    "stable_after_hours": 24, "block_on_failure_rate": 0.02 } }
  ```

---

### Phase Comparison

| Capability | v1 (Phase 1) | Phase 2 | Phase 3 |
|---|---|---|---|
| Binary authenticity | yes | yes | yes |
| Key rotation without race | no | yes | yes |
| Per-org key isolation | no | optional | yes |
| HSM-backed root key | no | no | yes |
| Automated cert lifecycle | no | manual | yes |
| Audit trail | no | basic | full |
| Rollout control | no | no | canary + auto-halt |
| Appropriate for | MVP / v1 | Growing SaaS | Enterprise SaaS |
