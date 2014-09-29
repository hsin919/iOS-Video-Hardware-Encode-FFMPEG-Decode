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
#import "h264Decoder.h"

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
@property (nonatomic, strong) FFMpegDecoder *h264decoder;
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

- (void)initFFMPEG
{
    [FFMpegDecoder staticInitialize];
    
    FFMpegDecoder *tmpffmpegdecoder = [[FFMpegDecoder alloc] initH264CodecWithWidth:0 height:0 privateData:nil];
    self.h264decoder = tmpffmpegdecoder;
}

- (void)previewImage:(NSData *)frame
{
    NSMutableDictionary *info =[NSMutableDictionary dictionaryWithCapacity:1];
    UIImage *decodeImage = nil;
    
    FFDecodeResult result = [self.h264decoder decodeFrame:frame];
    if(result == DECODE_SUCCESS)
    {
        NSLog(@"FFMPEG decode DECODE_SUCCESS");
        decodeImage =[self.h264decoder getDecodedFrameUI];
        [[NSNotificationCenter defaultCenter] postNotificationName:C4MI_NOTIFY_RECEIVEVIDEODATA object:decodeImage userInfo:info];
    }
    else
    {
        NSLog(@"FFMPEG decode fail:%i", result);
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
        
        // create an output for YUV output with self as delegate
        _captureQueue = dispatch_queue_create("uk.co.gdcl.avencoder.capture", DISPATCH_QUEUE_SERIAL);
        _output = [[AVCaptureVideoDataOutput alloc] init];
        [_output setSampleBufferDelegate:self queue:_captureQueue];
        NSDictionary* setcapSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                        [NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange], kCVPixelBufferPixelFormatTypeKey,
                                        nil];
        _output.videoSettings = setcapSettings;
        [_session addOutput:_output];
        
        [self initFFMPEG];
        
        // create an encoder
        _encoder = [AVEncoder encoderForHeight:480 andWidth:720];
        // register callback here
        [_encoder encodeWithBlock:^int(NSArray* data, double pts) {
            // data 是 frames
            if([data count] > 0)
            {
                [self previewImage:[data objectAtIndex:0]];
            }
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
            _rtsp = [RTSPServer setupListener:data];
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
