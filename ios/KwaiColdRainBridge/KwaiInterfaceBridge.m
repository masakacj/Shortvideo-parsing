#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import <string.h>
#import <objc/runtime.h>

static NSString *const KURLKey = @"CJ.KwaiBridge.Endpoint";
static BOOL KInstalled = NO;

static UIViewController *KTop(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) { window = w; break; }
        }
    }
    if (!window) window = UIApplication.sharedApplication.keyWindow;
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:UINavigationController.class]) vc = ((UINavigationController *)vc).visibleViewController;
    return vc;
}
static void KAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = KTop(); if (!vc) return;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    });
}
static NSString *KEndpoint(void) {
    return [[NSUserDefaults standardUserDefaults] stringForKey:KURLKey] ?: @"";
}
static void KConfigure(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = KTop(); if (!vc) return;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"接口设置" message:@"填写完整的 HTTPS 解析接口地址。地址只储存在本机，不上传到 GitHub。" preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
            f.placeholder = @"https://服务器/api/kuaishou/resolve";
            f.keyboardType = UIKeyboardTypeURL;
            f.autocapitalizationType = UITextAutocapitalizationTypeNone;
            f.autocorrectionType = UITextAutocorrectionTypeNo;
            f.text = KEndpoint();
        }];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSString *s = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSURLComponents *u = [NSURLComponents componentsWithString:s];
            if (s.length && (!u.host || ![@[@"https",@"http"] containsObject:u.scheme.lowercaseString])) {
                KAlert(@"地址无效", @"请填写完整 http(s) 接口地址。"); return;
            }
            [[NSUserDefaults standardUserDefaults] setObject:s forKey:KURLKey];
        }]];
        [vc presentViewController:a animated:YES completion:nil];
    });
}
static NSString *KInputFromClipboard(void) {
    NSString *s = UIPasteboard.generalPasteboard.string ?: @"";
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"https?://[^\\s]+" options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (m) return [s substringWithRange:m.range];
    return s.length < 80 ? s : @"";
}
static NSURL *KResolveURL(NSString *endpoint, NSString *input) {
    NSURLComponents *u = [NSURLComponents componentsWithString:endpoint];
    if (!u) return nil;
    NSMutableArray *items = [u.queryItems mutableCopy] ?: [NSMutableArray array];
    BOOL hasInput = NO;
    for (NSURLQueryItem *i in items) if ([@[@"url", @"input", @"photo_id"] containsObject:i.name.lowercaseString]) hasInput = YES;
    if (!hasInput) [items addObject:[NSURLQueryItem queryItemWithName:@"url" value:input]];
    BOOL hasSource = NO;
    for (NSURLQueryItem *i in items) if ([i.name.lowercaseString isEqualToString:@"source"]) hasSource = YES;
    if (!hasSource) [items addObject:[NSURLQueryItem queryItemWithName:@"source" value:@"dyyy"]];
    u.queryItems = items; return u.URL;
}
static void KSaveURL(NSURL *url) {
    if (!url || ![@[@"http", @"https"] containsObject:url.scheme.lowercaseString]) { KAlert(@"无法下载", @"视频链接无效"); return; }
    KAlert(@"下载开始", @"正在下载所选视频，完成后将保存至相册。");
    [[[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *file, NSURLResponse *response, NSError *error) {
        if (error || !file) { KAlert(@"下载失败", error.localizedDescription ?: @"无文件返回"); return; }
        NSString *ext = [url.pathExtension.lowercaseString isEqualToString:@"mov"] ? @"mov" : @"mp4";
        NSURL *tmp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"kwai-%@.%@", NSUUID.UUID.UUIDString, ext]]];
        if (![[NSFileManager defaultManager] copyItemAtURL:file toURL:tmp error:&error]) { KAlert(@"保存失败", error.localizedDescription); return; }
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
            if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) { KAlert(@"需要相册权限", @"请允许插件保存视频。"); return; }
            [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:tmp];
            } completionHandler:^(BOOL success, NSError *saveError) {
                [[NSFileManager defaultManager] removeItemAtURL:tmp error:nil];
                KAlert(success ? @"保存成功" : @"保存失败", success ? @"已保存到相册" : (saveError.localizedDescription ?: @"未知错误"));
            }];
        }];
    }] resume];
}
static void KPresentStreams(id parsed) {
    id data = [parsed isKindOfClass:NSDictionary.class] ? parsed[@"data"] : nil;
    id list = [data isKindOfClass:NSDictionary.class] ? data[@"video_list"] : nil;
    if (![list isKindOfClass:NSArray.class]) list = [parsed isKindOfClass:NSDictionary.class] ? parsed[@"video_list"] : nil;
    if (![list isKindOfClass:NSArray.class] || ![list count]) { KAlert(@"解析完成", @"未找到 video_list，请检查接口返回格式。"); return; }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"接口下载" message:@"选择接口返回的视频画质" preferredStyle:UIAlertControllerStyleActionSheet];
        NSUInteger count = MIN((NSUInteger)20, [list count]);
        for (NSUInteger n = 0; n < count; n++) {
            id entry = list[n]; if (![entry isKindOfClass:NSDictionary.class]) continue;
            NSString *link = [entry[@"url"] isKindOfClass:NSString.class] ? entry[@"url"] : nil;
            NSString *level = [entry[@"level"] description] ?: [entry[@"quality"] description] ?: @"视频";
            NSString *type = [entry[@"type"] description] ?: @"";
            if (!link.length) continue;
            NSString *label = [NSString stringWithFormat:@"%@%@", level, [type isEqualToString:@"download"] ? @"（接口任务）" : @""];
            [a addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                if ([type isEqualToString:@"download"]) {
                    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:link] completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                        KAlert(e ? @"接口任务失败" : @"接口任务已发送", e.localizedDescription ?: @"已请求服务端下载链接，请在服务端查看任务。");
                    }] resume];
                } else KSaveURL([NSURL URLWithString:link]);
            }]];
        }
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *vc = KTop(); a.popoverPresentationController.sourceView = vc.view;
        a.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(vc.view.bounds), CGRectGetMidY(vc.view.bounds), 1, 1);
        [vc presentViewController:a animated:YES completion:nil];
    });
}
static void KResolve(NSString *input) {
    NSString *ep = KEndpoint();
    if (!ep.length) { KAlert(@"尚未设置接口", @"请先到插件设置填写接口地址。"); return; }
    NSURL *url = KResolveURL(ep, input);
    if (!url) { KAlert(@"接口错误", @"无法构造解析请求"); return; }
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (e || !d) { KAlert(@"解析失败", e.localizedDescription ?: @"服务器无响应"); return; }
        NSError *err = nil; id parsed = [NSJSONSerialization JSONObjectWithData:d options:0 error:&err];
        if (err) { KAlert(@"解析失败", @"服务器未返回有效 JSON"); return; }
        KPresentStreams(parsed);
    }] resume];
}
static void KAskLink(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = KTop(); if (!vc) return;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"接口下载" message:@"粘贴视频分享链接或 photoId" preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *f) { f.text = KInputFromClipboard(); f.placeholder = @"分享链接 / photoId"; }];
        [a addAction:[UIAlertAction actionWithTitle:@"接口设置" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *b) { KConfigure(); }]];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"解析" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *b) {
            NSString *v = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (v.length) KResolve(v); else KAlert(@"缺少链接", @"请输入视频分享链接或 photoId");
        }]];
        [vc presentViewController:a animated:YES completion:nil];
    });
}
/* Append to the ORIGINAL plugin's long-press action sheet rather than replacing its actions. */
static void (*KOriginalPresent)(id, SEL, UIViewController *, BOOL, void *);
static void KPresent(id self, SEL cmd, UIViewController *vc, BOOL animated, void *completion) {
    if ([vc isKindOfClass:UIAlertController.class] && ((UIAlertController *)vc).preferredStyle == UIAlertControllerStyleActionSheet) {
        UIAlertController *a = (UIAlertController *)vc;
        BOOL hasDownload = NO, already = NO;
        for (UIAlertAction *action in a.actions) {
            NSString *name = action.title ?: @"";
            if ([name containsString:@"下载"] || [name containsString:@"保存"] || [name.lowercaseString containsString:@"download"]) hasDownload = YES;
            if ([name isEqualToString:@"接口下载"]) already = YES;
        }
        if (hasDownload && !already) [a addAction:[UIAlertAction actionWithTitle:@"接口下载" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act) { KAskLink(); }]];
    }
    KOriginalPresent(self, cmd, vc, animated, completion);
}
/* Add an entry directly to the original HalfMenuView settings panel; no private ivar dependencies. */
static void (*KOriginalConfigure)(id, SEL);
static void KConfigurePanel(id self, SEL cmd) {
    KOriginalConfigure(self, cmd);
    UIView *view = (UIView *)self;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@"接口设置" forState:UIControlStateNormal];
    button.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.88];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.layer.cornerRadius = 8;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button addTarget:NSClassFromString(@"KBridgeAction") action:@selector(openSettings:) forControlEvents:UIControlEventTouchUpInside];
    [view addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-12],
        [button.topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.topAnchor constant:12],
        [button.widthAnchor constraintEqualToConstant:82],
        [button.heightAnchor constraintEqualToConstant:32]
    ]];
}
@interface KBridgeAction : NSObject
+ (void)openSettings:(id)sender;
@end
@implementation KBridgeAction
+ (void)openSettings:(id)sender { KConfigure(); }
@end

/*
 * ColdRain save fallback:
 * NSURLSession's didFinishDownloadingToURL: location is ephemeral.
 * Copy it BEFORE forwarding to the original handler, then use Photos' modern
 * transaction API. This is independent of quality-model and network logic.
 * The original handler remains active for progress/UI compatibility.
 */
static void (*KOriginalColdRainFinished)(id, SEL, NSURLSession *, NSURLSessionDownloadTask *, NSURL *);
/* Diagnose the downloaded bytes, never guess that an arbitrary payload is MP4. */
static NSString *KColdRainMediaType(NSURL *source) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:source.path];
    NSData *head = [handle readDataOfLength:512];
    [handle closeFile];
    const unsigned char *b = head.bytes;
    NSUInteger n = head.length;
    if (n < 12) return @"invalid";
    if (memcmp(b + 4, "ftyp", 4) == 0) {
        if (n >= 12 && memcmp(b + 8, "qt  ", 4) == 0) return @"mov";
        return @"mp4";
    }
    if (memcmp(b + 4, "moov", 4) == 0 || memcmp(b + 4, "mdat", 4) == 0 ||
        memcmp(b + 4, "wide", 4) == 0) return @"mov";
    if (memcmp(b, "FLV", 3) == 0) return @"flv";
    if (b[0] == 0x1a && b[1] == 0x45 && b[2] == 0xdf && b[3] == 0xa3) return @"webm";
    if (n > 190 && b[0] == 0x47 && b[188] == 0x47) return @"ts";
    if (memcmp(b, "#EXTM3U", 7) == 0) return @"m3u8";
    if (b[0] == '{' || b[0] == '[' || b[0] == '<') return @"text";
    if (memcmp(b, "ID3", 3) == 0) return @"audio";
    return @"unknown";
}
static NSError *KColdRainError(NSString *reason) {
    return [NSError errorWithDomain:@"KwaiColdRainBridge" code:1
                           userInfo:@{NSLocalizedDescriptionKey:reason ?: @"未知文件错误"}];
}
static void KColdRainCleanup(NSURL *file) {
    if (file) [[NSFileManager defaultManager] removeItemAtURL:file error:nil];
}
/* Keep an inaccessible/unrecognized file available for export through the share sheet. */
static void KColdRainFailure(NSURL *source, NSString *info, NSString *problem) {
    NSLog(@"[KwaiBridge] Photos save failed: %@, %@", info, problem);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = KTop();
        if (!vc) { KColdRainCleanup(source); return; }
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"冷冷雨视频保存失败"
           message:[NSString stringWithFormat:@"%@\n%@\n可以尝试导出原文件。", info, problem ?: @"未知错误"]
           preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"分享原文件" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            UIViewController *presenter = KTop();
            if (!presenter) { KColdRainCleanup(source); return; }
            UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[source] applicationActivities:nil];
            share.popoverPresentationController.sourceView = presenter.view;
            share.popoverPresentationController.sourceRect =
                CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1, 1);
            share.completionWithItemsHandler = ^(__unused UIActivityType activity,
                                                  __unused BOOL completed,
                                                  __unused NSArray *returnedItems,
                                                  __unused NSError *error) {
                KColdRainCleanup(source);
            };
            [presenter presentViewController:share animated:YES completion:nil];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *a) {
            KColdRainCleanup(source);
        }]];
        [vc presentViewController:alert animated:YES completion:nil];
    });
}
static void KColdRainImport(NSURL *file, void (^done)(BOOL, NSError *)) {
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:file];
    } completionHandler:^(BOOL success, NSError *error) {
        done(success, error);
    }];
}
/* Apple may support container remux (passthrough) with zero video-quality loss.
   Only if Photos also rejects the remux do we try HighestQuality re-encoding. */
static void KColdRainExport(NSURL *source, NSString *preset,
                            void (^done)(NSURL *, NSError *)) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:source options:nil];
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
        NSError *error = nil;
        if ([asset statusOfValueForKey:@"tracks" error:&error] != AVKeyValueStatusLoaded) {
            done(nil, error ?: KColdRainError(@"AVFoundation 无法识别视频文件"));
            return;
        }
        if ([asset tracksWithMediaType:AVMediaTypeVideo].count == 0) {
            done(nil, KColdRainError(@"文件中没有可读取的视频轨道"));
            return;
        }
        AVAssetExportSession *session = [[AVAssetExportSession alloc] initWithAsset:asset presetName:preset];
        if (!session) {
            done(nil, KColdRainError(@"系统不支持此视频的导出格式"));
            return;
        }
        AVFileType outputType = nil;
        NSString *extension = nil;
        if ([session.supportedFileTypes containsObject:AVFileTypeMPEG4]) {
            outputType = AVFileTypeMPEG4;
            extension = @"mp4";
        } else if ([session.supportedFileTypes containsObject:AVFileTypeQuickTimeMovie]) {
            outputType = AVFileTypeQuickTimeMovie;
            extension = @"mov";
        } else {
            done(nil, KColdRainError(@"系统无法将这个视频封装为 MP4 或 MOV"));
            return;
        }
        NSURL *output = [NSURL fileURLWithPath:
             [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"kwai-repacked-%@.%@", NSUUID.UUID.UUIDString, extension]]];
        session.outputURL = output;
        session.outputFileType = outputType;
        session.shouldOptimizeForNetworkUse = YES;
        [session exportAsynchronouslyWithCompletionHandler:^{
            if (session.status == AVAssetExportSessionStatusCompleted) {
                done(output, nil);
            } else {
                KColdRainCleanup(output);
                done(nil, session.error ?: KColdRainError(@"视频导出失败"));
            }
        }];
    }];
}
static void KColdRainReencode(NSURL *original, NSString *info, NSError *priorError) {
    KColdRainExport(original, AVAssetExportPresetHighestQuality, ^(NSURL *converted, NSError *exportError) {
        if (!converted) {
            KColdRainFailure(original, info, [NSString stringWithFormat:@"保存失败：%@；转换失败：%@",
                priorError.localizedDescription ?: @"3302",
                exportError.localizedDescription ?: @"未知原因"]);
            return;
        }
        KColdRainImport(converted, ^(BOOL saved, NSError *saveError) {
            KColdRainCleanup(converted);
            if (saved) {
                KColdRainCleanup(original);
                KAlert(@"相册保存成功", @"视频已通过兼容转换写入相册；这一备用方式可能重新编码。");
            } else {
                KColdRainFailure(original, info, [NSString stringWithFormat:@"兼容转换后仍无法保存：%@",
                    saveError.localizedDescription ?: @"未知原因"]);
            }
        });
    });
}
static void KColdRainRemux(NSURL *original, NSString *info, NSError *priorError) {
    KColdRainExport(original, AVAssetExportPresetPassthrough, ^(NSURL *repacked, NSError *exportError) {
        if (!repacked) {
            KColdRainReencode(original, info, exportError ?: priorError);
            return;
        }
        KColdRainImport(repacked, ^(BOOL saved, NSError *saveError) {
            KColdRainCleanup(repacked);
            if (saved) {
                KColdRainCleanup(original);
                KAlert(@"相册保存成功", @"视频已无损重新封装并写入相册（未重新编码）。");
            } else {
                KColdRainReencode(original, info, saveError ?: priorError);
            }
        });
    });
}
static void KColdRainSaveToPhotos(NSURL *original, NSString *info) {
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
        if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
            KColdRainFailure(original, info, @"没有相册写入权限，请在系统设置允许快手添加照片。");
            return;
        }
        KColdRainImport(original, ^(BOOL saved, NSError *error) {
            if (saved) {
                KColdRainCleanup(original);
                KAlert(@"相册保存成功", @"已确认 PhotoKit 写入成功。");
                return;
            }
            NSLog(@"[KwaiBridge] direct Photos import failed: %@", error);
            if ([error.domain isEqualToString:PHPhotosErrorDomain] && error.code == 3302) {
                KColdRainRemux(original, info, error);
            } else {
                KColdRainFailure(original, info, error.localizedDescription ?: @"PhotoKit 未能写入相册");
            }
        });
    }];
}
static void KColdRainFinished(id self, SEL cmd, NSURLSession *session, NSURLSessionDownloadTask *task, NSURL *location) {
    NSURL *backup = nil;
    NSError *copyError = nil;
    NSHTTPURLResponse *response = [task.response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)task.response : nil;
    NSString *kind = location.isFileURL ? KColdRainMediaType(location) : @"missing";
    unsigned long long bytes = [[[NSFileManager defaultManager] attributesOfItemAtPath:location.path error:nil] fileSize];
    NSInteger code = response ? response.statusCode : 0;
    NSString *mime = task.response.MIMEType ?: @"unknown";
    NSString *info = [NSString stringWithFormat:@"格式 %@ · %.2f MB · HTTP %ld · %@",
                      kind, bytes / 1048576.0, (long)code, mime];
    BOOL validBody = bytes > 1024 && (code == 0 || (code >= 200 && code < 300))
                     && ![@[@"invalid", @"text", @"audio", @"m3u8", @"missing"] containsObject:kind];
    if (validBody) {
        backup = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
             [NSString stringWithFormat:@"kwai-coldrain-%@.%@",
                NSUUID.UUID.UUIDString, [kind isEqualToString:@"unknown"] ? @"bin" : kind]]];
        if (![[NSFileManager defaultManager] copyItemAtURL:location toURL:backup error:&copyError]) backup = nil;
    }
    /* Always preserve the original plugin's own download behavior. */
    if (KOriginalColdRainFinished) KOriginalColdRainFinished(self, cmd, session, task, location);
    NSLog(@"[KwaiBridge] ColdRain download finished: %@, copied=%d", info, backup != nil);
    if (backup) KColdRainSaveToPhotos(backup, info);
    else if (copyError) KAlert(@"冷冷雨相册修复失败", copyError.localizedDescription);
    else KAlert(@"下载文件不是有效视频", [info stringByAppendingString:@"\n可能是接口返回的错误页面或播放清单，已跳过相册导入。"]);
}

static void KSwizzle(Class cls, SEL sel, IMP replacement, IMP *old) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel); if (!m) return;
    *old = method_getImplementation(m); method_setImplementation(m, replacement);
}
__attribute__((constructor)) static void KStart(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (KInstalled) return; KInstalled = YES;
        KSwizzle(UIViewController.class, @selector(presentViewController:animated:completion:), (IMP)KPresent, (IMP *)&KOriginalPresent);
        Class menu = NSClassFromString(@"HalfMenuView");
        if (menu) KSwizzle(menu, @selector(configureUI), (IMP)KConfigurePanel, (IMP *)&KOriginalConfigure);
        KSwizzle(NSClassFromString(@"DownloaderManager"), @selector(URLSession:downloadTask:didFinishDownloadingToURL:), (IMP)KColdRainFinished, (IMP *)&KOriginalColdRainFinished);
    });
}
