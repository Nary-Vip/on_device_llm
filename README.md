# on_dev_llm

A Flutter chat app that runs an LLM **on the device itself**, and falls back to
a cloud model only when the device can't reliably handle it.

## Problem

On-device LLMs are attractive — no per-token cost, works offline, nothing
leaves the phone — but a phone isn't a server: RAM is limited, batteries drain,
chips throttle under sustained load, and low-power mode kills background work.
A chat app that blindly always runs on-device will stall, crash, or overheat
the device the moment conditions aren't ideal. A chat app that always calls
the cloud gives up the whole point of running on-device in the first place.

This project explores a middle ground: **route each request to on-device or
cloud based on real device conditions**, transparently to the user, and
benchmark the two paths against each other so the trade-off (speed, quality,
cost) is measurable instead of assumed.

## How it works

- **`InferenceEngine`** — a common interface (`lib/core/interface`) implemented
  by both backends, so the rest of the app doesn't care which one is serving a
  given request.
- **`OnDeviceEngine`** (`lib/platform/on_device_engine.dart`) — runs a Gemma
  model fully on-device via platform channels:
  - Android → [LiteRT](https://ai.google.dev/edge/litert) (`gemma-4-E2B-it`)
  - iOS → [MediaPipe LLM Inference](https://ai.google.dev/edge/mediapipe/solutions/genai/llm_inference) (`Gemma3-1B-IT`, quantized `.task` model)

  Models are downloaded from Hugging Face on first launch and cached locally;
  `ModelLoadingScreen` shows download/load progress before handing off to chat.
- **`CloudEngine`** (`lib/engine/cloud_engine.dart`) — streams responses from
  the Gemini API (`generateContent` SSE) as the fallback/comparison backend.
- **`EngineRouter`** (`lib/core/engine_router.dart`) — the routing brain. Before
  every request it checks, in order:
  1. Is the on-device model loaded and ready?
  2. Is there enough free RAM (native platform channel, Android + iOS)?
  3. Is the device thermally throttling?
  4. Is the battery above the configured threshold (unless charging)?
  5. Is the OS in low-power mode?

  If any check fails, the request goes to the cloud instead. If the on-device
  engine throws mid-stream, the router transparently retries the same prompt
  on the cloud engine, so the user just sees a response — not an error.
- **Benchmark harness** (`lib/core/benchmark_harness.dart`,
  `lib/view/benchmark_screen.dart`) — runs a fixed prompt suite (short factual,
  math, explanation, structured list, creative writing) against a chosen
  backend and scores each response for correctness, repetition, length/format
  compliance, and instruction-following, then rolls that up into a letter
  grade alongside time-to-first-token and tokens/sec — so on-device vs. cloud
  can be compared on quality, not just speed.

## Screens

- `ModelLoadingScreen` — downloads/loads the on-device model, shows progress.
- `ChatScreen` — the main chat UI, routed through `EngineRouter`.
- `BenchmarkScreen` — runs and visualizes the benchmark suite (charts via `fl_chart`).

## Tech stack

Flutter + `flutter_bloc`, `sqflite` (local chat storage), `battery_plus` /
`device_info_plus` (device signal checks), `fl_chart` (benchmark charts),
`path_provider` (model file storage), native Kotlin/Swift platform channels
for RAM, thermal, and inference.

## Running it

```bash
flutter pub get
flutter run \
  --dart-define=API_KEY=<your Gemini API key>   # aistudio.google.com
  --dart-define=HF_TOKEN=<your Hugging Face token>  # for gated model downloads
```

- Get a free Gemini API key at [aistudio.google.com](https://aistudio.google.com).
- Get a Hugging Face access token at [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens)
  if the on-device model requires authentication to download.

> Note: never commit real tokens into source or `.vscode/launch.json` — pass
> them via `--dart-define` / local, untracked config instead.
