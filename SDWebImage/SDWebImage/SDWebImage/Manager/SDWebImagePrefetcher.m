/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImagePrefetcher.h"

@interface SDWebImagePrefetcher ()

@property (strong, nonatomic, nonnull) SDWebImageManager *manager;
@property (strong, atomic, nullable) NSArray<NSURL *> *prefetchURLs; // may be accessed from different queue
@property (assign, nonatomic) NSUInteger requestedCount;
@property (assign, nonatomic) NSUInteger skippedCount;
@property (assign, nonatomic) NSUInteger finishedCount;
@property (assign, nonatomic) NSTimeInterval startedTime;
@property (copy, nonatomic, nullable) SDWebImagePrefetcherCompletionBlock completionBlock;
@property (copy, nonatomic, nullable) SDWebImagePrefetcherProgressBlock progressBlock;

@end

@implementation SDWebImagePrefetcher

+ (nonnull instancetype)sharedImagePrefetcher {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{
        instance = [self new];
    });
    return instance;
}

- (nonnull instancetype)init {
    return [self initWithImageManager:[SDWebImageManager new]];
}

- (nonnull instancetype)initWithImageManager:(SDWebImageManager *)manager {
    if ((self = [super init])) {
        _manager = manager;
        _options = SDWebImageLowPriority;
        _prefetcherQueue = dispatch_get_main_queue();
        self.maxConcurrentDownloads = 3;
    }
    return self;
}

- (void)setMaxConcurrentDownloads:(NSUInteger)maxConcurrentDownloads {
    self.manager.imageDownloader.maxConcurrentDownloads = maxConcurrentDownloads;
}

- (NSUInteger)maxConcurrentDownloads {
    return self.manager.imageDownloader.maxConcurrentDownloads;
}

- (void)startPrefetchingAtIndex:(NSUInteger)index {
    NSURL *currentURL;
    @synchronized(self) {
        if (index >= self.prefetchURLs.count) return;
        currentURL = self.prefetchURLs[index];
        self.requestedCount++;
    }
    /*
     为什么这里不用__weak，不会造成循环引用吗？
     不会。因为self.progressBlock在最后被置为nil了，解除了循环引用。
     需要注意的是，当block强引用了self的对象，其实就是间接引用了self。self的对象相当于是两者的桥梁。self强引用了对象，然后block请引用了对象，相当于block强引用了self。当对象被置为nil时，self和block都不再持有对象，就打破了引用循环。
     使用self.progressBlock=nil;的方式打破循环引用的优点是：
     1. 延迟对象的释放，控制释放时机。
     2. 可以在不能使用__weak的地方使用__unsafe_unretained的，而不必担心悬挂指针。
     缺点是：
     必须要执行slef.progressBlock=nil;否则会循环引用
     
     self.completionBlock也是一样道理。
     */
    [self.manager loadImageWithURL:currentURL options:self.options progress:nil completed:^(UIImage *image, NSData *data, NSError *error, SDImageCacheType cacheType, BOOL finished, NSURL *imageURL) {
        if (!finished) return;
        self.finishedCount++;
        
        if (self.progressBlock) {
            self.progressBlock(self.finishedCount,(self.prefetchURLs).count);
        }
        if (!image) {
            // Add last failed
            self.skippedCount++;
        }
        if ([self.delegate respondsToSelector:@selector(imagePrefetcher:didPrefetchURL:finishedCount:totalCount:)]) {
            [self.delegate imagePrefetcher:self
                            didPrefetchURL:currentURL
                             finishedCount:self.finishedCount
                                totalCount:self.prefetchURLs.count
             ];
        }
        if (self.prefetchURLs.count > self.requestedCount) {
            dispatch_queue_async_safe(self.prefetcherQueue, ^{
                [self startPrefetchingAtIndex:self.requestedCount];
            });
        } else if (self.finishedCount == self.requestedCount) {
            [self reportStatus];
            if (self.completionBlock) {
                self.completionBlock(self.finishedCount, self.skippedCount);
                self.completionBlock = nil;
            }
            self.progressBlock = nil;
        }
    }];
}

- (void)reportStatus {
    NSUInteger total = (self.prefetchURLs).count;
    if ([self.delegate respondsToSelector:@selector(imagePrefetcher:didFinishWithTotalCount:skippedCount:)]) {
        [self.delegate imagePrefetcher:self
               didFinishWithTotalCount:(total - self.skippedCount)
                          skippedCount:self.skippedCount
         ];
    }
}

- (void)prefetchURLs:(nullable NSArray<NSURL *> *)urls {
    [self prefetchURLs:urls progress:nil completed:nil];
}

- (void)prefetchURLs:(nullable NSArray<NSURL *> *)urls
            progress:(nullable SDWebImagePrefetcherProgressBlock)progressBlock
           completed:(nullable SDWebImagePrefetcherCompletionBlock)completionBlock {
    /*
     在预加载之前先取消之前所有的下载操作，避免干扰
     */
    [self cancelPrefetching]; // Prevent duplicate prefetch request
    self.startedTime = CFAbsoluteTimeGetCurrent();
    self.prefetchURLs = urls;
    /*
     Q：为什么这里block不需要显式地调用copy方法，即 self.completionBlock = [completionBlock copy];
     A：因为当把block赋值给附有__strong修饰的id类型的类或者Block类型的成员变量时，会自动将Block复制到堆上。
     */
    self.completionBlock = completionBlock;
    self.progressBlock = progressBlock;
    
    // 判断urls数组是否为0.为0的话，直接执行completionBlock
    if (urls.count == 0) {
        if (completionBlock) {
            completionBlock(0,0);
        }
    } else {
        // Starts prefetching from the very first image on the list with the max allowed concurrency
        NSUInteger listCount = self.prefetchURLs.count;
        for (NSUInteger i = 0; i < self.maxConcurrentDownloads && self.requestedCount < listCount; i++) {
            [self startPrefetchingAtIndex:i];
        }
    }
}

- (void)cancelPrefetching {
    @synchronized(self) {
        self.prefetchURLs = nil;
        self.skippedCount = 0;
        self.requestedCount = 0;
        self.finishedCount = 0;
    }
    [self.manager cancelAll];
}

@end

