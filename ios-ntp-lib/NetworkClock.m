/*╔══════════════════════════════════════════════════════════════════════════════════════════════════╗
  ║ NetworkClock.m                                                                                   ║
  ║                                                                                                  ║
  ║ Created by Gavin Eadie on Oct17/10 ... Copyright 2010-14 Ramsay Consulting. All rights reserved. ║
  ╚══════════════════════════════════════════════════════════════════════════════════════════════════╝*/

#import <arpa/inet.h>

#import "NetworkClock.h"
#import "ntp-log.h"
#import "GCDAsyncUdpSocket.h"

@interface NetworkClock () <NetAssociationDelegate> {
    
    NSDate *                poolIPAddressesRefreshDate;
    NSDictionary *          poolIPAddresses;
    NSMutableArray *        timeAssociations;
    NSArray *               sortDescriptors;

    NSSortDescriptor *      dispersionSortDescriptor;

}

@property (nonatomic, readwrite) NetworkClockState networkClockState;
@property (nonatomic, readwrite) NSTimeInterval networkOffset;
@property (nonatomic, strong, readonly) NSArray *defaultPoolList;

@end

#pragma mark -
#pragma mark                        N E T W O R K • C L O C K

/*┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
  ┃ NetworkClock is a singleton class which will provide the best estimate of the difference in time ┃
  ┃ between the device's system clock and the time returned by a collection of time servers.         ┃
  ┃                                                                                                  ┃
  ┃ The method <networkTime> returns an NSDate with the network time.                                ┃
  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛*/

@implementation NetworkClock


- (instancetype) init {
    if (self = [super init]) {
        /*┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
          │ Prepare a sort-descriptor to sort associations based on their dispersion, and then create an     │
          │ array of empty associations to use ...                                                           │
          └──────────────────────────────────────────────────────────────────────────────────────────────────┘*/
        sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:@"dispersion" ascending:YES]];
        timeAssociations = [NSMutableArray arrayWithCapacity:100];
        self.networkOffset = INFINITY;
    }
    
    return self;
}

/*┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
  ┃ Return the device clock time adjusted for the offset to network-derived UTC.                     ┃
  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛*/
- (NSDate *) networkTime {
    return [[NSDate date] dateByAddingTimeInterval:-[self networkOffset]];
}

/*┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
  ┃ Use the following time servers or, if it exists, read the "ntp.hosts" file from the application  ┃
  ┃ resources and derive all the IP addresses referred to, remove any duplicates and create an       ┃
  ┃ 'association' (individual host client) for each one.                                             ┃
  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛*/
- (void)startWithCompletion:(nonnull void(^)(BOOL success))completion {
    if (self.networkClockState == NetworkClockStateStarting) {
        completion(NO);
        return;
    }
    
    if (timeAssociations.count || self.networkClockState == NetworkClockStateStarted) {
        completion(YES);
        return;
    }
    
    self.networkClockState = NetworkClockStateStarting;
    
    // IP addresses must be refreshed every 1 hour as they updated in pools
    if (poolIPAddressesRefreshDate) {
        NSTimeInterval timeSinceLastRefresh = [[NSDate date] timeIntervalSinceDate:poolIPAddressesRefreshDate];
        if (timeSinceLastRefresh >= 60 * 60) { // 1 hour
            poolIPAddressesRefreshDate = nil;
            poolIPAddresses = nil;
        }
    }
    
    if (poolIPAddresses) {
        [self createNetAssosiationsWithIPAddresses:poolIPAddresses];
        self.networkClockState = NetworkClockStateStarted;
        completion(YES);
    } else {
        [self resolveHosts:[self pools] withCompletion:^(NSDictionary *IPAddresses) {
            if (IPAddresses.count) {
                poolIPAddressesRefreshDate = [NSDate date];
                poolIPAddresses = IPAddresses;
                [self createNetAssosiationsWithIPAddresses:poolIPAddresses];
                self.networkClockState = NetworkClockStateStarted;
                completion(YES);
            } else {
                self.networkClockState = NetworkClockStateNotStarted;
                completion(NO);
            }
        }];
    }
}

/*┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
  ┃ Stop all the individual ntp clients associations ..                                              ┃
  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛*/
- (void) finish {
    [timeAssociations makeObjectsPerformSelector:@selector(finish)];
    [timeAssociations removeAllObjects];
    self.networkClockState = NetworkClockStateNotStarted;
}

#pragma mark - Private methods

- (void)createNetAssosiationsWithIPAddresses:(NSDictionary *)IPAddresses
{
    for (NSString *IPAddress in IPAddresses) {
        NetAssociation *timeAssociation = [[NetAssociation alloc] initWithServerPool:IPAddresses[IPAddress] IPAddress:IPAddress];
        timeAssociation.delegate = self;
        [timeAssociations addObject:timeAssociation];
        [timeAssociation enable];                               // starts are randomized internally
    }
}

- (void) resolveHosts:(NSArray<NSString*>*)hosts withCompletion:(void(^)(NSDictionary *IPAddresses))completion{
    NSMutableDictionary *hostAddresses = [NSMutableDictionary dictionaryWithCapacity:100];
    
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        for (NSString * ntpDomainName in hosts) {
            if ([ntpDomainName length] == 0 ||
                [ntpDomainName characterAtIndex:0] == ' ' ||
                [ntpDomainName characterAtIndex:0] == '#') {
                continue;
            }
            
            /*┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
              │  ... resolve the IP address of the named host : "0.pool.ntp.org" --> [123.45.67.89], ...         │
              └──────────────────────────────────────────────────────────────────────────────────────────────────┘*/
            CFHostRef ntpHostName = CFHostCreateWithName (nil, (__bridge CFStringRef)ntpDomainName);
            if (nil == ntpHostName) {
                NTP_Logging(@"CFHostCreateWithName <nil> for %@", ntpDomainName);
                continue;                                           // couldn't create 'host object' ...
            }
            
            CFStreamError   nameError;
            if (!CFHostStartInfoResolution (ntpHostName, kCFHostAddresses, &nameError)) {
                NTP_Logging(@"CFHostStartInfoResolution error %i for %@", (int)nameError.error, ntpDomainName);
                CFRelease(ntpHostName);
                continue;                                           // couldn't start resolution ...
            }
            
            Boolean         nameFound;
            CFArrayRef      ntpHostAddrs = CFHostGetAddressing (ntpHostName, &nameFound);
            
            if (!nameFound) {
                NTP_Logging(@"CFHostGetAddressing: %@ NOT resolved", ntpHostName);
                CFRelease(ntpHostName);
                continue;                                           // resolution failed ...
            }
            
            if (ntpHostAddrs == nil) {
                NTP_Logging(@"CFHostGetAddressing: no addresses resolved for %@", ntpHostName);
                CFRelease(ntpHostName);
                continue;                                           // NO addresses were resolved ...
            }
            /*┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
              │  for each (sockaddr structure wrapped by a CFDataRef/NSData *) associated with the hostname,     │
              │  drop the IP address string into a Set to remove duplicates.                                     │
              └──────────────────────────────────────────────────────────────────────────────────────────────────┘*/
            for (NSData * ntpHost in (__bridge NSArray *)ntpHostAddrs) {
                NSString *IPAddress = [GCDAsyncUdpSocket hostFromAddress:ntpHost];
                hostAddresses[IPAddress] = ntpDomainName;
            }
            
            CFRelease(ntpHostName);
        }
        
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(hostAddresses);
            });
        }
    });
}

- (NSArray<NSString*> *) pools {
    NSArray *ntpDomains;
    NSString *filePath = [[NSBundle mainBundle] pathForResource:@"ntp.hosts" ofType:@""];
    if (nil == filePath) {
        ntpDomains = self.defaultPoolList;
    } else {
        NSString *      fileData = [[NSString alloc] initWithData:[[NSFileManager defaultManager]
                                                                   contentsAtPath:filePath]
                                                         encoding:NSUTF8StringEncoding];
        
        ntpDomains = [fileData componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    }
    
    return ntpDomains;
}

- (NSArray *)defaultPoolList {
    static NSArray *defaultPoolList;
    if (defaultPoolList == nil) {
        defaultPoolList = @[@"0.pool.ntp.org",
                            @"0.uk.pool.ntp.org",
                            @"0.us.pool.ntp.org",
                            @"asia.pool.ntp.org",
                            @"europe.pool.ntp.org",
                            @"north-america.pool.ntp.org",
                            @"south-america.pool.ntp.org",
                            @"oceania.pool.ntp.org",
                            @"africa.pool.ntp.org"];
    }
    
    return defaultPoolList;
}

#pragma mark - NetAssosiation Delegate

- (void)netAssociationDidUpdateState:(NetAssociation *)sender {
    NSTimeInterval newOffset = INFINITY;
    NSTimeInterval oldValue = self.networkOffset;
    
    if ([timeAssociations count] > 0) {
        NSArray *sortedArray = [timeAssociations sortedArrayUsingDescriptors:sortDescriptors];
        
        double timeInterval = 0.0;
        short usefulCount = 0;

        for (NetAssociation * timeAssociation in sortedArray) {
            if (timeAssociation.active) {
                if (timeAssociation.trusty) {
                    usefulCount++;
                    timeInterval = timeInterval + timeAssociation.offset;
                } else {
                    if ([timeAssociations count] > 8) {
                        //NSLog(@"Clock•Drop: [%@]", timeAssociation.serverIPAddress);
                        timeAssociation.delegate = nil;
                        [timeAssociation finish];
                        [timeAssociations removeObject:timeAssociation];
                    }
                }
                
                if (usefulCount == 8) break;                // use 8 best dispersions
            }
        }
        
        if (usefulCount > 0) {
            newOffset = timeInterval / usefulCount;
        }
    }
    
    if (oldValue != newOffset) {
        self.networkOffset = newOffset;
        if (self.networkOffsetUpdated) {
            self.networkOffsetUpdated(newOffset);
        }
    }
}

@end
