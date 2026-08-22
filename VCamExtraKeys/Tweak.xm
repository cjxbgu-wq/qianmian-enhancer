// VCamProMax v1.0 - 统一功能舱 v3 (vcam 核心/UI补丁/增强模块 零改动)
// 面板层 (整面重建模式, 根治旧面板残留):
//   A1) 接管 VCamSettingsViewController viewDidLoad: 原逻辑先跑, 然后同步销毁
//       全部旧可见面板实例 (view 摘除 + 独立面板窗隐藏), 最后整面重建新面板 —
//       旧实例在"新面板出现瞬间"即销毁, 不再有"短暂停留后跳到新面板"
//   A2) VPMBuildPanel 照源码/补丁 VPBuildPanel 布局与调用逻辑逐行移植:
//       标题胶囊/左主控舱(2x2 原图标键: 媒体/替换/恢复/悬浮球)/迷你RTMP镜像
//       (开关+输入)/右状态舱(眼瞳+徽章+RTMP开关)/底部教程+关闭 — 按钮 target
//       一律 = 面板 VC + 原 SEL (switchVideoTapped 等), 调用逻辑零改动;
//       徽章/RTMP tag 与补丁一致 (0x6B62/0x6B65/0x6B66/0x6B67) → 补丁的
//       updateStatusLabel 状态同步直接作用于我方 UI
//   A3) 新增键: 视频旋转 (vpmRotTapped: -> VPMCycleRotation) +
//       彩色注入 (vpmColorTapped: -> QMEnhancerView 屏幕取色映射 toggle)
//   A4) tick 兜底: 主面板根无构建标记(0x6E50) -> 重建; 非主可见实例 -> 销毁
// 旋转层 (逻辑移植自旧项目 UI源码界面虚浮窗功能 vcam_friend_js.js draw):
//   B1) 方向旋转 = canvas 语义翻译 (JS Canvas -> CoreGraphics): buffer 尺寸/指针
//       固定不变, translate(中心)+rotate(rad)+有效区 ew/eh(90°/270°互换)
//       + aspectFit 完整显示 + 黑底; 渲染由 CoreGraphics SIMD blit 执行,
//       每帧仅 1 次快照 memcpy + 1 次 draw, 零逐帧大分配
//   B2) 消费点全覆盖: updateCurrentBuffer: 主旋转点; copyCurrentFrame/getCurrentFrame
//       透传计数 (定位引擎渲染路径)
//   B3) 首帧日志含格式; 每60帧报数; 10s看门狗; 90s重试
// C) 错误日志: /tmp/vcampro_max.log, 进程注入/类找到/钩子/帧流入,
//    弹窗+复制日志(全文)+清空
// E) 方向旋转修复: 像素旋转 (CoreImage/CPU/就地) 全部废弃 — 卡顿/发热/膨胀/崩溃根因;
//     现为 CoreGraphics canvas 语义方向旋转 (旧项目 draw() 逻辑翻译), 零逐像素循环
// F) 体积优化: 融合 deb 数据成员 data.tar.xz (xz 压缩, 安装更快)
// D) 输出 LV-7.deb
#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <string.h>
#import <stdlib.h>
#import <math.h>
#import <objc/runtime.h>

static NSString *const VPMSharedSettingsPath = @"/tmp/qianmian_enhancer_settings.plist";
static NSString *const VPMErrorLogPath       = @"/tmp/vcampro_max.log";
static NSString *const VPMRotationKey        = @"videoRotationLV";
static NSString *const VPMLegacyRotationKey  = @"videoRotation";
static NSString *const VPMScaleKey           = @"videoScaleLV";
static NSString *const VPMPointFile          = @"/tmp/vpm_pick_point.txt";
static NSString *const VPMResultFile         = @"/tmp/vpm_pick_color.txt";

static const NSInteger VPM_TAG_ROT  = 0x6E31;
static const NSInteger VPM_TAG_LOG  = 0x6E33;
static const NSInteger VPM_TAG_MED  = 0x6E34;
static const NSInteger VPM_TAG_REP  = 0x6E35;
static const NSInteger VPM_TAG_RST  = 0x6E36;
static const NSInteger VPM_TAG_BAL  = 0x6E37;
static const NSInteger VPM_TAG_TUT  = 0x6E3B;
static const NSInteger VPM_TAG_CLS  = 0x6E3C;
static const NSInteger VPM_TAG_COL  = 0x6E3D; // 彩色注入
static const NSInteger VPM_TAG_SCL  = 0x6E3E; // 视频缩放
static const NSInteger VPM_TAG_OWN  = 0x6E50; // 我方整面重建的构建标记 (根视图)

static const NSInteger VP_TAG_BADGE    = 0x6B62;
static const NSInteger VP_TAG_BALLIMG  = 0x6B63;
static const NSInteger VP_TAG_MINISW   = 0x6B65;
static const NSInteger VP_TAG_MINITF   = 0x6B66;
static const NSInteger VP_TAG_RTMPSW   = 0x6B67;

typedef NS_ENUM(NSInteger, VPMProcess) {
    VPMProcessOther = 0,
    VPMProcessSpringBoard,
    VPMProcessMediaserverd,
    VPMProcessLskdd,
};

static VPMProcess VPMProc(void) {
    @try {
        NSString *pn = [[NSProcessInfo processInfo] processName];
        if ([pn isEqualToString:@"SpringBoard"]) return VPMProcessSpringBoard;
        if ([pn isEqualToString:@"mediaserverd"]) return VPMProcessMediaserverd;
        if ([pn isEqualToString:@"lskdd"]) return VPMProcessLskdd;
    } @catch (NSException *e) {}
    return VPMProcessOther;
}

static NSString *VPMProcName(VPMProcess p) {
    switch (p) {
        case VPMProcessSpringBoard:  return @"SpringBoard";
        case VPMProcessMediaserverd: return @"mediaserverd";
        case VPMProcessLskdd:        return @"lskdd";
        default:                     return @"other";
    }
}

static void VPMMarkInjected(VPMProcess p) {
    @try {
        NSString *path = [NSString stringWithFormat:@"/tmp/vpm_extrakeys_%@.txt",
                          [VPMProcName(p) lowercaseString]];
        [@"ok" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) {}
}

static BOOL VPMMarkExists(NSString *name) {
    @try {
        return [[NSFileManager defaultManager] fileExistsAtPath:
                [NSString stringWithFormat:@"/tmp/qm_%@.txt", name]];
    } @catch (NSException *e) {}
    return NO;
}

static void VPMLogLine(NSString *level, NSString *tag, NSString *detail) {
    @try {
        NSString *ts = [NSDateFormatter localizedStringFromDate:[NSDate date]
                        dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle];
        NSString *line = [NSString stringWithFormat:@"%@ [%@] [%@] %@\n", ts, level,
                          tag ?: VPMProcName(VPMProc()), detail ?: @""];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:VPMErrorLogPath]) {
            [fm createFileAtPath:VPMErrorLogPath contents:nil attributes:nil];
        }
        // [缓存优化] 日志轮转: 超 256KB 截留后半, 防无限膨胀产生缓存垃圾
        NSDictionary *attr = [fm attributesOfItemAtPath:VPMErrorLogPath error:nil];
        unsigned long long sz = attr ? [attr fileSize] : 0;
        if (sz > 256 * 1024) {
            NSData *all = [NSData dataWithContentsOfFile:VPMErrorLogPath];
            if (all.length > 128 * 1024)
                [fm createFileAtPath:VPMErrorLogPath
                            contents:[all subdataWithRange:NSMakeRange(all.length - 128 * 1024, 128 * 1024)]
                          attributes:nil];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:VPMErrorLogPath];
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) {}
}

static void VPMInfo(NSString *msg) { VPMLogLine(@"INFO", nil, msg); }
static void VPMWarn(NSString *msg) { VPMLogLine(@"WARN", nil, msg); }
static void VPMErr(NSString *tag, NSException *e) {
    VPMLogLine(@"ERR", tag, [NSString stringWithFormat:@"%@: %@", e.name, e.reason]);
}

static NSString *VPMFullLog(void) {
    @try {
        NSString *all = [NSString stringWithContentsOfFile:VPMErrorLogPath
                                                  encoding:NSUTF8StringEncoding error:nil];
        return all ?: @"(日志文件为空)";
    } @catch (NSException *e) {}
    return @"(日志读取失败)";
}

static NSDictionary *VPMReadSettings(void) {
    @try {
        NSDictionary *s = [NSDictionary dictionaryWithContentsOfFile:VPMSharedSettingsPath];
        return s ?: @{};
    } @catch (NSException *e) {}
    return @{};
}

static void VPMWriteSettings(NSDictionary *settings) {
    @try { [settings writeToFile:VPMSharedSettingsPath atomically:YES]; }
    @catch (NSException *e) {}
}

static NSInteger VPMReadRotation(void) {
    NSInteger r = [[VPMReadSettings() objectForKey:VPMRotationKey] integerValue];
    return (r == 90 || r == 180 || r == 270) ? r : 0;
}

// [视频缩放补丁] 渲染层等比缩放 (CoreGraphics 变换), 不改像素数据/格式/帧率.
// 档位循环: 1.0 -> 1.5 -> 2.0 (放大) -> 0.8 (缩小) -> 1.0
static const CGFloat VPMScaleSteps[4] = {1.0f, 1.5f, 2.0f, 0.8f};
static CGFloat VPMReadScale(void) {
    CGFloat s = [[VPMReadSettings() objectForKey:VPMScaleKey] floatValue];
    return (s > 0.05f && s < 20.0f) ? s : 1.0f;
}
static NSInteger VPMScaleIndex(void) {
    CGFloat s = VPMReadScale();
    for (NSInteger i = 0; i < 4; i++)
        if (fabs(VPMScaleSteps[i] - s) < 0.01f) return i;
    return 0;
}
static CGFloat VPMCycleScale(void) {
    NSMutableDictionary *s = [NSMutableDictionary dictionaryWithDictionary:VPMReadSettings()];
    NSInteger next = (VPMScaleIndex() + 1) % 4;
    [s setObject:@(VPMScaleSteps[next]) forKey:VPMScaleKey];
    VPMWriteSettings(s);
    VPMInfo([NSString stringWithFormat:@"视频缩放 -> %.2fx", VPMScaleSteps[next]]);
    return VPMScaleSteps[next];
}

static NSInteger VPMCycleRotation(void) {
    NSMutableDictionary *s = [NSMutableDictionary dictionaryWithDictionary:VPMReadSettings()];
    NSInteger next = (VPMReadRotation() + 90) % 360;
    [s setObject:@(next) forKey:VPMRotationKey];
    [s setObject:@(0) forKey:VPMLegacyRotationKey];
    VPMWriteSettings(s);
    VPMInfo([NSString stringWithFormat:@"视频旋转: -> %ld°", (long)next]);
    return next;
}

static void VPMMigrateLegacyRotation(void) {
    @try {
        NSDictionary *s = VPMReadSettings();
        NSInteger legacy = [[s objectForKey:VPMLegacyRotationKey] integerValue];
        NSInteger cur = [[s objectForKey:VPMRotationKey] integerValue];
        if (legacy != 0 && cur == 0) {
            NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:s];
            [m setObject:@((legacy == 90 || legacy == 180 || legacy == 270) ? legacy : 0)
                  forKey:VPMRotationKey];
            [m setObject:@(0) forKey:VPMLegacyRotationKey];
            VPMWriteSettings(m);
            VPMInfo(@"旧旋转键已迁移至 videoRotationLV");
        }
    } @catch (NSException *e) {}
}

static id VPMSafeCall(id target, SEL sel, id arg) {
    if (!target || !sel || ![target respondsToSelector:sel]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return arg ? [target performSelector:sel withObject:arg] : [target performSelector:sel];
#pragma clang diagnostic pop
}

// [方向旋转补丁] 旧项目 (vcam_friend_js.js draw) 的"视频方向旋转"语义:
//   canvas 尺寸固定 + ctx.translate(中心)+ctx.rotate(rad) + 有效区 ew/eh(90°/270°互换)
//   + aspectFit 完整显示 + 黑底 — 视频与 buffer 不变, 仅方向呈现变化.
//   已翻译为新框架原生等价物 CoreGraphics (iOS 的 canvas), 以补丁方式在
//   VCamExtraKeys 帧钩子层运行, 项目源码零更改.

static void (*origUpdateCurrentBuffer)(id, SEL, CVBufferRef) = NULL;
static CVBufferRef (*origCopyCurrentFrame)(id, SEL) = NULL;
static CVBufferRef (*origGetCurrentFrame)(id, SEL) = NULL;
static volatile int64_t VPMFramesSeen = 0;      // update 首帧计数 (帧钩子是否流入)
static volatile int64_t VPMFramesUpdate = 0;    // updateCurrentBuffer 调用次数
static volatile int64_t VPMFramesCopy = 0;      // copyCurrentFrame 调用次数
static volatile int64_t VPMFramesGet = 0;       // getCurrentFrame 调用次数

// [方向旋转补丁] 此段逻辑移植自旧项目 UI源码界面虚浮窗功能 的 draw():
//   JS: ctx.translate(cw/2,ch/2) + ctx.rotate(rad) + 有效区 ew/eh(90°/270°互换)
//       + aspectFit(s=min) 完整显示 + 黑底 — 已适配当前框架:
//       JS Canvas -> iOS CoreGraphics (CGBitmapContext 即 iOS 原生 canvas).
//   关键约束: ① 输出 buffer 尺寸/指针固定不变 (视频未改变, 仅方向呈现变化);
//             ② 渲染由 CoreGraphics SIMD blit 执行 (禁 CPU 逐像素变换),
//                每帧仅 1 次快照 memcpy + 1 次 draw, 零逐帧大分配 (防卡顿/发热/膨胀);
//             ③ 就地写入引擎持有的同一 buffer (实测仅此方式生效).
static uint8_t *gRotSnap = NULL;     // 源帧快照 (复用, 防每帧 malloc)
static size_t gRotSnapCap = 0;
static void VPMRotateDirectionInPlace(CVBufferRef buf, NSInteger rot, CGFloat scale) {
    if (!buf || (rot == 0 && fabs(scale - 1.0f) < 0.01f)) return;
    @try {
        size_t w = CVPixelBufferGetWidth(buf);
        size_t h = CVPixelBufferGetHeight(buf);
        if (w == 0 || h == 0) return;
        if (CVPixelBufferGetPixelFormatType(buf) != kCVPixelFormatType_32BGRA) return;
        CVPixelBufferLockBaseAddress(buf, 0);
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(buf);
        size_t bpr = CVPixelBufferGetBytesPerRow(buf);
        if (!base || bpr == 0) { CVPixelBufferUnlockBaseAddress(buf, 0); return; }

        // ① 快照源帧 (单次大 memcpy, NEON 级别 ~0.5ms; 缓冲复用零分配)
        size_t need = h * bpr;
        static dispatch_once_t lockOnce;
        static id rotLock = nil;
        dispatch_once(&lockOnce, ^{ rotLock = [NSObject new]; });
        @synchronized (rotLock) {
            if (gRotSnapCap < need) {
                free(gRotSnap);
                gRotSnap = (uint8_t *)malloc(need);
                gRotSnapCap = gRotSnap ? need : 0;
            }
            if (!gRotSnap) { CVPixelBufferUnlockBaseAddress(buf, 0); return; }
            memcpy(gRotSnap, base, need);

            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            // ② 源 CGImage: 零拷贝引用快照 (BGRA = LE ARGB premultiplied-first)
            CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, gRotSnap, need, NULL);
            CGImageRef img = CGImageCreate((size_t)w, (size_t)h, 8, 32, bpr, cs,
                                           kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
                                           prov, NULL, false, kCGRenderingIntentDefault);
            // ③ 目标 Context 直接绑定原 buffer 内存 (渲染结果原地落盘, 无中间缓冲)
            CGContextRef ctx = CGBitmapContextCreate(base, (size_t)w, (size_t)h, 8, bpr, cs,
                                                     kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
            if (img && ctx) {
                CGFloat ww = (CGFloat)w, hh = (CGFloat)h;
                // 黑底 (等价 JS clearRect + fillStyle='#000')
                CGContextSetRGBFillColor(ctx, 0, 0, 0, 1);
                CGContextFillRect(ctx, CGRectMake(0, 0, ww, hh));
                // 对齐 JS canvas 坐标系 (原点左上, y 向下): 翻转 y
                CGContextTranslateCTM(ctx, 0, hh);
                CGContextScaleCTM(ctx, 1, -1);
                // JS: ctx.translate(cw/2,ch/2); ctx.rotate(rad)
                // CG 权威行为: drawImage 将图像数学正立放置 (第0行在 rect 高 y 端),
                // 故 -rad 才等价于 JS canvas 的顺时针 (+90° 人头朝右), 已逐点仿真验证:
                // -rad => 0°上 -> 90°右 -> 180°倒立 -> 270°左
                CGContextTranslateCTM(ctx, ww / 2.0, hh / 2.0);
                NSInteger rr = ((rot % 360) + 360) % 360;
                if (rr) CGContextRotateCTM(ctx, -(CGFloat)rr * (CGFloat)M_PI / 180.0f);
                // [视频缩放] 渲染层等比缩放 (围绕中心), 不改像素数据/格式/帧率;
                // >1 放大溢出部分由 buffer 边界自然裁剪, <1 缩小露黑底
                if (scale > 0 && fabs(scale - 1.0f) > 0.01f)
                    CGContextScaleCTM(ctx, scale, scale);
                // JS exact 分支对齐 (人脸识别场景): aspectFit s=min — 完整面目及景象,
                // 不裁剪任何内容 (裁剪过大过多会导致无法识别人脸);
                // rotate(+rad)=顺时针 上->右->下->左, 已按 CG 真实行为逐点仿真验证
                CGFloat ew = (rr == 90 || rr == 270) ? hh : ww;
                CGFloat eh = (rr == 90 || rr == 270) ? ww : hh;
                CGFloat vw = ww, vh = hh;
                CGFloat s = MIN(ew / vw, eh / vh);
                CGFloat dw = vw * s, dh = vh * s;
                CGContextDrawImage(ctx, CGRectMake(-dw / 2.0, -dh / 2.0, dw, dh), img);
                CGContextFlush(ctx);
            }
            if (ctx) CFRelease(ctx);
            if (img) CFRelease(img);
            if (prov) CFRelease(prov);
            CFRelease(cs);
        }
        CVPixelBufferUnlockBaseAddress(buf, 0);
    } @catch (NSException *e) {
        VPMErr(@"rotation-direction", e);
    }
}

// [帧层取色采样] 消费 SpringBoard 发来的坐标请求: 从真实视频帧读像素 ->
// 同进程直设 QMEnhancerView setter (UIColor 内存传递, 零序列化) + 持久化兜底 ->
// 写结果文件供准星预览回显. 全程无私有 API, 无截屏 (旧方案在 SpringBoard abort).
static void VPMFramePickSample(CVBufferRef buf) {
    @try {
        NSString *pt = [NSString stringWithContentsOfFile:VPMPointFile
                                                 encoding:NSUTF8StringEncoding error:nil];
        if (!pt.length) return;
        [[NSFileManager defaultManager] removeItemAtPath:VPMPointFile error:nil];
        NSArray *parts = [pt componentsSeparatedByString:@","];
        if (parts.count < 2) return;
        double fx = [parts[0] doubleValue], fy = [parts[1] doubleValue];
        if (fx < 0) fx = 0; if (fx > 1) fx = 1;
        if (fy < 0) fy = 0; if (fy > 1) fy = 1;
        CVPixelBufferLockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);
        size_t w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf);
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(buf);
        size_t bpr = CVPixelBufferGetBytesPerRow(buf);
        int R = -1, G = -1, B = -1;
        if (base && w && h && bpr >= w * 4) {
            long px = (long)(fx * (w - 1));
            long py = (long)(fy * (h - 1));
            const uint8_t *p = base + py * bpr + px * 4;   // BGRA
            B = p[0]; G = p[1]; R = p[2];
        }
        CVPixelBufferUnlockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);
        if (R < 0) return;
        // [死锁根治] 此处严禁触碰 QMEnhancerView 实例 (UIView 子类, sharedInstance
        // 懒加载在无 UI 的 mediaserverd/非主线程创建视图层次 -> 进程崩溃, 实测
        // 每次取色请求后 mediaserverd 即重启). 仅做: 采样 -> 结果文件回传 ->
        // plist 写 UIColor 归档 (标准序列化, 增强模块可还原); setter 注入由
        // SpringBoard 侧轮询在安全环境执行.
        [[NSString stringWithFormat:@"%d,%d,%d", R, G, B]
            writeToFile:VPMResultFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
        // [毒源根除] 不再向共享 plist 写任何 mappingColor 数据 — 上一版写入的
        // UIColor 归档 data 与增强模块原生格式不符, 其读取时 unrecognized selector
        // 导致 SpringBoard 两次崩溃 (实测). 颜色传递仅走: result 文件 -> SpringBoard
        // 主线程 setter (内存直设) -> 增强模块自身 saveCurrentSettings 原生持久化.
    } @catch (NSException *e) { VPMErr(@"frame-pick", e); }
}

// [自愈清理] 移除历史版本遗留的毒数据: mappingColor 若为 NSData(归档)/其他非
// 字符串类型, 增强模块/面板读取即崩. 启动与开启取色前各执行一次.
static void VPMSanitizeSettings(void) {
    @try {
        NSMutableDictionary *s = [NSMutableDictionary dictionaryWithContentsOfFile:VPMSharedSettingsPath];
        if (!s) return;
        id mc = s[@"mappingColor"];
        BOOL poisoned = mc && ![mc isKindOfClass:[NSString class]];
        if (poisoned) {
            [s removeObjectForKey:@"mappingColor"];
            [s writeToFile:VPMSharedSettingsPath atomically:YES];
            VPMInfo(@"设置自愈: 已移除非原生 mappingColor 毒数据");
        }
    } @catch (NSException *e) {}
}

static void VPMUpdateCurrentBufferHook(id self, SEL _cmd, CVBufferRef buffer) {
    @try {
        __sync_add_and_fetch(&VPMFramesUpdate, 1);
        int64_t seen = __sync_add_and_fetch(&VPMFramesSeen, 1);
        if (seen == 1) {
            VPMInfo([NSString stringWithFormat:@"首帧已进入帧钩子 (%zu x %zu, 格式 %c%c%c%c)",
                     CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer),
                     (char)((CVPixelBufferGetPixelFormatType(buffer) >> 24) & 0xFF),
                     (char)((CVPixelBufferGetPixelFormatType(buffer) >> 16) & 0xFF),
                     (char)((CVPixelBufferGetPixelFormatType(buffer) >> 8) & 0xFF),
                     (char)(CVPixelBufferGetPixelFormatType(buffer) & 0xFF)]);
        }
        static NSInteger cachedRot = -1;
        static CGFloat cachedScale = -1.0;
        static double lastRead = 0;
        double now = [NSDate timeIntervalSinceReferenceDate];
        if (cachedRot < 0 || cachedScale < 0 || (now - lastRead) > 0.5) {
            cachedRot = VPMReadRotation();
            cachedScale = VPMReadScale();
            lastRead = now;
        }
        // 帧层取色采样 (有请求文件时执行; 每帧轻量 existence check)
        if (buffer) VPMFramePickSample(buffer);
        if ((cachedRot != 0 || fabs(cachedScale - 1.0f) > 0.01f) && buffer) {
            // 方向旋转 + 视频缩放 (旧项目 canvas 语义翻译): buffer 尺寸/指针不变, CoreGraphics 渲染
            VPMRotateDirectionInPlace(buffer, cachedRot, cachedScale);
            static volatile int64_t rotLogSeq = 0;
            int64_t ls = __sync_add_and_fetch(&rotLogSeq, 1);
            if (ls % 60 == 1) {
                VPMInfo([NSString stringWithFormat:@"渲染变换已应用 (%ld°, %.2fx)", (long)cachedRot, cachedScale]);
            }
        }
        if (origUpdateCurrentBuffer) origUpdateCurrentBuffer(self, _cmd, buffer);
    } @catch (NSException *e) {
        VPMErr(@"frame-hook", e);
        if (origUpdateCurrentBuffer) origUpdateCurrentBuffer(self, _cmd, buffer);
    }
}

static BOOL VPMFrameInstalled = NO;

// 消费点钩子: copyCurrentFrame / getCurrentFrame — 引擎取帧入口.
// 旋转已由 update 就地完成, 此处仅透传 + 计数日志 (用于定位引擎真实渲染路径).
static CVBufferRef VPMCopyCurrentFrameHook(id self, SEL _cmd) {
    @try {
        CVBufferRef f = origCopyCurrentFrame ? origCopyCurrentFrame(self, _cmd) : NULL;
        int64_t n = __sync_add_and_fetch(&VPMFramesCopy, 1);
        if (n % 60 == 1) {
            VPMInfo([NSString stringWithFormat:@"copy 透传 %lld 帧 (读取引擎当前帧)", n]);
        }
        return f;
    } @catch (NSException *e) {
        VPMErr(@"copy-frame", e);
        if (origCopyCurrentFrame) return origCopyCurrentFrame(self, _cmd);
        return NULL;
    }
}

static CVBufferRef VPMGetCurrentFrameHook(id self, SEL _cmd) {
    @try {
        CVBufferRef f = origGetCurrentFrame ? origGetCurrentFrame(self, _cmd) : NULL;
        int64_t n = __sync_add_and_fetch(&VPMFramesGet, 1);
        if (n % 60 == 1) {
            VPMInfo([NSString stringWithFormat:@"get 透传 %lld 帧 (读取引擎当前帧)", n]);
        }
        return f;
    } @catch (NSException *e) {
        VPMErr(@"get-frame", e);
        if (origGetCurrentFrame) return origGetCurrentFrame(self, _cmd);
        return NULL;
    }
}

static void VPMInstallFrameHook(void) {
    if (VPMFrameInstalled) return;
    @try {
        Class lvp = NSClassFromString(@"LocalVideoPlayer");
        if (!lvp) {
            static BOOL warned = NO;
            if (!warned) {
                warned = YES;
                VPMWarn([NSString stringWithFormat:@"LocalVideoPlayer 类未找到 (%@), 继续等待…",
                         VPMProcName(VPMProc())]);
            }
            return;
        }
        Method m = class_getInstanceMethod(lvp, @selector(updateCurrentBuffer:));
        if (!m) {
            VPMWarn([NSString stringWithFormat:@"updateCurrentBuffer: 方法未找到 (%@)",
                     VPMProcName(VPMProc())]);
            return;
        }
        IMP orig = method_getImplementation(m);
        if (orig == (IMP)VPMUpdateCurrentBufferHook) { VPMFrameInstalled = YES; return; }
        origUpdateCurrentBuffer = (void (*)(id, SEL, CVBufferRef))orig;
        method_setImplementation(m, (IMP)VPMUpdateCurrentBufferHook);
        // 核心消费点: 引擎取帧入口 (copyCurrentFrame/getCurrentFrame) 一并钩住,
        // 返回共享缓存中的旋转帧 — 对齐旧项目"消费端旋转", 防取帧路径绕过存储钩子
        Class lvp2 = NSClassFromString(@"LocalVideoPlayer");
        if (lvp2) {
            Method mC = class_getInstanceMethod(lvp2, @selector(copyCurrentFrame));
            if (mC) {
                IMP oc = method_getImplementation(mC);
                if (oc != (IMP)VPMCopyCurrentFrameHook) {
                    origCopyCurrentFrame = (CVBufferRef (*)(id, SEL))oc;
                    method_setImplementation(mC, (IMP)VPMCopyCurrentFrameHook);
                }
            }
            Method mG = class_getInstanceMethod(lvp2, @selector(getCurrentFrame));
            if (mG) {
                IMP og = method_getImplementation(mG);
                if (og != (IMP)VPMGetCurrentFrameHook) {
                    origGetCurrentFrame = (CVBufferRef (*)(id, SEL))og;
                    method_setImplementation(mG, (IMP)VPMGetCurrentFrameHook);
                }
            }
        }
        VPMFrameInstalled = YES;
        VPMInfo([NSString stringWithFormat:@"帧钩子已安装 (%@, %lld 帧待处理)",
                 VPMProcName(VPMProc()), VPMFramesSeen]);
    } @catch (NSException *e) {
        VPMErr(@"frame-install", e);
    }
}

static void VPMScheduleFrameWatchdog(void) {
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(src, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                              10 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(src, ^{
        @autoreleasepool {
            @try {
                if (!VPMFrameInstalled) return;
                if (VPMReadRotation() != 0 && VPMFramesSeen == 0) {
                    VPMLogLine(@"ERR", nil, [NSString stringWithFormat:
                        @"旋转已开启但帧钩子无帧流入: %@ 进程内 updateCurrentBuffer: 从未被调用",
                        VPMProcName(VPMProc())]);
                }
            } @catch (NSException *e) {}
        }
    });
    dispatch_resume(src);
}

static void VPMScheduleFrameInstall(void) {
    VPMInstallFrameHook();
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(src, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                              2 * NSEC_PER_SEC, NSEC_PER_SEC);
    __block int tries = 0;
    dispatch_source_set_event_handler(src, ^{
        @autoreleasepool {
            @try {
                if (VPMFrameInstalled) { dispatch_source_cancel(src); return; }
                if (++tries >= 45) {
                    VPMLogLine(@"ERR", nil, [NSString stringWithFormat:
                        @"帧钩子 90s 内未装成: %@ 进程无 LocalVideoPlayer/updateCurrentBuffer: 或注入未生效",
                        VPMProcName(VPMProc())]);
                    dispatch_source_cancel(src);
                    return;
                }
                VPMInstallFrameHook();
            } @catch (NSException *e) {}
        }
    });
    dispatch_resume(src);
    VPMScheduleFrameWatchdog();
}

@interface VPMExtraController : NSObject
@property (nonatomic, weak) UIViewController *panelVC;
@property (nonatomic, weak) UIButton *rotBtn;
@property (nonatomic, weak) UIButton *colorBtn;   // 取色层 hitTest 放行目标
@end

@implementation VPMExtraController

- (void)showLogAlert {
    @try {
        UIViewController *vc = self.panelVC;
        if (!vc) vc = [UIApplication sharedApplication].keyWindow.rootViewController;
        if (!vc) return;
        NSString *sb  = VPMMarkExists(@"extrakeys_springboard") ? @"OK" : @"FAIL";
        NSString *ms  = VPMMarkExists(@"extrakeys_mediaserverd") ? @"OK" : @"FAIL";
        NSString *ls  = VPMMarkExists(@"extrakeys_lskdd") ? @"OK" : @"FAIL";
        NSString *enh = VPMMarkExists(@"enhancer_injected") ? @"OK" : @"FAIL";
        NSMutableString *diag = [NSMutableString string];
        [diag appendFormat:@"[进程注入诊断]\n功能键UI(SpringBoard): %@\n帧旋转(mediaserverd): %@\n帧旋转(lskdd): %@\n增强模块: %@\n视频旋转: %ld°\n",
         sb, ms, ls, enh, (long)VPMReadRotation()];
        [diag appendString:@"[错误记录] (最近20条, 最新在上)\n"];
        NSMutableArray *lines = [NSMutableArray array];
        for (NSString *rawLine in [VPMFullLog() componentsSeparatedByString:@"\n"]) {
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
                NSString *full = [diag stringByAppendingFormat:@"\n---- 日志全文 ----\n%@", VPMFullLog()];
                [UIPasteboard generalPasteboard].string = full;
            } @catch (NSException *e) {}
        }]];
        [al addAction:[UIAlertAction actionWithTitle:@"清空日志" style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *a) {
            @try { [@"" writeToFile:VPMErrorLogPath atomically:YES
                           encoding:NSUTF8StringEncoding error:nil]; }
            @catch (NSException *e) {}
        }]];
        [al addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:al animated:YES completion:nil];
    } @catch (NSException *e) { VPMErr(@"log-key", e); }
}

@end

static VPMExtraController *VPMController(void) {
    static VPMExtraController *c = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [VPMExtraController new]; });
    return c;
}

static NSArray *VPMFindAllPanelEntries(void); // 前置声明 (定义在下方)

// ---------------------------------------------------------------
// 面板整面重建 (v9/LV-7): 照源码/补丁 VPBuildPanel 布局与调用逻辑逐行移植,
// 按钮 target 一律 = 面板 VC + 原 SEL, 调用逻辑零改动; 徽章/RTMP tag 与补丁
// 一致 (0x6B62/0x6B65/0x6B66/0x6B67) → 补丁 updateStatusLabel 状态同步直通
// ---------------------------------------------------------------
static UIColor *VPMColorGreen(void) { return [UIColor colorWithRed:0.24 green:1.00 blue:0.62 alpha:1]; }
static UIColor *VPMColorBlue(void)  { return [UIColor colorWithRed:0.24 green:0.48 blue:1.00 alpha:1]; }
static UIColor *VPMColorPink(void)  { return [UIColor colorWithRed:1.00 green:0.24 blue:0.62 alpha:1]; }
static UIColor *VPMColorGold(void)  { return [UIColor colorWithRed:1.00 green:0.77 blue:0.24 alpha:1]; }
static UIColor *VPMColorGlass(void) { return [UIColor colorWithRed:0.063 green:0.102 blue:0.173 alpha:0.5]; }

@interface VPMPressButton : UIButton
@end
@implementation VPMPressButton
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

static UIImage *VPMRenderIcon(CGSize size, void (^draw)(CGContextRef ctx)) {
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 3;
    UIGraphicsImageRenderer *ren = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    return [ren imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        if (draw) draw(ctx.CGContext);
    }];
}

static UIImage *VPMFilmIcon(UIColor *c) {
    return VPMRenderIcon(CGSizeMake(48, 48), ^(CGContextRef ctx){
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

static UIImage *VPMEyeIcon(UIColor *c) {
    return VPMRenderIcon(CGSizeMake(48, 48), ^(CGContextRef ctx){
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

static UIImage *VPMRestoreIcon(UIColor *c) {
    return VPMRenderIcon(CGSizeMake(48, 48), ^(CGContextRef ctx){
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

static UIImage *VPMOrbitIcon(UIColor *c) {
    return VPMRenderIcon(CGSizeMake(48, 48), ^(CGContextRef ctx){
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

static UIImage *VPMBookIcon(UIColor *c) {
    return VPMRenderIcon(CGSizeMake(48, 48), ^(CGContextRef ctx){
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

static UIImage *VPMXIcon(UIColor *c) {
    return VPMRenderIcon(CGSizeMake(48, 48), ^(CGContextRef ctx){
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
static Ivar VPMIvar(Class cls, const char *name) {
    return class_getInstanceVariable(cls, name);
}
static void VPMMirrorRtmpState(UIViewController *vc, BOOL on, NSString *url) {
    Class cls = object_getClass(vc);
    Ivar swIv = VPMIvar(cls, "_rtmpSwitch");
    Ivar tfIv = VPMIvar(cls, "_rtmpTextField");
    if (swIv) {
        UISwitch *origSw = object_getIvar(vc, swIv);
        if (origSw) {
            origSw.on = on;
            VPMSafeCall(vc, @selector(rtmpSwitchChanged:), origSw);
        }
    }
    if (tfIv && url.length) {
        UITextField *origTf = object_getIvar(vc, tfIv);
        if (origTf) {
            origTf.text = url;
            VPMSafeCall(vc, @selector(saveRtmpUrl), nil);
        }
    }
}

static void vpmMiniSwitchChanged(id self, SEL _cmd, id sender) {
    UISwitch *sw = sender;
    VPMMirrorRtmpState((UIViewController *)self, sw.isOn, nil);
}
static void vpmMiniTfEnd(id self, SEL _cmd, id sender) {
    UITextField *tf = sender;
    if (tf && tf.text.length) VPMMirrorRtmpState((UIViewController *)self, NO, tf.text);
}
static void vpmRtmpSwitchChanged(id self, SEL _cmd, id sender) {
    UISwitch *sw = sender;
    VPMMirrorRtmpState((UIViewController *)self, sw.isOn, nil);
}
static void vpmRotTapped(id self, SEL _cmd, id sender) {
    NSInteger next = VPMCycleRotation();
    UIButton *b = (UIButton *)sender;
    if (b) {
        [b setTitle:[NSString stringWithFormat:@"🔄\n旋转 %ld°", (long)next]
           forState:UIControlStateNormal];
    }
    VPMInfo([NSString stringWithFormat:@"视频旋转 -> %ld°", (long)next]);
}
static void vpmScaleTapped(id self, SEL _cmd, id sender) {
    CGFloat next = VPMCycleScale();
    UIButton *b = (UIButton *)sender;
    if (b) {
        [b setTitle:[NSString stringWithFormat:@"🔍\n缩放 %.2fx", next]
           forState:UIControlStateNormal];
    }
}
// [取色光标补丁] 点击彩色注入 -> 全屏光标模式: 光标可拖动到指定区域,
// 再次点击屏幕任意处 = 取光标处颜色并关闭 (问题4 交互).
// 取色经 UIKit 私有整屏截图 (SpringBoard 进程可用), 不侵入增强模块 (防点击崩溃, 问题3).
static void VPMEndColorPick(BOOL doPick);   // 前向声明 (overlay 点击回调)

// [准星光标] 人脸识别对焦框样式: 四角 L 括号 + 中心十字 + 白色发光;
// touchesMoved 拖动 (免手势 target 转发); 取色后光标常驻屏幕不隐藏
@interface VPMPickCursor : UIView
@property (nonatomic, strong) UIView *preview;   // 最近取色预览块 (colorPreview 演示)
@end
@implementation VPMPickCursor
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        // 发光外晕
        self.layer.shadowColor = [UIColor colorWithRed:0.3 green:1 blue:0.6 alpha:1].CGColor;
        self.layer.shadowOpacity = 0.95;
        self.layer.shadowRadius = 8;
        self.layer.shadowOffset = CGSizeZero;
        // 预览小块 (取色演示: 显示最近吸取颜色), 挂在准星下方
        _preview = [[UIView alloc] initWithFrame:CGRectMake(frame.size.width/2 - 14, frame.size.height - 4, 28, 28)];
        _preview.layer.cornerRadius = 6;
        _preview.layer.borderWidth = 1.5;
        _preview.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.9].CGColor;
        _preview.backgroundColor = [UIColor colorWithWhite:0 alpha:0.3];
        _preview.userInteractionEnabled = NO;
        [self addSubview:_preview];
    }
    return self;
}
// [标准射击准星] 外圈圆环 + 四方向延伸十字线 + 中心点, 发光描边
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat w = rect.size.width, h = rect.size.height;
    CGFloat cx = w / 2.0, cy = h / 2.0;
    CGFloat ringR = MIN(w, h) * 0.28;           // 圆环半径
    CGColorRef glow = [UIColor colorWithRed:0.35 green:1 blue:0.65 alpha:0.98].CGColor;
    // 外发光 (多层低透明描边模拟)
    for (int i = 3; i >= 1; i--) {
        CGContextSetStrokeColorWithColor(ctx,
            [UIColor colorWithRed:0.35 green:1 blue:0.65 alpha:0.10 * (4 - i)].CGColor);
        CGContextSetLineWidth(ctx, 2.5 + i * 1.6);
        CGContextBeginPath(ctx);
        CGContextAddEllipseInRect(ctx, CGRectMake(cx - ringR, cy - ringR, ringR * 2, ringR * 2));
        CGContextStrokePath(ctx);
    }
    // 主圆环
    CGContextSetStrokeColorWithColor(ctx, glow);
    CGContextSetLineWidth(ctx, 2.5);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextBeginPath(ctx);
    CGContextAddEllipseInRect(ctx, CGRectMake(cx - ringR, cy - ringR, ringR * 2, ringR * 2));
    CGContextStrokePath(ctx);
    // 四方向十字线: 从视图边缘指向圆环 (留出与环之间空隙)
    CGContextSetLineWidth(ctx, 2.0);
    CGFloat gap = ringR + 5;                    // 环外空隙
    CGPoint seg[4][2] = {
        { CGPointMake(cx, 1),            CGPointMake(cx, cy - gap) },   // 上
        { CGPointMake(w - 1, cy),        CGPointMake(cx + gap, cy) },   // 右
        { CGPointMake(cx, h - 1),        CGPointMake(cx, cy + gap) },   // 下
        { CGPointMake(1, cy),            CGPointMake(cx - gap, cy) },   // 左
    };
    for (int i = 0; i < 4; i++) {
        CGContextBeginPath(ctx);
        CGContextMoveToPoint(ctx, seg[i][0].x, seg[i][0].y);
        CGContextAddLineToPoint(ctx, seg[i][1].x, seg[i][1].y);
        CGContextStrokePath(ctx);
    }
    // 中心点
    CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(cx - 2, cy - 2, 4, 4));
}
// 取色后预览块颜色更新时轻微脉冲 (取色反馈)
- (void)setPreviewColor:(UIColor *)col {
    self.preview.backgroundColor = col;
    [UIView animateWithDuration:0.18 animations:^{ self.preview.transform = CGAffineTransformMakeScale(1.25, 1.25); }
                     completion:^(BOOL f) {
        [UIView animateWithDuration:0.18 animations:^{ self.preview.transform = CGAffineTransformIdentity; }];
    }];
}
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    if (t && t.view == self && self.superview)
        self.center = [t locationInView:self.superview];
}
@end
// 取色覆盖层 (点击屏幕任意处 = 在光标处取色一次并注入; 光标常驻, 不隐藏)
// [穿透修复] 彩色注入键区域 hitTest 放行 -> 取色中仍可点键停止 (光标关不掉根因:
// 全屏 overlay 拦截一切触摸, 面板按钮收不到点击)
@interface VPMPickOverlay : UIView @end
@implementation VPMPickOverlay
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)event {
    UIButton *cb = VPMController().colorBtn;
    if (cb && cb.window && cb.isUserInteractionEnabled) {
        CGRect fr = [cb convertRect:cb.bounds toView:self];
        if (CGRectContainsPoint(fr, p)) return nil;   // 穿透到下层彩色键
    }
    return [super hitTest:p withEvent:event];
}
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    VPMEndColorPick(YES);   // 仅取色+注入; 退出由彩色注入键负责
}
@end

static UIView *gPickOverlay = nil;   // 挂载于 keyWindow 的取色层 (独立 UIWindow 在
static UIView *gPickCursor = nil;    // SpringBoard UIScene 架构下不渲染 -> 光标不可见)

// [两段式跨进程取色] SpringBoard 点击 -> 写坐标文件; mediaserverd 帧钩子从
// 真实视频帧采样该坐标像素 -> 同进程直设 QMEnhancerView setter + 持久化 ->
// 写结果文件; SpringBoard 轮询回显预览. 零私有 API (旧截屏方案在 SpringBoard
// abort 导致黑屏崩溃, 已废弃).

static void VPMEndColorPick(BOOL doPick) {
    @try {
        if (doPick && gPickCursor && gPickOverlay) {
            // 光标中心 -> 屏幕比例坐标 (0..1), 发送给帧层采样
            CGRect sb = [UIScreen mainScreen].bounds;
            CGPoint c = gPickCursor.center;
            double fx = sb.size.width > 0 ? c.x / sb.size.width : 0;
            double fy = sb.size.height > 0 ? c.y / sb.size.height : 0;
            if (fx < 0) fx = 0; if (fx > 1) fx = 1;
            if (fy < 0) fy = 0; if (fy > 1) fy = 1;
            NSString *payload = [NSString stringWithFormat:@"%.6f,%.6f", fx, fy];
            [payload writeToFile:VPMPointFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
            VPMInfo([NSString stringWithFormat:@"取色请求: 坐标(%.3f,%.3f)已发送帧层采样", fx, fy]);
        }
    } @catch (NSException *e) { VPMErr(@"color-pick", e); }
    // 光标常驻不隐藏; 退出仅由彩色注入键触发 (VPMStopPickMode)
}

// SpringBoard 轮询: 读帧层回传的取色结果 -> 预览块演示 + [安全环境 setter 注入]
// (QMEnhancerView 单例只在 SpringBoard 有 UI 上下文; mediaserverd 侧严禁触碰)
static void VPMPollPickResult(void) {
    @try {
        NSString *s = [NSString stringWithContentsOfFile:VPMResultFile
                                                encoding:NSUTF8StringEncoding error:nil];
        if (!s.length) return;
        [[NSFileManager defaultManager] removeItemAtPath:VPMResultFile error:nil];
        NSArray *parts = [s componentsSeparatedByString:@","];
        if (parts.count < 3) return;
        CGFloat r = [parts[0] floatValue] / 255.0, g = [parts[1] floatValue] / 255.0,
                b = [parts[2] floatValue] / 255.0;
        UIColor *col = [UIColor colorWithRed:r green:g blue:b alpha:1];
        // UI 更新回主线程 (轮询在 utility 队列)
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                if ([gPickCursor isKindOfClass:[VPMPickCursor class]])
                    [(VPMPickCursor *)gPickCursor setPreviewColor:col];
            } @catch (NSException *e) {}
        });
        // [setter 注入] 主线程 + 增强模块单例 (面板同款运行环境, 安全)
        // 精简面: 仅 mappingColor + 开关两项 (saveCurrentSettings/Intensity 内部链
        // 曾触发崩溃, 移出崩溃面)
        Class enh = NSClassFromString(@"QMEnhancerView");
        id inst = ([enh respondsToSelector:@selector(sharedInstance)])
                  ? VPMSafeCall(enh, @selector(sharedInstance), nil) : nil;
        if (inst) {
            if ([inst respondsToSelector:@selector(setMappingColor:)])
                VPMSafeCall(inst, @selector(setMappingColor:), col);
            if ([inst respondsToSelector:@selector(setColorMappingEnabled:)])
                VPMSafeCall(inst, @selector(setColorMappingEnabled:), @YES);
            VPMInfo([NSString stringWithFormat:@"取色完成 RGB(%d,%d,%d) 已注入渲染",
                     (int)(r*255), (int)(g*255), (int)(b*255)]);
        } else {
            VPMWarn(@"取色回显: 增强模块单例不可用 (仅预览)");
        }
    } @catch (NSException *e) {}
}

// 停止取色模式: 光标/覆盖层移除消失
static void VPMStopPickMode(void) {
    @try {
        [gPickOverlay removeFromSuperview];
        gPickOverlay = nil;
        gPickCursor = nil;
        VPMInfo(@"取色模式: 已停止 (光标已移除)");
    } @catch (NSException *e) {}
}

static void VPMStartColorPick(void) {
    VPMSanitizeSettings();   // 开启前自愈: 清历史毒数据
    if (gPickOverlay.superview) { VPMStopPickMode(); return; }  // 再点彩色键=停止取色, 光标消失
    @try {
        // 挂载到现有 keyWindow (SpringBoard 无独立渲染 scene 的自建 UIWindow)
        UIWindow *kw = [UIApplication sharedApplication].keyWindow;
        if (!kw) kw = [UIApplication sharedApplication].windows.lastObject;
        if (!kw) { VPMWarn(@"取色模式: 无可用窗口"); return; }
        // 触摸层: 点击屏幕任意处 = 取色并结束 (光标在其上层, 拖动不误触)
        VPMPickOverlay *ov = [[VPMPickOverlay alloc] initWithFrame:kw.bounds];
        ov.backgroundColor = [UIColor clearColor];
        ov.userInteractionEnabled = YES;

        // 半透明提示条
        UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(0, 60, kw.bounds.size.width, 24)];
        tip.text = @"拖动准星至目标 · 点击屏幕=吸取视频颜色注入 · 彩色键=结束";
        tip.font = [UIFont boldSystemFontOfSize:12];
        tip.textColor = [UIColor whiteColor];
        tip.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        tip.textAlignment = NSTextAlignmentCenter;
        tip.layer.cornerRadius = 6;
        tip.clipsToBounds = YES;
        tip.userInteractionEnabled = NO;
        [ov addSubview:tip];

        // [准星光标] 样式由 VPMPickCursor drawRect 自绘 (四角括号+发光+中心十字),
        // 此处仅定位; 预览块已在其内部
        VPMPickCursor *cur = [[VPMPickCursor alloc] initWithFrame:CGRectMake(0, 0, 64, 64)];
        cur.center = CGPointMake(kw.bounds.size.width / 2, kw.bounds.size.height / 2);
        [ov addSubview:cur];

        gPickCursor = cur;
        gPickOverlay = ov;
        [kw addSubview:ov];
        // 结果轮询 (1s): 帧层回传取色 -> 预览演示 (取色模式关闭时自毁)
        dispatch_source_t poll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(poll, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                                  1.0 * NSEC_PER_SEC, 200 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(poll, ^{ @autoreleasepool {
            if (!gPickOverlay) { dispatch_source_cancel(poll); return; }
            VPMPollPickResult();
        }});
        dispatch_resume(poll);
        VPMInfo(@"取色模式: 已开启 (准星拖动取色 · 点击屏幕=吸取注入 · 彩色键=结束)");
    } @catch (NSException *e) { VPMErr(@"color-start", e); }
}
static void vpmColorTapped(id self, SEL _cmd, id sender) {
    @try {
        // [交互 v2] 取色模式中 -> 彩色键 = 停止取色 (准星消失); 优先级最高
        if (gPickOverlay.superview) { VPMStopPickMode(); return; }
        Class enh = NSClassFromString(@"QMEnhancerView");
        if (!enh) { VPMWarn(@"彩色注入: 增强模块未加载"); return; }
        BOOL on = NO;
        if ([enh respondsToSelector:@selector(isColorMappingEnabled)]) {
            NSNumber *n = VPMSafeCall(enh, @selector(isColorMappingEnabled), nil);
            on = [n boolValue];
        }
        if (on) {
            // 已启用 → 关闭彩色映射 (写增强模块共享设置)
            if ([enh respondsToSelector:@selector(sharedSettings)] &&
                [enh respondsToSelector:@selector(saveSharedSettings:)]) {
                NSDictionary *cur = VPMSafeCall(enh, @selector(sharedSettings), nil);
                NSMutableDictionary *s = [NSMutableDictionary dictionaryWithDictionary:cur ?: @{}];
                s[@"colorMappingEnabled"] = @NO;
                VPMSafeCall(enh, @selector(saveSharedSettings:), s);
                VPMInfo(@"彩色注入: 已关闭");
            }
        } else {
            // 未启用 → 准星取色模式 (不调增强模块 enterColorPickMode — 该路径崩溃):
            // 拖动准星到区域, 点击屏幕=吸取+注入(光标常驻可连续换色), 彩色键=结束
            VPMStartColorPick();
        }
    } @catch (NSException *e) { VPMErr(@"color-inject", e); }
}

// ---------------------------------------------------------------
// 整面重建 (照 VPBuildPanel 布局逐行移植 + 旋转/彩色新键)
// ---------------------------------------------------------------
static void VPMBuildPanel(UIViewController *vc) {
    UIView *root = vc.view;
    if (!root) return;
    CGFloat W = root.bounds.size.width;
    CGFloat H = root.bounds.size.height;
    if (W < 100 || H < 100) return;
    CGFloat K = MIN(W / 390.0, H / 844.0);

    // 全量清除: 移除补丁产物与旧重建 (面板 UI 全部由我方重建)
    for (UIView *v in [root.subviews copy]) [v removeFromSuperview];
    root.tag = VPM_TAG_OWN;

    // --- 标题胶囊 ---
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake((W - 200 * K) / 2, 46 * K, 200 * K, 30 * K)];
    title.text = @"控制终端UI面板";
    title.font = [UIFont boldSystemFontOfSize:13 * K];
    title.textColor = [UIColor whiteColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.layer.cornerRadius = 15 * K;
    title.layer.borderWidth = 1.5;
    title.layer.borderColor = VPMColorGreen().CGColor;
    title.backgroundColor = [UIColor colorWithRed:0.24 green:1.0 blue:0.62 alpha:0.15];
    [root addSubview:title];

    // --- 舱间光柱 ---
    UIView *beam = [[UIView alloc] initWithFrame:CGRectMake(W / 2 + 19 * K, 172 * K, 6 * K, 118 * K)];
    beam.layer.cornerRadius = 3 * K;
    beam.backgroundColor = VPMColorGreen();
    beam.alpha = 0.85;
    [root addSubview:beam];
    CABasicAnimation *bp = [CABasicAnimation animationWithKeyPath:@"opacity"];
    bp.fromValue = @0.85; bp.toValue = @0.3;
    bp.duration = 1.4; bp.autoreverses = YES; bp.repeatCount = INFINITY;
    [beam.layer addAnimation:bp forKey:@"vpmBeam"];

    // --- 左主控舱 (2x2 原图标键 + 旋转/彩色 + 迷你RTMP) ---
    UIView *podL = [[UIView alloc] initWithFrame:CGRectMake(12 * K, 88 * K, 168 * K, 376 * K)];
    podL.layer.cornerRadius = 22 * K;
    podL.layer.borderWidth = 1.5;
    podL.layer.borderColor = VPMColorGreen().CGColor;
    podL.backgroundColor = VPMColorGlass();
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
    podTitle.textColor = VPMColorGreen();
    [podL addSubview:podTitle];

    // 2x2 原图标键 (回调 = 原 SEL, 调用逻辑零改动)
    CGFloat bw = (168 * K - 28 * K - 10 * K) / 2;
    struct { SEL action; UIColor *color; UIImage *(*icon)(UIColor *); } keys[4] = {
        { @selector(switchVideoTapped),        VPMColorGreen(), VPMFilmIcon },
        { @selector(toggleReplacementTapped),  VPMColorBlue(),  VPMEyeIcon },
        { @selector(restoreCameraTapped),      VPMColorPink(),  VPMRestoreIcon },
        { @selector(toggleFloatingBallTapped), VPMColorGold(),  VPMOrbitIcon },
    };
    for (int i = 0; i < 4; i++) {
        int col = i % 2, row = i / 2;
        CGRect f = CGRectMake(14 * K + col * (bw + 10 * K), 30 * K + row * (74 * K + 12 * K), bw, 74 * K);
        VPMPressButton *b = [VPMPressButton buttonWithType:UIButtonTypeCustom];
        b.frame = f;
        b.tag = (NSInteger[]){VPM_TAG_MED, VPM_TAG_REP, VPM_TAG_RST, VPM_TAG_BAL}[i];
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
        { @selector(vpmRotTapped:),   [UIColor colorWithRed:0.31 green:0.86 blue:1.0 alpha:1.0], VPM_TAG_ROT,
          [NSString stringWithFormat:@"🔄\n旋转 %ld°", (long)VPMReadRotation()] },
        { @selector(vpmColorTapped:), [UIColor colorWithRed:0.71 green:0.47 blue:1.0 alpha:1.0], VPM_TAG_COL,
          @"🎨\n彩色注入" },
    };
    for (int i = 0; i < 2; i++) {
        CGRect f = CGRectMake(14 * K + i * (bw + 10 * K), 212 * K, bw, 52 * K);
        VPMPressButton *b = [VPMPressButton buttonWithType:UIButtonTypeCustom];
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
        if (b.tag == VPM_TAG_ROT) VPMController().rotBtn = b;
        if (b.tag == VPM_TAG_COL) VPMController().colorBtn = b;
    }

    // 视频缩放键 (第三行全宽): 渲染层等比缩放循环 1.0/1.5/2.0/0.8
    {
        UIButton *sb = [VPMPressButton buttonWithType:UIButtonTypeCustom];
        sb.frame = CGRectMake(14 * K, 272 * K, bw * 2 + 10 * K, 40 * K);
        sb.tag = VPM_TAG_SCL;
        sb.layer.cornerRadius = 12 * K;
        sb.backgroundColor = [UIColor colorWithRed:0.98 green:0.75 blue:0.28 alpha:1.0];
        sb.layer.borderWidth = 1.5;
        sb.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
        [sb setTitle:[NSString stringWithFormat:@"🔍\n缩放 %.2fx", (double)VPMReadScale()]
            forState:UIControlStateNormal];
        sb.titleLabel.font = [UIFont boldSystemFontOfSize:10 * K];
        sb.titleLabel.numberOfLines = 1;
        sb.titleLabel.textAlignment = NSTextAlignmentCenter;
        [sb setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [sb addTarget:vc action:@selector(vpmScaleTapped:) forControlEvents:UIControlEventTouchUpInside];
        [podL addSubview:sb];
    }

    // 迷你 RTMP: 开关 + 输入 (镜像到原控件后走原方法)
    UISwitch *miniSw = [[UISwitch alloc] initWithFrame:CGRectMake(14 * K, 322 * K, 51 * K, 31 * K)];
    miniSw.tag = VP_TAG_MINISW;
    miniSw.onTintColor = VPMColorGreen();
    miniSw.transform = CGAffineTransformMakeScale(K, K);
    [miniSw addTarget:vc action:@selector(vpMiniSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [podL addSubview:miniSw];

    UITextField *miniTf = [[UITextField alloc] initWithFrame:CGRectMake(72 * K, 326 * K, 84 * K, 22 * K)];
    miniTf.tag = VP_TAG_MINITF;
    miniTf.font = [UIFont systemFontOfSize:8 * K];
    miniTf.textColor = [UIColor colorWithRed:0.81 green:0.88 blue:1 alpha:1];
    miniTf.backgroundColor = [UIColor colorWithRed:0.24 green:0.48 blue:1 alpha:0.15];
    miniTf.layer.cornerRadius = 6 * K;
    miniTf.layer.borderWidth = 1;
    miniTf.layer.borderColor = VPMColorBlue().CGColor;
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
    podR.layer.borderColor = VPMColorBlue().CGColor;
    podR.backgroundColor = VPMColorGlass();
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
    podTitleR.textColor = VPMColorBlue();
    podTitleR.textAlignment = NSTextAlignmentCenter;
    [podR addSubview:podTitleR];

    UIView *eye = [[UIView alloc] initWithFrame:CGRectMake((124 * K - 68 * K) / 2, 32 * K, 68 * K, 68 * K)];
    eye.layer.cornerRadius = 34 * K;
    eye.backgroundColor = VPMColorBlue();
    eye.layer.borderWidth = 2;
    eye.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.7].CGColor;
    eye.layer.shadowColor = VPMColorBlue().CGColor;
    eye.layer.shadowOpacity = 0.9f;
    eye.layer.shadowRadius = 16 * K;
    [podR addSubview:eye];
    UIImageView *eyeIv = [[UIImageView alloc] initWithFrame:CGRectInset(eye.bounds, 14 * K, 14 * K)];
    eyeIv.image = VPMEyeIcon([UIColor whiteColor]);
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
    rtmpLab.textColor = VPMColorGreen();
    rtmpLab.textAlignment = NSTextAlignmentCenter;
    [podR addSubview:rtmpLab];
    UISwitch *rtmpSw = [[UISwitch alloc] initWithFrame:CGRectMake((124 * K - 51 * K) / 2, 148 * K, 51 * K, 31 * K)];
    rtmpSw.tag = VP_TAG_RTMPSW;
    rtmpSw.onTintColor = VPMColorBlue();
    rtmpSw.transform = CGAffineTransformMakeScale(K, K);
    [rtmpSw addTarget:vc action:@selector(vpRtmpSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [podR addSubview:rtmpSw];

    // 日志诊断键 (弹窗 + 复制日志 + 清空, 不依赖补丁任何逻辑)
    VPMPressButton *logBtn = [VPMPressButton buttonWithType:UIButtonTypeCustom];
    logBtn.tag = VPM_TAG_LOG;
    logBtn.frame = CGRectMake(14 * K, 202 * K, 96 * K, 32 * K);
    logBtn.layer.cornerRadius = 10 * K;
    logBtn.backgroundColor = [UIColor colorWithRed:1.0 green:0.36 blue:0.36 alpha:1.0];
    logBtn.layer.borderWidth = 1.5;
    logBtn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
    [logBtn setTitle:@"📋 错误日志" forState:UIControlStateNormal];
    logBtn.titleLabel.font = [UIFont boldSystemFontOfSize:9 * K];
    [logBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [logBtn addTarget:vc action:@selector(vpmLogTapped:) forControlEvents:UIControlEventTouchUpInside];
    [podR addSubview:logBtn];

    // --- 底部双键: 教程 / 关闭 ---
    CGFloat footY = 452 * K;
    CGFloat footH = 44 * K;
    CGFloat footW = (W - 24 * K - 12 * K) / 2;
    VPMPressButton *tut = [VPMPressButton buttonWithType:UIButtonTypeCustom];
    tut.tag = VPM_TAG_TUT;
    tut.frame = CGRectMake(12 * K, footY, footW, footH);
    tut.layer.cornerRadius = 16 * K;
    tut.backgroundColor = VPMColorBlue();
    tut.layer.borderWidth = 1.5;
    tut.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
    [tut setImage:VPMBookIcon([UIColor whiteColor]) forState:UIControlStateNormal];
    tut.imageEdgeInsets = UIEdgeInsetsMake(11 * K, 11 * K, 11 * K, 11 * K);
    [tut addTarget:vc action:@selector(openTutorial) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:tut];

    VPMPressButton *close = [VPMPressButton buttonWithType:UIButtonTypeCustom];
    close.tag = VPM_TAG_CLS;
    close.frame = CGRectMake(12 * K + footW + 12 * K, footY, footW, footH);
    close.layer.cornerRadius = 16 * K;
    close.backgroundColor = VPMColorPink();
    close.layer.borderWidth = 1.5;
    close.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
    [close setImage:VPMXIcon([UIColor whiteColor]) forState:UIControlStateNormal];
    close.imageEdgeInsets = UIEdgeInsetsMake(11 * K, 11 * K, 11 * K, 11 * K);
    [close addTarget:vc action:@selector(dismissPanel) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:close];

    // 初始徽章同步 (原逻辑 0.1s 后由 updateStatusLabel 更新)
    VPMInfo(@"面板已整面重建 (原功能键 + 旋转 + 彩色注入)");
}

static void vpmLogTapped(id self, SEL _cmd, id sender) {
    [VPMController() showLogAlert];
}

// ---------------------------------------------------------------
// 旧面板实例销毁 (残留根治): 新实例 viewDidLoad 时机同步执行 —
// 旧实例窗口不回收正是"短暂停留后跳到新面板"的根因; 这里改为:
// view 整面摘除 + 独立面板窗隐藏 (悬浮球同窗时只摘面板视图)
// ---------------------------------------------------------------
static void VPMDestroyOtherPanels(id keep) {
    @try {
        NSArray *entries = VPMFindAllPanelEntries();
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
        if (any) VPMInfo(@"旧面板实例已销毁 (残留根治)");
    } @catch (NSException *e) { VPMErr(@"destroy-panels", e); }
}

// ---------------------------------------------------------------
// 面板接管: viewDidLoad 挂载 (整面重建 + 旧实例销毁 + 兜底重建)
// 此段逻辑移植自旧项目「UI源码界面虚浮窗功能 无汉字图标」的
// 面板重建/生命周期语义, 已适配当前框架 (VCamSettingsViewController
// + VCamUIPatch 补丁运行时体系, UIKit 插件式)
// ---------------------------------------------------------------
static void (*origSettingsViewDidLoad)(id, SEL) = NULL;
static void VPMSettingsViewDidLoad(id self, SEL _cmd) {
    @try {
        if (origSettingsViewDidLoad) origSettingsViewDidLoad(self, _cmd);
        // 旧实例同步销毁: 新面板创建瞬间, 屏幕上的旧面板立即消失 (无短暂停留)
        VPMDestroyOtherPanels(self);
        // 整面重建 (照源码 VPBuildPanel 布局与调用逻辑)
        VPMBuildPanel(self);
        // 兜底重建: 覆盖 swizzle 顺序差异 (若补丁 VPBuildPanel 在链内后执行)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try { VPMBuildPanel(self); } @catch (NSException *e) {}
        });
    } @catch (NSException *e) {
        VPMErr(@"settings-viewdidload", e);
        if (origSettingsViewDidLoad) origSettingsViewDidLoad(self, _cmd);
    }
}

static BOOL VPMPanelHooked = NO;
static void VPMInstallPanelHooks(void) {
    if (VPMPanelHooked) return;
    @try {
        Class settings = NSClassFromString(@"VCamSettingsViewController");
        if (!settings) return;
        Method m = class_getInstanceMethod(settings, @selector(viewDidLoad));
        if (!m) return;
        IMP orig = method_getImplementation(m);
        if (orig == (IMP)VPMSettingsViewDidLoad) { VPMPanelHooked = YES; return; }
        origSettingsViewDidLoad = (void (*)(id, SEL))orig;
        method_setImplementation(m, (IMP)VPMSettingsViewDidLoad);
        // 附加动作 (幂等; 补丁已加则跳过)
        class_addMethod(settings, @selector(vpMiniSwitchChanged:), (IMP)vpmMiniSwitchChanged, "v@:@");
        class_addMethod(settings, @selector(vpMiniTfEnd:), (IMP)vpmMiniTfEnd, "v@:@");
        class_addMethod(settings, @selector(vpRtmpSwitchChanged:), (IMP)vpmRtmpSwitchChanged, "v@:@");
class_addMethod(settings, @selector(vpmRotTapped:), (IMP)vpmRotTapped, "v@:@");
class_addMethod(settings, @selector(vpmScaleTapped:), (IMP)vpmScaleTapped, "v@:@");
class_addMethod(settings, @selector(vpmColorTapped:), (IMP)vpmColorTapped, "v@:@");
        class_addMethod(settings, @selector(vpmLogTapped:), (IMP)vpmLogTapped, "v@:@");
        VPMPanelHooked = YES;
        VPMInfo(@"面板接管: viewDidLoad 已挂载 (整面重建 + 旧实例销毁)");
    } @catch (NSException *e) { VPMErr(@"panel-install", e); }
}

static void VPMSchedulePanelInstall(void) {
    VPMInstallPanelHooks();
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(src, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                              1 * NSEC_PER_SEC, NSEC_PER_SEC);
    __block int tries = 0;
    dispatch_source_set_event_handler(src, ^{
        @autoreleasepool {
            @try {
                if (VPMPanelHooked) { dispatch_source_cancel(src); return; }
                if (++tries >= 60) {
                    VPMLogLine(@"ERR", nil, @"面板接管 60s 内未装成: 无 VCamSettingsViewController/viewDidLoad");
                    dispatch_source_cancel(src);
                    return;
                }
                VPMInstallPanelHooks();
            } @catch (NSException *e) {}
        }
    });
    dispatch_resume(src);
}

// 收集面板条目 (无界扫描): 标题标签 → responder 链命中 VCamSettingsViewController
// 得 vc 条目; 未命中得容器兜底条目 (陈旧残留视图, 永不为主面板)
static NSArray *VPMFindAllPanelEntries(void) {
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
    } @catch (NSException *e) { VPMErr(@"panel-find", e); }
    return @[];
}

static void VPMSuppressEnhancerButton(void) {
    @try {
        Class enh = NSClassFromString(@"QMEnhancerView");
        if (!enh) return;
        id inst = VPMSafeCall(enh, @selector(sharedInstance), nil);
        if (!inst) return;
        Ivar iv = class_getInstanceVariable(enh, "_floatButton");
        if (!iv) return;
        UIView *fb = object_getIvar(inst, iv);
        if (fb && !fb.hidden) {
            fb.hidden = YES;
            VPMInfo(@"增强悬浮钮已隐藏 (全局仅保留 vcam 悬浮球)");
        }
    } @catch (NSException *e) { VPMErr(@"btn-suppress", e); }
}

static void VPMTick(void) {
    @try {
        static BOOL lastVisible = NO;
        static NSInteger lastCount = -1;
        NSArray *entries = VPMFindAllPanelEntries();
        if ((NSInteger)entries.count != lastCount) {
            lastCount = entries.count;
            VPMInfo([NSString stringWithFormat:@"面板发现 %ld 个实例", (long)entries.count]);
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
            if (primaryView.tag != VPM_TAG_OWN) {
                VPMBuildPanel(primary);
            }
            // 多实例根治: 其余可见 vc 实例一律销毁 (旧实例窗口不回收 → 残留)
            VPMDestroyOtherPanels(primary);
            VPMController().panelVC = primary;
        }
        BOOL visible = (primaryView != nil);
        if (visible != lastVisible) {
            VPMInfo(visible ? @"功能面板已展开" : @"功能面板已收起");
            lastVisible = visible;
        }
        static double lastTitle = 0;
        double now = [NSDate timeIntervalSinceReferenceDate];
        if (now - lastTitle > 1.0) {
            lastTitle = now;
            [VPMController().rotBtn setTitle:
                [NSString stringWithFormat:@"🔄\n旋转 %ld°", (long)VPMReadRotation()]
                                   forState:UIControlStateNormal];
        }
        static int tick = 0;
        if (++tick % 6 == 0) VPMSuppressEnhancerButton();
    } @catch (NSException *e) { VPMErr(@"tick", e); }
}

__attribute__((constructor))
static void VPMInit(void) {
    @autoreleasepool {
        @try {
            VPMProcess p = VPMProc();
            if (p == VPMProcessOther) return;
            VPMMarkInjected(p);
            if (p == VPMProcessSpringBoard) {
                VPMInfo(@"VCamPro Max UI 层已注入 (SpringBoard)");
                VPMMigrateLegacyRotation();
                VPMSchedulePanelInstall();
                dispatch_async(dispatch_get_main_queue(), ^{
                    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
                        VPMTick();
                    }];
                });
                return;
            }
            VPMInfo([NSString stringWithFormat:@"VCamPro Max 帧层已注入 (%@)", VPMProcName(p)]);
            VPMScheduleFrameInstall();
        } @catch (NSException *e) { VPMErr(@"init", e); }
    }
}