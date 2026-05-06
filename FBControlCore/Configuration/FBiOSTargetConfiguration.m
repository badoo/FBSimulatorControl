/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBiOSTargetConfiguration.h"

#import "FBArchitecture.h"


@implementation FBiOSTargetScreenInfo

- (instancetype)initWithWidthPixels:(NSUInteger)widthPixels heightPixels:(NSUInteger)heightPixels scale:(float)scale
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _widthPixels = widthPixels;
  _heightPixels = heightPixels;
  _scale = scale;

  return self;
}

- (BOOL)isEqual:(FBiOSTargetScreenInfo *)object
{
  if (![object isKindOfClass:FBiOSTargetScreenInfo.class]) {
    return NO;
  }
  return self.widthPixels == object.widthPixels && self.heightPixels == object.heightPixels && self.scale == object.scale;
}

- (NSUInteger)hash
{
  return self.widthPixels ^ self.heightPixels ^ (NSUInteger) self.scale;
}

- (id)copyWithZone:(NSZone *)zone
{
  return self;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"Screen Pixels %lu,%lu | Scale %fX", self.widthPixels, self.heightPixels, self.scale];
}

@end

@implementation FBDeviceType

#pragma mark Initializers

+ (instancetype)genericWithName:(NSString *)name
{
  // Infer family from the name prefix so callers don't have to enumerate
  // every concrete model. CoreSimulator returns names like "iPhone 16 Pro",
  // "iPad Pro (11-inch) (4th generation)", "Apple TV 4K (3rd generation)";
  // MobileDevice returns either a model name or a productType like
  // "iPhone16,2" — both start with the family token.
  FBControlCoreProductFamily family = FBControlCoreProductFamilyUnknown;
  if ([name hasPrefix:@"iPhone"]) {
    family = FBControlCoreProductFamilyiPhone;
  } else if ([name hasPrefix:@"iPad"]) {
    family = FBControlCoreProductFamilyiPad;
  } else if ([name hasPrefix:@"Apple TV"] || [name hasPrefix:@"AppleTV"]) {
    family = FBControlCoreProductFamilyAppleTV;
  } else if ([name hasPrefix:@"Apple Watch"] || [name hasPrefix:@"Watch"]) {
    family = FBControlCoreProductFamilyAppleWatch;
  } else if ([name hasPrefix:@"Mac"]) {
    family = FBControlCoreProductFamilyMac;
  }
  // Modern Apple platforms are arm64 across the board (devices since A7,
  // simulators on Apple Silicon Macs). Intel-host simulators run x86_64;
  // we approximate via NXGetLocalArchInfo at runtime rather than hardcode.
  FBArchitecture deviceArch = FBArchitectureArm64;
  FBArchitecture simulatorArch = FBArchitectureArm64;
#if !TARGET_CPU_ARM64
  simulatorArch = FBArchitectureX86_64;
#endif
  return [[self alloc] initWithModel:name productTypes:[NSSet setWithObject:name] deviceArchitecture:deviceArch simulatorArchitecture:simulatorArch family:family];
}

- (instancetype)initWithModel:(FBDeviceModel)model productTypes:(NSSet<NSString *> *)productTypes deviceArchitecture:(FBArchitecture)deviceArchitecture simulatorArchitecture:(FBArchitecture)simulatorArchitecture family:(FBControlCoreProductFamily)family
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _model = model;
  _productTypes = productTypes;
  _deviceArchitecture = deviceArchitecture;
  _simulatorArchitecture = simulatorArchitecture;
  _family = family;

  return self;
}

#pragma mark NSObject

- (BOOL)isEqual:(FBDeviceType *)object
{
  if (![object isKindOfClass:self.class]) {
    return NO;
  }
  return [self.model isEqualToString:object.model];
}

- (NSUInteger)hash
{
  return self.model.hash;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"Model '%@'", self.model];
}

#pragma mark NSCopying

- (instancetype)copyWithZone:(NSZone *)zone
{
  return self;
}

#pragma mark Helpers

+ (instancetype)iPhoneWithModel:(FBDeviceModel)model productType:(NSString *)productType deviceArchitecture:(FBArchitecture)deviceArchitecture simulatorArchitecture:(FBArchitecture)simulatorArchitecture
{
  return [self iPhoneWithModel:model productTypes:@[productType] deviceArchitecture:deviceArchitecture simulatorArchitecture:simulatorArchitecture];
}

+ (instancetype)iPhoneWithModel:(FBDeviceModel)model productTypes:(NSArray<NSString *> *)productTypes deviceArchitecture:(FBArchitecture)deviceArchitecture simulatorArchitecture:(FBArchitecture)simulatorArchitecture
{
  return [[self alloc] initWithModel:model productTypes:[NSSet setWithArray:productTypes] deviceArchitecture:deviceArchitecture simulatorArchitecture:simulatorArchitecture family:FBControlCoreProductFamilyiPhone];
}

+ (instancetype)iPadWithModel:(FBDeviceModel)model productTypes:(NSArray<NSString *> *)productTypes deviceArchitecture:(FBArchitecture)deviceArchitecture simulatorArchitecture:(FBArchitecture)simulatorArchitecture
{
  return [[self alloc] initWithModel:model productTypes:[NSSet setWithArray:productTypes] deviceArchitecture:deviceArchitecture simulatorArchitecture:simulatorArchitecture family:FBControlCoreProductFamilyiPad];
}

+ (instancetype)tvWithModel:(FBDeviceModel)model productTypes:(NSArray<NSString *> *)productTypes deviceArchitecture:(FBArchitecture)deviceArchitecture simulatorArchitecture:(FBArchitecture)simulatorArchitecture
{
  return [[self alloc] initWithModel:model productTypes:[NSSet setWithArray:productTypes] deviceArchitecture:deviceArchitecture simulatorArchitecture:simulatorArchitecture family:FBControlCoreProductFamilyAppleTV];
}

+ (instancetype)watchWithModel:(FBDeviceModel)model productTypes:(NSArray<NSString *> *)productTypes deviceArchitecture:(FBArchitecture)deviceArchitecture simulatorArchitecture:(FBArchitecture)simulatorArchitecture
{
  return [[self alloc] initWithModel:model productTypes:[NSSet setWithArray:productTypes] deviceArchitecture:deviceArchitecture simulatorArchitecture:simulatorArchitecture family:FBControlCoreProductFamilyAppleWatch];
}

+ (instancetype)genericWithModel:(NSString *)model
{
  return [[self alloc] initWithModel:model productTypes:[NSSet set] deviceArchitecture:FBArchitectureArm64 simulatorArchitecture:FBArchitectureX86_64 family:FBControlCoreProductFamilyUnknown];
}

@end

#pragma mark OS Versions

@implementation FBOSVersion

#pragma mark Initializers

+ (instancetype)genericWithName:(NSString *)name
{
  // Infer device families from the OS prefix. CoreSimulator and MobileDevice
  // hand us names like "iOS 18.1", "tvOS 18.1", "watchOS 11.1", "macOS 26.4".
  NSSet<NSNumber *> *families = NSSet.set;
  if ([name hasPrefix:@"iOS"]) {
    families = [NSSet setWithArray:@[
      @(FBControlCoreProductFamilyiPhone),
      @(FBControlCoreProductFamilyiPad),
    ]];
  } else if ([name hasPrefix:@"tvOS"]) {
    families = [NSSet setWithObject:@(FBControlCoreProductFamilyAppleTV)];
  } else if ([name hasPrefix:@"watchOS"]) {
    families = [NSSet setWithObject:@(FBControlCoreProductFamilyAppleWatch)];
  } else if ([name hasPrefix:@"macOS"] || [name hasPrefix:@"OSX"] || [name hasPrefix:@"Mac"]) {
    families = [NSSet setWithObject:@(FBControlCoreProductFamilyMac)];
  }
  return [[self alloc] initWithName:name families:families];
}

- (instancetype)initWithName:(FBOSVersionName)name families:(NSSet<NSNumber *> *)families
{
  self = [super init];
  if (!self){
    return nil;
  }

  _name = name;
  _families = families;

  return self;
}

#pragma mark NSObject

// Version String implies uniqueness
- (BOOL)isEqual:(FBOSVersion *)version
{
  if (![version isKindOfClass:self.class]) {
    return NO;
  }

  return [self.name isEqualToString:version.name];
}

- (NSUInteger)hash
{
  return self.name.hash;
}

- (NSDecimalNumber *)number
{
  NSString *versionString = [self.name componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet][1];
  return [NSDecimalNumber decimalNumberWithString:versionString];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"OS '%@'", self.name];
}

#pragma mark NSCopying

- (instancetype)copyWithZone:(NSZone *)zone
{
  // Object is immutable
  return self;
}

#pragma mark Helpers

+ (instancetype)iOSWithName:(FBOSVersionName)name
{
  NSSet *families = [NSSet setWithArray:@[
    @(FBControlCoreProductFamilyiPhone),
    @(FBControlCoreProductFamilyiPad),
  ]];
  return [[self alloc] initWithName:name families:families];
}

+ (instancetype)tvOSWithName:(FBOSVersionName)name
{
  return [[self alloc] initWithName:name families:[NSSet setWithObject:@(FBControlCoreProductFamilyAppleTV)]];
}

+ (instancetype)watchOSWithName:(FBOSVersionName)name
{
  return [[self alloc] initWithName:name families:[NSSet setWithObject:@(FBControlCoreProductFamilyAppleWatch)]];
}

+ (instancetype)macOSWithName:(FBOSVersionName)name
{
  return [[self alloc] initWithName:name families:[NSSet setWithObject:@(FBControlCoreProductFamilyMac)]];
}

@end

@implementation FBiOSTargetConfiguration

#pragma mark Lookup Tables

+ (NSDictionary<FBArchitecture, NSSet<FBArchitecture> *> *)baseArchToCompatibleArch
{
  return @{
    FBArchitectureArm64 : [NSSet setWithArray:@[FBArchitectureArm64, FBArchitectureArmv7s, FBArchitectureArmv7]],
    FBArchitectureArmv7s : [NSSet setWithArray:@[FBArchitectureArmv7s, FBArchitectureArmv7]],
    FBArchitectureArmv7 : [NSSet setWithArray:@[FBArchitectureArmv7]],
    FBArchitectureI386 : [NSSet setWithObject:FBArchitectureI386],
    FBArchitectureX86_64 : [NSSet setWithArray:@[FBArchitectureX86_64, FBArchitectureI386]],
  };
}

@end
