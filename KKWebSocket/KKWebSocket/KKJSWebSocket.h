//
//  KKJSWebSocket.h
//  KKWebSocket
//
//  Created by hailong11 on 2018/5/9.
//  Copyright © 2018年 kkmofang.cn. All rights reserved.
//

#import <JavaScriptCore/JavaScriptCore.h>
#import <KKWebSocket/KKWebSocket.h>

@protocol KKJSWebSocket<JSExport>

-(void) close;

JSExportAs(on,
           -(void) on:(NSString *) name fn:(JSValue *) fn
           );

JSExportAs(send,
           -(void) send:(JSValue *) data
           );

@end

@interface KKJSWebSocket : NSObject<KKJSWebSocket>

+(void) openlibs:(JSContext *) jsContext queue:(dispatch_queue_t) queue;

@property(nonatomic,strong,readonly) KKWebSocket * webSocket;

-(instancetype) initWithWebSocket:(KKWebSocket *) webSocket;

@end
