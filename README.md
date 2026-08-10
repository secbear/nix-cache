# Personal Nix Cache Infra

Flake-first infrastructure for a low-cost personal Nix binary cache:

- `niks3` on Fly.io for the write/admin plane
- Neon Free for PostgreSQL metadata
- Cloudflare R2 for object storage and public cache reads

The repo is intentionally split by control plane:

- `flake.nix` owns the toolchain, commands, and local workflow
- `infra/opentofu` owns provider resources and runtime wiring inputs
- `fly/` owns the app deployment shape
- `.envrc` provides the optional local bootstrap hook for secret injection

The public read path goes straight to R2. The Fly app only handles uploads, GC, and admin APIs. That keeps the running Fly VM small and cheap. OpenTofu manages only non-secret infrastructure; every real secret is injected through environment variables at runtime.

## Why This Shape

- Lowest practical cloud cost for `niks3`
- Public repo friendly: no raw secrets, no state, no private IP assumptions
- Main operational commands: `just plan`, `just up`, `just deploy`, `just gc`, `just down`
- Tracked example config in `infra/opentofu/stack.auto.tfvars.example.json`, with the real environment file kept local
- Secret-source agnostic: `bws run`, shell exports, or any other env injector all work

As of March 28, 2026, the intended baseline is roughly:

- Fly `shared-cpu-1x 256MB`: about `$1.94/mo`
- Neon Free: `$0`
- Cloudflare R2: first `10 GB` free, then `$0.015/GB-month`

That keeps a personal cache under `$10/mo` until roughly the `500 GB` range, before request overages.

## Layout

```text
.
├── flake.nix
├── justfile
├── .envrc
├── fly/
│   └── fly.toml.tmpl
├── .github/
│   └── workflows/
│       └── niks3-push.yml
├── infra/
│   └── opentofu/
│       ├── cloudflare.tf
│       ├── locals.tf
│       ├── outputs.tf
│       ├── providers.tf
│       ├── stack.auto.tfvars.example.json
│       ├── variables.tf
│       └── versions.tf
├── nix/
│   ├── flake/
│   │   ├── apps.nix
│   │   ├── devshell.nix
│   │   ├── packages.nix
│   │   └── treefmt.nix
│   └── lib/
│       └── mk-project-script.nix
```

## Quickstart

All commands below assume you are inside the flake dev shell.

Either:

```sh
nix develop
```

or, if you use `direnv`:

```sh
direnv allow
```

1. Run `just init-config` to create a local `infra/opentofu/stack.auto.tfvars.json` from the tracked example.

1. Edit `infra/opentofu/stack.auto.tfvars.json` with your real local values, including `cloudflare_account_id` and `cloudflare_zone_id`.

1. If your Fly account can access more than one organization, set `fly_org_slug` in `infra/opentofu/stack.auto.tfvars.json`.

1. Make sure your required secrets are available either as direct environment variables or via Bitwarden Secrets Manager.

1. Enable the repo-managed Git hooks:

   ```sh
   git config core.hooksPath .githooks
   ```

1. Run `just up`.

Useful follow-up commands:

- `just plan`
- `just deploy`
- `just gc`
- `just status`
- `just down`

This repo ships a repo-managed pre-commit hook under `.githooks/pre-commit` for `fmt`, `lint`, and
`nix flake check --no-build`. Clones must opt in with `git config core.hooksPath .githooks`. One
small GitHub Actions job independently evaluates every flake system and builds the Linux treefmt
check; it does not build or deploy the infrastructure.

## Secret Model

Tracked in Git:

- placeholder infra config and code
- the required secret names and deploy contract

Never tracked:

- OpenTofu state under `.state/`
- `infra/opentofu/stack.auto.tfvars.json`
- real secret values

The tracked example file contains placeholders only. Real environment identifiers stay in the ignored local tfvars file.

The environment contract is intentionally small and explicit:

- `CLOUDFLARE_API_TOKEN`
- `FLY_API_TOKEN`
- `NIKS3_API_TOKEN`
- `NIKS3_DB`
- `NIKS3_S3_ACCESS_KEY`
- `NIKS3_S3_SECRET_KEY`
- `NIKS3_SIGNING_KEY`

Value sources:

- `CLOUDFLARE_API_TOKEN`: Cloudflare API token with the permissions needed for the OpenTofu-managed R2 and custom-domain resources
- `FLY_API_TOKEN`: Fly API token that can create, deploy, and destroy the app
- `NIKS3_API_TOKEN`: random bearer token used by `niks3`
- `NIKS3_DB`: Neon PostgreSQL connection string
- `NIKS3_S3_ACCESS_KEY`: Cloudflare R2 S3 access key ID
- `NIKS3_S3_SECRET_KEY`: Cloudflare R2 S3 secret access key
- `NIKS3_SIGNING_KEY`: private Nix cache signing key, for example the full output of `nix key generate-secret --key-name cache.secbear.dev-1`

OpenTofu state is intended to stay free of runtime secrets. Neon is provisioned manually, and the R2 S3 credentials are created manually. The signing key is base64-encoded during deploy and Fly writes it into the guest as a file via `[[files]]`.

## Secret Injection

The repo stays environment-variable first:

- if the required env vars already exist, commands use them directly
- otherwise, if `BWS_ACCESS_TOKEN` and `BWS_PROJECT_ID` are set and `bws` is on `PATH`, `plan`, `deploy`, `up`, `gc`, and `down` transparently re-exec through Bitwarden Secrets Manager

This flake does not package `bws`. The command only needs it to already be on your system `PATH`.

That means you can still use any injector you want:

- manual shell exports
- `direnv`
- Bitwarden Secrets Manager via `bws run`
- another secret manager

The recommended local flow is:

```sh
security add-generic-password -U -a "$USER" -s "niks3-cache-bws-access-token" -w '...'
```

Then keep the bootstrap out of Git with `.envrc.local`:

```sh
export BWS_ACCESS_TOKEN="$(security find-generic-password -a "$USER" -s "niks3-cache-bws-access-token" -w)"
export BWS_PROJECT_ID="replace-with-your-bitwarden-project-id"
```

With the tracked `.envrc` already loading `.envrc.local`, `direnv allow` is enough to make plain commands work:

```sh
just plan
just up
```

## Garbage Collection

Garbage collection should operate on uploads tracked through `niks3`, not direct bucket writes.

Use:

```sh
just gc
```

By default, the wrapper preserves completed closures for 100 years (effectively indefinitely) and
only removes abandoned upload records:

- `--older-than 876000h` (100 years)
- `--failed-uploads-older-than 6h`

Override them when needed:

```sh
nix run .#gc -- --older-than 720h --failed-uploads-older-than 12h
```

This repo currently exposes GC as an on-demand command. It is not scheduled yet. Do not introduce
age-based completed-closure deletion until the server supports and uses explicit release-root pins.

## CI Uploads

There are two upload surfaces:

- `.github/actions/niks3-push/action.yml` pushes already-realized installables from the caller's
  current runner. Prefer this as the final step of a trusted main CI job: it publishes the exact
  store that passed the gates and performs no duplicate build.
- `.github/workflows/niks3-push.yml` is a convenient reusable workflow for callers that do not
  already have a Nix build runner. It restores from the public cache, builds the requested roots on
  its own runner, then pushes the closure delta.

Both use GitHub Actions OIDC for authentication — no static secret is needed in calling workflows.
They request an OIDC token with the niks3 write-plane URL as the audience. The server validates the
token against the subject patterns configured in `oidc_github_subject_patterns`.

The workflow intentionally makes the write-plane URL, public read URL, and signing key explicit
inputs, so callers do not accidentally target this repo's live infrastructure by default. It reads
from that cache before building, then uploads only the missing closure delta. The default CLI ref is
an immutable upstream commit matching the `niks3` version this repo currently tracks.

`niks3 push` recursively discovers each requested installable's full Nix closure, so callers should
list only their expensive roots (for example the dev shell, dependency-only derivations, and final
container). Store paths, NARs, narinfos, build logs, and realisations in those closures are uploaded
transactionally; listing every transitive dependency is unnecessary.

Run this job only after all release gates pass on a trusted branch. Pull requests should consume the
public cache read-only and must never receive cache-write authority.

> **Note:** `id-token: write` permission is required, which means fork pull requests cannot push to the cache. This is intentional.

Same-run publisher example:

```yaml
permissions:
  contents: read
  id-token: write

steps:
  - uses: SecBear/nix-cache/.github/actions/niks3-push@<full-commit-sha>
    with:
      server-url: https://secbear-cache-niks3.fly.dev
      installables: |
        .#yourAlreadyBuiltPackage
```

The publishing job must not run pull-request code. Use a distinct main-only job or reusable-workflow
caller rather than granting `id-token: write` to a PR job and relying on a conditional upload step.

Reusable-workflow example:

Minimal caller example from this repo:

```yaml
jobs:
  cache:
    uses: ./.github/workflows/niks3-push.yml
    with:
      server-url: https://secbear-cache-niks3.fly.dev
      substituter-url: https://cache.secbear.dev
      substituter-public-key: cache.secbear.dev-1:Pbeqskasb4M7FrHn+/kfnv1PCSvF0cJhl1snZ13Jn20=
      installables: |
        .#yourPackage
        .#yourOtherPackage
```

Example from another repository:

```yaml
jobs:
  cache:
    uses: SecBear/nix-cache/.github/workflows/niks3-push.yml@<full-commit-sha>
    with:
      server-url: https://secbear-cache-niks3.fly.dev
      substituter-url: https://cache.secbear.dev
      substituter-public-key: cache.secbear.dev-1:Pbeqskasb4M7FrHn+/kfnv1PCSvF0cJhl1snZ13Jn20=
      installables: |
        .#yourPackage
```

## Operational Notes

- The public cache URL is the R2 custom domain, not the Fly app URL.
- The write/admin endpoint is `https://<fly_app_name>.fly.dev`.
- `niks3` read proxy stays disabled by default to keep Fly cost low.
- The Neon project and R2 S3 API credentials are managed outside OpenTofu by design.
- First app creation on Fly requires billing/payment information on the account.
- The repo expects provider/admin and runtime secrets to come from the environment.
- The repo uses OpenTofu-compatible HCL. Plain Terraform users can adapt it, but the command surface is built around `tofu`.
- `niks3` v1.4.0 is pinned by both source revision and multi-architecture image digest. Upgrade to
  v1.8.0 before the paid release, but snapshot Neon and verify its database migration plus upload,
  read, signing, retry, and GC behavior before deploying it.
- OIDC subjects are cache-administrator authority because accepted uploads are signed. The deployed
  policy must be the exact trusted Attune main ref; owner-wide or repository-wide wildcards are not
  acceptable. The tracked example encodes that fail-closed shape.
- Keep an offline backup of the signing key. R2 data is reproducible; signing-key compromise requires
  key rotation, cache purge, and consumer key replacement.

## Current Limits

- Fly is managed with `fly.toml` and `flyctl`, not Terraform, because Fly's Terraform provider is not a good primary path as of March 28, 2026.
