//
//  VideoDecoder.h
//  DecoderWrapper
//
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include "libavformat/avformat.h"
#include "libswscale/swscale.h"
#include "libavcodec/avcodec.h"

enum VideoCodecType {
	kVCT_H264 = CODEC_ID_H264,
    kVCT_MPEG4 = CODEC_ID_MPEG4
};

typedef enum : NSUInteger {
    DECODE_FAIL = 0,
    DECODE_SUCCESS,
    DECODE_NOT_INIT,
    DECODE_NEED_REALLOCATE,
} FFDecodeResult;

enum VideoColorSpace {
	kVCS_RGBA32
};

typedef void (*LogCallbackfn)(int level, const char *module, const char* logLine);

@interface FFMpegDecoder : NSObject{
    
//    dispatch_queue_t h264decode_queue;
    BOOL initialized;
	struct AVCodec *codec;
	struct AVCodecContext *codecCtx;
	struct AVFrame *srcFrame;
	struct AVFrame *dstFrame;
	struct AVPicture picture;
	struct SwsContext *convertCtx;
	uint8_t *outputBuf;
	int outputBufLen;
	
	BOOL outputInit;
	BOOL frameReady;
	
	int globalWidth;
	int globalHeight;
    AVPacket packet;
}


+ (void)staticInitialize;
+ (void)registerLogCallback:(LogCallbackfn)fn;

//why duplicate function, because we don't want to break those original code
- (id)initMPEG4CodecWithWidth:(int)width
                       height:(int)height
                  privateData:(NSData*)privateData;

- (id)initH264CodecWithWidth:(int)width
			 height:(int)height 
		privateData:(NSData*)privateData;

- (FFDecodeResult)decodeFrame:(NSData*)frameData;

- (BOOL)isFrameReady;
- (NSData*)getDecodedFrame;
- (NSUInteger)getDecodedFrameWidth;
- (NSUInteger)getDecodedFrameHeight;
- (UIImage*) getDecodedFrameUI;
- (UIImage *)imageFromAVPicture:(AVPicture)pict width:(int)width height:(int)height;
@end
