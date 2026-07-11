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
  ssh_key=$(yq -r '.sshKey // ""' "$file")
  vm_count=$(yq -r '.vms // [] | length' "$file")
  network_count=$(yq -r '.networks // [] | length' "$file")

  [ -z "$cluster" ] && err "$file: 'cluster' is missing"
  if [ -n "$cluster" ] && [ -z "${registered_clusters[$cluster]:-}" ]; then
    err "$file: cluster '$cluster' is not in argocd/registered-clusters.yaml"
  fi
  [ -z "$namespace" ] && err "$file: 'namespace' is missing"
  [ -z "$ssh_key" ] && err "$file: 'sshKey' is missing"

  declare -A seen_network_names   # reset per file
  seen_network_names=()

  if [ "$network_count" -eq 0 ]; then
    err "$file: 'networks' is missing or empty"
  else
    for j in $(seq 0 $((network_count - 1))); do
      net_name=$(yq -r ".networks[$j].name // \"\"" "$file")
      net_bridge=$(yq -r ".networks[$j].bridge // \"\"" "$file")

      [ -z "$net_name" ] && err "$file: networks[$j] is missing 'name'"
      [ -z "$net_bridge" ] && err "$file: networks[$j] (${net_name:-<unnamed>}) is missing 'bridge'"

      if [ -n "$net_name" ]; then
        if [ -n "${seen_network_names[$net_name]:-}" ]; then
          err "$file: networks[$j] name '$net_name' duplicates another network in the same file"
        else
          seen_network_names[$net_name]=1
        fi
      fi
    done
  fi

  if [ "$vm_count" -eq 0 ]; then
    err "$file: 'vms' is missing or empty"
    continue
  fi

  for i in $(seq 0 $((vm_count - 1))); do
    vm_name=$(yq -r ".vms[$i].name // \"\"" "$file")
    vm_ip=$(yq -r ".vms[$i].ip // \"\"" "$file")
    vm_network=$(yq -r ".vms[$i].network // \"\"" "$file")

    [ -z "$vm_name" ] && err "$file: vms[$i] is missing 'name'"

    if [ -z "$vm_network" ]; then
      if [ "$network_count" -gt 1 ]; then
        err "$file: vm '${vm_name:-<unnamed>}' is missing 'network' (required when 'networks' has more than one entry)"
      fi
    elif [ -z "${seen_network_names[$vm_network]:-}" ]; then
      err "$file: vm '${vm_name:-<unnamed>}' references network '$vm_network' which is not in 'networks'"
    fi

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
