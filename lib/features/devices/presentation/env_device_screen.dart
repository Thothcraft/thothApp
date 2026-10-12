import 'package:flutter/material.dart';

/// Environmental sensing — node-side ambient signals.
class EnvDeviceScreen extends StatelessWidget {
  const EnvDeviceScreen({super.key});

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
      appBar: AppBar(title: const Text('Environmental Monitoring')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Ambient readings come from sensors on your Thoth nodes — '
            'each node reports its sensor list, which appears in the '
            'radio-map scene.',
            style: TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 20),
          _row(
              Icons.thermostat,
              'Climate',
              'Temperature / humidity / pressure boards on a node '
                  'uplink as evidence keys and aggregate into the '
                  'descriptor stats the context builder reasons over.'),
          _row(
              Icons.mic_outlined,
              'Audio level',
              'Where a node carries a mic, audio level rides the same '
                  'descriptor stream as a field (mean/std) — a quiet room '
                  'supports the sleep/empty baselines, never raw audio '
                  'uploads.'),
          _row(
              Icons.sensors,
              'Radar micro-motion',
              'Radar-equipped nodes report SNR / range / fluctuation '
                  'fields; the occupancy calibration compares the live '
                  'window against your measured empty-room baseline.'),
          const SizedBox(height: 24),
          const Text(
            'Only sensors a node actually reports appear in '
            'capabilities — a question needing a sensor that is not '
            'producing is answered as unanswerable, not guessed.',
            style: TextStyle(fontSize: 13, color: Colors.black54),
          ),
        ],
      ),
    );
  }
}
