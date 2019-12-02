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

#import "WebRTC/RTCAVFoundationVideoSource.h"
#import "WebRTC/RTCAudioTrack.h"
#import "WebRTC/RTCCameraVideoCapturer.h"
#import "WebRTC/RTCConfiguration.h"
#import "WebRTC/RTCFileLogger.h"
#import "WebRTC/RTCFileVideoCapturer.h"
#import "WebRTC/RTCIceServer.h"
#import "WebRTC/RTCLogging.h"
#import "WebRTC/RTCMediaConstraints.h"
#import "WebRTC/RTCMediaStream.h"
#import "WebRTC/RTCPeerConnectionFactory.h"
#import "WebRTC/RTCRtpSender.h"
#import "WebRTC/RTCTracing.h"
#import "WebRTC/RTCVideoCodecFactory.h"
#import "WebRTC/RTCVideoTrack.h"

#import "ARDAppEngineClient.h"
#import "ARDJoinResponse.h"
#import "ARDMessageResponse.h"
#import "ARDSettingsModel.h"
#import "ARDSignalingMessage.h"
#import "ARDTURNClient+Internal.h"
#import "ARDUtilities.h"
#import "ARDWebSocketChannel.h"
#import "RTCIceCandidate+JSON.h"
#import "RTCSessionDescription+JSON.h"
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>
#import <MQTTClient/MQTTClient.h>
#import <MQTTClient/MQTTSessionManager.h>


static NSString * const kARDIceServerRequestUrl = @"https://appr.tc/params";

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
static BOOL const kARDAppClientEnableTracing = NO;
static BOOL const kARDAppClientEnableRtcEventLog = YES;
static int64_t const kARDAppClientAecDumpMaxSizeInBytes = 5e6;  // 5 MB.
static int64_t const kARDAppClientRtcEventLogMaxSizeInBytes = 5e6;  // 5 MB.
static int const kKbpsMultiplier = 1000;

// We need a proxy to NSTimer because it causes a strong retain cycle. When
// using the proxy, |invalidate| must be called before it properly deallocs.
@interface ARDTimerProxy : NSObject

- (instancetype)initWithInterval:(NSTimeInterval)interval
                         repeats:(BOOL)repeats
                    timerHandler:(void (^)(void))timerHandler;
- (void)invalidate;

@end

@implementation ARDTimerProxy {
    NSTimer *_timer;
    void (^_timerHandler)(void);
}

- (instancetype)initWithInterval:(NSTimeInterval)interval
                         repeats:(BOOL)repeats
                    timerHandler:(void (^)(void))timerHandler {
    NSParameterAssert(timerHandler);
    if (self = [super init]) {
        _timerHandler = timerHandler;
        _timer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                  target:self
                                                selector:@selector(timerDidFire:)
                                                userInfo:nil
                                                 repeats:repeats];
    }
    return self;
}

- (void)invalidate {
    [_timer invalidate];
}

- (void)timerDidFire:(NSTimer *)timer {
    _timerHandler();
}

@end

@interface ARDAppClient()<MQTTSessionManagerDelegate>

@end


@implementation ARDAppClient {
    RTCFileLogger *_fileLogger;
    ARDTimerProxy *_statsTimer;
    ARDSettingsModel *_settings;
    RTCVideoTrack *_localVideoTrack;
    BOOL _bIPCDebug ;
    NSDictionary *_localTocken ;
    NSDictionary *_rtcConfig ;
    NSDictionary *_mqttConfig ;
    
    NSString *_sessionId ;
    NSString *_moto_topic ;
    
    MQTTSessionManager *_sessionManager ;
    
    NSString *clientId_ ;
    NSString *secret_ ;
    NSString *deviceId_ ;
    NSString *localKey_ ;
    NSString *authCode_ ;
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
@synthesize defaultPeerConnectionConstraints = _defaultPeerConnectionConstraints;
@synthesize isLoopback = _isLoopback;

- (instancetype)init {
    return [self initWithDelegate:nil];
}

- (instancetype)initWithDelegate:(id<ARDAppClientDelegate>)delegate {
    if (self = [super init]) {
        _roomServerClient = [[ARDAppEngineClient alloc] init];
        _delegate = delegate;
        NSURL *turnRequestURL = [NSURL URLWithString:kARDIceServerRequestUrl];
        _turnClient = [[ARDTURNClient alloc] initWithURL:turnRequestURL];
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

//获取当前时间戳
- (NSString *)getCurrentTimeStr{
    NSDate* date = [NSDate dateWithTimeIntervalSinceNow:0];//获取当前时间0秒后的时间
    NSTimeInterval time=[date timeIntervalSince1970]*1000;// *1000 是精确到毫秒，不乘就是精确到秒
    NSString *timeString = [NSString stringWithFormat:@"%.0f", time];
    return timeString;
}

- (int64_t)getCurrentTimeinS{
    NSDate* date = [NSDate dateWithTimeIntervalSinceNow:0];//获取当前时间0秒后的时间
    NSTimeInterval time=[date timeIntervalSince1970];// *1000 是精确到毫秒，不乘就是精确到秒
    return time ;
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
                 isIPCDebug:(BOOL)isIPCDebug {
    _bIPCDebug = isIPCDebug ;
    if (_bIPCDebug) {
        authCode_ = authCode__ ;
        deviceId_ = deviceId__;// 此处填写设备id;
        localKey_ = localKey__;// 此处是设备localkey ;
        clientId_ = clientId__;
        secret_ =  secret__  ;
        [self connectMQTTForWebrtc];
    }else
    {
        NSParameterAssert(roomId.length);
        NSParameterAssert(_state == kARDAppClientStateDisconnected);
        _settings = settings;
        _isLoopback = isIPCDebug;
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
                RTCLogError("Error retrieving TURN servers: %@",
                            error.localizedDescription);
            }
            ARDAppClient *strongSelf = weakSelf;
            [strongSelf.iceServers addObjectsFromArray:turnServers];
            strongSelf.isTurnComplete = YES;
            [strongSelf startSignalingIfReady];
        }];
        
        // Join room on room server.
        [_roomServerClient joinRoomWithRoomId:roomId
                                   isLoopback:_isLoopback
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
}

- (void)disconnect {
    
    if (_bIPCDebug) {
        [_peerConnection close];
        _peerConnection = nil;
        [_sessionManager disconnectWithDisconnectHandler:^(NSError *error) {
            if (error) {
                NSLog(@"Mqtt disconnect failed!!!!");
            }else
            {
                NSLog(@"Mqtt disconnect succeeded!!!!");
            }
        }];
    }else
    {
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
}

#pragma mark - ARDSignalingChannelDelegate

- (void)channel:(id<ARDSignalingChannel>)channel didReceiveMessage:(ARDSignalingMessage *)message {
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

- (void)channel:(id<ARDSignalingChannel>)channel didChangeState:(ARDSignalingChannelState)state {
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

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeSignalingState:(RTCSignalingState)stateChanged {
    RTCLog(@"Signaling state changed: %ld", (long)stateChanged);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream {
    dispatch_async(dispatch_get_main_queue(), ^{
        RTCLog(@"Received %lu video tracks and %lu audio tracks",
               (unsigned long)stream.videoTracks.count,
               (unsigned long)stream.audioTracks.count);
        if (stream.videoTracks.count) {
            RTCVideoTrack *videoTrack = stream.videoTracks[0];
            [_delegate appClient:self didReceiveRemoteVideoTrack:videoTrack];
        }
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveStream:(RTCMediaStream *)stream {
    RTCLog(@"Stream was removed.");
}

- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {
    RTCLog(@"WARNING: Renegotiation needed but unimplemented.");
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {
    RTCLog(@"ICE state changed: %ld", (long)newState);
    dispatch_async(dispatch_get_main_queue(), ^{
        [_delegate appClient:self didChangeConnectionState:newState];
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceGatheringState:(RTCIceGatheringState)newState {
    RTCLog(@"ICE gathering state changed: %ld", (long)newState);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_bIPCDebug) {
            [self sendCandidate:candidate];
        }else{
            ARDICECandidateMessage *message = [[ARDICECandidateMessage alloc] initWithCandidate:candidate];
            [self sendSignalingMessage:message];
        }
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!_bIPCDebug) {
            ARDICECandidateRemovalMessage *message = [[ARDICECandidateRemovalMessage alloc]initWithRemovedCandidates:candidates];
            [self sendSignalingMessage:message];
        }
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didOpenDataChannel:(RTCDataChannel *)dataChannel {
}




#pragma mark - RTCSessionDescriptionDelegate
// Callbacks for this delegate occur on non-main thread and need to be
// dispatched back to main queue as needed.

- (void)peerConnection:(RTCPeerConnection *)peerConnection didCreateSessionDescription:(RTCSessionDescription *)sdp
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
            [_delegate appClient:self didError:sdpError];
            return;
        }
        __weak ARDAppClient *weakSelf = self;
        [_peerConnection setLocalDescription:sdp
                           completionHandler:^(NSError *error) {
                               ARDAppClient *strongSelf = weakSelf;
                               [strongSelf peerConnection:strongSelf.peerConnection
                        didSetSessionDescriptionWithError:error];
                           }];
        ARDSessionDescriptionMessage *message =
        [[ARDSessionDescriptionMessage alloc] initWithDescription:sdp];
        [self sendSignalingMessage:message];
        [self setMaxBitrateForPeerConnectionVideoSender];
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didCreateSessionDescription_:(RTCSessionDescription *)sdp error:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (error) {
            RTCLogError(@"Failed to create session description. Error: %@", error);
            NSDictionary *userInfo = @{
                                       NSLocalizedDescriptionKey: @"Failed to create session description.",
                                       };
            NSError *sdpError = [[NSError alloc] initWithDomain:kARDAppClientErrorDomain code:kARDAppClientErrorCreateSDP userInfo:userInfo];
            //            [_delegate appClient:self didError:sdpError];
            return;
        }
        __weak ARDAppClient *weakSelf = self;
        [_peerConnection setLocalDescription:sdp completionHandler:^(NSError *error)
         {
             if (error == nil) {
//                 _localSdp = sdp ;
                 [weakSelf sendOffer:sdp];
             }
             ARDAppClient *strongSelf = weakSelf;
             [strongSelf peerConnection:strongSelf.peerConnection didSetSessionDescriptionWithError_:error];
         }];
        //        ARDSessionDescriptionMessage *message = [[ARDSessionDescriptionMessage alloc] initWithDescription:sdp];
        
        //        [self sendSignalingMessage:message];
        //        [self setMaxBitrateForPeerConnectionVideoSender];
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didSetSessionDescriptionWithError:(NSError *)error {
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
            [_delegate appClient:self didError:sdpError];
            return;
        }
        // If we're answering and we've just set the remote offer we need to create
        // an answer and set the local description.
        if (!_isInitiator && !_peerConnection.localDescription) {
            RTCMediaConstraints *constraints = [self defaultAnswerConstraints];
            __weak ARDAppClient *weakSelf = self;
            [_peerConnection answerForConstraints:constraints
                                completionHandler:^(RTCSessionDescription *sdp,
                                                    NSError *error) {
                                    ARDAppClient *strongSelf = weakSelf;
                                    [strongSelf peerConnection:strongSelf.peerConnection
                                   didCreateSessionDescription:sdp
                                                         error:error];
                                }];
        }
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didSetSessionDescriptionWithError_:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (error) {
            RTCLogError(@"Failed to set session description. Error: %@", error);
            [self disconnect];
            NSDictionary *userInfo = @{
                                       NSLocalizedDescriptionKey: @"Failed to set session description.",
                                       };
            NSError *sdpError = [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                                           code:kARDAppClientErrorSetSDP
                                                       userInfo:userInfo];
            [_delegate appClient:self didError:sdpError];
            return;
        }
        // If we're answering and we've just set the remote offer we need to create
        // an answer and set the local description.
        //        if (!_peerConnection.localDescription) {
        //            RTCMediaConstraints *constraints = [self defaultAnswerConstraints];
        //            __weak ARDAppClient *weakSelf = self;
        //            [_peerConnection answerForConstraints:constraints
        //                                completionHandler:^(RTCSessionDescription *sdp,NSError *error) {
        //                                    ARDAppClient *strongSelf = weakSelf;
        //                                    [strongSelf peerConnection:strongSelf.peerConnection didCreateSessionDescription_:sdp error:error];
        //                                }];
        //        }
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
    config.iceServers = _iceServers;
    _peerConnection = [_factory peerConnectionWithConfiguration:config
                                                    constraints:constraints
                                                       delegate:self];
    // Create AV senders.
    [self createMediaSenders];
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

- (void)createMediaSenders {
    RTCMediaConstraints *constraints = [self defaultMediaAudioConstraints];
    RTCAudioSource *source = [_factory audioSourceWithConstraints:constraints];
    RTCAudioTrack *track = [_factory audioTrackWithSource:source
                                                  trackId:kARDAudioTrackId];
    RTCMediaStream *stream = [_factory mediaStreamWithStreamId:kARDMediaStreamId];
    [stream addAudioTrack:track];
    if(!_bIPCDebug)
    {
        _localVideoTrack = [self createLocalVideoTrack];
        if (_localVideoTrack) {
            [stream addVideoTrack:_localVideoTrack];
        }
    }
    [_peerConnection addStream:stream];
}

- (RTCVideoTrack *)createLocalVideoTrack {
    if ([_settings currentAudioOnlySettingFromStore]) {
        return nil;
    }
    
    RTCVideoSource *source = [_factory videoSource];
    
#if !TARGET_IPHONE_SIMULATOR
    RTCCameraVideoCapturer *capturer = [[RTCCameraVideoCapturer alloc] initWithDelegate:source];
    [_delegate appClient:self didCreateLocalCapturer:capturer];
    
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
    NSString *valueLevelControl = [_settings currentUseLevelControllerSettingFromStore] ?
    kRTCMediaConstraintsValueTrue :
    kRTCMediaConstraintsValueFalse;
    NSDictionary *mandatoryConstraints = @{ kRTCMediaConstraintsLevelControl : valueLevelControl };
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

//异步请求
- (void)sendAsyncWithRequest:(NSURLRequest *)request
{
    NSOperationQueue *queue = [NSOperationQueue mainQueue];
    
    [NSURLConnection sendAsynchronousRequest:request queue:queue completionHandler:^(NSURLResponse * _Nullable response, NSData * _Nullable data, NSError * _Nullable connectionError) {
        //这个block会在请求完毕的时候自动调用
        if (connectionError || data == nil) {
            //            [MBProgressHUD showError:@"请求失败"];
            return;
        }
        //解析服务器返回的JSON数据
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableLeaves error:nil];
        NSString *error = dict[@"error"];
        if (error) {
            //            [MBProgressHUD showError:error];
        }
        else{
            NSString *success = dict[@"success"];
            //            [MBProgressHUD showSuccess:success];
        }
    }];
}

//同步请求
- (NSDictionary *)sendSyncWithRequest:(NSURLRequest *)request
{
    //发送用户名和密码给服务器（HTTP协议）
    NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:nil error:nil];
    
    //解析服务器返回的JSON数据
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableLeaves error:nil];
    return dict ;
}

#define CC_MD5_DIGEST_LENGTH 16

- (NSString*)getmd5WithString:(NSString *)string
{
    const char* original_str=[string UTF8String];
    unsigned char digist[CC_MD5_DIGEST_LENGTH]; //CC_MD5_DIGEST_LENGTH = 16
    CC_MD5(original_str, (uint)strlen(original_str), digist);
    NSMutableString* outPutStr = [NSMutableString stringWithCapacity:10];
    for(int  i =0; i<CC_MD5_DIGEST_LENGTH;i++){
        [outPutStr appendFormat:@"%02x", digist[i]];//小写x表示输出的是小写MD5，大写X表示输出的是大写MD5
    }
    return [outPutStr lowercaseString];
}
- (NSString*)calcSignForTokenWithClientId:(NSString*)clientId secret:(NSString*)secret timeStamp:(NSString*)timeStamp
{
    NSString *astring = [[NSString alloc] initWithString:[NSString stringWithFormat:@"%@%@%@",clientId,secret,timeStamp]];
    NSString *md5String = [self getmd5WithString:astring];
    return [md5String uppercaseString];
}

- (NSString*)calcSignForOthersWithClientId:(NSString*)clientId access_token:(NSString*)access_token secret:(NSString*)secret timeStamp:(NSString*)timeStamp
{
    NSString *astring = [[NSString alloc] initWithString:[NSString stringWithFormat:@"%@%@%@%@",clientId,access_token,secret,timeStamp]];
    NSString *md5String = [self getmd5WithString:astring];
    return [md5String uppercaseString];
}


-(BOOL)getMQTTConfig:(NSString*)clientId secret:(NSString*)secret access_token:(NSString*)access_token {
    /*
     curl --location --request GET "{{url}}/v1.0/access/11/config?type=websocket" \
     --header "client_id: {{clientId}}" \
     --header "access_token: {{easy_access_token}}" \
     --header "sign: {{easy_sign}}" \
     --header "t: {{timestamp}}"
     */
    //    NSString *strURL = [NSString stringWithFormat:@"https://openapi-cn.wgine.com/v1.0/access/11/config?type=websocket"];
    NSString *strURL = [NSString stringWithFormat:@"https://openapi-cn.wgine.com/v1.0/access/11/config"];
    NSURL *url = [NSURL URLWithString:strURL];
    
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    //添加header
    NSMutableURLRequest *mutableRequest = [request mutableCopy];    //拷贝request
    NSString *ts = [self getCurrentTimeStr] ;
    
    //    NSString *sign = [self calcSign:clientId secret:secret timeStamp:ts];
    NSString *sign = [self calcSignForOthersWithClientId:clientId access_token:access_token secret:secret timeStamp:ts];
    
    // sign
    NSString *signString = [[NSString alloc] initWithString:[NSString stringWithFormat:@"%@",sign]];
    [mutableRequest addValue:signString forHTTPHeaderField:@"sign"];
    
    // client id
    NSString *clientString = [[NSString alloc] initWithString:[NSString stringWithFormat:@"%@",clientId]];
    [mutableRequest addValue:clientString forHTTPHeaderField:@"client_id"];
    
    // ts
    NSString *astring = [[NSString alloc] initWithString:[NSString stringWithFormat:@"%@",ts]];
    [mutableRequest addValue:astring forHTTPHeaderField:@"t"];
    
    
    //access_token
    NSString *accessString = [[NSString alloc] initWithString:[NSString stringWithFormat:@"%@",access_token]];
    [mutableRequest addValue:accessString forHTTPHeaderField:@"access_token"];
    
    request = [mutableRequest copy];        //拷贝回去
    NSLog(@"========%@", request.allHTTPHeaderFields);
    
    NSDictionary *dict = [self sendSyncWithRequest:request];
    //    NSString *success = dict[@"success"];
    BOOL success = [dict[@"success"] boolValue];
    if (success) {
        _mqttConfig = dict[@"result"];
        return YES ;
    }
    return NO ;
}

-(BOOL)getRtcConfig:(NSString*)clientId secret:(NSString*)secret access_token:(NSString*)access_token deviceid:(NSString*)did{
    /*
     curl --location --request GET "{{url}}/v1.0/devices/vdevo157163890481773/camera-config?type=rtc" \
     --header "client_id: {{clientId}}" \
     --header "access_token: {{easy_access_token}}" \
     --header "sign: {{easy_sign}}" \
     --header "t: {{timestamp}}"
     */
    NSString *strURL = [NSString stringWithFormat:@"https://openapi-cn.wgine.com/v1.0/devices/%@/camera-config?type=rtc",did];
    NSURL *url = [NSURL URLWithString:strURL];
    
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    //添加header
    
    NSMutableURLRequest *mutableRequest = [request mutableCopy];    //拷贝request
    NSString *ts = [self getCurrentTimeStr] ;
    NSString *sign = [self calcSignForOthersWithClientId:clientId access_token:access_token secret:secret timeStamp:ts];
    
    // sign
    NSString *signString = [[NSString alloc] initWithString:[NSString stringWithFormat:@"%@",sign]];
    [mutableRequest addValue:signString forHTTPHeaderField:@"sign"];
    
    // client id
    NSString *clientString = [[NSString alloc] initWithString:[NSString stringWithFormat:@"%@",clientId]];
    [mutableRequest addValue:clientString forHTTPHeaderField:@"client_id"];
    
    // ts
    NSString *astring = [[NSString alloc] initWithString:[NSString stringWithFormat:@"%@",ts]];
    [mutableRequest addValue:astring forHTTPHeaderField:@"t"];
    
    //access_token
    NSString *accessString = [[NSString alloc] initWithString:[NSString stringWithFormat:@"%@",access_token]];
    [mutableRequest addValue:accessString forHTTPHeaderField:@"access_token"];
    
    request = [mutableRequest copy];        //拷贝回去
    NSLog(@"========%@", request.allHTTPHeaderFields);
    
    NSDictionary *dict = [self sendSyncWithRequest:request];
    BOOL success = [dict[@"success"] boolValue];
    if (success) {
        _rtcConfig = dict[@"result"];
        return YES ;
    }
    return NO ;
}

- (BOOL)getTokenWithClientId:(NSString*)clientId secret:(NSString*)secret  code:(NSString*)code{
    /*
     curl --location --request GET "{{url}}/v1.0/token?code=669c3e1f3a4e38103bf6e9544ea0d311&grant_type=2" \
     --header "client_id: {{clientId}}" \
     --header "sign: {{easy_sign}}" \
     --header "t: {{timestamp}}"
     */
    //    NSString *code = @"a2bc554fe8a5ec6cd31654729c1f5c67" ;
    NSString *strURL = [NSString stringWithFormat:@"https://openapi-cn.wgine.com/v1.0/token?code=%@&grant_type=2",code];
    NSURL *url = [NSURL URLWithString:strURL];
    //创建一个请求
    NSLog(@"url====%@",strURL);
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    //添加header
    
    NSMutableURLRequest *mutableRequest = [request mutableCopy];    //拷贝request
    NSString *ts = [self getCurrentTimeStr] ;
    NSString *sign = [self calcSignForTokenWithClientId:clientId secret:secret timeStamp:ts];
    
    // sign
    NSString *signString = [[NSString alloc] initWithString:[NSString stringWithFormat:@"%@",sign]];
    [mutableRequest addValue:signString forHTTPHeaderField:@"sign"];
    
    // client id
    NSString *clientString = [[NSString alloc] initWithString:[NSString stringWithFormat:@"%@",clientId]];
    [mutableRequest addValue:clientString forHTTPHeaderField:@"client_id"];
    
    // ts
    NSString *astring = [[NSString alloc] initWithString:[NSString stringWithFormat:@"%@",ts]];
    [mutableRequest addValue:astring forHTTPHeaderField:@"t"];
    
    
    
    
    request = [mutableRequest copy];        //拷贝回去
    NSLog(@"========%@", request.allHTTPHeaderFields);
    
    NSDictionary *dict = [self sendSyncWithRequest:request];
    //    NSString *success = dict[@"success"];
    BOOL success = [dict[@"success"] boolValue];
    if (success) {
        _localTocken = dict[@"result"];
        return YES ;
    }
    return NO ;
}

-(NSString *)randomStringWithLength:(NSInteger)len {
    NSString *letters = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    NSMutableString *randomString = [NSMutableString stringWithCapacity: len];
    
    for (NSInteger i = 0; i < len; i++) {
        [randomString appendFormat: @"%C", [letters characterAtIndex: arc4random_uniform([letters length])]];
    }
    return randomString;
}


-(void)connectMQTTForWebrtc{
    _rtcConfig = nil ;
    _mqttConfig = nil ;
    _sessionId = [self randomStringWithLength:32];
    BOOL result = [self getTokenWithClientId:clientId_ secret:secret_ code:authCode_];
    if (result) {
//    if(YES){
//        NSString *accessToken = @"701ff5474064d9ddc08ac990a760c1d5";// getTokenWithClientId 函数获取 ;           // from _localToken
        NSString *accessToken = _localTocken[@"access_token"];
        [self getRtcConfig:clientId_ secret:secret_ access_token:accessToken deviceid:deviceId_];
        [self getMQTTConfig:clientId_ secret:secret_ access_token:accessToken];
    }
    if (_mqttConfig && _rtcConfig) {
        NSString *clientId = _mqttConfig[@"client_id"];
        _sessionManager = [[MQTTSessionManager alloc]init];
        _sessionManager.delegate =self;
        NSString *uid = [_mqttConfig[@"username"] substringFromIndex : 6];
        NSString *topic = [NSString stringWithFormat:@"/av/u/%@",uid];
        
        BOOL bTLS = YES ;
        NSString *host = @"" ;
        int port = 8883 ;
        NSString *url = _mqttConfig[@"url"] ;
        NSRange range = [url rangeOfString:@"ssl://"];
        if (range.location == NSNotFound) {
            bTLS = NO ;
            
        }else
        {
            bTLS = YES ;
            url = [url substringFromIndex:6];
            range = [url rangeOfString:@":"];
            host = [url substringToIndex:range.location];
            port = [[url substringFromIndex:range.location + range.length] intValue];
        }
        NSInteger keeplive = [_mqttConfig[@"expire_time"] integerValue] ;
        NSLog(@"==== uid=%@ ",uid);
        NSLog(@"==== topic=%@ ",topic);
        NSLog(@"==== host=%@ ",host);
        NSLog(@"==== keeplive=%d ", (int)keeplive);
        NSLog(@"==== userName=%@ ", _mqttConfig[@"username"] );
        NSLog(@"==== password=%@ ", _mqttConfig[@"password"] );
        MQTTSSLSecurityPolicy *securitPolicy = [MQTTSSLSecurityPolicy defaultPolicy] ;
        [_sessionManager connectTo:host
                             port:port
                              tls:bTLS
                        keepalive:keeplive
                            clean:NO
                             auth:YES
                             user:_mqttConfig[@"username"]
                             pass:_mqttConfig[@"password"]
                             will:NO
                        willTopic:nil
                          willMsg:nil
                          willQos:MQTTQosLevelExactlyOnce
                   willRetainFlag:NO
                     withClientId:clientId
                   securityPolicy:securitPolicy
                     certificates:nil
                    protocolLevel:MQTTProtocolVersion311
                   connectHandler:^(NSError *error) {
                        if (error) {
                            NSLog(@"Error happend while connecting to mqtt!!!");
                        }
                   }];
    }
}

- (NSString *)convertToJsonData:(NSDictionary *)dict
{
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:&error];
    NSString *jsonString;
    
    if (!jsonData) {
        NSLog(@"%@",error);
    } else {
        jsonString = [[NSString alloc]initWithData:jsonData encoding:NSUTF8StringEncoding];
    }
    
    NSMutableString *mutStr = [NSMutableString stringWithString:jsonString];
    
    //    NSRange range = {0,jsonString.length};
    
    //去掉字符串中的空格
    //    [mutStr replaceOccurrencesOfString:@" " withString:@"" options:NSLiteralSearch range:range];
    
    NSRange range2 = {0,mutStr.length};
    
    //去掉字符串中的换行符
    [mutStr replaceOccurrencesOfString:@"\n" withString:@"" options:NSLiteralSearch range:range2];
    
    return mutStr;
}

//SHA256加密
- (NSString*)sha256HashFor:(NSString*)input{
    const char* str = [input UTF8String];
    unsigned char result[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(str, (CC_LONG)strlen(str), result);
    
    NSMutableString *ret = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH*2];
    for(int i = 0; i<CC_SHA256_DIGEST_LENGTH; i++){
        [ret appendFormat:@"%02x",result[i]];
    }
    ret = (NSMutableString *)[ret uppercaseString];
    NSData *data = [ret dataUsingEncoding:NSUTF8StringEncoding];
    //NSString *stringBase64 = [data base64Encoding]; // base64格式的字符串(不建议使用,用下面方法替代)
    NSString *stringBase64 = [data base64EncodedStringWithOptions:NSDataBase64EncodingEndLineWithLineFeed]; // base
    return stringBase64;
}

- (NSString *)hmacSHA256WithSecret:(NSString *)secret content:(NSString *)content
{
    const char *cKey  = [secret cStringUsingEncoding:NSASCIIStringEncoding];
    const char *cData = [content cStringUsingEncoding:NSUTF8StringEncoding];// 有可能有中文 所以用NSUTF8StringEncoding -> NSASCIIStringEncoding
    unsigned char cHMAC[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, cKey, strlen(cKey), cData, strlen(cData), cHMAC);
    NSData *HMACData = [NSData dataWithBytes:cHMAC length:sizeof(cHMAC)];
    const unsigned char *buffer = (const unsigned char *)[HMACData bytes];
    NSMutableString *HMAC = [NSMutableString stringWithCapacity:HMACData.length * 2];
    for (int i = 0; i < HMACData.length; ++i){
        [HMAC appendFormat:@"%02x", buffer[i]];
    }
    
    return HMAC;
}

- (NSString*)getAuth{
    NSString *p2p_password = _rtcConfig[@"configs"][@"password"];
    NSString *haskey = [NSString stringWithFormat:@"%@:%@",p2p_password,localKey_];
    NSLog(@"====hashkey %@",haskey);
    
    const char *cKey  = [haskey cStringUsingEncoding:NSASCIIStringEncoding];
    const char *cData = [deviceId_ cStringUsingEncoding:NSUTF8StringEncoding];// 有可能有中文 所以用NSUTF8StringEncoding -> NSASCIIStringEncoding
    unsigned char cHMAC[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, cKey, strlen(cKey), cData, strlen(cData), cHMAC);
    NSData *HMACData = [NSData dataWithBytes:cHMAC length:sizeof(cHMAC)];
    NSString *stringBase64 = [HMACData base64Encoding];
    
    return stringBase64 ;
}

- (void)sendOffer:(RTCSessionDescription *)sdp
{
    NSMutableDictionary *message = [NSMutableDictionary dictionaryWithCapacity:0];//创建一个空字典
    
    [message setObject:@302 forKey:@"protocol"];
    int64_t t = [self getCurrentTimeinS];
    [message setObject:[NSNumber numberWithLongLong:t] forKey:@"t"];
    
    NSMutableDictionary *configuration = [NSMutableDictionary dictionaryWithCapacity:0];//创建一个空字典
    NSMutableDictionary *header = [NSMutableDictionary dictionaryWithCapacity:0];//创建一个空字典
    NSString *uid = [_mqttConfig[@"username"] substringFromIndex : 6];         // uid
    
    // header
    [header setObject:uid forKey:@"from"];
    [header setObject:deviceId_ forKey:@"to"];
    [header setObject:@"offer" forKey:@"type"];
    [header setObject:@"moto_pre_cn002" forKey:@"moto_id"];
    
    [header setObject:_sessionId forKey:@"sessionid"];
    
    [configuration setObject:header forKey:@"header"];
    
    NSMutableDictionary *msg = [NSMutableDictionary dictionaryWithCapacity:0];//创建一个空字典
    
    [msg setObject:@"webrtc" forKey:@"mode"];
    NSMutableArray *ices = _rtcConfig[@"configs"][@"p2p_config"][@"ices"];
    [msg setObject:ices forKey:@"token"];
    [msg setObject:sdp.sdp forKey:@"sdp"];
    
    NSString *auth = [self getAuth];
    //    NSString *auth = _rtcConfig[@"configs"][@"auth"];
    [msg setObject:auth forKey:@"auth"];
    [configuration setObject:msg forKey:@"msg"];
    
    _moto_topic= [NSString stringWithFormat:@"/av/moto/moto_pre_cn002/u/%@",deviceId_];
    
    [message setObject:configuration forKey:@"data"];
    
    NSString *json = [self convertToJsonData:message];
    NSData *jsonData = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSLog(@"=======sendoffer :%@ ",json);
    [_sessionManager.session publishData:jsonData onTopic:_moto_topic retain:NO qos:MQTTQosLevelAtLeastOnce publishHandler:^(NSError *error) {
        if (error) {
            NSLog(@"=======sendoffer failed.....");
        }
    }];
}

- (void)sendCandidate:(RTCIceCandidate *)candidate
{
    NSMutableDictionary *message = [NSMutableDictionary dictionaryWithCapacity:0];//创建一个空字典
    
    [message setObject:@302 forKey:@"protocol"];
    int64_t t = [self getCurrentTimeinS];
    [message setObject:[NSNumber numberWithLongLong:t] forKey:@"t"];
    
    NSMutableDictionary *singaling = [NSMutableDictionary dictionaryWithCapacity:0];//创建一个空字典
    NSMutableDictionary *header = [NSMutableDictionary dictionaryWithCapacity:0];//创建一个空字典
    NSString *uid = [_mqttConfig[@"username"] substringFromIndex : 6];
    // header
    [header setObject:uid forKey:@"from"];
    [header setObject:deviceId_ forKey:@"to"];
    [header setObject:@"candidate" forKey:@"type"];
    [header setObject:@"moto_pre_cn002" forKey:@"moto_id"];
    [header setObject:_sessionId forKey:@"sessionid"];
    [singaling setObject:header forKey:@"header"];
    
    NSMutableDictionary *msg = [NSMutableDictionary dictionaryWithCapacity:0];//创建一个空字典
    [msg setObject:@"webrtc" forKey:@"mode"];
    NSString *strCandidate = [NSString stringWithFormat:@"a=%@",candidate.sdp];
    [msg setObject:strCandidate forKey:@"candidate"];
    [singaling setObject:msg forKey:@"msg"];
    
    [message setObject:singaling forKey:@"data"];
    
    NSString *json = [self convertToJsonData:message];
    NSData *jsonData = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSLog(@"=======sendCandidate :%@ ",json);
    [_sessionManager.session publishData:jsonData onTopic:_moto_topic retain:NO qos:MQTTQosLevelAtLeastOnce publishHandler:^(NSError *error) {
        if (error) {
            NSLog(@"=======sendCandidate failed.....");
        }
    }];
}

-(void)createPeerConnection
{
    RTCDefaultVideoDecoderFactory *decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
    RTCDefaultVideoEncoderFactory *encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
    _factory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory decoderFactory:decoderFactory];
    // Create peer connection.
    RTCMediaConstraints *constraints = [self defaultPeerConnectionConstraints];
    RTCConfiguration *config = [[RTCConfiguration alloc] init];
    NSMutableArray *icess = [NSMutableArray array];
    
    NSString *credential ;
    NSString *username ;
    NSMutableArray *stunUrls = [NSMutableArray array];
    NSMutableArray *turnUrls = [NSMutableArray array];
    for (id obj in _iceServers) {
        NSDictionary *ice = obj ;
        NSString *value = ice[@"urls"] ;
        NSRange nat = [value rangeOfString:@"stun"];
        if (nat.location != NSNotFound) {
            [stunUrls addObject:value];
            continue ;
        }
        nat = [value rangeOfString:@"turn"];
        if (nat.location != NSNotFound) {
            [turnUrls addObject:value];
            username = ice[@"username"];
            credential = ice[@"credential"];
        }
    }
    RTCIceServer *stun  = [[RTCIceServer alloc]initWithURLStrings:stunUrls];
    RTCIceServer *turn = [[RTCIceServer alloc]initWithURLStrings:turnUrls username:username credential:credential];
    [icess addObject:stun];
    [icess addObject:turn];
    config.iceServers = icess;
    
    if(_peerConnection == nil){
        _peerConnection = [_factory peerConnectionWithConfiguration:config constraints:constraints delegate:self];
        [self createMediaSenders];
        __weak ARDAppClient *weakSelf = self;
        [_peerConnection offerForConstraints:[self defaultOfferConstraints] completionHandler:^(RTCSessionDescription *sdp,NSError *error) {
            ARDAppClient *strongSelf = weakSelf;
            [strongSelf peerConnection:strongSelf.peerConnection didCreateSessionDescription_:sdp error:error];
        }];
    }
}

-(void)createPeerConnect{
    NSMutableArray *ices = _rtcConfig[@"configs"][@"p2p_config"][@"ices"];
    if (ices) {
        for (id obj in ices) {
            NSDictionary *ice = obj ;
            NSString *value = ice[@"urls"] ;
            NSRange nat = [value rangeOfString:@"nat"];
            NSRange tcp = [value rangeOfString:@"tcp"];
            NSRange tls = [value rangeOfString:@"tls"];
            if (nat.location == NSNotFound && tcp.location == NSNotFound && tls.location == NSNotFound) {
                [_iceServers addObject:obj];
            }
        }
        [self createPeerConnection];
    }
}


- (void)onReceiveAnswer :(NSMutableDictionary *)dict
{
    NSString *sdp = dict[@"data"][@"msg"][@"sdp"];
    NSString *strSdp = [sdp stringByReplacingOccurrencesOfString:@"profile-level-id=42001f" withString:@"profile-level-id=42e01f"];
    //    NSString *strSdp = [sdp stringByReplacingOccurrencesOfString:@"profile-level-id=640029" withString:@"profile-level-id=42001f"];
    RTCSessionDescription *description = [[RTCSessionDescription alloc]initWithType:RTCSdpTypeAnswer sdp:strSdp];
    NSLog(@"====== receive answer sdp :%@",sdp);
    __weak ARDAppClient *weakSelf = self;
    [_peerConnection setRemoteDescription:description
                        completionHandler:^(NSError *error)
     {
         ARDAppClient *strongSelf = weakSelf;
         [strongSelf peerConnection:strongSelf.peerConnection didSetSessionDescriptionWithError_:error];
     }];
}

-(void)onReceiveCandidate:(NSMutableDictionary *)dict
{
    NSString *candidate = dict[@"data"][@"msg"][@"candidate"];
    if (candidate) {
        NSString *strCandidate = candidate ;
        NSRange range = [strCandidate rangeOfString:@"a="];
        if (range.location != NSNotFound) {
            strCandidate = [candidate substringFromIndex:2];
            RTCIceCandidate *iceCandidate = [[RTCIceCandidate alloc]initWithSdp:strCandidate sdpMLineIndex:0 sdpMid:@"audio"];
            ARDICECandidateMessage *candidateMessage = [[ARDICECandidateMessage alloc]initWithCandidate:iceCandidate];
            [_peerConnection addIceCandidate:candidateMessage.candidate];
        }
    }
}


#pragma mark - mqtt session manager delegate
/** gets called when a new message was received
 
 @param data the data received, might be zero length
 @param topic the topic the data was published to
 @param retained indicates if the data retransmitted from server storage
 */
- (void)handleMessage:(NSData *)data onTopic:(NSString *)topic retained:(BOOL)retained
{
    NSLog(@"===== handleMessage :%@" , topic);
}

/** gets called when a new message was received
 @param sessionManager the instance of MQTTSessionManager whose state changed
 @param data the data received, might be zero length
 @param topic the topic the data was published to
 @param retained indicates if the data retransmitted from server storage
 */
- (void)sessionManager:(MQTTSessionManager *)sessionManager
     didReceiveMessage:(NSData *)data
               onTopic:(NSString *)topic
              retained:(BOOL)retained
{
    NSString* newStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSError *err = nil;
    NSMutableDictionary *dict  = [NSJSONSerialization JSONObjectWithData:[newStr dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingMutableContainers error:&err];
    if (dict) {
        NSString *msgType = dict[@"data"][@"header"][@"type"] ;
        if ([msgType isEqualToString:@"answer"]) {
            [self onReceiveAnswer:dict];
            NSLog(@"====== didReceiveMessage type=answer msg:%@",dict);
        }else if([msgType isEqualToString:@"candidate"])
        {
            [self onReceiveCandidate:dict];
            NSLog(@"====== didReceiveMessage type=candidate msg:%@",dict);
        }else if([msgType isEqualToString:@"disconnect"]){
            NSLog(@"====== didReceiveMessage type=disconnect msg:%@",dict);
        }
    }
}

/** gets called when a published message was actually delivered
 @param msgID the Message Identifier of the delivered message
 @note this method is called after a publish with qos 1 or 2 only
 */
- (void)messageDelivered:(UInt16)msgID
{
    
}

/** gets called when a published message was actually delivered
 @param sessionManager the instance of MQTTSessionManager whose state changed
 @param msgID the Message Identifier of the delivered message
 @note this method is called after a publish with qos 1 or 2 only
 */
- (void)sessionManager:(MQTTSessionManager *)sessionManager didDeliverMessage:(UInt16)msgID
{
    NSLog(@"===== didDeliverMessage :%d" , msgID);
}

/** gets called when the connection status changes
 @param sessionManager the instance of MQTTSessionManager whose state changed
 @param newState the new connection state of the sessionManager. This will be identical to `sessionManager.state`.
 */
- (void)sessionManager:(MQTTSessionManager *)sessionManager didChangeState:(MQTTSessionManagerState)newState
{
    if (MQTTSessionManagerStateConnected == newState) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *uid = [_mqttConfig[@"username"] substringFromIndex : 6];
            
            NSString *topic = [NSString stringWithFormat:@"/av/u/%@",uid];
            NSLog(@"====== subscribe topic:%@",topic);
            [sessionManager.session subscribeToTopic:topic atLevel:MQTTQosLevelAtLeastOnce subscribeHandler:^(NSError *error, NSArray<NSNumber *> *gQoss) {
                if (error == nil) {
                    [self createPeerConnect];
                }
            }];
        });
    }
}

@end

