# Building the CIA on a GitHub-hosted Mac (your own disc, private storage)

`.github/workflows/build-cia-macos.yml` builds `mkw-3ds.cia` on a GitHub-hosted
macOS runner from **your own** Mario Kart Wii (USA, `RMCE01`) disc image. This
repository is public, so the disc is fetched from storage only you can read, and
nothing made from it is ever published.

The disc image must be your own dump of your own copy, and the storage location
must be private. Built CIAs contain Nintendo's game files: do not share them
(see `NOTICE`).

## One-time setup

1. **Put the disc somewhere private** that serves it over HTTPS: a private
   bucket (Cloudflare R2, Backblaze B2, S3, Azure Blob, GCS) or your own server.
   GitHub release assets are limited to 2 GiB per file, so a full disc does not
   fit there. Only an unmodified USA `.iso` or `.wbfs` works (not NKit, RVZ,
   other regions or patched dumps).
2. **Settings → Environments → New environment: `disc-build`.** Tick *Required
   reviewers* and add yourself. Optionally limit it to the `main` branch.
3. **Add secrets to that environment** (repository secrets of the same names
   also work; the environment's win):

| Name | Kind | What |
|---|---|---|
| `DISC_URL` | secret, required | HTTPS location of the image |
| `DISC_AUTH_HEADER` | secret, optional | one header line, e.g. `Authorization: Bearer …` (use an `Authorization` header: curl does not forward it when the host redirects) |
| `DISC_SHA256` | variable or secret, optional | expected SHA-256; checked before the builder runs |
| `OUTPUT_S3_ENDPOINT`, `OUTPUT_S3_BUCKET`, `OUTPUT_S3_ACCESS_KEY_ID`, `OUTPUT_S3_SECRET_ACCESS_KEY` | secrets, only for *upload privately* | S3-compatible target, `https://` endpoint |
| `OUTPUT_S3_REGION`, `OUTPUT_S3_PREFIX` | secrets, optional | default `auto` and `mkw-ci/<run id>/` |

A GitHub secret holds at most 48 KB, so the disc itself can never be a secret:
the secrets only say *how to fetch it*.

### What to put in `DISC_URL` (examples, not tested against each provider)

- **S3 / R2 / B2 presigned URL:** `https://…?X-Amz-Signature=…` (no header). It
  expires (up to 7 days), so you re-sign it before a run.
- **Azure Blob SAS URL / GCS signed URL:** the full signed URL; SAS can be
  long-lived.
- **Your own server:** `https://files.example.org/mkw.iso` with
  `DISC_AUTH_HEADER` = `Authorization: Bearer <token>` or
  `Authorization: Basic <base64>`. This does not expire.
- For an `https://api.github.com/…/releases/assets/<id>` URL the script adds
  `Accept: application/octet-stream` itself.

## Running it

Actions → *Build CIA (macOS, own disc)* → Run workflow. You approve the run in
the `disc-build` environment first. Inputs: the runner (`macos-15`, Apple
Silicon, 7 GB RAM, or `macos-15-intel`, 14 GB RAM), *smoke_test*,
*upload_private*, and *verbose_log* (prints the builder's full output to the
**public** log: debugging only).

The job: checks out the repo → Python 3.13, Node 24 → Rosetta (Apple Silicon:
the pinned `bannertool` is an x86_64 binary) → frees disk → installs devkitPro
`3ds-dev` (pinned installer, SHA-256 checked) → `tools/bootstrap.py` → venv →
fetches the disc to `$RUNNER_TEMP` → checks it (size, game ID, NKit, SHA-256,
then the builder's own disc and game-code checks) → builds → checks the CIA →
optional smoke test → optional private upload → always removes the disc and
everything built from it.

Without *upload_private* nothing leaves the runner: you only get pass or fail.
With it, the CIA and `sd-card/3ds` (as a tar) go to your private bucket, never
to GitHub. Files over 5 GiB are skipped (single PUT limit).

## What is public and what is not

- **Only `workflow_dispatch`.** No `push`, `pull_request` or
  `pull_request_target`, so a fork's PR can never reach the secrets. The
  environment's reviewer gate covers the rest.
- **Secrets go to the fetch step only**, as `env:`; derived values (the query
  part of a signed URL, the token in a header) are masked; the URL and header
  are never printed and curl's own error text is dropped (it names hosts).
- **No artifacts, no `actions/cache` for disc data, no releases, comments or
  step summaries.** Only pip and npm packages are cached.
- **The log is filtered.** The builder prints the name and size of every disc
  file it reads and a receipt with hashes of the CIA. `tools/ci/public_log_filter.py`
  keeps all of that in `build-cia-log.txt` on the runner (never uploaded) and
  shows only step progress. A failure shows the last line with paths and file
  names removed.
- Permissions are `contents: read`, checkout does not persist credentials, and
  the workflow uses only `actions/*` actions.

## The smoke test: what it does and does not prove

With *smoke_test* the builder also makes a `.cci`. The job then installs
Azahar (release 2126.1 by default, `AZAHAR_TAG`), selects the **software
renderer**, runs the image for about 45 s, captures the screen once and checks
numerically that something was drawn and that it differs from the empty screen.
The frame is deleted; only the numbers are logged.

- It runs on a VM without a GPU, so it is not a playability or performance test.
- A pass ("runtime verified") means a non-blank frame appeared. It cannot tell a
  title screen from an emulator error window.
- If Azahar cannot start, the screen cannot be captured, or the frame is blank,
  the step prints **"runtime NOT verified"** and fails without failing the job
  (`continue-on-error`). The always-run structural check (`tools/ci/check_cia.py`:
  size, CIA header, this port's title ID, receipt) says the file is well formed,
  not that the game runs.

## Costs, limits, caveats

- Standard runners are free and unlimited on public repositories. The documented
  specs are `macos-15`: 3 vCPU (M1), 7 GB RAM, 14 GB SSD; `macos-15-intel`: 4
  vCPU, 14 GB RAM, 14 GB SSD. The builder wants about 15 GB (plus the ~4.7 GB
  disc image and devkitPro), so on paper **disk does not fit and is the main
  risk**. The documented figure may be far below what the writable volume really
  has, and only a measurement tells: run *Probe macOS runner* once. Note that on
  macOS `df -h /` shows the read-only system volume; the probe and the cleanup
  script read the data volume instead.
- The build stops in the first minutes, before downloading the disc, if fewer
  than `min_free_gb` GiB (default 22) are free after cleanup. Lower it (or use
  0) only if the probe shows the build really fits.
- If neither runner has the room even after cleanup, the options are: a larger
  runner (only on GitHub Team/Enterprise plans, and the docs list the same 14 GB
  for them too, so check), or a self-hosted Mac (GitHub advises against
  self-hosted runners on public repositories; this workflow only runs on manual,
  approved dispatch, but fork-PR workflows could still reach such a runner
  unless you require approval for them). Tune `tools/ci/free_disk_macos.sh` with
  the probe numbers, then delete the probe workflow.
- The job limit is 6 hours (the workflow asks for 330 minutes). The README's
  30–60 minutes is for a desktop Mac; a 3-vCPU runner will be slower.
- devkitPro asks that pacman not be used in CI (it points to its Docker images,
  which macOS runners cannot run). The workflow installs it once per manual run.
- Intel macOS runner images are being phased out; `macos-15` is the default.
