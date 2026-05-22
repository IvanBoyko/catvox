SHELL := /bin/bash

IOS_PROJECT := CatVox.xcodeproj
IOS_SCHEME := CatVox
IOS_UI_TEST_SCHEME := CatVoxUITests
IOS_CONFIGURATION := Debug
IOS_BUILD_DESTINATION := generic/platform=iOS Simulator
IOS_TEST_DESTINATION := platform=iOS Simulator,name=iPhone 16,OS=latest
IOS_UI_TEST_DESTINATION := $(IOS_TEST_DESTINATION)

CATVOX_ENVIRONMENT ?= dev
CATVOX_ENV_CONFIG ?= config/environments/$(CATVOX_ENVIRONMENT).xcconfig
catvox_xcconfig_value = $(strip $(shell scripts/lib/read-xcconfig-value.sh '$(CATVOX_ENV_CONFIG)' '$(1)' 2>/dev/null))

GCP_PROJECT_ID ?= $(call catvox_xcconfig_value,GCP_PROJECT_ID)
FIREBASE_PROJECT ?= $(or $(call catvox_xcconfig_value,FIREBASE_PROJECT),$(GCP_PROJECT_ID))
CATVOX_PROJECT_ID ?= $(or $(call catvox_xcconfig_value,CATVOX_PROJECT_ID),$(GCP_PROJECT_ID))
CATVOX_FUNCTION_REGION ?= $(call catvox_xcconfig_value,CATVOX_FUNCTION_REGION)
CATVOX_FIRESTORE_LOCATION ?= $(call catvox_xcconfig_value,CATVOX_FIRESTORE_LOCATION)
CATVOX_GCP_CI_SERVICE_ACCOUNT ?= $(call catvox_xcconfig_value,CATVOX_GCP_CI_SERVICE_ACCOUNT)
CATVOX_GCP_WIF_PROVIDER ?= $(call catvox_xcconfig_value,CATVOX_GCP_WIF_PROVIDER)
CATVOX_BACKEND_SERVICE_ACCOUNT ?= $(or $(call catvox_xcconfig_value,CATVOX_BACKEND_SERVICE_ACCOUNT),catvox-backend-sa@$(FIREBASE_PROJECT).iam.gserviceaccount.com)
CATVOX_SIGNED_UPLOAD_URL_HOST ?= $(or $(call catvox_xcconfig_value,CATVOX_SIGNED_UPLOAD_URL_HOST),replace-with-dev-signed-upload-host)
CATVOX_ANALYSE_VIDEO_HOST ?= $(or $(call catvox_xcconfig_value,CATVOX_ANALYSE_VIDEO_HOST),replace-with-dev-analyse-video-host)
CATVOX_SIGNED_UPLOAD_URL_ENDPOINT ?= https://$(CATVOX_SIGNED_UPLOAD_URL_HOST)
CATVOX_ANALYSE_VIDEO_ENDPOINT ?= https://$(CATVOX_ANALYSE_VIDEO_HOST)
CATVOX_FIREBASE_APP_ID ?= $(or $(call catvox_xcconfig_value,CATVOX_FIREBASE_APP_ID),replace-with-dev-firebase-app-id)
CATVOX_FIREBASE_API_KEY ?= $(or $(call catvox_xcconfig_value,CATVOX_FIREBASE_API_KEY),replace-with-dev-firebase-api-key)
CATVOX_IOS_BUNDLE_ID ?= $(or $(call catvox_xcconfig_value,CATVOX_IOS_BUNDLE_ID),$(call catvox_xcconfig_value,CATVOX_PRODUCT_BUNDLE_IDENTIFIER))
CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME ?= $(call catvox_xcconfig_value,CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME)
CATVOX_FIREBASE_IOS_APP_DELETION_POLICY ?= $(call catvox_xcconfig_value,CATVOX_FIREBASE_IOS_APP_DELETION_POLICY)
CATVOX_FIREBASE_APPLE_TEAM_ID ?= $(call catvox_xcconfig_value,CATVOX_FIREBASE_APPLE_TEAM_ID)
CATVOX_ENABLE_APP_CHECK_DEBUG_TOKEN ?= $(call catvox_xcconfig_value,CATVOX_ENABLE_APP_CHECK_DEBUG_TOKEN)
CATVOX_APP_CHECK_DEBUG_TOKEN_DISPLAY_NAME ?= $(call catvox_xcconfig_value,CATVOX_APP_CHECK_DEBUG_TOKEN_DISPLAY_NAME)
CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM ?= $(call catvox_xcconfig_value,CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM)
CATVOX_INTEGRATION_MUTATIONS_ALLOWED ?= 1
CATVOX_INTEGRATION_SAFE_ENVIRONMENTS ?= $(or $(call catvox_xcconfig_value,CATVOX_INTEGRATION_SAFE_ENVIRONMENTS),dev)
CATVOX_TF_BACKEND_CONFIG ?= terraform/backend/$(CATVOX_ENVIRONMENT).hcl
CATVOX_TF_VARS_FILE ?= terraform/env/$(CATVOX_ENVIRONMENT).tfvars
CATVOX_TF_STATE_BUCKET ?= $(or $(call catvox_xcconfig_value,CATVOX_TF_STATE_BUCKET),catvox-tf-state-$(GCP_PROJECT_ID))
CATVOX_TF_STATE_PREFIX ?= catvox/state
CATVOX_TF_INIT_FLAGS ?= -reconfigure
# Backward-compatible alias used by App Check token resolution helpers.
CATVOX_TFVARS_PATH ?= $(CATVOX_TF_VARS_FILE)
CATVOX_FIREBASE_PLIST_OUTPUT ?= CatVox/Resources/Firebase/GoogleService-Info-$(CATVOX_ENVIRONMENT).plist

# PostHog Terraform root (see ADR-0020). State lives in the matching environment's
# GCS bucket with prefix `posthog/state`. There is no env/<env>.tfvars file —
# per-environment values are sourced from config/environments/<env>.xcconfig
# via the variables above. The matching GitHub Environment supplies only the
# PostHog API key. The CATVOX_POSTHOG_TF_VARS_FILE pointer is retained only so
# future slices can opt back into a tfvars file if needed; it is unset by default.
CATVOX_POSTHOG_PROJECT_ID ?= $(call catvox_xcconfig_value,CATVOX_POSTHOG_PROJECT_ID)
CATVOX_POSTHOG_ORGANIZATION_ID ?= $(call catvox_xcconfig_value,CATVOX_POSTHOG_ORGANIZATION_ID)
CATVOX_POSTHOG_API_HOST_NAME ?= $(call catvox_xcconfig_value,CATVOX_POSTHOG_API_HOST_NAME)
CATVOX_POSTHOG_API_HOST ?= $(if $(CATVOX_POSTHOG_API_HOST_NAME),https://$(CATVOX_POSTHOG_API_HOST_NAME),)
CATVOX_POSTHOG_TF_BACKEND_CONFIG ?= terraform/posthog/backend/$(CATVOX_ENVIRONMENT).hcl
CATVOX_POSTHOG_TF_VARS_FILE ?=
CATVOX_POSTHOG_TF_STATE_BUCKET ?= $(CATVOX_TF_STATE_BUCKET)
CATVOX_POSTHOG_TF_STATE_PREFIX ?= posthog/state
CATVOX_POSTHOG_TF_INIT_FLAGS ?= -reconfigure

catvox_tf_backend_rel = $(patsubst terraform/%,%,$(CATVOX_TF_BACKEND_CONFIG))
catvox_tf_vars_rel = $(patsubst terraform/%,%,$(CATVOX_TF_VARS_FILE))
# Local runs usually use ignored backend HCL files; CI supplies equivalent inline backend flags.
catvox_tf_backend_args = $(if $(wildcard $(CATVOX_TF_BACKEND_CONFIG)),-backend-config="$(catvox_tf_backend_rel)",-backend-config="bucket=$(CATVOX_TF_STATE_BUCKET)" -backend-config="prefix=$(CATVOX_TF_STATE_PREFIX)")
catvox_tf_var_file_arg = $(if $(wildcard $(CATVOX_TF_VARS_FILE)),-var-file="$(catvox_tf_vars_rel)",)
catvox_tf_env_args = TF_VAR_environment_name="$(CATVOX_ENVIRONMENT)" TF_VAR_project_id="$(GCP_PROJECT_ID)" TF_VAR_region="$(CATVOX_FUNCTION_REGION)" TF_VAR_firestore_location="$(CATVOX_FIRESTORE_LOCATION)" TF_VAR_tf_state_bucket="$(CATVOX_TF_STATE_BUCKET)" TF_VAR_firebase_ios_bundle_id="$(CATVOX_IOS_BUNDLE_ID)" TF_VAR_firebase_ios_app_display_name="$(CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME)" TF_VAR_firebase_ios_app_deletion_policy="$(CATVOX_FIREBASE_IOS_APP_DELETION_POLICY)" TF_VAR_firebase_apple_team_id="$(CATVOX_FIREBASE_APPLE_TEAM_ID)" TF_VAR_enable_app_check_debug_token="$(CATVOX_ENABLE_APP_CHECK_DEBUG_TOKEN)" TF_VAR_app_check_debug_token_display_name="$(CATVOX_APP_CHECK_DEBUG_TOKEN_DISPLAY_NAME)" TF_VAR_manage_gcf_sources_bucket_iam="$(CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM)"

catvox_posthog_tf_backend_rel = $(patsubst terraform/posthog/%,%,$(CATVOX_POSTHOG_TF_BACKEND_CONFIG))
catvox_posthog_tf_vars_rel = $(patsubst terraform/posthog/%,%,$(CATVOX_POSTHOG_TF_VARS_FILE))
catvox_posthog_tf_backend_args = $(if $(wildcard $(CATVOX_POSTHOG_TF_BACKEND_CONFIG)),-backend-config="$(catvox_posthog_tf_backend_rel)",-backend-config="bucket=$(CATVOX_POSTHOG_TF_STATE_BUCKET)" -backend-config="prefix=$(CATVOX_POSTHOG_TF_STATE_PREFIX)")
catvox_posthog_tf_var_file_arg = $(if $(and $(CATVOX_POSTHOG_TF_VARS_FILE),$(wildcard $(CATVOX_POSTHOG_TF_VARS_FILE))),-var-file="$(catvox_posthog_tf_vars_rel)",)
catvox_posthog_tf_env_args = TF_VAR_environment_name="$(CATVOX_ENVIRONMENT)" TF_VAR_posthog_api_host="$(CATVOX_POSTHOG_API_HOST)" TF_VAR_posthog_project_id="$(CATVOX_POSTHOG_PROJECT_ID)" TF_VAR_posthog_organization_id="$(CATVOX_POSTHOG_ORGANIZATION_ID)"

define catvox_require_env_path
	@if [[ -n "$($(1))" && "$$(basename "$($(1))" "$(2)")" != "$(CATVOX_ENVIRONMENT)" ]]; then \
		printf '%s basename must match CATVOX_ENVIRONMENT (%s): %s\n' "$(1)" "$(CATVOX_ENVIRONMENT)" "$($(1))" >&2; \
		exit 1; \
	fi
endef

.PHONY: help doctor \
	ios-generate ios-build ios-build-only ios-test ios-test-only ios-ui-test ios-ui-test-only ios-ci ios-device-launch ios-device-console app-deploy \
	ios-validate-env-config ios-validate-env-config-drift ios-analytics-guard \
	functions-install functions-build functions-test functions-deploy functions-integration functions-ci \
	backend-build backend-deploy backend-integration \
	terraform-check-env-paths terraform-fmt-check terraform-init terraform-validate terraform-plan terraform-ci-plan terraform-apply terraform-ci-apply terraform-output-firebase-plist \
	posthog-terraform-check-env-paths posthog-terraform-fmt-check posthog-terraform-init posthog-terraform-validate posthog-terraform-plan posthog-terraform-ci-plan posthog-terraform-apply posthog-terraform-ci-apply \
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
		'  make ios-validate-env-config-drift Compare committed Firebase plist to Terraform output' \
		'  make ios-analytics-guard    Verify PostHog SDK usage stays behind AnalyticsService' \
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
		'  make posthog-terraform-plan  fmt-check, init, validate, and plan PostHog Terraform' \
		'  make posthog-terraform-apply Plan, then interactively apply PostHog Terraform; requires CONFIRM=apply' \
		'  make posthog-terraform-ci-apply CI-only auto-approved PostHog Terraform apply' \
		'' \
		'  make environment-create     Bootstrap a named GCP/Firebase environment' \
		'  make bootstrap-remote-state Legacy helper for Terraform state bucket bootstrap' \
		'  make bootstrap-wif          Legacy helper; WIF is Terraform-managed for new envs' \
		'' \
		'Environment overrides:' \
		'  CATVOX_ENVIRONMENT=dev selects config/environments/dev.xcconfig plus matching Terraform backend/tfvars basenames' \
		'  GCP_PROJECT_ID=... FIREBASE_PROJECT=... CATVOX_PROJECT_ID=...' \
		'  CATVOX_FUNCTION_REGION=... CATVOX_FIRESTORE_LOCATION=...' \
		'  CATVOX_GCP_CI_SERVICE_ACCOUNT=... CATVOX_GCP_WIF_PROVIDER=...' \
		'  CATVOX_SIGNED_UPLOAD_URL_HOST=... CATVOX_ANALYSE_VIDEO_HOST=...' \
		'  CATVOX_SIGNED_UPLOAD_URL_ENDPOINT=... CATVOX_ANALYSE_VIDEO_ENDPOINT=... override full URLs' \
		'  CATVOX_FIREBASE_APP_ID=... CATVOX_FIREBASE_API_KEY=... CATVOX_IOS_BUNDLE_ID=...' \
		'  CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME=... CATVOX_FIREBASE_IOS_APP_DELETION_POLICY=...' \
		'  CATVOX_FIREBASE_APPLE_TEAM_ID=... CATVOX_ENABLE_APP_CHECK_DEBUG_TOKEN=true|false' \
		'  CATVOX_APP_CHECK_DEBUG_TOKEN_DISPLAY_NAME=... CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM=true|false' \
		'  CATVOX_INTEGRATION_SAFE_ENVIRONMENTS=dev marks mutable-test environments' \
		'  CATVOX_APP_CHECK_DEBUG_TOKEN=... make functions-integration' \
		'  CATVOX_TF_BACKEND_CONFIG=terraform/backend/dev.hcl overrides Terraform backend config; basename must match CATVOX_ENVIRONMENT' \
		'  CATVOX_TF_VARS_FILE=terraform/env/dev.tfvars overrides Terraform var file; basename must match CATVOX_ENVIRONMENT' \
		'  CATVOX_TFVARS_PATH=... overrides the local tfvars fallback path for App Check debug tokens' \
		'  CATVOX_POSTHOG_PROJECT_ID=... overrides the xcconfig PostHog project ID for terraform/posthog/' \
		'  CATVOX_POSTHOG_ORGANIZATION_ID=... overrides the xcconfig PostHog organization ID for terraform/posthog/' \
		'  CATVOX_POSTHOG_API_HOST_NAME=us.posthog.com overrides the xcconfig PostHog Terraform API host name' \
		'  CATVOX_POSTHOG_TF_BACKEND_CONFIG=terraform/posthog/backend/dev.hcl overrides PostHog Terraform backend config; basename must match CATVOX_ENVIRONMENT' \
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

ios-validate-env-config-drift:
	@tmpdir="$$(mktemp -d)"; \
	trap 'rm -rf "$$tmpdir"' EXIT; \
	cd terraform && terraform output -raw firebase_ios_plist_base64 | base64 --decode > "$$tmpdir/expected.plist"; \
	diff -u "$$tmpdir/expected.plist" "$(CURDIR)/$(CATVOX_FIREBASE_PLIST_OUTPUT)"

ios-analytics-guard:
	@scripts/guard-analytics-capture-boundary.sh

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

ios-ci: ios-generate ios-analytics-guard ios-build-only ios-test-only

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

terraform-check-env-paths:
	$(call catvox_require_env_path,CATVOX_TF_BACKEND_CONFIG,.hcl)
	$(call catvox_require_env_path,CATVOX_TF_VARS_FILE,.tfvars)

terraform-init: terraform-check-env-paths
	@cd terraform && terraform init $(CATVOX_TF_INIT_FLAGS) $(catvox_tf_backend_args)

terraform-validate:
	@cd terraform && terraform validate -no-color

terraform-plan: terraform-check-env-paths
	@cd terraform && $(catvox_tf_env_args) GOOGLE_CLOUD_QUOTA_PROJECT="$(GCP_PROJECT_ID)" terraform fmt -check -recursive
	@cd terraform && $(catvox_tf_env_args) GOOGLE_CLOUD_QUOTA_PROJECT="$(GCP_PROJECT_ID)" terraform init $(CATVOX_TF_INIT_FLAGS) $(catvox_tf_backend_args)
	@cd terraform && $(catvox_tf_env_args) GOOGLE_CLOUD_QUOTA_PROJECT="$(GCP_PROJECT_ID)" terraform validate -no-color
	@cd terraform && $(catvox_tf_env_args) GOOGLE_CLOUD_QUOTA_PROJECT="$(GCP_PROJECT_ID)" terraform plan -no-color $(catvox_tf_var_file_arg)

terraform-ci-plan: terraform-check-env-paths
	@cd terraform && $(catvox_tf_env_args) GOOGLE_CLOUD_QUOTA_PROJECT="$(GCP_PROJECT_ID)" terraform plan -no-color $(catvox_tf_var_file_arg)

terraform-apply: terraform-check-env-paths
	@if [[ "$(CONFIRM)" != "apply" ]]; then \
		printf 'Refusing to run Terraform apply. Re-run as: make terraform-apply CONFIRM=apply\n' >&2; \
		exit 1; \
	fi
	@cd terraform && $(catvox_tf_env_args) GOOGLE_CLOUD_QUOTA_PROJECT="$(GCP_PROJECT_ID)" terraform init $(CATVOX_TF_INIT_FLAGS) $(catvox_tf_backend_args)
	@cd terraform && $(catvox_tf_env_args) GOOGLE_CLOUD_QUOTA_PROJECT="$(GCP_PROJECT_ID)" terraform plan -no-color $(catvox_tf_var_file_arg)
	@cd terraform && $(catvox_tf_env_args) GOOGLE_CLOUD_QUOTA_PROJECT="$(GCP_PROJECT_ID)" terraform apply -no-color $(catvox_tf_var_file_arg)

terraform-ci-apply: terraform-check-env-paths
	@cd terraform && $(catvox_tf_env_args) GOOGLE_CLOUD_QUOTA_PROJECT="$(GCP_PROJECT_ID)" terraform apply -auto-approve -no-color $(catvox_tf_var_file_arg)

posthog-terraform-fmt-check:
	@cd terraform/posthog && terraform fmt -check -recursive

posthog-terraform-check-env-paths:
	$(call catvox_require_env_path,CATVOX_POSTHOG_TF_BACKEND_CONFIG,.hcl)
	$(call catvox_require_env_path,CATVOX_POSTHOG_TF_VARS_FILE,.tfvars)

posthog-terraform-init: posthog-terraform-check-env-paths
	@cd terraform/posthog && terraform init $(CATVOX_POSTHOG_TF_INIT_FLAGS) $(catvox_posthog_tf_backend_args)

posthog-terraform-validate:
	@cd terraform/posthog && terraform validate -no-color

posthog-terraform-plan: posthog-terraform-check-env-paths
	@cd terraform/posthog && terraform fmt -check -recursive
	@cd terraform/posthog && terraform init $(CATVOX_POSTHOG_TF_INIT_FLAGS) $(catvox_posthog_tf_backend_args)
	@cd terraform/posthog && terraform validate -no-color
	@cd terraform/posthog && $(catvox_posthog_tf_env_args) terraform plan -no-color $(catvox_posthog_tf_var_file_arg)

posthog-terraform-ci-plan: posthog-terraform-check-env-paths
	@cd terraform/posthog && $(catvox_posthog_tf_env_args) terraform plan -no-color $(catvox_posthog_tf_var_file_arg)

posthog-terraform-apply: posthog-terraform-check-env-paths
	@if [[ "$(CONFIRM)" != "apply" ]]; then \
		printf 'Refusing to run PostHog Terraform apply. Re-run as: make posthog-terraform-apply CONFIRM=apply\n' >&2; \
		exit 1; \
	fi
	@cd terraform/posthog && terraform init $(CATVOX_POSTHOG_TF_INIT_FLAGS) $(catvox_posthog_tf_backend_args)
	@cd terraform/posthog && $(catvox_posthog_tf_env_args) terraform plan -no-color $(catvox_posthog_tf_var_file_arg)
	@cd terraform/posthog && $(catvox_posthog_tf_env_args) terraform apply -no-color $(catvox_posthog_tf_var_file_arg)

posthog-terraform-ci-apply: posthog-terraform-check-env-paths
	@cd terraform/posthog && $(catvox_posthog_tf_env_args) terraform apply -auto-approve -no-color $(catvox_posthog_tf_var_file_arg)

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
	 CATVOX_FUNCTION_REGION="$(CATVOX_FUNCTION_REGION)" \
	 CATVOX_FIRESTORE_LOCATION="$(CATVOX_FIRESTORE_LOCATION)" \
	 CATVOX_TF_BACKEND_CONFIG="$(CATVOX_TF_BACKEND_CONFIG)" \
	 CATVOX_TF_VARS_FILE="$(CATVOX_TF_VARS_FILE)" \
	 CATVOX_TF_STATE_BUCKET="$(CATVOX_TF_STATE_BUCKET)" \
	 CATVOX_TF_STATE_PREFIX="$(CATVOX_TF_STATE_PREFIX)" \
	 CATVOX_IOS_BUNDLE_ID="$(CATVOX_IOS_BUNDLE_ID)" \
	 CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME="$(CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME)" \
	 CATVOX_FIREBASE_IOS_APP_DELETION_POLICY="$(CATVOX_FIREBASE_IOS_APP_DELETION_POLICY)" \
	 CATVOX_FIREBASE_APPLE_TEAM_ID="$(CATVOX_FIREBASE_APPLE_TEAM_ID)" \
	 CATVOX_ENABLE_APP_CHECK_DEBUG_TOKEN="$(CATVOX_ENABLE_APP_CHECK_DEBUG_TOKEN)" \
	 CATVOX_APP_CHECK_DEBUG_TOKEN_DISPLAY_NAME="$(CATVOX_APP_CHECK_DEBUG_TOKEN_DISPLAY_NAME)" \
	 CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM="$(CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM)" \
	 ./scripts/create-environment.sh
