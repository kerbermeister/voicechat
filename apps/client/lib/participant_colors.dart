import 'dart:math';
import 'package:flutter/material.dart';

const _nameHues = <double>[
  265,
  155,
  30,
  205,
  340,
  52,
  185,
  292,
  95,
  12,
  225,
  320,
];

/// Resolve palette collisions within a group, independently of member/event order.
Map<String, int> participantColorSlots(Iterable<String> userIds) {
  final ids = userIds.toSet().toList()..sort();
  final result = <String, int>{};
  final used = <int>{};
  for (final id in ids) {
    var hash = 0;
    for (final unit in id.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    var slot = hash % _nameHues.length;
    if (used.length >= _nameHues.length) {
      slot = used.length;
    } else {
      var bestDistance = -1.0;
      for (var offset = 0; offset < _nameHues.length; offset++) {
        final candidate = (hash + offset) % _nameHues.length;
        if (used.contains(candidate)) continue;
        final distance = used.isEmpty
            ? 180.0
            : used
                  .map((other) {
                    final delta = (_nameHues[candidate] - _nameHues[other])
                        .abs();
                    return min(delta, 360 - delta);
                  })
                  .reduce(min);
        if (distance > bestDistance) {
          slot = candidate;
          bestDistance = distance;
        }
      }
    }
    used.add(slot);
    result[id] = slot;
  }
  return result;
}

Color participantNameColor(int slot, Color background) {
  final hue = slot < _nameHues.length
      ? _nameHues[slot]
      : (slot * 137.508) % 360;
  final light = HSLColor.fromAHSL(1, hue, .68, .83).toColor();
  final dark = HSLColor.fromAHSL(1, hue, .65, .25).toColor();
  double contrast(Color foreground) {
    final a = foreground.computeLuminance();
    final b = background.computeLuminance();
    return a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
  }

  final lighten = contrast(Colors.white) >= contrast(Colors.black);
  var color = lighten ? light : dark;
  for (var step = 0; step < 20 && contrast(color) < 4.5; step++) {
    final hsl = HSLColor.fromColor(color);
    color = hsl
        .withLightness((hsl.lightness + (lighten ? .03 : -.03)).clamp(0.0, 1.0))
        .toColor();
  }
  return color;
}
