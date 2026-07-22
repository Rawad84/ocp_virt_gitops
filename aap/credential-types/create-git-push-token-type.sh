#!/usr/bin/env bash
# Creates the "Git Push Token" Custom Credential Type in AAP Controller via
# its REST API - the credential type that lets a Credential's stored token
# become the git_push_token extra_var the "VM Intake" Job Template's
# playbook (ansible/playbooks/intake_create_vm_request.yml) expects. The
# built-in "GitHub Personal Access Token" type does NOT do this - it has no
# injector, so a token stored under that type never reaches the playbook.
# See ansible/aap-config/configure_controller.yml's header for the rest of
# the Controller setup this credential type fits into.
#
# Equivalent to creating it by hand under Access -> Credential Types -> Add:
#   Name: Git Push Token
#   Input configuration:
#     fields:
#       - id: token
#         label: Git Push Token
#         type: string
#         secret: true
#     required:
#       - token
#   Injector configuration:
#     extra_vars:
#       git_push_token: "{{ token }}"
#
# Usage:
#   export CONTROLLER_HOST=https://<controller-route>
#   export CONTROLLER_USERNAME=admin
#   export CONTROLLER_PASSWORD=<...>
#   ./create-git-push-token-type.sh
#
# Where to find each value, for an AAP-Operator-deployed instance (Controller
# + EDA + Hub via a single AnsibleAutomationPlatform CR, same pattern as
# ../operator/instance.yaml):
#
#   CONTROLLER_HOST - the Controller route. Find it with:
#     oc get route -n <aap-namespace> | grep controller
#     # -> use the HOST/PORT column value, prefixed with https://
#
#   CONTROLLER_USERNAME - "admin" unless changed post-install.
#
#   CONTROLLER_PASSWORD - the Operator auto-generates this on first deploy
#   and stores it in a Secret in the same namespace as the
#   AnsibleAutomationPlatform CR (named "aap" in this repo's manifests -
#   see ../operator/namespace.yaml). Retrieve it with:
#     oc get secret aap-controller-admin-password -n aap \
#       -o jsonpath='{.data.password}' | base64 -d
#   (Secret name follows the pattern "<AnsibleAutomationPlatform CR
#   name>-controller-admin-password" - adjust the "aap-" prefix and
#   "-n aap" namespace if your instance/namespace is named differently.)
#   Don't print this to a shared terminal/log - pipe it straight into an
#   export, e.g.:
#     export CONTROLLER_PASSWORD=$(oc get secret aap-controller-admin-password \
#       -n aap -o jsonpath='{.data.password}' | base64 -d)
#
# After this exists, create (or recreate) the "git-push-token" Credential
# itself using this type, paste in a real GitHub PAT, and attach it to the
# "VM Intake" Job Template.
set -euo pipefail

: "${CONTROLLER_HOST:?Set CONTROLLER_HOST, e.g. https://aap-controller-aap.apps.example.com}"
: "${CONTROLLER_USERNAME:?Set CONTROLLER_USERNAME}"
: "${CONTROLLER_PASSWORD:?Set CONTROLLER_PASSWORD}"

# -k / --insecure: drop this once the Controller route's TLS cert is trusted
# by wherever you run this from.
curl -sS -k -u "${CONTROLLER_USERNAME}:${CONTROLLER_PASSWORD}" \
  -X POST "${CONTROLLER_HOST}/api/controller/v2/credential_types/" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Git Push Token",
    "description": "Exposes a PAT as the git_push_token extra_var for the VM Intake playbook",
    "kind": "cloud",
    "inputs": {
      "fields": [
        {"id": "token", "label": "Git Push Token", "type": "string", "secret": true}
      ],
      "required": ["token"]
    },
    "injectors": {
      "extra_vars": {"git_push_token": "{{ token }}"}
    }
  }'
