import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
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
const firebaseAuthDomain = String.fromEnvironment('FIREBASE_AUTH_DOMAIN');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (firebaseKey.isNotEmpty) {
    await Firebase.initializeApp(options: FirebaseOptions(
      apiKey: firebaseKey, appId: firebaseApp,
      messagingSenderId: firebaseSender, projectId: firebaseProject,
      authDomain: firebaseAuthDomain.isEmpty ? null : firebaseAuthDomain,
    ));
  }
  runApp(const PilzApp());
}

class PilzApp extends StatelessWidget {
  const PilzApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'PILZRADAR', debugShowCheckedModeBanner: false,
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff326747)), useMaterial3: true),
    home: firebaseKey.isEmpty
        ? const Scaffold(body: Center(child: Text('Firebase-Konfiguration fehlt.')))
        : StreamBuilder<User?>(
            stream: FirebaseAuth.instance.authStateChanges(),
            builder: (c, s) {
              if (s.connectionState == ConnectionState.waiting) {
                return const Scaffold(body: Center(child: CircularProgressIndicator()));
              }
              return s.data == null ? const LoginPage() : const ProfileGate();
            },
          ),
  );
}

void showError(BuildContext c, Object e) {
  if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('$e')));
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override State<LoginPage> createState() => _LoginPageState();
}
class _LoginPageState extends State<LoginPage> {
  final email = TextEditingController(), pass = TextEditingController();
  bool register = false, busy = false;
  @override void dispose() { email.dispose(); pass.dispose(); super.dispose(); }
  Future<void> submit() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      if (register) {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(email: email.text.trim(), password: pass.text);
      } else {
        await FirebaseAuth.instance.signInWithEmailAndPassword(email: email.text.trim(), password: pass.text);
      }
    } catch (e) { if (mounted) showError(context, e); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('🍄 PILZRADAR')),
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420),
      child: Padding(padding: const EdgeInsets.all(20), child: Column(
        mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.forest, size: 75, color: Colors.green),
          TextField(controller: email, keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'E-Mail')),
          TextField(controller: pass, obscureText: true,
            decoration: const InputDecoration(labelText: 'Passwort (mindestens 6 Zeichen)')),
          const SizedBox(height: 18),
          FilledButton(onPressed: busy ? null : submit,
            child: Text(register ? 'Registrieren' : 'Anmelden')),
          TextButton(onPressed: () => setState(() => register = !register),
            child: Text(register ? 'Bereits registriert? Anmelden' : 'Neues Konto erstellen')),
        ],
      )),
    )),
  );
}

class ProfileGate extends StatelessWidget {
  const ProfileGate({super.key});
  @override Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
      builder: (c, s) {
        if (s.hasError) return Scaffold(body: Center(child: Text('Profilzugriff fehlgeschlagen: ${s.error}')));
        if (!s.hasData) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        final name = (s.data!.data()?['name'] ?? '').toString().trim();
        return name.isEmpty ? const NamePage() : HomePage(myName: name);
      },
    );
  }
}

class NamePage extends StatefulWidget {
  const NamePage({super.key});
  @override State<NamePage> createState() => _NamePageState();
}
class _NamePageState extends State<NamePage> {
  final ctrl = TextEditingController();
  bool busy = false;
  @override void dispose() { ctrl.dispose(); super.dispose(); }
  Future<void> save() async {
    final name = ctrl.text.trim();
    if (name.length < 2 || busy) return;
    setState(() => busy = true);
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'name': name, 'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) { if (mounted) showError(context, e); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('Dein Name')),
    body: Center(child: Padding(padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Wie sollen dich deine Teammitglieder sehen?'),
        TextField(controller: ctrl, maxLength: 40, decoration: const InputDecoration(labelText: 'Anzeigename')),
        FilledButton(onPressed: busy ? null : save, child: const Text('Namen speichern')),
      ]),
    )),
  );
}

class HomePage extends StatefulWidget {
  final String myName;
  const HomePage({super.key, required this.myName});
  @override State<HomePage> createState() => _HomePageState();
}
class _HomePageState extends State<HomePage> {
  final db = FirebaseFirestore.instance;
  final random = Random.secure();
  String? teamId;
  int tab = 0;
  Position? pos;
  LatLng? start;
  Timer? timer;
  bool tracking = false;
  late final Future<SharedPreferences> prefsFuture = SharedPreferences.getInstance();
  String get uid => FirebaseAuth.instance.currentUser!.uid;
  DocumentReference<Map<String, dynamic>> get teamRef => db.collection('teams').doc(teamId);
  @override void initState() { super.initState(); restore(); }
  @override void dispose() { timer?.cancel(); super.dispose(); }
  Future<void> restore() async {
    final prefs = await prefsFuture;
    if (mounted) setState(() => teamId = prefs.getString('team'));
  }
  Future<void> selectTeam(String? id) async {
    if (tracking) await toggleTracking();
    final prefs = await prefsFuture;
    if (id == null) { await prefs.remove('team'); }
    else { await prefs.setString('team', id); }
    if (mounted) setState(() { teamId = id; tab = 0; });
  }
  Future<Position?> locate() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) throw Exception('GPS aktivieren');
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        throw Exception('Standortberechtigung fehlt');
      }
      final result = await Geolocator.getCurrentPosition();
      if (mounted) setState(() => pos = result);
      return result;
    } catch (e) { if (mounted) showError(context, e); return null; }
  }
  Future<void> share() async {
    if (teamId == null) return;
    final p = await locate();
    if (p == null) return;
    try {
      await teamRef.collection('locations').doc(uid).set({
        'uid': uid, 'name': widget.myName, 'lat': p.latitude, 'lng': p.longitude,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) { if (mounted) showError(context, e); }
  }
  Future<void> toggleTracking() async {
    if (tracking) {
      timer?.cancel();
      if (mounted) setState(() => tracking = false);
      if (teamId != null) {
        try { await teamRef.collection('locations').doc(uid).delete(); }
        catch (e) { if (mounted) showError(context, e); }
      }
    } else {
      final p = await locate();
      if (p == null || teamId == null) return;
      try {
        await teamRef.collection('locations').doc(uid).set({
          'uid': uid, 'name': widget.myName, 'lat': p.latitude, 'lng': p.longitude,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        if (mounted) setState(() => tracking = true);
        timer = Timer.periodic(const Duration(seconds: 20), (_) => share());
      } catch (e) { if (mounted) showError(context, e); }
    }
  }
  Future<void> sos() async {
    if (teamId == null) return;
    final p = await locate();
    if (p == null) return;
    try {
      await teamRef.collection('messages').add({
        'uid': uid, 'name': widget.myName,
        'text': '🆘 SOS! Ich brauche Hilfe. Standort: ${p.latitude}, ${p.longitude}',
        'createdAt': FieldValue.serverTimestamp(), 'sos': true,
      });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('SOS an Teamchat gesendet. Bei akuter Gefahr 112 anrufen!')));
    } catch (e) { if (mounted) showError(context, e); }
  }
  String makeCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    return List.generate(6, (_) => chars[random.nextInt(chars.length)]).join();
  }
  Future<void> createTeam() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(context: context, builder: (c) => AlertDialog(
      title: const Text('Team erstellen'),
      content: TextField(controller: ctrl, maxLength: 50,
        decoration: const InputDecoration(labelText: 'Teamname')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Abbrechen')),
        FilledButton(onPressed: () => Navigator.pop(c, ctrl.text.trim()), child: const Text('Erstellen')),
      ],
    ));
    ctrl.dispose();
    if (name == null || name.isEmpty) return;
    try {
      for (var i = 0; i < 8; i++) {
        final code = makeCode();
        final codeRef = db.collection('teamCodes').doc(code);
        final newTeam = db.collection('teams').doc();
        final success = await db.runTransaction<bool>((tx) async {
          final old = await tx.get(codeRef);
          if (old.exists) return false;
          tx.set(newTeam, {
            'name': name, 'owner': uid, 'members': [uid], 'code': code,
            'createdAt': FieldValue.serverTimestamp(),
          });
          tx.set(codeRef, {'teamId': newTeam.id, 'owner': uid});
          return true;
        });
        if (success) { await selectTeam(newTeam.id); return; }
      }
      throw Exception('Kein freier Teamcode gefunden');
    } catch (e) { if (mounted) showError(context, e); }
  }
  Future<void> createCodeForOldTeam(String id) async {
    try {
      final ref = db.collection('teams').doc(id);
      for (var i = 0; i < 8; i++) {
        final code = makeCode();
        final codeRef = db.collection('teamCodes').doc(code);
        final success = await db.runTransaction<bool>((tx) async {
          final existing = await tx.get(codeRef);
          final team = await tx.get(ref);
          if (existing.exists) return false;
          if (!team.exists || team.data()?['owner'] != uid) {
            throw Exception('Nur der Teamleiter darf einen Teamcode erzeugen');
          }
          if ((team.data()?['code'] ?? '').toString().isNotEmpty) return true;
          tx.update(ref, {'code': code});
          tx.set(codeRef, {'teamId': id, 'owner': uid});
          return true;
        });
        if (success) return;
      }
      throw Exception('Teamcode konnte nicht erzeugt werden');
    } catch (e) { if (mounted) showError(context, e); }
  }
  Future<void> joinTeam() async {
    final ctrl = TextEditingController();
    final code = await showDialog<String>(context: context, builder: (c) => AlertDialog(
      title: const Text('Teamcode eingeben'),
      content: TextField(controller: ctrl, textCapitalization: TextCapitalization.characters,
        maxLength: 6, decoration: const InputDecoration(labelText: '6-stelliger Teamcode')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Abbrechen')),
        FilledButton(onPressed: () => Navigator.pop(c, ctrl.text.trim().toUpperCase()),
          child: const Text('Anfrage senden')),
      ],
    ));
    ctrl.dispose();
    if (code == null || code.length != 6) return;
    try {
      final found = await db.collection('teamCodes').doc(code).get();
      if (!found.exists) throw Exception('Teamcode nicht gefunden');
      final id = (found.data()?['teamId'] ?? '').toString();
      if (id.isEmpty) throw Exception('Team nicht gefunden');
      final teamSnapshot = await db.collection('teams').doc(id).get();
      if (!teamSnapshot.exists) throw Exception('Team nicht gefunden');
      final teamData = teamSnapshot.data()!;
      if (List.from(teamData['blocked'] ?? []).contains(uid)) {
        throw Exception('Du wurdest für dieses Team gesperrt');
      }
      if (List.from(teamData['members'] ?? []).contains(uid)) {
        await selectTeam(id);
        return;
      }
      await db.collection('teams').doc(id).collection('requests').doc(uid).set({
        'uid': uid, 'name': widget.myName, 'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Beitrittsanfrage gesendet. Teamleiter muss freigeben.')));
    } catch (e) { if (mounted) showError(context, e); }
  }
  Future<void> approve(String team, String member) async {
    try {
      final ref = db.collection('teams').doc(team);
      final req = ref.collection('requests').doc(member);
      final batch = db.batch();
      batch.update(ref, {'members': FieldValue.arrayUnion([member])});
      batch.update(req, {'status': 'approved'});
      await batch.commit();
    } catch (e) { if (mounted) showError(context, e); }
  }
  Future<void> reject(String team, String member) async {
    try {
      await db.collection('teams').doc(team).collection('requests').doc(member)
          .update({'status': 'rejected'});
    } catch (e) { if (mounted) showError(context, e); }
  }
  Future<void> removeMember(String team, String member) async {
    try {
      await db.collection('teams').doc(team).update({
        'members': FieldValue.arrayRemove([member]),
        'blocked': FieldValue.arrayUnion([member]),
      });
      await db.collection('teams').doc(team).collection('locations').doc(member).delete();
    } catch (e) { if (mounted) showError(context, e); }
  }
  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('🍄 PILZRADAR'),
      actions: [IconButton(onPressed: () => FirebaseAuth.instance.signOut(),
        icon: const Icon(Icons.logout), tooltip: 'Abmelden')]),
    body: teamId == null ? teams() : Column(children: [
      SizedBox(height: 56, child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: teamRef.snapshots(),
        builder: (c, s) {
          if (s.hasError) return Center(child: Text('Teamfehler: ${s.error}'));
          if (!s.hasData) return const Center(child: CircularProgressIndicator());
          final d = s.data!.data();
          if (d == null || !(List.from(d['members'] ?? []).contains(uid))) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && teamId != null) selectTeam(null);
            });
            return const Center(child: Text('Kein Teamzugriff'));
          }
          return Row(children: [
            Expanded(child: Padding(padding: const EdgeInsets.all(12),
              child: Text('Team: ${d['name']}', overflow: TextOverflow.ellipsis))),
            TextButton(onPressed: () => selectTeam(null), child: const Text('Wechseln')),
          ]);
        },
      )),
      Expanded(child: tab == 0 ? mapView() : tab == 1 ? finds() : tab == 2 ? chat() : teams()),
    ]),
    bottomNavigationBar: teamId == null ? null : NavigationBar(
      selectedIndex: tab, onDestinationSelected: (v) => setState(() => tab = v),
      destinations: const [
        NavigationDestination(icon: Icon(Icons.map), label: 'Karte'),
        NavigationDestination(icon: Icon(Icons.eco), label: 'Funde'),
        NavigationDestination(icon: Icon(Icons.chat), label: 'Chat'),
        NavigationDestination(icon: Icon(Icons.groups), label: 'Teams'),
      ],
    ),
  );

  Widget teams() => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
    stream: db.collection('teams').where('members', arrayContains: uid).snapshots(),
    builder: (c, s) {
      if (s.hasError) return Center(child: Text('Teamfehler: ${s.error}'));
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      return ListView(children: [
        const ListTile(title: Text('Meine Teams'),
          subtitle: Text('Teamcodes statt Firebase-UIDs verwenden.')),
        ...s.data!.docs.map((doc) {
          final d = doc.data();
          return Card(child: Column(children: [
            ListTile(title: Text('${d['name']}'),
              subtitle: Text('Teamcode: ${d['code'] ?? 'Altteam ohne Code'}'),
              onTap: () => selectTeam(doc.id)),
            if (d['owner'] == uid) ...[
              if ((d['code'] ?? '').toString().isEmpty)
                ListTile(leading: const Icon(Icons.vpn_key),
                  title: const Text('Teamcode für bestehendes Team erstellen'),
                  onTap: () => createCodeForOldTeam(doc.id)),
              ListTile(leading: const Icon(Icons.pending_actions),
                title: const Text('Beitrittsanfragen'),
                onTap: () => Navigator.push(context, MaterialPageRoute(
                  builder: (_) => RequestsPage(team: doc.id, onApprove: approve, onReject: reject)))),
              ListTile(leading: const Icon(Icons.manage_accounts),
                title: const Text('Mitglieder verwalten'),
                onTap: () => Navigator.push(context, MaterialPageRoute(
                  builder: (_) => MembersPage(team: doc.id, owner: uid, onRemove: removeMember)))),
            ],
          ]));
        }),
        ListTile(leading: const Icon(Icons.add), title: const Text('Neues Team erstellen'), onTap: createTeam),
        ListTile(leading: const Icon(Icons.group_add), title: const Text('Mit Teamcode beitreten'), onTap: joinTeam),
      ]);
    },
  );

  Widget mapView() => Column(children: [
    Wrap(spacing: 6, children: [
      FilledButton.tonal(onPressed: locate, child: const Text('Mein GPS')),
      FilledButton.tonal(onPressed: toggleTracking,
        child: Text(tracking ? 'Tracking stoppen' : 'Live teilen')),
      FilledButton.tonal(onPressed: () => setState(() =>
        start = pos == null ? null : LatLng(pos!.latitude, pos!.longitude)),
        child: const Text('Start merken')),
      FilledButton(onPressed: sos, style: FilledButton.styleFrom(backgroundColor: Colors.red),
        child: const Text('SOS')),
    ]),
    Expanded(child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: teamRef.collection('locations').snapshots(),
      builder: (c, s) {
        if (s.hasError) return Center(child: Text('Kartenfehler: ${s.error}'));
        final docs = s.data?.docs ?? [];
        final points = docs.where((d) => d.data()['lat'] is num && d.data()['lng'] is num);
        final center = pos == null ? const LatLng(51.15, 11.8) : LatLng(pos!.latitude, pos!.longitude);
        return FlutterMap(
          options: MapOptions(initialCenter: center, initialZoom: 13),
          children: [
            TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'de.pilzradar.app'),
            MarkerLayer(markers: [
              if (pos != null) Marker(point: center, width: 55, height: 55,
                child: const Icon(Icons.my_location, color: Colors.blue, size: 34)),
              if (start != null) Marker(point: start!, width: 55, height: 55,
                child: const Icon(Icons.flag, color: Colors.orange, size: 34)),
              ...points.map((d) => Marker(
                point: LatLng((d.data()['lat'] as num).toDouble(), (d.data()['lng'] as num).toDouble()),
                width: 110, height: 65,
                child: Column(children: [
                  const Icon(Icons.person_pin_circle, color: Colors.green, size: 32),
                  Text('${d.data()['name'] ?? 'Mitglied'}', maxLines: 1,
                    overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                ]),
              )),
            ]),
          ],
        );
      },
    )),
    if (start != null && pos != null) ListTile(
      title: Text('Luftlinie zum Start: ${Geolocator.distanceBetween(pos!.latitude, pos!.longitude, start!.latitude, start!.longitude).round()} m'),
      trailing: TextButton(onPressed: () => openRoute(start!.latitude, start!.longitude),
        child: const Text('Route')),
    ),
    const Padding(padding: EdgeInsets.all(8),
      child: Text('Live-Standort nur bei geöffneter App. Im iPhone-Browser kein zuverlässiges Hintergrundtracking.',
        style: TextStyle(fontSize: 11))),
  ]);
  Future<void> openRoute(double lat, double lng) async {
    final u = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=walking');
    try { if (!await launchUrl(u, mode: LaunchMode.externalApplication)) throw Exception('Karten-App nicht verfügbar'); }
    catch (e) { if (mounted) showError(context, e); }
  }

  Widget finds() => FutureBuilder<SharedPreferences>(
    future: prefsFuture,
    builder: (c, s) {
      if (s.hasError) return Center(child: Text('Speicherfehler: ${s.error}'));
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      final prefs = s.data!;
      final key = 'finds_$uid';
      List<Map<String, dynamic>> entries;
      try {
        final decoded = jsonDecode(prefs.getString(key) ?? '[]');
        entries = (decoded as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } catch (e) {
        return Center(child: Text('Funddaten konnten nicht gelesen werden: $e'));
      }
      return ListView(children: [
        ListTile(title: const Text('Private Fundorte (nur auf diesem Gerät)'),
          trailing: IconButton(icon: const Icon(Icons.add), onPressed: () => addFind(prefs, key, entries))),
        ...entries.map((e) => ListTile(
          leading: const Icon(Icons.eco), title: Text('${e['name'] ?? 'Pilzfund'}'),
          subtitle: Text('${e['date'] ?? ''}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) =>
            FindDetails(data: e, onRoute: openRoute,
              onDelete: () async {
                entries.removeWhere((item) => item['id'] == e['id']);
                await prefs.setString(key, jsonEncode(entries));
                if (mounted) setState(() {});
              }))),
        )),
        const ListTile(title: Text('Pilzbestimmung per Foto'),
          subtitle: Text('Noch nicht aktiviert. Niemals Essbarkeit allein anhand eines Fotos beurteilen.')),
      ]);
    },
  );
  Future<void> addFind(SharedPreferences prefs, String key, List<Map<String, dynamic>> entries) async {
    final p = await locate();
    if (p == null || !mounted) return;
    final ctrl = TextEditingController();
    final name = await showDialog<String>(context: context, builder: (c) => AlertDialog(
      title: const Text('Pilzfund speichern'),
      content: TextField(controller: ctrl,
        decoration: const InputDecoration(labelText: 'Pilzart / Notiz')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Abbrechen')),
        FilledButton(onPressed: () => Navigator.pop(c, ctrl.text.trim()),
          child: const Text('Speichern')),
      ],
    ));
    ctrl.dispose();
    if (name == null) return;
    entries.add({
      'id': const Uuid().v4(), 'name': name.isEmpty ? 'Pilzfund' : name,
      'lat': p.latitude, 'lng': p.longitude, 'date': DateTime.now().toIso8601String(),
    });
    try {
      await prefs.setString(key, jsonEncode(entries));
      if (mounted) setState(() {});
    } catch (e) { if (mounted) showError(context, e); }
  }

  Widget chat() {
    final ref = teamRef.collection('messages');
    return ChatPanel(key: ValueKey(teamId), messages: ref, uid: uid, name: widget.myName);
  }
}

class ChatPanel extends StatefulWidget {
  final CollectionReference<Map<String, dynamic>> messages;
  final String uid, name;
  const ChatPanel({super.key, required this.messages, required this.uid, required this.name});
  @override State<ChatPanel> createState() => _ChatPanelState();
}
class _ChatPanelState extends State<ChatPanel> {
  final input = TextEditingController();
  @override void dispose() { input.dispose(); super.dispose(); }
  Future<void> send() async {
    final text = input.text.trim();
    if (text.isEmpty) return;
    try {
      await widget.messages.add({
        'uid': widget.uid, 'name': widget.name, 'text': text,
        'createdAt': FieldValue.serverTimestamp(),
      });
      input.clear();
    } catch (e) { if (mounted) showError(context, e); }
  }
  @override Widget build(BuildContext c) => Column(children: [
    Expanded(child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: widget.messages.orderBy('createdAt', descending: true).limit(100).snapshots(),
      builder: (c, s) {
        if (s.hasError) return Center(child: Text('Chatfehler: ${s.error}'));
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        return ListView(reverse: true, children: s.data!.docs.map((d) => ListTile(
          title: Text('${d.data()['text'] ?? ''}'),
          subtitle: Text(d.data()['uid'] == widget.uid ? 'Ich' :
            '${d.data()['name'] ?? 'Teammitglied'}'),
        )).toList());
      },
    )),
    SafeArea(child: Row(children: [
      Expanded(child: TextField(controller: input, onSubmitted: (_) => send(),
        decoration: const InputDecoration(hintText: 'Nachricht an Team'))),
      IconButton(icon: const Icon(Icons.send), onPressed: send),
    ])),
  ]);
}

class RequestsPage extends StatelessWidget {
  final String team;
  final Future<void> Function(String, String) onApprove, onReject;
  const RequestsPage({super.key, required this.team, required this.onApprove, required this.onReject});
  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('Beitrittsanfragen')),
    body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('teams').doc(team)
        .collection('requests').where('status', isEqualTo: 'pending').snapshots(),
      builder: (c, s) {
        if (s.hasError) return Center(child: Text('Anfragefehler: ${s.error}'));
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        if (s.data!.docs.isEmpty) return const Center(child: Text('Keine offenen Anfragen'));
        return ListView(children: s.data!.docs.map((d) => ListTile(
          title: Text('${d.data()['name'] ?? 'Mitglied'}'),
          trailing: Wrap(children: [
            IconButton(icon: const Icon(Icons.check, color: Colors.green),
              onPressed: () => onApprove(team, d.id)),
            IconButton(icon: const Icon(Icons.close, color: Colors.red),
              onPressed: () => onReject(team, d.id)),
          ]),
        )).toList());
      },
    ),
  );
}

class MembersPage extends StatelessWidget {
  final String team, owner;
  final Future<void> Function(String, String) onRemove;
  const MembersPage({super.key, required this.team, required this.owner, required this.onRemove});
  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('Mitglieder')),
    body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('teams').doc(team).snapshots(),
      builder: (c, s) {
        if (s.hasError) return Center(child: Text('Mitgliederfehler: ${s.error}'));
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        final members = List<String>.from(s.data!.data()?['members'] ?? []);
        return ListView(children: members.map((id) => StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance.collection('users').doc(id).snapshots(),
          builder: (c, user) => ListTile(
            title: Text('${user.data?.data()?['name'] ?? (id == owner ? 'Teamleiter' : 'Mitglied')}'),
            subtitle: id == owner ? const Text('Teamleiter') : null,
            trailing: id == owner ? null : IconButton(
              icon: const Icon(Icons.person_remove),
              onPressed: () async {
                final confirm = await showDialog<bool>(context: c, builder: (dialog) => AlertDialog(
                  title: const Text('Mitglied entfernen?'),
                  content: const Text('Der Zugriff auf dieses Team wird gesperrt.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(dialog, false),
                      child: const Text('Abbrechen')),
                    FilledButton(onPressed: () => Navigator.pop(dialog, true),
                      child: const Text('Entfernen')),
                  ],
                ));
                if (confirm == true) await onRemove(team, id);
              },
            ),
          ),
        )).toList());
      },
    ),
  );
}

class FindDetails extends StatelessWidget {
  final Map<String, dynamic> data;
  final Future<void> Function(double, double) onRoute;
  final Future<void> Function() onDelete;
  const FindDetails({super.key, required this.data, required this.onRoute, required this.onDelete});
  @override Widget build(BuildContext c) {
    final lat = (data['lat'] as num?)?.toDouble();
    final lng = (data['lng'] as num?)?.toDouble();
    return Scaffold(
      appBar: AppBar(title: Text('${data['name'] ?? 'Pilzfund'}')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        ListTile(title: const Text('Notiz'), subtitle: Text('${data['name'] ?? ''}')),
        ListTile(title: const Text('Datum'), subtitle: Text('${data['date'] ?? ''}')),
        ListTile(title: const Text('Koordinaten'), subtitle: Text('$lat, $lng')),
        if (lat != null && lng != null) FilledButton.icon(
          onPressed: () => onRoute(lat, lng),
          icon: const Icon(Icons.directions), label: const Text('Route zum Fundort')),
        OutlinedButton.icon(
          onPressed: () async {
            final yes = await showDialog<bool>(context: c, builder: (dialog) => AlertDialog(
              title: const Text('Fund löschen?'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dialog, false),
                  child: const Text('Abbrechen')),
                FilledButton(onPressed: () => Navigator.pop(dialog, true),
                  child: const Text('Löschen')),
              ],
            ));
            if (yes == true) {
              await onDelete();
              if (c.mounted) Navigator.pop(c);
            }
          },
          icon: const Icon(Icons.delete_outline), label: const Text('Fund löschen')),
      ]),
    );
  }
}
