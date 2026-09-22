// ============================================================================
//  十一 · 接着奏乐 —— 手机版
//  N2 节点：扫描手机里的音乐，把曲库列出来
//
//  本节点只解决「扫得到 + 列得出来」两件事，视觉打磨留给后面的节点。
//  权限说明：安卓 13（API 33）起必须用 READ_MEDIA_AUDIO 分媒体权限，
//            由 CI 在生成 Android 工程后自动注入 AndroidManifest.xml。
//
//  标记串：SHIYI_PLAYER_N2 —— CI 会检查它，防止本文件被模板覆盖。
// ============================================================================
import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';

// ===== 设计令牌：与网页版 index.html 一致（墨黑 + 黄铜）=====
const Color kInk = Color(0xFF0B0A09); // 暖黑底
const Color kPanel = Color(0xFF151311); // 卡片底
const Color kLine = Color(0xFF2A2622); // 分隔线
const Color kBrass = Color(0xFFD8A24A); // 主色·黄铜
const Color kBrassLight = Color(0xFFF0C47C); // 亮黄铜
const Color kText = Color(0xFFECE5D9); // 暖白字
const Color kMuted = Color(0xFF8A8175); // 次级文字
const Color kBrassBg = Color(0x1AD8A24A); // 10% 黄铜底

// ---- 安全取值工具 ----
// 不假设 AudioModel 各字段的可空性 / 类型，统一走 dynamic，
// 避免"插件某字段是 String? 还是 String"这类差异导致编译失败。
String _txt(dynamic v) => v == null ? '' : v.toString();

int _intOf(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return 0;
}

/// 把毫秒格式化成 m:ss（媒体库的 DURATION 单位是毫秒）
String _mmss(dynamic raw) {
  final int ms = _intOf(raw);
  if (ms <= 0) return '--:--';
  final int total = ms ~/ 1000;
  final int m = total ~/ 60;
  final int s = total % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

void main() {
  runApp(const ShiyiPlayerApp());
}

class ShiyiPlayerApp extends StatelessWidget {
  const ShiyiPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '接着奏乐',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kInk,
        colorScheme: const ColorScheme.dark(
          primary: kBrass,
          surface: kPanel,
          onSurface: kText,
        ),
      ),
      home: const LibraryPage(),
    );
  }
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final OnAudioQuery _query = OnAudioQuery();

  // checking | denied | loading | ready | empty | failed
  String _stage = 'checking';
  List<AudioModel> _songs = <AudioModel>[];
  String _err = '';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    if (!mounted) return;
    setState(() {
      _stage = 'checking';
    });
    bool granted = false;
    try {
      granted = await _query.permissionsStatus();
    } catch (e) {
      granted = false;
    }
    if (!mounted) return;
    if (!granted) {
      setState(() {
        _stage = 'denied';
      });
      return;
    }
    await _load();
  }

  Future<void> _ask() async {
    bool granted = false;
    try {
      granted = await _query.permissionsRequest();
    } catch (e) {
      granted = false;
    }
    if (!mounted) return;
    if (granted) {
      await _load();
    } else {
      setState(() {
        _stage = 'denied';
      });
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _stage = 'loading';
    });
    try {
      // 不传任何查询参数，用插件默认行为，减少 API 签名差异带来的风险；
      // 排序放到 Dart 里自己做。
      final List<AudioModel> list =
          List<AudioModel>.from(await _query.querySongs());
      list.sort((AudioModel a, AudioModel b) => _txt(a.title)
          .toLowerCase()
          .compareTo(_txt(b.title).toLowerCase()));
      if (!mounted) return;
      setState(() {
        _songs = list;
        _stage = list.isEmpty ? 'empty' : 'ready';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '$e';
        _stage = 'failed';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      '接着奏乐',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: kText,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      _load();
                    },
                    child: const Text('重新扫描'),
                  ),
                ],
              ),
              Text(
                _subtitle(),
                style: const TextStyle(
                  fontSize: 12.5,
                  color: kBrass,
                  letterSpacing: 1.4,
                ),
              ),
              const SizedBox(height: 14),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  String _subtitle() {
    if (_stage == 'ready') {
      return '共 ${_songs.length} 首';
    }
    return '手机版 · N2 曲库';
  }

  Widget _body() {
    if (_stage == 'checking' || _stage == 'loading') {
      return _hint('正在读取手机里的音乐…');
    }
    if (_stage == 'denied') {
      return _permissionCard();
    }
    if (_stage == 'failed') {
      return _hint('读取失败\n\n$_err');
    }
    if (_stage == 'empty') {
      return _emptyCard();
    }
    return _songList();
  }

  Widget _hint(String s) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          s,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13.5, color: kMuted, height: 1.6),
        ),
      ),
    );
  }

  Widget _permissionCard() {
    return Center(
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        decoration: BoxDecoration(
          color: kPanel,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kLine),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              '需要「音乐和音频」权限',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: kText,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '安卓 13 起，读取本地音乐要单独授权。\n点下面的按钮，在系统弹窗里选「允许」。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: kMuted, height: 1.55),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  _ask();
                },
                child: const Text('授予权限'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyCard() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              '权限没问题，但一首歌都没扫到',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: kText,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '最常见的两个原因：\n\n'
              '1. 音乐被放在了 Android/data/… 里面\n'
              '   （安卓 11 起系统不索引这个目录，任何播放器都扫不到）\n\n'
              '2. 刚拷进来，系统媒体库还没入库\n\n'
              '办法：把音乐挪到「内部存储 / Music /」或「Download /」，'
              '再点右上角「重新扫描」。',
              style: TextStyle(fontSize: 12.5, color: kMuted, height: 1.6),
            ),
            const SizedBox(height: 18),
            OutlinedButton(
              onPressed: () {
                _load();
              },
              child: const Text('重新扫描'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _songList() {
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 28),
      itemCount: _songs.length,
      separatorBuilder: (BuildContext c, int i) => const Divider(
        height: 1,
        thickness: 1,
        color: kLine,
      ),
      itemBuilder: (BuildContext c, int i) {
        final AudioModel m = _songs[i];
        final String artist = _txt(m.artist);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 11),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _txt(m.title),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14.5, color: kText),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      artist.isEmpty ? '未知歌手' : artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: kMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                _mmss(m.duration),
                style: const TextStyle(fontSize: 12, color: kBrassLight),
              ),
            ],
          ),
        );
      },
    );
  }
}
