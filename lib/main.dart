import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

const firebaseKey = String.fromEnvironment('FIREBASE_API_KEY');
const firebaseApp = String.fromEnvironment('FIREBASE_APP_ID');
const firebaseSender = String.fromEnvironment('FIREBASE_SENDER_ID');
const firebaseProject = String.fromEnvironment('FIREBASE_PROJECT_ID');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (firebaseKey.isNotEmpty) {
    await Firebase.initializeApp(options: FirebaseOptions(
      apiKey: firebaseKey, appId: firebaseApp,
      messagingSenderId: firebaseSender, projectId: firebaseProject,
    ));
  }
  runApp(const PilzApp());
}

class PilzApp extends StatelessWidget {
  const PilzApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'PILZRADAR', debugShowCheckedModeBanner: false,
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xff326747)), useMaterial3: true),
    home: firebaseKey.isEmpty ? const SetupPage() : StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, s) => s.data == null
          ? const LoginPage() : const HomePage(),
    ),
  );
}

class SetupPage extends StatelessWidget {
  const SetupPage({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(child: Padding(padding: EdgeInsets.all(24),
      child: Text('PILZRADAR – Firebase noch nicht eingerichtet. Trage die vier Firebase-Werte als GitHub-Secrets ein und starte den APK-Build erneut.',
        textAlign: TextAlign.center))),
  );
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final email = TextEditingController();
  final pass = TextEditingController();
  bool register = false, busy = false;

  Future<void> submit() async {
    setState(() => busy = true);
    try {
      if (register) {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email.text.trim(), password: pass.text);
      } else {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email.text.trim(), password: pass.text);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() { email.dispose(); pass.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PILZRADAR')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.forest, size: 80, color: Colors.green),
                TextField(
                  controller: email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'E-Mail'),
                ),
                TextField(
                  controller: pass,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Passwort (mindestens 6 Zeichen)',
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: busy ? null : submit,
                  child: Text(register ? 'Registrieren' : 'Anmelden'),
                ),
                TextButton(
                  onPressed: () => setState(() => register = !register),
                  child: Text(register
                      ? 'Bereits registriert? Anmelden'
                      : 'Neues Konto erstellen'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? teamId;
  int tab = 0;
  Position? pos;
  LatLng? start;
  Timer? timer;
  bool tracking = false;
  final db = FirebaseFirestore.instance;
  String get uid => FirebaseAuth.instance.currentUser!.uid;

  @override
  void initState() { super.initState(); _restore(); }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => teamId = prefs.getString('team'));
  }

  void notify(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)));
  }

  Future<void> locate() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw Exception('GPS aktivieren');
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        throw Exception('Standortberechtigung fehlt');
      }
      final result = await Geolocator.getCurrentPosition();
      if (mounted) setState(() => pos = result);
    } catch (e) { notify('$e'); }
  }

  Future<void> share() async {
    if (teamId == null) return;
    await locate();
    if (pos == null) return;
    try {
      await db.collection('teams').doc(teamId).collection('locations').doc(uid).set({
        'uid': uid, 'lat': pos!.latitude, 'lng': pos!.longitude,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) { notify('Standort teilen fehlgeschlagen: $e'); }
  }

  Future<void> toggleTracking() async {
    if (tracking) {
      timer?.cancel();
      setState(() => tracking = false);
      if (teamId != null) {
        try {
          await db.collection('teams').doc(teamId)
              .collection('locations').doc(uid).delete();
        } catch (e) { notify('Tracking stoppen fehlgeschlagen: $e'); }
      }
    } else {
      await share();
      if (pos == null) return;
      setState(() => tracking = true);
      timer = Timer.periodic(const Duration(seconds: 20), (_) => share());
    }
  }

  @override
  void dispose() { timer?.cancel(); super.dispose(); }

  // Ein Code wird zusammen mit seinem geschuetzten Index atomar gespeichert.
  String newInviteCode() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    return List.generate(6, (_) => alphabet[random.nextInt(alphabet.length)]).join();
  }

  Future<void> registerCode(DocumentReference<Map<String, dynamic>> teamRef,
      {String? name}) async {
    for (var attempt = 0; attempt < 8; attempt++) {
      final code = newInviteCode();
      final codeRef = db.collection('teamCodes').doc(code);
      try {
        await db.runTransaction((transaction) async {
          final existing = await transaction.get(codeRef);
          if (existing.exists) throw StateError('Code bereits vergeben');
          if (name != null) {
            transaction.set(teamRef, {
              'name': name, 'owner': uid, 'members': [uid],
              'code': code, 'createdAt': FieldValue.serverTimestamp(),
            });
          } else {
            transaction.update(teamRef, {'code': code});
          }
          transaction.set(codeRef, {'teamId': teamRef.id, 'owner': uid});
        });
        return;
      } on StateError {
        continue;
      }
    }
    throw StateError('Kein freier Teamcode gefunden. Bitte erneut versuchen.');
  }

  Future<void> createTeam() async {
    final name = TextEditingController();
    bool busy = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Team erstellen'),
          content: TextField(controller: name,
            decoration: const InputDecoration(labelText: 'Teamname')),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(dialogContext),
              child: const Text('Abbrechen')),
            FilledButton(onPressed: busy ? null : () async {
              if (name.text.trim().isEmpty) return;
              setDialogState(() => busy = true);
              try {
                final ref = db.collection('teams').doc();
                await registerCode(ref, name: name.text.trim());
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                await selectTeam(ref.id);
                notify('Team und Einladungscode erstellt.');
              } catch (e) {
                notify('Team erstellen fehlgeschlagen: $e');
                if (dialogContext.mounted) setDialogState(() => busy = false);
              }
            }, child: const Text('Erstellen')),
          ],
        ),
      ),
    );
    name.dispose();
  }

  Future<void> joinTeam() async {
    final codeController = TextEditingController();
    bool busy = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Teambeitritt beantragen'),
          content: TextField(
            controller: codeController,
            textCapitalization: TextCapitalization.characters,
            maxLength: 6,
            decoration: const InputDecoration(
              labelText: '6-stelliger Teamcode',
              prefixIcon: Icon(Icons.group_add),
            ),
          ),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(dialogContext),
              child: const Text('Abbrechen')),
            FilledButton(onPressed: busy ? null : () async {
              final code = codeController.text.trim().toUpperCase();
              if (!RegExp(r'^[A-Z0-9]{6}$').hasMatch(code)) {
                notify('Bitte einen gueltigen sechsstelligen Code eingeben.');
                return;
              }
              setDialogState(() => busy = true);
              try {
                final index = await db.collection('teamCodes').doc(code).get();
                if (!index.exists) throw StateError('Teamcode nicht gefunden');
                final id = index.data()?['teamId'] as String?;
                if (id == null) throw StateError('Teamcode ungueltig');
                final requestRef = db.collection('teams').doc(id)
                    .collection('joinRequests').doc(uid);
                await requestRef.set({
                  'uid': uid, 'status': 'pending', 'code': code,
                  'createdAt': FieldValue.serverTimestamp(),
                });
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                notify('Beitrittsanfrage gesendet. Warte auf Freigabe.');
              } catch (e) {
                notify('Anfrage fehlgeschlagen: $e');
                if (dialogContext.mounted) setDialogState(() => busy = false);
              }
            }, child: const Text('Anfragen')),
          ],
        ),
      ),
    );
    codeController.dispose();
  }

  Future<void> createMissingCode(
      QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
    if (doc.data()['owner'] != uid) {
      notify('Nur der Teamleiter darf einen Code erzeugen.');
      return;
    }
    try {
      await registerCode(doc.reference);
      notify('Einladungscode erzeugt.');
    } catch (e) { notify('Code konnte nicht erstellt werden: $e'); }
  }

  // Migriert alte Teams, die bereits einen Code, aber keinen Index besitzen.
  Future<void> activateExistingCode(
      QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
    if (doc.data()['owner'] != uid) return;
    final code = doc.data()['code']?.toString();
    if (code == null || !RegExp(r'^[A-Z0-9]{6}$').hasMatch(code)) {
      notify('Der alte Code ist ungueltig.');
      return;
    }
    try {
      final codeRef = db.collection('teamCodes').doc(code);
      final snapshot = await codeRef.get();
      if (snapshot.exists) {
        if (snapshot.data()?['teamId'] == doc.id) {
          notify('Teamcode ist bereits aktiv.');
        } else {
          notify('Code ist bereits vergeben. Bitte Support kontaktieren.');
        }
        return;
      }
      await codeRef.set({'teamId': doc.id, 'owner': uid});
      notify('Teamcode aktiviert.');
    } catch (e) { notify('Aktivierung fehlgeschlagen: $e'); }
  }

  Future<void> reviewRequest(String id, String applicantUid,
      {required bool approve}) async {
    final teamRef = db.collection('teams').doc(id);
    final requestRef = teamRef.collection('joinRequests').doc(applicantUid);
    try {
      final batch = db.batch();
      if (approve) {
        batch.update(teamRef, {
          'members': FieldValue.arrayUnion([applicantUid]),
        });
      }
      batch.update(requestRef, {
        'status': approve ? 'approved' : 'rejected',
      });
      await batch.commit();
      notify(approve ? 'Mitglied freigegeben.' : 'Anfrage abgelehnt.');
    } catch (e) { notify('Freigabe fehlgeschlagen: $e'); }
  }

  Widget requestsForTeam(String id) => StreamBuilder<
      QuerySnapshot<Map<String, dynamic>>>(
    stream: db.collection('teams').doc(id).collection('joinRequests')
        .where('status', isEqualTo: 'pending').snapshots(),
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return ListTile(title: Text('Anfragen nicht lesbar: ${snapshot.error}'));
      }
      final requests = snapshot.data?.docs ?? [];
      if (requests.isEmpty) return const SizedBox.shrink();
      return Column(children: [
        const ListTile(title: Text('Offene Beitrittsanfragen')),
        ...requests.map((request) => ListTile(
          title: Text('Nutzer: ${request.id.substring(0, min(8, request.id.length))}…'),
          subtitle: const Text('Moechte dem Team beitreten'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              tooltip: 'Freigeben', icon: const Icon(Icons.check, color: Colors.green),
              onPressed: () => reviewRequest(id, request.id, approve: true),
            ),
            IconButton(
              tooltip: 'Ablehnen', icon: const Icon(Icons.close, color: Colors.red),
              onPressed: () => reviewRequest(id, request.id, approve: false),
            ),
          ]),
        )),
      ]);
    },
  );

  Future<void> selectTeam(String id) async {
    if (tracking) {
      timer?.cancel();
      tracking = false;
    }
    if (!mounted) return;
    setState(() { teamId = id; tab = 0; });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('team', id);
    } catch (e) { debugPrint('Team speichern fehlgeschlagen: $e'); }
  }

  Future<void> sos() async {
    if (teamId == null) return;
    await locate();
    if (pos == null) return;
    try {
      await db.collection('teams').doc(teamId).collection('messages').add({
        'uid': uid,
        'text': '🆘 SOS! Ich brauche Hilfe. Standort: ${pos!.latitude}, ${pos!.longitude}',
        'createdAt': FieldValue.serverTimestamp(), 'sos': true,
      });
      notify('SOS an Teamchat gesendet. Bei akuter Gefahr 112 anrufen!');
    } catch (e) { notify('SOS-Nachricht fehlgeschlagen: $e. Bei akuter Gefahr 112 anrufen!'); }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('🍄 PILZRADAR'), actions: [
      IconButton(onPressed: () => FirebaseAuth.instance.signOut(),
        icon: const Icon(Icons.logout)),
    ]),
    body: teamId == null ? _teams() : Column(children: [
      SizedBox(height: 56,
        child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: db.collection('teams').doc(teamId).snapshots(),
          builder: (c, s) {
            if (!s.hasData || !s.data!.exists) {
              return const Center(child: Text('Team wird geladen…'));
            }
            final data = s.data!.data()!;
            return Row(children: [
              Expanded(child: Padding(padding: const EdgeInsets.all(12),
                child: Text('Team: ${data['name']}',
                  overflow: TextOverflow.ellipsis))),
              TextButton(onPressed: () async {
                if (tracking) await toggleTracking();
                final prefs = await SharedPreferences.getInstance();
                await prefs.remove('team');
                if (mounted) setState(() => teamId = null);
              }, child: const Text('Wechseln')),
            ]);
          },
        ),
      ),
      Expanded(child: tab == 0 ? _map() : tab == 1 ? _finds()
          : tab == 2 ? _chat() : _teams()),
    ]),
    bottomNavigationBar: teamId == null ? null : NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (value) => setState(() => tab = value),
      destinations: const [
        NavigationDestination(icon: Icon(Icons.map), label: 'Karte'),
        NavigationDestination(icon: Icon(Icons.eco), label: 'Funde'),
        NavigationDestination(icon: Icon(Icons.chat), label: 'Chat'),
        NavigationDestination(icon: Icon(Icons.groups), label: 'Teams'),
      ],
    ),
  );

  Widget _teams() => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
    stream: db.collection('teams').where('members', arrayContains: uid).snapshots(),
    builder: (c, s) {
      if (s.hasError) return Center(child: Text('Teams konnten nicht geladen werden: ${s.error}'));
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      final docs = s.data!.docs;
      return ListView(children: [
        const ListTile(title: Text('Meine Teams'),
          subtitle: Text('Nur Teammitglieder sehen Teamdaten.')),
        ...docs.map((doc) {
          final data = doc.data();
          final code = data['code']?.toString();
          final owner = data['owner'] == uid;
          return Card(child: Column(children: [
            ListTile(
              leading: const Icon(Icons.groups, color: Colors.green),
              title: Text('${data['name'] ?? 'Team'}'),
              subtitle: Text(code == null || code.isEmpty
                  ? 'Noch kein Teamcode vorhanden' : 'Teamcode: $code'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => selectTeam(doc.id),
            ),
            if (code != null && code.isNotEmpty)
              Column(children: [
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: code));
                    notify('Teamcode $code kopiert');
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Teamcode kopieren'),
                ),
                if (owner) TextButton.icon(
                  onPressed: () => activateExistingCode(doc),
                  icon: const Icon(Icons.verified_user),
                  label: const Text('Teamcode aktivieren (alte Teams)'),
                ),
              ])
            else if (owner)
              TextButton.icon(
                onPressed: () => createMissingCode(doc),
                icon: const Icon(Icons.vpn_key),
                label: const Text('Teamcode erzeugen'),
              ),
            if (owner) requestsForTeam(doc.id),
          ]));
        }),
        const SizedBox(height: 16),
        ListTile(
          leading: const Icon(Icons.add_circle, color: Colors.green),
          title: const Text('Neues Team erstellen'),
          subtitle: const Text('Eigenes Pilzsucher-Team gründen'),
          onTap: createTeam,
        ),
        ListTile(
          leading: const Icon(Icons.group_add, color: Colors.green),
          title: const Text('Team beitreten'),
          subtitle: const Text('Mit 6-stelligem Teamcode beitreten'),
          onTap: joinTeam,
        ),
        const Padding(padding: EdgeInsets.all(16),
          child: Text('Teile deinen Teamcode nur mit Personen, die du in dein Team aufnehmen möchtest.')),
      ]);
    },
  );

  Widget _map() => Column(children: [
    Wrap(spacing: 6, children: [
      FilledButton.tonal(onPressed: locate, child: const Text('Mein GPS')),
      FilledButton.tonal(onPressed: toggleTracking,
        child: Text(tracking ? 'Tracking stoppen' : 'Live teilen')),
      FilledButton.tonal(onPressed: () => setState(() => start = pos == null
          ? null : LatLng(pos!.latitude, pos!.longitude)),
        child: const Text('Start merken')),
      FilledButton(onPressed: sos,
        style: FilledButton.styleFrom(backgroundColor: Colors.red),
        child: const Text('SOS')),
    ]),
    Expanded(child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: db.collection('teams').doc(teamId).collection('locations').snapshots(),
      builder: (c, s) {
        final members = s.data?.docs ?? [];
        final points = members.where((e) => e.data()['lat'] != null).toList();
        final center = pos == null ? const LatLng(51.15, 11.8)
            : LatLng(pos!.latitude, pos!.longitude);
        return FlutterMap(
          options: MapOptions(initialCenter: center, initialZoom: 13),
          children: [
            TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'de.pilzradar.app'),
            MarkerLayer(markers: [
              if (pos != null) Marker(point: center, width: 60, height: 55,
                child: const Icon(Icons.my_location, color: Colors.blue, size: 34)),
              if (start != null) Marker(point: start!, width: 60, height: 55,
                child: const Icon(Icons.flag, color: Colors.orange, size: 34)),
              ...points.map((e) => Marker(
                point: LatLng((e.data()['lat'] as num).toDouble(),
                  (e.data()['lng'] as num).toDouble()),
                width: 90, height: 70,
                child: Column(children: [
                  const Icon(Icons.person_pin_circle, color: Colors.green, size: 34),
                  Text(e.id == uid ? 'Ich' : e.id.substring(0, min(6, e.id.length)),
                    style: const TextStyle(fontSize: 10)),
                ]),
              )),
            ]),
          ],
        );
      },
    )),
    if (start != null && pos != null)
      ListTile(
        title: Text('Luftlinie zum Start: ${Geolocator.distanceBetween(
          pos!.latitude, pos!.longitude, start!.latitude, start!.longitude).round()} m'),
        trailing: TextButton(onPressed: () async {
          final url = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${start!.latitude},${start!.longitude}&travelmode=walking');
          await launchUrl(url, mode: LaunchMode.externalApplication);
        }, child: const Text('Route öffnen')),
      ),
    const Padding(padding: EdgeInsets.all(8),
      child: Text('Live nur bei geöffneter App und Internet. Kartenkacheln benötigen Internet; gespeicherte Funde bleiben offline verfügbar.',
        style: TextStyle(fontSize: 11))),
  ]);

  Widget _finds() => FutureBuilder<SharedPreferences>(
    future: SharedPreferences.getInstance(),
    builder: (c, s) {
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      final prefs = s.data!;
      final key = 'finds_$uid';
      final entries = (jsonDecode(prefs.getString(key) ?? '[]') as List)
          .cast<Map<String, dynamic>>();
      return ListView(children: [
        ListTile(title: const Text('Private Fundorte (offline)'),
          trailing: IconButton(icon: const Icon(Icons.add), onPressed: () async {
            await locate();
            if (pos == null || !mounted) return;
            final name = TextEditingController();
            await showDialog<void>(context: context, builder: (dialogContext) => AlertDialog(
              title: const Text('Pilzfund speichern'),
              content: TextField(controller: name,
                decoration: const InputDecoration(labelText: 'Pilzart / Notiz')),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Abbrechen')),
                FilledButton(onPressed: () async {
                  entries.add({
                    'id': const Uuid().v4(), 'name': name.text,
                    'lat': pos!.latitude, 'lng': pos!.longitude,
                    'date': DateTime.now().toIso8601String(),
                  });
                  await prefs.setString(key, jsonEncode(entries));
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                  if (mounted) setState(() {});
                }, child: const Text('Speichern')),
              ],
            ));
            name.dispose();
          })),
        ...entries.map((e) => ListTile(
          leading: const Icon(Icons.eco),
          title: Text('${e['name']}'),
          subtitle: Text('${e['date']} · ${e['lat']}, ${e['lng']}'),
        )),
        const ListTile(title: Text('Pilzbestimmung per Foto'),
          subtitle: Text('Noch nicht aktiviert. Fotos allein reichen nicht für eine sichere Essbarkeitsbestimmung.')),
      ]);
    },
  );

  Widget _chat() {
    final ref = db.collection('teams').doc(teamId).collection('messages');
    final input = TextEditingController();
    return Column(children: [
      Expanded(child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: ref.orderBy('createdAt', descending: true).limit(100).snapshots(),
        builder: (c, s) => ListView(children: (s.data?.docs ?? []).map((doc) {
          final data = doc.data();
          final sender = '${data['uid'] ?? ''}';
          return ListTile(title: Text('${data['text'] ?? ''}'),
            subtitle: Text(sender == uid ? 'Ich'
              : sender.substring(0, min(6, sender.length))));
        }).toList()),
      )),
      Row(children: [
        Expanded(child: TextField(controller: input,
          decoration: const InputDecoration(hintText: 'Nachricht an Team'))),
        IconButton(icon: const Icon(Icons.send), onPressed: () async {
          if (input.text.trim().isEmpty) return;
          try {
            await ref.add({'uid': uid, 'text': input.text.trim(),
              'createdAt': FieldValue.serverTimestamp()});
            input.clear();
          } catch (e) { notify('Nachricht fehlgeschlagen: $e'); }
        }),
      ]),
    ]);
  }
}
