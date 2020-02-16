/*
 *  Copyright 2014 The WebRTC Project Authors. All rights reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "ARDAppClient+Internal.h"

#import <sys/time.h>

#import <WebRTC/CFHijackCapturerDelegate.h>
#import <WebRTC/RTCAudioTrack.h>
#import <WebRTC/RTCCameraVideoCapturer.h>
#import <WebRTC/RTCConfiguration.h>
#import <WebRTC/RTCDefaultVideoDecoderFactory.h>
#import <WebRTC/RTCDefaultVideoEncoderFactory.h>
#import <WebRTC/RTCFileLogger.h>
#import <WebRTC/RTCFileVideoCapturer.h>
#import <WebRTC/RTCIceServer.h>
#import <WebRTC/RTCLogging.h>
#import <WebRTC/RTCMediaConstraints.h>
#import <WebRTC/RTCMediaStream.h>
#import <WebRTC/RTCPeerConnectionFactory.h>
#import <WebRTC/RTCRtpSender.h>
#import <WebRTC/RTCRtpTransceiver.h>
#import <WebRTC/RTCTracing.h>
#import <WebRTC/RTCVideoSource.h>
#import <WebRTC/RTCVideoTrack.h>
#import <WebRTC/CFVideoProcessor.h>

#import "ARDAppEngineClient.h"
#import "ARDExternalSampleCapturer.h"
#import "ARDJoinResponse.h"
#import "ARDMessageResponse.h"
#import "ARDSettingsModel.h"
#import "ARDSignalingMessage.h"
#import "ARDTimerProxy.h"
#import "ARDTURNClient+Internal.h"
#import "ARDUtilities.h"
#import "ARDWebSocketChannel.h"
#import "RTCIceCandidate+JSON.h"
#import "RTCSessionDescription+JSON.h"

static NSString * const kARDIceServerRequestUrl = @"http://123.56.66.149:3033/iceconfig";

static NSString * const kARDAppClientErrorDomain = @"ARDAppClient";
static NSInteger const kARDAppClientErrorUnknown = -1;
static NSInteger const kARDAppClientErrorRoomFull = -2;
static NSInteger const kARDAppClientErrorCreateSDP = -3;
static NSInteger const kARDAppClientErrorSetSDP = -4;
static NSInteger const kARDAppClientErrorInvalidClient = -5;
static NSInteger const kARDAppClientErrorInvalidRoom = -6;
static NSString * const kARDMediaStreamId = @"ARDAMS";
static NSString * const kARDAudioTrackId = @"ARDAMSa0";
static NSString * const kARDVideoTrackId = @"ARDAMSv0";
static NSString * const kARDVideoTrackKind = @"video";

// TODO(tkchin): Add these as UI options.
#if defined(WEBRTC_IOS)
static BOOL const kARDAppClientEnableTracing = NO;
static BOOL const kARDAppClientEnableRtcEventLog = YES;
static int64_t const kARDAppClientAecDumpMaxSizeInBytes = 5e6;  // 5 MB.
static int64_t const kARDAppClientRtcEventLogMaxSizeInBytes = 5e6;  // 5 MB.
#endif
static int const kKbpsMultiplier = 1000;

@implementation ARDAppClient {
  RTCFileLogger *_fileLogger;
  ARDTimerProxy *_statsTimer;
  ARDSettingsModel *_settings;
  RTCVideoTrack *_localVideoTrack;
  CFHijackCapturerDelegate* _hijackDelegate;
  bool _recording;
  RTCDataChannel* _sendDataChannel;
  RTCDataChannel* _recvDataChannel;
  void (^_sendDcMsg)(void);
  int _testCount;
  __weak id<CFVideoProcessorDelegate> _videoProcessorDelegate;
}

@synthesize shouldGetStats = _shouldGetStats;
@synthesize state = _state;
@synthesize delegate = _delegate;
@synthesize roomServerClient = _roomServerClient;
@synthesize channel = _channel;
@synthesize loopbackChannel = _loopbackChannel;
@synthesize turnClient = _turnClient;
@synthesize peerConnection = _peerConnection;
@synthesize factory = _factory;
@synthesize messageQueue = _messageQueue;
@synthesize isTurnComplete = _isTurnComplete;
@synthesize hasReceivedSdp  = _hasReceivedSdp;
@synthesize roomId = _roomId;
@synthesize clientId = _clientId;
@synthesize isInitiator = _isInitiator;
@synthesize iceServers = _iceServers;
@synthesize webSocketURL = _websocketURL;
@synthesize webSocketRestURL = _websocketRestURL;
@synthesize defaultPeerConnectionConstraints =
    _defaultPeerConnectionConstraints;
@synthesize isLoopback = _isLoopback;
@synthesize broadcast = _broadcast;

- (instancetype)init {
  return [self initWithDelegate:nil];
}

- (instancetype)initWithDelegate:(id<ARDAppClientDelegate>)delegate {
  if (self = [super init]) {
    _roomServerClient = [[ARDAppEngineClient alloc] init];
    _delegate = delegate;
    NSURL *turnRequestURL = [NSURL URLWithString:kARDIceServerRequestUrl];
    _turnClient = [[ARDTURNClient alloc] initWithURL:turnRequestURL];
    _recording = false;
    _sendDcMsg = nil;
    _testCount = 0;
    [self configure];
  }
  return self;
}

// TODO(tkchin): Provide signaling channel factory interface so we can recreate
// channel if we need to on network failure. Also, make this the default public
// constructor.
- (instancetype)initWithRoomServerClient:(id<ARDRoomServerClient>)rsClient
                        signalingChannel:(id<ARDSignalingChannel>)channel
                              turnClient:(id<ARDTURNClient>)turnClient
                                delegate:(id<ARDAppClientDelegate>)delegate {
  NSParameterAssert(rsClient);
  NSParameterAssert(channel);
  NSParameterAssert(turnClient);
  if (self = [super init]) {
    _roomServerClient = rsClient;
    _channel = channel;
    _turnClient = turnClient;
    _delegate = delegate;
    [self configure];
  }
  return self;
}

- (void)configure {
  _messageQueue = [NSMutableArray array];
  _iceServers = [NSMutableArray array];
  _fileLogger = [[RTCFileLogger alloc] init];
  [_fileLogger start];
}

- (void)dealloc {
  self.shouldGetStats = NO;
  [self disconnect];
}

- (void)setShouldGetStats:(BOOL)shouldGetStats {
  if (_shouldGetStats == shouldGetStats) {
    return;
  }
  if (shouldGetStats) {
    __weak ARDAppClient *weakSelf = self;
    _statsTimer = [[ARDTimerProxy alloc] initWithInterval:1
                                                  repeats:YES
                                             timerHandler:^{
      ARDAppClient *strongSelf = weakSelf;
      [strongSelf.peerConnection statsForTrack:nil
                              statsOutputLevel:RTCStatsOutputLevelDebug
                             completionHandler:^(NSArray *stats) {
        dispatch_async(dispatch_get_main_queue(), ^{
          ARDAppClient *strongSelf = weakSelf;
          [strongSelf.delegate appClient:strongSelf didGetStats:stats];
        });
      }];
    }];
  } else {
    [_statsTimer invalidate];
    _statsTimer = nil;
  }
  _shouldGetStats = shouldGetStats;
}

- (void)setState:(ARDAppClientState)state {
  if (_state == state) {
    return;
  }
  _state = state;
  [_delegate appClient:self didChangeState:_state];
}

- (void)connectToRoomWithId:(NSString *)roomId
                   settings:(ARDSettingsModel *)settings
                 isLoopback:(BOOL)isLoopback {
  NSParameterAssert(roomId.length);
  NSParameterAssert(_state == kARDAppClientStateDisconnected);
  _settings = settings;
  _isLoopback = isLoopback;
  self.state = kARDAppClientStateConnecting;

  RTCDefaultVideoDecoderFactory *decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
  RTCDefaultVideoEncoderFactory *encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
  encoderFactory.preferredCodec = [settings currentVideoCodecSettingFromStore];
  _factory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                       decoderFactory:decoderFactory];

#if defined(WEBRTC_IOS)
  if (kARDAppClientEnableTracing) {
    NSString *filePath = [self documentsFilePathForFileName:@"webrtc-trace.txt"];
    RTCStartInternalCapture(filePath);
  }
#endif

  // Request TURN.
  __weak ARDAppClient *weakSelf = self;
  [_turnClient requestServersWithCompletionHandler:^(NSArray *turnServers,
                                                     NSError *error) {
    if (error) {
      RTCLogError(@"Error retrieving TURN servers: %@", error.localizedDescription);
    }
    ARDAppClient *strongSelf = weakSelf;
    [strongSelf.iceServers addObjectsFromArray:turnServers];
    strongSelf.isTurnComplete = YES;
    [strongSelf startSignalingIfReady];
  }];

  // Join room on room server.
  [_roomServerClient joinRoomWithRoomId:roomId
                             isLoopback:isLoopback
      completionHandler:^(ARDJoinResponse *response, NSError *error) {
    ARDAppClient *strongSelf = weakSelf;
    if (error) {
      [strongSelf.delegate appClient:strongSelf didError:error];
      return;
    }
    NSError *joinError =
        [[strongSelf class] errorForJoinResultType:response.result];
    if (joinError) {
      RTCLogError(@"Failed to join room:%@ on room server.", roomId);
      [strongSelf disconnect];
      [strongSelf.delegate appClient:strongSelf didError:joinError];
      return;
    }
    RTCLog(@"Joined room:%@ on room server.", roomId);
    strongSelf.roomId = response.roomId;
    strongSelf.clientId = response.clientId;
    strongSelf.isInitiator = response.isInitiator;
    for (ARDSignalingMessage *message in response.messages) {
      if (message.type == kARDSignalingMessageTypeOffer ||
          message.type == kARDSignalingMessageTypeAnswer) {
        strongSelf.hasReceivedSdp = YES;
        [strongSelf.messageQueue insertObject:message atIndex:0];
      } else {
        [strongSelf.messageQueue addObject:message];
      }
    }
    strongSelf.webSocketURL = response.webSocketURL;
    strongSelf.webSocketRestURL = response.webSocketRestURL;
    [strongSelf registerWithColliderIfReady];
    [strongSelf startSignalingIfReady];
  }];
}

- (void)disconnect {
  if (_state == kARDAppClientStateDisconnected) {
    return;
  }
  if (self.hasJoinedRoomServerRoom) {
    [_roomServerClient leaveRoomWithRoomId:_roomId
                                  clientId:_clientId
                         completionHandler:nil];
  }
  if (_channel) {
    if (_channel.state == kARDSignalingChannelStateRegistered) {
      // Tell the other client we're hanging up.
      ARDByeMessage *byeMessage = [[ARDByeMessage alloc] init];
      [_channel sendMessage:byeMessage];
    }
    // Disconnect from collider.
    _channel = nil;
  }
  _clientId = nil;
  _roomId = nil;
  _isInitiator = NO;
  _hasReceivedSdp = NO;
  _messageQueue = [NSMutableArray array];
  _localVideoTrack = nil;
#if defined(WEBRTC_IOS)
  [_factory stopAecDump];
  [_peerConnection stopRtcEventLog];
#endif
  [_peerConnection close];
  _peerConnection = nil;
  self.state = kARDAppClientStateDisconnected;
#if defined(WEBRTC_IOS)
  if (kARDAppClientEnableTracing) {
    RTCStopInternalCapture();
  }
#endif
}

- (void)toggleRecorder {
  _recording = !_recording;
  int dir = 1;
  if (_recording) {
      struct timeval time;
      gettimeofday(&time, nil);
      int64_t now_ms = ((time.tv_sec * 1000) + (time.tv_usec / 1000));
      NSString* folder = [NSSearchPathForDirectoriesInDomains(
          NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
      [_peerConnection
          startRecorder:dir
                   path:[NSString stringWithFormat:@"%@/recording_%lld.mkv",
                                                   folder, now_ms]];
  } else {
    [_peerConnection stopRecorder:dir];
  }
}

- (void)toggleVideoTrack {
  _localVideoTrack.isEnabled = !_localVideoTrack.isEnabled;
  [_hijackDelegate toggleMute:!_localVideoTrack.isEnabled];
}

#pragma mark - ARDSignalingChannelDelegate

- (void)channel:(id<ARDSignalingChannel>)channel
    didReceiveMessage:(ARDSignalingMessage *)message {
  switch (message.type) {
    case kARDSignalingMessageTypeOffer:
    case kARDSignalingMessageTypeAnswer:
      // Offers and answers must be processed before any other message, so we
      // place them at the front of the queue.
      _hasReceivedSdp = YES;
      [_messageQueue insertObject:message atIndex:0];
      break;
    case kARDSignalingMessageTypeCandidate:
    case kARDSignalingMessageTypeCandidateRemoval:
      [_messageQueue addObject:message];
      break;
    case kARDSignalingMessageTypeBye:
      // Disconnects can be processed immediately.
      [self processSignalingMessage:message];
      return;
  }
  [self drainMessageQueueIfReady];
}

- (void)channel:(id<ARDSignalingChannel>)channel
    didChangeState:(ARDSignalingChannelState)state {
  switch (state) {
    case kARDSignalingChannelStateOpen:
      break;
    case kARDSignalingChannelStateRegistered:
      break;
    case kARDSignalingChannelStateClosed:
    case kARDSignalingChannelStateError:
      // TODO(tkchin): reconnection scenarios. Right now we just disconnect
      // completely if the websocket connection fails.
      [self disconnect];
      break;
  }
}

#pragma mark - RTCPeerConnectionDelegate
// Callbacks for this delegate occur on non-main thread and need to be
// dispatched back to main queue as needed.

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didChangeSignalingState:(RTCSignalingState)stateChanged {
  RTCLog(@"Signaling state changed: %ld", (long)stateChanged);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
          didAddStream:(RTCMediaStream *)stream {
  RTCLog(@"Stream with %lu video tracks and %lu audio tracks was added.",
         (unsigned long)stream.videoTracks.count,
         (unsigned long)stream.audioTracks.count);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didStartReceivingOnTransceiver:(RTCRtpTransceiver *)transceiver {
  RTCMediaStreamTrack *track = transceiver.receiver.track;
  RTCLog(@"Now receiving %@ on track %@.", track.kind, track.trackId);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
       didRemoveStream:(RTCMediaStream *)stream {
  RTCLog(@"Stream was removed.");
}

- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {
  RTCLog(@"WARNING: Renegotiation needed but unimplemented.");
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didChangeIceConnectionState:(RTCIceConnectionState)newState {
  RTCLog(@"ICE state changed: %ld", (long)newState);
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.delegate appClient:self didChangeConnectionState:newState];
  });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didChangeConnectionState:(RTCPeerConnectionState)newState {
  RTCLog(@"ICE+DTLS state changed: %ld", (long)newState);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didChangeIceGatheringState:(RTCIceGatheringState)newState {
  RTCLog(@"ICE gathering state changed: %ld", (long)newState);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didGenerateIceCandidate:(RTCIceCandidate *)candidate {
  dispatch_async(dispatch_get_main_queue(), ^{
    ARDICECandidateMessage *message =
        [[ARDICECandidateMessage alloc] initWithCandidate:candidate];
    [self sendSignalingMessage:message];
  });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {
  dispatch_async(dispatch_get_main_queue(), ^{
    ARDICECandidateRemovalMessage *message =
        [[ARDICECandidateRemovalMessage alloc]
            initWithRemovedCandidates:candidates];
    [self sendSignalingMessage:message];
  });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
     didChangeLocalCandidate:(RTCIceCandidate *)local
    didChangeRemoteCandidate:(RTCIceCandidate *)remote
              lastReceivedMs:(int)lastDataReceivedMs
               didHaveReason:(NSString *)reason {
  RTCLog(@"ICE candidate pair changed because: %@", reason);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didOpenDataChannel:(RTCDataChannel *)dataChannel {
    NSLog(@"onDataChannel `%@`", dataChannel.label);
    dataChannel.delegate = self;
    _recvDataChannel = dataChannel;
}

- (void)dataChannelDidChangeState:(RTCDataChannel *)dataChannel {
}

- (void)dataChannel:(RTCDataChannel *)dataChannel
    didReceiveMessageWithBuffer:(RTCDataBuffer *)buffer {
    if (!buffer.isBinary) {
        NSString* message = [[NSString alloc] initWithData:buffer.data
                                                  encoding:NSUTF8StringEncoding];
        NSLog(@"DataChannel receive `%@`", message);
    }
}

- (void)startSendDcMsg {
    __weak ARDAppClient* weakSelf = self;
    _sendDcMsg = ^{
        ARDAppClient* strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf->_testCount++;
        NSString* message = [NSString stringWithFormat:@"iOS dc msg %d", strongSelf->_testCount];
        RTCDataBuffer* buffer = [[RTCDataBuffer alloc]
            initWithData:[message dataUsingEncoding:NSUTF8StringEncoding]
                isBinary:NO];
        [strongSelf->_sendDataChannel sendData:buffer];
        NSLog(@"DataChannel send `%@`", message);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), strongSelf->_sendDcMsg);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), _sendDcMsg);
}

#pragma mark - CFVideoProcessorDelegate

- (void)setVideoProcessorDelegate:(nullable id<CFVideoProcessorDelegate>)delegate {
  _videoProcessorDelegate = delegate;
}

- (void)onVideoFrame:(RTCVideoFrame *)frame {
  id<CFVideoProcessorDelegate> strongDelegate = _videoProcessorDelegate;
  if (strongDelegate) {
    [strongDelegate onProcessedVideoFrame:frame];
  }
}

#pragma mark - RTCSessionDescriptionDelegate
// Callbacks for this delegate occur on non-main thread and need to be
// dispatched back to main queue as needed.

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didCreateSessionDescription:(RTCSessionDescription *)sdp
                          error:(NSError *)error {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (error) {
      RTCLogError(@"Failed to create session description. Error: %@", error);
      [self disconnect];
      NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: @"Failed to create session description.",
      };
      NSError *sdpError =
          [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                     code:kARDAppClientErrorCreateSDP
                                 userInfo:userInfo];
      [self.delegate appClient:self didError:sdpError];
      return;
    }

    NSArray<NSString*>* sdpLines = [sdp.sdp componentsSeparatedByString:@"\r\n"];
    NSString* newDesc = @"";
    for (NSString* line in sdpLines) {
        if (![line containsString:@"urn:3gpp:video-orientation"] && ![line isEqualToString:@""]) {
            newDesc = [newDesc stringByAppendingFormat:@"%@\r\n", line];
        }
    }
    RTCSessionDescription* newSdp = [[RTCSessionDescription alloc] initWithType:sdp.type sdp:newDesc];

    __weak ARDAppClient *weakSelf = self;
    [self.peerConnection setLocalDescription:newSdp
                           completionHandler:^(NSError *error) {
                             ARDAppClient *strongSelf = weakSelf;
                             [strongSelf peerConnection:strongSelf.peerConnection
                                 didSetSessionDescriptionWithError:error];
                           }];
    ARDSessionDescriptionMessage *message =
        [[ARDSessionDescriptionMessage alloc] initWithDescription:newSdp];
    [self sendSignalingMessage:message];
    [self setMaxBitrateForPeerConnectionVideoSender];
  });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didSetSessionDescriptionWithError:(NSError *)error {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (error) {
      RTCLogError(@"Failed to set session description. Error: %@", error);
      [self disconnect];
      NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: @"Failed to set session description.",
      };
      NSError *sdpError =
          [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                     code:kARDAppClientErrorSetSDP
                                 userInfo:userInfo];
      [self.delegate appClient:self didError:sdpError];
      return;
    }
    // If we're answering and we've just set the remote offer we need to create
    // an answer and set the local description.
    if (!self.isInitiator && !self.peerConnection.localDescription) {
      RTCMediaConstraints *constraints = [self defaultAnswerConstraints];
      __weak ARDAppClient *weakSelf = self;
      [self.peerConnection answerForConstraints:constraints
                              completionHandler:^(RTCSessionDescription *sdp, NSError *error) {
                                ARDAppClient *strongSelf = weakSelf;
                                [strongSelf peerConnection:strongSelf.peerConnection
                                    didCreateSessionDescription:sdp
                                                          error:error];
                              }];
    }
  });
}

#pragma mark - Private

#if defined(WEBRTC_IOS)

- (NSString *)documentsFilePathForFileName:(NSString *)fileName {
  NSParameterAssert(fileName.length);
  NSArray *paths = NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES);
  NSString *documentsDirPath = paths.firstObject;
  NSString *filePath =
      [documentsDirPath stringByAppendingPathComponent:fileName];
  return filePath;
}

#endif

- (BOOL)hasJoinedRoomServerRoom {
  return _clientId.length;
}

// Begins the peer connection connection process if we have both joined a room
// on the room server and tried to obtain a TURN server. Otherwise does nothing.
// A peer connection object will be created with a stream that contains local
// audio and video capture. If this client is the caller, an offer is created as
// well, otherwise the client will wait for an offer to arrive.
- (void)startSignalingIfReady {
  if (!_isTurnComplete || !self.hasJoinedRoomServerRoom) {
    return;
  }
  self.state = kARDAppClientStateConnected;

  // Create peer connection.
  RTCMediaConstraints *constraints = [self defaultPeerConnectionConstraints];
  RTCConfiguration *config = [[RTCConfiguration alloc] init];
  RTCCertificate *pcert = [RTCCertificate generateCertificateWithParams:@{
    @"expires" : @100000,
    @"name" : @"RSASSA-PKCS1-v1_5"
  }];
  config.iceServers = _iceServers;
  config.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
  config.certificate = pcert;

  _peerConnection = [_factory peerConnectionWithConfiguration:config
                                                  constraints:constraints
                                                     delegate:self];
  // Create AV senders.
  [self createMediaSenders];

  RTCDataChannelConfiguration* dcConfig = [[RTCDataChannelConfiguration alloc] init];
  dcConfig.isOrdered = YES;
  //dcConfig.isNegotiated = YES;
  //dcConfig.channelId = 100;
  dcConfig.maxRetransmits = -1;
  dcConfig.maxPacketLifeTime = -1;
  //dcConfig.protocol = @"iOS DC";
  _sendDataChannel = [_peerConnection dataChannelForLabel:@"iOS ApprtcDemo data"
                                        configuration:dcConfig];
  //_sendDataChannel.delegate = self;
  [self startSendDcMsg];

  if (_isInitiator) {
    // Send offer.
    __weak ARDAppClient *weakSelf = self;
    [_peerConnection offerForConstraints:[self defaultOfferConstraints]
                       completionHandler:^(RTCSessionDescription *sdp,
                                           NSError *error) {
      ARDAppClient *strongSelf = weakSelf;
      [strongSelf peerConnection:strongSelf.peerConnection
          didCreateSessionDescription:sdp
                                error:error];
    }];
  } else {
    // Check if we've received an offer.
    [self drainMessageQueueIfReady];
  }
#if defined(WEBRTC_IOS)
  // Start event log.
  if (kARDAppClientEnableRtcEventLog) {
    NSString *filePath = [self documentsFilePathForFileName:@"webrtc-rtceventlog"];
    if (![_peerConnection startRtcEventLogWithFilePath:filePath
                                 maxSizeInBytes:kARDAppClientRtcEventLogMaxSizeInBytes]) {
      RTCLogError(@"Failed to start event logging.");
    }
  }

  // Start aecdump diagnostic recording.
  if ([_settings currentCreateAecDumpSettingFromStore]) {
    NSString *filePath = [self documentsFilePathForFileName:@"webrtc-audio.aecdump"];
    if (![_factory startAecDumpWithFilePath:filePath
                             maxSizeInBytes:kARDAppClientAecDumpMaxSizeInBytes]) {
      RTCLogError(@"Failed to start aec dump.");
    }
  }
#endif
}

// Processes the messages that we've received from the room server and the
// signaling channel. The offer or answer message must be processed before other
// signaling messages, however they can arrive out of order. Hence, this method
// only processes pending messages if there is a peer connection object and
// if we have received either an offer or answer.
- (void)drainMessageQueueIfReady {
  if (!_peerConnection || !_hasReceivedSdp) {
    return;
  }
  for (ARDSignalingMessage *message in _messageQueue) {
    [self processSignalingMessage:message];
  }
  [_messageQueue removeAllObjects];
}

// Processes the given signaling message based on its type.
- (void)processSignalingMessage:(ARDSignalingMessage *)message {
  NSParameterAssert(_peerConnection ||
      message.type == kARDSignalingMessageTypeBye);
  switch (message.type) {
    case kARDSignalingMessageTypeOffer:
    case kARDSignalingMessageTypeAnswer: {
      ARDSessionDescriptionMessage *sdpMessage =
          (ARDSessionDescriptionMessage *)message;
      RTCSessionDescription *description = sdpMessage.sessionDescription;
      __weak ARDAppClient *weakSelf = self;
      [_peerConnection setRemoteDescription:description
                          completionHandler:^(NSError *error) {
                            ARDAppClient *strongSelf = weakSelf;
                            [strongSelf peerConnection:strongSelf.peerConnection
                                didSetSessionDescriptionWithError:error];
                          }];
      break;
    }
    case kARDSignalingMessageTypeCandidate: {
      ARDICECandidateMessage *candidateMessage =
          (ARDICECandidateMessage *)message;
      [_peerConnection addIceCandidate:candidateMessage.candidate];
      break;
    }
    case kARDSignalingMessageTypeCandidateRemoval: {
      ARDICECandidateRemovalMessage *candidateMessage =
          (ARDICECandidateRemovalMessage *)message;
      [_peerConnection removeIceCandidates:candidateMessage.candidates];
      break;
    }
    case kARDSignalingMessageTypeBye:
      // Other client disconnected.
      // TODO(tkchin): support waiting in room for next client. For now just
      // disconnect.
      [self disconnect];
      break;
  }
}

// Sends a signaling message to the other client. The caller will send messages
// through the room server, whereas the callee will send messages over the
// signaling channel.
- (void)sendSignalingMessage:(ARDSignalingMessage *)message {
  if (_isInitiator) {
    __weak ARDAppClient *weakSelf = self;
    [_roomServerClient sendMessage:message
                         forRoomId:_roomId
                          clientId:_clientId
                 completionHandler:^(ARDMessageResponse *response,
                                     NSError *error) {
      ARDAppClient *strongSelf = weakSelf;
      if (error) {
        [strongSelf.delegate appClient:strongSelf didError:error];
        return;
      }
      NSError *messageError =
          [[strongSelf class] errorForMessageResultType:response.result];
      if (messageError) {
        [strongSelf.delegate appClient:strongSelf didError:messageError];
        return;
      }
    }];
  } else {
    [_channel sendMessage:message];
  }
}

- (void)setMaxBitrateForPeerConnectionVideoSender {
  for (RTCRtpSender *sender in _peerConnection.senders) {
    if (sender.track != nil) {
      if ([sender.track.kind isEqualToString:kARDVideoTrackKind]) {
        [self setMaxBitrate:[_settings currentMaxBitrateSettingFromStore] forVideoSender:sender];
      }
    }
  }
}

- (void)setMaxBitrate:(NSNumber *)maxBitrate forVideoSender:(RTCRtpSender *)sender {
  if (maxBitrate.intValue <= 0) {
    return;
  }

  RTCRtpParameters *parametersToModify = sender.parameters;
  for (RTCRtpEncodingParameters *encoding in parametersToModify.encodings) {
    encoding.maxBitrateBps = @(maxBitrate.intValue * kKbpsMultiplier);
  }
  [sender setParameters:parametersToModify];
}

- (RTCRtpTransceiver *)videoTransceiver {
  for (RTCRtpTransceiver *transceiver in _peerConnection.transceivers) {
    if (transceiver.mediaType == RTCRtpMediaTypeVideo) {
      return transceiver;
    }
  }
  return nil;
}

- (void)createMediaSenders {
  RTCMediaConstraints *constraints = [self defaultMediaAudioConstraints];
  RTCAudioSource *source = [_factory audioSourceWithConstraints:constraints];
  RTCAudioTrack *track = [_factory audioTrackWithSource:source
                                                trackId:kARDAudioTrackId];
  [_peerConnection addTrack:track streamIds:@[ kARDMediaStreamId ]];
  _localVideoTrack = [self createLocalVideoTrack];
  if (_localVideoTrack) {
    [_peerConnection addTrack:_localVideoTrack streamIds:@[ kARDMediaStreamId ]];
    [_delegate appClient:self didReceiveLocalVideoTrack:_localVideoTrack];
    // We can set up rendering for the remote track right away since the transceiver already has an
    // RTCRtpReceiver with a track. The track will automatically get unmuted and produce frames
    // once RTP is received.
    RTCVideoTrack *track = (RTCVideoTrack *)([self videoTransceiver].receiver.track);
    [_delegate appClient:self didReceiveRemoteVideoTrack:track];
  }
}

- (RTCVideoTrack *)createLocalVideoTrack {
  if ([_settings currentAudioOnlySettingFromStore]) {
    return nil;
  }

  RTCVideoSource *source = [_factory videoSource];
  [source setVideoProcessor:self];

#if !TARGET_IPHONE_SIMULATOR
  if (self.isBroadcast) {
    ARDExternalSampleCapturer *capturer =
        [[ARDExternalSampleCapturer alloc] initWithDelegate:source];
    [_delegate appClient:self didCreateLocalExternalSampleCapturer:capturer];
  } else {
    _hijackDelegate = [[CFHijackCapturerDelegate alloc] initWithRealDelegate:source];
    RTCCameraVideoCapturer *capturer = [[RTCCameraVideoCapturer alloc] initWithDelegate:_hijackDelegate];
    [_delegate appClient:self didCreateLocalCapturer:capturer];
  }
#else
#if defined(__IPHONE_11_0) && (__IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_11_0)
  if (@available(iOS 10, *)) {
    RTCFileVideoCapturer *fileCapturer = [[RTCFileVideoCapturer alloc] initWithDelegate:source];
    [_delegate appClient:self didCreateLocalFileCapturer:fileCapturer];
  }
#endif
#endif

  return [_factory videoTrackWithSource:source trackId:kARDVideoTrackId];
}

#pragma mark - Collider methods

- (void)registerWithColliderIfReady {
  if (!self.hasJoinedRoomServerRoom) {
    return;
  }
  // Open WebSocket connection.
  if (!_channel) {
    _channel =
        [[ARDWebSocketChannel alloc] initWithURL:_websocketURL
                                         restURL:_websocketRestURL
                                        delegate:self];
    if (_isLoopback) {
      _loopbackChannel =
          [[ARDLoopbackWebSocketChannel alloc] initWithURL:_websocketURL
                                                   restURL:_websocketRestURL];
    }
  }
  [_channel registerForRoomId:_roomId clientId:_clientId];
  if (_isLoopback) {
    [_loopbackChannel registerForRoomId:_roomId clientId:@"LOOPBACK_CLIENT_ID"];
  }
}

#pragma mark - Defaults

 - (RTCMediaConstraints *)defaultMediaAudioConstraints {
   NSDictionary *mandatoryConstraints = @{};
   RTCMediaConstraints *constraints =
       [[RTCMediaConstraints alloc] initWithMandatoryConstraints:mandatoryConstraints
                                             optionalConstraints:nil];
   return constraints;
}

- (RTCMediaConstraints *)defaultAnswerConstraints {
  return [self defaultOfferConstraints];
}

- (RTCMediaConstraints *)defaultOfferConstraints {
  NSDictionary *mandatoryConstraints = @{
    @"OfferToReceiveAudio" : @"true",
    @"OfferToReceiveVideo" : @"true"
  };
  RTCMediaConstraints* constraints =
      [[RTCMediaConstraints alloc]
          initWithMandatoryConstraints:mandatoryConstraints
                   optionalConstraints:nil];
  return constraints;
}

- (RTCMediaConstraints *)defaultPeerConnectionConstraints {
  if (_defaultPeerConnectionConstraints) {
    return _defaultPeerConnectionConstraints;
  }
  NSString *value = _isLoopback ? @"false" : @"true";
  NSDictionary *optionalConstraints = @{ @"DtlsSrtpKeyAgreement" : value };
  RTCMediaConstraints* constraints =
      [[RTCMediaConstraints alloc]
          initWithMandatoryConstraints:nil
                   optionalConstraints:optionalConstraints];
  return constraints;
}

#pragma mark - Errors

+ (NSError *)errorForJoinResultType:(ARDJoinResultType)resultType {
  NSError *error = nil;
  switch (resultType) {
    case kARDJoinResultTypeSuccess:
      break;
    case kARDJoinResultTypeUnknown: {
      error = [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                         code:kARDAppClientErrorUnknown
                                     userInfo:@{
        NSLocalizedDescriptionKey: @"Unknown error.",
      }];
      break;
    }
    case kARDJoinResultTypeFull: {
      error = [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                         code:kARDAppClientErrorRoomFull
                                     userInfo:@{
        NSLocalizedDescriptionKey: @"Room is full.",
      }];
      break;
    }
  }
  return error;
}

+ (NSError *)errorForMessageResultType:(ARDMessageResultType)resultType {
  NSError *error = nil;
  switch (resultType) {
    case kARDMessageResultTypeSuccess:
      break;
    case kARDMessageResultTypeUnknown:
      error = [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                         code:kARDAppClientErrorUnknown
                                     userInfo:@{
        NSLocalizedDescriptionKey: @"Unknown error.",
      }];
      break;
    case kARDMessageResultTypeInvalidClient:
      error = [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                         code:kARDAppClientErrorInvalidClient
                                     userInfo:@{
        NSLocalizedDescriptionKey: @"Invalid client.",
      }];
      break;
    case kARDMessageResultTypeInvalidRoom:
      error = [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                         code:kARDAppClientErrorInvalidRoom
                                     userInfo:@{
        NSLocalizedDescriptionKey: @"Invalid room.",
      }];
      break;
  }
  return error;
}

@end
