import { test } from "node:test";
import assert from "node:assert/strict";

import { findIosAppId } from "../find-firebase-ios-app-id.mjs";

const BUNDLE = "com.kathelix.catvox";
const APP_ID = "1:953500951129:ios:1595a4c27cd8f3f7964748";

test("matches by namespace field (firebase apps:list shape)", () => {
  const json = JSON.stringify({
    status: "success",
    result: [
      { appId: "1:1:ios:other", platform: "IOS", namespace: "com.kathelix.catvox.dev" },
      { appId: APP_ID, platform: "IOS", namespace: BUNDLE },
    ],
  });
  assert.equal(findIosAppId(json, BUNDLE), APP_ID);
});

test("matches by bundleId field", () => {
  const json = JSON.stringify([{ appId: APP_ID, bundleId: BUNDLE }]);
  assert.equal(findIosAppId(json, BUNDLE), APP_ID);
});

test("accepts a top-level apps array", () => {
  const json = JSON.stringify({ apps: [{ appId: APP_ID, namespace: BUNDLE }] });
  assert.equal(findIosAppId(json, BUNDLE), APP_ID);
});

test("exact bundle match only — no prefix collision either direction", () => {
  const dev = JSON.stringify({ result: [{ appId: "1:x:ios:dev", namespace: "com.kathelix.catvox.dev" }] });
  assert.equal(findIosAppId(dev, BUNDLE), "");
  const prod = JSON.stringify({ result: [{ appId: APP_ID, namespace: BUNDLE }] });
  assert.equal(findIosAppId(prod, "com.kathelix.catvox.dev"), "");
});

test("returns empty when no iOS app matches the bundle id", () => {
  const json = JSON.stringify({ result: [{ appId: "1:x:ios:y", namespace: "com.example.other" }] });
  assert.equal(findIosAppId(json, BUNDLE), "");
});

test("returns empty on unparseable or empty input", () => {
  assert.equal(findIosAppId("not json", BUNDLE), "");
  assert.equal(findIosAppId("", BUNDLE), "");
});

test("returns empty when the bundle id argument is blank", () => {
  const json = JSON.stringify([{ appId: APP_ID, namespace: BUNDLE }]);
  assert.equal(findIosAppId(json, ""), "");
  assert.equal(findIosAppId(json, "   "), "");
});

test("ignores entries without an appId", () => {
  const json = JSON.stringify({ result: [{ namespace: BUNDLE }] });
  assert.equal(findIosAppId(json, BUNDLE), "");
});

test("returns the first matching app id", () => {
  const json = JSON.stringify({
    result: [
      { appId: APP_ID, namespace: BUNDLE },
      { appId: "1:dupe:ios:zzz", namespace: BUNDLE },
    ],
  });
  assert.equal(findIosAppId(json, BUNDLE), APP_ID);
});
