import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:airledger/services/coach_proposal_store.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('absent row id loads null (pending)', () async {
    expect(await CoachProposalStore.load('row-1'), isNull);
  });

  test('save/load round-trip with localIds', () async {
    await CoachProposalStore.save(
      'row-1',
      const CoachProposalState(
        status: CoachProposalStatus.scheduled,
        localIds: ['a', 'b'],
      ),
    );
    final st = await CoachProposalStore.load('row-1');
    expect(st!.status, CoachProposalStatus.scheduled);
    expect(st.localIds, ['a', 'b']);
  });

  test('overwrite moves scheduled -> undone', () async {
    await CoachProposalStore.save(
      'row-1',
      const CoachProposalState(
        status: CoachProposalStatus.scheduled,
        localIds: ['a'],
      ),
    );
    await CoachProposalStore.save(
      'row-1',
      const CoachProposalState(
        status: CoachProposalStatus.undone,
        localIds: [],
      ),
    );
    final st = await CoachProposalStore.load('row-1');
    expect(st!.status, CoachProposalStatus.undone);
    expect(st.localIds, isEmpty);
  });
}
