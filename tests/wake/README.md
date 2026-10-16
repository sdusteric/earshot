# Wake bench audio

Audio for tuning "Hey Earshot" without real recordings. The audio is generated
outside the repo and never committed.

Positives, near-misses and mentions (`phrases.tsv`), said by every English
Kokoro voice (a*, b*) plus say Samantha and Daniel, in 5 mic conditions:

    tests/wake/make-wake-audio.sh OUTDIR

It writes `OUTDIR/manifest.tsv` (file, label, class, voice, condition, split,
text). The split is by voice: every third voice in sorted order is `holdout`,
the rest are `tune`. A rerun skips files that exist. `JOBS=N` sets the number
of parallel jobs (default 10). The synth and degrade functions are copied from
`tests/hearing/make-audio.sh` and must stay the same as there.

Real human negatives (LibriSpeech test-clean, about 5.4 h, from
https://www.openslr.org/resources/12/test-clean.tar.gz unpacked into SRC):

    tests/wake/librispeech.sh SRC OUTDIR2

It writes `OUTDIR2/wav/*.wav` and `OUTDIR2/manifest.tsv`, whose file column is
`wav/ID.wav`, relative to the manifest. A rerun skips wavs that exist.

Run the bench with both manifests, each resolved relative to its own folder, and
the per-segment output in an explicit `--out` file (a name ending in
`manifest.tsv` is refused, so a manifest is never overwritten):

    earshot-probe wake-bench OUTDIR/manifest.tsv OUTDIR2/manifest.tsv --out RESULTS.tsv

Other flags: `--confirmers ctc,apple,parakeet` (default all three) and
`--limit N` (the first N files of each manifest, for a smoke test).

How the run goes:

- Segments are cut as the listener cuts them, and the spotter scores each one,
  for "hey earshot" (the score column) and, on the same pass of the model, for
  "earshot" alone (the bare column, `CtcWakeSpotter.barePhrase`; the listener
  does not use it). A segment whose two scores are both under -9.5 (the floor of
  the sweep, under -9.25, the threshold at sensitivity 10) is not run through
  the confirmers; it is recorded as not fired.
- Each confirmer is held to the listener's confirm limit
  (`Listener.Timing().confirmLimit`, 0.75 s). A look that takes longer counts
  as no answer. The pass column is the listener's confirm: words pass by
  `Listener.confirmsWake` (any tier), and no answer passes only when the spotter scored
  -5.0 or more (`CtcWakeSpotter.unconfirmedThreshold`). wake-rescore counts no
  answer the same way. The report counts these per confirmer.
- The parakeet column is the best case: the bench keeps Parakeet loaded all
  run. Live it is loaded only after a command and unloaded after 10 idle
  minutes, and a confirm never loads it or keeps it loaded, so it usually has
  no answer and the wake falls to the strict score.

The report prints, per confirmer and per threshold, the positives woken by
split and by condition, the near-misses and mentions that falsely wake by split,
and the LibriSpeech fires and false wakes per hour, then the positives woken by
split and condition at the thresholds of sensitivity 1, 5 and 10. With apple and
parakeet both run it ends with the end to end block (see Rescoring). Pick the
threshold and confirmer on the `tune` columns only, then check `holdout` once.

## The two tiers

The confirm (`Listener.wakeWords`) passes a head that starts with the wake
phrase. What it does then falls in one of two tiers:

- Literal: a greeting (hey, hi, high, hay, hate, eight, 8, a, ok, okay), then the
  phrase written as such, "earshot", "earshots", "ear shot" or "air shot". Only
  this tier sends the words after the phrase.
- Window only: the wake chimes and opens the command window, but nothing of the
  segment is sent. Two shapes:
  - Bare: "Earshot" or "ear shot" as the first word with no greeting, and a comma
    or a stop after it, or nothing after it ("Earshot, stop", "Ear shot."). A
    noise gate that cuts the start of a mention leaves the same words ("did you
    ask earshot to run the tests" heard as "Ear shot. To run."), so they can't be
    told from an address.
  - Sound-alike: a greeting, then a word or two that sound like "earshot" (sound
    key ARXT, ending in "shot" or "shots") but are spelled otherwise: "your
    shot", "you're shot", "year shot", "we're shot", "our shots". "Okay, your
    shot. Approve it." sounds the same.

The phrase is never taken later in the text: "Earshot is listening" and "did you
ask earshot to run the tests" are about Earshot.

At finish the literal tier is decided on the unboosted hearings only: the plain
transcript (or the boosted one when the session-name boost changed nothing),
then, for a wake passed on words, the second hearing. The boosted transcript
alone never counts, since a session named earshot makes the boost write
"earshot" over a sound-alike ("Okay, your shot. Stop the build." became "Okay,
earshot stop the blog"). The command is the boosted words after the phrase when
they have it too, otherwise the unboosted words'. A wake's own clip is also
heard without the names that spell the phrase ("earshot", "Earshot Spike",
"airshot": `Listener.wakeVocabulary`). Found, the words after the phrase are the
command; the phrase alone opens the window, and a command said during the
confirm is kept. Not found, nothing of the segment is sent: a wake passed on
words opens the window, which takes only speech that starts after the chime,
and one passed on the strict score alone is dropped.

So false wakes come in two kinds, counted apart per class:

- dispatch: a greeting and the phrase written as such, with words after it, on a
  negative. Those words go out as a command, and "approve it" can approve a
  pending permission prompt. This is the number that must stay at zero.
- window: a chime that sends nothing of the segment and only opens the command
  window (bare, a sound-alike, the phrase alone, or a transcript without the
  phrase).

## Running it in shards

A single long process degrades Apple's recognizer, so the bench's Apple column
stops meaning what the listener gets. Run about 1000 files per process, each shard a
manifest of its own in the same folder as the full one (the file column is
relative to the manifest), and keep the per-segment output of each:

    probe=app/EarshotKit/.build/release/earshot-probe   # swift build -c release first
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

    earshot-probe wake-rescore RESULTS/*.out.tsv
    earshot-probe wake-rescore RESULTS/*.out.tsv --threshold -8

It prints, for the stripWake rule and the listener's rule (`Listener.wakeWords`,
both tiers) and for apple, parakeet and the two OR'd, the positives woken by
split and condition, the near-misses and mentions that falsely wake by split
(dispatch and window apart), LibriSpeech fires and false wakes of each kind an
hour (taken as 5.40 h), and the confirm's p50 and p95. In these confirm-only
tables the head's own words stand in for what the finish would send, and a look
with no answer (passed on the strict score) counts as window. Then the same
table end to end, as the listener runs a wake: Apple's confirm passes it, then
the finish rule (`Listener.finishRemainder`) runs with Parakeet's head text as
the unboosted transcript (the confirm hears it with no names) and Apple's head
text as the second hearing.
That is a stand-in: live, the finish hears the whole command, not the head. A
segment with no Parakeet text is an empty transcript there, as a failed
transcription is. With `--threshold T` it prints only that row, then positives
by split and condition, and every near-miss, mention and LibriSpeech segment
that the listener's rule or the end to end rule wakes at T, with its kind and
what was heard. The shipped setting is the `wakeWords (both tiers), second
look: apple` block at -8.0; the end to end block is what a wake costs and
catches once the command is finished.

## The bare term

With a bare column (TSVs from before it have none) and Apple's look, the
report and wake-rescore end with the bare term's sweep: the phrase held at -8.0
(or `--threshold T`) with the listener's rule, and "earshot" alone firing a
segment the phrase did not, at each bare threshold. A bare fire passes only on
Apple's words (`Listener.confirmsWake`, any tier; no answer never passes it) and
is counted as window, whatever the words: it would chime and open the command
window, never send. The first row (inf) is the shipped wake. `--bare B` adds the
positives by split and condition at B and lists every negative woken there.
Measured on 2026-10-16 and not adopted (tests/app-e2e.md, the wake section):

    earshot-probe wake-rescore RESULTS/*.out.tsv --threshold -8 --bare -8.5
