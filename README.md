OCP VM Large-Scale GitOps Stack

Purpose

A GitOps-driven system for creating OpenShift Virtualization (OCP Virt) VMs at
scale. A user (or automation) commits a request file to this repo describing
one or more VMs; Argo CD picks it up automatically and creates the
corresponding OpenShift objects — namespace, network attachment, and
VirtualMachine(s) — on the target cluster named in the file.

Target platform: OpenShift 4.20 with OpenShift Virtualization installed.
GitOps engine: Argo CD (OpenShift GitOps operator).

High-Level Flow


A request file is added/edited under requests/ (see schema below).
CI runs on the PR and hard-fails the build if the file violates any
validation rule (see "Validation Rules — Hard Stops"). Nothing merges
until it passes.
On merge, an Argo CD ApplicationSet (Git file generator, watching
requests/**/*.yaml) picks up the new/changed file on its next
reconciliation and generates/updates the corresponding Argo CD
Application.
That Application renders a shared Helm chart using the request file as
its values, and applies: Namespace → NetworkAttachmentDefinition →
DataVolume (base image clone) → VirtualMachine(s), in that sync-wave
order.
Each VM's static IP and NAD reference come directly from the request
file and are injected into the VM's cloudInitNoCloud networkData, so
the guest self-configures its network on first boot.
Day-2 configuration (anything beyond first-boot network/hostname/SSH) is
out of scope for the initial build — see "Phase 2" below.


Repository Layout (target)

.
├── README.md
├── argocd/
│   ├── applicationset-vm-requests.yaml   # ApplicationSet, Git file generator
│   └── registered-clusters.yaml          # allowlist of cluster names known to Argo CD — CI validates `cluster` against this
├── charts/
│   └── vm-request/                       # shared Helm chart, all VMs render from this
│       ├── Chart.yaml
│       ├── values.yaml                   # chart-level defaults (e.g. default size tier)
│       └── templates/
│           ├── networkattachmentdefinition.yaml
│           ├── datavolume.yaml
│           └── virtualmachine.yaml
│           # no namespace.yaml — namespace creation is handled by the
│           # Application's CreateNamespace=true syncOption, not a chart-
│           # owned resource (see Key Design Decisions: namespace sharing)
├── requests/                             # user-submitted request files live here
│   └── <group-name>/
│       └── request.yaml
├── ci/
│   └── validate-request.sh               # pre-merge hard-stop validation + duplicate-IP scan + cluster-registration check
└── docs/
    └── request-schema.md

Nothing above has been created yet — this file is the spec for building it.

VM Request File Schema

One file = one group of VMs deployed together (shared cluster/namespace/network
unless a VM overrides it). Conceptual shape:

yamlcluster: <name>              # REQUIRED — must match an entry in argocd/registered-clusters.yaml
namespace: <name>            # REQUIRED — may match a namespace used by another request file (see below)
network:                     # REQUIRED — NAD reference this group attaches to
  name: <nad-name>            # REQUIRED
  bridge: <bridge-iface>       # REQUIRED — existing node-level Linux bridge (via NNCP), this repo does not manage it
  vlan: <vlan-id>              # OPTIONAL — omit entirely for untagged
  prefixLength: <cidr-bits>    # OPTIONAL — defaults to 24
  gateway: <ipv4>              # OPTIONAL
sshKey: <ssh-public-key>      # REQUIRED — injected into cloud-init for all VMs in this group
vms:
  - name: <vm-name>
    size: small|medium|large # OPTIONAL — defaults if omitted
    ip: <static-ip>          # REQUIRED, must be unique across the ENTIRE repo
  - name: <vm-name-2>
    ip: <static-ip-2>
    # size omitted -> falls back to default tier

Finalized — this schema is now implemented in charts/vm-request/ and
enforced by ci/validate-request.sh. Full field reference:
docs/request-schema.md. Working example: requests/example-group/request.yaml.

Exact field names/structure are still to be finalized when the Helm chart is
built — the above is the agreed shape, not final syntax.

Validation Rules — Hard Stops

These must cause the CI job to fail the PR/build. No silent defaults, no
partial apply:


cluster missing → fail build
cluster does not match an entry in argocd/registered-clusters.yaml → fail
build (prevents a request file from targeting a cluster Argo CD has no
credentials/connection for)
namespace missing → fail build
network (NAD reference) missing → fail build
sshKey missing → fail build
Any VM missing ip → fail build (there is no pod-network fallback —
every VM must have a static IP and a NAD to attach it to)
Any ip that already appears elsewhere in the repo (any other request
file, any other VM) → fail build (repo-wide duplicate check)

Note: namespace is intentionally NOT checked for repo-wide uniqueness —
multiple request files are allowed to target the same (cluster, namespace)
pair. See "Key Design Decisions" for how the chart avoids resource-ownership
conflicts when that happens.


The only field allowed to default silently:


size → falls back to a standard tier (e.g. small) if omitted


Implementation note: enforce these twice — once in CI (schema/lint check or a
helm template dry-run against the file) as the real merge gate, and again
inside the Helm chart using required(...) on cluster/namespace/network/
per-VM ip as a defense-in-depth safety net in case something bypasses PR
review.

Key Design Decisions (and why)


ApplicationSet with a Git "file" generator, not classic App-of-Apps and
not a directory generator. The file generator parses each request file's
contents directly into template parameters, so a file's own cluster
field can drive spec.destination.name — this is what makes "cluster is
mandatory and request-driven" actually work mechanically.
No in-cluster CNI-level IPAM (no Multus/Whereabouts). IP addresses are
supplied directly in the request file by whoever creates it. Collision
protection comes from the CI repo-wide duplicate-IP scan, not from a
Kubernetes IPAM plugin. NADs are plain L2 bridge bindings with no ipam
stanza.
No pod-network fallback. An earlier draft of this design allowed VMs
with no IP to fall back to pod-network-only. That has been explicitly
reversed — IP (and therefore NAD) are mandatory for every VM.
VM sizing via CPU/memory values injected directly into each VM's
spec.domain (small/medium/large mapped in charts/vm-request/values.yaml
to cpuCores/memory pairs), not VirtualMachineClusterInstancetype /
VirtualMachineClusterPreference references. This reverses an earlier
version of this decision. Reasoning: referencing instancetype/preference
objects requires them to already exist on the target cluster (e.g. via
the common-instancetypes operator bundle) — an external dependency this
repo would otherwise have to assume or ship itself. Inlining cpu/memory
keeps sizing fully self-contained: the size→resource mapping still lives
in exactly one place (values.yaml), a request file still only ever says
size: small|medium|large, and no per-VM manifest hardcodes its own
numbers. Current mapping: small=1 vCPU/2Gi, medium=2 vCPU/4Gi,
large=4 vCPU/8Gi.
Git is the canonical, auditable record of IP/namespace/cluster
assignments — there is deliberately no external IPAM service, database,
or portal backing this. git log/git blame on the request files is the
audit trail.
Deleting a request file preserves the underlying resources. The
ApplicationSet's syncPolicy sets preserveResourcesOnDeletion: true, so
when a request file is removed (or the generator otherwise stops
producing it), Argo CD deletes the generated Application object but does
NOT cascade-delete the namespace/NAD/DataVolume/VM it created — those
are orphaned in place, not destroyed. Reasoning: a request file being
deleted, renamed, or moved is a much more common (and often accidental)
event than "please delete this running VM," and the blast radius of
getting that wrong (destroying a live VM) is too high to make deletion
the default. Actual VM teardown should be a separate, deliberate action
(manual oc delete, or a future explicit "decommission" flag), not an
implicit side effect of a git rm.
cluster values are validated against a repo-tracked allowlist
(argocd/registered-clusters.yaml), not by querying Argo CD live from CI.
CI hard-fails if a request file's cluster isn't in that list. This list
must be kept in sync by hand whenever a new cluster is registered with
Argo CD (e.g. via argocd cluster add) — it is a manual bookkeeping step,
not automatically derived, because CI runners are not assumed to have
credentials to query the Argo CD API or list cluster secrets.
Namespace sharing across request files is allowed (Option B). The chart
does NOT template a Namespace object as an owned resource — instead the
generated Application sets the Argo CD syncOption CreateNamespace=true,
which idempotently ensures the namespace exists without any single
Application "owning" it. This means two unrelated request files can
target the same (cluster, namespace) pair — e.g. two teams incrementally
landing VMs into one shared namespace — without Argo CD fighting over
resource-tracking labels on the Namespace object. CI does not enforce
namespace uniqueness (only ip uniqueness is repo-wide-enforced).


Explicitly Out of Scope For Now

Do not build or reintroduce these unless asked — they were discussed and
deliberately set aside in favor of the simpler Git-file-only flow above:


Self-service front-end/portal (Budibase/Appsmith/custom app)
External IPAM service integration (NetBox, Infoblox, etc.)
ITSM/service-catalog integration (ServiceNow or similar)
Pod-network-only fallback path for VMs without an IP
IP-to-subnet/VLAN validity checking — CI only enforces that an ip is
globally unique across the repo, not that it actually belongs to the
subnet/VLAN backing the NAD it's paired with. A request file can still
merge with a syntactically valid but wrong-subnet IP; that's on the
submitter/reviewer to catch, not CI.


Phase 2 (documented, not part of initial build)


Day-2 configuration via Ansible Automation Platform (AAP), which the
customer already has. cloud-init only handles first-boot basics
(hostname, SSH keys, static network). Once a VM is Ready, either a
phone-home callback from cloud-init or Event-Driven Ansible triggers an
AAP Job Template for anything beyond that. Not required for the first
working increment against a real cluster.


Open Assumption to Confirm

Making network (NAD reference) a hard-required field was inferred as a
logical consequence of making ip mandatory (a static IP needs a network to
attach to) — this was flagged to the user but not explicitly confirmed
before this file was written. Confirm before relying on it heavily; it's a
one-line change to relax if wrong.

Prerequisites (Cluster-Side, Outside This Repo's Scope)


OpenShift 4.20 cluster with the OpenShift Virtualization operator and
OpenShift GitOps (Argo CD) operator installed.
Node-level networking (bridge/NNCP or equivalent) already in place for any
VLAN/NAD referenced by request files — this repo manages the NAD object,
not the underlying node network config.
oc, kubectl, helm, and virtctl CLIs available for testing.
Cluster access configured (e.g. oc login / KUBECONFIG) before running
any verification steps below.


Build Order (suggested)


Shared Helm chart (charts/vm-request/) with namespace, NAD, DataVolume,
and VirtualMachine templates, using required(...) for hard-stop fields
and default(...) for size.
ci/validate-request.sh — schema/required-field check + repo-wide
duplicate-IP scan. Wire into whatever CI runs on PRs to this repo.
argocd/applicationset-vm-requests.yaml — Git file generator pointed at
requests/**/*.yaml, template using generator params for
cluster/namespace/values.
One example request file under requests/ to prove the pipeline end to
end.
Apply the ApplicationSet to a real OCP cluster and verify.


Testing & Verification Against a Real Cluster

After applying the ApplicationSet and committing an example request file:


oc get applications.argoproj.io -n openshift-gitops — confirm the
Application was generated from the request file and is Synced/Healthy.
oc get namespace <ns> — confirm the namespace was created.
oc get network-attachment-definitions -n <ns> — confirm the NAD exists
and has no ipam stanza.
oc get vm -n <ns> and oc get vmi -n <ns> — confirm VM(s) exist and are
Running.
virtctl console <vm-name> -n <ns> (or SSH once network is confirmed) —
verify the guest actually picked up the static IP from cloud-init.
Deliberately commit a bad file (missing cluster, missing ip, or a
duplicate ip) and confirm CI fails the build before merge — this is the
most important test, since the hard-stop behavior is the core contract of
this design.
