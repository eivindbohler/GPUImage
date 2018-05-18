// 2448x3264 pixel image = 31,961,088 bytes for uncompressed RGBA

#import "GPUImageStillCamera.h"

void stillImageDataReleaseCallback(void *releaseRefCon, const void *baseAddress)
{
    free((void *)baseAddress);
}

void GPUImageCreateSampleBuffer(CVPixelBufferRef cameraFrame, CMSampleBufferRef *sampleBuffer)
{
    CMVideoFormatDescriptionRef videoInfo = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(NULL, cameraFrame, &videoInfo);

    CMTime frameTime = CMTimeMake(1, 30);
    CMSampleTimingInfo timing = {frameTime, frameTime, kCMTimeInvalid};

    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, cameraFrame, YES, NULL, NULL, videoInfo, &timing, sampleBuffer);
    CVPixelBufferUnlockBaseAddress(cameraFrame, 0);
    CFRelease(videoInfo);
    CVPixelBufferRelease(cameraFrame);
}

void GPUImageCreateResizedSampleBuffer(CVPixelBufferRef cameraFrame, CGSize finalSize, CMSampleBufferRef *sampleBuffer)
{
    // CVPixelBufferCreateWithPlanarBytes for YUV input
    
    CGSize originalSize = CGSizeMake(CVPixelBufferGetWidth(cameraFrame), CVPixelBufferGetHeight(cameraFrame));

    CVPixelBufferLockBaseAddress(cameraFrame, 0);
    GLubyte *sourceImageBytes =  CVPixelBufferGetBaseAddress(cameraFrame);
    CGDataProviderRef dataProvider = CGDataProviderCreateWithData(NULL, sourceImageBytes, CVPixelBufferGetBytesPerRow(cameraFrame) * originalSize.height, NULL);
    CGColorSpaceRef genericRGBColorspace = CGColorSpaceCreateDeviceRGB();
    CGImageRef cgImageFromBytes = CGImageCreate((int)originalSize.width, (int)originalSize.height, 8, 32, CVPixelBufferGetBytesPerRow(cameraFrame), genericRGBColorspace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst, dataProvider, NULL, NO, kCGRenderingIntentDefault);
    
    GLubyte *imageData = (GLubyte *) calloc(1, (int)finalSize.width * (int)finalSize.height * 4);
    
    CGContextRef imageContext = CGBitmapContextCreate(imageData, (int)finalSize.width, (int)finalSize.height, 8, (int)finalSize.width * 4, genericRGBColorspace,  kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGContextDrawImage(imageContext, CGRectMake(0.0, 0.0, finalSize.width, finalSize.height), cgImageFromBytes);
    CGImageRelease(cgImageFromBytes);
    CGContextRelease(imageContext);
    CGColorSpaceRelease(genericRGBColorspace);
    CGDataProviderRelease(dataProvider);
    
    CVPixelBufferRef pixel_buffer = NULL;
    CVPixelBufferCreateWithBytes(kCFAllocatorDefault, finalSize.width, finalSize.height, kCVPixelFormatType_32BGRA, imageData, finalSize.width * 4, stillImageDataReleaseCallback, NULL, NULL, &pixel_buffer);
    CMVideoFormatDescriptionRef videoInfo = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixel_buffer, &videoInfo);
    
    CMTime frameTime = CMTimeMake(1, 30);
    CMSampleTimingInfo timing = {frameTime, frameTime, kCMTimeInvalid};
    
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixel_buffer, YES, NULL, NULL, videoInfo, &timing, sampleBuffer);
    CVPixelBufferUnlockBaseAddress(cameraFrame, 0);
    CFRelease(videoInfo);
    CVPixelBufferRelease(pixel_buffer);
}

@interface GPUImageStillCamera ()
{
    AVCapturePhotoOutput *photoOutput;
}

// Methods calling this are responsible for calling dispatch_semaphore_signal(frameRenderingSemaphore) somewhere inside the block
- (void)capturePhotoProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withImageOnGPUHandler:(void (^)(NSError *error))block;

@end

@implementation GPUImageStillCamera {
    BOOL requiresFrontCameraTextureCacheCorruptionWorkaround;
    NSNumber *photoPixelFormatType;
    BOOL photoOutputIsCapturing;
    GPUImageOutput<GPUImageInput> *photoOutputFinalFilterInChain;
    void (^photoOutputCompletionHandler)(NSError *);
}

@synthesize currentCaptureMetadata = _currentCaptureMetadata;
@synthesize jpegCompressionQuality = _jpegCompressionQuality;

#pragma mark -
#pragma mark Initialization and teardown

- (id)initWithSessionPreset:(NSString *)sessionPreset cameraPosition:(AVCaptureDevicePosition)cameraPosition;
{
    if (!(self = [super initWithSessionPreset:sessionPreset cameraPosition:cameraPosition]))
    {
		return nil;
    }
    
    /* Detect iOS version < 6 which require a texture cache corruption workaround */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    requiresFrontCameraTextureCacheCorruptionWorkaround = [[[UIDevice currentDevice] systemVersion] compare:@"6.0" options:NSNumericSearch] == NSOrderedAscending;
#pragma clang diagnostic pop
    
    [self.captureSession beginConfiguration];
    
    photoOutput = [[AVCapturePhotoOutput alloc] init];
   
    // Having a still photo input set to BGRA and video to YUV doesn't work well, so since I don't have YUV resizing for iPhone 4 yet, kick back to BGRA for that device
//    if (captureAsYUV && [GPUImageContext supportsFastTextureUpload])
    if (captureAsYUV && [GPUImageContext deviceSupportsRedTextures]) {
        BOOL supportsFullYUVRange = NO;
        NSArray *supportedPixelFormats = photoOutput.availablePhotoPixelFormatTypes;
        for (NSNumber *currentPixelFormat in supportedPixelFormats) {
            if ([currentPixelFormat intValue] == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
                supportsFullYUVRange = YES;
            }
        }
        
        if (supportsFullYUVRange) {
            photoPixelFormatType = [NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange];
        } else {
            photoPixelFormatType = [NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange];
        }
    } else {
        captureAsYUV = NO;
        photoPixelFormatType = [NSNumber numberWithInt:kCVPixelFormatType_32BGRA];
        [videoOutput setVideoSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_32BGRA] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
    }

    [self.captureSession addOutput:photoOutput];

    [self.captureSession commitConfiguration];

    self.jpegCompressionQuality = 0.8;

    return self;
}

- (id)init;
{
    if (!(self = [self initWithSessionPreset:AVCaptureSessionPresetPhoto cameraPosition:AVCaptureDevicePositionBack]))
    {
		return nil;
    }
    return self;
}

- (void)removeInputsAndOutputs;
{
    [self.captureSession removeOutput:photoOutput];
    [super removeInputsAndOutputs];
}

#pragma mark -
#pragma mark Photography controls

- (void)capturePhotoAsSampleBufferWithCompletionHandler:(void (^)(CMSampleBufferRef imageSampleBuffer, NSError *error))block
{
    NSLog(@"If you want to use the method capturePhotoAsSampleBufferWithCompletionHandler:, you must comment out the line in GPUImageStillCamera.m in the method initWithSessionPreset:cameraPosition: which sets the CVPixelBufferPixelFormatTypeKey, as well as uncomment the rest of the method capturePhotoAsSampleBufferWithCompletionHandler:. However, if you do this you cannot use any of the photo capture methods to take a photo if you also supply a filter.");
    
    /*dispatch_semaphore_wait(frameRenderingSemaphore, DISPATCH_TIME_FOREVER);
    
    [photoOutput captureStillImageAsynchronouslyFromConnection:[[photoOutput connections] objectAtIndex:0] completionHandler:^(CMSampleBufferRef imageSampleBuffer, NSError *error) {
        block(imageSampleBuffer, error);
    }];
     
     dispatch_semaphore_signal(frameRenderingSemaphore);

     */
    
    return;
}

- (void)capturePhotoAsImageProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withCompletionHandler:(void (^)(UIImage *processedImage, NSError *error))block;
{
    [self capturePhotoProcessedUpToFilter:finalFilterInChain withImageOnGPUHandler:^(NSError *error) {
        UIImage *filteredPhoto = nil;

        if(!error){
            filteredPhoto = [finalFilterInChain imageFromCurrentFramebuffer];
        }
        dispatch_semaphore_signal(self->frameRenderingSemaphore);

        block(filteredPhoto, error);
    }];
}

- (void)capturePhotoAsImageProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withOrientation:(UIImageOrientation)orientation withCompletionHandler:(void (^)(UIImage *processedImage, NSError *error))block {
    [self capturePhotoProcessedUpToFilter:finalFilterInChain withImageOnGPUHandler:^(NSError *error) {
        UIImage *filteredPhoto = nil;
        
        if(!error) {
            filteredPhoto = [finalFilterInChain imageFromCurrentFramebufferWithOrientation:orientation];
        }
        dispatch_semaphore_signal(self->frameRenderingSemaphore);
        
        block(filteredPhoto, error);
    }];
}

- (void)capturePhotoAsJPEGProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withCompletionHandler:(void (^)(NSData *processedJPEG, NSError *error))block;
{
//    reportAvailableMemoryForGPUImage(@"Before Capture");

    [self capturePhotoProcessedUpToFilter:finalFilterInChain withImageOnGPUHandler:^(NSError *error) {
        NSData *dataForJPEGFile = nil;

        if(!error){
            @autoreleasepool {
                UIImage *filteredPhoto = [finalFilterInChain imageFromCurrentFramebuffer];
                dispatch_semaphore_signal(self->frameRenderingSemaphore);
//                reportAvailableMemoryForGPUImage(@"After UIImage generation");

                dataForJPEGFile = UIImageJPEGRepresentation(filteredPhoto,self.jpegCompressionQuality);
//                reportAvailableMemoryForGPUImage(@"After JPEG generation");
            }

//            reportAvailableMemoryForGPUImage(@"After autorelease pool");
        }else{
            dispatch_semaphore_signal(self->frameRenderingSemaphore);
        }

        block(dataForJPEGFile, error);
    }];
}

- (void)capturePhotoAsJPEGProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withOrientation:(UIImageOrientation)orientation withCompletionHandler:(void (^)(NSData *processedImage, NSError *error))block {
    [self capturePhotoProcessedUpToFilter:finalFilterInChain withImageOnGPUHandler:^(NSError *error) {
        NSData *dataForJPEGFile = nil;
        
        if(!error) {
            @autoreleasepool {
                UIImage *filteredPhoto = [finalFilterInChain imageFromCurrentFramebufferWithOrientation:orientation];
                dispatch_semaphore_signal(self->frameRenderingSemaphore);
                
                dataForJPEGFile = UIImageJPEGRepresentation(filteredPhoto, self.jpegCompressionQuality);
            }
        } else {
            dispatch_semaphore_signal(self->frameRenderingSemaphore);
        }
        
        block(dataForJPEGFile, error);
    }];
}

- (void)capturePhotoAsPNGProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withCompletionHandler:(void (^)(NSData *processedPNG, NSError *error))block;
{

    [self capturePhotoProcessedUpToFilter:finalFilterInChain withImageOnGPUHandler:^(NSError *error) {
        NSData *dataForPNGFile = nil;

        if(!error){
            @autoreleasepool {
                UIImage *filteredPhoto = [finalFilterInChain imageFromCurrentFramebuffer];
                dispatch_semaphore_signal(self->frameRenderingSemaphore);
                dataForPNGFile = UIImagePNGRepresentation(filteredPhoto);
            }
        }else{
            dispatch_semaphore_signal(self->frameRenderingSemaphore);
        }
        
        block(dataForPNGFile, error);        
    }];
    
    return;
}

- (void)capturePhotoAsPNGProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withOrientation:(UIImageOrientation)orientation withCompletionHandler:(void (^)(NSData *processedPNG, NSError *error))block;
{
    
    [self capturePhotoProcessedUpToFilter:finalFilterInChain withImageOnGPUHandler:^(NSError *error) {
        NSData *dataForPNGFile = nil;
        
        if(!error){
            @autoreleasepool {
                UIImage *filteredPhoto = [finalFilterInChain imageFromCurrentFramebufferWithOrientation:orientation];
                dispatch_semaphore_signal(self->frameRenderingSemaphore);
                dataForPNGFile = UIImagePNGRepresentation(filteredPhoto);
            }
        }else{
            dispatch_semaphore_signal(self->frameRenderingSemaphore);
        }
        
        block(dataForPNGFile, error);
    }];
    
    return;
}

#pragma mark - Private Methods

- (void)capturePhotoProcessedUpToFilter:(GPUImageOutput<GPUImageInput> *)finalFilterInChain withImageOnGPUHandler:(void (^)(NSError *error))block
{
    dispatch_semaphore_wait(self->frameRenderingSemaphore, DISPATCH_TIME_FOREVER);

    if (photoOutputIsCapturing) {
        block([NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorMaximumStillImageCaptureRequestsExceeded userInfo:nil]);
        return;
    }

    photoOutputIsCapturing        = YES;
    photoOutputFinalFilterInChain = finalFilterInChain;
    photoOutputCompletionHandler  = block;

    NSDictionary<NSString *, id> *settingsDict = @{(NSString *)kCVPixelBufferPixelFormatTypeKey : photoPixelFormatType};
    AVCapturePhotoSettings *photoSettings = [AVCapturePhotoSettings photoSettingsWithFormat:settingsDict];
    photoSettings.flashMode = _flashMode;

    [photoOutput capturePhotoWithSettings:photoSettings delegate:self];
}

- (void)captureOutput:(AVCaptureOutput *)output didFinishProcessingPixelBuffer:(CVPixelBufferRef)pixelBuffer error:(NSError *)error
{
    // For now, resize photos to fix within the max texture size of the GPU

    CGSize sizeOfPhoto = CGSizeMake(CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer));
    CGSize scaledImageSizeToFitOnGPU = [GPUImageContext sizeThatFitsWithinATextureForSize:sizeOfPhoto];

    CMSampleBufferRef sampleBuffer = NULL;

    if (!CGSizeEqualToSize(sizeOfPhoto, scaledImageSizeToFitOnGPU)) {
        if (CVPixelBufferGetPlaneCount(pixelBuffer) > 0) {
            NSAssert(NO, @"Error: no downsampling for YUV input in the framework yet");
        } else {
            GPUImageCreateResizedSampleBuffer(pixelBuffer, scaledImageSizeToFitOnGPU, &sampleBuffer);
        }

        dispatch_semaphore_signal(self->frameRenderingSemaphore);
        [photoOutputFinalFilterInChain useNextFrameForImageCapture];
        [self captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:output.connections.firstObject];
        dispatch_semaphore_wait(self->frameRenderingSemaphore, DISPATCH_TIME_FOREVER);
        if (pixelBuffer != NULL) {
            CFRelease(sampleBuffer);
        }
    } else {
        // This is a workaround for the corrupt images that are sometimes returned when taking a photo with the front camera and using the iOS 5.0 texture caches
        AVCaptureDevicePosition currentCameraPosition = [[self->videoInput device] position];
        if ((currentCameraPosition != AVCaptureDevicePositionFront) || (![GPUImageContext supportsFastTextureUpload]) || !self->requiresFrontCameraTextureCacheCorruptionWorkaround) {
            GPUImageCreateSampleBuffer(pixelBuffer, &sampleBuffer);
            dispatch_semaphore_signal(self->frameRenderingSemaphore);
            [photoOutputFinalFilterInChain useNextFrameForImageCapture];
            [self captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:output.connections.firstObject];
            dispatch_semaphore_wait(self->frameRenderingSemaphore, DISPATCH_TIME_FOREVER);
        }
    }
}

#pragma mark - AVCapturePhotoCaptureDelegate

- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error
{
    if (photoOutputCompletionHandler == nil || photoOutputFinalFilterInChain == nil) {
        return;
    }

    if (photo.pixelBuffer == nil) {
        photoOutputCompletionHandler(error);
        photoOutputCompletionHandler = nil;
        return;
    }

    [self captureOutput:output didFinishProcessingPixelBuffer:photo.pixelBuffer error:error];

    _currentCaptureMetadata = photo.metadata;

    photoOutputCompletionHandler(nil);

    _currentCaptureMetadata = nil;
    photoOutputCompletionHandler = nil;
    photoOutputFinalFilterInChain = nil;
}

@end
