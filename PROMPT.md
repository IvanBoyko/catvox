# Project Vision: CatVox AI

## 1. The Big Picture
We are building a premium iPhone/iPad application for cat owners under the **Kathelix Ltd** brand. The goal is to use high-end AI to "translate" cat behavior into humorous, persona-driven monologues while providing legitimate feline behavioral insights. 

This isn't just a toy - it's a portfolio showcase of Kathelix’s ability to build resilient, AI-driven cloud architectures. The app must feel polished, professional, and technologically superior.

## 2. Core User Experience
* **The 10-Second Rule:** Users record a fixed 10-second clip of their cat. We capture both video (posture/ears/tail) and audio (vocalizations).
* **The Magic Reveal:** We use a "Glassmorphism" (frosted glass) aesthetic. The "translation" appears as a beautiful, semi-transparent thought bubble over the video loop.
* **The Persona Engine:** We don't just give a generic answer. We assign the cat a "Persona" (e.g., Grumpy Boss, Existential Philosopher) to make the results varied and viral.

## 3. Key Decisions Made
* **Aesthetics:** High-end, dark-mode, glassmorphism UI. We prefer SwiftUI's native `.ultraThinMaterial`.
* **No Ads:** We explicitly rejected intrusive advertising. We want a clean, premium experience.
* **Monetization:** We use a "Daily Credit" system (e.g., 5 free scans/day) and an In-App Purchase to unlock unlimited scans and remove watermarks.
* **Viral Strategy:** Shared videos will have a subtle "Powered by Kathelix" watermark to drive brand awareness and LinkedIn leads.
* **Infrastructure:** We are using **Google Cloud (Vertex AI)** for the intelligence because it handles multimodal (video + audio) data natively better than others.

## 4. Technical Constraints for the Developer
* **Backend Proxy:** All AI calls must go through a Firebase Cloud Function. Never call Vertex AI directly from the client to protect API keys.
* **Lean Infrastructure:** Keep GCP costs low by using **Gemini 3.1 Flash**. Implement auto-deletion (TTL) for uploaded videos in Cloud Storage.
* **Privacy:** No personal data collection beyond a Firebase UID. Videos are transient and deleted after processing.

## 5. Developer Mindset
We prioritize **short iteration cycles**. Don't try to build the entire system perfectly in one go. Build the "Result View" with mock data first, then the "Camera Logic," then the "Cloud Connection." Every module should be testable.