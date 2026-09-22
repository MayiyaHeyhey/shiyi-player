// ============================================================================
//  十一 · 接着奏乐 —— 手机版
//  N1 节点：骨架自检页
//
//  这个文件的唯一使命，是证明「代码 → 云端编译 → 装进手机」整条链路是通的。
//  同时把 N2 需要的设备信息（系统版本 / 分辨率 / 安全区）打到屏幕上。
//
//  标记串：SHIYI_PLAYER_N1 —— CI 会检查它，防止本文件被模板覆盖。
// ============================================================================
import 'dart:io';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
// ===== 设计令牌：与网页版 index.html 完全一致（墨黑 + 黄铜）=====
const Color kInk = Color(0xFF0B0A09); // 暖黑底
const Color kPanel = Color(0xFF151311); // 卡片底
const Color kLine = Color(0xFF2A2622); // 分隔线
const Color kBrass = Color(0xFFD8A24A); // 主色·黄铜
const Color kBrassLight = Color(0xFFF0C47C); // 亮黄铜
const Color kText = Color(0xFFECE5D9); // 暖白字
const Color kMuted = Color(0xFF8A8175); // 次级文字
// 带透明度的黄铜（预先算好 alpha，避免依赖 withOpacity / withValues 这类会变的 API）
const Color kBrassBg = Color(0x1AD8A24A); // 10% 黄铜底
const Color kBrassBorder = Color(0x59D8A24A); // 35% 黄铜边
void main() {
  runApp(const ShiyiPlayerApp());
}
class ShiyiPlayerApp extends StatelessWidget {
  const ShiyiPlayerApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '十一 · 接着奏乐',
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
      home: const N1BootCheck(),
    );
  }
}
class N1BootCheck extends StatelessWidget {
  const N1BootCheck({super.key});
  @override
  Widget build(BuildContext context) {
    final MediaQueryData mq = MediaQuery.of(context);
    final Size size = mq.size;
    final double dpr = mq.devicePixelRatio;
    final EdgeInsets pad = mq.padding;
    final bool isRelease = !kDebugMode;
    final List<List<String>> rows = <List<String>>[
      <String>[
        '构建模式',
        isRelease ? 'release（真机安装包）' : 'debug',
      ],
      <String>[
        '系统版本',
        Platform.operatingSystemVersion,
      ],
      <String>[
        '逻辑分辨率',
        size.width.toStringAsFixed(0) +
            ' × ' +
            size.height.toStringAsFixed(0) +
            ' dp',
      ],
      <String>[
        '像素比',
        dpr.toStringAsFixed(2) + '×',
      ],
      <String>[
        '物理分辨率',
        (size.width * dpr).toStringAsFixed(0) +
            ' × ' +
            (size.height * dpr).toStringAsFixed(0) +
            ' px',
      ],
      <String>[
        '屏幕方向',
        mq.orientation == Orientation.portrait ? '竖屏' : '横屏',
      ],
      <String>[
        '安全区',
        '上 ' +
            pad.top.toStringAsFixed(0) +
            ' / 下 ' +
            pad.bottom.toStringAsFixed(0),
      ],
    ];
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 30, 22, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // ---------- 标题 ----------
              const Text(
                '十一 · 接着奏乐',
                style: TextStyle(
                  fontSize: 29,
                  fontWeight: FontWeight.w700,
                  color: kText,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Container(width: 26, height: 2, color: kBrass),
                  const SizedBox(width: 10),
                  const Text(
                    '手机版 · N1 骨架自检',
                    style: TextStyle(
                      fontSize: 13.5,
                      color: kBrass,
                      letterSpacing: 2,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              // ---------- 自检信息 ----------
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: kPanel,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: kLine),
                  ),
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        '自检信息',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: kMuted,
                          letterSpacing: 1.6,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Expanded(
                        child: ListView.separated(
                          itemCount: rows.length,
                          separatorBuilder: (BuildContext ctx, int i) =>
                              const SizedBox(height: 11),
                          itemBuilder: (BuildContext ctx, int i) {
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                SizedBox(
                                  width: 76,
                                  child: Text(
                                    rows[i][0],
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: kMuted,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    rows[i][1],
                                    style: const TextStyle(
                                      fontSize: 13.5,
                                      color: kText,
                                      height: 1.35,
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // ---------- 结论 ----------
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 15),
                decoration: BoxDecoration(
                  color: kBrassBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: kBrassBorder),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '✅ 骨架跑通',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: kBrassLight,
                      ),
                    ),
                    SizedBox(height: 7),
                    Text(
                      '这个页面能打开，说明「写代码 → 云端编译 → 装进手机」整条链路已经打通。\n'
                      '下一步 N2：扫描手机里的音乐，把曲库显示出来。',
                      style: TextStyle(
                        fontSize: 13,
                        color: kText,
                        height: 1.55,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
