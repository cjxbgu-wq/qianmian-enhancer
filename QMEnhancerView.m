#import "QMEnhancerView.h"
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>

// 共享设置文件路径 - 改到 /tmp/ 所有进程都能访问
static NSString *const kQMSharedSettingsPath = @"/tmp/qianmian_enhancer_settings.plist";

@interface QMEnhancerView ()

@property (nonatomic, strong) UIView *controlPanel;
@property (nonatomic, strong) UIButton *floatButton;
@property (nonatomic, strong) UISlider *zoomSlider;
@property (nonatomic, strong) UIButton *colorPickButton;
@property (nonatomic, strong) UIButton *softGlowButton;
@property (nonatomic, strong) UIButton *beautyButton;
@property (nonatomic, strong) UIButton *skinButton;
@property (nonatomic, strong) UIButton *resetButton;
@property (nonatomic, strong) UILabel *zoomLabel;
@property (nonatomic, strong) UILabel *mixLabel;
@property (nonatomic, strong) UISlider *mixSlider;
@property (nonatomic, strong) UIView *colorPreview;
@property (nonatomic, strong) UILabel *hexLabel;
@property (nonatomic, strong) NSArray<UIButton *> *zoomButtons;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIView *glowDot;
@property (nonatomic, strong) UIView *beautyDot;
@property (nonatomic, strong) UIView *skinDot;

// 取色模式覆盖层
@property (nonatomic, strong) UIView *colorPickOverlay;
@property (nonatomic, strong) UILabel *pickHintLabel;
@property (nonatomic, assign) BOOL isColorPickMode;

@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, assign) BOOL isPanelVisible;
@property (nonatomic, assign) CGPoint startPoint;

@end

@implementation QMEnhancerView

#pragma mark - 点击修复（控制面板超出范围也能点）

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *result = [super hitTest:point withEvent:event];
    if (result) {
        return result;
    }
    
    for (UIView *subview in self.subviews) {
        CGPoint subPoint = [subview convertPoint:point fromView:self];
        if (CGRectContainsPoint(subview.bounds, subPoint)) {
            UIView *subResult = [subview hitTest:subPoint withEvent:event];
            if (subResult) {
                return subResult;
            }
        }
    }
    
    return nil;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if ([super pointInside:point withEvent:event]) {
        return YES;
    }
    
    if (!_controlPanel.hidden) {
        CGPoint panelPoint = [_controlPanel convertPoint:point fromView:self];
        if (CGRectContainsPoint(_controlPanel.bounds, panelPoint)) {
            return YES;
        }
    }
    
    return NO;
}

#pragma mark - 共享设置（进程间通信）

+ (NSDictionary *)sharedSettings {
    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:kQMSharedSettingsPath];
    if (!settings) {
        return @{
            @"zoomScale": @(1.0),
            @"colorMappingEnabled": @(NO),
            @"colorRed": @(1.0),
            @"colorGreen": @(1.0),
            @"colorBlue": @(1.0),
            @"colorMixIntensity": @(0.5),
            @"softGlowEnabled": @(NO),
            @"beautyEnabled": @(NO),
            @"skinEnabled": @(NO),
            @"videoRotation": @(0)
        };
    }
    return settings;
}

+ (void)saveSharedSettings:(NSDictionary *)settings {
    [settings writeToFile:kQMSharedSettingsPath atomically:YES];
}

+ (CGFloat)currentZoomScale {
    return [[[self sharedSettings] objectForKey:@"zoomScale"] floatValue];
}

+ (BOOL)isColorMappingEnabled {
    return [[[self sharedSettings] objectForKey:@"colorMappingEnabled"] boolValue];
}

+ (UIColor *)currentMappingColor {
    NSDictionary *settings = [self sharedSettings];
    CGFloat r = [[settings objectForKey:@"colorRed"] floatValue];
    CGFloat g = [[settings objectForKey:@"colorGreen"] floatValue];
    CGFloat b = [[settings objectForKey:@"colorBlue"] floatValue];
    return [UIColor colorWithRed:r green:g blue:b alpha:1.0];
}

+ (CGFloat)currentColorMixIntensity {
    return [[[self sharedSettings] objectForKey:@"colorMixIntensity"] floatValue];
}

+ (BOOL)isSoftGlowEnabled {
    return [[[self sharedSettings] objectForKey:@"softGlowEnabled"] boolValue];
}

+ (BOOL)isBeautyEnabled {
    return [[[self sharedSettings] objectForKey:@"beautyEnabled"] boolValue];
}

+ (BOOL)isSkinEnabled {
    return [[[self sharedSettings] objectForKey:@"skinEnabled"] boolValue];
}

- (void)saveCurrentSettings {
    CGFloat r, g, b, a;
    [_mappingColor getRed:&r green:&g blue:&b alpha:&a];
    
    NSDictionary *settings = @{
        @"zoomScale": @(_zoomScale),
        @"colorMappingEnabled": @(_colorMappingEnabled),
        @"colorRed": @(r),
        @"colorGreen": @(g),
        @"colorBlue": @(b),
        @"colorMixIntensity": @(_colorMixIntensity),
        @"softGlowEnabled": @(_softGlowEnabled),
        @"beautyEnabled": @(_beautyEnabled),
        @"skinEnabled": @(_skinEnabled)
    };
    // 合并保存: 保留外部写入的键 (如视频旋转 videoRotation), 避免覆盖丢失
    NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:[[self class] sharedSettings]];
    [merged addEntriesFromDictionary:settings];
    [[self class] saveSharedSettings:merged];
}

+ (instancetype)sharedInstance {
    static QMEnhancerView *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[QMEnhancerView alloc] initWithFrame:CGRectMake(0, 0, 60, 60)];
    });
    return instance;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _zoomScale = 1.0;
        _colorMappingEnabled = NO;
        _mappingColor = [UIColor whiteColor];
        _colorMixIntensity = 0.5;
        _softGlowEnabled = NO;
        _beautyEnabled = NO;
        _skinEnabled = NO;
        _ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
        _isPanelVisible = NO;
        _isColorPickMode = NO;
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    self.backgroundColor = [UIColor clearColor];
    
    UIColor *c1 = [UIColor colorWithRed:0.31 green:0.86 blue:1.0 alpha:1.0];   // 极光青
    UIColor *c2 = [UIColor colorWithRed:0.71 green:0.47 blue:1.0 alpha:1.0];   // 极光紫
    UIColor *c3 = [UIColor colorWithRed:1.0 green:0.47 blue:0.78 alpha:1.0];   // 极光粉
    
    // 悬浮球 - 透明玻璃 + 内珠（取色映射开启时内珠=映射色）
    _floatButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _floatButton.frame = self.bounds;
    _floatButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.22];
    _floatButton.layer.cornerRadius = self.bounds.size.width / 2;
    _floatButton.layer.borderWidth = 1.5;
    _floatButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
    _floatButton.layer.shadowColor = c1.CGColor;
    _floatButton.layer.shadowRadius = 8;
    _floatButton.layer.shadowOpacity = 0.35;
    _floatButton.layer.shadowOffset = CGSizeZero;
    UIView *ballDot = [[UIView alloc] initWithFrame:CGRectMake(self.bounds.size.width/2-11, self.bounds.size.height/2-11, 22, 22)];
    ballDot.backgroundColor = c1;
    ballDot.layer.cornerRadius = 11;
    ballDot.layer.borderWidth = 1;
    ballDot.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.6].CGColor;
    ballDot.layer.shadowColor = c1.CGColor;
    ballDot.layer.shadowRadius = 6;
    ballDot.layer.shadowOpacity = 0.9;
    ballDot.layer.shadowOffset = CGSizeZero;
    [_floatButton addSubview:ballDot];
    [_floatButton addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_floatButton];
    
    // 控制面板 - 冰川极光玻璃
    _controlPanel = [[UIView alloc] initWithFrame:CGRectMake(70, -110, 250, 360)];
    _controlPanel.backgroundColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.21 alpha:0.94];
    _controlPanel.layer.cornerRadius = 16;
    _controlPanel.layer.borderWidth = 1;
    _controlPanel.layer.borderColor = [UIColor colorWithRed:0.31 green:0.86 blue:1.0 alpha:0.5].CGColor;
    _controlPanel.layer.shadowColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.9 alpha:1.0].CGColor;
    _controlPanel.layer.shadowRadius = 12;
    _controlPanel.layer.shadowOpacity = 0.3;
    _controlPanel.layer.shadowOffset = CGSizeZero;
    _controlPanel.hidden = YES;
    [self addSubview:_controlPanel];
    
    // 顶部极光渐变条
    CAGradientLayer *strip = [CAGradientLayer layer];
    strip.frame = CGRectMake(14, 6, 222, 3);
    strip.cornerRadius = 1.5;
    strip.colors = @[(id)c1.CGColor, (id)c2.CGColor, (id)c3.CGColor];
    strip.startPoint = CGPointMake(0, 0);
    strip.endPoint = CGPointMake(1, 0);
    [_controlPanel.layer addSublayer:strip];
    
    // 标题 + 状态胶囊
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 14, 140, 22)];
    _statusLabel.textColor = [UIColor whiteColor];
    _statusLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _statusLabel.text = @"增强 · 取色映射";
    [_controlPanel addSubview:_statusLabel];
    
    UIView *capsule = [[UIView alloc] initWithFrame:CGRectMake(250-14-58, 14, 58, 20)];
    capsule.backgroundColor = [UIColor colorWithRed:0.31 green:0.86 blue:1.0 alpha:0.18];
    capsule.layer.cornerRadius = 10;
    capsule.layer.borderWidth = 1;
    capsule.layer.borderColor = [UIColor colorWithRed:0.31 green:0.86 blue:1.0 alpha:0.7].CGColor;
    UILabel *capText = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 58, 20)];
    capText.text = @"取色中";
    capText.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    capText.textColor = [UIColor whiteColor];
    capText.textAlignment = NSTextAlignmentCenter;
    [capsule addSubview:capText];
    [_controlPanel addSubview:capsule];
    
    // 屏幕取色按钮 + 色块 + hex
    _colorPickButton = [self styledButton:@"屏幕取色" color:c1 selector:@selector(enterColorPickMode)];
    _colorPickButton.frame = CGRectMake(14, 46, 100, 38);
    [_controlPanel addSubview:_colorPickButton];
    
    _colorPreview = [[UIView alloc] initWithFrame:CGRectMake(120, 46, 34, 38)];
    _colorPreview.backgroundColor = [UIColor whiteColor];
    _colorPreview.layer.cornerRadius = 10;
    _colorPreview.layer.borderWidth = 2;
    _colorPreview.layer.borderColor = [UIColor whiteColor].CGColor;
    [_controlPanel addSubview:_colorPreview];
    
    _hexLabel = [[UILabel alloc] initWithFrame:CGRectMake(160, 46, 76, 38)];
    _hexLabel.numberOfLines = 2;
    _hexLabel.text = @"映射色\n#FFFFFF";
    _hexLabel.font = [UIFont systemFontOfSize:10];
    _hexLabel.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    [_controlPanel addSubview:_hexLabel];
    
    // 映射强度
    _mixLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 92, 150, 18)];
    _mixLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
    _mixLabel.font = [UIFont systemFontOfSize:11];
    _mixLabel.text = @"映射强度";
    [_controlPanel addSubview:_mixLabel];
    
    _mixSlider = [[UISlider alloc] initWithFrame:CGRectMake(14, 108, 222, 26)];
    _mixSlider.minimumValue = 0.0;
    _mixSlider.maximumValue = 1.0;
    _mixSlider.value = 0.5;
    _mixSlider.minimumTrackTintColor = c1;
    _mixSlider.maximumTrackTintColor = [UIColor colorWithWhite:0.35 alpha:1.0];
    [_mixSlider addTarget:self action:@selector(mixIntensityChanged:) forControlEvents:UIControlEventValueChanged];
    [_controlPanel addSubview:_mixSlider];
    
    // 视频缩放 5 档
    _zoomLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 140, 150, 18)];
    _zoomLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
    _zoomLabel.font = [UIFont systemFontOfSize:11];
    _zoomLabel.text = @"视频缩放";
    [_controlPanel addSubview:_zoomLabel];
    
    NSMutableArray *zbs = [NSMutableArray array];
    CGFloat zx = 14;
    NSArray *zs = @[@"1.0", @"1.5", @"2.0", @"2.5", @"3.0"];
    for (int i = 0; i < 5; i++) {
        UIButton *zb = [UIButton buttonWithType:UIButtonTypeCustom];
        zb.frame = CGRectMake(zx, 160, 38, 26);
        [zb setTitle:zs[i] forState:UIControlStateNormal];
        zb.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        [zb setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        zb.layer.cornerRadius = 7;
        zb.layer.borderWidth = 1;
        zb.layer.borderColor = c2.CGColor;
        zb.backgroundColor = [UIColor colorWithWhite:0.22 alpha:0.6];
        zb.tag = i;
        [zb addTarget:self action:@selector(zoomSegTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_controlPanel addSubview:zb];
        [zbs addObject:zb];
        zx += 38 + 6;
    }
    _zoomButtons = zbs;
    [self updateZoomButtons];
    
    // 滤镜三键
    _softGlowButton = [self styledButton:@"电影光效" color:c1 selector:@selector(toggleSoftGlow)];
    _softGlowButton.frame = CGRectMake(14, 206, 68, 34);
    [_controlPanel addSubview:_softGlowButton];
    _glowDot = [self filterDotForButton:_softGlowButton];
    
    _beautyButton = [self styledButton:@"轻微美颜" color:c3 selector:@selector(toggleBeauty)];
    _beautyButton.frame = CGRectMake(89, 206, 68, 34);
    [_controlPanel addSubview:_beautyButton];
    _beautyDot = [self filterDotForButton:_beautyButton];
    
    _skinButton = [self styledButton:@"肤色调节" color:c2 selector:@selector(toggleSkin)];
    _skinButton.frame = CGRectMake(164, 206, 72, 34);
    [_controlPanel addSubview:_skinButton];
    _skinDot = [self filterDotForButton:_skinButton];
    
    // 取色提示
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(14, 254, 222, 18)];
    hint.text = @"拖取色探针到屏幕任意位置取色";
    hint.font = [UIFont systemFontOfSize:10];
    hint.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];
    hint.textAlignment = NSTextAlignmentCenter;
    [_controlPanel addSubview:hint];
    
    // 收起面板
    _resetButton = [self styledButton:@"收 起 面 板" color:c2 selector:@selector(togglePanel)];
    _resetButton.frame = CGRectMake(14, 314, 222, 36);
    [_controlPanel addSubview:_resetButton];
    
    // 拖动手势
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [_floatButton addGestureRecognizer:pan];
    
    // 取色覆盖层（全屏）
    _colorPickOverlay = [[UIView alloc] initWithFrame:CGRectZero];
    _colorPickOverlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.3];
    _colorPickOverlay.hidden = YES;
    _colorPickOverlay.userInteractionEnabled = YES;
    
    _pickHintLabel = [[UILabel alloc] init];
    _pickHintLabel.text = @"👆 点击屏幕任意位置取色\n（再次点击取消）";
    _pickHintLabel.numberOfLines = 2;
    _pickHintLabel.textColor = [UIColor whiteColor];
    _pickHintLabel.textAlignment = NSTextAlignmentCenter;
    _pickHintLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    _pickHintLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
    _pickHintLabel.layer.cornerRadius = 10;
    _pickHintLabel.clipsToBounds = YES;
    [_colorPickOverlay addSubview:_pickHintLabel];
    
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleColorPickTap:)];
    [_colorPickOverlay addGestureRecognizer:tapGesture];
    
    // 取色注入标记 (安装日志检测: 取色悬浮窗/覆盖层已成功建立)
    @try {
        [@"ok" writeToFile:@"/tmp/qm_colorpick_injected.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) {}
}

- (UIButton *)styledButton:(NSString *)title color:(UIColor *)color selector:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithWhite:0.22 alpha:0.6];
    b.layer.cornerRadius = 10;
    b.layer.borderWidth = 1;
    b.layer.borderColor = color.CGColor;
    b.layer.shadowColor = color.CGColor;
    b.layer.shadowRadius = 4;
    b.layer.shadowOpacity = 0;
    b.layer.shadowOffset = CGSizeZero;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIView *)filterDotForButton:(UIButton *)button {
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(button.bounds.size.width-20, button.bounds.size.height/2-4, 8, 8)];
    dot.layer.cornerRadius = 4;
    dot.backgroundColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    [button addSubview:dot];
    return dot;
}

- (void)pressFeedback:(UIView *)view {
    [UIView animateWithDuration:0.09 animations:^{
        view.transform = CGAffineTransformMakeScale(0.92, 0.92);
        view.layer.shadowOpacity = 0.7;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.12 animations:^{
            view.transform = CGAffineTransformIdentity;
            view.layer.shadowOpacity = 0.0;
        }];
    }];
}

#pragma mark - 控制面板

- (void)togglePanel {
    _isPanelVisible = !_isPanelVisible;
    _controlPanel.hidden = !_isPanelVisible;
    [self pressFeedback:_floatButton];
}

#pragma mark - 缩放控制

- (void)setZoomTo:(CGFloat)zoom {
    _zoomScale = zoom;
    _zoomLabel.text = [NSString stringWithFormat:@"视频缩放 %.1fx", zoom];
    [self updateZoomButtons];
    [self saveCurrentSettings];
}

- (void)updateZoomButtons {
    for (UIButton *b in _zoomButtons) {
        CGFloat zv = 1.0 + b.tag * 0.5;
        BOOL sel = fabs(zv - _zoomScale) < 0.001;
        b.backgroundColor = sel ? [UIColor colorWithRed:0.31 green:0.86 blue:1.0 alpha:0.55]
                                : [UIColor colorWithWhite:0.22 alpha:0.6];
        b.layer.borderColor = sel ? [UIColor colorWithRed:0.31 green:0.86 blue:1.0 alpha:1.0].CGColor
                                  : [UIColor colorWithRed:0.71 green:0.47 blue:1.0 alpha:0.7].CGColor;
        b.layer.shadowOpacity = sel ? 0.5 : 0.0;
    }
}

- (void)zoomSegTapped:(UIButton *)sender {
    [self pressFeedback:sender];
    [self setZoomTo:1.0 + sender.tag * 0.5];
}

- (void)zoomChanged:(UISlider *)slider {
    _zoomScale = slider.value;
    _zoomLabel.text = [NSString stringWithFormat:@"视频缩放 %.1fx", _zoomScale];
    [self saveCurrentSettings];
}

#pragma mark - 取色模式（点击任意位置取色）

- (void)enterColorPickMode {
    _isColorPickMode = YES;
    [self pressFeedback:_colorPickButton];
    
    UIWindow *window = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { window = w; break; }
    }
    
    if (window && _colorPickOverlay.superview == nil) {
        _colorPickOverlay.frame = window.bounds;
        _pickHintLabel.frame = CGRectMake(0, 0, 240, 60);
        _pickHintLabel.center = CGPointMake(window.bounds.size.width / 2, 100);
        [window addSubview:_colorPickOverlay];
    }
    _colorPickOverlay.hidden = NO;
    
    _colorPickButton.selected = YES;
    _colorPickButton.layer.borderColor = [UIColor colorWithRed:1.0 green:0.6 blue:0.2 alpha:1.0].CGColor;
    _colorPickButton.backgroundColor = [UIColor colorWithRed:0.32 green:0.24 blue:0.16 alpha:0.7];
}

- (void)exitColorPickMode {
    _isColorPickMode = NO;
    _colorPickOverlay.hidden = YES;
    _colorPickButton.selected = NO;
    _colorPickButton.layer.borderColor = [UIColor colorWithRed:0.31 green:0.86 blue:1.0 alpha:1.0].CGColor;
    _colorPickButton.backgroundColor = [UIColor colorWithWhite:0.22 alpha:0.6];
}

- (void)handleColorPickTap:(UITapGestureRecognizer *)gesture {
    CGPoint tapPoint = [gesture locationInView:_colorPickOverlay];
    
    UIImage *screenshot = [self captureScreen];
    if (screenshot) {
        CGFloat scale = [UIScreen mainScreen].scale;
        CGPoint imagePoint = CGPointMake(tapPoint.x * scale, tapPoint.y * scale);
        UIColor *color = [self colorAtPoint:imagePoint inImage:screenshot];
        
        _mappingColor = color;
        _colorPreview.backgroundColor = color;
        CGFloat r, g, b, a;
        [color getRed:&r green:&g blue:&b alpha:&a];
        _hexLabel.text = [NSString stringWithFormat:@"映射色\n#%02X%02X%02X",
                          (int)(r * 255), (int)(g * 255), (int)(b * 255)];
        _colorMappingEnabled = YES;
        [self saveCurrentSettings];
        // 取色结果标记 (安装日志/面板回显读取)
        @try {
            [[NSString stringWithFormat:@"#%02X%02X%02X", (int)(r * 255), (int)(g * 255), (int)(b * 255)]
                writeToFile:@"/tmp/qm_colorpick_result.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } @catch (NSException *e) {}
    }
    
    [self exitColorPickMode];
}

#pragma mark - 混合强度

- (void)mixIntensityChanged:(UISlider *)slider {
    _colorMixIntensity = slider.value;
    _mixLabel.text = [NSString stringWithFormat:@"映射强度 %.0f%%", _colorMixIntensity * 100];
    [self saveCurrentSettings];
}

#pragma mark - 滤镜开关

- (void)setFilterButton:(UIButton *)button dot:(UIView *)dot on:(BOOL)on color:(UIColor *)color {
    button.layer.borderColor = on ? color.CGColor : [UIColor colorWithWhite:0.45 alpha:1.0].CGColor;
    button.backgroundColor = on ? [UIColor colorWithRed:0.25 green:0.22 blue:0.32 alpha:0.75]
                                : [UIColor colorWithWhite:0.22 alpha:0.6];
    dot.backgroundColor = on ? [UIColor colorWithRed:0.35 green:0.8 blue:0.45 alpha:1.0]
                             : [UIColor colorWithWhite:0.5 alpha:1.0];
    button.layer.shadowOpacity = on ? 0.5 : 0.0;
}

- (void)toggleSoftGlow {
    [self pressFeedback:_softGlowButton];
    _softGlowEnabled = !_softGlowEnabled;
    [self setFilterButton:_softGlowButton dot:_glowDot on:_softGlowEnabled
                    color:[UIColor colorWithRed:0.31 green:0.86 blue:1.0 alpha:1.0]];
    [self saveCurrentSettings];
}

- (void)toggleBeauty {
    [self pressFeedback:_beautyButton];
    _beautyEnabled = !_beautyEnabled;
    [self setFilterButton:_beautyButton dot:_beautyDot on:_beautyEnabled
                    color:[UIColor colorWithRed:1.0 green:0.47 blue:0.78 alpha:1.0]];
    [self saveCurrentSettings];
}

- (void)toggleSkin {
    [self pressFeedback:_skinButton];
    _skinEnabled = !_skinEnabled;
    [self setFilterButton:_skinButton dot:_skinDot on:_skinEnabled
                    color:[UIColor colorWithRed:0.71 green:0.47 blue:1.0 alpha:1.0]];
    [self saveCurrentSettings];
}

#pragma mark - 重置

- (void)resetAll {
    [self setZoomTo:1.0];
    
    _colorMappingEnabled = NO;
    _mappingColor = [UIColor whiteColor];
    _colorPreview.backgroundColor = [UIColor whiteColor];
    _hexLabel.text = @"映射色\n#FFFFFF";
    _colorPickButton.selected = NO;
    _colorPickButton.layer.borderColor = [UIColor colorWithRed:0.31 green:0.86 blue:1.0 alpha:1.0].CGColor;
    _colorPickButton.backgroundColor = [UIColor colorWithWhite:0.22 alpha:0.6];
    
    _colorMixIntensity = 0.5;
    _mixSlider.value = 0.5;
    _mixLabel.text = @"映射强度 50%";
    
    _softGlowEnabled = NO;
    _beautyEnabled = NO;
    _skinEnabled = NO;
    [self setFilterButton:_softGlowButton dot:_glowDot on:NO
                    color:[UIColor colorWithRed:0.31 green:0.86 blue:1.0 alpha:1.0]];
    [self setFilterButton:_beautyButton dot:_beautyDot on:NO
                    color:[UIColor colorWithRed:1.0 green:0.47 blue:0.78 alpha:1.0]];
    [self setFilterButton:_skinButton dot:_skinDot on:NO
                    color:[UIColor colorWithRed:0.71 green:0.47 blue:1.0 alpha:1.0]];
    
    [self exitColorPickMode];
    [self saveCurrentSettings];
}

#pragma mark - 拖动

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    UIView *superview = self.superview;
    CGPoint translation = [gesture translationInView:superview];
    
    if (gesture.state == UIGestureRecognizerStateBegan) {
        _startPoint = self.center;
    }
    
    CGPoint newCenter = CGPointMake(_startPoint.x + translation.x, _startPoint.y + translation.y);
    
    CGFloat margin = 30;
    newCenter.x = MAX(margin, MIN(superview.bounds.size.width - margin, newCenter.x));
    newCenter.y = MAX(margin, MIN(superview.bounds.size.height - margin, newCenter.y));
    
    self.center = newCenter;
}

#pragma mark - 屏幕截图和取色

- (UIImage *)captureScreen {
    CGSize size = [UIScreen mainScreen].bounds.size;
    UIGraphicsBeginImageContextWithOptions(size, YES, 0);
    
    UIWindow *window = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { window = w; break; }
    }
    
    [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
    
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (UIColor *)colorAtPoint:(CGPoint)point inImage:(UIImage *)image {
    if (point.x < 0 || point.y < 0 || point.x >= image.size.width || point.y >= image.size.height) {
        return [UIColor whiteColor];
    }
    
    CGImageRef cgImage = image.CGImage;
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    
    unsigned char *pixelData = calloc(4, sizeof(unsigned char));
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixelData, 1, 1, 8, 4, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGRect rect = CGRectMake(-point.x, point.y - height, width, height);
    CGContextDrawImage(context, rect, cgImage);
    CGContextRelease(context);
    
    CGFloat red = pixelData[0] / 255.0;
    CGFloat green = pixelData[1] / 255.0;
    CGFloat blue = pixelData[2] / 255.0;
    free(pixelData);
    
    return [UIColor colorWithRed:red green:green blue:blue alpha:1.0];
}

#pragma mark - 核心：类方法逐帧处理（mediaserverd 侧安全路径，纯 CoreImage）

+ (void)processFrame:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return;
    
    CGFloat zoomScale = [self currentZoomScale];
    BOOL colorEnabled = [self isColorMappingEnabled];
    UIColor *mapColor = [self currentMappingColor];
    CGFloat mixIntensity = [self currentColorMixIntensity];
    BOOL softGlow = [self isSoftGlowEnabled];
    BOOL beauty = [self isBeautyEnabled];
    BOOL skin = [self isSkinEnabled];
    NSInteger videoRotation = [[[self sharedSettings] objectForKey:@"videoRotation"] integerValue];
    
    if (zoomScale <= 1.01 && !colorEnabled && !softGlow && !beauty && !skin && videoRotation == 0) {
        return;
    }
    
    static CIContext *ctx = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ctx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    });
    if (!ctx) return;
    
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    
    CIImage *resultImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    
    // 0. 视频旋转 (0/90/180/270): 旋转 + 自适应裁满, 同缓冲渲染
    if (videoRotation == 90 || videoRotation == 180 || videoRotation == 270) {
        CGAffineTransform t = CGAffineTransformIdentity;
        if (videoRotation == 90)  t = CGAffineTransformMake(0, 1, -1, 0, height, 0);
        if (videoRotation == 180) t = CGAffineTransformMake(-1, 0, 0, -1, width, height);
        if (videoRotation == 270) t = CGAffineTransformMake(0, -1, 1, 0, 0, width);
        CIImage *rotated = [resultImage imageByApplyingTransform:t];
        CGRect ext = rotated.extent;
        if (ext.size.width > 1 && ext.size.height > 1) {
            CGFloat sx = width / ext.size.width;
            CGFloat sy = height / ext.size.height;
            CGFloat s = MAX(sx, sy);
            rotated = [rotated imageByApplyingTransform:CGAffineTransformMakeScale(s, s)];
            CGRect se = rotated.extent;
            rotated = [rotated imageByApplyingTransform:CGAffineTransformMakeTranslation(
                (width - se.size.width) / 2.0, (height - se.size.height) / 2.0)];
            rotated = [rotated imageByCroppingToRect:CGRectMake(0, 0, width, height)];
            resultImage = rotated;
        }
    }
    
    // 1. 缩放（中心裁剪放大）
    if (zoomScale > 1.01) {
        CGFloat scale = zoomScale;
        CGFloat cropWidth = width / scale;
        CGFloat cropHeight = height / scale;
        CGFloat cropX = (width - cropWidth) / 2.0;
        CGFloat cropY = (height - cropHeight) / 2.0;
        
        CGRect cropRect = CGRectMake(cropX, cropY, cropWidth, cropHeight);
        resultImage = [resultImage imageByCroppingToRect:cropRect];
        resultImage = [resultImage imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    }
    
    // 2. 色彩映射（屏幕取色注入）
    if (colorEnabled && mapColor) {
        CGFloat r, g, b, a;
        [mapColor getRed:&r green:&g blue:&b alpha:&a];
        
        CIFilter *colorMatrixFilter = [CIFilter filterWithName:@"CIColorMatrix"];
        [colorMatrixFilter setValue:resultImage forKey:kCIInputImageKey];
        
        CGFloat mix = mixIntensity;
        [colorMatrixFilter setValue:[CIVector vectorWithX:r * mix + (1-mix) Y:0 Z:0 W:0] forKey:@"inputRVector"];
        [colorMatrixFilter setValue:[CIVector vectorWithX:0 Y:g * mix + (1-mix) Z:0 W:0] forKey:@"inputGVector"];
        [colorMatrixFilter setValue:[CIVector vectorWithX:0 Y:0 Z:b * mix + (1-mix) W:0] forKey:@"inputBVector"];
        [colorMatrixFilter setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:1.0] forKey:@"inputAVector"];
        [colorMatrixFilter setValue:[CIVector vectorWithX:r * 0.08 * mix Y:g * 0.08 * mix Z:b * 0.08 * mix W:0.0] forKey:@"inputBiasVector"];
        
        resultImage = colorMatrixFilter.outputImage;
    }
    
    // 3. 柔光滤镜（电影光效）
    if (softGlow) {
        CIFilter *shadowAdjust = [CIFilter filterWithName:@"CIHighlightShadowAdjust"];
        [shadowAdjust setValue:resultImage forKey:kCIInputImageKey];
        [shadowAdjust setValue:@(0.3) forKey:@"inputShadowAmount"];
        [shadowAdjust setValue:@(-0.1) forKey:@"inputHighlightAmount"];
        CIImage *adjustedImage = shadowAdjust.outputImage;
        
        CIFilter *blurFilter = [CIFilter filterWithName:@"CIGaussianBlur"];
        [blurFilter setValue:adjustedImage forKey:kCIInputImageKey];
        [blurFilter setValue:@(4.0) forKey:kCIInputRadiusKey];
        CIImage *blurredImage = blurFilter.outputImage;
        
        CIFilter *blendFilter = [CIFilter filterWithName:@"CIScreenBlendMode"];
        [blendFilter setValue:blurredImage forKey:kCIInputImageKey];
        [blendFilter setValue:adjustedImage forKey:kCIInputBackgroundImageKey];
        CIImage *blendedImage = blendFilter.outputImage;
        
        CIFilter *opacityFilter = [CIFilter filterWithName:@"CIColorMatrix"];
        [opacityFilter setValue:blendedImage forKey:kCIInputImageKey];
        [opacityFilter setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:0.6] forKey:@"inputAVector"];
        
        CIFilter *finalBlend = [CIFilter filterWithName:@"CISourceOverCompositing"];
        [finalBlend setValue:opacityFilter.outputImage forKey:kCIInputImageKey];
        [finalBlend setValue:adjustedImage forKey:kCIInputBackgroundImageKey];
        resultImage = finalBlend.outputImage;
    }
    
    // 4. 轻微美颜（轻模糊 + 柔化肤色）
    if (beauty) {
        CIFilter *blurFilter = [CIFilter filterWithName:@"CIGaussianBlur"];
        [blurFilter setValue:resultImage forKey:kCIInputImageKey];
        [blurFilter setValue:@(1.5) forKey:kCIInputRadiusKey];
        
        CIFilter *controls = [CIFilter filterWithName:@"CIColorControls"];
        [controls setValue:blurFilter.outputImage forKey:kCIInputImageKey];
        [controls setValue:@(1.06) forKey:@"inputSaturation"];
        [controls setValue:@(0.02) forKey:@"inputBrightness"];
        [controls setValue:@(1.0) forKey:@"inputContrast"];
        
        CIFilter *opacityFilter = [CIFilter filterWithName:@"CIColorMatrix"];
        [opacityFilter setValue:controls.outputImage forKey:kCIInputImageKey];
        [opacityFilter setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:0.45] forKey:@"inputAVector"];
        
        CIFilter *finalBlend = [CIFilter filterWithName:@"CISourceOverCompositing"];
        [finalBlend setValue:opacityFilter.outputImage forKey:kCIInputImageKey];
        [finalBlend setValue:resultImage forKey:kCIInputBackgroundImageKey];
        resultImage = finalBlend.outputImage;
    }
    
    // 5. 肤色调节（暖调 + 轻微降饱和）
    if (skin) {
        CIFilter *controls = [CIFilter filterWithName:@"CIColorControls"];
        [controls setValue:resultImage forKey:kCIInputImageKey];
        [controls setValue:@(0.92) forKey:@"inputSaturation"];
        [controls setValue:@(0.03) forKey:@"inputBrightness"];
        resultImage = controls.outputImage;
        
        CIFilter *warm = [CIFilter filterWithName:@"CIColorMatrix"];
        [warm setValue:resultImage forKey:kCIInputImageKey];
        [warm setValue:[CIVector vectorWithX:1.0 Y:0 Z:0 W:0] forKey:@"inputRVector"];
        [warm setValue:[CIVector vectorWithX:0 Y:1.0 Z:0 W:0] forKey:@"inputGVector"];
        [warm setValue:[CIVector vectorWithX:0 Y:0 Z:0.96 W:0] forKey:@"inputBVector"];
        [warm setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:1.0] forKey:@"inputAVector"];
        [warm setValue:[CIVector vectorWithX:0.02 Y:0.01 Z:0.02 W:0] forKey:@"inputBiasVector"];
        resultImage = warm.outputImage;
    }
    
    if (resultImage) {
        [ctx render:resultImage toCVPixelBuffer:pixelBuffer];
    }
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
}

#pragma mark - 核心：处理像素缓冲区（实时逐帧处理）

- (void)processPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return;
    
    CGFloat zoomScale = [[self class] currentZoomScale];
    BOOL colorEnabled = [[self class] isColorMappingEnabled];
    UIColor *mapColor = [[self class] currentMappingColor];
    CGFloat mixIntensity = [[self class] currentColorMixIntensity];
    BOOL softGlow = [[self class] isSoftGlowEnabled];
    
    if (zoomScale <= 1.01 && !colorEnabled && !softGlow) {
        return;
    }
    
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    
    CIImage *resultImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    
    // 1. 缩放
    if (zoomScale > 1.01) {
        CGFloat scale = zoomScale;
        CGFloat cropWidth = width / scale;
        CGFloat cropHeight = height / scale;
        CGFloat cropX = (width - cropWidth) / 2.0;
        CGFloat cropY = (height - cropHeight) / 2.0;
        
        CGRect cropRect = CGRectMake(cropX, cropY, cropWidth, cropHeight);
        resultImage = [resultImage imageByCroppingToRect:cropRect];
        resultImage = [resultImage imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    }
    
    // 2. 颜色映射
    if (colorEnabled && mapColor) {
        CGFloat r, g, b, a;
        [mapColor getRed:&r green:&g blue:&b alpha:&a];
        
        CIFilter *colorMatrixFilter = [CIFilter filterWithName:@"CIColorMatrix"];
        [colorMatrixFilter setValue:resultImage forKey:kCIInputImageKey];
        
        CGFloat mix = mixIntensity;
        CIVector *rVector = [CIVector vectorWithX:r * mix + (1-mix) Y:0 Z:0 W:0];
        CIVector *gVector = [CIVector vectorWithX:0 Y:g * mix + (1-mix) Z:0 W:0];
        CIVector *bVector = [CIVector vectorWithX:0 Y:0 Z:b * mix + (1-mix) W:0];
        CIVector *aVector = [CIVector vectorWithX:0 Y:0 Z:0 W:1.0];
        CIVector *biasVector = [CIVector vectorWithX:r * 0.08 * mix Y:g * 0.08 * mix Z:b * 0.08 * mix W:0.0];
        
        [colorMatrixFilter setValue:rVector forKey:@"inputRVector"];
        [colorMatrixFilter setValue:gVector forKey:@"inputGVector"];
        [colorMatrixFilter setValue:bVector forKey:@"inputBVector"];
        [colorMatrixFilter setValue:aVector forKey:@"inputAVector"];
        [colorMatrixFilter setValue:biasVector forKey:@"inputBiasVector"];
        
        resultImage = colorMatrixFilter.outputImage;
    }
    
    // 3. 柔光滤镜
    if (softGlow) {
        resultImage = [self applySoftGlowToImage:resultImage];
    }
    
    if (resultImage) {
        [_ciContext render:resultImage toCVPixelBuffer:pixelBuffer];
    }
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
}

#pragma mark - 柔光滤镜效果

- (CIImage *)applySoftGlowToImage:(CIImage *)inputImage {
    CIFilter *shadowAdjust = [CIFilter filterWithName:@"CIHighlightShadowAdjust"];
    [shadowAdjust setValue:inputImage forKey:kCIInputImageKey];
    [shadowAdjust setValue:@(0.3) forKey:@"inputShadowAmount"];
    [shadowAdjust setValue:@(-0.1) forKey:@"inputHighlightAmount"];
    CIImage *adjustedImage = shadowAdjust.outputImage;
    
    CIFilter *blurFilter = [CIFilter filterWithName:@"CIGaussianBlur"];
    [blurFilter setValue:adjustedImage forKey:kCIInputImageKey];
    [blurFilter setValue:@(4.0) forKey:kCIInputRadiusKey];
    CIImage *blurredImage = blurFilter.outputImage;
    
    CIFilter *blendFilter = [CIFilter filterWithName:@"CIScreenBlendMode"];
    [blendFilter setValue:blurredImage forKey:kCIInputImageKey];
    [blendFilter setValue:adjustedImage forKey:kCIInputBackgroundImageKey];
    CIImage *blendedImage = blendFilter.outputImage;
    
    CIFilter *opacityFilter = [CIFilter filterWithName:@"CIColorMatrix"];
    [opacityFilter setValue:blendedImage forKey:kCIInputImageKey];
    CIVector *aVector = [CIVector vectorWithX:0 Y:0 Z:0 W:0.6];
    [opacityFilter setValue:aVector forKey:@"inputAVector"];
    
    CIFilter *finalBlend = [CIFilter filterWithName:@"CISourceOverCompositing"];
    [finalBlend setValue:opacityFilter.outputImage forKey:kCIInputImageKey];
    [finalBlend setValue:adjustedImage forKey:kCIInputBackgroundImageKey];
    
    return finalBlend.outputImage;
}

#pragma mark - 显示 + 自动重连（防止消失）

- (void)showInWindow:(UIWindow *)window {
    if (self.superview) {
        [self removeFromSuperview];
    }
    
    // 屏幕左侧，绿色小球
    self.frame = CGRectMake(15, window.bounds.size.height / 2, 60, 60);
    [window addSubview:self];
    
    // 监听亮屏，每次重新加到最前面
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(checkAndReadd)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    
    // 启动定时器，每 5 秒检查一次，消失了就重新加上
    [NSTimer scheduledTimerWithTimeInterval:5.0
                                     target:self
                                   selector:@selector(checkAndReadd)
                                   userInfo:nil
                                    repeats:YES];
}

- (void)checkAndReadd {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { window = w; break; }
        }
        
        if (window && self.superview != window) {
            [self removeFromSuperview];
            [window addSubview:self];
            [window bringSubviewToFront:self];
        } else if (window) {
            [window bringSubviewToFront:self];
        }
    });
}

- (void)toggleVisibility {
    self.hidden = !self.hidden;
}

@end
