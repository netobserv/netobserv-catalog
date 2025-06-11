# Netobserv Catalog

dummy change

This repository build the Netobserv OLM catalog used to release new version of Openshift Network Observability Operator.

Some of the comands below require an access to `registry.redhat.io`. Make sure you have it (e.g. by running `export REGISTRY_AUTH_FILE=/path/to/secret.json` first).

To generate all catalogs from template:
```bash
make generate
```

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
