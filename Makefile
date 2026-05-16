SHELL := /bin/bash

IOS_PROJECT := CatVox.xcodeproj
IOS_SCHEME := CatVox
IOS_UI_TEST_SCHEME := CatVoxUITests
IOS_CONFIGURATION := Debug
IOS_BUILD_DESTINATION := generic/platform=iOS Simulator
IOS_TEST_DESTINATION := platform=iOS Simulator,name=iPhone 16,OS=latest
IOS_UI_TEST_DESTINATION := $(IOS_TEST_DESTINATION)

CATVOX_ENV_CONFIG ?= config/environments/dev.xcconfig
catvox_xcconfig_value = $(strip $(shell scripts/lib/read-xcconfig-value.sh '$(CATVOX_ENV_CONFIG)' '$(1)' 2>/dev/null))

GCP_PROJECT_ID ?= $(or $(call catvox_xcconfig_value,GCP_PROJECT_ID),kathelix-catvox-dev)
FIREBASE_PROJECT ?= $(or $(call catvox_xcconfig_value,FIREBASE_PROJECT),$(GCP_PROJECT_ID))
CATVOX_PROJECT_ID ?= $(or $(call catvox_xcconfig_value,CATVOX_PROJECT_ID),$(GCP_PROJECT_ID))
CATVOX_ENVIRONMENT ?= $(or $(call catvox_xcconfig_value,CATVOX_ENVIRONMENT),dev)
CATVOX_FUNCTION_REGION ?= $(or $(call catvox_xcconfig_value,CATVOX_FUNCTION_REGION),us-central1)
CATVOX_BACKEND_SERVICE_ACCOUNT ?= $(or $(call catvox_xcconfig_value,CATVOX_BACKEND_SERVICE_ACCOUNT),catvox-backend-sa@$(FIREBASE_PROJECT).iam.gserviceaccount.com)
CATVOX_SIGNED_UPLOAD_URL_HOST ?= $(or $(call catvox_xcconfig_value,CATVOX_SIGNED_UPLOAD_URL_HOST),replace-with-dev-signed-upload-host)
CATVOX_ANALYSE_VIDEO_HOST ?= $(or $(call catvox_xcconfig_value,CATVOX_ANALYSE_VIDEO_HOST),replace-with-dev-analyse-video-host)
CATVOX_SIGNED_UPLOAD_URL_ENDPOINT ?= https://$(CATVOX_SIGNED_UPLOAD_URL_HOST)
CATVOX_ANALYSE_VIDEO_ENDPOINT ?= https://$(CATVOX_ANALYSE_VIDEO_HOST)
CATVOX_FIREBASE_APP_ID ?= $(or $(call catvox_xcconfig_value,CATVOX_FIREBASE_APP_ID),replace-with-dev-firebase-app-id)
CATVOX_FIREBASE_API_KEY ?= $(or $(call catvox_xcconfig_value,CATVOX_FIREBASE_API_KEY),replace-with-dev-firebase-api-key)
CATVOX_IOS_BUNDLE_ID ?= $(or $(call catvox_xcconfig_value,CATVOX_IOS_BUNDLE_ID),$(call catvox_xcconfig_value,CATVOX_PRODUCT_BUNDLE_IDENTIFIER),com.kathelix.catvox.dev)
CATVOX_INTEGRATION_MUTATIONS_ALLOWED ?= 1
CATVOX_INTEGRATION_SAFE_ENVIRONMENTS ?= $(or $(call catvox_xcconfig_value,CATVOX_INTEGRATION_SAFE_ENVIRONMENTS),dev)
CATVOX_TERRAFORM_ENV ?= $(CATVOX_ENVIRONMENT)
CATVOX_TF_BACKEND_CONFIG ?= terraform/backend/$(CATVOX_TERRAFORM_ENV).hcl
CATVOX_TF_VARS_FILE ?= terraform/env/$(CATVOX_TERRAFORM_ENV).tfvars
CATVOX_TF_STATE_BUCKET ?= catvox-tf-state-$(GCP_PROJECT_ID)
CATVOX_TF_STATE_PREFIX ?= catvox/state
CATVOX_TF_INIT_FLAGS ?= -reconfigure
CATVOX_TFVARS_PATH ?= $(CATVOX_TF_VARS_FILE)
CATVOX_FIREBASE_PLIST_OUTPUT ?= CatVox/Resources/Firebase/GoogleService-Info-$(CATVOX_ENVIRONMENT).plist

catvox_tf_backend_rel = $(patsubst terraform/%,%,$(CATVOX_TF_BACKEND_CONFIG))
catvox_tf_vars_rel = $(patsubst terraform/%,%,$(CATVOX_TF_VARS_FILE))
catvox_tf_backend_args = $(if $(wildcard $(CATVOX_TF_BACKEND_CONFIG)),-backend-config="$(catvox_tf_backend_rel)",-backend-config="bucket=$(CATVOX_TF_STATE_BUCKET)" -backend-config="prefix=$(CATVOX_TF_STATE_PREFIX)")
catvox_tf_var_file_arg = $(if $(wildcard $(CATVOX_TF_VARS_FILE)),-var-file="$(catvox_tf_vars_rel)",)

.PHONY: help doctor \
	ios-generate ios-build ios-build-only ios-test ios-test-only ios-ui-test ios-ui-test-only ios-ci ios-device-launch ios-device-console app-deploy \
	ios-validate-env-config \
	functions-install functions-build functions-test functions-deploy functions-integration functions-ci \
	backend-build backend-deploy backend-integration \
	terraform-fmt-check terraform-init terraform-validate terraform-plan terraform-ci-plan terraform-apply terraform-ci-apply terraform-output-firebase-plist \
	environment-create bootstrap-remote-state bootstrap-wif

help:
	@printf '%s\n' \
		'CatVox local automation targets:' \
		'' \
		'  make doctor                 Check core local CLI prerequisites' \
		'' \
		'  make ios-build              Generate project and build simulator app' \
		'  make ios-test               Generate project and run iOS unit tests' \
		'  make ios-ui-test            Generate project and run iOS XCUITests' \
		'  make ios-validate-env-config Validate selected Firebase plist and xcconfig values' \
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
		'  make terraform-output-firebase-plist Write Firebase plist from Terraform output' \
		'' \
		'  make environment-create     Bootstrap a named GCP/Firebase environment' \
		'  make bootstrap-remote-state Legacy helper for Terraform state bucket bootstrap' \
		'  make bootstrap-wif          Legacy helper; WIF is Terraform-managed for new envs' \
		'' \
		'Environment overrides:' \
		'  CATVOX_ENV_CONFIG=config/environments/dev.xcconfig selects app-facing env defaults' \
		'  CATVOX_ENVIRONMENT=dev GCP_PROJECT_ID=... FIREBASE_PROJECT=... CATVOX_PROJECT_ID=...' \
		'  CATVOX_SIGNED_UPLOAD_URL_HOST=... CATVOX_ANALYSE_VIDEO_HOST=...' \
		'  CATVOX_SIGNED_UPLOAD_URL_ENDPOINT=... CATVOX_ANALYSE_VIDEO_ENDPOINT=... override full URLs' \
		'  CATVOX_FIREBASE_APP_ID=... CATVOX_FIREBASE_API_KEY=... CATVOX_IOS_BUNDLE_ID=...' \
		'  CATVOX_INTEGRATION_SAFE_ENVIRONMENTS=dev marks mutable-test environments' \
		'  CATVOX_APP_CHECK_DEBUG_TOKEN=... make functions-integration' \
		'  CATVOX_TERRAFORM_ENV=dev selects terraform/backend and terraform/env files' \
		'  CATVOX_TF_BACKEND_CONFIG=terraform/backend/dev.hcl overrides Terraform backend config' \
		'  CATVOX_TF_VARS_FILE=terraform/env/dev.tfvars overrides Terraform var file' \
		'  CATVOX_TFVARS_PATH=... overrides the local tfvars fallback path for App Check debug tokens' \
		'  IOS_TEST_DESTINATION="platform=iOS Simulator,name=iPhone 16,OS=latest"' \
		'  IOS_UI_TEST_DESTINATION="platform=iOS Simulator,name=iPhone 16,OS=latest"' \
		'  DEVICE_ID=... make ios-device-launch' \
		'  CATVOX_APP_CHECK_DEBUG_TOKEN=... make ios-device-launch'

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

ios-validate-env-config:
	@CATVOX_ENVIRONMENT="$(CATVOX_ENVIRONMENT)" \
	 CATVOX_ENV_CONFIG="$(CATVOX_ENV_CONFIG)" \
	 CATVOX_PROJECT_ID="$(CATVOX_PROJECT_ID)" \
	 CATVOX_FIREBASE_APP_ID="$(CATVOX_FIREBASE_APP_ID)" \
	 CATVOX_FIREBASE_API_KEY="$(CATVOX_FIREBASE_API_KEY)" \
	 CATVOX_IOS_BUNDLE_ID="$(CATVOX_IOS_BUNDLE_ID)" \
	 node scripts/validate-firebase-ios-config.mjs

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

ios-ui-test: ios-generate ios-ui-test-only

ios-ui-test-only:
	@destination="$(IOS_UI_TEST_DESTINATION)"; \
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
			-scheme "$(IOS_UI_TEST_SCHEME)" \
			-destination "$$destination" \
			-configuration "$(IOS_CONFIGURATION)" \
			CODE_SIGNING_ALLOWED=NO \
		| xcpretty; \
	else \
		xcodebuild test \
			-project "$(IOS_PROJECT)" \
			-scheme "$(IOS_UI_TEST_SCHEME)" \
			-destination "$$destination" \
			-configuration "$(IOS_CONFIGURATION)" \
			CODE_SIGNING_ALLOWED=NO; \
	fi

ios-ci: ios-generate ios-build-only ios-test-only

ios-device-launch:
	@CATVOX_IOS_BUNDLE_ID="$(CATVOX_IOS_BUNDLE_ID)" \
	 CATVOX_IOS_SCHEME="$(IOS_SCHEME)" \
	 IOS_CONFIGURATION="$(IOS_CONFIGURATION)" \
	 CATVOX_TFVARS_PATH="$(CATVOX_TFVARS_PATH)" \
	 ./scripts/run-on-iphone.sh launch

ios-device-console:
	@CATVOX_IOS_BUNDLE_ID="$(CATVOX_IOS_BUNDLE_ID)" \
	 CATVOX_IOS_SCHEME="$(IOS_SCHEME)" \
	 IOS_CONFIGURATION="$(IOS_CONFIGURATION)" \
	 CATVOX_TFVARS_PATH="$(CATVOX_TFVARS_PATH)" \
	 ./scripts/run-on-iphone.sh console

app-deploy: ios-device-launch

functions-install:
	@npm --prefix functions ci

functions-build:
	@npm --prefix functions run build

functions-test:
	@npm --prefix functions run test:unit

functions-deploy: functions-build
	@CATVOX_ENVIRONMENT="$(CATVOX_ENVIRONMENT)" \
	 CATVOX_PROJECT_ID="$(FIREBASE_PROJECT)" \
	 CATVOX_FUNCTION_REGION="$(CATVOX_FUNCTION_REGION)" \
	 CATVOX_BACKEND_SERVICE_ACCOUNT="$(CATVOX_BACKEND_SERVICE_ACCOUNT)" \
	 firebase deploy --only functions --project "$(FIREBASE_PROJECT)"

functions-integration:
	@app_check_token="$$(CATVOX_TFVARS_PATH="$(CATVOX_TFVARS_PATH)"; export CATVOX_TFVARS_PATH; source scripts/lib/app-check-debug-token.sh; read_catvox_app_check_debug_token)"; \
	if [[ -n "$$app_check_token" ]]; then \
		export CATVOX_APP_CHECK_DEBUG_TOKEN="$$app_check_token"; \
	fi; \
	CATVOX_ENVIRONMENT="$(CATVOX_ENVIRONMENT)" \
	CATVOX_INTEGRATION_MUTATIONS_ALLOWED="$(CATVOX_INTEGRATION_MUTATIONS_ALLOWED)" \
	CATVOX_INTEGRATION_SAFE_ENVIRONMENTS="$(CATVOX_INTEGRATION_SAFE_ENVIRONMENTS)" \
	CATVOX_PROJECT_ID="$(CATVOX_PROJECT_ID)" \
	CATVOX_SIGNED_UPLOAD_URL_ENDPOINT="$(CATVOX_SIGNED_UPLOAD_URL_ENDPOINT)" \
	CATVOX_ANALYSE_VIDEO_ENDPOINT="$(CATVOX_ANALYSE_VIDEO_ENDPOINT)" \
	CATVOX_FIREBASE_APP_ID="$(CATVOX_FIREBASE_APP_ID)" \
	CATVOX_FIREBASE_API_KEY="$(CATVOX_FIREBASE_API_KEY)" \
	CATVOX_IOS_BUNDLE_ID="$(CATVOX_IOS_BUNDLE_ID)" \
	npm --prefix functions run test:integration

functions-ci: functions-install functions-test

backend-build: functions-build

backend-deploy: functions-deploy

backend-integration: functions-integration

terraform-fmt-check:
	@cd terraform && terraform fmt -check -recursive

terraform-init:
	@cd terraform && terraform init $(CATVOX_TF_INIT_FLAGS) $(catvox_tf_backend_args)

terraform-validate:
	@cd terraform && terraform validate -no-color

terraform-plan:
	@cd terraform && TF_VAR_project_id="$(GCP_PROJECT_ID)" GOOGLE_CLOUD_QUOTA_PROJECT="$(GCP_PROJECT_ID)" terraform fmt -check -recursive
	@cd terraform && TF_VAR_project_id="$(GCP_PROJECT_ID)" GOOGLE_CLOUD_QUOTA_PROJECT="$(GCP_PROJECT_ID)" terraform init $(CATVOX_TF_INIT_FLAGS) $(catvox_tf_backend_args)
	@cd terraform && TF_VAR_project_id="$(GCP_PROJECT_ID)" GOOGLE_CLOUD_QUOTA_PROJECT="$(GCP_PROJECT_ID)" terraform validate -no-color
	@cd terraform && TF_VAR_project_id="$(GCP_PROJECT_ID)" GOOGLE_CLOUD_QUOTA_PROJECT="$(GCP_PROJECT_ID)" terraform plan -no-color $(catvox_tf_var_file_arg)

terraform-ci-plan:
	@cd terraform && GOOGLE_CLOUD_QUOTA_PROJECT="$(GCP_PROJECT_ID)" terraform plan -no-color $(catvox_tf_var_file_arg)

terraform-apply:
	@if [[ "$(CONFIRM)" != "apply" ]]; then \
		printf 'Refusing to run Terraform apply. Re-run as: make terraform-apply CONFIRM=apply\n' >&2; \
		exit 1; \
	fi
	@cd terraform && TF_VAR_project_id="$(GCP_PROJECT_ID)" GOOGLE_CLOUD_QUOTA_PROJECT="$(GCP_PROJECT_ID)" terraform init $(CATVOX_TF_INIT_FLAGS) $(catvox_tf_backend_args)
	@cd terraform && TF_VAR_project_id="$(GCP_PROJECT_ID)" GOOGLE_CLOUD_QUOTA_PROJECT="$(GCP_PROJECT_ID)" terraform plan -no-color $(catvox_tf_var_file_arg)
	@cd terraform && TF_VAR_project_id="$(GCP_PROJECT_ID)" GOOGLE_CLOUD_QUOTA_PROJECT="$(GCP_PROJECT_ID)" terraform apply -no-color $(catvox_tf_var_file_arg)

terraform-ci-apply:
	@cd terraform && GOOGLE_CLOUD_QUOTA_PROJECT="$(GCP_PROJECT_ID)" terraform apply -auto-approve -no-color $(catvox_tf_var_file_arg)

terraform-output-firebase-plist:
	@mkdir -p "$$(dirname "$(CATVOX_FIREBASE_PLIST_OUTPUT)")"
	@cd terraform && terraform output -raw firebase_ios_plist_base64 | base64 --decode > "../$(CATVOX_FIREBASE_PLIST_OUTPUT)"
	@CATVOX_ENVIRONMENT="$(CATVOX_ENVIRONMENT)" \
	 CATVOX_ENV_CONFIG="$(CATVOX_ENV_CONFIG)" \
	 CATVOX_PROJECT_ID="$(CATVOX_PROJECT_ID)" \
	 CATVOX_FIREBASE_APP_ID="$(CATVOX_FIREBASE_APP_ID)" \
	 CATVOX_FIREBASE_API_KEY="$(CATVOX_FIREBASE_API_KEY)" \
	 CATVOX_IOS_BUNDLE_ID="$(CATVOX_IOS_BUNDLE_ID)" \
	 node scripts/validate-firebase-ios-config.mjs

bootstrap-remote-state:
	@PROJECT_ID="$(GCP_PROJECT_ID)" ./terraform/bootstrap_remote_state.sh

bootstrap-wif:
	@PROJECT_ID="$(GCP_PROJECT_ID)" ./terraform/bootstrap_wif.sh

environment-create:
	@CATVOX_ENVIRONMENT="$(CATVOX_ENVIRONMENT)" \
	 GCP_PROJECT_ID="$(GCP_PROJECT_ID)" \
	 FIREBASE_PROJECT="$(FIREBASE_PROJECT)" \
	 CATVOX_TF_BACKEND_CONFIG="$(CATVOX_TF_BACKEND_CONFIG)" \
	 CATVOX_TF_VARS_FILE="$(CATVOX_TF_VARS_FILE)" \
	 CATVOX_TF_STATE_BUCKET="$(CATVOX_TF_STATE_BUCKET)" \
	 CATVOX_TF_STATE_PREFIX="$(CATVOX_TF_STATE_PREFIX)" \
	 CATVOX_IOS_BUNDLE_ID="$(CATVOX_IOS_BUNDLE_ID)" \
	 ./scripts/create-environment.sh
