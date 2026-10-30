# 影视聚合 · TV Aggregation

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![Platform](https://img.shields.io/badge/platform-Android%20TV%20%7C%20Web-green)](#)
[![License](https://img.shields.io/badge/license-Personal%20use-lightgrey)](#disclaimer)

**中文名：影视聚合** · **English: TV Aggregation**

Flutter 实现的 Android TV + Web 影视客户端：聚合自建 / 第三方 MacCMS 采集源，支持豆瓣推荐、搜索、多线路播放与遥控器操作。

> Repository: [github.com/functionName/TV-Aggregation](https://github.com/functionName/TV-Aggregation)

---

## Features

- **首页**：豆瓣热门 / 单源发现流，电视遥控友好
- **搜索**：屏幕键盘 + 多源聚合；支持拼音辅助
- **详情**：多源、多线路、选集、收藏与历史续播
- **播放器**：倍速、换线、HLS 中插广告过滤（对齐常见 m3u8 异源块思路）
- **设置**：扫码 / U 盘 / JSON 导入采集源；成人内容过滤等开关
- **双端**：Android TV（Leanback）与 Web 调试预览

## Screenshots

（可自行补充截图到 `docs/screenshots/`）

## Requirements

- [Flutter SDK](https://docs.flutter.dev/get-started/install)（建议 3.24+）
- Android SDK（打 TV APK）
- Chrome（跑 Web）

```bash
flutter pub get
```

## Run

### Web（需本地 CORS 代理）

浏览器无法直连多数采集站与豆瓣，调试时请走项目自带代理：

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File scripts/run_web.ps1
# 打开 http://localhost:8080
```

### Android / TV

```bash
flutter devices
flutter run -d <deviceId>
```

电视 APK 无浏览器 CORS，播放与接口均为直连，不需要 Web 代理。

## Build APK（电视 32 位）

默认打 `armeabi-v7a`，适配多数安卓盒子：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build_tv_apk.ps1
```

产物示例：

- `build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk`
- 或脚本复制后的 `yingshi-x.y.z-armeabi-v7a-release.apk`

```bash
# 也可直接
flutter build apk --release --split-per-abi --target-platform android-arm
```

## Project layout

```
lib/                 # Dart 业务与 UI
  screens/           # 首页 / 发现 / 搜索 / 详情 / 播放 / 设置
  services/          # 采集、豆瓣、播放列表过滤、配置存储
  widgets/           # 焦点、品牌、通用组件
android/             # Android TV 壳
web/                 # Flutter Web
scripts/             # run_web.ps1 / build_tv_apk.ps1
tool/web_proxy.dart  # Web 调试 CORS 代理 + m3u8 去广告列表
assets/              # 默认源配置、手机配源页、品牌图
```

## Configuration

应用不内置商业片源。请在 **设置** 中：

1. 扫码用手机添加 MacCMS `api.php/provide/vod` 地址，或
2. 导入 JSON（兼容常见 LibreTV / 同类 settings 格式），或
3. 电视端从 U 盘读取配置文件

默认示例源仅作结构参考，可用性随上游变化，请自行维护。

## Disclaimer

本项目仅供学习与个人研究 Flutter / Android TV 交互。

- 不提供、不托管任何影视版权内容
- 用户需自行配置合法合规的数据源，并对使用行为负责
- 请遵守当地法律法规与上游站点服务条款

## License

源码按个人项目公开；若需明确开源协议，可后续补充 `LICENSE`（如 MIT）。第三方依赖遵循各自许可证。

## Acknowledgements

UI 与部分业务思路迁移自早期 WebView 壳方案；m3u8 中插过滤参考常见播放器对 `#EXT-X-DISCONTINUITY` 异源块的处理方式。
