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
    
}
@property (nonatomic, strong) NSLock *lockFFMPEG;

- (id)initCodecWithWidth:(int)width
                  height:(int)height
             privateData:(NSData*)privateData codec:(enum AVCodecID)codecType;
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

- (id)initMPEG4CodecWithWidth:(int)width
                       height:(int)height
                  privateData:(NSData*)privateData
{
    return [self initCodecWithWidth:width height:height privateData:privateData codec:AV_CODEC_ID_MPEG4];
}

- (FFDecodeResult)decodeFrame:(NSData*)srcframeData {
	//frameReady = FALSE;
	
    if (initialized==false) {
        
        //NSLog(@"can't decode due to non-initialized");
        return DECODE_NOT_INIT;
    }
    
	packet.data = (uint8_t*)[srcframeData bytes];
	packet.size = [srcframeData length];
	
	int frameFinished = 0;
    //NSLog(@"DEBUG_H264CRASH codeCtx decodeFrame %p", codecCtx);
    
    [self.lockFFMPEG lock];
    
    int res = avcodec_decode_video2(codecCtx, srcFrame, &frameFinished, &packet);
    //no frame or err( res < 0)
    if(res <= 0 || frameFinished == 0) {
        //NSLog(@"can't decode due to no frame or err( res < 0)");
        [self.lockFFMPEG unlock];
        return DECODE_FAIL;
    }
    
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

    
//    }
}

@end
