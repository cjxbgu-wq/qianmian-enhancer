// ===============================================================
// VCamExtraKeys v4 (LV-1) — 功能键挂载模块 (vcam 核心/补丁/增强 零改动)
// ===============================================================
// v4 要点 (按用户反馈迭代):
//   A) 视频旋转: 照抄 "UI源码界面虚浮窗功能 无汉字图标\Tweak.xm" 参考算法
//      (101 键 → 0/90/180/270 循环; CGAffineTransform 旋转 → 自适应裁满),
//      挂到部署管线真实入口 LocalVideoPlayer updateCurrentBuffer:
//      (mediaserverd 侧, 原实现零改动, 仅入队前替换旋转后帧)。
//      旋转状态键独立为 videoRotationLV (单所有者), 并迁移清零旧 videoRotation,
//      杜绝与增强模块 processFrame 双重旋转。
//   B) UI: 方案J 面板 + 底部 3 键条: 视频旋转(实时角度) / 增强面板 / 错误日志。
//   C) 错误日志: /tmp/qianmian_error.log 只记 [ERR]/[WARN] 与注入诊断,
//      弹窗展示"哪里报错" + 各进程注入状态, 可清空。
//   D) 输出包命名 LV-1.deb (递增 LV-2 ...)。
// ===============================================================

#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>

static NSString *const QMKSharedSettingsPath = @"/tmp/qianmian_enhancer_settings.plist";
static NSString *const QMKErrorLogPath       = @"/tmp/qianmian_error.log";
static NSString *const QMKRotationKey        = @"videoRotationLV"; // 单所有者键
static NSString *const QMKLegacyRotationKey  = @"videoRotation";   // 旧键(迁移后清零)
static const NSInteger QMK_BAR_TAG    = 0x6E20;
static const NSInteger QMK_ROTBTN_TAG = 0x6E21;

// ---------------------------------------------------------------
// 进程识别 (UI 层仅 SpringBoard; 帧层仅 mediaserverd/lskdd)
// ---------------------------------------------------------------
typedef NS_ENUM(NSInteger, QMKProcess) {
    QMKProcessOther = 0,
    QMKProcessSpringBoard,
    QMKProcessMediaserverd,
    QMKProcessLskdd,
};

static QMKProcess QMKProc(void) {
    @try {
        NSString *pn = [[NSProcessInfo processInfo] processName];
        if ([pn isEqualToString:@"SpringBoard"]) return QMKProcessSpringBoard;
        if ([pn isEqualToString:@"mediaserverd"]) return QMKProcessMediaserverd;
        if ([pn isEqualToString:@"lskdd"]) return QMKProcessLskdd;
    } @catch (NSException *e) {}
    return QMKProcessOther;
}

static NSString *QMKProcName(QMKProcess p) {
    switch (p) {
        case QMKProcessSpringBoard:  return @"SpringBoard";
        case QMKProcessMediaserverd: return @"mediaserverd";
        case QMKProcessLskdd:        return @"lskdd";
        default:                     return @"other";
    }
}

// 每进程注入标记 (错误日志诊断用): /tmp/qm_extrakeys_sb.txt 等
static void QMKMarkInjected(QMKProcess p) {
    @try {
        NSString *path = [NSString stringWithFormat:@"/tmp/qm_extrakeys_%@.txt",
                          [QMKProcName(p) lowercaseString]];
        [@"ok" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) {}
}

static BOOL QMKMarkExists(NSString *name) {
    @try {
        return [[NSFileManager defaultManager] fileExistsAtPath:
                [NSString stringWithFormat:@"/tmp/qm_%@.txt", name]];
    } @catch (NSException *e) {}
    return NO;
}

// ---------------------------------------------------------------
// 错误/诊断日志 (用户要求: 记录"哪里报错", 非行为流水)
//   [INFO] 正常状态  /  [WARN] 可恢复异常  /  [ERR] 报错点 (含异常名+原因+位置)
// ---------------------------------------------------------------
static void QMKLogLine(NSString *level, NSString *tag, NSString *detail) {
    @try {
        NSString *ts = [NSDateFormatter localizedStringFromDate:[NSDate date]
                        dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle];
        NSString *line = [NSString stringWithFormat:@"%@ [%@] [%@] %@\n", ts, level,
                          tag ?: QMKProcName(QMKProc()), detail ?: @""];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:QMKErrorLogPath]) {
            [fm createFileAtPath:QMKErrorLogPath contents:nil attributes:nil];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:QMKErrorLogPath];
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) {}
}

static void QMKInfo(NSString *msg) { QMKLogLine(@"INFO", nil, msg); }
static void QMKWarn(NSString *msg) { QMKLogLine(@"WARN", nil, msg); }
static void QMKErr(NSString *tag, NSException *e) {
    QMKLogLine(@"ERR", tag, [NSString stringWithFormat:@"%@: %@", e.name, e.reason]);
}

// ---------------------------------------------------------------
// 共享设置 (读/合并写 — 与增强模块 saveCurrentSettings 同策略)
// ---------------------------------------------------------------
static NSDictionary *QMKReadSettings(void) {
    @try {
        NSDictionary *s = [NSDictionary dictionaryWithContentsOfFile:QMKSharedSettingsPath];
        return s ?: @{};
    } @catch (NSException *e) {}
    return @{};
}

static void QMKWriteSettings(NSDictionary *settings) {
    @try {
        [settings writeToFile:QMKSharedSettingsPath atomically:YES];
    } @catch (NSException *e) {}
}

static NSInteger QMKReadRotation(void) {
    NSInteger r = [[QMKReadSettings() objectForKey:QMKRotationKey] integerValue];
    return (r == 90 || r == 180 || r == 270) ? r : 0; // 值域钳制 (脏数据归零)
}

// 旋转循环 0→90→180→270→0; 单所有者写 videoRotationLV, 兼容旧键迁移清零
static NSInteger QMKCycleRotation(void) {
    NSMutableDictionary *s = [NSMutableDictionary dictionaryWithDictionary:QMKReadSettings()];
    NSInteger next = (QMKReadRotation() + 90) % 360;
    [s setObject:@(next) forKey:QMKRotationKey];
    [s setObject:@(0) forKey:QMKLegacyRotationKey]; // 防增强模块双重旋转
    QMKWriteSettings(s);
    QMKInfo([NSString stringWithFormat:@"视频旋转: -> %ld°", (long)next]);
    return next;
}

// 旧键一次性迁移: v3 写入的 videoRotation → videoRotationLV, 旧键清零
static void QMKMigrateLegacyRotation(void) {
    @try {
        NSDictionary *s = QMKReadSettings();
        NSInteger legacy = [[s objectForKey:QMKLegacyRotationKey] integerValue];
        NSInteger cur = [[s objectForKey:QMKRotationKey] integerValue];
        if (legacy != 0 && cur == 0) {
            NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:s];
            [m setObject:@((legacy == 90 || legacy == 180 || legacy == 270) ? legacy : 0)
                  forKey:QMKRotationKey];
            [m setObject:@(0) forKey:QMKLegacyRotationKey];
            QMKWriteSettings(m);
            QMKInfo(@"旧旋转键已迁移至 videoRotationLV");
        }
    } @catch (NSException *e) {}
}

// ---------------------------------------------------------------
// 转发辅助 (无 ARC 警告 performSelector)
// ---------------------------------------------------------------
static id QMKSafeCall(id target, SEL sel, id arg) {
    if (!target || !sel || ![target respondsToSelector:sel]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return arg ? [target performSelector:sel withObject:arg] : [target performSelector:sel];
#pragma clang diagnostic pop
}

// ===============================================================
// 帧层 (mediaserverd / lskdd): 视频旋转 照抄参考算法并映射到部署管线
//   参考: UI源码界面虚浮窗功能/Tweak.xm vcam_applyVideoTransforms + vcam_aspectFill
//   顺序: 旋转变换 → 自适应裁满(MAX 比缩放居中裁剪) → 渲染回 w×h 新缓冲
//   原实现 updateCurrentBuffer: 仅 retain 存储 — 零改动, 入队前替换旋转帧
// ===============================================================
static CIContext *QMKCI(void) {
    static CIContext *ctx = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ctx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    });
    return ctx;
}

// 旋转 + 自适应裁满, 渲染到新建 BGRA 缓冲 (每次新建: 无缓冲复用竞态;
// 原实现 retain 存储, 我们 orig 后释放自身引用即安全)
static CVPixelBufferRef QMKApplyRotation(CVPixelBufferRef src, NSInteger rot) {
    if (!src || rot == 0) return NULL;
    @try {
        CIImage *img = [CIImage imageWithCVImageBuffer:src];
        size_t w = CVPixelBufferGetWidth(src);
        size_t h = CVPixelBufferGetHeight(src);
        if (w == 0 || h == 0) return NULL;
        CVPixelBufferRef dst = NULL;
        CVPixelBufferCreate(kCFAllocatorDefault, (size_t)w, (size_t)h,
                            kCVPixelFormatType_32BGRA, NULL, &dst);
        if (!dst) { QMKErr(@"rotation-alloc", nil); return NULL; }
        if (rot == 90)  img = [img imageByApplyingTransform:CGAffineTransformMake(0, 1, -1, 0, h, 0)];
        if (rot == 180) img = [img imageByApplyingTransform:CGAffineTransformMake(-1, 0, 0, -1, w, h)];
        if (rot == 270) img = [img imageByApplyingTransform:CGAffineTransformMake(0, -1, 1, 0, 0, w)];
        CGRect ext = img.extent;
        if (ext.size.width < 1 || ext.size.height < 1) { CVPixelBufferRelease(dst); return NULL; }
        CGFloat sx = (CGFloat)w / ext.size.width;
        CGFloat sy = (CGFloat)h / ext.size.height;
        CGFloat scale = MAX(sx, sy);
        img = [img imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        CGRect se = img.extent;
        img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(
                   (w - se.size.width) / 2.0, (h - se.size.height) / 2.0)];
        img = [img imageByCroppingToRect:CGRectMake(0, 0, (CGFloat)w, (CGFloat)h)];
        [QMKCI() render:img toCVPixelBuffer:dst];
        return dst;
    } @catch (NSException *e) {
        QMKErr(@"rotation-apply", e);
        return NULL;
    }
}

// 帧钩子: 读旋转值(0.5s 节流缓存), 非零则替换为旋转帧再走原实现
static void (*origUpdateCurrentBuffer)(id, SEL, CVBufferRef) = NULL;
static void QMKUpdateCurrentBufferHook(id self, SEL _cmd, CVBufferRef buffer) {
    @try {
        static NSInteger cachedRot = -1;
        static double lastRead = 0;
        double now = [NSDate timeIntervalSinceReferenceDate];
        if (cachedRot < 0 || (now - lastRead) > 0.5) {
            cachedRot = QMKReadRotation();
            lastRead = now;
        }
        if (cachedRot != 0 && buffer) {
            CVPixelBufferRef rotated = QMKApplyRotation(buffer, cachedRot);
            if (rotated) {
                if (origUpdateCurrentBuffer) origUpdateCurrentBuffer(self, _cmd, rotated);
                CVPixelBufferRelease(rotated); // 原实现已 retain, 释放我们这份
                return;
            }
            QMKWarn(@"旋转应用失败, 回退原始帧");
        }
        if (origUpdateCurrentBuffer) origUpdateCurrentBuffer(self, _cmd, buffer);
    } @catch (NSException *e) {
        QMKErr(@"frame-hook", e);
        if (origUpdateCurrentBuffer) origUpdateCurrentBuffer(self, _cmd, buffer);
    }
}

static BOOL QMKFrameInstalled = NO;
static void QMKInstallFrameHook(void) {
    if (QMKFrameInstalled) return;
    @try {
        Class lvp = NSClassFromString(@"LocalVideoPlayer");
        if (!lvp) return; // 类未加载, 由重试调度补装
        Method m = class_getInstanceMethod(lvp, @selector(updateCurrentBuffer:));
        if (!m) return;
        IMP orig = method_getImplementation(m);
        if (orig == (IMP)QMKUpdateCurrentBufferHook) { QMKFrameInstalled = YES; return; }
        origUpdateCurrentBuffer = (void (*)(id, SEL, CVBufferRef))orig;
        method_setImplementation(m, (IMP)QMKUpdateCurrentBufferHook);
        QMKFrameInstalled = YES;
        QMKInfo([NSString stringWithFormat:@"帧钩子已安装 (%@)", QMKProcName(QMKProc())]);
    } @catch (NSException *e) {
        QMKErr(@"frame-install", e);
    }
}

// ===============================================================
// UI 层 (SpringBoard): 3 键条 + 诊断弹窗 + 悬浮钮抑制
// ===============================================================
@interface QMKExtraController : NSObject
@property (nonatomic, weak) UIViewController *panelVC;
@property (nonatomic, strong) UIButton *rotBtn;
- (void)rotateTapped;
- (void)enhancerPanelTapped;
- (void)logTapped;
@end

@implementation QMKExtraController

- (void)rotateTapped {
    @try {
        NSInteger next = QMKCycleRotation();
        if (self.rotBtn) {
            [self.rotBtn setTitle:[NSString stringWithFormat:@"旋转 %ld°", (long)next]
                         forState:UIControlStateNormal];
        }
    } @catch (NSException *e) { QMKErr(@"rotate-key", e); }
}

- (void)enhancerPanelTapped {
    @try {
        Class enh = NSClassFromString(@"QMEnhancerView");
        if (!enh) { QMKWarn(@"增强面板: 增强模块未加载"); return; }
        id inst = QMKSafeCall(enh, @selector(sharedInstance), nil);
        if (inst && [inst respondsToSelector:@selector(togglePanel)]) {
            QMKSafeCall(inst, @selector(togglePanel), nil);
            QMKInfo(@"增强面板: 展开/收起已切换");
        } else {
            QMKWarn(@"增强面板: 切换失败 (增强单例不可用)");
        }
    } @catch (NSException *e) { QMKErr(@"enhancer-panel", e); }
}

// 错误日志弹窗: 注入诊断 + 旋转状态 + 最近错误 (定位"哪里报错")
- (void)logTapped {
    @try {
        UIViewController *vc = self.panelVC;
        if (!vc) vc = [UIApplication sharedApplication].keyWindow.rootViewController;
        if (!vc) return;
        NSString *sb  = QMKMarkExists(@"extrakeys_springboard") ? @"OK" : @"FAIL";
        NSString *ms  = QMKMarkExists(@"extrakeys_mediaserverd") ? @"OK" : @"FAIL";
        NSString *ls  = QMKMarkExists(@"extrakeys_lskdd") ? @"OK" : @"FAIL";
        NSString *enh = QMKMarkExists(@"enhancer_injected") ? @"OK" : @"FAIL";
        NSString *pix = QMKMarkExists(@"update_called") ? @"OK" : @"FAIL";
        NSMutableString *msg = [NSMutableString string];
        [msg appendFormat:@"[注入诊断]\n功能键UI(SpringBoard): %@\n帧旋转(mediaserverd): %@\n帧旋转(lskdd): %@\n增强模块: %@\n像素管线(update_called): %@\n视频旋转: %ld°\n\n[错误记录]\n",
         sb, ms, ls, enh, pix, (long)QMKReadRotation()];
        // 取最近 20 条, 最新在上
        NSMutableArray *lines = [NSMutableArray array];
        NSString *all = [NSString stringWithContentsOfFile:QMKErrorLogPath
                                                  encoding:NSUTF8StringEncoding error:nil];
        for (NSString *rawLine in [all componentsSeparatedByString:@"\n"]) {
            NSString *l = [rawLine stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (l.length > 0) [lines addObject:l];
        }
        if (lines.count == 0) {
            [msg appendString:@"(无错误)"];
        } else {
            NSInteger n = MIN((NSInteger)lines.count, 20);
            NSRange tail = NSMakeRange((NSInteger)lines.count - n, n);
            for (NSString *l in [[lines subarrayWithRange:tail] reverseObjectEnumerator]) {
                [msg appendFormat:@"%@\n", l];
            }
        }
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"错误日志 (诊断)"
                                                                    message:msg
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [al addAction:[UIAlertAction actionWithTitle:@"清空日志" style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *a) {
            @try { [@"" writeToFile:QMKErrorLogPath atomically:YES
                           encoding:NSUTF8StringEncoding error:nil]; }
            @catch (NSException *e) {}
        }]];
        [al addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:al animated:YES completion:nil];
    } @catch (NSException *e) { QMKErr(@"log-key", e); }
}

@end

static QMKExtraController *QMKController(void) {
    static QMKExtraController *c = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [QMKExtraController new]; });
    return c;
}

static UIButton *QMKBarButton(NSString *title, NSInteger tag, UIColor *border,
                              UIView *bar, SEL action) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.tag = tag;
    b.layer.cornerRadius = 8;
    b.layer.borderWidth = 1;
    b.layer.borderColor = border.CGColor;
    b.backgroundColor = [UIColor colorWithWhite:0.18 alpha:0.7];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.6;
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b addTarget:QMKController() action:action forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:b];
    return b;
}

// 3 键条: 视频旋转(实时角度) / 增强面板 / 错误日志 (取色增强已按要求移入增强面板)
static void QMKAttachBar(UIView *hostView, UIViewController *vc) {
    @try {
        if ([hostView viewWithTag:QMK_BAR_TAG]) return; // 幂等
        CGFloat W = hostView.bounds.size.width;
        CGFloat H = hostView.bounds.size.height;
        if (W < 100 || H < 100) return;
        CGFloat K = MIN(W / 390.0, H / 844.0);
        CGFloat bh = 42 * K;
        CGFloat by = H - bh - 20 * K;
        if (by < 40 * K) by = 40 * K;
        UIColor *c1 = [UIColor colorWithRed:0.31 green:0.86 blue:1.0 alpha:1.0];
        UIColor *c2 = [UIColor colorWithRed:0.71 green:0.47 blue:1.0 alpha:1.0];
        UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(12 * K, by, W - 24 * K, bh)];
        bar.tag = QMK_BAR_TAG;
        bar.layer.cornerRadius = 12;
        bar.layer.borderWidth = 1;
        bar.layer.borderColor = c2.CGColor;
        bar.backgroundColor = [UIColor colorWithRed:0.063 green:0.102 blue:0.173 alpha:0.96];
        bar.layer.shadowColor = [UIColor blackColor].CGColor;
        bar.layer.shadowOpacity = 0.4f;
        bar.layer.shadowOffset = CGSizeMake(0, 8);
        bar.layer.shadowRadius = 20;
        CGFloat pad = 4 * K;
        CGFloat btnW = (bar.bounds.size.width - pad * 4) / 3;
        CGFloat btnH = bh - pad * 2;
        QMKController().panelVC = vc;
        UIButton *rot = QMKBarButton([NSString stringWithFormat:@"旋转 %ld°", (long)QMKReadRotation()],
                                     QMK_ROTBTN_TAG, c1, bar, @selector(rotateTapped));
        rot.frame = CGRectMake(pad, pad, btnW, btnH);
        QMKController().rotBtn = rot;
        UIButton *enh = QMKBarButton(@"增强面板", 0x6E22, c2, bar, @selector(enhancerPanelTapped));
        enh.frame = CGRectMake(pad * 2 + btnW, pad, btnW, btnH);
        UIButton *log = QMKBarButton(@"错误日志", 0x6E23, c2, bar, @selector(logTapped));
        log.frame = CGRectMake(pad * 3 + btnW * 2, pad, btnW, btnH);
        [hostView addSubview:bar];
        QMKInfo(@"增强键条已挂载 (面板底部)");
    } @catch (NSException *e) { QMKErr(@"bar-attach", e); }
}

// 锚点: 方案J 面板标题 "控制终端UI面板"
static UIView *QMKFindPanelLabel(UIView *root, int depth) {
    if (!root || depth > 4) return nil;
    if ([root isKindOfClass:[UILabel class]]) {
        UILabel *lb = (UILabel *)root;
        if ([lb.text isEqualToString:@"控制终端UI面板"]) return root;
    }
    for (UIView *v in root.subviews) {
        UIView *hit = QMKFindPanelLabel(v, depth + 1);
        if (hit) return hit;
    }
    return nil;
}

static UIViewController *QMKFindPanelVC(void) {
    @try {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            for (UIView *sv in w.subviews) {
                UIView *lb = QMKFindPanelLabel(sv, 0);
                if (lb) {
                    UIResponder *r = lb;
                    while (r) {
                        r = r.nextResponder;
                        if ([r isKindOfClass:[UIViewController class]]) {
                            return (UIViewController *)r;
                        }
                    }
                    return w.rootViewController;
                }
            }
        }
    } @catch (NSException *e) { QMKErr(@"panel-find", e); }
    return nil;
}

// 悬浮钮抑制: 增强模块 checkAndReadd 每 5s 重挂, 我们 3s 重隐藏 (全局唯一悬浮球)
static void QMKSuppressEnhancerButton(void) {
    @try {
        Class enh = NSClassFromString(@"QMEnhancerView");
        if (!enh) return;
        id inst = QMKSafeCall(enh, @selector(sharedInstance), nil);
        if (!inst) return;
        Ivar iv = class_getInstanceVariable(enh, "_floatButton");
        if (!iv) return;
        UIView *fb = object_getIvar(inst, iv);
        if (fb && !fb.hidden) {
            fb.hidden = YES;
            QMKInfo(@"增强悬浮钮已隐藏 (全局仅保留 vcam 悬浮球)");
        }
    } @catch (NSException *e) { QMKErr(@"btn-suppress", e); }
}

static void QMKTick(void) {
    @try {
        static BOOL lastVisible = NO;
        UIViewController *vc = QMKFindPanelVC();
        BOOL visible = (vc != nil);
        if (visible) {
            UIView *host = vc.view ?: vc.view.window;
            if (host) QMKAttachBar(host, vc);
        }
        if (visible != lastVisible) {
            QMKInfo(visible ? @"功能面板已展开" : @"功能面板已收起");
            lastVisible = visible;
        }
        static int tick = 0;
        if (++tick % 6 == 0) QMKSuppressEnhancerButton();
    } @catch (NSException *e) { QMKErr(@"tick", e); }
}

// ---------------------------------------------------------------
// 入口: 按进程分派 (UI 层 SpringBoard / 帧层 mediaserverd·lskdd)
// ---------------------------------------------------------------
__attribute__((constructor))
static void QMKInit(void) {
    @autoreleasepool {
        @try {
            QMKProcess p = QMKProc();
            if (p == QMKProcessOther) return;
            QMKMarkInjected(p);
            if (p == QMKProcessSpringBoard) {
                QMKInfo(@"VCamExtraKeys LV-1 UI 层已注入 (SpringBoard)");
                QMKMigrateLegacyRotation();
                dispatch_async(dispatch_get_main_queue(), ^{
                    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
                        QMKTick();
                    }];
                });
                return;
            }
            // 帧层: 装旋转钩子 (类可能晚加载, 0.5/2/5s 重试)
            QMKInfo([NSString stringWithFormat:@"VCamExtraKeys LV-1 帧层已注入 (%@)", QMKProcName(p)]);
            QMKInstallFrameHook();
            dispatch_async(dispatch_get_main_queue(), ^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ QMKInstallFrameHook(); });
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ QMKInstallFrameHook(); });
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ QMKInstallFrameHook(); });
            });
        } @catch (NSException *e) { QMKErr(@"init", e); }
    }
}