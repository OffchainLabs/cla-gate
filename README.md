# CLA gate

CLA assistant sometimes stalls and leaves `license/cla` pending, which blocks merges. This
repository holds a workflow that an organization ruleset runs on pull requests in selected
repositories. When the pull request author and every commit author are OffchainLabs members, the
workflow posts `license/cla: success` itself. Every other pull request is left for CLA assistant.

## How it works

The ruleset runs `cla-gate.yml` in each gated repository on pull requests into the branches it
targets. The gate reads a GitHub App's private key from AWS Secrets Manager, creates a token from
the app, which has only **Members: read**, and checks each login with
`GET /orgs/OffchainLabs/members/{login}`, which also sees concealed memberships.

The gate decides as follows:

1. Pull requests from forks are skipped and left to CLA assistant. Only people with write access
   can open pull requests from branches in the repository.
2. `dependabot[bot]` and `github-actions[bot]` count as members without a lookup, because
   Dependabot runs don't get Actions secrets and so can't read the key.
3. If the pull request author or any commit author isn't a member, or a commit's email isn't
   linked to a GitHub account, it stops. Git author emails are unverified, so commit authors are
   checked as well as the authenticated pull request author.
4. If the pull request's head changed while it was checking, it stops; the run for the new head
   decides instead.
5. Otherwise it posts `license/cla: success` on the head commit, labelled "(CLA gate)".

Errors are reported on the run but never fail it, and the gate never posts a failure, so a broken
gate leaves pull requests to CLA assistant.

A status belongs to a commit, so a success counts in every pull request with that head commit.
That is safe as long as every branch that takes pull requests is targeted: the gate only runs on
pull requests into targeted branches, so each commit added to one of them since it was targeted
passed the gate or CLA assistant. Opening the same commit against another targeted branch adds
only such commits, apart from history that was already in a branch when it was first targeted.

The app key is stored in the security team's AWS account. The gate assumes an AWS role with
GitHub's OIDC token. The role trusts only this workflow on this repository's `main` branch, so
other workflows in gated repositories can't read the key.
Gated repositories can have public logs, and AWS's output names the account, the role and the
secret, so the gate calls AWS with the AWS CLI and prints none of its output; on failure it
prints only its own message. It masks the OIDC token, the AWS credentials and every line of the
key. The role's ARN is an org secret, so it's masked too; any workflow in an OffchainLabs
repository can still read it, which is harmless because the role only trusts this workflow. The
app has no permissions beyond **Members: read**.

## Setup

Requires an OffchainLabs organization owner.

### 1. Publish this repository

`OffchainLabs/cla-gate` must be **public**, because a ruleset workflow must be at least as visible
as the repositories it runs in. The ruleset runs the workflow from `main`, so every merge to
`main` deploys to all gated repositories at once and can read the app key. Keep `main` behind
reviewed pull requests and the required checks.

The AWS role trusts the workflow by this repository's name. Before renaming, transferring or
deleting the repository, have the security team change or remove the role; otherwise a new
repository created as `OffchainLabs/cla-gate` could read the key.

### 2. Create the GitHub App

In OffchainLabs organization settings → Developer settings → GitHub Apps → New GitHub App:

- Uncheck **Webhook → Active**.
- Permissions: **Organization → Members: Read-only**. Nothing else.
- Where can this app be installed: **Only on this account**.

Install it on OffchainLabs. Note the **Client ID**, and generate a private key.

### 3. Choose repositories

Organization settings → Custom properties: create a `cla-gate` property (true/false), then set it
to `true` on each repository to gate. Leave **Allow repository actors to set this property**
unchecked, or repository admins can remove their repository from the gate. CLA assistant must
already be enabled for those repositories.

### 4. Store the key

The security team manages the AWS role and the `cla-gate-app-key` secret. The role must trust
`OffchainLabs/cla-gate/.github/workflows/cla-gate.yml@refs/heads/main`. Put the private key in
that secret as plain text, not as key/value pairs, then delete the local `.pem`.
The gate rejects any value that isn't a PEM private key.

Store the role's ARN and the app's client ID for the gate. `gh secret set` prompts for the ARN,
which keeps it out of shell history:

```sh
gh secret set CLA_GATE_AWS_ROLE_ARN --org OffchainLabs --visibility all
gh variable set CLA_GATE_CLIENT_ID --org OffchainLabs --visibility all --body CLIENT_ID
```

If the app's key was ever stored anywhere else, such as an Actions secret, delete that copy and
delete the old key in the app's settings, so it's revoked rather than just unused.

### 5. Block secrets for fork pull requests

Enterprise settings → Policies → Actions: for fork pull request workflows in private repositories,
turn off **Send write tokens to workflows from pull requests** and **Send secrets and variables to
workflows from pull requests**.

### 6. Create the ruleset

Organization settings → Rulesets → New branch ruleset:

- Target: repositories where property `cla-gate` is `true`; the default branch and every other
  long-lived branch that takes pull requests, such as `develop`. Target only branches that change
  through pull requests, because requiring a workflow blocks direct pushes.
- **Require status checks to pass**: `license/cla`.
- **Require workflows to pass before merging**: `OffchainLabs/cla-gate`,
  `.github/workflows/cla-gate.yml`, at ref `refs/heads/main`. Pin to the branch, not a commit:
  the role trusts the workflow only by that ref, so a run pinned to a commit can't read the key.

Start in **Evaluate** mode, open a pull request in a gated repository, then switch to **Active**.

## Tests

`tests/run-tests.sh` pulls the gate's scripts out of `cla-gate.yml` and runs them against stub
`gh`, `curl` and `aws` commands. It checks each case's exit code, the statuses posted, the logins
looked up, and the output, and that the key step prints nothing but masks for every line of the
key. CI runs it on every pull request. Running it locally needs `yq` and bash 4 or
later; on macOS, `brew install yq bash`.

## Tested behaviour

Verified with the OffchainLabs organization ruleset on `OffchainLabs/cla-gate-test`, with the
version before the key moved to AWS:

- A branch pull request by a member with concealed membership gets `license/cla: success`.
- A Dependabot pull request gets `license/cla: success`. The token step fails because the run has
  no Actions secrets, and the gate passes `dependabot[bot]` without a lookup.

With earlier versions of the gate:

- The ruleset runs this workflow in the target repository, in both Evaluate and Active mode.
- A fork pull request skips the job, posts nothing, and the skipped run satisfies the required
  workflow, so the pull request waits only on CLA assistant.
- With the app not installed, the run reports the error, posts nothing, and still passes.
- The ruleset doesn't run the workflow on pull requests into branches it doesn't target.
- A ruleset can pin the workflow to a branch, and the run's OIDC token then has
  `job_workflow_ref` ending in that branch ref (`@refs/heads/<branch>`), not the commit.

On `arbitrum-docs` before gating, CLA assistant only ever posted `license/cla: success` on member
pull requests, from minutes to over a day after they opened, and sometimes never.

Not yet tested: reading the key from AWS, and an enterprise ruleset running this workflow in
organizations other than OffchainLabs.

## Known limitations

- Ruleset workflows run only when a pull request is opened, reopened, or pushed to, and ignore
  `types` filters. A pull request moved from an untargeted base to a targeted one has no gate run
  until it's pushed to or closed and reopened.
- Ruleset workflows don't run on events caused by `GITHUB_TOKEN`, so a pull request opened or
  pushed to by a workflow using it never runs the gate and waits on the required workflow. Close
  and reopen it to run the gate, or open such pull requests with a GitHub App token.
- When a branch such as `develop` is first targeted, commits already on it haven't been checked.
  A commit that passed in a pull request into `develop` also passes when opened against `main`,
  even though that pull request also brings in those older commits. Opening `develop` itself
  against `main` checks them.
- The newest `license/cla` status wins. If CLA assistant posts a failure or pending after the
  gate's success, for example for a member it considers unsigned, the pull request is blocked
  until CLA assistant passes it.
- A member can pass someone else's code by committing it under their own name. CLA assistant has
  the same limitation.
- Git author emails are unverified. Anyone who can push to a gated repository can add commits
  authored as a member, or as `dependabot[bot]`, to a member's or Dependabot's pull request, and
  the gate counts them as that author. The same people can also post `license/cla` themselves,
  because the ruleset doesn't require the status to come from a particular app.
- Re-running an old workflow run reuses the version of the gate it originally ran, and the AWS
  role trusts every version on `main`, since AWS can't condition on the commit. GitHub allows
  re-runs for 30 days. So if a version that exposes the key ever reaches `main`, neither reverting
  nor rotating the key is enough on its own: a re-run of that version would read the new key.
  Instead, in this order:
  1. Put the fixed gate on a new branch and add the branch to the ruleset that protects `main`.
     Have the security team change the role's trusted `job_workflow_ref` to that branch, then
     point the org ruleset that runs the gate at it. Old runs still name `refs/heads/main`, so
     the role rejects them.
  2. Revoke the role's active AWS sessions (IAM → the role → **Revoke active sessions**).
  3. Rotate the app key: store a new one in Secrets Manager and delete the old one in the app's
     settings.

  Keep the new branch for at least 30 days before moving back to `main`.
- The gate job runs on the gated repository's runners. An admin of a gated repository who
  registers a self-hosted runner could receive the job, and with it the key, so gated
  repositories' admins are trusted with the key.
