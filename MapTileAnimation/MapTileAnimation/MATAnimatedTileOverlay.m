//
//  MATAnimatedTileOverlay.m
//  MapTileAnimationDemo
//
//  Created by Bruce Johnson on 6/12/14.
//  Copyright (c) 2014 The Climate Corporation. All rights reserved.
//


#import "MATAnimatedTileOverlay.h"
#import "MATAnimationTile.h"
#import "MATAnimatedTileOverlayDelegate.h"

#define Z_INDEX "{z}"
#define X_INDEX "{x}"
#define Y_INDEX "{y}"

NSString *const MATAnimatedTileOverlayErrorDomain = @"MATAnimatedTileOverlayError";

@interface MATAnimatedTileOverlay ()

@property (nonatomic, readwrite, strong) NSOperationQueue *fetchQueue;
@property (nonatomic, readwrite, strong) NSOperationQueue *downloadQueue;

@property (nonatomic, readwrite, strong) NSArray *templateURLs;
@property (nonatomic, readwrite) NSInteger numberOfAnimationFrames;
@property (nonatomic, assign) NSTimeInterval frameDuration;
@property (nonatomic, readwrite, strong) NSTimer *timer;
@property (readwrite, assign) MATAnimatingState currentAnimatingState;
@property (strong, nonatomic) NSSet *mapTiles;
@property (nonatomic) NSInteger tileSize;

@end

// TODO: Purge NSURLCache on memory warnings

@implementation MATAnimatedTileOverlay

#pragma mark - Lifecycle

- (id) initWithTemplateURLs: (NSArray *)templateURLs frameDuration:(NSTimeInterval)frameDuration
{
	self = [super init];
	if (self)
	{
        //Initialize network caching settings
        NSURLCache *URLCache = [[NSURLCache alloc] initWithMemoryCapacity:4 * 1024 * 1024
                                                             diskCapacity:32 * 1024 * 1024
                                                                 diskPath:nil];
        [NSURLCache setSharedURLCache:URLCache];
        
		self.templateURLs = templateURLs;
		self.numberOfAnimationFrames = [templateURLs count];
		self.frameDuration = frameDuration;
		self.currentFrameIndex = 0;
		self.fetchQueue = [[NSOperationQueue alloc] init];
		[self.fetchQueue setMaxConcurrentOperationCount: 1];  //essentially a serial queue
		self.downloadQueue = [[NSOperationQueue alloc] init];
		[self.downloadQueue setMaxConcurrentOperationCount: 25];
		
		self.tileSize = 256;
		
		self.currentAnimatingState = MATAnimatingStateStopped;
		self.minimumZ = 4;
		self.maximumZ = 11;

	}
	return self;
}

#pragma mark - Custom accessors

//setter for currentAnimatingState
- (void) setCurrentAnimatingState:(MATAnimatingState)currentAnimatingState {
    //set new animating state if state different than old value
    if(currentAnimatingState != _currentAnimatingState){
        _currentAnimatingState = currentAnimatingState;
        //call the optional delegate method – ensure the delegate object actually implements an optional method before the method is called
        if ([self.delegate respondsToSelector:@selector(animatedTileOverlay:didChangeAnimationState:)]) {
            [self.delegate animatedTileOverlay:self didChangeAnimationState:_currentAnimatingState];
        }
    }
}

#pragma mark MKOverlay

- (CLLocationCoordinate2D)coordinate
{
    return MKCoordinateForMapPoint(MKMapPointMake(MKMapRectGetMidX([self boundingMapRect]), MKMapRectGetMidY([self boundingMapRect])));
}

- (MKMapRect)boundingMapRect
{
    return MKMapRectWorld;
}

#pragma mark - IBActions

/*
 called from the animation timer on a periodic basis
 */
- (IBAction)updateImageTileAnimation:(NSTimer *)aTimer
{
	[self.fetchQueue addOperationWithBlock:^{
		self.currentFrameIndex++;
        //        NSLog(@"frame: %@", @(self.currentFrameIndex).stringValue);
		//reset the index counter if we have rolled over
		if (self.currentFrameIndex > self.numberOfAnimationFrames - 1) {
			self.currentFrameIndex = 0;
		}
        
        [self updateTilesToFrameIndex:self.currentFrameIndex];
	}];
}

#pragma mark - Public

- (void)startAnimating;
{
	self.timer = [NSTimer scheduledTimerWithTimeInterval:self.frameDuration target:self selector:@selector(updateImageTileAnimation:) userInfo:nil repeats:YES];
	[self.timer fire];
	self.currentAnimatingState = MATAnimatingStateAnimating;
    
}

- (void)pauseAnimating
{
	[self.timer invalidate];
    [self.downloadQueue cancelAllOperations];
	[self.fetchQueue cancelAllOperations];
	self.timer = nil;
	self.currentAnimatingState = MATAnimatingStateStopped;
}

/*
 will fetch all the tiles for a mapview's map rect and zoom scale.  Provides a download progres block and download completetion block
 */
- (void)fetchTilesForMapRect:(MKMapRect)aMapRect
                   zoomScale:(MKZoomScale)aScale
               progressBlock:(void(^)(NSUInteger currentTimeIndex, BOOL *stop))progressBlock
             completionBlock:(void (^)(BOOL success, NSError *error))completionBlock
{
	//check to see if our zoom level is supported by our tile server
    
    //super zoomed in (cap zoom scale)
    if(aScale > 0.000500000) {
        aScale = 0.000500000;
        UIAlertView *message = [[UIAlertView alloc] initWithTitle:@"Zoom Scale Alert"
                                                          message:@"You've zoomed in past tile data we have"
                                                         delegate:nil
                                                cancelButtonTitle:@"CLOSE"
                                                otherButtonTitles:nil];
        
        [message show];
    }
    
    //super zoomed out (cap zoom scale)
    if(aScale < 0.000020000) {
        aScale = 0.000020000;
        UIAlertView *message = [[UIAlertView alloc] initWithTitle:@"Zoom Scale Alert"
                                                          message:@"You've zoomed out past tile data we have"
                                                         delegate:nil
                                                cancelButtonTitle:@"CLOSE"
                                                otherButtonTitles:nil];
        
        [message show];
    }
    
    NSLog(@"zoom scale: %lf", aScale);
	NSUInteger zoomLevel = [self zoomLevelForZoomScale: aScale];
	if (zoomLevel > self.maximumZ || zoomLevel < self.minimumZ) {
		
		NSError *error = [[NSError alloc] initWithDomain: NSStringFromClass([self class])
													code: MATAnimatingErrorInvalidZoomLevel
												userInfo: @{NSLocalizedDescriptionKey: [NSString stringWithFormat: @"Current Zoom Level %lu not supported (min %ld max %ld scale %lf)", (unsigned long)zoomLevel, (long)self.minimumZ, (long)self.maximumZ, aScale]}];
		
		[self.delegate animatedTileOverlay: self didHaveError: error];

		dispatch_async(dispatch_get_main_queue(), ^{
            completionBlock(NO, error);
		});
		
		return;
	}

	self.currentAnimatingState = MATAnimatingStateLoading;
    
	[self.fetchQueue addOperationWithBlock:^{
        
		//calculate the tiles rects needed for a given mapRect and create the MATAnimationTile objects
		NSSet *mapTiles = [self mapTilesInMapRect:aMapRect zoomScale:aScale];
		
		//at this point we have a set of MATAnimationTiles we need to derive the urls for each tile, for each time index
		for (MATAnimationTile *tile in mapTiles) {
			NSMutableArray *array = [NSMutableArray arrayWithCapacity: self.numberOfAnimationFrames];
			for (NSUInteger timeIndex = 0; timeIndex < self.numberOfAnimationFrames; timeIndex++) {
				NSString *tileURL = [self URLStringForX:tile.xCoordinate Y:tile.yCoordinate Z:tile.zCoordinate timeIndex:timeIndex];
				[array addObject:tileURL];
			}
			tile.tileURLs = [array copy];
		}
		
		//update the tile array with new tile objects
		self.mapTiles = mapTiles;
		//set and check a flag to see if the calling object has stopped tile loading
		__block BOOL didStopFlag = NO;
		//start downloading the tiles for a given time index, we want to download all the tiles for a time index
		//before we move onto the next time index
		for (NSUInteger timeIndex = 0; timeIndex < self.numberOfAnimationFrames; timeIndex++) {
			if (didStopFlag) {
				NSLog(@"User Stopped");
				[self.downloadQueue cancelAllOperations];
				self.currentAnimatingState = MATAnimatingStateStopped;
				break;
			}
            
			//loop over all the tiles for this time index
			for (MATAnimationTile *tile in self.mapTiles) {
				NSString *tileURL = tile.tileURLs[timeIndex];
				//this will return right away
				[self fetchAndCacheImageTileAtURL:tileURL];
			}
			//wait for all the tiles in this time index to download before proceeding the next time index
			[self.downloadQueue waitUntilAllOperationsAreFinished];
            
			dispatch_async(dispatch_get_main_queue(), ^{
				progressBlock(timeIndex, &didStopFlag);
			});
		}
		[self.downloadQueue waitUntilAllOperationsAreFinished];
        
		//set the current image to the first time index
		[self moveToFrameIndex:self.currentFrameIndex];
		
		dispatch_async(dispatch_get_main_queue(), ^{
            completionBlock(!didStopFlag, nil);
		});
	}];
}

/*
 updates the MATAnimationTile tile image property to point to the tile image for the current time index
 */
- (void)moveToFrameIndex:(NSInteger)frameIndex
{
    if (self.currentAnimatingState == MATAnimatingStateAnimating) {
        [self pauseAnimating];
    }
    [self updateTilesToFrameIndex:frameIndex];
}

- (MATAnimationTile *)tileForMapRect:(MKMapRect)aMapRect zoomScale:(MKZoomScale)aZoomScale;
{
	if (self.mapTiles) {
		MATTileCoordinate coord = [self tileCoordinateForMapRect: aMapRect zoomScale: aZoomScale];
		for (MATAnimationTile *tile in self.mapTiles) {
			if (coord.xCoordinate == tile.xCoordinate &&
                coord.yCoordinate == tile.yCoordinate &&
                coord.zCoordiante == tile.zCoordinate)
            {
				return tile;
			}
		}
	}
	return nil;
}

- (NSString *)templateURLStringForFrameIndex: (NSUInteger)frameIndex {
	return self.templateURLs[frameIndex];
}

#pragma  mark - Private

/*
 will fetch a tile image and cache it to the network cache (i.e. do nothing with it)
 */
- (void)fetchAndCacheImageTileAtURL:(NSString *)aUrlString
{
	[self.downloadQueue addOperationWithBlock: ^{
		NSString *urlString = [aUrlString copy];
		
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        
        NSURLSession *session = [NSURLSession sharedSession];
        NSURLRequest *request = [[NSURLRequest alloc] initWithURL:[NSURL URLWithString:urlString] cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:5];
        NSURLSessionTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            [self checkResponseForError:(NSHTTPURLResponse *)response data:data];
            dispatch_semaphore_signal(semaphore);
        }];
        [task resume];
        // have the thread wait until the download task is done
        dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 60)); //timeout is 10 secs.
	}];
}

- (void)updateTilesToFrameIndex:(NSInteger)frameIndex
{
    // RSS: Tried to have this data updating occur on a background thread, but it causes threading issues.
    // I wanted this in the background so that it doesn't block the main thread when it's loading cached
    // data. However, scrubbing quickly causes multiple calls to occur concurrently, which causes the
    // currentFrameIndex to enter a race condition. If we want to do this in the background, I think we'll
    // need to create a serial background queue.
//    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (MATAnimationTile *tile in self.mapTiles) {
            NSURL *url = [[NSURL alloc] initWithString:tile.tileURLs[frameIndex]];
            NSURLRequest *request = [[NSURLRequest alloc] initWithURL:url cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:1];
            NSURLResponse *response;
            NSError *error;
            NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
            
            BOOL errorOccurred = [self checkResponseForError:(NSHTTPURLResponse *)response data:data];
            
            if (!errorOccurred) {
//                dispatch_async(dispatch_get_main_queue(), ^{
                    tile.currentImageTile = [UIImage imageWithData:data];
//                });
            }
        }
        
        self.currentFrameIndex = frameIndex;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate animatedTileOverlay:self didAnimateWithAnimationFrameIndex:self.currentFrameIndex];
        });
//    });
}

/*
 derives a URL string from the template URLs, needs tile coordinates and a time index
 */
- (NSString *)URLStringForX:(NSInteger)xValue Y:(NSInteger)yValue Z:(NSInteger)zValue timeIndex:(NSInteger)aTimeIndex
{
	NSString *currentTemplateURL = [self.templateURLs objectAtIndex: aTimeIndex];
	NSString *returnString = nil;
	NSString *xString = [NSString stringWithFormat: @"%ld", (long)xValue];
	NSString *yString = [NSString stringWithFormat: @"%ld", (long)yValue];
	NSString *zString = [NSString stringWithFormat: @"%ld", (long)zValue];
	
	NSString *replaceX = [currentTemplateURL stringByReplacingOccurrencesOfString: @X_INDEX withString: xString];
	NSString *replaceY = [replaceX stringByReplacingOccurrencesOfString: @Y_INDEX withString: yString];
	NSString *replaceZ = [replaceY stringByReplacingOccurrencesOfString: @Z_INDEX withString: zString];
	
	returnString = replaceZ;
	return returnString;
}

- (MATTileCoordinate) tileCoordinateForMapRect: (MKMapRect)aMapRect zoomScale:(MKZoomScale)aZoomScale
{
	MATTileCoordinate coord = {0 , 0, 0};
	
	NSUInteger zoomLevel = [self zoomLevelForZoomScale: aZoomScale];
    CGPoint mercatorPoint = [self mercatorTileOriginForMapRect: aMapRect];
    NSUInteger tilex = floor(mercatorPoint.x * [self worldTileWidthForZoomLevel:zoomLevel]);
    NSUInteger tiley = floor(mercatorPoint.y * [self worldTileWidthForZoomLevel:zoomLevel]);
    
	coord.xCoordinate = tilex;
	coord.yCoordinate = tiley;
	coord.zCoordiante = zoomLevel;
	
	return coord;
}

/*
 calculates the number of tiles, the tile coordinates and tile MapRect frame given a MapView's MapRect and zoom scale
 returns an array MATAnimationTile objects
 */
- (NSSet *) mapTilesInMapRect: (MKMapRect)aRect zoomScale: (MKZoomScale)aScale
{
    NSInteger z = [self zoomLevelForZoomScale: aScale];//zoomScaleToZoomLevel(aScale, (double)self.tileSize);
    NSMutableSet *tiles = nil;
	
    NSInteger minX = floor((MKMapRectGetMinX(aRect) * aScale) / self.tileSize);
    NSInteger maxX = ceil((MKMapRectGetMaxX(aRect) * aScale) / self.tileSize);
    NSInteger minY = floor((MKMapRectGetMinY(aRect) * aScale) / self.tileSize);
    NSInteger maxY = ceil((MKMapRectGetMaxY(aRect) * aScale) / self.tileSize);
    
    if (!tiles) {
        tiles = [NSMutableSet set];
    }
    
	for(NSInteger x = minX; x <= maxX; x++) {
        for(NSInteger y = minY; y <=maxY; y++) {
					
			MKMapRect frame = MKMapRectMake((double)(x * self.tileSize) / aScale, (double)(y * self.tileSize) / aScale, self.tileSize / aScale, self.tileSize / aScale);
			MATAnimationTile *tile = [[MATAnimationTile alloc] initWithFrame: frame xCord: x yCord: y zCord: z];
			[tiles addObject:tile];
            
        }
    }
    return [NSSet setWithSet: tiles];
}

/*
 Determine the number of tiles wide *or tall* the world is, at the given zoomLevel.
 (In the Spherical Mercator projection, the poles are cut off so that the resulting 2D map is "square".)
 */
- (NSUInteger)worldTileWidthForZoomLevel:(NSUInteger)zoomLevel
{
    return (NSUInteger)(pow(2,zoomLevel));
}

/**
 * Similar to above, but uses a MKZoomScale to determine the
 * Mercator zoomLevel. (MKZoomScale is a ratio of screen points to
 * map points.)
 */
- (NSUInteger)zoomLevelForZoomScale:(MKZoomScale)zoomScale
{
    CGFloat realScale = zoomScale / [[UIScreen mainScreen] scale];
    NSUInteger z = (NSUInteger)(log(realScale)/log(2.0)+20.0);
	
    z += ([[UIScreen mainScreen] scale] - 1.0);
    return z;
}

/**
 * Given a MKMapRect, this reprojects the center of the mapRect
 * into the Mercator projection and calculates the rect's top-left point
 * (so that we can later figure out the tile coordinate).
 *
 * See http://wiki.openstreetmap.org/wiki/Slippy_map_tilenames#Derivation_of_tile_names
 */
- (CGPoint)mercatorTileOriginForMapRect:(MKMapRect)mapRect
{
    MKCoordinateRegion region = MKCoordinateRegionForMapRect(mapRect);
    
    // Convert lat/lon to radians
    CGFloat x = (region.center.longitude) * (M_PI/180.0); // Convert lon to radians
    CGFloat y = (region.center.latitude) * (M_PI/180.0); // Convert lat to radians
    y = log(tan(y)+1.0/cos(y));
    
    // X and Y should actually be the top-left of the rect (the values above represent
    // the center of the rect)
    x = (1.0 + (x/M_PI)) / 2.0;
    y = (1.0 - (y/M_PI)) / 2.0;
	
    return CGPointMake(x, y);
}

- (BOOL)checkResponseForError:(NSHTTPURLResponse *)response data:(NSData *)data
{
    if (data) {
        if (response.statusCode != 200) {
            NSString *localizedDescription = [NSString stringWithFormat:@"Error during fetch. Image tile HTTP respsonse code %ld, URL %@", (long)response.statusCode, response.URL];
            NSError *error = [NSError errorWithDomain:MATAnimatedTileOverlayErrorDomain code:MATAnimatingErrorBadURLResponseCode userInfo:@{ NSLocalizedDescriptionKey : localizedDescription }];
            [self sendErrorToDelegate:error];
            return YES;
        }
    } else {
        NSString *localizedDescription = [NSString stringWithFormat:@"No image data. HTTP respsonse code %ld, URL %@", (long)response.statusCode, response.URL];
        NSError *error = [NSError errorWithDomain:MATAnimatedTileOverlayErrorDomain code:MATAnimatingErrorNoImageData userInfo:@{ NSLocalizedDescriptionKey : localizedDescription }];
        [self sendErrorToDelegate:error];
        return YES;
    }
    return NO;
}

- (void)sendErrorToDelegate:(NSError *)error
{
    if ([self.delegate respondsToSelector:@selector(animatedTileOverlay:didHaveError:)]) {
        [self.delegate animatedTileOverlay:self didHaveError:error];
    }
}

#pragma mark - Protocol conformance

@end
