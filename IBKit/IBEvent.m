//
//  Event.m
//  IBDemo
//
//  Created by Xi Huang on 5/26/16.
//  Copyright © 2016 Tokbox, Inc. All rights reserved.
//

#import "IBEvent.h"
#import "IBEvent_Internal.h"
#import "IBDateFormatter.h"

@interface IBEvent()
@property (nonatomic) NSString *descriptiveStatus;
@end

@implementation IBEvent

- (NSString *)descriptiveStatus {
    if (!_status) return nil;
    
    if ([_status isEqualToString:@"N"]) {
        
        if (!_startTime) return nil;
        
        if (_startTime && ![_startTime isEqual:[NSNull null]]) {
            return [IBDateFormatter convertToAppStandardFromDate:_startTime];
        }
        else{
            return @"Not Started";
        }
    }
    
    if([_status isEqualToString:@"P"]){
        return @"Not Started";
    }
    
    if([_status isEqualToString:@"L"]){
        return @"Live";
    }
    
    if([_status isEqualToString:@"C"]){
        return @"Closed";
    }
    
    return nil;
}

- (instancetype)initWithJson:(NSDictionary *)json {
    if (!json) return nil;
    
    if (self = [super init]) {
        
        if (json[@"admins_id"]) {
            _adminId = [json[@"admins_id"] integerValue];
            _adminName = json[@"admins_name"];
        }
        _celebrityURL = json[@"celebrity_url"];
        _fanURL = json[@"fan_url"];
        _hostURL = json[@"host_url"];
        
        if (json[@"date_time_start"] != [NSNull null]) {
            _startTime = [IBDateFormatter convertFromBackendDateString:json[@"date_time_start"]];
        }
        
        if (json[@"date_time_end"] != [NSNull null]) {
            _endTime = [IBDateFormatter convertFromBackendDateString:json[@"date_time_end"]];
        }
        
        if (json[@"event_image"] != [NSNull null]) {
            _image = json[@"event_image"];
        }
        
        if (json[@"event_image_end"] != [NSNull null]) {
            _endImage = json[@"event_image_end"];
        }
        
        _eventName = json[@"event_name"];
        _fanURL = json[@"fan_url"];
        _hostURL = json[@"host_url"];
        _identifier = json[@"id"];
        _status = json[@"status"];
    }
    return self;
}

- (void)updateEventWithJson:(NSDictionary *)updatedJson {
    if (!updatedJson) return;
    
    _status = updatedJson[@"newStatus"];
}

@end
