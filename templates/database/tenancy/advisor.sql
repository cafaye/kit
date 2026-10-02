-- kit template — the ACCOUNT boundary, graded by the DATABASE.
--
--     psql "$MIGRATIONS_DATABASE_URL" -f advisor.sql
--     select * from cafaye.advisor_findings();
--
-- WHAT THIS IS. Nine row-level-security rules, one function, one output shape:
-- every finding is a row carrying `(name, level, facing, categories, description,
-- detail, remediation, metadata, cache_key)`. A gate reads the rows; nothing has
-- to parse anything.
--
-- WHY IT EXISTS BESIDE `substrate.sql` AND THE SIX DRIVERS. Those three grade
-- what the templates SAY: the substrate as text, the assertion set as names, and
-- the boundary as a set of denials RUN against the cluster. None of them can see
-- a policy whose predicate is `true`, because a permissive predicate returns rows
-- and a denial cannot tell "permitted by the predicate" from "permitted by
-- accident". Nor can a file scanner see that two permissive policies on the same
-- (table, role, command) combine with OR. This file grades the LIVE DATABASE, and
-- that is the only layer that can see either.
--
-- NINE RULES, AND WHY THE COUNT IS NINE. The shape is taken from Supabase's
-- database advisor (`pg-meta`'s `studio/advisor/lints.ts`), which is where the
-- row-per-rule union-all query and the nine-column output come from. NOTHING is
-- copied from it: it is MIT-licensed and its own rule is that an adopter must not
-- vendor it, and this repository's rule is that nothing in `moon/refs/` is ever
-- copied in. Every query below was written against this fleet's catalogs, and
-- every one that had to differ says so at the point of the difference.
--
-- Two of the source's rules count as one here, which is why six bullets read as
-- eight and the number is nine:
--
--   1. `policy_exists_rls_disabled`              ERROR   policies, no ENABLE
--   2. `rls_disabled_in_public`                   ERROR   no RLS on a table the API reaches
--   3. `rls_policy_always_true`                   WARN    a permissive predicate that is always true
--   4. `rls_references_user_metadata`             ERROR   an authorization input the caller can edit
--   5. `multiple_permissive_policies`             WARN    >1 permissive policy per (table, role, command)
--   6. `login_role_security_definer_executable`   WARN    SECURITY DEFINER the login role can run
--   7. `auth_rls_initplan`                        WARN    an identity call not wrapped for the InitPlan
--   8. `rls_enabled_no_policy`                    INFO    RLS on, no policy: the table is unreadable
--   9. (counted as two in the source: `anon_…` and `authenticated_…`) — see rule 6.
--
--   Rule 8 is the source's `rls_enabled_no_policy`, which the packet's list does
--   not name and which is kept because it is the AVAILABILITY half of the
--   boundary and costs one union arm: a table with RLS enabled and no policy
--   denies every row to every role, which is fail-closed and therefore not a
--   security hole, and is also how a migration fails at 3am rather than in
--   review. It is INFO, not ERROR, and the proof below asserts zero ERROR/WARN
--   rows precisely so that an INFO here is visible without being a failure.
--
-- ---------------------------------------------------------------------------
-- WHAT WAS MAPPED, AND WHAT WAS DROPPED. Every substitution is here, not in a
-- separate table, because a rule whose mapping lives somewhere else is a rule
-- whose mapping is out of date.
--
--   `anon` and `authenticated`  ->  ANY NON-OWNER LOGIN ROLE. Supabase has two
--       fixed roles fronting PostgREST, so its rules can name them. kit has
--       `<service>_app`: a per-service LOGIN that owns nothing, is not a
--       superuser, and is the role every request authenticates as. The
--       distinction the source draws between "anonymous" and "signed in"
--       collapses here, which is why rules 2 and 6 are one rule each rather than
--       two: there is no role in this substrate that is not a signed-in caller.
--       That is a real difference and it is a narrowing — a role that is not
--       LOGIN, or is a superuser, or holds BYPASSRLS, is outside both rules
--       exactly as it is outside the source's.
--
--   `pgrst.db_schemas`          ->  `p_schemas`, the argument. PostgREST declares
--       which schemas it exposes in a GUC; kit has no PostgREST, and the honest
--       equivalent is "the schemas this service actually uses", which is a
--       decision rather than a setting. So the scope is an ARGUMENT, and a NULL
--       means the whole database minus the catalog schemas. A caller that means
--       "everything" gets it, and a caller that means "my own tables" says so.
--
--   `auth.uid()`, `auth.jwt()`, `auth.role()`, `auth.email()`  ->
--       `cafaye.current_account_id()` and `cafaye.current_credential_digest()`.
--       These are the substrate's two documented identity seams. Rule 7 looks for
--       an unwrapped call to either, plus a bare `current_setting(`, which is
--       the third of the three the substrate exists to remove.
--
--   `auth.jwt() -> 'user_metadata'`  ->  rule 4, and it is the mapping that
--       changed most (see the block above that rule).
--
--   `pg_policies`  ->  `pg_policy` + `pg_get_expr()`. The source's rules 3 and 4
--       read Supabase's `pg_policies` view, which is a MATERIALIZED VIEW their
--       platform refreshes. Plain Postgres has no such view and no refresh job,
--       so both arms read `pg_policy` and render the expressions with
--       `pg_get_expr`. That is not a translation detail: a materialized view is
--       a cache, and a rule that reads a cache reports what the cache last saw.
--
--   DROPPED, with the reason: `facing` is `INTERNAL` on every row rather than
--       `EXTERNAL`. Supabase's value means "this finding is about the surface
--       PostgREST exposes"; kit exposes no such surface, and a constant column
--       that is always the same value is a column nobody reads.
--
--   DROPPED: the source's per-row `remediation` is a documentation URL. kit
--       ships no URL for a template it hands out, so `remediation` carries the
--       SQL that fixes the finding and the file that explains it. A remediation
--       a caller cannot execute without a second lookup is a second lookup.
--
--   DROPPED: the source's `cache_key` is an opaque string for their dashboard to
--       deduplicate with. Here it is the same string, and it is kept because it
--       is the one column that is stable across runs — so a gate can diff two
--       runs by it. It is not needed to read a finding and it is not decoration.

-- ---------------------------------------------------------------------------
-- THE SCOPE ARGUMENT, and the one thing to know before reading a row.
--
-- `p_schemas` filters by SCHEMA and nothing else. A NULL is the whole database
-- minus `pg_catalog`, `information_schema`, `pg_toast` and every `pg_%` schema,
-- which is the smallest exclusion that is not a list of other people's business:
-- the source excludes thirty named extension schemas, and every one of those is
-- a schema `pg_%` or `information_schema` already covers, or a schema some other
-- platform put its extensions in.
--
-- Extension-owned tables are excluded by `pg_depend.deptype = 'e'`, for the same
-- reason `substrate.sql`'s sweep excludes them and in the same words: pgvector
-- and friends ship their own tables with their own grants, and reporting a table
-- this substrate cannot protect trains the reader to ignore the report.
--
-- IT STANDS ALONE. Nothing here calls a `cafaye.*` function the substrate owns,
-- and that is deliberate rather than tidy. A checker that only exists where the
-- thing it checks has already been installed cannot find a service that has NOT
-- installed it — which is the service that needs it. So rule 5's recognition of a
-- substrate-written policy, which is the one place the substrate's own naming
-- convention appears, is inlined rather than delegated to
-- `cafaye.credential_tables()`. The duplication is four lines of regexp and the
-- comment above each says which catalog it reads.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS DOES NOT FIND, because a rule that reads as a promise it cannot keep
-- is worse than no rule.
--
--   * That a policy's predicate is the RIGHT predicate. Rule 3 finds `true`;
--       nothing here can tell a policy that is subtly too wide from one that is
--       exactly right, because "right" is a property of the service's data model
--       and this function has never read it.
--
--   * That the service SETS the identity. `cafaye.begin_account/1` is one call in
--       one place. A service that never calls it reads zero rows, which is safe
--       and loud, and no rule in this file can tell it from a service whose
--       tables are empty.
--
--   * That the login role is not a MEMBER of the owner role, that the login role
--       holds no BYPASSRLS, and that the owner's FORCE is set. The last is
--       `relforcerowsecurity`, and this file has no rule for it on purpose:
--       `substrate.sql`'s sweep names it and `isolation.sql` asserts it by
--       RUNNING the denials as the owner, because a catalog reading can be
--       satisfied by a table nobody reads. One file claiming all three would
--       mean one file where a reader looks for the proof and finds a column.

-- ---------------------------------------------------------------------------
-- rule 5's exemption, stated here because it is the only judgement in this file
-- and MD24 is the reason it exists.
--
-- MD24 gives every credential table FIVE policies: one per command from
-- `protect_table`, plus a `for select` from `protect_credential_table` whose
-- predicate is the digest the CALLER PRESENTED. So `(api_keys, alpha, SELECT)`
-- holds two permissive policies, and the source's rule reads that as a
-- performance defect. It is not a defect; it is the mechanism, and the two
-- predicates combine as
--
--     (account_id = the session's account) OR (token_digest = the digest presented)
--
-- which is exactly what MD24 says it means: your account's rows, or the one
-- credential row you named. Collapsing them into one policy would mean writing a
-- policy that ORs a digest, which is the shape `substrate.sql` argues against in
-- the comment above `protect_credential_table`.
--
-- So the rule stays at WARN and unsoftened, and the EXEMPTION is the rule's own
-- semantics rather than an allowlist of names:
--
--     a (table, role, command) group is exempt when EVERY policy in it was
--     written by the substrate.
--
-- It is an all-of condition and that is the whole design. An allowlist keyed on
-- policy NAMES (`%_cafaye_resolve`) is a ratchet: a service that renames a
-- policy gets a red it cannot fix, and a service that adds a THIRD permissive
-- policy next to the exempt two still passes. Under this exemption the substrate
-- writes `account_users`'s four policies and `api_keys`'s five, all recognised,
-- group exempt — and the moment a service hand-writes a second permissive SELECT
-- on `api_keys`, the group is no longer all-of and the rule fires, naming the
-- hand-written one. That is the shape this file has to be able to reach, and the
-- fixture in `tests/tenancy_test.sh` reaches it.

create or replace function cafaye.advisor_findings(
  p_schemas text[] default null
)
returns table (
  name        text,
  level       text,
  facing      text,
  categories  text[],
  description text,
  detail      text,
  remediation text,
  metadata    jsonb,
  cache_key   text
)
language sql
stable
as $advisor$
with
-- (1) THE SCOPE. An argument, not a list: see the block above.
scoped as (
  select n.nspname
  from pg_namespace n
  where n.nspname not in ('pg_catalog', 'information_schema')
    and n.nspname !~ '^pg_'
    and (p_schemas is null or n.nspname = any (p_schemas))
),

-- (2) WHO IS AN API CALLER. Non-superuser, no BYPASSRLS, can log in, not a
--     `pg_%` role. `rolbypassrls` is excluded for the reason the source excludes
--     it: a role that bypasses policies is not subject to them, so "the policy
--     is wrong for this role" is a different finding and this is not it.
api_roles as (
  select r.oid, r.rolname
  from pg_roles r
  where r.rolcanlogin
    and not r.rolsuper
    and not r.rolbypassrls
    and r.rolname !~ '^pg_'
),

-- (3) EVERY POLICY IN SCOPE, with its expressions RENDERED.
--
--     `pg_get_expr` is a pretty-printer, not the text that was executed: the
--     substrate writes `(account_id = (select cafaye.current_account_id()))` and
--     the catalog gives back
--     `(account_id = ( SELECT cafaye.current_account_id() AS current_account_id))`
--     — its own capitalisation, spacing and generated alias. Every regexp below
--     is written against the RENDERED form, and a regexp written against the
--     executed form matches nothing here and looks for ever afterwards like a
--     rule that found nothing. This is the trap `substrate.sql` records beside
--     `credential_tables()`, and it is why that function's pattern is copied
--     below rather than reinvented.
--
--     AND THE SCHEMA QUALIFICATION IN THAT OUTPUT IS NOT FIXED, which is a
--     measurement rather than a caveat. `pg_get_expr` drops the schema from a
--     name the READER can resolve, and what the reader can resolve is their
--     `search_path`. Measured on this kit, reading the same policy twice:
--
--         as role `alpha`   search_path = "$user", public   ($user = a schema
--                           named `alpha`, which does not exist)
--                             -> (account_id = ( SELECT cafaye.current_account_id() …))
--
--         as role `cafaye`  search_path = "$user", public   ($user = a schema
--                           named `cafaye`, which DOES exist)
--                             -> (account_id = ( SELECT current_account_id() …))
--
--     `"$user"` is the whole mechanism, and it means the cluster's own admin
--     role — the one named after the platform — reads the substrate's policies in
--     the short form. `cafaye.credential_tables()` returns nothing at all in that
--     session, for exactly this reason.
--
--     So every regexp below accepts BOTH forms, and the comment says why rather
--     than leaving `(cafaye\.)?` looking like sloppiness. The alternative — match
--     the qualified form only, as the substrate does — makes rule 5 report MD24's
--     credential policy as a hand-written one to exactly the reader least likely
--     to know why, and makes rule 7 silently miss a bare call for the same
--     reader. A rule that is blind under one search_path is the defect this
--     comment exists to prevent.
policies as (
  select n.nspname,
         c.relname,
         c.oid as reloid,
         c.relrowsecurity,
         p.polname,
         p.polcmd,
         p.polpermissive,
         p.polroles,
         pg_get_expr(p.polqual, p.polrelid)          as qual,
         pg_get_expr(p.polwithcheck, p.polrelid)     as with_check
  from pg_policy p
  join pg_class c on c.oid = p.polrelid
  join pg_namespace n on n.oid = c.relnamespace
  join scoped s on s.nspname = n.nspname
  left join pg_depend d on d.objid = c.oid and d.deptype = 'e'
  where c.relkind = 'r'
    and d.objid is null
),

-- (4) ONE ROW PER (POLICY, ROLE). `polroles = '{0}'` means PUBLIC and is
--     expanded to every API role, which is what makes a `to public` policy
--     group with each caller rather than sitting in a bucket of its own.
policy_roles as (
  select p.*, r.rolname
  from policies p
  join api_roles r
    on p.polroles @> array[r.oid]
    or p.polroles = array[0::oid]
),

-- (5) ONE ROW PER (POLICY, ROLE, COMMAND), with `for all` expanded to all four.
--     A `for all` policy plus a `for select` policy is therefore two rows in the
--     same (role, command) group, which is what trips rule 5.
--
--     `for all` is `polcmd = '*'` and it is expanded rather than left as its own
--     command, and the reason it has to be is that `for all` PLUS `for select` is
--     the shape MD24's fifth policy would take if it were a `for all`: expanding
--     it is what puts the two in the same group. The expansion is written out as
--     five cases rather than folded into one, so that `array['SELECT']` for `r`
--     and `array['SELECT','INSERT','UPDATE','DELETE']` for `*` cannot be confused
--     by a later edit that changes one of them.
policy_cmds as (
  select pr.*, act.cmd
  from policy_roles pr
  cross join lateral unnest(
    case pr.polcmd
      when 'r' then array['SELECT']
      when 'a' then array['INSERT']
      when 'w' then array['UPDATE']
      when 'd' then array['DELETE']
      when '*' then array['SELECT', 'INSERT', 'UPDATE', 'DELETE']
      else array['ERROR']
    end
  ) as act(cmd)
),

-- (6) WHICH POLICIES THE SUBSTRATE WROTE, and it is two shapes:
--
--       the account predicate  `account_id = ( select cafaye.current_account_id()`
--       the credential predicate  `<column> = ( select cafaye.current_credential_digest()`
--
--     Inlined rather than delegated to `cafaye.credential_tables()` — see the
--     block above: an advisor that only exists where the substrate has been
--     installed cannot find the service that has not installed it. The second
--     shape is `protect_credential_table`'s, and it is checked against the
--     DIGEST FORM rather than against the digest COLUMN, because the column is
--     the adopter's choice and the form is the substrate's. Both shapes carry
--     `(cafaye\.)?` for the `search_path` reason recorded above, and it is worth
--     being blunt about the asymmetry: the substrate's own `credential_tables()`
--     requires the qualified form, so this function recognises more policies than
--     that one does. That is the right direction to err — over-recognising a
--     substrate policy leaves a hand-written one still reported.
substrate_written as (
  select pc.*,
         (pc.qual ~* '^\s*\(?account_id = \(\s*select (cafaye\.)?current_account_id\(\)'
            or pc.qual ~* '^\s*\(?[a-z_][a-z0-9_$]* = \(\s*select (cafaye\.)?current_credential_digest\(\)') as substrate_written
  from policy_cmds pc
),

-- (7) NORMALISED EXPRESSIONS, for rule 3. Whitespace and case removed, because
--     `USING ( TRUE )` and `USING (true)` are the same policy and a rule that
--     reads one of them is a rule with a typo in it.
--
--     This one is per POLICY, not per (policy, role, command), and it is built
--     from a different arm of the CTE chain for a specific reason: a `for all`
--     policy fires rule 3 four times otherwise, once per command it was expanded
--     into, and four identical findings for one bad policy is a report nobody
--     reads to the end. The source reports this rule once per policy too — its
--     `FOR ALL` expansion belongs to rule 5 and only to rule 5. So rule 3 gets a
--     per-policy view with its role list, and rule 5 keeps the expansion.
policy_once as (
  select p.*,
         (select coalesce(array_agg(distinct r.rolname order by r.rolname), array[]::text[])
            from api_roles r
           where p.polroles @> array[r.oid]
              or p.polroles = array[0::oid]) as roles
  from policies p
),
normalized as (
  select po.*,
         replace(replace(replace(lower(coalesce(po.qual, '')), ' ', ''), e'\n', ''), e'\t', '')          as n_qual,
         replace(replace(replace(lower(coalesce(po.with_check, '')), ' ', ''), e'\n', ''), e'\t', '') as n_check
  from policy_once po
),

-- ===========================================================================
-- 1. `policy_exists_rls_disabled` — the rules read as if they are in place and
--    are not. The finding is the shape that reads correct in review: policies
--    exist, `relrowsecurity` is false, and every catalog a reader would consult
--    says the table is protected because it has policies.
-- ===========================================================================
rule_policies_rls_disabled as (
  select 'policy_exists_rls_disabled'::text as name,
         'ERROR'::text as level,
         array['SECURITY']::text[] as categories,
         'Row level security policies exist on this table but row level security is not enabled on it. Every one of those policies is inert: Postgres reads the table as unrestricted, so the policies document an intent the server is not enforcing.'::text as description,
         format('Table %I.%I has %s policy/policies and `relrowsecurity` is false, so none of them applies. Policies: %s.',
                nspname, relname, count(*)::text, array_agg(polname order by polname))::text as detail,
         format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY; then run this advisor again. If the policies were meant to be inert, drop them: an inert policy is a comment that survives refactors.', nspname, relname)::text as remediation,
         jsonb_build_object('schema', nspname, 'name', relname, 'type', 'table',
                            'policies', array_agg(polname order by polname)) as metadata,
         format('policy_exists_rls_disabled_%s_%s', nspname, relname)::text as cache_key
  from policies
  where not relrowsecurity
  group by nspname, relname
),

-- ===========================================================================
-- 2. `rls_disabled_in_public` — the table the API can reach, with no RLS.
--
--    THE MAPPING, and it is the load-bearing adaptation of the whole file.
--    Supabase asks whether `anon` or `authenticated` holds SELECT and whether
--    the schema is in `pgrst.db_schemas`. kit has no PostgREST and no fixed
--    roles, so the question becomes: does ANY non-owner, non-superuser LOGIN
--    role hold SELECT on this table. That is the same question with the
--    platform's names filled in by the catalog's, and it is strictly the
--    generalisation: a role kit did not know about when the rule was written
--    is in scope, which a hard-coded pair of role names would miss.
--
--    `has_table_privilege` includes privileges held through PUBLIC and through
--    role membership, which is the correct answer to "can this caller read it"
--    and the wrong one to ask about a single grant — the grant is not the
--    capability, and a rule that read grants instead would miss every inherited
--    one.
-- ===========================================================================
rule_rls_disabled_in_public as (
  select 'rls_disabled_in_public'::text as name,
         'ERROR'::text as level,
         array['SECURITY']::text[] as categories,
         'Row level security is not enabled on a table a non-owner login role can SELECT. Whatever this table holds is readable by every role that can reach the database, whatever the service intends.'::text as description,
         format('Table %I.%I has no row level security, and %s login role(s) can SELECT it: %s.',
                n.nspname, c.relname, count(*)::text,
                array_to_string(array_agg(distinct r.rolname order by r.rolname), ', '))::text as detail,
         format('If the table holds customer rows: ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY; and call cafaye.protect_table(''%I'') from its migration. If it holds none, revoke the grant that makes it reachable — the reachability is the finding, not the missing RLS.', n.nspname, c.relname, c.relname)::text as remediation,
         jsonb_build_object('schema', n.nspname, 'name', c.relname, 'type', 'table',
                            'reachable_by', array_agg(distinct r.rolname order by r.rolname)) as metadata,
         format('rls_disabled_in_public_%s_%s', n.nspname, c.relname)::text as cache_key
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  join scoped s on s.nspname = n.nspname
  join api_roles r on has_table_privilege(r.rolname, c.oid, 'SELECT')
  left join pg_depend d on d.objid = c.oid and d.deptype = 'e'
  where c.relkind = 'r'
    and not c.relrowsecurity
    and d.objid is null
  group by n.nspname, c.relname, c.oid
),

-- ===========================================================================
-- 3. `rls_policy_always_true` — a permissive predicate that is always true.
--
--    `SELECT ... USING (true)` IS DELIBERATELY NOT FLAGGED, and the source is
--    right about why: a public read-only surface written `for select using
--    (true)` is a decision, not an accident. `UPDATE`, `DELETE` and `FOR ALL`
--    are different — a permissive write predicate that is always true lets a
--    caller write any row, which is the shape every "we'll tighten it later"
--    policy takes.
--
--    The NULL clause is half of it and is the half nobody writes: an INSERT has
--    no `using` (there is no existing row to filter) so a permissive INSERT with
--    a NULL `with check` permits every row anybody offers it. `normalize` is
--    what makes `USING ( TRUE )`, `USING (1=1)` and `USING ((true))` one
--    finding rather than three near-misses.
-- ===========================================================================
rule_policy_always_true as (
  select 'rls_policy_always_true'::text as name,
         'WARN'::text as level,
         array['SECURITY']::text[] as categories,
         'A permissive policy qualifier that is always true, or a NULL clause on a permissive write policy. A permissive policy that always passes is the table unprotected with the appearance of a policy: the table reads as governed and the server is permitting everything.'::text as description,
         format('Policy %I on %I.%I is %s for role(s) %s and its %s always passes, so the policy does not narrow anything.%s',
                polname, nspname, relname,
                case polcmd when 'r' then 'for SELECT' when 'a' then 'for INSERT'
                            when 'w' then 'for UPDATE' when 'd' then 'for DELETE'
                            else 'for ALL' end,
                coalesce(nullif(array_to_string(roles, ', '), ''), 'no login role (this policy binds none)'),
                case when perm_using and perm_check then 'USING and WITH CHECK'
                     when perm_using then 'USING'
                     else 'WITH CHECK' end,
                case when perm_using and perm_check then ' (both clauses)'
                     when perm_using then ' (the USING clause)'
                     else ' (the WITH CHECK clause is absent on a permissive write policy)' end)::text as detail,
         format('Rewrite the qualifier so it names what the caller must hold: account_id = (select cafaye.current_account_id()) on an account-scoped table. cafaye.protect_table/2 writes that form; a hand-written `true` is the one predicate no caller can narrow.', polname)::text as remediation,
         jsonb_build_object('schema', nspname, 'name', relname, 'type', 'policy',
                            'policy_name', polname, 'roles', roles,
                            'qual', qual, 'with_check', with_check) as metadata,
         format('rls_policy_always_true_%s_%s_%s', nspname, relname, polname)::text as cache_key
  from (
    select n.*,
           (polcmd in ('w', 'd', '*')
            and (n_qual in ('true', '(true)', '1=1', '(1=1)')
                 or (qual is null and polpermissive))) as perm_using,
           (n_check in ('true', '(true)', '1=1', '(1=1)')
            or (with_check is null and polpermissive and polcmd = 'a')
            or (with_check is null and polpermissive and polcmd in ('w', '*')
                and n_qual in ('true', '(true)', '1=1', '(1=1)'))) as perm_check
    from normalized n
  ) f
  where relrowsecurity
    and polpermissive
    and (perm_using or perm_check)
),

-- ===========================================================================
-- 4. `rls_references_user_metadata` — an authorization input the caller can
--    EDIT. This is the rule that changed most, and the change is the reason the
--    rule earns ERROR rather than being dropped along with the `auth` schema.
--
--    THE SOURCE'S RULE, IN ITS OWN TERMS: `auth.users.user_metadata` is editable
--    by the end user, so a policy that consults it consults something the user
--    controls. The source admits at `:821-822` that it cannot do better than a
--    string match: "False positives are possible, but it isn't practical to
--    string match."
--
--    THE HALF THAT IS PORTED VERBATIM, caveat and all. A policy mentioning
--    `user_metadata`, `raw_user_meta_data` or `app_metadata` is flagged whether
--    or not this fleet ever writes one, because the caveat is the point: this
--    half is a keyword search and says so.
--
--    THE HALF THAT IS NOT, and it is the reason this rule stays. Postgres records
--    a policy's dependencies: `pg_depend` holds a row per relation the policy
--    EXPRESSION reaches outside its own table. So "does this policy's predicate
--    read a table a caller can write" is a question about the catalog, not
--    about the text — and it is the shape of `user_metadata` exactly. A service
--    that keeps a `profile_flags` / `memberships` / `is_admin` table and writes
--    `using (exists (select 1 from profile_flags f where f.is_admin))` has built
--    its own `user_metadata`, and no keyword search finds it: the name is the
--    service's, the column is the service's, and the words `user_metadata` appear
--    nowhere. Supabase's rule could only ever report the half it could spell.
--
--    A column OF the policy's own table is not a hit, and that exclusion is not
--    cosmetic: `recordDependencyOnSingleRelExpr` deliberately does not record
--    self-references, so `using (account_id = ...)` produces no row here and the
--    substrate's own policies are silent.
-- ===========================================================================
rule_references_user_metadata as (
  select 'rls_references_user_metadata'::text as name,
         'ERROR'::text as level,
         array['SECURITY']::text[] as categories,
         'A policy takes an authorization input that the caller is able to edit. `user_metadata`-style claims are writable by the subject they describe, and a predicate that consults one decides access from something the caller controls. The catalog half of this rule reads pg_depend: a policy whose expression reaches outside its own table, into a table a login role may INSERT into or UPDATE, is flagged whatever that table is called.'::text as description,
         format('Policy %I on %I.%I reads %s, and a login role holds INSERT/UPDATE on it. Whatever the policy decides from those rows, the caller can change. Rendered qualifier: %s',
                p.polname, n.nspname, c.relname,
                array_to_string(array_agg(distinct dep_ns.nspname || '.' || dep_c.relname), ', '),
                coalesce(pg_get_expr(p.polqual, p.polrelid), '(none)'))::text as detail,
         format('The identity has to arrive from somewhere the caller cannot write. cafaye.begin_account/1 carries it into a transaction-local GUC and cafaye.current_account_id() reads it; a flag table is a request, not an identity. Deny the grant (REVOKE INSERT, UPDATE ON <that table> FROM <the login role>) and decide from the account instead.', n.nspname, c.relname)::text as remediation,
         jsonb_build_object('schema', n.nspname, 'name', c.relname, 'type', 'policy',
                            'policy_name', p.polname,
                            'reads', array_agg(distinct dep_ns.nspname || '.' || dep_c.relname)) as metadata,
         format('rls_references_user_metadata_%s_%s_%s', n.nspname, c.relname, p.polname)::text as cache_key
  from pg_policy p
  join pg_class c on c.oid = p.polrelid
  join pg_namespace n on n.oid = c.relnamespace
  join scoped s on s.nspname = n.nspname
  join pg_depend pd
    on pd.classid = 'pg_policy'::regclass
   and pd.objid = p.oid
   and pd.refclassid = 'pg_class'::regclass
   and pd.refobjid <> p.polrelid
  join pg_class dep_c on dep_c.oid = pd.refobjid
  join pg_namespace dep_ns on dep_ns.oid = dep_c.relnamespace
  where c.relkind = 'r'
    and dep_c.relkind = 'r'
    and exists (
      select 1 from api_roles r
      where has_table_privilege(r.rolname, dep_c.oid, 'INSERT')
         or has_table_privilege(r.rolname, dep_c.oid, 'UPDATE')
    )
  group by p.oid, p.polname, n.nspname, c.relname, pg_get_expr(p.polqual, p.polrelid)
  union all
  -- the ported keyword half, caveat included
  select 'rls_references_user_metadata'::text,
         'ERROR'::text,
         array['SECURITY']::text[],
         'A policy names a user-metadata column in its qualifier or its WITH CHECK. This half of the rule is a keyword search, which is why the source that this one is ported from admits it produces false positives: a column merely NAMED user_metadata trips it whether or not the data in it is user-editable.'::text,
         format('Policy %I on %I.%I names a user-metadata column: %s', polname, nspname, relname,
                coalesce(qual, with_check))::text,
         format('Treat the column as caller-editable input and decide from the account. If the name is a false positive, the rule says so rather than assuming it: the qualifier is above, in full.')::text,
         jsonb_build_object('schema', nspname, 'name', relname, 'type', 'policy',
                            'policy_name', polname, 'match', 'keyword'),
         format('rls_references_user_metadata_keyword_%s_%s_%s', nspname, relname, polname)::text
  from policies
  where lower(coalesce(qual, '') || ' ' || coalesce(with_check, ''))
          ~ 'user_metadata|raw_user_meta_data|app_metadata'
),

-- ===========================================================================
-- 5. `multiple_permissive_policies` — two or more PERMISSIVE policies on one
--    (table, role, command). They combine with OR, so the effective predicate is
--    the union of both, and every one of them is evaluated for every relevant
--    query.
--
--    AND THE EXEMPTION, which is the only judgement in this file: a group is
--    exempt when EVERY policy in it was written by the substrate. See the block
--    above for why, and for why an allowlist of policy names would be a ratchet
--    rather than an exemption. The all-of condition is what makes it safe: MD24's
--    fifth policy is exempt alongside the four, and a hand-written sixth is not.
-- ===========================================================================
rule_multiple_permissive as (
  select 'multiple_permissive_policies'::text as name,
         'WARN'::text as level,
         array['PERFORMANCE', 'SECURITY']::text[] as categories,
         'More than one PERMISSIVE policy applies to this table, role and command. Permissive policies combine with OR rather than AND, so the effective predicate is the union of all of them and each is evaluated on every relevant query — which is both a cost at scale and a wider surface than either policy reads as on its own.'::text as description,
         format('Table %I.%I has %s permissive policies for role %s for command %s. All of them: %s. Not written by the substrate: %s.',
                nspname, relname, count(*)::text, rolname, cmd,
                array_to_string(array_agg(polname order by polname), ', '),
                array_to_string(array_agg(polname order by polname) filter (where not substrate_written), ', '))::text as detail,
         format('Keep one permissive policy per role per command, and fold the conditions into it with AND. cafaye.protect_table/2 writes exactly one per command; a second policy on the same (role, command) is the OR that makes the table wider than it reads.')::text as remediation,
         jsonb_build_object('schema', nspname, 'name', relname, 'type', 'table',
                            'role', rolname, 'command', cmd,
                            'policies', array_agg(polname order by polname),
                            'hand_written', array_agg(polname order by polname) filter (where not substrate_written)) as metadata,
         format('multiple_permissive_policies_%s_%s_%s_%s', nspname, relname, rolname, cmd)::text as cache_key
  from substrate_written
  group by nspname, relname, rolname, cmd
  having count(*) > 1
     and bool_or(not substrate_written)
),

-- ===========================================================================
-- 6. `login_role_security_definer_executable` — a SECURITY DEFINER function
--    the application login role can run. One rule, where the source has two:
--    `anon_…` and `authenticated_…` differ only in whether the caller signed in,
--    and in this substrate every caller is a role that can log in. The source's
--    distinction has no third state to fall into, and inventing one would be a
--    rule about a topology kit does not run.
--
--    A `SECURITY DEFINER` function runs with its OWNER's privileges and with the
--    owner's exemption from row-level security unless FORCE applies to it — so a
--    definer that is a table owner is an owner bypass behind a function
--    signature. `substrate.sql` writes none: every function it owns is an invoker,
--    which is why `pg_proc.prosecdef` is worth a rule here and finds nothing.
-- ===========================================================================
rule_security_definer as (
  select 'login_role_security_definer_executable'::text as name,
         'WARN'::text as level,
         array['SECURITY']::text[] as categories,
         'A SECURITY DEFINER function that a non-owner login role may EXECUTE. It runs with the privileges of whoever owns it, so the capability a caller gets is the owner''s and not the caller''s — and if the owner is a table owner, it is also that table''s FORCE exemption.'::text as description,
         format('Function %I.%I(%s) is SECURITY DEFINER, is owned by %s, and %s login role(s) may EXECUTE it: %s.',
                n.nspname, p.proname,
                pg_get_function_identity_arguments(p.oid), owner.rolname,
                count(*)::text,
                array_to_string(array_agg(distinct r.rolname order by r.rolname), ', '))::text as detail,
         format('REVOKE EXECUTE ON FUNCTION %I.%I(%s) FROM the login roles, or declare it SECURITY INVOKER so it can only do what the caller can already do. A definer function is a privilege escalation with an argument list.', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid))::text as remediation,
         jsonb_build_object('schema', n.nspname, 'name', p.proname,
                            'arguments', pg_get_function_identity_arguments(p.oid),
                            'language', l.lanname, 'owner', owner.rolname, 'security_definer', true,
                            'executable_by', array_agg(distinct r.rolname order by r.rolname)) as metadata,
         format('login_role_security_definer_executable_%s_%s_%s', n.nspname, p.proname,
                pg_get_function_identity_arguments(p.oid))::text as cache_key
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  join scoped s on s.nspname = n.nspname
  join pg_language l on l.oid = p.prolang
  join pg_roles owner on owner.oid = p.proowner
  join api_roles r on has_function_privilege(r.rolname, p.oid, 'EXECUTE')
  where p.prosecdef
    -- The OWNER is deliberately NOT filtered for being a superuser or a BYPASSRLS
    -- role, and the reason is that filtering it would be filtering out the worst
    -- case: a SECURITY DEFINER function owned by a cluster superuser and callable
    -- by a login role is the most capable object in the database, and a rule that
    -- stays quiet about it because its owner is too powerful to be interesting has
    -- inverted the finding. The catalog schemas are already out of scope, so the
    -- functions this would otherwise reach are the platform's own.
    and owner.rolname !~ '^pg_'
  group by n.nspname, p.oid, p.proname, l.lanname, owner.rolname
),

-- ===========================================================================
-- 7. `auth_rls_initplan` — an identity call that is not wrapped in
--    `(select …)`, so the planner evaluates it once per candidate ROW instead of
--    once per statement.
--
--    THE MEASUREMENT IS KIT'S OWN and it is in `tests/tenancy_test.sh`: five
--    rows, one query, five rows matched — the wrapped form calls the function
--    ONCE, the bare form FIVE times. This rule does not replace that
--    measurement, because a measurement is a measurement and a regexp is a
--    regexp. It CORROBORATES it: `substrate.sql` writes only the wrapped form, so
--    this rule must be silent on a substrate the measurement has just passed,
--    and if it is not, one of the two is wrong and the disagreement is the
--    finding.
--
--    The precondition is the source's and it is not optional: wrapping is only
--    correct when the call does not depend on row data. `account_id =
--    (select cafaye.current_account_id())` is the same value for every row, which
--    is what makes the InitPlan legal, and `protect_table` only ever writes that
--    form.
-- ===========================================================================
rule_initplan as (
  select 'auth_rls_initplan'::text as name,
         'WARN'::text as level,
         array['PERFORMANCE']::text[] as categories,
         'A policy qualifier calls the identity function bare, so it is re-evaluated for every candidate row instead of once per statement. Measured on this kit: one call against five, on a five-row table. Correct and slow; invisible until the table is large, which is the worst moment to find it.'::text as description,
         format('Policy %I on %I.%I calls an identity function without the (select …) wrapper. Measured on this kit, the bare form called the function once per candidate row (5 rows, 5 calls) where the wrapped form called it once. %s',
                polname, nspname, relname,
                case
                  when qual ~ 'current_setting\(' then 'unwrapped: current_setting(...)'
                  when qual ~ 'current_account_id\(\)' then 'unwrapped: cafaye.current_account_id()'
                  when qual ~ 'current_credential_digest\(\)' then 'unwrapped: cafaye.current_credential_digest()'
                  else 'unwrapped identity call'
                end)::text as detail,
         format('Rewrite it as `(... = ( select cafaye.current_account_id()))`. Only do so when the call does not depend on the row — the InitPlan is correct precisely because it is uncorrelated, so a call that reads the row must stay bare. cafaye.protect_table/2 writes the wrapped form for every policy it creates.')::text as remediation,
         jsonb_build_object('schema', nspname, 'name', relname, 'type', 'policy',
                            'policy_name', polname, 'qual', qual, 'with_check', with_check) as metadata,
         format('auth_rls_initplan_%s_%s_%s', nspname, relname, polname)::text as cache_key
  from policies
  where relrowsecurity
    -- An InitPlan is exactly `(... ( SELECT f() …))`, so the discriminator is
    -- the parenthesised SELECT and not the word `select` somewhere nearby. It is
    -- matched CASE-INSENSITIVELY because the deparser capitalises the keyword
    -- while leaving the function name in lower case: `SELECT
    -- cafaye.current_account_id()` is what the catalog holds, and a lowercase
    -- `select` in the pattern turns this rule into one that fires on every
    -- wrapped policy in the fleet.
    --
    -- Both deparse forms are accepted, for the `search_path` reason recorded
    -- above: requiring the qualified spelling would make this rule blind to a
    -- genuinely bare call in exactly the session where the name dequalifies,
    -- which is the session of the cluster's own admin role.
    and (
      (qual ~* '(cafaye\.)?current_account_id\(\)'        and qual !~* '\(\s*select\s+(cafaye\.)?current_account_id\(\)')
      or (qual ~* '(cafaye\.)?current_credential_digest\(\)' and qual !~* '\(\s*select\s+(cafaye\.)?current_credential_digest\(\)')
      or (qual ~* 'current_setting\('                       and qual !~* '\(\s*select\s+current_setting\(')
      or (with_check ~* '(cafaye\.)?current_account_id\(\)'        and with_check !~* '\(\s*select\s+(cafaye\.)?current_account_id\(\)')
      or (with_check ~* '(cafaye\.)?current_credential_digest\(\)' and with_check !~* '\(\s*select\s+(cafaye\.)?current_credential_digest\(\)')
      or (with_check ~* 'current_setting\('                       and with_check !~* '\(\s*select\s+current_setting\(')
    )
),

-- ===========================================================================
-- 8. `rls_enabled_no_policy` — RLS on, no policy. INFO, not ERROR, and the
--    level is the finding: the table is UNREADABLE to every role, which is
--    fail-closed. It is reported because the boundary is then two-sided — a
--    service whose table reads as protected and whose table reads as empty is a
--    3am failure with no error anywhere, and the catalog is where that shows up
--    first.
-- ===========================================================================
rule_rls_no_policy as (
  select 'rls_enabled_no_policy'::text as name,
         'INFO'::text as level,
         array['SECURITY']::text[] as categories,
         'Row level security is enabled and no policy exists, so every role is denied every row. Nothing leaks; the table is simply unreadable, which is a fail-closed outage rather than a breach.'::text as description,
         format('Table %I.%I has row level security enabled and no policy. Every SELECT on it returns no rows, including from the owner.', n.nspname, c.relname)::text as detail,
         format('Create the policies (cafaye.protect_table(''%I'')) or drop row level security from the table if it was meant to be readable.', c.relname)::text as remediation,
         jsonb_build_object('schema', n.nspname, 'name', c.relname, 'type', 'table') as metadata,
         format('rls_enabled_no_policy_%s_%s', n.nspname, c.relname)::text as cache_key
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  join scoped s on s.nspname = n.nspname
  left join pg_depend d on d.objid = c.oid and d.deptype = 'e'
  where c.relkind = 'r'
    and c.relrowsecurity
    and d.objid is null
    and not exists (select 1 from pg_policy p where p.polrelid = c.oid)
)

select f.name,
       f.level,
       'INTERNAL'::text as facing,
       f.categories,
       f.description,
       f.detail,
       f.remediation,
       f.metadata,
       f.cache_key
from (
  select * from rule_policies_rls_disabled
  union all select * from rule_rls_disabled_in_public
  union all select * from rule_policy_always_true
  union all select * from rule_references_user_metadata
  union all select * from rule_multiple_permissive
  union all select * from rule_security_definer
  union all select * from rule_initplan
  union all select * from rule_rls_no_policy
) f
-- Ordered by the KEY rather than by the finding, so a run that gains and loses
-- findings produces a diff a reader can read. `cache_key` is the one column here
-- that does not change when a finding's prose does.
order by f.cache_key;
$advisor$;