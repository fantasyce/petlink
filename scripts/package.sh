#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${PETLINK_PACKAGE_APP:-dist/PetLink.app}"
test -d "$app"
package_arch="$(lipo -archs "$app/Contents/MacOS/PetLink")"
case "$package_arch" in arm64|x86_64) ;; *) echo "Unsupported package architecture" >&2; exit 1 ;; esac
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
mkdir -p .build dist
dmg_root="$(mktemp -d .build/dmg-root.XXXXXX)"
mount_root="$(mktemp -d .build/dmg-mount.XXXXXX)"
mounted=false
cleanup() {
  if [[ "$mounted" == true ]]; then hdiutil detach "$mount_root" >/dev/null; fi
  /usr/bin/find "$dmg_root" -depth -delete
  /usr/bin/find "$mount_root" -depth -delete
}
trap cleanup EXIT
ditto "$app" "$dmg_root/PetLink.app"
cp packaging/README.txt "$dmg_root/README.txt"
ln -s /Applications "$dmg_root/Applications"
hdiutil create -volname "PetLink $version" -srcfolder "$dmg_root" -format UDZO -ov dist/PetLink-${version}-${package_arch}.dmg
hdiutil verify dist/PetLink-${version}-${package_arch}.dmg
hdiutil attach -readonly -nobrowse -mountpoint "$mount_root" dist/PetLink-${version}-${package_arch}.dmg >/dev/null
mounted=true
/sbin/mount | grep -F "on $PWD/$mount_root" | grep -F 'read-only' >/dev/null
codesign --verify --deep --strict "$mount_root/PetLink.app"
test "$(find "$mount_root" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = 3
test -L "$mount_root/Applications"
test "$(readlink "$mount_root/Applications")" = /Applications
cmp packaging/README.txt "$mount_root/README.txt"
for notice in LICENSE NOTICE THIRD_PARTY_NOTICES; do
  cmp "$notice" "$mount_root/PetLink.app/Contents/Resources/Licenses/$notice"
done
python3 scripts/test-localization.py "$mount_root/PetLink.app/Contents/Resources"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$mount_root/PetLink.app/Contents/Info.plist")" = "$build_number"
for executable in PetLink PetLinkAgentEvent; do
  source_hash="$(shasum -a 256 "$app/Contents/MacOS/$executable" | awk '{print $1}')"
  mounted_hash="$(shasum -a 256 "$mount_root/PetLink.app/Contents/MacOS/$executable" | awk '{print $1}')"
  test "$source_hash" = "$mounted_hash"
  printf '%s  %s\n' "$source_hash" "$executable"
done >dist/PetLink-${version}-${package_arch}.executables.sha256
if /usr/bin/strings "$mount_root/PetLink.app/Contents/MacOS/PetLink" | rg -q 'correct horse battery staple|once-only|http-invite|UI Paste Test'; then
  echo 'test data found in packaged executable' >&2
  exit 1
fi
if rg -n 'BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{16,}' "$mount_root"; then
  echo 'credential-like data found in DMG' >&2
  exit 1
fi
hdiutil detach "$mount_root" >/dev/null
mounted=false
shasum -a 256 dist/PetLink-${version}-${package_arch}.dmg | tee dist/PetLink-${version}-${package_arch}.dmg.sha256
