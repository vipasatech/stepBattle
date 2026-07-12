import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:fluttermoji/fluttermoji.dart';

import '../config/colors.dart';
import 'avatar_circle.dart';

/// Renders a circular avatar for a user, preferring their fluttermoji
/// character spec when set and falling back to the URL / initials
/// [AvatarCircle] otherwise.
///
/// * [config] — the JSONB value from `profiles.avatar_config` (or a
///   deserialised copy of it). When null, we fall back to
///   [imageUrl] + [initials] just like an ordinary [AvatarCircle].
/// * [imageUrl] / [initials] — the current avatar_url + initials
///   fallback used everywhere else in the app. Only used when
///   [config] is null.
/// * [radius] — same semantics as [AvatarCircle.radius].
///
/// Why we duplicate the FluttermojiCircleAvatar rendering path:
///   • fluttermoji's built-in widget always reads from the LOCAL
///     SharedPreferences store (i.e. it can only render the signed-
///     in user's own avatar).
///   • Leaderboards, map clusters, and friend rows need to render
///     OTHER users' avatars from their per-row `avatar_config`
///     column. So we hand-render the SVG here off the passed-in
///     [config] map using [FluttermojiFunctions.decodeFluttermojifromString].
class FluttermojiAvatar extends StatelessWidget {
  final Map<String, dynamic>? config;
  final String? imageUrl;
  final String initials;
  final double radius;
  final Color? borderColor;
  final double borderWidth;

  const FluttermojiAvatar({
    super.key,
    required this.config,
    required this.imageUrl,
    required this.initials,
    this.radius = 20,
    this.borderColor,
    this.borderWidth = 1.5,
  });

  @override
  Widget build(BuildContext context) {
    // Character avatar path — decode the config to an SVG string and
    // render it inside a circle-clipped container.
    if (config != null) {
      final svg = FluttermojiFunctions()
          .decodeFluttermojifromString(jsonEncode(config));
      return Container(
        width: radius * 2,
        height: radius * 2,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.surfaceContainerHigh,
          border: borderColor != null
              ? Border.all(color: borderColor!, width: borderWidth)
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: radius * 2,
            height: radius * 2,
            child: SvgPicture.string(svg),
          ),
        ),
      );
    }

    // Legacy path — image URL with initials fallback.
    return AvatarCircle(
      radius: radius,
      imageUrl: imageUrl,
      initials: initials,
      borderColor: borderColor ?? Colors.transparent,
      borderWidth: borderColor != null ? borderWidth : 0,
    );
  }
}
