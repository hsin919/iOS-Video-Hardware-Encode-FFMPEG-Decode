//
//  EncoderDemoViewController.h
//  Encoder Demo
//
//  Created by Geraint Davies on 11/01/2013.
//  Copyright (c) 2013 GDCL http://www.gdcl.co.uk/license.htm
//

#import <UIKit/UIKit.h>

@interface EncoderDemoViewController : UIViewController
@property (weak, nonatomic) IBOutlet UIImageView *decodeView;
@property (strong, nonatomic) IBOutlet UIImageView *cameraView;
@property (strong, nonatomic) IBOutlet UILabel *serverAddress;

- (void) startPreview;

@end
