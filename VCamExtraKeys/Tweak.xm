// VCamExtraKeys v7 (LV-5) - 统一功能舱 v3 (vcam 核心/UI补丁/增强模块 零改动)
// 修复 v6 旧面板仍可见: 根因 = "有界深度扫描"与"每次展示新建实例且不回收"不匹配:
//   补丁每次 viewDidLoad 全量重建, 旧实例窗口不回收; v6 扫描带深度上限(6层),
//   旧面板被模态/多级容器埋在更深层级时永远找不到 → 既不隐藏也不绑定。
//   A1) 无界扫描(迭代栈, 无深度上限)收集面板条目: 标题标签 → responder 链(≤6跳)
//       命中 VCamSettingsViewController → vc 条目; 未命中 → 容器兜底条目
//   A2) 主面板 = 可见 vc 条目中 (windowLevel 最高, 其次最新); 容器条目永不为
//       主面板, 一律兜底隐藏 (陈旧残留)
//   A3) 非主 vc 面板整面隐藏; 仅在有可见主面板时执行 (收起态不动任何根)
//   A4) 键转发固定指向主面板活 VC; 面板实例数变化时记录日志
// B) 视频旋转: 帧层(mediaserverd/lskdd)钩 LocalVideoPlayer updateCurrentBuffer:
//    照抄参考算法(旋转变换->自适应裁满->渲染回 w x h), 自证诊断:
//    首帧记尺寸/每60帧报数/10s看门狗(旋转开但无帧流入->ERR)/90s重试
// C) 错误日志: /tmp/qianmian_error.log, 进程注入/类找到/钩子/帧流入,
//    弹窗+复制日志(全文)+清空
// D) 输出 LV-5.deb
#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>

static NSString *const QMKSharedSettingsPath = @"/tmp/qianmian_enhancer_settings.plist";
static NSString *const QMKErrorLogPath       = @"/tmp/qianmian_error.log";
static NSString *const QMKRotationKey        = @"videoRotationLV";
static NSString *const QMKLegacyRotationKey  = @"videoRotation";

static const NSInteger QMK_TAG_POD  = 0x6E30;
static const NSInteger QMK_TAG_ROT  = 0x6E31;
static const NSInteger QMK_TAG_ENH  = 0x6E32;
static const NSInteger QMK_TAG_LOG  = 0x6E33;
static const NSInteger QMK_TAG_MED  = 0x6E34;
static const NSInteger QMK_TAG_REP  = 0x6E35;
static const NSInteger QMK_TAG_RST  = 0x6E36;
static const NSInteger QMK_TAG_BAL  = 0x6E37;
static const NSInteger QMK_TAG_RTM  = 0x6E38;
static const NSInteger QMK_TAG_URL  = 0x6E39;
static const NSInteger QMK_TAG_STT  = 0x6E3A;
static const NSInteger QMK_TAG_TUT  = 0x6E3B;
static const NSInteger QMK_TAG_CLS  = 0x6E3C;

static const NSInteger VP_TAG_BADGE   = 0x6B62;
static const NSInteger VP_TAG_MINISW  = 0x6B65;
static const NSInteger VP_TAG_MINITF  = 0x6B66;
static const NSInteger VP_TAG_RTMPSW  = 0x6B67;

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
    return (r == 90 || r == 180 || r == 270) ? r : 0;
}

static NSInteger QMKCycleRotation(void) {
    NSMutableDictionary *s = [NSMutableDictionary dictionaryWithDictionary:QMKReadSettings()];
    NSInteger next = (QMKReadRotation() + 90) % 360;
    [s setObject:@(next) forKey:QMKRotationKey];
    [s setObject:@(0) forKey:QMKLegacyRotationKey];
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

static id QMKSafeCall(id target, SEL sel, id arg) {
    if (!target || !sel || ![target respondsToSelector:sel]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return arg ? [target performSelector:sel withObject:arg] : [target performSelector:sel];
#pragma clang diagnostic pop
}

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

static void (*origUpdateCurrentBuffer)(id, SEL, CVBufferRef) = NULL;
static volatile int64_t QMKFramesSeen = 0;
static volatile int64_t QMKFramesRotated = 0;
static void QMKUpdateCurrentBufferHook(id self, SEL _cmd, CVBufferRef buffer) {
    @try {
        int64_t n = __sync_add_and_fetch(&QMKFramesSeen, 1);
        if (n == 1) {
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
                CVPixelBufferRelease(rotated);
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
            static BOOL warned = NO;
            if (!warned) {
                warned = YES;
                QMKWarn([NSString stringWithFormat:@"LocalVideoPlayer 类未找到 (%@), 继续等待…",
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
                    QMKLogLine(@"ERR", nil, [NSString stringWithFormat:
                        @"旋转已开启但帧钩子无帧流入: %@ 进程内 updateCurrentBuffer: 从未被调用",
                        QMKProcName(QMKProc())]);
                }
            } @catch (NSException *e) {}
        }
    });
    dispatch_resume(src);
}

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
                if (++tries >= 45) {
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

static void QMKUrlCommit(UIViewController *vc);

@interface QMKExtraController : NSObject
@property (nonatomic, weak) UIViewController *panelVC;
@property (nonatomic, weak) UIButton *rotBtn;
@property (nonatomic, weak) UILabel *sttRep;
@property (nonatomic, weak) UILabel *sttRtmp;
- (void)keyTapped:(UIButton *)sender;
- (void)urlEditingEnd:(UITextField *)sender;
@end

@implementation QMKExtraController

- (void)keyTapped:(UIButton *)sender {
    if (!sender) return;
    @try {
        switch (sender.tag) {
            case QMK_TAG_ROT: {
                NSInteger next = QMKCycleRotation();
                [self.rotBtn setTitle:[NSString stringWithFormat:@"🔄\n旋转 %ld°", (long)next]
                             forState:UIControlStateNormal];
                break;
            }
            case QMK_TAG_ENH: {
                Class enh = NSClassFromString(@"QMEnhancerView");
                if (!enh) { QMKWarn(@"增强面板: 增强模块未加载"); break; }
                id inst = QMKSafeCall(enh, @selector(sharedInstance), nil);
                if (inst && [inst respondsToSelector:@selector(togglePanel)]) {
                    QMKSafeCall(inst, @selector(togglePanel), nil);
                    QMKInfo(@"增强面板: 展开/收起已切换");
                } else {
                    QMKWarn(@"增强面板: 切换失败 (增强单例不可用)");
                }
                break;
            }
            case QMK_TAG_LOG: [self showLogAlert]; break;
            case QMK_TAG_MED: [self forwardSel:@selector(switchVideoTapped)]; break;
            case QMK_TAG_REP: [self forwardSel:@selector(toggleReplacementTapped)]; break;
            case QMK_TAG_RST: [self forwardSel:@selector(restoreCameraTapped)]; break;
            case QMK_TAG_BAL: [self forwardSel:@selector(toggleFloatingBallTapped)]; break;
            case QMK_TAG_RTM: [self toggleRtmp]; break;
            case QMK_TAG_TUT: [self forwardSel:@selector(openTutorial)]; break;
            case QMK_TAG_CLS: [self forwardSel:@selector(dismissPanel)]; break;
            default: break;
        }
    } @catch (NSException *e) { QMKErr(@"key-tapped", e); }
}

- (void)forwardSel:(SEL)sel {
    UIViewController *vc = self.panelVC;
    if (!vc || ![vc respondsToSelector:sel]) {
        QMKWarn([NSString stringWithFormat:@"面板 VC 不可用或方法缺失: %@",
                 NSStringFromSelector(sel)]);
        return;
    }
    QMKSafeCall(vc, sel, nil);
    QMKInfo([NSString stringWithFormat:@"已触发原功能: %@", NSStringFromSelector(sel)]);
}

- (void)toggleRtmp {
    UIViewController *vc = self.panelVC;
    UIView *root = vc ? vc.view : nil;
    UISwitch *miniSw = (UISwitch *)[root viewWithTag:VP_TAG_MINISW];
    if (![miniSw isKindOfClass:[UISwitch class]]) {
        QMKWarn(@"RTMP 键: 补丁 miniSw 未找到 (0x6B65)");
        return;
    }
    [miniSw setOn:!miniSw.isOn animated:YES];
    [miniSw sendActionsForControlEvents:UIControlEventValueChanged];
    QMKInfo([NSString stringWithFormat:@"RTMP 已切换: %@", miniSw.isOn ? @"ON" : @"OFF"]);
}

- (void)urlEditingEnd:(UITextField *)sender {
    QMKUrlCommit(self.panelVC);
}

- (void)showLogAlert {
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
        for (NSString *rawLine in [QMKFullLog() componentsSeparatedByString:@"\n"]) {
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
                              UIView *parent, CGRect frame) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.tag = tag;
    b.frame = frame;
    b.layer.cornerRadius = 16;
    b.layer.borderWidth = 1.5;
    b.layer.borderColor = border.CGColor;
    b.backgroundColor = [UIColor colorWithRed:0.10 green:0.16 blue:0.27 alpha:0.55];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:10];
    b.titleLabel.numberOfLines = 2;
    b.titleLabel.textAlignment = NSTextAlignmentCenter;
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.6;
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b addTarget:QMKController() action:@selector(keyTapped:) forControlEvents:UIControlEventTouchUpInside];
    [parent addSubview:b];
    return b;
}

static void QMKAttachUnifiedPod(UIViewController *vc) {
    @try {
        UIView *root = vc.view;
        if (!root || [root viewWithTag:QMK_TAG_POD]) return;
        CGFloat W = root.bounds.size.width;
        CGFloat H = root.bounds.size.height;
        if (W < 100 || H < 100) return;
        CGFloat K = MIN(W / 390.0, H / 844.0);

        UIColor *green  = [UIColor colorWithRed:0.24 green:1.0  blue:0.62 alpha:1.0];
        UIColor *blue   = [UIColor colorWithRed:0.24 green:0.48 blue:1.0  alpha:1.0];
        UIColor *pink   = [UIColor colorWithRed:1.0  green:0.24 blue:0.62 alpha:1.0];
        UIColor *gold   = [UIColor colorWithRed:1.0  green:0.77 blue:0.24 alpha:1.0];
        UIColor *teal   = [UIColor colorWithRed:0.31 green:0.86 blue:1.0  alpha:1.0];
        UIColor *purple = [UIColor colorWithRed:0.71 green:0.47 blue:1.0  alpha:1.0];
        UIColor *red    = [UIColor colorWithRed:1.0  green:0.36 blue:0.36 alpha:1.0];
        UIColor *slate  = [UIColor colorWithRed:0.49 green:0.61 blue:0.84 alpha:1.0];

        // 全量隐藏原面板控件 (标题/双舱/教程/关闭), 仅保留我方统一舱;
        // 补丁每次 viewDidLoad 重建后, 下轮 tick 会重新隐藏 (幂等)
        for (UIView *v in root.subviews) v.hidden = YES;
        UISwitch *miniSw = (UISwitch *)[root viewWithTag:VP_TAG_MINISW];
        UISwitch *rtmpSw = (UISwitch *)[root viewWithTag:VP_TAG_RTMPSW];
        if (![miniSw isKindOfClass:[UISwitch class]]) QMKWarn(@"原 miniSw 未找到 (0x6B65)");
        if (![rtmpSw isKindOfClass:[UISwitch class]]) QMKWarn(@"原 rtmpSw 未找到 (0x6B67)");

        UIView *pod = [[UIView alloc] initWithFrame:CGRectMake(12 * K, 88 * K, 366 * K, 344 * K)];
        pod.tag = QMK_TAG_POD;
        pod.layer.cornerRadius = 22 * K;
        pod.layer.borderWidth = 1.5;
        pod.layer.borderColor = green.CGColor;
        pod.backgroundColor = [UIColor colorWithRed:0.063 green:0.102 blue:0.173 alpha:0.6];
        pod.layer.shadowColor = [UIColor blackColor].CGColor;
        pod.layer.shadowOpacity = 0.4f;
        pod.layer.shadowOffset = CGSizeMake(0, 12 * K);
        pod.layer.shadowRadius = 32 * K;

        UILabel *pt = [[UILabel alloc] initWithFrame:CGRectMake(14 * K, 12 * K, 120 * K, 12 * K)];
        pt.text = @"功能舱";
        pt.font = [UIFont boldSystemFontOfSize:9 * K];
        pt.textColor = green;
        [pod addSubview:pt];

        CGFloat kw = (366 * K - 28 * K - 40 * K) / 5;
        CGFloat kh = 80 * K;
        CGFloat ky1 = 30 * K, ky2 = 120 * K;
        NSArray *defs = @[
            @{@"t": @"🎞️\n媒体切换", @"tag": @(QMK_TAG_MED), @"c": green},
            @{@"t": @"👁️\n替换",     @"tag": @(QMK_TAG_REP), @"c": blue},
            @{@"t": @"↩️\n恢复相机",  @"tag": @(QMK_TAG_RST), @"c": pink},
            @{@"t": @"🟠\n悬浮球",    @"tag": @(QMK_TAG_BAL), @"c": gold},
            @{@"t": [NSString stringWithFormat:@"🔄\n旋转 %ld°", (long)QMKReadRotation()],
              @"tag": @(QMK_TAG_ROT), @"c": teal},
            @{@"t": @"🧪\n增强面板",  @"tag": @(QMK_TAG_ENH), @"c": purple},
            @{@"t": @"📋\n错误日志",  @"tag": @(QMK_TAG_LOG), @"c": red},
            @{@"t": [NSString stringWithFormat:@"📡\nRTMP %@", (miniSw && miniSw.isOn) ? @"ON" : @"OFF"],
              @"tag": @(QMK_TAG_RTM), @"c": slate},
            @{@"t": @"📖\n教程",     @"tag": @(QMK_TAG_TUT), @"c": blue},
            @{@"t": @"✖️\n关闭",     @"tag": @(QMK_TAG_CLS), @"c": pink},
        ];
        for (int i = 0; i < 10; i++) {
            int col = i % 5, row = i / 5;
            CGRect f = CGRectMake((14 + col * (kw + 10)) * K,
                                  (row == 0 ? ky1 : ky2) * K, kw, kh);
            UIButton *b = QMKKeyButton(defs[i][@"t"], [defs[i][@"tag"] integerValue],
                                       defs[i][@"c"], pod, f);
            if (b.tag == QMK_TAG_ROT) QMKController().rotBtn = b;
        }

        UITextField *miniTf = (UITextField *)[root viewWithTag:VP_TAG_MINITF];
        UITextField *url = [[UITextField alloc] initWithFrame:CGRectMake(14 * K, 214 * K, 338 * K, 26 * K)];
        url.tag = QMK_TAG_URL;
        url.font = [UIFont systemFontOfSize:9 * K];
        url.textColor = [UIColor colorWithRed:0.81 green:0.88 blue:1 alpha:1];
        url.backgroundColor = [UIColor colorWithRed:0.24 green:0.48 blue:1 alpha:0.15];
        url.layer.cornerRadius = 7 * K;
        url.layer.borderWidth = 1;
        url.layer.borderColor = blue.CGColor;
        url.keyboardType = UIKeyboardTypeURL;
        url.autocapitalizationType = UITextAutocapitalizationTypeNone;
        url.returnKeyType = UIReturnKeyDone;
        url.attributedPlaceholder = [[NSAttributedString alloc]
            initWithString:@"rtmp://推流地址…"
            attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.35]}];
        if ([miniTf isKindOfClass:[UITextField class]]) url.text = miniTf.text;
        [url addTarget:QMKController() action:@selector(urlEditingEnd:) forControlEvents:UIControlEventEditingDidEnd];
        [url addTarget:QMKController() action:@selector(urlEditingEnd:) forControlEvents:UIControlEventEditingDidEndOnExit];
        [pod addSubview:url];

        [root addSubview:pod];

        UIView *stt = [[UIView alloc] initWithFrame:CGRectMake(12 * K, 490 * K, 366 * K, 44 * K)];
        stt.tag = QMK_TAG_STT;
        stt.layer.cornerRadius = 14 * K;
        stt.layer.borderWidth = 1.5;
        stt.layer.borderColor = blue.CGColor;
        stt.backgroundColor = [UIColor colorWithRed:0.063 green:0.102 blue:0.173 alpha:0.6];
        UILabel *rep = [[UILabel alloc] initWithFrame:CGRectMake(20 * K, 0, 160 * K, 44 * K)];
        rep.tag = QMK_TAG_STT + 1;
        rep.textColor = green;
        rep.font = [UIFont boldSystemFontOfSize:11 * K];
        [stt addSubview:rep];
        UILabel *rtm = [[UILabel alloc] initWithFrame:CGRectMake(190 * K, 0, 160 * K, 44 * K)];
        rtm.tag = QMK_TAG_STT + 2;
        rtm.textColor = slate;
        rtm.font = [UIFont boldSystemFontOfSize:11 * K];
        [stt addSubview:rtm];
        [root addSubview:stt];
        QMKController().sttRep = rep;
        QMKController().sttRtmp = rtm;

        QMKInfo(@"统一功能舱已挂载 (10 键 + RTMP 输入 + 状态条, 原面板控件已隐藏)");
    } @catch (NSException *e) { QMKErr(@"pod-attach", e); }
}

static void QMKRefreshStatus(UIViewController *vc) {
    @try {
        UIView *root = vc ? vc.view : nil;
        QMKExtraController *c = QMKController();
        UILabel *badge = (UILabel *)[root viewWithTag:VP_TAG_BADGE];
        if (c.sttRep && [badge isKindOfClass:[UILabel class]] && badge.text.length) {
            c.sttRep.text = [NSString stringWithFormat:@"👁️ 替换 %@", badge.text];
        }
        UISwitch *miniSw = (UISwitch *)[root viewWithTag:VP_TAG_MINISW];
        if (c.sttRtmp) {
            BOOL on = [miniSw isKindOfClass:[UISwitch class]] && miniSw.isOn;
            c.sttRtmp.text = [NSString stringWithFormat:@"📡 RTMP %@", on ? @"ON" : @"OFF"];
            UIButton *rtm = (UIButton *)[root viewWithTag:QMK_TAG_RTM];
            if (rtm) [rtm setTitle:[NSString stringWithFormat:@"📡\nRTMP %@", on ? @"ON" : @"OFF"]
                          forState:UIControlStateNormal];
        }
    } @catch (NSException *e) { QMKErr(@"status-refresh", e); }
}

static void QMKUrlCommit(UIViewController *vc) {
    @try {
        UIView *root = vc ? vc.view : nil;
        UITextField *miniTf = (UITextField *)[root viewWithTag:VP_TAG_MINITF];
        UITextField *ours = (UITextField *)[root viewWithTag:QMK_TAG_URL];
        if (![miniTf isKindOfClass:[UITextField class]] ||
            ![ours isKindOfClass:[UITextField class]]) return;
        if (![miniTf.text isEqualToString:ours.text]) {
            miniTf.text = ours.text;
            [miniTf sendActionsForControlEvents:UIControlEventEditingDidEnd];
            QMKInfo(@"RTMP 地址已提交");
        }
    } @catch (NSException *e) { QMKErr(@"url-commit", e); }
}

// 收集面板条目 (无界扫描): 标题标签 → responder 链命中 VCamSettingsViewController
// 得 vc 条目; 未命中得容器兜底条目 (陈旧残留视图, 永不为主面板)
static NSArray *QMKFindAllPanelEntries(void) {
    @try {
        Class panelCls = NSClassFromString(@"VCamSettingsViewController");
        NSMutableArray *out = [NSMutableArray array];
        NSInteger order = 0;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            // 迭代栈遍历, 无深度上限 (v6 有界递归正是漏掉深层旧面板的根因)
            NSMutableArray *stack = [NSMutableArray arrayWithArray:[w subviews]];
            while (stack.count) {
                UIView *v = [stack lastObject];
                [stack removeLastObject];
                if ([v isKindOfClass:[UILabel class]]) {
                    UILabel *lb = (UILabel *)v;
                    if ([lb.text isEqualToString:@"控制终端UI面板"]) {
                        // 沿 responder 找面板 VC: 面板内容到 VC 最多 2-3 跳,
                        // 6 跳为上限防止意外深链 (仅此步有界, 非扫描本身)
                        UIResponder *r = lb;
                        UIViewController *vc = nil;
                        for (int i = 0; i < 6 && r; i++) {
                            r = r.nextResponder;
                            if (r && panelCls && [r isKindOfClass:panelCls]) {
                                vc = (UIViewController *)r;
                                break;
                            }
                        }
                        if (vc) {
                            [out addObject:@{@"kind": @"vc", @"vc": vc, @"view": vc.view,
                                             @"win": w, @"order": @(order++)}];
                        } else {
                            // 无 VC 兜底: 取窗口之下最高祖先作为隐藏目标 (陈旧残留)
                            UIView *anc = v;
                            while (anc.superview && anc.superview != w) anc = anc.superview;
                            [out addObject:@{@"kind": @"container", @"vc": [NSNull null],
                                             @"view": anc, @"win": w, @"order": @(order++)}];
                        }
                    }
                }
                for (UIView *c in [v subviews]) [stack addObject:c];
            }
        }
        return out;
    } @catch (NSException *e) { QMKErr(@"panel-find", e); }
    return @[];
}

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
        static NSInteger lastCount = -1;
        NSArray *entries = QMKFindAllPanelEntries();
        if ((NSInteger)entries.count != lastCount) {
            lastCount = entries.count;
            QMKInfo([NSString stringWithFormat:@"面板发现 %ld 个实例", (long)entries.count]);
        }
        // 主面板 = 可见 vc 条目中 (windowLevel 最高, 其次最新); 容器条目永不为主
        UIViewController *primary = nil;
        UIView *primaryView = nil;
        double bestLevel = -1;
        NSInteger bestOrder = -1;
        for (NSDictionary *e in entries) {
            if (![e[@"kind"] isEqualToString:@"vc"]) continue;
            UIView *v = e[@"view"];
            UIWindow *w = e[@"win"];
            if (!v || v.hidden || !w || w.hidden) continue;
            double lv = w.windowLevel;
            NSInteger od = [e[@"order"] integerValue];
            if (!primaryView || lv > bestLevel || (lv == bestLevel && od > bestOrder)) {
                bestLevel = lv;
                bestOrder = od;
                primaryView = v;
                primary = e[@"vc"];
            }
        }
        // 非主 vc 整面隐藏 + 无 VC 容器兜底隐藏; 仅在有可见主面板时执行
        // (收起态不动任何根: 应用仅靠窗口隐藏/恢复时面板不能被我们永久藏死)
        if (primaryView) {
            for (NSDictionary *e in entries) {
                UIView *v = e[@"view"];
                if (v && !v.hidden &&
                    (v != primaryView || [e[@"kind"] isEqualToString:@"container"])) {
                    v.hidden = YES;
                }
            }
            QMKController().panelVC = primary;
            QMKAttachUnifiedPod(primary);
            QMKRefreshStatus(primary);
        }
        BOOL visible = (primaryView != nil);
        if (visible != lastVisible) {
            QMKInfo(visible ? @"功能面板已展开" : @"功能面板已收起");
            lastVisible = visible;
        }
        static double lastTitle = 0;
        double now = [NSDate timeIntervalSinceReferenceDate];
        if (now - lastTitle > 1.0) {
            lastTitle = now;
            [QMKController().rotBtn setTitle:
                [NSString stringWithFormat:@"🔄\n旋转 %ld°", (long)QMKReadRotation()]
                                   forState:UIControlStateNormal];
        }
        static int tick = 0;
        if (++tick % 6 == 0) QMKSuppressEnhancerButton();
    } @catch (NSException *e) { QMKErr(@"tick", e); }
}

__attribute__((constructor))
static void QMKInit(void) {
    @autoreleasepool {
        @try {
            QMKProcess p = QMKProc();
            if (p == QMKProcessOther) return;
            QMKMarkInjected(p);
            if (p == QMKProcessSpringBoard) {
                QMKInfo(@"VCamExtraKeys LV-5 UI 层已注入 (SpringBoard)");
                QMKMigrateLegacyRotation();
                dispatch_async(dispatch_get_main_queue(), ^{
                    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
                        QMKTick();
                    }];
                });
                return;
            }
            QMKInfo([NSString stringWithFormat:@"VCamExtraKeys LV-5 帧层已注入 (%@)", QMKProcName(p)]);
            QMKScheduleFrameInstall();
        } @catch (NSException *e) { QMKErr(@"init", e); }
    }
}