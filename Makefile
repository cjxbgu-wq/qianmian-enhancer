ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard mediaserverd

# 必须保留！iOS 16 rootless 越狱才能注入
THEOS_PACKAGE_SCHEME = rootless
THEOS_NO_PHOENICIA = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QianmianEnhancer

QianmianEnhancer_FILES = Tweak.xm QMEnhancerView.m
QianmianEnhancer_FRAMEWORKS = UIKit CoreGraphics CoreImage CoreVideo QuartzCore
QianmianEnhancer_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
