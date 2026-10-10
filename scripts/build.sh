#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_root="${PETLINK_BUILD_ROOT:-.build}"
app="${PETLINK_APP_OUTPUT:-dist/PetLink.app}"
mkdir -p "$build_root"
python3 scripts/test-localization.py
swiftc -parse-as-library client/Localization.swift client/LocalizationTests.swift -o "$build_root/localization-tests"
"$build_root/localization-tests" client/Resources
build_root="$(cd "$build_root" && pwd)"
fixtures_root="$(mktemp -d "$build_root/f.XXXXXX")"
cleanup_test_fixtures() {
  result=$?
  if [[ "$result" -eq 0 ]]; then /usr/bin/find "$fixtures_root" -depth -delete; fi
  return "$result"
}
trap cleanup_test_fixtures EXIT
swiftc client/Localization.swift client/ServiceEndpoint.swift client/ServiceEndpointTests.swift -o "$build_root/endpoint-tests"
"$build_root/endpoint-tests"
PETLINK_GOOGLE_TEST_OUTPUT="$build_root/google-tests" bash scripts/test-google-auth.sh
swiftc client/Localization.swift client/LocalCompanion.swift client/LocalCompanionTests.swift -o "$build_root/local-companion-tests"
swiftc client/Localization.swift client/LocalCompanion.swift client/CodexConversationCore.swift client/PetInteractionTests.swift -o "$build_root/interaction-tests"
"$build_root/interaction-tests"
swiftc client/Localization.swift client/LocalCompanion.swift client/SocialUnlockLifecycleTests.swift -o "$build_root/social-unlock-tests"
swiftc client/Localization.swift client/LocalCompanion.swift client/SocialUnlockShiftTests.swift -o "$build_root/social-shift-tests"
"$build_root/social-shift-tests"
"$build_root/social-unlock-tests"
"$build_root/local-companion-tests"
swiftc client/Localization.swift client/CodexConversationCore.swift client/CodexConversationTests.swift -o "$build_root/codex-conversation-tests"
"$build_root/codex-conversation-tests" "$fixtures_root/conversation-fixture"
swiftc client/Localization.swift client/CodexConversationCore.swift client/ConversationActivity.swift client/ConversationActivityTests.swift -o "$build_root/activity-tests"
"$build_root/activity-tests"
swiftc client/Localization.swift -swift-version 5 client/CodexConversationCore.swift client/ConversationActivity.swift client/CodexSessionDiscovery.swift client/ClaudeSessionStatus.swift client/AvatarAgentAdapters.swift client/ClaudeConversationCore.swift client/ClaudeCoworkSessionDiscovery.swift client/DSHDesktopApplication.swift client/DSHDesktopSessionDiscovery.swift client/CodexConversationView.swift client/PencilCore.swift client/PencilUI.swift client/ConversationMonitorTests.swift -framework AppKit -framework SwiftUI -o "$build_root/monitor-tests"
"$build_root/monitor-tests" "$fixtures_root/monitor-fixtures"
swiftc client/Localization.swift -swift-version 5 client/CodexConversationCore.swift client/ConversationActivity.swift client/CodexSessionDiscovery.swift client/ClaudeSessionStatus.swift client/AvatarAgentAdapters.swift client/ClaudeConversationCore.swift client/ClaudeCoworkSessionDiscovery.swift client/DSHDesktopApplication.swift client/DSHDesktopSessionDiscovery.swift client/CodexConversationView.swift client/PencilCore.swift client/PencilUI.swift client/ConversationFeedbackTests.swift -framework AppKit -framework SwiftUI -o "$build_root/feedback-tests"
"$build_root/feedback-tests" "$fixtures_root/feedback-fixtures"
swiftc client/Localization.swift client/AvatarAgentAdapters.swift client/DSHDesktopApplication.swift client/AgentVersionMonitor.swift client/AgentVersionMonitorTests.swift -o "$build_root/version-tests"
"$build_root/version-tests" "$fixtures_root/version-fixtures"
swiftc client/Localization.swift client/CodexConversationCore.swift client/CodexSessionDiscovery.swift client/DSHDesktopApplication.swift client/DSHDesktopSessionDiscovery.swift client/SessionCompatibilityTests.swift -o "$build_root/compatibility-tests"
"$build_root/compatibility-tests" "$fixtures_root/compatibility-fixtures"
swiftc client/Localization.swift client/CodexDaemonProbe.swift client/CodexProbeContractTests.swift -o "$build_root/probe-contract-tests"
"$build_root/probe-contract-tests" "$fixtures_root/p"
swiftc client/Localization.swift -swift-version 5 client/CodexConversationCore.swift client/ConversationActivity.swift client/CodexSessionDiscovery.swift client/ClaudeSessionStatus.swift client/AvatarAgentAdapters.swift client/ClaudeConversationCore.swift client/ClaudeCoworkSessionDiscovery.swift client/DSHDesktopApplication.swift client/DSHDesktopSessionDiscovery.swift client/CodexConversationView.swift client/PencilCore.swift client/PencilUI.swift client/CodexAutoSessionsTests.swift -framework AppKit -framework SwiftUI -o "$build_root/auto-session-tests"
"$build_root/auto-session-tests" "$fixtures_root/auto-session-fixtures"
swiftc client/Localization.swift client/CodexConversationCore.swift client/CodexSessionDiscovery.swift client/ClaudeSessionStatus.swift client/AvatarAgentAdapters.swift client/ClaudeConversationCore.swift client/ClaudeCoworkSessionDiscovery.swift client/ClaudeConversationTests.swift -o "$build_root/claude-conversation-tests"
"$build_root/claude-conversation-tests" "$fixtures_root/claude-conversation-fixtures"
swiftc client/Localization.swift client/CodexConversationCore.swift client/CodexSessionDiscovery.swift client/ClaudeSessionStatus.swift client/AvatarAgentAdapters.swift client/ClaudeConversationCore.swift client/ClaudeCoworkSessionDiscovery.swift client/ClaudeCoworkSessionDiscoveryTests.swift -o "$build_root/cowork-discovery-tests"
"$build_root/cowork-discovery-tests" "$fixtures_root/cowork-discovery"
swiftc client/Localization.swift client/CodexConversationCore.swift client/CodexSessionDiscovery.swift client/ClaudeSessionStatus.swift client/AvatarAgentAdapters.swift client/ClaudeConversationCore.swift client/ClaudeCoworkSessionDiscovery.swift client/ClaudeDesktopLifecycleTests.swift -o "$build_root/claude-desktop-lifecycle-tests"
"$build_root/claude-desktop-lifecycle-tests" "$fixtures_root/claude-desktop-lifecycle"
swiftc client/Localization.swift client/CodexConversationCore.swift client/CodexSessionDiscovery.swift client/ClaudeSessionStatus.swift client/AvatarAgentAdapters.swift client/ClaudeConversationCore.swift client/ClaudeCoworkSessionDiscovery.swift client/ClaudeDesktopIntegrationTests.swift -o "$build_root/claude-desktop-integration-tests"
"$build_root/claude-desktop-integration-tests" "$fixtures_root/claude-desktop-integration"
swiftc client/Localization.swift -swift-version 5 client/CodexConversationCore.swift client/ConversationActivity.swift client/CodexSessionDiscovery.swift client/ClaudeSessionStatus.swift client/AvatarAgentAdapters.swift client/ClaudeConversationCore.swift client/ClaudeCoworkSessionDiscovery.swift client/DSHDesktopApplication.swift client/DSHDesktopSessionDiscovery.swift client/CodexConversationView.swift client/PencilCore.swift client/PencilUI.swift client/ClaudeMonitorTests.swift -framework AppKit -framework SwiftUI -o "$build_root/claude-monitor-tests"
"$build_root/claude-monitor-tests" "$fixtures_root/claude-monitor-fixtures"
swiftc client/Localization.swift client/CodexConversationCore.swift client/CodexSessionDiscovery.swift client/DSHDesktopApplication.swift client/DSHDesktopSessionDiscovery.swift client/DSHDesktopSessionDiscoveryTests.swift -o "$build_root/dsh-discovery-tests"
"$build_root/dsh-discovery-tests" "$fixtures_root/dsh-discovery-fixtures"
swiftc client/Localization.swift client/CodexConversationCore.swift client/CodexSessionDiscovery.swift client/DSHDesktopApplication.swift client/DSHDesktopSessionDiscovery.swift client/DSHDesktopProcessTests.swift -o "$build_root/dsh-process-tests"
"$build_root/dsh-process-tests" "$fixtures_root/dsh-process-fixtures"
swiftc client/Localization.swift -swift-version 5 client/CodexConversationCore.swift client/ConversationActivity.swift client/CodexSessionDiscovery.swift client/ClaudeSessionStatus.swift client/AvatarAgentAdapters.swift client/ClaudeConversationCore.swift client/ClaudeCoworkSessionDiscovery.swift client/DSHDesktopApplication.swift client/DSHDesktopSessionDiscovery.swift client/CodexConversationView.swift client/PencilCore.swift client/PencilUI.swift client/DSHDesktopMonitorTests.swift -framework AppKit -framework SwiftUI -o "$build_root/dsh-monitor-tests"
"$build_root/dsh-monitor-tests" "$fixtures_root/dsh-monitor-fixtures"
swiftc client/Localization.swift -swift-version 5 client/CodexConversationCore.swift client/ConversationActivity.swift client/CodexSessionDiscovery.swift client/ClaudeSessionStatus.swift client/AvatarAgentAdapters.swift client/ClaudeConversationCore.swift client/ClaudeCoworkSessionDiscovery.swift client/DSHDesktopApplication.swift client/DSHDesktopSessionDiscovery.swift client/CodexConversationView.swift client/PencilCore.swift client/PencilUI.swift client/MultiProviderMonitorTests.swift -framework AppKit -framework SwiftUI -o "$build_root/multi-provider-monitor-tests"
"$build_root/multi-provider-monitor-tests" "$fixtures_root/multi-provider-fixtures"
swiftc client/Localization.swift client/AgentIntegrationCore.swift client/AgentSessionRegistry.swift client/AgentSessionRegistryTests.swift -o "$build_root/agent-registry-tests"
"$build_root/agent-registry-tests"
swiftc client/Localization.swift -swift-version 5 client/AvatarCore.swift client/V2Models.swift client/AgentIntegrationCore.swift client/LocalSessionPresentation.swift client/LocalSessionPresentationTests.swift -framework CryptoKit -o "$build_root/local-session-tests"
"$build_root/local-session-tests"
swiftc client/Localization.swift client/PencilCore.swift client/PencilCoreTests.swift -o "$build_root/pencil-core-tests"
"$build_root/pencil-core-tests"
swiftc client/Localization.swift client/PencilCore.swift client/PencilNoticeTests.swift -o "$build_root/pencil-notice-tests"
"$build_root/pencil-notice-tests"
swiftc client/Localization.swift client/PencilCore.swift client/PencilUI.swift client/WindowChrome.swift client/PencilNoticeViewTests.swift -framework AppKit -framework SwiftUI -o "$build_root/pencil-notice-view-tests"
"$build_root/pencil-notice-view-tests"
swiftc client/Localization.swift client/PencilCore.swift client/PencilUI.swift client/WindowChrome.swift client/WindowChromeTests.swift -framework AppKit -framework SwiftUI -o "$build_root/window-chrome-tests"
"$build_root/window-chrome-tests"
swiftc client/Localization.swift -parse-as-library client/PencilAssetsTests.swift -framework AppKit -o "$build_root/pencil-assets-tests"
"$build_root/pencil-assets-tests" client/Resources
swiftc client/Localization.swift -swift-version 5 client/LeaseGate.swift client/LeaseGateTests.swift -o "$build_root/lease-tests"
"$build_root/lease-tests"
swiftc client/Localization.swift -swift-version 5 client/Models.swift client/VaultTests.swift -framework Security -o "$build_root/vault-tests"
"$build_root/vault-tests"
swiftc client/Localization.swift -swift-version 5 client/AvatarCore.swift client/V2Models.swift client/V2ModelsTests.swift -framework CryptoKit -o "$build_root/v2-model-tests"
"$build_root/v2-model-tests"
swiftc client/Localization.swift -swift-version 5 client/AvatarCore.swift client/V2Models.swift client/AvatarRequestState.swift client/AvatarRequestStateTests.swift -framework CryptoKit -o "$build_root/avatar-request-tests"
"$build_root/avatar-request-tests"
swiftc client/Localization.swift -swift-version 5 client/AvatarCore.swift client/V2Models.swift client/AvatarRequestState.swift client/AvatarChatState.swift client/VisitorChatBubble.swift client/AvatarChatStateTests.swift -framework CryptoKit -o "$build_root/avatar-chat-tests"
"$build_root/avatar-chat-tests"
swiftc client/Localization.swift -swift-version 5 client/PencilCore.swift client/PencilUI.swift client/AvatarChatInput.swift client/AvatarChatInputTests.swift -framework AppKit -framework SwiftUI -o "$build_root/avatar-input-tests"
"$build_root/avatar-input-tests"
swiftc client/Localization.swift -swift-version 5 client/AgentIntegrationCore.swift client/AgentIntegrationTests.swift -framework CryptoKit -o "$build_root/agent-tests"
"$build_root/agent-tests"
swiftc client/Localization.swift -swift-version 5 client/CodexDaemonProbe.swift client/CodexDaemonProbeTests.swift -o "$build_root/codex-probe-tests"
"$build_root/codex-probe-tests"
swiftc client/Localization.swift -swift-version 5 client/AvatarAgentAdapters.swift client/ClaudeSessionStatus.swift client/ClaudeSessionStatusTests.swift -o "$build_root/claude-status-tests"
"$build_root/claude-status-tests"
swiftc client/Localization.swift -swift-version 5 client/ClaudeHookSettings.swift client/ClaudeHookSettingsTests.swift -o "$build_root/claude-hook-tests"
"$build_root/claude-hook-tests" "$fixtures_root/claude-migration-fixture"
swiftc client/Localization.swift -swift-version 5 client/AvatarCore.swift client/AvatarCoreTests.swift -framework CryptoKit -o "$build_root/avatar-core-tests"
"$build_root/avatar-core-tests"
swiftc client/Localization.swift -swift-version 5 client/AvatarCore.swift client/V2Models.swift client/AvatarWireInteropTests.swift -framework CryptoKit -o "$build_root/avatar-wire-tests"
export PETLINK_AVATAR_WIRE_TEST="$build_root/avatar-wire-tests"
swiftc client/Localization.swift -swift-version 5 client/AvatarCore.swift client/AvatarIdentityVault.swift client/AvatarIdentityVaultTests.swift -framework CryptoKit -framework Security -o "$build_root/avatar-vault-tests"
"$build_root/avatar-vault-tests"
swiftc client/Localization.swift -swift-version 5 client/AvatarCore.swift client/AvatarIdentityVault.swift client/AvatarAuthorization.swift client/AvatarAuthorizationTests.swift -framework CryptoKit -framework Security -o "$build_root/avatar-authorization-tests"
"$build_root/avatar-authorization-tests"
"$build_root/avatar-authorization-tests" --missing
swiftc client/Localization.swift -swift-version 5 client/AvatarAgentAdapters.swift client/AvatarAgentAdaptersTests.swift -o "$build_root/avatar-adapter-tests"
"$build_root/avatar-adapter-tests"
swiftc client/Localization.swift client/AvatarAgentAdapters.swift client/AgentExecutableQuarantineTests.swift -o "$build_root/agent-quarantine-tests"
"$build_root/agent-quarantine-tests" "$fixtures_root/quarantine"
swiftc client/Localization.swift -swift-version 5 client/AvatarAgentAdapters.swift scripts/AvatarCodexWireProbe.swift -o "$build_root/avatar-codex-wire-probe"
if command -v codex >/dev/null && [[ "$(codex --version)" == "codex-cli 0.160.0" ]]; then
  python3 scripts/test-avatar-codex-transport.py "$build_root/avatar-codex-wire-probe"
else
  echo 'SKIP optional Codex transport probe: supported local CLI unavailable'
fi
dsh_app="/Applications/DeepSeek Harness.app"
if [[ -x "$dsh_app/Contents/MacOS/DeepSeek Harness" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$dsh_app/Contents/Info.plist")" == "0.2.0-rc.2" ]]; then
  ELECTRON_RUN_AS_NODE=1 "$dsh_app/Contents/MacOS/DeepSeek Harness" scripts/DSHAvatarRuntimeTests.mjs "$dsh_app/Contents/Resources/app.asar/dsh/node_modules/@deepseek-ai"
else
  echo 'SKIP optional DSH model transport probe: supported desktop runtime unavailable'
fi
swiftc client/Localization.swift -swift-version 5 client/PetWindowGeometry.swift client/PetWindowTests.swift -framework AppKit -o "$build_root/pet-window-tests"
"$build_root/pet-window-tests"
swiftc client/Localization.swift -swift-version 5 client/Models.swift client/PencilCore.swift client/PencilUI.swift client/PetWindowGeometry.swift client/VisitorChatBubble.swift client/PetWindows.swift client/PetQuickMenu.swift client/CodexConversationCore.swift client/CodexSessionDiscovery.swift client/ClaudeSessionStatus.swift client/AvatarAgentAdapters.swift client/ClaudeConversationCore.swift client/ClaudeCoworkSessionDiscovery.swift client/DSHDesktopApplication.swift client/DSHDesktopSessionDiscovery.swift client/CodexConversationView.swift client/ConversationActivity.swift client/PetPositionLifecycleTests.swift -framework AppKit -framework SwiftUI -framework Security -o "$build_root/pet-position-lifecycle-tests"
"$build_root/pet-position-lifecycle-tests" "$fixtures_root/pet-position-fixture"
swiftc client/Localization.swift -swift-version 5 client/Models.swift client/PencilCore.swift client/PencilUI.swift client/PetWindowGeometry.swift client/VisitorChatBubble.swift client/PetWindows.swift client/PetQuickMenu.swift client/CodexConversationCore.swift client/CodexSessionDiscovery.swift client/ClaudeSessionStatus.swift client/AvatarAgentAdapters.swift client/ClaudeConversationCore.swift client/ClaudeCoworkSessionDiscovery.swift client/DSHDesktopApplication.swift client/DSHDesktopSessionDiscovery.swift client/CodexConversationView.swift client/ConversationActivity.swift client/PetVisibilityTests.swift -framework AppKit -framework SwiftUI -framework Security -o "$build_root/pet-visibility-tests"
"$build_root/pet-visibility-tests" "$fixtures_root/pet-visibility-fixture"
swiftc client/Localization.swift -swift-version 5 client/Models.swift client/PencilCore.swift client/PencilUI.swift client/PetWindowGeometry.swift client/VisitorChatBubble.swift client/PetWindows.swift client/PetQuickMenu.swift client/CodexConversationCore.swift client/CodexSessionDiscovery.swift client/ClaudeSessionStatus.swift client/AvatarAgentAdapters.swift client/ClaudeConversationCore.swift client/ClaudeCoworkSessionDiscovery.swift client/DSHDesktopApplication.swift client/DSHDesktopSessionDiscovery.swift client/CodexConversationView.swift client/ConversationActivity.swift client/VisitorChatBubbleTests.swift -framework AppKit -framework SwiftUI -framework Security -o "$build_root/visitor-bubble-tests"
"$build_root/visitor-bubble-tests" "$fixtures_root/visitor-bubbles"
swiftc client/Localization.swift client/PetWindowGeometry.swift client/VisitorBubblePlacementTests.swift -framework AppKit -o "$build_root/visitor-placement-tests"
"$build_root/visitor-placement-tests"

bash scripts/compile-client.sh "$build_root" "${PETLINK_ARCH:-arm64}"
# Assemble a fresh bundle. Merging into an older signed output can retain
# removed resources and make the resulting signature invalid.
app_stage="$(mktemp -d "$build_root/app-stage.XXXXXX")"
staged_app="$app_stage/PetLink.app"
app_replaced=false
cleanup_app_stage() {
  result=$?
  if [[ "$result" -ne 0 && "$app_replaced" == true ]]; then
    if [[ -e "$app" ]]; then mv "$app" "$app_stage/failed.app"; fi
    if [[ -e "$app_stage/previous.app" ]]; then mv "$app_stage/previous.app" "$app"; fi
  fi
  /usr/bin/find "$app_stage" -depth -delete
  if [[ "$result" -eq 0 ]]; then /usr/bin/find "$fixtures_root" -depth -delete; fi
  return "$result"
}
trap cleanup_app_stage EXIT
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$build_root/PetLink" "$staged_app/Contents/MacOS/PetLink"
cp "$build_root/PetLinkAgentEvent" "$staged_app/Contents/MacOS/PetLinkAgentEvent"
codesign --force --sign - "$staged_app/Contents/MacOS/PetLinkAgentEvent"
codesign --force --sign - "$staged_app/Contents/MacOS/PetLink"
ditto client/Resources "$staged_app/Contents/Resources"
mkdir -p "$staged_app/Contents/Resources/Licenses"
cp LICENSE NOTICE THIRD_PARTY_NOTICES "$staged_app/Contents/Resources/Licenses/"
cp packaging/Info.plist "$staged_app/Contents/Info.plist"
codesign --force --sign - --identifier com.fantasyce.petlink "$staged_app"
codesign --verify --deep --strict "$staged_app"
cd server
go test -race -count=1 ./...
go vet ./...
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o "$build_root/petlink-server" .
cd ..
test ! -L "$app"
mkdir -p "$(dirname "$app")"
if [[ -e "$app" ]]; then mv "$app" "$app_stage/previous.app"; fi
app_replaced=true
mv "$staged_app" "$app"
codesign --verify --deep --strict "$app"
