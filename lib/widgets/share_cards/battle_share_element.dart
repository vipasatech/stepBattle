/// The two draggable overlays on the Battle Status share card:
///   • [card]     — the transparent [BattleResultCard] with the tag,
///                  names, scores, progress bar, and XP footer.
///   • [wordmark] — the italic-bold `STEPBATTLE` label.
///
/// Hoisted out of `battle_status_share_sheet.dart` so both the sheet
/// (which manages selection) and `BattleStatusShareCard` (which
/// draws the preview outline) can reference the same type without
/// crossing a private-member boundary.
enum BattleShareElement { card, wordmark }
