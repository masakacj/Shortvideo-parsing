# 冷冷雨 dylib 的 GitHub Releases 直链发布

## 当前流程

1. `feature/kwai-coldrain-api-bridge` 分支的 GitHub Actions 使用 macOS/iOS SDK 编译 `KwaiInterfaceBridge.dylib`。
2. Actions 使用仓库的 `GITHUB_TOKEN` 创建公开 GitHub Release，tag 形如 `kwai-coldrain-run-<GitHub run id>`，实际 Release asset 名为 `KwaiColdRain-InterfaceBridge-v2.dylib`。
3. Actions 调用 `POST https://ipa.78175132.xyz/api/v1/dylibs/link`，只提交 `name`、`tag`、`sha256` 以及 GitHub run 的身份信息。
4. 下载中心通过 GitHub Actions 的运行凭据及 GitHub Releases API 核实来源、提交 SHA、资源名称与 SHA-256 后，仅把链接元数据记入 `/var/lib/ipa-signer/config/dylib-links.json`。
5. `https://ipa.78175132.xyz/dylib` 直接显示 GitHub 下载链接（无需经过签名服务器转发文件）。

此流程**不会把 dylib 字节文件上传到下载中心**。旧 `/dylibs/<filename>` 下载功能仍保留，已上传的历史版本也不会被删除。

## 发布位置

- GitHub Actions: `.github/workflows/kwai-coldrain.yml`
- 公网下载页：`https://ipa.78175132.xyz/dylib`
- Release tag：`kwai-coldrain-run-<run_id>`
- GitHub 直链：`https://github.com/masakacj/Shortvideo-parsing/releases/download/<tag>/KwaiColdRain-InterfaceBridge-v2.dylib`

## 校验规则

- 仅允许 `masakacj/Shortvideo-parsing` 指定分支和 `kwai-coldrain.yml` 工作流调用链接同步接口。
- GitHub Release 必须在对应提交 SHA 上创建，文件名必须符合 dylib 白名单，GitHub API 必须查得到已上传的真实 asset。
- 校验 Release asset 的 GitHub SHA-256 digest 与本次编译得到的 SHA-256。
- 网页只允许展示 GitHub Releases 白名单路径下的链接。
- 不在仓库或 workflow 中放入服务器管理员 Token、IPA 签名证书或其他私密凭证。
- `GITHUB_TOKEN` 仅用于当前 Actions 运行；存储中心使用已验证的 GitHub 运行身份。

## 注意

这是下载/发布管线的改变，**不代表冷冷雨在真机上已经解决相册写入错误 3302**。补丁与原插件同时加载的兼容性仍需真机验证。
