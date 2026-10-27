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

# kodek Opus (stałoprzecinkowy, bez części zmiennoprzecinkowej) — rozmowy głosowe
OPUS_FILES = $(sort $(wildcard opus/celt/*.c)) $(sort $(wildcard opus/silk/*.c)) $(sort $(wildcard opus/silk/fixed/*.c)) opus/src/opus.c opus/src/opus_decoder.c opus/src/opus_encoder.c opus/src/repacketizer.c

AeroChat_FILES = main.m AppDelegate.m ACStore.m ACCrash.m ACTheme.m ACMetal.m ACViews.m ACDemo.m ACChatsController.m ACContactsController.m ACChatController.m ACSettingsController.m ACTelegram.m ACTelegramMedia.m ACMedia.m ACSetupController.m ACCall.m ACCallController.m ACAudio.m tg_bn.c tg_crypto.c tg_tl.c tg_mt.c ac_libc.c ac_dh.c ac_tgc.c $(OPUS_FILES)
AeroChat_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore AudioToolbox
AeroChat_CFLAGS = -DHAVE_CONFIG_H -Iopus -Iopus/include -Iopus/celt -Iopus/silk -Iopus/silk/fixed -Iopus/src -fobjc-arc -O2 -fno-stack-protector -D_FORTIFY_SOURCE=0 -Wno-deprecated-declarations -Wno-unused-command-line-argument -Wno-error

include $(THEOS_MAKE_PATH)/application.mk

after-install::
	install.exec "uicache"
