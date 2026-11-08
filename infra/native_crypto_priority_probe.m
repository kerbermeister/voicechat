#import <WebRTC/WebRTC.h>
#import <mach/mach.h>
#import <pthread.h>
#import <sys/qos.h>
#import <unistd.h>

static BOOL cryptoThreadsReady(void) {
  thread_act_array_t threads = NULL;
  mach_msg_type_number_t count = 0;
  if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return NO;
  unsigned found = 0, ready = 0;
  for (unsigned i = 0; i < count; ++i) {
    pthread_t thread = pthread_from_mach_thread_np(threads[i]);
    char name[64] = {0};
    if (thread && pthread_getname_np(thread, name, sizeof(name)) == 0 &&
        strncmp(name, "FrameCryptorTransformer", strlen("FrameCryptorTransformer")) == 0) {
      qos_class_t qos = QOS_CLASS_UNSPECIFIED;
      ++found;
      if (pthread_get_qos_class_np(thread, &qos, NULL) == 0 &&
          qos == QOS_CLASS_USER_INTERACTIVE) ++ready;
    }
    mach_port_deallocate(mach_task_self(), threads[i]);
  }
  vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_t));
  return found == 4 && ready == 4;
}

int main(void) {
  @autoreleasepool {
    if (pthread_set_qos_class_self_np(QOS_CLASS_DEFAULT, 0) != 0) return 1;
    RTCPeerConnectionFactory *factory = [[RTCPeerConnectionFactory alloc] init];
    RTCConfiguration *configuration = [[RTCConfiguration alloc] init];
    configuration.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    RTCMediaConstraints *constraints =
        [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
    RTCPeerConnection *peer = [factory peerConnectionWithConfiguration:configuration
                                                         constraints:constraints delegate:nil];
    RTCRtpTransceiver *audio = [peer addTransceiverOfType:RTCRtpMediaTypeAudio];
    RTCRtpTransceiver *video = [peer addTransceiverOfType:RTCRtpMediaTypeVideo];
    audio.sender.track = [factory audioTrackWithSource:[factory audioSourceWithConstraints:constraints]
                                             trackId:@"audio"];
    video.sender.track = [factory videoTrackWithSource:[factory videoSource] trackId:@"video"];
    if (![audio.sender.track.kind isEqualToString:@"audio"] ||
        ![audio.receiver.track.kind isEqualToString:@"audio"] ||
        ![video.sender.track.kind isEqualToString:@"video"] ||
        ![video.receiver.track.kind isEqualToString:@"video"]) return 1;
    RTCFrameCryptorKeyProvider *keys = [[RTCFrameCryptorKeyProvider alloc]
        initWithRatchetSalt:[NSData data] ratchetWindowSize:0 sharedKeyMode:NO
        uncryptedMagicBytes:nil failureTolerance:0 keyRingSize:1
        discardFrameWhenCryptorNotReady:YES];
    RTCFrameCryptor *audioSender = [[RTCFrameCryptor alloc] initWithFactory:factory
        rtpSender:audio.sender participantId:@"audio-sender"
        algorithm:RTCCryptorAlgorithmAesGcm keyProvider:keys];
    RTCFrameCryptor *videoSender = [[RTCFrameCryptor alloc] initWithFactory:factory
        rtpSender:video.sender participantId:@"video-sender"
        algorithm:RTCCryptorAlgorithmAesGcm keyProvider:keys];
    RTCFrameCryptor *audioReceiver = [[RTCFrameCryptor alloc] initWithFactory:factory
        rtpReceiver:audio.receiver participantId:@"audio-receiver"
        algorithm:RTCCryptorAlgorithmAesGcm keyProvider:keys];
    RTCFrameCryptor *videoReceiver = [[RTCFrameCryptor alloc] initWithFactory:factory
        rtpReceiver:video.receiver participantId:@"video-receiver"
        algorithm:RTCCryptorAlgorithmAesGcm keyProvider:keys];
    if (!audioSender || !videoSender || !audioReceiver || !videoReceiver) return 1;
    __attribute__((objc_precise_lifetime)) NSArray *cryptors =
        @[audioSender, videoSender, audioReceiver, videoReceiver];
    if (cryptors.count != 4) return 1;
    BOOL ready = NO;
    for (unsigned i = 0; i < 100 && !ready; ++i) {
      ready = cryptoThreadsReady();
      if (!ready) usleep(10000);
    }
    [peer close];
    return ready ? 0 : 2;
  }
}
