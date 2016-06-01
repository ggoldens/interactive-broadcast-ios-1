//
//  OpenTokNetworkTest.h
//  IBDemo
//
//  Created by Andrea Phillips on 6/1/16.
//  Copyright © 2016 Tokbox, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface OpenTokNetworkTest : NSObject
@property (nonatomic) double prevVideoTimestamp;
@property (nonatomic) double prevVideoBytes;
@property (nonatomic) double prevAudioTimestamp;
@property (nonatomic) double prevAudioBytes;
@property (nonatomic) uint64_t prevVideoPacketsLost;
@property (nonatomic) uint64_t prevVideoPacketsRcvd;
@property (nonatomic) uint64_t prevAudioPacketsLost;
@property (nonatomic) uint64_t prevAudioPacketsRcvd;
@property (nonatomic) long video_bw;
@property (nonatomic) long audio_bw;
@property (nonatomic) double video_pl_ratio;
@property (nonatomic) double audio_pl_ratio;
@property (nonatomic) NSString *frameRate;
@property (nonatomic) NSString *resolution;
@end
