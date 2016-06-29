//
//  EventViewController.m
//  IB-ios
//
//  Created by Andrea Phillips on 30/09/2015.
//  Copyright (c) 2015 Andrea Phillips. All rights reserved.
//

#import "OTKTextChatComponent.h"
#import "IBApi.h"

#import "EventViewController.h"

#import "SVProgressHUD.h"
#import "DotSpinnerViewController.h"

#import "EventView.h"
#import "IBInstance_Internal.h"
#import "IBDateFormatter.h"
#import "JSON.h"
#import "UIColor+AppAdditions.h"
#import "UIView+Category.h"
#import "UIImageView+Category.h"
#import "PerformSelectorWithDebounce.h"

#import "OpenTokManager.h"
#import "OpenTokNetworkTest.h"
#import "OpenTokLoggingWrapper.h"

#import <Reachability/Reachability.h>

#import <MediaPlayer/MediaPlayer.h>

typedef enum : NSUInteger {
    IBEventStageNotLive = 0,
    IBEventStageLive = 1 << 0,
    IBEventStageBackstage = 1 << 1,
    IBEventStageOnstage = 1 << 2
} IBEventStage;

@interface EventViewController () <OTSessionDelegate, OTSubscriberKitDelegate, OTPublisherDelegate, OTKTextChatDelegate,OTSubscriberKitNetworkStatsDelegate>

@property (nonatomic) NSString *userName;
@property (nonatomic) NSUInteger eventStage;
@property (nonatomic) BOOL inCallWithProducer;

@property (nonatomic) OTKTextChatComponent *textChat;
@property (nonatomic) CGFloat chatYPosition;

@property (nonatomic) EventView *eventView;
@property (nonatomic) BOOL shouldResendProducerSignal;
@property (nonatomic) BOOL stopGoingLive;
@property (nonatomic) CGFloat unreadCount;

// Reachability
@property (nonatomic) Reachability *internetReachability;

// Data
@property (nonatomic) IBUser *user;
@property (nonatomic) IBEvent *event;
@property (nonatomic) IBInstance *instance;

// OpenTok
@property (nonatomic) OpenTokManager *openTokManager;
@property (nonatomic) OpenTokNetworkTest *networkTest;

@property (nonatomic) AVPlayer *player;
@property (nonatomic) AVPlayerLayer *playerLayer;

@end

@implementation EventViewController

- (instancetype)initWithInstance:(IBInstance *)instance
                       indexPath:(NSIndexPath *)indexPath
                            user:(IBUser *)user {
    
    if (!instance || !indexPath || !user) return nil;
    
    if (self = [super initWithNibName:@"EventViewController" bundle:[NSBundle bundleForClass:[self class]]]) {
        
        OTDefaultAudioDevice *defaultAudioDevice = [[OTDefaultAudioDevice alloc] init];
        [OTAudioDeviceManager setAudioDevice:defaultAudioDevice];
        
        _instance = instance;
        _event = _instance.events[indexPath.row];
        _user = user;
        _userName = user.name ? user.name : [user userRoleName];
        
        _openTokManager = [[OpenTokManager alloc] init];
        
        // start necessary services
        __weak EventViewController *weakSelf = self;

        [self addObserver:weakSelf
               forKeyPath:@"event.status"
                  options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld)
                  context:NULL];
        
        [self addObserver:weakSelf
               forKeyPath:@"openTokManager.canJoinShow"
                  options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld)
                  context:NULL];
        [self addObserver:weakSelf
               forKeyPath:@"openTokManager.waitingOnBroadcast"
                  options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld)
                  context:NULL];
        
        [self addObserver:weakSelf
               forKeyPath:@"openTokManager.startBroadcast"
                  options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld)
                  context:NULL];
        
        [self addObserver:weakSelf
               forKeyPath:@"openTokManager.broadcastEnded"
                  options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld)
                  context:NULL];
        
        _internetReachability = [Reachability reachabilityForInternetConnection];
        [_internetReachability startNotifier];
        
        [[UIApplication sharedApplication] setIdleTimerDisabled:YES];

    }
    return self;
}

-(void)viewDidLoad {
    
    [super viewDidLoad];
    self.eventView = (EventView *)self.view;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reachabilityChanged:) name:kReachabilityChangedNotification object:nil];
    
    if (self.internetReachability.currentReachabilityStatus != NotReachable) {
        [self createEventToken];
    }
}

- (void)reachabilityChanged:(NSNotification *)notification {
    Reachability *reachability = [notification object];
    switch (reachability.currentReachabilityStatus) {
        case NotReachable:
            break;
        case ReachableViaWWAN:
        case ReachableViaWiFi:{
            
            if (!self.instance) {
                [self createEventToken];
            }
            break;
        }
    }
}

- (void)createEventToken{
    
    [SVProgressHUD show];
    [IBApi createEventTokenWithUser:self.user
                              event:self.event
                         completion:^(IBInstance *instance, NSError *error) {
                             [SVProgressHUD dismiss];
                                 
                             if (!error && instance.events.count == 1)
                             {
                                 self.instance = instance;
                                 self.event = [self.instance.events lastObject];
                                 [self statusChanged];
                                 [self checkPresence];
                             }
                             else
                             {
                                 NSLog(@"createEventTokenError");
                             }
                         }];
}

- (void)viewDidLayoutSubviews {
    
    [super viewDidLayoutSubviews];
    [self.eventView performSelector:@selector(adjustSubscriberViewsFrameWithSubscribers:) withObject:self.openTokManager.subscribers afterDelay:1.0];

}

- (void)viewWillDisappear:(BOOL)animated {

    [self removeObserver:self forKeyPath:@"event.status"];
    
    [self removeObserver:self forKeyPath:@"openTokManager.startBroadcast"];
    [self removeObserver:self forKeyPath:@"openTokManager.waitingOnBroadcast"];
    [self removeObserver:self forKeyPath:@"openTokManager.broadcastEnded"];
    [self removeObserver:self forKeyPath:@"openTokManager.canJoinShow"];
    
    if(_openTokManager.startBroadcast){
        [self removeObserver:self forKeyPath:@"player.status"];
    }
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.openTokManager closeSocket];
    [super viewWillDisappear:animated];
    
}
- (void)checkPresence{
    [self.openTokManager connectFanToSocketWithURL:self.instance.signalingURL sessionId:self.instance.sessionIdHost];
}

- (void)startBroadcastEvent{
    
    self.eventView.getInLineBtn.hidden = YES;
    
    NSURL *streamURL = [NSURL URLWithString:self.openTokManager.broadcastUrl];
    self.player = [AVPlayer playerWithURL:streamURL];
    
    _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
    [self.eventView.layer addSublayer: _playerLayer];
    
    [_playerLayer setFrame:_eventView.videoHolder.frame];
    [_playerLayer setVideoGravity:AVLayerVideoGravityResizeAspectFill ];
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    
    [self addObserver:self forKeyPath:@"player.status" options:0 context:nil];

}

- (void) closeBroadcastEvent{
    [_playerLayer removeFromSuperlayer];
    self.event.status = @"C";
}

- (void)playerItemDidReachEnd:(NSNotification *)notification {
    AVPlayerItem *p = [notification object];
    [p seekToTime:kCMTimeZero];
    NSLog(@"Broadcast Stopped");
}

- (void)startSession{
    _openTokManager.session = [[OTSession alloc] initWithApiKey:self.instance.apiKey
                                                      sessionId:self.instance.sessionIdHost
                                                       delegate:self];
    [self.openTokManager connectWithTokenHost:self.instance.tokenHost];
    

    self.eventView.getInLineBtn.hidden = YES;
    [self statusChanged];
    
    if(self.user.userRole == IBUserRoleFan) {
        [self.openTokManager emitJoinRoom:self.instance.sessionIdHost];
    }
}

- (void)loadChat{
    OTSession *currentSession;
    
    if((self.eventStage & IBEventStageBackstage) == IBEventStageBackstage){
        currentSession = _openTokManager.producerSession;
    }
    else{
        currentSession = _openTokManager.session;
    }
    
    _textChat = [[OTKTextChatComponent alloc] init];
    _textChat.delegate = self;
    [_textChat setMaxLength:1050];
    [_textChat setSenderId:currentSession.connection.connectionId alias:@"You"];
    
    _chatYPosition = self.eventView.statusBar.layer.frame.size.height + self.eventView.chatBar.layer.frame.size.height;
    
    CGRect r = self.view.bounds;
    r.origin.y += _chatYPosition;
    r.size.height -= _chatYPosition;
    (_textChat.view).frame = r;
    [self.eventView insertSubview:_textChat.view belowSubview:self.eventView.chatBar];
    
    if(self.user.userRole != IBUserRoleFan){
        self.eventView.chatBtn.hidden = NO;
    }
    
    self.textChat.view.hidden = YES;
    [_eventView hideChatBar];
    _unreadCount = 0;
}

-(void)unpublishBackstage {
    [_openTokManager unpublishFrom:_openTokManager.producerSession withUserRole:[self.user userRoleName]];
    self.eventStage &= ~IBEventStageBackstage;
    _shouldResendProducerSignal = YES;
}

-(void)forceDisconnect
{
    [_openTokManager cleanupPublisher];
    NSString *text = [NSString stringWithFormat: @"There already is a %@ using this session. If this is you please close all applications or browser sessions and try again.", self.user.userRole == IBUserRoleFan ? @"celebrity" : @"host"];
    [self.eventView showNotification:text useColor:[UIColor SLBlueColor]];
    self.eventView.videoHolder.hidden = YES;

    [_openTokManager disconnectOnstageSession];
}

#pragma mark - publishers
- (void)doPublish{
    if(self.user.userRole == IBUserRoleFan){

        if((self.eventStage & IBEventStageBackstage) == IBEventStageBackstage){
            [self.openTokManager sendNewUserSignalWithName:self.userName];
            [self publishTo:_openTokManager.producerSession];
            _openTokManager.publisher.publishAudio = NO;
            (_openTokManager.publisher.view).frame = CGRectMake(0, 0, self.eventView.inLineHolder.bounds.size.width, self.eventView.inLineHolder.bounds.size.height);
            [self.eventView stopLoader];
            [self.eventView fanIsInline];
        }
        
        if((self.eventStage & IBEventStageOnstage) == IBEventStageOnstage) {
            [self publishTo:_openTokManager.session];
            [self.eventView.fanViewHolder addSubview:_openTokManager.publisher.view];
            _openTokManager.publisher.view.frame = CGRectMake(0, 0, self.eventView.fanViewHolder.bounds.size.width, self.eventView.fanViewHolder.bounds.size.height);
            [self.eventView fanIsOnStage];
        }
    }
    else {
        if(self.user.userRole == IBUserRoleCelebrity && !_stopGoingLive){
            [self publishTo:_openTokManager.session];
            [self.eventView.celebrityViewHolder addSubview:_openTokManager.publisher.view];
            (_openTokManager.publisher.view).frame = CGRectMake(0, 0, self.eventView.celebrityViewHolder.bounds.size.width, self.eventView.celebrityViewHolder.bounds.size.height);
        }
        
        if(self.user.userRole == IBUserRoleHost && !_stopGoingLive){
            [self publishTo:_openTokManager.session];
            [self.eventView.hostViewHolder addSubview:_openTokManager.publisher.view];
            (_openTokManager.publisher.view).frame = CGRectMake(0, 0, self.eventView.hostViewHolder.bounds.size.width, self.eventView.hostViewHolder.bounds.size.height);
        }
        
        if(_stopGoingLive){
            [self forceDisconnect];
        }
    }
    
    [self.eventView adjustSubscriberViewsFrameWithSubscribers:self.openTokManager.subscribers];
}

-(void) publishTo:(OTSession *)session {
    
    
    NSString *session_name = _openTokManager.session.sessionId == session.sessionId ? @"onstage" : @"backstage";
    NSString *logtype = [NSString stringWithFormat:@"%@_publishes_%@", [self.user userRoleName], session_name];
    [OpenTokLoggingWrapper logEventAction:logtype variation:@"attempt"];
    
    if(!_openTokManager.publisher){
        _openTokManager.publisher = [[OTPublisher alloc] initWithDelegate:self name:self.userName];
    }
    
    OTError *error = nil;
    [session publish:_openTokManager.publisher error:&error];
    
    if (error) {
        NSLog(@"%@", error);
        [_openTokManager sendWarningSignal];
        
        [SVProgressHUD showErrorWithStatus:error.localizedDescription];
        [OpenTokLoggingWrapper logEventAction:logtype variation:@"fail"];
    }
    else{
        [OpenTokLoggingWrapper logEventAction:logtype variation:@"success"];
    }
}

# pragma mark - OTPublisher delegate callbacks
- (void)publisher:(OTPublisherKit *)publisher
    streamCreated:(OTStream *)stream
{
    if((self.eventStage & IBEventStageBackstage) == IBEventStageBackstage){
        NSLog(@"stream Created PUBLISHER BACK");
        _openTokManager.selfSubscriber = [[OTSubscriber alloc] initWithStream:stream delegate:self];
        _openTokManager.selfSubscriber.subscribeToAudio = NO;
        
        OTError *error = nil;
        [_openTokManager.producerSession subscribe: _openTokManager.selfSubscriber error:&error];
        if (error) {
            NSLog(@"subscribe self error");
        }
    }
    else{
        NSLog(@"stream Created PUBLISHER ONST");
        [self doSubscribe:stream];
    }
    [self performSelector:@selector(startNetworkTest) withObject:nil afterDelay:5.0];
}

- (void)publisher:(OTPublisherKit*)publisher
  streamDestroyed:(OTStream *)stream
{
    
    if(!_openTokManager.publisher.stream && !stream.connection) return;
    
    NSString *me = [self.user userRoleName];
    NSString *connectingTo = [stream.connection.data stringByReplacingOccurrencesOfString:@"usertype=" withString:@""];
    OTSubscriber *_subscriber = _openTokManager.subscribers[connectingTo];
    
    if ([_subscriber.stream.streamId isEqualToString:stream.streamId])
    {
        NSLog(@"stream DESTROYED ONSTAGE %@", connectingTo);
        
        NSString *logtype = [NSString stringWithFormat:@"%@_unpublishes_onstage",me];
        [OpenTokLoggingWrapper logEventAction:logtype variation:@"success"];
        [_openTokManager cleanupSubscriber:connectingTo];
        [self.eventView adjustSubscriberViewsFrameWithSubscribers:self.openTokManager.subscribers];
    }
    if(_openTokManager.selfSubscriber){
        [_openTokManager unsubscribeSelfFromProducerSession];
    }
    [_openTokManager cleanupPublisher];
}

- (void)publisher:(OTPublisherKit*)publisher
 didFailWithError:(OTError*) error
{
    NSLog(@"publisher didFailWithError %@", error);
    [_openTokManager cleanupPublisher];
}

//Subscribers
- (void)doSubscribe:(OTStream*)stream
{
    
    NSString *connectingTo = [stream.connection.data stringByReplacingOccurrencesOfString:@"usertype=" withString:@""];
    
    if(stream.session.connection.connectionId != _openTokManager.producerSession.connection.connectionId && ![connectingTo isEqualToString:@"producer"]){
        
        OTSubscriber *subs = [[OTSubscriber alloc] initWithStream:stream delegate:self];
        subs.viewScaleBehavior = OTVideoViewScaleBehaviorFit;
        _openTokManager.subscribers[connectingTo] = subs;
        NSString *logtype = [NSString stringWithFormat:@"%@_subscribes_%@", [self.user userRoleName],connectingTo];
        [OpenTokLoggingWrapper logEventAction:logtype variation:@"attempt"];

        if([_openTokManager subscribeToOnstageWithType:connectingTo]) {
            [OpenTokLoggingWrapper logEventAction:logtype variation:@"fail"];
            [self.eventView showError:@"You are experiencing network connectivity issues. Please try closing the application and coming back to the event" useColor:[UIColor SLRedColor]];
        }
        subs = nil;
        
    }
    if(stream.session.connection.connectionId == _openTokManager.producerSession.connection.connectionId && [connectingTo isEqualToString:@"producer"]){
        _openTokManager.producerSubscriber = [[OTSubscriber alloc] initWithStream:stream delegate:self];
        if ([_openTokManager backstageSubscribeToProducer]) {
            [self.eventView showError:@"You are experiencing network connectivity issues. Please try closing the application and coming back to the event" useColor:[UIColor SLRedColor]];
        }
        
    }
    if(stream.session.connection.connectionId == _openTokManager.session.connection.connectionId && [connectingTo isEqualToString:@"producer"]){
        _openTokManager.privateProducerSubscriber = [[OTSubscriber alloc] initWithStream:stream delegate:self];
        if ([_openTokManager onstageSubscribeToProducer]) {
            [self.eventView showError:@"You are experiencing network connectivity issues. Please try closing the application and coming back to the event" useColor:[UIColor SLRedColor]];
        }
    }
}

# pragma mark - OTSubscriber delegate callbacks

- (void)subscriberDidConnectToStream:(OTSubscriberKit*)subscriber
{
    _networkTest = [[OpenTokNetworkTest alloc] initWithFrameRateAndResolution:@"30" resolution:@"640x480"];
    if(subscriber.session.connection.connectionId == _openTokManager.session.connection.connectionId && subscriber.stream != _openTokManager.privateProducerStream){
        
        NSLog(@"subscriberDidConnectToStream (%@)", subscriber.stream.connection.connectionId);
        
        UIView *holder;
        NSString *connectingTo = [subscriber.stream.connection.data stringByReplacingOccurrencesOfString:@"usertype=" withString:@""];
        OTSubscriber *_subscriber = _openTokManager.subscribers[connectingTo];
        
        NSString *logtype = [NSString stringWithFormat:@"%@_subscribes_%@", [self.user userRoleName],connectingTo];
        [OpenTokLoggingWrapper logEventAction:logtype variation:@"success"];
        
        assert(_subscriber == subscriber);
        
        holder = [self.eventView valueForKey:[NSString stringWithFormat:@"%@ViewHolder", connectingTo]];
        (_subscriber.view).frame = CGRectMake(0, 0, holder.bounds.size.width,holder.bounds.size.height);
        
        [holder addSubview:_subscriber.view];
        self.eventView.eventImage.hidden = YES;
        [self.eventView adjustSubscriberViewsFrameWithSubscribers:self.openTokManager.subscribers];
    }
    
    if(_openTokManager.publisher && _openTokManager.publisher.stream.connection.connectionId == subscriber.stream.connection.connectionId){
        subscriber.subscribeToAudio = NO;
    }
}

- (void)subscriber:(OTSubscriberKit*)subscriber
  didFailWithError:(OTError*)error
{
    NSLog(@"subscriber %@ didFailWithError %@",subscriber.stream.streamId,error);
    
    [self.eventView showNotification:@"You are experiencing network connectivity issues. Please try closing the application and coming back to the event" useColor:[UIColor SLRedColor]];
    [_openTokManager.errors setObject:error forKey:@"subscriberError"];
    [_openTokManager sendWarningSignal];
}

- (void)subscriberVideoDisabled:(OTSubscriberKit*)subscriber
                         reason:(OTSubscriberVideoEventReason)reason
{
    NSString *feed = [subscriber.stream.connection.data stringByReplacingOccurrencesOfString:@"usertype=" withString:@""];
    UIView *feedView = [self.eventView valueForKey:[NSString stringWithFormat:@"%@ViewHolder", feed]];
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    UIImageView* avatar = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"avatar" inBundle:bundle compatibleWithTraitCollection:nil]];
    avatar.contentMode = UIViewContentModeScaleAspectFill;
    
    CGRect frame = feedView.frame;
    avatar.frame = CGRectMake(0, 0, frame.size.width,frame.size.height);
    
    [feedView addSubview:avatar];
}

- (void)subscriberVideoEnabled:(OTSubscriberKit*)subscriber
                        reason:(OTSubscriberVideoEventReason)reason
{
    NSString *feed = [subscriber.stream.connection.data stringByReplacingOccurrencesOfString:@"usertype=" withString:@""];
    UIView *feedView = [self.eventView valueForKey:[NSString stringWithFormat:@"%@ViewHolder", feed]];
    for(UIView* subview in [feedView subviews]) {
        if([subview isKindOfClass:[UIImageView class]]) {
            [subview removeFromSuperview];
        }
    }
}

-(void)startNetworkTest{
    if((self.eventStage & IBEventStageBackstage) ==  IBEventStageBackstage ||
       (self.eventStage & IBEventStageOnstage) == IBEventStageOnstage) {
        
        if(_openTokManager.hostStream &&
           _openTokManager.hostStream.hasVideo &&
           (self.eventStage & IBEventStageLive) == IBEventStageLive) {
            
            OTSubscriber *test = _openTokManager.subscribers[@"host"];
            test.networkStatsDelegate = self;
        }
        else if(_openTokManager.celebrityStream &&
                _openTokManager.celebrityStream.hasVideo &&
                (self.eventStage & IBEventStageLive) == IBEventStageLive) {
            
            OTSubscriber *test = _openTokManager.subscribers[@"celebrity"];
            test.networkStatsDelegate = self;
        }
        else if(_openTokManager.selfSubscriber) {
            _openTokManager.selfSubscriber.networkStatsDelegate = self;
        }
    }
}

-(void)subscriber:(OTSubscriberKit*)subscriber
videoNetworkStatsUpdated:(OTSubscriberKitVideoNetworkStats*)stats {
    
    if (stats.timestamp - _networkTest.prevVideoTimestamp >= 3000) {
        subscriber.delegate = nil;
        [self performSelector:@selector(checkQualityAndSendSignal) withDebounceDuration:15.0];
    }
    [_networkTest setStats:stats];
}

- (void)checkQualityAndSendSignal
{
    if(_openTokManager.publisher && _openTokManager.publisher.session) {
        [_openTokManager updateQualitySignal:[_networkTest getQuality]];
        [self startNetworkTest];
    }
}

# pragma mark - OTSession delegate callbacks
- (void)sessionDidConnect:(OTSession*)session {
    
    if (session == self.openTokManager.session) {
        
        NSString* sourceId = [NSString stringWithFormat:@"%@-event-%@", [NSBundle mainBundle].infoDictionary[@"CFBundleIdentifier"], self.event.identifier];
        [OpenTokLoggingWrapper loggerWithApiKey:self.instance.apiKey
                                      sessionId:session.sessionId
                                   connectionId:session.connection.connectionId
                                       sourceId:sourceId];
        
        NSString *logtype = [NSString stringWithFormat:@"%@_connects_onstage", [self.user userRoleName]];
        [OpenTokLoggingWrapper logEventAction:logtype variation:@"success"];
    }
    
    if (self.user.userRole == IBUserRoleFan) {
        if(session.sessionId == _openTokManager.session.sessionId){
            NSLog(@"sessionDidConnect to Onstage");
            (self.eventView.statusLabel).text = @"";
            self.eventView.closeEvenBtn.hidden = NO;
        }
        if(session.sessionId == _openTokManager.producerSession.sessionId){
            NSLog(@"sessionDidConnect to Backstage");
            self.eventStage |= IBEventStageBackstage;
            [self.eventView fanIsInline];
            [self doPublish];
            [self loadChat];
            [OpenTokLoggingWrapper logEventAction:@"fan_connects_backstage" variation:@"success"];
        }
    }
    else {
        [self.eventView showLoader];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (_stopGoingLive) {
                [self forceDisconnect];
            }
            else{
                [self loadChat];
                self.eventStage |= IBEventStageOnstage;
                [self doPublish];
            }
            [self.eventView stopLoader];
        });
    }
}

- (void)sessionDidDisconnect:(OTSession*)session {
    
    NSLog(@"sessionDidDisconnect (%@)", session.sessionId);
    if(session == _openTokManager.producerSession) {
        self.eventStage &= ~IBEventStageBackstage;
        
        _shouldResendProducerSignal = YES;
        [_openTokManager cleanupPublisher];
        [self.eventView hideNotification];
        [self.eventView fanLeaveLine];
    }
    else {
        self.eventView.getInLineBtn.hidden = YES;
        _openTokManager.session = nil;
    }
}


- (void)session:(OTSession*)mySession
  streamCreated:(OTStream *)stream {
    
    NSLog(@"session streamCreated (%@)", stream.streamId);
    if(mySession.connection.connectionId != _openTokManager.producerSession.connection.connectionId) {
        
        if([stream.connection.data isEqualToString:@"usertype=producer"]){
            _openTokManager.privateProducerStream = stream;
        }
        else{
            
            if([stream.connection.data isEqualToString:@"usertype=host"]){
                _openTokManager.hostStream = stream;
                if(self.user.userRole == IBUserRoleHost){
                    _stopGoingLive = YES;
                }
            }
            
            if([stream.connection.data isEqualToString:@"usertype=celebrity"]){
                _openTokManager.celebrityStream = stream;
                if(self.user.userRole == IBUserRoleCelebrity){
                    _stopGoingLive = YES;
                }
            }
            
            if([stream.connection.data isEqualToString:@"usertype=fan"]){
                _openTokManager.fanStream = stream;
            }
            
            if((self.eventStage & IBEventStageLive) == IBEventStageLive || self.user.userRole == IBUserRoleCelebrity || self.user.userRole == IBUserRoleHost){
                [self doSubscribe:stream];
            }
        }
    }
    else{
        if([stream.connection.data isEqualToString:@"usertype=producer"]){
            _openTokManager.producerStream = stream;
            if(_openTokManager.producerSession.connection){
                _shouldResendProducerSignal = YES;
            }
        }
    }
}

- (void)session:(OTSession*)session streamDestroyed:(OTStream *)stream {
    
    NSLog(@"session streamDestroyed (%@)", stream.streamId);
    NSLog(@"disconnectin from stream (%@)", stream.connection.data);
    
    NSString *type = [stream.connection.data stringByReplacingOccurrencesOfString:@"usertype=" withString:@""];
    if ([type isEqualToString:@"producer"]) {
        if(session.connection.connectionId == _openTokManager.producerSession.connection.connectionId) {
            _openTokManager.producerStream = nil;
        }
        else{
            _openTokManager.privateProducerStream = nil;
        }
    }
    else{
        if(session.connection.connectionId == _openTokManager.session.connection.connectionId) {
            
            if([type isEqualToString:@"host"]){
                _openTokManager.hostStream = nil;
            }
            
            if([type isEqualToString:@"celebrity"]){
                _openTokManager.celebrityStream = nil;
            }
            
            if([type isEqualToString:@"fan"]){
                _openTokManager.fanStream = nil;
            }
            [_openTokManager cleanupSubscriber:type];
            [self.eventView adjustSubscriberViewsFrameWithSubscribers:self.openTokManager.subscribers];
        }
    }
}

- (void) session:(OTSession*)session
didFailWithError:(OTError*)error
{
    [self.eventView showNotification:@"You are experiencing network connectivity issues. Please try closing the application and coming back to the event" useColor:[UIColor SLRedColor]];
    NSLog(@"didFailWithError: (%@)", error);
}


#pragma mark - session signal handler

- (void)session:(OTSession*)session receivedSignalType:(NSString*)type fromConnection:(OTConnection*)connection withString:(NSString*)string {
    
    if (!type) return;
    NSDictionary* messageData;
    if(string){
        messageData = [JSON parseJSON:string];
    }
    NSLog(@"session did receiveSignalType: (%@)", type);
    
    if([type isEqualToString:@"startEvent"]){
        if ([self.event.status isEqualToString:@"N"]){
            self.event.status = @"P";
            _shouldResendProducerSignal = YES;
            [self statusChanged];
        }
    }
    else if([type isEqualToString:@"openChat"]){
        _openTokManager.producerConnection = connection;
    }
    else if([type isEqualToString:@"closeChat"]){
        if(self.user.userRole == IBUserRoleFan){
            [self hideChatBox];
        }
    }
    else if([type isEqualToString:@"muteAudio"]){
        [messageData[@"mute"] isEqualToString:@"on"] ? [_openTokManager.publisher setPublishAudio: NO] : [_openTokManager.publisher setPublishAudio: YES];
    }
    else if([type isEqualToString:@"videoOnOff"]){
        [messageData[@"video"] isEqualToString:@"on"] ? [_openTokManager.publisher setPublishVideo: YES] : [_openTokManager.publisher setPublishVideo: NO];
    }
    else if([type isEqualToString:@"newBackstageFan"]){
        if(self.user.userRole != IBUserRoleFan){
            [self.eventView showError:@"A new FAN has been moved to backstage" useColor:[UIColor SLBlueColor]];
        }
    }
    else if([type isEqualToString:@"joinBackstage"]){
        self.eventView.statusLabel.text = @"BACKSTAGE";
        _openTokManager.publisher.publishAudio = YES;
        [self.eventView showVideoPreviewWithPublisher:_openTokManager.publisher];
        [self.eventView showNotification:@"Going Backstage.You are sharing video." useColor:[UIColor SLBlueColor]];
    }
    else if([type isEqualToString:@"newFanAck"]){
        _shouldResendProducerSignal = NO;
        [self performSelector:@selector(captureAndSendScreenshot) withObject:nil afterDelay:2.0];
    }
    else if([type isEqualToString:@"producerLeaving"]){
        _shouldResendProducerSignal = YES;
    }
    else if([type isEqualToString:@"resendNewFanSignal"]){
        if(_shouldResendProducerSignal){
            [self.openTokManager sendNewUserSignalWithName:self.userName];
        }
    }
    else if([type isEqualToString:@"joinProducer"]){
        [self doSubscribe:_openTokManager.producerStream];
        _inCallWithProducer = YES;
        _openTokManager.publisher.publishAudio = YES;
        [self.openTokManager muteOnstageSession:YES];
        
        [self.eventView showNotification:@"YOU ARE NOW IN CALL WITH PRODUCER" useColor:[UIColor SLBlueColor]];
        [self.eventView showVideoPreviewWithPublisher:_openTokManager.publisher];
    }
    else if([type isEqualToString:@"privateCall"]){
        if ((self.eventStage & IBEventStageOnstage) == IBEventStageOnstage || (self.eventStage & IBEventStageBackstage) == IBEventStageBackstage) {
            if ([messageData[@"callWith"] isEqualToString: _openTokManager.publisher.stream.connection.connectionId ]) {
                [self doSubscribe:_openTokManager.privateProducerStream];
                _inCallWithProducer = YES;
                [self.openTokManager muteOnstageSession:YES];
                [self.eventView showNotification:@"YOU ARE NOW IN PRIVATE CALL WITH PRODUCER" useColor:[UIColor SLBlueColor]];
                if(self.user.userRole == IBUserRoleFan && (self.eventStage & IBEventStageBackstage) == IBEventStageBackstage){
                    [self.eventView showVideoPreviewWithPublisher:_openTokManager.publisher];
                }
            }
            else {
                [self.openTokManager muteOnstageSession:YES];
                [self.eventView showNotification:@"OTHER PARTICIPANTS ARE IN A PRIVATE CALL. THEY MAY NOT BE ABLE TO HEAR YOU." useColor:[UIColor SLBlueColor]];
            }
        }
    }
    else if([type isEqualToString:@"endPrivateCall"]){
        if ((self.eventStage & IBEventStageOnstage) == IBEventStageOnstage || (self.eventStage & IBEventStageBackstage) == IBEventStageBackstage) {
            if(_inCallWithProducer){
                [_openTokManager unsubscribeFromPrivateProducerCall];
                _inCallWithProducer = NO;
                if(self.user.userRole == IBUserRoleFan && (self.eventStage & IBEventStageBackstage) == IBEventStageBackstage){
                    [self.eventView hideVideoPreview];
                }
            }
            else{
                NSLog(@"I CAN HEAR AGAIN");
                [self.openTokManager muteOnstageSession:NO];
            }
            [self.eventView hideNotification];
        }
    }
    else if([type isEqualToString:@"disconnectProducer"]){
        if((self.eventStage & IBEventStageOnstage) != IBEventStageOnstage){
            [_openTokManager unsubscribeOnstageProducerCall];
            _inCallWithProducer = NO;
            self.eventView.getInLineBtn.hidden = NO;
            [self.eventView hideNotification];
            [self.eventView hideVideoPreview];
        }
    }
    else if([type isEqualToString:@"disconnectBackstage"]){
        _openTokManager.publisher.publishAudio = NO;
        self.eventView.leaveLineBtn.hidden = NO;
        self.eventView.statusLabel.text = @"IN LINE";
        [self.eventView hideNotification];
        [self.eventView hideVideoPreview];
    }
    else if([type isEqualToString:@"goLive"]){
        self.event.status = @"L";
    }
    else if([type isEqualToString:@"joinHost"]){
        
        [self unpublishBackstage];
        self.eventStage |= IBEventStageOnstage;
        [self hideChatBox];
        [self.eventView fanIsOnStage];
        if(![self.event.status isEqualToString:@"L"] && (self.eventStage & IBEventStageLive) != IBEventStageLive){
            [self goLive];
        }
        [DotSpinnerViewController show];
    }
    else if ([type isEqualToString:@"joinHostNow"]) {
        
        // TODO: remove spinner
        [DotSpinnerViewController dismiss];
        [self doPublish];
    }
    else if([type isEqualToString:@"finishEvent"]){
        self.event.status = @"C";
    }
    else if([type isEqualToString:@"disconnect"]){
        
        self.eventView.statusLabel.hidden = YES;
        self.eventView.chatBtn.hidden = YES;
        self.eventView.closeEvenBtn.hidden = NO;
        [self hideChatBox];
        
        self.eventStage &= ~ IBEventStageOnstage;
        
        if(_openTokManager.publisher) {
            [_openTokManager unpublishFrom:_openTokManager.session withUserRole:[self.user userRoleName]];
        }
        [_openTokManager disconnectBackstageSession];
        
        [self.eventView showError:@"Thank you for participating, you are no longer sharing video/voice. You can continue to watch the session at your leisure." useColor:[UIColor SLBlueColor]];
    }
    else if([type isEqualToString:@"chatMessage"]){
        if (![connection.connectionId isEqualToString:session.connection.connectionId]) {
            self.eventView.chatBtn.hidden = NO;
            _openTokManager.producerConnection = connection;
            NSDictionary *userInfo = [JSON parseJSON:string];
            OTKChatMessage *msg = [[OTKChatMessage alloc]init];
            msg.senderAlias = [connection.data stringByReplacingOccurrencesOfString:@"usertype=" withString:@""];
            msg.senderId = connection.connectionId;
            msg.text = userInfo[@"message"][@"message"];
            _unreadCount ++;
            [_textChat addMessage:msg];
            [self.eventView.chatBtn setTitle:[NSString stringWithFormat:@"%.0f", _unreadCount] forState:UIControlStateNormal];
        }
    }
}

- (void)captureAndSendScreenshot {
    
    if (_openTokManager.publisher.view) {
        UIImage *screenshot = [_openTokManager.publisher.view captureViewImage];
        NSData *imageData = UIImageJPEGRepresentation(screenshot, 0.3);
        NSString *encodedString = [imageData base64EncodedStringWithOptions:0 ];
        NSString *formattedString = [NSString stringWithFormat:@"data:image/png;base64,%@",encodedString];
        [self.openTokManager sendScreenShotSignalWithFormattedString:formattedString];
    }
}

#pragma mark - status observer
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    
    NSLog(keyPath);
    
    if ([keyPath isEqual:@"event.status"] && ![change[@"old"] isEqualToString:change[@"new"]]) {
        [self statusChanged];
    }
    if ([keyPath isEqual:@"player.status"]) {
        if(_player.status == AVPlayerStatusReadyToPlay){
            [_player play];
        }
    }
    if ([keyPath isEqual:@"openTokManager.waitingOnBroadcast"] && ![change[@"old"] isEqualToValue:change[@"new"]]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [_eventView showNotification:@"Waiting on Show To Begin" useColor:[UIColor SLBlueColor]];
            _eventView.getInLineBtn.hidden = YES;
        });
    }
    if ([keyPath isEqual:@"openTokManager.startBroadcast"] && ![change[@"old"] isEqualToValue:change[@"new"]]) {
        if(_openTokManager.startBroadcast){
            dispatch_async(dispatch_get_main_queue(), ^{
                self.event.status = @"L";
                [_eventView hideNotification];
                [self startBroadcastEvent];
            });
            
        }
    }
    if ([keyPath isEqual:@"openTokManager.broadcastEnded"] && ![change[@"old"] isEqualToValue:change[@"new"]]) {
        if(_openTokManager.broadcastEnded){
            dispatch_async(dispatch_get_main_queue(), ^{
                [self performSelector:@selector(closeBroadcastEvent) withObject:nil afterDelay:15.0];
            });
        }
    }
    if ([keyPath isEqual:@"openTokManager.canJoinShow"] && ![change[@"old"] isEqualToValue:change[@"new"]]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startSession];
        });
    }
}

-(void)statusChanged {
    
    self.eventView.eventName.text = [NSString stringWithFormat:@"%@ (%@)", self.event.eventName, self.event.displayStatus];
    
    if ([self.event.status isEqualToString:@"N"]) {
        
        if (self.user.userRole != IBUserRoleFan) {
            self.eventView.eventImage.hidden = YES;
        }
        else {
            self.eventView.eventImage.hidden = NO;
            [self.eventView.eventImage loadImageWithUrl:[NSString stringWithFormat:@"%@%@", self.instance.frontendURL, self.event.image]];
            self.eventView.getInLineBtn.hidden = YES;
        }
    }
    else if([self.event.status isEqualToString:@"P"]) {
        
        if (self.user.userRole != IBUserRoleFan) {
            self.eventView.eventImage.hidden = YES;
        }
        else {
            self.eventView.eventImage.hidden = NO;
            [self.eventView.eventImage loadImageWithUrl:[NSString stringWithFormat:@"%@%@", self.instance.frontendURL, self.event.image]];
            self.eventView.getInLineBtn.hidden = NO;
        }
    }
    else if ([self.event.status isEqualToString:@"L"]) {
        
        if (_openTokManager.subscribers.count > 0) {
            self.eventView.eventImage.hidden = YES;
        }
        else{
            self.eventView.eventImage.hidden = NO;
            [self.eventView.eventImage loadImageWithUrl:[NSString stringWithFormat:@"%@%@", self.instance.frontendURL, self.event.image]];
        }
        
        if (self.user.userRole == IBUserRoleFan &&
           (self.eventStage & IBEventStageBackstage) != IBEventStageBackstage &&
           (self.eventStage & IBEventStageOnstage) != IBEventStageOnstage){
            
            self.eventView.getInLineBtn.hidden = NO;
        }
        self.eventStage |= IBEventStageLive;
        [self goLive];
    }
    else if ([self.event.status isEqualToString:@"C"]) {
        
        if (self.event.endImage) {
            [self.eventView.eventImage loadImageWithUrl:[NSString stringWithFormat:@"%@%@", self.instance.frontendURL, self.event.endImage]];
        }
        [self.eventView eventIsClosed];
        
        [_openTokManager disconnectOnstageSession];
        
        if ((self.eventStage & IBEventStageBackstage) == IBEventStageBackstage) {
            [_openTokManager disconnectBackstageSession];
        }
        [_openTokManager cleanupPublisher];
    }
}

-(void)goLive {
    NSLog(@"Event changed status to LIVE");
    self.eventStage |= IBEventStageLive;
    if(_openTokManager.hostStream && !_openTokManager.subscribers[@"host"]){
        [self doSubscribe:_openTokManager.hostStream];
    }
    
    if(_openTokManager.celebrityStream && !_openTokManager.subscribers[@"celebrity"]){
        [self doSubscribe:_openTokManager.celebrityStream];
    }
    
    if(_openTokManager.fanStream && !_openTokManager.subscribers[@"fan"]){
        [self doSubscribe:_openTokManager.fanStream];
    }
}


#pragma mark - OTChat
- (void)keyboardWillShow:(NSNotification*)aNotification
{
    NSDictionary* info = aNotification.userInfo;
    CGSize kbSize = [info[UIKeyboardFrameBeginUserInfoKey] CGRectValue].size;
    double duration = [info[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    _chatYPosition = 106 - _textChat.view.bounds.size.height ;
    [UIView animateWithDuration:duration animations:^{
        CGRect r = self.view.bounds;
        r.origin.y += _chatYPosition;
        r.size.height -= _chatYPosition + kbSize.height;
        _textChat.view.frame = r;
    }];
}

- (void)keyboardWillHide:(NSNotification*)aNotification
{
    NSDictionary* info = aNotification.userInfo;
    double duration = [info[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    _chatYPosition = self.eventView.statusBar.layer.frame.size.height + self.eventView.chatBar.layer.frame.size.height;
    
    [UIView animateWithDuration:duration animations:^{
        
        CGRect r = self.view.bounds;
        r.origin.y += _chatYPosition;
        r.size.height -= _chatYPosition;
        _textChat.view.frame = r;
    }];
}

- (BOOL)onMessageReadyToSend:(OTKChatMessage *)message {
    OTError *error = nil;
    OTSession *currentSession;
    currentSession = _openTokManager.producerSession;
    
    NSDictionary *user_message = @{@"message": message.text};
    NSDictionary *userInfo = @{@"message": user_message};
    
    [currentSession signalWithType:@"chatMessage" string:[JSON stringify:userInfo] connection: _openTokManager.producerConnection error:&error];
    if (error) {
        return NO;
    }
    return YES;
}

#pragma mark - fan Actions
- (IBAction)chatNow:(id)sender {
    [UIView animateWithDuration:0.5 animations:^() {
        [self showChatBox];
        _unreadCount = 0;
        [self.eventView.chatBtn setTitle:@"" forState:UIControlStateNormal];
    }];
}

- (IBAction)closeChat:(id)sender {
    [UIView animateWithDuration:0.5 animations:^() {
        [self hideChatBox];
        if(self.user.userRole != IBUserRoleFan){
            self.eventView.chatBtn.hidden = NO;
        }
    }];
}

- (IBAction)getInLineClick:(id)sender {
    _openTokManager.producerSession = [[OTSession alloc] initWithApiKey:_instance.apiKey
                                                              sessionId:self.instance.sessionIdProducer
                                                               delegate:self];
    [self.eventView showLoader];
    [_openTokManager connectBackstageSessionWithToken:self.instance.tokenProducer];
}

- (IBAction)leaveLine:(id)sender {
    [self.eventView fanLeaveLine];
    [self unpublishBackstage];
    [_openTokManager disconnectBackstageSession];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (IBAction)dismissInlineTxt:(id)sender {
    [self.eventView hideVideoPreview];
}

- (void)showChatBox{
    self.textChat.view.hidden = NO;
    [_eventView userIsChatting];
}

- (void)hideChatBox{
    self.textChat.view.hidden = YES;
    [_eventView hideChatBar];
}

- (IBAction)goBack:(id)sender {
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(){
        [_openTokManager disconnectBackstageSession];
        [_openTokManager disconnectOnstageSession];
    });
    
    [[UIApplication sharedApplication] setIdleTimerDisabled:NO];
    [self.presentingViewController dismissViewControllerAnimated:NO completion:nil];
}

#pragma mark - orientation
- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}
@end