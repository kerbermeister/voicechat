import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';

Future<ui.Image> videoPoster(RenderRepaintBoundary boundary, String source) =>
    boundary.toImage(pixelRatio: math.min(1.5, 330 / boundary.size.width));
