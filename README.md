# NetObserv OLM catalog fragments

This repository builds the NetObserv OLM catalog fragments (FBC) used to release new version of OpenShift Network Observability Operator.

It's designed around 3 templates:
- z-stream, aiming to prepare for the next z-stream upgrade (ie. patch upgrade)
- y-stream, aiming to prepare for the next y-stream upgrade (ie. minor upgrade - can also be used for major)
- released, that represents the currently released, and is used to build the final release FBC

Y and Z stream templates use the latest bundle generated in from Tekton/Konflux.

From each template, catalog fragments are generated in `./auto-generated` directory.

The lifecycle process through Konflux is described in [Konflux.md](./Konflux.md).

## Generate

Commands below require an access to `registry.redhat.io`. Make sure you're logged in, or set `REGISTRY_AUTH_FILE=/path/to/secret.json`.

When a new bundle was built and pushed to quay, catalogs must be regenerated in order to include it.

To generate all catalogs from templates:

```bash
make generate
```

To generate from a specific template:

```bash
make gen-ystream
# or
make gen-zstream
```

Then commit and push the changes to the `main` branch. It will trigger Konflux jobs that build and push catalogs to quay (`catalog-ystream:latest` or `catalog-zstream:latest`). See [Konflux - Deploying](./Konflux.md#deploying) for how to consume them.

See also:

- [Creating release candidate](./Konflux.md#release-candidates)
- [Accepting final release](./Konflux.md#release)
- [Preparing for the next release](./Konflux.md#after-release)

## Testing

To build the catalog with released version:
```bash
podman build -t catalog .
```

To use upstream opm:
```bash
podman build -t catalog -f upstream.Dockerfile .
```

To use a different generated catalog:
```bash
podman build --build-arg INDEX_FILE=./auto-generated/<catalog-file>.yaml  -t catalog .
```

One-step, build and test on a cluster:
```bash
make build-image push-image deploy
```
