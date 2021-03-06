//
//  WDRegistrationController_Private.h
//  Watchdog
//
//  Created by Konstantin Pavlikhin on 6/5/13.
//  Copyright (c) 2013 Konstantin Pavlikhin. All rights reserved.
//

#import "WDRegistrationController.h"

@interface WDRegistrationController ()

// These method prototypes are here for unit testing purposes.

- (NSDictionary*) decomposeQuickApplyLink: (NSString*) link utilizingBundleName: (NSString*) bundleName;

- (BOOL) isSerial: (NSString*) serial conformsToCustomerName: (NSString*) name error: (NSError**) error;

@end
