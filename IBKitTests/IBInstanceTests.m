//
//  IBInstanceTests.m
//  IBDemo
//
//  Created by Xi Huang on 6/2/16.
//  Copyright © 2016 Tokbox, Inc. All rights reserved.
//

#import <Kiwi/Kiwi.h>
#import "IBInstance.h"
#import "IBInstance_Internal.h"

SPEC_BEGIN(IBInstanceTests)

context(@"IBInstanceURLTest", ^(){
    
    describe(@"A standalone IBInstance", ^(){
        
        [IBInstance configBackendURL:@"https://tokbox-ib-staging-tesla.herokuapp.com"];
        it(@"should return a valid URL", ^(){
            [[[[IBInstance sharedManager] backendURL] should] equal:@"https://tokbox-ib-staging-tesla.herokuapp.com"];
        });
    });
});

SPEC_END