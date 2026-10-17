# Wake bench audio

Audio for tuning "Hey Kobi" without real recordings. The audio is generated
outside the repo and never committed.

Positives, near-misses, mentions and collisions (`phrases.tsv`), said by every
English Kokoro voice (a*, b*) plus say Samantha and Daniel, in 5 mic conditions:

    tests/wake/make-wake-audio.sh OUTDIR

It writes `OUTDIR/manifest.tsv` (file, label, class, voice, condition, split,
text). The split is by voice: every third voice in sorted order is `holdout`,
the rest are `tune`. A rerun skips files that exist, and rewrites the manifest
from phrases.tsv (so a changed class needs no new audio). `JOBS=N` sets the
number of parallel jobs (default 10). The synth and degrade functions are
copied from `tests/hearing/make-audio.sh` and must stay the same as there.

The classes:

- positive: "Hey Kobi" in the shapes the listener takes (label 1).
- nearmiss: other names and everyday words that share sounds ("Hey Toby, run
  the tests", "copy that", "okay Colby, stop"). They must not wake.
- mention: the name, but not as a wake at the start ("is Kobi still running",
  "Kobe beef is expensive"). They must not wake.
- collision: a name said the same as "Kobi" ("hey Kobe, run the tests",
  "hey Coby, stop"). They wake, as "Hey Kobi" does: no recognizer can tell
  them apart. They are counted and reported, not counted as false wakes.

Real human negatives (LibriSpeech test-clean, about 5.4 h, from
https://www.openslr.org/resources/12/test-clean.tar.gz unpacked into SRC):

    tests/wake/librispeech.sh SRC OUTDIR2

It writes `OUTDIR2/wav/*.wav` and `OUTDIR2/manifest.tsv`, whose file column is
`wav/ID.wav`, relative to the manifest. A rerun skips wavs that exist.
test-clean never says kobi or kobe, so every clip is label 0.

Run the bench with both manifests, each resolved relative to its own folder, and
the per-segment output in an explicit `--out` file (a name ending in
`manifest.tsv` is refused, so a manifest is never overwritten):

    kobi-probe wake-bench OUTDIR/manifest.tsv OUTDIR2/manifest.tsv --out RESULTS.tsv

Other flags: `--confirmers ctc,apple,parakeet` (default all three) and
`--limit N` (the first N files of each manifest, for a smoke test).

How the run goes:

- Segments are cut as the listener cuts them, and the spotter scores each one,
  on one pass of the model, three ways: "hey kobi" (the score column,
  `CtcWakeSpotter.phrase`), "hey kobe" (the other column,
  `CtcWakeSpotter.otherPhrase`) and "kobi" alone (the bare column,
  `CtcWakeSpotter.barePhrase`; the listener does not use it). The listener
  wakes on the higher of score and other (`CtcWakeSpotter.score`). A segment
  whose scores are all under -9.5 (the floor of the sweep, under -9.25, the
  threshold at sensitivity 10) is not run through the confirmers; it is
  recorded as not fired.
- Each confirmer is held to the listener's confirm limit
  (`Listener.Timing().confirmLimit`, 0.75 s). A look that takes longer counts
  as no answer. The pass column is the listener's confirm: words pass by
  `Listener.confirmsWake` (any tier), and no answer passes only when the
  listener's score is -4.0 or more (`CtcWakeSpotter.unconfirmedThreshold`).
  wake-rescore counts no answer the same way. The report counts these per
  confirmer.
- The parakeet column is the best case: the bench keeps Parakeet loaded all
  run. Live it is loaded only after a command and unloaded after 10 idle
  minutes, and a confirm never loads it or keeps it loaded, so it usually has
  no answer and the wake falls to the strict score.

The report prints, per confirmer and per threshold, the positives woken by
split and by condition, the near-misses and mentions that falsely wake and the
collisions that wake, by split, and the LibriSpeech fires and false wakes per
hour, then the positives woken by split and condition at the thresholds of
sensitivity 1, 5 and 10, with how many of them dispatch in brackets. With apple
and parakeet both run it ends with the end to end block (see Rescoring). Pick
the threshold and confirmer on the `tune` columns only, then check `holdout`
once.

## The two tiers

The confirm (`Listener.wakeWords`) passes a head that starts with the wake
phrase. What it does then falls in one of two tiers:

- Literal: a greeting (hey, hi, high, hay, hate, eight, 8, a, i, k, ok, okay),
  then the name written as such: "kobi", "kobe" or "koby"
  (`Listener.nameSpellings`). Apple's recognizer wrote "Kobe" for most "Kobi"s
  on the bench and "Kobi" almost never; "K Kobe" is a mis-heard "Okay Kobi",
  "I Kobe" a mis-heard "Hi Kobi". Only this tier sends the words after the name.
- Window only (bare): the name as the first word with no greeting, and a comma
  or a stop after it, or nothing after it ("Kobe, stop", "Kobe."). The wake
  chimes and opens the command window, but nothing of the segment is sent: a
  noise gate that cuts the start of a mention leaves the same words ("can Kobi
  read my mail" heard as "Kobe, read my mail.").

The name is never taken later in the text, nor run into a sentence at the
start: "Kobe is listening" and "did you ask kobi to run the tests" are about
Kobi.

There is no sound-alike tier. Names that recognizers sometimes write for
"Kobi" are other people's names too, and on the tune split each cost more
near-miss windows than it won positives: "Colby" after a greeting won 30
positives for 169 near-miss windows, "Toby" 8 for 240, "Obi" and "Gobi" 0 for
96. "Coby" as a literal spelling won 6 positives and woke 3 near-misses and
mentions, so it is left out too.

At finish the literal tier is decided on the unboosted hearings only: the plain
transcript (or the boosted one when the session-name boost changed nothing),
then, for a wake passed on words, the second hearing. The boosted transcript
alone never counts, since a session named kobe would make the boost write
"Kobe" over another name ("Hey Toby, approve it" read as "Hey Kobe, approve
it"). The command is the boosted words after the name when they have it too,
otherwise the unboosted words'. A wake's own clip is also heard without the
session names that have a spelling of the name in them ("kobi", "Kobe app":
`Listener.wakeVocabulary`). Found, the words after the name are the command;
the name alone opens the window, and a command said during the confirm is
kept. Not found, nothing of the segment is sent: a wake passed on words opens
the window, which takes only speech that starts after the chime, and one
passed on the strict score alone is dropped.

So false wakes come in two kinds, counted apart per class:

- dispatch: a greeting and the name written as such, with words after it, on a
  negative. Those words go out as a command, and "approve it" can approve a
  pending permission prompt. This is the number that must stay at zero.
- window: a chime that sends nothing of the segment and only opens the command
  window (bare, the phrase alone, or a transcript without the phrase).

## Running it in shards

A single long process degrades Apple's recognizer, so the bench's Apple column
stops meaning what the listener gets. Run about 1000 files per process, each shard a
manifest of its own in the same folder as the full one (the file column is
relative to the manifest), and keep the per-segment output of each. Three shards
at a time ran with no confirm timeouts on an 18-core Mac (about 45 min in all):

    probe=app/KobiKit/.build/release/kobi-probe   # swift build -c release first
    for m in OUTDIR OUTDIR2; do
      head -1 $m/manifest.tsv > $m/header
      tail -n +2 $m/manifest.tsv | grep -v '^#' | split -l 1000 - $m/shard-
      for s in $m/shard-??; do
        { cat $m/header; cat $s; } > $s.tsv && rm $s
        out=RESULTS/$(basename $m)-$(basename $s).out.tsv
        [ -s $out ] && continue   # a rerun skips finished shards
        $probe wake-bench $s.tsv --out $out > ${out%.out.tsv}.log 2>&1
      done
    done

Each shard's log has its own report; the totals come from wake-rescore.

## Rescoring

`wake-rescore` reads the per-segment TSVs again and works out each look's pass
from the text it heard, so a confirm rule can be tried without the audio:

    kobi-probe wake-rescore RESULTS/*.out.tsv
    kobi-probe wake-rescore RESULTS/*.out.tsv --threshold -8
    kobi-probe wake-rescore RESULTS/*.out.tsv --threshold -8 --spotter phrase

It prints, for the stripWake rule and the listener's rule (`Listener.wakeWords`,
both tiers) and for apple, parakeet and the two OR'd, the positives woken by
split and condition, the near-misses and mentions that falsely wake and the
collisions that wake, by split (dispatch and window apart), LibriSpeech fires
and false wakes of each kind an hour (taken as 5.40 h), and the confirm's p50
and p95. `--spotter` picks the score that fires a segment: phrase ("hey kobi"),
other ("hey kobe") or max (the higher); the default is the listener's. In these
confirm-only tables the head's own words stand in for what the finish would
send, and a look with no answer (passed on the strict score) counts as window.
Then the same table end to end, as the listener runs a wake: Apple's confirm
passes it, then the finish rule (`Listener.finishRemainder`) runs with
Parakeet's head text as the unboosted transcript (the confirm hears it with no
names) and Apple's head text as the second hearing.
That is a stand-in: live, the finish hears the whole command, not the head. A
segment with no Parakeet text is an empty transcript there, as a failed
transcription is. With `--threshold T` it prints only that row, then positives
by split and condition, and every near-miss, mention, collision and LibriSpeech
segment that the listener's rule or the end to end rule wakes at T, with its
kind and what was heard. The end to end block at -8.0 is what a wake costs and
catches once the command is finished.

## Results, 2026-10-17 ("Hey Kobi")

18300 synthetic clips (32 positives, 62 near-misses, 18 mentions, 10
collisions, by 30 voices, by 5 conditions) and 2620 LibriSpeech clips (5.4 h).
Apple answered every confirm (no timeouts, no "no answer"). End to end at -8.0
(sensitivity 5), with the listener's score (the higher of "hey kobi" and "hey
kobe"):

| Split | Clean | Quiet | Gate 0.2 | Gate 0.4 | Gate 0.6 | All |
|---|---|---|---|---|---|---|
| tune (of 640 each) | 619 (97%) | 499 (78%) | 296 (46%) | 44 (7%) | 2 (0%) | 1460/3200 (46%) |
| holdout (of 320 each) | 300 (94%) | 265 (83%) | 166 (52%) | 20 (6%) | 3 (1%) | 754/1600 (47%) |
| both, "Hey Earshot" at -8.0 (of 960 each) | 814 (85%) | 441 (46%) | 352 (37%) | 45 (5%) | 5 (1%) | |
| both, "Hey Kobi" (of 960 each) | 919 (96%) | 764 (80%) | 462 (48%) | 64 (7%) | 5 (1%) | |

Of the positives that woke, those whose words went out in the same breath
(tune + holdout): clean 640, quiet 555, gate 0.2 86, gate 0.4 1, gate 0.6 0.
Only 22 of the 32 positive phrases have a greeting, the name and a command
(660 clips per condition), so in clean and quiet 97% and 84% of those
dispatched. Under a gate the greeting is cut and the wake is bare: it chimes,
and the command is said again.

False wakes at -8.0:

| Class (clips) | Dispatch tune | Dispatch holdout | Window tune | Window holdout |
|---|---|---|---|---|
| Near-miss (6200 tune, 3100 holdout) | 0 | 0 | 11 (0.2%) | 2 (0.1%) |
| Mention (1800 tune, 900 holdout) | 0 | 0 | 15 | 7 |
| LibriSpeech (5.40 h) | 0.00 an hour | | 0.00 an hour | |

The spotter fires 200.2 times an hour on LibriSpeech. 20 of the 22 mention
windows are in the noise gates (the start of the sentence is cut, so Apple
hears "Kobe, read my mail."). Of the 13 near-miss windows, 10 are in the gates
("hey Toby", "hey Gobi", "hey Hobie" or "hey Kofi" heard as "Kobe, ..." or
"Hey, Kobe."), and 3 are quiet clips heard as a greeting and "Kobe" ("hey
Kofi", "hi Cody", "okay Cody").

Collisions (1000 tune, 500 holdout) woke 431 and 214: 202 and 106 dispatched.

Spotter score, tune, end to end at -8.0: "hey kobi" alone 1408/3200, "hey
kobe" alone 1457, the higher of the two 1460, all with 0 dispatch false wakes.

Thresholds, tune, end to end:

| Threshold | Positives | Near-miss dispatch | Near-miss window | Mention window | LibriSpeech fires/h |
|---|---|---|---|---|---|
| -7.0 (sensitivity 1) | 1252 | 0 | 4 | 10 | 60.7 |
| -7.5 | 1371 | 0 | 7 | 13 | 123.9 |
| -8.0 (sensitivity 5) | 1460 | 0 | 11 | 15 | 200.2 |
| -8.5 | 1512 | 0 | 16 | 16 | 282.2 |
| -9.25 (sensitivity 10) | 1559 | 1 | 22 | 17 | 379.8 |

The one dispatch at -9.25 is "okay Cody, go ahead" through a 0.2 gate, which
Parakeet heard as "Hey Kobe, go on." Apple's confirm takes 52 ms at the median
and 65 ms at the 95th percentile.

The strict score (no recognizer answer), spotter alone on tune: at -4.0 clean
positives 52%, quiet 5%, near-misses 2% (127/6200), LibriSpeech 0 an hour; at
-5.0 near-misses 9% and one LibriSpeech clip.

Apple's contextual strings ("Hey Kobi", "Kobi") changed none of the heads of
2250 clips on a first probe of 15 phrases, against none at all, or with "Kobe"
added.

## The bare term

With a bare column (TSVs from before it have none) and Apple's look, the
report and wake-rescore end with the bare term's sweep: the phrase held at -8.0
(or `--threshold T`) with the listener's rule, and "kobi" alone firing a
segment the phrase did not, at each bare threshold. A bare fire passes only on
Apple's words (`Listener.confirmsWake`, any tier; no answer never passes it) and
is counted as window, whatever the words: it would chime and open the command
window, never send. The first row (inf) is the shipped wake. `--bare B` adds the
positives by split and condition at B and lists every negative woken there.
For "Hey Earshot" it was measured on 2026-10-16 and not adopted
(tests/app-e2e.md, the wake section). For "Hey Kobi", with the phrase at -8.0
and "kobi" alone at -8.0, it adds 31 tune positives (1491 of 3200) for 3 more
near-miss windows, all window only; the listener does not use it:

    kobi-probe wake-rescore RESULTS/*.out.tsv --threshold -8 --bare -8
