# CatVox — Apple Developer Program License Agreement (ADPLA) Compliance Gap Audit

**Purpose.** This is the working punch‑list to bring CatVox into compliance with the **updated Apple Developer Program License Agreement (ADPLA)** before submitting to the App Store. Each gap cites the ADPLA clause + page and the concrete repo evidence, and gives a remediation action. Work the blockers first.

| | |
|---|---|
| **Audited against** | Apple Developer Program License Agreement (the attached 117‑page PDF, ref `6AX82WT38B`) |
| **App under audit** | CatVox iOS — bundle `com.kathelix.catvox`, marketing version `1.0` build `1`, min iOS 17, iPhone‑only |
| **Developer / account** | Kathelix Ltd — Team `QYT76L5836` |
| **Audit date** | 2026‑06‑19 |
| **Method** | All ADPLA developer/publishing obligations extracted clause‑by‑clause from the PDF, audited against the live repo, then each claimed gap adversarially re‑verified against the repo. Evidence is cited to `file:line` and ADPLA `§/page`. |
| **Status** | Pre‑submission. **2 hard submission blockers + 8 high‑priority items** must be resolved before go‑live. |

> **Scope note.** The ADPLA incorporates the **App Store Review Guidelines**, the **Human Interface Guidelines (HIG)**, and Apple **Documentation** *by reference* (§3.3.1(G), §3.2(c)) and makes compliance with them a contractual obligation. Where a gap is really a Review‑Guidelines/HIG matter, it is flagged as such. This audit covers the **license agreement**; it is **not legal advice** — the licensing/EULA items (H2) need review by counsel.

---

## 1. Executive summary

CatVox's **engineering** privacy posture is strong: an accurate privacy manifest, required‑reason API declarations, no IDFA/tracking, disabled analytics autocapture with data minimisation, App Attest/App Check, documented‑APIs‑only, a conspicuous recording indicator, local + 24h server deletion. Those are **already compliant** (§4) and should not be re‑done.

The gaps are almost entirely **publishing, legal, and disclosure** artifacts that live *outside* the code and have simply not been produced yet — most importantly there is **no published privacy policy, no support URL, and no resolution of the GPLv3‑vs‑App‑Store licensing conflict.**

| Severity | Count | Items |
|---|--:|---|
| 🔴 **Blocker** (cannot submit / will be rejected) | 2 | B1 Privacy policy, B2 Support URL |
| 🟠 **High** (required before go‑live) | 8 | H1 AI/data disclosure + analytics consent · H2 GPLv3/EULA reconciliation · H3 "Upgrade to Pro" placeholder · H4 Export‑compliance declaration · H5 Service‑provider agreements (DPAs) · H6 Server‑side retention + deletion path · H7 Mac/visionOS availability decision · H8 EU DSA trader disclosure |
| 🟡 **Medium** | 7 | M1 FOSS attribution / Licenses screen · M2 Breach‑notification process · M3 Medical‑claim disclaimer · M4 Re‑consent discipline · M5 Cellular/bandwidth awareness · M6 HIG/accessibility pass · M7 Retention‑wording fix |
| 🟢 **Low** | 3 | L1 Ongoing iOS‑compat + SPM updates · L2 Rights‑loss withdrawal procedure · L3 Recurring Guidelines/ADPLA compliance review |
| ⚙️ **Mandatory ASC steps** (do at submission) | 4 | App Privacy answers · Age rating · Export answer · EULA selection |

**The four things actually gating go‑live:** (1) publish a privacy policy + URL, (2) provide a support URL, (3) decide & resolve the GPLv3 licensing/EULA conflict, (4) remove or reword the non‑functional "Upgrade to Pro" button.

---

## 2. Blockers — must resolve to submit

### 🔴 B1 — Publish a privacy policy (and link it in‑app + App Store Connect)
- **ADPLA:** §3.3.3(C) (p.23); Schedule 1 §2.1 (p.104), §3.6 (p.105‑106); Exhibit D §2 (p.116). *"You must provide a privacy policy in Your Application, on the App Store, and/or on Your website explaining Your collection, use, disclosure, sharing, retention, and deletion of user or device data."*
- **Current state:** No policy and no URL exist. The only artifact is [docs/app-store-privacy.md](docs/app-store-privacy.md), which self‑describes as *"the working checklist … not a replacement for legal review"* (line 3‑4) and lists only what *"the public privacy policy should state"* (lines 62‑79). Repo‑wide search found no privacy‑policy URL anywhere, no in‑app privacy view, and no ASC metadata. App Store Connect **requires a Privacy Policy URL to submit** — this is a hard stop.
- **Why it's acute for CatVox:** the app uploads user **video + audio** off‑device to **Google Vertex AI (Gemini)** and runs **PostHog** product analytics — both must be disclosed.
- **Remediation:**
  1. Expand the drafted points in [docs/app-store-privacy.md](docs/app-store-privacy.md) into a real policy covering: data collected (clips, audio, product‑interaction analytics, anonymous install ID); **third‑party processors** (Google Vertex AI/Gemini for analysis, Firebase/GCP backend, PostHog analytics); that **clips + audio are sent off‑device to Google for AI analysis**; retention (raw clips auto‑deleted, local history user‑deletable, backend usage record keyed to an anonymous ID — see H6); deletion options + a contact; **no advertising / no tracking / no sale of data**; breach notification (M2); regional rights (GDPR/CCPA).
  2. Host it at a stable URL (e.g. `kathelix.com/catvox/privacy` or GitHub Pages).
  3. Enter the URL in App Store Connect and **link it from inside the app** (Schedule 1 §3.6 requires it be readily viewable in‑app). This requires adding an About/Settings/Legal surface — none exists today (`CatVox/Views/` has only Home/Recording/Result/Components).
  4. **Legal review** before publishing.

### 🔴 B2 — Provide a support URL / support pathway
- **ADPLA:** Schedule 1 §5.1 (p.106); Exhibit B §3 (p.110) — the developer (not Apple) provides all end‑user support and maintenance.
- **Current state:** No support URL, support email, or in‑app Help/Contact exists (the only `supportURL` occurrences are `CatVoxApp.swift:59/69`, a local `applicationSupportDirectory` filesystem path — unrelated). In‑app feedback intake is explicitly deferred to issue #123 (v2.0). App Store Connect **requires a Support URL to submit.**
- **Remediation:** Stand up a support page or support email and enter the Support URL in App Store Connect. Optionally surface it in the in‑app About screen created for B1. (Free, no‑accounts apps still require this.)

---

## 3. High‑priority — required before go‑live

### 🟠 H1 — Disclose off‑device AI processing & obtain analytics consent
- **ADPLA:** §3.3.3(B) prior consent (p.23); §3.3.3(C) disclosure (p.23); §3.3.3(F)(iv) honor denial/withdrawal (p.25); consent/disclosure pattern §3.3.11(B)(iii)/§3.3.8(D) (p.44/37). *(Note: §3.3.11/§3.2(h) govern **Apple's** models — CatVox uses Google Gemini, so those clauses are N/A; the obligations that apply are the §3.3.3 data/privacy ones.)*
- **Current state:**
  - **No off‑device disclosure.** Audio/video go to Vertex AI Gemini (`functions/src/gemini.ts`, `docs/systemInstruction.md:16`) but no user‑facing string names the recipient or the transfer. Upload UI shows only *"Sending clip — XX%"* ([UploadProgressView.swift:120](CatVox/Views/Result/UploadProgressView.swift#L120)); `NSMicrophoneUsageDescription` says only *"captures audio to analyse your cat's vocalisations"* — no mention of third‑party transmission.
  - **No analytics consent gate.** [CatVoxApp.swift:27](CatVox/App/CatVoxApp.swift#L27) calls `AnalyticsService.configure()` unconditionally in `init()`; [AnalyticsService.swift:71‑75](CatVox/Services/AnalyticsService.swift#L71) immediately sets up PostHog and `identify()`s a persistent install UUID — before any UI, with no consent. The only gating is build/test flags, never user consent. There is no opt‑out/withdrawal control.
- **Remediation:** (a) State in the privacy policy (B1) and ideally in‑app (a first‑run notice before the first upload) that clips + audio are uploaded to Google for AI analysis; (b) add an analytics **consent/opt‑out** mechanism (at minimum an EU/GDPR consent gate, since ePrivacy/GDPR require prior consent for non‑essential analytics) and a way to withdraw it (PostHog `optOut()`), satisfying §3.3.3(F)(iv). Keep the existing data‑minimisation (which is already compliant).

### 🟠 H2 — Reconcile the GPLv3 license with App Store distribution & the end‑user EULA
- **ADPLA:** §3.3.4(A)(v) FOSS (p.30); **§5.1 licensing warranty** (p.45 — you warrant the app's license, *including FOSS*, "will not conflict with the digital signing or content protection aspects of the Program" and won't require Apple to disclose signing keys); §7.6 no other distribution (p.53); Schedule 1 §3.2 + Exhibit B §1‑§2, §10 (p.105, 110‑111); §14.6 self‑termination on conflict (p.60).
- **Current state:** [LICENSE](LICENSE) is **verbatim GPLv3** (sole human author Ivan Boyko / Kathelix Ltd — confirmed via git log). The classic GPL‑vs‑App‑Store conflict is **present and unmitigated:** Apple's default end‑user EULA (Schedule 1 Exhibit B) is device‑limited, non‑transferable, names Apple as an enforcing third‑party beneficiary, and applies FairPlay/usage rules — all of which conflict with GPLv3 §10 ("no further restrictions") and §6 (Installation Information). There is **no GPLv3 §7 App Store exception, no dual‑license, and no EULA decision** recorded anywhere. By submitting you attest the §5.1 warranty, so this must be resolved deliberately.
- **Resolution options (you are the sole copyright holder, so this is your call to make):**
  - **(a) Recommended — add a GPLv3 §7 "App Store / Apple‑platform" additional permission** to CatVox's own license, expressly allowing distribution through the App Store under Apple's terms and waiving the conflicting GPL conditions for the Apple‑signed binary. This is the standard fix used by FOSS‑on‑App‑Store projects.
  - **(b) Dual‑license:** keep GPLv3 for the public source, distribute the App Store binary under a separate license / Apple's standard EULA.
  - **(c) Relicense** the app to a permissive license (MIT/Apache‑2.0).
- **Also under this workstream:**
  - **Decide standard vs. custom EULA** (Schedule 1 §3.2). If you keep Apple's standard EULA, option (a) or (b) above is what makes that consistent with your source license.
  - **Surface the developer's name + address + contact** for end‑user complaints (Exhibit B §8) — "Kathelix Ltd" appears only in internal docs; no address/contact is anywhere user‑facing. Apple's standard EULA does **not** auto‑provide this.
  - The **ai-loop** submodule is also GPLv3 but is **developer tooling, not shipped in the iOS binary**, so it does not affect app distribution.
- **Remediation:** Make the licensing decision (a/b/c) with counsel, apply it to `LICENSE` (and/or the ASC EULA field), and record it in an ADR.

### 🟠 H3 — Remove or reword the non‑functional "Upgrade to Pro" button
- **ADPLA / Guidelines:** §3.2(f) no misleading practices (p.20); §3.3.1(C) added features only via IAP (p.21); Review Guideline 2.3.1 (no placeholder/hidden features).
- **Current state:** [QuotaExceededView.swift:52‑88](CatVox/Views/Result/QuotaExceededView.swift#L52) renders a prominent gradient **"Upgrade to Pro"** button whose only action is an analytics event + a *"Coming Soon"* alert. StoreKit/IAP is unimplemented (deferred to issue #53). A prominent CTA advertising a feature that doesn't exist is a **common App Review rejection** ("advertised functionality not present").
- **Remediation (v1.0):** either remove the CTA, or reword it as a non‑purchase informational teaser (no "Upgrade/Buy" affordance). Ship the real StoreKit flow only when #53 lands (see the deferred IAP prerequisites in §6).

### 🟠 H4 — Declare export compliance (set `ITSAppUsesNonExemptEncryption`)
- **ADPLA:** §5.3 export warranty (p.46); §14.8 (p.60‑61); Schedule 1 §2.3 (p.104); Attachment 12 §2.3(F) (p.93).
- **Current state:** `ITSAppUsesNonExemptEncryption` is **absent** from both `project.yml` (info.properties, lines 72‑88) and the generated [CatVox/Info.plist](CatVox/Info.plist), so the export question must be answered manually on every upload, and [scripts/validate-release-safety.mjs](scripts/validate-release-safety.mjs) does not assert it.
- **Remediation:** CatVox uses only standard HTTPS/TLS (exempt). Add `ITSAppUsesNonExemptEncryption = false` to `project.yml` info.properties, document the determination, and add it to the release‑safety required‑keys list so CI guards it. (If you ever add non‑exempt crypto, this flips and may require a CCATS/self‑classification.)

### 🟠 H5 — Put binding service‑provider agreements (DPAs) in place
- **ADPLA:** §2.9 Service Providers (p.18‑19 — must have a binding written agreement "at least as restrictive and protective of Apple"); Attachment 12 §2.3(F) export flow‑down (p.93).
- **Current state:** User clips/audio flow to **Google Cloud / Vertex AI**, the **Firebase/GCP** backend, and **PostHog**. No DPA / sub‑processor / service‑provider agreement is referenced anywhere in the project.
- **Remediation:** Confirm and **record** that Google Cloud (Vertex AI + Firebase) and PostHog Data Processing Addendums are accepted (these exist as standard online terms for both vendors) and that they meet §2.9. Capture this in a short `docs/SERVICE_PROVIDERS.md`. Largely a verification + documentation task.

### 🟠 H6 — Bound server‑side retention & provide a data‑deletion path
- **ADPLA:** §3.3.3(C) retention/deletion disclosure (p.23) + general controller duties.
- **Current state:** Raw clips auto‑delete (`terraform/core/main.tf:73‑85`, age = 1 day) ✅ and local scans are user‑deletable ([ScanHistoryStore.swift:48](CatVox/Services/ScanHistoryStore.swift#L48)) ✅. **But** the Firestore `usage/{userId}` document (keyed by the anonymous install UUID) is **never deleted** — `functions/src/usageGuard.ts` only resets the daily count; there's no TTL and no user‑deletion path, so the identifier persists server‑side **indefinitely**. No data‑subject deletion/contact exists.
- **Remediation:** Add a Firestore TTL (or scheduled cleanup) for stale `usage/{userId}` docs, document the retention period, and provide a deletion‑request contact in the privacy policy (B1). Reflect all retention/deletion accurately in the policy.

### 🟠 H7 — Decide Mac (Apple silicon) / visionOS availability
- **ADPLA:** §6.3 (p.48) — iOS apps are **made available by default** on Mac with Apple silicon and Apple Vision Pro unless you opt out, and you warrant the rights to run there.
- **Current state:** iPhone‑only build (`TARGETED_DEVICE_FAMILY "1"`, iOS 17), camera/mic + Firebase/PostHog + Gemini backend, never validated on Mac/visionOS. `docs/HLD.md:97` documents an **iPad** non‑goal but says nothing about the Mac/Vision Pro auto‑availability default, and no opt‑out decision is recorded.
- **Remediation:** Decide in App Store Connect whether to make CatVox available on Mac/Vision Pro; if not, **opt out**. Record the decision (ADR or release runbook). If opting in, test there and confirm SDK/model/GPL rights extend to those platforms.

### 🟠 H8 — EU DSA trader status & disclosure
- **ADPLA:** Schedule 1, Exhibit D §3 (p.117) — DSA / P2B redress; ASC gates EU distribution on **trader verification**.
- **Current state:** Developer is **Kathelix Ltd** (an EU/UK company), so EU distribution very likely triggers the DSA trader‑disclosure regime. No trader contact details (address/phone/email) are captured anywhere; no awareness note exists.
- **Remediation:** Complete the **trader verification** in App Store Connect (legal name, address, phone, email — which will be publicly displayed) before EU distribution. This overlaps with the contact info needed for B1/H2.

---

## 4. Already compliant — do **not** redo (evidence)

| Area | ADPLA | Evidence |
|---|---|---|
| **Recording indicator** while capturing audio/video | §3.3.3(A) p.22 | Red dot + "REC" + animated countdown ring, [RecordingView.swift:116](CatVox/Views/Recording/RecordingView.swift#L116). *(Applies to the in‑app camera path; Photos‑imported clips aren't recorded by the app.)* |
| **Privacy manifest** present & accurate; **required‑reason APIs** declared | §3.3.3(B) p.23 | [CatVox/PrivacyInfo.xcprivacy](CatVox/PrivacyInfo.xcprivacy) — 4 data types, `NSPrivacyTracking=false`, UserDefaults `CA92.1`, FileTimestamp `C617.1` |
| **No IDFA / no tracking / no device fingerprinting** | §3.3.3(B),(E) p.23‑24 | No ATT/IDFA; anonymous per‑install UUID in `UserDefaults` (not a device‑based identifier) — [UserIdentityStore.swift](CatVox/Services/UserIdentityStore.swift) |
| **Analytics minimisation** (autocapture/crash/swizzle off; no raw video/paths/thoughts) | §3.3.3(B) p.23 | [AnalyticsService.swift:59‑69](CatVox/Services/AnalyticsService.swift#L59); [docs/app-store-privacy.md:30‑31](docs/app-store-privacy.md#L30) |
| **Documented APIs only; no private APIs; no downloaded executable code** | §3.3.1(A),(B) p.21 | SwiftUI + pinned SPM deps only |
| **App Attest / App Check** (prod enforced) | §3.3.1, §5 | [CatVox.entitlements](CatVox/CatVox.entitlements) `appattest-environment=production`; backend `runWithAppCheck` |
| **No Apple‑model usage** (Gemini is third‑party) → §3.2(h)/§3.3.11 N/A | §3.2(h) p.21 | `functions/src/gemini.ts` (Vertex AI) |
| **Local + server deletion** | §3.3.3(C) | `ScanHistoryStore.deleteScan()`; GCS lifecycle delete `terraform/core/main.tf:73‑85` |
| **Distribution channel exclusivity** (App Store/TestFlight only) | §3.2(g), §7.6 | iOS app/test targets only; Release archive is the only signed artifact |
| **Static security/leak gates + CodeQL** | §3.3.4(A)(iv) | [scripts/validate-release-safety.mjs](scripts/validate-release-safety.mjs); GitHub default CodeQL setup |

---

## 5. Medium / Low / Mandatory‑ASC items

### Medium
- **🟡 M1 — FOSS attribution + GPL source offer.** §3.3.4(A)(v) p.30; §14.1 p.58. No committed `NOTICE`/acknowledgements file and no in‑app Licenses screen for the bundled permissive SDKs (Firebase Apache‑2.0, PostHog MIT, PLCrashReporter, gRPC, abseil, leveldb, nanopb, …). **Add an in‑app "Acknowledgements / Licenses" screen** (use the About surface from B1) and, for the GPL source, a "where to get the source" note. *(Apache‑2.0/MIT are GPLv3‑compatible, so combining them is fine — only the attribution is missing.)*
- **🟡 M2 — Data‑breach notification process.** §3.3.3(C) p.23. No breach‑response runbook. Add a short `docs/` runbook + a policy clause committing to notify users per law.
- **🟡 M3 — Medical/clinical claim disclaimer.** §3.3.2 p.22. "Expert Insights" / `owner_tip` ([ExpertInsightsDrawer.swift:20](CatVox/Views/Result/ExpertInsightsDrawer.swift#L20)) presents behavioural advice; ensure marketing + UI don't imply veterinary/medical diagnosis. Add an in‑app/store disclaimer ("not veterinary advice"). The Gemini prompt already says to recommend consulting a vet (`docs/systemInstruction.md:30`).
- **🟡 M4 — Re‑consent on data‑scope change.** §3.3.3(B) p.23. No consent‑version tracking (follows from H1). Maintain the discipline that any new collection updates the policy + ASC + re‑prompts.
- **🟡 M5 — Cellular/bandwidth awareness.** §3.3.7(B)(i) p.34. Video upload + AI calls have no Wi‑Fi/cellular awareness. Consider `allowsConstrainedNetworkAccess` / a large‑upload‑on‑cellular guard.
- **🟡 M6 — HIG / accessibility pass.** §3.3.1(G) p.22. `accessibilityLabel` count = 0 in `CatVox/Views/`. Do a VoiceOver/Dynamic‑Type/HIG pass before submission.
- **🟡 M7 — Retention wording fix.** `terraform/core/main.tf` comments (lines 68/79) say "delete after 24 h" while the enforced rule is `age = 1` day — align the comment and the privacy‑policy wording.

### Low
- **🟢 L1 — Ongoing iOS‑compat + SPM updates.** §6.8 p.50; §2.10 p.19. `dependabot.yml` covers npm + actions only — **add the `swift`/SPM ecosystem** so Firebase/PostHog stay current; commit to rebuild/re‑test on each major iOS release.
- **🟢 L2 — Rights‑loss withdrawal procedure.** Schedule 1 §6.2 p.107. Document a "notify Apple + withdraw" procedure if rights to a bundled component are ever lost.
- **🟢 L3 — Recurring compliance review.** §4 p.44‑45. The release‑safety validator is technical/point‑in‑time. Add a periodic checklist pass against the Review Guidelines/ADPLA (Apple updates them).

### ⚙️ Mandatory App Store Connect steps (complete at submission)
- **App Privacy ("nutrition label") answers** — must match [CatVox/PrivacyInfo.xcprivacy](CatVox/PrivacyInfo.xcprivacy) **and** the Xcode archive privacy report, **including the inert PLCrashReporter crash‑data manifest** that ships via PostHog (already noted in [docs/app-store-privacy.md:42‑48](docs/app-store-privacy.md#L42)).
- **Age rating** questionnaire — no rating decided yet; choose one (likely 4+) and confirm AI‑generated text can't surface mature content.
- **Export‑compliance** answer — see H4.
- **EULA selection** — standard vs custom — see H2.

---

## 6. Deferred — In‑App Purchase ("Pro" tier, issue #53)

No IAP ships in v1.0, so these are **prerequisites for when the paid tier ships**, not v1.0 blockers (per adversarial verification). When #53 lands, satisfy: **execute the Schedule 2 Paid Applications Agreement** in App Store Connect before charging any fee, and **submit each IAP product for review** before sale (Schedule 1 §1.5); StoreKit‑only unlock with **Apple receipt/transaction verification** before granting entitlement (§3.3.9(A), Attachment 2 §3.1); **Restore Purchases** + cross‑device entitlement keyed off the StoreKit transaction, not the install UUID (Attachment 2 §2.6); pre‑purchase **license disclosure** + terms link (Attachment 2 §3.2); **no self‑refunds** — direct refund requests to Apple (Attachment 2 §3.4). Until then, keep the CTA disabled/reworded (H3).

---

## 7. Recommended remediation sequence

1. **B1 Privacy policy** + **B2 Support URL** (+ the in‑app About/Legal surface they both need). *Unblocks submission.*
2. **H2 Licensing decision** (GPLv3 §7 exception / dual‑license + EULA choice + developer contact) — needs counsel, start early.
3. **H1 disclosure + analytics consent**, **H3 remove/reword "Upgrade to Pro"**, **H4 export key**.
4. **H5 DPAs**, **H6 retention/deletion**, **H7 Mac/visionOS opt‑out**, **H8 DSA trader verification**.
5. **M1–M7**, then **L1–L3**.
6. At upload: complete the **mandatory ASC steps**; generate the archive privacy report and reconcile it with the ASC App Privacy answers.

---

### Appendix — requirement‑cluster → ADPLA reference map
Privacy policy/disclosure/consent §3.3.3(B‑D), Sch.1 §2.1/§3.6, Ex.D §2 · Permission strings & recording indicator §3.3.3(A),(F)(iv) · Privacy manifest/required‑reason/SDK accountability §3.3.3(B), §2.9, Att.12 §2.3(F) · Analytics/IDFA §3.3.3(B),(E) · AI/external processing §3.3.3, §3.2(h), §3.3.11 · Retention/security/deletion §3.3.3(C) · Security/App Attest/no‑private‑APIs §3.3.1(A‑D), §5 · Code signing §5.1 · Content/age/metadata §3.1(b), §3.2(f), §3.3.2, §3.3.4(A), Sch.1 §2.4/§4 · IAP/monetization §3.3.1(C), §3.3.9(A), Att.2 · Export/encryption §5.3, §14.8, Sch.1 §2.3 · FOSS/GPL/EULA §3.3.4(A)(v), §5.1, §7.6, Sch.1 §3.2, Ex.B · EULA minimum terms Sch.1 §3.2‑3.3, Ex.B §1‑§10 · Trademarks/attribution §2.4, §2.6, §14.1 · Distribution/TestFlight §3.2(g), §7, §7.6 · Support/completeness/maintenance §3.3.1(G), §6.8, §6.9, §2.10, Sch.1 §5.1, Ex.B §3 · Developer account/eligibility/DSA §3.1, §4, §11.2, Ex.D §3.

*Generated from a full clause‑by‑clause extraction of the ADPLA (301 obligations across 117 pages) audited against the repo with per‑finding adversarial verification. Not legal advice; the licensing/EULA items require review by counsel.*
