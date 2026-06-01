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
CATVOX_ENV_CACHE_DIR ?= .make.d
# Derive the cache filename from the full CATVOX_ENV_CONFIG path, not just
# CATVOX_ENVIRONMENT, so callers that override the config path (e.g.
# `make CATVOX_ENV_CONFIG=/tmp/staging.xcconfig`) get a distinct cache and
# never read stale values from a previous run that used the default path.
CATVOX_ENV_CACHE ?= $(CATVOX_ENV_CACHE_DIR)/$(subst /,__,$(CATVOX_ENV_CONFIG)).env.mk

# Parse <env>.xcconfig once per environment and cache the resulting `KEY ?= VALUE`
# lines as a Makefile fragment. Standard prerequisite mtime tracking handles
# invalidation: any change to the xcconfig file or to the parser scripts
# regenerates the fragment on the next make invocation. Use `mktemp` inside the
# cache dir so parallel make processes in the same workspace do not race on a
# fixed `$@.tmp` path.
$(CATVOX_ENV_CACHE): $(CATVOX_ENV_CONFIG) scripts/lib/emit-xcconfig-env.sh scripts/lib/xcconfig-parse.awk scripts/lib/xcconfig-validate.sh | $(CATVOX_ENV_CACHE_DIR)
	@tmp=$$(mktemp '$@.XXXXXX') && \
	  trap 'rm -f "$$tmp"' EXIT && \
	  scripts/lib/emit-xcconfig-env.sh --format=make '$<' > "$$tmp" && \
	  mv "$$tmp" '$@'

$(CATVOX_ENV_CACHE_DIR):
	@mkdir -p '$@'

# When the xcconfig is present, use `include` so a parser/validation failure
# halts the build loudly. When it is absent (fresh checkout, brand-new env),
# fall back to `-include` so non-environment targets like `make help` and
# `make doctor` continue to work; the post-include `?=` fallbacks below cover
# the unset keys.
ifneq ($(wildcard $(CATVOX_ENV_CONFIG)),)
include $(CATVOX_ENV_CACHE)
else
-include $(CATVOX_ENV_CACHE)
endif

# Post-include defaults: apply only when the xcconfig did not set the key.
# Environment-supplied values (`CATVOX_PROJECT_ID=foo make ...`) and
# command-line overrides (`make CATVOX_PROJECT_ID=foo ...`) still win because
# `?=` is a no-op on already-defined variables.
# CATVOX_PROJECT_ID intentionally has no placeholder fallback. Fresh
# environment bootstrap must fail fast unless the caller supplies a real project.
CATVOX_BACKEND_SERVICE_ACCOUNT ?= catvox-backend-sa@$(CATVOX_PROJECT_ID).iam.gserviceaccount.com
CATVOX_SIGNED_UPLOAD_URL_HOST ?= replace-with-dev-signed-upload-host
CATVOX_ANALYSE_VIDEO_HOST ?= replace-with-dev-analyse-video-host
CATVOX_SIGNED_UPLOAD_URL_ENDPOINT ?= https://$(CATVOX_SIGNED_UPLOAD_URL_HOST)
CATVOX_ANALYSE_VIDEO_ENDPOINT ?= https://$(CATVOX_ANALYSE_VIDEO_HOST)
CATVOX_FIREBASE_APP_ID ?= replace-with-dev-firebase-app-id
CATVOX_FIREBASE_API_KEY ?= replace-with-dev-firebase-api-key
CATVOX_IOS_BUNDLE_ID ?= replace-with-dev-bundle-id
# WIF ref pin fallback (empty = trust any ref). The per-environment value lives
# in config/environments/<env>.xcconfig as CATVOX_GCP_WIF_GITHUB_REF.
CATVOX_GCP_WIF_GITHUB_REF ?=
# Firestore App Check enforcement mode. Real environments set this in xcconfig;
# the fresh-checkout fallback is the non-enforcing, non-destructive UNENFORCED.
CATVOX_FIREBASE_FIRESTORE_APP_CHECK_ENFORCEMENT ?= UNENFORCED
# Environment security tier (ADR-0026). Fresh-checkout fallback is the
# non-protected (mutable) tier; protected environments set true in xcconfig.
CATVOX_ENVIRONMENT_PROTECTED ?= false
CATVOX_INTEGRATION_MUTATIONS_ALLOWED ?= 1
CATVOX_INTEGRATION_SAFE_ENVIRONMENTS ?= dev
CATVOX_TF_VARS_FILE ?= terraform/env/$(CATVOX_ENVIRONMENT).tfvars
CATVOX_TF_STATE_BUCKET ?= catvox-tf-state-$(CATVOX_PROJECT_ID)
CATVOX_TF_STATE_PREFIX ?= catvox/state
CATVOX_TF_INIT_FLAGS ?= -reconfigure
# Backward-compatible alias used by App Check token resolution helpers.
CATVOX_TFVARS_PATH ?= $(CATVOX_TF_VARS_FILE)
CATVOX_FIREBASE_PLIST_OUTPUT ?= CatVox/Resources/Firebase/GoogleService-Info-$(CATVOX_ENVIRONMENT).plist

# PostHog Terraform root (see ADR-0020). State lives in the matching environment's
# GCS bucket with prefix `posthog/state`. There is no env/<env>.tfvars file —
# per-environment values are sourced from config/environments/<env>.xcconfig
# via the include above. The matching GitHub Environment supplies only the
# PostHog API key. The CATVOX_POSTHOG_TF_VARS_FILE pointer is retained only so
# future slices can opt back into a tfvars file if needed; it is unset by default.
CATVOX_POSTHOG_API_HOST ?= $(if $(CATVOX_POSTHOG_API_HOST_NAME),https://$(CATVOX_POSTHOG_API_HOST_NAME),)
CATVOX_POSTHOG_TF_VARS_FILE ?=
CATVOX_POSTHOG_TF_STATE_BUCKET ?= $(CATVOX_TF_STATE_BUCKET)
CATVOX_POSTHOG_TF_STATE_PREFIX ?= posthog/state
CATVOX_POSTHOG_TF_INIT_FLAGS ?= -reconfigure

catvox_tf_vars_rel = $(patsubst terraform/%,%,$(CATVOX_TF_VARS_FILE))
catvox_tf_backend_args = -backend-config="bucket=$(CATVOX_TF_STATE_BUCKET)" -backend-config="prefix=$(CATVOX_TF_STATE_PREFIX)"
catvox_tf_var_file_arg = $(if $(wildcard $(CATVOX_TF_VARS_FILE)),-var-file="$(catvox_tf_vars_rel)",)
catvox_tf_env_args = TF_VAR_environment_name="$(CATVOX_ENVIRONMENT)" TF_VAR_project_id="$(CATVOX_PROJECT_ID)" TF_VAR_region="$(CATVOX_FUNCTION_REGION)" TF_VAR_firestore_location="$(CATVOX_FIRESTORE_LOCATION)" TF_VAR_tf_state_bucket="$(CATVOX_TF_STATE_BUCKET)" TF_VAR_firebase_ios_bundle_id="$(CATVOX_IOS_BUNDLE_ID)" TF_VAR_firebase_ios_app_display_name="$(CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME)" TF_VAR_firebase_ios_app_deletion_policy="$(CATVOX_FIREBASE_IOS_APP_DELETION_POLICY)" TF_VAR_firebase_apple_team_id="$(CATVOX_FIREBASE_APPLE_TEAM_ID)" TF_VAR_manage_gcf_sources_bucket_iam="$(CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM)" TF_VAR_github_ref="$(CATVOX_GCP_WIF_GITHUB_REF)" TF_VAR_firestore_app_check_enforcement="$(CATVOX_FIREBASE_FIRESTORE_APP_CHECK_ENFORCEMENT)"

catvox_posthog_tf_vars_rel = $(patsubst terraform/posthog/%,%,$(CATVOX_POSTHOG_TF_VARS_FILE))
catvox_posthog_tf_backend_args = -backend-config="bucket=$(CATVOX_POSTHOG_TF_STATE_BUCKET)" -backend-config="prefix=$(CATVOX_POSTHOG_TF_STATE_PREFIX)"
catvox_posthog_tf_var_file_arg = $(if $(and $(CATVOX_POSTHOG_TF_VARS_FILE),$(wildcard $(CATVOX_POSTHOG_TF_VARS_FILE))),-var-file="$(catvox_posthog_tf_vars_rel)",)
catvox_posthog_tf_env_args = TF_VAR_environment_name="$(CATVOX_ENVIRONMENT)" TF_VAR_posthog_api_host="$(CATVOX_POSTHOG_API_HOST)" TF_VAR_posthog_project_id="$(CATVOX_POSTHOG_PROJECT_ID)" TF_VAR_posthog_organization_id="$(CATVOX_POSTHOG_ORGANIZATION_ID)"

define catvox_require_env_path
	@if [[ -n "$($(1))" && "$$(basename "$($(1))" "$(2)")" != "$(CATVOX_ENVIRONMENT)" ]]; then \
		printf '%s basename must match CATVOX_ENVIRONMENT (%s): %s\n' "$(1)" "$(CATVOX_ENVIRONMENT)" "$($(1))" >&2; \
		exit 1; \
	fi
endef

.PHONY: help doctor scripts-test \
	setup-local-ai-loop ai-loop-start ai-loop-answer \
	ios-generate ios-build ios-build-only ios-test ios-test-only ios-ui-test ios-ui-test-only ios-ci ios-device-launch ios-device-console app-deploy \
	ios-validate-env-config ios-validate-env-config-structure ios-validate-env-config-drift ios-analytics-guard ios-validate-release-safety \
	functions-install functions-build functions-test functions-deploy functions-integration functions-ci \
	backend-build backend-deploy backend-integration \
	terraform-check-env-paths terraform-fmt-check terraform-init terraform-validate terraform-test terraform-plan terraform-ci-plan terraform-apply terraform-ci-apply terraform-import terraform-output-firebase-plist \
	posthog-terraform-check-env-paths posthog-terraform-fmt-check posthog-terraform-init posthog-terraform-validate posthog-terraform-plan posthog-terraform-ci-plan posthog-terraform-apply posthog-terraform-ci-apply posthog-environment-provision \
	smoke environment-create configure-github-environment environment-write-config environment-doctor \
	terraform-destroy posthog-terraform-destroy environment-destroy

help:
	@printf '%s\n' \
		'CatVox local automation targets:' \
		'' \
		'  make doctor                 Check core local CLI prerequisites' \
		'  make setup-local-ai-loop    Configure local AI loop Git hook and prerequisites' \
		'  make ai-loop-start          Start local AI loop with AI_LOOP_BRANCH and AI_LOOP_PROMPT' \
		'  make ai-loop-answer         Answer an AI loop clarification with AI_LOOP_ANSWER' \
		'' \
		'  make ios-build              Generate project and build simulator app' \
		'  make ios-test               Generate project and run iOS unit tests' \
		'  make ios-ui-test            Generate project and run iOS XCUITests' \
		'  make ios-validate-env-config Validate selected Firebase plist and xcconfig values' \
		'  make ios-validate-env-config-structure Validate <env> xcconfig structure before plist lands' \
		'  make ios-validate-env-config-drift Compare committed Firebase plist to Terraform output' \
		'  make ios-analytics-guard    Verify PostHog SDK usage stays behind AnalyticsService' \
		'  make ios-validate-release-safety [CATVOX_ENVIRONMENT=<env>] Validate protected Release safety; auto-discovers the protected env (no foreign-env leak, debug surfaces gated)' \
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
		'  make posthog-environment-provision Prompt/store PostHog API key, apply PostHog Terraform, and write xcconfig' \
		'' \
		'  make smoke CATVOX_ENVIRONMENT=<env> Run non-invasive environment smoke checks' \
		'  make environment-create     Bootstrap a named GCP/Firebase environment' \
		'  make environment-doctor     Read-only preflight of an environment'\''s provisioning prerequisites' \
		'  make environment-write-config Write resolved non-secret xcconfig values (PHASE=identity|hosts|posthog|all)' \
		'  make configure-github-environment Configure a GitHub Environment from committed config' \
		'  make environment-destroy    Tear down an environment (CONFIRM=destroy; protected also needs ALLOW_PROTECTED_DESTROY=<env>)' \
		'' \
		'Environment overrides:' \
		'  CATVOX_ENVIRONMENT=dev selects config/environments/dev.xcconfig plus matching Terraform tfvars basename' \
		'  CATVOX_PROJECT_ID=...' \
		'  CATVOX_FUNCTION_REGION=... CATVOX_FIRESTORE_LOCATION=...' \
		'  CATVOX_GCP_CI_SERVICE_ACCOUNT=... CATVOX_GCP_WIF_PROVIDER=...' \
		'  CATVOX_SIGNED_UPLOAD_URL_HOST=... CATVOX_ANALYSE_VIDEO_HOST=...' \
		'  CATVOX_SIGNED_UPLOAD_URL_ENDPOINT=... CATVOX_ANALYSE_VIDEO_ENDPOINT=... override full URLs' \
		'  CATVOX_FIREBASE_APP_ID=... CATVOX_FIREBASE_API_KEY=... CATVOX_IOS_BUNDLE_ID=...' \
		'  CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME=... CATVOX_FIREBASE_IOS_APP_DELETION_POLICY=...' \
		'  CATVOX_FIREBASE_APPLE_TEAM_ID=... CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM=true|false' \
		'  CATVOX_INTEGRATION_SAFE_ENVIRONMENTS=dev marks mutable-test environments' \
		'  CATVOX_APP_CHECK_DEBUG_TOKEN=... make functions-integration' \
		'  CATVOX_TFVARS_PATH=... overrides the local tfvars fallback path for App Check debug tokens' \
		'  AI_LOOP_INVOKE_AGENTS=1 enables opt-in local AI-loop agent dispatch' \
		'  AI_LOOP_CREATE_PR=0 (or git config ai-loop.createPr false) skips draft-PR bootstrap during make ai-loop-start; default is on' \
		'  AI_LOOP_AGENT_PROFILE=smoke|real selects cheaper smoke or stronger real local AI-loop commands' \
		'  AI_LOOP_ANSWER="..." answers an AI-loop clarification via make ai-loop-answer' \
		'  CATVOX_POSTHOG_PROJECT_ID=... overrides the xcconfig PostHog project ID for terraform/posthog/' \
		'  CATVOX_POSTHOG_ORGANIZATION_ID=... overrides the xcconfig PostHog organization ID for terraform/posthog/' \
		'  CATVOX_POSTHOG_API_HOST_NAME=us.posthog.com overrides the xcconfig PostHog Terraform API host name' \
		'  RUN_POSTHOG_TERRAFORM_APPLY=1 includes PostHog provisioning in make environment-create' \
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

scripts-test:
	@bash scripts/test/emit-xcconfig-env.test.sh
	@bash scripts/test/makefile-env-cache.test.sh
	@bash scripts/test/import-preexisting-resources.test.sh
	@bash scripts/test/configure-github-environment.test.sh
	@bash scripts/test/provision-posthog-environment.test.sh
	@bash scripts/test/environment-doctor.test.sh
	@bash scripts/test/write-environment-config.test.sh
	@bash scripts/test/destroy-environment.test.sh
	@node --test scripts/test/validate-environment-config.test.mjs scripts/test/validate-release-safety.test.mjs scripts/test/find-firebase-ios-app-id.test.mjs scripts/test/docs-environment-model-sst.test.mjs
	@python3 tools/ai-loop/ai_loop_test.py

setup-local-ai-loop:
	@python3 tools/ai-loop/ai_loop.py setup

ai-loop-start:
	@python3 tools/ai-loop/ai_loop.py start

ai-loop-answer:
	@python3 tools/ai-loop/ai_loop.py answer

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

ios-validate-env-config-structure:
	@CATVOX_ENVIRONMENT="$(CATVOX_ENVIRONMENT)" \
	 CATVOX_ENV_CONFIG="$(CATVOX_ENV_CONFIG)" \
	 node scripts/validate-environment-config.mjs "$(CATVOX_ENVIRONMENT)"

ios-validate-env-config-drift:
	@tmpdir="$$(mktemp -d)"; \
	trap 'rm -rf "$$tmpdir"' EXIT; \
	cd terraform && terraform output -raw firebase_ios_plist_base64 | base64 --decode > "$$tmpdir/expected.plist"; \
	diff -u "$$tmpdir/expected.plist" "$(CURDIR)/$(CATVOX_FIREBASE_PLIST_OUTPUT)"

ios-analytics-guard:
	@scripts/guard-analytics-capture-boundary.sh

# Release safety is a protected-tier check. With no override it auto-discovers
# the protected environment; pass CATVOX_ENVIRONMENT=<env> to target a specific
# config. The repo default (CATVOX_ENVIRONMENT ?= dev) is deliberately not
# forwarded, so a bare invocation validates the protected tier rather than dev.
ios-validate-release-safety:
	@node scripts/validate-release-safety.mjs \
	 $(if $(filter-out file default undefined,$(origin CATVOX_ENVIRONMENT)),"$(CATVOX_ENVIRONMENT)")

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
	@firebase functions:artifacts:setpolicy --project "$(CATVOX_PROJECT_ID)" --location "$(CATVOX_FUNCTION_REGION)" --days 7 --non-interactive --force
	@CATVOX_ENVIRONMENT="$(CATVOX_ENVIRONMENT)" \
	 CATVOX_PROJECT_ID="$(CATVOX_PROJECT_ID)" \
	 CATVOX_FUNCTION_REGION="$(CATVOX_FUNCTION_REGION)" \
	 CATVOX_BACKEND_SERVICE_ACCOUNT="$(CATVOX_BACKEND_SERVICE_ACCOUNT)" \
	 firebase deploy --only functions --project "$(CATVOX_PROJECT_ID)"

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
	$(call catvox_require_env_path,CATVOX_TF_VARS_FILE,.tfvars)
	@bash scripts/guard-terraform-tfvars-private-only.sh "$(CATVOX_TF_VARS_FILE)" "$(CATVOX_ENVIRONMENT)"

terraform-init: terraform-check-env-paths
	@cd terraform && terraform init $(CATVOX_TF_INIT_FLAGS) $(catvox_tf_backend_args)

terraform-validate: terraform-check-env-paths
	@cd terraform && terraform validate -no-color

terraform-test: terraform-check-env-paths
	@cd terraform && terraform test

terraform-plan: terraform-check-env-paths
	@cd terraform && $(catvox_tf_env_args) GOOGLE_CLOUD_QUOTA_PROJECT="$(CATVOX_PROJECT_ID)" terraform fmt -check -recursive
	@cd terraform && $(catvox_tf_env_args) GOOGLE_CLOUD_QUOTA_PROJECT="$(CATVOX_PROJECT_ID)" terraform init $(CATVOX_TF_INIT_FLAGS) $(catvox_tf_backend_args)
	@cd terraform && $(catvox_tf_env_args) GOOGLE_CLOUD_QUOTA_PROJECT="$(CATVOX_PROJECT_ID)" terraform validate -no-color
	@cd terraform && $(catvox_tf_env_args) GOOGLE_CLOUD_QUOTA_PROJECT="$(CATVOX_PROJECT_ID)" terraform plan -no-color $(catvox_tf_var_file_arg)

# CI-only plan. terraform -detailed-exitcode reports 0 = no changes, 2 = changes,
# 1 = error. `make` collapses every non-zero recipe exit to 2, so it cannot carry
# the 0-vs-2 distinction itself; the recipe echoes terraform's real code on a
# CATVOX_TF_DETAILED_EXITCODE= marker line and exits 0 for 0/2 (only a genuine
# error fails). The plan workflow reads that marker to skip the PR comment — and
# the email it triggers — on no-change runs. See .github/actions/terraform-ci-plan.
terraform-ci-plan: terraform-check-env-paths
	@cd terraform && $(catvox_tf_env_args) GOOGLE_CLOUD_QUOTA_PROJECT="$(CATVOX_PROJECT_ID)" terraform plan -detailed-exitcode -no-color $(catvox_tf_var_file_arg); \
		code=$$?; \
		echo "CATVOX_TF_DETAILED_EXITCODE=$$code"; \
		[ "$$code" = "2" ] && exit 0 || exit "$$code"

terraform-apply: terraform-check-env-paths
	@if [[ "$(CONFIRM)" != "apply" ]]; then \
		printf 'Refusing to run Terraform apply. Re-run as: make terraform-apply CONFIRM=apply\n' >&2; \
		exit 1; \
	fi
	@cd terraform && $(catvox_tf_env_args) GOOGLE_CLOUD_QUOTA_PROJECT="$(CATVOX_PROJECT_ID)" terraform init $(CATVOX_TF_INIT_FLAGS) $(catvox_tf_backend_args)
	@cd terraform && $(catvox_tf_env_args) GOOGLE_CLOUD_QUOTA_PROJECT="$(CATVOX_PROJECT_ID)" terraform plan -no-color $(catvox_tf_var_file_arg)
	@cd terraform && $(catvox_tf_env_args) GOOGLE_CLOUD_QUOTA_PROJECT="$(CATVOX_PROJECT_ID)" terraform apply -no-color $(catvox_tf_var_file_arg)

terraform-ci-apply: terraform-check-env-paths
	@cd terraform && $(catvox_tf_env_args) GOOGLE_CLOUD_QUOTA_PROJECT="$(CATVOX_PROJECT_ID)" terraform apply -auto-approve -no-color $(catvox_tf_var_file_arg)

# Import a single existing resource into Terraform state. Used by
# scripts/import-preexisting-resources.sh for idempotent provisioning into a
# project that already has resources (issue #38 Step 3, S5). Run after
# terraform-init; the caller is responsible for the in-state idempotency guard.
terraform-import: terraform-check-env-paths
	@if [[ -z "$(ADDRESS)" || -z "$(ID)" ]]; then \
		printf 'terraform-import requires ADDRESS=<resource address> and ID=<import id>; run after terraform-init.\n' >&2; \
		exit 1; \
	fi
	@cd terraform && $(catvox_tf_env_args) GOOGLE_CLOUD_QUOTA_PROJECT="$(CATVOX_PROJECT_ID)" terraform import -no-color $(catvox_tf_var_file_arg) "$(ADDRESS)" "$(ID)"

# Destroy the core Terraform-managed resources for an environment. Gated on
# CONFIRM=destroy. Invoked by scripts/destroy-environment.sh after its own safety
# checks; the iOS app honours its deletion_policy (ABANDON/DELETE) here.
terraform-destroy: terraform-check-env-paths
	@if [[ "$(CONFIRM)" != "destroy" ]]; then \
		printf 'Refusing to run Terraform destroy. Re-run as: make terraform-destroy CONFIRM=destroy\n' >&2; \
		exit 1; \
	fi
	@cd terraform && $(catvox_tf_env_args) GOOGLE_CLOUD_QUOTA_PROJECT="$(CATVOX_PROJECT_ID)" terraform init $(CATVOX_TF_INIT_FLAGS) $(catvox_tf_backend_args)
	@cd terraform && $(catvox_tf_env_args) GOOGLE_CLOUD_QUOTA_PROJECT="$(CATVOX_PROJECT_ID)" terraform destroy -auto-approve -no-color $(catvox_tf_var_file_arg)

posthog-terraform-fmt-check:
	@cd terraform/posthog && terraform fmt -check -recursive

posthog-terraform-check-env-paths:
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

# CI-only plan. See terraform-ci-plan above for the -detailed-exitcode +
# CATVOX_TF_DETAILED_EXITCODE marker contract the plan workflow relies on to skip
# the PR comment on no-change runs.
posthog-terraform-ci-plan: posthog-terraform-check-env-paths
	@cd terraform/posthog && $(catvox_posthog_tf_env_args) terraform plan -detailed-exitcode -no-color $(catvox_posthog_tf_var_file_arg); \
		code=$$?; \
		echo "CATVOX_TF_DETAILED_EXITCODE=$$code"; \
		[ "$$code" = "2" ] && exit 0 || exit "$$code"

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

posthog-environment-provision:
	@CATVOX_ENVIRONMENT="$(CATVOX_ENVIRONMENT)" \
	 CATVOX_ENV_CONFIG="$(CATVOX_ENV_CONFIG)" \
	 GITHUB_ENVIRONMENT_REVIEWERS="$(GITHUB_ENVIRONMENT_REVIEWERS)" \
	 POSTHOG_API_KEY="$(POSTHOG_API_KEY)" \
	 ./scripts/provision-posthog-environment.sh

# Destroy the PostHog Terraform resources for an environment. Gated on
# CONFIRM=destroy. Tolerant of an empty/uninitialised root during first
# bootstrap or after a previous teardown.
posthog-terraform-destroy: posthog-terraform-check-env-paths
	@if [[ "$(CONFIRM)" != "destroy" ]]; then \
		printf 'Refusing to run PostHog Terraform destroy. Re-run as: make posthog-terraform-destroy CONFIRM=destroy\n' >&2; \
		exit 1; \
	fi
	@cd terraform/posthog && terraform init $(CATVOX_POSTHOG_TF_INIT_FLAGS) $(catvox_posthog_tf_backend_args)
	@cd terraform/posthog && $(catvox_posthog_tf_env_args) terraform destroy -auto-approve -no-color $(catvox_posthog_tf_var_file_arg)

smoke:
	@CATVOX_ENVIRONMENT="$(CATVOX_ENVIRONMENT)" \
	 CATVOX_ENV_CONFIG="$(CATVOX_ENV_CONFIG)" \
	 node scripts/smoke.mjs

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

environment-create:
	@CATVOX_ENVIRONMENT="$(CATVOX_ENVIRONMENT)" \
	 CATVOX_PROJECT_ID="$(CATVOX_PROJECT_ID)" \
	 CATVOX_FUNCTION_REGION="$(CATVOX_FUNCTION_REGION)" \
	 CATVOX_FIRESTORE_LOCATION="$(CATVOX_FIRESTORE_LOCATION)" \
	 CATVOX_TF_VARS_FILE="$(CATVOX_TF_VARS_FILE)" \
	 CATVOX_TF_STATE_BUCKET="$(CATVOX_TF_STATE_BUCKET)" \
	 CATVOX_TF_STATE_PREFIX="$(CATVOX_TF_STATE_PREFIX)" \
	 CATVOX_IOS_BUNDLE_ID="$(CATVOX_IOS_BUNDLE_ID)" \
	 CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME="$(CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME)" \
	 CATVOX_FIREBASE_IOS_APP_DELETION_POLICY="$(CATVOX_FIREBASE_IOS_APP_DELETION_POLICY)" \
	 CATVOX_FIREBASE_APPLE_TEAM_ID="$(CATVOX_FIREBASE_APPLE_TEAM_ID)" \
	 CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM="$(CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM)" \
	 RUN_POSTHOG_TERRAFORM_APPLY="$(RUN_POSTHOG_TERRAFORM_APPLY)" \
	 GITHUB_ENVIRONMENT_REVIEWERS="$(GITHUB_ENVIRONMENT_REVIEWERS)" \
	 POSTHOG_API_KEY="$(POSTHOG_API_KEY)" \
	 ./scripts/create-environment.sh

configure-github-environment:
	@CATVOX_ENVIRONMENT="$(CATVOX_ENVIRONMENT)" \
	 CATVOX_ENVIRONMENT_PROTECTED="$(CATVOX_ENVIRONMENT_PROTECTED)" \
	 CATVOX_GCP_WIF_GITHUB_REF="$(CATVOX_GCP_WIF_GITHUB_REF)" \
	 GITHUB_ENVIRONMENT_REVIEWERS="$(GITHUB_ENVIRONMENT_REVIEWERS)" \
	 ./scripts/configure-github-environment.sh

# Read-only preflight: assert an environment's provisioning prerequisites
# (billing, APIs, CI SA roles incl. cloudfunctions.admin, WIF scoping, state
# bucket) and fail fast with a hint instead of surfacing them mid-deploy.
environment-doctor:
	@CATVOX_ENVIRONMENT="$(CATVOX_ENVIRONMENT)" \
	 CATVOX_PROJECT_ID="$(CATVOX_PROJECT_ID)" \
	 CATVOX_FUNCTION_REGION="$(CATVOX_FUNCTION_REGION)" \
	 CATVOX_GCP_CI_SERVICE_ACCOUNT="$(CATVOX_GCP_CI_SERVICE_ACCOUNT)" \
	 CATVOX_GCP_WIF_PROVIDER="$(CATVOX_GCP_WIF_PROVIDER)" \
	 CATVOX_TF_STATE_BUCKET="$(CATVOX_TF_STATE_BUCKET)" \
	 ./scripts/environment-doctor.sh

# Write resolved non-secret values into config/environments/<env>.xcconfig from
# Terraform outputs + the Firebase plist (identity) and the deployed Cloud Run
# hosts (hosts). Working tree only — the operator reviews and commits. PHASE
# selects which values to write: identity (default) | hosts | all.
environment-write-config:
	@CATVOX_ENVIRONMENT="$(CATVOX_ENVIRONMENT)" \
	 CATVOX_ENV_CONFIG="$(CATVOX_ENV_CONFIG)" \
	 CATVOX_PROJECT_ID="$(CATVOX_PROJECT_ID)" \
	 CATVOX_FUNCTION_REGION="$(CATVOX_FUNCTION_REGION)" \
	 CATVOX_FIREBASE_PLIST_OUTPUT="$(CATVOX_FIREBASE_PLIST_OUTPUT)" \
	 WRITE_CONFIG_PHASE="$(PHASE)" \
	 ./scripts/write-environment-config.sh

# Tear down a named environment (keeps the GCP project): terraform destroy +
# PostHog + the out-of-graph buckets + the GitHub Environment. Gated:
# CONFIRM=destroy for any env; protected envs also require
# ALLOW_PROTECTED_DESTROY=<env>.
environment-destroy:
	@CATVOX_ENVIRONMENT="$(CATVOX_ENVIRONMENT)" \
	 CATVOX_PROJECT_ID="$(CATVOX_PROJECT_ID)" \
	 CATVOX_FUNCTION_REGION="$(CATVOX_FUNCTION_REGION)" \
	 CATVOX_TF_STATE_BUCKET="$(CATVOX_TF_STATE_BUCKET)" \
	 CATVOX_ENVIRONMENT_PROTECTED="$(CATVOX_ENVIRONMENT_PROTECTED)" \
	 CATVOX_TF_VARS_FILE="$(CATVOX_TF_VARS_FILE)" \
	 CONFIRM="$(CONFIRM)" \
	 ALLOW_PROTECTED_DESTROY="$(ALLOW_PROTECTED_DESTROY)" \
	 GITHUB_REPO="$(GITHUB_REPO)" \
	 ./scripts/destroy-environment.sh
