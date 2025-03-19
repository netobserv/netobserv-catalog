.PHONY: generate
generate:
	rm -f ./auto-generated/catalog/*
	rm -f ./auto-generated/legacy-catalog/*
	for i in $(shell ls ./templates/); do \
		opm alpha render-template basic --migrate-level=bundle-object-to-csv-metadata  -o yaml ./templates/$$i > ./auto-generated/catalog/$$i; \
		opm alpha render-template basic -o yaml ./templates/$$i > ./auto-generated/legacy-catalog/$$i; \
	done
