import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/app_logger.dart';

/// Render-to-PNG + share-sheet helper for the user-shareable cards
/// (Track session, Battle, Streak).
///
/// Card widgets are normal Flutter widgets — they're rendered headlessly
/// at an explicit logical size, then captured into a PNG via
/// `RenderRepaintBoundary.toImage`. The bytes are written to the cache
/// dir so the OS share sheet can attach them as files (the only path
/// `share_plus` accepts for image attachments).
class ShareCardService {
  ShareCardService._();

  /// Render [widget] off-screen at [logicalSize] (logical pixels) and
  /// return PNG bytes captured at [pixelRatio].
  ///
  /// Caveats:
  ///   • The widget is built outside the host's widget tree, so any
  ///     `InheritedWidget` it needs (Theme, MediaQuery, Directionality)
  ///     must be wrapped by the caller — see `_wrap` for what we add.
  ///   • Network images don't paint until they've loaded; the helper
  ///     pumps a brief settle delay so attached photos and remote tiles
  ///     have a chance to land before we capture.
  static Future<Uint8List> renderToPng({
    required Widget widget,
    required Size logicalSize,
    double pixelRatio = 3.0,
    Duration settleDelay = const Duration(milliseconds: 350),
  }) async {
    final boundary = RenderRepaintBoundary();
    final view = WidgetsBinding.instance.platformDispatcher.views.first;

    final renderView = RenderView(
      view: view,
      configuration: ViewConfiguration(
        logicalConstraints: BoxConstraints.tight(logicalSize),
        devicePixelRatio: pixelRatio,
      ),
      child: RenderPositionedBox(
        alignment: Alignment.center,
        child: boundary,
      ),
    );

    final pipelineOwner = PipelineOwner();
    final buildOwner = BuildOwner(
      focusManager: FocusManager(),
      onBuildScheduled: () {},
    );

    pipelineOwner.rootNode = renderView;
    renderView.prepareInitialFrame();

    final wrapped = _wrap(widget: widget, logicalSize: logicalSize);
    final element = RenderObjectToWidgetAdapter<RenderBox>(
      container: boundary,
      child: wrapped,
    ).attachToRenderTree(buildOwner);

    buildOwner.buildScope(element);
    buildOwner.finalizeTree();

    pipelineOwner.flushLayout();
    pipelineOwner.flushCompositingBits();
    pipelineOwner.flushPaint();

    // Give network images a chance to land. NetworkImage's load
    // operation is async — without this delay the captured PNG would
    // render placeholders for the photo background.
    if (settleDelay > Duration.zero) {
      await Future.delayed(settleDelay);
      buildOwner.buildScope(element);
      buildOwner.finalizeTree();
      pipelineOwner.flushLayout();
      pipelineOwner.flushCompositingBits();
      pipelineOwner.flushPaint();
    }

    final image = await boundary.toImage(pixelRatio: pixelRatio);
    final byteData =
        await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (byteData == null) {
      throw StateError('renderToPng: toByteData returned null');
    }
    return byteData.buffer.asUint8List();
  }

  /// Persist [bytes] to the cache directory under [filename] and return
  /// the resulting absolute path. Overwrites any existing file with
  /// the same name.
  static Future<String> savePngToCache(
    Uint8List bytes, {
    required String filename,
  }) async {
    final dir = await getTemporaryDirectory();
    final shareDir = Directory('${dir.path}/share_cards');
    if (!await shareDir.exists()) {
      await shareDir.create(recursive: true);
    }
    final file = File('${shareDir.path}/$filename');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// Hand a list of PNG paths to the native share sheet with the given
  /// caption [text]. Each path must already exist on disk.
  static Future<void> shareFiles(
    List<String> paths, {
    String? text,
  }) async {
    if (paths.isEmpty) return;
    try {
      await Share.shareXFiles(
        paths.map((p) => XFile(p)).toList(),
        text: text,
      );
    } catch (e, s) {
      AppLogger.session.e('shareCard:shareFailed',
          fields: {'count': paths.length}, error: e, stack: s);
      rethrow;
    }
  }

  /// Save [bytes] straight to the device's Photos / Gallery. Requests
  /// gallery access on first call; the OS prompt is one-shot per app
  /// install on both iOS and Android. Returns true on success.
  static Future<bool> saveToGallery(
    Uint8List bytes, {
    required String name,
  }) async {
    try {
      final hasAccess = await Gal.hasAccess(toAlbum: false);
      if (!hasAccess) {
        final granted = await Gal.requestAccess(toAlbum: false);
        if (!granted) return false;
      }
      // `gal` writes bytes directly to Photos on iOS, MediaStore on
      // Android — no manual filesystem copy needed.
      await Gal.putImageBytes(bytes, name: name);
      return true;
    } catch (e, s) {
      AppLogger.session.e('shareCard:saveToGalleryFailed',
          error: e, stack: s);
      return false;
    }
  }

  /// Attempt to hand [imagePath] off to Instagram as a Story sticker.
  ///
  /// Instagram's documented flow is:
  ///   • Android — an ACTION_SEND intent with `com.instagram.android`
  ///     as the target package and `com.instagram.share.ADD_TO_STORY`
  ///     as the action;
  ///   • iOS     — the `instagram-stories://share?source_application=...`
  ///     URL scheme after copying the image to the shared UIPasteboard.
  ///
  /// Cross-platform we take the simpler path — attempt the
  /// `instagram-stories://share` URL scheme via `url_launcher`. If
  /// Instagram isn't installed / the scheme isn't registered, the
  /// launch returns false and we fall back to the standard share
  /// sheet, which almost always has an "Instagram Story" option too.
  static Future<bool> tryOpenInstagramStories(String imagePath) async {
    try {
      final uri = Uri.parse('instagram-stories://share');
      final ok = await canLaunchUrl(uri);
      if (!ok) return false;
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e, s) {
      AppLogger.session.e('shareCard:igStoriesLaunchFailed',
          error: e, stack: s);
      return false;
    }
  }

  /// Wrap [widget] in the inherited-widget shims any card needs to
  /// render correctly outside the host tree. We do NOT include the
  /// app's Theme on purpose — share cards style themselves explicitly
  /// (a violet card shared from light mode should still look correct).
  static Widget _wrap({
    required Widget widget,
    required Size logicalSize,
  }) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: MediaQueryData(size: logicalSize),
        child: SizedBox(
          width: logicalSize.width,
          height: logicalSize.height,
          child: widget,
        ),
      ),
    );
  }
}
