////////////////////////////////////////////////////////////////////////////////
//  
//  RegistrationController.m
//  
//  Watchdog
//  
//  Created by Konstantin Pavlikhin on 27/01/10.
//  
////////////////////////////////////////////////////////////////////////////////

#import "RegistrationController.h"

#import "RegistrationWindowController.h"

NSString* const WDCustomerNameKey = @"WDCustomerName";

NSString* const WDSerialKey = @"WDSerial";

NSString* const WDDynamicBlacklistKey = @"WDDynamicBlacklist";

// RegistrationController is a singleton instance, so we can allow ourselves this trick.
static RegistrationWindowController* registrationWindowController = nil;

@interface RegistrationController ()

// Redeclare this property as private readwrite.
@property(readwrite, assign, atomic) enum ApplicationState applicationState;

@end

@implementation RegistrationController

#pragma mark - Public Methods

+ (RegistrationController*) sharedRegistrationController
{
  static dispatch_once_t predicate;
  
  static RegistrationController *sharedRegistrationController = nil;
  
  dispatch_once(&predicate, ^{ sharedRegistrationController = [self new]; });
  
  return sharedRegistrationController;
}

// Supplied link should look like this: bundledisplayname-wd://WEDSCVBNMRFHNMJJFCV:WSXFRFVBJUHNMQWETYIOPLKJHGFDSXCVBNYFVBGFCVBNMHSGHFKAJSHCASC.
- (void) registerWithQuickApplyLink: (NSString*) link
{
  // Getting non-localized application display name.
  NSString* appDisplayName = [[[NSBundle mainBundle] infoDictionary] objectForKey: @"CFBundleDisplayName"];
  
  // Concatenating URL scheme part with forward slashes.
  NSString* schemeWithSlashes = [appDisplayName stringByAppendingString: @"-wd://"];
  
  // Wiping out link prefix.
  NSString* nameColonSerial = [link stringByReplacingOccurrencesOfString: schemeWithSlashes withString: @""];
  
  NSRange rangeOfColon = [nameColonSerial rangeOfString: @":"];
  
  // Colon name/serial separator not found — link is corrupted.
  if(rangeOfColon.location == NSNotFound)
  {
    [[[self class] corruptedQuickApplyLinkAlert] runModal];
    
    return;
  }
  
  NSString* customerNameInBase32 = nil;
  
  NSString* serial = nil;
  
  // -substringToIndex can raise an exception...
  @try
  {
    customerNameInBase32 = [nameColonSerial substringToIndex: rangeOfColon.location];
    
    serial = [nameColonSerial substringFromIndex: rangeOfColon.location + 1];
  }
  @catch(NSException* exception)
  {
    [[[self class] corruptedQuickApplyLinkAlert] runModal];
    
    return;
  }
  
  // If we are here we already got two base32 encoded parts: customer name & the serial itself. Lets decode a name!
  
  // Создаем трансформацию перевода из base32.
  SecTransformRef base32DecodeTransform = SecDecodeTransformCreate(kSecBase32Encoding, NULL);
  
  if(base32DecodeTransform)
  {
    BOOL success = NO;
    
    NSData* tempData = [customerNameInBase32 dataUsingEncoding: NSUTF8StringEncoding];
    
    // Задаем входной параметр в виде NSData.
    if(SecTransformSetAttribute(base32DecodeTransform, kSecTransformInputAttributeName, tempData, NULL))
    {
      // Запускаем трансформацию.
      CFTypeRef customerNameData = SecTransformExecute(base32DecodeTransform, NULL);
      
      if(customerNameData)
      {
        NSString* customerName = [[[NSString alloc] initWithData: customerNameData encoding: NSUTF8StringEncoding] autorelease];
        
        [self registerWithCustomerName: customerName serial: serial handler: ^(enum SerialVerdict verdict)
        {
          if(verdict != ValidSerialVerdict)
          {
            [[[self class] alertWithSerialVerdict: verdict] runModal];
            
            return;
          }
          // Show Registration Window if everything is OK.
          [self showRegistrationWindow: self];
        }];
        
        success = YES;
      }
    }
    
    CFRelease(base32DecodeTransform);
    
    if(success) return;
  }
  
  // Error state.
  [[[self class] corruptedQuickApplyLinkAlert] runModal];
}

// Tries to register application with supplied customer name & serial pair.
- (void) registerWithCustomerName: (NSString*) name serial: (NSString*) serial handler: (SerialCheckHandler) handler
{
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^
  {
    // Wiping out any existing registration data & state.
    [self deauthorizeAccount];
    
    // Launching full-featured customer data check.
    [self complexCheckOfCustomerName: name serial: serial completionHandler: ^(enum SerialVerdict verdict)
    {
      // If all of the tests pass...
      if(verdict == ValidSerialVerdict)
      {
        NSUserDefaults* userDefaults = [NSUserDefaults standardUserDefaults];
        
        [userDefaults setObject: name forKey: WDCustomerNameKey];
        
        [userDefaults setObject: serial forKey: WDSerialKey];
        
        self.applicationState = RegisteredApplicationState;
      }
      
      #warning На каком треде запускается этот хэндлер?
      // Calling handler with the corresponding verdict (used by the SerialEntryController to determine when to shake the input window).
      handler(verdict);
    }];
  });
}

- (IBAction) showRegistrationWindow: (id) sender
{
  [[self registrationWindowController] showWindow: sender];
}

- (NSString*) registeredCustomerName
{
  if([self applicationState] != RegisteredApplicationState) return nil;
  
  return [[NSUserDefaults standardUserDefaults] stringForKey: WDCustomerNameKey];
}

- (void) deauthorizeAccount
{
  NSUserDefaults* userDefaults = [NSUserDefaults standardUserDefaults];
  
  [userDefaults removeObjectForKey: WDCustomerNameKey];
  
  [userDefaults removeObjectForKey: WDSerialKey];
  
  self.applicationState = UnregisteredApplicationState;
}

- (void) checkForStoredSerialAndValidateIt
{
  // Starting a separate thread...
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^()
  {
    // Looking for serial data in user preferences.
    NSUserDefaults* userDefaults = [NSUserDefaults standardUserDefaults];
    
    NSString* name = [userDefaults stringForKey: WDCustomerNameKey];
    
    NSString* serial = [userDefaults stringForKey: WDSerialKey];
    
    // If both parameters are missing — treat it (silently) like unregistered state.
    if(!name && !serial) { self.applicationState = UnregisteredApplicationState; return; };
    
    // Prepare block handler for any other cases.
    void (^handler)(enum SerialVerdict serialVerdict) = ^(enum SerialVerdict serialVerdict)
    {
      if(serialVerdict == ValidSerialVerdict) { self.applicationState = RegisteredApplicationState; return; };
      
      // Once we've reached this point something is definitely incorrect.
      
      // Wiping out stored registration data and going to the unregistered state.
      [self deauthorizeAccount];
      
      dispatch_async(dispatch_get_main_queue(), ^()
      {
        [[[self class] alertWithSerialVerdict: serialVerdict] runModal];
      });
    };
    
    [self complexCheckOfCustomerName: name serial: serial completionHandler: handler];
  });
}

#pragma mark - Private Methods

+ (NSAlert*) corruptedQuickApplyLinkAlert
{
  NSAlert* alert = [[[NSAlert alloc] init] autorelease];
  
  [alert setMessageText: NSLocalizedString(@"Corrupted Quick-Apply Link", @"Alert title.")];
  
  [alert setInformativeText: NSLocalizedString(@"Please enter your registration data manualy.", @"Alert body.")];
  
  return alert;
}

+ (NSAlert*) corruptedRegistrationDataAlert
{
  NSAlert* alert = [[[NSAlert alloc] init] autorelease];
  
  [alert setMessageText: NSLocalizedString(@"Serial validation fail", @"Alert title.")];
  
  [alert setInformativeText: NSLocalizedString(@"Your serial is corrupted. Please, re-register application.", @"Alert body.")];
  
  return alert;
}

+ (NSAlert*) blacklistedRegistrationDataAlert
{
  NSAlert* alert = [[[NSAlert alloc] init] autorelease];
  
  [alert setMessageText: NSLocalizedString(@"Serial validation fail", @"Alert title.")];
  
  [alert setInformativeText: NSLocalizedString(@"Your serial is blacklisted. Please, contact support to get a new key.", @"Alert body.")];
  
  return alert;
}

+ (NSAlert*) piratedRegistrationDataAlert
{
  NSAlert* alert = [[[NSAlert alloc] init] autorelease];
  
  [alert setMessageText: NSLocalizedString(@"Serial validation fail", @"Alert title.")];
  
  [alert setInformativeText: NSLocalizedString(@"It seems like you are using pirated serial.", @"Alert body.")];
  
  return alert;
}

+ (NSAlert*) alertWithSerialVerdict: (enum SerialVerdict) verdict
{
  NSAlert* alert = nil;
  
  switch(verdict)
  {
    // Compiler generates warning if this constant not handled in switch.
    case ValidSerialVerdict:
    {
      alert = nil;
    }
    
    case CorruptedSerialVerdict:
    {
      alert = [self corruptedRegistrationDataAlert];
    }
    
    case BlacklistedSerialVerdict:
    {
      alert = [self blacklistedRegistrationDataAlert];
    }
    
    case PiratedSerialVerdict:
    {
      alert = [self piratedRegistrationDataAlert];
    }
  }
  
  return alert;
}

- (id) init
{
  self = [super init];
  
  if(!self) return nil;
  
  // We can't judge about application state until we execute all checks.
  _applicationState = UnknownApplicationState; // Using synthesized instance variable directly so no KVO-notification is being fired!
  
  return self;
}

// Since RegistrationController is a singleton instance this method most probably won't be called at all. But it is here for the pedantic completeness sense.
- (void) dealloc
{
  [_DSAPublicKeyPEM release], _DSAPublicKeyPEM = nil;
  
  [_serialsStaticBlacklist release], _serialsStaticBlacklist = nil;
  
  [super dealloc];
}

// Lazy RegistrationWindowController constructor.
- (RegistrationWindowController*) registrationWindowController
{
  if(!registrationWindowController) registrationWindowController = [RegistrationWindowController new];
  
  return registrationWindowController;
}

- (void) complexCheckOfCustomerName: (NSString*) name serial: (NSString*) serial completionHandler: (SerialCheckHandler) handler
{
  // Если лицензия не расшифровалась...
  if(![self isSerial: serial conformsToCustomerName: name error: NULL])
  {
    handler(CorruptedSerialVerdict); return;
  }
  
  // Если лицензия найдена в одном из черных списков...
  if([self isSerialInStaticBlacklist: serial] || [self isSerialInDynamicBlacklist: serial])
  {
    handler(BlacklistedSerialVerdict); return;
  }
  
  handler([self synchronousServerCheckWithSerial: serial]);
}

- (BOOL) isSerial: (NSString*) serial conformsToCustomerName: (NSString*) name error: (NSError**) error
{
  // Проверка на элементарные вырожденные случаи.
  if(!serial || !name || ![serial length] || ![name length]) return NO;
  
  void (^logAndReleaseError)(void) = ^
  {
    CFShow(*error), CFRelease(*error);
  };
  
  // Переводим серийник из base32 ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  
  // Создаем трансформацию перевода из base32.
  SecTransformRef base32DecodeTransform = SecDecodeTransformCreate(kSecBase32Encoding, (CFErrorRef*)error);
  
  // Если трансформация не создана — выход с ошибкой.
  if(base32DecodeTransform == NULL)
  {
    logAndReleaseError();
    
    return NO;
  }
  
  // Задаем входной параметр в виде NSData.
  if(!SecTransformSetAttribute(base32DecodeTransform, kSecTransformInputAttributeName, [serial dataUsingEncoding: NSUTF8StringEncoding], (CFErrorRef*)error))
  {
    logAndReleaseError();
    
    // Трансформация была создана — освобождаем ее.
    CFRelease(base32DecodeTransform);
    
    return NO;
  }
  
  // Запускаем трансформацию.
  CFTypeRef signature = SecTransformExecute(base32DecodeTransform, (CFErrorRef*)error);
  
  if(signature == NULL)
  {
    logAndReleaseError();
    
    // Трансформация была создана — освобождаем ее.
    CFRelease(base32DecodeTransform);
    
    return NO;
  }
  
  return [self verifyDSASignature: signature data: [name dataUsingEncoding: NSUTF8StringEncoding] error: NULL];
}

- (BOOL) verifyDSASignature: (NSData*) signature data: (NSData*) sourceData error: (NSError**) error
{
  if(!self.DSAPublicKeyPEM) [NSException raise: NSInternalInconsistencyException format: @"DSA public key is not set."];
  
  // Получаем публичный ключ от делегата в виде строки формата PEM и переводим его в дату.
  CFDataRef publicKeyData = (CFDataRef)[self.DSAPublicKeyPEM dataUsingEncoding: NSUTF8StringEncoding];
  
  // Приводим публичный ключ к виду SecKeyRef.
  SecItemImportExportKeyParameters params;
  
  params.keyUsage = NULL;
  
  params.keyAttributes = NULL;
  
  SecExternalItemType itemType = kSecItemTypePublicKey;
  
  SecExternalFormat externalFormat = kSecFormatPEMSequence;
  
  int flags = 0;
  
  NSMutableArray* temparray = [NSMutableArray array];
  
  SecItemImport(publicKeyData, NULL, &externalFormat, &itemType, flags, &params, NULL, (CFArrayRef*)&temparray);
  
  SecKeyRef publicKey = (SecKeyRef)CFArrayGetValueAtIndex((CFArrayRef)temparray, 0);
  
  // Создаем трансформацию проверки подписи.
  SecTransformRef verifier = SecVerifyTransformCreate(publicKey, (CFDataRef)signature, (CFErrorRef*)error);
  
  // Задаем дату, чью подпись мы собираемся проверять.
  SecTransformSetAttribute(verifier, kSecTransformInputAttributeName, sourceData, (CFErrorRef*)error);
  
  CFTypeRef result = SecTransformExecute(verifier, (CFErrorRef*)error);
  
  return (result == kCFBooleanTrue)? YES : NO;
}

// Performs server check of the supplied serial.
- (enum SerialVerdict) synchronousServerCheckWithSerial: (NSString*) serial
{
  NSString* serialCheckBase = [[NSBundle mainBundle] objectForInfoDictionaryKey: @"WDServerCheckURL"];
  
  NSString* userNameHash = [[NSUserName() dataUsingEncoding: NSUTF8StringEncoding] SHA1HexString];
  
  NSString* queryString = [NSString stringWithFormat: @"%@?serial=%@&account=%@", serialCheckBase, serial, userNameHash];
  
  NSMutableURLRequest* URLRequest = [NSMutableURLRequest requestWithURL: [NSURL URLWithString: queryString]];
  
  {{
    NSString* hostAppName = [[NSBundle mainBundle] objectForInfoDictionaryKey: @"CFBundleName"];
    
    [URLRequest setValue: hostAppName? hostAppName : @"Watchdog" forHTTPHeaderField: @"User-agent"];
  }}
  
  [URLRequest setTimeoutInterval: 10.0];
  
  NSURLResponse* URLResponse = nil;
  
  NSError* error = nil;
  
  #warning TODO: переделать на асинхронное поведение
  NSData* responseData = [NSURLConnection sendSynchronousRequest: URLRequest returningResponse: &URLResponse error: &error];
  
  NSString* string = [[[NSString alloc] initWithData: responseData encoding: NSUTF8StringEncoding] autorelease];
  
  if([string isEqualToString: @"Valid"])
  {
    return ValidSerialVerdict;
  }
  else if([string isEqualToString: @"Blacklisted"])
  {
    [self addSerialToDynamicBlacklist: serial];
    
    return BlacklistedSerialVerdict;
  }
  else if([string isEqualToString: @"Pirated"])
  {
    [self addSerialToDynamicBlacklist: serial];
    
    return PiratedSerialVerdict;
  }
  
  // Not going to be too strict at this point.
  return ValidSerialVerdict;
}

// Checks whether specified serial is present in the static blacklist.
- (BOOL) isSerialInStaticBlacklist: (NSString*) serial
{
  return [self.serialsStaticBlacklist containsObject: serial];
}

// Checks whether specified serial is present in the dynamic blacklist.
- (BOOL) isSerialInDynamicBlacklist: (NSString*) serial
{
  NSArray* dynamicBlacklist = [[NSUserDefaults standardUserDefaults] arrayForKey: WDDynamicBlacklistKey];
  
  return [dynamicBlacklist containsObject: serial];
}

// Adds specified serial to the dynamic blacklist.
- (void) addSerialToDynamicBlacklist: (NSString*) serial
{
  NSUserDefaults* userDefaults = [NSUserDefaults standardUserDefaults];
  
  NSArray* dynamicBlacklist = [userDefaults arrayForKey: WDDynamicBlacklistKey];
  
  if(!dynamicBlacklist) dynamicBlacklist = [NSArray array];
  
  [userDefaults setObject: [dynamicBlacklist arrayByAddingObject: serial] forKey: WDDynamicBlacklistKey];
}

@end
