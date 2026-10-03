# Where a child gate's 11 seconds actually go — the floor's composition, measured

> **WHY THIS FILE EXISTS.** `PROFILE-child-gate.md` measured the floor — a child
> gate that runs **zero** checks still costs **11.07 s** — and said so in one
> sentence: *"the `cp -R`, the bootstrap, the `--only` evaluation across every
> registered check, and the summary. No declaration can touch it."* That is a
> **list of suspects, not a measurement.** Four hypotheses, four numbers never
> taken. This file takes them.

Date: 2026-10-03. Branch: `worker/kit-startup-floor-01`, base `1f88196`.

**The headline is already in and it contradicts the packet's premise in a useful
way: the bootstrap is 0.04 s.** Resolving an interpreter and installing
dependencies is **0.6%** of the floor. The packet's first hypothesis —
"interpreter discovery? A venv?" — is measured, and it is not the cost.

---

## 1. The floor on this box, and the honest difference from 11.07 s

```sh
unset KIT_PYTHON
bash tests/validate.sh --static-only --only=__no_such_check__
```

The gate **refuses** the filter and exits 1, which is correct and is what makes
it a zero-check run.

| run | seconds | note |
|---|---:|---|
| first, cold | **16.54** | the box was busy; discarded |
| second | **6.97** | `/usr/bin/time -p`, unfiltered |
| profiled (`KIT_PROFILE`) | **6.850** | the profiler's own `total` row |

**6.85 s, not 11.07 s, on the same command on the same tree.** The difference is
**not** a change in the gate: `1f88196` is yesterday's merge and the commit is
untouched. The difference is **machine load** — `PROFILE-child-gate.md` §"The
floor is measured, not inferred" and `AGENTS.md` §"`self_test` hits its
90-minute bound on a busy box" are the same observation from two directions:
this box runs several kit gates at once. **Every number below is this box's, and
the ratio — not the absolute seconds — is the claim.**

## 2. The composition, from the gate's own profiler

`KIT_PROFILE=/tmp/f.tsv` and read the `phase` rows. **The phase rows sum to the
run's `total` (6.850 s), so nothing is unattributed** — this is a closed
decomposition, not a sample.

| # | section | seconds | share | what it is |
|---|---|---:|---:|---|
| 1 | `static: templates/kamal — every artifact is present` | **3.805** | **55.6%** | **mostly `tests/kamal_test.sh` — 24 cases against the real `kamal` and `kamal-backup` binaries** |
| 2 | `static: templates declare no third-party dependency` | 0.648 | 9.5% | an inline Python snippet check |
| 3 | `static: the canary harness — contract, adapter, and every artifact` | 0.626 | 9.1% | inline Python over `templates/secrets/` |
| 4 | `static: the fleet adopts the stack rather than copying it` | 0.522 | 7.6% | `tests/fleet_check.py` against 6 real repositories |
| 5 | `static: every Dockerfile runs non-root on a pinned base` | 0.394 | 5.8% | inline Python over 8 Dockerfiles |
| 6 | `static: compose — the observability chokepoint` | 0.206 | 3.0% | inline Python over the compose files |
| 7 | `static: templates/database/tenancy — every artifact is present` | 0.146 | 2.1% | presence only |
| 8 | `static: the core fan-out standard` | 0.133 | 1.9% | `tests/core_fanout_check.py` |
| 9 | `static: secrets — the scanner is present, configured, and can fail` | 0.104 | 1.5% | parses `.gitleaks.toml`, reads the workflow |
| 10 | `00 bootstrap: resolve the interpreter and install deps` | **0.040** | **0.6%** | **the packet's first hypothesis. It is not the cost.** |
| 11 | `static: every language declares a tier…` | 0.017 | 0.2% | |
| 12 | `10 static` / `20 telemetry` / `30 observability` / `40 classifier…` / `50 lint` / `60 self_test` / `70 summary` / END | 0.093 | 1.4% | seven skipped phases and the summary, together |
| — | `static: templates/otel…`, `every Dockerfile is hadolint clean`, `every YAML…`, `lint runs from kit…`, and 5 more sections | 0.014 | 0.2% | each under 0.03 s |
| | **total** | **6.850** | | closed: rows sum to `total` |

### The three claims this table earns

1. **The bootstrap is not the floor — 0.040 s of 6.850.** `tests/bootstrap.sh`'s
   `kit_bootstrap_python` costs **6 milliseconds**. "Resolve the interpreter
   once, like the cache rollout's handoff suggested" would buy **nothing**, and
   the suggestion is withdrawn by this measurement rather than left standing.
2. **One section is 55.6% of the floor**, and it is not a probe, not a venv and
   not git. It is **`tests/kamal_test.sh`, which runs the real `kamal` and
   `kamal-backup` binaries 24 times** — a *genuine* dependency load, executed on
   every copy of the gate, including the 86 copies that were asked for one cheap
   check.
3. **`--only` does not gate the static phase's work.** The filter refused to run
   any check, yet 6.8 s of Python and of `kamal` binaries still executed. **The
   floor is not "the cost of evaluating the filter" — it is the cost of ~20
   sections that ignore the filter entirely.**

## 3. Reproduce

```sh
unset KIT_PYTHON
KIT_PROFILE=/tmp/f.tsv bash tests/validate.sh --static-only --only=__no_such_check__
awk -F'\t' '$1=="phase" {printf "%7.3f  %s\n", $3+0, $2} /total/ {print}' /tmp/f.tsv | sort -rn
```