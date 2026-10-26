# CLA gate

CLA assistant sometimes stalls and leaves `license/cla` pending, which blocks merges. This
repository holds a workflow that an enterprise ruleset runs on pull requests in selected
repositories. When the pull request author and every commit author are OffchainLabs members, the
workflow posts `license/cla: success` itself. Every other pull request is left for CLA assistant.

## How it decides

1. Pull requests from forks are skipped. Only people with write access can open pull requests from
   branches in the repository, so outsiders never start a run that can reach the app key, and
   GitHub never sends secrets to fork pull request runs.
2. If the pull request author isn't an OffchainLabs member, the workflow stops. Checking the
   authenticated author first means nobody can use forged commit authors to probe membership.
3. If any commit author isn't a member, or a commit's email isn't linked to a GitHub account, the
   workflow stops. Git author emails are unverified, so this is checked after the author.
4. Otherwise it posts `license/cla: success` on the head commit, labelled "(CLA gate)".

`dependabot[bot]` and `github-actions[bot]` count as members. Errors are reported on the run but
never fail it, so a broken gate can't block merges.

Membership is checked with `GET /orgs/OffchainLabs/members/{login}`, which returns 204 for members
and 404 otherwise, using a token from a GitHub App whose only permission is organization
Members: read. That is the same access every org member already has, so a leaked key exposes only
the member list.

## Setup

Requires an enterprise owner. Run the `gh` commands as an org owner of each organization named.

### 1. Publish this repository

Create `OffchainLabs/cla-gate` as a **public** repository (a ruleset workflow must be at least as
visible as the repositories it runs in) and push `main`. Add a ruleset on `main` requiring a
reviewed pull request, so changes to the gate are reviewed.

### 2. Create the GitHub App

In OffchainLabs organization settings → Developer settings → GitHub Apps → New GitHub App:

- Uncheck **Webhook → Active**.
- Permissions: **Organization → Members: Read-only**. Nothing else.
- Where can this app be installed: **Only on this account**.

Install it on OffchainLabs. Note the **Client ID**.

### 3. Store the key in each organization with gated repositories

Generate a private key from the app's settings page, then for each organization `ORG` that owns
gated repositories:

```sh
gh secret set CLA_GATE_PRIVATE_KEY --org ORG --visibility all < cla-gate.private-key.pem
gh variable set CLA_GATE_CLIENT_ID --org ORG --visibility all --body CLIENT_ID
```

Then delete the local `.pem`. To rotate, generate a new key, rerun the commands, and delete the old
key in the app settings.

### 4. Block secrets for fork pull requests

Enterprise settings → Policies → Actions: for fork pull request workflows in private repositories,
turn off **Send write tokens to workflows from pull requests** and **Send secrets and variables to
workflows from pull requests**. Public repositories never send secrets to fork pull requests.

### 5. Choose repositories

Enterprise settings → Policies → Custom properties: create a `cla-gate` property (true/false), then
set it to `true` on each repository to gate. CLA assistant must already be enabled for those
repositories.

### 6. Create the enterprise ruleset

Enterprise settings → Policies → Code → Rulesets → New branch ruleset:

- Target: all organizations; repositories where property `cla-gate` is `true`; the default branch.
  Target only branches that change through pull requests, because requiring a workflow blocks
  direct pushes.
- **Require status checks to pass**: `license/cla`.
- **Require workflows to pass before merging**: `OffchainLabs/cla-gate`,
  `.github/workflows/cla-gate.yml`, pinned to a commit SHA. Update the pin to deploy changes.

Start in **Evaluate** mode, open a pull request in a gated repository, then switch to **Active**.

## Verify on a test repository

These behaviours aren't covered by GitHub's documentation and should be checked before going
Active:

- An enterprise ruleset can run this workflow in repositories outside OffchainLabs.
- The ruleset-run workflow receives the target organization's `CLA_GATE_PRIVATE_KEY` and
  `CLA_GATE_CLIENT_ID`.
- A fork pull request, where the job is skipped, still satisfies the required workflow.
