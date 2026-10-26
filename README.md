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
  `CLA_MEMBERS` and never has access to the app key.

Most members keep their membership concealed, and workflows in fork pull requests can read
organization variables. So `CLA_MEMBERS` holds an HMAC-SHA256 of each lowercased login rather than
the login itself, keyed with the `CLA_MEMBERS_KEY` organization secret. Fork pull requests don't
get secrets, so they see only hashes they can't check guesses against. Anyone who can run a
workflow in an OffchainLabs repository from a branch, which takes write access, can read the key
and test whether a given login is a member.

The gate decides as follows:

1. Pull requests from forks are skipped and left to CLA assistant. Only people with write access can
   open pull requests from branches in the repository.
2. `dependabot[bot]` and `github-actions[bot]` count as members without consulting
   `CLA_MEMBERS`, because Dependabot runs don't get `CLA_MEMBERS_KEY`.
3. If `CLA_MEMBERS` was last synced more than 24 hours ago, it reports an error and stops, so
   people who have left the organization don't keep passing while the sync is broken.
4. If the pull request author or any commit author isn't a member, or a commit's email isn't
   linked to a GitHub account, it stops. Git author emails are unverified, so commit authors are
   checked as well as the authenticated pull request author.
5. If the pull request's head changed while it was checking, it stops; the run for the new head
   decides instead.
6. Otherwise it posts `license/cla: success` on the head commit, labelled "(CLA gate)".

Statuses belong to a commit, not a pull request, so a success can outlive the reason for it: the
base branch can change and bring in other people's commits, or the same commit can be opened
against another branch. The gate reruns when a pull request is edited, and whenever it stops
after an earlier success of its own on that commit, it replaces that success with
`license/cla: pending`. Its **Details** link asks CLA assistant to recheck.

Errors are reported on the run but never fail it, so a broken gate can't block merges. New members
pass once the next sync runs; until then their pull requests wait on CLA assistant.

## Setup

Requires an OffchainLabs organization owner.

### 1. Publish this repository

`OffchainLabs/cla-gate` must be **public**, because a ruleset workflow must be at least as visible
as the repositories it runs in. Add a ruleset on `main` requiring a reviewed pull request, with
approval of the most recent push, because anyone who can push to `main` can read the app key. The
key can rewrite every OffchainLabs Actions variable, not only `CLA_MEMBERS`: GitHub can't limit
the Variables permission to one variable.

### 2. Create the GitHub App

In OffchainLabs organization settings → Developer settings → GitHub Apps → New GitHub App:

- Uncheck **Webhook → Active**.
- Permissions: **Organization → Members: Read-only** and **Organization → Variables: Read and
  write**. Nothing else.
- Where can this app be installed: **Only on this account**.

Install it on OffchainLabs. Note the **Client ID**.

### 3. Store the keys

Create the hash key as an organization secret. The sync and every gated repository read it:

```sh
openssl rand -hex 32 | gh secret set CLA_MEMBERS_KEY --org OffchainLabs --visibility all
```

Generate a private key from the app's settings page, then store it in the sync environment:

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
to `true` on each repository to gate. Leave **Allow repository actors to set this property**
unchecked, or repository admins can remove their repository from the gate. CLA assistant must
already be enabled for those repositories.

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

## Known limitations

- GitHub disables scheduled workflows in public repositories after 60 days without repository
  activity. Writing `CLA_MEMBERS` doesn't count, so once this repository goes quiet the sync stops.
  A day later the gate starts reporting errors and every pull request waits on CLA assistant.
  Re-enable **Sync members** from the Actions tab if that happens.
- `CLA_MEMBERS` can be up to an hour old. New members' pull requests wait on CLA assistant until
  the next sync, and people who left can pass until then.
- A repository variable takes precedence over an organization variable of the same name, so an
  admin of a gated repository can override `CLA_MEMBERS` there and pass anyone. The gate can't
  detect this. It doesn't add much: any member can already pass an outsider's code by committing it
  under their own name.
