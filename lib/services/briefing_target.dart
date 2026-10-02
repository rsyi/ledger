/// The day a nightly briefing plans for, from when it was posted: before
/// noon → that day, otherwise the next day (coach_nightly.sh's TARGET
/// rule). Briefing rows are stamped with the POSTING day in `date`, so
/// idempotence checks must compare on this, not on `date`.
DateTime briefingTargetDay(DateTime postedAt) {
  final day = DateTime(postedAt.year, postedAt.month, postedAt.day);
  return postedAt.hour < 12 ? day : day.add(const Duration(days: 1));
}
