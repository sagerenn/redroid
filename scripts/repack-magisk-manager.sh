#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <magisk-apk> <output-apk>" >&2
  exit 1
fi

magisk_apk=$1
output_apk=$2
package_name=${MAGISK_MANAGER_PACKAGE:-repackaged.com.topjohnwu.magisk}
app_label=${MAGISK_MANAGER_LABEL:-Magisk}

workdir=$(mktemp -d)
cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT

stub_apk="$workdir/stub.apk"
unzip -p "$magisk_apk" assets/stub.apk > "$stub_apk"

decoded="$workdir/stub"
apktool d -f -o "$decoded" "$stub_apk" >/dev/null

manifest="$decoded/AndroidManifest.xml"

python3 - <<'PY' "$manifest" "$package_name" "$app_label"
import random
import re
import sys
from pathlib import Path

manifest_path, package_name, app_label = sys.argv[1:4]
text = Path(manifest_path).read_text(encoding='utf-8')

letters = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
tail = letters + '0123456789'
rng = random.Random(1337)

first = []
second = []
third = []
for a in letters:
    if a not in ('a', 'A'):
        first.append(a)
    for b in tail:
        second.append(a + b)
        for c in tail:
            third.append(a + b + c)
rng.shuffle(first)
rng.shuffle(second)
rng.shuffle(third)

names = first + second[:30] + third[:30]
used = set()

def next_name():
    while True:
        name = rng.choice(names) + '.' + rng.choice(names)
        name = name[0].lower() + name[1:]
        if name not in used:
            used.add(name)
            return name

mapping = {f'x.COMPONENT_PLACEHOLDER_{idx}': next_name() for idx in range(6)}

text = text.replace('package="com.topjohnwu.magisk"', f'package="{package_name}"')
text = text.replace('android:authorities="com.topjohnwu.magisk.provider"', f'android:authorities="{package_name}.provider"')
text = text.replace('android:label="Magisk"', f'android:label="{app_label}"')

for old, new in mapping.items():
    text = text.replace(old, new)

Path(manifest_path).write_text(text, encoding='utf-8')
PY

built_dir="$workdir/build"
apktool b -o "$built_dir/unsigned.apk" "$decoded" >/dev/null

keystore="$workdir/manager.jks"
storepass=magisk
keypass=magisk
alias_name=magisk

keytool -genkeypair \
  -alias "$alias_name" \
  -keystore "$keystore" \
  -storepass "$storepass" \
  -keypass "$keypass" \
  -keyalg RSA \
  -keysize 4096 \
  -validity 10950 \
  -dname "C=US,ST=California,L=Mountain View,O=Google Inc.,OU=Android,CN=Android" \
  >/dev/null 2>&1

cp "$built_dir/unsigned.apk" "$output_apk"
jarsigner \
  -keystore "$keystore" \
  -storepass "$storepass" \
  -keypass "$keypass" \
  "$output_apk" "$alias_name" >/dev/null

echo "$output_apk"
