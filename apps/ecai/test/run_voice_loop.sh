#!/usr/bin/env bash
# Local TTS -> finite microphone capture -> existing Erlang voice recognizer.
# Requires the preceding ecai-voice-erlang patch. No DamageBDD services started.
set -Eeuo pipefail
umask 077
APP="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd -- "$APP/../.." && pwd)"
SESSION="$ROOT/_build/ecai_voice_live"
DEVICE=default PLAYBACK=default VOICE=en SECONDS_PER_TAKE=6 SETTLE_MS=750
ENROLL_TAKES=1 CALIBRATE_TAKES=1 ROUNDS=0 AUTO=0 CONSENT=0
BACKEND=curve IMPORT='' SPEAKERS_ARG='' ACTIVE_PID='' HAVE_LOCK=0
ENROLL_SET=0 CALIBRATE_SET=0

usage() {
    cat <<'HELP'
Usage: bash apps/ecai/test/run_voice_loop.sh [options]
  --session DIR       Private, resumable session (default _build/ecai_voice_live)
  --speakers A,B       2-10 distinct labels; prompted on a new session otherwise
  --profile FILE       Start a NEW session from an existing compatible profile
  --device PCM         ALSA microphone PCM (default default)
  --playback PCM       ALSA speaker/headphone PCM (default default)
  --voice NAME         eSpeak voice (default en)
  --seconds N          Recording duration, 2-30 seconds (default 6)
  --enroll-takes N     Enrollment takes per person, 1-10 (default 1)
  --calibrate-takes N  Separate calibration takes, 1-10 (default 1)
  --settle-ms N        Silence after playback, 250-5000 ms (default 750)
  --backend NAME      curve (default) or integer control
  --rounds N          Stop after N test captures; 0 = manual loop until q
  --auto              No keyboard between TEST captures; requires --rounds 1-100
  --consent           Explicitly confirm all participants consent to local capture
  --devices           List ALSA capture/playback devices and exit; no capture
  --help              Show help
No automatic deletion or enrollment from tests. At most 200 microphone attempts
per session (including failed attempts). Use headphones and a real microphone,
NOT a system-audio/monitor source. Ctrl-C stops the loop and its active command.
HELP
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_value() { [[ $# -ge 2 && -n $2 ]] || die "Missing value for $1"; }
while (($#)); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --devices)
            for tool in arecord aplay; do
                command -v "$tool" >/dev/null || die "Missing $tool (alsa-utils)"
                printf '\n=== %s hardware ===\n' "$tool"; timeout -k 2s 10s "$tool" -l
                printf '\n=== %s PCMs ===\n' "$tool"; timeout -k 2s 10s "$tool" -L
            done; exit 0 ;;
        --auto) AUTO=1; shift ;;
        --consent) CONSENT=1; shift ;;
        --session|--speakers|--profile|--device|--playback|--voice|--seconds|--enroll-takes|--calibrate-takes|--settle-ms|--backend|--rounds)
            need_value "$@"; KEY=$1; VAL=$2; shift 2
            case "$KEY" in
                --session) SESSION=$VAL ;; --speakers) SPEAKERS_ARG=$VAL ;;
                --profile) IMPORT=$VAL ;; --device) DEVICE=$VAL ;; --playback) PLAYBACK=$VAL ;;
                --voice) VOICE=$VAL ;; --seconds) SECONDS_PER_TAKE=$VAL ;;
                --enroll-takes) ENROLL_TAKES=$VAL; ENROLL_SET=1 ;;
                --calibrate-takes) CALIBRATE_TAKES=$VAL; CALIBRATE_SET=1 ;;
                --settle-ms) SETTLE_MS=$VAL ;; --backend) BACKEND=$VAL ;; --rounds) ROUNDS=$VAL ;;
            esac ;;
        *) die "Unknown option: $1 (use --help)" ;;
    esac
done
number() { [[ $2 =~ ^(0|[1-9][0-9]{0,4})$ ]] && (( $2 >= $3 && $2 <= $4 )) || die "$1 must be $3-$4"; }
number --seconds "$SECONDS_PER_TAKE" 2 30
number --enroll-takes "$ENROLL_TAKES" 1 10
number --calibrate-takes "$CALIBRATE_TAKES" 1 10
number --settle-ms "$SETTLE_MS" 250 5000
number --rounds "$ROUNDS" 0 100
[[ $BACKEND == curve || $BACKEND == integer ]] || die '--backend must be curve or integer'
(( ! AUTO || ROUNDS > 0 )) || die '--auto requires a finite --rounds count'
[[ $SESSION != *$'\n'* && $SESSION != *$'\t'* ]] || die 'Session path contains control characters'
[[ -z $IMPORT || -z $SPEAKERS_ARG ]] || die 'Use --profile OR --speakers, not both'
for cmd in erl erlc timeout flock arecord aplay mktemp; do
    command -v "$cmd" >/dev/null || die "Missing $cmd; install OTP, alsa-utils and coreutils/util-linux"
done
TTS="$(command -v espeak-ng || command -v espeak || true)"
[[ -n $TTS ]] || die 'Missing espeak-ng (or espeak)'
[[ -f "$APP/src/ecai_voice.erl" ]] || die 'Apply the preceding Erlang voice POC patch first'

# A timeout process owns each external command. Signals are sent to timeout,
# which forwards them to its monitored process group and escalates after 2s.
# No eval, sh -c, os:cmd or generated Erlang expressions.
cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    if [[ -n $ACTIVE_PID ]]; then
        kill -TERM "$ACTIVE_PID" 2>/dev/null || true
        wait "$ACTIVE_PID" 2>/dev/null || true
        ACTIVE_PID=''
    fi
    if (( HAVE_LOCK )); then flock -u 9 || true; fi
    exit "$rc"
}
trap cleanup EXIT
trap 'printf "\nStopped; existing samples are retained.\n" >&2; exit 130' INT
trap 'exit 143' TERM
run_bounded() {
    local duration=$1 rc=0; shift
    timeout --kill-after=2s "${duration}s" "$@" </dev/null 9>&- &
    ACTIVE_PID=$!
    wait "$ACTIVE_PID" || rc=$?
    ACTIVE_PID=''
    return "$rc"
}

# Do not repurpose arbitrary nonempty directories or silently replace profiles.
[[ ! -L $SESSION ]] || die 'Session directory must not be a symlink'
mkdir -p -- "$SESSION"
SESSION="$(cd -- "$SESSION" && pwd)"
exec 9>"$SESSION/.lock"
flock -n 9 || die 'Another loop is already using this session'
HAVE_LOCK=1
if [[ ! -f "$SESSION/session.version" ]]; then
    [[ -z $(find "$SESSION" -mindepth 1 -maxdepth 1 ! -name .lock -print -quit) ]] || die 'Directory is nonempty and is not a voice-loop session'
    printf 'ecai-voice-loop/1\n' > "$SESSION/session.version"
fi
[[ $(cat "$SESSION/session.version") == ecai-voice-loop/1 ]] || die 'Unsupported session version'
chmod 700 -- "$SESSION"
mkdir -p -- "$SESSION"/{develop,takes,tests,logs,prompt}
printf '%s\n' "$DEVICE" > "$SESSION/capture-device.txt"
printf '%s\n' "$PLAYBACK" > "$SESSION/playback-device.txt"
export ECAI_VOICE_LOOP_SESSION="$SESSION" ECAI_VOICE_LOOP_SECONDS="$SECONDS_PER_TAKE"
export ECAI_VOICE_LOOP_BACKEND="$BACKEND"
BUILD="${ECAI_VOICE_BUILD_DIR:-$ROOT/_build/ecai_voice_poc}"
mkdir -p -- "$BUILD"; BUILD="$(cd -- "$BUILD" && pwd)"
export ECAI_VOICE_BUILD_DIR="$BUILD"
export ERL_CRASH_DUMP="$SESSION/logs/erl_crash.dump"
# The existing compile mode builds ecai_voice*.erl without booting the app.
run_bounded 120 bash "$APP/test/run_voice_poc.sh" compile > "$SESSION/logs/compile.log" 2>&1 || {
    cat "$SESSION/logs/compile.log" >&2; die 'Compilation failed; no microphone was opened'
}
backend() {
    local action=$1 log=$2 rc=0
    export ECAI_VOICE_LOOP_ACTION="$action"
    run_bounded 180 erl -noshell -noinput -pa "$BUILD/ebin" -s ecai_voice_loop main > "$log" 2>&1 || rc=$?
    cat -- "$log"
    return "$rc"
}
ask() {
    printf '%s' "$1"
    if ! IFS= read -r ANSWER; then printf '\nEnd of input; session retained.\n'; exit 0; fi
    case "$ANSWER" in q|quit) printf 'Session retained: %s\n' "$SESSION"; exit 0 ;; esac
}
valid_label() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ && $1 != unknown ]]; }
load_labels() {
    mapfile -t SPEAKERS < "$SESSION/speakers.txt"
    (( ${#SPEAKERS[@]} >= 2 && ${#SPEAKERS[@]} <= 10 )) || die 'Need 2-10 speakers'
    local label seen='|'
    for label in "${SPEAKERS[@]}"; do
        valid_label "$label" || die "Invalid speaker label: $label"
        [[ $seen != *"|$label|"* ]] || die "Duplicate speaker label: $label"
        seen+="$label|"
    done
}
say() {
    printf '[TTS] %s\n' "$1"
    printf '%s\n' "$1" > "$SESSION/prompt/current.txt"
    rm -f -- "$SESSION/prompt/current.wav"
    run_bounded 30 "$TTS" -v "$VOICE" -s 165 -w "$SESSION/prompt/current.wav" -f "$SESSION/prompt/current.txt" \
        >> "$SESSION/logs/tts.log" 2>&1 || die 'TTS synthesis failed; capture will not start (logs/tts.log)'
    [[ -s "$SESSION/prompt/current.wav" ]] || die 'TTS produced no WAV; capture will not start'
    run_bounded 45 aplay -q -D "$PLAYBACK" "$SESSION/prompt/current.wav" \
        >> "$SESSION/logs/playback.log" 2>&1 || die 'Prompt playback failed; capture will not start (logs/playback.log)'
}
settle() { local delay; printf -v delay '%d.%03d' "$((SETTLE_MS / 1000))" "$((SETTLE_MS % 1000))"; sleep "$delay"; }
record_take() {
    local phrase=$1 prompt=$2 directory=$3 count
    count=$(find "$SESSION/takes" "$SESSION/tests" -name '*.wav' -type f | wc -l)
    (( count < 200 )) || die '200-capture session budget reached; start a new session'
    TAKE="$(mktemp "$directory/take-XXXXXXXX.wav")"
    printf '%s\n' "$phrase" > "$TAKE.phrase.txt"
    printf 'sample=%s\nexpected=%s\nseconds=%s\ncapture=%s\nplayback=%s\nsettle_ms=%s\n' \
        "$TAKE" "${ECAI_VOICE_LOOP_EXPECTED:-}" "$SECONDS_PER_TAKE" "$DEVICE" "$PLAYBACK" "$SETTLE_MS" > "$TAKE.capture.txt"
    printf '\nRead naturally for the whole recording; continue in your own words:\n  %s\n' "$phrase"
    say "$prompt After a short pause, speak in your normal voice for $SECONDS_PER_TAKE seconds."
    settle
    printf 'recorder_launch_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$TAKE.capture.txt"
    printf '\n*** RECORDING for %s seconds ***\n' "$SECONDS_PER_TAKE"
    if ! run_bounded "$((SECONDS_PER_TAKE + 8))" arecord --fatal-errors -q -D "$DEVICE" \
        -t wav -f S16_LE -r 16000 -c 1 -d "$SECONDS_PER_TAKE" "$TAKE" > "$TAKE.capture.log" 2>&1; then
        cat "$TAKE.capture.log" >&2
        die "Capture failed or timed out; partial take retained but not accepted: $TAKE"
    fi
    printf 'recorder_exit_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$TAKE.capture.txt"
    printf '*** RECORDING FINISHED ***\n'
    export ECAI_VOICE_LOOP_SAMPLE="$TAKE"
}
PHRASES_ENROLL=(
    'The morning train crossed the river while sunlight reached the platform.'
    'I put the blue notebook on the table and opened the kitchen window.'
    'Beyond the garden, a quiet road led down to the old harbour.'
)
PHRASES_CAL=(
    'We carried fresh vegetables home and talked about our plans for tomorrow.'
    'A small silver boat moved slowly past the rocks near the lighthouse.'
    'The weather changed before lunch, so we decided to walk another way.'
)
PHRASES_TEST=(
    'Describe something you did yesterday, in your own words.'
    'Describe the room around you without mentioning your name.'
    'Explain how you would make your favourite meal.'
    'Tell us about a place you remember visiting.'
)
collect() {
    local split=$1 label=$2 index=$3 dest phrase
    printf -v dest '%s/develop/%s--%s--%02d.wav' "$SESSION" "$split" "$label" "$index"
    if [[ -f $dest ]]; then printf 'Using saved take: %s\n' "$dest"; return; fi
    if [[ $split == enroll ]]; then phrase=${PHRASES_ENROLL[$(((index-1)%3))]};
    else phrase=${PHRASES_CAL[$(((index-1)%3))]}; fi
    while :; do
        ask "[$split / $label / take $index] Enter when this person is ready; q quits: "
        [[ -z $ANSWER ]] || continue
        export ECAI_VOICE_LOOP_EXPECTED="$label"
        record_take "$phrase" "$label. $split take $index. Please read the text on screen." "$SESSION/takes"
        if backend check "$TAKE.check.log"; then
            while :; do
                ask 'Enter to keep, r to retry, p to play back, q to quit: '
                case "$ANSWER" in
                    '')
                        # Keep the original attempt and metadata; link an accepted,
                        # immutable filename into development. No overwrite allowed.
                        ln -- "$TAKE" "$dest"
                        printf '%s\t%s\n' "$dest" "$TAKE" >> "$SESSION/accepted.tsv"
                        return ;;
                    r) break ;;
                    p) run_bounded 40 aplay -q -D "$PLAYBACK" "$TAKE" || die 'Take playback failed' ;;
                    *) printf 'Use Enter, r, p, or q.\n' ;;
                esac
            done
        else
            printf '\nTake rejected by the quality/format check. It was NOT enrolled.\n'
            ask 'Enter to record another take; q to stop and inspect: '
        fi
    done
}

printf '\nECAI live voice experiment. No speech transcription or biometric authentication.\n'
printf 'Session: %s\nMicrophone: %s; playback: %s\n' "$SESSION" "$DEVICE" "$PLAYBACK"
printf 'Use headphones. Do not select a monitor/system-output source. All WAVs stay local.\n'
if (( ! CONSENT )); then
    ask 'All participants consent to recording and local retention? Type yes, or q: '
    [[ $ANSWER == yes ]] || die 'Recording consent not confirmed'
fi
if [[ -n $IMPORT ]]; then
    [[ ! -f "$SESSION/voices.ecv" && ! -f "$SESSION/speakers.txt" ]] || die '--profile requires a new session'
    export ECAI_VOICE_LOOP_PROFILE="$IMPORT"
    backend import "$SESSION/logs/import.log" || die 'Profile import failed'
fi
if [[ ! -f "$SESSION/speakers.txt" ]]; then
    if [[ -z $SPEAKERS_ARG ]]; then
        ask 'Known speakers, comma separated (for example alice,bob); q quits: '
        SPEAKERS_ARG=$ANSWER
    fi
    [[ $SPEAKERS_ARG != *, && $SPEAKERS_ARG != ,* && $SPEAKERS_ARG != *,,* ]] || die 'Empty speaker label'
    IFS=, read -r -a SPEAKERS <<< "$SPEAKERS_ARG"
    # Validate before writing a persistent session definition.
    (( ${#SPEAKERS[@]} >= 2 && ${#SPEAKERS[@]} <= 10 )) || die 'Use 2-10 different people'
    seen='|'
    for label in "${SPEAKERS[@]}"; do
        valid_label "$label" || die "Invalid speaker label: $label"
        [[ $seen != *"|$label|"* ]] || die "Duplicate speaker label: $label"
        seen+="$label|"
    done
    printf '%s\n' "${SPEAKERS[@]}" > "$SESSION/speakers.txt"
fi
load_labels
if [[ -n $SPEAKERS_ARG ]]; then
    current=$(IFS=,; printf '%s' "${SPEAKERS[*]}")
    [[ $current == "$SPEAKERS_ARG" ]] || die 'Speaker list differs from saved session; choose a new --session'
fi
if [[ ! -f "$SESSION/voices.ecv" ]]; then
    if [[ -f "$SESSION/development-counts.txt" ]]; then
        read -r saved_enroll saved_calibrate < "$SESSION/development-counts.txt"
        number saved_enroll "$saved_enroll" 1 10
        number saved_calibrate "$saved_calibrate" 1 10
        (( ! ENROLL_SET || ENROLL_TAKES == saved_enroll )) || die 'Enrollment count differs from saved session'
        (( ! CALIBRATE_SET || CALIBRATE_TAKES == saved_calibrate )) || die 'Calibration count differs from saved session'
        ENROLL_TAKES=$saved_enroll; CALIBRATE_TAKES=$saved_calibrate
    else
        printf '%s %s\n' "$ENROLL_TAKES" "$CALIBRATE_TAKES" > "$SESSION/development-counts.txt"
    fi
    # Phase-major order and shared prompts limit phrase/identity shortcuts.
    for split in enroll calibrate; do
        if [[ $split == enroll ]]; then takes=$ENROLL_TAKES; else takes=$CALIBRATE_TAKES; fi
        for ((n=1; n<=takes; n++)); do
            for label in "${SPEAKERS[@]}"; do collect "$split" "$label" "$n"; done
        done
    done
    if [[ ! -f "$SESSION/unknown-choice.txt" ]]; then
        while :; do
            ask 'Record a THIRD, unenrolled person for unknown calibration? y/n, q quits: '
            case "$ANSWER" in y|n) printf '%s\n' "$ANSWER" > "$SESSION/unknown-choice.txt"; break ;; esac
        done
    fi
    if [[ $(cat "$SESSION/unknown-choice.txt") == y ]]; then collect calibrate unknown 1; fi
    if ! backend build "$SESSION/logs/build.log"; then
        die 'Calibration failed. No live matching/profile was enabled. Keep this session as evidence; do not tune against test results.'
    fi
fi
backend inspect "$SESSION/logs/inspect.log" || die 'Saved profile failed validation; no test capture will start'
printf '\nProfile frozen. TEST takes will never modify enrollment or thresholds.\n'
printf 'Known labels: %s\n' "${SPEAKERS[*]}"
printf 'At each test, enter the expected label, unknown, or Enter for no ground truth; q quits.\n'
for ((round=1; ROUNDS==0 || round<=ROUNDS; round++)); do
    if (( AUTO )); then ANSWER='';
    else
        ask "[test $round] Expected speaker / unknown / Enter / q: "
        if [[ -n $ANSWER && $ANSWER != unknown ]]; then
            found=0
            for label in "${SPEAKERS[@]}"; do [[ $ANSWER != "$label" ]] || found=1; done
            if (( ! found )); then printf 'Not an enrolled label.\n'; round=$((round-1)); continue; fi
        fi
    fi
    export ECAI_VOICE_LOOP_EXPECTED="$ANSWER"
    phrase="${PHRASES_TEST[$(((round-1)%4))]}"
    record_take "$phrase" "Test sample $round. $phrase" "$SESSION/tests"
    if ! backend score "$TAKE.score.log"; then die "Scoring failed; sample and error retained: $TAKE"; fi
    [[ -s "$TAKE.feedback.txt" ]] || die 'Missing feedback file after scoring'
    say "$(cat "$TAKE.feedback.txt")"
    printf 'Saved: %s\n' "$TAKE.result.term"
done
printf '\nCompleted %s test captures. Session retained: %s\n' "$ROUNDS" "$SESSION"
