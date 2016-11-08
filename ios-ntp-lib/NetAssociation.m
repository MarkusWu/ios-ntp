/*╔══════════════════════════════════════════════════════════════════════════════════════════════════╗
  ║ NetAssociation.m                                                                                 ║
  ║                                                                                                  ║
  ║ Created by Gavin Eadie on Nov03/10 ... Copyright 2010-15 Ramsay Consulting. All rights reserved. ║
  ╚══════════════════════════════════════════════════════════════════════════════════════════════════╝*/

#import "NetAssociation.h"
#import "ntp-log.h"

#import <sys/time.h>



/*┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
 │  NTP Timestamp Structure                                                                         │
 │                                                                                                  │
 │   0                   1                   2                   3                                  │
 │   0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1                                │
 │  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+                               │
 │  |  Seconds                                                      |                               │
 │  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+                               │
 │  |  Seconds Fraction (0-padded)  |       |       |       |       | <-- 4294967296 = 1 second     │
 │  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+                               │
 │                  |               |       |   |   |               |                               │
 │                  |               |       |   |   |              233 picoseconds                  │
 │                  |               |       |   | 59.6 nanoseconds (mask = 0xffffff00)              │
 │                  |               |       |  238 nanoseconds (mask = 0xfffffc00)                  │
 │                  |               |      0.954 microsecond (mask = 0xfffff000)                    │
 │                  |             15.3 microseconds (mask = 0xffff0000)                             │
 │                 3.9 milliseconds (mask = 0xff000000)                                             │
 │                                                                                                  │
 │                                                                                                  │
 └──────────────────────────────────────────────────────────────────────────────────────────────────┘*/

static const uint8_t kFifoQueueSize = 8;

#define JAN_1970    		((uint64_t)0x83aa7e80)          // UNIX epoch in NTP's epoch:
// 1970-1900 (2,208,988,800s)

union ntpTime {
    
    struct {
        uint32_t    fractSeconds;
        uint32_t    wholeSeconds;
    }           partials;
    
    uint64_t    floating;
    
} ;


#pragma -
#pragma mark                        T i m e • C o n v e r t e r s

static union ntpTime NTP_1970 = {0, JAN_1970};              // network time for 1 January 1970, GMT

static double pollIntervals[18] = {
      2.0,   16.0,   16.0,   16.0,   16.0,    35.0,    72.0,  127.0,     258.0,
    511.0, 1024.0, 2048.0, 4096.0, 8192.0, 16384.0, 32768.0, 65536.0, 131072.0
};

/*┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ Convert from Unix time to NTP time                                                               │
  │     (on MacOSX clock resolution is 1μS, so ntp's ~12 low bits are meaningless)                   │
  └──────────────────────────────────────────────────────────────────────────────────────────────────┘*/
union ntpTime unix2ntp(const struct timeval * tv) {
    union ntpTime   ntp1;

    ntp1.partials.wholeSeconds = (uint32_t)(tv->tv_sec + JAN_1970);
    ntp1.partials.fractSeconds = (uint32_t)((double)tv->tv_usec * (1LL<<32) * 1.0e-6);
    return ntp1;
}

/*┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ get current time in NTP format                                                                   │
  └──────────────────────────────────────────────────────────────────────────────────────────────────┘*/
union ntpTime ntp_time_now() {
    struct timeval      now;
    gettimeofday(&now, (struct timezone *)NULL);
    return unix2ntp(&now);
}

/*┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ get (ntpTime2 - ntpTime1) in (double) seconds                                                    │
  └──────────────────────────────────────────────────────────────────────────────────────────────────┘*/
double ntpDiffSeconds(union ntpTime * start, union ntpTime * stop) {
    int32_t         a;
    uint32_t        b;
    a = stop->partials.wholeSeconds - start->partials.wholeSeconds;
    if (stop->partials.fractSeconds >= start->partials.fractSeconds) {
        b = stop->partials.fractSeconds - start->partials.fractSeconds;
    }
    else {
        b = start->partials.fractSeconds - stop->partials.fractSeconds;
        b = ~b;
        a -= 1;
    }
    
    return a + b / 4294967296.0;
}

/*┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
  ┃ NetAssociation: Private Variables                                                                ┃
  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛*/
@interface NetAssociation () <GCDAsyncUdpSocketDelegate> {

    GCDAsyncUdpSocket *     socket;                         // NetAssociation UDP Socket

    dispatch_queue_t        workingQueue;
    NSTimer *               queryTimer;                     // fires off an ntp request ...
    int                     pollingIntervalIndex;           // index into polling interval table
    
    union ntpTime           ntpClientSendTime,
                            ntpServerRecvTime,
                            ntpServerSendTime,
                            ntpClientRecvTime,
                            ntpServerBaseTime;

    int                     li, vn, mode, stratum, poll, prec, refid;

    double                  fifoQueue[kFifoQueueSize];
    short                   fifoIndex;

}

@property (readonly) double root_delay;                     // milliSeconds
@property (readonly) double roundtrip;                      // seconds
@property (readonly) double serverDelay;                    // seconds

@end

#pragma mark -
#pragma mark                        N E T W O R K • A S S O C I A T I O N

@implementation NetAssociation

/*┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
  ┃ Initialize the association with a blank socket and prepare the time transaction to happen every  ┃
  ┃ 16 seconds (initial value) ...                                                                   ┃
  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛*/
- (instancetype) initWithServerPool:(NSString *)pool IPAddress:(NSString *) serverIPAddress {
    if (self = [super init]) {
/*┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ Set initial/default values for instance variables ...                                            │
  └──────────────────────────────────────────────────────────────────────────────────────────────────┘*/
        pollingIntervalIndex = 0;                           // ensure the first timer firing is soon
        _active = FALSE;                                    // isn't running till it reports time ...
        _trusty = FALSE;                                    // don't trust this clock to start with ...
        _offset = INFINITY;                                 // start with net clock meaningless
        _serverIPAddress = [serverIPAddress copy];
        _pool = pool;
        _timeDeviationDrift = 0.025;
        
/*┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ Create a UDP socket that will communicate with the time server and set its delegate ...          │
  └──────────────────────────────────────────────────────────────────────────────────────────────────┘*/
        workingQueue = dispatch_queue_create([_serverIPAddress cStringUsingEncoding:NSUTF8StringEncoding], DISPATCH_QUEUE_SERIAL);
        socket = [[GCDAsyncUdpSocket alloc] initWithDelegate:self delegateQueue:workingQueue];
    }

    return self;
}

- (void)dealloc {
    socket.delegate = nil;
    [socket close];
}

/*┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
  ┃ This sets the association in a mode where it repeatedly gets time from its server and performs   ┃
  ┃ statical check and averages on these multiple values to provide a more accurate time.            ┃
  ┃ starts the timer firing (sets the fire time randonly within the next five seconds) ...           ┃
  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛*/
- (void) enable {
    dispatch_async(workingQueue, ^{
        [self cleanupFIFOQueue];
    });
    
    [self startQueryTimer];

    pollingIntervalIndex = 4;                           // subsequent timers fire at default intervals
}

/*┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
  ┃ Set the receiver and send the time query with 2 second timeout, ...                              ┃
  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛*/
- (void) queryTimeServer {
    __weak typeof(self) weakSelf = self;
    
    [queryTimer invalidate];
    queryTimer = nil;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf sendTimeQuery];
            [strongSelf startQueryTimer];
        }
    });
}

/*┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ Put some wobble into the repeating time so they don't synchronize and thump the network          │
  └──────────────────────────────────────────────────────────────────────────────────────────────────┘*/
- (void)startQueryTimer {
    NSTimeInterval timerWobbleFactor = ((float)rand()/(float)RAND_MAX / 2.0) + 0.75;       // 0.75 .. 1.25
    NSTimeInterval interval = pollIntervals[pollingIntervalIndex] * timerWobbleFactor;
    
    queryTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                  target:self
                                                selector:@selector(queryTimeServer)
                                                userInfo:nil
                                                 repeats:NO];
                  
    queryTimer.tolerance = 1.0;                     // it can be up to 1 second late
}

/*┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
  ┃                                                                 ...                              ┃
  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛*/
- (void) sendTimeQuery {
    dispatch_async(workingQueue, ^{
        NSError *   error = nil;
        
        [socket sendData:[self createPacket] toHost:_serverIPAddress port:123 withTimeout:2.0 tag:0];
        
        if(![socket beginReceiving:&error]) {
            NTP_Logging(@"Unable to start listening on socket for [%@] due to error [%@]", _serverIPAddress, error);
            return;
        }
    });
}

/*┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
  ┃ This stops the timer firing (sets the fire time to the infinite future) ...                      ┃
  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛*/
- (void) finish {
    dispatch_sync(workingQueue, ^{
        [socket close];
        
        [self cleanupFIFOQueue];
        
        _active = FALSE;
        _trusty = FALSE;
        _offset = INFINITY;
    });
    
    [queryTimer invalidate];
    queryTimer = nil;
}

- (void)cleanupFIFOQueue {
    for (short i = 0; i < kFifoQueueSize; i++) fifoQueue[i] = NAN;      // set fifo to all empty
    fifoIndex = 0;
}

/*┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
  ┃ Make an NSDate from ntpTimestamp ... (via seconds from JAN_1970) ...                             ┃
  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛*/
- (NSDate *) dateFromNetworkTime:(union ntpTime *) networkTime {
    return [NSDate dateWithTimeIntervalSince1970:ntpDiffSeconds(&NTP_1970, networkTime)];
}


#pragma mark                        N e t w o r k • T r a n s a c t i o n s

/*┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
  │      Create a time query packet ...                                                              │
  │──────────────────────────────────────────────────────────────────────────────────────────────────│
  │                                                                                                  │
  │                               1                   2                   3                          │
  │           0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1                        │
  │          +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+                       │
  │     [ 0] | L | Ver |Mode |    Stratum    |     Poll      |   Precision   |                       │
  │          +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+                       │
  │     [ 1] |                        Root  Delay (32)                       | in NTP short format   │
  │          +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+                       │
  │     [ 2] |                     Root  Dispersion (32)                     | in NTP short format   │
  │          +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+                       │
  │     [ 3] |                     Reference Identifier                      |                       │
  │          +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+                       │
  │     [ 4] |                                                               |                       │
  │          |                    Reference Timestamp (64)                   | in NTP long format    │
  │     [ 5] |                                                               |                       │
  │          +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+                       │
  │     [ 6] |                                                               |                       │
  │          |                    Originate Timestamp (64)                   | in NTP long format    │
  │     [ 7] |                                                               |                       │
  │          +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+                       │
  │     [ 8] |                                                               |                       │
  │          |                     Receive Timestamp (64)                    | in NTP long format    │
  │     [ 9] |                                                               |                       │
  │          +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+                       │
  │     [10] |                                                               |                       │
  │          |                     Transmit Timestamp (64)                   | in NTP long format    │
  │     [11] |                                                               |                       │
  │                                                                                                  │
  └──────────────────────────────────────────────────────────────────────────────────────────────────┘*/

- (NSData *) createPacket {
	uint32_t        wireData[12];

	memset(wireData, 0, sizeof wireData);
	wireData[0] = htonl((0 << 30) |                                         // no Leap Indicator
                        (4 << 27) |                                         // NTP v4
                        (3 << 24) |                                         // mode = client sending
                        (0 << 16) |                                         // stratum (n/a)
                        (4 << 8)  |                                         // polling rate (16 secs)
                        (-6 & 0xff));                                       // precision (~15 mSecs)
	wireData[1] = htonl(1<<16);
	wireData[2] = htonl(1<<16);

    ntpClientSendTime = ntp_time_now();

    wireData[10] = htonl(ntpClientSendTime.partials.wholeSeconds);                   // Transmit Timestamp
	wireData[11] = htonl(ntpClientSendTime.partials.fractSeconds);

    return [NSData dataWithBytes:wireData length:48];
}

- (void) decodePacket:(NSData *) data {
    uint32_t        wireData[12];
    [data getBytes:wireData length:48];

	li      = ntohl(wireData[0]) >> 30 & 0x03;
	vn      = ntohl(wireData[0]) >> 27 & 0x07;
	mode    = ntohl(wireData[0]) >> 24 & 0x07;
	stratum = ntohl(wireData[0]) >> 16 & 0xff;
/*┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
  │  Poll: 8-bit signed integer representing the maximum interval between successive messages,       │
  │  in log2 seconds.  Suggested default limits for minimum and maximum poll intervals are 6 and 10. │
  └──────────────────────────────────────────────────────────────────────────────────────────────────┘*/
    poll    = ntohl(wireData[0]) >>  8 & 0xff;
/*┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
  │  Precision: 8-bit signed integer representing the precision of the system clock, in log2 seconds.│
  │  (-10 corresponds to about 1 millisecond, -20 to about 1 microSecond)                            │
  └──────────────────────────────────────────────────────────────────────────────────────────────────┘*/
    prec    = ntohl(wireData[0])       & 0xff;
    if (prec & 0x80) prec |= 0xffffff00;                                // -ve byte --> -ve int

    _root_delay = ntohl(wireData[1]) * 0.0152587890625;                 // delay (mS) [1000.0/2**16].
    _dispersion = ntohl(wireData[2]) * 0.0152587890625;                 // error (mS)

    refid   = ntohl(wireData[3]);

    ntpServerBaseTime.partials.wholeSeconds = ntohl(wireData[4]);                // when server clock was wound
    ntpServerBaseTime.partials.fractSeconds = ntohl(wireData[5]);

/*┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
  │  if the send time in the packet isn't the same as the remembered send time, ditch it ...         │
  └──────────────────────────────────────────────────────────────────────────────────────────────────┘*/
    if (ntpClientSendTime.partials.wholeSeconds != ntohl(wireData[6]) ||
        ntpClientSendTime.partials.fractSeconds != ntohl(wireData[7])) return;   //  NO;

    ntpServerRecvTime.partials.wholeSeconds = ntohl(wireData[8]);
    ntpServerRecvTime.partials.fractSeconds = ntohl(wireData[9]);
    ntpServerSendTime.partials.wholeSeconds = ntohl(wireData[10]);
    ntpServerSendTime.partials.fractSeconds = ntohl(wireData[11]);

//  NTP_Logging(@"%@", [self prettyPrintPacket]);

/*┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ determine the quality of this particular time ..                                                 │
  │ .. if max_error is less than 50mS (and not zero) AND                                             │
  │ .. stratum > 0 AND                                                                               │
  │ .. the mode is 4 (packet came from server) AND                                                   │
  │ .. the server clock was set less than 1 hour ago                                                 │
  └──────────────────────────────────────────────────────────────────────────────────────────────────┘*/
    double offset = INFINITY;                                                 // clock meaningless
    if ((_dispersion < 50.0 && _dispersion > 0.00001) &&
        (stratum > 0) && (mode == 4) &&
        (ntpDiffSeconds(&ntpServerBaseTime, &ntpServerSendTime) < 3600.0))
    {
        double  t41 = ntpDiffSeconds(&ntpClientSendTime, &ntpClientRecvTime);   // .. (T4-T1)
        double  t32 = ntpDiffSeconds(&ntpServerRecvTime, &ntpServerSendTime);   // .. (T3-T2)

        _roundtrip  = t41 - t32;

        double  t21 = ntpDiffSeconds(&ntpServerSendTime, &ntpClientRecvTime);   // .. (T2-T1)
        double  t34 = ntpDiffSeconds(&ntpServerRecvTime, &ntpClientSendTime);   // .. (T3-T4)

        offset = (t21 + t34) / 2.0;                                     // calculate offset

//      NSLog(@"t21=%.6f t34=%.6f delta=%.6f offset=%.6f", t21, t34, _roundtrip, _offset);
        _active = TRUE;

//      NTP_Logging(@"%@", [self prettyPrintTimersWithOffset:offset]);
    } else {
        //NSLog(@"PACKET FAIL %@", _serverIPAddress);
    }
    
    [self handleNewOffset:offset];
}

- (void) handleNewOffset:(double)offset {
/*┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ the packet is trustworthy -- compute and store offset in kFifoQueueSize-slot fifo ...                         │
  └──────────────────────────────────────────────────────────────────────────────────────────────────┘*/

    fifoQueue[fifoIndex++ % kFifoQueueSize] = offset;                            // store offset in seconds
    fifoIndex %= kFifoQueueSize;                                                 // rotate index in range

/*┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ look at the (up to eight) offsets in the fifo and and count 'good', 'fail' and 'not used yet'    │
  └──────────────────────────────────────────────────────────────────────────────────────────────────┘*/
    short good = 0, fail = 0, none = 0;
    double offsetSum = 0.0;                                     // reset for averaging

    for (short i = 0; i < kFifoQueueSize; i++) {
        if (isnan(fifoQueue[i])) {                                  // fifo slot is unused
            none++;
            continue;
        }
        if (isinf(fifoQueue[i]) || fabs(fifoQueue[i]) < 0.0001) {   // server can't be trusted
            fail++;
            continue;
        }

        good++;
        offsetSum += fifoQueue[i];                             // accumulate good times
    }

/*┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
  │   .. if we have at least one 'good' server response or four or more 'fail' responses, we'll      │
  │      inform our management accordingly.  If we have less than four 'fails' we won't make any     │
  │      note of that ... we won't condemn a server until we get four 'fail' packets.                │
  └──────────────────────────────────────────────────────────────────────────────────────────────────┘*/
    double averageOffset = _offset;
    double stdDev = 0.0;
    BOOL shouldNotify = NO;
    
    if (good > 0 || fail > 3) {
        shouldNotify = YES;
        averageOffset = offsetSum / good;                     // average good times

        for (short i = 0; i < kFifoQueueSize; i++) {
            if (isnan(fifoQueue[i])) continue;

            if (isinf(fifoQueue[i]) || fabs(fifoQueue[i]) < 0.001) continue;

            stdDev += pow(fifoQueue[i] - averageOffset, 2.0);
        }
        stdDev = sqrt(stdDev/(float)good);
            
        _trusty = (good+none > 4) &&                                // four or more 'fails'
                  (stdDev <= _timeDeviationDrift);                  // s.d. <= Deviation Drift

        NTP_Logging(@"  [%@:%@] {%3.1f,%3.1f,%3.1f,%3.1f,%3.1f,%3.1f,%3.1f,%3.1f} ↑=%i, ↓=%i, %3.1f(%3.1f) %@", _pool, _serverIPAddress,
                    fifoQueue[0]*1000.0, fifoQueue[1]*1000.0, fifoQueue[2]*1000.0, fifoQueue[3]*1000.0,
                    fifoQueue[4]*1000.0, fifoQueue[5]*1000.0, fifoQueue[6]*1000.0, fifoQueue[7]*1000.0,
                    good, fail, averageOffset*1000.0, stdDev*1000.0, _trusty ? @"↑" : @"↓");

    }

/*┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
  │   .. if the association is providing times which don't vary much, we could increase its polling  │
  │      interval.  In practice, once things settle down, the standard deviation on any time server  │
  │      seems to fall in the 70-120mS range (plenty close for our work).  We usually pick up a few  │
  │      stratum=1 servers, it would be a Good Thing to not hammer those so hard ...                 │
  └──────────────────────────────────────────────────────────────────────────────────────────────────┘*/
    if ((stratum == 1 && pollingIntervalIndex != 6) ||
        (stratum == 2 && pollingIntervalIndex != 5))
    {
        pollingIntervalIndex = 7 - stratum;
    }
    
    if (shouldNotify && _active) {
        dispatch_async(dispatch_get_main_queue(), ^{
            _offset = averageOffset;
            [self.delegate netAssociationDidUpdateState:self];
        });
    }
}

#pragma mark                        N e t w o r k • C a l l b a c k s

- (void)udpSocket:(GCDAsyncUdpSocket *)sock didConnectToAddress:(NSData *)address {
    NTP_Logging(@"didConnectToAddress");
}

- (void)udpSocket:(GCDAsyncUdpSocket *)sock didNotConnect:(NSError *)error {
    NTP_Logging(@"didNotConnect - %@", error.description);
}

- (void)udpSocket:(GCDAsyncUdpSocket *)sock didSendDataWithTag:(long)tag {
}

- (void)udpSocket:(GCDAsyncUdpSocket *)sock didNotSendDataWithTag:(long)tag dueToError:(NSError *)error {
    NTP_Logging(@"didNotSendDataWithTag - %@", error.description);
}

- (void)udpSocket:(GCDAsyncUdpSocket *)sock didReceiveData:(NSData *)data
      fromAddress:(NSData *)address withFilterContext:(id)filterContext {
//  NTP_Logging(@"didReceiveData - [%@]", [GCDAsyncUdpSocket hostFromAddress:address]);

    /*┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
      │  grab the packet arrival time as fast as possible, before computations below ...                 │
      └──────────────────────────────────────────────────────────────────────────────────────────────────┘*/
    ntpClientRecvTime = ntp_time_now();

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf) {
            dispatch_async(workingQueue, ^{
                [strongSelf decodePacket:data];
            });
        }
    });
}

- (void)udpSocketDidClose:(GCDAsyncUdpSocket *)sock withError:(NSError *)error {
    NTP_Logging(@"Socket closed : [%@]", _serverIPAddress);
}

#pragma mark                        P r e t t y P r i n t e r s

- (NSString *) prettyPrintPacket {
    NSMutableString *   prettyString = [NSMutableString stringWithFormat:@"prettyPrintPacket\n\n"];

    [prettyString appendFormat:@"  leap indicator: %3d\n  version number: %3d\n"
                                "   protocol mode: %3d\n         stratum: %3d\n"
                                "   poll interval: %3d\n"
                                "   precision exp: %3d\n\n", li, vn, mode, stratum, poll, prec];

    [prettyString appendFormat:@"      root delay: %7.3f (mS)\n"
                                "      dispersion: %7.3f (mS)\n\n", _root_delay, _dispersion];

    [prettyString appendFormat:@"client send time: %010u.%06d (%@)\n",
                        ntpClientSendTime.partials.wholeSeconds,
                        (uint32_t)((double)ntpClientSendTime.partials.fractSeconds / (1LL<<32) * 1.0e6),
                        [self dateFromNetworkTime:&ntpClientSendTime]];

    [prettyString appendFormat:@"server recv time: %010u.%06d (%@)\n",
                        ntpServerRecvTime.partials.wholeSeconds,
                        (uint32_t)((double)ntpServerRecvTime.partials.fractSeconds / (1LL<<32) * 1.0e6),
                        [self dateFromNetworkTime:&ntpServerRecvTime]];

    [prettyString appendFormat:@"server send time: %010u.%06d (%@)\n",
                        ntpServerSendTime.partials.wholeSeconds,
                        (uint32_t)((double)ntpServerSendTime.partials.fractSeconds / (1LL<<32) * 1.0e6),
                        [self dateFromNetworkTime:&ntpServerSendTime]];

    [prettyString appendFormat:@"client recv time: %010u.%06d (%@)\n\n",
                        ntpClientRecvTime.partials.wholeSeconds,
                        (uint32_t)((double)ntpClientRecvTime.partials.fractSeconds / (1LL<<32) * 1.0e6),
                        [self dateFromNetworkTime:&ntpClientRecvTime]];

    [prettyString appendFormat:@"server clock set: %010u.%06d (%@)\n\n",
                        ntpServerBaseTime.partials.wholeSeconds,
                        (uint32_t)((double)ntpServerBaseTime.partials.fractSeconds / (1LL<<32) * 1.0e6),
                        [self dateFromNetworkTime:&ntpServerBaseTime]];

    return prettyString;
}

- (NSString *) prettyPrintTimersWithOffset:(double)offset {
    NSMutableString *   prettyString = [NSMutableString stringWithFormat:@"prettyPrintTimers\n\n"];

    [prettyString appendFormat:@"time server addr: [%@]\n"
                                " round trip time: %7.3f (mS)\n"
                                "    clock offset: %7.3f (mS)\n\n",
          _serverIPAddress, _roundtrip * 1000.0, offset * 1000.0];

    return prettyString;
}

- (NSString *) description {
    return [NSString stringWithFormat:@"%@ [%@:%@] stratum=%i; offset=%3.1f±%3.1fmS",
            _trusty ? @"↑" : @"↓", _pool, _serverIPAddress, stratum, _offset, _dispersion];
}

@end
