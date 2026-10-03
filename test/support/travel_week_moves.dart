// The live `program_moves` rows for the week of Mon 2026-10-05 (travel
// Wed–Sat, packed into Mon/Tue) — 11 moves + 16 skips, mirrored from
// `dart run tool/missed_work.dart --date 2026-10-05` on 2026-10-02.
import 'package:airledger/services/program_moves.dart';

DateTime _d(int day) => DateTime(2026, 10, day);

const travelNote = 'travel Wed–Sat — packed into Mon/Tue';

List<ProgramMove> travelWeekMoves() {
  var n = 0;
  ProgramMove move(String item, int from, int to) => ProgramMove(
        id: 'mv${n++}',
        to: _d(to),
        from: _d(from),
        item: item,
        period: 'AM',
        source: 'manual',
        createdAt: DateTime(2026, 10, 2, 9, n),
        note: travelNote,
      );
  ProgramMove skip(String item, int day, [String extra = '']) => ProgramMove(
        id: 'sk${n++}',
        to: _d(day),
        from: _d(day),
        item: item,
        source: skipSource,
        createdAt: DateTime(2026, 10, 2, 10, n),
        note: extra.isEmpty ? 'travel Wed–Sat' : 'travel Wed–Sat — $extra',
      );
  return [
    move('Norwegian', 6, 11),
    move('Bench heavy', 7, 5),
    move('Bench back-offs', 7, 5),
    move('Pull-ups', 7, 5),
    move('Deadlift heavy', 9, 6),
    move('Deadlift back-offs', 9, 6),
    move('RDL or leg curl', 9, 6),
    move('OHP heavy', 10, 5),
    move('OHP back-offs', 10, 5),
    move('Seated cable row', 10, 6),
    move('Face pulls', 10, 6),
    skip('Bench volume', 5,
        'Wed bench top + back-offs moved to Mon cover it'),
    skip('Triceps extension', 5, 'trimmed from the packed Mon session'),
    skip('Squat volume', 7),
    skip('OHP volume', 7),
    skip('Muscle-ups', 8),
    skip('Banded muscle-ups', 8),
    skip('Handstand practice', 8),
    skip('Front-lever up-downs', 8),
    skip('Hanging leg raise', 8),
    skip('Dips', 8),
    skip('EZ curls', 8),
    skip('Bench volume', 9, 'bench covered Mon'),
    skip('Climb — LIGHT session', 9),
    skip('Pull-ups', 10, 'pull-ups done Mon'),
    skip('Lateral raise', 10, 'laterals done Mon'),
    skip('External rotations', 10),
  ];
}
