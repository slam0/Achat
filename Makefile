# AeroChat - komunikator w stylu Frutiger Aero / skeuomorfizmu dla iOS 6 (jailbreak), budowany w Theosie.
SDKVER ?= 6.1

# armv7 działa na iPhone 3GS/4/4S/5 i iPod touch 4/5 (iOS 6.x)
export ARCHS = armv7
export TARGET = iphone:clang:$(SDKVER):6.0

# stary dpkg z iOS 6 nie czyta nowszej kompresji niż gzip
export THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip

INSTALL_TARGET_PROCESSES = AeroChat

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = AeroChat

AeroChat_FILES = main.m AppDelegate.m ACStore.m ACCrash.m ACTheme.m ACMetal.m ACViews.m ACDemo.m ACChatsController.m ACContactsController.m ACChatController.m ACSettingsController.m ACTelegram.m ACTelegramMedia.m ACMedia.m ACSetupController.m tg_bn.c tg_crypto.c tg_tl.c tg_mt.c ac_libc.c
AeroChat_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
AeroChat_CFLAGS = -fobjc-arc -O2 -fno-stack-protector -D_FORTIFY_SOURCE=0 -Wno-deprecated-declarations -Wno-unused-command-line-argument

include $(THEOS_MAKE_PATH)/application.mk

after-install::
	install.exec "uicache"
