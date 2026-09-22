// ============================================================================
//  十一 · 接着奏乐 —— 手机版
//  N4 节点：前台能出声 → 后台也能响（后台播放 + 通知栏控制）
//
//  本节点只解决「切出去 / 锁屏 / 退出 App 后音乐不停 + 通知栏能控制」，
//  视觉打磨与通知栏上下曲留给后面的节点。
//
//  ⚠️ 已经踩过的坑，改动时不要回退（完整记录见 节点进度.md）：
//   1) 模型类名是 SongModel，不是 AudioModel（后者是插件内部基类，2.9.0 未导出）。
//   2) on_audio_query_android 1.1.0 在 AGP8 下缺 namespace、JVM 目标不一致，
//      且权限数组多要 READ_MEDIA_IMAGES / WRITE_EXTERNAL_STORAGE（会导致永远卡授权页）。
//      三处均由 CI 第 10 步打补丁修复，不要删那一步。
//   3) 插件的 querySongs() 不带 IS_MUSIC 过滤，铃声/提示音会一起捞出来 ——
//      本文件在 Dart 侧按 isMusic 过滤，并带兜底（滤完为空则退回全量，绝不给空白页）。
//   4) 分区存储下 MediaStore 的 _data 文件路径不保证可读 ——
//      播放走「content:// URI 优先，文件路径降级」两级链，见 _play()。
//   5) 【N4 新增】后台播放由 just_audio_background 接管，代价是三处配套改动，
//      缺任何一处都会「能装能开但通知栏不出现」：
//        · 本文件：main() 里 await JustAudioBackground.init() + 每个音源挂 MediaItem
//        · CI：manifest 注入 AudioService / MediaButtonReceiver 与 3 条权限
//        · CI：把 MainActivity 的父类换成 AudioServiceActivity（见 build-apk.yml 第 7 步）
//
//  标记串：SHIYI_PLAYER_N4 —— CI 会检查它，防止本文件被模板覆盖。
// ============================================================================
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:on_audio_query/on_audio_query.dart';

// 版本号（和 pubspec 的 version 保持一致，方便截图验收时确认装的是哪一版）
const String kBuild = 'v0.4.0 · N4';

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
  _Song(this.title, this.artist, this.dur, this.durMs, this.isMusic, this.uri,
      this.data);
  final String title;
  final String artist;
  final String dur; // 已格式化好的 m:ss（列表右侧显示用）
  final int durMs; // 原始毫秒（N4：交给通知栏当进度条总长用）
  final bool isMusic;
  final String uri; // content://media/external/audio/media/<id>
  final String data; // 真实文件路径（降级用）
}

Future<void> main() async {
  // N4：后台播放的前提 —— 先把音频会话挂到系统媒体会话上。
  // ⚠️ 必须 await 完成后再 runApp，否则第一首歌可能来不及挂上通知栏。
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.shiyi.shiyi_player.channel.audio',
    androidNotificationChannelName: '接着奏乐 · 播放控制',
    // 播放时通知不可被划掉（避免误划导致「音乐还在响但控制入口没了」）
    androidNotificationOngoing: true,
  );
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

  // N3：前台播放器。一个实例够用（just_audio_background 也只支持单实例）。
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<ProcessingState>? _psSub;

  // checking | denied | loading | ready | empty | failed
  String _stage = 'checking';
  List<_Song> _songs = <_Song>[];
  int _filteredOut = 0;
  String _err = '';

  int _index = -1; // 正在播第几首，-1 = 没在播
  double? _dragMs; // 拖动进度条时的临时值（避免被 positionStream 拉回）

  @override
  void initState() {
    super.initState();
    // 播完自动下一首
    _psSub = _player.processingStateStream.listen((ProcessingState st) {
      if (st == ProcessingState.completed && mounted) {
        _next();
      }
    });
    _boot();
  }

  @override
  void dispose() {
    _psSub?.cancel();
    _player.dispose();
    super.dispose();
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
    // 重新扫描后曲目可能变了，停掉当前播放并把状态清干净，避免"声音还在响但界面找不到它"
    try {
      await _player.stop();
    } catch (e) {
      // 播放器还没初始化过，忽略
    }
    _index = -1;
    _dragMs = null;

    try {
      // 不传查询参数，用插件默认行为（外部存储 / 按标题升序），减少 API 签名差异风险。
      final List<SongModel> raw = await _query.querySongs();
      final List<_Song> all = raw.map(_toSong).toList();

      // 只留媒体库标记为「音乐」的，甩掉铃声 / 提示音 / 录音。
      // 兜底：万一全被滤掉（个别机型 is_music 全为 0），就退回全量，绝不显示空白。
      final List<_Song> music = all.where((_Song s) => s.isMusic).toList();
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

    int durMs = 0;
    try {
      durMs = _intOf(m.duration);
    } catch (e) {
      durMs = 0;
    }

    bool isMusic = true; // 取不到就当它是音乐，宁可多显示也不漏
    try {
      isMusic = m.isMusic == true;
    } catch (e) {
      isMusic = true;
    }

    String uri = '';
    try {
      uri = _txt(m.uri).trim();
    } catch (e) {
      uri = '';
    }

    String data = '';
    try {
      data = _txt(m.data).trim();
    } catch (e) {
      data = '';
    }

    return _Song(title.isEmpty ? '未知曲目' : title, artist, _mmss(durMs), durMs,
        isMusic, uri, data);
  }

  // ===== 播放 =====

  Future<void> _play(int i) async {
    if (i < 0 || i >= _songs.length) return;
    final _Song s = _songs[i];
    setState(() {
      _index = i;
      _dragMs = null;
    });

    // N4：通知栏/锁屏要显示曲名歌手，必须给音源挂 MediaItem。
    // id 用 uri（或退化成文件路径）—— 同一首歌必须稳定得到同一个 id，
    // 否则系统会把「同一首歌」当成两首，出现重复的通知或封面缓存错乱。
    final String mediaId = s.uri.isNotEmpty ? s.uri : s.data;
    final MediaItem tag = MediaItem(
      id: mediaId.isEmpty ? 'idx-$i' : mediaId,
      title: s.title,
      artist: s.artist.isEmpty ? '未知歌手' : s.artist,
      duration: s.durMs > 0 ? Duration(milliseconds: s.durMs) : null,
    );

    bool ok = false;

    // ① 首选 content:// URI —— 分区存储下最稳，且不需要文件路径权限
    if (s.uri.isNotEmpty) {
      try {
        await _player.setAudioSource(
            AudioSource.uri(Uri.parse(s.uri), tag: tag));
        ok = true;
      } catch (e) {
        ok = false;
      }
    }

    // ② 降级：真实文件路径（媒体文件在 READ_MEDIA_AUDIO 授权下可直读）
    //    注意这里用 AudioSource.file 而不是 setFilePath —— 后者没有 tag 参数，
    //    走它就会丢掉 MediaItem，通知栏会变成没有标题的空壳。
    if (!ok && s.data.isNotEmpty) {
      try {
        await _player.setAudioSource(AudioSource.file(s.data, tag: tag));
        ok = true;
      } catch (e) {
        ok = false;
      }
    }

    if (!ok) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('这首播不了：${s.title}')),
      );
      return;
    }

    try {
      await _player.play();
    } catch (e) {
      // play() 失败不致命（例如被音频焦点打断），静默即可
    }
  }

  void _next() {
    if (_songs.isEmpty) return;
    final int n = _index < 0 ? 0 : (_index + 1) % _songs.length;
    _play(n);
  }

  void _prev() {
    if (_songs.isEmpty) return;
    final int n = _index < 0 ? 0 : (_index - 1 + _songs.length) % _songs.length;
    _play(n);
  }

  // ===== 界面 =====

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
              if (_index >= 0 && _index < _songs.length) _playerBar(),
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
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: _songs.length,
      separatorBuilder: (BuildContext c, int i) => const Divider(
        height: 1,
        thickness: 1,
        color: kLine,
      ),
      itemBuilder: (BuildContext c, int i) {
        final _Song m = _songs[i];
        final bool playing = i == _index;
        return InkWell(
          onTap: () {
            _play(i);
          },
          child: Padding(
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
                        style: TextStyle(
                          fontSize: 14.5,
                          color: playing ? kBrass : kText,
                          fontWeight:
                              playing ? FontWeight.w600 : FontWeight.w400,
                        ),
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
          ),
        );
      },
    );
  }

  /// 底部播放条：曲名 + 歌手 + 进度条 + 时间 + ⏮ ⏯ ⏭
  Widget _playerBar() {
    final _Song s = _songs[_index];
    return Container(
      margin: const EdgeInsets.only(top: 6, bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: BoxDecoration(
        color: kPanel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kLine),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      s.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: kBrassLight,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      s.artist.isEmpty ? '未知歌手' : s.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: kMuted),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: _prev,
                icon: const Icon(Icons.skip_previous),
                color: kText,
                tooltip: '上一首',
              ),
              StreamBuilder<PlayerState>(
                stream: _player.playerStateStream,
                builder:
                    (BuildContext c, AsyncSnapshot<PlayerState> snap) {
                  final bool playing = snap.data?.playing ?? false;
                  return IconButton(
                    iconSize: 34,
                    color: kBrass,
                    tooltip: playing ? '暂停' : '播放',
                    onPressed: () {
                      if (playing) {
                        _player.pause();
                      } else {
                        _player.play();
                      }
                    },
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                  );
                },
              ),
              IconButton(
                onPressed: _next,
                icon: const Icon(Icons.skip_next),
                color: kText,
                tooltip: '下一首',
              ),
            ],
          ),
          _progressRow(),
        ],
      ),
    );
  }

  Widget _progressRow() {
    return StreamBuilder<Duration?>(
      stream: _player.durationStream,
      builder: (BuildContext c1, AsyncSnapshot<Duration?> ds) {
        final int totalMs = ds.data?.inMilliseconds ?? 0;
        return StreamBuilder<Duration>(
          stream: _player.positionStream,
          builder: (BuildContext c2, AsyncSnapshot<Duration> ps) {
            final int posMs = _dragMs?.round() ?? (ps.data?.inMilliseconds ?? 0);
            final double maxMs = totalMs > 0 ? totalMs.toDouble() : 1.0;
            final double val =
                posMs.clamp(0, maxMs.toInt()).toDouble();
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2.5,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 14),
                  ),
                  child: Slider(
                    value: val,
                    max: maxMs,
                    activeColor: kBrass,
                    inactiveColor: kLine,
                    onChanged: totalMs > 0
                        ? (double v) {
                            setState(() {
                              _dragMs = v;
                            });
                          }
                        : null,
                    onChangeEnd: totalMs > 0
                        ? (double v) {
                            _player.seek(Duration(milliseconds: v.round()));
                            setState(() {
                              _dragMs = null;
                            });
                          }
                        : null,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(
                    children: <Widget>[
                      Text(
                        _mmss(posMs),
                        style: const TextStyle(fontSize: 11, color: kMuted),
                      ),
                      const Spacer(),
                      Text(
                        _mmss(totalMs),
                        style: const TextStyle(fontSize: 11, color: kMuted),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
