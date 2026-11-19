BUILD := local-data/build
DEMO_CORE := ios/EtoTy/PilotProfile.swift ios/EtoTy/VisitPDF.swift
PERSONAL_SOURCES := $(filter-out ios/EtoTy/EtoTyApp.swift,$(wildcard ios/EtoTy/*.swift))
PERSONAL_TESTS := $(filter-out tests/PilotChecks.swift,$(wildcard tests/*Checks.swift))
SWIFTC := swiftc -module-cache-path "$(BUILD)/modules"

.PHONY: check ios-build ios-smoke sample-brief db-check
check: $(BUILD)/core-check $(BUILD)/personal-check
	python3 -B -m unittest discover -s tests -p test_ios_smoke_result.py
	plutil -lint ios/EtoTy.xcodeproj/project.pbxproj
	xmllint --noout ios/EtoTy.xcodeproj/xcshareddata/xcschemes/EtoTy.xcscheme
	$(SWIFTC) -parse-as-library -typecheck ios/EtoTy/*.swift
	"$(BUILD)/core-check"
	"$(BUILD)/personal-check"
	osascript -l JavaScript tests/run.js app/check-in.js

$(BUILD)/core-check: $(DEMO_CORE) tests/PilotChecks.swift Makefile
	mkdir -p "$(BUILD)/modules"
	$(SWIFTC) -parse-as-library $(DEMO_CORE) tests/PilotChecks.swift -o "$@"

$(BUILD)/personal-check: $(PERSONAL_SOURCES) $(PERSONAL_TESTS) Makefile
	mkdir -p "$(BUILD)/modules"
	$(SWIFTC) -parse-as-library $(PERSONAL_SOURCES) $(PERSONAL_TESTS) -o "$@"

sample-brief: $(BUILD)/core-check
	"$(BUILD)/core-check" --sample-pdf local-data/visit-example.pdf

ios-build:
	./setup-iphone.command --build

ios-smoke:
	./setup-iphone.command --smoke

db-check:
	sh tests/database.sh
