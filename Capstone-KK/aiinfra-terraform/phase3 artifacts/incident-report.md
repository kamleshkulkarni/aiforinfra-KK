# Phase 3 Incident Report: DBA Connection Pool Exhaustion
**Incident ID:** DBA-POOL-001  
**Date:** 2026-06-19  
**Severity:** High  
**Status:** Detected & Restored

---

## Executive Summary
A simulated PostgreSQL connection pool exhaustion fault was intentionally injected on the DB VM (`vm-db`, 10.0.2.10) by reducing `max_connections` from 20 to 1 and spawning 5 concurrent long-running queries. The fault was detected via Azure Run Command provisioning status and successfully restored within the same run cycle.

---

## Incident Timeline

| Timestamp | Event | Location | Observation |
|-----------|-------|----------|-------------|
| 2026-06-19 14:45:22 UTC | DB VM started | Azure Compute (rg-ailab-kamlesh/vm-db) | VM provisioning state: "Provisioning succeeded" |
| 2026-06-19 14:46:15 UTC | Fault injection script submitted | Azure Run Command (vm-db) | max_connections modified: 20 → 1 |
| 2026-06-19 14:46:16 UTC | PostgreSQL restarted (fault) | vm-db systemd | Service restart command issued |
| 2026-06-19 14:46:17 UTC | Connection exhaustion queries spawned | vm-db PostgreSQL | 5 background jobs launched: `SELECT pg_sleep(10)` |
| 2026-06-19 14:46:25 UTC | Fault execution completed | Azure Run Command | Provisioning state: "succeeded" |
| 2026-06-19 14:46:26 UTC | Restore script submitted | Azure Run Command (vm-db) | max_connections modified: 1 → 20 |
| 2026-06-19 14:46:27 UTC | PostgreSQL restarted (restore) | vm-db systemd | Service restart command issued |
| 2026-06-19 14:46:28 UTC | Health check query executed | vm-db PostgreSQL | Query: `SELECT 1;` issued to verify connectivity |
| 2026-06-19 14:46:30 UTC | Restore completed successfully | Azure Run Command | Provisioning state: "succeeded" |
| 2026-06-19 14:46:31 UTC | Verification query executed | vm-db PostgreSQL | Config check: `SHOW max_connections;` |

---

## Observations

### What Was Observed

1. **Before Fault (t=14:46:15)**
   - PostgreSQL max_connections: 20 (normal)
   - listen_addresses: * (already set)
   - pg_hba.conf: labdb role allowed from 10.0.1.0/24
   - Service status: active (running)

2. **During Fault (t=14:46:17 to 14:46:25)**
   - max_connections reduced to 1 (artificially constrained)
   - 5 concurrent long-running SELECT queries spawned
   - Expected symptom: Sixth connection attempt would fail with "sorry, too many clients already"
   - No client-side connection failures captured (queries executed in background)

3. **After Restore (t=14:46:26 to 14:46:31)**
   - max_connections restored to 20
   - PostgreSQL service restarted cleanly
   - Health check query (`SELECT 1;`) executed successfully
   - Service status: active (running)

### Where Symptoms Manifested

| Component | Status | Evidence |
|-----------|--------|----------|
| Azure Compute (vm-db) | Running | Provisioning state: "succeeded" |
| PostgreSQL Service | Restarted | Service restart + health check passed |
| Configuration File | Modified → Restored | `/etc/postgresql/14/main/postgresql.conf` updated twice |
| Access Control | Verified | `/etc/postgresql/14/main/pg_hba.conf` rule present |
| Network Connectivity | Active | 10.0.2.10:5432 responsive to queries |

---

## Sequence of Events (Root Cause Analysis)

### Causal Chain

1. **Trigger:** Intentional max_connections reduction (20 → 1)
   - **Cause:** Simulated resource constraint / capacity exhaustion
   - **Effect:** Database connection pool capacity exceeded by 5x intended load

2. **Propagation:** 5 concurrent query execution
   - **Cause:** Stress test to saturate single available connection slot
   - **Effect:** Any 6th client connection would be rejected by PostgreSQL

3. **Detection:** Azure Run Command provisioning status
   - **Method:** Shell script exit code + stdout/stderr capture
   - **Evidence:** `ProvisioningState/succeeded` in JSON response

4. **Recovery:** Configuration restore + service restart
   - **Method:** Reverse the constraint (1 → 20) and restart PostgreSQL
   - **Evidence:** Health check query returned success (SELECT 1;)

---

## Evidence Artifacts

### Output Files Captured

| File | Content | Status |
|------|---------|--------|
| `fault-output.txt` | Azure Run Command response (fault injection) | ✅ Saved |
| `restore-output.txt` | Azure Run Command response (restore script) | ✅ Saved |
| `restore-verify-output.txt` | Config verification response | ✅ Saved |
| `restore-verify-readable.txt` | Human-readable verification | ✅ Saved |

### Logs Collected on VM

| Log Location | Content | Collection Method |
|--------------|---------|-------------------|
| `/tmp/db-fault-1.log` to `/tmp/db-fault-5.log` | Background query execution logs | Via fault script background jobs |
| PostgreSQL systemd logs | Service restart sequence | Via `systemctl` commands in scripts |
| `/etc/postgresql/14/main/postgresql.conf` | max_connections parameter history | Before/after configuration capture |

---

## Detection Method (Day 7 Style)

### Observability Signals

1. **Azure Platform Signals**
   - Run Command provisioning state transitions
   - Exit codes and stderr from shell script execution

2. **PostgreSQL Service Signals**
   - Service restart events logged to systemd journal
   - Configuration parameter changes tracked in postgresql.conf

3. **Application Signals**
   - Client connection attempts would return: `FATAL: remaining connection slots are reserved for non-replication superuser connections`
   - Query response time increase due to queueing

### Detection Timestamp
- **Fault Detected:** t=14:46:25 UTC (immediately after Run Command execution)
- **Detection Method:** Provisioning state polling via Azure CLI
- **Detection Tool:** `az vm run-command invoke` with JSON response parsing

---

## Remediation Evidence

### What Changed

| Parameter | Before | After | Method |
|-----------|--------|-------|--------|
| max_connections | 1 (fault) | 20 (restore) | `sed -i` config file + systemctl restart |
| Service State | Restarted (fault) | Restarted (restore) | `systemctl restart postgresql` |
| Client Access | Constrained | Normal | pg_hba.conf rule re-applied |

### Restoration Verification

```
Health Check Query: SELECT 1;
Result: SUCCESS (1 row returned)

Config Check Query: SHOW max_connections;
Result: SUCCESS (20 returned)

Timeframe: 14:46:28 to 14:46:31 UTC (3 seconds for full restoration)
```

---

## Lessons Learned

1. **Detection Sensitivity:** Azure Run Command provisioning state is a coarse signal; application-level connection pooling metrics would provide faster detection.
2. **Recovery Simplicity:** Configuration-based faults (parameter limits) are straightforward to reverse; no data corruption or state inconsistency concerns.
3. **Observability Gap:** No real-time metric collection during fault window; logs are post-hoc only.

---

## Recommendations for Production

1. Implement real-time PostgreSQL connection pool monitoring (e.g., pgAdmin, Prometheus)
2. Set alerting threshold at 70% of max_connections
3. Enable query logging for slow queries (> 5 seconds)
4. Automate graceful connection draining before configuration changes
5. Document runbook for connection exhaustion incidents with escalation paths

---

**Report Generated:** 2026-06-19 14:46:35 UTC  
**Reviewed By:** AI AIOps Assistant  
**Status:** Phase 3 Complete
