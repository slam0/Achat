#import "ACAudio.h"
#import "ACCrash.h"
#include "ac_tgc.h"
#include <AudioToolbox/AudioToolbox.h>
#include <string.h>

#define MAX_FRAMES 4096

@interface ACAudio ()
- (void)interruption:(UInt32)state;
@end

/* Wskaźnik silnika jest czytany w wątku audio; zerujemy go przed zatrzymaniem urządzenia. */
static void *volatile gEngine;
static ACAudioPushFn volatile gPush;
static ACAudioPullFn volatile gPull;
static AudioUnit gUnit;
static int16_t gCapBuf[MAX_FRAMES];

static OSStatus CaptureCB(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus, UInt32 frames, AudioBufferList *io)
{
    AudioBufferList bl;
    void *e = gEngine;
    ACAudioPushFn push = gPush;
    OSStatus st;
    if (!e || !push || !gUnit || frames == 0 || frames > MAX_FRAMES) return noErr;
    bl.mNumberBuffers = 1;
    bl.mBuffers[0].mNumberChannels = 1;
    bl.mBuffers[0].mDataByteSize = frames * 2;
    bl.mBuffers[0].mData = gCapBuf;
    st = AudioUnitRender(gUnit, flags, ts, 1, frames, &bl);
    if (st == noErr) push(e, gCapBuf, (int)frames);
    return noErr;
}

static OSStatus PlayCB(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus, UInt32 frames, AudioBufferList *io)
{
    void *e = gEngine;
    ACAudioPullFn pull = gPull;
    UInt32 i;
    for (i = 0; i < io->mNumberBuffers; i++) {
        AudioBuffer *b = &io->mBuffers[i];
        if (!b->mData) continue;
        if (!e || !pull || i > 0) memset(b->mData, 0, b->mDataByteSize);
        else pull(e, (int16_t *)b->mData, (int)(b->mDataByteSize / 2));
    }
    return noErr;
}

static void InterruptionCB(void *ud, UInt32 state)
{
    ACAudio *a = (__bridge ACAudio *)ud;
    [a interruption:state];
}

@implementation ACAudio {
    BOOL _running, _sessionInit, _speaker;
}
@synthesize running = _running;

static NSString *Code(OSStatus s) { return [NSString stringWithFormat:@"%d", (int)s]; }

- (void)interruption:(UInt32)state
{
    if (!_running || !gUnit) return;
    if (state == kAudioSessionBeginInterruption) {
        AudioOutputUnitStop(gUnit);
    } else {
        AudioSessionSetActive(true);
        AudioOutputUnitStart(gUnit);
    }
}

- (BOOL)setupUnit:(OSType)sub name:(NSString *)name error:(NSString **)err
{
    AudioComponentDescription d;
    d.componentType = kAudioUnitType_Output;
    d.componentSubType = sub;
    d.componentManufacturer = kAudioUnitManufacturer_Apple;
    d.componentFlags = 0;
    d.componentFlagsMask = 0;
    AudioComponent comp = AudioComponentFindNext(NULL, &d);
    if (!comp) { if (err) *err = [NSString stringWithFormat:@"%@: brak komponentu", name]; return NO; }
    OSStatus st = AudioComponentInstanceNew(comp, &gUnit);
    if (st != noErr) { gUnit = NULL; if (err) *err = [NSString stringWithFormat:@"%@: tworzenie %@", name, Code(st)]; return NO; }

    UInt32 one = 1;
    st = AudioUnitSetProperty(gUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, sizeof(one));
    if (st == noErr) st = AudioUnitSetProperty(gUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, sizeof(one));
    if (st != noErr) { if (err) *err = [NSString stringWithFormat:@"%@: EnableIO %@", name, Code(st)]; goto bad; }

    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof(f));
    f.mSampleRate = ACG_SAMPLE_RATE;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    f.mFramesPerPacket = 1;
    f.mChannelsPerFrame = 1;
    f.mBitsPerChannel = 16;
    f.mBytesPerFrame = 2;
    f.mBytesPerPacket = 2;
    st = AudioUnitSetProperty(gUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &f, sizeof(f));
    if (st == noErr) st = AudioUnitSetProperty(gUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof(f));
    if (st != noErr) { if (err) *err = [NSString stringWithFormat:@"%@: format %@", name, Code(st)]; goto bad; }

    AURenderCallbackStruct cb;
    cb.inputProc = CaptureCB;
    cb.inputProcRefCon = NULL;
    st = AudioUnitSetProperty(gUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, sizeof(cb));
    if (st != noErr) { if (err) *err = [NSString stringWithFormat:@"%@: wejście %@", name, Code(st)]; goto bad; }
    cb.inputProc = PlayCB;
    st = AudioUnitSetProperty(gUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof(cb));
    if (st != noErr) { if (err) *err = [NSString stringWithFormat:@"%@: wyjście %@", name, Code(st)]; goto bad; }

    st = AudioUnitInitialize(gUnit);
    if (st != noErr) { if (err) *err = [NSString stringWithFormat:@"%@: inicjalizacja %@", name, Code(st)]; goto bad; }
    return YES;
bad:
    AudioComponentInstanceDispose(gUnit);
    gUnit = NULL;
    return NO;
}

- (BOOL)startWithEngine:(void *)engine push:(ACAudioPushFn)push pull:(ACAudioPullFn)pull error:(NSString **)err
{
    if (_running) return YES;
    OSStatus st;
    if (!_sessionInit) {
        st = AudioSessionInitialize(NULL, NULL, InterruptionCB, (__bridge void *)self);
        if (st != noErr && st != kAudioSessionAlreadyInitialized) { if (err) *err = [NSString stringWithFormat:@"sesja audio %@", Code(st)]; return NO; }
        _sessionInit = YES;
    }
    UInt32 cat = kAudioSessionCategory_PlayAndRecord;
    st = AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(cat), &cat);
    if (st != noErr) { if (err) *err = [NSString stringWithFormat:@"kategoria audio %@", Code(st)]; return NO; }
    UInt32 mode = kAudioSessionMode_VoiceChat;
    AudioSessionSetProperty(kAudioSessionProperty_Mode, sizeof(mode), &mode);
    Float32 dur = 0.02f;
    AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(dur), &dur);
    st = AudioSessionSetActive(true);
    if (st != noErr) { if (err) *err = [NSString stringWithFormat:@"aktywacja audio %@", Code(st)]; return NO; }
    [self setSpeaker:_speaker];

    gPush = push;
    gPull = pull;
    gEngine = engine;
    NSString *e1 = nil, *e2 = nil;
    BOOL ok = [self setupUnit:kAudioUnitSubType_VoiceProcessingIO name:@"VPIO" error:&e1];
    if (!ok) {
        ACCrumb([@"audio: " stringByAppendingString:e1 ?: @"?"]);
        ok = [self setupUnit:kAudioUnitSubType_RemoteIO name:@"RIO" error:&e2];
    }
    if (!ok) {
        gEngine = NULL;
        AudioSessionSetActive(false);
        if (err) *err = [NSString stringWithFormat:@"%@; %@", e1 ?: @"", e2 ?: @""];
        return NO;
    }
    st = AudioOutputUnitStart(gUnit);
    if (st != noErr) {
        gEngine = NULL;
        AudioUnitUninitialize(gUnit);
        AudioComponentInstanceDispose(gUnit);
        gUnit = NULL;
        AudioSessionSetActive(false);
        if (err) *err = [NSString stringWithFormat:@"start audio %@", Code(st)];
        return NO;
    }
    _running = YES;
    ACCrumb(e1 ? @"audio: RemoteIO" : @"audio: VoiceProcessingIO");
    return YES;
}

- (void)stop
{
    if (!_running) return;
    _running = NO;
    gEngine = NULL;
    if (gUnit) {
        AudioOutputUnitStop(gUnit);
        AudioUnitUninitialize(gUnit);
        AudioComponentInstanceDispose(gUnit);
        gUnit = NULL;
    }
    UInt32 route = kAudioSessionOverrideAudioRoute_None;
    AudioSessionSetProperty(kAudioSessionProperty_OverrideAudioRoute, sizeof(route), &route);
    AudioSessionSetActive(false);
}

- (void)setSpeaker:(BOOL)on
{
    _speaker = on;
    UInt32 route = on ? kAudioSessionOverrideAudioRoute_Speaker : kAudioSessionOverrideAudioRoute_None;
    AudioSessionSetProperty(kAudioSessionProperty_OverrideAudioRoute, sizeof(route), &route);
}

@end
