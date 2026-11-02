import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../collaboration/admin/admin_records.dart';
import '../../collaboration/admin/admin_records_crypto.dart';
import '../../collaboration/admin/admin_records_share.dart';
import '../../collaboration/sync/failover_crypto.dart';
import '../../collaboration/sync/sync_address.dart';
import '../../db/otic_database.dart';
import '../../db/providers/db_provider.dart';
import 'admin_service.dart';
import '../teacher/teacher_pin_screen.dart';

/// What this device holds from the Admin (null when nothing).
final adminRecordsStateProvider =
    FutureProvider.autoDispose<AdminRecordsStateRow?>(
      (ref) => AdminRecords(ref.watch(dbProvider)).received(),
    );

/// Admin → Send school records: the code and address another device types,
/// and Accept or Decline for each device that asks. One way only.
class SendRecordsPage extends ConsumerStatefulWidget {
  const SendRecordsPage({super.key});

  @override
  ConsumerState<SendRecordsPage> createState() => _SendRecordsPageState();
}

class _SendRecordsPageState extends ConsumerState<SendRecordsPage> {
  AdminRecordsServer? _server;
  StreamSubscription<List<AdminRecordsRequest>>? _sub;
  List<AdminRecordsRequest> _pending = const [];
  List<String> _addresses = const [];
  bool _takeover = false;
  bool _starting = false;
  String? _error;
  final _pass = TextEditingController();

  @override
  void dispose() {
    _sub?.cancel();
    _server?.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final pass = _pass.text;
    if (_takeover && pass.length < kMinPassphraseLength) {
      return setState(
        () => _error = 'At least $kMinPassphraseLength characters',
      );
    }
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final session = ref.read(adminSessionProvider);
      if (session == null) throw StateError('Sign in as Admin to send records.');
      if (_takeover && !session.lease.fresh) {
        final pin = await askTeacherPin(context, title: 'Confirm Admin PIN');
        if (pin == null || await ref.read(adminServiceProvider).signIn(pin) == null) return;
        session.lease.authenticatedAt = DateTime.now();
        session.lease.lastActivity = DateTime.now();
      }
      session.lease.requireValid(sensitive: _takeover);
      final db = ref.read(dbProvider);
      if ((await db.classSyncDao.identity()).schoolId == null) {
        return setState(() => _error = 'Set the school first');
      }
      Map<String, Object?>? sealed;
      if (_takeover) {
        final details = await AdminRecords(db).takeoverDetails();
        if (details != null) {
          sealed = await sealAdminTakeover(passphrase: pass, admin: details);
        }
      }
      final server = AdminRecordsServer(db);
      await server.start(takeover: sealed);
      final addresses = await localIPv4Addresses();
      if (!mounted) {
        await server.stop();
        return;
      }
      _sub = server.pending.listen((p) => setState(() => _pending = p));
      setState(() {
        _server = server;
        _addresses = addresses;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start: $e');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _stop() async {
    await _sub?.cancel();
    await _server?.stop();
    if (mounted) setState(() => _server = null);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(adminSessionProvider, (_, session) {
      if (session == null) unawaited(_stop());
    });
    final server = _server;
    return Scaffold(
      appBar: AppBar(title: const Text('Send school records')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (server == null) ...[
            CheckboxListTile(
              value: _takeover,
              onChanged: (v) => setState(() => _takeover = v ?? false),
              title: const Text('Let me take over as Admin on that device'),
            ),
            if (_takeover)
              TextField(
                controller: _pass,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Admin passphrase (12+ characters)',
                ),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _starting ? null : _start,
              child: const Text('Start'),
            ),
          ] else ...[
            ListTile(
              title: const Text('Code'),
              subtitle: SelectableText(
                server.locked ? 'Locked — too many wrong tries' : _shown(server.code),
                style: const TextStyle(fontSize: 22, letterSpacing: 2),
              ),
              trailing: TextButton(
                onPressed: () => setState(server.newCode),
                child: const Text('New code'),
              ),
            ),
            ListTile(
              title: const Text('Address'),
              subtitle: SelectableText(
                _addresses.map((a) => '$a:${server.port}').join('\n'),
              ),
            ),
            for (final r in _pending)
              Card(
                child: ListTile(
                  title: Text(r.name),
                  subtitle: Text(
                    [
                      'Wants the school records',
                      for (final e in r.registrations.entries)
                        'brings ${e.value} new learner'
                            '${e.value == 1 ? '' : 's'} from ${e.key}',
                    ].join(' · '),
                  ),
                  trailing: Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: () => server.decide(r, accept: false),
                        child: const Text('Decline'),
                      ),
                      FilledButton(
                        onPressed: () => server.decide(r, accept: true),
                        child: const Text('Accept'),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: _stop, child: const Text('Stop')),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }

  static String _shown(String? code) => code == null
      ? ''
      : '${code.substring(0, 4)}-${code.substring(4)}';
}

/// On a device that isn't the Admin's: receive the school records (and take
/// over as Admin, when the Admin allowed it).
class ReceiveRecordsCard extends ConsumerStatefulWidget {
  const ReceiveRecordsCard({super.key});

  @override
  ConsumerState<ReceiveRecordsCard> createState() => _ReceiveRecordsCardState();
}

class _ReceiveRecordsCardState extends ConsumerState<ReceiveRecordsCard> {
  final _address = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _address.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _receive() async {
    final endpoint = parseTeacherAddress(_address.text);
    if (endpoint == null) {
      return setState(() => _message = 'Type the address the Admin shows');
    }
    setState(() {
      _busy = true;
      _message = 'Waiting for the Admin to accept…';
    });
    final error = await receiveAdminRecords(
      ref.read(dbProvider),
      address: endpoint.address,
      port: endpoint.port,
      typedCode: _code.text,
      deviceName: 'Device',
    );
    if (!mounted) return;
    ref.invalidate(adminRecordsStateProvider);
    setState(() {
      _busy = false;
      _message = error ?? 'School records received';
    });
  }

  Future<void> _takeOver() async {
    final pass = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Take over as Admin'),
        content: TextField(
          controller: pass,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Admin passphrase'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Take over'),
          ),
        ],
      ),
    );
    final text = pass.text;
    pass.dispose();
    if (ok != true) return;
    setState(() => _busy = true);
    final done = await AdminRecords(ref.read(dbProvider)).takeOver(text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = done ? null : 'That passphrase is not right';
    });
    if (done) {
      ref.invalidate(adminSetUpProvider);
      ref.invalidate(adminRecordsStateProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(adminRecordsStateProvider).valueOrNull;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Receive school records',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (state != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Version ${state.version} received'),
              ),
            TextField(
              controller: _address,
              decoration: const InputDecoration(
                labelText: 'Address',
                hintText: 'e.g. 192.168.43.1:41234',
              ),
            ),
            TextField(
              controller: _code,
              decoration: const InputDecoration(labelText: 'Code'),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _receive,
              child: const Text('Receive'),
            ),
            if (state?.takeoverJson != null) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _busy ? null : _takeOver,
                child: const Text('Take over as Admin'),
              ),
            ],
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_message!),
              ),
          ],
        ),
      ),
    );
  }
}
