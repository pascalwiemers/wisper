#!/bin/bash
# Golden regression cases for the cleanup prompt. Run after any change to
# Cleaner.instructions and eyeball input vs output — cases come from real
# failures logged in transcripts.db.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

BIN=".build/xcode/Build/Products/Release/Wisper"
[[ -x "$BIN" ]] || ./scripts/build-app.sh

CASES=(
    "um so I wanted to test if this pill works"
    "this is a test of um oh I think the pill is not working correctly"
    "it seems like the waveform animation of the pill is not properly does not have a proper threshold setting or the threshold setting doesnt adjust"
    "we should um we should probably ship it on monday no wait uh tuesday because like the tests arent done yet you know"
    "what um what time is the standup tomorrow"
    "hey can you um can you send me the the figma link for the uh the new onboarding flow like sometime today"
    "so the deploy failed again I think its the uh the redis connection pool thing we saw last week"
    "I think we should maybe hold off on the launch until next week"
    "this is already a clean sentence."
    # Trips Apple's guardrails ("cut out my arms" — ASR mishearing of "my ums");
    # must still come back filler-free via the regex fallback.
    "Um so this is a test if the pill is working. Um let's see if it can cut out my arms and uh my stuttering um maybe uh"
    # Deliberate repetition is emphasis — both "for real"s must survive.
    "I would like to be able to say for real, for real."
    "it was very very slow no no no I mean like really really slow"
)

for c in "${CASES[@]}"; do
    echo "IN : $c"
    echo "OUT: $("$BIN" --clean "$c" 2>/dev/null)"
    echo
done
