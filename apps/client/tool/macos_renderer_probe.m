#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CGGeometry.h>

// Minimal selector declarations keep the regression runnable against a signed
// app whose distributed frameworks omit development headers.
@protocol RendererProbeAPI <NSObject>
@property(nonatomic, strong) id videoTrack;
- (instancetype)initWithTextureRegistry:(id)registry messenger:(id)messenger;
- (CVPixelBufferRef)copyPixelBuffer;
- (void)setSize:(CGSize)size;
- (void)renderFrame:(id)frame;
- (void)dispose;
@end
@protocol PixelBufferProbeAPI <NSObject>
- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixels;
@end
@protocol VideoFrameProbeAPI <NSObject>
- (instancetype)initWithBuffer:(id)buffer rotation:(NSInteger)rotation
                   timeStampNs:(int64_t)timestamp;
@end
typedef void (^ProbeBinaryReply)(NSData *reply);
typedef void (^ProbeMessageHandler)(NSData *message, ProbeBinaryReply reply);

@interface ProbeRegistry : NSObject
@property(nonatomic) int notifications;
@property(nonatomic) int unregisters;
@end
@implementation ProbeRegistry
- (int64_t)registerTexture:(NSObject *)texture { return 7; }
- (void)textureFrameAvailable:(int64_t)textureId { self.notifications++; }
- (void)unregisterTexture:(int64_t)textureId { self.unregisters++; }
@end

@interface ProbeMessenger : NSObject
@end
@implementation ProbeMessenger
- (void)sendOnChannel:(NSString *)channel message:(NSData *)message {}
- (void)sendOnChannel:(NSString *)channel message:(NSData *)message
         binaryReply:(ProbeBinaryReply)callback { if (callback) callback(nil); }
- (int64_t)setMessageHandlerOnChannel:(NSString *)channel
        binaryMessageHandler:(ProbeMessageHandler)handler { return 1; }
- (void)cleanUpConnection:(int64_t)connection {}
@end

@interface ProbeTrack : NSObject
@property(nonatomic, strong) id lateFrame;
- (void)addRenderer:(id<RendererProbeAPI>)renderer;
- (void)removeRenderer:(id<RendererProbeAPI>)renderer;
@end
@implementation ProbeTrack
- (void)addRenderer:(id<RendererProbeAPI>)renderer {}
- (void)removeRenderer:(id<RendererProbeAPI>)renderer {
    if (self.lateFrame) [renderer renderFrame:self.lateFrame];
}
@end

static id SolidFrame(uint8_t gray, int width, int height) {
    CVPixelBufferRef pixels = nil;
    NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
        kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &pixels);
    NSCAssert(status == kCVReturnSuccess && pixels != nil, @"Synthetic pixels unavailable");
    CVPixelBufferLockBaseAddress(pixels, 0);
    uint8_t *data = CVPixelBufferGetBaseAddress(pixels);
    size_t stride = CVPixelBufferGetBytesPerRow(pixels);
    for (int row = 0; row < height; row++) {
        for (int column = 0; column < width; column++) {
            uint8_t *pixel = data + row * stride + column * 4;
            pixel[0] = pixel[1] = pixel[2] = gray;
            pixel[3] = 255;
        }
    }
    CVPixelBufferUnlockBaseAddress(pixels, 0);
    id<PixelBufferProbeAPI> buffer = [(id<PixelBufferProbeAPI>)
        [NSClassFromString(@"RTCCVPixelBuffer") alloc] initWithPixelBuffer:pixels];
    id frame = [(id<VideoFrameProbeAPI>)[NSClassFromString(@"RTCVideoFrame") alloc]
        initWithBuffer:buffer rotation:0 timeStampNs:1];
    CVPixelBufferRelease(pixels);
    return frame;
}

static uint32_t FirstPixel(CVPixelBufferRef pixels) {
    NSCAssert(pixels != nil, @"Renderer did not expose a pixel buffer");
    CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    uint32_t value = *(const uint32_t *)CVPixelBufferGetBaseAddress(pixels);
    CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    return value;
}

static NSString *RendererClassName = @"FlutterRTCVideoRenderer";

static id<RendererProbeAPI> MakeRenderer(ProbeRegistry *registry) {
    Class rendererClass = NSClassFromString(RendererClassName);
    NSCAssert(rendererClass != Nil, @"Production renderer class unavailable");
    id<RendererProbeAPI> renderer = [(id<RendererProbeAPI>)[rendererClass alloc]
        initWithTextureRegistry:registry messenger:[ProbeMessenger new]];
    renderer.videoTrack = [ProbeTrack new];
    [renderer setSize:CGSizeMake(2, 2)];
    return renderer;
}

static uint32_t ReferencePixel(uint8_t gray) {
    ProbeRegistry *registry = [ProbeRegistry new];
    id<RendererProbeAPI> renderer = MakeRenderer(registry);
    [renderer renderFrame:SolidFrame(gray, 2, 2)];
    CVPixelBufferRef pixels = [renderer copyPixelBuffer];
    uint32_t value = FirstPixel(pixels);
    CVPixelBufferRelease(pixels);
    [renderer dispose];
    return value;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSCAssert(argc >= 2, @"Pass the candidate flutter_webrtc.framework bundle");
        NSBundle *plugin = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[1]]];
        NSError *loadError = nil;
        NSCAssert([plugin loadAndReturnError:&loadError], @"Cannot load renderer %@", loadError);
        if (argc == 3) RendererClassName = [NSString stringWithUTF8String:argv[2]];
        uint32_t latestReference = ReferencePixel(200);
        uint32_t nextReference = ReferencePixel(80);
        ProbeRegistry *registry = [ProbeRegistry new];
        id<RendererProbeAPI> renderer = MakeRenderer(registry);
        // No raster consumption while the window is occluded or its thread is busy.
        [renderer renderFrame:SolidFrame(50, 2, 2)];
        [renderer renderFrame:SolidFrame(100, 2, 2)];
        [renderer renderFrame:SolidFrame(200, 2, 2)];
        CVPixelBufferRef heldByRaster = [renderer copyPixelBuffer];
        uint32_t first = FirstPixel(heldByRaster);
        BOOL latestWins = first == latestReference;
        int notificationsBeforeNext = registry.notifications;
        // Flutter retains the first buffer while a subsequent frame is decoded.
        [renderer renderFrame:SolidFrame(80, 2, 2)];
        BOOL retainedBufferImmutable = FirstPixel(heldByRaster) == first;
        CVPixelBufferRef next = [renderer copyPixelBuffer];
        BOOL nextFrameCorrect = FirstPixel(next) == nextReference;
        BOOL notificationsCoalesced = notificationsBeforeNext == 1 && registry.notifications == 2;
        uint32_t heldBeforeDispose = FirstPixel(heldByRaster);
        [renderer dispose];
        BOOL retainedBufferSurvivesDispose = FirstPixel(heldByRaster) == heldBeforeDispose;
        CVPixelBufferRelease(heldByRaster);
        CVPixelBufferRelease(next);
        ProbeRegistry *swapRegistry = [ProbeRegistry new];
        id<RendererProbeAPI> swap = MakeRenderer(swapRegistry);
        [swap renderFrame:SolidFrame(50, 2, 2)];
        CVPixelBufferRef previous = [swap copyPixelBuffer];
        CVPixelBufferRelease(previous);
        ((ProbeTrack *)swap.videoTrack).lateFrame = SolidFrame(200, 2, 2);
        swap.videoTrack = [ProbeTrack new];
        CVPixelBufferRef stale = [swap copyPixelBuffer];
        BOOL trackChangeDropsPrevious = stale == nil;
        if (stale) CVPixelBufferRelease(stale);
        [swap setSize:CGSizeMake(2, 2)];
        [swap renderFrame:SolidFrame(80, 2, 2)];
        CVPixelBufferRef small = [swap copyPixelBuffer];
        uint32_t smallPixel = FirstPixel(small);
        [swap setSize:CGSizeMake(4, 2)];
        [swap renderFrame:SolidFrame(80, 4, 2)];
        CVPixelBufferRef resized = [swap copyPixelBuffer];
        BOOL sizeChangeCorrect = CVPixelBufferGetWidth(resized) == 4 &&
            CVPixelBufferGetHeight(resized) == 2 && FirstPixel(resized) == nextReference &&
            FirstPixel(small) == smallPixel;
        CVPixelBufferRelease(resized);
        CVPixelBufferRelease(small);
        [swap dispose];
        printf("{\"production_renderer_component\":true,\"physical_display_measured\":false,"
               "\"synthetic_frames\":true,\"mock_texture_registry\":true,"
               "\"latest_frame_wins\":%s,\"retained_buffer_immutable\":%s,"
               "\"next_frame_correct\":%s,\"notifications_coalesced\":%s,"
               "\"retained_buffer_survives_dispose\":%s,"
               "\"track_change_discards_previous_frame\":%s,\"size_change_correct\":%s}\n",
               latestWins ? "true" : "false", retainedBufferImmutable ? "true" : "false",
               nextFrameCorrect ? "true" : "false", notificationsCoalesced ? "true" : "false",
               retainedBufferSurvivesDispose ? "true" : "false",
               trackChangeDropsPrevious ? "true" : "false", sizeChangeCorrect ? "true" : "false");
        return latestWins && retainedBufferImmutable && nextFrameCorrect &&
            notificationsCoalesced && retainedBufferSurvivesDispose &&
            trackChangeDropsPrevious && sizeChangeCorrect ? 0 : 1;
    }
}
