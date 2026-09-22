// 冒烟测试：只验证测试环境能跑，不引用任何业务类。
//
// 为什么要有这个文件：
//   `flutter create` 如果发现 test/ 不存在，会自动补一个引用模板类 MyApp 的
//   widget_test.dart，而我们的 main.dart 里没有 MyApp —— flutter analyze 会报 hard error。
//   把这个文件放进仓库，flutter create 就不会再生成模板版。
//   同时 CI 也会在 flutter create 之后重写一遍，双保险。
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('冒烟：测试环境可用', () {
    expect(1 + 1, 2);
  });
}
