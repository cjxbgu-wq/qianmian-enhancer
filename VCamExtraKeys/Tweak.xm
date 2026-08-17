#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ---------------------------------------------------------------
// VCamExtraKeys: 功能键挂载模块 (旁路挂载, 现有项目零改动)
//   屏幕取色键: 按键 -> 截屏(三法链, 参考主源码 sampleScreenColor) -> 悬浮窗 -> 点选 -> 写共享设置
//   视频旋转键: 循环 0/90/180/270, 写共享设置 videoRotation (增强模块像素链内旋转)
//   安装日志键: 检测注入状态 (像素管线/增强模块/取色注入/映射状态/旋转角度)
// 全部逻辑 @try/@catch 包裹, 异常不影响 vcam-v3 现有流程
// ---------------------------------------------------------------

static NSString *const QMKSharedSettingsPath = @"/tmp/qianmian_enhancer_settings.plist";
static const NSInteger QMK_BAR_TAG  = 0x6E01; // 功能键条
static const NSInteger QMK_OVER_TAG = 0x6E02; // 取色悬浮层
static const NSInteger QMK_DOT_TAG  = 0x6E03; // 取色色点

static void QMKMark(NSString *name) {
    @try {
        NSString *path = [NSString stringWithFormat:@"/tmp/qm_%@.txt", name];
        [@"ok" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) {}
}

static NSDictionary *QMKReadSettings(void) {
    @try {
        NSDictionary *s = [NSDictionary dictionaryWithContentsOfFile:QMKSharedSettingsPath];
        return s ?: @{};
    } @catch (NSException *e) {}
    return @{};
}

static void QMKWriteSetting(NSString *key, id value) {
    @try {
        NSMutableDictionary *s = [NSMutableDictionary dictionaryWithDictionary:QMKReadSettings()];
        [s setObject:value forKey:key];
        [s writeToFile:QMKSharedSettingsPath atomically:YES];
    } @catch (NSException *e) {}
}

static NSInteger QMKIntSetting(NSString *key, NSInteger def) {
    NSDictionary *s = QMKReadSettings();
    if ([s objectForKey:key]) return [[s objectForKey:key] integerValue];
    return def;
}

// ---- 屏幕快照 (参考主源码 sampleScreenColor 三法链) ----
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

// ---- 功能键控制器 (单例, 保存取色状态) ----
@interface QMKExtraController : NSObject
@property (nonatomic, strong) UIImage *snapshot;
@property (nonatomic, strong) UIView *overlay;
@property (nonatomic, strong) UIButton *rotateButton;
@property (nonatomic, strong) UILabel *rotateLabel;
@property (nonatomic, weak) UIViewController *host;
- (void)startPick:(UIButton *)sender;
- (void)handlePickTap:(UITapGestureRecognizer *)g;
- (void)rotateTapped;
- (void)logTapped;
- (void)updateRotateLabel;
- (void)refreshPickDot;
@end

@implementation QMKExtraController

- (void)startPick:(UIButton *)sender {
    @try {
        QMKPress(sender, YES);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            QMKPress(sender, NO);
        });
        if (self.overlay) return; // 已在取色中
        UIImage *snap = QMKSnapshot(); // 先截屏(不含遮罩)
        if (!snap) return;
        self.snapshot = snap;
        UIView *root = self.host ? self.host.view : nil;
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
            [self refreshPickDot];
        }
        [ov removeFromSuperview];
        self.overlay = nil;
        self.snapshot = nil;
    } @catch (NSException *e) {}
}

- (void)rotateTapped {
    @try {
        NSInteger cur = QMKIntSetting(@"videoRotation", 0);
        NSInteger next = (cur + 90) % 360;
        QMKWriteSetting(@"videoRotation", @(next));
        [self updateRotateLabel];
    } @catch (NSException *e) {}
}

- (void)updateRotateLabel {
    @try {
        if (self.rotateLabel) {
            NSInteger cur = QMKIntSetting(@"videoRotation", 0);
            self.rotateLabel.text = [NSString stringWithFormat:@"旋转 %ld°", (long)cur];
        }
    } @catch (NSException *e) {}
}

- (void)refreshPickDot {
    @try {
        UIView *root = self.host ? self.host.view : nil;
        UIView *dot = [root viewWithTag:QMK_DOT_TAG];
        if (!dot) return;
        NSDictionary *s = QMKReadSettings();
        if ([[s objectForKey:@"colorMappingEnabled"] boolValue]) {
            CGFloat r = [[s objectForKey:@"colorRed"] floatValue];
            CGFloat g = [[s objectForKey:@"colorGreen"] floatValue];
            CGFloat b = [[s objectForKey:@"colorBlue"] floatValue];
            dot.backgroundColor = [UIColor colorWithRed:r green:g blue:b alpha:1.0];
        } else {
            dot.backgroundColor = [UIColor colorWithWhite:0.7 alpha:1.0];
        }
    } @catch (NSException *e) {}
}

- (void)logTapped {
    @try {
        UIViewController *vc = self.host;
        if (!vc) return;
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *pipe = [fm fileExistsAtPath:@"/tmp/qm_update_called.txt"] ? @"OK" : @"FAIL";
        NSString *mod  = [fm fileExistsAtPath:@"/tmp/qm_enhancer_injected.txt"] ? @"OK" : @"FAIL";
        NSString *pick = [fm fileExistsAtPath:@"/tmp/qm_colorpick_injected.txt"] ? @"OK" : @"FAIL";
        NSDictionary *s = QMKReadSettings();
        BOOL mapOn = [[s objectForKey:@"colorMappingEnabled"] boolValue];
        NSString *hex = @"#FFFFFF";
        if (mapOn) {
            hex = [NSString stringWithFormat:@"#%02X%02X%02X",
                   (int)([[s objectForKey:@"colorRed"] floatValue] * 255),
                   (int)([[s objectForKey:@"colorGreen"] floatValue] * 255),
                   (int)([[s objectForKey:@"colorBlue"] floatValue] * 255)];
        }
        NSString *rot = [NSString stringWithFormat:@"%ld°", (long)QMKIntSetting(@"videoRotation", 0)];
        NSString *msg = [NSString stringWithFormat:
            @"[像素管线] 帧处理命中: %@\n[增强模块] dylib 注入: %@\n[屏幕取色] 取色模块注入: %@\n[映射状态] %@\n[视频旋转] %@",
            pipe, mod, pick, (mapOn ? [@"已启用 " stringByAppendingString:hex] : @"未启用"), rot];
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"安装日志" message:msg
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [al addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:al animated:YES completion:nil];
    } @catch (NSException *e) {}
}

@end

static QMKExtraController *QMKController(void) {
    static QMKExtraController *c = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [QMKExtraController new]; });
    return c;
}

// ---- 功能键条构建 (幂等) ----
static void QMKInstallBar(UIViewController *vc) {
    @try {
        UIView *root = vc.view;
        if (!root) return;
        if ([root viewWithTag:QMK_BAR_TAG]) return;
        CGFloat W = root.bounds.size.width;
        CGFloat H = root.bounds.size.height;
        if (W < 200 || H < 300) return;
        CGFloat K = MIN(W / 390.0, H / 844.0);

        UIColor *c1 = [UIColor colorWithRed:0.31 green:0.86 blue:1.0 alpha:1.0]; // 极光青
        UIColor *c2 = [UIColor colorWithRed:0.71 green:0.47 blue:1.0 alpha:1.0]; // 极光紫
        UIColor *c3 = [UIColor colorWithRed:1.0 green:0.47 blue:0.78 alpha:1.0]; // 极光粉

        // 增强键条: 位于底部双键之下
        CGFloat barY = (402 * K + 44 * K + 8 * K);
        CGFloat barH = 40 * K;
        UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(12 * K, barY, W - 24 * K, barH)];
        bar.tag = QMK_BAR_TAG;
        bar.layer.cornerRadius = 14 * K;
        bar.layer.borderWidth = 1;
        bar.layer.borderColor = c2.CGColor;
        bar.backgroundColor = [UIColor colorWithRed:0.063 green:0.102 blue:0.173 alpha:0.96];
        bar.layer.shadowColor = [UIColor blackColor].CGColor;
        bar.layer.shadowOpacity = 0.4f;
        bar.layer.shadowOffset = CGSizeMake(0, 8 * K);
        bar.layer.shadowRadius = 20 * K;

        CGFloat bw = (bar.bounds.size.width - 16 * K - 10 * K) / 3;
        CGFloat by = 5 * K;
        CGFloat bh = barH - 10 * K;

        // 取色键
        UIButton *pick = [UIButton buttonWithType:UIButtonTypeCustom];
        pick.frame = CGRectMake(8 * K, by, bw, bh);
        pick.layer.cornerRadius = 10 * K;
        pick.layer.borderWidth = 1;
        pick.layer.borderColor = c1.CGColor;
        pick.backgroundColor = [UIColor colorWithWhite:0.18 alpha:0.7];
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(10 * K, (bh - 12 * K) / 2, 12 * K, 12 * K)];
        dot.tag = QMK_DOT_TAG;
        dot.layer.cornerRadius = 6 * K;
        dot.layer.borderWidth = 1;
        dot.layer.borderColor = [UIColor whiteColor].CGColor;
        dot.backgroundColor = [UIColor colorWithWhite:0.7 alpha:1.0];
        [pick addSubview:dot];
        UILabel *pl = [[UILabel alloc] initWithFrame:CGRectMake(28 * K, 0, bw - 30 * K, bh)];
        pl.text = @"屏幕取色";
        pl.font = [UIFont boldSystemFontOfSize:10 * K];
        pl.textColor = [UIColor whiteColor];
        [pick addSubview:pl];
        [pick addTarget:QMKController() action:@selector(startPick:) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:pick];

        // 旋转键
        UIButton *rot = [UIButton buttonWithType:UIButtonTypeCustom];
        rot.frame = CGRectMake(8 * K + bw + 5 * K, by, bw, bh);
        rot.layer.cornerRadius = 10 * K;
        rot.layer.borderWidth = 1;
        rot.layer.borderColor = c3.CGColor;
        rot.backgroundColor = [UIColor colorWithWhite:0.18 alpha:0.7];
        UILabel *rl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, bw, bh)];
        rl.font = [UIFont boldSystemFontOfSize:10 * K];
        rl.textColor = [UIColor whiteColor];
        rl.textAlignment = NSTextAlignmentCenter;
        [rot addSubview:rl];
        [rot addTarget:QMKController() action:@selector(rotateTapped) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:rot];
        QMKController().rotateButton = rot;
        QMKController().rotateLabel = rl;

        // 日志键
        UIButton *log = [UIButton buttonWithType:UIButtonTypeCustom];
        log.frame = CGRectMake(8 * K + 2 * (bw + 5 * K), by, bw, bh);
        log.layer.cornerRadius = 10 * K;
        log.layer.borderWidth = 1;
        log.layer.borderColor = c2.CGColor;
        log.backgroundColor = [UIColor colorWithWhite:0.18 alpha:0.7];
        UILabel *ll = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, bw, bh)];
        ll.text = @"安装日志";
        ll.font = [UIFont boldSystemFontOfSize:10 * K];
        ll.textColor = [UIColor whiteColor];
        ll.textAlignment = NSTextAlignmentCenter;
        [log addSubview:ll];
        [log addTarget:QMKController() action:@selector(logTapped) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:log];

        [root addSubview:bar];
        [QMKController() updateRotateLabel];
        [QMKController() refreshPickDot];
        QMKMark(@"colorpick_injected"); // 取色功能键/悬浮窗注入成功
    } @catch (NSException *e) {}
}

// ---- 挂载 (swizzle + 延迟重试, 与 VCamUIPatch 同模式) ----
static BOOL QMKInstalled = NO;
static void (*QMKOrigViewDidLoad)(id, SEL) = NULL;

static void QMKViewDidLoad(id self, SEL _cmd) {
    if (QMKOrigViewDidLoad) QMKOrigViewDidLoad(self, _cmd);
    @try {
        QMKController().host = (UIViewController *)self;
        QMKInstallBar((UIViewController *)self);
    } @catch (NSException *e) {}
}

static void QMKInstallSwizzles(void) {
    if (QMKInstalled) return;
    Class settings = NSClassFromString(@"VCamSettingsViewController");
    if (!settings) return; // 类未加载, 由重试调度补装
    Method m = class_getInstanceMethod(settings, @selector(viewDidLoad));
    if (!m) return;
    QMKOrigViewDidLoad = (void (*)(id, SEL))method_getImplementation(m);
    if (!class_addMethod(settings, @selector(viewDidLoad), (IMP)QMKViewDidLoad, method_getTypeEncoding(m))) {
        method_setImplementation(m, (IMP)QMKViewDidLoad);
    }
    QMKInstalled = YES;
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
                });
            });
        });
    }
}
