#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_output="${PETLINK_GOOGLE_TEST_OUTPUT:-}"
if [[ -z "$task_output" ]]; then task_output="$(mktemp -d "${TMPDIR:-/tmp}/petlink-google-tests.XXXXXX")"; fi
mkdir -p "$task_output"
printf 'Test artifacts: %s\n' "$task_output"
swiftc client/Localization.swift -parse-as-library -swift-version 5 client/ServiceEndpoint.swift client/GoogleAuthCore.swift client/GoogleAuthCoreTests.swift -framework CryptoKit -framework Security -o "$task_output/core-tests"
"$task_output/core-tests"
if [[ -f client/GoogleLoopbackTests.swift ]]; then
  swiftc client/Localization.swift -parse-as-library -swift-version 5 client/ServiceEndpoint.swift client/GoogleAuthCore.swift client/GoogleLoopback.swift client/GoogleLoopbackTests.swift -framework CryptoKit -framework Security -framework Network -o "$task_output/loopback-tests"
  "$task_output/loopback-tests"
fi
swiftc client/Localization.swift -parse-as-library -swift-version 5 client/ServiceEndpoint.swift client/GoogleAuthCore.swift client/GoogleAuthTransport.swift client/GoogleAuthTransportTests.swift -framework CryptoKit -framework Security -o "$task_output/transport-tests"
"$task_output/transport-tests"
if [[ -f client/GoogleAuthCoordinatorTests.swift ]]; then
  swiftc client/Localization.swift -parse-as-library -swift-version 5 client/ServiceEndpoint.swift client/GoogleAuthCore.swift client/GoogleLoopback.swift client/GoogleAuthCoordinator.swift client/GoogleAuthCoordinatorTests.swift -framework CryptoKit -framework Security -framework Network -o "$task_output/coordinator-tests"
  "$task_output/coordinator-tests"
fi
