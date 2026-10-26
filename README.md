# CLA gate

CLA assistant sometimes stalls and leaves `license/cla` pending, which blocks merges. This
repository holds a workflow that an organization ruleset runs on pull requests in selected
repositories. When the pull request author and every commit author are OffchainLabs members, the
workflow posts `license/cla: success` itself. Every other pull request is left for CLA assistant.

## How it works

Two workflows:

- **`sync-members.yml`** runs hourly in this repository. It reads the OffchainLabs member list
  with a GitHub App and writes it to the `CLA_MEMBERS` organization variable. The app key is a
  secret in this repository's `cla-gate-sync` environment, which deploys only from `main`.
- **`cla-gate.yml`** is run by the ruleset in each gated repository. It checks logins against
  `CLA_MEMBERS` and needs no key.

Gated repositories never have access to the key. Anyone with write access to an OffchainLabs
repository can read `CLA_MEMBERS`, which is the member list every org member can already see.

The gate decides as follows:

1. Pull requests from forks are skipped and left to CLA assistant. Only people with write access can
   open pull requests from branches in the repository.
2. If the pull request author isn't a member, it stops.
3. If any commit author isn't a member, or a commit's email isn't linked to a GitHub account, it
   stops. Git author emails are unverified, so this is checked after the authenticated author.
4. Otherwise it posts `license/cla: success` on the head commit, labelled "(CLA gate)".

`dependabot[bot]` and `github-actions[bot]` count as members. Errors are reported on the run but
never fail it, so a broken gate can't block merges. New members pass once the next sync runs;
until then their pull requests wait on CLA assistant.

## Setup

Requires an OffchainLabs organization owner.

### 1. Publish this repository

`OffchainLabs/cla-gate` must be **public**, because a ruleset workflow must be at least as visible
as the repositories it runs in. Add a ruleset on `main` requiring a reviewed pull request, because
anyone who can push to `main` can read the app key.

### 2. Create the GitHub App

In OffchainLabs organization settings → Developer settings → GitHub Apps → New GitHub App:

- Uncheck **Webhook → Active**.
- Permissions: **Organization → Members: Read-only** and **Organization → Variables: Read and
  write**. Nothing else.
- Where can this app be installed: **Only on this account**.

Install it on OffchainLabs. Note the **Client ID**.

### 3. Store the key in the sync environment

Generate a private key from the app's settings page, then:

```sh
gh api -X PUT repos/OffchainLabs/cla-gate/environments/cla-gate-sync --input - <<'EOF'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
EOF
gh api -X POST repos/OffchainLabs/cla-gate/environments/cla-gate-sync/deployment-branch-policies \
  -f name=main -f type=branch
gh secret set CLA_GATE_PRIVATE_KEY --repo OffchainLabs/cla-gate --env cla-gate-sync \
  < cla-gate.private-key.pem
gh variable set CLA_GATE_CLIENT_ID --repo OffchainLabs/cla-gate --env cla-gate-sync \
  --body CLIENT_ID
```

Then delete the local `.pem`. Run **Sync members** from the Actions tab once and check that
`CLA_MEMBERS` appears in the organization's Actions variables.

### 4. Block secrets for fork pull requests

Enterprise settings → Policies → Actions: for fork pull request workflows in private repositories,
turn off **Send write tokens to workflows from pull requests** and **Send secrets and variables to
workflows from pull requests**.

### 5. Choose repositories

Organization settings → Custom properties: create a `cla-gate` property (true/false), then set it
to `true` on each repository to gate. CLA assistant must already be enabled for those repositories.

### 6. Create the ruleset

Organization settings → Rulesets → New branch ruleset:

- Target: repositories where property `cla-gate` is `true`; the default branch. Target only
  branches that change through pull requests, because requiring a workflow blocks direct pushes.
- **Require status checks to pass**: `license/cla`.
- **Require workflows to pass before merging**: `OffchainLabs/cla-gate`,
  `.github/workflows/cla-gate.yml`, pinned to a commit SHA. Update the pin to deploy changes.

Start in **Evaluate** mode, open a pull request in a gated repository, then switch to **Active**.

## Tested behaviour

Verified with an OffchainLabs organization ruleset on `OffchainLabs/cla-gate-test`:

- The ruleset runs this workflow in the target repository, in both Evaluate and Active mode.
- Sync members writes all organization members to `CLA_MEMBERS`, and the gate reads it.
- A branch pull request by a member gets `license/cla: success` from the gate.
- A fork pull request skips the job, posts nothing, and the skipped run satisfies the required
  workflow, so the pull request waits only on CLA assistant.
- With setup incomplete, the run reports the error, posts nothing, and still passes. This was
  tested with the earlier design that looked up membership live.

Not yet tested: an enterprise ruleset running this workflow in organizations other than
OffchainLabs.
