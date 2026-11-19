BUILD := local-data/build
CORE := ios/EtoTy/PilotProfile.swift ios/EtoTy/VisitPDF.swift
SWIFTC := swiftc -module-cache-path "$(BUILD)/modules"

.PHONY: check ios-build sample-brief db-check
check: $(BUILD)/core-check
	plutil -lint ios/EtoTy.xcodeproj/project.pbxproj
	xmllint --noout ios/EtoTy.xcodeproj/xcshareddata/xcschemes/EtoTy.xcscheme
	$(SWIFTC) -parse-as-library -typecheck ios/EtoTy/*.swift
	"$(BUILD)/core-check"
	osascript -l JavaScript tests/run.js app/check-in.js

$(BUILD)/core-check: $(CORE) tests/PilotChecks.swift
	mkdir -p "$(BUILD)/modules"
	$(SWIFTC) -parse-as-library $(CORE) tests/PilotChecks.swift -o "$@"

sample-brief: $(BUILD)/core-check
	"$(BUILD)/core-check" --sample-pdf local-data/visit-example.pdf

ios-build:
	xcodebuild -project ios/EtoTy.xcodeproj -scheme EtoTy -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath "$(BUILD)/ios" CODE_SIGNING_ALLOWED=NO build

db-check:
	sh tests/database.sh
