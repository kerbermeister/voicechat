import 'package:flutter/painting.dart';

// Prefer platform colour glyphs: Inter contains a monochrome heart of its own.
const emojiStyle = TextStyle(
  fontFamily: 'Apple Color Emoji',
  fontFamilyFallback: ['Noto Color Emoji', 'Segoe UI Emoji', 'sans-serif'],
);
