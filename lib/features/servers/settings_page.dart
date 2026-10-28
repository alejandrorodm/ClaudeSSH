import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/storage/server_repository.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.repository});

  final ServerRepository repository;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _auth = LocalAuthentication();
  late bool _enabled = widget.repository.biometricLockEnabled();
  bool? _supported;
  bool _busy = false;
  String? _version;

  @override
  void initState() {
    super.initState();
    _auth.isDeviceSupported().then((supported) {
      if (mounted) setState(() => _supported = supported);
    });
    PackageInfo.fromPlatform().then((info) {
      if (mounted) {
        setState(() => _version = '${info.version} (${info.buildNumber})');
      }
    });
  }

  Future<void> _toggle(bool next) async {
    if (!next) {
      setState(() => _enabled = false);
      await widget.repository.setBiometricLockEnabled(false);
      return;
    }

    // Turning it on must prove it actually works first, so the toggle can
    // never leave the user locked out of their own app.
    setState(() => _busy = true);
    try {
      final ok = await _auth.authenticate(
        localizedReason: 'Confirm to require this on app launch',
      );
      if (!mounted) return;
      if (ok) {
        setState(() => _enabled = true);
        await widget.repository.setBiometricLockEnabled(true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Not enabled: authentication failed')),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Not enabled: $error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final supported = _supported;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Require unlock on launch'),
            subtitle: Text(
              supported == false
                  ? 'Not available: set up a screen lock on this device first'
                  : 'Biometrics or your device PIN/pattern, asked once on cold start',
            ),
            value: _enabled,
            onChanged: (supported == false || _busy) ? null : _toggle,
          ),
          const Divider(),
          ListTile(
            title: const Text('Version'),
            subtitle: Text(_version ?? '…'),
          ),
        ],
      ),
    );
  }
}
