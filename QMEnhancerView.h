#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>

@interface QMEnhancerView : UIView

@property (nonatomic, assign) CGFloat zoomScale;
@property (nonatomic, assign) BOOL colorMappingEnabled;
@property (nonatomic, strong) UIColor *mappingColor;
@property (nonatomic, assign) CGFloat colorMixIntensity;
@property (nonatomic, assign) BOOL softGlowEnabled;
@property (nonatomic, assign) BOOL beautyEnabled;
@property (nonatomic, assign) BOOL skinEnabled;
@property (nonatomic, strong) UIWindow *floatWindow;

+ (instancetype)sharedInstance;
+ (void)processFrame:(CVPixelBufferRef)pixelBuffer;
- (void)processPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)showInWindow:(UIWindow *)window;
- (void)toggleVisibility;

@end
