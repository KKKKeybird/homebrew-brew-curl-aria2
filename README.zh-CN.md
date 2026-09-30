# brew-curl-aria2

[English](README.md) · 简体中文

`brew-curl-aria2` 是一个第三方 Homebrew tap。它把符合条件的文件下载交给 aria2c，在服务器支持 Range 请求时，对单个文件使用多个 HTTP 连接。其他 curl 请求仍由 curl 处理。

项目不修改 Homebrew 源码，也不运行 aria2 后台服务。它通过 `HOMEBREW_CURL_PATH` 指定兼容 curl 的包装脚本。当前 Homebrew 的 macOS 实现会读取该变量，但[官方环境变量文档](https://docs.brew.sh/Manpage#environment)仅将其列为 Linux 用途，因此不能保证未来版本继续兼容。

## 安装

```sh
brew tap kkkkeybird/brew-curl-aria2
brew install brew-curl-aria2
brew-curl-aria2 enable
brew-curl-aria2 test
brew-curl-aria2 status
```

Formula 会自动安装 aria2 依赖。单独安装不会改变 Homebrew 的下载行为；`enable` 会把包装脚本路径写入 Homebrew 用户环境文件。设置了 `XDG_CONFIG_HOME` 时，文件位于 `$XDG_CONFIG_HOME/homebrew/brew.env`，否则位于 `~/.homebrew/brew.env`。

此后照常运行 `brew upgrade --cask <名称>` 等命令。已缓存的文件不会重新下载。

## 请求处理

带有可转换 curl 参数的 HTTP(S) 文件下载和续传会优先使用 aria2c。默认使用 8 个连接和 8 个分段。获取响应头、查询版本、提交请求体、未指定续传时覆盖已有文件，以及使用语义不同的 curl 参数时，原命令会交给 curl。显式代理或 Cookie、协议及 IP 地址族限制、指定数字偏移的续传请求都属于后一类。Homebrew 的自动续传参数 `--continue-at -` 会交给 aria2c。

aria2c 在独立的 `<输出路径>.aria2-work` 目录中下载，完成后才把文件交给 Homebrew。它可以续传 curl 的连续部分文件，也可以恢复自己的分段进度。aria2c 失败时，脚本会用原始参数运行 curl，保留原来的连续部分文件。如果两者都失败，aria2 的分段进度会保留到下次尝试；下载成功后会清理。服务器拒绝 Range 请求时，会先让 aria2c 用单连接重新下载，失败后才回退 curl。旧版 `.aria2` 分段文件只会交给 aria2c 续传，不会交给 curl。Homebrew 对 formula 和 cask 下载文件的校验仍然生效。

如果服务器对单连接限速，多连接可能提升速度；链路已满载时可能没有收益。部分服务器不支持 Range 请求。aria2c 使用 HTTP/1.1，而 curl 可能协商 HTTP/2 或 HTTP/3。

## 配置

以下变量可写入 Homebrew 用户环境文件：

```sh
HOMEBREW_BREW_CURL_ARIA2_CONNECTIONS=8
HOMEBREW_BREW_CURL_ARIA2_SPLITS=8
HOMEBREW_BREW_CURL_ARIA2_CHUNK=1M
```

排障时可设 `HOMEBREW_BREW_CURL_ARIA2_DEBUG=1`，把分流决策写入 stderr；或设置 `HOMEBREW_BREW_CURL_ARIA2_LOG=/path/to/log`，追加到日志文件。`HOMEBREW_BREW_CURL_ARIA2_PROGRESS=1` 会启用 aria2c 进度输出，但 Homebrew 可能捕获该输出。直接调用包装脚本时，也接受不带 `HOMEBREW_` 前缀的变量名。

如果已有其他 `HOMEBREW_CURL_PATH`，`enable` 不会覆盖；`disable` 只删除本项目写入的值。如果设置了 `HOMEBREW_FORCE_BREWED_CURL`，Homebrew 会优先使用 brewed curl。

## 验证与开发

```sh
brew-curl-aria2 status
brew-curl-aria2 test
bash test/shim.bash
python3 test/resume.py
```

自检命令会下载小文件，并检查 aria2c 分流与 curl 透传。仓库测试使用模拟可执行文件，在 macOS 和 Linux CI 中运行。

## 发布

维护者可在 GitHub Actions 中运行 **Release** 工作流，输入新的 `主版本.次版本.修订号`。流程会运行测试、生成可复现的源码包、更新命令版本和 Formula 的下载地址及 SHA-256、创建 tag，并发布 GitHub Release。普通 `main` 分支提交不会自动发版。

## 卸载

```sh
brew-curl-aria2 disable
brew uninstall brew-curl-aria2
brew untap kkkkeybird/brew-curl-aria2
```

卸载前先执行 `disable`，避免 `HOMEBREW_CURL_PATH` 指向已删除的文件。

## 许可证

MIT。本项目与 Homebrew、aria2 官方无关联。
