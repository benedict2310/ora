# Input Epic (I)

Alternative input methods beyond voice for Ora's overlay.

## Overview

Ora is voice-first, but not voice-only. The Input epic adds seamless text input as a fallback for situations where speaking isn't practical (meetings, libraries, late night). The key design principle is zero-friction mode switching: start speaking or start typing — Ora adapts.

## Stories

| ID | Title | Status | Priority |
|:---|:------|:-------|:---------|
| I.01 | [Text Input Mode](I.01-TEXT-INPUT-MODE.md) | 🚧 Not Started | P1 |
| I.02 | ASR Partial Pre-fill (planned) | 📋 Future | P2 |

> **I.02 (ASR Partial Pre-fill):** When switching from voice to text mode, pre-fill the text field with any ASR partial transcription already displayed. Deferred from I.01 to keep the initial implementation simple.

## Dependencies

```
O.07 Conversation Mode (✅ Complete)
         │
         ▼
    I.01 Text Input Mode
         │
         ▼
    I.02 ASR Partial Pre-fill
```
