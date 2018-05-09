//
//  KKJSWebSocket.m
//  KKWebSocket
//
//  Created by hailong11 on 2018/5/9.
//  Copyright © 2018年 kkmofang.cn. All rights reserved.
//

#import "KKJSWebSocket.h"
#import "KKWebSocket.h"

@implementation KKJSWebSocket

+(void) openlibs:(JSContext *) jsContext queue:(dispatch_queue_t) queue {
    
    JSValue * v = [JSValue valueWithNewObjectInContext:jsContext];
    
    v[@"alloc"] = ^JSValue*() {
        
        NSArray * arguments = [JSContext currentArguments];
        NSString * url = nil;
        NSString * protocol = nil;
        
        if([arguments count] >0) {
            url = [arguments[0] toString];
        }
        
        if([arguments count] >1) {
            url = [arguments[1] toString];
        }
        
        if(url) {
            
            KKWebSocket * webSocket = [[KKWebSocket alloc] initWithURL:[NSURL URLWithString:url]];
            
            webSocket.queue = queue;
            
            if(protocol != nil) {
                webSocket.headers[@"Sec-WebSocket-Protocol"] = protocol;
            }
            
            KKJSWebSocket * jsWebSocket = [[KKJSWebSocket alloc] initWithWebSocket:webSocket];
            
            [webSocket connect];
            
            return [JSValue valueWithObject:jsWebSocket inContext:[JSContext currentContext]];
            
        }
        
        return nil;
    };
    
    [jsContext.globalObject setValue:v forProperty:@"WebSocket"];
    
}

-(instancetype) initWithWebSocket:(KKWebSocket *) webSocket {
    if((self = [super init])) {
        _webSocket = webSocket;
    }
    return self;
}

-(void) dealloc {
    
    [_webSocket setOndata:nil];
    [_webSocket setOntext:nil];
    [_webSocket setOnconnected:nil];
    [_webSocket setOndisconnected:nil];
    [_webSocket disconnect];
    
}

-(void) send:(JSValue *)data {
    
}

-(void) on:(NSString *)name fn:(JSValue *)fn {
    
    if([name isEqualToString:@"open"]) {
        
        if([fn isObject]) {
            _webSocket.onconnected = ^{
                [fn callWithArguments:@[]];
            };
        } else {
            _webSocket.onconnected = nil;
        }
        
    } else if([name isEqualToString:@"close"]) {
        
        if([fn isObject]) {
            _webSocket.ondisconnected = ^(NSError * error) {
                [fn callWithArguments:@[[error localizedDescription]]];
            };
        } else {
            _webSocket.ondisconnected = nil;
        }
        
        
    } else if([name isEqualToString:@"data"]) {
        
        if([fn isObject]) {
            _webSocket.ondata = ^(NSData * data) {
                [fn callWithArguments:@[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]]];
            };
            
            _webSocket.ontext = ^(NSString * text) {
                [fn callWithArguments:@[text]];
            };
        } else {
            _webSocket.ondata = nil;
            _webSocket.ontext = nil;
        }
    }
}

-(void) close {
    [_webSocket disconnect];
}

@end
