# REPORT — kit-guard-wrapper-tier-scope-01

**Branch** `worker/kit-guard-wrapper-tier-scope-01` · **base** `0574446` (master,
carrying `docker_tier_project_name`) · **worktree** `wt-m39-kit-guard-wrapper-scope-01`

**Text scan throughout. No image, no container, no `docker` invocation was made by
anything in this branch.** Every command was bounded by `timeout`.

---

## 1. The defect, and how I proved it was real

`docker_tier_project_name` printed, in its own success line:

```
5 docker tier(s), 0 hardcoded container/volume/project name and 0 fixed host port;
the sixth tier is covered on the day it lands, not the day this file is edited
```

The first half was true. The second was false: three tiers under `tests/` bring a
compose stack up and were not in scope at all.

### The measurement, before anything changed

The packet's own mutation, run by hand:

```
$ grep -n '^PROJECT=' tests/canary_test.sh
71:PROJECT="kit-canary"                    <- the mutation IS in the file
$ git diff --stat -- tests/canary_test.sh
 tests/canary_test.sh | 2 +-               <- one line changed, by text

$ python3 <guard extracted from tests/validate.sh> tests ; echo exit=$?
5 docker tier(s), 0 hardcoded container/volume/project name and 0 fixed host port;
the sixth tier is covered on the day it lands, not the day this file is edited
exit=0
grep -c canary = 0

$ git checkout -- tests/canary_test.sh ; grep -n '^PROJECT=' tests/canary_test.sh
71:PROJECT="kit-canary-$$"                 <- reverted
```

**Before: `grep -c canary` = 0, exit 0. After revert: the same green.**

Six independent mutations, same harness (`reports/wrapper-tier-scope/mutations.sh`):

| # | mutation | before | after |
|---|---|---|---|
| 1 | `canary_test.sh`: `PROJECT="kit-canary-$$"` → `"kit-canary"` | 0 | 0 |
| 2 | `no_telemetry_in_readiness.sh`: `PROJECT` loses its `$$` | 0 | 0 |
| 3 | `stack_live_test.sh`: `PROJECT` loses its `$$` | 0 | 0 |
| 4 | `canary_test.sh`: the `compose()` wrapper hardcodes `-p` | 0 | 0 |
| 5 | `no_telemetry_in_readiness.sh`: the `compose()` wrapper hardcodes `-p` | 0 | 0 |
| 6 | `stack_live_test.sh`: direct `docker compose -p` hardcoded | 0 | 0 |

**0 of 6 bit.** The falsification in the packet reproduces verbatim.

### Why the pattern could not see them

`BRING_UP` was `r"\bdocker\s+(?:compose\b.*\bup\b|run\b)"` and needs both halves of
a command on one logical line.

```
tests/canary_test.sh:82   compose() { docker compose -p "$PROJECT" -f "$WORK/compose.yml" "$@"; }
tests/canary_test.sh:419  if compose up -d --wait --wait-timeout 120 sender …
```

`docker compose` is in the wrapper's body; `up` arrives at the call site through
`"$@"`. Two places, no line holds both. `stack_live_test.sh` never writes
`docker compose … up` at all — it brings the stack up with `bash ./bin/dev up` at
line 348 and names the shared project only from `ps`, `exec`, `port` and `logs`.

The consequence that matters: **a file dropped from `tiers` is invisible to a rule
that counts tiers.** So not even the emptiness finding named them. They were
never counted, so "was counted as a docker tier but nothing could be read" could
not fire either. The output said `0 hardcoded … name` about a file that had one.

---

## 2. What I changed

### 2.1 `WRAPPER` — the second arm of the tier predicate

Matches a function **definition** whose body invokes `docker compose`:

```python
WRAPPER = re.compile(
    r"^\s*(?:function\s+)?[A-Za-z_][A-Za-z0-9_]*\s*\(\s*\)\s*\{[^{}]*\bdocker\s+compose\b"
)
```

The definition, not the call sites, and that is a trade rather than a preference. A
call-site pattern must know every spelling a pass-through can take (`compose up`,
`"$COMPOSE" up`, `dc -f x up`, a wrapper three files away), and the sixth idiom is
another blind spot. A definition has exactly one shape and keeps the `docker
compose` on the same line it is hiding. `[^{}]*` so a wrapper cannot borrow the next
function's docker.

### 2.2 A fifth emptiness finding — the real fix

> a script under `tests/` that invokes docker but was not counted as a docker tier
> is a finding, named.

Widening `BRING_UP` alone is a one-line patch that regresses silently the next
time someone adds a wrapper idiom. The predicate is **deliberately wider** than the
tier set:

```python
TOUCHES_DOCKER = re.compile(
    r"\bdocker\s+(?:compose|run|rm|volume|network|build|image|rmi|create|tag|cp)\b"
)
```

Deriving it from `tiers` would be a tautology that can never fire — a green that
costs its reader trust in the red ones, which is this repository's own recorded
failure mode.

### 2.3 `TAKES_A_SHARED_NAME` — the third arm

Forced by 2.2, which immediately named `provenance_test.sh`. It never starts a
container, so neither of the first two arms could see it.

```python
TAKES_A_SHARED_NAME = re.compile(
    r"\bdocker\s+(?:compose|run|volume|network|build|image|rmi|tag)\b[^\n]*?"
    r"(?:\s(?:--project-name|--name|-p|-t|--tag|-v)[=\s])"
)
```

### 2.4 Two false positives the widening produced — fixed, not tolerated

**`deploy_test.sh:456`** is `note "  docker build -t cafaye-kit16/courier:35c6a27
/path/to/courier"` — an example printed to a reader who has no image. The new
image-tag rule matched a whole command inside a string. Now `command_positions()`
drops any match whose `docker` lies inside a quoted run.

The first attempt **blanked the quoted runs instead**, which was worse and worth
recording: `docker build --tag "$IMAGE_BAD"` became `docker build --tag ` and the
pattern captured the *next flag* as the image name (`-f`), and a `\` continuation
reported `-t` with the value `\`. Both are findings with a name in them, so both
read as real defects and neither is.

**`stack_live_test.sh:297`** `KIT_POSTGRES_DATABASES=kit_probe` — a database name
created *inside* the stack the same file brings up under `PROJECT="kit-stack-$$"`.
Two runs cannot collide on it: the finding's own sentence, *"every run of this tier
shares it"*, was false there. The literal-assignment rule now requires the
variable to be **read by a docker line in the same file** — the question its
message actually asserts — derived from the file rather than from a list.
`PROJECT` and every real namespace is read by a `docker compose -p "$PROJECT"`, so
the load-bearing case is untouched, and all 8 mutation cases confirm it.

---

## 3. The four emptiness findings, and which are reachable today

| # | finding | fires today? | proved by |
|---|---|---|---|
| 1 | no docker tier found under `tests/` | no | reachable — predicate is `not tiers` |
| 2 | *n* tiers found and none derives a namespaced name | no | reachable — predicate is `derived == 0` |
| 3 | was counted as a tier but no docker invocation could be read | no | reachable — predicate is `examined == 0` |
| 4 | brings a stack up and never names a project | no | reachable — predicate is `brings_up and not names_a_project` |
| **5** | **invokes docker but was not counted as a tier** | **no — 0 uncovered** | **case 7 below, BITTEN** |

Finding 5 fires on nothing today, and a rule that fires on nothing is not yet
proven to be able to fire — which is this packet's whole subject. So case 7 builds
one: a bare `docker volume rm shared-vol` dropped into `lint_test.sh`, which no arm
can make a tier, so the finding has to arrive from the tier-set rule or not at all.

```
BITTEN  lint_test: a bare docker volume rm makes it uncovered  before=0 after=1
```

Case 7 fails if finding 5 is deleted and passes if it is there. That is what makes
it a control rather than a paragraph.

**Worth stating plainly: findings 1–4 are reachable by inspection of their
predicates and are not covered by a recipe in this branch.** That is the same
hole this packet exists to close, one level in, and I am naming it rather than
leaving it absent.

---

## 4. After — the measurement

```
$ bash reports/wrapper-tier-scope/mutations.sh
guard: 503 lines extracted from tests/validate.sh

BITTEN  canary: PROJECT loses its $$                       before=0 after=1
BITTEN  no_telemetry: PROJECT loses its $$                 before=0 after=1
BITTEN  stack_live: PROJECT loses its $$                   before=0 after=1
BITTEN  canary: wrapper hardcodes -p                       before=0 after=1
BITTEN  no_telemetry: wrapper hardcodes -p                 before=0 after=1
BITTEN  stack_live: direct docker compose -p hardcoded     before=0 after=1
BITTEN  lint_test: a bare docker volume rm makes it uncovered   before=0 after=1
BITTEN  provenance: image tag loses its $$                 before=0 after=1

8/8 cases bit, 0 failed
```

In situ, through the real gate:

```
$ bash tests/validate.sh --only='no docker tier hardcodes'   # exit 0
PASS tests/  (no docker tier hardcodes a project, container, volume, image or host
port name; every shared namespace is derived from the run)
     9 docker tier(s), 0 hardcoded container/volume/project/image name and 0 fixed
     host port; 0 script(s) under tests/ invoke docker without being a tier, so a
     stack brought up through a wrapper is a tier too — covered on the day it lands,
     not the day this file is edited
```

`shellcheck -S warning` clean on `tests/provenance_test.sh` and the recipe.

### The tier set, and why 9 and not 8

The packet predicted `8 docker tier(s)` and zero uncovered. **I get 9.**

```
canary_test.sh                    deploy_test.sh        isolation_test.sh
kamal_test.sh                     no_telemetry_in_readiness.sh
provenance_test.sh                rls_perf_test.sh      stack_live_test.sh
tenancy_test.sh
```

The four the packet named are the three wrapper tiers plus `provenance_test.sh`,
which finding 5 named within minutes of existing. Its two image tags were literal
in the tree and are now `kit-provenance-test-$$:{good,plain}` — the same defect the
other four namespaces were fixed for, wearing an image hat. `docker build -t NAME`
writes over a tag and `docker rmi -f NAME` deletes one, and neither consults `-p`.

I did not tune the number. A guard whose count was adjusted to a target is a guard
measuring the target, and the packet says to name the difference instead.

---

## 5. What I chose not to do, and why

- **Did not add these as `self_test.sh` breakages.** That suite runs whole gates in
  sequence; a recipe per mutation is several minutes each, and this is a text scan
  with a 0.1 s recipe that runs the *shipped* guard. The extraction is the reason
  this is not a worse choice: `mutations.sh` pulls the python out of
  `tests/validate.sh` on every run and **stops** if it comes back empty, so it
  cannot outlive the check it proves and cannot silently measure nothing.

- **Did not generalise `outside_quotes` to every rule.** `DOCKER_USE` is a search
  whose result feeds `examined`, so destringing the lines it reads would change how
  many use sites a tier appears to have — and that count is itself a check. The
  scope is recorded at the helper.

- **Did not let `examined` widen with `NAMES_IN_DOCKER`.** Widening it would have
  made emptiness finding 3 *harder* to fire, which is the wrong direction to reach
  in. The asymmetry is written down at the pattern.

- **Did not close findings 1–4 with recipes.** Out of the clock, and I would rather
  hand over a named gap than a half-built one.

- **Did not reimplement bash expansion.** `DECISIONS.md` already argues it: it
  means interposing a shell parser, and this repository has removed one containment
  assertion over brace counting precisely because it fired on correct code.

---

## 6. The limit, stated honestly

`DECISIONS.md` keeps the previous entry intact — a *name* reached through a helper
is invisible at the use site:

```
compose_up() { docker compose --project-name "$1" -f "$f" up -d; }
compose_up kit-isolation                                            -> GREEN
```

It is a different sentence from the new one, and the distinction is the point:

> **Before: the whole TIER was out of scope, silently. After: the tier is in scope,
> and only indirection inside it remains invisible.**

A wrapper that brings a stack up is now a tier. A name the wrapper *builds* before
passing it is still not something a text scan can read. Merged into one vague "the
guard is heuristic", both sentences become worth less than either.

---

## 7. Things this brief did not anticipate

**1. `provenance_test.sh` was a fifth namespace nobody had looked at.** Two literal
image tags, torn down with `docker rmi -f`. Named by the new emptiness finding
within minutes of it existing. Fixed here because leaving it would have meant
shipping a knowingly-red gate; it is scope expansion and I am labelling it as such.

**2. Two false positives the widening produced**, both detailed in §2.4. Neither was
in the brief. The `deploy_test.sh:456` one is the interesting half: **blanking the
quoted runs — the obvious way to implement "a command inside a string is not a
command" — produces findings with plausible names in them**, so it is not a check
that fails loudly, it is a check that invents two defects and one nonsense tag.

**3. `stack_live_test.sh` was never in scope at all, for a second reason.** It
brings the stack up through `bash ./bin/dev up` — a *fetched CLI*, not a shell
function. Even a widened wrapper arm would have missed it; only the
`TAKES_A_SHARED_NAME` arm catches it. If kit grows a second stack driver, that is
the idiom to watch.

**4. My own harness ate my own edit, and I committed a message about it.** The
EXIT trap ran `git checkout -- tests/` even on the STOP path where it had just
refused to start because `tests/` was dirty — discarding an uncommitted
`NAMES_IN_DOCKER`, after which I committed a message describing text that was never
in the file. `grep -n NAMES_IN_DOCKER tests/validate.sh` printed nothing and I read
past it. Commit `37aa0f2`. `restore` is now armed (`MUTATED=1`) rather than
installed. This is the exact class the packet is about, aimed at the harness.

**5. A hole the eighth case found, not the sixth.** `GOOD_IMAGE` losing its `$$`
produced **no finding**, because the literal-assignment rule asked whether the
variable was fed to docker using `DOCKER_USE`, and `docker build` is not one of its
five subcommands. The declaration was invisible to the rule whose subject is
declarations. Fixed with `NAMES_IN_DOCKER`, scoped so `examined` does not widen.

**6. A finding's remedy was wrong on the variable it names.** The literal-assignment
message ended *Put the run's own name in it (`PROJECT="$PROJECT-…"`)* — an
instruction to assign a variable from itself, on the line a reader is trying to
fix. Unreachable while only the five original tiers were in scope, because none of
them names its project variable `PROJECT`. It now reads `$RUN-…` when the variable
*is* `PROJECT`. A finding whose remedy is wrong is half a finding.

**7. Emptiness findings 1–4 have no recipe in this branch** (§3). Named rather than
absent.

**The pattern across 4, 5 and 6 is worth stating separately: every one of them was
exposed by widening the tier set, and none was caused by it.** `stack_live`'s
`KIT_POSTGRES_DATABASES`, the recipe's advice, and the `NAMES_IN_DOCKER` hole were
all invisible because the tier set was wrong, and all three were found by the same
act of making it right. A scope fix in a guard is not only a widening; it is also a
searchlight.

---

## 8. Verification checklist

- [x] Committed to `worker/kit-guard-wrapper-tier-scope-01`. Not pushed, not merged,
      not tagged.
- [x] Every command bounded by `timeout` (60 s scans, 300 s recipe, 240 s gate).
- [x] Nothing skipped silently. The 111 checks excluded by `--only` are counted by
      the gate itself in a `note:` line, and the recipe prints all 8 case rows
      including their before/after counts.
- [x] Every "fixed" has a before/after: `0/6 → 8/8`; `5 tiers / 0 uncovered →
      9 tiers / 0 uncovered`; `grep -c canary` 0 → 1 (case 1).
- [x] Every mutation asserted **by text**: the writer exits nonzero unless the
      anchor matched exactly once, then `git diff --quiet` and `grep` confirm the
      new text is present before anything is measured.
- [x] Text scan only — no image pulled, no container started, nothing left running.
- [x] `DECISIONS.md` records the trade and the limit, separately from the limit it
      was told to keep.
- [x] `CHANGELOG.md` has an entry with the measurement in it.
- [x] Check label's leading text kept byte-identical so
      `reports/compose-collision/mutations.sh`'s `--only=` still selects it.

## 9. Next

1. Recipes for emptiness findings 1–4, four independent mutations, same harness.
2. A recipe that proves `WRAPPER`'s `[^{}]*` cannot swallow the next function's
   docker — the one property of the new arm with no control.
3. `self_test.sh` breakage for the tier set, if the suite's cost is ever accepted;
   otherwise say so in `AGENTS.md` so the next reader knows the coverage is in
   `reports/`, not in the suite.
4. **Worth a packet on its own:** `deploy_test.sh:163-164` runs
   `docker image rm "${IMAGE_A:-none}-rollback-target"`. The volume rule catches
   `docker volume rm X`; nothing catches the image equivalent, which is the same
   defect in the same shape one namespace over.