# Auto Source Detector

This build adds automatic public media-source detection for `streamType=web` pages.

How it works:
- Opens the configured web page in the protected WebView.
- Waits for client-side JavaScript to initialize.
- Scans public `<video>` / `<source>` elements and browser performance resource entries.
- Detects public HLS (`.m3u8`) and common progressive video URLs.
- Scores candidates and switches to the native video player when a strong HLS/video source is found.
- Leaves DASH (`.mpd`) inside WebView because the current `video_player` dependency does not provide DASH playback.
- Does not bypass DRM, authentication, subscriptions, or access controls.

Recommended Rotana URL format:
`https://rotana.net/ar/live#/live/rotana-comedy`

The detector is intentionally best-effort: websites can change their player architecture, use cross-origin media, DRM, blob URLs, or encrypted delivery that cannot be converted to a native public URL.

## Final detector hardening

The web-source path now uses additional public-source signals:

- DRM/EME detection via `requestMediaKeySystemAccess` (detection only; no DRM bypass or key extraction).
- Fetch/XHR URL observation for media/API requests exposed normally by the page.
- Existing DOM/video/iframe/performance detection remains enabled.
- Candidate validation happens before switching to the native player.
- If DRM is detected, the page stays in WebView rather than attempting native playback.
- If a validated native source fails during playback, the player falls back to WebView automatically.


## V3 Session State Machine

The WebView auto-source engine now uses a single session state machine instead of overlapping boolean flags. States include `loadingPage`, `webReady`, `discovering`, `candidateTrial`, `nativePlaying`, `nativeFailed`, `drmWebOnly`, and `webFallback`.

Safety gates include single-flight detection, per-session generation tokens, candidate evidence accumulation, native-attempt budget (2), failed-source quarantine, DRM WebView-only mode, and a real native playback proof before the hand-off is considered successful.
