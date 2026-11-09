import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------- data

class Book {
  final String id;
  String path;
  String name;
  int pages;
  int last;
  int added;
  int opened;
  bool fav;
  List<int> bm;

  Book({
    required this.id,
    required this.path,
    required this.name,
    this.pages = 0,
    this.last = 1,
    this.added = 0,
    this.opened = 0,
    this.fav = false,
    List<int>? bm,
  }) : bm = bm ?? <int>[];

  // The title is exactly the file name, without the extension.
  String get title => name.replaceFirst(RegExp(r'\.[^.]+$'), '');

  String get series {
    final base = title.replaceAll(RegExp(r'[_.]+'), ' ').trim();
    final s = base
        .replaceFirst(
          RegExp(r'[\s\-–:,]*(vol(ume)?\.?|part|book|bk|ch(apter)?|#)?\s*\(?\d+\)?\s*$',
              caseSensitive: false),
          '',
        )
        .trim();
    return (s.length > 2 && s != base) ? s : '';
  }

  String get author {
    if (title.contains(' - ')) {
      final a = title.split(' - ').last.trim();
      if (a.split(' ').length <= 4) return a;
    }
    return '';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'path': path,
        'name': name,
        'pages': pages,
        'last': last,
        'added': added,
        'opened': opened,
        'fav': fav,
        'bm': bm,
      };

  factory Book.fromJson(Map<String, dynamic> j) => Book(
        id: j['id'] as String,
        path: j['path'] as String,
        name: j['name'] as String,
        pages: (j['pages'] ?? 0) as int,
        last: (j['last'] ?? 1) as int,
        added: (j['added'] ?? 0) as int,
        opened: (j['opened'] ?? 0) as int,
        fav: (j['fav'] ?? false) as bool,
        bm: ((j['bm'] ?? <dynamic>[]) as List).map((e) => e as int).toList(),
      );
}

class TocItem {
  final String title;
  final int level;
  final int page;
  TocItem(this.title, this.level, this.page);
}

class Store {
  static late SharedPreferences sp;
  static List<Book> books = [];

  static Future<void> init() async {
    sp = await SharedPreferences.getInstance();
    final s = sp.getString('books');
    if (s != null) {
      books = (jsonDecode(s) as List)
          .map((e) => Book.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    modeN.value = sp.getInt('mode') ?? 0;
  }

  static Future<void> save() async {
    await sp.setString('books', jsonEncode(books.map((b) => b.toJson()).toList()));
  }

  static Future<void> setMode(int m) async {
    modeN.value = m;
    await sp.setInt('mode', m);
  }
}

// 0 = light, 1 = sepia, 2 = dark
final ValueNotifier<int> modeN = ValueNotifier<int>(0);

// ---------------------------------------------------------------- app

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Store.init();
  runApp(const ReaderApp());
}

class ReaderApp extends StatelessWidget {
  const ReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: modeN,
      builder: (context, m, _) {
        final dark = m == 2;
        final scheme = ColorScheme.fromSeed(
          seedColor: const Color(0xFF007AFF),
          brightness: dark ? Brightness.dark : Brightness.light,
        );
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Reader',
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: scheme,
            scaffoldBackgroundColor: m == 1
                ? const Color(0xFFF4ECD8)
                : (dark ? Colors.black : const Color(0xFFF2F2F7)),
          ),
          home: const LibraryPage(),
        );
      },
    );
  }
}

Widget glass(Widget child, {double radius = 24}) {
  final dark = modeN.value == 2;
  return ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
      child: Container(
        decoration: BoxDecoration(
          color: (dark ? const Color(0xFF1C1C1E) : Colors.white).withAlpha(dark ? 195 : 205),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: Colors.white.withAlpha(dark ? 40 : 170)),
        ),
        child: child,
      ),
    ),
  );
}

// ---------------------------------------------------------------- library

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  int tab = 0;
  String query = '';

  String get greeting {
    final h = DateTime.now().hour;
    final part = h < 12 ? 'morning' : (h < 17 ? 'afternoon' : 'evening');
    return 'Good $part boss';
  }

  Future<void> _add() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      allowMultiple: true,
    );
    if (res == null) return;
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/books');
    if (!await folder.exists()) await folder.create(recursive: true);
    var n = 0;
    for (final f in res.files) {
      final src = f.path;
      if (src == null) continue;
      n++;
      final id = '${DateTime.now().microsecondsSinceEpoch}$n';
      final dest = '${folder.path}/$id.pdf';
      try {
        await File(src).rename(dest);
      } catch (_) {
        await File(src).copy(dest);
      }
      Store.books.add(Book(
        id: id,
        path: dest,
        name: f.name,
        added: DateTime.now().millisecondsSinceEpoch,
      ));
    }
    await Store.save();
    if (mounted) setState(() {});
  }

  Future<void> _open(Book b) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ReaderPage(book: b)),
    );
    if (mounted) setState(() {});
  }

  void _menu(Book b) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(b.fav ? Icons.star : Icons.star_border),
              title: Text(b.fav ? 'Remove from favorites' : 'Add to favorites'),
              onTap: () {
                b.fav = !b.fav;
                Store.save();
                Navigator.pop(ctx);
                setState(() {});
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Remove from library'),
              onTap: () async {
                Navigator.pop(ctx);
                Store.books.remove(b);
                try {
                  await File(b.path).delete();
                } catch (_) {}
                await Store.save();
                if (mounted) setState(() {});
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(Book b) {
    final prog = b.pages > 0 ? (b.last / b.pages).clamp(0.0, 1.0) : 0.0;
    return GestureDetector(
      onTap: () => _open(b),
      onLongPress: () => _menu(b),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(60),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Cover(b),
                  if (b.fav)
                    const Positioned(
                      top: 6,
                      right: 6,
                      child: Icon(Icons.star, color: Colors.amber, size: 18),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            b.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: prog, minHeight: 3),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final q = query.toLowerCase();
    var list = Store.books
        .where((b) => q.isEmpty || (b.title + b.author + b.series).toLowerCase().contains(q))
        .toList();
    if (tab == 3) list = list.where((b) => b.fav).toList();
    list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

    final groups = <String, List<Book>>{};
    for (final b in list) {
      final k = tab == 1
          ? (b.series.isEmpty ? 'No series' : b.series)
          : (tab == 2 ? (b.author.isEmpty ? 'Unknown author' : b.author) : '');
      (groups[k] ??= <Book>[]).add(b);
    }
    final keys = groups.keys.toList()..sort();

    final recent = Store.books.where((b) => b.opened > 0).toList()
      ..sort((a, b) => b.opened.compareTo(a.opened));

    const tabs = ['All', 'Series', 'Author', 'Favorites'];

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('Add books'),
      ),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(greeting,
                        style: TextStyle(
                            fontSize: 15, color: Theme.of(context).hintColor)),
                    const Text('Library',
                        style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  onChanged: (v) => setState(() => query = v),
                  decoration: InputDecoration(
                    hintText: 'Search library',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 44,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: tabs.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => ChoiceChip(
                    label: Text(tabs[i]),
                    selected: tab == i,
                    onSelected: (_) => setState(() => tab = i),
                  ),
                ),
              ),
            ),
            if (recent.isNotEmpty && q.isEmpty && tab == 0)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => _open(recent.first),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        gradient: const LinearGradient(
                          colors: [Color(0xFF007AFF), Color(0xFF5E5CE6)],
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Continue reading',
                              style: TextStyle(color: Colors.white70)),
                          const SizedBox(height: 4),
                          Text(recent.first.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700)),
                          Text(
                              'Page ${recent.first.last} of ${recent.first.pages}',
                              style: const TextStyle(color: Colors.white70)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (list.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'Your library is empty.\nTap "Add books" to add PDF files from your phone.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            for (final k in keys) ...[
              if (k.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
                    child: Text('$k (${groups[k]!.length})',
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Theme.of(context).hintColor)),
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                sliver: SliverGrid(
                  delegate: SliverChildBuilderDelegate(
                    (c, i) => _card(groups[k]![i]),
                    childCount: groups[k]!.length,
                  ),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.5,
                  ),
                ),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 90)),
          ],
        ),
      ),
    );
  }
}

class Cover extends StatelessWidget {
  final Book b;
  const Cover(this.b, {super.key});

  @override
  Widget build(BuildContext context) {
    return PdfDocumentViewBuilder.file(
      b.path,
      builder: (context, document) {
        if (document == null) {
          return Container(color: Colors.grey.shade300);
        }
        return PdfPageView(
          document: document,
          pageNumber: 1,
          alignment: Alignment.topCenter,
        );
      },
    );
  }
}

// ---------------------------------------------------------------- reader

class ReaderPage extends StatefulWidget {
  final Book book;
  const ReaderPage({super.key, required this.book});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  final PdfViewerController controller = PdfViewerController();
  late final PdfTextSearcher searcher = PdfTextSearcher(controller)..addListener(_u);
  final TextEditingController pageCtl = TextEditingController();
  final TextEditingController searchCtl = TextEditingController();
  final FocusNode pageFocus = FocusNode();
  final ValueNotifier<int> tick = ValueNotifier<int>(0);

  PdfDocument? doc;
  bool bars = true;
  bool searching = false;
  bool restoring = false;
  bool detecting = false;
  double prog = 0;
  int total = 0;
  int cur = 1;
  int target = 1;
  List<TocItem> toc = [];
  Timer? saveTimer;

  Book get b => widget.book;

  @override
  void initState() {
    super.initState();
    target = b.last < 1 ? 1 : b.last;
    cur = target;
    pageCtl.text = '$cur';
  }

  void _u() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    saveTimer?.cancel();
    Store.save();
    searcher.removeListener(_u);
    searcher.dispose();
    pageCtl.dispose();
    searchCtl.dispose();
    pageFocus.dispose();
    tick.dispose();
    super.dispose();
  }

  void _ready(PdfDocument d, PdfViewerController c) {
    doc = d;
    total = d.pages.length;
    b.pages = total;
    b.opened = DateTime.now().millisecondsSinceEpoch;
    if (target > 1 && target <= total) {
      restoring = true;
      c.goToPage(pageNumber: target, duration: Duration.zero);
      cur = target;
      Timer(const Duration(seconds: 2), () => restoring = false);
    }
    pageCtl.text = '$cur';
    Store.save();
    if (mounted) setState(() {});
    _loadOutline(d);
  }

  Future<void> _loadOutline(PdfDocument d) async {
    try {
      final o = await d.loadOutline();
      final out = <TocItem>[];
      _flat(o, 0, out);
      toc = out;
      tick.value++;
    } catch (_) {}
  }

  void _flat(List<PdfOutlineNode> nodes, int level, List<TocItem> out) {
    for (final n in nodes) {
      out.add(TocItem(n.title, level, n.dest?.pageNumber ?? 0));
      if (n.children.isNotEmpty) _flat(n.children, level + 1, out);
    }
  }

  void _page(int? n) {
    if (n == null) return;
    if (restoring) {
      if (n == target) restoring = false;
      return;
    }
    cur = n;
    b.last = n;
    if (!pageFocus.hasFocus) pageCtl.text = '$n';
    saveTimer?.cancel();
    saveTimer = Timer(const Duration(milliseconds: 700), () {
      Store.save();
    });
    if (mounted) setState(() {});
  }

  void _go(int n) {
    if (n < 1 || n > total) return;
    controller.goToPage(pageNumber: n);
  }

  void _toggleBookmark() {
    if (b.bm.contains(cur)) {
      b.bm.remove(cur);
    } else {
      b.bm.add(cur);
      b.bm.sort();
    }
    Store.save();
    setState(() {});
  }

  // Finds headings by text size when the PDF has no built-in contents.
  Future<void> _detect() async {
    final d = doc;
    if (d == null || detecting) return;
    detecting = true;
    prog = 0;
    tick.value++;
    final pages = d.pages;
    final n = pages.length;
    try {
      // pass 1: the most common text size is the body text
      final weight = <int, double>{};
      final step = n > 40 ? n ~/ 40 : 1;
      for (var i = 0; i < n; i += step) {
        final t = await pages[i].loadText();
        if (t == null) continue;
        for (final f in t.fragments) {
          final k = ((f.bounds.top - f.bounds.bottom).abs() * 2).round();
          weight[k] = (weight[k] ?? 0) + f.text.length;
        }
      }
      if (weight.isEmpty) {
        detecting = false;
        tick.value++;
        return;
      }
      var bodyK = weight.keys.first;
      weight.forEach((k, v) {
        if (v > (weight[bodyK] ?? 0)) bodyK = k;
      });

      // pass 2: collect larger text that looks like a heading
      final cands = <List<dynamic>>[]; // [page, text, sizeKey]
      for (var i = 0; i < n; i++) {
        if (!mounted) return;
        final t = await pages[i].loadText();
        if (t != null) {
          final seen = <String>{};
          for (final f in t.fragments) {
            final k = ((f.bounds.top - f.bounds.bottom).abs() * 2).round();
            if (k < bodyK * 1.18) continue;
            final tx = f.text.trim();
            if (tx.length < 3 || tx.length > 90) continue;
            if (RegExp(r'^[\d\s\.\-–]+$').hasMatch(tx)) continue;
            if (!seen.add(tx)) continue;
            cands.add([i + 1, tx, k]);
          }
        }
        if (i % 10 == 0) {
          prog = i / n;
          tick.value++;
          await Future<void>.delayed(Duration.zero);
        }
        if (cands.length > 4000) break;
      }

      // the three biggest repeated sizes become Heading 1, 2 and 3
      final counts = <int, int>{};
      for (final c in cands) {
        final k = c[2] as int;
        counts[k] = (counts[k] ?? 0) + 1;
      }
      final tiers = counts.keys.where((k) => counts[k]! >= 2).toList()
        ..sort((a, c) => c.compareTo(a));
      final top = tiers.take(3).toList();
      final out = <TocItem>[];
      for (final c in cands) {
        final lv = top.indexOf(c[2] as int);
        if (lv < 0) continue;
        out.add(TocItem(c[1] as String, lv, c[0] as int));
      }
      toc = out;
    } catch (_) {}
    detecting = false;
    prog = 1;
    tick.value++;
  }

  ColorFilter? get _filter {
    switch (modeN.value) {
      case 1:
        return const ColorFilter.matrix(<double>[
          0.393, 0.769, 0.189, 0, 0,
          0.349, 0.686, 0.168, 0, 0,
          0.272, 0.534, 0.131, 0, 0,
          0, 0, 0, 1, 0,
        ]);
      case 2:
        return const ColorFilter.matrix(<double>[
          -0.9, 0, 0, 0, 230,
          0, -0.9, 0, 0, 230,
          0, 0, -0.9, 0, 230,
          0, 0, 0, 1, 0,
        ]);
      default:
        return null;
    }
  }

  void _openToc() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        maxChildSize: 0.95,
        builder: (ctx2, sc) => DefaultTabController(
          length: 2,
          child: Column(
            children: [
              const TabBar(tabs: [Tab(text: 'Contents'), Tab(text: 'Bookmarks')]),
              Expanded(
                child: TabBarView(children: [
                  _tocTab(ctx, sc),
                  _bookmarkTab(ctx),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tocTab(BuildContext sheetCtx, ScrollController sc) {
    return ValueListenableBuilder<int>(
      valueListenable: tick,
      builder: (context, _, __) {
        if (toc.isEmpty) {
          return ListView(
            controller: sc,
            padding: const EdgeInsets.all(24),
            children: [
              Text(detecting
                  ? 'Finding headings… ${(prog * 100).round()}%'
                  : 'This book has no built-in contents.'),
              const SizedBox(height: 12),
              if (detecting)
                LinearProgressIndicator(value: prog)
              else
                FilledButton(
                  onPressed: _detect,
                  child: const Text('Find headings automatically'),
                ),
            ],
          );
        }
        return ListView.builder(
          controller: sc,
          itemCount: toc.length,
          itemBuilder: (c, i) {
            final t = toc[i];
            final lv = t.level > 2 ? 2 : t.level;
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.only(left: 16.0 + 18.0 * lv, right: 16),
              leading: SizedBox(
                width: 26,
                child: Text('H${lv + 1}',
                    style: TextStyle(
                        fontSize: 11, color: Theme.of(context).hintColor)),
              ),
              title: Text(
                t.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: lv == 0 ? 17 : (lv == 1 ? 15 : 14),
                  fontWeight: lv == 0
                      ? FontWeight.w700
                      : (lv == 1 ? FontWeight.w600 : FontWeight.w400),
                ),
              ),
              trailing: Text(t.page > 0 ? '${t.page}' : ''),
              onTap: () {
                if (t.page > 0) {
                  Navigator.pop(sheetCtx);
                  _go(t.page);
                }
              },
            );
          },
        );
      },
    );
  }

  Widget _bookmarkTab(BuildContext sheetCtx) {
    return StatefulBuilder(
      builder: (context, setSt) {
        if (b.bm.isEmpty) {
          return const Center(child: Text('No bookmarks yet.'));
        }
        return ListView(
          children: [
            for (final p in List<int>.from(b.bm))
              ListTile(
                leading: const Icon(Icons.bookmark),
                title: Text('Page $p'),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    b.bm.remove(p);
                    Store.save();
                    setSt(() {});
                    setState(() {});
                  },
                ),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _go(p);
                },
              ),
          ],
        );
      },
    );
  }

  void _openGrid() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        maxChildSize: 0.95,
        builder: (ctx2, sc) => PdfDocumentViewBuilder.file(
          b.path,
          builder: (context, d) {
            if (d == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return GridView.builder(
              controller: sc,
              padding: const EdgeInsets.all(10),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 0.62,
              ),
              itemCount: d.pages.length,
              itemBuilder: (c, i) {
                final here = (i + 1) == cur;
                return GestureDetector(
                  onTap: () {
                    Navigator.pop(ctx);
                    _go(i + 1);
                  },
                  child: Column(
                    children: [
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            border: here
                                ? Border.all(
                                    color: Theme.of(context).colorScheme.primary,
                                    width: 2)
                                : null,
                          ),
                          child: PdfPageView(document: d, pageNumber: i + 1),
                        ),
                      ),
                      Text('${i + 1}', style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _topBar() {
    if (searching) {
      final count = searcher.matches.length;
      final idx = searcher.currentIndex;
      return glass(
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                searcher.resetTextSearch();
                searchCtl.clear();
                setState(() => searching = false);
              },
            ),
            Expanded(
              child: TextField(
                controller: searchCtl,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: 'Search in book',
                  border: InputBorder.none,
                  isDense: true,
                ),
                onSubmitted: (v) {
                  if (v.trim().isEmpty) {
                    searcher.resetTextSearch();
                  } else {
                    searcher.startTextSearch(v.trim(), caseInsensitive: true);
                  }
                },
              ),
            ),
            if (searcher.isSearching)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Text(count == 0 ? '' : '${(idx ?? 0) + 1}/$count',
                  style: const TextStyle(fontSize: 13)),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_up),
              onPressed: count == 0 ? null : () => searcher.goToPrevMatch(),
            ),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: count == 0 ? null : () => searcher.goToNextMatch(),
            ),
          ],
        ),
      );
    }
    final marked = b.bm.contains(cur);
    return glass(
      Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 20),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Text(
              b.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => setState(() => searching = true),
          ),
          IconButton(
            icon: const Icon(Icons.format_list_bulleted),
            onPressed: _openToc,
          ),
          IconButton(
            icon: const Icon(Icons.grid_view),
            onPressed: _openGrid,
          ),
          IconButton(
            icon: Icon(marked ? Icons.bookmark : Icons.bookmark_border),
            onPressed: _toggleBookmark,
          ),
        ],
      ),
    );
  }

  Widget _bottomBar() {
    return glass(
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: () => _go(cur - 1),
            ),
            SizedBox(
              width: 70,
              child: TextField(
                controller: pageCtl,
                focusNode: pageFocus,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
                onTap: () => pageCtl.selection =
                    TextSelection(baseOffset: 0, extentOffset: pageCtl.text.length),
                onSubmitted: (v) {
                  final n = int.tryParse(v);
                  if (n != null) _go(n);
                  pageFocus.unfocus();
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text('/ $total'),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: () => _go(cur + 1),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: Icon(modeN.value == 0
                  ? Icons.light_mode
                  : (modeN.value == 1 ? Icons.wb_twilight : Icons.dark_mode)),
              onPressed: () => Store.setMode((modeN.value + 1) % 3),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = modeN.value;
    final bg = m == 2
        ? const Color(0xFFEEEEEE)
        : (m == 1 ? const Color(0xFFE5DCC5) : const Color(0xFFD1D1D6));
    final inset = MediaQuery.of(context).viewInsets.bottom;

    Widget viewer = PdfViewer.file(
      b.path,
      controller: controller,
      params: PdfViewerParams(
        backgroundColor: bg,
        onViewerReady: _ready,
        onPageChanged: _page,
        pagePaintCallbacks: [searcher.pageTextMatchPaintCallback],
      ),
    );
    final f = _filter;
    if (f != null) viewer = ColorFiltered(colorFilter: f, child: viewer);

    return ValueListenableBuilder<int>(
      valueListenable: modeN,
      builder: (context, _, __) => Scaffold(
        resizeToAvoidBottomInset: false,
        body: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => setState(() => bars = !bars),
                child: viewer,
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: IgnorePointer(
                  ignoring: !bars && !searching,
                  child: AnimatedSlide(
                    duration: const Duration(milliseconds: 220),
                    offset: (bars || searching) ? Offset.zero : const Offset(0, -1.6),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                      child: _topBar(),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: inset,
              left: 0,
              right: 0,
              child: SafeArea(
                top: false,
                child: IgnorePointer(
                  ignoring: !bars,
                  child: AnimatedSlide(
                    duration: const Duration(milliseconds: 220),
                    offset: bars ? Offset.zero : const Offset(0, 1.6),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      child: _bottomBar(),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
