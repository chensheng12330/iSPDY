#import <CoreFoundation/CFStream.h>
#import <dispatch/dispatch.h>  // dispatch_queue_t
#import <string.h>  // memmove

#import "ispdy.h"
#import "compressor.h"  // ISpdyCompressor
#import "framer.h"  // ISpdyFramer
#import "loop.h"  // ISpdyLoop
#import "parser.h"  // ISpdyParser

static const NSInteger kInitialWindowSize = 65536;

@implementation ISpdy {
  ISpdyVersion version_;
  NSInputStream* in_stream_;
  NSOutputStream* out_stream_;
  ISpdyCompressor* comp_;
  ISpdyFramer* framer_;
  ISpdyParser* parser_;

  // Run loop
  BOOL on_ispdy_loop_;
  NSMutableSet* scheduled_loops_;

  // Next stream's id
  uint32_t stream_id_;
  NSInteger initial_window_;

  // Dictionary of all streams
  NSMutableDictionary* streams_;

  // Connection write buffer
  NSMutableData* buffer_;

  // Dispatch queue for invoking methods on delegates
  dispatch_queue_t delegate_queue_;

  // Dispatch queue for invoking methods on parser loop
  dispatch_queue_t connection_queue_;
}

- (id) init: (ISpdyVersion) version
       host: (NSString*) host
       port: (UInt32) port
     secure: (BOOL) secure {
  self = [super init];
  if (!self)
    return self;

  version_ = version;
  comp_ = [[ISpdyCompressor alloc] init: version];
  framer_ = [[ISpdyFramer alloc] init: version compressor: comp_];
  parser_ = [[ISpdyParser alloc] init: version compressor: comp_];
  [parser_ setDelegate: self];

  stream_id_ = 1;
  initial_window_ = kInitialWindowSize;

  streams_ = [[NSMutableDictionary alloc] initWithCapacity: 100];

  buffer_ = [[NSMutableData alloc] initWithCapacity: 4096];

  // Initialize storage for loops
  scheduled_loops_ = [NSMutableSet setWithCapacity: 1];

  // Initialize connection
  CFReadStreamRef cf_in_stream;
  CFWriteStreamRef cf_out_stream;

  CFStreamCreatePairWithSocketToHost(
      NULL,
      (__bridge CFStringRef) host,
      port,
      &cf_in_stream,
      &cf_out_stream);

  in_stream_ = (NSInputStream*) CFBridgingRelease(cf_in_stream);
  out_stream_ = (NSOutputStream*) CFBridgingRelease(cf_out_stream);

  if (in_stream_ == nil || out_stream_ == nil) {
    in_stream_ = nil;
    out_stream_ = nil;
    return nil;
  }

  [in_stream_ setDelegate: self];
  [out_stream_ setDelegate: self];

  // Initialize encryption
  if (secure) {
    [in_stream_ setProperty: NSStreamSocketSecurityLevelNegotiatedSSL
                     forKey: NSStreamSocketSecurityLevelKey];
    [out_stream_ setProperty: NSStreamSocketSecurityLevelNegotiatedSSL
                      forKey: NSStreamSocketSecurityLevelKey];
  }

  // Initialize dispatch queue
  delegate_queue_ = dispatch_get_main_queue();
  NSAssert(delegate_queue_ != NULL, @"Failed to get main queue");
  connection_queue_ = dispatch_queue_create("com.voxer.ispdy",
                                            DISPATCH_QUEUE_SERIAL);
  NSAssert(connection_queue_ != NULL, @"Failed to get main queue");


  return self;
}


- (void) dealloc {
  [self close];
  if (on_ispdy_loop_) {
    [self removeFromRunLoop: [ISpdyLoop defaultLoop]
                    forMode: NSDefaultRunLoopMode];
  }

  NSError* err = [NSError errorWithDomain: @"spdy"
                                     code: kISpdyErrDealloc
                                 userInfo: nil];
  [self _closeStreams: err];

  delegate_queue_ = NULL;
  connection_queue_ = NULL;
}


- (void) scheduleInRunLoop: (NSRunLoop*) loop forMode: (NSString*) mode {
  [scheduled_loops_ addObject: loop];

  [in_stream_ scheduleInRunLoop: loop forMode: mode];
  [out_stream_ scheduleInRunLoop: loop forMode: mode];
}


- (void) removeFromRunLoop: (NSRunLoop*) loop forMode: (NSString*) mode {
  [scheduled_loops_ removeObject: loop];

  [in_stream_ removeFromRunLoop: loop forMode: mode];
  [out_stream_ removeFromRunLoop: loop forMode: mode];
}


- (void) setDelegateQueue: (dispatch_queue_t) queue {
  NSAssert(queue != NULL, @"Empty delegate queue!");
  delegate_queue_ = queue;
}


- (void) _delegateDispatch: (void (^)()) block {
  dispatch_async(delegate_queue_, block);
}


- (void) _connectionDispatch: (void (^)()) block {
  dispatch_async(connection_queue_, block);
}


- (BOOL) connect {
  /* Use default (off-thread) NS loop, if no was provided by user */
  if ([scheduled_loops_ count] == 0) {
    on_ispdy_loop_ = YES;
    [self scheduleInRunLoop: [ISpdyLoop defaultLoop]
                    forMode: NSDefaultRunLoopMode];
  }

  [in_stream_ open];
  [out_stream_ open];

  // Send initial window
  if (version_ != kISpdyV2) {
    [framer_ clear];
    [framer_ initialWindow: kInitialWindowSize];
    [self _writeRaw: [framer_ output]];
  }

  return YES;
}


- (BOOL) close {
  if (in_stream_ == nil || out_stream_ == nil)
    return NO;

  [in_stream_ close];
  [out_stream_ close];
  in_stream_ = nil;
  out_stream_ = nil;

  return YES;
}


- (void) _writeRaw: (NSData*) data {
  NSStreamStatus status = [out_stream_ streamStatus];

  // If stream is not open yet, or if there's already queued data -
  // queue more.
  if ((status != NSStreamStatusOpen && status != NSStreamStatusWriting) ||
      [buffer_ length] > 0) {
    [buffer_ appendData: data];
    return;
  }

  // Try writing to stream first
  NSInteger r = [out_stream_ write: [data bytes] maxLength: [data length]];
  if (r == -1)
    return [self _handleError: [out_stream_ streamError]];

  // Only part of data was written, queue rest
  if (r < (NSInteger) [data length]) {
    const void* input = [data bytes] + r;
    [buffer_ appendBytes: input length: [data length] - r];
  }
}


- (void) _handleError: (NSError*) err {
  // Already closed - ignore
  if (![self close])
    return;

  [self _closeStreams: err];

  // Fire global error
  [self _delegateDispatch: ^{
    [self.delegate connection: self handleError: err];
  }];
}


- (void) _closeStreams: (NSError*) err {
  // Close all streams
  NSDictionary* streams = streams_;
  streams_ = nil;
  for (NSNumber* stream_id in streams) {
    ISpdyRequest* req = [streams objectForKey: stream_id];
    [self _delegateDispatch: ^{
      [req.delegate request: req handleError: err];
      [req.delegate handleEnd: req];
    }];
  }
}


- (void) send: (ISpdyRequest*) request {
  NSAssert(request.connection == nil, @"Request was already sent");

  if (request.connection != nil)
    return;
  request.connection = self;
  request.window_in = initial_window_;
  request.window_out = kInitialWindowSize;

  [self _connectionDispatch: ^{
    request.stream_id = stream_id_;
    stream_id_ += 2;

    NSNumber* request_key = [NSNumber numberWithUnsignedInt: request.stream_id];
    [streams_ setObject: request forKey: request_key];

    [framer_ clear];
    [framer_ synStream: request.stream_id
              priority: 0
                method: request.method
                    to: request.url
               headers: request.headers];
    [self _writeRaw: [framer_ output]];
  }];
}


- (void) _writeData: (NSData*) data to: (ISpdyRequest*) request {
  NSData* pending = data;
  NSInteger pending_length = [pending length];
  NSData* rest = nil;

  NSAssert(request.connection != nil, @"Request was closed");

  if (request.window_out != 0) {
    // Perform flow control
    if (version_ != kISpdyV2) {
      // Only part of the data could be written now
      if (pending_length > request.window_out) {
        NSRange range;

        range.location = request.window_out;
        range.length = pending_length - request.window_out;
        rest = [pending subdataWithRange: range];

        range.location = 0;
        range.length = request.window_out;
        pending = [pending subdataWithRange: range];

        pending_length = [pending length];
      }
      request.window_out -= pending_length;
    }

    [framer_ clear];
    [framer_ dataFrame: request.stream_id
                   fin: 0
              withData: pending];

    [self _writeRaw: [framer_ output]];
  } else {
    rest = data;
  }

  if (rest != nil)
    [request _queueData: rest];
  else
    [request _tryPendingClose];
}


- (void) _rst: (uint32_t) stream_id code: (uint8_t) code {
  [framer_ clear];
  [framer_ rst: stream_id code: code];
  [self _writeRaw: [framer_ output]];
}


- (void) _error: (ISpdyRequest*) request code: (ISpdyErrorCode) code {
  [self _rst: request.stream_id code: code];

  [self _delegateDispatch: ^{
    NSError* err = [NSError errorWithDomain: @"spdy"
                                       code: code
                                   userInfo: nil];
    [request.delegate request: request handleError: err];
  }];
}


- (void) _end: (ISpdyRequest*) request {
  NSAssert(request.connection != nil, @"Request was already closed");
  NSAssert(request.closed_by_us == NO,
           @"Request already awaiting other side");
  NSAssert(request.pending_closed_by_us == NO,
           @"Request already awaiting other side");

  [framer_ clear];
  [framer_ dataFrame: request.stream_id
                 fin: 1
            withData: nil];
  if (![request _hasQueuedData]) {
    request.closed_by_us = YES;
    [self _writeRaw: [framer_ output]];
    [request _tryClose];
  } else {
    request.pending_closed_by_us = YES;
  }
}


- (void) _close: (ISpdyRequest*) request {
  NSAssert(request.connection != nil, @"Request was already closed");
  request.connection = nil;

  if (!request.closed_by_us) {
    [self _rst: request.stream_id code: kISpdyRstCancel];
    request.closed_by_us = YES;
  }

  NSNumber* request_key = [NSNumber numberWithUnsignedInt: request.stream_id];
  [streams_ removeObjectForKey: request_key];
}

// NSSocket delegate methods

- (void) stream: (NSStream*) stream handleEvent: (NSStreamEvent) event {
  [self _connectionDispatch: ^{
    if (event == NSStreamEventErrorOccurred)
      return [self _handleError: [stream streamError]];

    if (event == NSStreamEventEndEncountered) {
      NSError* err = [NSError errorWithDomain: @"spdy"
                                         code: kISpdyErrConnectionEnd
                                     userInfo: nil];
      return [self _handleError: err];
    }

    if (event == NSStreamEventHasSpaceAvailable && [buffer_ length] > 0) {
      NSAssert(out_stream_ == stream, @"Write event on input stream?!");

      // Socket available for write
      NSInteger r = [out_stream_ write: [buffer_ bytes]
                             maxLength: [buffer_ length]];
      if (r == -1)
        return [self _handleError: [out_stream_ streamError]];

      // Shift data
      if (r < (NSInteger) [buffer_ length]) {
        void* bytes = [buffer_ mutableBytes];
        memmove(bytes, bytes + r, [buffer_ length] - r);
      }
      // Truncate
      [buffer_ setLength: [buffer_ length] - r];
    } else if (event == NSStreamEventHasBytesAvailable) {
      NSAssert(in_stream_ == stream, @"Read event on output stream?!");

      // Socket available for read
      uint8_t buf[kInitialWindowSize];
      while ([in_stream_ hasBytesAvailable]) {
        NSInteger r = [in_stream_ read: buf maxLength: sizeof(buf)];
        if (r == 0)
          break;
        else if (r < 0)
          return [self _handleError: [in_stream_ streamError]];

        [parser_ execute: buf length: (NSUInteger) r];
      }
    }
  }];
}

// Parser delegate methods

- (void) handleFrame: (ISpdyFrameType) type
                body: (id) body
              is_fin: (BOOL) is_fin
           forStream: (uint32_t) stream_id {
  ISpdyRequest* req = nil;

  if (type == kISpdySynReply ||
      type == kISpdyRstStream ||
      type == kISpdyData) {
    req =
        [streams_ objectForKey: [NSNumber numberWithUnsignedInt: stream_id]];

    // If stream isn't found - notify server about it,
    // but don't reply with RST for RST to prevent echoing each other
    // indefinitely.
    if (req == nil && type != kISpdyRstStream) {
      [self _rst: stream_id code: kISpdyRstProtocolError];
      NSError* err = [NSError errorWithDomain: @"spdy"
                                         code: kISpdyErrNoSuchStream
                                     userInfo: nil];
      return [self _handleError: err];
    }
  }

  // Stream was already ended, this is probably a harmless race condition on
  // server.
  if (req != nil && req.connection == nil)
    return;

  switch (type) {
    case kISpdyData:
      {
        // Perform flow-control
        if (version_ != kISpdyV2) {
          req.window_in -= [body length];

          // Send WINDOW_UPDATE if exhausted
          if (req.window_in <= 0) {
            uint32_t delta = kInitialWindowSize - req.window_in;
            [framer_ clear];
            [framer_ windowUpdate: stream_id update: delta];
            [self _writeRaw: [framer_ output]];
            req.window_in += delta;
          }
        }
        [self _delegateDispatch: ^{
          [req.delegate request: req handleInput: (NSData*) body];
        }];
      }
      break;
    case kISpdySynReply:
      {
        if (req.seen_response)
          return [self _error: req code: kISpdyErrDoubleResponse];
        req.seen_response = YES;
        [self _delegateDispatch: ^{
          [req.delegate request: req handleResponse: body];
        }];

        // Write queued data
        [req _unqueue];
      }
      break;
    case kISpdyRstStream:
      {
        NSError* err = [NSError errorWithDomain: @"spdy"
                                           code: kISpdyErrRst
                                       userInfo: nil];
        [self _delegateDispatch: ^{
          [req.delegate request: req handleError: err];
        }];
        [req close];
      }
      break;
    case kISpdyWindowUpdate:
      [req _updateWindow: [body integerValue]];
      break;
    case kISpdySettings:
      {
        ISpdySettings* settings = (ISpdySettings*) body;
        NSInteger delta = settings.initial_window - initial_window_;
        initial_window_ = settings.initial_window;

        // Update all streams' output window
        if (delta != 0) {
          for (NSNumber* stream_id in streams_) {
            ISpdyRequest* req = [streams_ objectForKey: stream_id];
            [req _updateWindow: delta];
          }
        }
      }
    default:
      // Ignore
      break;
  }

  if (is_fin) {
    req.closed_by_them = YES;
    [req _tryClose];
  }

  // Try end request, if its pending
  [req _tryPendingClose];
}


- (void) handleParserError: (NSError*) err {
  return [self _handleError: err];
}

@end


@implementation ISpdyRequest {
  NSMutableArray* data_queue_;
}

- (id) init: (NSString*) method url: (NSString*) url {
  self = [self init];
  self.method = method;
  self.url = url;
  return self;
}


- (void) writeData: (NSData*) data {
  [self.connection _connectionDispatch: ^{
    [self.connection _writeData: data to: self];
  }];
}


- (void) writeString: (NSString*) str {
  [self writeData: [str dataUsingEncoding: NSUTF8StringEncoding]];
}


- (void) end {
  [self.connection _connectionDispatch: ^{
    [self.connection _end: self];
  }];
}


- (void) close {
  [self.connection _connectionDispatch: ^{
    [self.connection _close: self];
  }];
}


- (void) _tryClose {
  if (self.connection == nil)
    return;
  if (self.closed_by_us && self.closed_by_them) {
    [self.connection _delegateDispatch: ^{
      [self.delegate handleEnd: self];
    }];
    [self close];
  }
}


- (void) _tryPendingClose {
  if (self.pending_closed_by_us) {
    self.pending_closed_by_us = NO;
    [self end];
  }
}


- (void) _updateWindow: (NSInteger) delta {
  self.window_out += delta;

  // Try writing queued data
  if (self.window_out > 0)
    [self _unqueue];
}


- (void) _queueData: (NSData*) data {
  if (data_queue_ == nil)
    data_queue_ = [NSMutableArray arrayWithCapacity: 16];

  [data_queue_ addObject: data];
}


- (BOOL) _hasQueuedData {
  return [data_queue_ count] > 0;
}


- (void) _unqueue {
  if (data_queue_ != nil) {
    NSUInteger count = [data_queue_ count];
    for (NSUInteger i = 0; i < count; i++)
      [self.connection _writeData: [data_queue_ objectAtIndex: i] to: self];

    NSRange range;
    range.location = 0;
    range.length = count;
    [data_queue_ removeObjectsInRange: range];
  }
}

@end

@implementation ISpdyResponse

// No-op, only to generate properties' accessors

@end
