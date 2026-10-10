#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_root="${PETLINK_RECOVERY_TEST_ROOT:?use a fresh task-owned root}"
test_profile="${PETLINK_RECOVERY_TEST_PROFILE:?use a fresh wake- profile}"
[[ "$test_profile" == wake-* && "$test_profile" != *'/'* ]]
test_kind="${PETLINK_RECOVERY_TEST_KIND:-wake}"
test_entry="client/V2RecoveryTests.swift"
credential_test=0
appearance_test=0
invalid_session_test=0
if [[ "$test_kind" == credentials ]]; then
  [[ "$test_profile" == wake-credential-* ]]
  test_entry="client/V2CredentialRenewalTests.swift"
  credential_test=1
elif [[ "$test_kind" == appearance ]]; then
  [[ "$test_profile" == wake-appearance-* ]]
  test_entry="client/V2AppearanceRecoveryTests.swift"
  appearance_test=1
elif [[ "$test_kind" == invalid-session ]]; then
  [[ "$test_profile" == wake-invalid-* ]]
  test_entry="client/V2InvalidSessionTests.swift"
  invalid_session_test=1
else
  [[ "$test_kind" == wake ]]
fi
mkdir "$test_root"
test_root="$(cd "$test_root" && pwd)"
# Reuse the formal App's source list and frameworks; substitute only its entry
# point and omit the main workspace view, which requires the App delegate.
python3 - "$test_root/model-recovery-tests" "$test_entry" <<'PY'
import shlex,subprocess,sys
from pathlib import Path
line=next(x for x in Path('scripts/compile-client.sh').read_text().splitlines() if x.startswith('swiftc ') and 'client/App.swift' in x)
args=shlex.split(line)
args=[x.replace('${petlink_arch}', 'arm64') for x in args]
args=[x for x in args if x not in ['client/DesktopUI.swift','client/PetShowroom.swift','client/PetInteractionUI.swift','client/AvatarView.swift','client/GoogleAuthView.swift']]
args[args.index('client/App.swift')]=sys.argv[2]
args[args.index('-o')+1]=sys.argv[1]
subprocess.run(args,check=True)
PY
PETLINK_AVATAR_UI_PROFILE="$test_profile" PETLINK_AVATAR_UI_ROOT="$test_root" PETLINK_CREDENTIAL_RENEWAL_TEST="$credential_test" PETLINK_APPEARANCE_TEST="$appearance_test" PETLINK_INVALID_SESSION_TEST="$invalid_session_test" \
  go -C server test -race -count=1 -run '^TestAvatarAuthorizationNativeUIFixture$' -timeout=22m -v . >"$test_root/backend.log" 2>&1 &
fixture_pid=$!
finish() {
  result=$?
  touch "$test_root/stop"
  wait "$fixture_pid" || true
  return "$result"
}
trap finish EXIT
for ((attempt=0;attempt<150;attempt++)); do
  if [[ -f "$test_root/endpoint" ]]; then break; fi
  sleep 0.1
done
test -f "$test_root/endpoint"
"$test_root/model-recovery-tests" "$test_root" "$test_profile"
