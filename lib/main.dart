// ============================================================================
//  十一 · 接着奏乐 —— 手机版
//  N7 节点：搜索（零依赖）
//
//  搜索**只是「视图过滤」** —— 不改 _songs、不重建播放队列：
//  点搜索结果播它自己，之后仍按全库循环（延续 N5 的「循环整库」）。
//  同轮并入两笔旧账：① 删掉「导入电脑版星星」的种子功能
//  （目标用户电脑上没有数据，产品不该预置开发者的私人数据）
//  ② _subtitle() 的「已评 N 首」改为**恒常显示**（零值时隐藏会把失败伪装成「功能没做」）。
//  视觉打磨留给 N8。
//
//  ⚠️ 已经踩过的坑，改动时不要回退（完整记录见 节点进度.md）：
//   1) 模型类名是 SongModel，不是 AudioModel（后者是插件内部基类，2.9.0 未导出）。
//   2) on_audio_query_android 1.1.0 在 AGP8 下缺 namespace、JVM 目标不一致，
//      且权限数组多要 READ_MEDIA_IMAGES / WRITE_EXTERNAL_STORAGE（会导致永远卡授权页）。
//      三处均由 CI 第 10 步打补丁修复，不要删那一步。
//   3) 插件的 querySongs() 不带 IS_MUSIC 过滤，铃声/提示音会一起捞出来 ——
//      本文件在 Dart 侧按 isMusic 过滤，并带兜底（滤完为空则退回全量，绝不给空白页）。
//   4) 分区存储下 MediaStore 的 _data 文件路径不保证可读 ——
//      建队列时逐首选源：content:// URI 优先，拿不到才退文件路径，见 _buildSources()。
//   5) 后台播放由 just_audio_background 接管，代价是三处配套改动，
//      缺任何一处都会「能装能开但通知栏不出现」：
//        · 本文件：main() 里 await JustAudioBackground.init() + 每个音源挂 MediaItem
//        · CI：manifest 注入 AudioService / MediaButtonReceiver 与 3 条权限
//        · CI：把 MainActivity 的父类换成 AudioServiceActivity（见 build-apk.yml 第 7 步）
//   6) 【N5 新增】两处「一改就出连锁 bug」的地方：
//        · 队列装上后播放器自己会切歌 —— 必须删掉 N3/N4 那个
//          「processingState==completed 就手动下一首」的监听，否则会连跳两首。
//        · 播放器构造必须显式给 maxSkipsOnError：它的默认值是 0，
//          意思是「一个坏文件就卡住」，整库队列里这很致命。
//      另：0.10.x 的新播放列表 API 是 setAudioSources(List<AudioSource>)；
//          ConcatenatingAudioSource 已在 0.10.0 废弃，不要走老路。
//   7) 【N6 新增】评分有两个「看着能用、其实会串」的陷阱：
//        · 键必须是**文件名（含扩展名）**，不是曲名、更不是自增序号 ——
//          曲名会被「取不到标签」的兜底值污染，序号会随排序变化而漂移。
//          用文件名还顺带让电脑版已打的星可以直接搬过来。
//        · 改排序会改变列表顺序，而 N5 的**队列顺序 = 列表顺序** →
//          排序一变就必须**作废并重建队列**，否则界面高亮会指到别的歌、
//          甚至播的还是旧顺序里那一首。
//   8) 【N6 新增】持久化用 `SharedPreferencesAsync`，**不要**用经典的
//      `SharedPreferences`（官方已标为 legacy 并建议新用户改用 Async 版）；
//      也**不要**直接 import sqflite —— 它只是别人的传递依赖，属隐式依赖。
//   9) 【N7 新增】🔴 列表代码**全程按下标工作**（itemBuilder 的 `i` 同时当
//      「列表下标」和「队列下标」用）。一加搜索过滤，「显示下标」就和
//      `_songs` 下标错位了 —— 后果是**点搜索结果会播一首完全不相干的歌，
//      而且不报错、不崩溃，只会静默播错**。
//      三处必须同时处理，缺一即错（实现见 _visList / _isPlaying / _realIndex）：
//        · itemBuilder：`_songs[i]` → `vis[i]`
//        · 高亮判断：**不能比下标**，改成比对象（fileName + uri）
//        · onTap：先把可见项映射回 `_songs` 的**真实下标**，再调 `_play`
//      另：`_visList()` 刻意**不缓存为 state**，每次从 (`_songs` 顺序 + `_searchText`)
//      纯函数算出 —— 否则切排序后会出现「列表变了、缓存没更新」的失同步。
//
//  标记串：SHIYI_PLAYER_N7 —— CI 会检查它，防止本文件被模板覆盖。
// ============================================================================
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 版本号（和 pubspec 的 version 保持一致，方便截图验收时确认装的是哪一版）
const String kBuild = 'v0.8.1 · N8.1';

// ===== 设计令牌（N8「深色潮玩 / dark neo-pop」，十一拍板 A+C，方案二·玩具总动员）=====
// 两层结构：下面是 primitive（裸色板），widget 里按用途取用。
// 🔴 将来加浅色主题/换主题，只动这一层，widget 代码一行不改 —— 这是 N8 买下的能力。
//
// 三条硬纪律：
//   ① 深色主题的层次**靠底色明度差**（inset < bg < panel < raised），不靠阴影
//   ② 中性色全带 0.01~0.02 色度偏色 —— 纯黑/纯灰不存在于自然界，看着发死
//   ③ 硬投影必须用实色 kShadow，**禁用 alpha 透明**（alpha 是调色板没做完的信号）
//
// 对比度均按 WCAG 验过（对 kInk）：kText>12:1 / kMuted≈7:1 / kTextLow≈5:1 /
// kAccent≈6.9:1 / kBlue≈5.5:1。⚠️ kTextLow 别再压暗 —— 第一版 #6B7385 只有 3.2:1。
// ---- primitive：色板 ----
const Color kInk = Color(0xFF0F131C); // 页面底（深靛蓝黑）
const Color kInset = Color(0xFF0B0F16); // 凹槽（进度槽）
const Color kPanel = Color(0xFF171C27); // 面板（播放条/卡片）
const Color kRaised = Color(0xFF1E2433); // 悬浮（输入框/按键）
const Color kShadow = Color(0xFF060910); // 硬投影（实色）
const Color kLine = Color(0xFF2A3244); // 常规描边/分隔线
const Color kStrokeStrong = Color(0xFFE8E4D8); // 重点勾边（奶油白）
const Color kText = Color(0xFFF2EEE3); // 主文字（暖白）
const Color kMuted = Color(0xFFA8B0C2); // 次文字（蓝灰）
const Color kTextLow = Color(0xFF8890A4); // 弱文字
const Color kAccent = Color(0xFFFF6B2C); // 电光橙：只给「正在发生」的事
const Color kAccentDeep = Color(0xFFE04E17); // 橙·按压态
const Color kAccentSoft = Color(0xFFFFB48A); // 橙·弱化（小号强调文字）
const Color kBlue = Color(0xFF8FA0FF); // 长春花蓝：次级交互/焦点
// ---- semantic：按用途 ----
const Color kStarOff = Color(0xFF3A4256); // N8：未点亮的星（空心描边色，不再发花）
const String kNumFont = 'SpaceGrotesk'; // N8：数字/时长展示体（静态 700 实例化）

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
      this.data, this.fileName);
  final String title;
  final String artist;
  final String dur; // 已格式化好的 m:ss（列表右侧显示用）
  final int durMs; // 原始毫秒（N4：交给通知栏当进度条总长用）
  final bool isMusic;
  final String uri; // content://media/external/audio/media/<id>
  final String data; // 真实文件路径（降级用）
  // N6：评分键 —— 文件名（含扩展名）。
  // 选它的三个理由：① 与电脑版 ratings.json 同构，评分可直接搬过来
  // ② 不受「曲名取不到标签」的兜底值影响 ③ 不随排序变化而漂移
  final String fileName;
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
          primary: kAccent,
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

  // 播放器：一个实例够用（just_audio_background 也只支持单实例）。
  // N5：maxSkipsOnError 的默认值是 0 —— 队列里只要有一个坏文件就会卡在那儿。
  //     显式给个上限，坏文件自动跳过，不拖垮整条队列。
  final AudioPlayer _player = AudioPlayer(maxSkipsOnError: 5);
  // N5：界面下标跟着播放器的 currentIndex 走，自动切歌时界面才跟得上
  StreamSubscription<int?>? _ciSub;

  // N5：整库队列。装成功后缓存下来，之后切歌只 seek 不重建
  //（115 首要是一首歌就重建一次队列，纯属浪费）。
  List<AudioSource>? _sources;

  // ===== N6：评分 =====
  // 键 = 文件名（含扩展名）。选它的三个理由：① 不受「取不到标签」的兜底值影响
  // ② 不随排序变化而漂移 ③ 字段全同的两首歌也能靠 uri 区分（见 _isPlaying）
  //（N7 起不再「与电脑版 ratings.json 同构」—— 那条种子导入通道已删除）
  Map<String, int> _stars = <String, int>{};
  static const String _kStarsKey = 'shiyi_mobile_ratings_v1';
  int _ratedCount = 0; // 曲库里已评分的首数（副标题显示用）
  int _sameNameGroups = 0; // 诊断：曲库里有几组同名文件（同名会共享同一份评分）

  // 排序模式：'title' 按标题升序（默认） | 'stars' 按星级降序
  String _sortMode = 'title';

  // ===== N7：搜索 =====
  // 只作为「视图过滤条件」存在 —— 绝不改写 _songs，绝不重建播放队列。
  // 🔴 现有列表代码全程按下标工作，过滤后必须做下标映射（见 _realIndex / _isPlaying）。
  String _searchText = '';
  final TextEditingController _searchCtl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  // checking | denied | loading | ready | empty | failed
  String _stage = 'checking';
  List<_Song> _songs = <_Song>[];
  int _filteredOut = 0;
  String _err = '';

  int _index = -1; // 正在播第几首，-1 = 没在播
  double? _dragMs; // 拖动进度条时的临时值（避免被 positionStream 拉回）
  bool _playPressed = false; // N8 方案二：主播放键「按下下沉」的状态

  @override
  void initState() {
    super.initState();
    // N5：自动切歌交给播放器自己（队列 + LoopMode.all），这里只负责让界面跟上。
    // ⚠️ 千万别在这里再监听 processingState==completed 去手动切下一首 ——
    //    会和播放器自己的切歌叠加，表现成「一首歌没放完就跳两首」。
    _ciSub = _player.currentIndexStream.listen((int? idx) {
      if (!mounted || idx == null || idx == _index) return;
      setState(() {
        _index = idx;
        _dragMs = null;
      });
    });
    // N8：搜索框聚焦态要重绘（描边变色）—— FocusNode 变化不会自己触发 setState
    _searchFocus.addListener(() {
      if (mounted) setState(() {});
    });
    _boot();
  }

  @override
  void dispose() {
    _ciSub?.cancel();
    _searchCtl.dispose(); // N7
    _searchFocus.dispose(); // N7
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
    // N6：先把评分读出来，_load() 里统计「已评 N 首」才是准的
    await _loadStars();
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
    // N5：曲库要重扫了，队列必须作废重建 ——
    // 否则「界面上的第 3 首」和「队列里的第 3 首」会错位（还播着旧列表里的歌）。
    _sources = null;

    try {
      // 不传查询参数，用插件默认行为（外部存储 / 按标题升序），减少 API 签名差异风险。
      final List<SongModel> raw = await _query.querySongs();
      final List<_Song> all = raw.map(_toSong).toList();

      // 只留媒体库标记为「音乐」的，甩掉铃声 / 提示音 / 录音。
      // 兜底：万一全被滤掉（个别机型 is_music 全为 0），就退回全量，绝不显示空白。
      final List<_Song> music = all.where((_Song s) => s.isMusic).toList();
      final List<_Song> music2 = music.isEmpty ? all : music;
      // N5：队列要求「列表下标 == 队列下标」严格一一对应，
      // 所以拿不到任何可播地址的僵尸条目必须先剔掉（否则整库下标后移、全错位）。
      final List<_Song> kept = music2
          .where((_Song s) => s.uri.isNotEmpty || s.data.isNotEmpty)
          .toList();

      if (!mounted) return;
      setState(() {
        _songs = kept;
        _sortSongs(); // N6：按当前排序模式排列（默认按标题）
        _filteredOut = all.length - kept.length;
        _stage = kept.isEmpty ? 'empty' : 'ready';

        // N6：统计「曲库里已评了几首」
        _ratedCount = 0;
        for (final _Song s in _songs) {
          if ((_stars[s.fileName] ?? 0) > 0) _ratedCount++;
        }

        // N6 诊断：同名文件会**共享同一份评分**（键是文件名）。
        // 这里不预先假设「手机上没有重名」—— 把它显示出来，让事实自己说话。
        final Map<String, int> cnt = <String, int>{};
        for (final _Song s in _songs) {
          if (s.fileName.isNotEmpty) {
            cnt[s.fileName] = (cnt[s.fileName] ?? 0) + 1;
          }
        }
        int dup = 0;
        cnt.forEach((String k, int v) {
          if (v > 1) dup++;
        });
        _sameNameGroups = dup;
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

    // N6：评分键。`displayName` 就是「文件名含扩展名」。
    // 别拿 `displayNameWOExt`（去掉扩展名的版本）当键 ——
    // 它与用于**显示**的 title 是两回事，混用会让键不稳定。
    String fileName = '';
    try {
      fileName = _txt(m.displayName).trim();
    } catch (e) {
      fileName = '';
    }
    if (fileName.isEmpty && data.isNotEmpty) {
      fileName = data.split('/').last; // 兜底：从真实路径取末段
    }

    return _Song(title.isEmpty ? '未知曲目' : title, artist, _mmss(durMs), durMs,
        isMusic, uri, data, fileName);
  }

  // ===== N6：评分 =====

  /// 载入评分（只读手机本地）。
  ///
  /// N7：**删掉了「导入电脑版星星」的种子逻辑** —— 那**不是产品功能，是开发者便利**。
  /// 目标用户电脑上没有数据；预置开发者的私人数据方向也是错的
  /// （低概率会给「文件名恰好相同」的他人歌曲空降星级）。见 节点进度.md §二十二。
  Future<void> _loadStars() async {
    String? raw;
    try {
      final SharedPreferencesAsync prefs = SharedPreferencesAsync();
      raw = await prefs.getString(_kStarsKey);
    } catch (e) {
      raw = null; // 读不出来就当「还没评分」，绝不因此让 App 起不来
    }

    final Map<String, int> m = <String, int>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        final Object? j = jsonDecode(raw);
        if (j is Map) {
          j.forEach((Object? k, Object? v) {
            final int n = _intOf(v);
            if (k != null && n >= 1 && n <= 5) {
              m['$k'] = n;
            }
          });
        }
      } catch (e) {
        // 数据坏了就当作空，不崩
      }
    }
    if (!mounted) return;
    setState(() {
      _stars = m;
    });
  }

  /// 落盘。写失败不致命（内存里的评分照常生效），所以静默处理。
  Future<void> _saveStars() async {
    try {
      await SharedPreferencesAsync().setString(_kStarsKey, jsonEncode(_stars));
    } catch (e) {
      // 忽略：这次没存住而已
    }
  }

  /// 点第 n 颗星。**再点同一颗 = 取消评分**（给错了得能退）。
  void _rate(_Song s, int n) {
    if (s.fileName.isEmpty) return; // 拿不到文件名就没法存，直接忽略
    setState(() {
      if ((_stars[s.fileName] ?? 0) == n) {
        _stars.remove(s.fileName);
      } else {
        _stars[s.fileName] = n;
      }
      _ratedCount = 0;
      for (final _Song x in _songs) {
        if ((_stars[x.fileName] ?? 0) > 0) _ratedCount++;
      }
    });
    _saveStars();
  }

  /// 按当前模式**原地**重排 _songs。
  /// 星级排序的**次级键是标题** —— 同星级内部顺序稳定，不会每次刷新都乱跳。
  // ===== N7：搜索 =====

  /// 可见列表 = 在「**已排序**的 `_songs`」之上做关键词过滤。
  ///
  /// 🔴 刻意**不缓存为 state** —— 每次从 (`_songs` 当前顺序 + `_searchText`) 纯函数算出。
  ///    这样「切排序后搜索结果自动跟着变」，永远不会出现「列表变了但缓存没更新」的
  ///    失同步。110 首的过滤是 O(n)，每帧算一次也远小于一帧预算。
  List<_Song> _visList() {
    final String q = _searchText.trim().toLowerCase();
    if (q.isEmpty) return _songs;
    // 空格分隔 = 多个关键词，**全部命中**才算（例如「花 鸦」也能搜到「花鸦 - 雾屿霓虹」）
    final List<String> keys = q
        .split(RegExp(r'\s+'))
        .where((String k) => k.isNotEmpty)
        .toList();
    if (keys.isEmpty) return _songs;
    return _songs.where((_Song s) {
      // 搜「曲名 + 歌手 + 文件名」。
      // 文件名**必须在**：少数歌的 ID3 标签损坏、曲名显示成 `??`，
      // 只有靠文件名才搜得到它们。
      final String hay = '${s.title} ${s.artist} ${s.fileName}'.toLowerCase();
      for (final String k in keys) {
        if (!hay.contains(k)) return false;
      }
      return true;
    }).toList();
  }

  /// 这一首是不是「正在播的那首」。
  ///
  /// 🔴 **不能比下标** —— 过滤之后「显示下标」和 `_songs` 下标已经对不上，
  ///    比下标会把黄铜高亮打在一首根本没在放的歌上。
  ///    改比「文件名 + uri」：uri 对应唯一一条 MediaStore 记录，
  ///    与「当前是第几首」无关，因此过滤前后都成立。
  bool _isPlaying(_Song s) {
    if (_index < 0 || _index >= _songs.length) return false;
    final _Song p = _songs[_index];
    return s.fileName == p.fileName && s.uri == p.uri;
  }

  /// 过滤视图里的对象 → `_songs` 里的**真实下标**（找不到返回 -1）。
  ///
  /// `_Song` 没有重写 `operator ==`（已读码确认）⇒ `indexOf` 走**引用相等**；
  /// 而 `_visList()` 返回的是同一批对象引用，故定位可靠、不会被「字段全同的两首歌」骗。
  int _realIndex(_Song s) => _songs.indexOf(s);

  void _sortSongs() {
    _songs.sort((_Song a, _Song b) {
      if (_sortMode == 'stars') {
        final int sa = _stars[a.fileName] ?? 0;
        final int sb = _stars[b.fileName] ?? 0;
        if (sa != sb) return sb.compareTo(sa); // 星级降序
      }
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
  }

  /// 切换排序。
  /// 🔴 关键：列表顺序一变，N5 那条「**队列顺序 = 列表顺序**」的对应关系就断了，
  /// 所以必须**作废并重建队列**；正在播放时还得把「同一首歌的同一秒」接回去 ——
  /// 否则界面高亮会指到别的歌，甚至播的还是旧顺序里的那一首。
  Future<void> _setSort(String mode) async {
    if (_sortMode == mode) return;

    final _Song? playing =
        (_index >= 0 && _index < _songs.length) ? _songs[_index] : null;
    final Duration pos = _player.position;
    final bool wasPlaying = _player.playing;

    setState(() {
      _sortMode = mode;
      _sortSongs();
      _dragMs = null;
    });

    if (playing == null) {
      _sources = null; // 没在播：只作废队列，下次点歌自然会重建
      return;
    }

    // 按「文件名 + uri」认人找新下标 —— 不能按下标找，下标已经变了
    final int ni = _songs.indexWhere((_Song s) =>
        s.fileName == playing.fileName && s.uri == playing.uri);
    if (ni < 0) {
      _sources = null;
      return;
    }
    setState(() {
      _index = ni;
    });

    try {
      final List<AudioSource> built = _buildSources();
      await _player.setAudioSources(built,
          initialIndex: ni, initialPosition: pos);
      await _player.setLoopMode(LoopMode.all);
      _sources = built;
      if (wasPlaying) {
        try {
          await _player.play();
        } catch (e) {
          // 续播失败不致命
        }
      }
    } catch (e) {
      _sources = null; // 重建失败：作废掉，下次点歌重建，不打扰用户
    }
  }

  // ===== 播放 =====

  /// 一首歌 -> 通知栏用的 MediaItem。
  /// 同一首歌必须稳定得到同一个 id，否则系统会把它当成两首，
  /// 表现为重复通知 / 封面缓存错乱。
  MediaItem _tagOf(_Song s, int i) {
    final String mediaId = s.uri.isNotEmpty ? s.uri : s.data;
    return MediaItem(
      id: mediaId.isEmpty ? 'idx-$i' : mediaId,
      title: s.title,
      artist: s.artist.isEmpty ? '未知歌手' : s.artist,
      duration: s.durMs > 0 ? Duration(milliseconds: s.durMs) : null,
    );
  }

  /// N5：把整个曲库建成一条播放队列。
  /// 顺序必须和 _songs 完全一致 —— 界面下标要直接当队列下标用。
  /// 逐首选源：content:// URI 优先（分区存储下最稳），拿不到才退文件路径。
  List<AudioSource> _buildSources() {
    final List<AudioSource> out = <AudioSource>[];
    for (int i = 0; i < _songs.length; i++) {
      final _Song s = _songs[i];
      final MediaItem tag = _tagOf(s, i);
      out.add(s.uri.isNotEmpty
          ? AudioSource.uri(Uri.parse(s.uri), tag: tag)
          : AudioSource.file(s.data, tag: tag));
    }
    return out;
  }

  Future<void> _play(int i) async {
    if (i < 0 || i >= _songs.length) return;
    final _Song s = _songs[i];
    if (!mounted) return;
    setState(() {
      _index = i;
      _dragMs = null;
    });

    try {
      final List<AudioSource>? q = _sources;
      if (q == null) {
        // 首次播放 / 重新扫描后：装整库队列，从点的这首开始
        final List<AudioSource> built = _buildSources();
        await _player.setAudioSources(built, initialIndex: i);
        // 循环整库：最后一首放完自动回第一首，不断播
        await _player.setLoopMode(LoopMode.all);
        _sources = built;
      } else {
        // 队列已在，直接切轨道 —— 不重建队列（115 首重建一次太浪费）
        await _player.seek(Duration.zero, index: i);
      }
    } catch (e) {
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
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: kText,
                        letterSpacing: 1.0,
                        height: 1.1,
                      ),
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: kMuted,
                      textStyle: const TextStyle(fontSize: 12.5),
                    ),
                    onPressed: () {
                      _load();
                    },
                    child: const Text('重新扫描'),
                  ),
                ],
              ),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _subtitle(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: kAccentSoft,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  // N6：排序切换。直接写当前模式，不用图标让人猜
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 30),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      foregroundColor: kBlue,
                    ),
                    onPressed: _stage == 'ready'
                        ? () {
                            _setSort(_sortMode == 'stars' ? 'title' : 'stars');
                          }
                        : null,
                    child: Text(
                      _sortMode == 'stars' ? '排序：按星级' : '排序：按标题',
                      style: const TextStyle(fontSize: 12, letterSpacing: 0.5),
                    ),
                  ),
                ],
              ),
              // N7：搜索框。**常驻单行**（比「点图标再展开」少一次点击）。
              // 只在曲库就绪后出现 —— 没歌可搜时摆个搜索框是噪音。
              if (_stage == 'ready') ...<Widget>[
                const SizedBox(height: 8),
                _searchField(),
              ],
              const SizedBox(height: 10),
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
      // 顺序即优先级：「已评」和「同名警告」比「滤掉多少首」重要，所以放前面
      //
      // 🔴 N6 踩坑修正（详见 节点进度.md §二十二）：
      //   旧写法是 `_ratedCount > 0 ? ' · 已评 N 首' : ''` —— **零值时整段消失**，
      //   而「评分一条都没匹配上」恰恰就是零值那种情况，结果失败在界面上
      //   看起来像「功能没做出来」，用户无法提供任何线索。
      //   ⇒ 规则：关键计数恒常显示，绝不在零值时隐藏。
      //
      // 另附「找不到对应文件的评分条数」作为判别量：
      //   正常情况下 _stars.length == _ratedCount（用户打几首就是几首）；
      //   若 _stars.length > _ratedCount，多出来的就是「存着但曲库里没有的」——
      //   种子导入后文件名对不上时，就是这个形态，一眼可分。
      final int orphan = _stars.length - _ratedCount;
      final String star = ' · 已评 $_ratedCount 首'
          '${orphan > 0 ? '（另有 $orphan 条找不到对应文件）' : ''}';
      final String dup =
          _sameNameGroups > 0 ? ' · ⚠️ $_sameNameGroups 组同名' : '';
      final String extra =
          _filteredOut > 0 ? ' · 已滤掉 $_filteredOut 首铃声/提示音' : '';
      // N7：搜索命中数。延续「关键计数恒常显示」纪律 ——
      //     搜索时必须能看到命中几首，否则「列表怎么空了」和「搜不到」
      //     在界面上长得一模一样，用户无法区分。
      final String hit =
          _searchText.trim().isEmpty ? '' : ' · 找到 ${_visList().length} 首';
      return '共 ${_songs.length} 首$hit$star$dup$extra';
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
    // N7：搜索无命中 → 明确说「没找到」，绝不给一片空白。
    //（空白会让用户分不清「搜不到」和「App 坏了」）
    if (_searchText.trim().isNotEmpty && _visList().isEmpty) {
      return _hint('没找到「${_searchText.trim()}」\n\n可以搜歌名、歌手或文件名');
    }
    return _songList();
  }

  /// N7：搜索框。常驻单行 —— 放大镜 + 输入框 + 有输入才出现的 ✕。
  Widget _searchField() {
    // N8 方案二：搜索框也是「可按压元素」——奶油勾边 + 硬投影；
    // 聚焦时描边换长春花蓝并加粗一档（信号：焦点在哪）
    final bool focused = _searchFocus.hasFocus;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOutCubic,
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: kRaised,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: focused ? kBlue : kStrokeStrong,
          width: focused ? 1.8 : 1.4,
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: kShadow, offset: Offset(0, 2), blurRadius: 0),
        ],
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.search, size: 18, color: focused ? kBlue : kTextLow),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchCtl,
              focusNode: _searchFocus,
              style: const TextStyle(fontSize: 14, color: kText),
              cursorColor: kAccent,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: '搜索歌名 / 歌手 / 文件名',
                hintStyle: TextStyle(fontSize: 13, color: kTextLow),
              ),
              onChanged: (String v) {
                setState(() {
                  _searchText = v;
                });
              },
            ),
          ),
          // ✕ 只在有输入时出现，平时不占视觉噪音
          if (_searchText.isNotEmpty)
            GestureDetector(
              behavior: HitTestBehavior.opaque, // 扩大点击区，别被父级抢走
              onTap: () {
                _searchCtl.clear();
                setState(() {
                  _searchText = '';
                });
              },
              child: const Padding(
                padding: EdgeInsets.only(left: 8, top: 4, bottom: 4),
                child: Icon(Icons.close, size: 18, color: kMuted),
              ),
            ),
        ],
      ),
    );
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
          borderRadius: BorderRadius.circular(20),
          // N8 方案二：面板统一「奶油勾边 + 硬投影」
          border: Border.all(color: kStrokeStrong, width: 2),
          boxShadow: const <BoxShadow>[
            BoxShadow(color: kShadow, offset: Offset(0, 3), blurRadius: 0),
          ],
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

  /// N6：5 颗可点的小星。
  /// ⚠️ 星星自己得**吃掉点击事件**（HitTestBehavior.opaque），否则会穿透到整行的
  ///    InkWell 上去，变成「想打星结果触发了播放」。嵌套手势里最内层优先，这是关键。
  Widget _starsRow(_Song s) {
    final int cur = _stars[s.fileName] ?? 0;
    final bool canRate = s.fileName.isNotEmpty;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List<Widget>.generate(5, (int i) {
        final int n = i + 1;
        final bool on = n <= cur;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: canRate
              ? () {
                  _rate(s, n);
                }
              : null,
          child: Padding(
            // 左右各 2px：把点击热区从 16px 撑到 20px，手指才点得准
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Transform.rotate(
              // N8 方案二·贴纸感：点亮的星按位置交替歪一点点 ——
              // 齐整里藏一点「手贴上去」的乱；没亮的保持端正（不满屏乱晃）
              angle: on ? (i.isEven ? 0.07 : -0.07) : 0,
              child: Icon(
                on ? Icons.star_rounded : Icons.star_outline_rounded,
                size: 17,
                color: on ? kAccent : kStarOff,
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _songList() {
    // N7：列表吃的是**过滤后的可见列表**，不是 _songs 本身。
    final List<_Song> vis = _visList();
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: vis.length,
      separatorBuilder: (BuildContext c, int i) => const Divider(
        height: 1,
        thickness: 1,
        color: kLine,
      ),
      itemBuilder: (BuildContext c, int i) {
        final _Song m = vis[i];
        final bool playing = _isPlaying(m); // N7：比对象，不比下标
        return InkWell(
          onTap: () {
            // N7：先映射回 _songs 的**真实下标**再播。
            // 🔴 直接 _play(i) 会播「全库第 i 首」＝ 完全不相干的歌（不报错，静默播错）
            final int ri = _realIndex(m);
            if (ri >= 0) _play(ri);
            _searchFocus.unfocus(); // 收起键盘，别挡住播放条
          },
          child: Container(
            // N8 方案二：正在播放的行用奶油白勾边 + 面板底「勾」出来；
            // 没在播的行不加任何装饰 —— 勾边只给重点，满屏勾边等于没有重点
            decoration: playing
                ? BoxDecoration(
                    color: kPanel,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: kStrokeStrong, width: 1.6),
                  )
                : null,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                // N8：序号。展示体数字，编辑感；正在播放的行变橙
                SizedBox(
                  width: 28,
                  child: Text(
                    '${i + 1}'.padLeft(2, '0'),
                    style: TextStyle(
                      fontFamily: kNumFont,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: playing ? kAccent : kTextLow,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              m.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14.5,
                                color: playing ? kAccent : kText,
                                fontWeight: playing
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          // N8：时长换展示体数字；颜色压到 kTextLow ——
                          // 橙的预算留给「正在发生」，不能花在每行的时长上
                          Text(
                            m.dur,
                            style: TextStyle(
                              fontFamily: kNumFont,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: playing ? kAccentSoft : kTextLow,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              m.artist.isEmpty ? '未知歌手' : m.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontSize: 12, color: kMuted),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _starsRow(m), // N6：5 颗可点的星
                        ],
                      ),
                    ],
                  ),
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
      margin: const EdgeInsets.only(top: 6, bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: BoxDecoration(
        color: kPanel,
        borderRadius: BorderRadius.circular(20),
        // N8 方案二：播放条是全 App 的「主角框」—— 奶油白 2dp 勾边 + 硬投影
        border: Border.all(color: kStrokeStrong, width: 2),
        boxShadow: const <BoxShadow>[
          // 硬投影：实色、零模糊 —— 阴影的边缘是「切」出来的，不是晕开的
          BoxShadow(color: kShadow, offset: Offset(0, 3), blurRadius: 0),
        ],
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
                        fontWeight: FontWeight.w700,
                        color: kAccent,
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
                  // N8 方案二：实体按键感 —— 按下整体下沉 3dp、投影消失、颜色压深
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (_) {
                      setState(() {
                        _playPressed = true;
                      });
                    },
                    onTapUp: (_) {
                      setState(() {
                        _playPressed = false;
                      });
                    },
                    onTapCancel: () {
                      setState(() {
                        _playPressed = false;
                      });
                    },
                    onTap: () {
                      if (playing) {
                        _player.pause();
                      } else {
                        _player.play();
                      }
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 110),
                      curve: Curves.easeOutCubic,
                      width: 54,
                      height: 54,
                      // transform 位移不占布局空间 —— 正合适做「按下去」
                      transform: Matrix4.translationValues(
                          0, _playPressed ? 3 : 0, 0),
                      decoration: BoxDecoration(
                        color: _playPressed ? kAccentDeep : kAccent,
                        shape: BoxShape.circle,
                        border: Border.all(color: kStrokeStrong, width: 2),
                        boxShadow: _playPressed
                            ? const <BoxShadow>[]
                            : const <BoxShadow>[
                                BoxShadow(
                                    color: kShadow,
                                    offset: Offset(0, 3),
                                    blurRadius: 0),
                              ],
                      ),
                      child: Icon(
                        playing ? Icons.pause : Icons.play_arrow,
                        size: 32,
                        color: kInk, // 图标「挖空」成底色 —— 印刷感，不是系统感
                      ),
                    ),
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
                    // N8 方案二：轨道加粗到 4dp，进度是「正在发生」的事，配得上橙
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7, elevation: 0),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 14),
                  ),
                  child: Slider(
                    value: val,
                    max: maxMs,
                    activeColor: kAccent,
                    inactiveColor: kInset,
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
                        style: const TextStyle(
                            fontFamily: kNumFont,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: kMuted,
                            letterSpacing: 0.3),
                      ),
                      const Spacer(),
                      Text(
                        _mmss(totalMs),
                        style: const TextStyle(
                            fontFamily: kNumFont,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: kMuted,
                            letterSpacing: 0.3),
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
