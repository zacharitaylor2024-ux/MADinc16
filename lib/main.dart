import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'firebase_options.dart';

const apiUrl =
    'https://opentdb.com/api.php?amount=5&category=17&difficulty=medium&type=boolean&encode=url3986';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const ScienceSignalApp());
}

class ScienceSignalApp extends StatelessWidget {
  const ScienceSignalApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Science Signal',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: const AuthGate(),
      );
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});
  @override
  Widget build(BuildContext context) => StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Scaffold(
                body: Center(child: CircularProgressIndicator()));
          }
          return snap.data == null
              ? const SignInPage()
              : QuizPage(key: ValueKey(snap.data!.uid), uid: snap.data!.uid);
        },
      );
}

class SignInPage extends StatefulWidget {
  const SignInPage({super.key});
  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final email = TextEditingController();
  final password = TextEditingController();
  bool busy = false;
  String error = '';
  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> signIn() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email.text.trim(), password: password.text);
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() => error = 'Sign-in failed: ${e.code}');
    } catch (_) {
      if (mounted)
        setState(() => error = 'Could not sign in. Check connection.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Science Signal • Class B')),
        body: Center(
            child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('Sign in with your Firebase test account'),
                const SizedBox(height: 16),
                TextField(
                    controller: email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'Email')),
                TextField(
                    controller: password,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Password')),
                if (error.isNotEmpty)
                  Text(error, style: const TextStyle(color: Colors.red)),
                const SizedBox(height: 16),
                FilledButton(
                    onPressed: busy ? null : signIn,
                    child: Text(busy ? 'Signing in...' : 'Sign in')),
              ])),
        )),
      );
}

class ScienceQuestion {
  final String text;
  final String correct;
  const ScienceQuestion(this.text, this.correct);
  static ScienceQuestion parse(dynamic raw) {
    if (raw is! Map<String, dynamic>)
      throw const FormatException('Not an object');
    String decoded(String key) {
      final v = raw[key];
      if (v is! String) throw const FormatException('Missing string');
      return Uri.decodeComponent(v);
    }

    final category = decoded('category');
    final question = decoded('question');
    final correct = decoded('correct_answer');
    final incorrect = raw['incorrect_answers'];
    if (incorrect is! List ||
        incorrect.length != 1 ||
        incorrect.first is! String) {
      throw const FormatException('Invalid answer list');
    }
    final wrong = Uri.decodeComponent(incorrect.first as String);
    if (category != 'Science & Nature' ||
        decoded('difficulty') != 'medium' ||
        decoded('type') != 'boolean' ||
        question.trim().isEmpty ||
        !{'True', 'False'}.contains(correct) ||
        {correct, wrong}.length != 2 ||
        !{correct, wrong}.containsAll(['True', 'False'])) {
      throw const FormatException('Question failed Class B validation');
    }
    return ScienceQuestion(question, correct);
  }
}

class QuizPage extends StatefulWidget {
  final String uid;
  const QuizPage({super.key, required this.uid});
  @override
  State<QuizPage> createState() => _QuizPageState();
}

class _QuizPageState extends State<QuizPage> {
  final db = FirebaseFirestore.instance;
  final client = http.Client();
  List<ScienceQuestion> questions = [];
  List<String?> answers = List.filled(5, null);
  int index = 0;
  String phase = 'loading';
  String message = '';
  String? roundId;
  String? lastVerifiedId;
  bool commitAcknowledged = false;
  bool injectDeniedOnce = false;
  bool injectUnavailableOnce = false;
  bool injectQuotaOnce = false;
  bool showTestingTools = false;
  DateTime? lastRequest;
  Future<void>? underlyingCommit;
  final retrieveId = TextEditingController();

  DocumentReference<Map<String, dynamic>> attemptRef(String id) =>
      db.collection('users').doc(widget.uid).collection('attempts').doc(id);
  bool get busyOrUnresolved => {
        'submitting',
        'verifying',
        'saveUnknown',
        'verificationUnavailable',
        'permissionDenied'
      }.contains(phase);
  bool get completed => answers.every((a) => a != null);
  int get score =>
      List.generate(5, (i) => answers[i] == questions[i].correct ? 1 : 0)
          .fold(0, (a, b) => a + b);
  Map<String, dynamic> get payload => {
        'schemaVersion': 1,
        'variant': 'B',
        'categoryId': 17,
        'questionCount': 5,
        'correctCount': score,
      };
  @override
  void initState() {
    super.initState();
    loadQuestions();
  }

  @override
  void dispose() {
    client.close();
    retrieveId.dispose();
    super.dispose();
  }

  void status(String next, String msg) {
    if (mounted && FirebaseAuth.instance.currentUser?.uid == widget.uid)
      setState(() {
        phase = next;
        message = msg;
      });
  }

  String errorCode(Object error) =>
      error is FirebaseException ? error.code : error.toString();

  Future<void> loadQuestions() async {
    if (busyOrUnresolved) return;
    final elapsed = lastRequest == null
        ? 999
        : DateTime.now().difference(lastRequest!).inSeconds;
    if (elapsed < 5) {
      status('requestError',
          'Wait ${5 - elapsed} seconds before retrying the API.');
      return;
    }
    status('loading', 'Loading exactly five questions...');
    lastRequest = DateTime.now();
    try {
      final res = await client
          .get(Uri.parse(apiUrl))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200)
        throw FormatException('HTTP ${res.statusCode}');
      final decoded = jsonDecode(res.body);
      if (decoded is! Map ||
          decoded['response_code'] != 0 ||
          decoded['results'] is! List ||
          (decoded['results'] as List).length != 5) {
        throw const FormatException(
            'Invalid API response code or question count');
      }
      final next = (decoded['results'] as List)
          .map((q) => ScienceQuestion.parse(q))
          .toList();
      if (!mounted) return;
      setState(() {
        questions = next;
        answers = List.filled(5, null);
        index = 0;
        roundId = db
            .collection('users')
            .doc(widget.uid)
            .collection('attempts')
            .doc()
            .id;
        commitAcknowledged = false;
        underlyingCommit = null;
        phase = 'playing';
        message = 'Ready. Round ID: $roundId';
      });
    } catch (e) {
      status('requestError', 'Could not load valid questions: $e');
    }
  }

  void choose(String value) {
    if (phase != 'playing' || answers[index] != null) return;
    setState(() => answers[index] = value);
  }

  void next() {
    if (answers[index] == null || phase != 'playing') return;
    setState(() {
      if (index < 4) {
        index++;
      } else {
        phase = 'readyToSubmit';
        message = 'Review your 5 answers before submitting.';
      }
    });
  }

  bool matches(Map<String, dynamic>? data, Map<String, dynamic> fixed) =>
      data != null &&
      data.length == 6 &&
      fixed.entries.every((e) => data[e.key] == e.value);

  Future<void> commit(String id, Map<String, dynamic> frozen) async {
    final ref = attemptRef(id);
    await db.runTransaction((txn) async {
      final existing = await txn.get(ref);
      if (existing.exists) {
        if (!matches(existing.data(), frozen))
          throw StateError(
              'COLLISION: different score/fields for this round ID');
      } else {
        txn.set(ref, {...frozen, 'submittedAt': FieldValue.serverTimestamp()});
      }
    });
  }

  Future<void> submit() async {
    if (phase != 'readyToSubmit' ||
        !completed ||
        questions.length != 5 ||
        roundId == null) return;
    final id = roundId!;
    final frozen = Map<String, dynamic>.from(payload);
    status('submitting', 'Saving one immutable attempt to Firestore...');
    try {
      final op = commit(id, frozen);
      underlyingCommit = op;
      await op.timeout(const Duration(seconds: 10));
      commitAcknowledged = true;
      await verify(id, frozen);
    } on TimeoutException {
      status('saveUnknown',
          'Save acknowledgement timed out. The operation may still complete. Reconcile this SAME ID; do not replay.');
    } catch (e) {
      status('saveUnknown',
          'Commit failed or is uncertain (${errorCode(e)}). Reconcile this ID before any retry.');
    }
  }

  Future<void> verify(String id, Map<String, dynamic> expected) async {
    status('verifying', 'Reading $id directly from the server...');
    try {
      if (injectDeniedOnce) {
        injectDeniedOnce = false;
        throw FirebaseException(
            plugin: 'cloud_firestore',
            code: 'permission-denied',
            message: 'DEV ONLY injected after commit');
      }
      if (injectUnavailableOnce) {
        injectUnavailableOnce = false;
        throw FirebaseException(
            plugin: 'cloud_firestore',
            code: 'unavailable',
            message: 'DEV ONLY injected');
      }
      if (injectQuotaOnce) {
        injectQuotaOnce = false;
        throw FirebaseException(
            plugin: 'cloud_firestore',
            code: 'resource-exhausted',
            message: 'DEV ONLY injected');
      }
      final snap = await attemptRef(id)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 10));
      final data = snap.data();
      if (!snap.exists ||
          snap.metadata.isFromCache ||
          snap.metadata.hasPendingWrites ||
          !matches(data, expected) ||
          data!['submittedAt'] is! Timestamp) {
        throw StateError(
            'Server record missing, pending, or does not match immutable fields');
      }
      if (FirebaseAuth.instance.currentUser?.uid != widget.uid ||
          roundId != id && retrieveId.text.trim() != id) return;
      setState(() {
        lastVerifiedId = id;
        phase = 'cloudVerified';
        message =
            'Cloud verified from server. ID: $id • ${data['correctCount']}/5 • ${data['submittedAt']}';
      });
    } catch (e) {
      final code = errorCode(e);
      status(
          code.contains('permission-denied')
              ? 'permissionDenied'
              : 'verificationUnavailable',
          'Write ${commitAcknowledged ? 'acknowledged' : 'not confirmed'}; verification unavailable ($code). Same ID: $id');
    }
  }

  Future<void> reconcile() async {
    if (roundId == null ||
        !{'saveUnknown', 'verificationUnavailable', 'permissionDenied'}
            .contains(phase)) return;
    final id = roundId!;
    final frozen = Map<String, dynamic>.from(payload);
    status('verifying',
        'Reconciliation: waiting for original operation, then checking server...');
    try {
      await underlyingCommit;
      commitAcknowledged = true;
    } catch (_) {/* server read resolves the known ID */}
    // If a record is present it must match; if absent, an explicit user retry can use the same ID.
    await verify(id, frozen);
  }

  Future<void> retrySameId() async {
    if (!{'saveUnknown', 'verificationUnavailable', 'permissionDenied'}
            .contains(phase) ||
        roundId == null) return;
    final id = roundId!;
    final frozen = Map<String, dynamic>.from(payload);
    status(
        'submitting', 'Retrying create-once transaction with unchanged ID...');
    try {
      await underlyingCommit; // never overlap an uncertain original operation
    } catch (_) {}
    try {
      final snap = await attemptRef(id)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 10));
      if (snap.exists) {
        commitAcknowledged = true;
        await verify(id, frozen);
        return;
      }
      final op = commit(id, frozen);
      underlyingCommit = op;
      await op.timeout(const Duration(seconds: 10));
      commitAcknowledged = true;
      await verify(id, frozen);
    } catch (e) {
      status('saveUnknown',
          'Same-ID retry cannot be confirmed (${errorCode(e)}). No new ID created.');
    }
  }

  Future<void> retrievePrevious() async {
    if (busyOrUnresolved) return;
    final id = retrieveId.text.trim();
    if (id.isEmpty) {
      status(phase, 'Enter the previous document ID.');
      return;
    }
    status('verifying', 'Retrieving previous attempt from server...');
    try {
      final snap = await attemptRef(id)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 10));
      final data = snap.data();
      if (!snap.exists ||
          snap.metadata.isFromCache ||
          snap.metadata.hasPendingWrites ||
          data == null ||
          data.length != 6 ||
          data['schemaVersion'] != 1 ||
          data['variant'] != 'B' ||
          data['categoryId'] != 17 ||
          data['questionCount'] != 5 ||
          data['correctCount'] is! int ||
          (data['correctCount'] as int) < 0 ||
          (data['correctCount'] as int) > 5 ||
          data['submittedAt'] is! Timestamp) {
        throw StateError('Record not found or schema invalid');
      }
      if (!mounted || FirebaseAuth.instance.currentUser?.uid != widget.uid)
        return;
      setState(() {
        lastVerifiedId = id;
        phase = 'cloudVerified';
        message =
            'Previous server attempt verified: $id • ${data['correctCount']}/5 • ${data['submittedAt']}';
      });
    } catch (e) {
      status('verificationUnavailable',
          'Previous attempt not verified: ${errorCode(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = questions.isNotEmpty && index < questions.length
        ? questions[index]
        : null;
    final selected = q == null ? null : answers[index];
    return Scaffold(
      appBar: AppBar(title: const Text('Science Signal • Class B'), actions: [
        IconButton(
            tooltip:
                showTestingTools ? 'Hide testing tools' : 'Show testing tools',
            onPressed: () =>
                setState(() => showTestingTools = !showTestingTools),
            icon: Icon(showTestingTools
                ? Icons.bug_report
                : Icons.bug_report_outlined)),
        IconButton(
            tooltip: 'Sign out',
            onPressed:
                busyOrUnresolved ? null : () => FirebaseAuth.instance.signOut(),
            icon: const Icon(Icons.logout)),
      ]),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Text(
            'Signed in as ${FirebaseAuth.instance.currentUser?.email ?? widget.uid}',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        if (showTestingTools)
          Text('State: $phase', style: Theme.of(context).textTheme.titleMedium),
        if (showTestingTools ||
            {
              'loading',
              'requestError',
              'submitting',
              'verifying',
              'saveUnknown',
              'verificationUnavailable',
              'permissionDenied'
            }.contains(phase))
          Text(message),
        const Divider(height: 26),
        if (phase == 'loading' || phase == 'submitting' || phase == 'verifying')
          const LinearProgressIndicator(),
        if (phase == 'requestError')
          FilledButton(
              onPressed: loadQuestions,
              child: const Text('Retry questions (5-second limit)')),
        if (q != null && (phase == 'playing' || phase == 'readyToSubmit')) ...[
          Text('Question ${index + 1} / 5',
              style: Theme.of(context).textTheme.titleLarge),
          LinearProgressIndicator(value: (index + 1) / 5),
          const SizedBox(height: 16),
          Text(q.text, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 18),
          for (final choice in ['True', 'False'])
            Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: OutlinedButton(
                    onPressed: phase == 'playing' && selected == null
                        ? () => choose(choice)
                        : null,
                    child: Text(choice))),
          if (selected != null)
            Text(
                selected == q.correct
                    ? 'Correct ✓'
                    : 'Incorrect ✗ • Correct answer: ${q.correct}',
                style: TextStyle(
                    color: selected == q.correct
                        ? Colors.green.shade700
                        : Colors.red.shade700)),
          if (phase == 'playing')
            FilledButton(
                onPressed: selected == null ? null : next,
                child: Text(index == 4 ? 'Review answers' : 'Continue')),
        ],
        if (phase == 'readyToSubmit' ||
            phase == 'submitting' ||
            phase == 'verifying' ||
            phase == 'cloudVerified' ||
            phase == 'saveUnknown' ||
            phase == 'permissionDenied' ||
            phase == 'verificationUnavailable') ...[
          if (questions.length == 5 && completed) ...[
            Text('Result: $score / 5',
                style: Theme.of(context).textTheme.titleLarge),
            for (var i = 0; i < 5; i++)
              Text(
                  '${i + 1}. Your answer: ${answers[i]} • Correct: ${questions[i].correct}'),
          ],
          if (roundId != null) SelectableText('Round ID: $roundId'),
          if (phase == 'readyToSubmit')
            FilledButton(
                onPressed: submit, child: const Text('Submit to Cloud (once)')),
          if (phase == 'saveUnknown' ||
              phase == 'permissionDenied' ||
              phase == 'verificationUnavailable') ...[
            FilledButton(
                onPressed: reconcile,
                child: const Text('Reconcile / re-read SAME ID')),
            OutlinedButton(
                onPressed: retrySameId,
                child: const Text('Retry create-once on SAME ID')),
          ],
        ],
        if (phase == 'cloudVerified') ...[
          const Text('Cloud verified ✓',
              style:
                  TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
          if (showTestingTools && lastVerifiedId != null)
            SelectableText('Verified ID: $lastVerifiedId'),
          FilledButton(
              onPressed: loadQuestions, child: const Text('Play a new round')),
        ],
        if (showTestingTools) ...[
          const Divider(height: 32),
          const Text(
              'Restart retrieval test (T07): copy an ID, restart and sign in, then retrieve:'),
          TextField(
              controller: retrieveId,
              decoration:
                  const InputDecoration(labelText: 'Existing round ID')),
          OutlinedButton(
              onPressed: busyOrUnresolved ? null : retrievePrevious,
              child: const Text('Server-only retrieve by ID')),
          const Divider(height: 32),
          const Text('Failure Injection:'),
          SwitchListTile(
              title:
                  const Text('T09: deny first verification after real commit'),
              value: injectDeniedOnce,
              onChanged: phase == 'playing' || phase == 'readyToSubmit'
                  ? (v) => setState(() => injectDeniedOnce = v)
                  : null),
          SwitchListTile(
              title: const Text('T12: inject unavailable'),
              value: injectUnavailableOnce,
              onChanged: phase == 'playing' || phase == 'readyToSubmit'
                  ? (v) => setState(() => injectUnavailableOnce = v)
                  : null),
          SwitchListTile(
              title: const Text('T12: inject resource-exhausted'),
              value: injectQuotaOnce,
              onChanged: phase == 'playing' || phase == 'readyToSubmit'
                  ? (v) => setState(() => injectQuotaOnce = v)
                  : null),
        ],
      ]),
    );
  }
}
