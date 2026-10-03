#!/usr/bin/env bash
#
# kit's proof that `KIT_SELF_TEST_SHARD=i/n` PARTITIONS the self-test suite.
#
#   bash tests/shard_test.sh
#
# THE CLAIM
#   For every 1 <= i <= n, the n shards together run every numbered breakage
#   EXACTLY ONCE, and no shard in 1..n is empty.
#
# WHY IT IS A SEPARATE FILE, and not a paragraph in self_test.sh's header. The
# property is about the harness's own arithmetic, so no `expect_red_check` can
# reach it: every recipe in the suite proves that the GATE goes red, and the gate
# is not what shards. What did go wrong was arithmetic in a file nobody could
# execute partially, and it shipped because every shard that was run happened to
# be a shard that worked. Four shards as a merge gate produced a false green on
# the fourth.
#
# IT EVALUATES THE REAL FUNCTION rather than restating it. The sharding block is
# extracted from `tests/self_test.sh` verbatim and `eval`'d, so this file cannot
# pass while the file it is proving has drifted -- a second copy of the modulo
# would be a second thing to be wrong, which is the shape of defect the packet is
# about. Same reason it enumerates the breakages with the SAME grep the suite's
# own summary uses to print "ran N of TOTAL".
#
# WHAT IT IS NOT
#   It does not run a single breakage. It asks the partition question, which is
#   answerable in under a second, and the recipes that prove it is load-bearing
#   are 94 and 95.
#
# THE THREE PROPERTIES, and each one alone is satisfiable by a wrong partition:
#   EXACTLY ONCE  a partition that double-counts runs every breakage twice and
#                still reports the suite covered -- the failure direction that
#                looks like a working gate.
#   COMPLETE     a partition that drops one breakage covers everything it claims
#                to and never runs the one it dropped.
#   NON-EMPTY    a partition whose last shard asks for a residue class nobody is
#                in covers the suite in n-1 shards and reports the nth as PASS.
#                This is the shipped defect, and it is invisible to the other
#                two.
#
# THE OVER-PROVISIONING CASE IS A SEPARATE ASSERTION because it is the one case
# where an empty shard is CORRECT: n > the suite's size means some shard must be
# empty. So it is refused at the door, loudly, with both numbers -- see
# `_shard_suite_size` in tests/self_test.sh. Run with `0/4` or `4/4`-as-zero and
# the refusal is what this file reports.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/tests/self_test.sh"

failures=0
cases=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}
note() { printf 'NOTE  %s\n' "$1"; }

if [ ! -f "$SELF" ]; then
  echo "shard_test: cannot find tests/self_test.sh under $ROOT" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# The sharding block, extracted verbatim.
#
# From the `_shard_i=` assignment to the closing brace of `_shard_claims`, which
# is the first line in that range that is exactly `}`. Nothing between them is a
# bare `}`, so the range is unambiguous -- and if somebody reformats it into one,
# this extraction finds a shorter block and every assertion below fails, which is
# the right direction for a check to break in.
# ---------------------------------------------------------------------------
_shard_block="$(awk '/^_shard_i="\$\{KIT_SELF_TEST_SHARD:-\}"/,/^}$/' "$SELF")"

if ! printf '%s' "$_shard_block" | grep -q '_shard_claims()'; then
  echo "shard_test: could not extract the sharding block from tests/self_test.sh." >&2
  echo "           The file's shape changed and this check cannot see it any more;" >&2
  echo "           a check that stops seeing is not a check that passed." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# The suite's breakages, enumerated the way the summary counts them. Same
# expression, same shape: a label this misses is a breakage the sharded summary
# would call covered by nobody, and that is exactly the hole to look for.
#
# `expect_skip_check` is a SEPARATE ALTERNATIVE here because it is a separate
# alternative there too -- `(red|green)(_check|_lang|_script)?` does not spell it.
# And BOTH QUOTE STYLES, because breakage 5 is labelled with `"` and every other
# one with `'`: a checker that enumerates the suite with a DIFFERENT rule than the
# suite enumerates itself is checking its own rule. The first version of this grep
# got both of those wrong and counted 96 breakages where the suite's summary
# counts 97 -- and the one it dropped was breakage 5, silently, with no finding.
# ---------------------------------------------------------------------------
LABEL_RE="^ *expect_(red|green)(_check|_lang|_script)? +['\"]breakage [0-9]+[a-z]*:.*|^ *expect_skip_check +['\"]breakage [0-9]+[a-z]*:.*"
LABELS=()
while IFS= read -r _label; do
  [ -n "$_label" ] || continue
  LABELS+=("$_label")
done < <(grep -oE "$LABEL_RE" "$SELF" |
  sed -E "s/^ *expect_(red|green)(_check|_lang|_script)? +//; s/^ *expect_skip_check +//")

SUITE_SIZE=${#LABELS[@]}
if [ "$SUITE_SIZE" -lt 2 ]; then
  echo "shard_test: found $SUITE_SIZE breakage labels in tests/self_test.sh; the grep is wrong." >&2
  exit 1
fi

# The suite's own count, computed with the SUMMARY's expression, and asserted equal
# to what this file enumerated. The two enumerating differently is the hazard the
# comment above is about, and this is where it gets caught rather than silently
# shrinking the property: the first version of this grep matched only single-quoted
# labels, missed `expect_skip_check`, and found 96 against the suite's 97 with no
# finding anywhere. A checker that agrees with nothing is not a checker.
SUITE_COUNT=$(grep -cE "^ *expect_(red|green)(_check|_lang|_script)? +.breakage +[0-9]+[a-z]*:|^ *expect_skip_check +.breakage +[0-9]+[a-z]*:" "$SELF" || true)

# THE HIGHEST NUMBER, and it is not the count. The labels are sparse -- they run
# 1..93 with lettered siblings and gaps left by renumbering -- so the n that makes
# every shard non-empty is the highest NUMBER, not the number of labels. Reading
# the bound as the count is what let n=97 through with nine empty shards, and an
# empty shard is the whole defect.
SUITE_MAX=0
for _label in "${LABELS[@]}"; do
  _n="${_label%%:*}"
  _n="${_n##*breakage }"
  _n="${_n%%[a-z]}"
  [ -n "$_n" ] || continue
  # `if`, not `[ … ] && SUITE_MAX=…`: a bare AND-list that ends false is a `set -e`
  # exit, and the first version of this loop died on breakage 1 and printed
  # nothing. Same shape as the one in `empty_in`, which cost the same twenty
  # minutes.
  if [ "$_n" -gt "$SUITE_MAX" ]; then
    SUITE_MAX="$_n"
  fi
done

# The unnumbered labels -- the green controls, `expect_green 'unbroken tree'` and
# friends. They are NOT in LABELS, so a partition that covers LABELS says nothing
# about where they land, and `_shard_claims` has a branch for them.
UNNUMBERED=()
while IFS= read -r _label; do
  [ -n "$_label" ] || continue
  UNNUMBERED+=("$_label")
done < <(grep -oE "^ *expect_(red|green)(_check|_lang|_script)? +['\"][^'\"]+['\"]" "$SELF" |
  sed -E "s/^ *expect_(red|green)(_check|_lang|_script)? +//" |
  grep -vE 'breakage [0-9]+[a-z]*:' || true)

# Both lists to the child as one newline-joined value. `set -f` there, because a
# label is prose and prose contains `?`.
ALL_LABELS="$(printf '%s\n' "${LABELS[@]}" "${UNNUMBERED[@]+"${UNNUMBERED[@]}"}")"
export ALL_LABELS

printf -- '-- the sharding partition of %s breakages, numbered up to %s\n' "$SUITE_SIZE" "$SUITE_MAX"

cases=$((cases + 1))
if [ "$SUITE_COUNT" -eq "$SUITE_SIZE" ]; then
  pass "this file enumerates $SUITE_SIZE breakages, which is what the suite's own summary counts"
else
  fail "this file enumerates $SUITE_SIZE breakages and the suite's summary counts $SUITE_COUNT -- the two rules have drifted, so the property below is not the suite's"
fi

# ---------------------------------------------------------------------------
# claims <n> -- print `i<TAB>label` for every breakage each shard in 1..n claims.
#
#   ONE child per n, and the block is `eval`'d ONCE inside it with the shard
# variables assigned per shard. Two earlier shapes were wrong here and both were
# slow for the same reason: re-parsing `KIT_SELF_TEST_SHARD` inside the loop made
# the block recount the suite's highest number -- a grep, a sed and a `sort` over
# a 5,000-line file -- once per shard, which is 93 of them for n=93 and turned a
# one-second check into a two-minute one.
#
# The over-provisioning refusal lives in the block's PARSE section and is skipped
# by this loop on purpose: it is a property of the block, asserted by `refuse` and
# end to end below, not of the function inside it. Assigning `_shard_i` and
# `_shard_n` directly is the only way to ask the function about an n its own guard
# would have refused.
#
# `bash -c <script> "$SELF"`, and the `$SELF` is load-bearing rather than
# decorative: the extracted block counts the suite's size from `"$0"`, and the
# first version ran it in a subshell of THIS file, where `$0` is shard_test.sh and
# the count is however many `expect_` lines shard_test.sh happens to contain --
# zero. So every over-provisioned shard was refused for the wrong reason, and
# `n = SUITE_SIZE` -- the partition where each shard must claim exactly one
# breakage, and the shape most sensitive to an off-by-one -- reported nine empty
# shards. A check reading `$0` is a check reading its caller unless it is given
# the right one.
# ---------------------------------------------------------------------------
claims() {
  local n="$1"
  KIT_SHARD_N="$n" KIT_SHARD_BLOCK="$_shard_block" \
    bash -c '
      set -f
      IFS="
"
      eval "$KIT_SHARD_BLOCK"
      for i in $(seq 1 "$KIT_SHARD_N"); do
        _shard_i="$i"
        _shard_n="$KIT_SHARD_N"
        for label in $ALL_LABELS; do
          if _shard_claims "$label"; then
            printf "%s\t%s\n" "$i" "$label"
          fi
        done
      done
    ' "$SELF"
}

# The largest n that leaves NO shard empty, found by asking rather than assumed.
#
# It is NOT the highest breakage number, which is the shape this file first
# assumed and which measured wrong: the labels are sparse (they run 1..63 and
# 68..93, with 64-67 left by a renumbering), so shard 64 is empty for every n in
# 64..93 and a gate asked for 90 shards would run 4 fewer recipes than it was told
# and never say so. That is the SAME defect as the one this file exists to catch,
# one level up: an n that is arithmetically legal and covers less than it appears
# to. So it is measured here, and the gaps are printed rather than absorbed.
NUMBERS=()
for _label in "${LABELS[@]}"; do
  _n="${_label%%:*}"
  _n="${_n##*breakage }"
  _n="${_n%%[a-z]}"
  [ -n "$_n" ] || continue
  NUMBERS+=("$_n")
done

# The DISTINCT shards the numbers land on for a given n, as an array indexed by
# shard number, so `${#OCC[@]}` is the count. An array rather than a
# `sort -u | wc -l` pipeline: the pipeline version printed a concatenated number
# instead of a count and took the whole check down with an `integer expression
# expected`, which is a check that dies for a reason nobody is looking at.
MAX_SAFE_N=0
declare -a OCC=()
for ((n = 1; n <= SUITE_MAX; n++)); do
  OCC=()
  for _k in "${NUMBERS[@]}"; do
    OCC[$(( (_k - 1) % n + 1 ))]=1
  done
  if [ "${#OCC[@]}" -eq "$n" ]; then
    MAX_SAFE_N="$n"
  fi
done
cases=$((cases + 1))
if [ "${MAX_SAFE_N:-0}" -ge 1 ]; then
  pass "the largest n with no empty shard is $MAX_SAFE_N of the suite's $SUITE_MAX numbers; a shard past it is empty because the numbering SKIPS $(if [ "${MAX_SAFE_N:-0}" -lt "$SUITE_MAX" ]; then printf '%s..%s' "$((MAX_SAFE_N + 1))" "$SUITE_MAX"; else printf 'nothing'; fi), and tests/self_test.sh reports that as a FAIL rather than a PASS"
else
  fail "no n leaves every shard non-empty, so there is no usable partition at all"
fi

# The ns worth proving. 1 and 2 are the degenerate shapes; 3, 4, 5, 7 and 8 are the
# ones actually run as gates -- 4 is the merge gate that produced the false green
# -- and the largest safe n is the last one, because that partition claims exactly
# one number per shard and any off-by-one shows up as an empty shard at once.
NSS="1 2 3 4 5 7 8 $MAX_SAFE_N"

for n in $NSS; do
  out="$(claims "$n")"
  cases=$((cases + 1))

  # NON-EMPTY, and the LAST shard first because that is the one the shipped
  # arithmetic emptied. Reported by name so a regression is legible in the log
  # without reading this file.
  empty=""
  for i in $(seq 1 "$n"); do
    got="$(printf '%s\n' "$out" | grep -c "^$i	" || true)"
    if [ "${got:-0}" -eq 0 ]; then
      empty="$empty $i"
    fi
  done
  if [ -n "$empty" ]; then
    fail "$n shard(s):$empty ran ZERO of the suite's $SUITE_SIZE breakages"
    if printf '%s' "$empty" | grep -q " $n\$" || [ "$empty" = " $n" ]; then
      fail "  and shard $n/n is one of them -- THE SHIPPED DEFECT: a 0-based residue compared against a 1-based shard index asks for a class nobody is in"
    fi
    continue
  fi
  pass "n=$n: every shard in 1..$n claims at least one breakage, shard $n/n included"

  # EXACTLY ONCE and COMPLETE, from the same tally: a breakage claimed by two
  # shards is a partition that overlaps, and one claimed by none is a partition
  # with a hole. Counted rather than eyeballed because both are quiet.
  #
  # The names are TRUNCATED, and that is not politeness. An off-by-one makes EVERY
  # label unclaimed at once, so the first version of this message printed all 99
  # of them on one line and buried the two findings above it -- a check whose
  # failure output is a wall of text is a check nobody reads, and the count is the
  # part that carries the diagnosis.
  dupes=""
  missing=""
  missing_count=0
  # The short name is the LABEL, not the line: several recipes carry their
  # arguments on the same line, so truncating at the first colon still leaves
  # `"'breakage 1: ... \"$one\" --static-only"` in the message.
  short_of() { printf 'breakage %s' "${1##*breakage }"; }
  _short=""
  for label in "${LABELS[@]}"; do
    got="$(printf '%s\n' "$out" | grep -cF "	$label" || true)"
    case "${got:-0}" in
      1) ;;
      0)
        missing_count=$((missing_count + 1))
        if [ "$missing_count" -le 3 ]; then
          _short="$(short_of "$label")"
          missing="$missing ${_short%%:*}"
        fi
        ;;
      *) dupes="$dupes $(short_of "$label" | cut -d: -f1)(x$got)" ;;
    esac
  done
  if [ -n "$dupes" ]; then
    fail "n=$n: these breakages are claimed by more than one shard:$dupes"
  else
    pass "n=$n: no breakage is claimed twice"
  fi
  if [ "$missing_count" -ne 0 ]; then
    fail "n=$n: $missing_count breakage(s) are claimed by NO shard, so the n shards do not cover the suite:$missing$([ "$missing_count" -gt 3 ] && printf ' ... and %s more' "$((missing_count - 3))")"
  else
    pass "n=$n: the $n shards cover all $SUITE_SIZE numbered breakages"
  fi

  # The controls, where they land. A partition that drops the unnumbered
  # breakages from every shard means they run only in the unsharded case, which
  # is the same "nobody asked for it" hole with a quieter symptom.
  if [ "${#UNNUMBERED[@]}" -gt 0 ]; then
    orphan=""
    for label in "${UNNUMBERED[@]}"; do
      got="$(printf '%s\n' "$out" | grep -cF "	$label" || true)"
      if [ "${got:-0}" -ne 1 ]; then
        orphan="$orphan $label(x${got:-0})"
      fi
    done
    if [ -n "$orphan" ]; then
      fail "n=$n: an unnumbered control is claimed by something other than exactly one shard:$orphan"
    else
      pass "n=$n: each of the ${#UNNUMBERED[@]} unnumbered control(s) runs on exactly one shard"
    fi
  fi
done

# ---------------------------------------------------------------------------
# THE REFUSALS. A shard that cannot be told from a broken shard is the defect, so
# the misconfigurations are asserted to be REFUSED rather than absorbed.
#
# Evaluated from the same extracted block, so these are the real refusals and not
# a description of them.
# ---------------------------------------------------------------------------
refuse() { # refuse <i> <n> <what is expected to be refused>
  local i="$1" n="$2" what="$3" out ec=0
  cases=$((cases + 1))
  # `bash -c ... "$SELF"` for the same reason `claims` uses it: the block counts
  # the suite's size from `"$0"`, and evaluated in a subshell of this file `$0` is
  # shard_test.sh -- so the over-provisioning refusal fired on a suite of ZERO
  # breakages and passed for the wrong reason.
  out="$(
    KIT_SELF_TEST_SHARD="$i/$n" bash -c "$_shard_block" "$SELF" 2>&1
  )" || ec=$?
  if [ "$ec" -eq 0 ]; then
    fail "$what: KIT_SELF_TEST_SHARD=$i/$n was ACCEPTED"
    printf '        %s\n' "${out:-<no output>}" | sed 's/^/        /' | head -5
  elif [ "$ec" -ne 2 ]; then
    fail "$what: KIT_SELF_TEST_SHARD=$i/$n exited $ec, not the 2 that means 'refused'"
  else
    pass "$what: KIT_SELF_TEST_SHARD=$i/$n is refused with exit 2 -- $(printf '%s' "$out" | head -1)"
  fi
}

refuse 0 "$SUITE_MAX" 'a 0-based shard index'
refuse $((SUITE_MAX + 1)) "$SUITE_MAX" 'a shard index past the end'
refuse 1 $((SUITE_MAX + 1)) 'an over-provisioned shard count'
refuse 1 0 'a zero shard count'
refuse 1 x 'a non-numeric shard count'

# And the END TO END one: a real `bash tests/self_test.sh` with more shards than
# breakages must refuse without starting a recipe. The eval above proves the
# block refuses; this proves the block is REACHED, which is a different claim and
# the one a reader of a log actually gets. Bounded, because the failure mode of a
# missing guard here is a run that starts copying a throwaway tree per breakage.
#
# `timeout` is RESOLVED rather than assumed -- GNU coreutils calls it `timeout`,
# macOS has no /usr/bin/timeout, Homebrew's installs `gtimeout`.
TO=""
for candidate in timeout gtimeout; do
  if command -v "$candidate" >/dev/null 2>&1; then
    TO="$candidate"
    break
  fi
done

cases=$((cases + 1))
if [ -z "$TO" ]; then
  note "no timeout binary on PATH; the end-to-end refusal is asserted by the eval above only"
else
  _out_file="$(mktemp "${TMPDIR:-/tmp}/kit-shard-refuse.XXXXXX")"
  _rc=0
  KIT_SELF_TEST_SHARD="1/$((SUITE_MAX + 1))" "$TO" 20 bash "$SELF" >"$_out_file" 2>&1 || _rc=$?
  if [ "$_rc" -eq 2 ] && grep -q 'cannot partition a suite numbered up to' "$_out_file"; then
    pass "an over-provisioned run of tests/self_test.sh refuses at the door: $(head -1 "$_out_file")"
  else
    fail "an over-provisioned run of tests/self_test.sh exited $_rc and said '$(head -1 "$_out_file")'"
    printf '        a run that starts here would copy a throwaway tree per breakage\n' >&2
  fi
  rm -f "$_out_file"
fi

printf '\n'
if [ "$failures" -ne 0 ]; then
  echo "FAIL: shard partition -- $failures of $cases assertions failed. A shard that"
  echo "      does not partition the suite is a gate reporting coverage it never ran."
  exit 1
fi
echo "PASS: shard partition -- $cases cases; the n shards partition $SUITE_SIZE breakages exactly once, and a shard that cannot is refused."
