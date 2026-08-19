// VCamExtraKeys v9 (LV-7) - 统一功能舱 v3 (vcam 核心/UI补丁/增强模块 零改动)
// 面板层 (整面重建模式, 根治旧面板残留):
//   A1) 接管 VCamSettingsViewController viewDidLoad: 原逻辑先跑, 然后同步销毁
//       全部旧可见面板实例 (view 摘除 + 独立面板窗隐藏), 最后整面重建新面板 —
//       旧实例在"新面板出现瞬间"即销毁, 不再有"短暂停留后跳到新面板"
//   A2) QMKBuildPanel 照源码/补丁 VPBuildPanel 布局与调用逻辑逐行移植:
//       标题胶囊/左主控舱(2x2 原图标键: 媒体/替换/恢复/悬浮球)/迷你RTMP镜像
//       (开关+输入)/右状态舱(眼瞳+徽章+RTMP开关)/底部教程+关闭 — 按钮 target
//       一律 = 面板 VC + 原 SEL (switchVideoTapped 等), 调用逻辑零改动;
//       徽章/RTMP tag 与补丁一致 (0x6B62/0x6B65/0x6B66/0x6B67) → 补丁的
//       updateStatusLabel 状态同步直接作用于我方 UI
//   A3) 新增键: 视频旋转 (qmkRotTapped: -> QMKCycleRotation) +
//       彩色注入 (qmkColorTapped: -> QMEnhancerView 屏幕取色映射 toggle)
//   A4) tick 兜底: 主面板根无构建标记(0x6E50) -> 重建; 非主可见实例 -> 销毁
// 旋转层 (对齐旧项目 UI源码界面虚浮窗功能):
//   B1) 旋转结果保持源格式 (420v/420f/BGRA), 不再固定输出 BGRA — 核心 YUV 管线兼容
//   B2) 消费点全覆盖: 除 updateCurrentBuffer: 外再钩 copyCurrentFrame/getCurrentFrame
//       (核心引擎取帧入口), 按源指针共享旋转缓存(≤4)防重复旋转/重复分配
//   B3) 首帧日志含格式; 每60帧报数; 10s看门狗; 90s重试
// C) 错误日志: /tmp/qianmian_error.log, 进程注入/类找到/钩子/帧流入,
//    弹窗+复制日志(全文)+清空
// E) 黑屏修复: 旋转缓存 4->16 + 淘汰延迟 2s 释放 (引擎异步渲染滞后数帧持野指针 -> 黑屏)
// F) 体积优化: 融合 deb 数据成员 data.tar.xz (xz 压缩, 安装更快)
// D) 输出 LV-7.deb
#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static NSString *const QMKSharedSettingsPath = @"/tmp/qianmian_enhancer_settings.plist";
static NSString *const QMKErrorLogPath       = @"/tmp/qianmian_error.log";
static NSString *const QMKRotationKey        = @"videoRotationLV";
static NSString *const QMKLegacyRotationKey  = @"videoRotation";

static const NSInteger QMK_TAG_ROT  = 0x6E31;
static const NSInteger QMK_TAG_LOG  = 0x6E33;
static const NSInteger QMK_TAG_MED  = 0x6E34;
static const NSInteger QMK_TAG_REP  = 0x6E35;
static const NSInteger QMK_TAG_RST  = 0x6E36;
static const NSInteger QMK_TAG_BAL  = 0x6E37;
static const NSInteger QMK_TAG_TUT  = 0x6E3B;
static const NSInteger QMK_TAG_CLS  = 0x6E3C;
static const NSInteger QMK_TAG_COL  = 0x6E3D; // 彩色注入
static const NSInteger QMK_TAG_OWN  = 0x6E50; // 我方整面重建的构建标记 (根视图)

static const NSInteger VP_TAG_BADGE    = 0x6B62;
static const NSInteger VP_TAG_BALLIMG  = 0x6B63;
static const NSInteger VP_TAG_MINISW   = 0x6B65;
static const NSInteger VP_TAG_MINITF   = 0x6B66;
static const NSInteger VP_TAG_RTMPSW   = 0x6B67;

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

static CVPixelBufferRef QMKApplyRotationPreservingFormat(CVPixelBufferRef src, NSInteger rot) {
    if (!src || rot == 0) return NULL;
    @try {
        CIImage *img = [CIImage imageWithCVImageBuffer:src];
        size_t w = CVPixelBufferGetWidth(src);
        size_t h = CVPixelBufferGetHeight(src);
        if (w == 0 || h == 0) return NULL;
        // [对齐旧项目] 旋转结果保持源格式: 核心 YUV 管线要求 420v/420f 输入,
        // 固定输出 BGRA 会被下游转换丢弃 -> 无效果/黑屏 (用户实测)
        OSType fmt = CVPixelBufferGetPixelFormatType(src);
        if (fmt != kCVPixelFormatType_32BGRA &&
            fmt != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
            fmt != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            fmt = kCVPixelFormatType_32BGRA;
        }
        NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        CVPixelBufferRef dst = NULL;
        CVPixelBufferCreate(kCFAllocatorDefault, (size_t)w, (size_t)h, fmt,
                            (__bridge CFDictionaryRef)attrs, &dst);
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

// 旋转帧缓存: 按源 buffer 指针缓存旋转结果, 多入口共享
// (updateCurrentBuffer:/copyCurrentFrame:/getCurrentFrame:), 防重复旋转/重复分配
// [黑屏修复] 引擎异步渲染可能滞后数帧, 淘汰即释放会让引擎持有野指针 -> 黑屏;
// 故: 上限 16 + 淘汰仅摘引用, 延迟 2s 释放 (引擎必已换帧, 既防野指针又防泄漏)
static NSMutableDictionary *gRotCache = nil;
static NSMutableArray *gRotCacheKeys = nil;
static CVPixelBufferRef QMKRotCached(CVBufferRef src, NSInteger rot) {
    if (!src || rot == 0) return NULL;
    @synchronized (gRotCache ?: (gRotCache = [NSMutableDictionary dictionary])) {
        if (!gRotCacheKeys) gRotCacheKeys = [NSMutableArray array];
        NSValue *key = [NSValue valueWithPointer:src];
        NSValue *hit = gRotCache[key];
        if (hit) return (CVPixelBufferRef)[hit pointerValue];
        while (gRotCacheKeys.count >= 16) {
            NSValue *old = gRotCacheKeys.firstObject;
            [gRotCacheKeys removeObjectAtIndex:0];
            NSValue *v = gRotCache[old];
            if (v) {
                [gRotCache removeObjectForKey:old];
                CVPixelBufferRef doomed = (CVPixelBufferRef)[v pointerValue];
                CFRetain(doomed);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                               dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    CVPixelBufferRelease(doomed);
                });
            }
        }
        CVPixelBufferRef out = QMKApplyRotationPreservingFormat(src, rot);
        if (out) {
            gRotCache[key] = [NSValue valueWithPointer:out];
            [gRotCacheKeys addObject:key];
        }
        return out;
    }
}

static void (*origUpdateCurrentBuffer)(id, SEL, CVBufferRef) = NULL;
static CVBufferRef (*origCopyCurrentFrame)(id, SEL) = NULL;
static CVBufferRef (*origGetCurrentFrame)(id, SEL) = NULL;
static volatile int64_t QMKFramesSeen = 0;
static volatile int64_t QMKFramesRotated = 0;
static void QMKUpdateCurrentBufferHook(id self, SEL _cmd, CVBufferRef buffer) {
    @try {
        int64_t n = __sync_add_and_fetch(&QMKFramesSeen, 1);
        if (n == 1) {
            QMKInfo([NSString stringWithFormat:@"首帧已进入帧钩子 (%zu x %zu, 格式 %c%c%c%c)",
                     CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer),
                     (char)((CVPixelBufferGetPixelFormatType(buffer) >> 24) & 0xFF),
                     (char)((CVPixelBufferGetPixelFormatType(buffer) >> 16) & 0xFF),
                     (char)((CVPixelBufferGetPixelFormatType(buffer) >> 8) & 0xFF),
                     (char)(CVPixelBufferGetPixelFormatType(buffer) & 0xFF)]);
        }
        static NSInteger cachedRot = -1;
        static double lastRead = 0;
        double now = [NSDate timeIntervalSinceReferenceDate];
        if (cachedRot < 0 || (now - lastRead) > 0.5) {
            cachedRot = QMKReadRotation();
            lastRead = now;
        }
        if (cachedRot != 0 && buffer) {
            // 共享缓存: 与取帧入口共用同一旋转结果, 不重复分配
            CVPixelBufferRef rotated = QMKRotCached(buffer, cachedRot);
            if (rotated) {
                if (origUpdateCurrentBuffer) origUpdateCurrentBuffer(self, _cmd, rotated);
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

// 消费点钩子: copyCurrentFrame / getCurrentFrame — 核心引擎取帧入口,
// 返回共享缓存旋转帧 (对齐旧项目"消费端旋转"语义)
static CVBufferRef QMKCopyCurrentFrameHook(id self, SEL _cmd) {
    @try {
        CVBufferRef f = origCopyCurrentFrame ? origCopyCurrentFrame(self, _cmd) : NULL;
        if (!f) return f;
        NSInteger rot = QMKReadRotation();
        if (rot == 0) return f;
        CVPixelBufferRef r = QMKRotCached(f, rot);
        if (r) {
            int64_t n = __sync_add_and_fetch(&QMKFramesRotated, 1);
            if (n % 60 == 1) {
                QMKInfo([NSString stringWithFormat:@"消费点 copyCurrentFrame 已旋转 %lld 帧 (%ld°)",
                         n, (long)rot]);
            }
            return r;
        }
        return f;
    } @catch (NSException *e) {
        QMKErr(@"copy-frame", e);
        if (origCopyCurrentFrame) return origCopyCurrentFrame(self, _cmd);
        return NULL;
    }
}

static CVBufferRef QMKGetCurrentFrameHook(id self, SEL _cmd) {
    @try {
        CVBufferRef f = origGetCurrentFrame ? origGetCurrentFrame(self, _cmd) : NULL;
        if (!f) return f;
        NSInteger rot = QMKReadRotation();
        if (rot == 0) return f;
        CVPixelBufferRef r = QMKRotCached(f, rot);
        if (r) return r;
        return f;
    } @catch (NSException *e) {
        QMKErr(@"get-frame", e);
        if (origGetCurrentFrame) return origGetCurrentFrame(self, _cmd);
        return NULL;
    }
}

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
        // 核心消费点: 引擎取帧入口 (copyCurrentFrame/getCurrentFrame) 一并钩住,
        // 返回共享缓存中的旋转帧 — 对齐旧项目"消费端旋转", 防取帧路径绕过存储钩子
        Class lvp2 = NSClassFromString(@"LocalVideoPlayer");
        if (lvp2) {
            Method mC = class_getInstanceMethod(lvp2, @selector(copyCurrentFrame));
            if (mC) {
                IMP oc = method_getImplementation(mC);
                if (oc != (IMP)QMKCopyCurrentFrameHook) {
                    origCopyCurrentFrame = (CVBufferRef (*)(id, SEL))oc;
                    method_setImplementation(mC, (IMP)QMKCopyCurrentFrameHook);
                }
            }
            Method mG = class_getInstanceMethod(lvp2, @selector(getCurrentFrame));
            if (mG) {
                IMP og = method_getImplementation(mG);
                if (og != (IMP)QMKGetCurrentFrameHook) {
                    origGetCurrentFrame = (CVBufferRef (*)(id, SEL))og;
                    method_setImplementation(mG, (IMP)QMKGetCurrentFrameHook);
                }
            }
        }
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

@interface QMKExtraController : NSObject
@property (nonatomic, weak) UIViewController *panelVC;
@property (nonatomic, weak) UIButton *rotBtn;
@end

@implementation QMKExtraController

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

static NSArray *QMKFindAllPanelEntries(void); // 前置声明 (定义在下方)

// ---------------------------------------------------------------
// 面板整面重建 (v9/LV-7): 照源码/补丁 VPBuildPanel 布局与调用逻辑逐行移植,
// 按钮 target 一律 = 面板 VC + 原 SEL, 调用逻辑零改动; 徽章/RTMP tag 与补丁
// 一致 (0x6B62/0x6B65/0x6B66/0x6B67) → 补丁 updateStatusLabel 状态同步直通
// ---------------------------------------------------------------
static UIColor *QMKColorGreen(void) { return [UIColor colorWithRed:0.24 green:1.00 blue:0.62 alpha:1]; }
static UIColor *QMKColorBlue(void)  { return [UIColor colorWithRed:0.24 green:0.48 blue:1.00 alpha:1]; }
static UIColor *QMKColorPink(void)  { return [UIColor colorWithRed:1.00 green:0.24 blue:0.62 alpha:1]; }
static UIColor *QMKColorGold(void)  { return [UIColor colorWithRed:1.00 green:0.77 blue:0.24 alpha:1]; }
static UIColor *QMKColorGlass(void) { return [UIColor colorWithRed:0.063 green:0.102 blue:0.173 alpha:0.5]; }

@interface QMKPressButton : UIButton
@end
@implementation QMKPressButton
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    [UIView animateWithDuration:0.08 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.transform = CGAffineTransformMakeScale(0.9, 0.9);
        self.alpha = 0.85;
    } completion:nil];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [UIView animateWithDuration:0.16 delay:0 usingSpringWithDamping:0.55 initialSpringVelocity:0.8
                        options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.transform = CGAffineTransformIdentity;
        self.alpha = 1.0;
    } completion:nil];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    self.transform = CGAffineTransformIdentity;
    self.alpha = 1.0;
}
@end

static UIImage *QMKRenderIcon(CGSize size, void (^draw)(CGContextRef ctx)) {
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 3;
    UIGraphicsImageRenderer *ren = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    return [ren imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        if (draw) draw(ctx.CGContext);
    }];
}

static UIImage *QMKFilmIcon(UIColor *c) {
    return QMKRenderIcon(CGSizeMake(48, 48), ^(CGContextRef ctx){
        CGContextSetStrokeColorWithColor(ctx, c.CGColor);
        CGContextSetFillColorWithColor(ctx, c.CGColor);
        CGContextSetLineWidth(ctx, 3);
        CGRect body = CGRectMake(5, 9, 38, 26);
        CGPathRef p = CGPathCreateWithRoundedRect(body, 4, 4, NULL);
        CGContextAddPath(ctx, p); CGContextStrokePath(ctx);
        CGPathRelease(p);
        CGContextMoveToPoint(ctx, 19, 9); CGContextAddLineToPoint(ctx, 19, 35); CGContextStrokePath(ctx);
        CGContextMoveToPoint(ctx, 28, 17); CGContextAddLineToPoint(ctx, 40, 23); CGContextAddLineToPoint(ctx, 28, 29);
        CGContextClosePath(ctx); CGContextFillPath(ctx);
    });
}

static UIImage *QMKEyeIcon(UIColor *c) {
    return QMKRenderIcon(CGSizeMake(48, 48), ^(CGContextRef ctx){
        CGContextSetStrokeColorWithColor(ctx, c.CGColor);
        CGContextSetFillColorWithColor(ctx, c.CGColor);
        CGContextSetLineWidth(ctx, 3);
        CGMutablePathRef p = CGPathCreateMutable();
        CGPathMoveToPoint(p, NULL, 3, 24);
        CGPathAddCurveToPoint(p, NULL, 8.5, 15, 14, 10.5, 24, 10.5);
        CGPathAddCurveToPoint(p, NULL, 34, 10.5, 39.5, 15, 45, 24);
        CGPathAddCurveToPoint(p, NULL, 39.5, 33, 34, 37.5, 24, 37.5);
        CGPathAddCurveToPoint(p, NULL, 14, 37.5, 8.5, 33, 3, 24);
        CGPathCloseSubpath(p);
        CGContextAddPath(ctx, p); CGContextStrokePath(ctx);
        CGPathRelease(p);
        CGContextFillEllipseInRect(ctx, CGRectMake(17, 17, 14, 14));
    });
}

static UIImage *QMKRestoreIcon(UIColor *c) {
    return QMKRenderIcon(CGSizeMake(48, 48), ^(CGContextRef ctx){
        CGContextSetStrokeColorWithColor(ctx, c.CGColor);
        CGContextSetLineWidth(ctx, 3);
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextSetLineJoin(ctx, kCGLineJoinRound);
        CGContextAddArc(ctx, 30, 24, 16, 0.35 * M_PI, 1.45 * M_PI, 0);
        CGContextStrokePath(ctx);
        CGContextMoveToPoint(ctx, 14, 8); CGContextAddLineToPoint(ctx, 14, 20); CGContextAddLineToPoint(ctx, 26, 20);
        CGContextStrokePath(ctx);
        CGContextMoveToPoint(ctx, 46, 40); CGContextAddLineToPoint(ctx, 38, 32); CGContextStrokePath(ctx);
    });
}

static UIImage *QMKOrbitIcon(UIColor *c) {
    return QMKRenderIcon(CGSizeMake(48, 48), ^(CGContextRef ctx){
        CGContextSetStrokeColorWithColor(ctx, c.CGColor);
        CGContextSetFillColorWithColor(ctx, c.CGColor);
        CGContextSetLineWidth(ctx, 3);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(15, 15, 18, 18));
        CGContextFillEllipseInRect(ctx, CGRectMake(21, 21, 6, 6));
        CGContextMoveToPoint(ctx, 24, 4);  CGContextAddLineToPoint(ctx, 24, 10);  CGContextStrokePath(ctx);
        CGContextMoveToPoint(ctx, 24, 38); CGContextAddLineToPoint(ctx, 24, 44);  CGContextStrokePath(ctx);
        CGContextMoveToPoint(ctx, 4, 24);  CGContextAddLineToPoint(ctx, 10, 24);  CGContextStrokePath(ctx);
        CGContextMoveToPoint(ctx, 38, 24); CGContextAddLineToPoint(ctx, 44, 24);  CGContextStrokePath(ctx);
    });
}

static UIImage *QMKBookIcon(UIColor *c) {
    return QMKRenderIcon(CGSizeMake(48, 48), ^(CGContextRef ctx){
        CGContextSetStrokeColorWithColor(ctx, c.CGColor);
        CGContextSetLineWidth(ctx, 3);
        CGContextSetLineJoin(ctx, kCGLineJoinRound);
        CGPathRef p = CGPathCreateWithRoundedRect(CGRectMake(8, 8, 22, 30), 4, 4, NULL);
        CGContextAddPath(ctx, p); CGContextStrokePath(ctx); CGPathRelease(p);
        CGContextMoveToPoint(ctx, 30, 8); CGContextAddLineToPoint(ctx, 37, 10);
        CGContextAddLineToPoint(ctx, 40, 12); CGContextAddLineToPoint(ctx, 40, 38);
        CGContextAddLineToPoint(ctx, 30, 38); CGContextStrokePath(ctx);
        CGContextMoveToPoint(ctx, 30, 8); CGContextAddLineToPoint(ctx, 30, 38); CGContextStrokePath(ctx);
    });
}

static UIImage *QMKXIcon(UIColor *c) {
    return QMKRenderIcon(CGSizeMake(48, 48), ^(CGContextRef ctx){
        CGContextSetStrokeColorWithColor(ctx, c.CGColor);
        CGContextSetLineWidth(ctx, 3);
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextMoveToPoint(ctx, 13, 13); CGContextAddLineToPoint(ctx, 35, 35); CGContextStrokePath(ctx);
        CGContextMoveToPoint(ctx, 35, 13); CGContextAddLineToPoint(ctx, 13, 35); CGContextStrokePath(ctx);
    });
}

// ---------------------------------------------------------------
// 附加动作 (运行时注册到 VCamSettingsViewController, 照补丁镜像逻辑)
// ---------------------------------------------------------------
static Ivar QMKIvar(Class cls, const char *name) {
    return class_getInstanceVariable(cls, name);
}
static void QMKMirrorRtmpState(UIViewController *vc, BOOL on, NSString *url) {
    Class cls = object_getClass(vc);
    Ivar swIv = QMKIvar(cls, "_rtmpSwitch");
    Ivar tfIv = QMKIvar(cls, "_rtmpTextField");
    if (swIv) {
        UISwitch *origSw = object_getIvar(vc, swIv);
        if (origSw) {
            origSw.on = on;
            QMKSafeCall(vc, @selector(rtmpSwitchChanged:), origSw);
        }
    }
    if (tfIv && url.length) {
        UITextField *origTf = object_getIvar(vc, tfIv);
        if (origTf) {
            origTf.text = url;
            QMKSafeCall(vc, @selector(saveRtmpUrl), nil);
        }
    }
}

static void qmkMiniSwitchChanged(id self, SEL _cmd, id sender) {
    UISwitch *sw = sender;
    QMKMirrorRtmpState((UIViewController *)self, sw.isOn, nil);
}
static void qmkMiniTfEnd(id self, SEL _cmd, id sender) {
    UITextField *tf = sender;
    if (tf && tf.text.length) QMKMirrorRtmpState((UIViewController *)self, NO, tf.text);
}
static void qmkRtmpSwitchChanged(id self, SEL _cmd, id sender) {
    UISwitch *sw = sender;
    QMKMirrorRtmpState((UIViewController *)self, sw.isOn, nil);
}
static void qmkRotTapped(id self, SEL _cmd, id sender) {
    NSInteger next = QMKCycleRotation();
    UIButton *b = (UIButton *)sender;
    if (b) {
        [b setTitle:[NSString stringWithFormat:@"🔄\n旋转 %ld°", (long)next]
           forState:UIControlStateNormal];
    }
    QMKInfo([NSString stringWithFormat:@"视频旋转 -> %ld°", (long)next]);
}
static void qmkColorTapped(id self, SEL _cmd, id sender) {
    @try {
        Class enh = NSClassFromString(@"QMEnhancerView");
        if (!enh) { QMKWarn(@"彩色注入: 增强模块未加载"); return; }
        BOOL on = NO;
        if ([enh respondsToSelector:@selector(isColorMappingEnabled)]) {
            NSNumber *n = QMKSafeCall(enh, @selector(isColorMappingEnabled), nil);
            on = [n boolValue];
        }
        if (on) {
            // 已启用 → 关闭彩色映射 (写增强模块共享设置)
            if ([enh respondsToSelector:@selector(sharedSettings)] &&
                [enh respondsToSelector:@selector(saveSharedSettings:)]) {
                NSDictionary *cur = QMKSafeCall(enh, @selector(sharedSettings), nil);
                NSMutableDictionary *s = [NSMutableDictionary dictionaryWithDictionary:cur ?: @{}];
                s[@"colorMappingEnabled"] = @NO;
                QMKSafeCall(enh, @selector(saveSharedSettings:), s);
                QMKInfo(@"彩色注入: 已关闭");
            }
        } else {
            // 未启用 → 展开增强面板并进入屏幕取色
            id inst = QMKSafeCall(enh, @selector(sharedInstance), nil);
            if (inst) {
                if ([inst respondsToSelector:@selector(togglePanel)]) {
                    QMKSafeCall(inst, @selector(togglePanel), nil);
                }
                if ([inst respondsToSelector:@selector(enterColorPickMode)]) {
                    QMKSafeCall(inst, @selector(enterColorPickMode), nil);
                }
                QMKInfo(@"彩色注入: 进入屏幕取色 (增强面板已展开)");
            }
        }
    } @catch (NSException *e) { QMKErr(@"color-inject", e); }
}

// ---------------------------------------------------------------
// 整面重建 (照 VPBuildPanel 布局逐行移植 + 旋转/彩色新键)
// ---------------------------------------------------------------
static void QMKBuildPanel(UIViewController *vc) {
    UIView *root = vc.view;
    if (!root) return;
    CGFloat W = root.bounds.size.width;
    CGFloat H = root.bounds.size.height;
    if (W < 100 || H < 100) return;
    CGFloat K = MIN(W / 390.0, H / 844.0);

    // 全量清除: 移除补丁产物与旧重建 (面板 UI 全部由我方重建)
    for (UIView *v in [root.subviews copy]) [v removeFromSuperview];
    root.tag = QMK_TAG_OWN;

    // --- 标题胶囊 ---
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake((W - 200 * K) / 2, 46 * K, 200 * K, 30 * K)];
    title.text = @"控制终端UI面板";
    title.font = [UIFont boldSystemFontOfSize:13 * K];
    title.textColor = [UIColor whiteColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.layer.cornerRadius = 15 * K;
    title.layer.borderWidth = 1.5;
    title.layer.borderColor = QMKColorGreen().CGColor;
    title.backgroundColor = [UIColor colorWithRed:0.24 green:1.0 blue:0.62 alpha:0.15];
    [root addSubview:title];

    // --- 舱间光柱 ---
    UIView *beam = [[UIView alloc] initWithFrame:CGRectMake(W / 2 + 19 * K, 172 * K, 6 * K, 118 * K)];
    beam.layer.cornerRadius = 3 * K;
    beam.backgroundColor = QMKColorGreen();
    beam.alpha = 0.85;
    [root addSubview:beam];
    CABasicAnimation *bp = [CABasicAnimation animationWithKeyPath:@"opacity"];
    bp.fromValue = @0.85; bp.toValue = @0.3;
    bp.duration = 1.4; bp.autoreverses = YES; bp.repeatCount = INFINITY;
    [beam.layer addAnimation:bp forKey:@"qmkBeam"];

    // --- 左主控舱 (2x2 原图标键 + 旋转/彩色 + 迷你RTMP) ---
    UIView *podL = [[UIView alloc] initWithFrame:CGRectMake(12 * K, 88 * K, 168 * K, 330 * K)];
    podL.layer.cornerRadius = 22 * K;
    podL.layer.borderWidth = 1.5;
    podL.layer.borderColor = QMKColorGreen().CGColor;
    podL.backgroundColor = QMKColorGlass();
    podL.layer.shadowColor = [UIColor blackColor].CGColor;
    podL.layer.shadowOpacity = 0.4f;
    podL.layer.shadowOffset = CGSizeMake(0, 12 * K);
    podL.layer.shadowRadius = 32 * K;
    UIVisualEffectView *blurL = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    blurL.frame = podL.bounds;
    blurL.layer.cornerRadius = 22 * K;
    blurL.layer.masksToBounds = YES;
    [podL addSubview:blurL];
    [root addSubview:podL];

    UILabel *podTitle = [[UILabel alloc] initWithFrame:CGRectMake(14 * K, 12 * K, 100 * K, 12 * K)];
    podTitle.text = @"主控舱";
    podTitle.font = [UIFont boldSystemFontOfSize:9 * K];
    podTitle.textColor = QMKColorGreen();
    [podL addSubview:podTitle];

    // 2x2 原图标键 (回调 = 原 SEL, 调用逻辑零改动)
    CGFloat bw = (168 * K - 28 * K - 10 * K) / 2;
    struct { SEL action; UIColor *color; UIImage *(*icon)(UIColor *); } keys[4] = {
        { @selector(switchVideoTapped),        QMKColorGreen(), QMKFilmIcon },
        { @selector(toggleReplacementTapped),  QMKColorBlue(),  QMKEyeIcon },
        { @selector(restoreCameraTapped),      QMKColorPink(),  QMKRestoreIcon },
        { @selector(toggleFloatingBallTapped), QMKColorGold(),  QMKOrbitIcon },
    };
    for (int i = 0; i < 4; i++) {
        int col = i % 2, row = i / 2;
        CGRect f = CGRectMake(14 * K + col * (bw + 10 * K), 30 * K + row * (74 * K + 12 * K), bw, 74 * K);
        QMKPressButton *b = [QMKPressButton buttonWithType:UIButtonTypeCustom];
        b.frame = f;
        b.tag = (NSInteger[]){QMK_TAG_MED, QMK_TAG_REP, QMK_TAG_RST, QMK_TAG_BAL}[i];
        b.layer.cornerRadius = 16 * K;
        b.backgroundColor = keys[i].color;
        b.layer.borderWidth = 1.5;
        b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
        [b setImage:keys[i].icon([UIColor whiteColor]) forState:UIControlStateNormal];
        b.imageView.contentMode = UIViewContentModeScaleAspectFit;
        b.imageEdgeInsets = UIEdgeInsetsMake(11 * K, 11 * K, 11 * K, 11 * K);
        [b addTarget:vc action:keys[i].action forControlEvents:UIControlEventTouchUpInside];
        [podL addSubview:b];
    }

    // 新键行: 视频旋转 / 彩色注入
    struct { SEL action; UIColor *color; NSInteger tag; NSString *title; } extra[2] = {
        { @selector(qmkRotTapped:),   [UIColor colorWithRed:0.31 green:0.86 blue:1.0 alpha:1.0], QMK_TAG_ROT,
          [NSString stringWithFormat:@"🔄\n旋转 %ld°", (long)QMKReadRotation()] },
        { @selector(qmkColorTapped:), [UIColor colorWithRed:0.71 green:0.47 blue:1.0 alpha:1.0], QMK_TAG_COL,
          @"🎨\n彩色注入" },
    };
    for (int i = 0; i < 2; i++) {
        CGRect f = CGRectMake(14 * K + i * (bw + 10 * K), 212 * K, bw, 52 * K);
        QMKPressButton *b = [QMKPressButton buttonWithType:UIButtonTypeCustom];
        b.frame = f;
        b.tag = extra[i].tag;
        b.layer.cornerRadius = 14 * K;
        b.backgroundColor = extra[i].color;
        b.layer.borderWidth = 1.5;
        b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
        [b setTitle:extra[i].title forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:10 * K];
        b.titleLabel.numberOfLines = 2;
        b.titleLabel.textAlignment = NSTextAlignmentCenter;
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [b addTarget:vc action:extra[i].action forControlEvents:UIControlEventTouchUpInside];
        [podL addSubview:b];
        if (b.tag == QMK_TAG_ROT) QMKController().rotBtn = b;
    }

    // 迷你 RTMP: 开关 + 输入 (镜像到原控件后走原方法)
    UISwitch *miniSw = [[UISwitch alloc] initWithFrame:CGRectMake(14 * K, 276 * K, 51 * K, 31 * K)];
    miniSw.tag = VP_TAG_MINISW;
    miniSw.onTintColor = QMKColorGreen();
    miniSw.transform = CGAffineTransformMakeScale(K, K);
    [miniSw addTarget:vc action:@selector(vpMiniSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [podL addSubview:miniSw];

    UITextField *miniTf = [[UITextField alloc] initWithFrame:CGRectMake(72 * K, 280 * K, 84 * K, 22 * K)];
    miniTf.tag = VP_TAG_MINITF;
    miniTf.font = [UIFont systemFontOfSize:8 * K];
    miniTf.textColor = [UIColor colorWithRed:0.81 green:0.88 blue:1 alpha:1];
    miniTf.backgroundColor = [UIColor colorWithRed:0.24 green:0.48 blue:1 alpha:0.15];
    miniTf.layer.cornerRadius = 6 * K;
    miniTf.layer.borderWidth = 1;
    miniTf.layer.borderColor = QMKColorBlue().CGColor;
    miniTf.keyboardType = UIKeyboardTypeURL;
    miniTf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    miniTf.returnKeyType = UIReturnKeyDone;
    miniTf.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"rtmp://..."
        attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.35]}];
    [miniTf addTarget:vc action:@selector(vpMiniTfEnd:) forControlEvents:UIControlEventEditingDidEnd];
    [miniTf addTarget:vc action:@selector(vpMiniTfEnd:) forControlEvents:UIControlEventEditingDidEndOnExit];
    [podL addSubview:miniTf];

    // --- 右状态舱 ---
    UIView *podR = [[UIView alloc] initWithFrame:CGRectMake(W - 12 * K - 124 * K, 88 * K, 124 * K, 330 * K)];
    podR.layer.cornerRadius = 22 * K;
    podR.layer.borderWidth = 1.5;
    podR.layer.borderColor = QMKColorBlue().CGColor;
    podR.backgroundColor = QMKColorGlass();
    podR.layer.shadowColor = [UIColor blackColor].CGColor;
    podR.layer.shadowOpacity = 0.4f;
    podR.layer.shadowOffset = CGSizeMake(0, 12 * K);
    podR.layer.shadowRadius = 32 * K;
    UIVisualEffectView *blurR = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    blurR.frame = podR.bounds;
    blurR.layer.cornerRadius = 22 * K;
    blurR.layer.masksToBounds = YES;
    [podR addSubview:blurR];
    [root addSubview:podR];

    UILabel *podTitleR = [[UILabel alloc] initWithFrame:CGRectMake(0, 14 * K, 124 * K, 12 * K)];
    podTitleR.text = @"状态";
    podTitleR.font = [UIFont boldSystemFontOfSize:9 * K];
    podTitleR.textColor = QMKColorBlue();
    podTitleR.textAlignment = NSTextAlignmentCenter;
    [podR addSubview:podTitleR];

    UIView *eye = [[UIView alloc] initWithFrame:CGRectMake((124 * K - 68 * K) / 2, 32 * K, 68 * K, 68 * K)];
    eye.layer.cornerRadius = 34 * K;
    eye.backgroundColor = QMKColorBlue();
    eye.layer.borderWidth = 2;
    eye.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.7].CGColor;
    eye.layer.shadowColor = QMKColorBlue().CGColor;
    eye.layer.shadowOpacity = 0.9f;
    eye.layer.shadowRadius = 16 * K;
    [podR addSubview:eye];
    UIImageView *eyeIv = [[UIImageView alloc] initWithFrame:CGRectInset(eye.bounds, 14 * K, 14 * K)];
    eyeIv.image = QMKEyeIcon([UIColor whiteColor]);
    eyeIv.contentMode = UIViewContentModeScaleAspectFit;
    [eye addSubview:eyeIv];

    UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake((124 * K - 52 * K) / 2, 108 * K, 52 * K, 18 * K)];
    badge.tag = VP_TAG_BADGE;
    badge.font = [UIFont boldSystemFontOfSize:10 * K];
    badge.textColor = [UIColor colorWithWhite:0.06 alpha:1];
    badge.textAlignment = NSTextAlignmentCenter;
    badge.layer.cornerRadius = 9 * K;
    badge.layer.masksToBounds = YES;
    [podR addSubview:badge];

    UILabel *rtmpLab = [[UILabel alloc] initWithFrame:CGRectMake(0, 134 * K, 124 * K, 10 * K)];
    rtmpLab.text = @"RTMP";
    rtmpLab.font = [UIFont systemFontOfSize:8 * K];
    rtmpLab.textColor = QMKColorGreen();
    rtmpLab.textAlignment = NSTextAlignmentCenter;
    [podR addSubview:rtmpLab];
    UISwitch *rtmpSw = [[UISwitch alloc] initWithFrame:CGRectMake((124 * K - 51 * K) / 2, 148 * K, 51 * K, 31 * K)];
    rtmpSw.tag = VP_TAG_RTMPSW;
    rtmpSw.onTintColor = QMKColorBlue();
    rtmpSw.transform = CGAffineTransformMakeScale(K, K);
    [rtmpSw addTarget:vc action:@selector(vpRtmpSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [podR addSubview:rtmpSw];

    // 日志诊断键 (弹窗 + 复制日志 + 清空, 不依赖补丁任何逻辑)
    QMKPressButton *logBtn = [QMKPressButton buttonWithType:UIButtonTypeCustom];
    logBtn.tag = QMK_TAG_LOG;
    logBtn.frame = CGRectMake(14 * K, 202 * K, 96 * K, 32 * K);
    logBtn.layer.cornerRadius = 10 * K;
    logBtn.backgroundColor = [UIColor colorWithRed:1.0 green:0.36 blue:0.36 alpha:1.0];
    logBtn.layer.borderWidth = 1.5;
    logBtn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
    [logBtn setTitle:@"📋 错误日志" forState:UIControlStateNormal];
    logBtn.titleLabel.font = [UIFont boldSystemFontOfSize:9 * K];
    [logBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [logBtn addTarget:vc action:@selector(qmkLogTapped:) forControlEvents:UIControlEventTouchUpInside];
    [podR addSubview:logBtn];

    // --- 底部双键: 教程 / 关闭 ---
    CGFloat footY = 452 * K;
    CGFloat footH = 44 * K;
    CGFloat footW = (W - 24 * K - 12 * K) / 2;
    QMKPressButton *tut = [QMKPressButton buttonWithType:UIButtonTypeCustom];
    tut.tag = QMK_TAG_TUT;
    tut.frame = CGRectMake(12 * K, footY, footW, footH);
    tut.layer.cornerRadius = 16 * K;
    tut.backgroundColor = QMKColorBlue();
    tut.layer.borderWidth = 1.5;
    tut.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
    [tut setImage:QMKBookIcon([UIColor whiteColor]) forState:UIControlStateNormal];
    tut.imageEdgeInsets = UIEdgeInsetsMake(11 * K, 11 * K, 11 * K, 11 * K);
    [tut addTarget:vc action:@selector(openTutorial) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:tut];

    QMKPressButton *close = [QMKPressButton buttonWithType:UIButtonTypeCustom];
    close.tag = QMK_TAG_CLS;
    close.frame = CGRectMake(12 * K + footW + 12 * K, footY, footW, footH);
    close.layer.cornerRadius = 16 * K;
    close.backgroundColor = QMKColorPink();
    close.layer.borderWidth = 1.5;
    close.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
    [close setImage:QMKXIcon([UIColor whiteColor]) forState:UIControlStateNormal];
    close.imageEdgeInsets = UIEdgeInsetsMake(11 * K, 11 * K, 11 * K, 11 * K);
    [close addTarget:vc action:@selector(dismissPanel) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:close];

    // 初始徽章同步 (原逻辑 0.1s 后由 updateStatusLabel 更新)
    QMKInfo(@"面板已整面重建 (原功能键 + 旋转 + 彩色注入)");
}

static void qmkLogTapped(id self, SEL _cmd, id sender) {
    [QMKController() showLogAlert];
}

// ---------------------------------------------------------------
// 旧面板实例销毁 (残留根治): 新实例 viewDidLoad 时机同步执行 —
// 旧实例窗口不回收正是"短暂停留后跳到新面板"的根因; 这里改为:
// view 整面摘除 + 独立面板窗隐藏 (悬浮球同窗时只摘面板视图)
// ---------------------------------------------------------------
static void QMKDestroyOtherPanels(id keep) {
    @try {
        NSArray *entries = QMKFindAllPanelEntries();
        BOOL any = NO;
        for (NSDictionary *e in entries) {
            if (![e[@"kind"] isEqualToString:@"vc"]) continue;
            UIViewController *vc = e[@"vc"];
            if (!vc || vc == keep) continue;
            UIWindow *w = e[@"win"];
            if (!w || w.hidden) continue;
            UIView *v = e[@"view"];
            if (!v || v.hidden) continue;
            @try { if (vc.presentingViewController) [vc dismissViewControllerAnimated:NO completion:nil]; }
            @catch (NSException *ex) {}
            [v removeFromSuperview];
            if (![w viewWithTag:VP_TAG_BALLIMG]) w.hidden = YES;
            any = YES;
        }
        if (any) QMKInfo(@"旧面板实例已销毁 (残留根治)");
    } @catch (NSException *e) { QMKErr(@"destroy-panels", e); }
}

// ---------------------------------------------------------------
// 面板接管: viewDidLoad 挂载 (整面重建 + 旧实例销毁 + 兜底重建)
// 此段逻辑移植自旧项目「UI源码界面虚浮窗功能 无汉字图标」的
// 面板重建/生命周期语义, 已适配当前框架 (千面 VCamSettingsViewController
// + VCamUIPatch 补丁运行时体系, UIKit 插件式)
// ---------------------------------------------------------------
static void (*origSettingsViewDidLoad)(id, SEL) = NULL;
static void QMKSettingsViewDidLoad(id self, SEL _cmd) {
    @try {
        if (origSettingsViewDidLoad) origSettingsViewDidLoad(self, _cmd);
        // 旧实例同步销毁: 新面板创建瞬间, 屏幕上的旧面板立即消失 (无短暂停留)
        QMKDestroyOtherPanels(self);
        // 整面重建 (照源码 VPBuildPanel 布局与调用逻辑)
        QMKBuildPanel(self);
        // 兜底重建: 覆盖 swizzle 顺序差异 (若补丁 VPBuildPanel 在链内后执行)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try { QMKBuildPanel(self); } @catch (NSException *e) {}
        });
    } @catch (NSException *e) {
        QMKErr(@"settings-viewdidload", e);
        if (origSettingsViewDidLoad) origSettingsViewDidLoad(self, _cmd);
    }
}

static BOOL QMKPanelHooked = NO;
static void QMKInstallPanelHooks(void) {
    if (QMKPanelHooked) return;
    @try {
        Class settings = NSClassFromString(@"VCamSettingsViewController");
        if (!settings) return;
        Method m = class_getInstanceMethod(settings, @selector(viewDidLoad));
        if (!m) return;
        IMP orig = method_getImplementation(m);
        if (orig == (IMP)QMKSettingsViewDidLoad) { QMKPanelHooked = YES; return; }
        origSettingsViewDidLoad = (void (*)(id, SEL))orig;
        method_setImplementation(m, (IMP)QMKSettingsViewDidLoad);
        // 附加动作 (幂等; 补丁已加则跳过)
        class_addMethod(settings, @selector(vpMiniSwitchChanged:), (IMP)qmkMiniSwitchChanged, "v@:@");
        class_addMethod(settings, @selector(vpMiniTfEnd:), (IMP)qmkMiniTfEnd, "v@:@");
        class_addMethod(settings, @selector(vpRtmpSwitchChanged:), (IMP)qmkRtmpSwitchChanged, "v@:@");
        class_addMethod(settings, @selector(qmkRotTapped:), (IMP)qmkRotTapped, "v@:@");
        class_addMethod(settings, @selector(qmkColorTapped:), (IMP)qmkColorTapped, "v@:@");
        class_addMethod(settings, @selector(qmkLogTapped:), (IMP)qmkLogTapped, "v@:@");
        QMKPanelHooked = YES;
        QMKInfo(@"面板接管: viewDidLoad 已挂载 (整面重建 + 旧实例销毁)");
    } @catch (NSException *e) { QMKErr(@"panel-install", e); }
}

static void QMKSchedulePanelInstall(void) {
    QMKInstallPanelHooks();
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(src, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                              1 * NSEC_PER_SEC, NSEC_PER_SEC);
    __block int tries = 0;
    dispatch_source_set_event_handler(src, ^{
        @autoreleasepool {
            @try {
                if (QMKPanelHooked) { dispatch_source_cancel(src); return; }
                if (++tries >= 60) {
                    QMKLogLine(@"ERR", nil, @"面板接管 60s 内未装成: 无 VCamSettingsViewController/viewDidLoad");
                    dispatch_source_cancel(src);
                    return;
                }
                QMKInstallPanelHooks();
            } @catch (NSException *e) {}
        }
    });
    dispatch_resume(src);
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
        if (primaryView) {
            // A4 兜底: 主面板根无我方构建标记 -> 重建 (覆盖任何未经 viewDidLoad 的布局异常)
            if (primaryView.tag != QMK_TAG_OWN) {
                QMKBuildPanel(primary);
            }
            // 多实例根治: 其余可见 vc 实例一律销毁 (旧实例窗口不回收 → 残留)
            QMKDestroyOtherPanels(primary);
            QMKController().panelVC = primary;
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
                QMKInfo(@"VCamExtraKeys LV-7 UI 层已注入 (SpringBoard)");
                QMKMigrateLegacyRotation();
                QMKSchedulePanelInstall();
                dispatch_async(dispatch_get_main_queue(), ^{
                    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
                        QMKTick();
                    }];
                });
                return;
            }
            QMKInfo([NSString stringWithFormat:@"VCamExtraKeys LV-7 帧层已注入 (%@)", QMKProcName(p)]);
            QMKScheduleFrameInstall();
        } @catch (NSException *e) { QMKErr(@"init", e); }
    }
}