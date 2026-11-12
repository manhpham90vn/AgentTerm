# Shortcuts for the scripts in scripts/. `make` alone lists them.
# The version of both apps is the one line in VERSION.

VERSION := $(shell tr -d '[:space:]' < VERSION)
SIM ?=
# What the formatter and the linter look at.
SWIFT_PATHS := Package.swift Sources Tests iOS/AgentTerm iOS/AgentTermUITests

.DEFAULT_GOAL := help
.PHONY: help version bump build test test-ios test-all run run-ios pair-ios run-all bundle format lint check reset-permissions \
        release-check release-mac release-ios release store-metadata store-screenshots announce cask clean

help: ## List what can be made
	@echo "AgentTerm $(VERSION)"
	@awk 'BEGIN { FS = ":.*## " } /^[a-z-]+:.*## / { printf "  make %-14s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

version: ## Print the version
	@echo $(VERSION)

bump: ## Set the version: make bump V=0.3.0
	@test -n "$(V)" || { echo "usage: make bump V=0.3.0"; exit 2; }
	@echo "$(V)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' || { echo "bump: '$(V)' is not a version like 0.3.0"; exit 2; }
	@echo "$(V)" > VERSION
	@echo "VERSION is now $(V). Both apps take it from there."

build: ## Build everything (debug)
	swift build

test: ## Run the package tests
	swift test

format: ## Format the Swift code in place (swift-format, settings in .swift-format)
	swift format --in-place --recursive $(SWIFT_PATHS)

lint: ## Check formatting and style without changing anything; what CI runs
	swift format lint --strict --recursive $(SWIFT_PATHS)

check: lint build test ## Lint, build and test: what to run before a commit

test-ios: ## Run the iPhone UI test in a simulator: make test-ios SIM="iPhone Air"
	./scripts/test-ios.sh $(if $(SIM),"$(SIM)")

test-all: test test-ios ## Both of the above

run: ## Build and open the Mac app (AgentTerm Dev)
	./scripts/run-mac.sh

run-ios: ## Build and open the iPhone app in a simulator: make run-ios SIM="iPhone 17"
	./scripts/run-ios.sh $(if $(SIM),"$(SIM)")

pair-ios: ## Pair that simulator with the Mac app running here
	./scripts/pair-ios.sh $(if $(SIM),"$(SIM)")

run-all: ## Run the Mac app and the iPhone app and pair them: make run-all SIM="iPhone 17"
	./scripts/run-all.sh $(if $(SIM),"$(SIM)")

bundle: ## Only build the Mac app bundle in dist/
	./scripts/bundle-mac.sh

release-check: ## Show which signing secrets and tools are found
	./scripts/release.sh --check

release-mac: ## Build, sign and notarize the Mac disk image here
	./scripts/release.sh mac release

release-ios: ## Build the iPhone app here and upload it to TestFlight
	./scripts/release.sh ios beta

release: ## Release both apps from GitHub Actions: make release [V=0.3.0-beta.1]
	./scripts/check-version.sh $(or $(V),$(VERSION))
	@./scripts/check-release-notes.sh $(or $(V),$(VERSION))
	gh workflow run release.yml -f version=$(or $(V),$(VERSION))

store-metadata: ## Send the App Store listing (fastlane/metadata) to App Store Connect
	./scripts/release.sh ios metadata

store-screenshots: ## Send the iPhone screenshots (fastlane/screenshots) to App Store Connect
	./scripts/release.sh ios screenshots

announce: ## Announce a release on Discord: make announce [V=0.3.0-beta.3] (needs DISCORD_WEBHOOK_URL)
	./scripts/announce-discord.sh $(or $(V),$(VERSION))

cask: ## Point the Homebrew cask at a released version: make cask [V=0.3.0]
	./scripts/publish-homebrew.sh $(or $(V),$(VERSION))

reset-permissions: ## Take back the macOS permissions given to AgentTerm Dev, to try the prompts again
	./scripts/reset-macos-permissions.sh

clean: ## Remove build output
	rm -rf .build dist iOS/AgentTerm.xcodeproj iOS/Version.xcconfig
