SHELL := /bin/bash

IOS_PROJECT := CatVox.xcodeproj
IOS_SCHEME := CatVox
IOS_CONFIGURATION := Debug
IOS_BUILD_DESTINATION := generic/platform=iOS Simulator
IOS_TEST_DESTINATION := platform=iOS Simulator,name=iPhone 16,OS=latest

GCP_PROJECT_ID ?= kathelix-catvox-prod
FIREBASE_PROJECT ?= $(GCP_PROJECT_ID)
CATVOX_PROJECT_ID ?= $(GCP_PROJECT_ID)

.PHONY: help doctor \
	ios-generate ios-build ios-build-only ios-test ios-test-only ios-ci ios-device-launch ios-device-console app-deploy \
	functions-install functions-build functions-test functions-deploy functions-integration functions-ci \
	backend-build backend-deploy backend-integration \
	terraform-fmt-check terraform-init terraform-validate terraform-plan terraform-ci-plan terraform-apply terraform-ci-apply \
	bootstrap-remote-state bootstrap-wif

help:
	@printf '%s\n' \
		'CatVox local automation targets:' \
		'' \
		'  make doctor                 Check core local CLI prerequisites' \
		'' \
		'  make ios-build              Generate project and build simulator app' \
		'  make ios-test               Generate project and run iOS unit tests' \
		'  make ios-ci                 Generate, build, and test like CI' \
		'  make ios-device-launch      Build, install, and launch on DEVICE_ID or default iPhone' \
		'  make ios-device-console     Build, install, and launch with devicectl console' \
		'' \
		'  make functions-install      Install Firebase Functions dependencies' \
		'  make functions-build        Build Firebase Functions' \
		'  make functions-test         Build and run backend unit tests' \
		'  make functions-deploy       Build and deploy Cloud Functions' \
		'  make functions-integration  Run backend integration tests against Dev' \
		'' \
		'  make terraform-plan         fmt-check, init, validate, and plan Terraform' \
		'  make terraform-apply        Plan, then interactively apply; requires CONFIRM=apply' \
		'  make terraform-ci-apply     CI-only auto-approved Terraform apply' \
		'' \
		'  make bootstrap-remote-state Run Terraform state bucket bootstrap script' \
		'  make bootstrap-wif          Run GitHub Actions WIF bootstrap script' \
		'' \
		'Environment overrides:' \
		'  GCP_PROJECT_ID=... FIREBASE_PROJECT=... CATVOX_PROJECT_ID=...' \
		'  CATVOX_APP_CHECK_DEBUG_TOKEN=... make functions-integration' \
		'  IOS_TEST_DESTINATION="platform=iOS Simulator,name=iPhone 16,OS=latest"' \
		'  DEVICE_ID=... make ios-device-launch'

doctor:
	@missing=0; \
	for tool in make xcodegen xcodebuild xcrun npm firebase terraform gcloud; do \
		if command -v "$$tool" >/dev/null 2>&1; then \
			printf 'ok: %s -> %s\n' "$$tool" "$$(command -v "$$tool")"; \
		else \
			printf 'missing: %s\n' "$$tool" >&2; \
			missing=1; \
		fi; \
	done; \
	if command -v node >/dev/null 2>&1; then \
		node_version="$$(node --version)"; \
		printf 'ok: node -> %s (%s)\n' "$$(command -v node)" "$$node_version"; \
		if [[ "$$node_version" != v22.* ]]; then \
			printf 'warn: Firebase Functions runtime is Node.js 22; local Node is %s\n' "$$node_version" >&2; \
		fi; \
	else \
		printf 'missing: node\n' >&2; \
		missing=1; \
	fi; \
	if ! command -v xcpretty >/dev/null 2>&1; then \
		printf 'warn: xcpretty is not installed; iOS targets will use raw xcodebuild output locally\n' >&2; \
	fi; \
	exit "$$missing"

ios-generate:
	@xcodegen generate

ios-build: ios-generate ios-build-only

ios-build-only:
	@set -o pipefail; \
	if command -v xcpretty >/dev/null 2>&1; then \
		xcodebuild build \
			-project "$(IOS_PROJECT)" \
			-scheme "$(IOS_SCHEME)" \
			-destination "$(IOS_BUILD_DESTINATION)" \
			-configuration "$(IOS_CONFIGURATION)" \
			CODE_SIGNING_ALLOWED=NO \
		| xcpretty; \
	else \
		xcodebuild build \
			-project "$(IOS_PROJECT)" \
			-scheme "$(IOS_SCHEME)" \
			-destination "$(IOS_BUILD_DESTINATION)" \
			-configuration "$(IOS_CONFIGURATION)" \
			CODE_SIGNING_ALLOWED=NO; \
	fi

ios-test: ios-generate ios-test-only

ios-test-only:
	@destination="$(IOS_TEST_DESTINATION)"; \
	if [[ "$${CI:-}" != "true" && "$$destination" == "platform=iOS Simulator,name=iPhone 16,OS=latest" ]] && \
		! xcrun simctl list devices available | grep -qE '^[[:space:]]+iPhone 16[[:space:](]'; then \
		fallback="$$(xcrun simctl list devices available | awk -F ' \\(' '/^[[:space:]]+iPhone / { gsub(/^[[:space:]]+/, "", $$1); print $$1; exit }')"; \
		if [[ -n "$$fallback" ]]; then \
			printf 'iPhone 16 simulator not available locally; using %s\n' "$$fallback"; \
			destination="platform=iOS Simulator,name=$$fallback,OS=latest"; \
		fi; \
	fi; \
	set -o pipefail; \
	if command -v xcpretty >/dev/null 2>&1; then \
		xcodebuild test \
			-project "$(IOS_PROJECT)" \
			-scheme "$(IOS_SCHEME)" \
			-destination "$$destination" \
			-configuration "$(IOS_CONFIGURATION)" \
			CODE_SIGNING_ALLOWED=NO \
		| xcpretty; \
	else \
		xcodebuild test \
			-project "$(IOS_PROJECT)" \
			-scheme "$(IOS_SCHEME)" \
			-destination "$$destination" \
			-configuration "$(IOS_CONFIGURATION)" \
			CODE_SIGNING_ALLOWED=NO; \
	fi

ios-ci: ios-generate ios-build-only ios-test-only

ios-device-launch:
	@./scripts/run-on-iphone.sh launch

ios-device-console:
	@./scripts/run-on-iphone.sh console

app-deploy: ios-device-launch

functions-install:
	@npm --prefix functions ci

functions-build:
	@npm --prefix functions run build

functions-test:
	@npm --prefix functions run test:unit

functions-deploy: functions-build
	@firebase deploy --only functions --project "$(FIREBASE_PROJECT)"

functions-integration:
	@CATVOX_PROJECT_ID="$(CATVOX_PROJECT_ID)" npm --prefix functions run test:integration

functions-ci: functions-install functions-test

backend-build: functions-build

backend-deploy: functions-deploy

backend-integration: functions-integration

terraform-fmt-check:
	@cd terraform && terraform fmt -check -recursive

terraform-init:
	@cd terraform && terraform init

terraform-validate:
	@cd terraform && terraform validate -no-color

terraform-plan:
	@cd terraform && TF_VAR_project_id="$(GCP_PROJECT_ID)" terraform fmt -check -recursive
	@cd terraform && TF_VAR_project_id="$(GCP_PROJECT_ID)" terraform init
	@cd terraform && TF_VAR_project_id="$(GCP_PROJECT_ID)" terraform validate -no-color
	@cd terraform && TF_VAR_project_id="$(GCP_PROJECT_ID)" terraform plan -no-color

terraform-ci-plan:
	@cd terraform && terraform plan -no-color

terraform-apply:
	@if [[ "$(CONFIRM)" != "apply" ]]; then \
		printf 'Refusing to run Terraform apply. Re-run as: make terraform-apply CONFIRM=apply\n' >&2; \
		exit 1; \
	fi
	@cd terraform && TF_VAR_project_id="$(GCP_PROJECT_ID)" terraform init
	@cd terraform && TF_VAR_project_id="$(GCP_PROJECT_ID)" terraform plan -no-color
	@cd terraform && TF_VAR_project_id="$(GCP_PROJECT_ID)" terraform apply -no-color

terraform-ci-apply:
	@cd terraform && terraform apply -auto-approve -no-color

bootstrap-remote-state:
	@PROJECT_ID="$(GCP_PROJECT_ID)" ./terraform/bootstrap_remote_state.sh

bootstrap-wif:
	@PROJECT_ID="$(GCP_PROJECT_ID)" ./terraform/bootstrap_wif.sh
