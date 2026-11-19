// Foldable / dual-screen awareness via MediaQuery display features.

import 'dart:ui' show DisplayFeatureState, DisplayFeatureType;

import 'package:material_ui/material_ui.dart';

/// Hinge / fold state of the current window.
@immutable
class FoldInfo {
  const FoldInfo({
    this.hingeBounds,
    this.isHalfOpened = false,
    this.isSeparating = false,
    this.hingeAxis,
  });

  /// No hinge or fold in this window.
  static const FoldInfo none = FoldInfo();

  /// Hinge/fold bounds in window coordinates (logical pixels), or `null`.
  final Rect? hingeBounds;

  /// Device is half-opened (book or tabletop posture).
  final bool isHalfOpened;

  /// Content should not straddle the hinge: a physical hinge, or a fold that
  /// is half-opened.
  final bool isSeparating;

  /// Direction the hinge runs: [Axis.vertical] splits left/right,
  /// [Axis.horizontal] splits top/bottom (tabletop). `null` without a hinge.
  final Axis? hingeAxis;

  bool get hasHinge => hingeBounds != null;

  /// Tabletop posture: horizontal fold, half-opened.
  bool get isTabletop => isHalfOpened && hingeAxis == Axis.horizontal;

  /// Book posture: vertical fold, half-opened.
  bool get isBook => isHalfOpened && hingeAxis == Axis.vertical;

  @override
  bool operator ==(Object other) =>
      other is FoldInfo &&
      other.hingeBounds == hingeBounds &&
      other.isHalfOpened == isHalfOpened &&
      other.isSeparating == isSeparating &&
      other.hingeAxis == hingeAxis;

  @override
  int get hashCode =>
      Object.hash(hingeBounds, isHalfOpened, isSeparating, hingeAxis);

  @override
  String toString() =>
      'FoldInfo(hinge: $hingeBounds, halfOpened: $isHalfOpened, '
      'separating: $isSeparating, axis: $hingeAxis)';
}

extension FoldX on BuildContext {
  /// Hinge / fold info for this window. Only folds and hinges count;
  /// cutouts are ignored.
  FoldInfo get fold {
    for (final feature in MediaQuery.displayFeaturesOf(this)) {
      if (feature.type != DisplayFeatureType.hinge &&
          feature.type != DisplayFeatureType.fold) {
        continue;
      }
      final bounds = feature.bounds;
      final halfOpened = feature.state == DisplayFeatureState.postureHalfOpened;
      return FoldInfo(
        hingeBounds: bounds,
        isHalfOpened: halfOpened,
        isSeparating: feature.type == DisplayFeatureType.hinge || halfOpened,
        // A zero-width fold still has a direction: the longer side.
        hingeAxis: bounds.height >= bounds.width
            ? Axis.vertical
            : Axis.horizontal,
      );
    }
    return FoldInfo.none;
  }
}
