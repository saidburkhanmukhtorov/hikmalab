# Supervisor Binary Signature Verification — All Phases

---

## Phase 1 — Single Hardcoded Key (Release & Test)

Full implementation, production ready for early stage.

### Project Structure

```
supervisor/
  cmd/
    supervisor/
      main.go
  internal/
    updater/
      verify.go
      update.go
    health/
      health.go
  build-public.pem      ← committed to repo (public, safe)
  go.mod
```

---

### Step 1 — Generate Keys

```bash
#!/bin/bash
# run once on your build machine, store private key in secrets manager

# Private key — never commit, never share
openssl genrsa -out build-private.pem 4096

# Public key — committed to repo, baked into binary
openssl rsa -in build-private.pem -pubout -out build-public.pem

echo "Store build-private.pem in your secrets manager NOW"
echo "Commit build-public.pem to repo"
```

---

### Step 2 — Sign Script (CI/CD)

```bash
#!/bin/bash
# sign-release.sh — runs in your CI pipeline
# build-private.pem is injected from secrets manager at build time

set -e

VERSION=$1
BINARY="supervisor-${VERSION}"
PRIVATE_KEY="build-private.pem"

# Build the binary
echo "Building ${BINARY}..."
go build -o "${BINARY}" ./cmd/supervisor

# Compute checksum
sha256sum "${BINARY}" > "${BINARY}.sha256"

# Sign the binary
openssl dgst -sha256 \
  -sign "${PRIVATE_KEY}" \
  -out "${BINARY}.sig" \
  "${BINARY}"

echo "Signed: ${BINARY}.sig"

# Upload binary + signature + checksum to update server
aws s3 cp "${BINARY}"        s3://your-updates-bucket/supervisor/
aws s3 cp "${BINARY}.sig"    s3://your-updates-bucket/supervisor/
aws s3 cp "${BINARY}.sha256" s3://your-updates-bucket/supervisor/

# Publish version manifest
cat > manifest.json <<EOF
{
  "version": "${VERSION}",
  "binary_url": "https://updates.yourapp.com/supervisor/supervisor-${VERSION}",
  "sig_url":    "https://updates.yourapp.com/supervisor/supervisor-${VERSION}.sig",
  "checksum_sha256": "$(cat ${BINARY}.sha256 | awk '{print $1}')",
  "released_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

aws s3 cp manifest.json s3://your-updates-bucket/supervisor/manifest.json

echo "Release ${VERSION} published"
```

---

### Step 3 — Embed Public Key at Compile Time

```go
// internal/updater/verify.go

package updater

import (
    _ "embed"
    "crypto"
    "crypto/rsa"
    "crypto/sha256"
    "crypto/x509"
    "encoding/pem"
    "fmt"
    "os"
)

// Public key baked into binary at compile time.
// No file to misconfigure on the device.
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
```

---

### Step 4 — Verify Downloaded Binary

```go
// internal/updater/verify.go (continued)

// VerifyBinary checks the downloaded binary against its signature.
// Returns nil only if signature is valid.
// On any failure: caller must delete the binary and abort.
func VerifyBinary(binaryPath, sigPath string) error {
    rsaKey, err := loadPublicKey()
    if err != nil {
        return err
    }

    // Hash the downloaded binary
    binaryData, err := os.ReadFile(binaryPath)
    if err != nil {
        return fmt.Errorf("failed to read binary %s: %w", binaryPath, err)
    }
    hash := sha256.Sum256(binaryData)

    // Read the signature file
    signature, err := os.ReadFile(sigPath)
    if err != nil {
        return fmt.Errorf("failed to read signature %s: %w", sigPath, err)
    }

    // Verify — this is the critical check
    err = rsa.VerifyPKCS1v15(rsaKey, crypto.SHA256, hash[:], signature)
    if err != nil {
        return fmt.Errorf("SIGNATURE INVALID for %s: %w", binaryPath, err)
    }

    return nil
}
```

---

### Step 5 — Update Flow in Supervisor

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
    Version         string `json:"version"`
    BinaryURL       string `json:"binary_url"`
    SigURL          string `json:"sig_url"`
    ChecksumSHA256  string `json:"checksum_sha256"`
}

const (
    supervisorDir = "/opt/learning/supervisor"
    manifestURL   = "https://updates.yourapp.com/supervisor/manifest.json"
)

func CheckAndUpdate(currentVersion string) error {
    // 1. Fetch manifest
    manifest, err := fetchManifest()
    if err != nil {
        return fmt.Errorf("failed to fetch manifest: %w", err)
    }

    if manifest.Version == currentVersion {
        return nil // already up to date
    }

    newBinaryPath := filepath.Join(supervisorDir, "supervisor-"+manifest.Version)
    newSigPath    := newBinaryPath + ".sig"

    // 2. Download binary and signature
    if err := downloadFile(manifest.BinaryURL, newBinaryPath); err != nil {
        return err
    }
    if err := downloadFile(manifest.SigURL, newSigPath); err != nil {
        os.Remove(newBinaryPath)
        return err
    }

    // 3. Verify signature — if this fails, clean up and stop
    if err := VerifyBinary(newBinaryPath, newSigPath); err != nil {
        os.Remove(newBinaryPath)
        os.Remove(newSigPath)
        reportFailure("supervisor_sig_verification_failed", err)
        return err
    }

    // 4. Make executable
    os.Chmod(newBinaryPath, 0755)

    // 5. Launch update script as independent process then exit
    // update.sh swaps the binary after this process exits
    // systemd restarts supervisor automatically
    cmd := exec.Command("/bin/bash",
        filepath.Join(supervisorDir, "update.sh"),
        fmt.Sprintf("%d", os.Getpid()),
        newBinaryPath,
    )
    cmd.Start() // fire and forget — do not Wait()

    // 6. Signal systemd to stop this process
    // update.sh detects exit and swaps binary
    // systemd brings new version up automatically
    os.Exit(0)

    return nil
}

func fetchManifest() (*Manifest, error) {
    resp, err := http.Get(manifestURL)
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

### Step 6 — Update Script (Atomic Swap)

```bash
#!/bin/bash
# /opt/learning/supervisor/update.sh
# Runs as independent process, outlives supervisor

SUPERVISOR_PID=$1
NEW_BINARY=$2
SUPERVISOR_BIN="/opt/learning/supervisor/supervisor"
BACKUP_BIN="/opt/learning/supervisor/supervisor-backup"

# Wait for supervisor to exit
echo "[update.sh] waiting for supervisor PID ${SUPERVISOR_PID} to exit..."
while kill -0 "$SUPERVISOR_PID" 2>/dev/null; do
  sleep 0.5
done

echo "[update.sh] supervisor exited, swapping binary..."

# Keep backup for emergency rollback
cp "$SUPERVISOR_BIN" "$BACKUP_BIN"

# Atomic swap
mv "$NEW_BINARY" "$SUPERVISOR_BIN"

echo "[update.sh] swap complete, systemd will restart supervisor"
# systemd Restart=always brings new supervisor up automatically
# Agent process was running the entire time (KillMode=process)
```

---

### Step 7 — systemd Unit

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

# Critical: only kills supervisor PID, not its children
# Agent keeps running during supervisor restart/update
KillMode=process

[Install]
WantedBy=multi-user.target
```

```bash
# Install and enable
sudo systemctl daemon-reload
sudo systemctl enable learning-supervisor
sudo systemctl start learning-supervisor
```

---

### Key Rotation for Phase 1

When private key is compromised, you must act fast:

```bash
# 1. Generate new keypair immediately
openssl genrsa -out build-private-v2.pem 4096
openssl rsa -in build-private-v2.pem -pubout -out build-public-v2.pem

# 2. Replace build-public.pem in repo with new public key
cp build-public-v2.pem build-public.pem

# 3. Build and sign a new supervisor release with the new private key
# — this new binary has the new public key baked in
VERSION="emergency-$(date +%Y%m%d)" ./sign-release.sh

# 4. Push to all devices as priority update
# Devices accept this because it's signed by old private key... 
# BUT WAIT — attacker also has old key and can race you.
# This is the weakness of Phase 1.
# See Phase 2 for the proper solution.
```

> **Phase 1 Limitation:** Key rotation is a race condition. If the attacker has your private key, they can also sign a malicious binary before you rotate. This is acceptable for early stage but must be solved before scaling.

---

### File Layout Summary

```
/opt/learning/
  supervisor/
    supervisor              ← running binary (symlinked or direct)
    supervisor-backup       ← previous version, kept for rollback
    supervisor-vX.Y.Z.sig   ← signature, kept alongside binary
    update.sh               ← swap script
    supervisor.conf         ← config: poll interval, server URL
  agent/
    current -> agent-1.4.2  ← symlink, atomically updated by supervisor
    agent-1.4.2
    agent-1.4.1             ← previous, kept for rollback
  state/
    agent.state             ← persisted state, survives restarts
```

---

---

## Phase 2 — Organization Scale: Two Keys

> **Detail level:** Architecture, algorithms, and methods. No full code.

### What Changes from Phase 1

In Phase 1 you have one global private key — if it leaks, every device across every organization is at risk simultaneously. Phase 2 introduces a **root key + intermediate key** hierarchy so that:

- The root key is kept completely offline
- Only the intermediate key is used day-to-day for signing releases
- If the intermediate key leaks, root key rotates it safely without a race condition

---

### Key Hierarchy

```
Root Key Pair (RSA-4096 or Ed25519)
  ├── Private: offline cold storage / HSM, used once or twice per year
  └── Public:  hardcoded in supervisor binary at compile time

        │
        │  Root signs an Intermediate Certificate
        ▼

Intermediate Key Pair (RSA-4096)
  ├── Private: AWS Secrets Manager / HashiCorp Vault, CI/CD access only
  └── Public:  distributed as a signed certificate (signed by root)

        │
        │  Intermediate signs each release binary
        ▼

Release Binary + Signature
```

---

### Certificate Format

Use **X.509 self-signed certificates** — well understood, tooling exists everywhere.

```
Root Certificate
  Subject:    CN=LearningDevice Root CA
  Key Usage:  Certificate Signing only
  Validity:   10 years
  Signed by:  itself (self-signed)

Intermediate Certificate
  Subject:    CN=LearningDevice Release Signing
  Key Usage:  Digital Signature only
  Validity:   1 year (rotated annually or on compromise)
  Signed by:  Root private key
```

---

### Verification Chain in Supervisor

```
Supervisor receives:
  1. supervisor-vX.Y.Z          (binary)
  2. supervisor-vX.Y.Z.sig      (binary signed by intermediate private key)
  3. intermediate.crt           (intermediate cert signed by root)

Verification steps:
  Step 1: Verify intermediate.crt is signed by hardcoded root public key
          → confirms this cert was issued by you
  Step 2: Extract intermediate public key from intermediate.crt
  Step 3: Verify binary signature using intermediate public key
          → confirms binary was signed after cert was issued
  Step 4: Check intermediate.crt is not expired
  Step 5: Accept or reject
```

Algorithm: **RSA-PSS with SHA-256** (stronger than PKCS1v15 used in Phase 1) or **Ed25519** (faster, smaller keys, modern).

---

### Key Rotation Without Race Condition

This is the key improvement over Phase 1:

```
Intermediate key compromised
        │
        ▼
Take root key out of cold storage
        │
        ▼
Generate new intermediate keypair
        │
        ▼
Sign new intermediate cert with root private key
(attacker doesn't have root key, can't do this)
        │
        ▼
Build supervisor release embedding new intermediate cert
Sign release binary with new intermediate private key
        │
        ▼
Push update — devices verify with root key (hardcoded, unchanged)
Chain validates: root → new intermediate → binary
        │
        ▼
Old intermediate cert expires or is revoked
Attacker's signatures are now invalid
```

No race condition — attacker cannot sign a valid chain without root key.

---

### Per-Organization Considerations

At this phase you may also want **per-organization intermediate keys**:

```
Root Key
  ├── Intermediate Key (Org A)  ← signs only Org A device updates
  ├── Intermediate Key (Org B)  ← signs only Org B device updates
  └── Intermediate Key (Platform)  ← signs supervisor updates for all
```

Benefits: compromise of Org A's key does not affect Org B. Tradeoff: more operational overhead managing multiple intermediates.

**Recommendation:** Start with one shared intermediate, split per-org only when a customer contractually requires it or after a security incident.

---

### Storage Requirements

| Key | Storage | Access |
|---|---|---|
| Root private | HSM or encrypted offline USB, physically locked | Manual only, 1-2x per year |
| Intermediate private | AWS Secrets Manager / Vault | CI/CD pipeline only, no human access |
| Intermediate cert | S3 update bucket, public | Read by all devices |
| Root public | Compiled into binary | Read-only |

---

### Revocation

X.509 supports Certificate Revocation Lists (CRL). For Phase 2, a simple approach:

- Supervisor polls a `/revocation.json` endpoint on your server at every update check
- If current intermediate cert serial is listed as revoked, supervisor refuses all updates and alerts
- You push a new intermediate cert via a root-signed emergency update

Full OCSP (Online Certificate Status Protocol) is overkill at this stage — a simple revocation list is sufficient.

---

---

## Phase 3 — Full SaaS: Certificate Chain with HSM

> **Detail level:** Architecture, algorithms, and methods. No full code.

### What Changes from Phase 2

Phase 2 still has a weak point: the root private key is on a USB drive or similar, which can be lost, stolen, or destroyed. Phase 3 moves the root key into a **Hardware Security Module (HSM)** — a tamper-proof device where the private key is generated inside the hardware and **can never be exported**. All signing operations happen inside the HSM.

---

### Full Certificate Chain

```
Root CA (HSM — air-gapped or online HSM service)
  │
  ├── Platform Intermediate CA
  │     └── Signs: supervisor updates, platform-level agent updates
  │
  └── Per-Organization Intermediate CA (one per org)
        └── Signs: org-specific policy bundles, org-scoped agent configs
```

Three levels: Root → Platform/Org Intermediate → Leaf certificate per release.

---

### HSM Options

| Option | Use case | Examples |
|---|---|---|
| Cloud HSM | SaaS, always online | AWS CloudHSM, Google Cloud HSM, Azure Dedicated HSM |
| HSM as a Service | Simpler, managed | AWS KMS (with custom key store), HashiCorp Vault with HSM backend |
| Physical HSM | Air-gapped root CA | Thales Luna, Yubico YubiHSM |

**Recommended path:** Use AWS KMS for intermediate keys (simple, audited, API-driven) and a YubiHSM or physical HSM for the root CA that you bring online only for intermediate cert signing.

---

### Signing Algorithm Upgrade

Move from RSA to **Ed25519**:

- Smaller keys and signatures (32 bytes vs 512 bytes)
- Faster verification on constrained devices
- Not vulnerable to timing attacks
- Supported by all modern HSMs and TLS stacks

For the certificate chain, use **ECDSA P-256** for intermediate certs (widely supported by X.509 tooling) and Ed25519 for leaf signatures on binaries.

---

### Audit Trail

At SaaS scale every signing operation must be logged and auditable:

```
Every signing event records:
  - Timestamp (UTC)
  - Version being signed
  - Key ID / certificate serial used
  - CI/CD job ID and commit hash
  - Operator identity (for manual operations)
  - Output signature hash

Stored in: append-only audit log (CloudTrail, or dedicated log service)
Alerts on: any signing outside CI/CD pipeline, unexpected key usage
```

This lets you prove to enterprise customers and auditors that no unauthorized binaries were ever signed.

---

### Automated Certificate Lifecycle

At SaaS scale, manual certificate rotation becomes operational risk. Automate:

```
Intermediate cert expiry — 90 days before expiry:
  1. CI/CD pipeline detects upcoming expiry via monitoring
  2. Generates new intermediate keypair in KMS
  3. Submits CSR to root CA signing service
  4. Root CA (HSM-backed) issues new intermediate cert
  5. New cert is distributed to devices via update manifest
  6. Old cert remains valid until expiry (overlap window)

Root cert expiry — manual, 1 year before:
  1. Security team notified
  2. New root cert generated in HSM
  3. Supervisor update ships with both old and new root cert
     (trust both during transition, drop old after 6 months)
```

---

### Multi-Region Resilience

For global SaaS, your update infrastructure must be resilient:

```
Update servers in multiple regions (US, EU, APAC)
  Each region has read replica of:
    - Manifest files
    - Signed binaries
    - Intermediate certificates

Signing happens only in primary region (single source of truth)
CDN in front of update servers (CloudFront, Fastly)

Device update flow:
  1. Resolve nearest update endpoint via GeoDNS
  2. Download from CDN (fast, resilient)
  3. Verify signature locally (no server roundtrip needed for verification)
```

---

### Rollout Control at Scale

With thousands of devices across many organizations, you need controlled rollouts:

```
Manifest includes rollout metadata:
{
  "version": "2.1.0",
  "rollout": {
    "strategy": "canary",
    "canary_percentage": 5,
    "canary_orgs": ["org-id-123"],   ← specific orgs for canary
    "stable_after_hours": 24,         ← auto-promote if no failures
    "block_on_failure_rate": 0.02     ← halt rollout if >2% devices fail
  }
}

Supervisor checks its org_id and device_id against rollout policy
Reports health back to server after each update
Server automatically promotes or halts based on failure telemetry
```

---

### Summary: What Each Phase Gives You

| Capability | Phase 1 | Phase 2 | Phase 3 |
|---|---|---|---|
| Binary authenticity | ✅ | ✅ | ✅ |
| Key rotation without race condition | ❌ | ✅ | ✅ |
| Per-org key isolation | ❌ | Optional | ✅ |
| HSM-backed root key | ❌ | ❌ | ✅ |
| Automated cert lifecycle | ❌ | Manual | ✅ |
| Audit trail | Basic | Basic | Full |
| Rollout control | Simple | Simple | Canary + auto-halt |
| Appropriate for | Early / MVP | Growing SaaS | Enterprise SaaS |