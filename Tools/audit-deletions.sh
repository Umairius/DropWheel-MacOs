#!/bin/bash
# Re-checks the deletion audit. If anyone (including me) adds a new removeItem/trashItem call, this fails
# until the new call site has been reviewed and DELETIONS.md updated.
cd "$(dirname "$0")/../Sources/DropWheel" || exit 1
expected=30
found=$(grep -n "removeItem\|trashItem\|unlink(\|removefile\|recycle\|\"rm\"\|/bin/rm" *.swift | grep -v "^FontData\|^IconData" | wc -l | tr -d ' ')
echo "deletion call sites found: $found (audited: $expected)"
if [ "$found" != "$expected" ]; then
  echo "MISMATCH: review these and update DELETIONS.md and this number:"
  grep -n "removeItem\|trashItem\|unlink(\|removefile\|recycle\|\"rm\"\|/bin/rm" *.swift | grep -v "^FontData\|^IconData"
  exit 1
fi
echo "OK"
