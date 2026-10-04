#!/bin/bash
# Fetch the EB1911 corpus: the complete Wikisource transcription rendered to
# HTML by https://github.com/dcampos/eb1911, rebuilt weekly, as JSON-lines.
# 82 MB.  Public domain text; the repo's tooling is the author's.
set -e
cd "$(dirname "$0")"
mkdir -p data
U=$(curl -sL --retry 3 "https://api.github.com/repos/dcampos/eb1911/releases" \
    | python3 -c "import json,sys
for a in json.load(sys.stdin)[0]['assets']:
    if a['name']=='all.json.bz2': print(a['browser_download_url']); break")
[ -n "$U" ] || { echo "could not find all.json.bz2 in the latest release" >&2; exit 1; }
echo "  $U"
curl -fL --retry 3 -o data/all.json.bz2 "$U"
ls -la data/all.json.bz2
