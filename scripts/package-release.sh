#!/bin/bash
set -euo pipefail
[[ $# == 5 ]] || { echo 'usage: package-release.sh APP VERSION OUTPUT.pkg KEYCHAIN IDENTITY' >&2; exit 64; }
app=$1 version=$2 output=$3 keychain=$4 identity=$5
here=$(cd "$(dirname "$0")" && pwd)
stage=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/lidclosed-pkg.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
root="$stage/root"
install -d -m 755 "$root/Applications" "$root/Library/LaunchDaemons" "$root/Library/PrivilegedHelperTools"
ditto "$app" "$root/Applications/LidClosed.app"
chmod -R go-w "$root/Applications/LidClosed.app"
install -m 755 "$here/lidclosed-helper.sh" "$root/Library/PrivilegedHelperTools/com.akwnnwastaken.LidClosed.helper"
for name in cleanup batteryguard; do
  install -m 644 "$here/../Resources/com.akwnnwastaken.LidClosed.$name.plist" "$root/Library/LaunchDaemons/"
done
install -d "$stage/scripts"
install -m 755 "$here/pkg/postinstall" "$stage/scripts/postinstall"
# The signing process uses a private umask; shared payload parents must remain traversable.
chmod 755 "$root" "$root/Applications" "$root/Library" "$root/Library/"{LaunchDaemons,PrivilegedHelperTools}
pkgbuild --root "$root" --ownership recommended --install-location / \
  --identifier com.akwnnwastaken.LidClosed.installer --version "$version" \
  --component-plist "$here/pkg/components.plist" --scripts "$stage/scripts" \
  --sign "$identity" --keychain "$keychain" --timestamp "$output"
pkgutil --expand "$output" "$stage/expanded"
# Validate security-critical metadata in the actual package bill of materials.
lsbom -p fmug "$stage/expanded/Bom" | awk '
  $3 != 0 || $4 != 0 { bad = 1 }
  $1 == "./Applications/LidClosed.app" && $2 == "40755" { app = 1 }
  $1 == "./Library/PrivilegedHelperTools/com.akwnnwastaken.LidClosed.helper" && $2 == "100755" { helper = 1 }
  $1 ~ /^\.\/Library\/LaunchDaemons\/com\.akwnnwastaken\.LidClosed\.(cleanup|batteryguard)\.plist$/ && $2 == "100644" { jobs++ }
  END { exit !(!bad && app && helper && jobs == 2) }'
