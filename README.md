# OpenRoom

[English](README.md) · [繁體中文](README.zh-TW.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md)

Local-only live meeting transcription. Apple Silicon Mac, one meeting at a time.

A rewrite of the old version (the Python/FastAPI/React project at
`github.com/SammyLin/huddle`). What killed the old version was not the language or the
framework, it was that **every failure path was silent**: audio arriving before the
session was ready got dropped without a word, sending on an unopened socket silently
returned false, a typo in an engine name silently fell back to a fake-data generator,
energy below a hardcoded threshold was silently skipped. What the user saw was "it
doesn't pick up audio, and it doesn't analyze either", with no way to tell which part
had broken.

So the first rule of this version is not model quality:

> **No silent degradation.** Every degradation, drop, or skip must emit a visible event.

## Decisions

| Item | Decision |
|---|---|
| Form | Single-machine personal tool. One meeting at a time, Apple Silicon only |
| Backend | Python 3.11 |
| Frontend | Tailwind + shadcn (UX redesigned) |
| ASR | Qwen3-ASR MLX (on-device) |
| Diarization | pyannote.audio, **in a separate process from ASR** |
| Languages | Chinese and English both first-class, including intra-sentence mixing |
| Audio source | macOS system audio capture (records Teams / Google Meet) |
| Storage | Files under `runs/`. The original decision was SQLite; one machine running one meeting writes once and reads once, so a database earned nothing |
| Not doing | Postgres, Docker, Cloud Run, JWT, CORS, rate limiting, simulator |

### Pass marks (carried over from the old PRD §4 NFR)

| Metric | Target |
|---|---|
| partial latency | < 800 ms P95 |
| final latency | < 3 s P95 |
| speaker-change detection latency | < 2 s |
| DER | < 15% |
| Traditional Chinese WER | < 12% |

The old PRD's "≥ 10 concurrent meetings" is void — one machine with one GPU cannot do
it, and does not need to.

## Build order

1. ~~**eval harness**~~ done
2. ~~audio → WS → written to disk~~ done (WS side done; macOS system audio capture still to do)
3. ~~Qwen3-ASR MLX (separate process)~~ latency gate passed, **WER has not** (29.4%, gate 12%)
4. ~~frontend: transcript + health panel~~ done
5. ~~live analysis layer (interview / discussion)~~ done, including transcript export
6. **Run a real meeting on it** ← we are here. Chinese WER 37.6%, latency passes the gate, it is readable
7. WER: feed proper nouns via `context`, `finalization_mode` (boundary duplication in the merge layer already fixed, worth 2pp)
8. ~~pyannote speaker diarization (separate process)~~ done, DER not measured yet
9. ~~macOS system audio capture~~ done: `native/openroom-capture`, ScreenCaptureKit grabs
   the system output (no reliance on browser tab sharing, so the Teams desktop app is
   captured too) and connects to the backend as a WS client straight off
   `docs/protocol.md`. The first run needs authorization under System Settings >
   Privacy & Security > Screen & System Audio Recording.

The LLM layer, originally scheduled last, was moved up: the transcript is only raw
material, **"give me supporting material and follow-up questions while the meeting is
still going" is the reason this tool exists**, and only running it tells you how
accurate the transcript actually has to be.

And grinding on WER sits **after** real usage because the gate was copied from the old
PRD, not measured as a requirement. A broken English transcript at 32% WER still lets
the analysis layer produce usable supporting material — so the primary metric is
insight quality, and WER is only a diagnostic. Labeling insight quality requires
something to label, which is why events are written to disk
(`runs/<timestamp>-<meeting_id>/events.jsonl`).

## Running it

```bash
uv venv --python 3.11 && source .venv/bin/activate
uv pip install -e '.[eval,dev,diarize]' 'mlx-qwen3-asr>=0.3.5'

export HF_TOKEN=hf_...                    # the diarization model is a gated repo, see below
python -m openroom.server --language en     # omit --language to auto-detect (use this for mixed zh/en)

cd app && npm install && npm run dev      # frontend → http://localhost:5173
```

The server warms the model up first (the first run compiles Metal kernels, about 46
seconds) and **only sends `ready` once warmup is done**. Audio sent before that gets an
`error` back instead of being quietly swallowed. The frontend **buffers** rather than
discards until `ready`, then resends in seq order — what gets held back is the opening
remarks, and once dropped they are gone.

Every session writes to `runs/<timestamp>-<meeting_id>/`: `audio.raw` (raw PCM),
`events.jsonl` (**every** event sent to the frontend, with `_wall_ms` and `infer_ms`),
`transcript.txt`. No SQLite — one machine, one meeting at a time, written once and read
once.

Choosing "system audio" in the frontend goes through the browser's screen-sharing
dialog, and you **must tick "share tab audio"**; without it there is no audio track, and
in that case it errors out rather than quietly recording silence.

### Speaker diarization

pyannote runs in its own process and re-runs over "the whole audio so far", so speaker
identities stay consistent over time. The model is a **gated repo**: accept the terms at
<https://huggingface.co/pyannote/speaker-diarization-community-1> first, then set
`HF_TOKEN`. Without it you get `speaker_error` rather than quietly losing speaker
labels.

```bash
python -m openroom.server --no-diarize            # turn off when measuring ASR latency, both sides fight over the same GPU
python -m openroom.server --diarize-idle-ratio 12 # more conservative: steadier ASR, later speaker labels
```

**Speaker labels are backfilled**, arriving tens of seconds behind the transcript; that
is real-time traded for identity consistency. Measurements are in
`docs/measurements.md`.

### Analysis layer

It listens along and adds material; the scenario decides what it looks for. `interview`
picks out wrong answers and the questions worth following up on; `discussion` fills in
proper nouns and background. The LLM goes through the `claude` CLI's print mode by
default (borrowing Claude Code's login, since this machine has no `ANTHROPIC_API_KEY`),
so every round costs money and the trigger is throttled: it runs only once 400
characters have accumulated and 25 seconds have passed since the last round, and skips
if the previous round has not come back.

```bash
python -m openroom.server --scenario interview --llm-model claude-sonnet-5
python -m openroom.server --no-web-search   # stop it from searching the web to verify
```

Analysis always queues behind audio capture (`nice -n 15`, background task, and the
whole round yields if ASR falls more than 6 seconds behind). Every skip sends
`insight_error`, so the reason is visible in the UI.

**The LLM provider is swappable**, selected with the `OPENROOM_LLM_PROVIDER` environment
variable (default `claude-cli`, behavior unchanged):

| provider | Description | Related env vars |
|---|---|---|
| `claude-cli` | Default, `claude -p ... --output-format json` |(none)|
| `cli` | Swap in a compatible CLI (same `-p`/`--output-format json` contract)| `OPENROOM_LLM_CLI` (tool name, e.g. `codex`, `gemini`) |
| `anthropic-api` | Calls the Anthropic Messages API directly | `ANTHROPIC_API_KEY` |
| `ollama` | Calls a local Ollama server | `OLLAMA_HOST` (default `http://localhost:11434`), `OPENROOM_OLLAMA_MODEL` (default `llama3.1`) |

```bash
OPENROOM_LLM_PROVIDER=anthropic-api ANTHROPIC_API_KEY=sk-ant-... python -m openroom.server
OPENROOM_LLM_PROVIDER=ollama OPENROOM_OLLAMA_MODEL=llama3.1 python -m openroom.server
```

All four providers behave the same way: any failure sends `insight_error`, none of them
quietly returns an empty result.

## The Mac app

`native/OpenRoomApp` is the front end: a SwiftUI app that launches the Python backend in
this repo and speaks the same WebSocket protocol the browser does. It is packaged by a
shell script, not an Xcode project.

```bash
native/OpenRoomApp/build-app.sh   # → native/OpenRoomApp/OpenRoom.app
```

The app is a front end and nothing else. ASR and diarization run in the Python backend
in this repo, which the app starts for you — it looks for the repo at
`~/workspaces/slab/openroom` unless `OPENROOM_REPO_PATH` says otherwise. Install the
backend first (see [Running it](#running-it)); without it the app opens and then cannot
transcribe anything.

### The downloaded build will not open

Releases carry a `.dmg`, and macOS will refuse to open what is inside it:

> "OpenRoom" Not Opened — Apple could not verify "OpenRoom" is free of malware that may
> harm your Mac or compromise your privacy.

That is correct behaviour, not a broken build. Signing this app with a Developer ID and
notarizing it requires a paid Apple Developer account, so the releases are ad-hoc signed
(`codesign --sign -`) and carry no notarization ticket. Anything downloaded from the
internet is quarantined, and macOS refuses to run un-notarized quarantined code.

The whole difference is one certificate. A project that opens without any of this — say
[openusage](https://github.com/robinebers/openusage), whose release workflow this one is
modelled on — ships a DMG signed by `Developer ID Application: … (QC3D3H67V9)` and
chaining to `Apple Root CA`, with a notarization ticket stapled to it. Ours reports
`Signature=adhoc`, `TeamIdentifier=not set`, and `does not have a ticket stapled to it`.
`release.yml` here already performs exactly the same signing, notarization and stapling
steps; with the secrets absent they are skipped, which is what the release log shows.
Nothing in the code needs to change — enrolling and adding the secrets is the entire gap.

Building it yourself is the honest way around this, and the only one that does not ask
you to switch off a protection: `build-app.sh` produces a bundle that was never
quarantined, so it opens normally.

To run a downloaded build anyway, System Settings → Privacy & Security → Security →
"Open Anyway", or:

```bash
xattr -dr com.apple.quarantine /Applications/OpenRoom.app
```

Understand what that does before you run it: quarantine is what makes macOS check
downloaded code at all, and stripping it turns that check off for this app. It is a
reasonable thing to do to a binary you built from source you can read. It is not a
reasonable habit to apply to software generally, and this README is not the place you
should be learning the command for someone else's download.

**Auto-update still works, and this is the only time you have to do it.** Gatekeeper
gates the copy *you* downloaded; Sparkle's updates do not go through it.
`SUUpdateValidator` accepts an update when its EdDSA signature validates *or* its code
signature matches the running app — either is sufficient, so an ad-hoc build updates on
the strength of the EdDSA signature alone. `SUFileManager` then strips
`com.apple.quarantine` from the extracted update before installing it. Getting past
Gatekeeper once, on first install, is the whole of the cost.

(That reading is from Sparkle's source, not from an observed update on a second machine.
It is the reason the update path was wired up rather than deferred until a certificate
exists, but a real cross-machine update has not been performed yet.)

### Updating itself

The app checks for its own updates through Sparkle 2. `SUEnableAutomaticChecks` is
deliberately **not** written into `Info.plist`, which means Sparkle asks on first launch
whether it may check at all — it does not reach the network before the user answers.
After that it checks once a day (`SUScheduledCheckInterval`, 86400 seconds), plus
whenever "Check for Updates…" in the app menu is used.

The feed is <https://sammylin.github.io/OpenRoom/appcast.xml>, served from this repo's
`gh-pages` branch. The downloads it points at are the `.dmg` assets on the matching
GitHub Releases.

Every update is verified by EdDSA signature against the `SUPublicEDKey` baked into
`Info.plist` at build time. A download whose signature does not verify is refused, not
installed. A build with no `SUPublicEDKey` gets no updater at all: `build-app.sh` ends its
output with `auto-update DISABLED (no SPARKLE_PUBLIC_ED_KEY)`, the app writes
`no SUPublicEDKey in Info.plist — auto-update disabled` to stderr, and the menu item is
greyed out reading "Updates unavailable — this build has no update key". There is no
fallback that installs an unverified download, and no flag to turn one on.

Steps 1 to 4 are already done for this repository: the key pair exists, both halves are
repository secrets, Pages serves <https://sammylin.github.io/OpenRoom/appcast.xml>, and
the feed carries a signed item for the current release. The public key in it is
`WB8oDu+EGNgiVYDD5f+tcYo4OP7XWWJZSvvnyBQ8A/M=`, which matches the `SUPublicEDKey` in the
shipped `Info.plist`. Only step 5, the Apple signing secrets, is outstanding — and that
one buys a first install without the Gatekeeper detour, not the ability to update.

The list above is what a fork would have to redo.

### Releasing

**Without a Developer ID certificate and notarization, auto-update is useless in
practice.** An adhoc-signed build is blocked by Gatekeeper on every machine except the one
that built it, and that applies to the copy Sparkle downloads exactly as it applies to a
copy downloaded by hand — the update ends in a Gatekeeper refusal instead of a new
version. `release.yml` says so loudly (a `::warning::` for every missing secret, and a
warning section in the release notes), but saying it loudly does not make it work. Until
the Apple secrets exist, the honest way to distribute this is `build-app.sh` on the user's
own machine.

One-time setup:

1. Generate the Sparkle key pair. `generate_keys` ships inside Sparkle's SwiftPM artifact,
   so build once first:

   ```bash
   swift build --package-path native/OpenRoomApp -c release
   gen=$(find native/OpenRoomApp/.build/artifacts -name generate_keys -perm -u+x | head -1)
   "$gen"                                # generates the pair, stores the private key in the login keychain
   "$gen" -p                             # print the public key
   "$gen" -x sparkle_private_key.txt     # export the private key for CI, then delete the file
   ```

2. Add the exported private key as the repository secret `SPARKLE_PRIVATE_KEY` (Settings →
   Secrets and variables → Actions). Without it the workflow skips the appcast entirely and
   warns that this release will not be offered to anyone — a partial feed is worse than no
   feed. The key is piped to `generate_appcast` on stdin, never through argv and never onto
   the runner's disk.

3. Add the public key as the repository secret `SPARKLE_PUBLIC_ED_KEY`. `build-app.sh`
   reads it from the environment and writes it into `Info.plist` as `SUPublicEDKey`;
   `release.yml` passes it through on every tagged build. The two keys are refused unless
   they arrive together — a private key without its public half would sign an appcast for
   an app that has no way to verify it, which fails on the user's machine and nowhere
   else.

4. Enable GitHub Pages on the `gh-pages` branch (Settings → Pages → Deploy from a branch,
   `gh-pages`, `/ (root)`) so the feed URL above actually serves. The branch is created by
   the first release that has `SPARKLE_PRIVATE_KEY`.

5. Add the Apple signing secrets: `APPLE_CERTIFICATE` (a Developer ID Application `.p12`,
   base64-encoded) and `APPLE_CERTIFICATE_PASSWORD` for signing; `APPLE_ID`,
   `APPLE_PASSWORD` (an app-specific password) and `APPLE_TEAM_ID` for notarization. The
   workflow checks what it imported and stops if the keychain holds anything other than a
   Developer ID Application identity.

Then a release is a tag:

```bash
git tag v0.2.0 && git push origin v0.2.0                  # stable: offered to every install
git tag v0.2.0-beta.1 && git push origin v0.2.0-beta.1    # prerelease: beta channel only
```

The tag shape decides everything, once, at the top of the workflow: a `-` in the tag makes
it a GitHub prerelease and puts its appcast item on Sparkle's `beta` channel; a clean tag
carries no channel, which is what every install subscribes to. Note that nothing in the app
subscribes to `beta` today — the updater is created with no delegate, so no install ever
asks for that channel — which means a `-beta.1` tag reaches only people who download it by
hand.

The workflow refuses to publish rather than publish something broken: it fails if
`Info.plist` disagrees with the tag, if notarization comes back anything but `Accepted`, if
the generated appcast has no signed enclosure for this release, or if the feed came out with
fewer items than it went in with.

## eval harness

Without numbers there is no way to say whether the rewrite made anything better, so the
harness came before any product code.

```bash
uv venv --python 3.11 && source .venv/bin/activate
uv pip install -e '.[eval]'

# fetch corpus: YouTube video → 16k mono wav + official subtitles as ground truth
python -m eval.corpus fetch 'https://www.youtube.com/watch?v=...'

# list the corpora already fetched
python -m eval.corpus list

# feed audio into the WS at real-time pace (same path the microphone takes), measure P95 latency
python -m eval.feed corpus/<slug>/audio.wav --ws ws://127.0.0.1:8000/ws/test

# compute WER (per-character for CJK, per-word for Latin, no language flag needed; comparing only the first N seconds requires reference.jsonl)
python -m eval.metrics wer corpus/<slug>/reference.jsonl hypothesis.txt --until-sec 120
```

When measuring ASR, start the server with `--no-analyst` so you do not pay the LLM once
per run.

**Manual subtitles are not necessarily a transcript — they can be a translation** (been
there: an English interview with Chinese subtitles, the resulting 80% WER was entirely
fake). `fetch` compares against the video's language and warns; `--langs` sets the
preferred order of subtitle languages.

Corpora live in `corpus/`, not under version control.

### Test material

- **GitLab Unfiltered** (<https://www.youtube.com/@GitLabUnfiltered/videos>) — real
  multi-person meetings on a single mixed track, exactly what diarization is up against.
  Official subtitles work as WER ground truth, but **English WER is not a product
  metric**.
- **塞掐 Side Chat E417** (`6h6VsrclFTI`) — Chinese interview, mixed Chinese/English,
  **manual zh-TW subtitles** (a human transcript, more trustworthy than auto-generated
  ones). This is the baseline for Traditional Chinese WER.
- **AMI Corpus** — full speaker annotations, the objective baseline for DER. To be wired
  up when diarization gets there.

The feeder schedules chunk *k* for `t0 + k × 100 ms` itself rather than leaning on
`ffmpeg -re`, whose accuracy moves between ffmpeg versions — the same three seconds of
audio feeds in 2872 ms through ffmpeg 8 and 2484 ms through 6.1.1, and that difference
lands directly in the latency figures. ffmpeg only decodes and resamples. The audio then
takes exactly the same path as the microphone, so the latency being measured is real, not
the fake numbers you get from running the model offline in a batch.
