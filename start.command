#!/bin/sh
set -eu
cd "$(dirname "$0")"
exec /usr/bin/osascript -l JavaScript app/check-in.js
