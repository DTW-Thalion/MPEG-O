#!/usr/bin/env bash
# Rebuild all three language API docs.
# Writes into docs/api/{python,java,objc}/.

set -e
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

echo "=== Python (Sphinx) ==="
cd "$repo/python"
source .venv/bin/activate
sphinx-build -b html --keep-going docs docs/_build/html
mkdir -p "$repo/docs/api/python"
rm -rf "$repo/docs/api/python/"*
cp -r docs/_build/html/. "$repo/docs/api/python/"
deactivate

echo "=== Java (Javadoc) ==="
cd "$repo/java"
mvn -q javadoc:javadoc

echo "=== Objective-C (autogsdoc) ==="
cd "$repo/objc/Documentation"
if command -v gnustep-config >/dev/null 2>&1; then
    . "$(gnustep-config --variable=GNUSTEP_MAKEFILES)/GNUstep.sh"
fi
make
mkdir -p "$repo/docs/api/objc"
rm -rf "$repo/docs/api/objc/"*
cp -r libTTIO/. "$repo/docs/api/objc/"

echo ""
echo "Done. Open docs/api/index.html in a browser."
