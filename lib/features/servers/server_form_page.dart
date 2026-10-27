import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/storage/server_repository.dart';
import 'server_profile.dart';

class ServerFormPage extends StatefulWidget {
  const ServerFormPage({
    super.key,
    required this.repository,
    this.existing,
    this.template,
  });

  final ServerRepository repository;

  /// The server being edited. Saving updates it in place.
  final ServerProfile? existing;

  /// A server to copy. Saving creates a new server with the same values and secrets.
  final ServerProfile? template;

  @override
  State<ServerFormPage> createState() => _ServerFormPageState();
}

class _ServerFormPageState extends State<ServerFormPage>
    with WidgetsBindingObserver {
  final _formKey = GlobalKey<FormState>();
  Timer? _draftTimer;
  bool _finished = false;
  late final String _id;
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _workingDirectory;
  late final TextEditingController _secret;
  late final TextEditingController _passphrase;
  late AuthMethod _auth;
  bool _loaded = false;
  bool _saving = false;
  bool _obscureSecret = true;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    final source = existing ?? widget.template;
    _id = existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString();
    _name = TextEditingController(
      text: existing != null
          ? existing.name
          : source == null
          ? ''
          : '${source.name} (copy)',
    );
    _host = TextEditingController(text: source?.host ?? '');
    _port = TextEditingController(text: '${source?.port ?? 22}');
    _username = TextEditingController(text: source?.username ?? '');
    _workingDirectory = TextEditingController(
      text: source?.workingDirectory ?? '',
    );
    _secret = TextEditingController();
    _passphrase = TextEditingController();
    _auth = source?.auth ?? AuthMethod.privateKey;
    WidgetsBinding.instance.addObserver(this);
    for (final controller in [
      _name,
      _host,
      _port,
      _username,
      _workingDirectory,
    ]) {
      controller.addListener(_scheduleDraftSave);
    }
    if (source != null) _loadSecrets(source.id);
    _restoreDraft();
  }

  /// Keyed per server, so editing or copying one server never shows another's draft.
  String get _draftId {
    if (widget.existing != null) return widget.existing!.id;
    if (widget.template != null) return 'copy.${widget.template!.id}';
    return 'new';
  }

  Future<void> _restoreDraft() async {
    final draft = widget.repository.loadDraft(_draftId);
    if (draft == null || !mounted) return;
    setState(() {
      _name.text = draft['name'] as String? ?? _name.text;
      _host.text = draft['host'] as String? ?? _host.text;
      _port.text = draft['port'] as String? ?? _port.text;
      _username.text = draft['username'] as String? ?? _username.text;
      _workingDirectory.text =
          draft['workingDirectory'] as String? ?? _workingDirectory.text;
      final auth = draft['auth'] as String?;
      if (auth != null) _auth = AuthMethod.values.byName(auth);
    });
  }

  void _scheduleDraftSave() {
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 400), _persistDraft);
  }

  void _persistDraft() {
    _draftTimer?.cancel();
    if (_finished) return;
    widget.repository.saveDraft(_draftId, {
      'name': _name.text,
      'host': _host.text,
      'port': _port.text,
      'username': _username.text,
      'workingDirectory': _workingDirectory.text,
      'auth': _auth.name,
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android may stop the app when you switch away, so save before that.
    if (state != AppLifecycleState.resumed) _persistDraft();
  }

  Future<void> _loadSecrets(String id) async {
    final credentials = await widget.repository.credentialsFor(id);
    if (!mounted) return;
    setState(() {
      _secret.text =
          (_auth == AuthMethod.password
              ? credentials.password
              : credentials.privateKeyPem) ??
          '';
      _passphrase.text = credentials.passphrase ?? '';
      _loaded = true;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_draftTimer?.isActive ?? false) _persistDraft();
    _draftTimer?.cancel();
    for (final controller in [
      _name,
      _host,
      _port,
      _username,
      _workingDirectory,
      _secret,
      _passphrase,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final profile = ServerProfile(
      id: _id,
      name: _name.text.trim(),
      host: _host.text.trim(),
      port: int.parse(_port.text.trim()),
      username: _username.text.trim(),
      auth: _auth,
      workingDirectory: _workingDirectory.text.trim(),
    );
    final isPassword = _auth == AuthMethod.password;
    final credentials = SshCredentials(
      password: isPassword ? _secret.text : null,
      privateKeyPem: isPassword ? null : _secret.text.trim(),
      passphrase: isPassword ? null : _passphrase.text,
    );

    try {
      await widget.repository
          .save(profile, credentials)
          .timeout(const Duration(seconds: 15));
      _finished = true;
      _draftTimer?.cancel();
      await widget.repository.clearDraft(_draftId);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save: $error')));
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete server?'),
        content: Text('"${_name.text}" and its saved secrets will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _finished = true;
    _draftTimer?.cancel();
    await widget.repository.delete(_id);
    await widget.repository.clearDraft(_draftId);
    if (mounted) Navigator.of(context).pop();
  }

  String? _required(String? value) =>
      (value == null || value.trim().isEmpty) ? 'Required' : null;

  String? _validatePort(String? value) {
    final port = int.tryParse(value?.trim() ?? '');
    if (port == null || port < 1 || port > 65535) return 'Enter 1-65535';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final isPassword = _auth == AuthMethod.password;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isEditing
              ? 'Edit server'
              : widget.template != null
              ? 'Duplicate server'
              : 'New server',
        ),
        actions: [
          if (_isEditing)
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
        ],
      ),
      body: !_loaded && _isEditing
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  TextFormField(
                    controller: _name,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      hintText: 'My VPS',
                    ),
                    validator: _required,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _host,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Host',
                      hintText: 'vps.example.com or 203.0.113.10',
                    ),
                    validator: _required,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          controller: _username,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: 'Username',
                          ),
                          validator: _required,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _port,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Port'),
                          validator: _validatePort,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  SegmentedButton<AuthMethod>(
                    segments: const [
                      ButtonSegment(
                        value: AuthMethod.privateKey,
                        label: Text('Private key'),
                        icon: Icon(Icons.key_outlined),
                      ),
                      ButtonSegment(
                        value: AuthMethod.password,
                        label: Text('Password'),
                        icon: Icon(Icons.password_outlined),
                      ),
                    ],
                    selected: {_auth},
                    onSelectionChanged: (value) {
                      setState(() => _auth = value.first);
                      _scheduleDraftSave();
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _secret,
                    obscureText: isPassword && _obscureSecret,
                    minLines: isPassword ? 1 : 4,
                    maxLines: isPassword ? 1 : 8,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: isPassword ? 'Password' : 'Private key (PEM)',
                      hintText: isPassword
                          ? null
                          : '-----BEGIN OPENSSH PRIVATE KEY-----',
                      alignLabelWithHint: true,
                      suffixIcon: isPassword
                          ? IconButton(
                              icon: Icon(
                                _obscureSecret
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                              onPressed: () => setState(
                                () => _obscureSecret = !_obscureSecret,
                              ),
                            )
                          : null,
                    ),
                    validator: _required,
                  ),
                  if (!isPassword) ...[
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _passphrase,
                      obscureText: true,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Key passphrase (optional)',
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: _workingDirectory,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Project directory (optional)',
                      hintText: '~/projects/my-app',
                      helperText:
                          'Claude runs here. Empty uses the home directory.',
                    ),
                  ),
                  const SizedBox(height: 28),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? 'Saving…' : 'Save'),
                  ),
                ],
              ),
            ),
    );
  }
}
