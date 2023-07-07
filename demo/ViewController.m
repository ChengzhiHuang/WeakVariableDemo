//
//  ViewController.m
//  demo
//
//  Created by ByteDance on 2023/7/7.
//

#import "ViewController.h"

#import <objc/message.h>
#import <pthread/pthread.h>

extern void _class_setCustomDeallocInitiation(_Nonnull Class cls);

extern void _objc_deallocOnMainThreadHelper(void * _Nullable context);

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
}

- (void)_objc_initiateDealloc {
    if (pthread_main_np()) {
        [self performSelector:NSSelectorFromString(@"dealloc")];
    }
    else {
        dispatch_async_f(dispatch_get_main_queue(), (__bridge void * _Nullable)(self), _objc_deallocOnMainThreadHelper);
    }
}

@end

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    _class_setCustomDeallocInitiation(SampleObject.class);
    
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        __autoreleasing SampleObject *object = [[SampleObject alloc] init];
    });
}


@end
