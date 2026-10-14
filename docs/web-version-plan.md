# Dawwen Web: Plan

Written for: an engineer or AI coding agent with no prior context, who will build the web version. Read this before writing code.

## 1. Goal

Build a browser-based version of Dawwen, a lecture recorder with live transcription, live translation to Arabic, summaries, and Q&A over the transcript. It should work on any device with a modern browser (iPad, Android, Windows, Mac).

Phase 1 is for one user, the owner. Phase 2 opens invite-only access to a few other students. Do not build public sign-up in either phase.

## 2. What already exists (reuse, do not rewrite)

The native iPad app lives in `Dawwen/` (Swift, iPadOS 26.0+). Its features and their current implementations:

- Live transcription: Apple on-device speech for English; Soniox real-time for other languages or when chosen (`Dawwen/Transcription/`).
- Live translation to Arabic: Apple Translation, on-device (`Dawwen/Translation/`).
- Post-lecture translation refinement and summaries: Claude, called through the gateway or directly (`Dawwen/Translation/TranslationRefiner.swift`, `Dawwen/Summarization/`).
- "Ask the lecture": small Claude calls over the stored transcript.
- Course vocabulary and glossary: passed to the transcriber and the translator.
- Export: TXT, Markdown with summary, SRT (original and translated), M4A audio.

The backend gateway lives in `server/gateway/` (FastAPI, deployed on AWS Lambda with SAM). It already provides:

- `POST /v1/claude/messages`: Claude proxy with daily and monthly spend caps (`server/gateway/app/claude.py`).
- `POST /v1/soniox/temp-key`: short-lived Soniox keys so the client never holds the permanent key (`server/gateway/app/soniox.py`).
- Per-device token auth, where the server stores only a SHA-256 hash (`server/gateway/app/auth.py`).
- Backup upload and download URLs on S3 (`server/gateway/app/backup.py`).
- A job queue for the optional home worker (`server/gateway/app/jobs.py`).

Reuse the gateway's patterns (spend caps, temp keys, hashed tokens, SAM template). Replace device tokens with real user accounts in Phase 2.

## 3. Phase 1 scope (single user, web)

Must have:

1. Sign-in for one account (email magic link or passkey; choose the simplest option that works).
2. Start, pause, and stop a recording from the browser. Show elapsed time and a clear "recording" indicator.
3. Live transcript from Soniox over WebSocket, using a temporary key from the server.
4. Live translation to Arabic. Use a cloud translation provider (see open decision D2).
5. Lecture library: list, open, rename, delete.
6. Lecture view: transcript with timestamps, playback of the recorded audio, and a search box.
7. Summary in Arabic or English through Claude, requested by the user.
8. "Ask the lecture": Claude answers from the stored transcript only.
9. Export: TXT, Markdown with summary, SRT.
10. Spend caps and a budget alert on AWS from day one.

Out of scope for Phase 1:

- Native mobile apps.
- Screen capture or slide OCR (the camera-based slide capture stays native-only).
- Speaker diarization beyond what Soniox returns by default.
- On-device models of any kind.
- Offline mode.
- Courses and folders.
- Payments.

## 4. Known web limits to design around

- Recording: the browser must keep the page in the foreground. On iOS Safari, recording stops or pauses when the screen locks or the tab goes to the background. Tell the user this in the UI. Save audio in chunks (for example every 10 seconds) to IndexedDB so a crash or tab close loses at most a few seconds.
- Microphone access needs HTTPS and a user gesture.
- Recovery: on next open, if an unfinished recording exists in IndexedDB, offer to finish or export it.
- Audio size: a 4-hour recording is large. Use compressed audio (Opus in WebM or M4A where supported) and upload chunks to S3 with presigned URLs, not through the Lambda request body.

## 5. Architecture (proposed defaults; confirm the open decisions)

- Frontend: a single-page web app. Default: React with Vite, or plain TypeScript if we want less framework. Mobile-first layout, RTL support for Arabic text.
- Backend: extend `server/gateway/` with user accounts, a lectures API, and presigned upload URLs. Keep FastAPI and SAM.
- Storage: DynamoDB or SQLite-on-S3 for metadata (the gateway already has a store abstraction; check `store.py`); S3 for audio and exports.
- Realtime transcript: the browser opens the Soniox WebSocket directly with a temporary key. Transcript chunks are also saved through the API so a reload does not lose them.
- Background work (refinement, summaries): the API creates a job, a worker runs it, the result is saved and the UI polls or receives a push. Start with the simplest option that works (polling).

Each Claude and translation call must check the spend cap before it runs and log its cost.

## 6. Privacy and consent

- The native app states that audio and text stay on the device, except for the services the user chooses. The web version sends audio to our server and to Soniox. Say this clearly in the UI and the privacy policy. Do not reuse the old wording.
- Store audio and transcripts only for the signed-in user. Provide delete for a lecture and for the whole account.
- Recording lectures may require the lecturer's consent or the university's policy. The UI must remind users of this. Do not add features that hide recording.
- Do not log transcript text or audio content in application logs.
- Keys (Anthropic, Soniox, translation provider) stay on the server or in SSM Parameter Store. The browser never sees them.

## 7. Cost controls

- Known costs: Soniox real-time about 0.12 USD per hour of audio (verify on the pricing page before budgeting). Claude costs depend on the model; the gateway already prices Haiku, Sonnet, and Opus.
- Set an AWS budget alert (the existing template creates one at 5 USD).
- Keep the existing per-day and per-month Claude caps. Add a per-user cap in Phase 2.
- Show the user an estimate before they start a long summary or refinement.

## 8. Phase 2 (invite-only, a few users)

- Replace device tokens with accounts and invite codes.
- Per-user spend caps and per-user storage limits.
- Data isolation tested: user A must never read user B's lectures. Add a test for it.
- Account deletion and data export.
- A written privacy policy and terms of use.
- Usage dashboard for the owner.

## 9. Testing

- Gateway: extend `server/gateway/tests/` (pytest, moto for AWS). Cover auth, spend caps, presigned URLs, and data isolation.
- Frontend: unit tests for the recorder's chunking and recovery logic, and an end-to-end test for start, stop, and open-library flows in Chrome and Safari.
- Manual: a 30-minute recording in Chrome and on iOS Safari, including a screen lock, and a tab reload during recording.
- CI: add a web build job next to the existing gateway and iOS jobs in `.github/workflows/ci.yml`.

## 10. Open decisions (confirm before coding)

- D1. Frontend stack: React + Vite, or plain TypeScript?
- D2. Translation provider for the web: Google Cloud Translation, DeepL, Azure, or Claude? Compare cost and Arabic quality on the same 200 sentences before choosing.
- D3. Hosting for the frontend: S3 + CloudFront, or Amplify Hosting?
- D4. Auth: magic link (email) or passkeys?
- D5. Region: `me-central-1` or `eu-central-1`. The current templates default to `eu-central-1`.
- D6. Do we keep the native iPad app as the main product, with the web version as a second client? The gateway serves both.

## 11. Definition of done for Phase 1

- The owner can record a 2-hour lecture in Chrome on a laptop and in Safari on an iPad, see a live Arabic translation, and get a summary afterwards.
- A refresh or crash during recording loses at most 10 seconds of audio.
- Monthly cost for one user is measured and under the budget alert.
- The gateway tests and the web build pass in CI.
