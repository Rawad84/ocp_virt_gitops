# VM Request File Schema

One file = one group of VMs deployed together, sharing a cluster, namespace,
network, and SSH key unless noted otherwise. The file's contents are passed
directly to `charts/vm-request` as Helm values — field names below are the
literal YAML keys the chart and CI script expect.

## Fields

| Field                    | Required | Notes |
|---------------------------|----------|-------|
| `cluster`                  | Yes      | Must match an entry in `argocd/registered-clusters.yaml`. Drives `spec.destination.name` on the generated Application. |
| `namespace`                | Yes      | May be reused by other request files (namespace sharing is allowed — see README.md "Key Design Decisions"). |
| `network.name`             | Yes      | Name of the NetworkAttachmentDefinition to create/attach to. |
| `network.bridge`           | Yes      | Node-level Linux bridge interface name (must already exist via NNCP or equivalent — this repo does not manage node networking). |
| `network.vlan`             | No       | VLAN ID for the bridge attachment. Omit entirely for untagged. |
| `network.prefixLength`     | No       | CIDR prefix length applied to every VM's static IP in this group. Defaults to `24`. |
| `network.gateway`          | No       | IPv4 gateway written into every VM's cloud-init networkData. Omitted if not set. |
| `sshKey`                   | Yes      | Single SSH public key string injected into every VM in this group via cloud-init. |
| `vms[].name`               | Yes      | VM name, also used as the DataVolume name (`<name>-boot`). |
| `vms[].ip`                 | Yes      | Static IP. Must be unique across the ENTIRE repo (enforced by CI). No pod-network fallback exists. |
| `vms[].size`               | No       | `small` \| `medium` \| `large`. Defaults to `small` (chart's `defaultSize`). Maps to a cpuCores/memory pair injected into `spec.domain` — see `charts/vm-request/values.yaml` (currently small=1 vCPU/2Gi, medium=2 vCPU/4Gi, large=4 vCPU/8Gi). |

## Example

```yaml
cluster: in-cluster
namespace: vm-example
network:
  name: example-net
  bridge: br1
  vlan: 100
  prefixLength: 24
  gateway: 192.0.2.1
sshKey: "ssh-ed25519 AAAA... some-key-comment"
vms:
  - name: example-vm-1
    size: small
    ip: 192.0.2.10
  - name: example-vm-2
    ip: 192.0.2.11
```

See `requests/example-group/request.yaml` for a working, CI-passing copy of
this example (using RFC 5737 TEST-NET-1 placeholder addressing).

## Validation

Enforced twice, per README.md's defense-in-depth policy:

1. **CI** (`ci/validate-request.sh`) — the real merge gate. Checks all
   required fields, that `cluster` is in `argocd/registered-clusters.yaml`,
   and that no `vms[].ip` value is duplicated anywhere else in the repo.
2. **Helm chart** (`required(...)` calls in the chart templates) — a
   safety net in case something bypasses CI/PR review.

`namespace` is deliberately NOT checked for uniqueness — see README.md.
