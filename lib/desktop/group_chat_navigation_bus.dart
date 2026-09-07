import 'dart:async';

/// Navigation event for the desktop group-chat content slot embedded in the
/// Chat tab (see HomePage._buildTabletLayout). Mirrors
/// [DesktopSettingsNavigationBus] / [MessageLocateBus]: feature code fires,
/// the shell-internal controller listens.
class GroupChatNavigationTarget {
  const GroupChatNavigationTarget.open(String this.groupChatId) : exit = false;
  const GroupChatNavigationTarget.exit() : groupChatId = null, exit = true;

  /// Group to show; null on [exit].
  final String? groupChatId;
  final bool exit;
}

class GroupChatNavigationBus {
  GroupChatNavigationBus._();

  static final GroupChatNavigationBus instance = GroupChatNavigationBus._();

  final StreamController<GroupChatNavigationTarget> _controller =
      StreamController<GroupChatNavigationTarget>.broadcast();

  Stream<GroupChatNavigationTarget> get stream => _controller.stream;

  /// Shows [groupChatId] in the desktop group-chat slot (switches the Chat
  /// tab content away from the single-chat view). No-op on mobile — mobile
  /// keeps pushing [GroupChatPage] as a route.
  void openGroupChat(String groupChatId) {
    _controller.add(GroupChatNavigationTarget.open(groupChatId));
  }

  /// Hides the desktop group-chat slot and returns to the single-chat view.
  /// Every previously opened group stays mounted offstage, so all their
  /// in-flight rounds keep running.
  void exitGroupChat() {
    _controller.add(const GroupChatNavigationTarget.exit());
  }

  void dispose() => _controller.close();
}
