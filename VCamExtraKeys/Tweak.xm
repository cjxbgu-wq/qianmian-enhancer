#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ---------------------------------------------------------------
// VCamExtraKeys v2: 功能键挂载模块 (旁路挂载, VCam 核心零改动)
//   根因修复(基于 v6.3.4 源码键位表):
//     - 旧版挂 VCamSettingsViewController (该 class 不存在) -> 键条永不出现
//     - v6.3.4 设计性隐藏了悬浮球 (FWCtrl +show 直接 return, 注释见 UI源码:4215)
//     - 悬浮球网格面板(196x244) 已含: 1-6=切换视频 / 转101=视频旋转 / 彩110=取色注入
//       / 正103=恢复 / 播107 停108 / 关109 / 上下左右 100/102/104/105 / 翻106
//   本模块 v2:
//     1) 运行时唤起 FWCtrl doShow -> 恢复"全局唯一悬浮按钮+功能面板" (用户要求流程)
//     2) 面板下方挂增强键条: 开关替换(toggleReplace) / 开关悬浮(doHide|doShow)
//        / 行为日志(解码核心 debug.log 显示软件行为, 调试用)  -- 前两键为 build191
//        移除、面板缺失的按键
//     3) 全部逻辑 @try/@catch, 仅 SpringBoard 进程生效, 幂等防重入
//     4) 行为日志与核心同格式(base64(XOR)): 核心已记录每个按键/旋转/偏移/注入行为,
//        本模块只读解码展示, 自身动作按同格式追写, VCam 核心零改动
// ---------------------------------------------------------------

static NSString *const QMKSharedSettingsPath = @"/tmp/qianmian_enhancer_settings.plist";
static const NSInteger QMK_BAR_TAG  = 0x6E01; // 增强键条
static const NSInteger QMK_OVER_TAG = 0x6E02; // 取色悬浮层

static void QMKMark(NSString *name) {
    @try {
        NSString *path = [NSString stringWithFormat:@"/tmp/qm_%@.txt", name];
        [@"ok" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) {}
}

// ---- 行为日志 (与 vcam 核心 debug.log 同格式: 每行 base64(XOR), 只读+同格式追写, 核心零改动) ----
static NSString *const QMKLogPath = @"/var/jb/var/mobile/Library/vcamplus/debug.log";
static const uint8_t QMKLogKey[] = {0x56,0x43,0x4D,0x2B,0x6C,0x30,0x67,0x5F,0x6B,0x33,0x79,0x21};

static NSString *QMKXorB64(NSString *plain) {
    @try {
        NSData *raw = [plain dataUsingEncoding:NSUTF8StringEncoding];
        NSMutableData *out = [NSMutableData dataWithLength:raw.length];
        const uint8_t *src = (const uint8_t *)raw.bytes;
        uint8_t *dst = (uint8_t *)out.mutableBytes;
        for (NSUInteger i = 0; i < raw.length; i++) dst[i] = src[i] ^ QMKLogKey[i % sizeof(QMKLogKey)];
        return [[out base64EncodedStringWithOptions:0] stringByAppendingString:@"\n"];
    } @catch (NSException *e) {}
    return nil;
}

static NSString *QMKXorDecode(NSString *b64) {
    @try {
        NSData *enc = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
        if (!enc) return nil;
        NSMutableData *out = [NSMutableData dataWithLength:enc.length];
        const uint8_t *src = (const uint8_t *)enc.bytes;
        uint8_t *dst = (uint8_t *)out.mutableBytes;
        for (NSUInteger i = 0; i < enc.length; i++) dst[i] = src[i] ^ QMKLogKey[i % sizeof(QMKLogKey)];
        return [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
    } @catch (NSException *e) {}
    return nil;
}

static void QMKAppendLog(NSString *msg) {
    @try {
        NSString *ts = [NSDateFormatter localizedStringFromDate:[NSDate date]
                        dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle];
        NSString *line = [NSString stringWithFormat:@"[%@] SpringBoard: %@", ts, msg];
        NSString *enc = QMKXorB64(line);
        if (!enc) return;
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:QMKLogPath]) [fm createFileAtPath:QMKLogPath contents:nil attributes:nil];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:QMKLogPath];
        [fh seekToEndOfFile]; [fh writeData:[enc dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile];
    } @catch (NSException *e) {}
}

static NSArray *QMKDecodeLog(void) {
    NSMutableArray *lines = [NSMutableArray array];
    @try {
        NSString *all = [NSString stringWithContentsOfFile:QMKLogPath encoding:NSUTF8StringEncoding error:nil];
        for (NSString *rawLine in [all componentsSeparatedByString:@"\n"]) {
            NSString *l = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (l.length == 0) continue;
            NSString *dec = QMKXorDecode(l);
            if (dec && dec.length > 0) [lines addObject:dec];
        }
    } @catch (NSException *e) {}
    return lines;
}

static BOOL QMKIsSpringBoard(void) {
    @try {
        NSString *pn = [[NSProcessInfo processInfo] processName];
        return [pn isEqualToString:@"SpringBoard"];
    } @catch (NSException *e) {}
    return NO;
}

static NSDictionary *QMKReadSettings(void) {
    @try {
        NSDictionary *s = [NSDictionary dictionaryWithContentsOfFile:QMKSharedSettingsPath];
        return s ?: @{};
    } @catch (NSException *e) {}
    return @{};
}

// ---- 屏幕快照 (三法链, 与 vcam sampleScreenColor 同构) ----
static UIImage *QMKSnapshot(void) {
    @try {
        UIScreen *screen = [UIScreen mainScreen];
        SEL s1 = NSSelectorFromString(@"_snapshotIncludingStatusBar:");
        if ([screen respondsToSelector:s1]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            UIImage *img = [screen performSelector:s1 withObject:@(NO)];
#pragma clang diagnostic pop
            if (img && img.CGImage) return img;
        }
        UIApplication *app = [UIApplication sharedApplication];
        SEL s2 = NSSelectorFromString(@"_screenshot");
        if ([app respondsToSelector:s2]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            UIImage *img = [app performSelector:s2];
#pragma clang diagnostic pop
            if (img && img.CGImage) return img;
        }
        UIWindow *win = [app keyWindow];
        if (win) {
            UIGraphicsBeginImageContextWithOptions(win.bounds.size, YES, 0.25);
            [win drawViewHierarchyInRect:win.bounds afterScreenUpdates:NO];
            UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            if (img && img.CGImage) return img;
        }
    } @catch (NSException *e) {}
    return nil;
}

static UIColor *QMKColorAtPoint(CGPoint point, UIImage *image) {
    @try {
        CGImageRef cgImage = image.CGImage;
        if (!cgImage) return [UIColor whiteColor];
        size_t w = CGImageGetWidth(cgImage);
        size_t h = CGImageGetHeight(cgImage);
        if (point.x < 0 || point.y < 0 || point.x >= w || point.y >= h) return [UIColor whiteColor];
        unsigned char *pixel = (unsigned char *)calloc(4, 1);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(pixel, 1, 1, 8, 4, cs,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(cs);
        if (!ctx) { free(pixel); return [UIColor whiteColor]; }
        CGContextSetBlendMode(ctx, kCGBlendModeCopy);
        CGContextDrawImage(ctx, CGRectMake(-point.x, point.y - h, w, h), cgImage);
        CGContextRelease(ctx);
        UIColor *c = [UIColor colorWithRed:pixel[0] / 255.0 green:pixel[1] / 255.0
                                      blue:pixel[2] / 255.0 alpha:1.0];
        free(pixel);
        return c;
    } @catch (NSException *e) {}
    return [UIColor whiteColor];
}

static void QMKPress(UIView *v, BOOL down) {
    [UIView animateWithDuration:0.08 animations:^{
        v.transform = down ? CGAffineTransformMakeScale(0.92, 0.92) : CGAffineTransformIdentity;
        v.alpha = down ? 0.85 : 1.0;
    }];
}

// ---- 功能键控制器 (单例, 保存取色状态 + 键条引用) ----
@interface QMKExtraController : NSObject
@property (nonatomic, strong) UIImage *snapshot;
@property (nonatomic, strong) UIView *overlay;
@property (nonatomic, strong) UIView *bar;
@property (nonatomic, strong) UIButton *replaceBtn;
@property (nonatomic, strong) UIButton *floatBtn;
@property (nonatomic, strong) UIButton *logBtn;
@property (nonatomic, weak) id fwCtrl;
- (void)startPick:(UIButton *)sender;
- (void)handlePickTap:(UITapGestureRecognizer *)g;
- (void)replaceTapped;
- (void)floatToggle;
- (void)logTapped;
- (void)installBarNearPanel:(UIView *)panel;
@end

// ---- 前向声明 (避免隐式声明编译错误) ----
static QMKExtraController *QMKController(void);
static id FWCtrlShared(void);

@implementation QMKExtraController

- (void)startPick:(UIButton *)sender {
    @try {
        QMKPress(sender, YES);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            QMKPress(sender, NO);
        });
        if (self.overlay) return; // 已在取色中
        UIImage *snap = QMKSnapshot();
        if (!snap) return;
        self.snapshot = snap;
        // 取色层挂到键条所在窗口, 无 host 时回退主窗口
        UIWindow *win = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
        UIView *root = win ? win : [UIApplication sharedApplication].keyWindow;
        if (!root) return;
        UIView *ov = [[UIView alloc] initWithFrame:root.bounds];
        ov.tag = QMK_OVER_TAG;
        ov.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 260, 40)];
        hint.text = @"点击任意位置取色  轻点顶部取消";
        hint.textAlignment = NSTextAlignmentCenter;
        hint.textColor = [UIColor whiteColor];
        hint.font = [UIFont boldSystemFontOfSize:15];
        hint.backgroundColor = [UIColor colorWithWhite:0 alpha:0.65];
        hint.layer.cornerRadius = 10;
        hint.clipsToBounds = YES;
        hint.center = CGPointMake(ov.bounds.size.width / 2, 100);
        [ov addSubview:hint];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handlePickTap:)];
        [ov addGestureRecognizer:tap];
        [root addSubview:ov];
        self.overlay = ov;
        QMKAppendLog(@"增强键条: 取色开始 (请点击屏幕取色)");
    } @catch (NSException *e) {}
}

- (void)handlePickTap:(UITapGestureRecognizer *)g {
    @try {
        UIView *ov = self.overlay;
        if (!ov) return;
        CGPoint p = [g locationInView:ov];
        if (p.y < 60) { // 顶部取消
            [ov removeFromSuperview];
            self.overlay = nil;
            self.snapshot = nil;
            QMKAppendLog(@"增强键条: 取色已取消");
            return;
        }
        UIImage *img = self.snapshot;
        if (img && img.CGImage) {
            CGFloat ratio = CGImageGetWidth(img.CGImage) / MAX(ov.bounds.size.width, 1);
            CGPoint ip = CGPointMake(p.x * ratio, p.y * ratio);
            UIColor *c = QMKColorAtPoint(ip, img);
            CGFloat r, g, b, a;
            [c getRed:&r green:&g blue:&b alpha:&a];
            NSMutableDictionary *s = [NSMutableDictionary dictionaryWithDictionary:QMKReadSettings()];
            [s setObject:@YES forKey:@"colorMappingEnabled"];
            [s setObject:@(r) forKey:@"colorRed"];
            [s setObject:@(g) forKey:@"colorGreen"];
            [s setObject:@(b) forKey:@"colorBlue"];
            [s writeToFile:QMKSharedSettingsPath atomically:YES];
            NSString *hex = [NSString stringWithFormat:@"#%02X%02X%02X", (int)(r * 255), (int)(g * 255), (int)(b * 255)];
            @try {
                [hex writeToFile:@"/tmp/qm_colorpick_result.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
            } @catch (NSException *e) {}
            QMKAppendLog([NSString stringWithFormat:@"增强键条: 取色完成 %@ 映射已启用", hex]);
        }
        [ov removeFromSuperview];
        self.overlay = nil;
        self.snapshot = nil;
    } @catch (NSException *e) {}
}

// 开关替换: 走 vcam 核心 toggleReplace (VCAM_FLAG 文件控制, 核心内部完成状态与日志)
- (void)replaceTapped {
    @try {
        id fw = self.fwCtrl;
        if (!fw) return;
        QMKPress(self.replaceBtn, YES);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            QMKPress(self.replaceBtn, NO);
        });
        if ([fw respondsToSelector:@selector(toggleReplace)]) {
            [fw performSelector:@selector(toggleReplace)];
        }
        BOOL en = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/var/mobile/Library/vcamplus/enabled"];
        QMKAppendLog([NSString stringWithFormat:@"增强键条: 开关替换 -> %@", en ? @"ON" : @"OFF"]);
    } @catch (NSException *e) {}
}

// 开关悬浮: doHide | doShow (与面板"关"键 109 同语义, 键条自身隐藏跟随)
- (void)floatToggle {
    @try {
        id fw = self.fwCtrl;
        if (!fw) return;
        QMKPress(self.floatBtn, YES);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            QMKPress(self.floatBtn, NO);
        });
        if ([fw respondsToSelector:@selector(doHide)]) {
            [fw performSelector:@selector(doHide)];
        }
        QMKAppendLog(@"增强键条: 开关悬浮 -> 隐藏");
        if (self.bar) {
            self.bar.hidden = YES;
        }
    } @catch (NSException *e) {}
}

- (void)logTapped {
    @try {
        QMKPress(self.logBtn, YES);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            QMKPress(self.logBtn, NO);
        });
        QMKAppendLog(@"增强键条: 行为日志已查看");
        NSArray *lines = QMKDecodeLog();
        NSString *msg;
        if (lines.count > 0) {
            NSInteger n = MIN((NSInteger)lines.count, 25);
            NSRange tail = NSMakeRange((NSInteger)lines.count - n, n);
            NSMutableString *m = [NSMutableString string];
            for (NSString *l in [[lines subarrayWithRange:tail] reverseObjectEnumerator]) {
                [m appendFormat:@"%@\n", l];
            }
            msg = m;
        } else {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *pipe = [fm fileExistsAtPath:@"/tmp/qm_update_called.txt"] ? @"OK" : @"FAIL";
            NSString *mod  = [fm fileExistsAtPath:@"/tmp/qm_enhancer_injected.txt"] ? @"OK" : @"FAIL";
            msg = [NSString stringWithFormat:@"[行为日志为空]\n像素管线: %@\n增强模块注入: %@\n日志路径: %@", pipe, mod, QMKLogPath];
        }
        UIWindow *win = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
        UIViewController *vc = win ? win.rootViewController : nil;
        if (!vc) return;
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"行为日志 (调试)" message:msg
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [al addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:al animated:YES completion:nil];
    } @catch (NSException *e) {}
}

// 增强键条: 挂在 vcam 悬浮面板正下方 (面板 196x244), 3 键等宽
- (void)installBarNearPanel:(UIView *)panel {
    @try {
        if (!panel) return;
        if (self.bar) {
            [self.bar removeFromSuperview];
            self.bar = nil;
        }
        UIView *root = panel.superview;
        if (!root) return;
        CGRect pf = panel.frame;
        if (pf.size.width < 100 || pf.size.height < 100) return;

        CGFloat pw = pf.size.width;
        CGFloat bw = pw;
        CGFloat bh = 36;
        CGFloat by = CGRectGetMaxY(pf) + 8;
        CGRect screen = [UIScreen mainScreen].bounds;
        if (by + bh > screen.size.height - 10) {
            by = CGRectGetMinY(pf) - bh - 8; // 底部越界时翻到面板上方
        }
        if (by < 10) by = 10;

        UIColor *c1 = [UIColor colorWithRed:0.31 green:0.86 blue:1.0 alpha:1.0]; // 极光青
        UIColor *c2 = [UIColor colorWithRed:0.71 green:0.47 blue:1.0 alpha:1.0]; // 极光紫

        UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(pf.origin.x, by, bw, bh)];
        bar.tag = QMK_BAR_TAG;
        bar.layer.cornerRadius = 12;
        bar.layer.borderWidth = 1;
        bar.layer.borderColor = c2.CGColor;
        bar.backgroundColor = [UIColor colorWithRed:0.063 green:0.102 blue:0.173 alpha:0.96];
        bar.layer.shadowColor = [UIColor blackColor].CGColor;
        bar.layer.shadowOpacity = 0.4f;
        bar.layer.shadowOffset = CGSizeMake(0, 8);
        bar.layer.shadowRadius = 20;

        CGFloat pad = 4;
        CGFloat btnW = (bw - pad * 4) / 3;
        CGFloat btnH = bh - pad * 2;

        // 开关替换
        UIButton *rep = [UIButton buttonWithType:UIButtonTypeCustom];
        rep.frame = CGRectMake(pad, pad, btnW, btnH);
        rep.layer.cornerRadius = 8;
        rep.layer.borderWidth = 1;
        rep.layer.borderColor = c1.CGColor;
        rep.backgroundColor = [UIColor colorWithWhite:0.18 alpha:0.7];
        [rep setTitle:@"开关替换" forState:UIControlStateNormal];
        rep.titleLabel.font = [UIFont boldSystemFontOfSize:10];
        [rep setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [rep addTarget:QMKController() action:@selector(replaceTapped) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:rep];
        QMKController().replaceBtn = rep;

        // 开关悬浮
        UIButton *flt = [UIButton buttonWithType:UIButtonTypeCustom];
        flt.frame = CGRectMake(pad * 2 + btnW, pad, btnW, btnH);
        flt.layer.cornerRadius = 8;
        flt.layer.borderWidth = 1;
        flt.layer.borderColor = c2.CGColor;
        flt.backgroundColor = [UIColor colorWithWhite:0.18 alpha:0.7];
        [flt setTitle:@"开关悬浮" forState:UIControlStateNormal];
        flt.titleLabel.font = [UIFont boldSystemFontOfSize:10];
        [flt setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [flt addTarget:QMKController() action:@selector(floatToggle) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:flt];
        QMKController().floatBtn = flt;

        // 安装日志
        UIButton *log = [UIButton buttonWithType:UIButtonTypeCustom];
        log.frame = CGRectMake(pad * 3 + btnW * 2, pad, btnW, btnH);
        log.layer.cornerRadius = 8;
        log.layer.borderWidth = 1;
        log.layer.borderColor = c2.CGColor;
        log.backgroundColor = [UIColor colorWithWhite:0.18 alpha:0.7];
        [log setTitle:@"安装日志" forState:UIControlStateNormal];
        log.titleLabel.font = [UIFont boldSystemFontOfSize:10];
        [log setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [log addTarget:QMKController() action:@selector(logTapped) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:log];
        QMKController().logBtn = log;

        [root addSubview:bar];
        self.bar = bar;
        self.fwCtrl = FWCtrlShared();
        QMKMark(@"colorpick_injected"); // 键条注入成功标记
    } @catch (NSException *e) {}
}

@end

static QMKExtraController *QMKController(void) {
    static QMKExtraController *c = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [QMKExtraController new]; });
    return c;
}

static id FWCtrlShared(void) {
    @try {
        Class fw = NSClassFromString(@"FWCtrl");
        if (!fw) return nil;
        return [fw performSelector:@selector(shared)];
    } @catch (NSException *e) {}
    return nil;
}

// ---- FWCtrl.togglePanel swizzle: 面板开关时同步增强键条 ----
static void (*QMKToggleOrig)(id, SEL) = NULL;
static void QMKToggleHook(id self, SEL _cmd) {
    if (QMKToggleOrig) QMKToggleOrig(self, _cmd);
    @try {
        if (!QMKIsSpringBoard()) return;
        UIView *panel = [self valueForKey:@"_panel"];
        if (!panel) return;
        BOOL visible = !panel.hidden;
        QMKController().fwCtrl = self;
        if (visible) {
            [QMKController() installBarNearPanel:panel];
            QMKAppendLog(@"增强键条: 功能面板已展开");
        } else {
            if (QMKController().bar) QMKController().bar.hidden = YES;
            QMKAppendLog(@"增强键条: 功能面板已收起");
        }
    } @catch (NSException *e) {}
}

// ---- 唤起悬浮球 (v6.3.4 设计性隐藏, 用户需求恢复; 仅 SpringBoard, 幂等) ----
static void QMKShowFloatBall(void) {
    @try {
        if (!QMKIsSpringBoard()) return;
        static BOOL shown = NO;
        if (shown) return;
        id fw = FWCtrlShared();
        if (!fw) return;
        if ([fw respondsToSelector:@selector(doShow)]) {
            [fw performSelector:@selector(doShow)];
            shown = YES;
            QMKAppendLog(@"增强模块: 悬浮球已恢复 (doShow)");
        }
    } @catch (NSException *e) {}
}

// ---- 挂载 (FWCtrl 真实类 + 延迟重试, 与 vcam 加载时序解耦) ----
static BOOL QMKInstalled = NO;

static void QMKInstallSwizzles(void) {
    if (QMKInstalled) return;
    Class fw = NSClassFromString(@"FWCtrl");
    if (!fw) return; // 类未加载, 由重试调度补装
    Method m = class_getInstanceMethod(fw, @selector(togglePanel));
    if (!m) return;
    QMKToggleOrig = (void (*)(id, SEL))method_getImplementation(m);
    if (!class_addMethod(fw, @selector(togglePanel), (IMP)QMKToggleHook, method_getTypeEncoding(m))) {
        method_setImplementation(m, (IMP)QMKToggleHook);
    }
    QMKInstalled = YES;
    QMKShowFloatBall();
}

__attribute__((constructor))
static void QMKInit(void) {
    @autoreleasepool {
        QMKInstallSwizzles();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            QMKInstallSwizzles();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                QMKInstallSwizzles();
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    QMKInstallSwizzles();
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        QMKInstallSwizzles();
                    });
                });
            });
        });
    }
}
