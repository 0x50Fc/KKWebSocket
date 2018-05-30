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
    if([data isString]) {
        [_webSocket writeString:[data toString]];
    }
}

-(void) on:(NSString *)name fn:(JSValue *)fn {
    
    if([name isEqualToString:@"open"]) {
        
        if([fn isObject]) {
            _webSocket.onconnected = ^{
                @try{
                    [fn callWithArguments:@[]];
                }
                @catch(NSException * ex) {
                    NSLog(@"[KK] %@",ex);
                }
            };
        } else {
            _webSocket.onconnected = nil;
        }
        
    } else if([name isEqualToString:@"close"]) {
        
        if([fn isObject]) {
            _webSocket.ondisconnected = ^(NSError * error) {
                @try{
                    [fn callWithArguments:[NSArray arrayWithObjects:[error localizedDescription], nil]];
                }
                @catch(NSException * ex) {
                    NSLog(@"[KK] %@",ex);
                }
            };
        } else {
            _webSocket.ondisconnected = nil;
        }
        
        
    } else if([name isEqualToString:@"data"]) {
        
        if([fn isObject]) {
            _webSocket.ondata = ^(NSData * data) {
                @try {
                    [fn callWithArguments:@[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]]];
                }
                @catch(NSException * ex) {
                    NSLog(@"[KK] %@",ex);
                }
            };
            
            _webSocket.ontext = ^(NSString * text) {
                @try{
                    [fn callWithArguments:@[text]];
                }
                @catch(NSException * ex) {
                    NSLog(@"[KK] %@",ex);
                }
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

-(void) recycle {
    _webSocket.onconnected = nil;
    _webSocket.ondisconnected = nil;
    _webSocket.ondata = nil;
    _webSocket.ontext = nil;
    [_webSocket disconnect];
    _webSocket = nil;
}

@end
