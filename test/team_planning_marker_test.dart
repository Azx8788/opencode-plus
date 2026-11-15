// Start-a-run requests are persisted as message records and parsed again
// after a restart. The product rename changed the first line of those
// messages, so the parser must keep recognising the line earlier builds
// wrote — otherwise a pending "Start a run" on an upgraded phone silently
// stops being a planning request.
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/state/team_planning.dart';

void main() {
  test('the current marker opens a planning request', () {
    expect(isTeamPlanningMarker(teamPlanningMarker), isTrue);
    expect(teamPlanningMarker, '[OpenCode Plus · Start a run]');
  });

  test('a marker written before the rename still opens one', () {
    expect(isTeamPlanningMarker('[OpenCode Mini · Start a run]'), isTrue);
    expect(isTeamPlanningMarker('  [OpenCode Mini · Start a run]  '), isTrue);
  });

  test('any other first line does not', () {
    expect(isTeamPlanningMarker('Objective: ship it'), isFalse);
    expect(isTeamPlanningMarker('[OpenCode Plus · Start a run] please'), isFalse);
    expect(isTeamPlanningMarker(''), isFalse);
  });

  test('a composed request starts with the current marker', () {
    final text = composeTeamPlanningMessage(
      objective: 'Ship the audit',
      supervision: TeamSupervision.balanced,
    );
    expect(text.split('\n').first, teamPlanningMarker);
    expect(isTeamPlanningMarker(text.split('\n').first), isTrue);
  });
}
