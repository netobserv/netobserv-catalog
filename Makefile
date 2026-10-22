
IMAGE ?= quay.io/$(USER)/network-observability-operator-catalog:latest
BUILD_STREAM ?= y-stream
OCI_BIN_PATH := $(shell which docker 2>/dev/null || which podman)
OCI_BIN ?= $(shell basename ${OCI_BIN_PATH})
ifneq (,$(shell which gsed 2>/dev/null))
  SED_INPLACE := gsed -i
else ifeq ($(shell uname -s),Darwin)
  SED_INPLACE := sed -i ''
else
  SED_INPLACE := sed -i
endif

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Tools

.PHONY: prereqs
prereqs: ## Prerequisites: installs opm and yq
	go install github.com/operator-framework/operator-registry/cmd/opm@v1.51.0
	go install github.com/mikefarah/yq/v4@v4.35.2

##@ Updating the catalogs

MIGRATE := --migrate-level=bundle-object-to-csv-metadata
# Where render.sh reads the already-rendered bundle blobs from; /dev/null renders them all again
CACHE ?=

.PHONY: generate
generate: prereqs ## Regenerate all catalogs, reusing the bundles already rendered by digest
	@for i in $(shell ls ./templates/ | grep yaml); do \
		if [[ "$(SKIP)" == *"$$i"* ]]; then \
		  echo "Skipping $$i" ; \
		else \
			echo "Generating $$i..." ; \
			CACHE=$(CACHE) ./render.sh ./templates/$$i ./auto-generated/catalog/$$i $(MIGRATE) || exit 1; \
			echo "Generating legacy $$i..." ; \
			CACHE=$(CACHE) ./render.sh ./templates/$$i ./auto-generated/legacy-catalog/$$i || exit 1; \
			if [[ "$$i" == "released.yaml" ]]; then \
				echo "Sedding $$i" ; \
				$(SED_INPLACE) -e 's#quay.io/redhat-user-workloads/ocp-network-observab-tenant/network-observability-operator-bundle-zstream#registry.redhat.io/network-observability/network-observability-operator-bundle#g' ./auto-generated/catalog/released.yaml ; \
				$(SED_INPLACE) -e 's#quay.io/redhat-user-workloads/ocp-network-observab-tenant/network-observability-operator-bundle-zstream#registry.redhat.io/network-observability/network-observability-operator-bundle#g' ./auto-generated/legacy-catalog/released.yaml ; \
				$(SED_INPLACE) -e 's#quay.io/redhat-user-workloads/ocp-network-observab-tenant/network-observability-operator-bundle-ystream#registry.redhat.io/network-observability/network-observability-operator-bundle#g' ./auto-generated/catalog/released.yaml ; \
				$(SED_INPLACE) -e 's#quay.io/redhat-user-workloads/ocp-network-observab-tenant/network-observability-operator-bundle-ystream#registry.redhat.io/network-observability/network-observability-operator-bundle#g' ./auto-generated/legacy-catalog/released.yaml ; \
			fi \
		fi \
	done

.PHONY: regenerate
regenerate: CACHE=/dev/null
regenerate: generate ## Regenerate all catalogs from scratch, re-rendering every bundle

.PHONY: gen-ystream
gen-ystream: SKIP=released.yaml,z-stream.yaml
gen-ystream: generate ## Generate only ystream

.PHONY: gen-zstream
gen-zstream: SKIP=released.yaml,y-stream.yaml
gen-zstream: generate ## Generate only zstream

.PHONY: final-ystream
final-ystream: ## Accept current ystream as final release
ifeq (,${BUNDLE_SHA})
	@echo "You must provide the final bundle SHA in BUNDLE_SHA. Check last snapshot in https://konflux-ui.apps.stone-prd-rh01.pg1f.p1.openshiftapps.com/ns/ocp-network-observab-tenant/applications/netobserv-ystream/releases."
else
	cp ./templates/y-stream.Dockerfile-args ./templates/next-release.Dockerfile-args
	cp ./templates/y-stream.yaml ./templates/released.yaml
	$(SED_INPLACE) 's/bundle-ystream:latest/bundle-ystream@sha256:$(BUNDLE_SHA)/' ./templates/released.yaml
	$(SED_INPLACE) 's/zstream/ystream/' .tekton/images-mirror-set.yaml
	SKIP="y-stream.yaml,z-stream.yaml" $(MAKE) generate
endif

.PHONY: final-zstream
final-zstream: ## Accept current zstream as final release
ifeq (,${BUNDLE_SHA})
	@echo "You must provide the final bundle SHA in BUNDLE_SHA. Check last snapshot in https://konflux-ui.apps.stone-prd-rh01.pg1f.p1.openshiftapps.com/ns/ocp-network-observab-tenant/applications/netobserv-zstream/releases."
else
	cp ./templates/z-stream.Dockerfile-args ./templates/next-release.Dockerfile-args
	cp ./templates/z-stream.yaml ./templates/released.yaml
	$(SED_INPLACE) 's/bundle-zstream:latest/bundle-zstream@sha256:$(BUNDLE_SHA)/' ./templates/released.yaml
	$(SED_INPLACE) 's/ystream/zstream/' .tekton/images-mirror-set.yaml
	SKIP="y-stream.yaml,z-stream.yaml" $(MAKE) generate
endif

.PHONY: prepare-next
prepare-next: ## Prepare the next y-stream and z-stream versions, after a release (set NEXT_Y for a major bump)
	./prepare-next.sh $(NEXT_Y)

##@ Testing

.PHONY: check-render
check-render: ## Check that reusing rendered bundles reproduces the released catalogs (offline)
	@status=0 ; \
	for d in catalog legacy-catalog; do \
		out=$$(mktemp) ; \
		[ "$$d" = catalog ] && flags="$(MIGRATE)" || flags="" ; \
		CACHE=./auto-generated/$$d/released.yaml ./render.sh ./templates/released.yaml $$out $$flags ; \
		diff ./auto-generated/$$d/released.yaml $$out && echo "$$d/released.yaml: OK" || status=1 ; \
		rm -f $$out ; \
	done ; \
	exit $$status

.PHONY: build-image
build-image: ## Build the catalog image
	$(OCI_BIN) build --build-arg INDEX_FILE="./auto-generated/catalog/$(BUILD_STREAM).yaml" -t $(IMAGE) -f upstream.Dockerfile .

.PHONY: push-image
push-image: ## Push the catalog image to a remote registry
	$(OCI_BIN) push ${IMAGE}

.PHONY: deploy
deploy: ## Deploy the catalog image on a cluster
	yq '.spec.image="$(IMAGE)"' ./catalog-source.yaml | kubectl apply -f -

.PHONY: undeploy
undeploy: ## Undeploy the catalog image from a cluster
	kubectl delete -f ./catalog-source.yaml

deploy-zstream: IMAGE=quay.io/redhat-user-workloads/ocp-network-observab-tenant/catalog-zstream:latest
deploy-zstream: deploy
	@echo "Before installing the operator, remember to install an ImageDigestMirrorSet too"

deploy-ystream: IMAGE=quay.io/redhat-user-workloads/ocp-network-observab-tenant/catalog-ystream:latest
deploy-ystream: deploy
	@echo "Before installing the operator, remember to install an ImageDigestMirrorSet too"
