#!/usr/bin/env bash
# Post-release step: rebuild the y-stream and z-stream templates on top of the
# just-released catalog, bumped to the next versions and wired in the OLM graph.
# Usage: ./prepare-next.sh [next-y-version]   (defaults to a minor bump; pass it
# explicitly for a major, e.g. ./prepare-next.sh 3.0.0)
set -euo pipefail
cd "$(dirname "$0")"

SED=${SED:-$(command -v gsed 2>/dev/null || echo sed)}
QUAY=quay.io/redhat-user-workloads/ocp-network-observab-tenant/network-observability-operator-bundle
RHIO=registry.redhat.io/network-observability/network-observability-operator-bundle
OPERATOR=network-observability-operator

buildversion() { $SED -n 's/^BUILDVERSION=//p' "templates/$1.Dockerfile-args"; }

released=$(buildversion next-release)
pending_y=$(buildversion y-stream)
pending_z=$(buildversion z-stream)
grep -q "name: $OPERATOR.v$released\$" templates/released.yaml || {
	echo "templates/released.yaml doesn't contain v$released: run 'make final-ystream' or 'make final-zstream' first" >&2
	exit 1
}

IFS=. read -r major minor patch <<<"$released"
next_z=$major.$minor.$((patch + 1))
if [ "$released" = "$pending_y" ]; then
	next_y=${1:-$major.$((minor + 1)).0} # y-stream release: bump to the next minor
elif [ "$released" = "$pending_z" ]; then
	next_y=${1:-$pending_y} # z-stream release: y-stream keeps its version
else
	echo "v$released matches neither y-stream (v$pending_y) nor z-stream (v$pending_z)" >&2
	exit 1
fi

# released.yaml still refers to the bundle on quay: it is now public on registry.redhat.io
$SED -i -E "s#$QUAY-[yz]stream@#$RHIO@#" templates/released.yaml

prepare() { # $1: stream letter (y|z), $2: next version
	local file=templates/$1-stream.yaml version=$2
	echo "BUILDVERSION=$version" >"templates/$1-stream.Dockerfile-args"
	# insert the next version in the stable channel, ie. before the next channel starts
	awk -v entry="      - name: $OPERATOR.v$version\n        replaces: $OPERATOR.v$released" '
		/^  - schema: olm.channel/ && ++n == 2 { print entry }
		{ print }
	' templates/released.yaml >"$file"
	grep -q "name: $OPERATOR.v$version\$" "$file" || {
		echo "failed to insert v$version in the stable channel of $file" >&2
		exit 1
	}
	printf '  - schema: olm.bundle          # %s\n    image: %s-%sstream:latest\n' "$version" "$QUAY" "$1" >>"$file"
	echo "$1-stream: v$version, replacing v$released"
}

prepare y "$next_y"
prepare z "$next_z"
echo "Once the bundle on-push jobs have succeeded, run 'make generate'."
