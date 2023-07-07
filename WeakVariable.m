//
//  Child.m
//  demo
//
//  Created by ByteDance on 2023/2/14.
//

#import <Foundation/Foundation.h>

static __weak id sWeakObject = nil;

@interface SampleObject : NSObject

@end

@implementation SampleObject

- (instancetype)init {
    if (self = [super init]) {
        sWeakObject = self;
        
        [self testEqual];
    }
    return self;
}

- (void)dealloc {
    [self testEqual];
}

- (void)testEqual {
    BOOL testEqual = sWeakObject == self;
    NSAssert(testEqual, @"WHY NOT EQUAL???");
}

@end
