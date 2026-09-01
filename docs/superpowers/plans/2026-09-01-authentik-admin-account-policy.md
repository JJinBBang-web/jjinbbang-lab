# Authentik Admin Account Policy Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an invitation-only Authentik enrollment path that creates personal users without granting administrator access, while preserving explicit dev/prod group approval.

**Architecture:** Keep administrator authorization in existing Authentik application bindings and Spring group checks. Add one declarative enrollment blueprint to the Authentik bootstrap, apply it with the existing one-shot Job, and enforce the contract with a focused shell test plus the existing manifest validation.

**Tech Stack:** Authentik 2026.2 blueprint YAML, Kubernetes ConfigMap/Job, Kustomize, POSIX shell validation

---

## Chunk 1: Invitation-only enrollment

### Task 1: Add a failing account-policy contract test

**Files:**
- Create: `scripts/test-authentik-admin-account-policy.sh`
- Modify: `scripts/validate-manifests.sh`

- [ ] Assert that an invitation stage exists and sets `continue_flow_without_invitation: false`.
- [ ] Assert that the enrollment user-write stage does not contain `create_users_group`.
- [ ] Assert that existing dev/prod application bindings still target their environment-specific groups.
- [ ] Run `./scripts/test-authentik-admin-account-policy.sh` and verify it fails before the blueprint exists.

### Task 2: Add the minimal Authentik enrollment blueprint

**Files:**
- Create: `platform/authentik/bootstrap/admin-enrollment-blueprint-configmap.yaml`
- Modify: `platform/authentik/bootstrap/kustomization.yaml`
- Modify: `platform/authentik/bootstrap/apply-blueprints-job.yaml`

- [ ] Define an invitation-only internal-user enrollment flow based on Authentik's maintained invitation blueprint.
- [ ] Collect username, password, name, and email; create the user under `users/jjinbbang/pending`.
- [ ] Do not auto-assign dev, prod, or Authentik administrator groups.
- [ ] Mount and apply the new blueprint after the existing SSO blueprint.
- [ ] Run the focused test and `./scripts/validate-manifests.sh`.

### Task 3: Document the account lifecycle

**Files:**
- Modify: `docs/runbooks/authentik-sso.md`
- Modify: `README.md`

- [ ] Document single-use 48-hour invitations, MFA-before-approval, dev/prod group approval, revocation, and break-glass handling.
- [ ] Run manifest validation again and inspect the complete diff for secrets.

### Task 4: Publish and apply after Git approval

**Files:**
- No additional source files.

- [ ] Commit the isolated change after presenting the required approval brief.
- [ ] Push the feature branch and open a PR to `main` after approval.
- [ ] Merge only after CI passes and separate merge approval is present.
- [ ] Apply/recreate the Authentik bootstrap Job after live-change approval.
- [ ] Verify the flow exists, tokenless enrollment is denied, group bindings remain unchanged, and existing SSO health is unaffected.
