//
//  ZSyncTouchHandler.m
//  SampleTouch
//
//  Created by Marcus S. Zarra on 11/11/09.
//  Copyright 2009 Zarra Studios, LLC. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person
//  obtaining a copy of this software and associated documentation
//  files (the "Software"), to deal in the Software without
//  restriction, including without limitation the rights to use,
//  copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following
//  conditions:
//
//  The above copyright notice and this permission notice shall be
//  included in all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
//  OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
//  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
//  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
//  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
//  OTHER DEALINGS IN THE SOFTWARE.

#import "ZSyncTouchHandler.h"
#import "ZSyncShared.h"

#define zsUUIDStringLength 55

@interface ZSyncTouchHandler()

@property (nonatomic, assign) id delegate;
@property (nonatomic, retain) NSPersistentStoreCoordinator *persistentStoreCoordinator;

@end

@implementation ZSyncTouchHandler

+ (id)shared;
{
  static ZSyncTouchHandler *sharedTouchHandler;
  if (sharedTouchHandler) return sharedTouchHandler;
  @synchronized(sharedTouchHandler) {
    sharedTouchHandler = [[ZSyncTouchHandler alloc] init];
    [[NSNotificationCenter defaultCenter] addObserver:sharedTouchHandler 
                                             selector:@selector(applicationWillTerminate:) 
                                                 name:UIApplicationWillTerminateNotification
                                               object:nil];
  }
  return sharedTouchHandler;
}

- (void)applicationWillTerminate:(NSNotification*)notification
{
  DLog(@"%s closing connection", __PRETTY_FUNCTION__);
  if ([self connection]) {
    [[self connection] close];
  }
  if ([self serviceBrowser]) {
    [[self serviceBrowser] stop];
    [_serviceBrowser release], _serviceBrowser = nil;
  }
}

- (NSString*)cachePath
{
  NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
  NSString *filePath = [paths objectAtIndex:0];
  
  return filePath;
}

- (void)requestSync;
{
  if (_serviceBrowser) {
    DLog(@"%s service browser is not nil", __PRETTY_FUNCTION__);
    return; //Already in the middle of something
  }
  
  //Need to find all of the available servers
  _serviceBrowser = [[MYBonjourBrowser alloc] initWithServiceType:zsServiceName];
  [_serviceBrowser start];
  
  // TODO: This sucks.  Has to be a better way
  // No call back from BLIP when it finds servers so we need to poll for now
  [NSTimer scheduledTimerWithTimeInterval:0.10 target:self selector:@selector(services:) userInfo:nil repeats:YES];
}

- (void)disconnectPairing;
{
  [[NSUserDefaults standardUserDefaults] removeObjectForKey:zsServerName];
  [[NSUserDefaults standardUserDefaults] removeObjectForKey:zsServerUUID];
  if ([self connection]) {
    [[self connection] close];
    [self setConnection:nil];
  }
}

- (NSString*)serverName;
{
  return [[NSUserDefaults standardUserDefaults] valueForKey:zsServerName];
}

- (void)cancelPairing;
{
  if (![self connection]) return;
  
  //Start a pairing request
  DLog(@"%s sending a pairing cancel", __PRETTY_FUNCTION__);
  NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
  [dictionary setValue:zsActID(zsActionCancelPairing) forKey:zsAction];
  
  NSString *deviceUUID = [[NSUserDefaults standardUserDefaults] valueForKey:zsDeviceID];
  if (!deviceUUID) {
    deviceUUID = [[NSProcessInfo processInfo] globallyUniqueString];
    [[NSUserDefaults standardUserDefaults] setValue:deviceUUID forKey:zsDeviceID];
  }
  
  [dictionary setValue:deviceUUID forKey:zsDeviceID];
  
  BLIPRequest *request = [BLIPRequest requestWithBody:nil properties:dictionary];
  [[self connection] sendRequest:request];
}

- (void)requestPairing:(ZSyncService*)server;
{
  MYBonjourService *service = [server service];
  BLIPConnection *conn = [[BLIPConnection alloc] initToBonjourService:service];
  [self setConnection:conn];
  [conn setDelegate:self];
  [conn open];
  [conn release], conn = nil;
}

- (void)authenticatePairing:(NSString*)code;
{
  if (![self connection]) return;
  
  //Start a pairing request
  DLog(@"%s sending a pairing code", __PRETTY_FUNCTION__);
  NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
  [dictionary setValue:zsActID(zsActionAuthenticatePairing) forKey:zsAction];
  
  NSString *deviceUUID = [[NSUserDefaults standardUserDefaults] valueForKey:zsDeviceID];
  if (!deviceUUID) {
    deviceUUID = [[NSProcessInfo processInfo] globallyUniqueString];
    [[NSUserDefaults standardUserDefaults] setValue:deviceUUID forKey:zsDeviceID];
  }
  [dictionary setValue:deviceUUID forKey:zsDeviceID];

  NSData *codeData = [code dataUsingEncoding:NSUTF8StringEncoding];
  BLIPRequest *request = [BLIPRequest requestWithBody:codeData properties:dictionary];
  [[self connection] sendRequest:request];
}

- (void)beginSyncWithService:(MYBonjourService*)service
{
  BLIPConnection *conn = [[BLIPConnection alloc] initToBonjourService:service];
  [self setConnection:conn];
  [conn setDelegate:self];
  [conn open];
  [conn release], conn = nil;
}

- (void)services:(NSTimer*)timer
{
  if (![[_serviceBrowser services] count]) {
    // TODO: This should time out at some point
    return;
  }
  [timer invalidate];
  
  NSString *serverUUID = [[NSUserDefaults standardUserDefaults] valueForKey:zsServerUUID];
  
  if (!serverUUID) { //See if the server is in this list
    [[self delegate] zSyncNoServerPaired:[self availableServers]];
    return;
  }
  
  for (MYBonjourService *service in [_serviceBrowser services]) {
    NSString *serverName = [service name];
    NSArray *components = [serverName componentsSeparatedByString:zsServerNameSeperator];
    ZAssert([components count] == 2,@"Wrong number of components: %i\n%@", [components count], serverName);
    NSString *serverUUID = [components objectAtIndex:1];
    if (![serverUUID isEqualToString:serverUUID]) continue;
    
    //Found our server, start the sync
    [self beginSyncWithService:service];
    [_serviceBrowser stop];
    [_serviceBrowser release], _serviceBrowser = nil;
    return;
  }
  //Did not find our registered server.  Fail
  [[self delegate] zSyncServerUnavailable:self];
  
}

- (void)registerDelegate:(id<ZSyncDelegate>)delegate withPersistentStoreCoordinator:(NSPersistentStoreCoordinator*)coordinator;
{
  [self setDelegate:delegate];
  [self setPersistentStoreCoordinator:coordinator];
}

- (void)receiveFile:(BLIPRequest*)request
{
  ZAssert([request complete], @"Message is incomplete");
  DLog(@"%s file received", __PRETTY_FUNCTION__);
  if (!receivedFileLookupDictionary) {
    receivedFileLookupDictionary = [[NSMutableDictionary alloc] init];
  }
  NSMutableDictionary *fileDict = [[NSMutableDictionary alloc] init];
  [fileDict setValue:[request valueOfProperty:zsStoreIdentifier] forKey:zsStoreIdentifier];
  if (![[request valueOfProperty:zsStoreConfiguration] isEqualToString:@"PF_DEFAULT_CONFIGURATION_NAME"]) {
    [fileDict setValue:[request valueOfProperty:zsStoreConfiguration] forKey:zsStoreConfiguration];
  }
  [fileDict setValue:[request valueOfProperty:zsStoreType] forKey:zsStoreType];
  
  NSString *tempFilename = [[NSProcessInfo processInfo] globallyUniqueString];
  NSString *tempPath = [[self cachePath] stringByAppendingPathComponent:tempFilename];
  DLog(@"%s file written to \n%@", __PRETTY_FUNCTION__, tempPath);
  
  DLog(@"%s request length: %i", __PRETTY_FUNCTION__, [[request body] length]);
  [[request body] writeToFile:tempPath atomically:YES];
  [fileDict setValue:tempPath forKey:zsTempFilePath];
  
  [receivedFileLookupDictionary setValue:fileDict forKey:[request valueOfProperty:zsStoreIdentifier]];
  [fileDict release], fileDict = nil;
  
  BLIPResponse *response = [request response];
  [response setValue:zsActID(zsActionFileReceived) ofProperty:zsAction];
  [response setValue:[request valueOfProperty:zsStoreIdentifier] ofProperty:zsStoreIdentifier];
  [response send];
}

- (BOOL)switchStore:(NSPersistentStore*)store withReplacement:(NSDictionary*)replacement error:(NSError**)error
{
  NSDictionary *storeOptions = [[[store options] copy] autorelease];
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSPersistentStoreCoordinator *psc = [self persistentStoreCoordinator];
  
  NSString *newFileTempPath = [replacement valueForKey:zsTempFilePath];
  NSString *fileOriginalPath = [[store URL] path];
  NSString *originalFileTempPath = [fileOriginalPath stringByAppendingPathExtension:@"zsync_"];
  
  if (![psc removePersistentStore:store error:error]) return NO;
  
  if ([fileManager fileExistsAtPath:originalFileTempPath]) {
    DLog(@"%s deleting stored file", __PRETTY_FUNCTION__);
    if ([fileManager removeItemAtPath:originalFileTempPath error:error]) return NO;
  }
  
  if ([fileManager fileExistsAtPath:fileOriginalPath]) {
    if (![fileManager moveItemAtPath:fileOriginalPath toPath:originalFileTempPath error:error]) return NO;
  }
  
  if (![fileManager moveItemAtPath:newFileTempPath toPath:fileOriginalPath error:error]) return NO;
  
  NSURL *fileURL = [NSURL fileURLWithPath:fileOriginalPath];
  if (![psc addPersistentStoreWithType:[replacement valueForKey:zsStoreType] configuration:[replacement valueForKey:zsStoreConfiguration] URL:fileURL options:storeOptions error:error]) return NO;
  
  return YES;
}

- (void)completeSync
{
  [[self persistentStoreCoordinator] lock];
  
  //First we need to verify that we received every file.  Otherwise we fail
  for (NSPersistentStore *store in [[self persistentStoreCoordinator] persistentStores]) {
    if ([receivedFileLookupDictionary objectForKey:[store identifier]]) continue;
    
    DLog(@"%s Store ID: %@\n%@", __PRETTY_FUNCTION__, [store identifier], [receivedFileLookupDictionary allKeys]);
    //Fail
    if ([[self delegate] respondsToSelector:@selector(zSync:errorOccurred:)]) {
      //Flush the temp files
      for (NSDictionary *fileDict in [receivedFileLookupDictionary allValues]) {
        NSError *error = nil;
        [[NSFileManager defaultManager] removeItemAtPath:[fileDict valueForKey:zsTempFilePath] error:&error];
        // We want to explode on this failure in dev but in prod just note it
        ZAssert(error == nil, @"Error deleting temp file: %@", [error localizedDescription]);
      }
      NSDictionary *userInfo = [NSDictionary dictionaryWithObject:[store identifier] forKey:zsStoreIdentifier];
      NSError *error = [NSError errorWithDomain:zsErrorDomain code:zsErrorFailedToReceiveAllFiles userInfo:userInfo];
      [[self delegate] zSync:self errorOccurred:error];
      [receivedFileLookupDictionary release], receivedFileLookupDictionary = nil;
    }
    [[self persistentStoreCoordinator] unlock];
    return;
  }
  
  //We have all of the files now we need to swap them out.
  for (NSPersistentStore *store in [[self persistentStoreCoordinator] persistentStores]) {
    NSDictionary *replacement = [receivedFileLookupDictionary valueForKey:[store identifier]];
    ZAssert(replacement != nil, @"Missing the replacement file for %@\n%@", [store identifier], [receivedFileLookupDictionary allKeys]);
    NSError *error = nil;
    if ([self switchStore:store withReplacement:replacement error:&error]) continue;
    ZAssert(error == nil, @"Error switching stores: %@", [error localizedDescription]);
    
    //TODO: We failed in the migration and need to roll back
  }
  
  [receivedFileLookupDictionary release], receivedFileLookupDictionary = nil;
  
  [[self connection] close];
  [self setConnection:nil];
  
  if ([[self delegate] respondsToSelector:@selector(zSyncFinished:)]) {
    [[self delegate] zSyncFinished:self];
  }
  
  [[self persistentStoreCoordinator] lock];
}

/*
 * We want to start looking for desktops to sync with here.  Once started
 * We want to maintain a list of computers found and also send out a notification
 * for every server that we discover
 */
- (void)startBrowser;
{
  if (_serviceBrowser) return;
  _serviceBrowser = [[MYBonjourBrowser alloc] initWithServiceType:zsServiceName];
  [_serviceBrowser start];
  
  [NSTimer scheduledTimerWithTimeInterval:0.10 target:self selector:@selector(services:) userInfo:nil repeats:YES];
}

- (NSArray*)availableServers;
{
  NSMutableSet *set = [NSMutableSet set];
  for (MYBonjourService *bonjourService in [_serviceBrowser services]) {
    NSString *serverName = [bonjourService name];
    NSArray *components = [serverName componentsSeparatedByString:zsServerNameSeperator];
    ZAssert([components count] == 2,@"Wrong number of components: %i\n%@", [components count], serverName);
    NSString *serverUUID = [components objectAtIndex:1];
    serverName = [components objectAtIndex:0];
    
    ZSyncService *zSyncService = [[ZSyncService alloc] init];
    [zSyncService setService:bonjourService];
    [zSyncService setName:serverName];
    [zSyncService setUuid:serverUUID];
    [set addObject:zSyncService];
    [zSyncService release], zSyncService = nil;
  }
  
  NSSortDescriptor *sort = [[NSSortDescriptor alloc] initWithKey:@"name" ascending:YES];
  NSArray *result = [set allObjects];
  result = [result sortedArrayUsingDescriptors:[NSArray arrayWithObject:sort]];
  [sort release], sort = nil;
  
  return result;
}

- (void)sendUploadComplete
{
  DLog(@"%s sending upload complete", __PRETTY_FUNCTION__);
  NSMutableDictionary *dictionary = [[NSMutableDictionary alloc] init];
  [dictionary setValue:zsActID(zsActionPerformSync) forKey:zsAction];
  BLIPRequest *request = [BLIPRequest requestWithBody:nil properties:dictionary];
  [request setNoReply:YES];
  [[self connection] sendRequest:request];
  [dictionary release], dictionary = nil;
}

- (void)uploadDataToServer
{
  [[self delegate] zSyncStarted:self];
  
  storeFileIdentifiers = [[NSMutableArray alloc] init];
  
  NSAssert([self persistentStoreCoordinator] != nil, @"PSD is nil.  Unable to upload");
  
  for (NSPersistentStore *store in [[self persistentStoreCoordinator] persistentStores]) {
    NSData *data = [[NSData alloc] initWithContentsOfMappedFile:[[store URL] path]];
    DLog(@"%s url %@\nIdentifier: %@\nSize: %i", __PRETTY_FUNCTION__, [store URL], [store identifier], [data length]);
    
    NSMutableDictionary *dictionary = [[NSMutableDictionary alloc] init];
    [dictionary setValue:[store identifier] forKey:zsStoreIdentifier];
    if (![[store configurationName] isEqualToString:@"PF_DEFAULT_CONFIGURATION_NAME"]) {
      [dictionary setValue:[store configurationName] forKey:zsStoreConfiguration];
    }
    [dictionary setValue:[store type] forKey:zsStoreType];
    [dictionary setValue:zsActID(zsActionStoreUpload) forKey:zsAction];
    
    BLIPRequest *request = [BLIPRequest requestWithBody:data properties:dictionary];
    // TODO: Compression is not working.  Need to find out why
    [request setCompressed:YES];
    [[self connection] sendRequest:request];
    [data release], data = nil;
    [dictionary release], dictionary = nil;
    DLog(@"%s file uploaded", __PRETTY_FUNCTION__);
    
    [storeFileIdentifiers addObject:[store identifier]];
  }
}

- (void)processTestFileTransfer:(BLIPRequest*)request
{
  NSData *data = [request body];
  DLog(@"%s length %i", __PRETTY_FUNCTION__, [data length]);
  NSString *path = [self cachePath];
  path = [path stringByAppendingPathComponent:@"test.jpg"];
  
  NSError *error = nil;
  if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
    DLog(@"%s deleting old file", __PRETTY_FUNCTION__);
    [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
    ZAssert(error == nil, @"error removing test file: %@", [error localizedDescription]);
  }
  
  [data writeToFile:path atomically:YES];
  DLog(@"%s file written\n%@", __PRETTY_FUNCTION__, path);
}

- (NSString*)generatePairingCode
{
  NSMutableString *string = [NSMutableString string];
  [string appendFormat:@"%i", (arc4random() % 10)];
  [string appendFormat:@"%i", (arc4random() % 10)];
  [string appendFormat:@"%i", (arc4random() % 10)];
  [string appendFormat:@"%i", (arc4random() % 10)];
  return string;
}

#pragma mark -
#pragma mark BLIP Delegate

/* Two possible states at this point. If we have a server UUID
 * then we are ready to start a sync.  If we do not have a server UUID
 * then we need to start a pairing.
 */
- (void)connectionDidOpen:(BLIPConnection*)connection 
{
  DLog(@"%s entered", __PRETTY_FUNCTION__);
  //Start by confirming that the server still supports our schema and version
  
  NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
  [dict setValue:zsActID(zsActionVerifySchema) forKey:zsAction];
  [dict setValue:zsActID([self majorVersionNumber]) forKey:zsSchemaMajorVersion];
  [dict setValue:zsActID([self minorVersionNumber]) forKey:zsSchemaMinorVersion];
  [dict setValue:[[UIDevice currentDevice] name] forKey:zsDeviceName];
  
  NSString *syncGUID = [[NSUserDefaults standardUserDefaults] stringForKey:zsSyncGUID];
  if (!syncGUID) {
    syncGUID = [[NSProcessInfo processInfo] globallyUniqueString];
    [[NSUserDefaults standardUserDefaults] setValue:syncGUID forKey:zsSyncGUID];
  }
  NSData *data = [syncGUID dataUsingEncoding:NSUTF8StringEncoding];
  BLIPRequest *request = [connection requestWithBody:data properties:dict];
  [request send];
  [dict release], dict = nil;
  DLog(@"%s initial send complete", __PRETTY_FUNCTION__);
}

/* We had an error talking to the server.  Push this error on to our delegate
 * and close the connection
 */
- (void)connection:(TCPConnection*)connection failedToOpen:(NSError*)error
{
  DLog(@"%s entered", __PRETTY_FUNCTION__);
  [_connection close], [_connection release], _connection = nil;
  [[self delegate] zSync:self errorOccurred:error];
}

- (void)connection:(BLIPConnection*)connection receivedResponse:(BLIPResponse*)response;
{
  if (![[response properties] valueOfProperty:zsAction]) {
    DLog(@"%s received empty response, ignoring", __PRETTY_FUNCTION__);
    return;
  }
  DLog(@"%s entered\n%@", __PRETTY_FUNCTION__, [[response properties] allProperties]);
  NSInteger action = [[[response properties] valueOfProperty:zsAction] integerValue];
  switch (action) {
    case zsActionFileReceived:
      ZAssert(storeFileIdentifiers != nil, @"zsActionFileReceived with a nil storeFileIdentifiers");
      [storeFileIdentifiers removeObject:[[response properties] valueOfProperty:zsStoreIdentifier]];
      if ([storeFileIdentifiers count] == 0) {
        [self sendUploadComplete];
        [storeFileIdentifiers release], storeFileIdentifiers = nil;
      }
      return;
    case zsActionRequestPairing:
      //Server has accepted the pairing request
      //Notify the delegate to present a pairing dialog
      if ([[self delegate] respondsToSelector:@selector(zSyncPairingRequestAccepted:)]) {
        // ???: This does nothing currently!
        //[[self delegate] zSyncPairingRequestAccepted:self];
      }
      return;
    case zsActionAuthenticatePassed:
      ALog(@"%s server UUID accepted: %@", __PRETTY_FUNCTION__, [response valueOfProperty:zsServerUUID]);
//      [[NSUserDefaults standardUserDefaults] setValue:[response valueOfProperty:zsServerUUID] forKey:zsServerUUID];
//      [[NSUserDefaults standardUserDefaults] setValue:[response valueOfProperty:zsServerName] forKey:zsServerName];
//      if ([[self delegate] respondsToSelector:@selector(zSyncPairingCodeApproved:)]) {
//        [[self delegate] zSyncPairingCodeApproved:self];
//      }
//      [[self serviceBrowser] stop];
//      [_serviceBrowser release], _serviceBrowser = nil;
//      [self uploadDataToServer];
      return;
    case zsActionAuthenticateFailed:
      ALog(@"%s zsActionAuthenticateFailed called, how?", __PRETTY_FUNCTION__);
//      if ([[self delegate] respondsToSelector:@selector(zSyncPairingCodeRejected:)]) {
//        [[self delegate] zSyncPairingCodeRejected:self];
//      }
      return;
    case zsActionSchemaUnsupported:
      if ([[self delegate] respondsToSelector:@selector(zSync:serverVersionUnsupported:)]) {
        NSDictionary *userInfo = [NSDictionary dictionaryWithObject:[response bodyString] forKey:NSLocalizedDescriptionKey];
        NSError *error = [NSError errorWithDomain:zsErrorDomain code:[[response valueOfProperty:zsErrorCode] integerValue] userInfo:userInfo];
        
        [[self delegate] zSync:self serverVersionUnsupported:error];
      }
      return;
    case zsActionSchemaSupported:
      if ([[NSUserDefaults standardUserDefaults] valueForKey:zsServerUUID]) {
        //Start a sync by pushing the data file to the server
        [self uploadDataToServer];
      } else {
        //We are not paired so we need to request a pairing session
        NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
        [dictionary setValue:zsActID(zsActionRequestPairing) forKey:zsAction];
        
        NSString *deviceUUID = [[NSUserDefaults standardUserDefaults] valueForKey:zsDeviceID];
        if (!deviceUUID) {
          deviceUUID = [[NSProcessInfo processInfo] globallyUniqueString];
          [[NSUserDefaults standardUserDefaults] setValue:deviceUUID forKey:zsDeviceID];
        }
        
        [dictionary setValue:deviceUUID forKey:zsDeviceID];
        
        BLIPRequest *request = [BLIPRequest requestWithBody:nil properties:dictionary];
        [[self connection] sendRequest:request];
        
        //Need to push the passcode
        [self setPasscode:[self generatePairingCode]];
        [[self delegate] zSyncHandler:self displayPairingCode:[self passcode]];
      }
      return;
    default:
      ALog(@"%s unknown action received %i", __PRETTY_FUNCTION__, action);
  }
}

- (BOOL)connection:(BLIPConnection*)connection receivedRequest:(BLIPRequest*)request
{
  NSInteger action = [[[request properties] valueOfProperty:zsAction] integerValue];
  switch (action) {
    case zsActionAuthenticatePairing:
      if ([[request bodyString] isEqualToString:[self passcode]]) {
        [[request response] setValue:zsActID(zsActionAuthenticatePassed) ofProperty:zsAction];
      } else {
        [[request response] setValue:zsActID(zsActionAuthenticateFailed) ofProperty:zsAction];
      }
      [[self delegate] zSyncPairingCodeCompleted:self];
      //Start a sync by pushing the data file to the server
      [self uploadDataToServer];
      return YES;
    case zsActionTestFileTransfer:
      [self processTestFileTransfer:request];
      return YES;
    case zsActionCompleteSync:
      DLog(@"%s completeSync", __PRETTY_FUNCTION__);
      [self performSelector:@selector(completeSync) withObject:nil afterDelay:0.01];
      return YES;
    case zsActionStoreUpload:
      DLog(@"%s receiveFile", __PRETTY_FUNCTION__);
      [self receiveFile:request];
      return YES;
    default:
      ALog(@"Unknown action received: %i", action);
      return NO;
  }
}

- (void)connectionDidClose:(TCPConnection*)connection;
{
  if (![self connection]) return;
  
  //premature closing
  [self setConnection:nil];
  
  if (![[self delegate] respondsToSelector:@selector(zSync:errorOccurred:)]) return;

  NSDictionary *userInfo = [NSDictionary dictionaryWithObject:NSLocalizedString(@"Server Hung Up", @"Server Hung Up message text") forKey:NSLocalizedDescriptionKey];
  NSError *error = [NSError errorWithDomain:zsErrorDomain code:zsErrorServerHungUp userInfo:userInfo];
  [[self delegate] zSync:self errorOccurred:error];
}

@synthesize delegate = _delegate;

@synthesize serviceBrowser = _serviceBrowser;
@synthesize connection = _connection;
@synthesize persistentStoreCoordinator = _persistentStoreCoordinator;

@synthesize majorVersionNumber;
@synthesize minorVersionNumber;
@synthesize passcode;

@end

@implementation ZSyncService

@synthesize name;
@synthesize uuid;
@synthesize service;

- (NSString*)description
{
  return [NSString stringWithFormat:@"[%@:%@]", [self name], [self uuid]];
}

- (NSUInteger)hash
{
  return [[self description] hash];
}

- (BOOL)isEqual:(id)object
{
  if (!object || ![object isKindOfClass:[ZSyncService class]]) return NO;
  
  if (![[object name] isEqualToString:[self name]]) return NO;
  if (![[object uuid] isEqualToString:[self uuid]]) return NO;
  
  return YES;
}

@end