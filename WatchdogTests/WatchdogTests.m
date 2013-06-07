//
//  WatchdogTests.m
//  WatchdogTests
//
//  Created by Konstantin Pavlikhin on 6/5/13.
//  Copyright (c) 2013 Konstantin Pavlikhin. All rights reserved.
//

#import "WatchdogTests.h"

#import "Specta.h"

#define EXP_SHORTHAND

#import "Expecta.h"

#import "WDRegistrationController+Private.h"

SpecBegin(WDRegistrationController)

describe(@"WDRegistrationController", ^
{
  WDRegistrationController* SRC = [WDRegistrationController sharedRegistrationController];
  
  it(@"should accept valid serials", ^
  {
    // Test against two EC keys and two DSAs.
    NSArray* prefixes = @[@"secp384r1", @"secp521r1", @"1024", @"2048"];
    
    [prefixes enumerateObjectsUsingBlock: ^(NSString* prefix, NSUInteger idx, BOOL* stop)
    {
      NSString* publicPEMName = [prefix stringByAppendingString: @"-public"];
      
      NSString* publicPEMPath = [[NSBundle bundleForClass: [self class]] pathForResource: publicPEMName ofType: @"pem" inDirectory: nil];
      
      SRC.publicKeyPEM = [NSString stringWithContentsOfFile: publicPEMPath encoding: NSUTF8StringEncoding error: NULL];
      
      NSString* dataName = [prefix stringByAppendingString: @"-data"];
      
      NSString* dataPath = [[NSBundle bundleForClass: [self class]] pathForResource: dataName ofType: @"plist" inDirectory: nil];
      
      NSArray* dataArray = [NSPropertyListSerialization propertyListWithData: [NSData dataWithContentsOfFile: dataPath] options: 0 format: 0 error: NULL];
      
      [dataArray enumerateObjectsUsingBlock: ^(NSDictionary* customer, NSUInteger idx, BOOL* stop)
      {
        expect([SRC isSerial: customer[@"Serial"] conformsToCustomerName: customer[@"Name"] error: NULL]).to.equal(YES);
      }];
    }];
  });
  
  it(@"should transition from the unknown state to the registered state", ^AsyncBlock
  {
    // Before any checks are made we can't make any assumptions about app' state.
    expect(SRC.applicationState).to.equal(WDUnknownApplicationState);
    
    NSString* publicPEMPath = [[NSBundle bundleForClass: [self class]] pathForResource: @"1024-public" ofType: @"pem" inDirectory: nil];
    
    SRC.publicKeyPEM = [NSString stringWithContentsOfFile: publicPEMPath encoding: NSUTF8StringEncoding error: NULL];
    
    // Valid credentials from the "1024 DSA" sample.
    NSString* name = @"John Appleseed";
    
    NSString* serial = @"GAWAEFA46ZQC6LB32U4S4OAPKMAY3DQP5FHSLEYCCQFTP4ZLD7EM5IJTQUX7NZVPLVXN7WYH3M";
    
    [SRC registerWithCustomerName: name serial: serial handler: ^(enum WDSerialVerdict verdict)
    {
      expect(verdict).to.equal(WDValidSerialVerdict);
      
      expect(SRC.applicationState).to.equal(WDRegisteredApplicationState);
      
      expect([SRC registeredCustomerName]).to.equal(name);
      
      done();
    }];
  });
  
  it(@"should transition to the unregistered state", ^
  {
    expect(SRC.applicationState).to.equal(WDRegisteredApplicationState);
    
    [SRC deauthorizeAccount];
    
    expect(SRC.applicationState).to.equal(WDUnregisteredApplicationState);
  });
});

SpecEnd
