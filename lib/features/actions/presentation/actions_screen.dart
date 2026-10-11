import 'package:flutter/material.dart';

import '../../actuators/presentation/actuators_screen.dart';
import '../../context/presentation/context_home_screen.dart';

/// Actions tab — automation rules + actuator dispatch queue + the
/// context/entities operational view under one bottom-nav destination.
class ActionsScreen extends StatelessWidget {
  const ActionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const DefaultTabController(
      length: 2,
      child: Column(
        children: [
          TabBar(tabs: [
            Tab(icon: Icon(Icons.toggle_on_outlined),
                text: 'Automations & actuators',),
            Tab(icon: Icon(Icons.insights_outlined),
                text: 'Context & entities',),
          ],),
          Expanded(
            child: TabBarView(children: [
              ActuatorsScreen(),
              ContextHomeScreen(),
            ],),
          ),
        ],
      ),
    );
  }
}
