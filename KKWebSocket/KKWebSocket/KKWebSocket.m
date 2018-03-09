//
//  KKWebSocket.m
//  KKWebSocket
//
//  Created by hailong11 on 2018/2/9.
//  Copyright © 2018年 kkmofang.cn. All rights reserved.
//

#import "KKWebSocket.h"

static NSRunLoop * _KKWebSocketRunLoop = nil;

@implementation NSRunLoop(KKWebSocket)

+ (void) KKWebSocketRunloop {
    
    _KKWebSocketRunLoop = [NSRunLoop currentRunLoop];
    
    NSLog(@"KKWebSocket Runloop run");
    
    @autoreleasepool{
        [NSTimer scheduledTimerWithTimeInterval:DBL_MAX target:[NSRunLoop class] selector:@selector(KKWebSocketRunloopDone) userInfo:nil repeats:NO];
        [_KKWebSocketRunLoop run];
    }
    
    NSLog(@"KKWebSocket Runloop exit");
}

+(void) KKWebSocketRunloopDone {
    
}

@end

NSRunLoop * KKWebSocketRunLoop(){
    KKWebSocketRunLoopThread();
    return _KKWebSocketRunLoop;
}

NSThread * KKWebSocketRunLoopThread(void) {
    static NSThread * thread = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        thread = [[NSThread alloc] initWithTarget:[NSRunLoop class] selector:@selector(KKWebSocketRunloop) object:nil];
        [thread setName:@"KKWebSocketRunLoopThread"];
        [thread start];
        [[NSRunLoop class] performSelector:@selector(KKWebSocketRunloopDone) onThread:thread withObject:nil waitUntilDone:YES];
    });
    return thread;
}

//get the opCode from the packet
typedef NS_ENUM(NSUInteger, KKOpCode) {
    KKOpCodeContinueFrame = 0x0,
    KKOpCodeTextFrame = 0x1,
    KKOpCodeBinaryFrame = 0x2,
    //3-7 are reserved.
    KKOpCodeConnectionClose = 0x8,
    KKOpCodePing = 0x9,
    KKOpCodePong = 0xA,
    //B-F reserved.
};

typedef NS_ENUM(NSUInteger, KKWebSocketCloseCode) {
    KKWebSocketCloseCodeNormal                 = 1000,
    KKWebSocketCloseCodeGoingAway              = 1001,
    KKWebSocketCloseCodeProtocolError          = 1002,
    KKWebSocketCloseCodeProtocolUnhandledType  = 1003,
    // 1004 reserved.
    KKWebSocketCloseCodeNoStatusReceived       = 1005,
    //1006 reserved.
    KKWebSocketCloseCodeEncoding               = 1007,
    KKWebSocketCloseCodePolicyViolated         = 1008,
    KKWebSocketCloseCodeMessageTooBig          = 1009
};

typedef NS_ENUM(NSUInteger, KKWebSocketInternalErrorCode) {
    // 0-999 WebSocket status codes not used
    KKWebSocketOutputStreamWriteError  = 1
};

#define kKKInternalHTTPStatusWebSocket 101


@interface KKWebSocketResponse : NSObject

@property(nonatomic, assign)BOOL isFin;
@property(nonatomic, assign)KKOpCode code;
@property(nonatomic, assign)NSInteger bytesLeft;
@property(nonatomic, assign)NSInteger frameCount;
@property(nonatomic, strong)NSMutableData *buffer;

@end

@interface KKWebSocketMessage : NSObject

@property(nonatomic, strong) NSData * data;
@property(nonatomic, assign) KKOpCode code;

@end

@interface KKWebSocket ()<NSStreamDelegate>

@property(nonatomic, strong) NSURL *url;
@property(nonatomic, strong) NSInputStream *inputStream;
@property(nonatomic, strong) NSOutputStream *outputStream;
@property(nonatomic, strong) NSMutableArray *readStack;
@property(nonatomic, strong) NSMutableArray *inputQueue;
@property(nonatomic, strong) NSMutableArray *writeQueue;
@property(nonatomic, strong) NSData *fragBuffer;
@property(nonatomic, strong) NSMutableDictionary *headers;

@end

//Constant Header Values.
NS_ASSUME_NONNULL_BEGIN
static NSString *const headerWSUpgradeName     = @"Upgrade";
static NSString *const headerWSUpgradeValue    = @"websocket";
static NSString *const headerWSHostName        = @"Host";
static NSString *const headerWSConnectionName  = @"Connection";
static NSString *const headerWSConnectionValue = @"Upgrade";
static NSString *const headerWSProtocolName    = @"Sec-WebSocket-Protocol";
static NSString *const headerWSVersionName     = @"Sec-Websocket-Version";
static NSString *const headerWSVersionValue    = @"13";
static NSString *const headerWSKeyName         = @"Sec-WebSocket-Key";
static NSString *const headerOriginName        = @"Origin";
static NSString *const headerWSAcceptName      = @"Sec-WebSocket-Accept";
NS_ASSUME_NONNULL_END

//Class Constants
static char CRLFBytes[] = {'\r', '\n', '\r', '\n'};
static int BUFFER_MAX = 40960;

// This get the correct bits out by masking the bytes of the buffer.
static const uint8_t KKFinMask             = 0x80;
static const uint8_t KKOpCodeMask          = 0x0F;
static const uint8_t KKRSVMask             = 0x70;
static const uint8_t KKMaskMask            = 0x80;
static const uint8_t KKPayloadLenMask      = 0x7F;
static const size_t  KKMaxFrameSize        = 32;

@implementation KKWebSocket

/////////////////////////////////////////////////////////////////////////////
//Default initializer
- (instancetype)initWithURL:(NSURL *)url
{
    if(self = [super init]) {
        self.url = url;
        self.readStack = [NSMutableArray new];
        self.inputQueue = [NSMutableArray new];
    }
    
    return self;
}
    
-(dispatch_queue_t) queue {
    if(_queue == nil) {
        _queue = dispatch_get_main_queue();
    }
    return _queue;
}

- (void)connect {
    
    if(_state != KKWebSocketStateNone) {
        return;
    }
    
    _state = KKWebSocketStateConnecting;
    
    [self performSelector:@selector(createHTTPRequest) onThread:KKWebSocketRunLoopThread() withObject:nil waitUntilDone:NO];
    
}


- (void) disconnect {
    if(_state == KKWebSocketStateConnecting || _state == KKWebSocketStateConnected) {
        _state = KKWebSocketStateDisconnecting;
        [self writeError:KKWebSocketCloseCodeNormal];
    }
}

- (void)writeString:(NSString*)string {
    if(string) {
        [self dequeueWrite:[string dataUsingEncoding:NSUTF8StringEncoding]
                  withCode:KKOpCodeTextFrame];
    }
}

- (void)writePing:(NSData*)data {
    [self dequeueWrite:data withCode:KKOpCodePing];
}

- (void)writeData:(NSData*)data {
    [self dequeueWrite:data withCode:KKOpCodeBinaryFrame];
}

- (void)addHeader:(NSString*)value forKey:(NSString*)key {
    if(!self.headers) {
        self.headers = [[NSMutableDictionary alloc] init];
    }
    [self.headers setObject:value forKey:key];
}

- (NSString *)origin;
{
    NSString *scheme = [_url.scheme lowercaseString];
    
    if ([scheme isEqualToString:@"wss"]) {
        scheme = @"https";
    } else if ([scheme isEqualToString:@"ws"]) {
        scheme = @"http";
    }
    
    if (_url.port) {
        return [NSString stringWithFormat:@"%@://%@:%@/", scheme, _url.host, _url.port];
    } else {
        return [NSString stringWithFormat:@"%@://%@/", scheme, _url.host];
    }
}

- (void)createHTTPRequest {
    CFURLRef url = CFURLCreateWithString(kCFAllocatorDefault, (CFStringRef)self.url.absoluteString, NULL);
    CFStringRef requestMethod = CFSTR("GET");
    CFHTTPMessageRef urlRequest = CFHTTPMessageCreateRequest(kCFAllocatorDefault,
                                                             requestMethod,
                                                             url,
                                                             kCFHTTPVersion1_1);
    CFRelease(url);
    
    NSNumber *port = _url.port;
    if (!port) {
        if([self.url.scheme isEqualToString:@"wss"] || [self.url.scheme isEqualToString:@"https"]){
            port = @(443);
        } else {
            port = @(80);
        }
    }

    CFHTTPMessageSetHeaderFieldValue(urlRequest,
                                     (__bridge CFStringRef)headerWSHostName,
                                     (__bridge CFStringRef)[NSString stringWithFormat:@"%@:%@",self.url.host,port]);
    CFHTTPMessageSetHeaderFieldValue(urlRequest,
                                     (__bridge CFStringRef)headerWSVersionName,
                                     (__bridge CFStringRef)headerWSVersionValue);
    CFHTTPMessageSetHeaderFieldValue(urlRequest,
                                     (__bridge CFStringRef)headerWSKeyName,
                                     (__bridge CFStringRef)[self generateWebSocketKey]);
    CFHTTPMessageSetHeaderFieldValue(urlRequest,
                                     (__bridge CFStringRef)headerWSUpgradeName,
                                     (__bridge CFStringRef)headerWSUpgradeValue);
    CFHTTPMessageSetHeaderFieldValue(urlRequest,
                                     (__bridge CFStringRef)headerWSConnectionName,
                                     (__bridge CFStringRef)headerWSConnectionValue);
    
    CFHTTPMessageSetHeaderFieldValue(urlRequest,
                                     (__bridge CFStringRef)headerOriginName,
                                     (__bridge CFStringRef)[self origin]);
    
    for(NSString *key in self.headers) {
        CFHTTPMessageSetHeaderFieldValue(urlRequest,
                                         (__bridge CFStringRef)key,
                                         (__bridge CFStringRef)self.headers[key]);
    }
    
    NSLog(@"[KK] %@", urlRequest);

    NSData *serializedRequest = (__bridge_transfer NSData *)(CFHTTPMessageCopySerializedMessage(urlRequest));
    [self initStreamsWithData:serializedRequest port:port];
    CFRelease(urlRequest);
}

- (NSString*)generateWebSocketKey {
    NSInteger seed = 16;
    NSMutableString *string = [NSMutableString stringWithCapacity:seed];
    for (int i = 0; i < seed; i++) {
        [string appendFormat:@"%C", (unichar)('a' + arc4random_uniform(25))];
    }
    return [[string dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
}

- (void)initStreamsWithData:(NSData*)data port:(NSNumber*)port {
    
    NSRunLoop * runloop = KKWebSocketRunLoop();
    
    CFReadStreamRef readStream = NULL;
    CFWriteStreamRef writeStream = NULL;
    CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)self.url.host, [port intValue], &readStream, &writeStream);
    
    self.inputStream = (__bridge_transfer NSInputStream *)readStream;
    self.inputStream.delegate = self;
    self.outputStream = (__bridge_transfer NSOutputStream *)writeStream;
    self.outputStream.delegate = self;
    if([self.url.scheme isEqualToString:@"wss"] || [self.url.scheme isEqualToString:@"https"]) {
        [self.inputStream setProperty:NSStreamSocketSecurityLevelNegotiatedSSL forKey:NSStreamSocketSecurityLevelKey];
        [self.outputStream setProperty:NSStreamSocketSecurityLevelNegotiatedSSL forKey:NSStreamSocketSecurityLevelKey];
    }
    
    [self.inputStream scheduleInRunLoop:runloop forMode:NSDefaultRunLoopMode];
    [self.outputStream scheduleInRunLoop:runloop forMode:NSDefaultRunLoopMode];
    [self.inputStream open];
    [self.outputStream open];
    size_t dataLen = [data length];
    [self.outputStream write:[data bytes] maxLength:dataLen];
    
}

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode {

    switch (eventCode) {
        case NSStreamEventNone:
            break;
            
        case NSStreamEventOpenCompleted:
            break;
            
        case NSStreamEventHasBytesAvailable:
            if(aStream == self.inputStream) {
                [self processInputStream];
            }
            break;
            
        case NSStreamEventHasSpaceAvailable:
        {
            [self processWriteQueue];
        }
            break;
            
        case NSStreamEventErrorOccurred:
            [self disconnectStream:[aStream streamError]];
            break;
            
        case NSStreamEventEndEncountered:
            [self disconnectStream:nil];
            break;
            
        default:
            break;
    }
}

- (void)disconnectStream:(NSError*)error {
    [self.inputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [self.outputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [self.outputStream close];
    [self.inputStream close];
    self.outputStream = nil;
    self.inputStream = nil;
    [self doDisconnect:error];
}

- (void)processInputStream {
    @autoreleasepool {
        uint8_t buffer[BUFFER_MAX];
        NSInteger length = [self.inputStream read:buffer maxLength:BUFFER_MAX];
        if(length > 0) {
            if(_state != KKWebSocketStateConnected) {
                CFIndex responseStatusCode;
                BOOL status = [self processHTTP:buffer length:length responseStatusCode:&responseStatusCode];
                if(status == NO) {
                    [self doDisconnect:[self errorWithDetail:@"Invalid HTTP upgrade" code:1 userInfo:@{@"HTTPResponseStatusCode" : @(responseStatusCode)}]];
                }
            } else {
                BOOL process = NO;
                if(self.inputQueue.count == 0) {
                    process = YES;
                }
                [self.inputQueue addObject:[NSData dataWithBytes:buffer length:length]];
                if(process) {
                    [self dequeueInput];
                }
            }
        }
    }
}

- (void)dequeueInput {
    if(self.inputQueue.count > 0) {
        NSData *data = [self.inputQueue objectAtIndex:0];
        NSData *work = data;
        if(self.fragBuffer) {
            NSMutableData *combine = [NSMutableData dataWithData:self.fragBuffer];
            [combine appendData:data];
            work = combine;
            self.fragBuffer = nil;
        }
        [self processRawMessage:(uint8_t*)work.bytes length:work.length];
        [self.inputQueue removeObject:data];
        [self dequeueInput];
    }
}

- (BOOL)processHTTP:(uint8_t*)buffer length:(NSInteger)bufferLen responseStatusCode:(CFIndex*)responseStatusCode {
    int k = 0;
    NSInteger totalSize = 0;
    for(int i = 0; i < bufferLen; i++) {
        if(buffer[i] == CRLFBytes[k]) {
            k++;
            if(k == 3) {
                totalSize = i + 1;
                break;
            }
        } else {
            k = 0;
        }
    }
    if(totalSize > 0) {
        BOOL status = [self validateResponse:buffer length:totalSize responseStatusCode:responseStatusCode];
        if (status == YES) {
            _state = KKWebSocketStateConnected;
            __weak typeof(self) weakSelf = self;
            dispatch_async(self.queue,^{
                if(weakSelf.onconnected) {
                    weakSelf.onconnected();
                }
            });
            totalSize += 1; //skip the last \n
            NSInteger  restSize = bufferLen-totalSize;
            if(restSize > 0) {
                [self processRawMessage:(buffer+totalSize) length:restSize];
            }
        }
        return status;
    }
    return NO;
}

- (BOOL)validateResponse:(uint8_t *)buffer length:(NSInteger)bufferLen responseStatusCode:(CFIndex*)responseStatusCode {
    CFHTTPMessageRef response = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, NO);
    CFHTTPMessageAppendBytes(response, buffer, bufferLen);
    *responseStatusCode = CFHTTPMessageGetResponseStatusCode(response);
    BOOL status = ((*responseStatusCode) == kKKInternalHTTPStatusWebSocket)?(YES):(NO);
    if(status == NO) {
        CFRelease(response);
        return NO;
    }
    NSDictionary *headers = (__bridge_transfer NSDictionary *)(CFHTTPMessageCopyAllHeaderFields(response));
    NSString *acceptKey = headers[headerWSAcceptName];
    CFRelease(response);
    if(acceptKey.length > 0) {
        return YES;
    }
    return NO;
}

-(void)processRawMessage:(uint8_t*)buffer length:(NSInteger)bufferLen {
    KKWebSocketResponse *response = [self.readStack lastObject];
    if(response && bufferLen < 2) {
        self.fragBuffer = [NSData dataWithBytes:buffer length:bufferLen];
        return;
    }
    if(response.bytesLeft > 0) {
        NSInteger len = response.bytesLeft;
        NSInteger extra =  bufferLen - response.bytesLeft;
        if(response.bytesLeft > bufferLen) {
            len = bufferLen;
            extra = 0;
        }
        response.bytesLeft -= len;
        [response.buffer appendData:[NSData dataWithBytes:buffer length:len]];
        [self processResponse:response];
        NSInteger offset = bufferLen - extra;
        if(extra > 0) {
            [self processExtra:(buffer+offset) length:extra];
        }
        return;
    } else {
        if(bufferLen < 2) { // we need at least 2 bytes for the header
            self.fragBuffer = [NSData dataWithBytes:buffer length:bufferLen];
            return;
        }
        BOOL isFin = (KKFinMask & buffer[0]);
        uint8_t receivedOpcode = (KKOpCodeMask & buffer[0]);
        BOOL isMasked = (KKMaskMask & buffer[1]);
        uint8_t payloadLen = (KKPayloadLenMask & buffer[1]);
        NSInteger offset = 2; //how many bytes do we need to skip for the header
        if((isMasked  || (KKRSVMask & buffer[0])) && receivedOpcode != KKOpCodePong) {
            [self doDisconnect:[self errorWithDetail:@"masked and rsv data is not currently supported" code:KKWebSocketCloseCodeProtocolError]];
            [self writeError:KKWebSocketCloseCodeProtocolError];
            return;
        }
        BOOL isControlFrame = (receivedOpcode == KKOpCodeConnectionClose || receivedOpcode == KKOpCodePing);
        if(!isControlFrame && (receivedOpcode != KKOpCodeBinaryFrame && receivedOpcode != KKOpCodeContinueFrame && receivedOpcode != KKOpCodeTextFrame && receivedOpcode != KKOpCodePong)) {
            [self doDisconnect:[self errorWithDetail:[NSString stringWithFormat:@"unknown opcode: 0x%x",receivedOpcode] code:KKWebSocketCloseCodeProtocolError]];
            [self writeError:KKWebSocketCloseCodeProtocolError];
            return;
        }
        if(isControlFrame && !isFin) {
            [self doDisconnect:[self errorWithDetail:@"control frames can't be fragmented" code:KKWebSocketCloseCodeProtocolError]];
            [self writeError:KKWebSocketCloseCodeProtocolError];
            return;
        }
        if(receivedOpcode == KKOpCodeConnectionClose) {
            //the server disconnected us
            uint16_t code = KKWebSocketCloseCodeNormal;
            if(payloadLen == 1) {
                code = KKWebSocketCloseCodeProtocolError;
            }
            else if(payloadLen > 1) {
                code = CFSwapInt16BigToHost(*(uint16_t *)(buffer+offset) );
                if(code < 1000 || (code > 1003 && code < 1007) || (code > 1011 && code < 3000)) {
                    code = KKWebSocketCloseCodeProtocolError;
                }
                offset += 2;
            }
            
            if(payloadLen > 2) {
                NSInteger len = payloadLen-2;
                if(len > 0) {
                    NSData *data = [NSData dataWithBytes:(buffer+offset) length:len];
                    NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    if(!str) {
                        code = KKWebSocketCloseCodeProtocolError;
                    }
                }
            }
            [self writeError:code];
            [self doDisconnect:[self errorWithDetail:@"continue frame before a binary or text frame" code:code]];
            return;
        }
        if(isControlFrame && payloadLen > 125) {
            [self writeError:KKWebSocketCloseCodeProtocolError];
            return;
        }
        NSInteger dataLength = payloadLen;
        if(payloadLen == 127) {
            dataLength = (NSInteger)CFSwapInt64BigToHost(*(uint64_t *)(buffer+offset));
            offset += sizeof(uint64_t);
        } else if(payloadLen == 126) {
            dataLength = CFSwapInt16BigToHost(*(uint16_t *)(buffer+offset) );
            offset += sizeof(uint16_t);
        }
        if(bufferLen < offset) { // we cannot process this yet, nead more header data
            self.fragBuffer = [NSData dataWithBytes:buffer length:bufferLen];
            return;
        }
        NSInteger len = dataLength;
        if(dataLength > (bufferLen-offset) || (bufferLen - offset) < dataLength) {
            len = bufferLen-offset;
        }
        NSData *data = nil;
        if(len < 0) {
            len = 0;
            data = [NSData data];
        } else {
            data = [NSData dataWithBytes:(buffer+offset) length:len];
        }
        if(receivedOpcode == KKOpCodePong) {
            NSInteger step = (offset+len);
            NSInteger extra = bufferLen-step;
            if(extra > 0) {
                [self processRawMessage:(buffer+step) length:extra];
            }
            return;
        }
        KKWebSocketResponse *response = [self.readStack lastObject];
        if(isControlFrame) {
            response = nil; //don't append pings
        }
        if(!isFin && receivedOpcode == KKOpCodeContinueFrame && !response) {
            [self doDisconnect:[self errorWithDetail:@"continue frame before a binary or text frame" code:KKWebSocketCloseCodeProtocolError]];
            [self writeError:KKWebSocketCloseCodeProtocolError];
            return;
        }
        BOOL isNew = NO;
        if(!response) {
            if(receivedOpcode == KKOpCodeContinueFrame) {
                [self doDisconnect:[self errorWithDetail:@"first frame can't be a continue frame" code:KKWebSocketCloseCodeProtocolError]];
                [self writeError:KKWebSocketCloseCodeProtocolError];
                return;
            }
            isNew = YES;
            response = [KKWebSocketResponse new];
            response.code = receivedOpcode;
            response.bytesLeft = dataLength;
            response.buffer = [NSMutableData dataWithData:data];
        } else {
            if(receivedOpcode == KKOpCodeContinueFrame) {
                response.bytesLeft = dataLength;
            } else {
                [self doDisconnect:[self errorWithDetail:@"second and beyond of fragment message must be a continue frame" code:KKWebSocketCloseCodeProtocolError]];
                [self writeError:KKWebSocketCloseCodeProtocolError];
                return;
            }
            [response.buffer appendData:data];
        }
        response.bytesLeft -= len;
        response.frameCount++;
        response.isFin = isFin;
        if(isNew) {
            [self.readStack addObject:response];
        }
        [self processResponse:response];
        
        NSInteger step = (offset+len);
        NSInteger extra = bufferLen-step;
        if(extra > 0) {
            [self processExtra:(buffer+step) length:extra];
        }
    }
    
}

- (void)processExtra:(uint8_t*)buffer length:(NSInteger)bufferLen {
    if(bufferLen < 2) {
        self.fragBuffer = [NSData dataWithBytes:buffer length:bufferLen];
    } else {
        [self processRawMessage:buffer length:bufferLen];
    }
}

- (BOOL)processResponse:(KKWebSocketResponse*)response {
    if(response.isFin && response.bytesLeft <= 0) {
        NSData *data = response.buffer;
        if(response.code == KKOpCodePing) {
            [self dequeueWrite:response.buffer withCode:KKOpCodePong];
        } else if(response.code == KKOpCodeTextFrame) {
            NSString *str = [[NSString alloc] initWithData:response.buffer encoding:NSUTF8StringEncoding];
            if(!str) {
                [self writeError:KKWebSocketCloseCodeEncoding];
                return NO;
            }
            __weak typeof(self) weakSelf = self;
            dispatch_async(self.queue,^{
                if(weakSelf.ontext) {
                    weakSelf.ontext(str);
                }
            });
        } else if(response.code == KKOpCodeBinaryFrame) {
            __weak typeof(self) weakSelf = self;
            dispatch_async(self.queue,^{
                if(weakSelf.ondata) {
                    weakSelf.ondata(data);
                }
            });
        }
        [self.readStack removeLastObject];
        return YES;
    }
    return NO;
}

-(NSMutableArray *) writeQueue {
    if(_writeQueue == nil) {
        _writeQueue = [[NSMutableArray alloc] initWithCapacity:4];
    }
    return _writeQueue;
}

- (void) processWriteQueue {
    
    KKWebSocketMessage * message = [_writeQueue lastObject];
    
    while(message) {
        
        [_writeQueue removeLastObject];
        
        NSData * data = message.data;
        KKOpCode code = message.code;
        
        uint64_t offset = 2; //how many bytes do we need to skip for the header
        uint8_t *bytes = (uint8_t*)[data bytes];
        uint64_t dataLength = data.length;
        NSMutableData *frame = [[NSMutableData alloc] initWithLength:(NSInteger)(dataLength + KKMaxFrameSize)];
        uint8_t *buffer = (uint8_t*)[frame mutableBytes];
        buffer[0] = KKFinMask | code;
        if(dataLength < 126) {
            buffer[1] |= dataLength;
        } else if(dataLength <= UINT16_MAX) {
            buffer[1] |= 126;
            *((uint16_t *)(buffer + offset)) = CFSwapInt16BigToHost((uint16_t)dataLength);
            offset += sizeof(uint16_t);
        } else {
            buffer[1] |= 127;
            *((uint64_t *)(buffer + offset)) = CFSwapInt64BigToHost((uint64_t)dataLength);
            offset += sizeof(uint64_t);
        }
        BOOL isMask = YES;
        if(isMask) {
            buffer[1] |= KKMaskMask;
            uint8_t *mask_key = (buffer + offset);
            (void)SecRandomCopyBytes(kSecRandomDefault, sizeof(uint32_t), (uint8_t *)mask_key);
            offset += sizeof(uint32_t);
            
            for (size_t i = 0; i < dataLength; i++) {
                buffer[offset] = bytes[i] ^ mask_key[i % sizeof(uint32_t)];
                offset += 1;
            }
        } else {
            for(size_t i = 0; i < dataLength; i++) {
                buffer[offset] = bytes[i];
                offset += 1;
            }
        }
        uint64_t total = 0;
        while (true) {
            if(_state == KKWebSocketStateDisconnected) {
                return;
            }
            NSInteger len = [self.outputStream write:([frame bytes]+total) maxLength:(NSInteger)(offset-total)];
            if(len < 0 || len == NSNotFound) {
                NSError *error = self.outputStream.streamError;
                if(!error) {
                    error = [self errorWithDetail:@"output stream error during write" code:KKWebSocketOutputStreamWriteError];
                }
                [self doDisconnect:error];
                break;
            } else {
                total += len;
            }
            if(total >= offset) {
                break;
            }
        }
        
        message = [_writeQueue lastObject];
    }
    
}

-(void) addMessage:(KKWebSocketMessage *) v {
    
    [self.writeQueue insertObject:v atIndex:0];
    
    if([self.outputStream hasSpaceAvailable]) {
        [self processWriteQueue];
    }
}

-(void)dequeueWrite:(NSData*)data withCode:(KKOpCode)code {
    
    if(_state== KKWebSocketStateDisconnected || _state == KKWebSocketStateNone) {
        return;
    }
    
    KKWebSocketMessage * v = [[KKWebSocketMessage alloc] init];
    v.data = data;
    v.code = code;
    
    [self performSelector:@selector(addMessage:) onThread:KKWebSocketRunLoopThread() withObject:v waitUntilDone:NO];
    
}

- (void)doDisconnect:(NSError*)error {
    if(_state != KKWebSocketStateDisconnected) {
        _state = KKWebSocketStateDisconnected;
        __weak typeof(self) weakSelf = self;
        dispatch_async(self.queue, ^{
            if(weakSelf.ondisconnected) {
                weakSelf.ondisconnected(error);
            }
        });
    }
}

- (NSError*)errorWithDetail:(NSString*)detail code:(NSInteger)code
{
    return [self errorWithDetail:detail code:code userInfo:nil];
}

- (NSError*)errorWithDetail:(NSString*)detail code:(NSInteger)code userInfo:(NSDictionary *)userInfo
{
    NSMutableDictionary* details = [NSMutableDictionary dictionary];
    details[detail] = NSLocalizedDescriptionKey;
    if (userInfo) {
        [details addEntriesFromDictionary:userInfo];
    }
    return [[NSError alloc] initWithDomain:@"KKWebSocket" code:code userInfo:details];
}

- (void)writeError:(uint16_t)code {
    uint16_t buffer[1];
    buffer[0] = CFSwapInt16BigToHost(code);
    [self dequeueWrite:[NSData dataWithBytes:buffer length:sizeof(uint16_t)] withCode:KKOpCodeConnectionClose];
}

- (void)dealloc {
    if(_inputStream ){
        [_inputStream removeFromRunLoop:KKWebSocketRunLoop() forMode:NSDefaultRunLoopMode];
        [_inputStream close];
    }
    if(_outputStream ){
        [_outputStream removeFromRunLoop:KKWebSocketRunLoop() forMode:NSDefaultRunLoopMode];
        [_outputStream close];
    }
    NSLog(@"KKWebSocket dealloc");
}

@end

@implementation KKWebSocketResponse

@end

@implementation KKWebSocketMessage

@end
