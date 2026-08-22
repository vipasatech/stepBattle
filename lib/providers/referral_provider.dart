import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/referral_service.dart';

/// Singleton service. Cheap to build; no state.
final referralServiceProvider = Provider<ReferralService>((ref) {
  return ReferralService(Supabase.instance.client);
});
