/***********************************************************************************
 *
 * Copyright (c) 2012 Olivier Halligon
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 *
 ***********************************************************************************/


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Imports

#import "OHHTTPStubs.h"


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Types

@interface OHHTTPStubsProtocol : NSURLProtocol @end

////////////////////////////////////////////////////////////////////////////////
#pragma mark - Implementation

@implementation OHHTTPStubs {
    NSMutableArray *_requestHandlers;
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark - Singleton methods

+ (OHHTTPStubs*)sharedInstance
{
    static OHHTTPStubs *sharedInstance = nil;

    static dispatch_once_t predicate;
    dispatch_once(&predicate, ^{
        sharedInstance = [[self alloc] init];
    });

    return sharedInstance;
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark - Setup & Teardown

- (id)init
{
    self = [super init];
    if (self)
    {
        _requestHandlers = [NSMutableArray array];
        [[self class] setEnabled:YES];
    }
    return self;
}

- (void)dealloc
{
    [[self class] setEnabled:NO];
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark - Public class methods

// Commodity methods
+(id)shouldStubRequestsPassingTest:(BOOL(^)(NSURLRequest* request))shouldReturnStubForRequest
                  withStubResponse:(OHHTTPStubsResponse*(^)(NSURLRequest* request))requestHandler
{
    return [self addRequestHandler:^OHHTTPStubsResponse *(NSURLRequest *request, BOOL onlyCheck)
    {
        BOOL shouldStub = shouldReturnStubForRequest ? shouldReturnStubForRequest(request) : YES;
        if (onlyCheck)
        {
            return shouldStub ? OHHTTPStubsResponseUseStub : OHHTTPStubsResponseDontUseStub;
        }
        else
        {
            return (requestHandler && shouldStub) ? requestHandler(request) : nil;
        }
    }];
}

+(id)addRequestHandler:(OHHTTPStubsRequestHandler)handler
{
    return [[self sharedInstance] addRequestHandler:handler];
}
+(BOOL)removeRequestHandler:(id)handler
{
    return [[self sharedInstance] removeRequestHandler:handler];
}
+(void)removeLastRequestHandler
{
    [[self sharedInstance] removeLastRequestHandler];
}
+(void)removeAllRequestHandlers
{
    [[self sharedInstance] removeAllRequestHandlers];
}

+(void)setEnabled:(BOOL)enabled
{
    static BOOL currentEnabledState = NO;
    if (enabled && !currentEnabledState)
    {
        [NSURLProtocol registerClass:[OHHTTPStubsProtocol class]];
    }
    else if (!enabled && currentEnabledState)
    {
        // Force instanciate sharedInstance to avoid it being created later and this turning setEnabled to YES again
        (void)[self sharedInstance]; // This way if we call [setEnabled:NO] before any call to sharedInstance it will be kept disabled
        [NSURLProtocol unregisterClass:[OHHTTPStubsProtocol class]];
    }
    currentEnabledState = enabled;
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark - Public instance methods

-(id)addRequestHandler:(OHHTTPStubsRequestHandler)handler
{
    OHHTTPStubsRequestHandler handlerCopy = [handler copy];
    @synchronized(self) {
        [_requestHandlers addObject:handlerCopy];
    }
    return handlerCopy;
}

-(BOOL)removeRequestHandler:(id)handler
{
    BOOL handlerFound = NO;

    @synchronized(self) {
        handlerFound = [_requestHandlers containsObject:handler];
        [_requestHandlers removeObject:handler];
    }
    return handlerFound;
}
-(void)removeLastRequestHandler
{
    @synchronized(self) {
        [_requestHandlers removeLastObject];
    }
}

-(void)removeAllRequestHandlers
{
    @synchronized(self) {
        [_requestHandlers removeAllObjects];
    }
}

- (void)enumerateRequestHandlersWithBlock:(void(^)(OHHTTPStubsRequestHandler handler, BOOL *stop))enumerationBlock {
    NSCParameterAssert(enumerationBlock != nil);

    @synchronized(self) {
        [_requestHandlers enumerateObjectsWithOptions:NSEnumerationReverse usingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            enumerationBlock(obj, stop);
        }];
    }
}

@end


////////////////////////////////////////////////////////////////////////////////
#pragma mark - Private Protocol Class

@implementation OHHTTPStubsProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    __block BOOL canInitWithRequest = NO;
    [OHHTTPStubs.sharedInstance enumerateRequestHandlersWithBlock:^ (OHHTTPStubsRequestHandler handler, BOOL *stop) {
        id response = handler(request, YES);
        canInitWithRequest = response != nil;
        if (canInitWithRequest) *stop = YES;
    }];
    return canInitWithRequest;
}

- (id)initWithRequest:(NSURLRequest *)request cachedResponse:(NSCachedURLResponse *)response client:(id<NSURLProtocolClient>)client
{
    return [super initWithRequest:request cachedResponse:nil client:client];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
	return request;
}

- (NSCachedURLResponse *)cachedResponse
{
	return nil;
}

- (void)startLoading {
    NSURLRequest* request = [self request];
	id<NSURLProtocolClient> client = [self client];

    __block OHHTTPStubsResponse *responseStub = nil;

    [OHHTTPStubs.sharedInstance enumerateRequestHandlersWithBlock:^(OHHTTPStubsRequestHandler handler, BOOL *stop) {
        responseStub = handler(request, NO);
        if (responseStub != nil) *stop = YES;
    }];

    if (responseStub.error == nil) {
        // Send the fake data

        NSTimeInterval canonicalResponseTime = responseStub.responseTime;
        if (canonicalResponseTime < 0) {
            // Interpret it as a bandwidth in KB/s ( -2 => 2KB/s )
            double bandwidth = -canonicalResponseTime * 1000.0; // in bytes per second
            canonicalResponseTime = responseStub.responseData.length / bandwidth;
        }
        NSTimeInterval requestTime = fabs(canonicalResponseTime * 0.1);
        NSTimeInterval responseTime = fabs(canonicalResponseTime - requestTime);

        NSHTTPURLResponse* urlResponse = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:responseStub.statusCode HTTPVersion:@"HTTP/1.1" headerFields:responseStub.httpHeaders];

        // Cookies handling
        if (request.HTTPShouldHandleCookies) {
            NSArray* cookies = [NSHTTPCookie cookiesWithResponseHeaderFields:responseStub.httpHeaders forURL:request.URL];
            [[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookies:cookies forURL:request.URL mainDocumentURL:request.mainDocumentURL];
        }

        NSString *redirectLocation = responseStub.httpHeaders[@"Location"];
        NSURL *redirectURL = (redirectLocation != nil ? [NSURL URLWithString:redirectLocation] : nil);
        NSInteger statusCode = responseStub.statusCode;

        void (^requestBlock)(void);
        if (statusCode >= 300 && statusCode < 400 && redirectURL) {
            NSURLRequest* redirectRequest = [NSURLRequest requestWithURL:redirectURL];

            requestBlock = ^{
                [client URLProtocol:self wasRedirectedToRequest:redirectRequest redirectResponse:urlResponse];
            };
        } else {
            requestBlock = ^{
                [client URLProtocol:self didReceiveResponse:urlResponse cacheStoragePolicy:NSURLCacheStorageNotAllowed];

                execute_after(responseTime,^{
                    [client URLProtocol:self didLoadData:responseStub.responseData];
                    [client URLProtocolDidFinishLoading:self];
                });
            };
        }

        execute_after(requestTime, requestBlock);
    } else {
        // Send the canned error
        execute_after(responseStub.responseTime, ^{
            [client URLProtocol:self didFailWithError:responseStub.error];
        });
    }
}

- (void)stopLoading
{

}

/////////////////////////////////////////////
// Delayed execution utility methods
/////////////////////////////////////////////

//! execute the block after a given amount of seconds
void execute_after(NSTimeInterval delayInSeconds, dispatch_block_t block)
{
    if (delayInSeconds > 0) {
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
        dispatch_after(popTime, dispatch_get_current_queue(), block);
    } else {
        block();
    }
}

@end
