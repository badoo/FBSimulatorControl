/**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

#import <FBControlCore/FBControlCore.h>
#import <XCTest/XCTest.h>

#import "FBiOSTargetDouble.h"

@interface FBiOSTargetTests : XCTestCase
@end

@implementation FBiOSTargetTests

// Helpers — use generic constructors instead of dictionary lookups, since
// FBiOSTargetConfiguration no longer maintains hardcoded device/OS tables.

+ (FBDeviceType *)deviceTypeForName:(NSString *)name
{
  return [FBDeviceType genericWithName:name];
}

+ (FBOSVersion *)osVersionForName:(NSString *)name
{
  return [FBOSVersion genericWithName:name];
}

+ (NSArray<FBDeviceType *> *)iPhoneDeviceTypes
{
  NSArray<NSString *> *names = @[
    @"iPhone 4s", @"iPhone 5", @"iPhone 5c", @"iPhone 5s",
    @"iPhone 6",  @"iPhone 6 Plus", @"iPhone 6s", @"iPhone 6s Plus",
    @"iPhone 7",  @"iPhone 7 Plus", @"iPhone SE (1st generation)",
  ];
  NSMutableArray *out = [NSMutableArray array];
  for (NSString *n in names) [out addObject:[self deviceTypeForName:n]];
  return [out copy];
}

+ (NSArray<FBDeviceType *> *)iPadDeviceTypes
{
  NSArray<NSString *> *names = @[
    @"iPad 2", @"iPad Air", @"iPad Air 2",
    @"iPad Pro", @"iPad Pro (12.9-inch)", @"iPad Pro (9.7-inch)", @"iPad Retina",
  ];
  NSMutableArray *out = [NSMutableArray array];
  for (NSString *n in names) [out addObject:[self deviceTypeForName:n]];
  return [out copy];
}

- (void)testDevicesOrderedFirst
{
  FBiOSTargetDouble *first = [FBiOSTargetDouble new];
  first.targetType = FBiOSTargetTypeDevice;
  first.state = FBiOSTargetStateBooted;
  first.deviceType = [FBiOSTargetTests deviceTypeForName:@"iPhone 6s"];
  first.osVersion = [FBiOSTargetTests osVersionForName:@"iOS 10.0"];

  FBiOSTargetDouble *second = [FBiOSTargetDouble new];
  second.targetType = FBiOSTargetTypeSimulator;
  first.state = FBiOSTargetStateBooted;
  second.deviceType = [FBiOSTargetTests deviceTypeForName:@"iPhone 6s"];
  second.osVersion = [FBiOSTargetTests osVersionForName:@"iOS 10.0"];

  XCTAssertEqual(FBiOSTargetComparison(first, second), NSOrderedDescending);
}

- (void)testOSVersionOrdering
{
  FBiOSTargetDouble *first = [FBiOSTargetDouble new];
  first.targetType = FBiOSTargetTypeDevice;
  first.state = FBiOSTargetStateBooted;
  first.deviceType = [FBiOSTargetTests deviceTypeForName:@"iPhone 6s"];
  first.osVersion = [FBiOSTargetTests osVersionForName:@"iOS 10.0"];

  FBiOSTargetDouble *second = [FBiOSTargetDouble new];
  second.targetType = FBiOSTargetTypeDevice;
  second.deviceType = [FBiOSTargetTests deviceTypeForName:@"iPhone 6s"];
  second.osVersion = [FBiOSTargetTests osVersionForName:@"iOS 10.1"];

  XCTAssertEqual(FBiOSTargetComparison(first, second), NSOrderedAscending);
}

- (void)testStateOrdering
{
  NSArray<NSNumber *> *stateOrder = @[
    @(FBiOSTargetStateCreating),
    @(FBiOSTargetStateShutdown),
    @(FBiOSTargetStateBooting),
    @(FBiOSTargetStateBooted),
    @(FBiOSTargetStateShuttingDown),
    @(FBiOSTargetStateUnknown),
  ];
  NSMutableArray<id<FBiOSTarget>> *input = [NSMutableArray array];
  for (NSNumber *stateNumber in stateOrder) {
    FBiOSTargetDouble *target = [FBiOSTargetDouble new];
    target.targetType = FBiOSTargetTypeDevice;
    target.state = stateNumber.unsignedIntegerValue;
    target.deviceType = [FBiOSTargetTests deviceTypeForName:@"iPhone 6s"];
    target.osVersion = [FBiOSTargetTests osVersionForName:@"iOS 10.0"];
    [input addObject:target];
  }
  for (NSUInteger index = 0; index < input.count; index++) {
    FBiOSTargetState expected = stateOrder[index].unsignedIntegerValue;
    FBiOSTargetState actual = input[index].state;
    XCTAssertEqual(expected, actual);
  }
}

- (void)testiPadComesBeforeiPhone
{
  NSArray<FBDeviceType *> *deviceTypes = [FBiOSTargetTests.iPhoneDeviceTypes arrayByAddingObjectsFromArray:FBiOSTargetTests.iPadDeviceTypes];
  NSMutableArray<id<FBiOSTarget>> *input = [NSMutableArray array];
  for (FBDeviceType *deviceType in deviceTypes) {
    FBiOSTargetDouble *target = [FBiOSTargetDouble new];
    target.targetType = FBiOSTargetTypeDevice;
    target.state = FBiOSTargetStateBooted;
    target.deviceType = deviceType;
    target.osVersion = [FBiOSTargetTests osVersionForName:@"iOS 10.0"];
    [input addObject:target];
  }
  NSArray<id<FBiOSTarget>> *output = [[input copy] sortedArrayUsingSelector:@selector(compare:)];
  XCTAssertEqual(input.count, output.count);
  for (NSUInteger index = 0; index < input.count; index++) {
    FBDeviceType *expected = input[index].deviceType;
    FBDeviceType *actual = output[index].deviceType;
    XCTAssertEqualObjects(expected, actual);
  }
}

@end
