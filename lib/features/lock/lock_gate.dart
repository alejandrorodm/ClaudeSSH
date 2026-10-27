import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/storage/server_repository.dart';

/// Wraps the app's home screen. When the user has turned on the biometric
/// lock in Settings, this asks for it once on cold start and only reveals
/// [child] after a successful authentication, device PIN/pattern included
/// (never biometrics-only, so a phone with no enrolled fingerprint still
/// has a working fallback).
///
/// This only guards the cold-start launch, not every return from the
/// background — re-locking whenever another app (for example the system
/// file picker) briefly takes focus would lock the user out of their own
/// in-progress task.
class LockGate extends StatefulWidget {
  const LockGate({super.key, required this.repository, required this.child});

  final ServerRepository repository;
  final Widget child;

  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> {
  final _auth = LocalAuthentication();
  bool _unlocked = false;
  bool _checking = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (!widget.repository.biometricLockEnabled()) {
      _unlocked = true;
      _checking = false;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
    }
  }

  Future<void> _unlock() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final ok = await _auth.authenticate(localizedReason: 'Unlock Claude SSH');
      if (!mounted) return;
      setState(() {
        _unlocked = ok;
        _checking = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = 'Could not unlock: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_unlocked) return widget.child;

    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lock_outline,
                size: 56,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text('Claude SSH is locked', style: theme.textTheme.titleLarge),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: const Icon(Icons.fingerprint),
                label: Text(_checking ? 'Checking…' : 'Unlock'),
                onPressed: _checking ? null : _unlock,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
