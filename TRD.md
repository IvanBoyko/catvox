# Technical Requirements Document: CatVox AI (MVP)

**Version:** 1.2  
**Company:** Kathelix Ltd  
**Project Lead:** Ivan Boyko
**Date:** April 2026  
**Status:** Specification Refinement (Post-Prototype)

---

## 1. Executive Summary
CatVox AI is a premium, minimalist iOS application designed to interpret cat behavior from 10-second video clips using multimodal Generative AI (Gemini 3.1 Flash). The app serves as a high-tech brand ambassador for Kathelix Ltd, showcasing expertise in AI integration, Cloud architecture, and superior UX design.

---

## 2. Brand Identity & Design Language
* **Brand Pillars:** Resilience (Phoenix narrative), Engineering Excellence, Playful Intelligence.
* **Visual Style:** Glassmorphism (Frosted glass), dark mode aesthetics, fluid spring-based animations.
* **Target Market:** UK & International English-speaking tech-savvy pet owners.

---

## 3. Functional Requirements

### 3.1 Core Features (MVP)
* **Video Capture:** Fixed 10-second recording window with a visual countdown UI.
* **Multimodal Analysis:** Simultaneous processing of video (body language) and audio (vocalization) via Vertex AI.
* **Persona Engine:** Logic to assign one of 6 "Cat Personas" (e.g., Grumpy Boss, Existential Philosopher) to the output.
* **Mood Diary:** A local history of scans saved using SwiftData.
* **Social Sharing:** Integrated "Share to Story" feature with a branded overlay.

### 3.2 Monetization & Sustainability
* **Credit System:** 5 free scans/day to manage GCP costs.
* **Pro Tier (IAP):** One-time purchase for unlimited scans and watermark removal.
* **Brand Promotion:** Subtle "Powered by Kathelix.com" watermark on all free-tier exports.

---

## 4. Technical Architecture

### 4.1 System Overview
* **Frontend:** iOS App (SwiftUI).
* **Backend Proxy:** Firebase Cloud Functions (Node.js) to protect Vertex AI API keys.
* **AI Engine:** Google Vertex AI - Gemini 3.1 Flash.
* **Storage:** Google Cloud Storage (Temporary video hosting).

### 4.2 API Data Schema
The backend must return a strictly formatted JSON object:

> {
>   "primary_emotion": "string",
>   "confidence_score": 0.0,
>   "analysis": "string",
>   "persona_type": "string",
>   "cat_thought": "string",
>   "owner_tip": "string"
> }

---

## 5. UI/UX Specifications

### 5.1 Key Screens
1. **Home Screen:** Minimalist dashboard showing the latest "Mood" and a "Start Scan" button.
2. **Recording Screen:** Viewfinder with an AVFoundation-based 10s progress ring.
3. **Result Screen:**
    * Full-screen looping video.
    * Animated Glassmorphism "Thought Bubble".
    * **Confidence Score UI:** The percentage ring must be dynamically color-coded:
        * **Green:** > 80% (High Confidence)
        * **Amber:** 50% - 80% (Moderate Confidence)
        * **Red:** < 50% (Low Confidence/Ambiguous)
    * Expandable "Expert Insights" drawer.
    * "Share to Story" CTA.

---

## 6. Project Roadmap

### Phase 1: Prototype Refinement (Current)
* **UI Update:** Apply dynamic color logic to the Confidence Score ring.
* Finalize System Instructions for Gemini.
* Setup Firebase/GCP project structure.

### Phase 2: MVP Development (3-4 Weeks)
* Implement Video Capture logic.
* Connect Backend Cloud Function to Vertex AI.
* Integrate StoreKit 2 for "Pro" features.

### Phase 3: Launch & Iteration
* Beta testing with limited users.
* LinkedIn/Social Media marketing campaign.

---

## 7. Future Enhancements (Post-MVP)
* **Haptic & Audio Completion Signals:** Implementation of high-intensity haptic buzz and audio "ping" upon recording completion (to be resolved after technical limitations with AVFoundation are addressed).
* **Advanced Mood Analytics:** Week-over-week trends for cat behavior.