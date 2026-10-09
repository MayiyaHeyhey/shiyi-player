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
import 'dart:ui' show ImageFilter; // N10：播放页的模糊背景要用

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 版本号（和 pubspec 的 version 保持一致，方便截图验收时确认装的是哪一版）
String kBuild = 'v0.10.0 · N10';

// ===== 主题系统（N9 双主题：十一拍板「两个都要，分两期」）=====
// 两套皮肤共用同一个形状骨架，差异集中在「潮玩浓度」这一个旋钮上：
//   pop70 玩具总动员（一期，N8 已交付）：全员奶油勾边 + 处处硬投影 + 贴纸星星
//   pop30 精密潮玩（二期，本节点新增）：勾边/投影只给重点，橙的预算砍半
//
// 🔴 为什么不再是 Color 全局常量：编译期定死的颜色**运行时切不了主题**。
//    现在颜色住在 PopTheme 里，经 PopThemeScope（InheritedWidget）下发，
//    widget 里一律 `pt.xxx` 取用；MaterialApp 的 ThemeData 只负责把
//    accent/panel/text 同步给 Material 组件（FilledButton/Slider 等）。
//
// 三条硬纪律不变：层次靠明度差不靠阴影 / 中性色带色度偏色 / 硬投影用实色禁 alpha。
// 对比度（对 ink #14100C）：正文约 14:1 / 次要约 6.8:1 / 弱化约 4.6:1 / 琥珀约 5.9:1。
// ⚠️ 均为公式估算，不是实测 —— 真机上若弱化色（时长/序号）看着发虚，再往上提一档。
class PopTheme {
  const PopTheme(this.id, this.ink, this.inset, this.panel, this.raised,
      this.shadow, this.line, this.strokeStrong, this.text, this.muted,
      this.textLow, this.accent, this.accentDeep, this.accentSoft, this.blue,
      this.starOff, this.strongStrokeOnPanels, this.shadowOnPressables,
      this.stickerStars);

  final String id; // 'pop70' | 'pop30'（持久化与相等性判断都用它）
  final Color ink, inset, panel, raised, shadow, line, strokeStrong;
  final Color text, muted, textLow, accent, accentDeep, accentSoft, blue, starOff;
  // —— 浓度开关（两个主题的真正差别在这里，不在色值）——
  final bool strongStrokeOnPanels; // 面板/搜索框是否用奶油勾边强调
  final bool shadowOnPressables; // 可按压元素是否都带硬投影
  final bool stickerStars; // 点亮的星是否贴纸式歪斜

  String get label => id == 'pop70' ? '暖胶·黑胶夜' : '暖胶·浅暖纸（待做）';

  // N10：暖胶 / 复古唱片 —— 目前只做这一套深色（黑胶夜）。
  //
  // 为什么 pop30 也填成同一套值：主题 id 是持久化在手机里的，老值可能是 'pop30'。
  // 若只改 pop70，存了 'pop30' 的手机会打开旧的蓝黑皮肤 —— 那是迁移事故。
  // 两个实例同值 ⇒ 无论持久化值是哪个，打开都是暖胶，零迁移成本。
  // 第二套（浅暖纸，对应参考图 2）留到 N11：届时只改 pop30 的值 + 把切换入口加回来。
  static const PopTheme pop70 = PopTheme(
    'pop70',
    Color(0xFF14100C), Color(0xFF0E0B08), Color(0xFF1E1811),
    Color(0xFF262019), Color(0xFF070503), Color(0xFF3A3026),
    Color(0xFFE8DCC8), Color(0xFFF2E8D9), Color(0xFFA89880),
    Color(0xFF8B7C68), Color(0xFFDE8636), Color(0xFFB45F1E),
    Color(0xFFF0BE86), Color(0xFF8C9C7A), Color(0xFF4A4034),
    false, false, false,
  );

  // 同 pop70（见上：预留给 N11 的浅暖纸，先填同值保证迁移安全）
  static const PopTheme pop30 = PopTheme(
    'pop30',
    Color(0xFF14100C), Color(0xFF0E0B08), Color(0xFF1E1811),
    Color(0xFF262019), Color(0xFF070503), Color(0xFF3A3026),
    Color(0xFFE8DCC8), Color(0xFFF2E8D9), Color(0xFFA89880),
    Color(0xFF8B7C68), Color(0xFFDE8636), Color(0xFFB45F1E),
    Color(0xFFF0BE86), Color(0xFF8C9C7A), Color(0xFF4A4034),
    false, false, false,
  );

  @override
  bool operator ==(Object other) => other is PopTheme && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// 把当前皮肤下发给整个组件树；widget 里 `PopThemeScope.of(context)` 取用。
class PopThemeScope extends InheritedWidget {
  const PopThemeScope({super.key, required this.theme, required super.child});

  final PopTheme theme;

  static PopTheme of(BuildContext c) =>
      c.dependOnInheritedWidgetOfExactType<PopThemeScope>()!.theme;

  @override
  bool updateShouldNotify(PopThemeScope oldWidget) =>
      oldWidget.theme != theme;
}

/// ThemeData 只承载 Material 组件需要的部分；皮肤本体走 PopThemeScope。
ThemeData buildAppTheme(PopTheme t) => ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: t.ink,
      colorScheme: ColorScheme.dark(
        primary: t.accent,
        surface: t.panel,
        onSurface: t.text,
      ),
    );

const String kNumFont = 'SpaceGrotesk'; // 数字/时长展示体（静态 700 实例化）

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
      this.data, this.fileName, this.id);
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

  // N10：MediaStore 的歌曲 id —— **唯一的用途是取专辑封面**
  //      （QueryArtworkWidget 的 id 参数是必填 int，没有它就取不到封面）。
  // ⚠️ 绝不拿它当持久化键：id 由系统分配，重新扫描后可能变，
  //    用它存评分会漂移 —— 评分键永远是上面的 fileName。
  final int id;
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

/// 根组件：持有当前主题 id，切换时整树重建。
/// 主题选择持久化在 SharedPreferencesAsync（与评分同一套存储）。
class ShiyiPlayerApp extends StatefulWidget {
  const ShiyiPlayerApp({super.key});

  @override
  State<ShiyiPlayerApp> createState() => _ShiyiPlayerAppState();
}

class _ShiyiPlayerAppState extends State<ShiyiPlayerApp> {
  static const String _kThemeKey = 'shiyi_player_theme';

  String _themeId = 'pop70'; // 默认 = 一期交付的「玩具总动员」

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    String? saved;
    try {
      saved = await SharedPreferencesAsync().getString(_kThemeKey);
    } catch (e) {
      saved = null; // 读不出来就用默认主题，绝不让 App 起不来
    }
    if (!mounted) return;
    if (saved == 'pop30' || saved == 'pop70') {
      setState(() {
        _themeId = saved!;
      });
    }
  }

  Future<void> _toggleTheme() async {
    final String next = _themeId == 'pop70' ? 'pop30' : 'pop70';
    setState(() {
      _themeId = next;
    });
    try {
      await SharedPreferencesAsync().setString(_kThemeKey, next);
    } catch (e) {
      // 存盘失败只影响「下次启动回到默认」，本次切换照常生效，不打扰用户
    }
  }

  @override
  Widget build(BuildContext context) {
    final PopTheme pt = _themeId == 'pop30' ? PopTheme.pop30 : PopTheme.pop70;
    return MaterialApp(
      title: '接着奏乐',
      debugShowCheckedModeBanner: false,
      // 两套皮肤都是深色 —— 显式锁死 theme 通道，防止系统深浅色模式抢权
      themeMode: ThemeMode.light,
      theme: buildAppTheme(pt),
      home: PopThemeScope(
        theme: pt,
        child: LibraryPage(
          onToggleTheme: _toggleTheme,
          themeName: pt.label,
        ),
      ),
    );
  }
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.onToggleTheme,
    required this.themeName,
  });

  final VoidCallback onToggleTheme;
  final String themeName;

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

  // ===== N10：移除 = App 内标记隐藏 =====
  // 🔴 只记一个文件名黑名单，**一个字节的文件都不动**。
  //    手机扫描的是全盘媒体库，不是 App 自己的文件夹 —— 移动系统媒体文件既可能
  //    被 Android 分区存储拒绝，语义也怪（用户只是不想在列表里看到它，不是要删歌）。
  //    键同样用文件名（与评分同一套理由），随时可恢复。
  Set<String> _hidden = <String>{};
  static const String _kHiddenKey = 'shiyi_player_hidden_v1';
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
  double? _dragMs;

  /// 当前皮肤。State 级 getter —— 本类所有方法直接 `pt.xxx` 取用。
  PopTheme get pt => PopThemeScope.of(context); // 拖动进度条时的临时值（避免被 positionStream 拉回）
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
    _sleepTimer?.cancel(); // N10：睡眠定时
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
    // N10：隐藏名单也要**先于** _load() 读出来，否则扫描时过滤不到
    await _loadHidden();
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

      // N10：剔除被「移除」的歌（App 内标记隐藏）。只是不纳入列表，文件没动。
      final List<_Song> shown =
          kept.where((_Song s) => !_hidden.contains(s.fileName)).toList();

      if (!mounted) return;
      setState(() {
        _songs = shown;
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

    // N10：封面钥匙（QueryArtworkWidget 的必填参数）。
    // 取不到给 0 —— 0 不是合法的音乐 id，组件会走 nullArtworkWidget 兜底，
    // 既不会崩，也不会错显示成别的歌的封面。
    int id = 0;
    try {
      id = m.id;
    } catch (e) {
      id = 0;
    }

    return _Song(title.isEmpty ? '未知曲目' : title, artist, _mmss(durMs), durMs,
        isMusic, uri, data, fileName, id);
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

  // ===== N10：移除（App 内隐藏，不动文件）=====

  Future<void> _loadHidden() async {
    String? raw;
    try {
      raw = await SharedPreferencesAsync().getString(_kHiddenKey);
    } catch (e) {
      raw = null; // 读不出来就当「没隐藏任何歌」，绝不因此让 App 起不来
    }
    final Set<String> m = <String>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        final Object? j = jsonDecode(raw);
        if (j is List) {
          for (final Object? v in j) {
            if (v != null) m.add('$v');
          }
        }
      } catch (e) {
        // 数据坏了就当空，不崩
      }
    }
    if (!mounted) return;
    setState(() {
      _hidden = m;
    });
  }

  Future<void> _saveHidden() async {
    try {
      await SharedPreferencesAsync()
          .setString(_kHiddenKey, jsonEncode(_hidden.toList()));
    } catch (e) {
      // 忽略：这次没存住而已
    }
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(s), duration: const Duration(seconds: 2)),
    );
  }

  /// 长按一首歌 → 底部菜单。
  void _showSongMenu(_Song s) {
    showModalBottomSheet(
      context: context,
      backgroundColor: pt.panel,
      builder: (BuildContext c) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: Icon(Icons.visibility_off_outlined, color: pt.muted),
                title: Text('不再显示这首歌',
                    style: TextStyle(fontSize: 15, color: pt.text)),
                subtitle: Text(
                  s.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: pt.textLow),
                ),
                onTap: () {
                  Navigator.pop(c);
                  _hide(s);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// 隐藏一首歌（只记黑名单，文件一个字节都不动）。
  ///
  /// 🔴 列表一变，N5 那条「队列顺序 = 列表顺序」的对应关系就断了 ——
  ///    所以必须照 _setSort 的套路来：**作废并重建队列**。
  ///    不这么做的话界面高亮会指到别的歌，甚至播的还是旧列表里那一首。
  Future<void> _hide(_Song s) async {
    if (s.fileName.isEmpty) return; // 拿不到文件名就没法存

    final bool hidingPlaying =
        _index >= 0 && _index < _songs.length && _isPlaying(s);
    final _Song? playing =
        (_index >= 0 && _index < _songs.length) ? _songs[_index] : null;
    final Duration pos = _player.position;

    setState(() {
      _hidden.add(s.fileName);
      _songs.removeWhere((_Song x) => x.fileName == s.fileName);
    });
    await _saveHidden();
    _toast('已隐藏「${s.title}」· 可在「已隐藏」里恢复');

    // 正在播的就是这首 ⇒ 它已经不在列表里了，直接停掉最干净，
    // 不留「播着一首列表里没有的歌」这种状态不一致。
    if (hidingPlaying) {
      try {
        await _player.stop();
      } catch (e) {
        // 忽略
      }
      if (!mounted) return;
      setState(() {
        _index = -1;
        _sources = null;
      });
      return;
    }

    if (playing == null) {
      _sources = null; // 没在播：只作废队列，下次点歌自然会重建
      return;
    }

    final int ni = _songs.indexWhere(
        (_Song x) => x.fileName == playing.fileName && x.uri == playing.uri);
    if (ni < 0) {
      _sources = null;
      return;
    }
    if (mounted) {
      setState(() {
        _index = ni;
      });
    }
    try {
      final List<AudioSource> built = _buildSources();
      await _player.setAudioSources(built,
          initialIndex: ni, initialPosition: pos);
      await _player.setLoopMode(LoopMode.all);
    } catch (e) {
      _sources = null;
    }
  }

  /// 恢复：重新扫描把歌加回列表（增量插入容易写错下标，重扫最稳）。
  Future<void> _unhide(String fileName) async {
    setState(() {
      _hidden.remove(fileName);
    });
    await _saveHidden();
    await _load();
  }

  /// 已隐藏清单，点某首即恢复。
  void _showHiddenSheet() {
    final List<String> names = _hidden.toList()..sort();
    showModalBottomSheet(
      context: context,
      backgroundColor: pt.panel,
      builder: (BuildContext c) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Text(
                  '已隐藏 ${names.length} 首 · 点一下恢复',
                  style: TextStyle(fontSize: 13, color: pt.muted),
                ),
              ),
              ListView.builder(
                shrinkWrap: true,
                itemCount: names.length,
                itemBuilder: (BuildContext c2, int i) {
                  return ListTile(
                    title: Text(names[i],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, color: pt.text)),
                    trailing: Icon(Icons.undo, size: 18, color: pt.accent),
                    onTap: () {
                      Navigator.pop(c);
                      _unhide(names[i]);
                    },
                  );
                },
              ),
            ],
          ),
        );
      },
    );
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
                  Expanded(
                    child: Text(
                      '接着奏乐',
                      style: TextStyle(
                        // N10：26→28、字距 1.0→2.0 ——
                        // 中文大标题松开字距才有「唱片内页」的排版味
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: pt.text,
                        letterSpacing: 2.0,
                        height: 1.1,
                      ),
                    ),
                  ),
                  // N10：主题切换入口**已撤** —— 目前只有一套暖胶，
                  //     点了没变化反而像个 bug。切换机制（onToggleTheme / themeName）
                  //     完整保留在代码里，N11 加浅暖纸时把这个按钮加回来即可。
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: pt.muted,
                      textStyle: TextStyle(fontSize: 12.5),
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
                      style: TextStyle(
                        fontSize: 12.5,
                        color: pt.accentSoft,
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
                      foregroundColor: pt.blue,
                    ),
                    onPressed: _stage == 'ready'
                        ? () {
                            _setSort(_sortMode == 'stars' ? 'title' : 'stars');
                          }
                        : null,
                    child: Text(
                      _sortMode == 'stars' ? '排序：按星级' : '排序：按标题',
                      style: TextStyle(fontSize: 12, letterSpacing: 0.5),
                    ),
                  ),
                  // N10：恢复入口**必须放在标题栏**，不能放列表底部 ——
                  // 万一所有歌都被隐藏，列表空了、底部入口跟着消失 ⇒ 用户再也恢复不回来。
                  if (_hidden.isNotEmpty)
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        foregroundColor: pt.muted,
                      ),
                      onPressed: _showHiddenSheet,
                      child: Text(
                        '已隐藏 ${_hidden.length}',
                        style: TextStyle(fontSize: 12, letterSpacing: 0.5),
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
      // N7：搜索命中数。延续「关键计数恒常显示」纪律 ——
      //     搜索时必须能看到命中几首，否则「列表怎么空了」和「搜不到」
      //     在界面上长得一模一样，用户无法区分。
      final String hit =
          _searchText.trim().isEmpty ? '' : ' · 找到 ${_visList().length} 首';
      return '共 ${_songs.length} 首$hit';
    }
    return '手机版 · 曲库 $kBuild';
  }

  /// N10：诊断串 —— 从标题正下方**挪到列表底部**的小字。
  ///
  /// 🔴 这是「换位置」，不是「隐藏」：这三条计数在排查问题时是唯一线索，
  ///    恒常显示（零值也显示）的纪律一条不改，见下面对 N6 踩坑的引用。
  Widget _diagnosticsLine() {
    if (_stage != 'ready') return const SizedBox.shrink();
    // 🔴 N6 踩坑修正（详见 节点进度.md §二十二）：
    //   旧写法「零值时整段消失」，而「评分一条都没匹配上」恰恰就是零值，
    //   结果失败在界面上看起来像「功能没做出来」，用户无法提供任何线索。
    final int orphan = _stars.length - _ratedCount;
    final String star = '已评 $_ratedCount 首'
        '${orphan > 0 ? '（另有 $orphan 条找不到对应文件）' : ''}';
    final String dup =
        _sameNameGroups > 0 ? ' · ⚠️ $_sameNameGroups 组同名' : '';
    final String extra =
        _filteredOut > 0 ? ' · 已滤掉 $_filteredOut 首铃声/提示音' : '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
      child: Text(
        '$star$dup$extra',
        maxLines: 2,
        style: TextStyle(fontSize: 11, color: pt.textLow, height: 1.4),
      ),
    );
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
    // N10：歌全被隐藏了 —— 列表会是空的，必须说清楚为什么、怎么恢复，
    //      否则用户看到一片空白只能以为是 App 坏了。
    if (_songs.isEmpty && _hidden.isNotEmpty) {
      return _hint('列表里的歌都被隐藏了\n\n点标题栏的「已隐藏 ${_hidden.length}」可以恢复');
    }
    // N7：搜索无命中 → 明确说「没找到」，绝不给一片空白。
    //（空白会让用户分不清「搜不到」和「App 坏了」）
    if (_searchText.trim().isNotEmpty && _visList().isEmpty) {
      return _hint('没找到「${_searchText.trim()}」\n\n可以搜歌名、歌手或文件名');
    }
    // N10：列表 + 底部诊断串。诊断串原本挂在标题正下方（开发者信息占了门面），
    //      现在降到列表底部小字 —— 仍然可见，只是不再抢第一眼。
    return Column(
      children: <Widget>[
        Expanded(child: _songList()),
        _diagnosticsLine(),
      ],
    );
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
        color: pt.raised,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          // N9：pop70 用奶油勾边强调，pop30 收敛为常规细线；聚焦时统一变蓝加粗
          color: focused
              ? pt.blue
              : (pt.strongStrokeOnPanels ? pt.strokeStrong : pt.line),
          width: focused ? 1.8 : (pt.strongStrokeOnPanels ? 1.4 : 1.2),
        ),
        // N9：pop30 的可按压元素不带投影 —— 硬投影只留给播放条
        boxShadow: pt.shadowOnPressables
            ? <BoxShadow>[
                BoxShadow(
                    color: pt.shadow, offset: Offset(0, 2), blurRadius: 0),
              ]
            : null,
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.search, size: 18, color: focused ? pt.blue : pt.textLow),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchCtl,
              focusNode: _searchFocus,
              style: TextStyle(fontSize: 14, color: pt.text),
              cursorColor: pt.accent,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: '搜索歌名 / 歌手 / 文件名',
                hintStyle: TextStyle(fontSize: 13, color: pt.textLow),
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
              child: Padding(
                padding: EdgeInsets.only(left: 8, top: 4, bottom: 4),
                child: Icon(Icons.close, size: 18, color: pt.muted),
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
          style: TextStyle(fontSize: 13.5, color: pt.muted, height: 1.6),
        ),
      ),
    );
  }

  Widget _permissionCard() {
    return Center(
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        decoration: BoxDecoration(
          color: pt.panel,
          borderRadius: BorderRadius.circular(20),
          // N9：浓度开关 —— pop70 奶油勾边+投影，pop30 细线无投影
          border: Border.all(
            color: pt.strongStrokeOnPanels ? pt.strokeStrong : pt.line,
            width: pt.strongStrokeOnPanels ? 2 : 1.2,
          ),
          boxShadow: pt.shadowOnPressables
              ? <BoxShadow>[
                  BoxShadow(
                      color: pt.shadow, offset: Offset(0, 3), blurRadius: 0),
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '需要「音乐和音频」权限',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: pt.text,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '安卓 13 起，读取本地音乐要单独授权。\n点下面的按钮，在系统弹窗里选「允许」。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: pt.muted, height: 1.55),
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
            Text(
              '权限没问题，但一首歌都没扫到',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: pt.text,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '最常见的两个原因：\n\n'
              '1. 音乐被放在了 Android/data/… 里面\n'
              '   （安卓 11 起系统不索引这个目录，任何播放器都扫不到）\n\n'
              '2. 刚拷进来，系统媒体库还没入库\n\n'
              '办法：把音乐挪到「内部存储 / Music /」或「Download /」，'
              '再点右上角「重新扫描」。',
              style: TextStyle(fontSize: 12.5, color: pt.muted, height: 1.6),
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
              // N8 方案二·贴纸感：点亮的星按位置交替歪一点点。
              // N9：歪不歪由主题定 —— pop30「精密潮玩」不歪（浓度开关 stickerStars）
              angle: on && pt.stickerStars ? (i.isEven ? 0.07 : -0.07) : 0,
              child: Icon(
                on ? Icons.star_rounded : Icons.star_outline_rounded,
                size: 17,
                color: on ? pt.accent : pt.starOff,
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
      separatorBuilder: (BuildContext c, int i) => Divider(
        height: 1,
        thickness: 1,
        color: pt.line,
      ),
      itemBuilder: (BuildContext c, int i) {
        final _Song m = vis[i];
        final bool playing = _isPlaying(m); // N7：比对象，不比下标
        return InkWell(
          // N10：长按 = 「不再显示」。
          // 把「移除」这种不可撤销感的操作放长按，和「短按播放」分开 —— 避免误触。
          onLongPress: () {
            _showSongMenu(m);
          },
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
                    color: pt.panel,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: pt.strokeStrong, width: 1.6),
                  )
                : null,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                // N10：封面 48px（圆角 6 = 照片卡片的圆角，不是玩具的圆角）。
                //     没有内嵌封面的歌走兜底：文件名 hash 出的暖色块 + 首字。
                _cover(m),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      // 第一行：曲名（左组·这是什么歌） | 时长（右组·它的状态）
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              m.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                color: playing ? pt.accent : pt.text,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          // N10：时长**故意不套**展示体数字 ——
                          // 那个字体只有 700 粗，会比 500 的中文曲名还重，抢主角的戏。
                          // 走系统字 12px + 弱化色，安静待在右边。
                          Text(
                            m.dur,
                            style: TextStyle(
                              fontSize: 12,
                              color: playing ? pt.accentSoft : pt.textLow,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      // 第二行：歌手（左组·与曲名强绑定） | 星级（右组·它的状态）
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              m.artist.isEmpty ? '未知歌手' : m.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  TextStyle(fontSize: 12, color: pt.muted),
                            ),
                          ),
                          const SizedBox(width: 16),
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

  // ===== N10：列表封面 =====

  /// 有封面用封面，没封面用兜底色块。
  ///
  /// `QueryArtworkWidget` 的 `id` 是必填 int（MediaStore 歌曲 id）——
  /// 这就是 `_Song` 必须有 id 字段的原因：没有它，封面取不出来。
  ///
  /// `size: 160` 是**解码尺寸**：列表只显示 48dp，压到 160 省内存也省电
  /// （战略层：省电优先；48dp 在 3x 屏上也才 144px，160 够用）。
  Widget _cover(_Song m) {
    return SizedBox(
      width: 48,
      height: 48,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: QueryArtworkWidget(
          id: m.id,
          type: ArtworkType.AUDIO,
          artworkWidth: 48,
          artworkHeight: 48,
          artworkBorder: BorderRadius.circular(6),
          artworkFit: BoxFit.cover,
          artworkQuality: FilterQuality.medium,
          quality: 70,
          size: 160,
          keepOldArtwork: true,
          nullArtworkWidget: _coverFallback(m),
        ),
      ),
    );
  }

  /// 没有内嵌封面的歌（flac 很常见）：文件名 hash → 暖色块 + 首字。
  ///
  /// 为什么用**固定色板**而不是 hash 算 HSL：hash 出来的颜色不可控，
  /// 偶尔会撞出难看的色相，直接破坏暖胶调性。这 6 个色是挑过的暖棕 / 苔绿。
  Widget _coverFallback(_Song m) {
    final int h = _hash(m.fileName);
    final Color bg = _kFallbackCovers[h % _kFallbackCovers.length];
    final String ch = m.title.isEmpty ? '?' : m.title.substring(0, 1);
    return Container(
      width: 48,
      height: 48,
      color: bg,
      alignment: Alignment.center,
      child: Text(
        ch,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w500,
          color: Color(0xFFF2E8D9),
        ),
      ),
    );
  }

  /// 自己写 hash，不用 `String.hashCode` —— 保证跨版本、跨运行都稳定：
  /// 同一首歌在任何手机上永远拿到同一个颜色，不会今天棕明天绿。
  static int _hash(String s) {
    int h = 0;
    for (int i = 0; i < s.length; i++) {
      h = (h * 31 + s.codeUnitAt(i)) & 0x7fffffff;
    }
    return h;
  }

  static const List<Color> _kFallbackCovers = <Color>[
    Color(0xFF6B4A2F), // 深棕
    Color(0xFF7A5230), // 琥珀棕
    Color(0xFF5C4A32), // 灰棕
    Color(0xFF8A6A3A), // 焦糖
    Color(0xFF4E5B3C), // 苔绿
    Color(0xFF6B5A3E), // 暖橄榄
  ];

  /// 底部播放条：曲名 + 歌手 + 进度条 + 时间 + ⏮ ⏯ ⏭
  Widget _playerBar() {
    final _Song s = _songs[_index];
    return Container(
      margin: const EdgeInsets.only(top: 6, bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: BoxDecoration(
        color: pt.panel,
        borderRadius: BorderRadius.circular(20),
        // 播放条是全 App 的「主角框」：勾边+硬投影两套主题都保留，
        // 只有勾边强弱随浓度走（pop30 换成细一点的常规线）
        border: Border.all(
          color: pt.strongStrokeOnPanels ? pt.strokeStrong : pt.line,
          width: pt.strongStrokeOnPanels ? 2 : 1.2,
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(color: pt.shadow, offset: Offset(0, 3), blurRadius: 0),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                // N10：点曲名区 → 打开全屏播放页。
                // 提示箭头用 expand_less（向上），暗示「往上展开成整页」。
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _openNowPlaying,
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              s.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: pt.accent,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              s.artist.isEmpty ? '未知歌手' : s.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11.5, color: pt.muted),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(Icons.expand_less, size: 20, color: pt.textLow),
                    ],
                  ),
                ),
              ),
              IconButton(
                onPressed: _prev,
                icon: Icon(Icons.skip_previous),
                color: pt.text,
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
                        color: _playPressed ? pt.accentDeep : pt.accent,
                        shape: BoxShape.circle,
                        border: Border.all(color: pt.strokeStrong, width: 2),
                        boxShadow: _playPressed
                            ? <BoxShadow>[]
                            : <BoxShadow>[
                                BoxShadow(
                                    color: pt.shadow,
                                    offset: Offset(0, 3),
                                    blurRadius: 0),
                              ],
                      ),
                      child: Icon(
                        playing ? Icons.pause : Icons.play_arrow,
                        size: 32,
                        color: pt.ink, // 图标「挖空」成底色 —— 印刷感，不是系统感
                      ),
                    ),
                  );
                },
              ),
              IconButton(
                onPressed: _next,
                icon: Icon(Icons.skip_next),
                color: pt.text,
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
                    activeColor: pt.accent,
                    inactiveColor: pt.inset,
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
                        style: TextStyle(
                            fontFamily: kNumFont,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: pt.muted,
                            letterSpacing: 0.3),
                      ),
                      const Spacer(),
                      Text(
                        _mmss(totalMs),
                        style: TextStyle(
                            fontFamily: kNumFont,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: pt.muted,
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

  /// N10：点曲名区 → 打开全屏「正在播放」页。
  /// 系统返回（返回键 + 安卓边缘返回手势）由 Navigator 自动接管，不写额外手势 ——
  /// 下滑返回是 iOS 习惯，且在安卓上会和封面区的滑动误触。
  void _openNowPlaying() {
    if (_index < 0 || _index >= _songs.length) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext c) => _NowPlayingPage(
          player: _player,
          songs: _songs,
          stars: _stars,
          // _rate / _next / _prev / _setSleep 内部各自会 setState，这里不要再包一层
          // —— 嵌套 setState 虽不崩，但纯属冗余，还容易让人误以为外面这层才是关键。
          onRate: _rate,
          onNext: _next,
          onPrev: _prev,
          onSleep: _setSleep,
        ),
      ),
    );
  }

  /// 睡眠定时：到点**直接停**。
  /// （十一拍板：不做「播完当前曲再停」—— 人睡着了不需要优雅收尾，
  ///   没睡着会自己再设定时；直接停还更省电。）
  Timer? _sleepTimer;

  void _setSleep(int minutes) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    if (minutes <= 0) {
      _toast('已取消定时');
      return;
    }
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      _player.stop();
      if (mounted) {
        setState(() {
          _index = -1;
        });
      }
      _toast('定时到了，已停止播放');
    });
    _toast('$minutes 分钟后停止播放');
  }
}

// ============================================================================
//  N10：正在播放（全屏页）
//
//  构图蓝本 = 十一给的参考图 4：深底 + 方形封面卡 + 唱片右侧半露 + 控件在下。
//  背景 = 参考图 1 的做法（封面放大模糊 + 暗遮罩）—— **零新依赖**。
//  不做「取色渐变」：老歌封面取色容易脏，而模糊原封面永远不会脏，它就是封面本身。
//
//  🔴 状态一律用 StreamBuilder 读播放器（currentIndex / position / playerState /
//     shuffleModeEnabled）—— 这样无论切歌来自页面内按钮、后台自动切、还是通知栏，
//     页面都跟着变，不会出现「显示 A 却在播 B」这种最难查的错位。
//
//  🔴 唱片**不转**（十一拍板 1B + 战略层省电）：静态 CustomPaint 画同心圆，
//     零动画零重绘；要照片级质感才需要换图片，但那会加体积且不能随主题变色。
// ============================================================================
class _NowPlayingPage extends StatelessWidget {
  const _NowPlayingPage({
    required this.player,
    required this.songs,
    required this.stars,
    required this.onRate,
    required this.onNext,
    required this.onPrev,
    required this.onSleep,
  });

  final AudioPlayer player;
  final List<_Song> songs;
  final Map<String, int> stars;
  final void Function(_Song, int) onRate;
  final void Function() onNext;
  final void Function() onPrev;
  final void Function(int) onSleep;

  @override
  Widget build(BuildContext context) {
    final PopTheme pt = PopThemeScope.of(context);
    return Scaffold(
      backgroundColor: pt.ink,
      body: StreamBuilder<int?>(
        stream: player.currentIndexStream,
        builder: (BuildContext c, AsyncSnapshot<int?> snap) {
          final int i = snap.data ?? player.currentIndex ?? 0;
          if (songs.isEmpty || i < 0 || i >= songs.length) {
            return const SizedBox.shrink();
          }
          final _Song s = songs[i];
          return Stack(
            children: <Widget>[
              Positioned.fill(child: _backdrop(s, pt)),
              SafeArea(child: _content(context, s, pt)),
            ],
          );
        },
      ),
    );
  }

  /// 模糊氛围背景：封面放大 → 高斯模糊 → 压一层暗色。
  /// 只在切歌时重算一次（静态），不是每帧 —— 不违背省电目标。
  Widget _backdrop(_Song s, PopTheme pt) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
          child: Transform.scale(
            scale: 1.4,
            child: QueryArtworkWidget(
              id: s.id,
              type: ArtworkType.AUDIO,
              artworkFit: BoxFit.cover,
              artworkWidth: 480,
              artworkHeight: 960,
              size: 320, // 反正要糊掉，解码尺寸压小 —— 省内存省电
              quality: 55,
              keepOldArtwork: true,
              nullArtworkWidget: Container(color: pt.panel),
            ),
          ),
        ),
        Container(color: pt.ink.withOpacity(0.76)),
      ],
    );
  }

  Widget _content(BuildContext context, _Song s, PopTheme pt) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
          child: Row(
            children: <Widget>[
              IconButton(
                icon: Icon(Icons.expand_more, color: pt.text),
                tooltip: '回到曲库',
                onPressed: () => Navigator.pop(context),
              ),
              Expanded(
                child: Text(
                  '正在播放',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13, color: pt.muted, letterSpacing: 1.5),
                ),
              ),
              IconButton(
                icon: Icon(Icons.timer_outlined, color: pt.muted),
                tooltip: '睡眠定时',
                onPressed: () => _sleepSheet(context, pt),
              ),
            ],
          ),
        ),
        Expanded(
          child: Center(child: _coverWithVinyl(context, s, pt)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                s.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: pt.text,
                    letterSpacing: 0.5),
              ),
              const SizedBox(height: 4),
              Text(
                s.artist.isEmpty ? '未知歌手' : s.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: pt.muted),
              ),
              const SizedBox(height: 6),
              _starsInline(s, pt),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _progress(s, pt),
        const SizedBox(height: 2),
        // 顺序 / 随机 —— 十一拍板：入口跟着播放组件走
        _modeButton(pt),
        const SizedBox(height: 4),
        _controls(pt),
        const SizedBox(height: 18),
      ],
    );
  }

  /// 方形封面卡 + 右侧半露的黑胶唱片。
  Widget _coverWithVinyl(BuildContext context, _Song s, PopTheme pt) {
    final double size = MediaQuery.of(context).size.width - 96;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: QueryArtworkWidget(
                id: s.id,
                type: ArtworkType.AUDIO,
                artworkFit: BoxFit.cover,
                artworkWidth: size,
                artworkHeight: size,
                artworkBorder: BorderRadius.circular(6),
                size: 600,
                quality: 90,
                keepOldArtwork: true,
                nullArtworkWidget: _fallbackBig(s, pt),
              ),
            ),
          ),
          // 唱片从右侧露出约四成 —— 这是「暖胶复古」的签名元素
          Positioned(
            right: -size * 0.30,
            top: size * 0.19,
            child: CustomPaint(
              size: Size(size * 0.62, size * 0.62),
              painter: _VinylPainter(pt: pt),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fallbackBig(_Song s, PopTheme pt) {
    return Container(
      color: pt.raised,
      alignment: Alignment.center,
      child: Text(
        s.title.isEmpty ? '?' : s.title.substring(0, 1),
        style: TextStyle(fontSize: 64, color: pt.muted),
      ),
    );
  }

  Widget _starsInline(_Song s, PopTheme pt) {
    final int cur = stars[s.fileName] ?? 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List<Widget>.generate(5, (int k) {
        return IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          iconSize: 24,
          icon: Icon(
            k < cur ? Icons.star : Icons.star_border,
            color: k < cur ? pt.accent : pt.starOff,
          ),
          onPressed: () => onRate(s, k + 1),
        );
      }),
    );
  }

  Widget _progress(_Song s, PopTheme pt) {
    return StreamBuilder<Duration>(
      stream: player.positionStream,
      builder: (BuildContext c, AsyncSnapshot<Duration> snap) {
        final int cur = (snap.data ?? Duration.zero).inMilliseconds;
        final int total = s.durMs > 0 ? s.durMs : 1;
        double v = cur / total;
        if (v < 0) v = 0;
        if (v > 1) v = 1;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: <Widget>[
              SliderTheme(
                data: SliderThemeData(
                  trackHeight: 4,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 7),
                  activeTrackColor: pt.accent,
                  inactiveTrackColor: pt.line,
                  thumbColor: pt.accentSoft,
                ),
                child: Slider(
                  value: v,
                  onChanged: (double x) {
                    player.seek(Duration(milliseconds: (x * total).round()));
                  },
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Text(_mmss(cur),
                      style: TextStyle(fontSize: 12, color: pt.muted)),
                  Text(_mmss(total),
                      style: TextStyle(fontSize: 12, color: pt.muted)),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _modeButton(PopTheme pt) {
    return StreamBuilder<bool>(
      stream: player.shuffleModeEnabledStream,
      builder: (BuildContext c, AsyncSnapshot<bool> snap) {
        final bool on = snap.data ?? false;
        return TextButton.icon(
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 34),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          icon: Icon(
            on ? Icons.shuffle : Icons.repeat,
            size: 17,
            color: on ? pt.accent : pt.muted,
          ),
          label: Text(
            on ? '随机播放' : '顺序播放',
            style:
                TextStyle(fontSize: 12.5, color: on ? pt.accent : pt.muted),
          ),
          onPressed: () async {
            try {
              await player.setShuffleModeEnabled(!on);
            } catch (e) {
              // 切换失败不致命
            }
          },
        );
      },
    );
  }

  /// 控件区：⏮ / 大播放键 72px / ⏭ —— 位于屏幕下半部（拇指区）。
  Widget _controls(PopTheme pt) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        IconButton(
          iconSize: 34,
          icon: Icon(Icons.skip_previous, color: pt.text),
          tooltip: '上一首',
          onPressed: onPrev,
        ),
        const SizedBox(width: 24),
        StreamBuilder<PlayerState>(
          stream: player.playerStateStream,
          builder: (BuildContext c, AsyncSnapshot<PlayerState> snap) {
            final bool playing = snap.data?.playing ?? false;
            return GestureDetector(
              onTap: () {
                if (playing) {
                  player.pause();
                } else {
                  player.play();
                }
              },
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: pt.accent,
                  shape: BoxShape.circle,
                  border: Border.all(color: pt.strokeStrong, width: 2),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                        color: pt.shadow, offset: Offset(0, 3), blurRadius: 0),
                  ],
                ),
                child: Icon(
                  playing ? Icons.pause : Icons.play_arrow,
                  size: 38,
                  color: pt.ink,
                ),
              ),
            );
          },
        ),
        const SizedBox(width: 24),
        IconButton(
          iconSize: 34,
          icon: Icon(Icons.skip_next, color: pt.text),
          tooltip: '下一首',
          onPressed: onNext,
        ),
      ],
    );
  }

  void _sleepSheet(BuildContext context, PopTheme pt) {
    showModalBottomSheet(
      context: context,
      backgroundColor: pt.panel,
      builder: (BuildContext c) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Text('多久以后停止播放',
                    style: TextStyle(fontSize: 13, color: pt.muted)),
              ),
              for (final int m in const <int>[15, 30, 60])
                ListTile(
                  title: Text('$m 分钟后',
                      style: TextStyle(fontSize: 15, color: pt.text)),
                  onTap: () {
                    Navigator.pop(c);
                    onSleep(m);
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 静态黑胶唱片（同心圆沟槽 + 琥珀标签 + 中心孔）。
/// **不转** —— 零动画零重绘，符合战略层「省电」。
class _VinylPainter extends CustomPainter {
  const _VinylPainter({required this.pt});

  final PopTheme pt;

  @override
  void paint(Canvas canvas, Size size) {
    final double r = size.width / 2;
    final Offset c = Offset(r, r);

    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF1A1512));
    final Paint groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = pt.line.withOpacity(0.55);
    for (double rr = r * 0.40; rr < r * 0.95; rr += 4) {
      canvas.drawCircle(c, rr, groove);
    }
    canvas.drawCircle(c, r * 0.34, Paint()..color = pt.accent);
    canvas.drawCircle(c, r * 0.05, Paint()..color = pt.ink);
  }

  @override
  bool shouldRepaint(covariant _VinylPainter old) => old.pt != pt;
}
