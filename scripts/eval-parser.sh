#!/bin/bash
# eval-parser.sh: the command parser (grammar, then the on-device model) on
# tests/eval/parser-cases.tsv, the set it is tuned on. Needs Apple
# Intelligence on. Bar: 95%. Then the two held-out sets, which nothing is
# tuned on, to see that it holds up on phrasings it has never seen.
# KOBI_EVAL_RAW=1 also prints what the model alone answered for each miss.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P() { swift run --package-path "$ROOT/app/KobiKit" -c release kobi-probe parse-eval "$1"; }
P "$ROOT/tests/eval/parser-cases.tsv"; status=$?
for f in parser-holdout parser-holdout2; do
  echo; echo "Held out: $f"
  P "$ROOT/tests/eval/$f.tsv" | grep -v "^FAIL"
done
exit $status
