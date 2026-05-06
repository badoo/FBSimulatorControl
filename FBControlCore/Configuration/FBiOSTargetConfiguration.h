/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

#import <FBControlCore/FBArchitecture.h>

NS_ASSUME_NONNULL_BEGIN

/**
 Uses the known values of SimDeviceType ProductFamilyID, to construct an enumeration.
 These mirror the values from -[SimDeviceState productFamilyID].
 */
typedef NS_ENUM(NSUInteger, FBControlCoreProductFamily) {
  FBControlCoreProductFamilyUnknown = 0,
  FBControlCoreProductFamilyiPhone = 1,
  FBControlCoreProductFamilyiPad = 2,
  FBControlCoreProductFamilyAppleTV = 3,
  FBControlCoreProductFamilyAppleWatch = 4,
  FBControlCoreProductFamilyMac = 5,
};

/**
 Device Names Enumeration.
 */
typedef NSString *FBDeviceModel NS_STRING_ENUM;








/**
 OS Versions Name Enumeration.
 */
typedef NSString *FBOSVersionName NS_STRING_ENUM;





#pragma mark Screen

/**
 Information about the Screen.
 */
@interface FBiOSTargetScreenInfo : NSObject <NSCopying>

/**
 The Width of the Screen in Pixels.
 */
@property (nonatomic, assign, readonly) NSUInteger widthPixels;

/**
 The Height of the Screen in Pixels.
 */
@property (nonatomic, assign, readonly) NSUInteger heightPixels;

/**
 The Scale of the Screen.
 */
@property (nonatomic, assign, readonly) float scale;

/**
 The Designated Initializer.
 */
- (instancetype)initWithWidthPixels:(NSUInteger)widthPixels heightPixels:(NSUInteger)heightPixels scale:(float)scale;

@end

#pragma mark Devices

@interface FBDeviceType : NSObject <NSCopying>

/**
 The Device Name of the Device.
 */
@property (nonatomic, copy, readonly) FBDeviceModel model;

/**
 The String Representations of the Product Types.
 */
@property (nonatomic, copy, readonly) NSSet<NSString *> *productTypes;

/**
 The native Device Architecture.
 */
@property (nonatomic, copy, readonly) FBArchitecture deviceArchitecture;

/**
 The Native Simulator Arhitecture.
 */
@property (nonatomic, copy, readonly) FBArchitecture simulatorArchitecture;

/**
 The Supported Product Family.
 */
@property (nonatomic, assign, readonly) FBControlCoreProductFamily family;

/**
 A Generic Device with the Given Name.
 */
+ (instancetype)genericWithName:(NSString *)name;

@end

#pragma mark OS Versions

@interface FBOSVersion : NSObject <NSCopying>

/**
 The Version name of the OS.
 */
@property (nonatomic, copy, readonly) FBOSVersionName name;

/**
 A Decimal Number Represnting the Version Number.
 */
@property (nonatomic, copy, readonly) NSDecimalNumber *number;

/**
 The Supported Families of the OS Version.
 */
@property (nonatomic, copy, readonly) NSSet<NSNumber *> *families;

/**
 A Generic OS with the Given Name.
 */
+ (instancetype)genericWithName:(NSString *)name;

@end

/**
 Mappings of Variants.
 */
@interface FBiOSTargetConfiguration : NSObject

/**
 Maps the architecture of the target to the compatible architectures for
 binaries on the target.
 */
@property (class, nonatomic, copy, readonly) NSDictionary<FBArchitecture, NSSet<FBArchitecture> *> *baseArchToCompatibleArch;

@end

NS_ASSUME_NONNULL_END
