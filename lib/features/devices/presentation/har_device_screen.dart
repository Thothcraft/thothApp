import 'package:flutter/material.dart';

/// Human Activity Recognition — where the IMU evidence comes from.
class HarDeviceScreen extends StatelessWidget {
  const HarDeviceScreen({super.key});

  Widget _row(IconData icon, String title, String body) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(body, style: const TextStyle(fontSize: 14)),
                ],
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Human Activity Recognition')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Activity (sit / stand / walk / sleep) needs an IMU on the '
            'body — a worn watch, or this phone in a pocket.',
            style: TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 20),
          _row(
              Icons.watch_outlined,
              'Watch IMU',
              'A paired watch streams accelerometer windows over BLE. '
                  'The watch.worn.v1 state says it is on a wrist; '
                  'activity.motion.v1 folds bursts into the activity '
                  'estimate.'),
          _row(
              Icons.smartphone_outlined,
              'Phone IMU + app state',
              'Phone motion (activity.motion.v1) plus app.focus.v1 '
                  '(what is on screen) lets the builder distinguish '
                  '"using phone" from "moving with phone".'),
          _row(
              Icons.bedtime_outlined,
              'Calibrated labels',
              'Upload labeled windows from a node (sleep, empty_room, '
                  '…) and the chat agent compares live descriptor stats '
                  'against YOUR baselines — no generic model needed.'),
          const SizedBox(height: 24),
          const Text(
            'IMU producers are gated by Settings → Sources. No IMU '
            'evidence in the window means activity questions are '
            'explicitly unanswerable — the assistant says so rather '
            'than guessing.',
            style: TextStyle(fontSize: 13, color: Colors.black54),
          ),
        ],
      ),
    );
  }
}
