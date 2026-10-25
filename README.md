# Athena

## 1. What is Athena?

Athena is a **mobile-first** AI deep-reading companion for iOS and Android. It keeps **100% of a book’s verbatim text** and, as you scroll, spawns grounded marginalia — `EMPIRICAL STUDY`, `CRITICAL DEBATE`, `HISTORICAL CONTEXT`, `CORE PARADOX` — anchored to exact quotes in the passage.

## 2. Using Athena on your phone (iOS & Android)

Point the app at the engine on your laptop. Same Wi-Fi: `http://<LAN-IP>:8000`. Off-network: any public tunnel URL you start yourself. Settings → **Server URL**.

**Android (`.apk`)**
- Local (Windows): `cd app && flutter build apk --release`
- Cloud: Actions workflow `mobile_release.yml` → artifact `Athena-Android-Release.apk`

**iOS (no Mac required)**
1. Sideload: download `Athena-iOS-Unsigned.ipa` from the same workflow; install with **Sideloadly** or **AltStore**.
2. Instant fullscreen web app: open the host URL in Safari → **Share** → **Add to Home Screen**.

The phone never uses `127.0.0.1` (that is the phone itself). Web on LAN/tunnel uses the page origin automatically.

## 3. Companion backend & layout

```bash
python scripts/run_athena.py
```

Serves Flutter UI + `/api/*` on **one origin** (`:8000`, also `:8080`). Health: `http://127.0.0.1:8000/api/health`.

```text
Athena/
├── app/        # Flutter client (iOS, Android, Web)
├── backend/    # FastAPI + ONNX edge AI
├── scripts/    # run_athena.py, verify_release.py
└── docs/       # ADRs and design notes
```

```bash
pytest backend/tests -q
cd app && flutter analyze lib && flutter test
python scripts/verify_release.py
```
