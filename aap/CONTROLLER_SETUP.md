# AAP Controller manual setup — VM GitOps pipeline

Manual UI steps to stand up everything `ansible/aap-config/configure_controller.yml`
would otherwise automate, verified against a live AAP 2.5 instance. All objects
live under Organization **Default**.

Prerequisite: the **VM GitOps Ansible Content** Project already exists and has
synced successfully (Source Control Branch: `feature/aap-bluecat`, or whatever
branch you're testing).

## 0. Applying `configure_controller.yml` instead of doing this by hand

Everything below can be done either by hand in the UI (the steps as written),
or by running `ansible/aap-config/configure_controller.yml` — it's the same
end result either way, since the `ansible.controller.*` modules the playbook
uses are themselves just typed wrappers around Controller's REST API
(`/api/v2/...`). There's no separate "apply via a raw API call" path beyond
that - either let the playbook make those API calls for you, or make them
yourself by hand through the UI (which is what the numbered steps below
document). There's a bootstrap order dependency either way: this playbook
can't run *as a Controller Job Template* on its first execution, because it's
what creates the Project/Job Templates in the first place. Run it from
wherever `ansible-playbook` and the required collections are available
(a workstation, a bastion host, a CI runner) targeting Controller's API
directly:

```bash
ansible-galaxy collection install -r ansible/requirements.yml
ansible-playbook ansible/aap-config/configure_controller.yml \
  -e controller_host=https://<controller-route> \
  -e controller_username=admin \
  -e controller_password="$(oc get secret aap-controller-admin-password -n aap -o jsonpath='{.data.password}' | base64 -d)"
```

`ansible.controller` is a Red Hat certified collection, not on public
Galaxy - it needs an Automation Hub (console.redhat.com, or a Private
Automation Hub) configured as a Galaxy source for `ansible-galaxy collection install` to actually find it, if there's no Hub reachable from wherever
this runs.

Safe to re-run: every task uses `ansible.controller.*` modules, which are
idempotent (`state: present` by default) - re-running against an
already-configured Controller updates in place rather than duplicating
objects.

## 1. Custom Credential Type — "Git Push Token"

The built-in "GitHub Personal Access Token" type stores a token but has no
injector, so it never reaches the playbook. This custom type fixes that.

**Access → Credential Types → Add**

- Name: `Git Push Token`
- Input configuration:
  ```yaml
  fields:
    - id: token
      label: Git Push Token
      type: string
      secret: true
  required:
    - token
  ```
- Injector configuration:
  ```yaml
  extra_vars:
    git_push_token: "{{ token }}"
  ```

Reusable script for this: `aap/credential-types/create-git-push-token-type.sh`

## 2. Credential — `git-push-token`

**Access → Credentials → Add**

- Name: `git-push-token`
- Organization: `Default`
- Credential Type: `Git Push Token` (the one just created)
- Git Push Token field: your GitHub PAT
  - Scope: Fine-grained PAT limited to this repo, **Contents: Read and write** only.
    Or classic PAT with `public_repo` scope.

## 3. Credential — `vm-ssh-key`

**Access → Credentials → Add**

- Name: `vm-ssh-key`
- Organization: `Default`
- Credential Type: `Machine`
- Username: `cloud-user` (default cloud-init user for the `rhel9` DataSource image —
  confirm against your actual golden image if different)
- SSH Private Key: paste a private key (`ssh-keygen -t ed25519 -f vm-ssh-key -N ""`
  to generate a dedicated one)
- Password / Private Key Passphrase: leave blank
- Privilege Escalation Method: leave unset - `postconfig.yml`'s `become: true`
  tasks default to `sudo` with no password, which works because the golden
  image's default `cloud-user` has passwordless sudo out of the box (standard
  for RHEL cloud images); only set this field if pointing at an image where
  that's not true

The **public** half of this key must be passed as the `ssh_key` extra_var on
every VM Intake launch — it's what cloud-init installs into each VM's
`authorized_keys`. They have to be the matching pair.

## 4. Credential — `openshift-<cluster_name>`

Named `openshift-<cluster_name>`, where `cluster_name` is the request file's
clear, human-meaningful cluster identifier — **not** the ArgoCD-reserved
`cluster` field (`in-cluster` etc.). See `ansible/playbooks/intake_create_vm_request.yml`'s
header for why these are two separate fields. For this workshop cluster,
`cluster_name: cluster-fq2h5`, so this credential is named
`openshift-cluster-fq2h5`. A different target cluster needs its own
separately-named credential (`openshift-<its-cluster_name>`), same pattern,
no code change. Used in two places, both by name, neither as a static Job
Template attachment:

- The per-namespace dynamic inventory's `inventory_source` (see
  `ansible/playbooks/intake_create_vm_request.yml` header).
- Passed as `credentials: ["openshift-{{ cluster_name }}"]` at launch time to
  both "VM Wait For Ready" and "VM Post-Configuration" (see
  `ansible/playbooks/tasks/wait_and_configure_vm.yml`) — this is why those
  two templates have **Prompt on launch** checked for Credentials rather
  than this credential being statically attached: a static attachment can't
  vary per launch, so a different `cluster_name` value would silently use
  the wrong cluster's credential.

RBAC/ServiceAccount to back this: `aap/rbac/vm-inventory-serviceaccount.yaml`,
applied **on the target cluster** (`oc apply -f`, generate token with
`oc create token aap-vm-inventory -n aap --duration=8760h`) — a new cluster
needs this applied there too, it's not automatically present just because
it's applied elsewhere.

**Access → Credentials → Add**

- Name: `openshift-cluster-fq2h5` (or `openshift-<cluster_name>` for
  whichever cluster this credential backs)
- Organization: `Default`
- Credential Type: `OpenShift or Kubernetes API Bearer Token`
- OpenShift or Kubernetes API Endpoint: cluster's API URL (`oc whoami --show-server`)
- API authentication bearer token: token from the ServiceAccount above
- Certificate Authority data: leave blank unless using an untrusted custom CA

## 5. Credential — `controller-api`

Lets the intake playbook's `ansible.controller.inventory` /
`ansible.controller.inventory_source` tasks authenticate back to this same
Controller instance. Injects `CONTROLLER_HOST` / `CONTROLLER_USERNAME` /
`CONTROLLER_PASSWORD` as **environment variables** (not extra_vars) — the
playbook tasks must NOT pass `controller_host`/etc. as explicit module
params, or they'll reference undefined vars instead of picking these up.

**Access → Credentials → Add**

- Name: `controller-api`
- Organization: `Default`
- Credential Type: `Red Hat Ansible Automation Platform`
- Red Hat Ansible Automation Platform (host field): this Controller's own URL
- Username: `admin` (or whichever account)
- Password: Controller admin password
  - For an Operator-deployed instance:
    `oc get secret aap-controller-admin-password -n aap -o jsonpath='{.data.password}' | base64 -d`
- OAuth Token: leave blank (mutually exclusive with username/password)

## 6. Skipped for now — `bluecat-api`

Not created while testing with `use_ipam: false` (DHCP mode). Create this
(Machine type, BlueCat host/user/pass) only when ready to test the IPAM path.

## 7. Job Template — "VM Intake"

This is now the orchestrator for the whole provisioning workflow, not just
the git-push step: after pushing `request.yaml`, it also launches "VM Wait
For Ready" and "VM Post-Configuration" (§9, §8 below) for each new VM —
scoped to only the VMs passed in *this* launch, never VMs already in the
group from a prior run. It never talks to the target cluster's API
directly itself (that's what the two launched templates are for), so it
does NOT need an `openshift-<cluster_name>` credential attached. See
`intake_create_vm_request.yml`'s header comment.

**Templates → Add → Job Template**

- Name: `VM Intake`
- Organization: `Default`
- Inventory: `Demo Inventory` (or any existing one — doesn't functionally
  matter, the playbook targets `hosts: localhost` / `connection: local`
  regardless of what's assigned here). Don't check Prompt on launch for it.
- Project: `VM GitOps Ansible Content`
- Playbook: `ansible/playbooks/intake_create_vm_request.yml`
- Execution Environment: `Day 2 EE` (has `ansible.controller` available)
- Credentials: `git-push-token`, `controller-api`
  (add `bluecat-api` later once `use_ipam: true` is being tested)
- Forks/Limit/Verbosity/Job slicing/Timeout/Show changes/Instance
  groups/Labels/Job tags/Skip tags: leave all at default/blank
- Extra variables:
  - Check **Prompt on launch** (top-right checkbox) — required, since
    `group_name`/`cluster_name`/`namespace`/`ssh_key`/`networks`/`vms` differ
    on every launch and have no defaults in the playbook (`cluster` is
    resolved automatically from `cluster_name`, never passed directly - see
    §4 and `intake_create_vm_request.yml`'s header)
  - In the YAML box, set the one default that should apply unless a launch
    overrides it:
    ```yaml
    use_ipam: false
    ```
  - Leave Privilege escalation / Provisioning callback / Enable webhook /
    Concurrent jobs / Enable fact storage / Prevent instance group fallback
    all unchecked

Example full launch extra_vars (DHCP mode) — `use_ipam: false` already comes
from the template default above, the rest gets pasted in at launch time via
the Prompt on launch field. No `cluster` here - it's resolved automatically
from `cluster_name` via `argocd/registered-clusters.yaml`:

```yaml
group_name: group-3
cluster_name: cluster-fq2h5
namespace: vm-example-3
ssh_key: "<public half of vm-ssh-key>"
networks:
  - { name: vlan-1415, vlanID: 1415 }
vms:
  - { name: test-vm-1, size: small, network: vlan-1415 }
```

## 8. Job Template — "VM Post-Configuration"

**Templates → Add → Job Template**

- Name: `VM Post-Configuration`
- Organization: `Default`
- Project: `VM GitOps Ansible Content`
- Playbook: `ansible/playbooks/postconfig.yml`
- Execution Environment: `Day 2 EE`
- Credentials: `vm-ssh-key`
  (for the actual post-config work over SSH into the guest; the separate
  cluster-API credential the `delegate_to: localhost` `kubernetes.core` tasks
  need — to check/patch the once-only `vm-gitops.io/post-config-applied`
  annotation on the VM object — is NOT listed here, see below)
- Options → check **Prompt on launch** for both:
  - **Inventory** (the per-namespace inventory varies per VM request)
  - **Credentials** (lets the caller pass `openshift-{{ cluster_name }}` by name
    at launch time instead of a fixed credential — see §4)
- Extra variables: check **Prompt on launch** too (`vm_name`/`vm_namespace`
  differ per launch and have no defaults in the playbook)

## 9. Job Template — "VM Wait For Ready"

Waits for one VM's guest agent to connect before "VM Post-Configuration"
runs against it - see `ansible/playbooks/wait_for_vm_ready.yml`.

**Templates → Add → Job Template**

- Name: `VM Wait For Ready`
- Organization: `Default`
- Project: `VM GitOps Ansible Content`
- Playbook: `ansible/playbooks/wait_for_vm_ready.yml`
- Inventory: `Demo Inventory` (doesn't functionally matter, same reason as
  VM Intake above)
- Execution Environment: `Day 2 EE`
- Credentials: none statically attached
- Options → check **Prompt on launch** for both:
  - **Credentials** (`openshift-{{ cluster_name }}` by name at launch time, same
    as VM Post-Configuration above)
  - **Extra variables** (`vm_name`/`vm_namespace` differ per launch)
