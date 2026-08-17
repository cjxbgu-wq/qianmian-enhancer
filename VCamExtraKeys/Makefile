ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

# 保持 iOS 16 rootless 越狱注登记
THEOS_PACKAGE_SCHEME = rootless
THEOS_NO_PHOENICIA = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCamExtraKeys

VCamExtraKeys_FILES = Tweak.xm
VCamExtraKeys_FRAMEWORKS = UIKit CoreGraphics QuartzCore
VCamExtraKeys_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
