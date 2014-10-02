//
//  VideoDecoder.m
//  DecoderWrapper
//
//

#import "h264Decoder.h"

#define kSwscaleFMT PIX_FMT_RGB24

LogCallbackfn g_logCallbackFn = NULL;

static BOOL beenInitialized =false;
static NSLock *ffmpegLock = nil;

static void av_log_callback(void *ptr, 
                            int level, 
                            const char *fmt, 
                            va_list vl)
{
    static char line[1024] = {0};
    const char *module = "unknown";
	
    if (ptr)
    {
        AVClass *avc = *(AVClass**) ptr;
        module = avc->item_name(ptr);
    }
	
    vsnprintf(line, sizeof(line), fmt, vl);

	if (g_logCallbackFn) {
		g_logCallbackFn(level, module, line);
	}
}

@interface FFMpegDecoder()
{
    NSInteger           _videoStream;
    NSArray             *_videoStreams;
    AVFormatContext     *_formatCtx;
    AVFrame             *_videoFrame;
    CGFloat             _videoTimeBase;
}
@property (nonatomic, strong) NSLock *lockFFMPEG;
@property (nonatomic, strong) NSString *tempHeaderFilePath;
@property (readonly, nonatomic) CGFloat fps;

- (id)initCodecWithWidth:(int)width
                  height:(int)height
             privateData:(NSData*)privateData codec:(enum AVCodecID)codecType;
- (NSString *)createTempFileForHeader;
@end


@implementation FFMpegDecoder
@synthesize lockFFMPEG;

+ (void)staticInitialize {
    
    @synchronized(self) {
		if(beenInitialized==false) {
            
            ffmpegLock= [[NSLock alloc] init];
            
            av_register_all();
            //avcodec_init();
            beenInitialized=TRUE;
        }
    }
}

+ (void)registerLogCallback:(LogCallbackfn)fn {
	g_logCallbackFn = fn;
	av_log_set_callback(av_log_callback);
}

//- (id)initWithCodec:(enum VideoCodecType)codecType
//		 colorSpace:(enum VideoColorSpace)colorSpace
//			  width:(int)width
//initWithCodec:kVCT_H264
//colorSpace:kVCS_RGBA32

- (int) openFormatContext
{
    AVFormatContext *formatCtx = NULL;
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:_tempHeaderFilePath]) {
        NSLog(@"file exist");
    }
    if (avformat_open_input(&formatCtx, [_tempHeaderFilePath cStringUsingEncoding: NSUTF8StringEncoding], NULL, NULL) < 0) {
        if (formatCtx)
            avformat_free_context(formatCtx);
        NSLog(@"[ERROR] initWithFirstFrame avformat_open_input fail");
        return -1;
    }
    
    if (avformat_find_stream_info(formatCtx, NULL) < 0) {
        
        avformat_close_input(&formatCtx);
        NSLog(@"[ERROR] initWithFirstFrame avformat_find_stream_info fail");
        return -1;
    }
    
    av_dump_format(formatCtx, 0, [_tempHeaderFilePath.lastPathComponent cStringUsingEncoding: NSUTF8StringEncoding], false);
    _formatCtx = formatCtx;
    return 0;
}

static NSArray *collectStreams(AVFormatContext *formatCtx, enum AVMediaType codecType)
{
    NSMutableArray *ma = [NSMutableArray array];
    for (NSInteger i = 0; i < formatCtx->nb_streams; ++i)
        if (codecType == formatCtx->streams[i]->codec->codec_type)
            [ma addObject: [NSNumber numberWithInteger: i]];
    return [ma copy];
}

- (void) closeVideoStream
{
    _videoStream = -1;
    //[self closeScaler];
    if (_videoFrame) {
        av_free(_videoFrame);
        _videoFrame = NULL;
    }
}

static void avStreamFPSTimeBase(AVStream *st, CGFloat defaultTimeBase, CGFloat *pFPS, CGFloat *pTimeBase)
{
    CGFloat fps, timebase;
    
    if (st->time_base.den && st->time_base.num)
        timebase = av_q2d(st->time_base);
    else if(st->codec->time_base.den && st->codec->time_base.num)
        timebase = av_q2d(st->codec->time_base);
    else
        timebase = defaultTimeBase;
    
    if (st->codec->ticks_per_frame != 1) {
        NSLog(0, @"WARNING: st.codec.ticks_per_frame=%d", st->codec->ticks_per_frame);
        //timebase *= st->codec->ticks_per_frame;
    }
    
    if (st->avg_frame_rate.den && st->avg_frame_rate.num)
        fps = av_q2d(st->avg_frame_rate);
    else if (st->r_frame_rate.den && st->r_frame_rate.num)
        fps = av_q2d(st->r_frame_rate);
    else
        fps = 1.0 / timebase;
    
    if (pFPS)
        *pFPS = fps;
    if (pTimeBase)
        *pTimeBase = timebase;
}

- (int) openVideoStream: (NSInteger) videoStream
{
    // get a pointer to the codec context for the video stream
    codecCtx = _formatCtx->streams[videoStream]->codec;
    
    // find the decoder for the video stream
    codec = avcodec_find_decoder(codecCtx->codec_id);
    if (!codec)
        return -1;
    
    // inform the codec that we can handle truncated bitstreams -- i.e.,
    // bitstreams where frame boundaries can fall in the middle of packets
    //if(codec->capabilities & CODEC_CAP_TRUNCATED)
    //    _codecCtx->flags |= CODEC_FLAG_TRUNCATED;
    
    // open codec
    [ffmpegLock lock];
    if (avcodec_open2(codecCtx, codec, NULL) < 0) {
        [ffmpegLock unlock];
        return -1;
    }
    [ffmpegLock unlock];
    
    _videoFrame = av_frame_alloc();
    
    if (!_videoFrame) {
        avcodec_close(codecCtx);
        return -1;
    }
    
    _videoStream = videoStream;
    
    // determine fps
    
    AVStream *st = _formatCtx->streams[_videoStream];
    avStreamFPSTimeBase(st, 0.04, &_fps, &_videoTimeBase);
    /*
    LoggerVideo(1, @"video codec size: %d:%d fps: %.3f tb: %f",
                self.frameWidth,
                self.frameHeight,
                _fps,
                _videoTimeBase);
    
    LoggerVideo(1, @"video start time %f", st->start_time * _videoTimeBase);
    LoggerVideo(1, @"video disposition %d", st->disposition);*/
    
    return 0;
}

- (int) openVideoStream
{
    _videoStream = -1;
    _videoStreams = collectStreams(_formatCtx, AVMEDIA_TYPE_VIDEO);
    for (NSNumber *n in _videoStreams) {
        
        const NSUInteger iStream = n.integerValue;
        
        if (0 == (_formatCtx->streams[iStream]->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
            
            if([self openVideoStream:iStream] == 0)
            {
                return 0;
            }
        }
    }
    
    return -1;
}

- (id)initWithFirstFrame:(NSData *)frameData
{
    self = [super init];
    if (self) {
        _tempHeaderFilePath = [self createTempFileForHeader];
       
        if (![[NSFileManager defaultManager] fileExistsAtPath:_tempHeaderFilePath]) {
            [[NSFileManager defaultManager] createFileAtPath:_tempHeaderFilePath contents:nil attributes:nil];
        }
        
        // Write data
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:_tempHeaderFilePath];
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:frameData];
        
        if(fileHandle != nil)
        {
            [fileHandle closeFile];
        }
        
        if([self openFormatContext] < 0)
        {
            return nil;
        }
        
        if([self openVideoStream] < 0)
        {
            return nil;
        }
        
        srcFrame = avcodec_alloc_frame();
        dstFrame = avcodec_alloc_frame();
        
        av_init_packet(&packet);
        
        self.lockFFMPEG = [[NSLock alloc] init];
        initialized=true;
    }
    return self;
}

- (id)initCodecWithWidth:(int)width
                  height:(int)height
             privateData:(NSData*)privateData codec:(enum AVCodecID)codecType
{
    if(self = [super init]) {
        //        h264decode_queue = dispatch_queue_create("h264decode_queue", NULL);
//        @synchronized(self) {
            outputInit = NO;
        codec = avcodec_find_decoder(codecType);
        if(!codec) {
            NSLog(@"------------ can not find the codec for %d",codecType);
            return nil;
        }
        codecCtx = avcodec_alloc_context3(codec);
        //NSLog(@"DEBUG_H264CRASH codeCtx alloc %p", codecCtx);
        
        // Note: for H.264 RTSP streams, the width and height are usually not specified (width and height are 0).
        // These fields will become filled in once the first frame is decoded and the SPS is processed.
        codecCtx->width = width;
        codecCtx->height = height;
        
        
        codecCtx->extradata = av_malloc([privateData length]);
        codecCtx->extradata_size = [privateData length];
        [privateData getBytes:codecCtx->extradata length:codecCtx->extradata_size];
        codecCtx->pix_fmt = PIX_FMT_YUV420P;
        
        codecCtx->workaround_bugs = 1;
        codecCtx->error_concealment = 2;	// IMPORTANT  for quality
        
        srcFrame = avcodec_alloc_frame();
        dstFrame = avcodec_alloc_frame();
        
        av_init_packet(&packet);
        
        [ffmpegLock lock];
        int res = avcodec_open2(codecCtx, codec, NULL);
        [ffmpegLock unlock];

        if (res < 0)
        {
            initialized=false;
            NSLog(@"Failed to initialize H264 decoder");
        }
        else
        {
            initialized=true;
        }
        
        self.lockFFMPEG = [[NSLock alloc] init];
        
//        }
	}
    
    return self;
}


- (id)initH264CodecWithWidth:(int)width
                      height:(int)height
                 privateData:(NSData*)privateData {
    
	return [self initCodecWithWidth:width height:height privateData:privateData codec:AV_CODEC_ID_H264];
}

- (NSString *)createTempFileForHeader
{
    // Create temporary folder
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docPath =[paths objectAtIndex:0];
    NSString *fileName = [NSString stringWithFormat:@"%@_%@", [[NSProcessInfo processInfo] globallyUniqueString], @"header.mp4"];
    NSString *path = [docPath stringByAppendingPathComponent:fileName];
    
    return path;
}

- (id)initMPEG4CodecWithWidth:(int)width
                       height:(int)height
                  privateData:(NSData*)privateData
{
    return [self initCodecWithWidth:width height:height privateData:privateData codec:AV_CODEC_ID_MPEG4];
}

-(NSData *)insertFirstFourBytes
{
    NSString *startBit = @"00 00 00 01";
    startBit = [startBit stringByReplacingOccurrencesOfString:@" " withString:@""];
    NSMutableData *commandToSend= [[NSMutableData alloc] init];
    unsigned char whole_byte;
    char byte_chars[3] = {'\0','\0','\0'};
    for (int i = 0; i < ([startBit length] / 2); i++) {
        byte_chars[0] = [startBit characterAtIndex:i*2];
        byte_chars[1] = [startBit characterAtIndex:i*2+1];
        whole_byte = strtol(byte_chars, NULL, 16);
        [commandToSend appendBytes:&whole_byte length:1];
    }
    //NSLog(@"%@", commandToSend);
    return commandToSend;
}

- (FFDecodeResult)decodeFrame:(NSData*)srcframeData {
	//frameReady = FALSE;
	
    if (initialized==false) {
        
        //NSLog(@"can't decode due to non-initialized");
        return DECODE_NOT_INIT;
    }
    
    static int fakeindex = 1;
    
    NSMutableData *nalData = [[NSMutableData alloc] init];
    const uint8_t *tempBytes = srcframeData.bytes;
    if(tempBytes[0] == 0x00 &&
       tempBytes[1] == 0x00 &&
       tempBytes[2] == 0x00 &&
       tempBytes[3] == 0x01)
    {
        NSLog(@"Complete frame");
    }
    else
    {
        [nalData appendData:[self insertFirstFourBytes]];
    }
    
    [nalData appendData:srcframeData];
    
    AVPacket _packet;
    av_init_packet(&_packet);
    _packet.data = (uint8_t*)[nalData bytes];
    _packet.size = [nalData length];
    _packet.stream_index = 0;
    _packet.pts = fakeindex;
    _packet.dts = fakeindex;
    _packet.duration = 0;
    
    fakeindex++;
	
	int frameFinished = 0;
    //NSLog(@"DEBUG_H264CRASH codeCtx decodeFrame %p", codecCtx);
    
    [self.lockFFMPEG lock];
    
    int res = avcodec_decode_video2(codecCtx, srcFrame, &frameFinished, &_packet);
    //no frame or err( res < 0)
    if(res <= 0 || frameFinished == 0) {
        //NSLog(@"can't decode due to no frame or err( res < 0)");
        [self.lockFFMPEG unlock];
        return DECODE_FAIL;
    }
    av_free_packet(&_packet);
    // Need to delay initializing the output buffers because we don't know the dimensions until we decode the first frame.
    //HBRLog(@">>>codecCtx->width/height is %d/%d", codecCtx->width, codecCtx->height);
    //HBRLog(@">>>globalWidth/height is %d/%d", globalWidth, globalHeight);
    if (!outputInit) {
        //NSLog(@"DEBUG_H264CRASH outputInit");
        if (codecCtx->width > 0 && codecCtx->height > 0) {
            globalWidth = codecCtx->width;
            globalHeight = codecCtx->height;
            
            //NSLog(@"globalWidth = %d", globalWidth);
            //NSLog(@"globalHeight = %d", globalHeight);
            
            outputBufLen = avpicture_get_size(kSwscaleFMT, codecCtx->width, codecCtx->height);
            outputBuf = av_malloc(outputBufLen);
            
            avpicture_fill((AVPicture*)dstFrame, outputBuf, kSwscaleFMT, codecCtx->width, codecCtx->height);
            
            convertCtx = sws_getContext(codecCtx->width, codecCtx->height, codecCtx->pix_fmt,  codecCtx->width,
                                        codecCtx->height, kSwscaleFMT,  SWS_FAST_BILINEAR    , NULL, NULL, NULL);
            
            if (convertCtx==NULL) {
                NSLog(@"can't get converCtx");
                [self.lockFFMPEG unlock];
                return DECODE_NEED_REALLOCATE;
            }
            
            //avpicture_free(&picture);
            avpicture_alloc(&picture, kSwscaleFMT,globalWidth,globalHeight);
            outputInit = YES;
        }
        else
        {
            NSLog(@"codecCtx->width/height is 0");
            [self.lockFFMPEG unlock];
            return DECODE_NEED_REALLOCATE;
        }
    }
    else if(globalWidth != codecCtx->width ||
            globalHeight != codecCtx->height)
    {
        [self.lockFFMPEG unlock];
        return DECODE_NEED_REALLOCATE;
    }
    
    if (frameFinished)
    {
        frameReady = YES;
    }
    
    [self.lockFFMPEG unlock];
    return DECODE_SUCCESS;
}

- (BOOL)isFrameReady {
	return frameReady;
	
}

- (NSData*)getDecodedFrame {
	if (!frameReady)
		return nil;
	[self.lockFFMPEG lock];
        sws_scale(convertCtx, (const uint8_t**)srcFrame->data, srcFrame->linesize, 0, codecCtx->height, dstFrame->data, dstFrame->linesize);
        //NSLog(@"DEBUG_H264CRASH getDecodedFrame %p", codecCtx);
    [self.lockFFMPEG unlock];
	return [NSData dataWithBytesNoCopy:outputBuf length:outputBufLen freeWhenDone:NO];
}

- (UIImage*)getDecodedFrameUI{
	if (!frameReady)
		return nil;
    
    UIImage *image = nil;
    
	[self.lockFFMPEG lock];
    sws_scale(convertCtx,(const uint8_t**)srcFrame->data, srcFrame->linesize, 0, codecCtx->height, dstFrame->data, dstFrame->linesize);
    av_picture_copy(&picture, (AVPicture*)dstFrame, kSwscaleFMT,globalWidth,globalHeight);
    
    //NSLog(@"DEBUG_H264CRASH getDecodedFrameUI %p", codecCtx);
    //NSLog(@"getDecodedFrameUI globalWidth = %d globalHeight = %d",globalWidth,globalHeight);
    
    image = [self imageFromAVPicture:picture width:globalWidth height:globalHeight];
    
    [self.lockFFMPEG unlock];
	
	return image;
}


-(UIImage *)imageFromAVPicture:(AVPicture)pict width:(int)width height:(int)height {
    
	CGBitmapInfo bitmapInfo = kCGBitmapByteOrderDefault;
	CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, pict.data[0], pict.linesize[0]*height,kCFAllocatorNull);
	CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
	CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
	CGImageRef cgImage = CGImageCreate(width,
									   height, 
									   8, 
									   24, 
									   pict.linesize[0],
									   colorSpace, 
									   bitmapInfo, 
									   provider, 
									   NULL, 
									   NO, 
									   kCGRenderingIntentDefault);
	CGColorSpaceRelease(colorSpace);
	UIImage *image = [UIImage imageWithCGImage:cgImage];
	CGImageRelease(cgImage);
	CGDataProviderRelease(provider);
	CFRelease(data);
	
	return image;
}

- (NSUInteger)getDecodedFrameWidth {
	return codecCtx->width;
}

- (NSUInteger)getDecodedFrameHeight {
	return codecCtx->height;
}


- (void)dealloc {
//    @synchronized(self) {
    
    [self.lockFFMPEG lock];

    avpicture_free(&picture); //crash1
    av_free_packet(&packet);
    sws_freeContext(convertCtx); //crash2
    av_free(codecCtx->extradata);
    [ffmpegLock lock];
    avcodec_close(codecCtx);
    [ffmpegLock unlock];
    //NSLog(@"DEBUG_H264CRASH av_free(codecCtx) :%p", codecCtx);
    av_free(codecCtx);
    av_free(srcFrame);
    av_free(dstFrame);
    av_free(outputBuf);
    
    [self.lockFFMPEG unlock];

    // remove files
    NSError *error = nil;
    [[NSFileManager defaultManager] removeItemAtURL:_tempHeaderFilePath error:&error];
    _tempHeaderFilePath = nil;
    
//    }
}

@end
