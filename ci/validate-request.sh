#!/usr/bin/env bash
# Pre-merge hard-stop validation for VM request files (see README.md
# "Validation Rules — Hard Stops"). Exits non-zero if ANY request file
# violates a hard-stop rule; this is the real merge gate.
#
# Requires: yq (mikefarah/yq, v4+) on PATH.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUESTS_DIR="${REPO_ROOT}/requests"
REGISTERED_CLUSTERS_FILE="${REPO_ROOT}/argocd/registered-clusters.yaml"

fail=0
err() {
  echo "ERROR: $1" >&2
  fail=1
}

declare -A registered_clusters
while IFS= read -r cluster; do
  [ -n "$cluster" ] && registered_clusters["$cluster"]=1
done < <(yq -r '.clusters[]' "$REGISTERED_CLUSTERS_FILE")

declare -A seen_ips   # ip -> "file:vm-name" of first sighting

shopt -s globstar nullglob
request_files=("${REQUESTS_DIR}"/**/*.yaml)

if [ "${#request_files[@]}" -eq 0 ]; then
  echo "No request files found under ${REQUESTS_DIR} — nothing to validate."
  exit 0
fi

for file in "${request_files[@]}"; do
  cluster=$(yq -r '.cluster // ""' "$file")
  namespace=$(yq -r '.namespace // ""' "$file")
  network_name=$(yq -r '.network.name // ""' "$file")
  network_bridge=$(yq -r '.network.bridge // ""' "$file")
  ssh_key=$(yq -r '.sshKey // ""' "$file")
  vm_count=$(yq -r '.vms // [] | length' "$file")

  [ -z "$cluster" ] && err "$file: 'cluster' is missing"
  if [ -n "$cluster" ] && [ -z "${registered_clusters[$cluster]:-}" ]; then
    err "$file: cluster '$cluster' is not in argocd/registered-clusters.yaml"
  fi
  [ -z "$namespace" ] && err "$file: 'namespace' is missing"
  [ -z "$network_name" ] && err "$file: 'network.name' is missing"
  [ -z "$network_bridge" ] && err "$file: 'network.bridge' is missing"
  [ -z "$ssh_key" ] && err "$file: 'sshKey' is missing"

  if [ "$vm_count" -eq 0 ]; then
    err "$file: 'vms' is missing or empty"
    continue
  fi

  for i in $(seq 0 $((vm_count - 1))); do
    vm_name=$(yq -r ".vms[$i].name // \"\"" "$file")
    vm_ip=$(yq -r ".vms[$i].ip // \"\"" "$file")

    [ -z "$vm_name" ] && err "$file: vms[$i] is missing 'name'"

    if [ -z "$vm_ip" ]; then
      err "$file: vm '${vm_name:-<unnamed>}' is missing 'ip' (no pod-network fallback exists)"
      continue
    fi

    if [ -n "${seen_ips[$vm_ip]:-}" ]; then
      err "$file: ip '$vm_ip' on vm '$vm_name' duplicates ${seen_ips[$vm_ip]} (repo-wide duplicate)"
    else
      seen_ips[$vm_ip]="$file:$vm_name"
    fi
  done
done

if [ "$fail" -ne 0 ]; then
  echo "Validation FAILED." >&2
  exit 1
fi

echo "Validation passed."
