#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

############################################################
# Help                                                     #
############################################################
show_help()
{
   echo "Generate the release resources"
   echo
   echo "Syntax: generate.sh [-h|-s|-o] [-a author] [-c cve_csv]"
   echo "Options:"
   echo "  -h           Print this help."
   echo "  -s           Fetch snapshots."
   echo "  -o           Overwrite."
   echo "  -a author    Release author (used in metadata labels)."
   echo "  -c cve_csv   Path to a CSV file (Jira export) containing CVEs for this release."
   echo
   echo "Example:"
   echo "  generate.sh -a jdoe -s -c ~/jira-export.csv"
}

# Reset in case getopts has been used previously in the shell.
OPTIND=1

FETCH=0
OVERWRITE=0
AUTHOR=""
CVE_CSV=""
NETOBSERV_SNAPSHOT=""
CATALOGS=

while getopts "hsoa:c:?" opt; do
  case "$opt" in
    h|\?)
      show_help
      exit 0
      ;;
    s)
      FETCH=1
      ;;
    o)
      OVERWRITE=1
      ;;
    a)
      AUTHOR="$OPTARG"
      ;;
    c)
      CVE_CSV="$OPTARG"
      ;;
  esac
done

shift $((OPTIND-1))
[ "${1:-}" = "--" ] && shift

if [ "$#" != "0" ]; then
	echo "Too many arguments: $@"
	show_help
	exit 1
fi

if [ -z "$AUTHOR" ]; then
  echo "ERROR: Author missing (-a option)"
  exit 1
fi

if [ -n "$CVE_CSV" ] && [ ! -f "$CVE_CSV" ]; then
  echo "ERROR: CVE CSV file not found: $CVE_CSV"
  exit 1
fi

# Get the next version to release from templates/next-release.Dockerfile-args
VERSION=$(grep '^BUILDVERSION=' "$REPO_DIR/templates/next-release.Dockerfile-args" | cut -d= -f2)
if [ -z "$VERSION" ]; then
  echo "ERROR: Could not read BUILDVERSION from templates/next-release.Dockerfile-args"
  exit 1
fi
echo "Next release version: $VERSION"

# Parse version components
MAJOR=$(echo "$VERSION" | cut -d. -f1)
MINOR=$(echo "$VERSION" | cut -d. -f2)
PATCH=$(echo "$VERSION" | cut -d. -f3)
VERSION_DASHED="${MAJOR}-${MINOR}-${PATCH}"

# Determine stream: y-stream if patch == 0, z-stream otherwise
if [ "$PATCH" = "0" ]; then
  STREAM="ystream"
else
  STREAM="zstream"
fi
echo "Stream: $STREAM"

# Sanity check: version should match the corresponding stream's Dockerfile-args
STREAM_VERSION=$(grep '^BUILDVERSION=' "$REPO_DIR/templates/${STREAM/stream/-stream}.Dockerfile-args" | cut -d= -f2)
if [ "$VERSION" != "$STREAM_VERSION" ]; then
  echo "ERROR: Version mismatch. next-release has '$VERSION' but ${STREAM/stream/-stream}.Dockerfile-args has '$STREAM_VERSION'"
  exit 1
fi
echo "Version matches $STREAM Dockerfile-args: OK"

# Get list of versioned catalogs from .tekton
CATALOGS=$(ls "$REPO_DIR/.tekton"/catalog-*-push.yaml 2>/dev/null \
  | sed 's|.*/catalog-||;s|-push.yaml||' \
  | grep -v -E '(ystream|zstream)' \
  | sort -t- -k1,1n -k2,2n)

if [ -z "$CATALOGS" ]; then
  echo "ERROR: No versioned catalogs found in .tekton/"
  exit 1
fi
echo ""
echo "Found catalogs: $(echo $CATALOGS | tr '\n' ' ')"

declare -A CATALOG_SNAPSHOTS
for cat in $CATALOGS; do
  CATALOG_SNAPSHOTS[$cat]=""
done

# Sanity check: snapshot should match "<app-name>-<YYYYMMDD>-<HHMMSS>-<seq>"
validate_snapshot() {
  local snapshot="$1"
  local expected_prefix="$2"
  local max_age_days="${3:-21}"

  if ! echo "$snapshot" | grep -qE "^${expected_prefix}-[0-9]{8}-[0-9]{6}-[0-9]+$"; then
    echo "ERROR: Snapshot '$snapshot' does not match expected pattern '${expected_prefix}-YYYYMMDD-HHMMSS-NNN'"
    return 1
  fi

  local snap_date
  snap_date=$(echo "$snapshot" | grep -oE '[0-9]{8}' | head -1)
  local snap_ts
  snap_ts=$(date -d "$snap_date" +%s 2>/dev/null) || {
    echo "ERROR: Could not parse date '$snap_date' from snapshot '$snapshot'"
    return 1
  }
  local now_ts
  now_ts=$(date +%s)
  local age_days=$(( (now_ts - snap_ts) / 86400 ))

  if [ "$age_days" -gt "$max_age_days" ]; then
    echo "ERROR: Snapshot '$snapshot' is $age_days days old (max $max_age_days days)"
    return 1
  fi
  return 0
}

if [[ $FETCH == 1 ]]; then
  # Get the latest snapshot for netobserv konflux app
  echo ""
  echo "Fetching latest snapshot for netobserv-$STREAM..."
  NETOBSERV_SNAPSHOT=$(kubectl get snapshots.appstudio.redhat.com \
    -n ocp-network-observab-tenant \
    -l "pac.test.appstudio.openshift.io/event-type=push,appstudio.openshift.io/application=netobserv-$STREAM" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath="{.items[-1].metadata.name}" 2>&1) || {
    echo "ERROR: Failed to get netobserv snapshot. Are you connected to the expected cluster?"
    echo "  $NETOBSERV_SNAPSHOT"
    exit 1
  }

  if [ -z "$NETOBSERV_SNAPSHOT" ]; then
    echo "ERROR: No snapshot found for netobserv-$STREAM"
    exit 1
  fi
  echo "  Snapshot: $NETOBSERV_SNAPSHOT"

  validate_snapshot "$NETOBSERV_SNAPSHOT" "netobserv-$STREAM" || exit 1
  echo "  Sanity check: OK"

  # For each catalog, get the latest snapshot
  FIRST_TS=""
  MIN_TS=""
  MAX_TS=""

  extract_timestamp() {
    local snapshot="$1"
    local date_part time_part
    date_part=$(echo "$snapshot" | grep -oE '[0-9]{8}' | head -1)
    time_part=$(echo "$snapshot" | grep -oE '[0-9]{8}-([0-9]{6})' | head -1 | cut -d- -f2)
    local formatted="${date_part:0:4}-${date_part:4:2}-${date_part:6:2} ${time_part:0:2}:${time_part:2:2}:${time_part:4:2}"
    date -d "$formatted" +%s 2>/dev/null
  }

  echo ""
  echo "Fetching catalog snapshots..."
  for cat in $CATALOGS; do
    APP_NAME="catalog-$cat"
    echo -n "  $APP_NAME: "
    SNAP=$(kubectl get snapshots.appstudio.redhat.com \
      -n ocp-network-observab-tenant \
      -l "pac.test.appstudio.openshift.io/event-type=push,appstudio.openshift.io/application=$APP_NAME" \
      --sort-by=.metadata.creationTimestamp \
      -o jsonpath="{.items[-1].metadata.name}" 2>&1) || {
      echo "ERROR: Failed to get snapshot for $APP_NAME"
      echo "  $SNAP"
      exit 1
    }

    if [ -z "$SNAP" ]; then
      echo "ERROR: No snapshot found for $APP_NAME"
      exit 1
    fi
    echo "$SNAP"

    validate_snapshot "$SNAP" "$APP_NAME" || exit 1

    CATALOG_SNAPSHOTS[$cat]="$SNAP"

    TS=$(extract_timestamp "$SNAP")
    if [ -z "$FIRST_TS" ]; then
      FIRST_TS="$TS"
      MIN_TS="$TS"
      MAX_TS="$TS"
    else
      [ "$TS" -lt "$MIN_TS" ] && MIN_TS="$TS"
      [ "$TS" -gt "$MAX_TS" ] && MAX_TS="$TS"
    fi
  done

  # Check timestamps are close (within 1 hour)
  DIFF=$((MAX_TS - MIN_TS))
  if [ "$DIFF" -gt 3600 ]; then
    echo ""
    echo "ERROR: Catalog snapshot timestamps differ by more than 1 hour (${DIFF}s)"
    echo "  Earliest: $(date -d @"$MIN_TS" '+%Y-%m-%d %H:%M:%S')"
    echo "  Latest:   $(date -d @"$MAX_TS" '+%Y-%m-%d %H:%M:%S')"
    exit 1
  fi
  echo ""
  echo "Catalog timestamp range: $(date -d @"$MIN_TS" '+%Y-%m-%d %H:%M:%S') .. $(date -d @"$MAX_TS" '+%Y-%m-%d %H:%M:%S') (${DIFF}s apart) - OK"
else
  echo ""
  echo "Skip fetching snaphots (use -s to fetch)"
fi

# Generate release files
RELEASE_DIR="$REPO_DIR/releases/$VERSION"
mkdir -p "$RELEASE_DIR"

# Parse CVEs from CSV if provided
CVE_ENTRIES=""
if [ -n "$CVE_CSV" ]; then
  echo ""
  echo "Parsing CVEs from $CVE_CSV..."
  while IFS= read -r line; do
    RAW_CVE_COMPONENT=$(echo "$line" | grep "CVE-" | sed -r "s~.*(CVE-[0-9]+-[0-9]+) network-observability/([^:]*)-rhel.*:.*~\1 \2-${STREAM}~" || true)
    [ -z "$RAW_CVE_COMPONENT" ] && continue

    CVE_COMPONENT=($RAW_CVE_COMPONENT)

    CVE_ENTRIES="${CVE_ENTRIES}        - key: ${CVE_COMPONENT[0]}
          component: ${CVE_COMPONENT[1]}
"
    echo "  ${CVE_COMPONENT[0]} -> ${CVE_COMPONENT[1]}"
  done < "$CVE_CSV"
fi

if [ -n "$CVE_ENTRIES" ]; then
  RELEASE_TYPE="RHSA"
else
  RELEASE_TYPE="RHEA"
fi

echo ""
NETOBSERV_OUT=$RELEASE_DIR/netobserv.yaml
if [ "$OVERWRITE" != 1 ] && [ -f "${NETOBSERV_OUT}" ]; then
  echo "${NETOBSERV_OUT} already exists, printing to stdout instead (use -o to overwrite)"
  NETOBSERV_OUT="/dev/stdout"
else
  echo "Generating $NETOBSERV_OUT"
fi

# Generate netobserv.yaml
{
  cat <<EOF
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  name: release-netobserv-${VERSION_DASHED}-1
  namespace: ocp-network-observab-tenant
  labels:
    release.appstudio.openshift.io/author: '${AUTHOR}'
spec:
  releasePlan: netobserv-${STREAM}
  snapshot: ${NETOBSERV_SNAPSHOT}
  data:
    releaseNotes:
      type: ${RELEASE_TYPE}
EOF
  if [ -n "$CVE_ENTRIES" ]; then
    echo "      cves:"
    printf '%s' "$CVE_ENTRIES"
  fi
} > "${NETOBSERV_OUT}"

echo ""
FBC_OUT=$RELEASE_DIR/fbc.yaml
if [ "$OVERWRITE" != 1 ] && [ -f "${FBC_OUT}" ]; then
  echo "${FBC_OUT} already exists, printing to stdout instead (use -o to overwrite)"
  FBC_OUT="/dev/stdout"
else
  echo "Generating $FBC_OUT"
  : > "$FBC_OUT"
fi

# Generate fbc.yaml
FIRST_CAT=true
for cat in $CATALOGS; do
  SNAP="${CATALOG_SNAPSHOTS[$cat]}"
  CAT_DASHED="$cat"

  if [ "$FIRST_CAT" = true ]; then
    FIRST_CAT=false
  else
    echo "---" >> "$FBC_OUT"
  fi

  cat >> "$FBC_OUT" <<EOF
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  name: netobserv-${VERSION_DASHED}-fbc-${CAT_DASHED}-0
  namespace: ocp-network-observab-tenant
  labels:
    release.appstudio.openshift.io/author: '${AUTHOR}'
spec:
  releasePlan: netobserv-fbc-v${CAT_DASHED}
  snapshot: ${SNAP}
EOF
done

if [ "$RELEASE_TYPE" = "RHEA" ]; then
  echo ""
  echo "WARNING: No CVEs provided - releaseNotes.type set to RHEA."
  echo "  If this release should include CVEs, go to:"
  echo "  https://redhat.atlassian.net/issues?jql=project%20%3D%20NETOBSERV%20AND%20fixVersion%20%3D%20netobserv-${VERSION}%20AND%20type%20%3D%20Vulnerability"
  echo "  Then click '...' > Export > CSV - my defaults, save the file, and re-run with:"
  echo "  $0 -a $AUTHOR -c <path-to-csv>"
fi

echo ""
echo "Done!"
