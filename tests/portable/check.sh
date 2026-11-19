#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
mkdir -p "local-data/build/modules"
swiftc -module-cache-path local-data/build/modules ios/EtoTy/PilotProfile.swift ios/EtoTy/CareDocument.swift \
	ios/EtoTy/CareRegionSuggestion.swift ios/EtoTy/CareMapCoverage.swift \
	ios/EtoTy/BriefDocumentSelection.swift tests/RegionSuggestionChecks.swift \
	tests/MapCoverageChecks.swift tests/VisitSourceChecks.swift tests/portable/main.swift \
	-o "local-data/build/evidence-check"
"local-data/build/evidence-check"
