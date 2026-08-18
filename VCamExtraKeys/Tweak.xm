// ===============================================================
// VCamExtraKeys v3 — 功能键挂载模块 (旁路挂载, 核心/补丁/增强 零改动)
// ===============================================================
// v3 根因重写 (基于部署真源比对):
//   v1/v2 挂 FWCtrl / doShow / togglePanel / btnTap — 该类与方法只存在于
//   "UI界面配置\UI源码\Tweak.xm"(vcamplus 旧 UI 参考源码), 设备部署的
//   vcamv3.dylib + VCamUIPatch.dylib + QianmianEnhancer.dylib 均无此类
//   (已对部署二进制做字符串级实证) → 模块整体空转, "没有任何改变"。
//   部署真源: VCamSettingsViewController(面板) + VCamFloatingBall(悬浮球)
//             + VCamUIPatch 方案J(面板重建) + QMEnhancerView(增强面板)
// v3 设计约束:
//   1) 不 swizzle 任何 vcam 类 — 纯视图锚点轮询 + performSelector 转发
//   2) 面板键条挂载在方案J 面板窗底部 (VPBuildPanel 清空子视图后重挂, tag 幂等)
//   3) 视频旋转: 合并写 /tmp/qianmian_enhancer_settings.plist 的 videoRotation
//      (消费端 = 增强模块 mediaserverd 侧 processFrame: 逐帧应用, 已实证)
//   4) 取色增强: 转发 QMEnhancerView enterColorPickMode (复用同一取色流程)
//   5) 增强面板: 转发 QMEnhancerView togglePanel (模块展开, 保留缩放/滤镜等)
//   6) 全局唯一悬浮按钮: 3s 定时器隐藏增强模块悬浮钮 (其 checkAndReadd 5s 重挂,
//      我们周期性重隐藏, 不改其代码); vcam 球保持唯一入口
//   7) 行为日志: 本模块自记 /tmp/qianmian_behavior.log (部署核心不写
//      vcamplus debug.log, v2 的 XOR 解码对象不存在, 已废弃)
//   8) 全部逻辑 @try/@catch, 仅 SpringBoard 生效, 幂等
// ===============================================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const QMKSharedSettingsPath = @"/tmp/qianmian_enhancer_settings.plist";
static NSString *const QMKBehaviorLogPath    = @"/tmp/qianmian_behavior.log";
static const NSInteger QMK_BAR_TAG    = 0x6E10; // 增强键条 (防与面板控件冲突)
static const NSInteger QMK_ROTBTN_TAG = 0x6E11; // 旋转键 (标题随当前角度刷新)

static void QMKMark(NSString *name) {
    @try {
        NSString *path = [NSString stringWithFormat:@"/tmp/qm_%@.txt", name];
        [@"ok" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) {}
}

static BOOL QMKIsSpringBoard(void) {
    @try {
        NSString *pn = [[NSProcessInfo processInfo] processName];
        return [pn isEqualToString:@"SpringBoard"];
    } @catch (NSException *e) {}
    return NO;
}

// 行为日志: 纯追加一行 (时间戳 + 动作), 调试软件时记录软件行为
static void QMKLog(NSString *msg) {
    @try {
        NSString *ts = [NSDateFormatter localizedStringFromDate:[NSDate date]
                        dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle];
        NSString *line = [NSString stringWithFormat:@"%@ [VCamExtraKeys] %@\n", ts, msg];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:QMKBehaviorLogPath]) {
            [fm createFileAtPath:QMKBehaviorLogPath contents:nil attributes:nil];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:QMKBehaviorLogPath];
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) {}
}

// 共享设置读取: 文件缺失时返回空字典 (与增强模块默认一致)
static NSDictionary *QMKReadSettings(void) {
    @try {
        NSDictionary *s = [NSDictionary dictionaryWithContentsOfFile:QMKSharedSettingsPath];
        return s ?: @{};
    } @catch (NSException *e) {}
    return @{};
}

// 共享设置写入: 必须合并后再写 — 增强模块 saveCurrentSettings 亦为合并写,
// 直接覆盖会丢 videoRotation 等外部键 (并发写风险由 atomically 原子落盘兜底)
static void QMKWriteSettings(NSDictionary *settings) {
    @try {
        [settings writeToFile:QMKSharedSettingsPath atomically:YES];
    } @catch (NSException *e) {}
}

// ---- 转发辅助: 无警告 performSelector ----
static id QMKSafeCall(id target, SEL sel, id arg) {
    if (!target || !sel || ![target respondsToSelector:sel]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return arg ? [target performSelector:sel withObject:arg] : [target performSelector:sel];
#pragma clang diagnostic pop
}

// ---- 视频旋转: 0/90/180/270 四态循环 (值域钳制), 消费端 = 增强模块帧处理 ----
static NSInteger QMKNextRotation(void) {
    NSInteger cur = [[QMKReadSettings() objectForKey:@"videoRotation"] integerValue];
    if (cur < 0) cur = 0;                      // 异常值钳制 (负数/脏数据)
    NSInteger next = (cur + 90) % 360;         // 循环: 270 -> 0 不越界
    NSMutableDictionary *s = [NSMutableDictionary dictionaryWithDictionary:QMKReadSettings()];
    [s setObject:@(next) forKey:@"videoRotation"];
    QMKWriteSettings(s);
    QMKLog([NSString stringWithFormat:@"视频旋转: %ld° -> %ld°", (long)cur, (long)next]);
    return next;
}

static NSInteger QMKCurrentRotation(void) {
    NSInteger cur = [[QMKReadSettings() objectForKey:@"videoRotation"] integerValue];
    return (cur < 0 || cur > 270) ? 0 : cur;
}

// ---- 取色增强: 转发增强模块现有取色流程 (不重写取色逻辑, 行为一致) ----
static BOOL QMKEnterColorPick(void) {
    Class enh = NSClassFromString(@"QMEnhancerView");
    if (!enh) { QMKLog(@"取色增强: 增强模块未加载, 已跳过"); return NO; }
    id inst = QMKSafeCall(enh, @selector(sharedInstance), nil);
    if (!inst) { QMKLog(@"取色增强: 增强单例不可用, 已跳过"); return NO; }
    // enterColorPickMode 为 void: 以 respondsToSelector 为准, 不取返回值
    if ([inst respondsToSelector:@selector(enterColorPickMode)]) {
        QMKSafeCall(inst, @selector(enterColorPickMode), nil);
        QMKLog(@"取色增强: 已进入屏幕取色模式");
        return YES;
    }
    QMKLog(@"取色增强: 增强模块无 enterColorPickMode, 已跳过");
    return NO;
}

// ---- 增强面板: 模块展开/收起 (保留缩放/滤镜/美颜/肤色等全部功能) ----
static void QMKToggleEnhancerPanel(void) {
    Class enh = NSClassFromString(@"QMEnhancerView");
    if (!enh) { QMKLog(@"增强面板: 增强模块未加载, 已跳过"); return; }
    id inst = QMKSafeCall(enh, @selector(sharedInstance), nil);
    // togglePanel 为 void: 以 respondsToSelector 为准, 不取返回值
    if (inst && [inst respondsToSelector:@selector(togglePanel)]) {
        QMKSafeCall(inst, @selector(togglePanel), nil);
        QMKLog(@"增强面板: 展开/收起已切换");
    } else {
        QMKLog(@"增强面板: 切换失败 (增强单例不可用)");
    }
}

// ---- 悬浮钮抑制: 保持全局唯一悬浮球 (vcam 球) ----
// 增强模块 checkAndReadd 每 5s 把悬浮钮重挂回 keyWindow; 我们每 3s 重隐藏,
// 只操作视图 hidden, 不碰增强模块代码 (KVC 读取其私有 ivar, 只读不改)
static void QMKSuppressEnhancerButton(void) {
    Class enh = NSClassFromString(@"QMEnhancerView");
    if (!enh) return;
    id inst = QMKSafeCall(enh, @selector(sharedInstance), nil);
    if (!inst) return;
    Ivar iv = class_getInstanceVariable(enh, "_floatButton");
    if (!iv) return;
    UIView *fb = object_getIvar(inst, iv);
    if (fb && !fb.hidden) {
        fb.hidden = YES;
        QMKLog(@"增强悬浮钮已隐藏 (全局仅保留 vcam 悬浮球)");
    }
}

// ---- 行为日志展示: 取最近 25 行, 最新在上 ----
static NSString *QMKLogTail(void) {
    NSMutableArray *lines = [NSMutableArray array];
    @try {
        NSString *all = [NSString stringWithContentsOfFile:QMKBehaviorLogPath
                                                  encoding:NSUTF8StringEncoding error:nil];
        for (NSString *rawLine in [all componentsSeparatedByString:@"\n"]) {
            NSString *l = [rawLine stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (l.length > 0) [lines addObject:l];
        }
    } @catch (NSException *e) {}
    if (lines.count == 0) return @"[行为日志为空]";
    NSInteger n = MIN((NSInteger)lines.count, 25);
    NSRange tail = NSMakeRange((NSInteger)lines.count - n, n);
    NSMutableString *m = [NSMutableString string];
    for (NSString *l in [[lines subarrayWithRange:tail] reverseObjectEnumerator]) {
        [m appendFormat:@"%@\n", l];
    }
    return m;
}

// ---- 键条控制器 (单例: 持有面板 VC 引用与旋转键, 供按钮动作使用) ----
@interface QMKExtraController : NSObject
@property (nonatomic, weak) UIViewController *panelVC;
@property (nonatomic, strong) UIButton *rotBtn;
- (void)rotateTapped;
- (void)colorPickTapped;
- (void)enhancerPanelTapped;
- (void)logTapped;
@end

@implementation QMKExtraController

// 视频旋转键: 循环 + 键标题实时刷新 (标题即当前角度, 用户可见状态)
- (void)rotateTapped {
    @try {
        NSInteger next = QMKNextRotation();
        if (self.rotBtn) {
            [self.rotBtn setTitle:[NSString stringWithFormat:@"旋转 %ld°", (long)next]
                         forState:UIControlStateNormal];
        }
    } @catch (NSException *e) {}
}

- (void)colorPickTapped {
    @try {
        QMKEnterColorPick();
    } @catch (NSException *e) {}
}

- (void)enhancerPanelTapped {
    @try {
        QMKToggleEnhancerPanel();
    } @catch (NSException *e) {}
}

// 行为日志键: 弹窗展示 (优先面板 VC, 回退主窗根 VC)
- (void)logTapped {
    @try {
        QMKLog(@"行为日志已查看");
        UIViewController *vc = self.panelVC;
        if (!vc) {
            UIWindow *win = [UIApplication sharedApplication].keyWindow;
            vc = win ? win.rootViewController : nil;
        }
        if (!vc) return;
        UIAlertController *al = [UIAlertController alertControllerWithTitle:@"行为日志 (调试)"
                                                                    message:QMKLogTail()
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

// ---- 键条按钮工厂 (统一按压反馈样式) ----
static UIButton *QMKBarButton(NSString *title, NSInteger tag, UIColor *border,
                              UIView *bar, SEL action) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.tag = tag;
    b.layer.cornerRadius = 8;
    b.layer.borderWidth = 1;
    b.layer.borderColor = border.CGColor;
    b.backgroundColor = [UIColor colorWithWhite:0.18 alpha:0.7];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:10];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.6;
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b addTarget:QMKController() action:action forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:b];
    return b;
}

// ---- 键条挂载: 锚点 = 方案J 面板窗 (标题"控制终端UI面板"), 幂等 ----
// 不在 viewDidLoad 里挂 (VPBuildPanel 会清空全部子视图); 轮询发现锚点后挂,
// 面板重建后自动重挂, tag 守卫防叠加
static void QMKAttachBar(UIView *hostView, UIViewController *vc) {
    @try {
        if ([hostView viewWithTag:QMK_BAR_TAG]) return; // 已挂载 (幂等)
        CGFloat W = hostView.bounds.size.width;
        CGFloat H = hostView.bounds.size.height;
        if (W < 100 || H < 100) return;                 // 异常尺寸防护
        CGFloat K = MIN(W / 390.0, H / 844.0);          // 与方案J 同基准等比

        CGFloat bh = 42 * K;
        CGFloat by = H - bh - 20 * K;                   // 面板窗底部, 不遮主舱区
        if (by < 40 * K) by = 40 * K;                   // 超窄窗兜底

        UIColor *c1 = [UIColor colorWithRed:0.31 green:0.86 blue:1.0 alpha:1.0]; // 极光青
        UIColor *c2 = [UIColor colorWithRed:0.71 green:0.47 blue:1.0 alpha:1.0]; // 极光紫

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
        CGFloat btnW = (bar.bounds.size.width - pad * 5) / 4;
        CGFloat btnH = bh - pad * 2;

        QMKController().panelVC = vc; // 弱引用: 面板关闭后自动清空, 无野指针

        // 视频旋转 (标题带当前角度)
        UIButton *rot = QMKBarButton([NSString stringWithFormat:@"旋转 %ld°", (long)QMKCurrentRotation()],
                                     QMK_ROTBTN_TAG, c1, bar, @selector(rotateTapped));
        rot.frame = CGRectMake(pad, pad, btnW, btnH);
        QMKController().rotBtn = rot;

        // 取色增强 (转发增强模块取色流程)
        UIButton *pick = QMKBarButton(@"取色增强", 0x6E12, c2, bar, @selector(colorPickTapped));
        pick.frame = CGRectMake(pad * 2 + btnW, pad, btnW, btnH);

        // 增强面板 (模块展开: 缩放/滤镜/美颜/肤色)
        UIButton *enh = QMKBarButton(@"增强面板", 0x6E13, c2, bar, @selector(enhancerPanelTapped));
        enh.frame = CGRectMake(pad * 3 + btnW * 2, pad, btnW, btnH);

        // 行为日志 (调试: 记录软件行为)
        UIButton *log = QMKBarButton(@"行为日志", 0x6E14, c2, bar, @selector(logTapped));
        log.frame = CGRectMake(pad * 4 + btnW * 3, pad, btnW, btnH);

        [hostView addSubview:bar];
        QMKLog(@"增强键条已挂载 (面板窗底部)");
    } @catch (NSException *e) {}
}

// ---- 锚点查找: 递归找标题为"控制终端UI面板"的 UILabel (方案J 定稿标题) ----
static UIView *QMKFindPanelLabel(UIView *root, int depth) {
    if (!root || depth > 4) return nil; // 深度限制: 方案J 层级 <= 3
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

// ---- 面板窗定位: 锚点标签 → 所在窗口根 VC 的 view (键条宿主) ----
static UIViewController *QMKFindPanelVC(void) {
    @try {
        NSArray *windows = [UIApplication sharedApplication].windows;
        for (UIWindow *w in windows) {
            for (UIView *sv in w.subviews) {
                UIView *lb = QMKFindPanelLabel(sv, 0);
                if (lb) {
                    // 面板 VC: 锚点向上找响应链中的 UIViewController
                    UIResponder *r = lb;
                    while (r) {
                        r = r.nextResponder;
                        if ([r isKindOfClass:[UIViewController class]]) {
                            return (UIViewController *)r;
                        }
                    }
                    // 兜底: 窗口根 VC
                    return w.rootViewController;
                }
            }
        }
    } @catch (NSException *e) {}
    return nil;
}

// ---- 周期巡检 (主线程, 幂等) ----
// 每 0.5s: 面板出现→挂键条; 面板显隐切换→记行为日志
// 每 3s: 抑制增强悬浮钮 (对抗其 5s 重挂定时器)
static void QMKTick(void) {
    @try {
        if (!QMKIsSpringBoard()) return;
        static BOOL lastVisible = NO;
        UIViewController *vc = QMKFindPanelVC();
        BOOL visible = (vc != nil);
        if (visible) {
            UIView *host = vc.view ?: vc.view.window;
            if (host) QMKAttachBar(host, vc);
        }
        if (visible != lastVisible) {
            QMKLog(visible ? @"功能面板已展开" : @"功能面板已收起");
            lastVisible = visible;
        }
        static int tick = 0;
        if (++tick % 6 == 0) { // 约 3s 一次
            QMKSuppressEnhancerButton();
        }
    } @catch (NSException *e) {}
}

__attribute__((constructor))
static void QMKInit(void) {
    @autoreleasepool {
        @try {
            if (!QMKIsSpringBoard()) return;
            QMKMark(@"extrakeys_injected");
            QMKLog(@"VCamExtraKeys v3 已注入 (SpringBoard)");
            // 主线程定时巡检: 面板挂载/显隐日志/悬浮钮抑制
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
                    QMKTick();
                }];
            });
        } @catch (NSException *e) {}
    }
}