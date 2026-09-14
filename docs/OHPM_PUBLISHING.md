# Publishing `@openharmony/firebase` to OHPM

The SDK lives in `firebase/` and is written as an ordinary OHPM library package, so it can
be shared across OpenHarmony apps (and teams) exactly like any commercial Firebase SDK.

## Package metadata

`firebase/oh-package.json5`:

```json5
{
  name: '@openharmony/firebase',
  version: '1.0.0',
  main: './src/main/ets/index.ets',
  dependencies: {}
}
```

Everything public re-exports from `firebase/src/main/ets/index.ets`.

## Local development (this repo)

`entry/oh-package.json5` references the package by relative path — no publish needed:

```json5
{
  dependencies: {
    '@openharmony/firebase': 'file:../firebase',
  }
}
```

##### Run `ohpm install` (or let DevEco Studio do it) — `file:` dependencies are copied
into `oh_modules/` like any other package and linters/compilers resolve `@openharmony/firebase`
imports transparently.

## Publishing

```bash
# 1. Bump version in firebase/oh-package.json5
# 2. From firebase/ run:
ohpm publish                    # interactive: prompts for token/OTP
# or non-interactive:
ohpm publish --allow-development --force --token <token>
```

Prerequisites:
- an OHPM account + token (`ohpm login`), 
- optional `oh-package.json5` `publishConfig` block if your org uses a private registry.

## Consumption

```bash
# inside any OpenHarmony app:
ohpm install @openharmony/firebase   # registry version
# then:
import { FirebaseApp } from '@openharmony/firebase';
```

## Keeping it dual-mode

- Pure-ArkTS surface (all REST services + the `TlsSocketTransport` FCM channel) ships in
  the OHPM package as-is.
- The native NAPI bridge (`firebase_native/`) is intentionally **not** part of the
  published package: device toolchains differ. Compile it into your HAP when you want the
  C++ TLS path; the SDK auto-detects the bridge at runtime (see the `FcmClient` docs).
- Never add Google service-account private keys to the package; keep Admin-key flows on
  your proxy server.