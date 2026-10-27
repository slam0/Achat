/* Konfiguracja Opusa dla AeroChat: arytmetyka stałoprzecinkowa (iOS 6 / armv7 bez FPU w kodeku), bez analizy zmiennoprzecinkowej */
#ifndef AC_OPUS_CONFIG_H
#define AC_OPUS_CONFIG_H
#define OPUS_BUILD 1
#define FIXED_POINT 1
#define DISABLE_FLOAT_API 1
#define USE_ALLOCA 1
#define OPUS_VERSION "1.3.1"
#endif
