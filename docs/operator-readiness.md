# ColumnStore Container: Kubernetes Operator Readiness

**Status:** Research / design (MCOL-6233)
**Scope:** What must change in *this* image so it can be driven by a Kubernetes
operator, and how we prove it. Single-node ("query accelerator") first;
**multi-node is the ultimate goal** and every change below is chosen so it is
reused by a future multi-node operator.

---

## 1. Goal and guiding principle

The end goal is a **multi-node ColumnStore Kubernetes operator**. We are not
building the operator in this ticket; we are conditioning the container image so
that an operator (ours later, or the existing `mariadb-operator` as a stepping
stone) can manage its full lifecycle.

**Guiding rule for every change:** it must be justified by *operator-agnostic
container hygiene* and/or *CMAPI + StatefulSet primitives that a multi-node
operator needs*.

Two buckets, judged by reusability:

| Bucket | Reusable for multi-node operator? |
|---|---|
| **A — container/image contract** (this document, §3) | **Yes, 100%.** A cluster is N of these containers + orchestration; the container must be operator-clean first. |
| **B — wiring to the stock `mariadb-operator`** | Mostly throwaway *as a destination* (it models one `mariadbd`, has no CMAPI/PM concept). Useful only as a cheap gap-finder. **Not on the critical path.** |

So: harden the container (§3), then prove it with a kind harness that forms a
cluster via **raw StatefulSet + CMAPI, no operator** (§4). The future operator
becomes "wrap these proven primitives in reconcile logic."

---

## 2. Where the image is today

Real behavior, from the current scripts:

- **Entry:** `tini -- docker-entrypoint.sh start-services` (`Dockerfile:190-193`).
- **`docker-entrypoint.sh`** traps `SIGTERM` → stops MariaDB + `mcs-stop`,
  starts `rsyslogd`, then `exec "$@" &` + `wait`. *(Shutdown is trapped — good —
  but see the lifecycle gap below.)*
- **`start-services`** is literally two lines: `mcs-start` then
  `tail -vf -n +1 /var/log/mariadb/columnstore/*.log`.
- **`mcs-start`** runs `columnstore-init` on first boot (flag
  `/etc/columnstore/container-initialized`), verifies S3 if `USE_S3_STORAGE`,
  starts **CMAPI** (`python3 -m cmapi_server`) in the background, starts
  ColumnStore (`mcs cluster start`) **only if single-node and already
  provisioned**, then starts MariaDB via `/etc/init.d/mariadb start`.
- **`provision`** is run *imperatively after start* (`docker exec ... provision
  mcs1 mcs2 ...`). It already drives the cluster **entirely through CMAPI** via
  the `mcs` CLI: `mcs cmapi is-ready`, `mcs cluster set api-key`,
  `mcs cluster node add --node ...`, `mcs cluster restart`, then a validation
  query. Sets flag `/etc/columnstore/container-provisioned`.
- **`mcs-health`** already encodes real readiness: MariaDB ping, CMAPI running,
  `mcs cluster status` → `dbrm_mode` (master/slave), process counts (6 primary /
  3 replica), readwrite/readonly, and `SELECT COUNT(1) FROM
  calpontsys.syscolumn` on the primary.
- **Runs as root.** `CMAPI_KEY` defaults to the hardcoded `somekey123`.
- **VOLUMEs:** `/etc/columnstore`, `/etc/my.cnf.d`, `/var/lib/mysql`,
  `/var/lib/columnstore` (`Dockerfile:187`).
- Carries **SkySQL-specific** paths/config (`/mnt/skysql/...`) — useful
  precedent: the image is already shaped for a managed/orchestrated environment.

**Two good things to build on:** `mcs-health` is a ready-made readiness probe,
and `provision` is already CMAPI-driven (exactly what an operator automates).

**The core gaps:** the container stays alive on `tail -f` (not the DB);
provisioning is a post-start `docker exec` (not declarative); logs go to files +
rsyslog (not stdout); it runs as root; node identity/config is not parameterized
for N nodes; the CMAPI key is hardcoded.

---

## 3. The container contract — required image changes

Eight changes. "Tier" marks what each unblocks: **C** = clean container
(operator-agnostic), **M** = multi-node operator enabler. Order respects
dependencies.

### Step 1 — Make container lifecycle track the real workload  *(Tier C)*
Drop the `tail -f` keepalive in `start-services`. The foreground process must be
something whose death means the container is unhealthy. Keep `tini` as PID 1.
Either `exec` the DB as the foreground process or run a thin supervisor that
exits non-zero when MariaDB **or** CMAPI dies (today MariaDB is launched via
`/etc/init.d/mariadb start` and is untracked — if `mariadbd` crashes, `tail`
keeps the container "up").
- **Files:** `scripts/start-services`, `scripts/docker-entrypoint.sh`, `scripts/mcs-start`.
- **Done when:** killing `mariadbd` (or CMAPI) causes the container to exit;
  `docker kill -s TERM` shuts down cleanly within the grace period.

### Step 2 — Logs to stdout/stderr  *(Tier C)*
Redirect MariaDB error log, ColumnStore logs, and CMAPI log to the container's
stdout/stderr; remove the hard dependency on `rsyslogd` for the foreground path.
- **Files:** `scripts/start-services`, `scripts/mcs-start`, `Dockerfile` (rsyslog setup).
- **Done when:** `docker logs <c>` shows MariaDB + ColumnStore + CMAPI output;
  no log file tailing is required for observability.

### Step 3 — Env-driven, idempotent entrypoint (no post-start `exec`)  *(Tier C/M)*
Provisioning must happen from configuration at startup, not via
`docker exec provision`. Detect first-run vs restart (reuse the existing
`container-initialized` / `container-provisioned` flags). Read all config from
env / mounted secret files: root & admin passwords (`*_FILE` convention),
`CMAPI_KEY`, `USE_S3_STORAGE` + `S3_*`, node identity (Step 7). A second start
with populated volumes must be a safe no-op.
- **Files:** `scripts/docker-entrypoint.sh`, `scripts/columnstore-init`, `scripts/provision`.
- **Done when:** the container reaches ready from env + mounted secrets alone;
  restart preserves data and re-runs nothing destructive.

### Step 4 — Stable probe contract  *(Tier C)*
Expose three explicit probe commands, built on the existing `mcs-health` logic:
- **startup** — init complete + `mariadbd` accepting connections;
- **readiness** — accepts SQL **and** ColumnStore is queryable **and** CMAPI
  responds (this is essentially today's `mcs-health`);
- **liveness** — process group alive / not deadlocked.
- **Files:** new `scripts/probe-startup|readiness|liveness`, refactor `scripts/mcs-health`.
- **Done when:** each probe returns correct exit codes and is wired into the
  harness Pod spec.

### Step 5 — Run as non-root  *(Tier C)*
Default to the `mysql` user; set directory ownership at build time; rely on
`fsGroup` for mounted volumes instead of the current runtime `chown -R`
(`docker-entrypoint.sh:12`, `mcs-start:8-12`). No operation may require being
root at runtime.
- **Files:** `Dockerfile`, `scripts/docker-entrypoint.sh`, `scripts/mcs-start`.
- **Done when:** `docker run --user <nonroot>` works end to end; compatible with
  a restricted `securityContext`.

### Step 6 — CMAPI as the sole, secured control surface  *(Tier M)*
Cluster operations already go through CMAPI via `provision` — formalize it.
Expose CMAPI (port **8640**), source the API key from a secret (drop the
`somekey123` default), make TLS configurable. Document the exact CMAPI calls the
formation flow uses (`set api-key`, `node add`, `cluster start/restart`,
`cluster status`) as the contract a future operator will call directly over
REST.
- **Files:** `scripts/provision`, `scripts/mcs-start`, `Dockerfile`
  (`cmapi_server.conf`), config templating.
- **Done when:** a single-node cluster forms via a CMAPI call from outside the
  container, authenticated by a secret-provided key; no `docker exec` needed.

### Step 7 — Peer-addressable identity & N-node config  *(Tier M)*
The same image must run as node-0 or node-N. Parameterize node name, role, and
peer list via env, resolved against stable DNS
(`<pod>-<ordinal>.<headless-svc>`). Config templating (`Columnstore.xml`,
`cmapi_server.conf`) must render for an arbitrary node count rather than the
compose-era fixed hostnames.
- **Files:** `scripts/docker-entrypoint.sh`, `scripts/columnstore-init`, config templating.
- **Done when:** the image joins a >1-node cluster using only env + stable
  hostnames.

### Step 8 — Declared storage layout  *(Tier C/M)*
Document and validate the persistence model: PVCs for `/var/lib/mysql`,
`/var/lib/columnstore`, `/etc/columnstore`; single-node uses a local PV,
multi-node uses shared **StorageManager/S3** for ColumnStore data. Clarify which
of the four current VOLUMEs must be per-pod vs shared.
- **Files:** `Dockerfile` (`VOLUME`), docs, S3/StorageManager config.
- **Done when:** restart with mounted PVCs preserves data; S3 mode verified in
  the harness.

### Step 9 — TLS-ready (consume mounted certs)  *(Tier C/M)*
Martin lists "issue and configure TLS certificates" as a Day-1 op and "rotate
TLS" as Day-2. The split: the container's contract is only to **consume** TLS
material — server/CMAPI cert, key, CA from mounted files (paths via env/secret)
— and enable TLS when present. *Issuing* and *rotating* certs is the operator's
job (e.g. cert-manager).
- **Files:** `Dockerfile` / `my.cnf.d`, `cmapi_server.conf`, entrypoint templating.
- **Done when:** providing cert/key/CA via mounted files enables TLS for SQL
  connections and the CMAPI endpoint without rebuilding the image.

### Step 10 — Expose a metrics endpoint  *(Tier C/M)*
Martin flags Prometheus metrics as a **Day-1** op, *"crucial for day-2
operations."* The split: the container must **expose** a Prometheus-format,
scrapeable endpoint — `mariadbd` via an exporter, plus basic ColumnStore/CMAPI
stats; the operator **configures scraping** (`ServiceMonitor`). This reuses the
same CMAPI/`mariadbd` state that `mcs-health` already reads, so it is cheap and
sits naturally beside the Step 4 probes ("observe it truthfully").
- **Files:** `Dockerfile` (exporter), `scripts/start-services` (run/foreground the
  exporter), config.
- **Done when:** a Prometheus endpoint exposes `mariadbd` + basic
  ColumnStore/CMAPI metrics and is scraped in the harness (L2/L3).

**Explicitly out of this core (day-2, operator-orchestrated):** backup & restore
hooks mapped to operator CRD semantics; rolling-upgrade orchestration. These are
real follow-ups but are *not* required to declare the image
operator-conditionable — they are driven by the operator on top of the contract
above.

---

## 4. Acceptance harness (kind)

A repeatable suite that forms a ColumnStore cluster with **raw StatefulSet +
CMAPI and no operator**, so it tests exactly the primitives a future operator
will automate. Everything here is reused by that operator.

**Tooling:** `kind`, `kubectl`, a thin bash/Go runner. Manifests: a headless
`Service` + `StatefulSet` (`volumeClaimTemplates` for PVCs) + `ConfigMap` /
`Secret` for env. Cluster formation is done by an init `Job` that calls CMAPI —
the stand-in for the operator's reconcile loop.

| Layer | Where | Asserts | Gates steps |
|---|---|---|---|
| **L1 — container contract** | plain `docker run`, no k8s (fast; every PR) | start-from-env, stdout logs, non-root, SIGTERM clean exit, **exit-on-mariadbd-death**, idempotent restart, all 3 probes | 1–5 |
| **L2 — single node on k8s** | kind, 1 replica | StatefulSet Ready, SQL works, ColumnStore query works, CMAPI status healthy, TLS enabled from mounted certs, metrics endpoint scrapeable, pod delete → data survives | + 6, 8 (local), 9, 10 |
| **L3 — multi-node on k8s** | kind, N replicas | N-node cluster forms via CMAPI, distributed CS query works, kill a pod → recovers, rolling restart with no data loss, scale 1→3 | + 7, 8 (S3) |
| **L4 — functional correctness** | existing MTR multi-node suite | ColumnStore behavior unbroken by hardening | regression backstop |

**Verdict:**
- L1 + L2 green → **single-node operator-ready**.
- + L3 green → **multi-node operator-ready** (the real goal).
- L4 green throughout → no functional regression.

**CI cadence:** L1 on every PR (seconds); L2/L3/L4 nightly on kind. Keep this
matrix as a checklist in the repo README so the operator team can see exactly
what is guaranteed before committing to build the operator.

---

## 5. Alignment with the ticket scope (Martin Montes' Day-1/Day-2 list)

How MCOL-6233's stated scope maps to the container contract vs. the operator.
"Container side" = something this image must provide (in §3); "Operator side" =
reconcile logic built on top later.

| Martin's item | Phase | Container side | Operator side |
|---|---|---|---|
| Provision multiple topologies | Day 1 | Steps 3, 6, 7 | reconcile CR → CMAPI |
| Configure system variables | Day 1 | Step 3 (env/config) | render config from CR |
| Compute resources + network-addressable | Day 1 | Step 7 (identity), Step 6 (CMAPI port) | resources, Service |
| Provision & attach volumes | Day 1 | Step 8 (layout) | PVC / volumeClaimTemplates |
| Issue & configure TLS certs | Day 1 | **Step 9** (consume certs) | cert-manager, issuance |
| Configure Prometheus metrics | Day 1 | **Step 10** (expose endpoint) | ServiceMonitor / scrape |
| Rolling upgrades, no downtime | Day 2 | clean restart (Steps 1, 8) | upgrade orchestration |
| Backup & restore | Day 2 | mariadb-backup + S3 hooks | Backup/Restore CRDs |
| Scale horizontally/vertically | Day 2 | Step 7 | scale reconcile → CMAPI |
| Expand volumes | Day 2 | Step 8 | PVC expansion |
| Rotate TLS + roll | Day 2 | Step 9 (reload certs) | rotation + rolling restart |

**Methodology alignment:** Martin's core advice — enable the lifecycle via an
env-driven `entrypoint.sh` in the plain container *before* building the operator,
and recognize when bash stops scaling — is exactly the spine of §3. Every Day-1
item has a corresponding container-contract step; Day-2 items are operator work
resting on that contract.

## 6. Suggested follow-up tickets

- Entrypoint: env-driven, idempotent, foreground lifecycle (Steps 1, 3)
- Logs to stdout/stderr (Step 2)
- Non-root + `securityContext` hardening (Step 5)
- Probe contract built on `mcs-health` (Step 4)
- CMAPI as secured control surface; remove hardcoded key (Step 6)
- N-node identity & config templating (Step 7)
- Storage layout: PVCs + shared StorageManager/S3 (Step 8)
- TLS-ready: consume mounted certs for SQL + CMAPI (Step 9)
- Metrics: expose Prometheus endpoint for mariadbd + ColumnStore/CMAPI (Step 10)
- kind acceptance harness, L1–L4 (§4)
- **Epic:** multi-node CMAPI orchestration operator (deferred; needs eval with
  the operator team)
- Coordination: operator-team evaluation (per MCOL-6233 comments)

---

## 7. On the `mariadb-operator` question

Using the existing `mariadb-operator` is **not** the destination — it models a
single `mariadbd` and has no concept of CMAPI-driven multi-node ColumnStore. It
is worth at most a cheap, opportunistic run against the hardened single-node
image (§3 Steps 1–6) to surface gaps and get a free "behaves under a real
reconcile loop" signal. The reusable path is: **harden the container (§3) →
prove multi-node via the no-operator CMAPI/StatefulSet harness (§4) → wrap those
primitives in a purpose-built operator.**

---

## 8. Building the harness — design, stack, effort

**Can it be built? Yes — and L1 can be written *now*,** before the image
implements §3, because the contract tests are simply the contract in executable
form. They fail until the image complies, which makes them a TDD spec for the
image work and the highest-leverage place to start.

**Language / framework (pragmatic split):**

- **L1 (container contract): Bash + `bats-core`.** The repo is already all bash,
  L1 is pure `docker`-CLI assertions, no build step, runs in seconds. Lowest
  friction and contributor-friendly.
- **L2 / L3 (k8s e2e): Go**, using `kind` + the standard Kubernetes client,
  talking to CMAPI over REST. Rationale, per this doc's reuse rule: the CMAPI
  client and cluster-formation helpers written here are exactly what the future
  operator needs, so the code is reused rather than thrown away. *(L2/L3 may
  start as bash + `kubectl` if speed-to-first-test matters more than reuse;
  migrate the CMAPI logic to Go when operator work begins.)*

**Tooling:** `kind` (local cluster), `kubectl`, `bats-core`, `minio` (in-cluster
S3 for L3), GitHub Actions (L1 every PR; L2/L3/L4 nightly).

**Layout:**
```
harness/
  contract/        # L1 — *.bats + helpers.bash
  k8s/manifests/   # headless Service, StatefulSet, ConfigMap/Secret, minio, CMAPI provision Job
  k8s/e2e/         # L2/L3 tests
  README.md        # verdict matrix + how to run
```
Single entrypoint, e.g. `make test-contract | test-k8s-single | test-k8s-multi`.

**Example L1 assertions (each one = a contract clause):**

- starts to *ready* from env alone, no `docker exec` (Step 3)
- `docker logs` shows mariadbd + CMAPI output (Step 2)
- `docker exec ... id -u` ≠ 0 (Step 5)
- `docker stop -t30` exits cleanly within budget; killing `mariadbd` exits the
  container non-zero (Step 1)
- write a row → restart → row survives (Steps 3, 8)
- startup / readiness / liveness probes return correct exit codes (Step 4)
- TLS enabled from mounted certs; metrics endpoint returns Prometheus text
  (Steps 9, 10)

**Effort (rough):** L1 ≈ 1–2 days, runs today, high value. L2 ≈ 2–3
days. L3 (multi-node formation, S3, failure injection, scaling) is the real
work, ≈ 1 week+, and depends on decisions still open (S3 backend, exact CMAPI
formation flow). L4 = wire the existing MTR suite, low effort. **Recommended
order:** build L1 first as the image's executable contract, then L2, then L3.
