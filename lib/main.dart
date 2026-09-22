// ============================================================================
//  十一 · 接着奏乐 —— 手机版
//  N2 节点：扫描手机里的音乐，把曲库列出来
//
//  本节点只解决「扫得到 + 列得出来」两件事，视觉打磨留给后面的节点。
//
//  ⚠️ 三个已经踩过的坑，改动时不要回退：
//   1) 模型类名是 SongModel，不是 AudioModel。
//      （AudioModel 只是插件内部基类，2.9.0 没有导出它 —— 写错名字会直接编译失败）
//   2) on_audio_query_android 1.1.0 的权限数组在安卓 13+ 上包含 READ_MEDIA_IMAGES，
//      低版本包含 WRITE_EXTERNAL_STORAGE。这两项我们没在清单里声明，
//      而插件是 `permissions.all{...}` 全通过才算授权 —— 结果就是「永远卡在授权页」。
//      CI 已打补丁把那两项删掉，只留 READ_MEDIA_AUDIO / READ_EXTERNAL_STORAGE，与清单一致。
//   3) 插件的 querySongs() 不带 IS_MUSIC 过滤，会把铃声/提示音/录音一起捞出来。
//      本文件在 Dart 侧按 isMusic 过滤，并带兜底（滤完为空就退回全量，绝不给空白页）。
//
//  标记串：SHIYI_PLAYER_N2 —— CI 会检查它，防止本文件被模板覆盖。
// ============================================================================
import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';

// 版本号（和 pubspec 的 version 保持一致，方便截图验收时确认装的是哪一版）
const String kBuild = 'v0.2.1 · N2';

// ===== 设计令牌：与网页版 index.html 一致（墨黑 + 黄铜）=====
const Color kInk = Color(0xFF0B0A09); // 暖黑底
const Color kPanel = Color(0xFF151311); // 卡片底
const Color kLine = Color(0xFF2A2622); // 分隔线
const Color kBrass = Color(0xFFD8A24A); // 主色·黄铜
const Color kBrassLight = Color(0xFFF0C47C); // 亮黄铜
const Color kText = Color(0xFFECE5D9); // 暖白字
const Color kMuted = Color(0xFF8A8175); // 次级文字

// ---- 安全取值工具 ----
// 插件字段的可空性在不同版本间会变（String / String? / bool?），
// 统一走 dynamic 取值 + 兜底，避免「插件某字段是不是可空」这种差异把构建搞崩。
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

/// 界面只吃这个类 —— 插件对象一律在加载阶段就被拆成纯字符串，
/// 这样界面层永远不会因为插件字段为 null 而崩。
class _Song {
  _Song(this.title, this.artist, this.dur, this.isMusic);
  final String title;
  final String artist;
  final String dur;
  final bool isMusic;
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
  List<_Song> _songs = <_Song>[];
  int _filteredOut = 0;
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
      // 不传查询参数，用插件默认行为（外部存储 / 按标题升序），减少 API 签名差异风险。
      final List<SongModel> raw = await _query.querySongs();
      final List<_Song> all = raw.map(_toSong).toList();

      // 只留媒体库标记为「音乐」的，甩掉铃声 / 提示音 / 录音。
      // 兜底：万一全被滤掉（个别机型 is_music 全为 0），就退回全量，绝不显示空白。
      final List<_Song> music =
          all.where((_Song s) => s.isMusic).toList();
      final List<_Song> kept = music.isEmpty ? all : music;

      kept.sort((_Song a, _Song b) =>
          a.title.toLowerCase().compareTo(b.title.toLowerCase()));

      if (!mounted) return;
      setState(() {
        _songs = kept;
        _filteredOut = all.length - kept.length;
        _stage = kept.isEmpty ? 'empty' : 'ready';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '$e';
        _stage = 'failed';
      });
    }
  }

  /// 插件对象 -> 纯字符串。所有字段访问都包 try，任何意外都退化成兜底值。
  _Song _toSong(SongModel m) {
    String title = '';
    try {
      title = _txt(m.title).trim();
    } catch (e) {
      title = '';
    }
    if (title.isEmpty) {
      try {
        title = _txt(m.displayNameWOExt).trim();
      } catch (e) {
        title = '';
      }
    }

    String artist = '';
    try {
      artist = _txt(m.artist).trim();
    } catch (e) {
      artist = '';
    }

    String dur = '--:--';
    try {
      dur = _mmss(m.duration);
    } catch (e) {
      dur = '--:--';
    }

    bool isMusic = true; // 取不到就当它是音乐，宁可多显示也不漏
    try {
      isMusic = m.isMusic == true;
    } catch (e) {
      isMusic = true;
    }

    return _Song(title.isEmpty ? '未知曲目' : title, artist, dur, isMusic);
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
                  letterSpacing: 1.2,
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
      final String extra =
          _filteredOut > 0 ? ' · 已滤掉 $_filteredOut 首铃声/提示音' : '';
      return '共 ${_songs.length} 首$extra';
    }
    return '手机版 · 曲库 $kBuild';
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
        final _Song m = _songs[i];
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
                      m.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14.5, color: kText),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      m.artist.isEmpty ? '未知歌手' : m.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: kMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                m.dur,
                style: const TextStyle(fontSize: 12, color: kBrassLight),
              ),
            ],
          ),
        );
      },
    );
  }
}
