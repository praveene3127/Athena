# Athena 🦉

> **Read deeply. Stay in context.**  
> *What if reading a book felt like doom-scrolling?*

Athena transforms dense, intimidating non-fiction books and academic papers into a frictionless, vertical, flow-state reading feed. It pairs 100% lossless source text fidelity with grounded, spoiler-shielded AI epiphanies and context cards.

---

## 📖 The Backstory: Why Athena?

We can all doom-scroll social feeds for 3 hours without breaking a sweat. The micro-chunked vertical momentum, instant feedback, and variable-reward epiphanies make vertical scrolling psychologically frictionless.

Yet opening a 400-page book or dense academic treatise often triggers friction:
* Static, intimidating walls of unbroken text.
* Forgotten historical figures, obscure technical terms, or missing empirical context.
* Heavy cognitive resistance that tempts readers to close the book and open a social media feed instead.

**The Athena thesis:**  
*What if we weaponized the addictive, low-friction mechanics of doom-scrolling for deep intellectual reading?*

Instead of brain-rot feeds or lazy AI summaries that destroy source nuances, Athena slices real books into a continuous, thumb-friendly vertical feed. Interleaved between reading paragraphs are spoiler-shielded context cards—revealing empirical studies, counterpoints, and philosophical paradoxes at the exact moment they matter. You find yourself scrolling chapter after chapter in deep flow state, having finished half a book without realizing it.

---

## ✨ Core Features

* 📱 **Doom-Scroll Feed Architecture**: Infinite vertical scroll through book passages without page-flipping friction.
* 🛡️ **Lossless Source Fidelity**: Every character from the original document is preserved verbatim in chronological order. We never summarize, paraphrase, or rewrite the author's words (`"".join(chunks) == canonical_text`).
* 💡 **Spoiler-Shielded AI Epiphanies**: Deep context cards (Empirical Studies, Critical Debates, Philosophical Paradoxes, Historical Cases) feature interactive tap-to-reveal spoilers (`||REVEAL||`) to spark curiosity before answering.
* 🦉 **Expressive Athena Guardian**: Athena's reactive owl companion displays adaptive expressions (thinking, deep focus, epiphanies, and sleepy when awaiting your API key).
* ⚡ **Zero-Keyword Document Bouncer**: Structural dominance classification inspects layout, sentences, and line typography. Never rejects real books quoting fake resumes, invoices, math, or exams for stories.
* 🔐 **Sovereign Privacy (BYOK)**: Runs on local ONNX embeddings (`bge-small-en-v1.5`) and allows you to bring your own API key (Gemini, Claude, OpenRouter, Groq, or local Ollama). Your personal books never leave your device.
* 🔍 **High-Res Original Page Inspector**: Tap any chunk to zoom into the exact original high-DPI page to verify equations, diagrams, and formatting.

---

## 🚀 How to Use Athena (Simply)

Using Athena takes less than 60 seconds:

```
┌─────────────────┐       ┌─────────────────┐       ┌─────────────────┐
│ 1. Awaken Athena│  ───> │ 2. Upload Book  │  ───> │ 3. Doom-Scroll  │
│  (Add API Key)  │       │   (PDF / EPUB)  │       │ (Deep Reading)  │
└─────────────────┘       └─────────────────┘       └─────────────────┘
```

1. **Awaken Athena**:
   - Open Athena in your browser or on your phone.
   - When Athena is asleep, tap **"Add API Key to Awaken Athena"**.
   - Paste your free Google Gemini API key (or OpenRouter / Groq / Claude / Ollama) and tap **Save**.
2. **Drop in a Book**:
   - Tap **"Upload PDF or EPUB"** (or click **"Try sample"** to test immediately).
   - Athena extracts the book, generates cryptographic SHA-256 chunk integrity proofs, and synthesizes grounded context cards.
3. **Scroll & Learn**:
   - Scroll effortlessly through continuous paper chunks.
   - Tap cyan context cards to expand empirical evidence and tap spoiler bars to test your intuition.

---

## 📦 One-Click App Downloads & Mobile Builds

Athena runs across **Android**, **iOS**, and **Web PWA**.

| Platform | Direct 1-Click Download | Build Method / Toolchain | Target Sideload / Install |
| :--- | :--- | :--- | :--- |
| **🤖 Android** | [**⬇️ Download Android APK (v0.1.1)**](releases/athena-release.apk) *(58.4 MB)* | `flutter build apk --release` | Direct install / Package Installer |
| **🍎 iOS** | [**⬇️ Download iOS IPA (v0.1.1)**](releases/athena-ios-release.ipa) *(1.2 MB)* | [xtool](https://github.com/xtool-org/xtool) (Linux/Win/Mac) or Xcode | [xtool install](https://github.com/xtool-org/xtool) / AltStore / TrollStore |
| **🌐 Web PWA** | [**Launch Web App (:8080)**](http://localhost:8080) | `flutter build web --release` | Add to Home Screen (100dvh PWA) |

---

### 🤖 Android (APK)

* **1-Click Download**:
  Download [**`releases/athena-release.apk`**](releases/athena-release.apk) directly.
* **Installation**:
  1. Transfer the `.apk` to your phone or download directly in your mobile browser.
  2. Open the file in your File Manager and select **Install** (enable *Allow from this source* if prompted).
* **Local Build**:
  ```bash
  cd app
  flutter build apk --release
  ```

---

### 🍎 iOS (Cross-Platform with xtool & IPA Sideloading)

Athena supports Xcode-free iOS development and builds via [**xtool**](https://github.com/xtool-org/xtool) — the cross-platform Xcode replacement for Linux, Windows (WSL), and macOS.

#### 1. Direct 1-Click IPA Download & Sideloading
* Download [**`releases/athena-ios-release.ipa`**](releases/athena-ios-release.ipa) directly.
* Install immediately on your iPhone or iPad using any sideloading tool:
  * **xtool**: `xtool install releases/athena-ios-release.ipa`
  * **TrollStore** (permanent, no revokes, iOS 14.0–17.0)
  * **AltStore / SideStore / Sideloadly** (macOS, Windows, or Linux)

#### 2. Building for iOS with xtool (Linux, Windows WSL, macOS)
You do not need a Mac or Xcode to build Athena for iOS. Athena includes pre-configured `xtool.yml` and `Package.swift`:

```bash
# 1. Install or run xtool (Linux / WSL / macOS)
curl -L -o xtool https://github.com/xtool-org/xtool/releases/download/1.23.0/xtool-x86_64.AppImage
chmod +x xtool

# 2. Configure xtool SDK & build iOS release
xtool setup
python tools/build_ios_xtool.py

# 3. Or deploy directly to a connected iPhone over USB:
cd app/ios
xtool dev
```

#### 3. Automated Cloud CI Builds (.github/workflows/ios-xtool.yml)
* Every push to `main` automatically runs `.github/workflows/ios-xtool.yml` on a Linux (`ubuntu-latest`) runner.
* `xtool` compiles the iOS application package and uploads `athena-ios-release.ipa` to GitHub Artifacts and Releases.
* Traditional macOS CI pipelines remain available in `.github/workflows/build.yml` and `codemagic.yaml`.

---

### 🌐 Web / Progressive Web App (PWA)

* Runs instantly in Safari, Chrome, Edge, or Firefox:
  ```bash
  cd app
  flutter build web --release
  ```
* Supports 100dvh viewport locking, safe-area insets (iPhone dynamic island and home bar), and offline PWA service worker caching.

---

## 🛠️ Architecture & Tech Stack

```
Athena Architecture:
┌────────────────────────────────────────────────────────┐
│               Flutter Front-End (App)                  │
│  - Riverpod State Management & GoRouter Navigation     │
│  - Scrollable Positioned Feed (paper reading chunks)   │
│  - Reactive Owl Avatar Engine (7 expressive states)    │
│  - BYOK Settings Sheet (Gemini, Claude, OpenRouter)    │
│  - High-Resolution Original PDF Zoom Inspector         │
└──────────────────────────▲─────────────────────────────┘
                           │ HTTP / REST API (:8000)
┌──────────────────────────▼─────────────────────────────┐
│                 FastAPI Python Backend                 │
│  - PyMuPDF Extraction & Deduplicated Column Ordering   │
│  - Lossless Chunker (SHA-256 Contiguous Verification)  │
│  - Zero-Keyword Document Bouncer (Structural Dominance)│
│  - FastEmbed ONNX Local Semantic Vector Engine         │
│  - Wikimedia Knowledge Engine & Bayesian Novelty Gate  │
│  - SQLite Database (WAL Mode + 5000ms Busy Timeout)    │
└────────────────────────────────────────────────────────┘
```

* **Frontend**: Flutter 3.24+, Dart, Riverpod, GoRouter, Dio.
* **Backend**: Python 3.12, FastAPI, Uvicorn, PyMuPDF, SQLite (WAL mode).
* **Local AI**: FastEmbed (`BAAI/bge-small-en-v1.5` ONNX runtime).
* **Cloud AI Providers**: Google Gemini, Anthropic Claude, OpenRouter, Groq, NVIDIA NIM, and local Ollama.

---

## 🧪 Verification & Release Quality

Athena is verified by an automated release test suite:
```bash
python verify_release.py
```
Guarantees 100% green compliance across:
1. Anti-slop static code audit (0 raw prints, 0 debug prints, 0 TODOs).
2. Scientific and technical compound word preservation.
3. API contract and context token security headers.
4. Pytest backend test suite (46 passed).
5. Flutter static analysis (0 issues) and widget test suite (all passed).
6. Lossless chunking invariant (`"".join(chunks) == source_text`) and exact-quote card anchoring.

---

## 📄 License

Athena is licensed under the [Apache License, Version 2.0](LICENSE).  
Copyright 2026 Athena Contributors.
