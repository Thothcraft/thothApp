import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// WiFi Sensing — how CSI/radio evidence works in Thothcraft.
class WifiDeviceScreen extends StatelessWidget {
  const WifiDeviceScreen({super.key});

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
      appBar: AppBar(title: const Text('WiFi Sensing')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Passive environmental sensing from WiFi signals — no '
            'camera or microphone involved.',
            style: TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 20),
          _row(
              Icons.wifi_tethering,
              'Radio scans',
              'Nodes and this phone uplink radio.wifi.v1 observations '
                  '(BSSID, RSSI) used for device presence and indoor '
                  'location. They land as wifi sensors in your context.'),
          _row(
              Icons.multiple_stop,
              'CSI link sensing',
              'Nodes on a shared WiFi channel expose Channel State '
                  'Information (radio.csi.v1): amplitude and phase per '
                  'subcarrier. People moving between two radios perturb '
                  'the link — that fluctuation drives occupancy and '
                  'through-wall motion estimates.'),
          _row(
              Icons.scatter_plot_outlined,
              'Trilateration',
              'When two or more anchored nodes see the same emitter, '
                  'the radio map solves its position from RSSI; a single '
                  'sighting draws only a range ring — signal strength '
                  'alone cannot place a radio on the floor plan.'),
          const SizedBox(height: 8),
          FilledButton.icon(
            icon: const Icon(Icons.hub_outlined),
            label: const Text('Open the radio map'),
            onPressed: () => context.push('/context/relations'),
          ),
          const SizedBox(height: 24),
          const Text(
            'WiFi evidence is emitted only where a node or this app is '
            'actively sensing — check Settings → Sources for what this '
            'phone produces.',
            style: TextStyle(fontSize: 13, color: Colors.black54),
          ),
        ],
      ),
    );
  }
}
