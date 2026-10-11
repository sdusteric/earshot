#!/bin/bash
# eval-parser.sh: the command parser (grammar, then the on-device model) on
# tests/eval/parser-cases.tsv. Needs Apple Intelligence on. Bar: 95%.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift run --package-path "$ROOT/app/EarshotKit" -c release earshot-probe parse-eval "$ROOT/tests/eval/parser-cases.tsv"
