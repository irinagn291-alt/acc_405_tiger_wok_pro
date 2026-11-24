#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
device="${1:?iPhone or iPad}"
test_case="${2:-}"
suffix="${3:-final}"
results="$PWD/QA/$device-$suffix.xcresult"
build="$PWD/.build/$device"
log="$PWD/QA/$device-$suffix.log"
xcrun simctl boot "$GF_SIMULATOR_UDID"
xcrun simctl bootstatus "$GF_SIMULATOR_UDID" -b
xcrun simctl status_bar "$GF_SIMULATOR_UDID" override --time '21:30' --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100
recording=''
if [[ "$device" == iPhone ]]; then
  date +%s > "$PWD/QA/$device-$suffix-video-start.txt"
  xcrun simctl io "$GF_SIMULATOR_UDID" recordVideo --codec=h264 "$PWD/QA/$device-$suffix-raw.mov" > "$PWD/QA/$device-$suffix-video.log" 2>&1 &
  recording=$!
fi
stop_recording() {
  if [[ -n "$recording" ]]; then
    kill -INT "$recording" 2>/dev/null || true
    wait "$recording" || true
  fi
}
trap stop_recording EXIT
set -- xcodebuild test -project TigerWok.xcodeproj -scheme TigerWok -destination "id=$GF_SIMULATOR_UDID" -parallel-testing-enabled NO -derivedDataPath "$build" -resultBundlePath "$results" CODE_SIGNING_ALLOWED=NO
if [[ -n "$test_case" ]]; then
  IFS=',' read -r -a cases <<< "$test_case"
  for name in "${cases[@]}"; do set -- "$@" "-only-testing:TigerWokUITests/WokUITests/$name"; done
fi
"$@" > "$log" 2>&1
