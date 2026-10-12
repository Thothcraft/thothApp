import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Legal Screen - Privacy Policy and Terms of Service.
/// The hosted documents are the authoritative copies.
class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key});

  static const _privacyUrl = 'https://thothcraft.com/privacy';
  static const _termsUrl = 'https://thothcraft.com/terms';

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy & Terms')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Privacy Policy',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          const Text(
            'Raw sensor data stays on your devices and nodes. BLE/Wi-Fi '
            'scans, IMU, GPS and audio evidence only leave the phone for '
            'your own Brain account when you enable them in Settings → '
            'Sources — every producer has an explicit toggle.',
            style: TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 32),
          const Text(
            'Terms of Service',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          const Text(
            'By using Thothcraft products and services you agree to run '
            'estimators and automations at your own responsibility — they '
            'can actuate real hardware (lights, locks, speakers) on your '
            'behalf.',
            style: TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: () => _open(_privacyUrl),
            child: const Text('Read Full Privacy Policy'),
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: () => _open(_termsUrl),
            child: const Text('Read Full Terms of Service'),
          ),
        ],
      ),
    );
  }
}
