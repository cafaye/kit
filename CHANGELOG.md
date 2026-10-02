# Changelog

All notable changes to `kit` are recorded here. kit has no releases yet and no
semver contract — it is consumed by *calling*
`.github/workflows/ci.reusable.yml@master` and by *copying* files out of
`docker/` and `templates/`. `lint/` is the exception and no longer belongs to
that sentence: the reusable workflow reads it at run time, so a service inherits
it without a copy (see kit-12 below).

> Entries under **Earlier**, and the three `workflows/ci.reusable.yml` bullets
> below, record the path the file had *at the time*. It was
> `workflows/ci.reusable.yml` until the move recorded in Unreleased/Changed.

## Unreleased

### Fixed

- **four self-test recipes asserted a string the check does not emit.** All four
  were *correct checks* on *correct mutations* whose recipe could not tell either
  from a failure, and all four reported "the gate went red, but NOT via …" —
  three of them while printing the needle two lines above the complaint.

  `expect_red_check` matches `FAIL $want`, so the needle has to be the check's
  **label**. Breakages 75, 76 and 77 asserted the finding's own wording
  (`"which is the image kit's stack already ships"`, `"promises a command the
  script does not dispatch"`), and those strings are printed as indented detail
  lines *under* the `FAIL <label>` header. Breakage 71 asserted
  `the connection budget  (max_connections covers` against a label that read
  `max_connions` — a misspelling of a setting that does not exist, in the one line
  a reader greps for to learn what a check measures.

  Two consequences beyond the four recipes. The `max_connions` label is corrected
  to `max_connections`, which is the variable the check reads. And a check label
  that a self-test asserts is now a **contract**: renaming one silently un-proofs
  the breakage, which is the same coupling as the `callable path` check and is now
  written down in `AGENTS.md` with the diagnostic to use next time — read the real
  FAIL line before assuming the check missed the defect.

- **the connection-contract check was satisfied by a comment.** It tested
  `if key not in body` over the whole snippet, and the go snippet's header says
  "1. `application_name` — THE ONE THAT IS NOT OPTIONAL". So deleting the single
  line that *sets* it left the substring in the file and the contract reported
  satisfied — and **self-test breakage 72, which performs exactly that deletion,
  was green.** This is the rule AGENTS.md already states about `-count=1` ("a
  check that a comment can satisfy is not a check") arriving in a new place, and
  the only reason it is written down here is that the self-test could not see it:
  the mutation was real, the recipe ran, and the check agreed with the tree.

  All three of the check's tests now read code with the comments stripped, per
  language — `//` for go/node/rust, `#` for python, and for elixir a `#` that is
  **not** `#{`, because interpolation is code and can carry a setting. The
  stripper does not track string literals, which is deliberate and conservative:
  a comment marker inside a string leaves its line scanned rather than eating the
  code after it, so the failure this can cause is a missed setting, never a
  setting wrongly reported absent.

  Fixing it also corrected `contract.json`'s bounded-pool token: it listed
  `:pool_size`, a spelling that existed only in the Elixir snippet's *prose*,
  while the code says `pool_size: @pool_size`. Once the comments stopped
  counting, the token read as absent and named a real defect in the token list.

- **`self_test.sh` classified a caught defect as a machine failure, on a large
  gate report.** The `env_skips` branch added in `1d98e42` tested for a finding
  with `printf '%s\n' "$out" | grep -qE '^(FAIL|SKIP)'` — while the verdict three
  lines above it had been changed to the non-piping `contains` for exactly this
  reason. **The fix was applied to one branch and missed in the one beside it.**

  The mechanism, measured: on a 239KB gate report whose findings sit at the top,
  that pipeline exits **141** *with the match present*. `grep -q` closes the pipe
  on its first match, `printf` dies of SIGPIPE, and `set -o pipefail` promotes 141
  to the pipeline's status — so the verdict flipped on the SIZE of the output
  rather than on what was in it. The threshold is a property of the pipe buffer,
  so it moves with the machine.

  And it fails in the worst direction available: the false answer is "this is an
  ENVIRONMENT failure", which is precisely the verdict that excuse was added to
  stop being lost. Four breakages — 71, and the three this packet adds (75, 76,
  77) — were reported as unevaluated on a run where every one of them had in fact
  been caught, and 72 was reported as "the gate stayed GREEN". Now a `contains`
  call, like its neighbours.

- **`fleet_check.py` no longer reported a clean fleet while five repositories
  carried their own Postgres.** `check_stale_copy` — failure mode 1, the check
  whose entire job is naming a service running its own copy of the shared
  platform — matched a service's image against kit's by **bare repository
  name**. kit-21 made the cluster a *built* image (MD21b), so kit's went from
  `postgres:${KIT_POSTGRES_TAG:-…}` to `kit-postgres:${…}`; a duplicating service
  still writes `postgres`, and the two stopped matching. Measured on the commit
  that shipped it:

  ```console
  $ fleet_check.py --repos-dir <a fleet whose alpha runs postgres:17>
  PASS fleet: no service carries a copy of kit's stack, none weakens the
               redaction boundary, no collector config is dead, …
  ```

  The comparison is now over the **upstream** image kit's stack is built *from*,
  not over the name of the local artefact kit built it into — a service cannot
  know to write `kit-postgres`, which is a build tag that exists on one
  developer's machine.

  It went unnoticed for a reason worth recording, because it is the same shape as
  the bug: self-test breakages 52/59/60 mutate a fixture to carry a stale copy
  **with a `ports:` entry**, and `check_override_surface` reports a published
  port by *service name* — a name the rename never touched. So breakage 60 went
  red on the port half while the image half was dead, and a green control was
  evidencing a different check. New **breakage 75** mutates the same fixture
  *without* the port, so the image comparison is the only thing that can go red;
  it is red on the pre-fix code and green on the post-fix code, both measured.

- **`bin/dev db grant` now exists.** Four files in this repository told a service
  author to run it — `templates/database/README.md`, `DECISIONS.md`,
  `templates/compose/postgres/initdb/10-cluster.sh` and
  `templates/compose/docker-compose.yml` — and `bin/dev` had no `db` command at
  all. Every one of those four is a reader who is told the way out of "my
  service's database was never created" exists, runs it, and gets
  `unknown command`. `DECISIONS.md` was created to stop this repository
  referencing a document that did not exist; this was the same defect one layer
  down, and it is now a check (**breakages 76 and 77**) rather than a fix, since
  the class is "a document names an interface and the interface disagrees".

  The command **prints** the statements and does not run them: they are
  `CREATE ROLE` and `CREATE DATABASE` on a cluster a service is about to be
  handed credentials for, and a wrapper whose failure mode is half-provisioned is
  not something to perform on a stack it did not start. It prints the
  `REVOKE ALL ON DATABASE … FROM PUBLIC` with them, which is the whole point —
  see the next entry.

- **the operator-side half of the isolation boundary is now stated rather than
  implied.** `DECISIONS.md` listed "the `REVOKE` for a database added by hand"
  among the things left to the operator, in one line, as a pointer to a command
  that did not exist. It now says what the position actually is: the boundary
  holds **by construction** for every database declared in
  `KIT_POSTGRES_DATABASES` on a fresh volume, and a database added afterwards is
  **the operator's to close** — because `docker-entrypoint-initdb.d` runs once per
  volume and cannot sweep a database that does not exist yet. A database created
  by hand and not revoked is reachable by every role in the cluster, whatever the
  table grants say. `tests/isolation_test.sh` proves the first half against a real
  cluster; the second is a documented step, and the document now says so where an
  adopter will read it.

### Changed

- **`templates/deploy/compose.deploy.yml`'s comment claimed its Postgres was "the
  same tag `templates/compose/docker-compose.yml` uses", so "a deploy and a
  `bin/dev up` are running the same database."** Both halves became false at
  kit-21: the dev stack moved to `postgres:17` because pgvector is a glibc-linked
  layer (MD21b), and the developer topology became one cluster of N databases
  rather than one database. The tag is unchanged and the deploy file is
  deliberately a *different* topology — one database for one service, with no
  initdb script, no per-service roles and no revoke, because there is nothing to
  isolate it from. The comment now says that, so the two are not "unified" by a
  reader in a hurry.

### Added

- **one Postgres cluster, one database and one role per service, and the database
  is the isolation boundary.** Nine services, one cluster, no pooler. A service
  adds its own name to `KIT_POSTGRES_DATABASES` and gets a role, a database and a
  refused-at-the-door boundary — there is no second container, no second port and
  no second volume, which is the entire point of sharing a cluster.

  `templates/compose/postgres/initdb/10-cluster.sh` provisions one non-superuser
  role and one owned database per name, then applies the boundary by **sweeping
  `REVOKE ALL ON DATABASE … FROM PUBLIC` over every non-template database** in
  the cluster rather than over a list of the ones it created. Measured, and this
  is the load-bearing part: with the revoke, `psql -U courier -d billing` answers
  `FATAL: permission denied for database "billing"` / `DETAIL: User does not have
  CONNECT privilege` before a query is parsed; without it, the connection
  **succeeds** and only the `SELECT` on billing's table is refused — by the
  accident that nobody granted it. A cluster provisioned without the revoke has,
  by Postgres's default, no isolation at all, and fails open silently.

- **`tests/isolation_test.sh` — the proof, not the claim.** Brings the *shipped*
  stack up through compose, creates two service databases and two service roles,
  and asserts service A cannot reach service B's, printing the refused query and
  the server's answer. Four assertions: A reaches its own; A is refused B's; B is
  refused A's (one lucky direction is not isolation); and a **control cluster of
  the same shape with the revoke removed must let A in**.

  The control is the assertion that makes the rest mean anything, and it is
  there because of the rule this repository already applies to allowlists and
  proofs: an assertion that cannot be shown to fail is not known to be
  load-bearing. Without it, a check asserting "A cannot SELECT from B's rows"
  would pass on a cluster with no isolation at all. Wired into the gate's
  observability phase with its own `BOUND` bound (1800s — three container
  lifecycles and two initdb runs), and a loud SKIP when docker is absent.

- **`templates/database/` — the connection contract, published and consumed.** The
  topology is only finished if a service's config actually works against it, so
  the four settings that only matter on a shared cluster are generated per
  language rather than described in a comment:

  | setting | what it prevents on one cluster |
  |---|---|
  | `application_name` | an unattributable query — nine services in one `pg_stat_activity` and no way to say whose |
  | `statement_timeout` | one service's runaway query occupying shared resources |
  | `idle_in_transaction_session_timeout` | one forgotten `BEGIN` blocking `VACUUM` cluster-wide |
  | a bounded pool | one service taking the connections the other eight need |

  Six languages (go, elixir, python, ruby, node — also bun — and rust), each
  parsed by **its own parser** in the gate, and each required to carry the
  contract by `templates/database/contract.json` rather than by a grep repeated
  six times. The cluster sets the two timeouts **per role** as a backstop, so a
  service that forgets them is bounded rather than unbounded.

- **the pooler decision, as a check rather than a paragraph.** kit runs **no
  PgBouncer**: direct connections, `max_connections` raised to 200, a per-role
  `CONNECTION LIMIT`, and per-role timeouts. The argument is in
  `templates/database/README.md` and the measurements in `DECISIONS.md` (MD21); the
  deciding sentence is from PgBouncer's own configuration documentation, which
  describes `RECONNECT` on its admin console as the remedy for
  `ERROR: cached plan must not change result type` after a DDL migration — a
  manual operator step after every schema change in nine repositories.

  The pooler workarounds are **forbidden** in `contract.json` and the gate fails
  the build if one appears in any generated config. A service carrying
  `prepare: :unnamed` on a fleet with no pooler is slower and looks entirely
  correct, so nothing else would ever find it.

- **`DECISIONS.md` — the file seven places referenced and that did not exist.**
  `AGENTS.md` (twice), `README.md` (twice, one of them a markdown link),
  `.github/zizmor.yml`, `ci.reusable.yml` (three times) and three of the gate's
  own scripts all pointed at it. A reference to a decision document that is not
  there tells the reader the trade was made and then leaves them with nothing to
  read — worse than not claiming it, because the absence looks like they have not
  looked hard enough. It now exists, with MD10, MD12, MD13 and the four MD21
  entries this packet decided, and a check asserts it is present, records real
  entries, and that every reference to it resolves.

### Changed

- **the cluster image is `postgres:17` (Debian), not `postgres:17-alpine`.**
  pglayers publishes each extension as a glibc-linked layer built from the PGDG
  Debian packages, and alpine is musl. Measured, on the alpine base: the image
  **builds cleanly** and then `CREATE EXTENSION vector` reports the extension is
  not available, with `ldd` showing `Error loading shared library
  ld-linux-*.so.1`. Two independent failures — the loader cannot resolve a glibc
  binary, and alpine's PostgreSQL looks under
  `/usr/local/share/postgresql/extension` while pglayers writes to
  `/usr/share/postgresql/17/extension`. On `postgres:17` the same layer answers a
  real query. An image that claims pgvector and does not have it is worse than one
  that is visibly missing it.

  The layer is composed rather than pulled: `pglayers-full` would be one line
  instead of four, but it *replaces* the official `postgres` image with a
  community build for every service permanently, and loads 80+ extensions and a
  raised `max_worker_processes` onto the cluster whether or not any is used.
  Trade recorded as MD21b, including that pglayers is a community project and
  **not** a PostgreSQL one — it layers onto the official images, which is a
  weaker claim.

- **extensions are a cluster decision, created by the admin role.** A service role
  cannot `CREATE EXTENSION`: pgvector's control file is not marked `trusted`, so
  a non-superuser is refused with `HINT: Must be superuser to create this
  extension`. Verified against pglayers' layer *and* upstream pgvector v0.8.6,
  whose `vector.control` is byte-identical — this is pgvector's own
  classification, not something the packaging drops. The `SET ROLE` design that
  looked right could not work, and the measurement is why.

- **`lint/hadolint.yaml` ignores DL3067 as well as DL3008.** The cluster image is
  `COPY --from=<layer> / /`, which is pglayers' whole mechanism and has no
  narrower form on PG17. The rule's rationale — an accidental whole-filesystem
  copy pastes in unreviewed files — is answered by pinning a specific published
  version of one extension rather than by the rule.

- **`templates/compose/.env.example` said `KIT_POSTGRES_TAG=16.6-alpine` while
  `docker-compose.yml` defaulted to `17-alpine`, and `.env.example` WINS** —
  `bin/dev` copies it to `.env` on first run, so every developer's stack ran 16.6
  while the compose file, this README and the CHANGELOG all said 17. Commit
  `48689e6` fixed the compose default and left the file that overrides it alone,
  which is the more dangerous half of that fix: it made the repository agree with
  itself and the developer's machine disagree with both.

  Now asserted in **both directions** — a tag in `.env.example` that is not the
  compose default fails, and a compose default that is not that tag fails. A
  check that only asked "is `KIT_POSTGRES_TAG` in `.env.example`" would be
  satisfied by the broken state, because the broken state has it. The check also
  refuses an alpine variant, with the reason. self_test breakage 68 is the shipped
  defect and breakage 69 is the alpine regression.

- **`artifacts.json` documented an `optional` field that no code implemented.**
  "Such an artefact is reported but does not, by itself, make a service look
  broken" — a property stated in the table's own `_about` and asserted in zero
  places, because no artefact in the table used it. kit-21 added the first
  optional artefacts and the reporter turned every one into an unpinned finding
  for every service in the fleet, which is the opposite of what the field says.
  `staleness.py` now implements it, and the exemption is **`absent` only**: a
  `diverged` optional artefact is a copy that has drifted and still needs a pin,
  and an `unknown` one is an unmeasured artefact and inherits the fail-closed
  rule rather than copying it.

### Fixed (previously open in this release)

- **a gate that exited non-zero reporting NO finding was reported as "the gate
  went red, but NOT via `<the named check>`", which blames a check for a machine
  problem.** `expect_red_check` had exactly two verdicts — green, or red-for-a-
  different-reason — and neither of them is true when the nested gate died before
  reporting anything: it is neither a proof the mutation escaped nor a proof the
  check failed to catch, it is a proof that could not be **evaluated**.

  It surfaced on kit-19's own full gate, at load average 15 on a 16GB box:
  breakage 35 came back `exit 1` with an empty finding list and was counted as a
  check that failed to catch a half-adopted language. `validate.sh` exits 1 on a
  FAIL *and* exits 1 from bootstrap when it cannot install its own dependencies
  (lines 132 and 3195), and the second never reaches a single check — so the two
  are indistinguishable from the exit status alone.

  A third verdict now exists, `SKIP`, and it is distinguished from a missing
  toolchain by a **separate counter** (`env_skips` against `skips`) because they
  are two different problems demanding two different responses. Both remain
  fatal: a proof nobody ran is not a proof, and an unevaluated one is not a proof
  either — but neither is reported as a gate defect, so the next reader does not
  go looking for a weakened check that is in fact fine. The summary names the
  count explicitly, because `env_skips` cannot appear in the PASS line at all
  (it is non-zero only on a run that exits 1).

  Verified against all four cases with the predicate isolated from the harness —
  a dead gate with no output classifies as an environment failure; a real red
  naming a *different* check still classifies as a red-for-the-wrong-reason; the
  named check firing is a pass; and green-with-no-finding is still a failure.
  That last one is the point: this widens what counts as an excuse by exactly the
  case where the gate said nothing, and no further.

  Same principle as breakage 39, which asserts the **explanation** rather than
  the exit status for the same reason: a red that misattributes itself sends the
  next reader to the wrong file.

- **`expect_green_check` read a MATCH as a non-match once the gate's output was
  large enough, so breakage 59 reported the adoption ceiling red when it had
  passed.** `printf '%s\n' "$out" | grep -qF` is the SIGPIPE defect
  `expect_red_check` was already repaired for and recorded at length: `grep -q`
  exits at the first match and closes the pipe, `printf` dies 141, `set -o
  pipefail` promotes that to the pipeline's status, and `!` inverts a success into
  a failure. It was latent because the gate's output had never crossed the 64K
  pipe buffer; kit-19's `license_check` printing its measurement on PASS — which
  is what `check`'s own contract asks of a check reporting which spec it
  verified — was the crossing point.

  Reproduced outside the suite to establish the mechanism rather than the
  coincidence: at 5000 lines `grep -qF` returns 141 and the shell `case` returns
  0 on the same input and the same match. The failing run printed the diagnosis
  itself — `printf: write error: Broken pipe` — inside a phase whose output nobody
  reads on a green run.

  **The fix is a `contains` helper** (a shell `case`, no pipe) used by
  `expect_red_check`, `expect_green_check` and `expect_skip_check`. Three correct
  copies were the wrong shape: the failure is a property of how the harness READS
  output and has nothing to do with which check it is reading. Stopping the new
  check printing was the alternative and it was worse twice over — it contradicts
  `check`'s documented behaviour, and the threshold it hides behind is a property
  of the pipe buffer, so it moves with the machine and returns as a flake on
  somebody else's packet. No recipe, threshold or pin changed.

- **`templates/compose/docker-compose.yml` defaulted to postgres 16.6 while the
  rest of the fleet floated at 17.** `postgres:${KIT_POSTGRES_TAG:-16.6-alpine}`
  meant a developer running `bin/dev` with nothing configured got postgres 16.6
  and a different database build from every CI runner in the fleet — which is the
  drift `core`'s `compose.postgres-pin` rule exists to make visible, and which
  it had recorded as a known exception since the rule landed.

  Now `postgres:${KIT_POSTGRES_TAG:-17-alpine}`, so an unconfigured developer
  gets the fleet's build. `core`'s recorded expectation in `tests/test_specs.py`
  and the table in `docs/postgres-pin.md` moved in the same commit as this one,
  because they are one claim stated twice.

  One kit reference to the rule remains and is now recorded rather than fixed:
  `templates/deploy/compose.deploy.yml` carries a `services.app.image` of
  `${KIT_DEPLOY_IMAGE:?the deploy tool sets KIT_DEPLOY_IMAGE}`. It is not a
  postgres image — it is a variable the deploy tool sets at run time — but it
  sits in `services:`, so the rule reads it. It is left visible on purpose:
  suppressing it would teach the rule to skip variables, and
  `${KIT_POSTGRES_TAG:-default}` is exactly the form the rule exists to resolve.

- **kit-17 — `templates/otel/ruby` had no interpreter floor, so the gate blamed
  the template for the interpreter it picked.** `FAIL templates/otel/ruby (ruby
  test suite)` on every gate run on macOS, minitest `.EE.......E..` — three of
  thirteen tests erroring, all three the same `NoMethodError: undefined method
  'filter_map'`, called from `usable_tracestate_entries`.

  **The template was right and the runner was wrong.** `filter_map` arrived in
  ruby 2.7; kit's own pin is 3.4 (`templates/mise.toml`, `lint/rubocop.yml`'s
  `TargetRubyVersion`), and the macOS system interpreter at `/usr/bin/ruby` is
  2.6.10. Every method *definition* in the file parses fine on 2.6, so 2.6 loads
  `traceparent.rb` without complaint and only raises on the first tracestate
  entry — which reads exactly like a bug in trace propagation, and was
  measured as one for three packets' worth of gate runs before anyone read a
  version number. (kit-14 attributed it pre-existing and reproduced it on a
  clean clone of master; this entry is the fix, not the attribution.) The other
  five templates are unaffected: go, node and rustc all *refuse* an old
  toolchain at build time with a message naming their own requirement. Ruby is
  the only one of the six that can fail silently.

  - **`KitOtel::RUBY_FLOOR = '2.7'`, in the file.** Not a sentence in the header,
    because the failure it prevents does not look like a version problem. 2.7 is
    `filter_map` and nothing else — everything else in the file and its suite is
    2.4 or older (`casecmp?` 2.4, `allbits?` 2.5, `&.` 2.3) — so it is the
    file's real requirement rather than a guess, and well below the 3.4 kit hands
    a service.
  - **The gate reads that constant** (`ruby_floor()`) instead of keeping its own
    copy of the number. A version restated in the runner is a second place for it
    to rot, and asking the artifact is the same reason the classifier's tier
    lives in `rules.json` and nowhere else.
  - **A below-floor interpreter is a loud, counted `SKIP`, not a `FAIL`.** The
    template is correct and the interpreter is too old; reporting that red would
    keep three landed-or-landing packets blocked by a red naming a file none of
    them touched. Reporting it `PASS` would be worse — a pass on the strength of
    thirteen tests that never ran. An unreadable floor is still a `FAIL`: that one
    *is* a template defect.
  - **`version_at_least()` — a hand-rolled version comparison.** Not `sort -V`,
    which is a GNU coreutils extension older BSD sort lacks; a floor comparison
    that degrades to a *string* compare on the sort macOS ships reads `2.10` <
    `2.9`. An unparseable field refuses rather than assuming the version is new
    enough — fail-closed, like `tests/classify.py`.
  - **Two new self-test breakages, 23 and 23b, both on a stub `ruby` that
    reports 2.6.10 and refuses the suite.** 23 deletes the floor guard and
    asserts the suite goes red *under its own label*; 23b keeps the guard and
    asserts the gate stays **green** while naming the skip. 23b needed a fourth
    helper, `expect_skip_check`: "the gate went red" cannot express a check that
    is load-bearing precisely by not going red, and "the gate went green" is
    satisfied just as well by a check that was deleted entirely.
  - **Two counting bugs found on the way, both the same shape.** The breakage
    counts in `self_test.sh` and `validate.sh` anchored on `^expect_`, which also
    matches the four helper *definitions* — `expect_red() {` looks exactly like a
    call to a name-only pattern — so both printed **28 over 23 recipes**. And the
    header/recipe check anchored on `^expect_` too, so the indented calls in
    breakages 23/23b (inside a `command -v ruby` guard) were reported as two
    documented breakages carrying no recipe: the check was right about the
    disagreement and wrong about the cause. All three now anchor on the breakage
    *label*, which a function definition cannot carry. `[ \t]*` rather than `\s*`
    in the header check, because under `re.M` `\s` matches a newline and `\s*`
    could span onto the next line and match a label that is not a recipe at all.
  - `self_test.sh` is now **25 breakages — 24 that assert the gate goes red, and
    one (23b) that asserts a green gate with a named skip.** The summary line
    says which is which rather than claiming all 25 "went red", because that
    would be a false statement about a proof that passed.

  Gate on this branch: **143 pass, 0 fail, 2 skip** (both the pre-existing
  `node --check cannot read TypeScript` skips for `templates/tier/{node,bun}`,
  which are a parser gap in a packet that owns it, not this one). All six
  traceparent suites green, `canary_test.sh` green against a real collector.


### Changed

- **kit-12 — lint runs from kit. The `cp` is gone.**
  `lint/` was 249 lines of golangci, rubocop, eslint, yamllint and hadolint
  configuration that **not one service in the fleet had ever copied**, and every
  check in this repository was green the whole time. Adoption correlated
  *inversely* with how much a file did: `uses: cafaye/kit/...@master` is 11/11
  because it is live, and `cp lint/golangci.yml` is 1/11 because a snapshot has
  no propagation and rots silently. So the config moved to where the step already
  is, and adoption becomes 11/11 with no per-service action.

  (The brief this packet answered put those at 8/8 and 0/9. The second is
  stale — `identity` has since landed a `.golangci.yml` of its own on `master`,
  for a reason recorded in `lint/drift-allowlist`. Writing `0/9` here would have
  been a number this work had measured and known to be wrong.)

  - **`kit-lint-ref` and a sparse `lint/` checkout, in the go, ruby and node
    jobs.** The workflow file and the configs are two different things:
    `uses: cafaye/kit/...@X` pins the *workflow*, and a reusable workflow is not
    handed its own ref — so the configs are fetched by name, and the name has to
    be an input. Pin it to the **same** ref you pinned `uses:` to; a caller who
    pins one and not the other gets that SHA's workflow with today's lint
    policy, which nothing detects automatically and is therefore documented in
    the input and in README.md rather than pretended to be automatic.
  - **The ESLint config is checked out *inside* the repository, at
    `<working-dir>/.kit`.** Measured, not preferred: node resolves an ESM import
    from the config file's own directory upward, so a config beside the
    repository finds no `@eslint/js` and the run dies with
    `ERR_MODULE_NOT_FOUND` — a red build that has linted nothing. One location
    serves all three linters.
  - **`lint/eslint.config.mjs` ignores `.kit/**`.** Without it the run is red
    with a parse error about *kit's own* config file, in a service that did
    nothing wrong, on a file the service never wrote.
  - **`lint-args` is the deviation seam**, and it is deliberately narrow: it is
    appended *after* kit's flags, so a service can add and cannot remove the
    `--config`; and it is a string rather than a path, so there is no
    service-side file to rot. What it may not do — change which config is read,
    what is linted, or whether a finding fails the build — is a list of 15
    refused flags enforced by a **`lint-args guard` step in the workflow**, not
    by kit's gate, because `lint-args` is the caller's value and kit has never
    got it. `lint_args_seam_check` asserts the guard is in all three lint jobs,
    that the copies are byte-identical, that it runs *before* the linter, and
    that its token list is the one written in the gate.
  - **ESLint runs directly, not `npm run lint`.** `npm run lint` is whatever
    script the repository happens to define — a repository that defines none gets
    a confusing "Missing script" rather than a lint, and one that defines it is
    running its own config, which is the copy this packet exists to end.

### Added

- **kit-19 — kit carries a licence, and a check that keeps it unambiguous.**
  cafaye's decision is MIT across the fleet, and `kit` had no `LICENSE` at all.
  That is not "unlicensed, therefore free": it is **all rights reserved**, the
  default copyright position when a public repository grants nothing, and it is
  the state `docs`' `licensing.md` names `kit` in. The grant is now the MIT text
  in `LICENSE`, and the README says so in two places — a `### kit's own licence`
  paragraph next to the AGPL one, and a `## License` section a reader looking for
  a licence actually finds.

  - **The check is for AGREEMENT, not for the file's existence, and that is the
    half that matters.** A licence is only unambiguous when exactly one place in
    a repository can declare one. `license_check` asserts the grant by MIT's own
    sentences rather than by the string `MIT` — the identifier is also how a
    badge line, a summary, or a note about some *other* repository's licence is
    spelled, and matching it passes on all three — asserts a copyright holder
    exists, asserts the README states MIT and links the file *in its own section*
    rather than anywhere in the document (the AGPL paragraph names a licence that
    is not kit's, so a whole-file substring search is satisfied by the exact
    conflation the section split exists to prevent), and then walks every root
    manifest that can carry a licence field and fails on any that is not MIT.

  - **It checks agreement, and does not ban the manifest.** A check satisfied by
    "kit has no `package.json`" would be satisfied by deleting one, and would be
    a `FAIL` the day kit legitimately grew one — the same shape as breakage
    31b's control. `templates/` is untouched by design: a licence in a template is
    that template's business, and only the root can be about kit.

  - **Two breakages, `61` and `62`, and 62 is the one that makes it real.** 61
    deletes `LICENSE`, which is the direction everybody can see. 62 writes a root
    `package.json` declaring `AGPL-3.0-only` while `LICENSE` and the README both
    still say MIT: the repository has acquired a third statement about its own
    grant, a compliance tool reads the manifest, and a reader has no way to tell
    which is authoritative. A check asserting only that `LICENSE` exists is
    satisfied by exactly that state, and a manifest is easy to add without
    anybody thinking of it as a licence decision. 62's fixture is **assembled**
    with `printf`, not written out — the same rule as breakages 24, 25 and 33,
    because a probe written out is a probe committed.

  - **`fresh_copy` now copies `LICENSE`.** Without it the new check fails on
    every throwaway copy for a reason that has nothing to do with the defect
    under test, and the two green-expecting proofs (23b, 59) go red for that
    reason. A check that cannot run in a copy is a proof that proves nothing
    while reporting something.

  - **Two counts moved, both in prose rather than in code.** The self-test is
    now 67 breakages, 65 of which must go red, and 47 assert the *named* check.
    `self_test.sh`'s header is checked against the recipes by
    `self_test_claims`, so the header could not simply be left at sixty-five; the
    README and `AGENTS.md` prose is not mechanically checked, which is why it is
    worth saying the numbers were updated in all three places deliberately.

- **kit-13 — the observability stack gets a live path, and a gate that says which
  repositories are not on it.** `templates/compose/` shipped a complete local
  observability platform and **no service used it**: no repository had an
  `otel-collector.yml`, six carried a bespoke 52–158 line
  `docker-compose.yml` whose only infrastructure was a Postgres, and **none**
  adopted `bin/dev`. The stack was built, gated, and running nowhere.

  - **`bin/dev` fetches the stack from a PINNED kit ref** and runs it beside the
    service's own `docker-compose.yml`, which is an override. A compose file
    cannot be `uses:`-ed — GitHub resolves reusable *workflows* and nothing else —
    so `bin/dev` is the callable path and the pin is what makes it one.
    `git init` + `fetch --depth 1` rather than `clone --branch`, because
    `--branch` cannot take a commit sha and so cannot express the stricter of the
    two pin forms.

  - **The pin is `kit.ref`, a committed one-liner — and it was `.env` first.**
    `.env` is git-ignored, so a pin there exists on exactly one machine and on no
    CI runner or teammate's checkout, which turns "one command, always current"
    into "one command, whatever this checkout last fetched". `bin/dev pin <ref>`
    moves it deliberately and prints the stack diff first. A 40-char sha or a
    `v<semver>` tag; a branch is refused **before any network call**, because by
    the time a fetch has returned it has already changed under you.

  - **`KIT_STACK_OFFLINE=1` is a real mode.** It uses only `KIT_STACK_DIR`, the
    cache, or a copy vendored at `.kit/stack` — and fails loudly, naming each,
    when none holds the pin. A cached or vendored tree must RECORD its ref in
    `.kit-stack-ref`; a directory that merely contains `templates/compose/` is
    refused, because accepting one silently is how an offline loop stops matching
    what the team runs.

  - **`tests/fetch_test.sh`** — 14 assertions, executed. A pinned ref resolves and
    the fetched bytes are byte-identical to the tree; a branch, a short sha and
    an empty pin are each refused with a message that says why; offline runs from
    a cache with the remote deleted from disk, fails loudly with a cold one, and
    accepts or refuses a vendored copy by whether it declares the pin. The remote
    is a local `file://` bare repository built from this tree, so the suite needs
    no network.

  - **`tests/stack_live_test.sh`** — 15 assertions, executed, and the reason the
    packet is not "a compose file that parses". It brings the **fetched** stack up
    (all eight containers healthy), sends real OTLP, and reads a trace out of
    Tempo and a metric out of Mimir — including the `spanmetrics` connector's
    `cafaye_duration_count`, which is what the fleet dashboard is built on. The
    canary reaches no exporter, asserted as an absence against a search that first
    proved the data is there. The collector's config is checked by
    `docker inspect .Mounts`: the daemon's own record of the bind, not the host's
    idea of it and not the container's (the image is distroless).

  - **`tests/fleet_check.py`, wired into the gate as `fleet`.** Four failure
    modes, one check each: a service carrying a copy of the shared stack, a
    service that re-points the collector's config mount (the redaction allowlist,
    derived from core's schemas), an `otel-collector.yml` nothing ever mounts, and
    a pin that is a branch. It reads the **sibling repositories**, not kit's own
    files, because the defect is in the callers — the same shape as D4.
    **It is red against the current fleet and that is the deliverable**: five
    repositories carry their own copy of the shared stack, six have no pin, and
    two publish a port on a service kit already ships. The predicate is the
    image, not the service name, and the image set is read out of kit's own
    compose file rather than a hand-kept list — three of the five copies name
    their database `db` rather than `postgres`, so a name-keyed check would report
    the fleet clean while five copies stood right there.

  - **Nine breakages (52–60), eight asserting the NAMED check and one asserting
    the gate stays green while naming its finding.** The fleet ones run against a
    **fixture fleet** rather than the real one — which is what makes the
    assertion mean anything when the real fleet is red by design. Breakage 58
    covers the `ports:` append rule and carries **no `image:`**, so it fires the
    port rule alone: a breakage that reddened two rules at once would not say
    which of them is load-bearing. 59 and 60 are the adoption ceiling's two
    sides and are described below.

- **kit-14 — the staleness reporter, pointed at `templates/`, and the word
  `absent`.**
  kit already had a change classifier and a staleness reporter for `core/`, and
  both work. Both also **only watched `core/`**, while `templates/` — the
  directory that has drifted furthest — was watched by nothing.

  This is not "detect drift in `templates/`". Drift detection assumes a copy
  exists, and in the fleet the copies are gone: of the twelve files in
  `templates/compose/`, the nine services hold `docker-compose.yml` in seven of
  them and **none of the collector, Tempo, Loki, Mimir or Grafana provisioning
  in any of them**. A reporter that only knew `current` and `stale` would have
  nothing to say about the commonest state in the fleet.

  - **`tests/artifacts.json` — the one place kit says what it ships and where a
    service puts it.** Twelve artefacts, the language each applies to, and the
    `compose` bundle's twelve members. Read by the reporter *and* by the gate,
    because a table written down twice is a table that is right in one of the
    two places. `destAlternatives` records the six Dockerfiles that live at the
    repository root rather than at kit's documented `docker/Dockerfile`: a
    documented, working placement is not an absence, and a reporter that cries
    wolf over it is a reporter that gets muted.
  - **`tests/staleness.py --scope templates` — five states.**
    `current`, `diverged`, **`absent`**, `unknown`, and `n/a`. `absent` is the
    new word and the whole reason the packet existed. `unknown` inherits the
    classifier's fail-closed rule rather than copying it: no declared language,
    a symlink where a copy should be, an unreadable file, an artefact kit has
    stopped shipping — each is a finding, because the cheap answer in every one
    of those cases is a guess. `n/a` exists so `unknown` can stay honest; a Go
    service has no `.rubocop.yml` because it is not a Ruby service, and calling
    that unmeasured would put three permanent, unfixable findings on every
    service in the fleet.
  - **A copy is never inferred from its content.** No similarity threshold, no
    percentage, no search for a file that hashes to kit's. A copy is `current`
    when the bytes at the declared path are equal and the path is a real file
    in the service's own tree, and at no other time. Proved by
    `tests/self_test.sh` breakage 37, written as the `quick_ratio() > 0.99`
    patch somebody would write to relax it.
  - **`templates/parity-allowlist` — why a copy is not kit's bytes.** The tier
    skip-allowlist's four hygiene rules in the same words and the same one-line
    dialect, because kit does not have two dialects of "record why". It adds the
    rule the tier file does not need: **an unpinned divergence or absence is a
    failure**, since its entries name copies in repositories the gate cannot
    read, and a record that silently omits a cell reads as "handled". **80
    entries**, and the count is printed on every green run because 80 is a bad
    number and everybody should be able to see that it is one.
  - **Eight new self-test breakages (33–40) and a boundary that finally has a
    check behind it.** 33 is a dead ledger entry (the ESLint shape) and 34 is an
    **expired** one — the first time anything in kit has watched a ratchet fire
    rather than reading that it exists, and it took spending a recipe to find
    that out. 35 is a `{lang}` source kit offers but does not ship: half a
    language is worse than none. 36 reports an `absent` artefact as `current`,
    and 37 grades by resemblance; they are separate because they are opposite
    mistakes, one removing a finding and the other inventing one, and a gate
    that can only do one of them is half a gate. 38 gives one of the two
    programs a third-party import, 39 removes a fixture's `.git` so the
    reporter cannot see it (and asserts the EXPLANATION, not just the exit
    status), and 40 deletes the line that consults the ruby toolchain floor.
  - **Two of those recipes were wrong, and `self_test` is what said so.**
    33 named an artefact id `artifacts.json` really declares, so the mutation
    broke nothing; the recipe now asserts its own premise before it mutates.
    34 asserted that the GATE rejects an entry naming a repository that is not
    on disk — it cannot, because kit's CI has no sibling checkouts and no gate
    here knows which repositories exist. The reporter does know, and
    `staleness_test.sh` proves that case; so 34 was re-pointed at the expiry
    rule the gate really has, rather than kit gaining a fleet roster so the
    gate could answer a question nobody asked it.
  - **`carve-out boundary` — a check, and the sentence it found out of date.**
    `AGENTS.md` has said "standard library only" since the carve-out was made
    and nothing verified it. The new check walks the **AST** of both programs —
    so a function-local import is read the same as a top-level one — and asserts
    that every module it finds is named in the sentence as well as on the list.
    It failed on its first run: `glob` arrived with this packet and `urllib` had
    been imported all along without ever being written down.

- **`tests/staleness.py --scope templates` measured the fleet, and the brief's
  numbers did not survive it.** `README.md` opens
  [what the fleet actually adopted](#what-the-fleet-actually-adopted) with the
  result. The corrections worth stating here: `mise.toml` is 9/9 diverged and
  the divergence is **adoption working**, because the template is the union of
  every language's pins (19 tools) and a service keeps the two it needs;
  `AGENTS.md` is 9/9 diverged and the divergence is the **opposite** — the
  template was superseded, only 12–40 of its 121 lines survive per service, and
  `## Observability` survives in **none** of the nine; and
  `lint/*` is **3 diverged, 3 absent**, not 0/9, because `billing`, `parlor` and
  `identity` each hold a linter config that is their own — none carrying kit's
  STRICTNESS NOTES block. The honest sentence is "nobody lints with kit's
  rules", not "nobody lints".

- **Four numbers in my own first draft were wrong, and all four flattered the
  measurement.** They are corrected above, in `templates/parity-allowlist` and
  in the report, and they are written down here because the pattern is the
  point: a figure that cannot survive being recomputed is a liability in a file
  whose whole job is to be believed.
  - **`AGENTS.md` "8–19 lines with markdown comments stripped".** The template
    has no comments to strip, and normalising the `<...>` placeholders does not
    shrink the diff either — still 315–669 changed lines. The nine are not
    filled-in forms, and this is the artefact where the fleet has the **least**
    of kit's template.
  - **`mise.toml` "8–19 code lines apart".** Not a number this comparison
    produces; the real figure is 80–110, and legitimately so.
  - **`bin/prime` "32 to 63 lines", and "the fleet's versions begin `#!/bin/sh`".**
    The range is 12–58. Only `caf` and `courier` use that shebang; `darkroom`,
    `muse` and `parlor` use kit's own, and **`identity/bin/prime` has no shebang
    at all**. All seven reasons asserted it; it was true for two. `billing`'s
    is not stale either — it carries the STRICTNESS NOTES block and is 12 lines
    from kit's ruby template, with Rails commands added.
  - **`billing/bin/dev` "predates kit's observability profile, brings up postgres
    and nats only".** It is two lines: `#!/usr/bin/env ruby` and
    `exec "./bin/rails", "server", *ARGV`. A Rails server shim, not a copy of
    kit's loop in any era. The claim was inferred from a line count rather than
    read off the file.

- **One of my own sentences was wrong, which is why it is here.** The first draft
  of `REPORT-kit-14.md` and of eight ledger entries said a partially-adopted
  compose stack "cannot start". Checked with `docker compose config`: it does
  not. None of the six services' compose files mounts any of kit's stack files,
  each declares one or two services of its own, and five of six pass validation
  — they are **replacements that kept a filename**, not broken copies. The
  reporter now says what it measured ("partially adopted: N of 12 members
  held") and stops there, because comparing bytes cannot tell a replacement from
  a broken copy.

- **A defect the byte-comparison cannot see, found while checking the sentence
  above.** `muse/docker-compose.yml` **does not parse**: an unquoted
  `${MUSE_VAULT_KEY:?…, or run: …}` whose error message contains a colon, and
  YAML reads the value as the start of a mapping. `docker compose config` fails
  with `yaml: line 65, column 67`. The reporter calls that cell `diverged`,
  which is true and is not the interesting thing about it; the ledger entry for
  `muse` now says so.

- **kit-16 — the first deployment, and the shape the other eight copy.**
  Nine services, nine languages, nine green gates, and not one of them had ever
  been deployed: there was no `deploy/` or `infra/` directory anywhere in the
  organisation and no ruling that mentioned production deployment. This is one
  reference deployment, run end to end, with the differences between the nine
  runtimes tabled rather than papered over.

  - **`templates/deploy/` — the distribution shape.** `compose.deploy.yml` is a
    real, runnable file rather than a template with holes in it: every value is
    a compose substitution, so it runs once `SERVICE_NAME` and
    `KIT_DEPLOY_IMAGE` are set. No `build:` section, `restart: unless-stopped`
    on every service, a healthcheck on every service, and **no credential
    anywhere in the file** — which is the property that shapes everything else.

  - **`templates/bin/deploy.sh` — the tool**, beside `dev.sh`, the other script
    kit hands out. `up` / `verify` / `rollback` / `status` / `down`. A deploy
    does not report success until the container's own healthcheck says
    `healthy`; a deploy that cannot reach green **rolls itself back** rather
    than leaving a broken version quietly replacing a working one.

  - **Credentials arrive on an inherited file descriptor and nowhere else.**
    There is no `--secrets-file`; `deploy` refuses the option by name. Values
    go into a **tmpfs** (RAM, per container, destroyed with the container)
    through the container's own stdin, so they never appear in `docker
    inspect`, in `docker compose config`, on the host disk, or in the image.
    The container starts and the application does not: `entrypoint.sh` waits
    for `/run/secrets/.loaded`, which the tool creates only once every claimed
    secret is in place, and **exits non-zero if it never arrives**.

  - **`templates/deploy/redact.py` — the log redactor.** Everything the tool
    prints is filtered: `docker inspect`, `docker compose config`, migration
    output, the health gate's own messages. Two layers — the exact values it
    was given, and **shape** (JWT, bearer token, AWS key, provider key, GitHub
    token, connection URL with a password, PEM header, any `*password*`/
    `*secret*`/`*token*` assignment) — because a filter that only knows its own
    inputs is defeated by anything it did not already hold. The credential's
    *name* survives, so the log still says which one was in play.

  - **`templates/deploy/reference/courier.deploy.yml` — the reference
    deployment**, and the thing this packet actually ran. `courier` (Elixir/
    Phoenix, 535 tests at `35c6a27`) was chosen over `caf` deliberately: it
    already has a release build and a readiness endpoint that really checks
    its database, so the template is written against the best story in the
    fleet rather than the worst. `caf` was rejected because a bug in its deploy
    path carries the authority to destroy shared Docker state.

  - **Rollback that is demonstrated, not described.** The previous artifact is
    recorded in a ledger (image tags and digests only — no secrets) *before*
    the new container starts, and `deploy rollback` runs the same deploy code
    path with a different tag and the same health gate.

  - **`tests/deploy_test.sh` — 66 assertions in nine sections, no sleeps.**
    Every health gate is demonstrated red **and** green: the database is taken
    away underneath the running service (`docker pause`, not `stop` — stopping
    the container destroys its tmpfs, so restarting it brings the database back
    *without its password* and tests the wrong thing), and `/readyz` is watched
    going 503, the container healthcheck is watched going unhealthy, and
    `deploy verify` is watched exiting non-zero; then all three are watched
    coming back. `/healthz` is asserted to stay 200 throughout, because a
    liveness probe that fails on a dependency turns a database blip into a
    crash-restart loop. The leak audit runs last, against the accumulated
    deploy log, the rendered compose config and `docker inspect`, and asserts
    the secret is present in the container's tmpfs so the negatives are real
    negatives.

    Two further sections close claims that would otherwise rest on reading the
    source. One deploys a **deliberately broken artifact** — the good image minus
    `/app/bin/migrate`, so the two differ by exactly the thing under test — and
    requires the deploy to report failure, to say it is rolling back, and to
    leave the previous artifact serving. The other creates a **decoy container
    and volume outside the compose project** and requires both to survive `down`
    *and* `down --purge`, so "never touch state you do not own" is executed
    rather than grepped for; it goes red if `cmd_down` ever grows a prune.

    **13 static proofs run without Docker; the 53 live ones SKIP loudly when the
    daemon or the image is absent, never silently.**

  - **The polyglot table, and why it is a table.** `docker/Dockerfile.go` and
    `docker/Dockerfile.rust` are `gcr.io/distroless/static` — **no shell, no
    coreutils** — so a shell-script secret gate cannot be mounted into them at
    all. The tool asks the container rather than the operator and switches to
    a tar streamed over `docker cp` when there is no shell, with the `.loaded`
    barrier as an extra tar member so a distroless service gets the identical
    guarantee; measured end to end against a distroless image carrying one bare
    binary and deliberately no `/bin/sh`. Separately, a `curl` healthcheck needs
    `curl`, and **the `-slim` runtimes ship neither `curl` nor `wget`** — a
    shell they do have, measured on `python:3.13-slim`. So each service writes
    its healthcheck in its own runtime's HTTP client, or, for distroless, in
    exec-form against a `healthcheck` subcommand the service itself provides.
    Migrations are a per-service label rather than a rule, because
    `bin/rails db:migrate`, `manage.py migrate` and `/app/bin/migrate` have no
    common form and Go and Rust have no schema at all.

  - **The database is pinned `postgres:17-alpine`**, the fleet's standard tag and
    the one `templates/compose/docker-compose.yml` already uses, so a deploy and
    a `bin/dev up` run the same server. Measured rather than assumed: `/bin/sh`
    (busybox), `pg_isready`, uid 0 and `docker-entrypoint.sh` on `PATH` — and no
    `curl`, with `wget` present, which is why the database's health probe is
    `pg_isready` and not an HTTP fetch. It runs behind the same secret gate as
    the application, because a `POSTGRES_PASSWORD` in `environment:` is a
    password `docker inspect` prints.

- **kit-15 — a check that fails when an adopting repository carries a workaround
  for a fixed core defect.** `core`'s gate checker had two defects that forced
  repositories which adopted `gate.yml` into local workarounds: **D12**
  (`RUN_KEY` could not see a one-line `run:`, fixed in core `63fd319`) and
  **D13** (a proof matched against bytes still carrying ANSI colour, fixed in
  core `c63af27`). Both are fixed, and a workaround for a fixed defect is not
  neutral — it is a second, local, unpolicied copy of a decision that now lives
  in core, and it is the kind that rots. A `gate.yml` carrying a hand-rolled
  escape-tolerant regex is now **weaker** than one without it: the escape runs
  absorb characters a stricter pattern would have rejected.

  - **`tests/gate_declaration_check.py`** — sweeps the adopting repositories for
    three shapes, each of which is *structural* rather than a keyword: a
    `proof[].match` carrying an escape token (D13), a `run:` block scalar whose
    entire body is the declared argv and nothing else (D12), and a comment
    naming a checker-internal term while claiming a `run:` spelling the checker
    cannot see (D12). It does **not** prescribe a `run:` spelling — doing that
    would be a second copy of a decision core owns, and `courier`'s block scalar
    is correct for three real reasons.
  - Wired into `tests/validate.sh` as `adopting repositories (no workaround for
    a fixed core defect)`, with the fleet root discovered beside the repository
    and a reported SKIP when there is none — the same treatment the
    core-allowlist check already gets, for the same reason.
  - **Three breakages in `tests/self_test.sh` (24-26)**, over a synthetic fleet
    built in the work directory, because kit is one repository and the fleet is
    fifteen. All three name the check they expect to go red, and the control is
    now the check's *positive* case: a sweep that has only ever run against a
    red fleet has proved it can fail and nothing about whether it is right.
  - `cafaye-rb`'s primary checkout is **red on this check today**, which is the
    check working: it carries the D12 workaround and the comment justifying it.
    It is fixed on `worker/kit-15-restore` and this is the report's evidence
    that the sweep found it.

  **The first version of the checker was a keyword scan and it cried wolf** —
  4 repositories, 24 findings, nearly all false, including `core/gate.yml` for
  the sentence "That is MD12's collect-then-run machinery" (`D12` is a substring
  of `MD12`) and `caf`'s declaration for comments arguing that a workaround is
  now *unnecessary*. Both fixes came from reading every comment it flagged, and
  both narrowed the check rather than loosening it. A check that fires on
  correct work teaches the reader to ignore it, and it had taught on the first
  repository scanned.

- **kit-12 — the gate now knows whether a linter ran.**
  - **`tests/lint_test.sh` (a sixth phase, `lint`, deliberately outside the
    `RUN_STATIC` guard).** Four linters are **executed** against a throwaway
    service built to violate exactly one rule, with kit's config, each paired
    with a control that must answer differently. `lint/` spent its whole life
    behind a parse check — `yaml.safe_load` on `golangci.yml`, `node --check` on
    the eslint config — and both are green on a file no linter has ever been
    pointed at. This phase is the only thing that tells a working config from a
    valid one, and it is **fatal on a skip**: the claim under test is "kit's
    configs work", and a run in which no linter executed has not tested it.
  - **`lint drift`, which reads BOTH files and reports the DIFFERENCE.** A
    service carrying a `.golangci.yml` that disagrees with kit's is told which
    linters it dropped or added. Banning the file was the first version and it is
    worse than the drift: a config that agrees with kit's has reached the same
    policy by another route, and failing it teaches the lesson that kit's config
    is a thing you get shouted at for having. Self-test breakage 31b asserts the
    agreeing copy **passes**, so the check cannot be satisfied by deleting it.
  - **`lint/drift-allowlist`**, for a difference that cannot be deleted yet:
    reason, owner, `since`, `until`, and four rules of which the fourth is the
    load-bearing one — **an entry that no longer describes a real difference
    fails**, modelled on ESLint's `reportUnusedDisableDirectives`. One entry is
    live: `identity`, whose `.golangci.yml` enables no linter and exists only to
    exclude one generated file.

### Fixed

- **A promise this repository made in a comment, with no control behind it.**
  The `lint-args` input's own description said `lint_wiring_check` "fails on
  exactly that string" for `--no-config`, and `lint_wiring_check` had no such
  assertion anywhere in it. The reason it *could* not have one is worth
  recording: `lint-args` is the **caller's** value, and kit's gate never sees
  it. So the control moved to where the value is — a `lint-args guard` step in
  every lint job — and kit's gate now asserts the guard exists, is identical in
  all three jobs, runs before the linter, is handed the variable, and still
  refuses all 15 flags. A comment promising a check is worse than no comment:
  the second one stops the reader looking for the first.
- **A claim this repository made about golangci-lint, before running it.** The
  drift check was written on the belief that a repo-root `.golangci.yml` is
  discovered "ahead of any flag the workflow passes", so a stale copy silently
  hijacked CI. **That is backwards.** `golangci-lint run -v` prints exactly one
  `[config_reader] Used config file`, and with `--config` it names kit's; a local
  config that disables `misspell` does not survive it, and RuboCop agrees. A copy
  does not hijack the build — it **splits** the policy, because every other
  invocation in that repository reads it while CI reads kit's, and it becomes
  live again the instant the flag is lost. That is still a finding, and it is the
  honest one. `GOLANGCI_LINT_CONFIG` **is** confirmed unread in v2, as claimed.
- **An allowlist rule that was red on a correct tree.** "An entry that no longer
  describes a difference" treated a repository that was *not in this checkout's
  fleet* as one that had stopped differing, so every run on a copy of kit — which
  is what `self_test.sh` does, twenty-odd times — reported the whole allowlist as
  dead. The rule is now scoped to repositories the run actually looked at; an
  entry naming one that was not looked at is reported as **unverified**, which is
  neither a pass nor a failure.


- **kit-08 — kit-04 landed on a master that had moved, without losing a check
  or a number.** `worker/kit-04` (secrets: gitleaks over full history, a
  runtime-leak canary, zizmor) branched before kit-05 and kit-07 and renumbered
  its breakages from the same base of 18 that master did. A textual union of the
  two files carries **34 recipes with four labels used twice** — 19, 20, 21 and
  22 — and `self_test_claims` compares the documented set against the carried
  set *as sets*, so the duplicates collapse silently and the check reports an
  agreement that does not exist.
  - Master's numbering is canonical and did not move. kit-04's **six language
    mutants** were dropped, not renumbered: they are master's 13–18 byte for
    byte, and a second copy would prove the same six rules twice under two
    names. kit-04's **eleven unique breakages** moved to **41–51**.
  - `tests/validate.sh`: 45 check sites on master, 34 on kit-04, **59
    merged** — twenty of the sites are shared verbatim, which is why the union is
    less than the sum. Both sides' checks survive, and what proves it is the
    *label* set rather than the count: every label on either side is still present
    in the merged file, except two that were resolved deliberately —
    `collector_check`, which is one function whose label disagreed (master's
    fuller revision won) and whose kit-04 version was an earlier, smaller copy of
    the same function; and the `self_test` invocation site itself, which is the
    union documented below.
    Master's `collector_check` also *subsumes* the part of kit-04's that is not
    superseded: `receivers` and `batch` are asserted per signal rather than for
    `traces` alone. The rest is deliberately gone — kit-04's "the traces pipeline
    ships to no non-local exporter" described the pre-fan-out stack, whose only
    exporter was `debug`, and it would go red against the tempo/loki/mimir
    fan-out master now ships. Keeping it would have been a check that fails on a
    correct tree, which is worse than no check.
  - The `self_test` invocation site now takes the union of both: `check_verbose`
    (kit-04's — the list of breakages that went red *is* the evidence, and a
    plain `check` prints one line and throws the rest away) with master's
    counted label. The count is `grep`-derived in both files from the same
    expression.
  - One mechanism replaced two: `self_test.sh` had a runtime `breakages=$((…))`
    counter *and* the grep. The counter also decremented itself on a skipped
    language, so a machine missing a toolchain would print a *lower* total than
    the file contains — which reads as though proofs had been dropped rather
    than as a missing prerequisite.
  - **The renumbering was left in two visible states, and both are fixed here.**
    The recipes ran `1`–`18`, then `41`–`51`, then `19`–`22`, so the file did not
    read in the order its own header documents it. Recipes `19`–`22` now sit
    between `18` and `41`, and the file runs in label order.
  - **`41`–`51` no longer share variable names with `19`–`22`.** The renumber
    rewrote the labels and left the variable names behind, so breakage `47` was
    still called `nineteen`; master's `19`–`22` then bound those same four names
    to a second directory. It worked only because each was read before the next
    write. Those eleven variables are now named for what they break.
  - **There is no breakage 23, and it was never a lost recipe.** The block moved
    by `+11`, carrying kit-04's `23` — the zizmor `unpinned-uses` baseline — to
    `51`. The gap is now documented where a renumber script will read it as a
    bug, and README states the scheme.

### Fixed

- **The gitleaks gate was red on kit-16's JWT canary, and the allowlist was empty
  by design.** `.gitleaks.toml` carried no `[[allowlists]]` entry because kit's own
  history scanned clean — but the gate runs `git log --all`, and every worker in
  this fleet is a worktree of one shared repository, so `--all` reaches
  `worker/kit-16-deploy`'s commit `924b725`: a `jwt` finding on
  `tests/deploy_test.sh` line 155. It is a fixture. kit-16's deploy story proves
  the redactor scrubs a token the deploy never supplied, and a canary built from a
  name the filter already knows would prove nothing — so the token is committed
  and the `jwt` rule fires on it. **The scanner did the one thing it is for.**
  The entry is the narrowest the config format allows — `targetRules = ["jwt"]`
  with `paths = ['''^tests/deploy_test\.sh$''']`, and `condition = "AND"`
  written out rather than left to the default, which is **OR**
  (`config/config.go`, `parseAllowlist`: an empty `condition` maps to
  `AllowlistMatchOr`) and would silently make the entry a union the day somebody
  adds a second criterion. Measured in a throwaway repository, both directions: a
  `jwt` in that file is suppressed, while a `generic-api-key` in the **same file**
  and a `jwt` in a **different file** are both still reported.
  - **The canary was re-proved after the entry was added**, because allowlisting a
    canary is only honest if the canary can still fail. `redact.py`'s JWT pattern
    weakened from `\.[A-Za-z0-9_-]{4,}` to `{99,}` in a scratch export of
    `worker/kit-16-deploy`, and `tests/deploy_test.sh` went red on **exactly one**
    claim — "the redactor left a JWT in the output" — with its other 16 green.
    Reverted, and the scratch copy is byte-identical to the branch.
  - **The better fix is kit-16's, and it is recorded as such.** The canary could
    be assembled at run time from a prefix, the way `templates/secrets/` already
    does, which is the pattern that exists so this file never needs an entry. That
    branch is not merged here. The entry is written so it decays: if kit-16 stops
    committing the string it matches nothing, and the next reader deletes it.
  - **The scan was not narrowed.** `--all` is what catches a secret that only ever
    existed on a branch, and it is the reason this finding was ever visible: on a
    single-branch clone the canary is invisible and the gate is green.
  - **README now says to delete the entry when copying the file.** kit's config is
    copied verbatim into thirteen repositories, and this entry names
    `tests/deploy_test.sh`, which none of them has. A `paths` allowlist matching
    nothing excuses nothing, so it cannot weaken a service's scan — but an entry
    whose reason is only true of the repository it came from is how the next reader
    learns that descriptions are optional in practice. gitleaks cannot report a
    dead allowlist entry the way `templates/tier/skip-allowlist` reports a dead one
    there, so the obligation is the reader's, and the README is the only place it
    can be stated.
- **`templates/otel/ruby` is red on master, and this merge neither caused nor
  fixed it.** Three `NoMethodError`s for `Array#filter_map` (Ruby 2.7+,
  `traceparent.rb:278`) under `/usr/bin/ruby` 2.6.10. Re-derived rather than
  inherited: `run_ruby` is byte-identical to master's, `git diff master --
  templates/otel/ruby/` is empty, and `git archive master` into a clean directory
  reproduces `3 errors` with master's own template and master's own runner —
  while the pinned `ruby 4.0.1` gives `1407 assertions, 0 errors`. The
  1370-vs-1407 gap is the tell: an interpreter too old to define a method does not
  skip assertions, it aborts the three tests that reach it. kit-14 has the real fix
  on `worker/kit-14-stale` (a `toolchain_floor_ruby` feature probe that FAILs
  naming the toolchain, proven by its breakage 30 — which is **breakage 40** on
  this branch); that branch was not merged when this was written.
  Not fixed here: it is pre-existing, it does not reproduce on this box's `PATH`,
  and a fix for a red I cannot see is a change I cannot verify. Rewriting
  `traceparent.rb` to avoid `filter_map` is recorded as the fix that is not the fix
  — it makes the gate green on an old interpreter by removing what the suite
  exists to exercise.
- **`expect_red_check` reported a proof as failing when the check it named was
  the one that fired.** The matcher was `printf '%s\n' "$out" | grep -qF`, and
  under `set -o pipefail` a writer that takes SIGPIPE makes the whole pipeline
  non-zero — so `grep -q` exiting at its first match turned a **hit** into a
  miss. Deterministic on output size, not on load: below the 64KB pipe buffer the
  assertion is correct, at or above it, `printf` is killed mid-write. Breakages
  **11** (hadolint) and **42** (the working-tree credential) both exceed it and
  were both reported as *"the gate went red, but NOT via `<the check that fired>`"*
  while printing that check among the FAIL lines it had just proven present.
  Now a substring test on the already-captured `$out`: no pipe, no SIGPIPE, and
  the assertion no longer depends on how much the gate prints. The same defect
  and the same answer were already recorded in `tests/canary_test.sh` for
  `docker logs | grep -q`.
- `tests/validate.sh` and `templates/secrets/go/sweep.go` cited breakages by their
  **kit-04** numbers — `15` for the `--redact` removal (now `43`) and `21` for the
  marshalling canary (now `49`). Both are the renumber's fallout, and both
  pointed a reader at the wrong recipe.
- Count drift in the prose, all of it second-hand rather than measured: `AGENTS.md`
  said *twenty-three* breakages in one place and *thirty-four* in another, *eight*
  named checks against the real **nineteen** (+2 over proof scripts = twenty-one),
  and *nineteen ways* in its own pre-commit checklist. `README.md` and
  `tests/self_test.sh` both counted the named proofs as *twenty* against the
  **nineteen** their own lists enumerate. Every one of these is a copy of the
  truth taken by hand, which is the failure the derived count exists to prevent.
- `tests/self_test.sh`'s header described the thirty-four breakages as *18 from
  the fan-out work, 17 from the tier work, 11 from the secrets work, 12 shared* —
  58, for a file that carries 34.
- A section comment read `# 47-22.` where the canary vectors are `47`–`50`: the
  renumber script's arithmetic leaking into prose.
- **Two of the thirty-four proofs were dead, and the renumber is what killed
  them.** Giving breakages `41`–`51` descriptive directory names named breakage
  50's copy `canary_literal` — which was already the name of the canary **value**
  assembled six lines below it. The recipe reassigned the variable to the value,
  so `edit` was handed `cafaye_canary_…/templates/secrets/go/canary.go` and died
  with a `FileNotFoundError`. Breakage 50 never ran, and because the script stops
  at the first crash neither did 51: *"the canary is committed as a literal"* and
  *"the zizmor config baselines unpinned-uses"* had silently stopped being
  tested, and the run died before printing its summary. Restored to `kit-04`'s
  naming, where the directory was `twentytwo` and the value `canary_literal`.
  Nothing about reading the file shows this — both lines are correct in
  isolation, `bash -n` is happy, and the header/recipe agreement below is
  perfect while both are wrong — so `self_test_claims` now also asserts that no
  throwaway-copy directory variable is ever reassigned.
- **kit-07 — the declared tier, and the allowlist that is supposed to shrink.**
  A tier is a class of test that needs a real dependency. The failure this
  exists to prevent has already happened in this fleet: a green run in which the
  whole database tier never executed once, because the suite printed `ok`.

  - **`templates/tier/<lang>/` — the declaration, per language, for all seven.**
    Declared in the test source and read by the runner's own collector, never
    grepped for a sentinel. A sentinel fails *open*: a test reaching Postgres
    through a helper two files away does not match Identity's
    `dbtest.Pool|Schema|EnvVar|TEST_DATABASE_URL`, so its package never enters
    the required list and the run is never required to contain it. Rust
    (`#[ignore = "cafaye:tier=db reason=…"]`), Go (`//go:build tier_db`) and
    Python (`@pytest.mark.tier_db`) have a collector that already exists. Ruby
    gets a `tier :db` macro, Elixir a `@tier :db` attribute, and Node and Bun an
    exported `TIER` const — each a **no-op at runtime**, so the collector is a
    ~15-line adapter rather than a parser.
  - **Two collector claims measured, and both corrected the prior claim.**
    `cargo test -- --list --format json` is **nightly-only** (`-Z
    unstable-options`, rustc 1.95.0) — on stable, `--list` includes ignored
    tests and `--list --ignored` gives the ignored subset, which between them
    carry everything the JSON would have. `--list --include-ignored` lists
    *everything* and filters nothing. And `bun test --reporter=junit` **does**
    emit a full inventory: a filtered-out test is still a `<testcase>`, so the
    absent-testcase failure mode does not occur there. What bun lacks is a
    declared *reason* — `test.skip` takes none.
  - **`templates/tier/README.md` — the normalised result format**, the three-way
    `ran` / `skipped` / `filtered` distinction JUnit XML cannot express, the
    allowlist rules, and **what a tier gate cannot catch**. A package filtered
    out of the run entirely is the sharpest: the test asserting the tier ran
    lives *inside* the tier and cannot observe its own absence. Only the
    inventory-vs-run set difference catches it, and that is `caf gate`'s.
  - **`templates/tier/skip-allowlist` — one file for the fleet**, with four
    hygiene rules: every entry names a **reason**, an **owner**, a `since` and a
    `until`; and **an entry matching nothing is a failure**. That last rule is
    modelled on ESLint's `reportUnusedDisableDirectives`, which reports a
    disable comment that no longer suppresses anything. Without it an allowlist is
    a ratchet that only turns one way, and within two quarters it contains every
    test in the repository. The **total is printed on every run, green included**
    — individual entries look justified; the aggregate is the problem.
  - **`required-tier` on the reusable workflow.** Demanded, not inferred: the
    caller names the gate variable (`REQUIRED_DB`) and the workflow exports it
    as `1` on every language job's test step — guard's `GUARD_REDIS_REQUIRED`
    pattern, which fails at *tier-invocation* time, before a report exists. A
    `tier demand` step then fails **naming the variable** if the run produced no
    `ran` line, because a gate variable that is set while a tier runs zero tests
    is a green build that verified nothing. Opt-in: the default is `''`.
  - **`-count=1` mandated on the Go job.** Go keys its test cache on the
    environment a test reads, so a gated and an ungated run already have
    different cache keys — genuinely good news — but mandating the flag removes
    the question rather than reasoning about it, and it costs nothing.
  - **Never cache a test report**, documented in README with the reasoning:
    `restore-keys` matches by **prefix**, and the default branch's cache is
    documented as available to other branches, so a key built from
    `hashFiles('**/lockfile')` restores a report written by a run that *had* the
    database into a run that did not. **A witness from a different run is not a
    witness.** Also stated: fork PRs get read-only cache access, which is a
    cross-trust-boundary path into the gate in any workflow using
    `actions/cache` today.
  - **Floors are relabelled as decrease detectors.** Identity's
    `1254/1166`-style floors are kept and are cheap at catching deletion, but a
    floor is satisfied by *any* 1254 tests including the wrong 1254. Calling one
    a tier gate is worse than having none.

- **`core/` — the `cafaye/core` fan-out standard.** Six repositories copy bytes
  out of `core` and nothing makes the copy reach them. This ships the standard
  that does, plus the two runnable pieces that make it enforceable:
  - `core/vendir/vendir.yml.{muse,pantry,caf}` — the three real consumers, in
    three languages. `muse` and `pantry` are **proven byte-identical (sha256)**
    to what those repositories have committed today, by running vendir 0.46.2
    against the real `cafaye/core`. `caf` **cannot migrate as-is** and its banner
    says why: vendir has no rename, `caf` holds the bytes as
    `manifest-0.2.json`, and core publishes them as
    `cafaye.manifest.schema.json`.
  - `core/vendir/vendir.yml.template` — the onboarding template. Four things to
    change, each marked, each with the reason it is easy to get wrong.
  - `core/renovate/renovate.json5` and `core/renovate/SETUP.md` — one
    `inheritConfig` policy for the fleet, and the ordered steps to stand it up
    **including what to verify before onboarding a second repository**.
  - `core/release/release.yml` — what `core` needs to be taggable. Ships here;
    belongs in `core/.github/workflows/`.
- **`tests/classify.py` + `tests/rules.json` — a change classifier that fails
  closed.** `self_test.sh` proves twenty-three synthetic breakages go red; it
  cannot prove a future change to `event-envelope.schema.json` is one of them. So
  a difference between two vendored schema sets is classified into
  `FILE`/`PACKAGE`/`WIRE_JSON`/`WIRE` (buf's four tiers, because *pick the
  category that matches what your consumers actually depend on*), and **anything
  the catalogue does not name is `UNRECOGNISED`, which is the strictest tier**.
  A new JSON Schema keyword arriving in core cannot be auto-merged green by
  omission. The escape hatch is fenced: a rule may set `breaking: false` only for
  an operation in the closed `advisoryOps` list, or the catalogue refuses to
  load.
- **`tests/staleness.py` — the fleet staleness reporter.** Reads every consuming
  repository's recorded pin — a `vendir.lock.yml` sha *or* the hand-bumped
  `CORE_REF`, because three repositories still use the second — resolves where
  `core` is now, and prints the distance. `--fail-on-behind` makes it a gate;
  `--fail-on-behind` is *off* by default because a stale copy is legal and a
  scheduled report that is red every week is a report that gets muted. Run
  against the real working tree it reports the first measured fleet fact:
  **`muse` is nineteen commits behind**, and `caf` and `pantry` hold vendored
  bytes with **no recorded origin at all**.
- **Three new self-test breakages (18 → 21 at the time of writing; 23 after
  the merge with the tier work).** `includePaths` nested under
  `git:`; the classifier made to **fail open**; the staleness reporter calling an
  undeclared pin `current`. The second is the sharpest proof in the file: it
  inverts the fail-closed property and asserts the suite notices.
- **A check for a file type kit was already shipping unlinted.** The vendir
  templates are YAML under non-`.yml` names, so the `git ls-files '*.yml'
  '*.yaml'` sweep skipped them — and a service that copies one greets its first
  CI run with a failure nobody authored. They are linted by name now.
- **Two new `classify_test.sh` cases that exist to keep the gate honest rather
  than red.** An advisory change must be *reported and not fail*, and a
  reordered `required`/`enum` must not break `FILE` — JSON Schema defines both as
  sets, so a reorder is provably not a semantic change. A gate that goes red on a
  cosmetic edit trains the first person who hits it to reach for the gate rather
  than the cause, which is how a fail-closed gate becomes a fail-open one.
- `core/README.md` records what the fan-out measurement actually found, which is
  **not** what the design was briefed on, and states plainly what stays unproven
  until the first real tag moves.

-
 
*
*
k
i
t
-
0
5
 
m
e
r
g
e
d
 
o
n
t
o
 
a
 
m
a
s
t
e
r
 
c
a
r
r
y
i
n
g
 
t
h
e
 
t
i
e
r
 
w
o
r
k
:
 
t
w
o
 
`
f
i
`
s
 
l
o
s
t
,
 
a
n
d
 
t
h
e


 
 
g
a
t
e
 
w
o
u
l
d
 
h
a
v
e
 
l
i
e
d
.
*
*
 
B
o
t
h
 
s
i
d
e
s
 
o
f
 
t
h
e
 
m
e
r
g
e
 
p
u
t
 
t
h
e
i
r
 
n
e
w
 
c
h
e
c
k
s
 
i
n
s
i
d
e
 
a


 
 
`
R
U
N
_
*
`
 
c
o
n
d
i
t
i
o
n
a
l
,
 
a
n
d
 
`
g
i
t
 
m
e
r
g
e
 
-
-
u
n
i
o
n
`
 
d
r
o
p
p
e
d
 
t
h
e
 
c
l
o
s
i
n
g
 
`
f
i
`
 
o
f
 
*
t
w
o
*


 
 
d
i
f
f
e
r
e
n
t
 
b
l
o
c
k
s
.
 
O
n
e
 
w
a
s
 
c
o
s
m
e
t
i
c
;
 
t
h
e
 
o
t
h
e
r
 
p
u
t
 
k
i
t
-
0
5
'
s
 
`
c
l
a
s
s
i
f
y
_
t
e
s
t
.
s
h
`


 
 
a
n
d
 
`
s
t
a
l
e
n
e
s
s
_
t
e
s
t
.
s
h
`
 
*
*
i
n
s
i
d
e
*
*
 
`
R
U
N
_
O
B
S
E
R
V
A
B
I
L
I
T
Y
`
,
 
s
o
 
a
 
r
u
n
 
w
i
t
h


 
 
o
b
s
e
r
v
a
b
i
l
i
t
y
 
d
i
s
a
b
l
e
d
 
w
o
u
l
d
 
h
a
v
e
 
s
i
l
e
n
t
l
y
 
e
x
e
c
u
t
e
d
 
n
e
i
t
h
e
r
 
—
 
a
n
d


 
 
*
*
`
b
a
s
h
 
-
n
`
 
p
a
s
s
e
d
 
t
h
r
o
u
g
h
o
u
t
*
*
,
 
b
e
c
a
u
s
e
 
t
h
e
 
f
i
l
e
 
w
a
s
 
s
t
i
l
l
 
*
b
a
l
a
n
c
e
d
*
.
 
A


 
 
s
y
n
t
a
x
 
c
h
e
c
k
 
i
s
 
n
o
t
 
a
 
s
t
r
u
c
t
u
r
a
l
 
c
h
e
c
k
,
 
a
n
d
 
t
h
i
s
 
i
s
 
t
h
e
 
s
e
c
o
n
d
 
t
i
m
e
 
t
h
i
s
 
f
l
e
e
t


 
 
h
a
s
 
t
a
k
e
n
 
a
 
g
r
e
e
n
 
f
r
o
m
 
a
 
c
h
e
c
k
 
t
h
a
t
 
c
o
u
l
d
 
n
o
t
 
s
e
e
 
t
h
e
 
d
e
f
e
c
t
.


-
 
*
*
k
i
t
-
0
5
'
s
 
c
l
a
s
s
i
f
i
e
r
 
a
n
d
 
s
t
a
l
e
n
e
s
s
 
p
r
o
o
f
s
 
s
h
i
p
p
e
d
 
w
r
a
p
p
e
d
 
i
n


 
 
`
i
f
 
[
 
"
$
R
U
N
_
S
T
A
T
I
C
"
 
-
e
q
 
1
 
]
`
,
 
u
n
d
e
r
 
a
 
c
o
m
m
e
n
t
 
s
a
y
i
n
g
 
t
h
e
y
 
"
r
u
n


 
 
u
n
c
o
n
d
i
t
i
o
n
a
l
l
y
,
 
b
e
c
a
u
s
e
 
b
o
t
h
 
a
r
e
 
t
h
e
 
p
r
o
p
e
r
t
y
 
r
a
t
h
e
r
 
t
h
a
n
 
t
h
e
 
s
h
a
p
e
.
"
*
*
 
T
h
e


 
 
c
o
d
e
 
a
n
d
 
t
h
e
 
c
o
m
m
e
n
t
 
s
a
i
d
 
o
p
p
o
s
i
t
e
 
t
h
i
n
g
s
,
 
a
n
d
 
t
h
e
 
c
o
d
e
 
w
a
s
 
t
h
e
 
o
n
e
 
t
h
a
t
 
r
a
n
.


 
 
T
h
e
y
 
a
r
e
 
n
o
w
 
u
n
c
o
n
d
i
t
i
o
n
a
l
,
 
a
n
d
 
t
h
e
 
r
e
a
s
o
n
 
i
s
 
r
e
c
o
r
d
e
d
 
a
t
 
t
h
e
 
c
a
l
l
 
s
i
t
e
:
 
a


 
 
c
h
e
c
k
 
t
h
a
t
 
o
n
l
y
 
p
a
r
s
e
d
 
t
h
o
s
e
 
t
w
o
 
f
i
l
e
s
 
w
o
u
l
d
 
p
a
s
s
 
o
n
 
a
 
c
l
a
s
s
i
f
i
e
r
 
t
h
a
t
 
w
a
v
e
s


 
 
e
v
e
r
y
 
c
h
a
n
g
e
 
t
h
r
o
u
g
h
,
 
s
o
 
s
k
i
p
p
i
n
g
 
s
t
a
t
i
c
 
a
n
a
l
y
s
i
s
 
m
u
s
t
 
n
o
t
 
b
e
 
a
b
l
e
 
t
o
 
r
e
m
o
v
e


 
 
t
h
e
 
p
r
o
o
f
 
t
h
a
t
 
t
h
e
 
c
l
a
s
s
i
f
i
e
r
 
f
a
i
l
s
 
c
l
o
s
e
d
.


-
 
*
*
`
s
e
l
f
_
t
e
s
t
.
s
h
`
 
s
a
y
s
 
t
w
e
n
t
y
-
o
n
e
;
 
t
h
e
 
f
i
l
e
 
p
r
o
v
e
s
 
t
w
e
n
t
y
-
t
h
r
e
e
.
*
*
 
B
o
t
h
 
s
i
d
e
s
 
o
f


 
 
t
h
e
 
m
e
r
g
e
 
c
a
r
r
i
e
d
 
a
 
c
o
u
n
t
 
t
h
a
t
 
h
a
d
 
d
r
i
f
t
e
d
,
 
a
n
d
 
`
v
a
l
i
d
a
t
e
.
s
h
`
 
r
e
c
o
m
p
u
t
e
d
 
i
t


 
 
w
i
t
h
 
a
 
p
a
t
t
e
r
n
 
t
h
a
t
 
*
*
o
m
i
t
t
e
d
 
`
e
x
p
e
c
t
_
r
e
d
_
s
c
r
i
p
t
`
*
*
 
—
 
w
h
i
c
h
 
i
s
 
w
h
y
 
k
i
t
-
0
5


 
 
h
a
r
d
c
o
d
e
d
 
`
2
1
`
 
i
n
s
t
e
a
d
 
o
f
 
c
o
u
n
t
i
n
g
.
 
T
h
e
 
p
a
t
t
e
r
n
 
n
o
w
 
c
o
v
e
r
s
 
a
l
l
 
f
o
u
r
 
h
e
l
p
e
r
s


 
 
(
`
e
x
p
e
c
t
_
r
e
d
`
,
 
`
_
c
h
e
c
k
`
,
 
`
_
l
a
n
g
`
,
 
`
_
s
c
r
i
p
t
`
)
,
 
t
h
e
 
h
e
a
d
e
r
 
r
e
a
d
s
 
t
w
e
n
t
y
-
t
h
r
e
e
,


 
 
a
n
d
 
t
h
e
 
c
o
m
p
o
s
i
t
i
o
n
 
i
s
 
s
t
a
t
e
d
 
i
n
 
b
o
t
h
 
f
i
l
e
s
:
 
*
*
8
*
*
 
n
a
m
e
d
-
c
h
e
c
k
,
 
*
*
6
*
*


 
 
p
e
r
-
l
a
n
g
u
a
g
e
 
m
u
t
a
t
i
o
n
,
 
*
*
2
*
*
 
p
r
o
o
f
-
i
n
v
e
r
s
i
o
n
,
 
*
*
7
*
*
 
w
h
o
l
e
-
g
a
t
e
.
### Changed

- **`templates/compose/docker-compose.yml` — the vendor config mounts are anchored
  to `${KIT_COMPOSE_DIR:-.}`.** The file is no longer copied into the service, so
  a bare `./` resolves against the service, where `otel-collector.yml` no longer
  is; and Docker's answer to a missing bind source is to **create a directory**, so
  all four backends died with `read /etc/tempo/tempo.yaml: is a directory` —
  naming a file type rather than the thing that is wrong. `docker compose config`
  renders the same project either way, and every static check was green. The
  default `.` is the directory holding this file, so a hand-copied stack is
  unchanged; `bin/dev` sets the variable to the fetched tree.

- **`templates/compose/docker-compose.yml` — Grafana no longer downloads a plugin
  on first boot** (`GF_INSTALL_PLUGINS_PREINSTALL_DISABLED=true`). Grafana 11.3
  preinstalls `grafana-lokiexplore-app` and holds the sqlite lock its own
  migrations want, so a cold start took anywhere from 26s to over **180s** to
  answer `/api/health` — a network call in a dev loop, and one that made the stack
  unstartable for an air-gapped developer. Nothing kit ships uses that plugin:
  both dashboards read Loki through the provisioned datasource and the alert rules
  are PromQL. It is *configuration*, not a modification — the AGPL condition is
  about not building a `grafana/*` image. **The Grafana healthcheck budget was
  left at its shipped value**: the wrong fix, raising the retries, would have hidden
  the network dependency and left the loop unusable offline. With the cause
  removed, Grafana answers at ~26s against a 65s budget and the whole stack is up
  in 76s.

### Fixed

- **`expect_red_check` reported a successful match as a failure, once the output
  was large enough.** It read the checker's verdict through
  `printf '%s\n' "$out" | grep -qF "FAIL $want"`. `grep -q` exits the instant it
  matches, so `printf` takes SIGPIPE while still writing; `set -o pipefail` then
  reports 141 for a pipeline that **succeeded**, and a passing breakage reads as
  "the gate went red, but NOT via `<the named check>`".

  It surfaced on breakage 25, whose check emits several hundred lines and is
  therefore the first output in this file big enough to overflow the 64K pipe
  buffer. Breakages 7-24 all pass on smaller output, which is the worst shape a
  latent defect can have: it presents as a failure of the thing under test while
  being a failure of the harness reading it. Measured rather than reasoned
  about — 2000 lines of output still returns 0 and 5000 returns 141, same match,
  same grep. The threshold is a property of the pipe buffer and would move with
  the machine, so the fix is to **stop piping** (a `case` pattern) rather than to
  bound the output.
- **A check that a comment could satisfy.** The `-count=1` assertion was a plain
  substring test over the go step's `run:` body, and that body's own comment
  block names the flag twice while explaining why removing it would be a
  mistake — so deleting the flag from the command left the check green. Found by
  deliberately breaking the tree, not by reading it. `strip_shell_comments`
  now removes comments while preserving `#` inside quotes, and it is applied
  wherever a check greps a `run:` body.
- **`templates/tier/go/*.go` was never gofmt'ed, and nothing checked it.** The
  gofmt check covered `templates/otel/go/*.go` only, so the new tree shipped
  with doc headings Go 1.19 would rewrite. It is checked now, over both trees.
- **`python3 -m py_compile` wrote `__pycache__/` into the template tree**, and
  the two checks that walk `templates/tier/<lang>/` then died with
  `IsADirectoryError` — a gate that went red on its own artefacts. The parse is
  now `compile()`, which is the same check with no filesystem side effect, and
  both checks skip non-files and *report* a stray directory rather than
  crashing on it.

- **kit-03 rebased onto a master that moved nine commits underneath it.** The
  branch point was `badcc2a`; master gained the move of the reusable workflow to
  `.github/workflows/` (`d42aebb`), kit calling its own workflow (`fb664a9`), a
  real Dockerfile parser and two real Dockerfile bugs (`9a8c3d7`), the gate
  bootstrapping its own dependencies (`a1cad0d`), and the hadolint asset rename
  from `darwin-*` to `macos-*` (`9b3dbeb`). Five files conflicted and all five
  were resolved as unions rather than as a choice between sides:
  - `tests/self_test.sh` — the breakage list is **19**, not master's 18 and not
    kit-03's 12. Master's 7-10 (four ways to break the documented `uses:` string
    against the real path), 11-12 (the two Dockerfile defects) and 13-18 (one
    semantic mutation per language) are intact, and kit-03's `2b` and its
    rewritten recipes for 2 and 4 are kept. Picking a side would have deleted a
    check that currently works, and the self-test's claim is that every breakage
    is caught by a *different* one.
  - `tests/validate.sh` — kit-03's `observability` phase, the `dev_escape_hatch`
    execution check, the eleven observability checks, and master's `callable path`
    check, `tests/bootstrap.sh` wiring and the whole-tree `yamllint` are all
    present. kit-03's own walk of `templates/compose` was **dropped as
    redundant**: master's `yamls_of_the_tree` enumerates by `git ls-files` and
    reaches the same files plus the rest of the repo, and two loops over one set
    of files report every problem twice and disagree about which is
    authoritative.
  - `AGENTS.md`, `README.md`, `CHANGELOG.md` — both sides' entries, with the
    breakage counts updated to 19 and the CHANGELOG's two `### Added` sections
    folded into one.
  - The collector and compose work was re-pointed at `.github/workflows/`
    rather than reintroducing the old path, and `fb664a9`'s local self-call is
    untouched.
- **The self_test count was a hardcoded string in two places, and both were
  wrong the moment either side added a breakage.** `self_test.sh`'s summary line
  and `validate.sh`'s check label now both **count** the recipes, so the number
  cannot drift from what the file proves. A new check asserts that every
  breakage the header documents has a recipe and every recipe has a header
  entry — the union requirement stated as an assertion, so the next packet that
  adds a breakage without documenting it (or documents one without writing it)
  gets a red gate instead of a stale sentence.

### Added

- **The observability stack** (PLAN.md §7b). Observability is ON BY DEFAULT and
  worked on in dev: `bin/dev up` brings up the OTel collector and the four LGTM
  backing services, and a service with nothing configured exports into them
  because `<SERVICE>_OTEL_ENDPOINT` *defaults* to the collector that ships with
  the stack. `<SERVICE>_OTEL_ENDPOINT` is the only contract (core D16); the
  shipped collector is just its default value, and unsetting it is a genuine
  no-op implemented with `OTEL_SDK_DISABLED`.
  - `templates/compose/otel-collector.yml` — OTLP **and** container-stderr
    receivers, the redaction allowlist **derived from core's schemas**, the
    `spanmetrics` connector, and fan-out to Tempo/Loki/Mimir. Every endpoint is
    a `${env:...}`; the gate fails on a literal.
  - `templates/compose/{tempo,loki,mimir}/` and
    `templates/compose/grafana/provisioning/` — vendor **configuration** and
    Grafana provisioning as files: three datasources, the dashboard provider, two
    dashboards and three alert rules, all working on first load.
  - `templates/compose/docker-compose.yml` — the four backing services, pinned
    to exact tags, healthchecked, memory-bounded, in an `observability` profile.
    **Grafana, Loki, Tempo and Mimir are AGPL-3.0 and ship UNMODIFIED**;
    `tests/validate.sh` fails on a `build:` stanza on any of them.
  - `templates/compose/.env.example` — every `${KIT_*}` the stack reads, with
    the port block documented.
  - `tests/canary_test.sh` — plants a canary in ten shapes a leak could take
    against a real collector and asserts it reaches no exporter, **and** that the
    allowed data survived.
  - `tests/no_telemetry_in_readiness.sh` — proves a service starts, serves and
    reports healthy with the collector killed, and that a collector whose three
    backends all refuse connections stays healthy, does not restart and does not
    enter a retry loop.
  - The six `templates/otel/<lang>/*.snippet` files now honour
    `<SERVICE>_OTEL_ENDPOINT`, default to the shipped collector, implement the
    free no-op with `OTEL_SDK_DISABLED`, record `error.type` and never
    `error.message`, and emit **exception log records** rather than the
    deprecated `exception` span event.
  - `templates/AGENTS.md` — an Observability section, so the endpoint contract
    and "telemetry is never in a readiness path" reach the service repo where a
    probe would actually be written.

- **The secret scanner.** A `secrets` job in `ci.reusable.yml` running
  **gitleaks 8.30.1** over the adopting repository's **full history**, with
  `--redact`. It is the one job in the workflow with **no opt-in**: an opt-in
  security control is not a control, and a secret scanner that only warns is a
  report. `fetch-depth: 0` is load-bearing — the runner default is a shallow
  clone, and a secret committed and deleted in one PR is still in the packfile
  of anyone who cloned. **Adopting this can turn a repo's first build red**;
  README says what to do, and the first thing to do is rotate.
  - gitleaks rather than trufflehog: trufflehog is **AGPL-3.0**, and it is the
    only candidate that verifies live credentials against the issuer's API,
    which for a fleet whose CI has network access is the wrong behaviour for a
    scanner. gitleaks is MIT, a static binary, and makes no network call.
  - `tests/gitleaks_gate.sh` is the **one** scan, called by both the `secrets`
    job and `tests/validate.sh`. A scanner whose CI and local invocations have
    drifted is two scanners, and the one that goes red is whichever nobody runs.
  - `.gitleaks.toml` — the allowlist, and **nothing else**. `extend.useDefault`
    so the rules stay gitleaks', and every `[[allowlists]]` entry must carry a
    `description` of at least 40 characters. An allowlist that grows and is never
    pruned is not an allowlist, it is a deferred disclosure. A `.gitleaksignore`
    fails the gate.
- **A `zizmor` job** (opt-in, `zizmor: 'true'`), running the GitHub Actions
  security audit on the adopting repo's own workflows. `tests/zizmor_gate.sh`
  counts `unpinned-uses` and prints the count and the reason on every run, and
  **fails on every other audit**. It is recorded, not baselined: see
  `DECISIONS.md` (MD10a), where the pin trade is costed in three options and none
  of them has been taken.
- **`templates/secrets/`** — the runtime credential-leak canary. A
  **language-neutral contract** (`templates/secrets/README.md`) and the **Go
  adapter**, with five vectors each carrying its own red proof: log/stdout/stderr,
  unknown serialisation fields, the whole error chain, keys present-but-empty,
  and Go type coverage.
  - It exists because **nothing off the shelf does this**. gosec's
    `credentials.Match` has no `*ast.CallExpr` case, so it finds literals and not
    a token passed to a logger. Bandit matches `ast.Constant` only. Brakeman's
    secret check is off by default. Of 268 Semgrep taint rules, **zero** intersect
    CWE-532.
  - The canary is **assembled at run time**, never written as a literal, so it is
    safe to commit and needs no allowlist entry. Two checks enforce that.
- **Ten new checks** in `tests/validate.sh` for the above, including one that
  asserts the scanner's **behaviour** by executing it: over a throwaway git
  repository holding a detectable credential, the scan must find it, must name
  the rule that fired, must not print the value, and must still find it after the
  file is deleted.
- **Eleven new `self_test` breakages**, each asserting that one *named* check
  went red: a credential in history, a credential in the working tree,
  `--redact` removed, the scan narrowed to the last commit,
  `pull_request_target` added, the `secrets` job made `continue-on-error`, four
  ways of breaking the canary's reference type, the canary committed as a
  literal, and `unpinned-uses` baselined in `.github/zizmor.yml`.
  - These were numbered 13–23 on `worker/kit-04` and are **24–34** here.
    kit-04's other six breakages (its 24–29) were its copies of the six language
    mutants, which master already carried as 13–18; those copies are dropped
    rather than renumbered, so no rule is proved twice under two numbers. The
    union is **34 breakages**, master's 1–23 unmoved.
  - `self_test` counts itself by grepping its own recipe calls, the same
    expression `validate.sh` uses for its label, so the summary and the gate
    label cannot disagree. It was a literal `18` in two files kept in step by
    hand, and for one commit a second runtime counter beside it.
- `tests/gitleaks_gate.sh` and `tests/zizmor_gate.sh`, `chmod +x` and asserted
  executable — they are run by the reusable workflow from a service's repository,
  so a missing executable bit is a `secrets` job that dies in thirteen repos.

### Fixed

- **`artipacked` (9 findings) in `ci.reusable.yml`.** Every `actions/checkout`
  now sets `persist-credentials: false`. No job in the file pushes, so a token
  left on disk after a checkout is a credential that outlives the job for no
  reason — and every job here runs `upload-artifact`, which is the combination
  the audit exists to catch. Found by zizmor, and fixed rather than baselined.
- **`.github/zizmor.yml` is no longer walked for stray copies of the workflow.**
  The `callable path` check reported `tests/self_test.sh` as "a second workflow
  declaring `workflow_call`" — it names the key in a comment explaining breakage
  8. A check that fires on the file proving it wrong is a check people delete.
- **Fetched tools now land in `tests/.bin/`, not `.venv/bin/`.** `.venv` is
  gitignored and `tests/self_test.sh` copies the tree twenty-nine times per run,
  so hadolint and gitleaks were being re-downloaded once per copy. The copy
  carries `tests/.bin`; it does not carry `.venv`.
- **The self_test control run no longer fails on a missing executable bit.**
  `cp -R` does not preserve mode bits on macOS, so every throwaway copy arrived
  with `tests/*.sh` non-executable and the new handed-out-scripts check failed in
  all of them — for a reason that had nothing to do with any breakage under test.

### Changed

- `tests/requirements.txt` pins **`zizmor==1.30.1`**, and an auditor is pinned
  where a parser is not: a new release adds findings, and a gate whose result
  depends on when it last ran is a gate nobody can reason about. zizmor comes
  from PyPI rather than a release archive because it publishes no checksums file,
  and pinning its archives would mean pinning hashes we computed ourselves.
- `kit_bootstrap_binary` takes an asset-name template and an inner-path, so it
  can install a tarball as well as a bare binary, and its sha256 table is keyed
  by **exact asset filename**. It used to be keyed by `macos-arm64`, which forced
  every caller's asset name to be derivable from `<name>-<os>-<arch>` — true for
  hadolint, false for gitleaks, and the reason this function could not install a
  second tool. There are now three spellings of the OS name in play
  (`macos`/`darwin`/`apple-darwin`) and all three are mapped explicitly.
- The `callable path` check's copy-walk skips `.bin` and shell scripts.

### Earlier

- A **`callable path` check** in `tests/validate.sh`: the reusable workflow
  exists at the path callers are documented to use, it declares
  `on: workflow_call`, every real `uses:` that names kit — in `README.md`,
  `AGENTS.md` and this repo's own workflow files — is exactly that path,
  `kit`'s own CI calls it with the local `./` form, and there is exactly one
  copy of it in the tree. The failure it exists for: for six months the file
  sat at `workflows/ci.reusable.yml`, the README told every reader to call
  `cafaye/kit/workflows/ci.reusable.yml@master`, GitHub resolved that to
  nothing, and **every check in the suite was green throughout**. A layout bug
  and a documentation bug that agree with each other are invisible to any check
  that reads only one of them.
- `tests/bootstrap.sh` — the gate now installs its own dependencies.
  `bash tests/validate.sh` is the **whole procedure on a clean clone**: it
  resolves an interpreter, builds `.venv` and pip installs
  `tests/requirements.txt` on first run, printing a `note:` line. `AGENTS.md`
  and the README no longer instruct anyone to run a two-line step first.

  This was the second time the gate failed on arrival. It exited 1 with
  `no python with PyYAML: pip install -r tests/requirements.txt` on every fresh
  clone and every CI runner, because it preferred the gitignored `.venv` and
  fell back to a `python3` that has no PyYAML. The prerequisite was documented,
  which is exactly why it got skipped: by every runner, and by anyone who
  cloned without reading the file first.
- `yamllint` now lints **every** YAML in the tree, enumerated by `git ls-files`
  rather than a hand-kept list of the two compose templates, and a missing
  yamllint is a `FAIL` instead of a `SKIP`. kit ships the config and a repo
  that copies it lints its own CI against it on day one, so a YAML that breaks
  the config greets the first adopting repo with a failure nobody authored. A
  skip here would hide a broken config behind a missing tool on precisely the
  machine that had not run the gate before.
- **`lint/hadolint.yaml`, and real lint on all seven Dockerfiles.** They were
  the only artifact in the tree with no parser at all — seven `SKIP ... (no
  parser for this file type)` lines, honest and completely uncovered, on a file
  every adopting service inherits. They now get three layers: hadolint
  (required, pinned to 2.15.1, verified against hadolint's published
  `checksums.sha256`); a non-root / no-`:latest` / no-`ADD` check for the two
  properties hadolint cannot see; and a check that each template's own
  STRICTNESS NOTES state the non-root guarantee to the reader deciding whether
  to adopt the file.

  **hadolint found a real defect on its first run.** `docker/Dockerfile.python`
  ran `pip install uv` with no version, so the resolver's own version decided
  what every build resolved to — an unpinned build input in the one image whose
  whole point is a frozen resolution. Now `ARG UV_VERSION=0.5.11`, in step with
  the `uv` pin in `templates/mise.toml`.

  **The third check found a documentation bug in the same run.**
  `Dockerfile.bun`'s STRICTNESS NOTES said *"The official image has no
  unprivileged user, so we create one."* `oven/bun:1.3.12-slim` ships `bun` at
  uid 1000 (verified against the running container) and the `useradd` that note
  described was never in the file — the note described a different Dockerfile
  than the one being read. Three of the seven said nothing about non-root at
  all; all seven say so now.
- The one ignored hadolint rule is DL3008 ("pin apt versions"), argued in
  `lint/hadolint.yaml` rather than assumed: a hardcoded `build-essential=12.9`
  in a template thirteen repos copy is a version thirteen people must remember
  to bump, and the day Debian drops that build every one of them fails at once —
  a correlated outage caused by a security patch landing. A service that wants
  reproducible apt resolution pins in its own repo, which is the
  "callers override, they never fork" rule.
- `expect_red_check` in `tests/self_test.sh`, which asserts that one *named*
  check reported `FAIL` rather than merely that the gate went red. Breakages
  7-10 use it, so the check written for each layout/documentation drift is
  proven load-bearing instead of being one of forty checks that could have
  gone red for an unrelated reason.
- `.github/workflows/ci.yml` — kit calling its own reusable workflow with
  `uses: ./.github/workflows/ci.reusable.yml`. The repository that defines the
  standard is now the first repository held to it, and if the callable path ever
  breaks again it is red on kit's own commit rather than discovered by the
  first service that adopts it.
- A `none` value for the `language` input, and a `none` job that runs the
  calling repository's own `tests/validate.sh`. **This is a bug fix, not a
  feature.** The workflow was uncallable by any repository without a service
  manifest — which includes `kit`. `language` is `required: true` and every
  value in `options` named a toolchain, so `uses: ./.github/workflows/ci.reusable.yml`
  had no input that could make it resolve. The job fails when `tests/validate.sh`
  is absent, because a config gate with no gate in it is the same defect as a
  coverage threshold left at `0`.
- `workflows/ci.reusable.yml` — a `bun` job: `bun install --frozen-lockfile` →
  `bun run typecheck` → `bun test`, with an opt-in coverage step. Exists because
  `guard` was hand-rolling a whole workflow for want of one; a repo that adopts
  it can collapse that file to a `uses:` call.
- `workflows/ci.reusable.yml` — an opt-in `telemetry` input (string, default
  `'false'`) and a `telemetry` job that runs the W3C traceparent conformance
  suite for all six languages in a matrix. Opt-in so that adopting kit never
  turns a green repo red.
- `docker/Dockerfile.bun` and `templates/bin-prime/bun.sh` — the other two
  artifacts a language ships, so `bun` is a first-class `language` value.
- `templates/bin/dev.sh` — the local developer loop. `up --wait`, migrate, seed
  an admin, print the URLs. Idempotent; fails loudly and stops *before*
  migrating rather than half-starting.
- `templates/compose/otel-collector.yml` — receiver, batch processor, and a
  `debug` exporter that writes to the collector's own stdout. Sends nothing
  anywhere, by default and by gate. **Superseded by kit-03** below: the
  collector now fans out to Tempo, Loki and Mimir, because observability is on
  by default. The `debug` exporter and the "no literal endpoint" rule stay.
- `templates/otel/<lang>/` — per language: a stdlib `traceparent.*` codec, an
  executed conformance suite, an SDK wiring snippet with a documented
  "when to use which" README, and a statement of the W3C sections implemented.
- `templates/otel/pins.md` — the OTel versions the snippets reference, at the
  otel root because it covers all six languages. kit vendors nothing.
- `README.md` — sections for the local stack and for trace propagation,
  including a worked example of a service adopting propagation, and an accurate
  description of what the gate actually does.


### Fixed

- **`tenant_id` was silently stripped from every trace and log resource.** The
  `redaction/cafaye_metrics` processor listed the private stash names
  (`cafaye.stashed.tenant_id`, `cafaye.stashed.account_id`) in its
  `ignored_keys`; `redaction/cafaye_traces` and `redaction/cafaye_logs` did not.
  The redaction processor deletes every attribute it does not exempt, so on
  traces and logs it deleted the carrier the restore was about to read, and the
  restore put `tenant_id` back from an empty source. Per-tenant metric totals
  worked; per-tenant trace and log identity did not, with no error anywhere.
  **Every static check passed on the broken tree** — being *stashed* and being
  *exempted* are different questions and only the second survives contact with a
  running collector. Two assertions added: every private stash name must be
  exempted in all three processors, and the three `ignored_keys` lists must be
  equal.
- **The collector's `_total` rename never fired, so every dashboard panel
  rendered "No data".** `transform/cafaye_metrics_labels` matched
  `IsMatch(name, "\\.calls$")` inside a YAML *single-quoted* scalar, where a
  backslash is not an escape — so OTTL received a regex requiring a literal
  backslash and it matched no metric, ever. The processor was wired in and
  documented at length. The pattern now avoids escapes entirely.
- **Every Grafana panel had `"datasource": null`**, which Grafana resolves to the
  *default* datasource — Mimir. All LogQL panels and the TraceQL panel were being
  sent to a Prometheus API and rejected (`parse error: unexpected character:
  '|'`); 12 of 15 panel queries were invalid. The alert rules grouped on
  `otel.status_code`, which is a parse error in PromQL because OTLP ingestion
  mangles dots in label names to underscores. Both fixed, and a check now holds
  it: every query must name the backend that can answer it, and every PromQL
  expr must use the underscored spelling.
- **`tests/self_test.sh` had two breakages whose recipes no longer applied.**
  `edit` correctly refuses a stale pattern, so the gate went red on breakage 2
  and never reached 3, and then again on 4. Both recipes rewritten against the
  shipped config; a twelfth breakage added covering a *missing* backend
  exporter, which the set-difference check could never have seen.
- **`tests/no_telemetry_in_readiness.sh` proved less than it claimed.** It passed
  bare `host:port` to the `otlphttp` exporters, which made the collector exit(1)
  with `endpoint must be a valid URL` — indistinguishable from the bug the test
  exists to catch. Its stand-in service was `traefik/whoami`, which ships no
  `wget` (so the probe never ran) and answers every path with 200 (so its
  `/readyz` could never fail). Replaced with a real two-service stack whose
  `/readyz` is proven to go 503 before the "still serving" claim means anything.
- **The canary's redaction receipt was flaky, 1 pass in 3.**
  `docker logs ... | grep -qi` under `set -o pipefail` is a SIGPIPE race: `grep -q`
  exits at the first match, so `docker logs` dies with 141 whenever the log is
  large enough to still be writing. The log is now captured to a file. The
  spanmetrics assertion had the same shape — the connector flushes on its own
  interval — and is now polled with a deadline. Both are PASSes, not NOTEs.
- **The local compose stack could not start.** `otel-collector.yml` resolves its
  values from the collector's own process environment, and Docker Compose does
  not inject the `.env` values it substitutes into containers. Every one resolved
  empty and the collector exited with `processors::memory_limiter: ... must be
  greater than zero`, which names a memory limiter rather than the missing
  environment. The nine `KIT_OTEL_*` values are now passed into the collector
  container. The stack parses, passed every check kit had, and did not work.
- The compose **port check** flagged the collector's in-network bind addresses
  (`0.0.0.0:4317`) as hardcoded published ports. It now reads the parsed
  `ports:` lists, so it can tell a published port from a bind address, and its
  failure message names the service and the value.
- The elixir conformance suite failed 2/13 on two tests that called
  `.outbound_headers` as map access on a struct with no such field, where the
  rest of the file uses the local `outbound/1` helper.
- The elixir "new identifiers are random" test rebound its `seen` set inside a
  `for` comprehension, shadowing the outer binding. The uniqueness assertion
  compared 256 draws against an empty set and could never fail.


### Changed

- **The port block.** Every published host port moved into **15000-15999**,
  one hundred per service: 15000 Grafana, 15500 Postgres, 15600 NATS client,
  15700 NATS monitoring, 15800 Redis, 15900 Tempo, 15901 Loki, 15902 Mimir. Not
  5432/4222/6379, which are the two or three most likely things already
  listening on a developer's machine — and `bin/dev` is the first command a new
  person runs. The gate asserts membership of the block and no reuse, as a RANGE
  rather than a list, so adding a service does not mean editing a check.
  **Unverified against the rest of the fleet**: the block is claimed
  fleet-wide and nothing coordinates it across repos. A sibling repo's scratch
  container was observed holding 15500 during kit-03's own verification.
- **`templates/compose/otel-collector.yml` no longer ships `debug` only.** It
  fans out to three backends now, so the privacy boundary is restated as what it
  can actually be: every endpoint a `${env:}`, the exporter set exactly those
  three plus the local `debug`, and a `redaction/*` processor in every pipeline
  before `batch` and therefore before every exporter.
- `templates/bin/dev.sh` — `STACK_TIMEOUT` 120s → 180s (five more containers,
  four with a real initialisation), brings up the `observability` profile by
  default, prints the wall-clock, and prints the observability URLs. The
  escape hatch is `KIT_DEV_PROFILES=`.
- `templates/compose/docker-compose.yml` — the collector's healthcheck probes
  its real `health_check` endpoint instead of printing its component list, and
  the four stores' healthcheck budgets were raised after measuring them.
- `tests/validate.sh` gained an `observability` phase and a `--no-observability`
  flag; both docker-requiring proofs SKIP loudly when docker is absent.

- **The reusable workflow moved to `.github/workflows/ci.reusable.yml`.** It was
  at `workflows/ci.reusable.yml`, and GitHub documents that subdirectories of
  the workflows directory are not supported — so the `uses: cafaye/kit/workflows/
  ci.reusable.yml@master` line in the README resolved to nothing. No repository
  in the fleet was calling it. It is now a **move, not a mirror**: one file, at
  the only path GitHub will resolve, so there is no second copy to diverge.
- `self_test.sh` grew from 5 breakages to **19** — master's 18 plus kit-03's
  `2b`, which deletes a backend exporter entirely. A set-difference check on the
  exporter set catches an exporter that should not be there and is silent about
  one that is *missing*, and a missing exporter ships a stack that collects
  everything and prints nothing. Six are per-language semantic mutations, each
  against a different W3C section, so
  **every** suite is proven able to fail rather than assumed to. A mutant that
  fails to compile is its own verdict rather than a pass, a missing toolchain is
  a skip that fails the run, and an unmatched mutation is a hard failure so the
  proof cannot rot into proving nothing.
  Both sides' recipes for breakages **2** and **4** were kept, and they are not
  the same recipe: kit-03's rewrote them because they named strings that no
  longer exist — `exporters: [debug]` stopped being the traces pipeline when it
  fanned out to three backends, and a literal `${KIT_POSTGRES_PORT:-5432}`
  stopped existing when the stack moved into the 15000-15999 port block.
  `edit` refuses an unmatched pattern, so a stale recipe fails loudly instead of
  passing silently; that is correct, and it is also how a self_test stops testing
  the thing it names.
  The count in the summary line is now **counted from the recipes** rather than
  written down, and a check asserts that every breakage the header documents has
  a recipe and every recipe has a header entry — so the two cannot drift.
- `validate.sh` reads the CI workflow's `language` options and requires a
  Dockerfile, a `bin/prime` and a `[tools]` pin for each — "half a language is
  worse than none", enforced rather than trusted. It also requires `language`
  options and the job set to be the same list, a ref on every `uses:`, no
  branch refs, and every `${{` to close.
- New checks: the otel-collector environment wiring, that every `*.snippet`
  carries an install line and a pinned version, that every snippet **parses in
  its own language**, and that the README's documented callers only pass inputs
  the workflow actually declares.
- The `telemetry` CI job is a matrix while the seven language jobs stay one-per-
  language: a matrix is right for six stdlib test suites that share nothing, and
  wrong for six toolchains that install different things.
- The `telemetry` input is a string rather than a boolean, because GitHub
  coerces the bare word `false` in some positions and `if: inputs.telemetry` is
  a trap as a result.

### Fixed

- A `pipefail` bug in the new staleness test, where a successful `grep` was
  masked by the classifier command's own deliberate non-zero exit. The output is
  captured to a variable and the status read from the command, never from a pipe:
  **a piped exit code is the exit of the last stage.** The same trap, one level
  down from the one `self_test.sh` already documents at breakage 6.
- The fail-closed tier was stated in **two** places — a string in `classify.py`
  and a rule in `rules.json` — and the self-test breakage written to invert it
  left the suite **green**, because the headline case never reached the line that
  was broken. A property asserted in two places is asserted in zero. Both facts
  now live in `rules.json` alone, and the counterexample is one token.
- A `current`-at-head pin was reported as `unknown`. That is the state a reader
  learns to ignore, which makes it the expensive direction to get wrong.

### Changed

- `AGENTS.md` records that the classifier **fails closed** as a rule about code
  and not about data, and carves `core/`'s two programs out of the config-only
  rule explicitly — stdlib only, nothing imports them, no committed output — so
  that the exception is bounded rather than the start of a trend.
- `AGENTS.md` and `README.md` describe twenty-three breakages rather than
  eighteen, and the phase list gains the classifier and staleness phases.

### Not done, and why

- **No repository was migrated.** `vendir.yml` files for `muse`, `pantry` and
  `caf` are shipped as templates with the exact steps in
  `core/renovate/SETUP.md`; applying them is thirteen pull requests in thirteen
  repositories, and this change is scoped to `kit`.
- **`oasdiff` is not wired in.** It is the right tool for the OpenAPI half — a
  static Go binary, a live GitHub Action, and **755 level-tagged checks** measured
  by running `oasdiff checks changelog` at v1.32.1 — but `core`'s fan-out is raw
  JSON Schema, and adding a pinned binary would make `kit` a repository with a
  dependency, which `AGENTS.md` forbids.
- **`expectOperations` is untouched and stays in `cafaye-ts`.** vendir has no
  opinion about whether a copy should have been allowed to change size, and a
  guard moved into a tool that cannot enforce it is a guard deleted.
- **Three of the fleet's five parity guards still skip** when the core checkout
  they compare against is absent. Fixing that is independent of vendir, more
  urgent than vendir, and belongs to the repositories that own them.


### Earlier (kit-01)

- `README.md` — what kit is, how a service repo adopts it, adoption checklist.
- `AGENTS.md` — conventions for this repo.
- `workflows/ci.reusable.yml` — reusable GitHub Actions workflow. Inputs
  `language` (go|ruby|elixir|python|node|rust), `working-dir`, `versions`, and
  `coverage-fail-under`; one job per language, each install → lint → test →
  coverage. No job builds or pushes an image.
- `lint/` — `yamllint.yml`, `golangci.yml`, `rubocop.yml`, `eslint.config.mjs`,
  each with its strictness decisions written down.
- `docker/Dockerfile.{go,rust}` — multi-stage, distroless final.
  `docker/Dockerfile.{ruby,elixir,python,node}` — multi-stage, `*-slim` final.
  All non-root, none on `:latest`, all versioned through build args.
- `templates/bin-prime/{go,ruby,elixir,python,node,rust}.sh` — worktree
  primers; exit 0 only when the tree is genuinely ready.
- `templates/mise.toml` — per-language tool sections with placeholder versions.
- `templates/AGENTS.md` — skeleton repo-conventions file.
- `tests/validate.sh` + `tests/requirements.txt` — the gate, and its deps.
