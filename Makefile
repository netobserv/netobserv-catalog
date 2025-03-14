.PHONY: generate
generate:
	rm -f ./auto-generated/*
	for i in $(shell ls ./templates/); do \
		opm alpha render-template basic -o yaml ./templates/$$i > ./auto-generated/$$i; \
	done
