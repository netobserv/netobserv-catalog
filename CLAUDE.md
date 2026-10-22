# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

No application code: it builds the OLM File-Based Catalog (FBC) fragments that ship the OpenShift
Network Observability Operator. Everything is YAML templates, generated catalogs, Konflux/Tekton
pipeline definitions and two bash scripts. `Konflux.md` holds the full release process; `README.md`
the short version.

## Commands

```bash
make help                 # all targets
make prereqs              # installs opm v1.51.0 and yq v4.35.2 (go install)
make generate             # regenerate all catalogs from templates/ (reuses already-rendered bundles)
make regenerate           # same, but renders every bundle again (CACHE=/dev/null) — needed after an opm bump
make gen-ystream          # only y-stream (SKIP=released.yaml,z-stream.yaml)
make gen-zstream          # only z-stream
make check-render         # offline self-check of render.sh: reproduces released.yaml byte-for-byte
make build-image push-image deploy   # build a catalog image and apply catalog-source.yaml on a cluster
make deploy-ystream / deploy-zstream # point a CatalogSource at the Konflux-built image
```

Generation pulls bundle images, so it needs `registry.redhat.io` credentials:
`REGISTRY_AUTH_FILE=/path/to/auth.json make gen-ystream`.

`render.sh` does the rendering (`opm alpha render-template basic` on the template stripped of its
bundles, then one `opm render` per bundle, bundles emitted sorted by name as opm does). Bundle blobs
whose image is digest-pinned are copied from the catalog already in `auto-generated/` instead of being
pulled again, so a regeneration pulls only the `:latest` stream bundle. Output is byte-identical to a
full render; `make check-render` asserts that. Reuse assumes opm renders a bundle identically across
runs, which a version bump may break — hence `make regenerate` (`CACHE=/dev/null`, honoured by any
`gen-*` target too). An output file that doesn't exist yet is also a full render.

There is no test suite and no linter. The check for a catalog change is building it:
`make build-image BUILD_STREAM=y-stream` (uses `upstream.Dockerfile`, public opm, no brew access needed).

Never hand-edit `auto-generated/` — edit `templates/` and regenerate.

## Architecture

**Three templates, three streams** (`templates/*.yaml`, `olm.template.basic` format):

- `released.yaml` — what is currently GA. All bundles pinned by digest on `registry.redhat.io`.
- `y-stream.yaml` — next minor/major. Last entry points at `...operator-bundle-ystream:latest` on quay.
- `z-stream.yaml` — next patch. Last entry points at `...operator-bundle-zstream:latest` on quay.

Each template is the *whole* upgrade graph (FBC is not additive — a released catalog must contain
every past version), so y/z-stream are `released.yaml` plus one appended `olm.channel` entry and one
appended `olm.bundle`.

Each `templates/<stream>.Dockerfile-args` carries just `BUILDVERSION=<x.y.z>`; Konflux passes it to
the build and the release script reads it. `next-release.Dockerfile-args` is the version of the
*released* template.

**Two generated flavours** per template, both produced by `make generate`:

- `auto-generated/catalog/` — rendered with `--migrate-level=bundle-object-to-csv-metadata`, used by
  OCP ≥ 4.17 and the y/z-stream pipelines.
- `auto-generated/legacy-catalog/` — rendered without migration, used by the OCP 4.12–4.16 pipelines.

`make generate` also rewrites the quay y/z-stream bundle repo back to
`registry.redhat.io/.../network-observability-operator-bundle` in the two `released.yaml` outputs,
because by then the bundle is public.

**Pipelines** (`.tekton/`): one application/component per OpenShift version (`catalog-4-12` …
`catalog-5-1`) plus `catalog-ystream` / `catalog-zstream`, each with a `-push` and `-pull-request`
PipelineRun referencing the shared `build-fbc-pipeline` in `pipeline-ref.yaml`. The OpenShift version
a fragment targets is set by `opm-image` (the brew/registry opm base image), not by the catalog
content. Versioned pipelines build `released.yaml` (legacy flavour for ≤4.16); stream pipelines build
`y-stream.yaml` / `z-stream.yaml`. `images-mirror-set.yaml` is a sample `ImageDigestMirrorSet` for
testing pre-release images; `make final-*` flips it between y and z.

## Release flow

1. Bundle built in Konflux → `make gen-ystream` (or `gen-zstream`) → commit → Konflux builds
   `catalog-ystream:latest` (release candidate).
2. Accepted: `BUNDLE_SHA=<sha> make final-ystream` (or `final-zstream`). Copies the stream template
   over `released.yaml`, pins the bundle digest, copies the Dockerfile-args to `next-release`, and
   regenerates `released` only.
3. `./releases/generate.sh -a <konflux-user> -s -o [-c cves.csv]` writes `releases/<version>/{netobserv,fbc}.yaml`
   Konflux `Release` objects: version comes from `next-release.Dockerfile-args`, the FBC list comes
   from the `.tekton/catalog-*-push.yaml` filenames, and `-s` fetches+validates the latest snapshots
   from the cluster (patch `0` ⇒ ystream, otherwise zstream). Apply `netobserv.yaml` first, then
   `fbc.yaml`; commit them once successful.
4. `make prepare-next [NEXT_Y=3.0.0]` → `prepare-next.sh` rebuilds both stream templates from the new
   `released.yaml`, bumps versions, wires the `replaces` edges and re-points the last bundle at the
   quay `:latest` tags. It refuses to run if `released.yaml` isn't the version `next-release.Dockerfile-args`
   claims. Then `make generate` once the bundle on-push jobs have succeeded.

Adding support for a new OpenShift version means adding a `catalog-<x>-<y>-{push,pull-request}.yaml`
pair in `.tekton/` (copy the newest, change the labels, `output-image` and `opm-image`) and creating
the matching application/component plus `ReleasePlanAdmission` in Konflux; `releases/generate.sh`
picks it up from the filename automatically.

## Conventions

- `make generate` is macOS-aware (`gsed` / BSD `sed`); keep new sed usage going through `SED_INPLACE`
  in the Makefile or `$SED` in the scripts.
- Bundle entries in templates carry a `# <version>` trailing comment — keep it, `prepare-next.sh`
  writes it and humans read the file by it.
- Operator package name is `netobserv-operator`; CSV/channel entry names are `network-observability-operator.v<version>`.
