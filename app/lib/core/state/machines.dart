import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Explicit Connection Mode enum per D1 architecture.
enum ConnectionMode {
  standaloneOnDevice,
  companionConnected,
  companionDegradedOffline,
}

class ConnectionModeNotifier extends Notifier<ConnectionMode> {
  @override
  ConnectionMode build() {
    return ConnectionMode.standaloneOnDevice;
  }

  void setMode(ConnectionMode mode) {
    if (state != mode) {
      applyTransition(
        'ConnectionMode',
        'app_client',
        state.name,
        mode.name,
        reason: 'notifier_update',
      );
      state = mode;
    }
  }
}

final connectionModeProvider =
    NotifierProvider<ConnectionModeNotifier, ConnectionMode>(() {
  return ConnectionModeNotifier();
});

/// Canonical State Machine definitions from contracts/state-machines.json.
const Map<String, Map<String, dynamic>> _machines = {
  'DocumentLifecycle': {
    'initial': 'queued',
    'states': [
      'queued',
      'processing',
      'partially_readable',
      'paused',
      'interrupted',
      'ready',
      'failed',
      'unsupported',
      'deleted',
    ],
    'transitions': {
      'queued': ['processing', 'failed', 'deleted'],
      'processing': [
        'partially_readable',
        'ready',
        'paused',
        'interrupted',
        'failed',
        'unsupported',
        'deleted',
      ],
      'partially_readable': [
        'ready',
        'paused',
        'interrupted',
        'failed',
        'deleted',
      ],
      'paused': ['processing', 'deleted'],
      'interrupted': ['processing', 'deleted'],
      'ready': ['deleted'],
      'failed': ['queued', 'processing', 'deleted'],
      'unsupported': ['deleted'],
      'deleted': <String>[],
    },
    'forbidden': [
      {'from': 'ready', 'to': 'processing'},
      {'from': 'ready', 'to': 'queued'},
    ],
  },
  'CardUserState': {
    'initial': 'unseen',
    'states': ['unseen', 'viewed', 'saved', 'dismissed'],
    'transitions': {
      'unseen': ['viewed', 'saved', 'dismissed'],
      'viewed': ['saved', 'dismissed'],
      'saved': ['viewed', 'dismissed'],
      'dismissed': ['viewed', 'saved'],
    },
  },
  'CardSlotSynthesis': {
    'initial': 'absent',
    'states': ['absent', 'in_flight', 'ready', 'failed_cooldown'],
    'transitions': {
      'absent': ['in_flight'],
      'in_flight': ['ready', 'failed_cooldown'],
      'ready': ['absent'],
      'failed_cooldown': ['in_flight', 'absent'],
    },
  },
  'ConnectionMode': {
    'initial': 'standaloneOnDevice',
    'states': [
      'standaloneOnDevice',
      'companionConnected',
      'companionDegradedOffline',
    ],
    'transitions': {
      'standaloneOnDevice': [
        'companionConnected',
        'companionDegradedOffline',
      ],
      'companionConnected': [
        'standaloneOnDevice',
        'companionDegradedOffline',
      ],
      'companionDegradedOffline': [
        'standaloneOnDevice',
        'companionConnected',
      ],
    },
  },
};

bool canTransition(String machineName, String fromState, String toState) {
  if (fromState == toState) return true;
  final machine = _machines[machineName];
  if (machine == null) return false;

  final forbidden = machine['forbidden'] as List<dynamic>?;
  if (forbidden != null) {
    for (final f in forbidden) {
      if (f['from'] == fromState && f['to'] == toState) {
        return false;
      }
    }
  }

  final transitions = machine['transitions'] as Map<String, dynamic>?;
  final allowed = transitions?[fromState] as List<dynamic>?;
  return allowed != null && allowed.contains(toState);
}

String applyTransition(
  String machineName,
  String entityId,
  String fromState,
  String toState, {
  String reason = '',
}) {
  if (fromState == toState) return toState;

  if (canTransition(machineName, fromState, toState)) {
    debugPrint(
      '[Athena SM] sm=$machineName id=$entityId from=$fromState to=$toState'
      '${reason.isNotEmpty ? " reason='$reason'" : ""}',
    );
    return toState;
  }

  debugPrint(
    '[Athena SM Warning] sm=$machineName id=$entityId from=$fromState to=$toState'
    ' REJECTED: forbidden or invalid transition'
    '${reason.isNotEmpty ? " (reason: $reason)" : ""}',
  );
  return fromState;
}
