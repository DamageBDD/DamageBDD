import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'flow_api.dart';

const ink = Color(0xFF173734);
const muted = Color(0xFF647570);
const paper = Color(0xFFF6F8F3);
const mint = Color(0xFFE7F5ED);
const border = Color(0xFFDCE5DF);
const actionLabels = {'practice_approve':'Practice review','challenge':'Evidence challenge','propose_scenario':'Scenario draft'};
String errorMessage(Object error) {
  final code = error is FlowException ? error.code : 'unexpected_error';
  return const {
    'connection_failed':'Connection interrupted. Retry the same action; its submission key is preserved.',
    'session_expired':'Your practice session expired. Start another session to continue.',
    'demo_session_required':'Start a sandbox session before contributing.',
    'stale_bundle':'The bundle changed. Reload and inspect the current version.',
    'fresh_run_required':'Replay the current checks before recording a practice review.',
    'already_contributed':'This contribution type is already recorded for this mission.',
    'session_complete':'Your session is complete. Your receipts are in Impact.',
    'rate_limited':'Too many new sessions. Try again after a minute.',
    'demo_capacity_full':'The sandbox is at capacity. Try again later.',
    'replay_limit':'This session reached its bounded replay limit.',
  }[code] ?? 'The action could not complete: $code';
}

class FlowApp extends StatefulWidget {
  final FlowRepository repository;
  final String endpoint;
  const FlowApp({super.key, required this.repository, this.endpoint = 'Sandbox service'});
  @override State<FlowApp> createState() => _FlowAppState();
}
class _FlowAppState extends State<FlowApp> {
  final _navigator = GlobalKey<NavigatorState>();
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  List<Bundle> _bundles = [];
  final Map<String, Run> _runs = {};
  Session? _session;
  String? _error;
  bool _loading = true, _starting = false;
  int _view = 0, _budget = 3;
  String _filter = 'All';
  static const _names = ['Flow','Missions','Inbox','Impact'];
  static const _icons = [Icons.north_east, Icons.track_changes, Icons.inbox_outlined, Icons.auto_awesome_outlined];
  bool get _active => _session != null && !_session!.complete;
  @override void initState() {super.initState(); _load();}
  @override void dispose() {widget.repository.close(); super.dispose();}
  Future<void> _load() async {
    setState(() {_loading = true; _error = null;});
    try {final bundles = await widget.repository.loadBundles(); if (mounted) setState(() {_bundles = bundles; _loading = false;});}
    catch (e) {if (mounted) setState(() {_loading = false; _error = errorMessage(e);});}
  }
  void _message(String message) => _messenger.currentState?.showSnackBar(SnackBar(content: Text(message)));
  void _handleError(Object e) {
    if (!mounted) return;
    if (e is FlowException && e.status == 401) setState(() {_session = null; _runs.clear();});
    _message(errorMessage(e));
  }
  Future<void> _start() async {
    setState(() {_starting = true;});
    try {
      final session = await widget.repository.startSession(_budget);
      if (mounted) {setState(() {_session = session; _runs.clear();}); _message('Session started. Inspect a mission before contributing.');}
    } catch (e) {_handleError(e);}
    finally {if (mounted) setState(() {_starting = false;});}
  }
  Future<void> _inspect(Bundle b) async {
    await showDialog<void>(context: _navigator.currentContext!, builder: (_) => EvidenceDialog(
      bundle: b, initialRun: _runs[b.id], canContribute: _active,
      already: (kind) => _session?.has(b.id, kind) ?? false,
      replay: () async {
        try {
          final run = await widget.repository.replay(b);
          if (mounted) setState(() {_runs[b.id] = run;});
          return run;
        } catch(e) {_handleError(e); rethrow;}
      },
      contribute: (kind, run) => _contribute(b, kind, run),
    ));
  }
  Future<bool> _contribute(Bundle b, String kind, Run? run) async {
    if (!_active) {_message('Start a sandbox session first.'); return false;}
    final saved = await showDialog<bool>(context: _navigator.currentContext!, builder: (_) => ContributionDialog(
      bundle: b, kind: kind, run: run,
      submit: (note, scenario, acknowledged) async {
        try {
          final session = await widget.repository.contribute(b, kind, note,
            scenario: scenario, run: run, acknowledge: acknowledged);
          if (!mounted) return;
          setState(() {_session = session; if (session.complete) _view = 3;});
          _message('${actionLabels[kind]} recorded for practice. Nothing was merged, deployed or paid.');
        } catch(e) {if (e is FlowException && e.status == 401 && mounted) setState(() {_session = null; _runs.clear();}); rethrow;}
      },
    ));
    return saved == true;
  }
  Future<void> _receipt(Receipt receipt) async {
    await showDialog<void>(context: _navigator.currentContext!, builder: (context) => Dialog(
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 680), child: SingleChildScrollView(
        padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _dialogHeader(context, 'Your contribution receipt', 'UNSIGNED SANDBOX RECORD'),
          _notice(receipt.valid ? 'Byte-integrity check passed' : 'Byte-integrity check failed',
            'A matching SHA-256 checks these bytes. It is not a signature, proof of identity, independent acceptance or proof of correctness.'),
          const SizedBox(height: 18), Text('${actionLabels[receipt.kind]} · ${receipt.mission}', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12), Text(receipt.data['note'] as String), const SizedBox(height: 16),
          const Text('Authority: none · Real-world outcome: not measured', style: TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 16), ExpansionTile(tilePadding: EdgeInsets.zero, title: const Text('Inspect the complete receipt'),
            children: [SelectableText(receipt.exportJson, style: const TextStyle(fontFamily: 'monospace', fontSize: 11))]),
          const SizedBox(height: 18), FilledButton.icon(onPressed: () async {
            try {await Clipboard.setData(ClipboardData(text: receipt.exportJson)); if (mounted) _message('Receipt JSON copied. Paste it into a file to keep it.');}
            catch (e) {if (mounted) _message('The clipboard is unavailable. Select the receipt text to copy it.');}
          }, icon: const Icon(Icons.copy, size: 17), label: const Text('Copy receipt JSON')),
        ]),
      )),
    ));
  }
  Future<void> _reset() async {
    final result = await showDialog<bool>(context: _navigator.currentContext!, builder: (context) => AlertDialog(
      title: const Text('Another session?'), content: const Text('This replaces the history shown in the app. Copy any receipts you want to keep first. There is no penalty for stopping now.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep this session')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Choose a new session'))],
    ));
    if (result == true && mounted) setState(() {_session = null; _runs.clear(); _view = 0;});
  }
  @override Widget build(BuildContext context) => MaterialApp(
    title: 'ECAI Flow', debugShowCheckedModeBanner: false, navigatorKey: _navigator, scaffoldMessengerKey: _messenger,
    theme: ThemeData(useMaterial3: true, scaffoldBackgroundColor: paper,
      colorScheme: ColorScheme.fromSeed(seedColor: ink, brightness: Brightness.light),
      appBarTheme: const AppBarTheme(backgroundColor: paper, foregroundColor: ink, elevation: 0),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(backgroundColor: ink, foregroundColor: Colors.white,
        minimumSize: const Size(44, 46), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)))),
      inputDecorationTheme: InputDecorationTheme(border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))),
    ),
    home: LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 900;
      return Scaffold(
        appBar: AppBar(title: Row(children: [const Icon(Icons.hub_outlined, size: 25), const SizedBox(width: 10),
          const Text('ECAI Flow', style: TextStyle(fontWeight: FontWeight.w600)), if (wide) ...[
            const SizedBox(width: 24), Text('Public sandbox / ${_names[_view]}', style: const TextStyle(fontSize: 13, color: muted))]]),
          actions: const [Padding(padding: EdgeInsets.only(right: 18), child: Chip(label: Text('Sandbox', style: TextStyle(fontSize: 11))))]),
        body: SafeArea(child: Row(children: [
          if (wide) NavigationRail(extended: constraints.maxWidth >= 1200, minExtendedWidth: 210,
            backgroundColor: Colors.white, selectedIndex: _view, onDestinationSelected: (v) => setState(() {_view = v;}),
            destinations: List.generate(4, (i) => NavigationRailDestination(icon: Icon(_icons[i]), label: Text(_names[i])))),
          Expanded(child: _loading ? const Center(child: CircularProgressIndicator())
            : _error != null ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.cloud_off_outlined, size: 40, color: muted), const SizedBox(height: 16), Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 16), SelectableText(widget.endpoint, style: const TextStyle(color: muted, fontSize: 12)),
                const SizedBox(height: 18), FilledButton(onPressed: _load, child: const Text('Retry connection')),
              ])))
            : Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1150),
                child: ListView(padding: EdgeInsets.all(wide ? 32 : 20), children: [
                  if (_view == 0) ..._flow(wide),
                  if (_view == 1) ..._missions(),
                  if (_view == 2) ..._inbox(),
                  if (_view == 3) ..._impact(),
                  const SizedBox(height: 30), const Text('ECAI × DAMAGE   ·   Sandbox v0.1\nNo engagement streaks. No production approvals.', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: muted, height: 1.7)),
                ])))),
        ])),
        bottomNavigationBar: wide ? null : NavigationBar(selectedIndex: _view, onDestinationSelected: (v) => setState(() {_view = v;}),
          destinations: List.generate(4, (i) => NavigationDestination(icon: Icon(_icons[i]), label: _names[i]))),
      );
    }),
  );
  List<Widget> _flow(bool wide) {
    final hero = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _eyebrow('YOUR ATTENTION, PUT TO WORK'), const SizedBox(height: 15),
      Text('Scroll less.\nMake something better.', style: TextStyle(fontSize: wide ? 46 : 36, height: 1.07, letterSpacing: -1.4, fontWeight: FontWeight.w600, color: ink)),
      const SizedBox(height: 20), const Text('Inspect a claim. Find the missing case.\nPractice a careful review, with evidence you can open.', style: TextStyle(height: 1.6, color: muted)),
      const SizedBox(height: 16), const Wrap(spacing: 8, runSpacing: 6, children: [Chip(label: Text('Evidence first')), Chip(label: Text('Finite sessions')), Chip(label: Text('No wallet'))]),
    ]);
    final filtered = _filter == 'All' ? _bundles : _bundles.where((b) => b.mission == _filter).toList();
    return [
      if (wide) Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: hero), const SizedBox(width: 24), SizedBox(width: 290, child: _sessionCard())])
      else ...[hero, const SizedBox(height: 22), _sessionCard()],
      const SizedBox(height: 30), const Text('Something worth your attention', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: ink)),
      const SizedBox(height: 8), const Text('Four fixed missions. No manufactured urgency.', style: TextStyle(color: muted, fontSize: 12)),
      const SizedBox(height: 14), Wrap(spacing: 8, runSpacing: 6, children: ['All', ..._bundles.map((b) => b.mission)].map((f) => ChoiceChip(
        label: Text(f), selected: _filter == f, onSelected: (_) => setState(() {_filter = f;}))).toList()),
      const SizedBox(height: 16), ...filtered.map((b) => Padding(padding: const EdgeInsets.only(bottom: 18), child: _card(b))),
      const SizedBox(height: 8), const Text('You’ve reached the end of this fixture set.\nNo hidden next page. No reward for staying longer.', textAlign: TextAlign.center, style: TextStyle(color: muted, fontSize: 12, height: 1.6)),
    ];
  }
  Widget _sessionCard() {
    final s = _session;
    return Container(padding: const EdgeInsets.all(22), decoration: BoxDecoration(color: mint, borderRadius: BorderRadius.circular(16), border: Border.all(color: border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _eyebrow(s?.complete == true ? 'A GOOD PLACE TO STOP' : 'A SMALL, FINITE SESSION'), const SizedBox(height: 12),
        Text(s == null ? 'One useful thing is enough.' : s.complete ? 'You made a contribution.' : 'Small actions add up.', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: ink)),
        const SizedBox(height: 12),
        if (s == null) ...[
          const Text('Choose a budget. Stop when you’re done. No streak to protect.', style: TextStyle(fontSize: 13, color: muted, height: 1.5)), const SizedBox(height: 16),
          DropdownButtonFormField<int>(initialValue: _budget, decoration: const InputDecoration(labelText: 'Today’s practice', isDense: true),
            items: [1,3,5].map((n) => DropdownMenuItem(value: n, child: Text('$n contribution${n == 1 ? '' : 's'}'))).toList(),
            onChanged: _starting ? null : (v) => setState(() {_budget = v!;})),
          const SizedBox(height: 12), SizedBox(width: double.infinity, child: FilledButton(onPressed: _starting ? null : _start, child: Text(_starting ? 'Starting…' : 'Start sandbox session'))),
        ] else ...[
          Text('${s.count} / ${s.budget} recorded', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: ink)), const SizedBox(height: 12),
          LinearProgressIndicator(value: s.count / s.budget, semanticsLabel: 'Session contributions', semanticsValue: '${s.count} of ${s.budget}'),
          const SizedBox(height: 16), const Text('A challenge and a missing scenario count just as much as a practice review.', style: TextStyle(fontSize: 12, color: muted, height: 1.5)),
          const SizedBox(height: 12), SizedBox(width: double.infinity, child: FilledButton(onPressed: () => setState(() {_view = 3;}), child: const Text('See your receipts'))),
        ],
        const SizedBox(height: 12), const Text('History is volatile: closing this app, expiry or a server restart can end access. Copy receipts you want to keep.', style: TextStyle(fontSize: 10, color: muted, height: 1.5)),
      ]));
  }
  Widget _card(Bundle b) {
    final run = _runs[b.id];
    return Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: border)),
      padding: const EdgeInsets.all(22), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Expanded(child: _eyebrow(b.mission.toUpperCase())), const Text('Fixed fixture', style: TextStyle(fontSize: 10, color: muted))]),
        const SizedBox(height: 15), Text(b.title, style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w600, color: ink, height: 1.2)),
        const SizedBox(height: 12), Text(b.text('summary'), style: const TextStyle(color: muted, fontSize: 13, height: 1.6)),
        const SizedBox(height: 18), LayoutBuilder(builder: (context, constraints) {
          final panels = [_comparison('BEFORE', b.text('before'), paper), _comparison('CANDIDATE', b.text('after'), mint)];
          return constraints.maxWidth < 300 ? Column(children: panels) : Row(crossAxisAlignment: CrossAxisAlignment.start, children: panels.map((p) => Expanded(child: p)).toList());
        }),
        const SizedBox(height: 14), Text(run == null ? 'Versioned bundle · Checks not replayed in this session' : '${run.data['candidate_passed']}/${run.data['total']} bounded candidate checks passed · Sandbox', style: const TextStyle(color: muted, fontSize: 11)),
        const SizedBox(height: 18), Wrap(spacing: 8, runSpacing: 6, children: [
          FilledButton.icon(onPressed: () => _inspect(b), icon: const Icon(Icons.north_east, size: 15), label: const Text('Inspect evidence')),
          TextButton(onPressed: _active && !(_session?.has(b.id,'propose_scenario') ?? false) ? () => _contribute(b,'propose_scenario',run) : null, child: const Text('Add a scenario')),
          TextButton(onPressed: _active && !(_session?.has(b.id,'challenge') ?? false) ? () => _contribute(b,'challenge',run) : null, child: const Text('Challenge')),
        ]),
      ]));
  }
  List<Widget> _missions() => [
    _pageHeading('CHOOSE WHAT YOU CARE ABOUT', 'Different systems.\nThe same careful questions.', 'Every mission has an explicit claim, an illustrative patch, bounded examples and visible limitations. No live operational data is connected.'),
    ..._bundles.map((b) => Card(margin: const EdgeInsets.only(bottom: 14), child: Padding(padding: const EdgeInsets.all(22), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(b.mission, style: const TextStyle(fontSize: 23, color: ink, fontWeight: FontWeight.w600)), const SizedBox(height: 10), Text(b.text('summary'), style: const TextStyle(height: 1.6, color: muted)),
      const SizedBox(height: 14), OutlinedButton(onPressed: () => _inspect(b), child: const Text('Open mission ↗')),
    ])))),
  ];
  List<Widget> _inbox() => [
    _pageHeading('YOUR ACTIVITY, WITHOUT THE NOISE', 'Inbox', 'This version records your own sandbox contributions. No maintainer acceptance, public reputation or production approval is implied.'),
    ..._receiptRows(),
  ];
  List<Widget> _impact() {
    final receipts = _session?.receipts ?? <Receipt>[];
    return [
      _pageHeading('A RECORD, NOT A SCOREBOARD', _session?.complete == true ? 'A good place to stop.' : 'What your attention produced.', 'These are practice contributions—not accepted repairs, saved money or measured real-world outcomes. Copy receipts you want to keep.'),
      Wrap(spacing: 12, runSpacing: 12, children: [
        _metric('${receipts.length}', 'Practice contributions'),
        _metric('${receipts.map((r) => r.data['mission_id']).toSet().length}', 'Missions contributed to'),
        _metric('0', 'Production actions authorized'),
      ]), const SizedBox(height: 24), ..._receiptRows(), const SizedBox(height: 20),
      const Text('No streak. No penalty for stopping.', textAlign: TextAlign.center, style: TextStyle(color: muted)),
      TextButton(onPressed: () => setState(() {_view = 0;}), child: const Text('Back to discovery')),
      if (_session != null) TextButton(onPressed: _reset, child: const Text('Start another session')),
    ];
  }
  List<Widget> _receiptRows() {
    final receipts = _session?.receipts ?? <Receipt>[];
    if (receipts.isEmpty) return [const Padding(padding: EdgeInsets.symmetric(vertical: 30), child: Text('No contributions recorded yet. Start a session and ask a useful question.', textAlign: TextAlign.center, style: TextStyle(color: muted, height: 1.6)))];
    return receipts.map((r) => Card(margin: const EdgeInsets.only(bottom: 12), child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${actionLabels[r.kind]} · ${r.mission}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
      const SizedBox(height: 8), const Text('Recorded for practice · No production authority', style: TextStyle(color: muted, fontSize: 12)),
      const SizedBox(height: 10), OutlinedButton(onPressed: () => _receipt(r), child: const Text('Open receipt ↗')),
    ])))).toList();
  }
}

Widget _eyebrow(String text) => Text(text, style: const TextStyle(color: Color(0xFF0B674D), fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.1));
Widget _comparison(String title, String text, Color color) => Container(width: double.infinity, padding: const EdgeInsets.all(15), color: color,
  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_eyebrow(title), const SizedBox(height: 7), Text(text, style: const TextStyle(fontSize: 12, height: 1.5))]));
Widget _pageHeading(String eyebrow, String title, String description) => Padding(padding: const EdgeInsets.only(bottom: 26), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
  _eyebrow(eyebrow), const SizedBox(height: 16), Text(title, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w600, color: ink, letterSpacing: -1, height: 1.15)), const SizedBox(height: 16), Text(description, style: const TextStyle(color: muted, height: 1.6)),
]));
Widget _metric(String count, String title) => Container(width: 180, padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: Colors.white, border: Border.all(color: border), borderRadius: BorderRadius.circular(12)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
  Text(count, style: const TextStyle(fontSize: 32, color: ink, fontWeight: FontWeight.w600)), const SizedBox(height: 10), Text(title, style: const TextStyle(fontSize: 12, color: muted)),
]));
Widget _notice(String title, String description) => Container(width: double.infinity, padding: const EdgeInsets.all(15), decoration: BoxDecoration(color: const Color(0xFFFCF0DB), borderRadius: BorderRadius.circular(10)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
  Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)), const SizedBox(height: 6), Text(description, style: const TextStyle(fontSize: 12, height: 1.6)),
]));
Widget _dialogHeader(BuildContext context, String title, String eyebrow) => Padding(padding: const EdgeInsets.only(bottom: 18), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_eyebrow(eyebrow), const SizedBox(height: 10), Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: ink))])),
  IconButton(onPressed: () => Navigator.pop(context), tooltip: 'Close dialog', icon: const Icon(Icons.close)),
]));

class EvidenceDialog extends StatefulWidget {
  final Bundle bundle;
  final Run? initialRun;
  final bool canContribute;
  final bool Function(String) already;
  final Future<Run> Function() replay;
  final Future<bool> Function(String, Run?) contribute;
  const EvidenceDialog({super.key, required this.bundle, this.initialRun, required this.canContribute,
    required this.already, required this.replay, required this.contribute});
  @override State<EvidenceDialog> createState() => _EvidenceDialogState();
}
class _EvidenceDialogState extends State<EvidenceDialog> {
  Run? _run;
  bool _busy = false;
  String? _error;
  @override void initState() {super.initState(); _run = widget.initialRun;}
  Future<void> _replay() async {
    setState(() {_busy = true; _error = null;});
    try {final run = await widget.replay(); if (mounted) setState(() {_run = run;});}
    catch (e) {if (mounted) setState(() {_error = errorMessage(e);});}
    finally {if (mounted) setState(() {_busy = false;});}
  }
  Future<void> _contribute(String kind) async {
    final saved = await widget.contribute(kind, _run);
    if (saved && mounted) Navigator.pop(context);
  }
  @override Widget build(BuildContext context) {
    final b = widget.bundle;
    return Dialog(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 780), child: SingleChildScrollView(padding: const EdgeInsets.all(22), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _dialogHeader(context, b.title, 'SANDBOX · NO PRODUCTION AUTHORITY'),
      _notice('${b.mission} · Illustrative fixture', 'Not a repository change. No real assets are affected. These examples are not a proof of general correctness.'),
      const SizedBox(height: 18), Text(b.text('question'), style: const TextStyle(height: 1.6)), const SizedBox(height: 16),
      ...['given','when','then'].map((k) => Padding(padding: const EdgeInsets.only(bottom: 8), child: _comparison(k.toUpperCase(), b.text(k), mint))),
      const SizedBox(height: 20), const Text('Replay the fixed examples', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)), const SizedBox(height: 10),
      Text(widget.canContribute ? 'This evaluates packaged fixtures, never submitted code or scenario drafts.' : 'Start a session from Flow to replay the examples.', style: const TextStyle(color: muted, fontSize: 12, height: 1.6)),
      const SizedBox(height: 12), FilledButton.icon(onPressed: widget.canContribute && !_busy ? _replay : null, icon: const Icon(Icons.play_arrow, size: 18), label: Text(_busy ? 'Replaying…' : _run == null ? 'Run fixed checks' : 'Replay checks again')),
      if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      if (_run != null) ...[
        const SizedBox(height: 18), ..._run!.checks.map((c) => Container(padding: const EdgeInsets.symmetric(vertical: 12), decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: border))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c['name'] as String, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)), const SizedBox(height: 7),
          Text('Expected: ${jsonEncode(c['expected'])}', style: const TextStyle(fontSize: 11, color: muted)), const SizedBox(height: 8),
          Wrap(spacing: 15, runSpacing: 7, children: [
            Text('Baseline: ${c['baseline_pass'] == true ? 'PASS' : 'FAIL'} · ${jsonEncode(c['baseline'])}', style: TextStyle(fontSize: 11, color: c['baseline_pass'] == true ? ink : const Color(0xFF9F3B34))),
            Text('Candidate: ${c['candidate_pass'] == true ? 'PASS' : 'FAIL'} · ${jsonEncode(c['candidate'])}', style: const TextStyle(fontSize: 11, color: ink)),
          ]),
        ]))), const SizedBox(height: 12), SelectableText('Run: ${_run!.id}\nEngine: ${_run!.data['engine']}\nDamageBDD runner executed: no · Outcome: not measured', style: const TextStyle(fontSize: 10, color: muted, height: 1.6)),
      ], const SizedBox(height: 18),
      ExpansionTile(tilePadding: EdgeInsets.zero, title: const Text('Inspect the illustrative patch'), children: [
        SelectableText(b.text('patch'), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('The diff illustrates the fixed evaluator. It is not queued for merging.', style: TextStyle(fontSize: 12, color: muted))),
      ]),
      ExpansionTile(tilePadding: EdgeInsets.zero, title: const Text('Read the DamageBDD scenario'), children: [
        SelectableText(b.text('feature'), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('The packaged Damage step adapter can execute the same checks. The replay button uses the fixture evaluator directly, not the Damage feature runner.', style: TextStyle(fontSize: 12, color: muted, height: 1.5))),
      ]),
      ExpansionTile(tilePadding: EdgeInsets.zero, initiallyExpanded: true, title: const Text('What this does not establish'), children: b.limitations.map((x) => Padding(padding: const EdgeInsets.only(bottom: 10), child: Align(alignment: Alignment.centerLeft, child: Text('• $x', style: const TextStyle(fontSize: 12, color: muted, height: 1.6))))).toList()),
      ExpansionTile(tilePadding: EdgeInsets.zero, title: const Text('Version identity and fixture data'), children: [
        SelectableText('Bundle SHA-256: ${b.digest}\nRunner: ${b.text('runner_version')}\nPolicy: ${b.text('policy_version')}', style: const TextStyle(fontFamily: 'monospace', fontSize: 10, height: 1.6)),
        const SizedBox(height: 15), SelectableText(const JsonEncoder.withIndent('  ').convert(b.data['cases']), style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
      ]), const SizedBox(height: 20),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final kind in ['propose_scenario','challenge']) OutlinedButton(onPressed: widget.canContribute && !_busy && !widget.already(kind) ? () => _contribute(kind) : null, child: Text(actionLabels[kind]!)),
        FilledButton(onPressed: widget.canContribute && !_busy && _run?.passed == true && !widget.already('practice_approve') ? () => _contribute('practice_approve') : null, child: const Text('Practice review')),
      ]),
    ]))));
  }
}

class ContributionDialog extends StatefulWidget {
  final Bundle bundle;
  final String kind;
  final Run? run;
  final Future<void> Function(String, Json?, bool) submit;
  const ContributionDialog({super.key, required this.bundle, required this.kind, this.run, required this.submit});
  @override State<ContributionDialog> createState() => _ContributionDialogState();
}
class _ContributionDialogState extends State<ContributionDialog> {
  final _form = GlobalKey<FormState>();
  final _note = TextEditingController();
  final _scenario = {for (final k in ['given','when','then']) k: TextEditingController()};
  bool _ack = false, _busy = false;
  String? _error;
  @override void dispose() {_note.dispose(); for(final c in _scenario.values) {c.dispose();} super.dispose();}
  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    if (widget.kind == 'practice_approve' && !_ack) {setState(() {_error = 'Acknowledge the exact scope before recording a practice review.';}); return;}
    setState(() {_busy = true; _error = null;});
    try {
      final scenario = widget.kind == 'propose_scenario' ? {for(final e in _scenario.entries) e.key:e.value.text.trim()} : null;
      await widget.submit(_note.text.trim(), scenario, _ack);
      if (mounted) Navigator.pop(context, true);
    } catch(e) {if (mounted) setState(() {_error = errorMessage(e); _busy = false;});}
  }
  @override Widget build(BuildContext context) {
    final kind = widget.kind;
    return Dialog(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 680), child: SingleChildScrollView(padding: const EdgeInsets.all(22), child: Form(key: _form, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _dialogHeader(context, actionLabels[kind]!, '${widget.bundle.mission.toUpperCase()} · PRACTICE ONLY'),
      Text(kind == 'practice_approve' ? 'Record that you inspected these exact examples and their limitations. This is not permission to merge, deploy or spend.'
        : kind == 'challenge' ? 'Point out missing evidence or an untested assumption. A well-supported “not ready” matters.'
        : 'Describe a missing behavior. This draft will not be executed or silently added to the accepted specification.', style: const TextStyle(color: muted, height: 1.6, fontSize: 13)),
      const SizedBox(height: 20),
      if (kind == 'propose_scenario') ..._scenario.entries.map((e) => Padding(padding: const EdgeInsets.only(bottom: 16), child: TextFormField(controller: e.value,
        decoration: InputDecoration(labelText: '${e.key[0].toUpperCase()}${e.key.substring(1)}'), maxLength: 500, minLines: 1, maxLines: 3,
        validator: (v) => (v?.trim().length ?? 0) < 3 ? 'Use at least three characters.' : null))),
      TextFormField(controller: _note, minLines: 3, maxLines: 6, maxLength: 2000,
        decoration: InputDecoration(labelText: kind == 'practice_approve' ? 'What did you inspect? What remains out of scope?' : 'Why does this matter?'),
        validator: (v) => (v?.trim().length ?? 0) < 8 ? 'Add a specific note of at least eight characters.' : null),
      if (kind == 'practice_approve') ...[
        const SizedBox(height: 14), SelectableText('Bundle: ${widget.bundle.digest}\nRun: ${widget.run?.id}\nEvidence: ${widget.run?.digest}', style: const TextStyle(fontFamily: 'monospace', fontSize: 10, height: 1.7, color: muted)),
        const SizedBox(height: 12), CheckboxListTile(value: _ack, onChanged: _busy ? null : (v) => setState(() {_ack = v == true;}), contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('I reviewed this bundle, these checks and their limitations. This is an unsigned practice record, not a production approval.', style: TextStyle(fontSize: 12, height: 1.5))),
      ],
      if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      const SizedBox(height: 16), Wrap(spacing: 10, runSpacing: 10, children: [
        OutlinedButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Keep inspecting')),
        FilledButton(onPressed: _busy ? null : _submit, child: Text(_busy ? 'Recording…' : kind == 'practice_approve' ? 'Record practice review' : kind == 'challenge' ? 'Record challenge' : 'Save scenario draft')),
      ]),
    ])))));
  }
}
