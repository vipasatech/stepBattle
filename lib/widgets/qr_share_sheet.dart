import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../config/colors.dart';

/// Bottom sheet that shows the user's [userCode] as a scannable QR
/// plus copy / share affordances.
///
/// The QR encodes the plain-text code (`#U4X92`) — the receiver's
/// scanner shows the text, they paste it into the friend-search bar.
/// No deep-link infrastructure is required for MVP; a stepbattle://
/// scheme handler can be layered on later without changing this sheet.
Future<void> showQrShareSheet(
  BuildContext context, {
  required String userCode,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    useRootNavigator: true,
    // Content is taller than half the viewport on small phones — need
    // `isScrollControlled` so the sheet expands to fit rather than
    // clipping the Share/Copy row.
    isScrollControlled: true,
    builder: (_) => _QrShareSheet(userCode: userCode),
  );
}

class _QrShareSheet extends StatelessWidget {
  final String userCode;
  const _QrShareSheet({required this.userCode});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF14141A).withValues(alpha: 0.72),
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(24),
          ),
          border: Border(
            top: BorderSide(
              color: AppColors.primary.withValues(alpha: 0.5),
              width: 1.5,
            ),
          ),
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Share my code',
                  style: TextStyle(
                    color: Colors.white,
                    fontFamily: 'Manrope',
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 14),
                // White card holds the QR so any camera can read it.
                // Sized so the whole sheet stays under 60% of viewport
                // height on typical phones (previously the Copy/Share
                // row overflowed by ~50 px).
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: QrImageView(
                    data: userCode,
                    version: QrVersions.auto,
                    size: 170,
                    gapless: true,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Color(0xFF141419),
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Color(0xFF141419),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  userCode,
                  style: const TextStyle(
                    color: Colors.white,
                    fontFamily: 'Space Grotesk',
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Friends can scan or type this code to add you.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontFamily: 'Manrope',
                    fontSize: 11.5,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _copy(context),
                        icon: const Icon(Icons.copy, size: 15),
                        label: const Text('Copy'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.2),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => _share(context),
                        icon: const Icon(Icons.ios_share, size: 15),
                        label: const Text('Share'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: userCode));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied $userCode'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _share(BuildContext context) async {
    await Share.share(
      'Add me on StepBattle: $userCode',
      subject: 'My StepBattle code',
    );
  }
}
