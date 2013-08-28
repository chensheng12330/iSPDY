#import <CoreFoundation/CFStream.h>
#import <Foundation/Foundation.h>

// Forward-declarations
@class ISpdy;
@class ISpdyRequest;
@class ISpdyFramer;

// SPDY Protocol version
typedef enum {
  kISpdyV2,
  kISpdyV3
} ISpdyVersion;

// Possible error codes in NSError with domain @"spdy"
typedef enum {
  kISpdyConnectionEnd
} ISpdyErrorCode;

// Delegate for handling request-level events
@protocol ISpdyRequestDelegate
- (void) request: (ISpdyRequest*) req handleError: (NSError*) err;
- (void) request: (ISpdyRequest*) req handleInput: (NSData*) input;
- (void) handleEnd: (ISpdyRequest*) req;
@end

// Request class.
//
// Should be used to initiate new request to the server, works only with
// existing ISpdy connection.
@interface ISpdyRequest : NSObject

@property (weak) id <ISpdyRequestDelegate> delegate;
@property (weak) ISpdy* connection;
@property NSString* method;
@property NSString* url;
@property NSDictionary* headers;

// Mostly internal fields
@property uint32_t stream_id;
@property BOOL closed_by_us;
@property BOOL closed_by_them;

// Initialize properties
- (id) init: (NSString*) method url: (NSString*) url;

// Write raw data to the underlying stream
- (void) writeData: (NSData*) data;

// Write string to the underlying stream
- (void) writeString: (NSString*) data;

// Gracefully end stream/request
- (void) end;

// Shutdown stream (CANCEL error code will be used)
- (void) close;

// Mostly internal method, calls `[req close]` if the stream is closed by both
// us and them.
- (void) _tryClose;

@end

// Delegate for handling connection-level events
@protocol ISpdyDelegate
- (void) connection: (ISpdy*) conn handleError: (NSError*) err;
@end

// ISpdy connection class
//
// Connects to server and holds underlying socket, parsing incoming data and
// generating outgoing protocol data. Should be instantiated in order to
// send requests to the server.
@interface ISpdy : NSObject <NSStreamDelegate> {
  ISpdyVersion version_;
  NSInputStream* in_stream_;
  NSOutputStream* out_stream_;
  ISpdyFramer* framer_;

  // Next stream's id
  uint32_t stream_id_;

  // Dictionary of all streams
  NSMutableDictionary* streams_;

  // Connection write buffer
  NSMutableData* buffer_;
}

@property (weak) id <ISpdyDelegate> delegate;

// Initialize connection to work with specified protocol version
- (id) init: (ISpdyVersion) version;

// Connect to remote server
- (BOOL) connect: (NSString*) host port: (UInt32) port secure: (BOOL) secure;

// Send initialized request to the server
- (void) send: (ISpdyRequest*) request;

// (Internal) Write raw data to the underlying socket
- (void) writeRaw: (NSData*) data;

// (Internal) Handle global errors
- (void) handleError: (NSError*) err;

// (Mostly internal) see ISpdyRequest for description
- (void) end: (ISpdyRequest*) request;
- (void) close: (ISpdyRequest*) request;
- (void) writeData: (NSData*) data to: (ISpdyRequest*) request;

@end