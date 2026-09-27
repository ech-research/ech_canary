# ECH Canary

<img src="assets/branding/ech-canary-icon.png" width="96" height="96" alt="ECH Canary 图标">

ECH Canary 是一款用于检查 HTTPS 连通性和 ECH（Encrypted Client Hello）握手结果的网络诊断工具。通过比较普通 TLS、ECH、不同 DNS 解析结果和指定 IP 下的连接表现，帮助判断当前网络中可用的访问方式。

应用基于 Flutter，支持 Android、Windows、Linux、macOS 和 iOS，采用 Material 3 Expressive 界面，适配桌面与移动设备。目前不提供 Web 版本。

## 使用方法

1. 在首页输入需要测试的域名或完整 HTTPS 地址。仅输入域名时，会自动补全 `https://`。
2. 选择直连、前置代理，或同时测试两种连接方式。使用前置代理时，填写 `http://主机:端口` 格式的 HTTP CONNECT 代理地址；目前不支持需要账号密码的代理。
3. 根据需要在设置页调整重复次数、超时、连接 IP、DNS / ECH 和测试基线。
4. 开始测试，完成后查看访问结论和可用方式。连接记录、判定依据、DNS / ECH 配置及日志可在“测试详情”中查看。

默认使用直连，每个测试组合重复两轮，单次请求超时 8 秒。DNS over HTTPS（DoH）服务依次尝试阿里 DNS、Cloudflare DNS 和 Google DNS 的 JSON 接口。

测试基线用于对照当前网络的连接情况，默认地址为 `https://crypto.cloudflare.com/cdn-cgi/trace`。测试目标与基线必须使用不同域名；两者都可以自行设置。

应用只使用手动填写的前置代理，不自动读取系统或环境变量中的代理配置。“直连”表示未为测试请求配置 HTTP 代理，系统 VPN/TUN 仍可能影响实际网络路径。

## 测试策略

对目标域名和测试基线，应用会在所选连接方式下分别执行以下测试：

| 策略 | ECH | TCP / CONNECT 目标 |
| --- | --- | --- |
| 普通 TLS | 关闭 | 原域名 |
| 系统 IP | 关闭 | 本机 DNS 解析 IP |
| DoH IP | 关闭 | 本路径 DoH 的 A / AAAA |
| ECH 域名连接 | 必须接受 | 原域名 |
| ECH + 系统 IP | 必须接受 | 本机 DNS 解析 IP |
| ECH + DoH IP | 必须接受 | 本路径 DoH 的 A / AAAA |
| 手动 IP / ECH + 手动 IP | 分别关闭、启用 | 用户提供的目标站 IP，仅用于目标域名 |
| 强制 Cloudflare IP / ECH + 强制 Cloudflare IP | 分别关闭、启用 | 设置中指定的 Cloudflare 边缘 IP |

### Cloudflare IP 测试

默认启用 Cloudflare IP 测试，候选地址为 `104.16.0.1` 和 `104.16.0.2`，可在设置中修改或关闭。该策略对目标域名和测试基线均生效，不按域名所属服务商筛选。

测试会直接连接指定 IP，保留原域名作为请求地址、TLS SNI、证书校验名称和 HTTP Host。ECH 测试使用发现的 ECH 配置，但不使用 DoH 返回的目标 IP 或 HTTPS 记录中的 IP 提示。这有助于比较 DNS 返回地址不可用时，指定 IP 能否改善连接。

指定 IP 不一定能为目标域名提供服务，内置地址的可达性也会因网络环境而异。缺少有效 ECH 配置时，ECH 测试会标记为跳过，普通 TLS 测试仍会执行。地址范围可参考 [Cloudflare 官方列表](https://www.cloudflare.com/ips-v4/)。

### 共享 ECH 配置

未发现目标域名的 ECH 配置时，默认尝试使用 `crypto.cloudflare.com` 的配置。此选项为实验功能，可在设置中关闭或更换配置来源。测试仅使用该域名的 ECH 配置，不使用其 IP 地址，并继续校验目标域名的证书；是否适用以实际握手结果为准。

## 如何解读结果

- **ECH 已接受**：由 TLS 握手结果确认，对应 `EchResponse.echAccepted`，不能仅凭 HTTP 状态码判断。
- **请求可用**：收到 HTTP 2xx 或 3xx 响应。测试不跟随重定向，会记录 `Location`，因此结果仅反映指定 URL 的首次响应。
- **TLS 可达但响应异常**：收到 HTTP 4xx 或 5xx 响应，说明已建立连接，但网站返回了错误；这类响应本身不能证明存在网络审查。
- **推荐的连接方式**：仅从本次完整测试中、通过全部重复轮次的组合中选取。测试取消或未完成时不会给出稳定推荐，结果也不代表其他网络或后续时间的表现。

判断结果时应结合测试基线、不同连接方式，以及同一 IP 下普通 TLS 与 ECH 的对比。DNS 地址差异可能来自 CDN 调度，单次超时或地址差异不足以确定故障原因。

每次测试都会按连接方式重新查询 DNS 和 ECH 配置。候选 IP 分别测试，IPv4 与 IPv6 交替选取，便于查看具体地址的连接结果。各类 DNS 查询的错误会保留在测试详情中。

以下差异会影响结果的解读：

- 系统 DNS 使用本机解析结果，而通过域名建立 HTTP CONNECT 隧道时，由代理解析目标域名。即使后续启用 ECH，代理仍会收到 CONNECT 中的域名；指定 IP 时则使用该 IP 建立隧道。
- “普通 TLS + 指定 IP”使用 Dart `RawSecureSocket`，ECH 请求使用 `ech_http`。两者均校验证书，但使用的证书信任库不同，证书或 TLS 错误不能单独作为 ECH 改善连通性的证据。
- 测试仅覆盖 HTTP/1.1 请求，不覆盖 QUIC、HTTP/3、UDP 或系统中其他应用的流量，也不会修改系统 DNS、路由或代理设置。

## 报告与隐私

应用在本机保留最近 20 份测试报告，支持查看历史记录、复制请求详情、在桌面端导出 JSON 文件，以及在移动端分享报告。测试可以随时停止，已完成的结果会保留；从历史记录选择“再次测试”时，会使用该报告中的域名和配置。测试详情默认隐藏基线记录，可按需显示。

报告包含完整测试 URL（包括查询参数）、代理地址、候选 IP、ECH 配置、错误与时间戳，不保存 HTTP 响应正文或 Cookie。

测试会访问配置的 DoH 服务、目标站点和测试基线。DoH 服务会收到查询的域名；应用不会自动上传诊断报告或发送使用统计。

## 从源码运行

需要 Flutter **3.47+**、Dart **3.13+**，以及目标平台的原生构建工具。Windows 版本需在 Windows 上编译，iOS/macOS 需在 macOS 上编译，Linux 需在 Linux 上编译。首次构建会下载并校验 ECH 原生依赖，随后编译本地桥接库，因此需要网络连接和对应的 C/C++ 工具链。

Windows 构建需要 Visual Studio 2026 的“使用 C++ 的桌面开发”工具及 **MSVC 14.51+**。较旧的 MSVC 无法编译 `ech_http` 内嵌的证书包，会报 `C2026` 字符串过长错误。

在项目根目录安装依赖并运行：

```powershell
flutter pub get
flutter run -d windows
```

运行到其他设备时，先通过 `flutter devices` 查看设备列表，再将 `flutter run -d windows` 中的 `windows` 替换为相应设备 ID。

## 命令行诊断

安装项目依赖后，可在项目根目录运行以下命令。请将 `your-domain.example` 替换为需要测试的域名。报告保存为当前目录下的 `artifacts/diagnostic-<id>.json`，终端会显示结果摘要和报告路径。

```powershell
# 使用默认配置测试
dart run tool/diagnose.dart --target your-domain.example

# 只执行一轮测试
dart run tool/diagnose.dart --target your-domain.example --quick

# 关闭 Cloudflare IP 测试
dart run tool/diagnose.dart --target your-domain.example --no-cloudflare

# 同时比较直连与前置代理
dart run tool/diagnose.dart --target your-domain.example --proxy http://127.0.0.1:8080
```

## 开发与构建

运行静态检查和测试：

```powershell
flutter analyze
flutter test
```

构建 Windows 或 Android ARM64 版本：

```powershell
flutter build windows --release
flutter build apk --release --target-platform android-arm64
```

ECH 请求使用 `ech_http`，界面使用 `material_3_expressive` 和 `material_ui`。具体依赖及版本约束见 [pubspec.yaml](pubspec.yaml)。

### CI 与发布

[CI 工作流](.github/workflows/ci.yaml) 在分支推送、Pull Request 或手动触发时运行。[发布工作流](.github/workflows/release.yaml) 复用相同的检查和构建流程。两者使用 Flutter **3.47.5** 及 `pubspec.lock` 中锁定的依赖，先运行 `flutter analyze` 和 `flutter test`，通过后按平台并发构建 release 版本。

| 平台 | Runner | 构建产物 |
| --- | --- | --- |
| Android | `ubuntu-24.04` | ARMv7、ARM64、x86_64 分架构 APK |
| Windows | `windows-2025-vs2026` | x64 完整应用 ZIP，包含 DLL 与资源 |
| Linux | `ubuntu-24.04` | x64 完整应用 tar.gz，保留执行权限 |
| macOS | `macos-15` | `.app` ZIP，保留应用包结构 |
| iOS | `macos-15` | 未签名的设备版 IPA，安装前需自行签名 |

CI 构建产物可从 GitHub Actions 对应的运行记录下载，保留 14 天。推送指向 `main` 分支历史提交的 tag 后，发布工作流会重新检查并构建所有平台；全部成功后创建 GitHub Release，附加安装包、应用压缩包及 `SHA256SUMS.txt` 校验文件。其他分支尚未合入 `main` 的提交不能通过发布检查。

版本号采用 `主版本.次版本.修订版本+构建号`，其中构建号按 `主版本 × 10000 + 次版本 × 100 + 修订版本` 计算，例如 `1.0.0+10000`、`2.3.6+20306`。次版本和修订版本各使用两位数范围（0–99）。

发布前更新 `pubspec.yaml` 中的版本号并合入 `main`；应用内版本取自该文件，Release 名称取自不含构建号的版本 tag。例如：

```sh
git switch main
git pull --ff-only origin main
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0
```

工作流使用 `GITHUB_TOKEN` 发布，仅发布任务拥有仓库内容写入权限。Android 发布包使用固定的发布签名。macOS 未配置 Developer ID 签名及公证，iOS 输出未签名 IPA；用于正式分发前，需要配置相应平台的签名。

### Android 发布签名

Release 构建从仓库的 Actions secrets 加载签名密钥。维护自己的发行版本时，需配置以下四项：

| Secret | 内容 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | JKS 密钥库文件的 Base64 编码 |
| `ANDROID_KEYSTORE_PASSWORD` | 密钥库密码 |
| `ANDROID_KEY_ALIAS` | 签名密钥别名 |
| `ANDROID_KEY_PASSWORD` | 签名密钥密码 |

发布前会使用 `apksigner` 验证每个 APK 的签名，并与 [发布证书 SHA-256 指纹](android/release-certificate.sha256) 比对。缺少签名配置、签名无效或证书不匹配时，工作流会停止发布。普通 CI 和未配置签名的本地构建使用调试签名，无需上述 secrets。

本地使用发布密钥构建时，设置 `ANDROID_KEYSTORE_PATH` 为密钥库的绝对路径，并设置 `ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS` 和 `ANDROID_KEY_PASSWORD`。另设 `ANDROID_REQUIRE_RELEASE_SIGNING=true` 可要求构建必须使用发布签名。

后续版本应保留相同的应用 ID 和签名密钥，并递增 `pubspec.yaml` 版本号中 `+` 后的构建号，才能覆盖升级。此前安装的调试签名版本需要卸载后再安装发布签名版本。请备份密钥库及密码；自行创建发行版本时，也需将证书指纹更新为自己密钥对应的值。

### 目录结构

- `lib/domain/`：测试配置、报告数据模型和结果判定。
- `lib/diagnostics/`：DNS / ECH 配置查询、网络请求及测试调度。
- `lib/data/`：配置和历史报告的本地存储。
- `lib/ui/`：域名测试、结果详情、历史记录和设置界面。
- `tool/diagnose.dart`：命令行诊断入口。
- `test/`：诊断逻辑、结果判定和网络连接测试。
