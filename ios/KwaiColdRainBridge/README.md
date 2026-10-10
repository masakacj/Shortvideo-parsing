# 冷冷雨快手插件接口扩展（独立兼容层）

使用用户提供的 `快手插件冷冷雨_0418.dylib` 作为基础插件，**旧版 KwaiParsePatch 不参与注入**。

## 集成方式
- 冷冷雨原版 dylib 不修改；本目录编译生成 `KwaiInterfaceBridge.dylib`。
- 签名 IPA 时**同时注入**原版和此扩展。不要单独注入本扩展以替代原版。
- 原插件若通过 UIKit `UIAlertControllerStyleActionSheet` 显示包含“下载/保存”的长按菜单，会自动多出“接口下载”。
- 原插件的 `HalfMenuView.configureUI` 设置页会显示“接口设置”按钮。接口地址保存在当前应用 `NSUserDefaults`。
- 接口调用：GET `<设置的 URL>?source=dyyy&url=<分享链接或 photoId>`，已有查询参数会保留。预期响应 `data.video_list` 为数组，条目含 `url`、`level`、`type`；`type=download` 按服务端任务请求处理，其他类型下载媒体保存相册。
- 下载时先从剪贴板填入快手分享链接，允许手动修正。

## 构建
GitHub Actions: `Build Kwai ColdRain Bridge`；无 Theos 依赖，使用 Apple macOS Runner 的 iOS SDK。

## 限制（重要）
- 原版只有二进制，没有源代码；这是双 dylib 兼容扩展，**不是**对原 dylib 的源码级直接修改。
- 无法在没有 iOS 真机和已注入的快手宿主环境下验证冷冷雨插件具体长按菜单行为。
- 若其长按窗口不是系统 `UIAlertController`，新入口不会自动出现在原长按菜单，需要对其实际弹窗类继续适配。
- 不把私有 API 地址、token、Cookie、签名凭据写入仓库。
- 原版设置界面如果晚于扩展加载才注册 Objective-C 类，需要确保原插件先于本扩展加载。
- 设置页覆盖按钮采用浮动控件，避免猜测原版 `menuData` 的不稳定数据结构。

## 回退
只移除 `KwaiInterfaceBridge.dylib` 即可恢复原插件原状；不再注入会闪退的旧插件。
