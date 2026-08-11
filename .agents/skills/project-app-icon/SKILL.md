---
name: project-app-icon
description: Design, review, and integrate the Cairn vinyl-based Android launcher icon. Use when the user chooses icon colors, requests an icon concept or vector, asks to replace launcher assets, or wants icon visual QA.
---

# Project App Icon

This skill turns an approved vinyl/record concept and exact user-provided colors into a vector source and Android launcher assets. Keep design decisions explicit: do not choose final colors, geometry, typography, or background treatment without user approval.

## Workflow

1. Read `design/app-icon-color-playground.html` and preserve the user's selected hex values.
2. Before implementation, present the proposed mark, its geometry, color roles, and launcher-background behavior for approval. Treat the user's response as the design contract.
3. Create the canonical icon as an SVG or other repo-native vector source. Keep the mark simple, centered, legible at 48dp, and free of album artwork or tiny text.
4. Render the approved vector to the Android density assets under `android/app/src/main/res/mipmap-*`. Preserve the existing manifest application id and icon resource name unless the user explicitly approves a rename.
5. Inspect the source vector and at least one rendered launcher image. Check transparent edges, contrast, visual centering, and recognizability at small size.
6. Run `flutter analyze` and `flutter build apk --debug` when the environment permits. Report exact limitations; do not imply device verification without installing and testing it.

## Design constraints

- The current app uses built-in Material `Icons.album` and `Icons.album_outlined`; those are references only, not reusable image files.
- The current Android launcher icon is the default Flutter PNG set. Replace it only after the new vector is approved.
- Prefer SVG/vector editing and deterministic rasterization for a launcher icon. Do not use AI raster generation for the final icon unless the user explicitly requests a bitmap style.
- Keep user-selected colors as literal six-digit hex values in the playground and any approved vector source.
- Do not silently add icon-generation dependencies or codegen. If a tool is needed, explain the dependency and its maintenance cost first.

## Decision gate

Before changing launcher assets, ask for explicit approval of:

- the record silhouette and center-label treatment;
- the exact hex values and which role each color fills;
- whether the icon is flat, outlined, gradient, or transparent-background;
- whether adaptive launcher foreground/background treatment is required.

Record approved choices in the active project tracking artifact when one exists. If the requested design cannot be represented cleanly as a small vector, stop and explain the trade-off before implementation.
