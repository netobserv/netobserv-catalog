#!/usr/bin/env bash
# Render a catalog from a basic template, reusing what was already rendered.
#
# Bundles pinned by digest are immutable, so their blobs are copied from the
# previous output instead of being pulled again: in practice only the pending
# y/z-stream bundle (tagged ':latest') is really rendered. The package and
# channel blobs are always re-rendered, which needs no registry access.
#
# Usage: ./render.sh <template> <output> [opm flags...]
# Set CACHE to read the already-rendered blobs from another file, or CACHE=/dev/null
# to force a full render.
set -euo pipefail
cd "$(dirname "$0")"
shopt -s nullglob
export LC_ALL=C # opm sorts the bundles by name, byte-wise

template=$1
out=$2
shift 2
cache=${CACHE:-$out}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bundles"

# split the previous output in one file per yaml document
if [ -f "$cache" ]; then
	awk -v d="$tmp" 'BEGIN { f = d "/doc-0" } /^---$/ { f = sprintf("%s/doc-%d", d, ++n) } { print > f }' "$cache"
fi

images=()
while IFS= read -r img; do
	images+=("$img")
done < <(yq '.entries[] | select(.schema == "olm.bundle") | .image' "$template")

[ ${#images[@]} -gt 0 ] || {
	echo "no bundle found in $template" >&2
	exit 1
}

for img in "${images[@]}"; do
	doc=
	# a tag can move: only digests are safe to reuse. /dev/null keeps grep off stdin
	# when there is no previous output to look into.
	if [[ $img == *@sha256:* ]]; then
		doc=$(grep -lxF "image: $img" /dev/null "$tmp"/doc-* | head -1) || true
	fi
	if [ -z "$doc" ]; then
		echo "  rendering $img" >&2
		opm render -o yaml "$@" "$img" >"$tmp/fresh"
		doc=$tmp/fresh
	fi
	cp "$doc" "$tmp/bundles/$(sed -n 's/^name: //p' "$doc")"
done

{
	yq 'del(.entries[] | select(.schema == "olm.bundle"))' "$template" >"$tmp/no-bundle.yaml"
	opm alpha render-template basic -o yaml "$@" "$tmp/no-bundle.yaml"
	cat "$tmp"/bundles/*
} >"$tmp/out.yaml"

mv "$tmp/out.yaml" "$out"
