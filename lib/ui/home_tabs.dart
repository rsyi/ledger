/// Bottom-nav tabs of the shell (home_screen.dart) — one source of
/// order + labels, testable without the shell's bootstrap.
///
/// 2026-10-02: Today · Log · Week · Progress. The Plan tab is retired
/// (IA restructure): its phase timeline sits on Progress, its forecast
/// behind Progress' Weight / Strength rows, and the Program screen
/// opens from Today's "Full week" action + the Week tab's app-bar icon.
library;

import 'package:flutter/material.dart';

abstract final class HomeTabs {
  static const int today = 0;
  static const int log = 1;
  static const int week = 2;
  static const int progress = 3;

  /// Number of tabs (the NavigationBar's destination count).
  static const int count = 4;
}

/// The NavigationBar destinations, in [HomeTabs] index order.
const List<NavigationDestination> homeNavDestinations = [
  NavigationDestination(
    icon: Icon(Icons.today_outlined),
    selectedIcon: Icon(Icons.today),
    label: 'Today',
  ),
  NavigationDestination(
    icon: Icon(Icons.edit_note_outlined),
    selectedIcon: Icon(Icons.edit_note),
    label: 'Log',
  ),
  NavigationDestination(
    icon: Icon(Icons.calendar_view_week_outlined),
    selectedIcon: Icon(Icons.calendar_view_week),
    label: 'Week',
  ),
  NavigationDestination(
    icon: Icon(Icons.insights_outlined),
    selectedIcon: Icon(Icons.insights),
    label: 'Progress',
  ),
];
