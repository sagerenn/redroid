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
unzip -q "$stub_apk" -d "$decoded"

# Drop the original stub signatures before rebuilding the APK.
rm -rf "$decoded/META-INF"

manifest_bin="$decoded/AndroidManifest.xml"

python3 - <<'PY' "$manifest_bin" "$package_name" "$app_label"
import random
import struct
import sys
from pathlib import Path

manifest_path, package_name, app_label = sys.argv[1:4]
data = bytearray(Path(manifest_path).read_bytes())

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

replacements = {
    'com.topjohnwu.magisk.provider': f'{package_name}.provider',
    'com.topjohnwu.magisk': package_name,
    'Magisk': app_label,
}
for idx in range(6):
    replacements[f'x.COMPONENT_PLACEHOLDER_{idx}'] = next_name()

def u32(off):
    return struct.unpack_from('<I', data, off)[0]

def u16(off):
    return struct.unpack_from('<H', data, off)[0]

def put_u32(off, value):
    struct.pack_into('<I', data, off, value)

def find_string_pool():
    off = 8
    while off < len(data):
      chunk_type = u16(off)
      header_size = u16(off + 2)
      chunk_size = u32(off + 4)
      if chunk_type == 0x0001:
        return off
      if chunk_size <= 0:
        raise RuntimeError('invalid chunk size')
      off += chunk_size
    raise RuntimeError('string pool not found')

start = find_string_pool()
size = u32(start + 4)
count = u32(start + 8)
flags = u32(start + 16)
data_off = start + u32(start + 20)
utf8 = (flags & 0x100) != 0
if utf8:
    raise RuntimeError('unexpected utf8 string pool')

indices = [u32(start + 28 + i * 4) for i in range(count)]
strings = []
for idx in indices:
    off = data_off + idx
    strlen = u16(off)
    raw = data[off + 2:off + 2 + strlen * 2].decode('utf-16le')
    strings.append(raw)

patched = [replacements.get(s, s) for s in strings]
prefix = bytearray(data[:data_off])
string_blob = bytearray()
new_indices = []
for s in patched:
    new_indices.append(len(string_blob))
    encoded = s.encode('utf-16le')
    string_blob += struct.pack('<H', len(s))
    string_blob += encoded
    string_blob += b'\x00\x00'
while len(string_blob) % 4:
    string_blob += b'\x00'

new_size = len(prefix) - start + len(string_blob)
size_diff = new_size - size

put_u32(4, u32(4) + size_diff)
put_u32(start + 4, new_size)

for i, idx in enumerate(new_indices):
    put_u32(start + 28 + i * 4, idx)

patched_bytes = bytearray()
patched_bytes += data[:data_off]
patched_bytes += string_blob
patched_bytes += data[start + size:]

Path(manifest_path).write_bytes(patched_bytes)
PY

unsigned_apk="$workdir/unsigned.apk"
(cd "$decoded" && zip -qr "$unsigned_apk" . -x 'META-INF/*')

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

cp "$unsigned_apk" "$output_apk"
apksigner sign \
  --ks "$keystore" \
  --ks-key-alias "$alias_name" \
  --ks-pass "pass:$storepass" \
  --key-pass "pass:$keypass" \
  --out "$output_apk" \
  "$unsigned_apk" >/dev/null

echo "$output_apk"
