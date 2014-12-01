//
//  VideoDecoder.m
//  DecoderWrapper
//
//  Copyright 2010 Dropcam. All rights reserved.
//

#import "VideoDecoder.h"

#include "swscale.h"

//#define SHOW_DEBUG_MV

LogCallbackfn g_logCallbackFn = NULL;

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

@implementation VideoDecoder

+ (void)staticInitialize {
    av_register_all();
    //avcodec_init();
}

+ (void)registerLogCallback:(LogCallbackfn)fn {
    g_logCallbackFn = fn;
    av_log_set_callback(av_log_callback);
}

- (id)initWithCodec:(enum VideoCodecType)codecType
         colorSpace:(enum VideoColorSpace)colorSpace
              width:(int)width
             height:(int)height
        privateData:(NSData*)privateData
{
    if(self = [super init])
    {
        
        codec = avcodec_find_decoder(CODEC_ID_H264);
        codecCtx = avcodec_alloc_context3(codec);
        
        // Note: for H.264 RTSP streams, the width and height are usually not specified (width and height are 0).
        // These fields will become filled in once the first frame is decoded and the SPS is processed.
        codecCtx->width = width;
        codecCtx->height = height;
        
        codecCtx->extradata = av_malloc([privateData length]);
        codecCtx->extradata_size = [privateData length];
        [privateData getBytes:codecCtx->extradata length:codecCtx->extradata_size];
        codecCtx->pix_fmt = PIX_FMT_YUV420P;
#ifdef SHOW_DEBUG_MV
        codecCtx->debug_mv = 0xFF;
#endif
        
        srcFrame = avcodec_alloc_frame();
        dstFrame = avcodec_alloc_frame();
        
        int res = avcodec_open2(codecCtx, codec, NULL);
        if (res < 0)
        {
            NSLog(@"Failed to initialize decoder");
        }
    }
    
    return self;
}

- (void)decodeFrame:(NSData*)frameData {
    AVPacket packet = {0};
    
    packet.data = (uint8_t*)[frameData bytes];
    packet.size = [frameData length];
    packet.stream_index = 0;
    packet.pts = 0x8000000000000000;
    packet.dts = 0x8000000000000000;
    //packet.duration=
    
    int frameFinished = 0;
    int res = avcodec_decode_video2(codecCtx, srcFrame, &frameFinished, &packet);
    if (res < 0)
    {
        NSLog(@"Failed to decode frame");
    }
    else
    {
        NSLog(@"Success to decode frame");
    }
    
    
    // Need to delay initializing the output buffers because we don't know the dimensions until we decode the first frame.
    if (!outputInit)
    {
        if (codecCtx->width > 0 && codecCtx->height > 0)
        {
            globalWidth = codecCtx->width;
            globalHeight = codecCtx->height;
#ifdef _DEBUG
            NSLog(@"Initializing decoder with frame size of: %dx%d", codecCtx->width, codecCtx->height);
#endif
            
            //NSLog(@"globalWidth = %d", globalWidth);
            //NSLog(@"globalHeight = %d", globalHeight);
            
            outputBufLen = avpicture_get_size(PIX_FMT_RGB24, codecCtx->width, codecCtx->height);
            outputBuf = av_malloc(outputBufLen);
            
            avpicture_fill((AVPicture*)dstFrame, outputBuf, PIX_FMT_RGB24, codecCtx->width, codecCtx->height);
            
            convertCtx = sws_getContext(codecCtx->width, codecCtx->height, codecCtx->pix_fmt,  codecCtx->width,
                                        codecCtx->height, PIX_FMT_RGB24,  SWS_FAST_BILINEAR    , NULL, NULL, NULL);
            
            
            //avpicture_free(&picture);
            avpicture_alloc(&picture, PIX_FMT_RGB24,globalWidth,globalHeight);
            outputInit = YES;
        }
        else
        {
            NSLog(@"Could not get video output dimensions");
        }
    }
    
    if (frameFinished)
        frameReady = YES;
}

- (BOOL)isFrameReady {
    return frameReady;
}


 - (UIImage*)getDecodedFrameImage
 {
	if (!frameReady)
 return nil;
	sws_scale(convertCtx,srcFrame->data, srcFrame->linesize, 0, codecCtx->height, dstFrame->data, dstFrame->linesize);
	
	avpicture_free(&picture);
	avpicture_alloc(&picture, PIX_FMT_RGB24,globalWidth,globalHeight);
	av_picture_copy(&picture, (AVPicture*)dstFrame, PIX_FMT_RGB24,globalWidth,globalHeight);
	return [self imageFromAVPicture:picture width:globalWidth height:globalHeight];
 }


 -(UIImage *)imageFromAVPicture:(AVPicture)pict width:(int)width height:(int)height
 {
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


- (NSData*)getDecodedFrame {
    //if (!frameReady)
    //return nil;
    
    sws_scale(convertCtx, (const uint8_t**)srcFrame->data, srcFrame->linesize, 0, codecCtx->height, dstFrame->data, dstFrame->linesize);
    
    return [NSData dataWithBytesNoCopy:outputBuf length:outputBufLen freeWhenDone:NO];
}

- (NSUInteger)getDecodedFrameWidth {
    return codecCtx->width;
}

- (NSUInteger)getDecodedFrameHeight {
    return codecCtx->height;
}


- (void)dealloc {
    av_free(codecCtx->extradata);
    avcodec_close(codecCtx);
    av_free(codecCtx);
    av_free(srcFrame);
    av_free(dstFrame);
    av_free(outputBuf);
}

@end
