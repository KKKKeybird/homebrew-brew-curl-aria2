# brew-curl-aria2

让 Homebrew 用 **aria2c 多线程（分段）下载**代替单连接的 curl。

Homebrew 的下载策略写死走 `Utils::Curl`：单个文件永远是**一条连接**。官方唯一的并行是
`HOMEBREW_DOWNLOAD_CONCURRENCY`（`DownloadQueue`，2024 年加入），它只在**不同包之间**并行，
对一个 595MB 的 cask 安装包没有任何帮助。上游也明确拒绝过引入其他下载器
（[Homebrew/brew#14144](https://github.com/Homebrew/brew/issues/14144)，2022 年提出，次日关闭，
维护者回复 "Sorry, not interested in supporting other downloaders or supporting multi-connection downloads."）。

这个工具不 patch Homebrew，只用官方代码里已有的钩子：`HOMEBREW_CURL_PATH`。

## 安装

```sh
brew tap kkkkeybird/brew-curl-aria2
brew install brew-curl-aria2        # 自动依赖 aria2

brew-curl-aria2 enable              # 显式开启（默认不改你的配置）
brew-curl-aria2 test                # 端到端自检
brew-curl-aria2 status              # 查看状态与告警
```

之后正常 `brew upgrade --cask <名字>` 即可。

## 实测效果（2026-09，macOS 27 / 路由器 OpenClash 出口）

| 对象 | curl 单连接 | aria2c -x8 | 提升 |
|---|---|---|---|
| ChatGPT 595MB cask | 44.2s (13.5 MB/s) | **28.1s (21 MB/s)** | 1.6x |
| Codex 123MB cask | ~19s | ~15s | ~1.3x |

收益取决于瓶颈：**每连接被限速时收益最大**（实测过 6x 的场景），链路总带宽已到顶时收益接近 0。

## 它到底改了什么

只有一行，写进 Homebrew 的用户级环境文件（`$XDG_CONFIG_HOME/homebrew/brew.env`，
否则 `~/.homebrew/brew.env`）：

```sh
HOMEBREW_CURL_PATH=/opt/homebrew/opt/brew-curl-aria2/libexec/curl-aria2
```

对应 Homebrew 官方代码：

- `Library/Homebrew/utils/curl.sh`：`HOMEBREW_CURL_PATH` → `HOMEBREW_CURL`
- `Library/Homebrew/shims/shared/curl`：执行 `${HOMEBREW_CURL}`
- macOS 上 `check-curl-version()` 直接返回，不校验版本

`brew-curl-aria2 disable` 删掉这一行即完全恢复。

## 为什么不做成 Homebrew 本体里的模块

- 上游没有第三方下载后端机制，且**明确拒绝**支持其他下载器（#14144）；
- `$(brew --prefix)/Library/Homebrew` 是 git 仓库，`brew update` 会覆盖你塞进去的东西；
- 所以正规做法就是 tap + formula + 官方 `HOMEBREW_CURL_PATH` 钩子。

## 调参

Homebrew **只把 `HOMEBREW_*` 变量传给下载子进程**，所以要用带前缀的写法（可写进 `~/.homebrew/brew.env`）：

```sh
HOMEBREW_BREW_CURL_ARIA2_CONNECTIONS=16   # 每服务器连接数（默认 8）
HOMEBREW_BREW_CURL_ARIA2_SPLITS=16        # 分段数（默认等于连接数）
HOMEBREW_BREW_CURL_ARIA2_CHUNK=4M         # 分段大小（默认 1M）
HOMEBREW_BREW_CURL_ARIA2_DEBUG=1          # 决策日志打到 stderr
HOMEBREW_BREW_CURL_ARIA2_LOG=/tmp/aria2.log  # 决策日志写文件（排障用）
HOMEBREW_BREW_CURL_ARIA2_PROGRESS=1       # 打开 aria2c 进度读数
```

直接手动调用 shim 时，短名 `BREW_CURL_ARIA2_*` 也可用。

## 安全设计

1. **不认识就交回 curl**：只有「带 `--output` 的普通 http(s) 下载」才走 aria2c；
   `--head`、`--dump-header`、`--write-out`、`--request`、POST/analytics、`-V` 全部原样透传。
2. **aria2c 非 0 退出或产物为空 → 用原始参数重跑 curl**，错误语义与官方一致（实测触发过：
   aria2c 因 c-ares DNS 解析失败退出 19，curl 立即接管完成下载）。
3. **只写一行配置**，`disable` / `brew uninstall` 即可完全恢复。

## 已知差异与注意

- aria2c 用 HTTP/1.1（curl 可能 HTTP/2），对镜像站与厂商 CDN 无实质影响。
- 已默认 `--async-dns=false`：使用系统解析器，避免透明代理/split-DNS 环境下 c-ares 解析失败。
- aria2c 失败会留下 `<文件>.aria2` 控制文件用于续传，`brew cleanup` 不清理它，属正常。
- 依赖服务器支持 Range 请求；不支持时 aria2c 失败并回退 curl。
- Homebrew 会捕获下载输出，因此进度条通常不可见（用 `HOMEBREW_BREW_CURL_ARIA2_PROGRESS=1` 试）。

## 卸载

```sh
brew-curl-aria2 disable
brew uninstall brew-curl-aria2
brew untap kkkkeybird/brew-curl-aria2
```

## License

MIT
