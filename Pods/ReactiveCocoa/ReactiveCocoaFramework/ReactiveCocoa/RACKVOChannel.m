//
//  RACKVOChannel.m
//  ReactiveCocoa
//
//  Created by Uri Baghin on 27/12/2012.
//  Copyright (c) 2012 GitHub, Inc. All rights reserved.
//

#ifndef LLog
#define LLogF(format, ...) NSLog(@"%s:%i: %@", __FILE__, __LINE__, [NSString stringWithFormat:format, ##__VA_ARGS__]);

#ifdef DEBUG
#define LLog(format, ...) LLogF(format, ##__VA_ARGS__);
#else
#define LLog(format, ...) while(0){}
#endif
#endif
#import "RACKVOChannel.h"
#import "RACEXTScope.h"
#import "NSObject+RACDeallocating.h"
#import "NSObject+RACDescription.h"
#import "NSObject+RACKVOWrapper.h"
#import "NSObject+RACPropertySubscribing.h"
#import "NSString+RACKeyPathUtilities.h"
#import "RACChannel.h"
#import "RACCompoundDisposable.h"
#import "RACDisposable.h"
#import "RACReplaySubject.h"
#import "RACSignal+Operations.h"
#import "RACSubscriber+Private.h"
#import "RACSubject.h"

// Key for the array of RACKVOChannel's additional thread local
// data in the thread dictionary.
static NSString * const RACKVOChannelDataDictionaryKey = @"RACKVOChannelKey";

// Wrapper class for additional thread local data.
@interface RACKVOChannelData : NSObject

// The flag used to ignore updates the channel itself has triggered.
@property (nonatomic, assign) BOOL ignoreNextUpdate;

// A pointer to the owner of the data. Only use this for pointer comparison,
// never as an object reference.
@property (nonatomic, assign) void *owner;

+ (instancetype)dataForChannel:(RACKVOChannel *)channel;

@end

@interface RACKVOChannel ()

// The object whose key path the channel is wrapping.
@property (atomic, unsafe_unretained) NSObject *target;

// The key path the channel is wrapping.
@property (nonatomic, copy, readonly) NSString *keyPath;

// Returns the existing thread local data container or nil if none exists.
@property (nonatomic, strong, readonly) RACKVOChannelData *currentThreadData;

// Creates the thread local data container for the channel.
- (void)createCurrentThreadData;

// Destroy the thread local data container for the channel.
- (void)destroyCurrentThreadData;

@end

@implementation RACKVOChannel

#pragma mark Properties

- (RACKVOChannelData *)currentThreadData {
	NSMutableArray *dataArray = NSThread.currentThread.threadDictionary[RACKVOChannelDataDictionaryKey];

	for (RACKVOChannelData *data in dataArray) {
		if (data.owner == (__bridge void *)self) return data;
	}

	return nil;
}

#pragma mark Lifecycle

- (id)initWithTarget:(NSObject *)target keyPath:(NSString *)keyPath nilValue:(id)nilValue {
	NSCParameterAssert(keyPath.rac_keyPathComponents.count > 0);

	self = [super init];
	if (self == nil) return nil;

	_target = target;
	_keyPath = [keyPath copy];

	[self.leadingTerminal setNameWithFormat:@"[-initWithTarget: %@ keyPath: %@ nilValue: %@] -leadingTerminal", target, keyPath, nilValue];
	[self.followingTerminal setNameWithFormat:@"[-initWithTarget: %@ keyPath: %@ nilValue: %@] -followingTerminal", target, keyPath, nilValue];

	// Observe the key path on target for changes and forward the changes to the
	// terminal.
	//
	// Intentionally capturing `self` strongly in the blocks below, so the
	// channel object stays alive while observing.
	RACDisposable *observationDisposable = [target rac_observeKeyPath:keyPath options:NSKeyValueObservingOptionInitial observer:nil block:^(id value, NSDictionary *change) {
		// If the change wasn't triggered by deallocation, only affects the last
		// path component, and ignoreNextUpdate is set, then it was triggered by
		// this channel and should not be forwarded.
		if (![change[RACKeyValueChangeCausedByDeallocationKey] boolValue] && [change[RACKeyValueChangeAffectedOnlyLastComponentKey] boolValue] && self.currentThreadData.ignoreNextUpdate) {
			[self destroyCurrentThreadData];
			return;
		}

		[self.leadingTerminal sendNext:value];
	}];
	
	NSString *keyPathByDeletingLastKeyPathComponent = keyPath.rac_keyPathByDeletingLastKeyPathComponent;
	NSArray *keyPathComponents = keyPath.rac_keyPathComponents;
	NSUInteger keyPathComponentsCount = keyPathComponents.count;
	NSString *lastKeyPathComponent = keyPathComponents.lastObject;

	// Update the value of the property with the values received.
	[[self.leadingTerminal
		finally:^{
			[observationDisposable dispose];
		}]
		subscribeNext:^(id x) {
			// Check the value of the second to last key path component. Since the
			// channel can only update the value of a property on an object, and not
			// update intermediate objects, it can only update the value of the whole
			// key path if this object is not nil.
			NSObject *object = (keyPathComponentsCount > 1 ? [self.target valueForKeyPath:keyPathByDeletingLastKeyPathComponent] : self.target);
			if (object == nil) return;

			// Set the ignoreNextUpdate flag before setting the value so this channel
			// ignores the value in the subsequent -didChangeValueForKey: callback.
			[self createCurrentThreadData];
			self.currentThreadData.ignoreNextUpdate = YES;

			[object setValue:x ?: nilValue forKey:lastKeyPathComponent];
		} error:^(NSError *error) {
			NSCAssert(NO, @"Received error in %@: %@", self, error);
			
			// Log the error if we're running with assertions disabled.
			LLog(@"Received error in %@: %@", self, error);
		}];
	
	// Capture `self` weakly for the target's deallocation disposable, so we can
	// freely deallocate if we complete before then.
	@weakify(self);
	
	[target.rac_deallocDisposable addDisposable:[RACDisposable disposableWithBlock:^{
		@strongify(self);
		[self.leadingTerminal sendCompleted];
		self.target = nil;
	}]];
	
	return self;
}

- (void)createCurrentThreadData {
	NSMutableArray *dataArray = NSThread.currentThread.threadDictionary[RACKVOChannelDataDictionaryKey];
	if (dataArray == nil) {
		dataArray = [NSMutableArray array];
		NSThread.currentThread.threadDictionary[RACKVOChannelDataDictionaryKey] = dataArray;
		[dataArray addObject:[RACKVOChannelData dataForChannel:self]];
		return;
	}

	for (RACKVOChannelData *data in dataArray) {
		if (data.owner == (__bridge void *)self) return;
	}

	[dataArray addObject:[RACKVOChannelData dataForChannel:self]];
}

- (void)destroyCurrentThreadData {
	NSMutableArray *dataArray = NSThread.currentThread.threadDictionary[RACKVOChannelDataDictionaryKey];
	NSUInteger index = [dataArray indexOfObjectPassingTest:^ BOOL (RACKVOChannelData *data, NSUInteger idx, BOOL *stop) {
		return data.owner == (__bridge void *)self;
	}];

	if (index != NSNotFound) [dataArray removeObjectAtIndex:index];
}

@end

@implementation RACKVOChannel (RACChannelTo)

- (RACChannelTerminal *)objectForKeyedSubscript:(NSString *)key {
	NSCParameterAssert(key != nil);

	RACChannelTerminal *terminal = [self valueForKey:key];
	NSCAssert([terminal isKindOfClass:RACChannelTerminal.class], @"Key \"%@\" does not identify a channel terminal", key);
	
	return terminal;
}

- (void)setObject:(RACChannelTerminal *)otherTerminal forKeyedSubscript:(NSString *)key {
	NSCParameterAssert(otherTerminal != nil);

	RACChannelTerminal *selfTerminal = [self objectForKeyedSubscript:key];
	[otherTerminal subscribe:selfTerminal];
	[[selfTerminal skip:1] subscribe:otherTerminal];
}

@end

@implementation RACKVOChannelData

+ (instancetype)dataForChannel:(RACKVOChannel *)channel {
	RACKVOChannelData *data = [[self alloc] init];
	data->_owner = (__bridge void *)channel;
	return data;
}

@end
