//
//  CameraServer.m
//  Encoder Demo
//
//  Created by Geraint Davies on 19/02/2013.
//  Copyright (c) 2013 GDCL http://www.gdcl.co.uk/license.htm
//

#import "CameraServer.h"
#import "AVEncoder.h"
#import "RTSPServer.h"
#import "VideoDecoder.h"

static CameraServer* theServer;

@interface CameraServer  () <AVCaptureVideoDataOutputSampleBufferDelegate>
{
    AVCaptureSession* _session;
    AVCaptureVideoPreviewLayer* _preview;
    AVCaptureVideoDataOutput* _output;
    dispatch_queue_t _captureQueue;
    
    AVEncoder* _encoder;
    
    RTSPServer* _rtsp;
}
@property (nonatomic, strong) VideoDecoder *h264decoder;
@property (nonatomic, strong) NSData *header;
@end


@implementation CameraServer

+ (void) initialize
{
    // test recommended to avoid duplicate init via subclass
    if (self == [CameraServer class])
    {
        theServer = [[CameraServer alloc] init];
    }
}

+ (CameraServer*) server
{
    return theServer;
}

- (void)initFilePath:(NSString *)frameFilePath
{
    NSError *_error = nil;
    if (![[NSFileManager defaultManager] fileExistsAtPath:frameFilePath]) {
        [[NSFileManager defaultManager] createFileAtPath:frameFilePath contents:nil attributes:nil];
    }
    else
    {
        BOOL success = [[NSFileManager defaultManager] removeItemAtPath:frameFilePath error:&_error];
        if(!success){
            NSLog(@">>>[ERROR]Delete file fail");
        }
        [[NSFileManager defaultManager] createFileAtPath:frameFilePath contents:nil attributes:nil];
    }
}

- (void)writeImageDataToFile:(NSData *)data
{
    static int frameIndex = 0;
    NSString *frameFilePath = nil;
    
    NSFileHandle* fileHandle = nil;
    
    NSString *docsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    frameFilePath = [docsPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%d.264", frameIndex]];
    NSLog(@"Write frame %i.264 length:%i", frameIndex, (int)[data length]);
    [self initFilePath:frameFilePath];
    fileHandle = [NSFileHandle fileHandleForWritingAtPath:frameFilePath];
    [fileHandle seekToEndOfFile];
    [fileHandle writeData:data];
    
    frameIndex++;
    if(fileHandle != nil)
    {
        [fileHandle closeFile];
    }
}

- (void)initFFMPEG
{
    [VideoDecoder staticInitialize];
    
    VideoDecoder *tmpffmpegdecoder = [[VideoDecoder alloc] initWithCodec:kVCT_H264 colorSpace:kVCS_RGBA32 width:0 height:0 privateData:nil];
    self.h264decoder = tmpffmpegdecoder;
}

- (void)previewImage:(NSData *)frame
{
    NSMutableDictionary *info =[NSMutableDictionary dictionaryWithCapacity:1];
    UIImage *decodeImage = nil;
    
    [self.h264decoder decodeFrame:frame];
    decodeImage =[self.h264decoder getDecodedFrameImage];
    [[NSNotificationCenter defaultCenter] postNotificationName:C4MI_NOTIFY_RECEIVEVIDEODATA object:decodeImage userInfo:info];
}

- (BOOL)isH264IFrame:(NSData*)mediaData
{
    static int count = 0;
    int RTPHeaderBytes = 0;
    const uint8_t *tempBytes = mediaData.bytes;
    int fragment_type = tempBytes[RTPHeaderBytes + 0] & 0x1F;
    int nal_type = tempBytes[RTPHeaderBytes + 1] & 0x1F;
    int start_bit = tempBytes[RTPHeaderBytes + 1] & 0x80;
    
    if (((fragment_type == 28 || fragment_type == 29) && nal_type == 5 && start_bit == 128) || fragment_type == 5)
    {
        NSLog(@">>>> I Frame index %i length:%i", count, (int)mediaData.length);
        count++;
        return true;
    }
    NSLog(@">>>> P Frame index %i length:%i", count, (int)mediaData.length);
    count++;
    return false;
}

- (void)limitSource:(AVCaptureDevice *)dev toFPS:(int)fps
{
    if([dev isTorchModeSupported:AVCaptureTorchModeOn] &&
       floor(NSFoundationVersionNumber) > NSFoundationVersionNumber_iOS_6_1) {
        [dev lockForConfiguration:nil];
        //configure frame rate
        [dev setActiveVideoMaxFrameDuration:CMTimeMake(1, fps)];
        [dev setActiveVideoMinFrameDuration:CMTimeMake(1, fps)];
        [dev unlockForConfiguration];
    }
    else
    {
        AVCaptureConnection *conn = [_output connectionWithMediaType:AVMediaTypeVideo];
        
        CMTimeShow(conn.videoMinFrameDuration);
        CMTimeShow(conn.videoMaxFrameDuration);
        
        if (conn.isVideoMinFrameDurationSupported)
            conn.videoMinFrameDuration = CMTimeMake(1, fps);
        if (conn.isVideoMaxFrameDurationSupported)
            conn.videoMaxFrameDuration = CMTimeMake(1, fps);
        
        CMTimeShow(conn.videoMinFrameDuration);
        CMTimeShow(conn.videoMaxFrameDuration);
    }
}

- (void) startup
{
    if (_session == nil)
    {
        NSLog(@"Starting up server");
        
        // create capture device with video input
        _session = [[AVCaptureSession alloc] init];
        AVCaptureDevice* dev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        AVCaptureDeviceInput* input = [AVCaptureDeviceInput deviceInputWithDevice:dev error:nil];
        [_session addInput:input];
        [self limitSource:dev toFPS:3];
        
        // create an output for YUV output with self as delegate
        _captureQueue = dispatch_queue_create("uk.co.gdcl.avencoder.capture", DISPATCH_QUEUE_SERIAL);
        _output = [[AVCaptureVideoDataOutput alloc] init];
        [_output setSampleBufferDelegate:self queue:_captureQueue];
        NSDictionary* setcapSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                        [NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange], kCVPixelBufferPixelFormatTypeKey,
                                        nil];
        _output.videoSettings = setcapSettings;
        [_session addOutput:_output];
        
        if([dev isTorchModeSupported:AVCaptureTorchModeOn]) {
            [dev lockForConfiguration:nil];
            //configure frame rate
            [dev setActiveVideoMaxFrameDuration:CMTimeMake(1, 10)];
            [dev setActiveVideoMinFrameDuration:CMTimeMake(1, 10)];
            [dev unlockForConfiguration];
        }
        else
        {
            AVCaptureConnection *conn = [_output connectionWithMediaType:AVMediaTypeVideo];
            
            CMTimeShow(conn.videoMinFrameDuration);
            CMTimeShow(conn.videoMaxFrameDuration);
            
            if (conn.isVideoMinFrameDurationSupported)
                conn.videoMinFrameDuration = CMTimeMake(1, 10);
            if (conn.isVideoMaxFrameDurationSupported)
                conn.videoMaxFrameDuration = CMTimeMake(1, 10);
            
            CMTimeShow(conn.videoMinFrameDuration);
            CMTimeShow(conn.videoMaxFrameDuration);
        }
        AVCaptureConnection *conn = [_output connectionWithMediaType:AVMediaTypeVideo];
        if ([conn isVideoOrientationSupported]) {
            conn.videoOrientation = AVCaptureVideoOrientationPortrait;
        }
        
        [self initFFMPEG];
        
        // create an encoder
        _encoder = [AVEncoder encoderForHeight:480 andWidth:720];
        // register callback here
        [_encoder encodeWithBlock:^int(NSArray* data, double pts) {
            // data 是 frames
            int frameLength = 0;
            NSMutableData *frameData = [[NSMutableData alloc] init];
            for(NSData *frame in data)
            {
                [frameData appendData:_header];
                [frameData appendData:frame];
            }
            [self previewImage:frameData];
            NSLog(@"Total length in %i frames = %i", (int)[data count], frameLength);
            
            if (_rtsp != nil)
            {
                // _rtsp server 把encode好的資料送出去
                _rtsp.bitrate = _encoder.bitspersecond;
                [_rtsp onVideoData:data time:pts];
            }
            return 0;
        } onParams:^int(NSData *data) {
            
            // _avcC 用在這邊
            // 也可以[P2P] 抽換成 P2P hole punching 流程 (顯示 UI)
            _header = data;
            //_rtsp = [RTSPServer setupListener:data];
            return 0;
        }];
        
        // start capture and a preview layer
        [_session startRunning];
        
        
        _preview = [AVCaptureVideoPreviewLayer layerWithSession:_session];
        _preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
    }
}

- (void) captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    // 從相機拿到callback 準備做encoding
    // pass frame to encoder
    [_encoder encodeFrame:sampleBuffer];
}

- (void) shutdown
{
    NSLog(@"shutting down server");
    if (_session)
    {
        [_session stopRunning];
        _session = nil;
    }
    if (_rtsp)
    {
        [_rtsp shutdownServer];
    }
    if (_encoder)
    {
        [ _encoder shutdown];
    }
}

- (NSString*) getURL
{
    NSString* ipaddr = [RTSPServer getIPAddress];
    NSString* url = [NSString stringWithFormat:@"rtsp://%@/", ipaddr];
    return url;
}

- (AVCaptureVideoPreviewLayer*) getPreviewLayer
{
    return _preview;
}

@end
