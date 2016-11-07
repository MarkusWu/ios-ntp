/*╔══════════════════════════════════════════════════════════════════════════════════════════════════╗
  ║ NetworkClock.h                                                                                   ║
  ║                                                                                                  ║
  ║ Created by Gavin Eadie on Oct17/10 ... Copyright 2010-14 Ramsay Consulting. All rights reserved. ║
  ╚══════════════════════════════════════════════════════════════════════════════════════════════════╝*/

#import "NetAssociation.h"

/*┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
  ┃ The NetworkClock sends notifications of the network time.  It will attempt to provide a very     ┃
  ┃ early estimate and then refine that and reduce the number of notifications ...                   ┃
  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛*/

typedef NS_ENUM(NSInteger, NetworkClockState) {
    NetworkClockStateNotStarted,
    NetworkClockStateStarting,
    NetworkClockStateStarted,
};


@interface NetworkClock : NSObject

@property (nullable, nonatomic, readonly, copy) NSDate *networkTime;
@property (nonatomic, readonly) NSTimeInterval networkOffset;       // If not determained == INFINITY
@property (nonatomic, readonly) NetworkClockState networkClockState;

@property (nullable, nonatomic, copy) void (^networkOffsetUpdated)(NSTimeInterval networkOffset);

- (void)startWithCompletion:(nonnull void(^)(BOOL success))completion;
- (void)finish;

@end
 