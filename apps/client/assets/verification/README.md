# Verification emoji

The 64 Matrix SAS emoji are bundled as unmodified 128px Noto Emoji PNGs so
verification does not depend on a remote fallback font or platform emoji fonts.
File names use the Unicode code point; optional U+FE0F selects emoji presentation
and does not select a different image. The SDK still generates the SAS values.

Source: [googlefonts/noto-emoji v2.047](https://github.com/googlefonts/noto-emoji/tree/22e564626297b4df0a40570ad81d6c05cc7c38bd/png/128).
`sources.json` records every source filename and SHA-256. Copyright 2013 Google LLC.
Upstream README identifies image resources as Apache 2.0; that text is included
in `LICENSE-APACHE-2.0.txt`. Upstream root license is also retained verbatim in
`LICENSE.txt` (OFL 1.1). No country flag assets are used.

`flutter test test/device_verification_test.dart` checks all 64 SDK symbols have
distinct bundled images that decode at 128×128, and checks the phone dialog and
switch to the numeric SAS. Updating the SDK alphabet requires updating these
assets and their provenance together.
