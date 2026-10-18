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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (firebaseKey.isNotEmpty) {
    await Firebase.initializeApp(options: FirebaseOptions(apiKey: firebaseKey, appId: firebaseApp,
      messagingSenderId: firebaseSender, projectId: firebaseProject));
  }
  runApp(const PilzApp());
}

class PilzApp extends StatelessWidget {
  const PilzApp({super.key});
  @override Widget build(BuildContext context) => MaterialApp(
    title: 'PILZRADAR', debugShowCheckedModeBanner: false,
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff326747)), useMaterial3: true),
    home: firebaseKey.isEmpty ? const SetupPage() : StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(), builder: (context,s) =>
        s.data == null ? const LoginPage() : const HomePage()));
}
class SetupPage extends StatelessWidget {
  const SetupPage({super.key});
  @override Widget build(BuildContext context) => const Scaffold(body: Center(child: Padding(
    padding: EdgeInsets.all(24), child: Text('PILZRADAR – Firebase noch nicht eingerichtet. Trage die vier Firebase-Werte als GitHub-Secrets ein und starte den APK-Build erneut.', textAlign: TextAlign.center))));
}
class LoginPage extends StatefulWidget { const LoginPage({super.key}); @override State<LoginPage> createState()=>_LoginPageState(); }
class _LoginPageState extends State<LoginPage> {
  final email=TextEditingController(), pass=TextEditingController(); bool register=false, busy=false;
  Future<void> submit() async { setState(()=>busy=true); try {
    if(register) {await FirebaseAuth.instance.createUserWithEmailAndPassword(email:email.text.trim(),password:pass.text);}
    else {await FirebaseAuth.instance.signInWithEmailAndPassword(email:email.text.trim(),password:pass.text);}
  } catch(e) {if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));} finally {if(mounted)setState(()=>busy=false);} }
  @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('PILZRADAR')),body:Center(child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:420),child:Padding(padding:const EdgeInsets.all(20),child:Column(mainAxisSize:MainAxisSize.min,children:[
    const Icon(Icons.forest,size:80,color:Colors.green),TextField(controller:email,keyboardType:TextInputType.emailAddress,decoration:const InputDecoration(labelText:'E-Mail')),
    TextField(controller:pass,obscureText:true,decoration:const InputDecoration(labelText:'Passwort (mindestens 6 Zeichen)')),
    const SizedBox(height:20),FilledButton(onPressed:busy?null:submit,child:Text(register?'Registrieren':'Anmelden')),
    TextButton(onPressed:()=>setState(()=>register=!register),child:Text(register?'Bereits registriert? Anmelden':'Neues Konto erstellen'))])))));
}
class HomePage extends StatefulWidget {const HomePage({super.key});@override State<HomePage> createState()=>_HomePageState();}
class _HomePageState extends State<HomePage> {
  String? teamId; int tab=0; Position? pos; LatLng? start; Timer? timer; bool tracking=false;
  final db=FirebaseFirestore.instance; String get uid=>FirebaseAuth.instance.currentUser!.uid;
  @override void initState(){super.initState();_restore();}
  Future<void> _restore() async {final p=await SharedPreferences.getInstance(); if(mounted)setState(()=>teamId=p.getString('team'));}
  Future<void> locate() async {try {if(!await Geolocator.isLocationServiceEnabled())throw Exception('GPS aktivieren');
    var perm=await Geolocator.checkPermission();if(perm==LocationPermission.denied)perm=await Geolocator.requestPermission();
    if(perm==LocationPermission.denied||perm==LocationPermission.deniedForever)throw Exception('Standortberechtigung fehlt');
    final p=await Geolocator.getCurrentPosition();if(mounted)setState(()=>pos=p);
  }catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));}}
  Future<void> share() async {if(teamId==null)return;await locate();if(pos==null)return;
    await db.collection('teams').doc(teamId).collection('locations').doc(uid).set({
      'uid':uid,'lat':pos!.latitude,'lng':pos!.longitude,'updatedAt':FieldValue.serverTimestamp()});}
  Future<void> toggleTracking() async {if(tracking){timer?.cancel();setState(()=>tracking=false);
    if(teamId!=null)await db.collection('teams').doc(teamId).collection('locations').doc(uid).delete();
  }else{await share();if(pos==null)return;setState(()=>tracking=true);timer=Timer.periodic(const Duration(seconds:20),(_)=>share());}}
  @override void dispose(){timer?.cancel();super.dispose();}
  Future<void> createTeam() async {final name=TextEditingController();await showDialog(context:context,builder:(c)=>AlertDialog(title:const Text('Team erstellen'),content:TextField(controller:name,decoration:const InputDecoration(labelText:'Teamname')),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('Abbrechen')),FilledButton(onPressed:()async {if(name.text.trim().isEmpty)return;
    final ref=await db.collection('teams').add({'name':name.text.trim(),'owner':uid,'members':[uid],'createdAt':FieldValue.serverTimestamp()});
    if(c.mounted)Navigator.pop(c);await selectTeam(ref.id);
  },child:const Text('Erstellen'))]));}
  Future<void> inviteMember(QueryDocumentSnapshot<Map<String,dynamic>> doc) async {
    if(doc.data()['owner']!=uid){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Nur der Teamleiter kann Mitglieder hinzufügen.')));return;}
    final ctrl=TextEditingController();
    await showDialog(context:context,builder:(c)=>AlertDialog(title:const Text('Mitglied hinzufügen'),
      content:TextField(controller:ctrl,decoration:const InputDecoration(labelText:'Firebase Nutzer-UID')),
      actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('Abbrechen')),
        FilledButton(onPressed:()async{final id=ctrl.text.trim();if(id.isEmpty)return;
          try{await doc.reference.update({'members':FieldValue.arrayUnion([id])});if(c.mounted)Navigator.pop(c);}
          catch(e){if(c.mounted)ScaffoldMessenger.of(c).showSnackBar(SnackBar(content:Text('$e')));}
        },child:const Text('Hinzufügen'))]));
  }
  Future<void> selectTeam(String id)async{if(tracking)await toggleTracking();final p=await SharedPreferences.getInstance();await p.setString('team',id);setState((){teamId=id;tab=0;});}
  Future<void> sos()async{if(teamId==null)return;await locate();if(pos==null)return;
    await db.collection('teams').doc(teamId).collection('messages').add({'uid':uid,'text':'🆘 SOS! Ich brauche Hilfe. Standort: ${pos!.latitude}, ${pos!.longitude}','createdAt':FieldValue.serverTimestamp(),'sos':true});
    if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('SOS an Teamchat gesendet. Bei akuter Gefahr 112 anrufen!')));
  }
  @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('🍄 PILZRADAR'),actions:[IconButton(onPressed:()=>FirebaseAuth.instance.signOut(),icon:const Icon(Icons.logout))]),
    body:teamId==null?_teams():Column(children:[SizedBox(height:56,child:StreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(stream:db.collection('teams').doc(teamId).snapshots(),builder:(c,s){if(!s.hasData||!s.data!.exists)return const Center(child:Text('Team wird geladen…'));final d=s.data!.data()!;return Row(children:[Expanded(child:Padding(padding:const EdgeInsets.all(12),child:Text('Team: ${d['name']}',overflow:TextOverflow.ellipsis))),TextButton(onPressed:()=>setState(()=>teamId=null),child:const Text('Wechseln'))]);})),Expanded(child:tab==0?_map():tab==1?_finds():tab==2?_chat():_teams())]),
    bottomNavigationBar:teamId==null?null:NavigationBar(selectedIndex:tab,onDestinationSelected:(v)=>setState(()=>tab=v),destinations:const [NavigationDestination(icon:Icon(Icons.map),label:'Karte'),NavigationDestination(icon:Icon(Icons.eco),label:'Funde'),NavigationDestination(icon:Icon(Icons.chat),label:'Chat'),NavigationDestination(icon:Icon(Icons.groups),label:'Teams')]));
  Widget _teams()=>StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:db.collection('teams').where('members',arrayContains:uid).snapshots(),builder:(c,s){final docs=s.data?.docs??[];return ListView(children:[const ListTile(title:Text('Meine Teams'),subtitle:Text('Nur Teammitglieder sehen Teamdaten.')),
    ...docs.map((d)=>ListTile(title:Text('${d.data()['name']}'),subtitle:Text('Team-ID: ${d.id}'),trailing:IconButton(icon:const Icon(Icons.person_add),onPressed:()=>inviteMember(d)),onTap:()=>selectTeam(d.id))),
    ListTile(leading:const Icon(Icons.add),title:const Text('Neues Team erstellen'),onTap:createTeam),
    const Padding(padding:EdgeInsets.all(16),child:Text('Teamleiter können Mitglieder über deren Firebase Nutzer-UID hinzufügen. Einladungslinks folgen in Version 1.1.'))]);});
  Widget _map()=>Column(children:[Wrap(spacing:6,children:[FilledButton.tonal(onPressed:locate,child:const Text('Mein GPS')),FilledButton.tonal(onPressed:toggleTracking,child:Text(tracking?'Tracking stoppen':'Live teilen')),FilledButton.tonal(onPressed:()=>setState(()=>start=pos==null?null:LatLng(pos!.latitude,pos!.longitude)),child:const Text('Start merken')),FilledButton(onPressed:sos,style:FilledButton.styleFrom(backgroundColor:Colors.red),child:const Text('SOS'))]),
    Expanded(child:StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:db.collection('teams').doc(teamId).collection('locations').snapshots(),builder:(c,s){final members=s.data?.docs??[];final points=members.where((e)=>e.data()['lat']!=null).toList();final center=pos==null?const LatLng(51.15,11.8):LatLng(pos!.latitude,pos!.longitude);
    return FlutterMap(options:MapOptions(initialCenter:center,initialZoom:13),children:[TileLayer(urlTemplate:'https://tile.openstreetmap.org/{z}/{x}/{y}.png',userAgentPackageName:'de.pilzradar.app'),MarkerLayer(markers:[
      if(pos!=null)Marker(point:center,width:60,height:55,child:const Icon(Icons.my_location,color:Colors.blue,size:34)),
      if(start!=null)Marker(point:start!,width:60,height:55,child:const Icon(Icons.flag,color:Colors.orange,size:34)),
      ...points.map((e)=>Marker(point:LatLng((e.data()['lat'] as num).toDouble(),(e.data()['lng'] as num).toDouble()),width:90,height:70,child:Column(children:[const Icon(Icons.person_pin_circle,color:Colors.green,size:34),Text(e.id==uid?'Ich':e.id.substring(0,min(6,e.id.length)),style:const TextStyle(fontSize:10))])))])]);})),
    if(start!=null&&pos!=null)ListTile(title:Text('Luftlinie zum Start: ${Geolocator.distanceBetween(pos!.latitude,pos!.longitude,start!.latitude,start!.longitude).round()} m'),trailing:TextButton(onPressed:()async {final u=Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${start!.latitude},${start!.longitude}&travelmode=walking');await launchUrl(u,mode:LaunchMode.externalApplication);},child:const Text('Route öffnen'))),
    const Padding(padding:EdgeInsets.all(8),child:Text('Live nur bei geöffneter App und Internet. Kartenkacheln benötigen Internet; gespeicherte Funde bleiben offline verfügbar.',style:TextStyle(fontSize:11)))]);
  Widget _finds()=>FutureBuilder<SharedPreferences>(future:SharedPreferences.getInstance(),builder:(c,s){if(!s.hasData)return const Center(child:CircularProgressIndicator());final prefs=s.data!;final key='finds_$uid';final entries=(jsonDecode(prefs.getString(key)??'[]') as List).cast<Map<String,dynamic>>();return ListView(children:[ListTile(title:const Text('Private Fundorte (offline)'),trailing:IconButton(onPressed:()async{await locate();if(pos==null)return;final name=TextEditingController();if(!mounted)return;await showDialog(context:context,builder:(d)=>AlertDialog(title:const Text('Pilzfund speichern'),content:TextField(controller:name,decoration:const InputDecoration(labelText:'Pilzart / Notiz')),actions:[TextButton(onPressed:()=>Navigator.pop(d),child:const Text('Abbrechen')),FilledButton(onPressed:()async{entries.add({'id':const Uuid().v4(),'name':name.text,'lat':pos!.latitude,'lng':pos!.longitude,'date':DateTime.now().toIso8601String()});await prefs.setString(key,jsonEncode(entries));if(d.mounted)Navigator.pop(d);setState((){});},child:const Text('Speichern'))]));},icon:const Icon(Icons.add))),
      ...entries.map((e)=>ListTile(leading:const Icon(Icons.eco),title:Text('${e['name']}'),subtitle:Text('${e['date']} · ${e['lat']}, ${e['lng']}'))),
      const ListTile(title:Text('Pilzbestimmung per Foto'),subtitle:Text('Noch nicht aktiviert. Fotos allein reichen nicht für eine sichere Essbarkeitsbestimmung.'))]);});
  Widget _chat(){final ref=db.collection('teams').doc(teamId).collection('messages');final input=TextEditingController();return Column(children:[Expanded(child:StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:ref.orderBy('createdAt',descending:true).limit(100).snapshots(),builder:(c,s)=>ListView(children:(s.data?.docs??[]).map((d)=>ListTile(title:Text('${d.data()['text']}'),subtitle:Text(d.data()['uid']==uid?'Ich':d.data()['uid'].toString().substring(0,6)))).toList()))),
    Row(children:[Expanded(child:TextField(controller:input,decoration:const InputDecoration(hintText:'Nachricht an Team'))),IconButton(icon:const Icon(Icons.send),onPressed:()async{if(input.text.trim().isEmpty)return;await ref.add({'uid':uid,'text':input.text.trim(),'createdAt':FieldValue.serverTimestamp()});input.clear();})])]);}
}
