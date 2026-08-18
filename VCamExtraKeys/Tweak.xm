// ===============================================================
// VCamExtraKeys v4.1 (LV-2) — 功能键挂载模块 (vcam 核心/补丁/增强 零改动)
// ===============================================================
// v4.1 变更 (按设备反馈迭代):
//   A) 新增功能键与正常按键同面板排序: 移除底部悬浮键条, 改为面板窗口内
//      "功能扩展"舱 (玻璃舱风格同主控舱), 3 键: 视频旋转(实时角度)/增强面板/错误日志。
//   B) 视频旋转失效根因防御: 帧钩子安装改为 dispatch_source 持续重试(每次 2s, 至多
//      90s), 并在帧层自证: 首帧落钩记 [INFO] 尺寸, 旋转开启时每 60 帧记 [INFO],
//      10s 看门狗: 旋转开启但无帧流入 → [ERR] 明确报"哪个进程无帧流入"。
//   C) 日志定位"进程未生效/异常": 每进程注入标记 + 类找到/钩子安装/帧流入状态
//      全部落盘; 弹窗新增【复制日志】按钮 (全文拷到剪贴板, 供直接反馈)。
//   D) 输出包命名 LV-2.deb。
// ===============================================================

#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>

static NSString *const QMKSharedSettingsPath = @"/tmp/qianmian_enhancer_settings.plist";
static NSString *const QMKErrorLogPath       = @"/tmp/qianmian_error.log";
static NSString *const QMKRotationKey        = @"videoRotationLV"; // 单所有者键
static NSString *const QMKLegacyRotationKey  = @"videoRotation";   // 旧键(迁移后清零)
static const NSInteger QMK_EXT_TAG  = 0x6E30; // 扩展舱容器
static const NSInteger QMK_ROT_TAG  = 0x6E31; // 旋转键
static const NSInteger QMK_ENH_TAG  = 0x6E32; // 增强面板键
static const NSInteger QMK_LOG_TAG  = 0x6E33; // 错误日志键

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

// 每进程注入标记: /tmp/qm_extrakeys_springboard.txt 等 (诊断"进程未生效")
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
// 错误/诊断日志 (用户要求: 记录"哪个进程未生效/哪里报错")
//   [INFO] 正常状态 / [WARN] 可恢复异常 / [ERR] 报错点 (异常名+原因+位置)
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

static NSString *QMKFullLog(void) {
    @try {
        NSString *all = [NSString stringWithContentsOfFile:QMKErrorLogPath
                                                  encoding:NSUTF8StringEncoding error:nil];
        return all ?: @"(日志文件为空)";
    } @catch (NSException *e) {}
    return @"(日志读取失败)";
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
    @try { [settings writeToFile:QMKSharedSettingsPath atomically:YES]; }
    @catch (NSException *e) {}
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

// 转发辅助 (无 ARC 警告 performSelector)
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
    dispatch_once(&once, ^{ ctx = [CIContext contextWithOptions:nil]; });
    return ctx;
}

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
static volatile int64_t QMKFramesSeen = 0;   // 本进程帧流入计数 (自证管线)
static volatile int64_t QMKFramesRotated = 0;
static void QMKUpdateCurrentBufferHook(id self, SEL _cmd, CVBufferRef buffer) {
    @try {
        int64_t n = __sync_add_and_fetch(&QMKFramesSeen, 1);
        if (n == 1) { // 首帧自证: 记录尺寸
            QMKInfo([NSString stringWithFormat:@"首帧已进入帧钩子 (%zu x %zu)",
                     CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer)]);
        }
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
                int64_t r = __sync_add_and_fetch(&QMKFramesRotated, 1);
                if (r % 60 == 1) {
                    QMKInfo([NSString stringWithFormat:@"已旋转 %lld 帧 (%ld° 管线正常)", r, (long)cachedRot]);
                }
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
        if (!lvp) {
            // 类未加载 → 留待重试; 仅首次提示, 避免刷屏
            static BOOL warned = NO;
            if (!warned) {
                warned = YES;
                QMKWarn([NSString stringWithFormat:@"LocalVideoPlayer 类未找到 (%@), 继续等待类加载…",
                         QMKProcName(QMKProc())]);
            }
            return;
        }
        Method m = class_getInstanceMethod(lvp, @selector(updateCurrentBuffer:));
        if (!m) {
            QMKWarn([NSString stringWithFormat:@"updateCurrentBuffer: 方法未找到 (%@)",
                     QMKProcName(QMKProc())]);
            return;
        }
        IMP orig = method_getImplementation(m);
        if (orig == (IMP)QMKUpdateCurrentBufferHook) { QMKFrameInstalled = YES; return; }
        origUpdateCurrentBuffer = (void (*)(id, SEL, CVBufferRef))orig;
        method_setImplementation(m, (IMP)QMKUpdateCurrentBufferHook);
        QMKFrameInstalled = YES;
        QMKInfo([NSString stringWithFormat:@"帧钩子已安装 (%@, %lld 帧待处理)",
                 QMKProcName(QMKProc()), QMKFramesSeen]);
    } @catch (NSException *e) {
        QMKErr(@"frame-install", e);
    }
}

// 10s 看门狗: 旋转已开启但本进程无帧流入 → 明确报错 (定位"进程未生效")
static void QMKScheduleFrameWatchdog(void) {
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(src, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                              10 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(src, ^{
        @autoreleasepool {
            @try {
                if (!QMKFrameInstalled) return;
                if (QMKReadRotation() != 0 && QMKFramesSeen == 0) {
                    QMKErr(@"rotate-watchdog", nil);
                    QMKLogLine(@"ERR", nil, [NSString stringWithFormat:
                        @"旋转已开启但帧钩子无帧流入: %@ 进程内 updateCurrentBuffer: 从未被调用",
                        QMKProcName(QMKProc())]);
                }
            } @catch (NSException *e) {}
        }
    });
    dispatch_resume(src);
}

// 帧层: 安装 + 持续重试 (类晚加载也覆盖), 全部走 dispatch_source 不依赖主线程 runloop
static void QMKScheduleFrameInstall(void) {
    QMKInstallFrameHook();
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(src, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                              2 * NSEC_PER_SEC, NSEC_PER_SEC);
    __block int tries = 0;
    dispatch_source_set_event_handler(src, ^{
        @autoreleasepool {
            @try {
                if (QMKFrameInstalled) { dispatch_source_cancel(src); return; }
                if (++tries >= 45) { // 90s 仍无类 → 明确报告"进程未生效"
                    QMKErr(@"rotate-install-timeout", nil);
                    QMKLogLine(@"ERR", nil, [NSString stringWithFormat:
                        @"帧钩子 90s 内未装成: %@ 进程无 LocalVideoPlayer/updateCurrentBuffer: 或注入未生效",
                        QMKProcName(QMKProc())]);
                    dispatch_source_cancel(src);
                    return;
                }
                QMKInstallFrameHook();
            } @catch (NSException *e) {}
        }
    });
    dispatch_resume(src);
    QMKScheduleFrameWatchdog();
}

// ===============================================================
// UI 层 (SpringBoard): 扩展舱 (与正常按键同面板排序) + 诊断弹窗 + 悬浮钮抑制
// ===============================================================
@interface QMKExtraController : NSObject
@property (nonatomic, weak) UIViewController *panelVC;
@property (nonatomic, weak) UIButton *rotBtn;
- (void)rotateTapped;
- (void)enhancerPanelTapped;
- (void)logTapped;
@end

@implementation QMKExtraController

- (void)rotateTapped {
    @try {
        NSInteger next = QMKCycleRotation();
        [self.rotBtn setTitle:[NSString stringWithFormat:@"旋转 %ld°", (long)next]
                     forState:UIControlStateNormal];
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

// 错误日志弹窗: 注入诊断(进程未生效?) + 旋转状态 + 最近错误 + 【复制日志】
- (void)logTapped {
    @try {
        UIViewController *vc = self.panelVC;
        if (!vc) vc = [UIApplication sharedApplication].keyWindow.rootViewController;
        if (!vc) return;
        NSString *sb  = QMKMarkExists(@"extrakeys_springboard") ? @"OK" : @"FAIL";
        NSString *ms  = QMKMarkExists(@"extrakeys_mediaserverd") ? @"OK" : @"FAIL";
        NSString *ls  = QMKMarkExists(@"extrakeys_lskdd") ? @"OK" : @"FAIL";
        NSString *enh = QMKMarkExists(@"enhancer_injected") ? @"OK" : @"FAIL";
        NSMutableString *diag = [NSMutableString string];
        [diag appendFormat:@"[进程注入诊断]\n功能键UI(SpringBoard): %@\n帧旋转(mediaserverd): %@\n帧旋转(lskdd): %@\n增强模块: %@\n视频旋转: %ld°\n",
         sb, ms, ls, enh, (long)QMKReadRotation()];
        [diag appendString:@"[错误记录] (最近20条, 最新在上)\n"];
        NSMutableArray *lines = [NSMutableArray array];
        NSString *all = QMKFullLog();
        for (NSString *rawLine in [all componentsSeparatedByString:@"\n"]) {
            NSString *l = [rawLine stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (l.length > 0) [lines addObject:l];
        }
        if (lines.count == 0) {
            [diag appendString:@"(无错误)"];
        } else {
            NSInteger n = MIN((NSInteger)lines.count, 20);
            NSRange tail = NSMakeRange((NSInteger)lines.count - n, n);
            for (NSString *l in [[lines subarrayWithRange:tail] reverseObjectEnumerator]) {
                [diag appendFormat:@"%@\n", l];
            }
        }
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"错误日志 (诊断)"
                                                                    message:diag
                                                             preferredStyle:UIAlertControllerStyleAlert];
        // 复制日志: 诊断 + 全文 → 剪贴板, 直接粘贴反馈
        [al addAction:[UIAlertAction actionWithTitle:@"复制日志" style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            @try {
                NSString *full = [diag stringByAppendingFormat:@"\n---- 日志全文 ----\n%@", QMKFullLog()];
                [UIPasteboard generalPasteboard].string = full;
            } @catch (NSException *e) {}
        }]];
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

static UIButton *QMKKeyButton(NSString *title, NSInteger tag, UIColor *border,
                              UIView *parent, CGRect frame, SEL action) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.tag = tag;
    b.frame = frame;
    b.layer.cornerRadius = 12;
    b.layer.borderWidth = 1.5;
    b.layer.borderColor = border.CGColor;
    b.backgroundColor = [UIColor colorWithRed:0.18 green:0.18 blue:0.25 alpha:0.7];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.6;
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b addTarget:QMKController() action:action forControlEvents:UIControlEventTouchUpInside];
    [parent addSubview:b];
    return b;
}

// 扩展舱: 挂到面板窗口底部, 与正常按键同面板同风格排序 (幂等)
static void QMKAttachExtPod(UIViewController *vc) {
    @try {
        UIView *host = vc.view;
        if (!host || [host viewWithTag:QMK_EXT_TAG]) return;
        CGFloat W = host.bounds.size.width;
        CGFloat H = host.bounds.size.height;
        if (W < 100 || H < 100) return;
        CGFloat K = MIN(W / 390.0, H / 844.0);
        CGFloat pw = W - 24 * K;              // 舱宽同主控舱外缘
        CGFloat ph = 86 * K;                  // 舱高
        CGFloat py = H - ph - 16 * K;         // 贴底 (教程/关闭之下)
        if (py < 46 * K + 30 * K + 10 * K) py = 46 * K + 30 * K + 10 * K; // 不低于标题区
        UIColor *purple = [UIColor colorWithRed:0.71 green:0.47 blue:1.0 alpha:1.0];
        UIColor *teal    = [UIColor colorWithRed:0.31 green:0.86 blue:1.0 alpha:1.0];
        UIColor *red     = [UIColor colorWithRed:1.0 green:0.36 blue:0.36 alpha:1.0];
        UIView *pod = [[UIView alloc] initWithFrame:CGRectMake(12 * K, py, pw, ph)];
        pod.tag = QMK_EXT_TAG;
        pod.layer.cornerRadius = 22 * K;
        pod.layer.borderWidth = 1.5;
        pod.layer.borderColor = purple.CGColor;
        pod.backgroundColor = [UIColor colorWithRed:0.063 green:0.102 blue:0.173 alpha:0.6];
        pod.layer.shadowColor = [UIColor blackColor].CGColor;
        pod.layer.shadowOpacity = 0.4f;
        pod.layer.shadowOffset = CGSizeMake(0, 12);
        pod.layer.shadowRadius = 32;
        UILabel *pt = [[UILabel alloc] initWithFrame:CGRectMake(14 * K, 8 * K, 120 * K, 12 * K)];
        pt.text = @"功能扩展";
        pt.font = [UIFont boldSystemFontOfSize:9 * K];
        pt.textColor = purple;
        [pod addSubview:pt];
        CGFloat ky = 26 * K;
        CGFloat kh = ph - ky - 12 * K;
        CGFloat pad = 4 * K;
        CGFloat bw = (pw - 14 * K * 2 - pad * 2) / 3;
        QMKController().panelVC = vc;
        UIButton *rot = QMKKeyButton([NSString stringWithFormat:@"旋转 %ld°", (long)QMKReadRotation()],
                                     QMK_ROT_TAG, teal, pod,
                                     CGRectMake(14 * K, ky, bw, kh), @selector(rotateTapped));
        QMKController().rotBtn = rot;
        QMKKeyButton(@"增强面板", QMK_ENH_TAG, purple, pod,
                     CGRectMake(14 * K + bw + pad, ky, bw, kh), @selector(enhancerPanelTapped));
        QMKKeyButton(@"错误日志", QMK_LOG_TAG, red, pod,
                     CGRectMake(14 * K + 2 * (bw + pad), ky, bw, kh), @selector(logTapped));
        [host addSubview:pod];
        QMKInfo(@"功能扩展舱已并入面板 (与正常按键同面板排序)");
    } @catch (NSException *e) { QMKErr(@"ext-pod-attach", e); }
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
        if (visible) QMKAttachExtPod(vc);
        if (visible != lastVisible) {
            QMKInfo(visible ? @"功能面板已展开" : @"功能面板已收起");
            lastVisible = visible;
        }
        // 旋转键实时角度刷新 (1s 节流)
        static double lastTitle = 0;
        double now = [NSDate timeIntervalSinceReferenceDate];
        if (now - lastTitle > 1.0) {
            lastTitle = now;
            [QMKController().rotBtn setTitle:
                [NSString stringWithFormat:@"旋转 %ld°", (long)QMKReadRotation()]
                                   forState:UIControlStateNormal];
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
                QMKInfo(@"VCamExtraKeys LV-2 UI 层已注入 (SpringBoard)");
                QMKMigrateLegacyRotation();
                dispatch_async(dispatch_get_main_queue(), ^{
                    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
                        QMKTick();
                    }];
                });
                return;
            }
            // 帧层: 装旋转钩子 (类可能晚加载, 持续重试至 90s + 10s 看门狗)
            QMKInfo([NSString stringWithFormat:@"VCamExtraKeys LV-2 帧层已注入 (%@)", QMKProcName(p)]);
            QMKScheduleFrameInstall();
        } @catch (NSException *e) { QMKErr(@"init", e); }
    }
}