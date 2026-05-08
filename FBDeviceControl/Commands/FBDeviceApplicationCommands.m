/**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBDeviceApplicationCommands.h"

#import <objc/runtime.h>
#import <stdatomic.h>
#import <zlib.h>

#import "FBAMDevice+Private.h"
#import "FBAMDevice.h"
#import "FBAMDServiceConnection.h"
#import "FBDevice+Private.h"
#import "FBDevice.h"
#import "FBDeviceApplicationLaunchStrategy.h"
#import "FBDeviceApplicationProcess.h"
#import "FBDeviceControlError.h"
#import "FBDeviceDebuggerCommands.h"

static void UninstallCallback(NSDictionary<NSString *, id> *callbackDictionary, FBAMDevice *device)
{
  [device.logger logFormat:@"Uninstall Progress: %@", [FBCollectionInformation oneLineDescriptionFromDictionary:callbackDictionary]];
}

static void InstallCallback(NSDictionary<NSString *, id> *callbackDictionary, FBAMDevice *device)
{
  [device.logger.debug logFormat:@"Install Progress: %@", [FBCollectionInformation oneLineDescriptionFromDictionary:callbackDictionary]];
}

static void TransferCallback(NSDictionary<NSString *, id> *callbackDictionary, FBAMDevice *device)
{
  [device.logger.debug logFormat:@"Transfer Progress: %@", [FBCollectionInformation oneLineDescriptionFromDictionary:callbackDictionary]];
}

// Callback for AMDeviceSecureInstallApplicationBundle (streaming_zip_conduit).
// Critical: that API has no user-context parameter — the second callback arg
// is an internal MobileDevice pointer, not an FBAMDevice. Do NOT type the arg
// as an Objective-C pointer or ARC will retain it on entry and crash. Keep
// it as void * and never dereference it.
static void StreamingInstallCallback(NSDictionary<NSString *, id> *callbackDictionary, void *_internalMobileDevicePointer)
{
  (void)callbackDictionary;
  (void)_internalMobileDevicePointer;
}

#pragma mark - Native streaming_zip_conduit installer

// What this is and why:
// `AMDeviceSecureInstallApplicationBundle` does extra host-side work (reads
// the IPA, decompresses it, re-encodes into a "streamable" zip via
// SZArchiverConvertZipArchiveToStreamable) before sending — adding ~18s
// for a 1.2 GB bundle. Xcode bypasses that path entirely and talks to the
// `com.apple.streaming_zip_conduit` service directly using a custom
// STORE-zip framing that the device unzips on the fly.
//
// This native implementation matches Xcode's flow:
//   1. Open com.apple.streaming_zip_conduit via SecureStartService
//   2. Send InitTransfer plist (length-prefixed bplist)
//   3. Stream a custom STORE zip:
//        - META-INF/ directory entry
//        - META-INF/com.apple.ZipMetadata.plist (record count + sizes)
//        - For each IPA entry: zip header with method=STORE, then raw
//          decompressed bytes (zlib inflate while emitting). No data
//          descriptors, no compression — the device's streaming consumer
//          requires this exact framing.
//        - 4-byte central-directory-header trailer (just the signature)
//   4. Read length-prefixed progress plists until DataComplete
//
// Protocol reverse-engineered by danielpaulus/go-ios — see
// ios/zipconduit/zipconduit_installer.go and zip_utils.go.

#pragma mark Native streaming_zip_conduit — protocol constants

// Zip header constants. These specific magic values (mod time/date, version)
// are what Xcode emits — copying them verbatim sidesteps any device-side
// validation surprises.
static const uint32_t SZCZipLocalSig    = 0x04034b50;
static const uint32_t SZCZipCDSig       = 0x02014b50;
static const uint16_t SZCZipModTime     = 0xBDEF;
static const uint16_t SZCZipModDate     = 0x52EC;
static const NSInteger SZCStdDirPerm    = 16877;   //  0o40755
static const NSInteger SZCStdFilePerm   = -32348;  //  0o100644 represented signed (matches Xcode capture)

// 32-byte UT/UX extra block captured from an Xcode session. Carries
// timestamps and Unix uid/gid we don't actually need, but the device-side
// validator expects extras with this exact layout.
static const uint8_t SZCZipExtraBytes[32] = {
  0x55,0x54,0x0d,0x00,0x07,0xf3,0xa2,0xec,0x60,0xf6,0xa2,0xec,0x60,0xf3,0xa2,0xec,
  0x60,0x75,0x78,0x0b,0x00,0x01,0x04,0xf5,0x01,0x00,0x00,0x04,0x14,0x00,0x00,0x00,
};

typedef struct __attribute__((packed)) {
  uint32_t signature;
  uint16_t version;
  uint16_t generalFlags;
  uint16_t method;
  uint16_t lastModTime;
  uint16_t lastModDate;
  uint32_t crc32;
  uint32_t compressedSize;
  uint32_t uncompressedSize;
  uint16_t fileNameLen;
  uint16_t extraLen;
} SZCZipLocalHeader;

#pragma mark Native streaming_zip_conduit — send/recv plumbing

// Send/receive go through AMDServiceConnectionSend/Receive (NOT raw send(2))
// because the framework wraps streaming_zip_conduit in TLS — plaintext on
// the underlying socket would be rejected by the device's TLS layer mid-stream.
//
// SZCSender provides two send modes:
//   sync       — caller's thread does the SSL_write; simple, predictable.
//   concurrent — caller hands chunks to a serial dispatch queue, which does
//                the SSL_write. The caller meanwhile inflates the next chunk.
//                Pipelines CPU (inflate) with wire (TLS+USB).
//
// Receive always runs synchronously on the caller's thread — there's only
// ever one in-flight read (terminal status plists), so async buys nothing.

@interface SZCSender : NSObject
@property (nonatomic, strong, readonly) FBAMDServiceConnection *connection;
@property (nonatomic, readonly) BOOL concurrent;
- (instancetype)initWithConnection:(FBAMDServiceConnection *)connection concurrent:(BOOL)concurrent;
- (BOOL)sendBytes:(const void *)bytes length:(size_t)len;
- (BOOL)sendData:(NSData *)data;            // zero-copy in concurrent mode
- (BOOL)flush;                              // wait for queued sends to drain
@end

@implementation SZCSender {
  dispatch_queue_t _sendQueue;
  dispatch_semaphore_t _backpressure;
  // Atomic 32-bit flag: 0 = ok, non-zero = a previous send failed. Reads
  // and writes are racing across the producer thread and the send queue,
  // so use atomic_int for proper memory ordering.
  _Atomic int _errorFlag;
}

- (instancetype)initWithConnection:(FBAMDServiceConnection *)connection concurrent:(BOOL)concurrent
{
  self = [super init];
  if (!self) return nil;
  _connection = connection;
  _concurrent = concurrent;
  if (concurrent) {
    _sendQueue = dispatch_queue_create("com.facebook.fbdevicecontrol.szc-sender", DISPATCH_QUEUE_SERIAL);
    // 16 chunks * 64 KB = 1 MB of in-flight backlog. Enough to keep the
    // wire saturated, small enough not to balloon RSS.
    _backpressure = dispatch_semaphore_create(16);
  }
  atomic_store(&_errorFlag, 0);
  return self;
}

// Internal raw blocking send loop. Always runs on whichever thread invokes it.
- (BOOL)blockingSendBytes:(const void *)bytes length:(size_t)len
{
  const uint8_t *p = (const uint8_t *)bytes;
  size_t left = len;
  FBAMDServiceConnection *c = self.connection;
  while (left > 0) {
    int n = c.calls.ServiceConnectionSend(c.connection, (void *)p, left);
    if (n <= 0) {
      atomic_store(&_errorFlag, 1);
      return NO;
    }
    p += n;
    left -= (size_t)n;
  }
  return YES;
}

- (BOOL)sendBytes:(const void *)bytes length:(size_t)len
{
  if (atomic_load(&_errorFlag)) return NO;
  if (!_concurrent) {
    return [self blockingSendBytes:bytes length:len];
  }
  // Concurrent: copy into NSData (caller's buffer might be transient) and
  // hand off. Backpressure semaphore caps queued bytes.
  NSData *copy = [NSData dataWithBytes:bytes length:len];
  return [self sendData:copy];
}

- (BOOL)sendData:(NSData *)data
{
  if (atomic_load(&_errorFlag)) return NO;
  if (!_concurrent) {
    return [self blockingSendBytes:data.bytes length:data.length];
  }
  dispatch_semaphore_wait(_backpressure, DISPATCH_TIME_FOREVER);
  // Capture self weakly — sender outlives the queue (we drain via flush)
  // but holding self strong in a long queue would extend its lifetime.
  __weak typeof(self) weakSelf = self;
  dispatch_async(_sendQueue, ^{
    typeof(self) strongSelf = weakSelf;
    if (strongSelf && !atomic_load(&strongSelf->_errorFlag)) {
      [strongSelf blockingSendBytes:data.bytes length:data.length];
    }
    if (strongSelf) {
      dispatch_semaphore_signal(strongSelf->_backpressure);
    }
  });
  return YES;
}

- (BOOL)flush
{
  if (!_concurrent) {
    return atomic_load(&_errorFlag) == 0;
  }
  // Empty barrier block — dispatch_sync to a serial queue waits for all
  // previously-async-dispatched blocks to finish.
  dispatch_sync(_sendQueue, ^{ });
  return atomic_load(&_errorFlag) == 0;
}

@end

// Synchronous receive helper — recvs always run on the caller's thread.
static int SZCRecvAll(FBAMDServiceConnection *conn, void *buf, size_t len)
{
  uint8_t *p = (uint8_t *)buf;
  size_t left = len;
  while (left > 0) {
    int n = conn.calls.ServiceConnectionReceive(conn.connection, p, left);
    if (n <= 0) return -1;
    p += n;
    left -= (size_t)n;
  }
  return 0;
}

// Length-prefixed binary plist write/read. The streaming_zip_conduit service
// frames every plist as 4-byte big-endian length + bplist00 payload.
static BOOL SZCSendPlist(SZCSender *sender, NSDictionary *plist, NSError **error)
{
  NSError *innerError = nil;
  NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:&innerError];
  if (!data) {
    if (error) *error = innerError;
    return NO;
  }
  uint32_t lenBE = htonl((uint32_t)data.length);
  if (![sender sendBytes:&lenBE length:4]) return NO;
  if (![sender sendData:data]) return NO;
  return YES;
}

static NSDictionary *SZCRecvPlist(FBAMDServiceConnection *conn, NSError **error)
{
  uint32_t lenBE = 0;
  if (SZCRecvAll(conn, &lenBE, 4) != 0) {
    if (error) *error = [NSError errorWithDomain:@"FBStreamingZipConduit" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Failed to read plist length"}];
    return nil;
  }
  uint32_t len = ntohl(lenBE);
  if (len == 0 || len > 16 * 1024 * 1024) {
    if (error) *error = [NSError errorWithDomain:@"FBStreamingZipConduit" code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Bogus plist length %u", len]}];
    return nil;
  }
  void *buf = malloc(len);
  if (SZCRecvAll(conn, buf, len) != 0) {
    free(buf);
    if (error) *error = [NSError errorWithDomain:@"FBStreamingZipConduit" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Failed to read plist body"}];
    return nil;
  }
  NSData *data = [NSData dataWithBytesNoCopy:buf length:len freeWhenDone:YES];
  id obj = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:error];
  return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

#pragma mark Native streaming_zip_conduit — STORE-zip framing

// Emit a directory zip entry (header only, no body bytes).
static BOOL SZCWriteZipDir(SZCSender *sender, NSString *name)
{
  NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
  SZCZipLocalHeader hdr = {
    .signature = SZCZipLocalSig, .version = 20, .generalFlags = 0,
    .method = 0, .lastModTime = SZCZipModTime, .lastModDate = SZCZipModDate,
    .crc32 = 0, .compressedSize = 0, .uncompressedSize = 0,
    .fileNameLen = (uint16_t)nameData.length, .extraLen = sizeof(SZCZipExtraBytes),
  };
  if (![sender sendBytes:&hdr length:sizeof(hdr)]) return NO;
  if (![sender sendData:nameData]) return NO;
  if (![sender sendBytes:SZCZipExtraBytes length:sizeof(SZCZipExtraBytes)]) return NO;
  return YES;
}

// Emit a file zip header. Caller follows with `size` bytes of file body.
static BOOL SZCWriteZipFileHeader(SZCSender *sender, NSString *name, uint32_t size, uint32_t crc)
{
  NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
  SZCZipLocalHeader hdr = {
    .signature = SZCZipLocalSig, .version = 20, .generalFlags = 0,
    .method = 0, .lastModTime = SZCZipModTime, .lastModDate = SZCZipModDate,
    .crc32 = crc, .compressedSize = size, .uncompressedSize = size,
    .fileNameLen = (uint16_t)nameData.length, .extraLen = sizeof(SZCZipExtraBytes),
  };
  if (![sender sendBytes:&hdr length:sizeof(hdr)]) return NO;
  if (![sender sendData:nameData]) return NO;
  if (![sender sendBytes:SZCZipExtraBytes length:sizeof(SZCZipExtraBytes)]) return NO;
  return YES;
}

#pragma mark Native streaming_zip_conduit — IPA reader

// Minimal IPA central-directory entry. Sizes are 32-bit because IPAs of
// concern are well under 4 GB; ZIP64 would need wider fields and a separate
// extra-field walk. We bail out cleanly if we ever see a ZIP64 sentinel.
//
// This is an Obj-C class rather than a C struct because the `name` is an
// NSString — boxing a C struct with an NSString * member into NSValue does
// NOT retain the string (NSValue treats it as an opaque pointer), leaving
// a dangling reference once the parse loop exits and ARC drops the local.
@interface SZCIPAEntry : NSObject
@property (nonatomic, copy)   NSString *name;
@property (nonatomic, assign) uint16_t method;       // 0 = store, 8 = deflate
@property (nonatomic, assign) uint32_t compressedSize;
@property (nonatomic, assign) uint32_t uncompressedSize;
@property (nonatomic, assign) uint32_t crc32;
@property (nonatomic, assign) uint32_t headerOffset;
@property (nonatomic, assign) BOOL isDirectory;
@end
@implementation SZCIPAEntry
@end

// Locate End-Of-Central-Directory record by scanning backwards from EOF.
// The record's last field is a variable-length comment so the signature
// lives somewhere in the last 64 KB. This is the standard zip approach.
static BOOL SZCFindEOCD(NSData *ipa, NSUInteger *outOffset)
{
  const uint8_t *bytes = ipa.bytes;
  NSUInteger len = ipa.length;
  if (len < 22) return NO;
  NSUInteger start = (len > 65557) ? (len - 65557) : 0;
  for (NSUInteger i = len - 22; i >= start; i--) {
    if (bytes[i] == 0x50 && bytes[i+1] == 0x4b && bytes[i+2] == 0x05 && bytes[i+3] == 0x06) {
      *outOffset = i;
      return YES;
    }
    if (i == 0) break;
  }
  return NO;
}

// Walk the central directory and return one SZCIPAEntry per zip entry.
// On unsupported features (ZIP64, encryption) returns nil with error set.
static NSArray<SZCIPAEntry *> *SZCParseIPAEntries(NSData *ipa, NSError **error)
{
  NSUInteger eocd = 0;
  if (!SZCFindEOCD(ipa, &eocd)) {
    if (error) *error = [NSError errorWithDomain:@"FBStreamingZipConduit" code:10 userInfo:@{NSLocalizedDescriptionKey: @"No EOCD found — file is not a zip"}];
    return nil;
  }
  const uint8_t *b = ipa.bytes;
  // EOCD layout: 0..4 sig, 8..2 disk, 10..2 disk-w-cd, 12..2 entries-this-disk,
  // 14..2 entries-total, 16..4 cd-size, 20..4 cd-offset, 24..2 comment-len.
  uint16_t totalEntries = OSReadLittleInt16(b, eocd + 10);
  uint32_t cdOffset     = OSReadLittleInt32(b, eocd + 16);
  if (totalEntries == 0xFFFF || cdOffset == 0xFFFFFFFF) {
    if (error) *error = [NSError errorWithDomain:@"FBStreamingZipConduit" code:11 userInfo:@{NSLocalizedDescriptionKey: @"ZIP64 archives are not supported"}];
    return nil;
  }
  NSMutableArray<SZCIPAEntry *> *entries = [NSMutableArray arrayWithCapacity:totalEntries];
  NSUInteger off = cdOffset;
  for (uint16_t i = 0; i < totalEntries; i++) {
    if (OSReadLittleInt32(b, off) != SZCZipCDSig) {
      if (error) *error = [NSError errorWithDomain:@"FBStreamingZipConduit" code:12 userInfo:@{NSLocalizedDescriptionKey: @"Malformed central directory"}];
      return nil;
    }
    // CD layout per https://en.wikipedia.org/wiki/ZIP_(file_format)#Central_directory_file_header
    uint16_t method     = OSReadLittleInt16(b, off + 10);
    uint32_t crc        = OSReadLittleInt32(b, off + 16);
    uint32_t compSize   = OSReadLittleInt32(b, off + 20);
    uint32_t uncompSize = OSReadLittleInt32(b, off + 24);
    uint16_t nameLen    = OSReadLittleInt16(b, off + 28);
    uint16_t extraLen   = OSReadLittleInt16(b, off + 30);
    uint16_t commentLen = OSReadLittleInt16(b, off + 32);
    uint32_t lhdrOffset = OSReadLittleInt32(b, off + 42);
    if (compSize == 0xFFFFFFFF || uncompSize == 0xFFFFFFFF || lhdrOffset == 0xFFFFFFFF) {
      if (error) *error = [NSError errorWithDomain:@"FBStreamingZipConduit" code:13 userInfo:@{NSLocalizedDescriptionKey: @"ZIP64 entry not supported"}];
      return nil;
    }
    NSString *name = [[NSString alloc] initWithBytes:(b + off + 46) length:nameLen encoding:NSUTF8StringEncoding];
    if (!name) name = [[NSString alloc] initWithBytes:(b + off + 46) length:nameLen encoding:NSASCIIStringEncoding];
    SZCIPAEntry *entry = [SZCIPAEntry new];
    entry.name = name;
    entry.method = method;
    entry.crc32 = crc;
    entry.compressedSize = compSize;
    entry.uncompressedSize = uncompSize;
    entry.headerOffset = lhdrOffset;
    entry.isDirectory = (uncompSize == 0 && [name hasSuffix:@"/"]);
    [entries addObject:entry];
    off += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}

// Quickly check whether an IPA contains any ".appex/" entry (an iOS app
// extension). Used by installApplicationWithPath: to decide whether the
// streaming path can handle the bundle: it currently can't preserve the
// per-entry unix mode bits that Apple's signature verifier requires for
// .appex sub-bundles, so those IPAs route to the legacy install path
// instead. Reads only the central directory; doesn't inflate any entries.
static BOOL SZCContainsAppex(NSString *ipaPath)
{
  NSData *ipa = [NSData dataWithContentsOfFile:ipaPath options:NSDataReadingMappedAlways error:nil];
  if (!ipa) return NO;
  NSArray<SZCIPAEntry *> *entries = SZCParseIPAEntries(ipa, nil);
  for (SZCIPAEntry *e in entries) {
    if ([e.name containsString:@".appex/"]) return YES;
  }
  return NO;
}

// Returns the offset of compressed data for an entry by parsing the local
// file header (we cannot rely on the central directory offset alone because
// the local header has its own variable-length name + extra fields).
static uint32_t SZCDataOffset(NSData *ipa, uint32_t headerOffset)
{
  const uint8_t *b = ipa.bytes;
  uint16_t nameLen  = OSReadLittleInt16(b, headerOffset + 26);
  uint16_t extraLen = OSReadLittleInt16(b, headerOffset + 28);
  return headerOffset + 30 + nameLen + extraLen;
}

// Stream one entry: inflate (or pass through STORE) compressed bytes from
// the host IPA, write zip header + uncompressed bytes via the sender.
// In concurrent mode each chunk lands on the sender's serial dispatch queue
// while we go inflate the next one — overlapping CPU and wire.
// Returns YES on success, NO on error (with `error` set).
static BOOL SZCStreamEntry(SZCSender *sender, NSData *ipa, SZCIPAEntry *entry, NSError **error)
{
  static NSString *const kDomain = @"FBStreamingZipConduit";

  if (entry.isDirectory) {
    if (!SZCWriteZipDir(sender, entry.name)) {
      if (error) *error = [NSError errorWithDomain:kDomain code:30 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"send dir entry header failed for %@", entry.name]}];
      return NO;
    }
    return YES;
  }
  if (!SZCWriteZipFileHeader(sender, entry.name, entry.uncompressedSize, entry.crc32)) {
    if (error) *error = [NSError errorWithDomain:kDomain code:31 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"send file header failed for %@", entry.name]}];
    return NO;
  }
  if (entry.uncompressedSize == 0) {
    return YES;
  }
  uint32_t dataOff = SZCDataOffset(ipa, entry.headerOffset);
  if (dataOff + entry.compressedSize > ipa.length) {
    if (error) *error = [NSError errorWithDomain:kDomain code:32 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"compressed bytes for %@ extend past EOF (dataOff=%u compSize=%u ipaLen=%lu)", entry.name, dataOff, entry.compressedSize, (unsigned long)ipa.length]}];
    return NO;
  }
  const uint8_t *src = (const uint8_t *)ipa.bytes + dataOff;

  if (entry.method == 0) {
    // STORE — bytes already uncompressed in the IPA. Verify CRC against
    // the CD's recorded value before sending; mismatch means we located
    // the wrong region in the IPA (bad headerOffset / data offset arithmetic).
    uint32_t actualCRC = (uint32_t)crc32(0, src, (uInt)entry.uncompressedSize);
    if (entry.crc32 != 0 && actualCRC != entry.crc32) {
      if (error) *error = [NSError errorWithDomain:kDomain code:39 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"STORE CRC mismatch for %@: expected 0x%08x got 0x%08x", entry.name, entry.crc32, actualCRC]}];
      return NO;
    }
    NSData *passthrough = [NSData dataWithBytesNoCopy:(void *)src length:entry.uncompressedSize freeWhenDone:NO];
    if (![sender sendData:passthrough]) {
      if (error) *error = [NSError errorWithDomain:kDomain code:33 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"STORE send failed for %@ (size=%u)", entry.name, entry.uncompressedSize]}];
      return NO;
    }
    return YES;
  }
  if (entry.method != 8) {
    if (error) *error = [NSError errorWithDomain:kDomain code:34 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"unsupported compression method %u for %@", entry.method, entry.name]}];
    return NO;
  }

  // DEFLATE — raw (no zlib wrapper). Negative window bits tells inflateInit2
  // to expect raw deflate, not zlib-framed deflate. Each output chunk is its
  // own malloc'd buffer wrapped in NSData so concurrent sends don't fight
  // over a shared destination.
  z_stream zs = {0};
  zs.next_in = (Bytef *)src;
  zs.avail_in = entry.compressedSize;
  int rc = inflateInit2(&zs, -MAX_WBITS);
  if (rc != Z_OK) {
    if (error) *error = [NSError errorWithDomain:kDomain code:35 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"inflateInit2 failed (%d) for %@", rc, entry.name]}];
    return NO;
  }
  static const size_t kChunk = 64 * 1024;
  uint64_t emitted = 0;
  uint32_t actualCRC = 0;
  rc = Z_OK;
  while (rc != Z_STREAM_END) {
    void *outBuf = malloc(kChunk);
    zs.next_out = outBuf;
    zs.avail_out = kChunk;
    rc = inflate(&zs, Z_NO_FLUSH);
    if (rc != Z_OK && rc != Z_STREAM_END) {
      free(outBuf);
      NSString *msg = zs.msg ? @(zs.msg) : @"(no msg)";
      uint32_t consumed = entry.compressedSize - zs.avail_in;
      inflateEnd(&zs);
      if (error) *error = [NSError errorWithDomain:kDomain code:36 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"inflate rc=%d (%@) for %@ emitted=%llu/%u consumed=%u/%u", rc, msg, entry.name, emitted, entry.uncompressedSize, consumed, entry.compressedSize]}];
      return NO;
    }
    size_t produced = kChunk - zs.avail_out;
    if (produced > 0) {
      // Update the running CRC over the inflated bytes BEFORE handing the
      // buffer to the (potentially async) sender — sender may free it from
      // another thread once the chunk is on the wire.
      actualCRC = (uint32_t)crc32(actualCRC, outBuf, (uInt)produced);
      NSData *chunk = [NSData dataWithBytesNoCopy:outBuf length:produced freeWhenDone:YES];
      if (![sender sendData:chunk]) {
        inflateEnd(&zs);
        if (error) *error = [NSError errorWithDomain:kDomain code:37 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"DEFLATE send failed for %@ at byte %llu", entry.name, emitted]}];
        return NO;
      }
      emitted += produced;
    } else {
      free(outBuf);
    }
  }
  inflateEnd(&zs);
  if (emitted != entry.uncompressedSize) {
    if (error) *error = [NSError errorWithDomain:kDomain code:38 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"size mismatch for %@: emitted=%llu uncompressed=%u", entry.name, emitted, entry.uncompressedSize]}];
    return NO;
  }
  if (entry.crc32 != 0 && actualCRC != entry.crc32) {
    if (error) *error = [NSError errorWithDomain:kDomain code:40 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"DEFLATE CRC mismatch for %@: expected 0x%08x got 0x%08x", entry.name, entry.crc32, actualCRC]}];
    return NO;
  }
  return YES;
}

#pragma mark Native streaming_zip_conduit — protocol plists

// Build the META-INF/com.apple.ZipMetadata.plist body bytes.
static NSData *SZCMetadataPlist(NSUInteger recordCount, uint64_t totalUncompressed)
{
  NSDictionary *meta = @{
    @"RecordCount":            @(recordCount),
    @"StandardDirectoryPerms": @(SZCStdDirPerm),
    @"StandardFilePerms":      @(SZCStdFilePerm),
    @"TotalUncompressedBytes": @(totalUncompressed),
    @"Version":                @2,
  };
  return [NSPropertyListSerialization dataWithPropertyList:meta format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
}

// Build the InitTransfer plist Xcode sends as the very first message.
static NSDictionary *SZCInitTransferPlist(NSString *ipaName)
{
  return @{
    @"InstallTransferredDirectory": @1,
    @"UserInitiatedTransfer":       @0,
    @"MediaSubdir":                 [NSString stringWithFormat:@"PublicStaging/%@", ipaName],
    @"InstallOptionsDictionary":    @{
      @"InstallDeltaTypeKey":  @"InstallDeltaTypeSparseIPAFiles",
      @"DisableDeltaTransfer": @1,
      @"IsUserInitiated":      @1,
      @"PreferWifi":           @1,
      @"PackageType":          @"Customer",
    },
  };
}

@interface FBDeviceApplicationCommands ()

@property (nonatomic, weak, readonly) FBDevice *device;

@end

@implementation FBDeviceApplicationCommands

#pragma mark Initializers

+ (instancetype)commandsWithTarget:(FBDevice *)target
{
  return [[self alloc] initWithDevice:target];
}

- (instancetype)initWithDevice:(FBDevice *)device
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _device = device;

  return self;
}

#pragma mark FBApplicationCommands Implementation

- (FBFuture<NSNull *> *)installApplicationWithPath:(NSString *)path
{
  // Install path selection:
  //
  //   default for .ipa, no appex   → nativeStreamingInstallAtPath:
  //                                   (com.apple.streaming_zip_conduit protocol,
  //                                   fastest path on USB 2.0)
  //
  //   .ipa containing any *.appex  → falls back to the legacy two-step pair.
  //                                   The streaming protocol's STORE-zip framing
  //                                   doesn't preserve per-entry unix mode bits,
  //                                   and Apple's code-signature verifier rejects
  //                                   bundles where an .appex's main binary
  //                                   doesn't land with the +x bit. Override
  //                                   with FBSIMCTL_STREAMING_FORCE=1 to keep
  //                                   the streaming path even with appex.
  //
  //   FBSIMCTL_STREAMING_INSTALL=1 → Apple's AMDeviceSecureInstallApplicationBundle
  //                                  (also streaming_zip_conduit but goes through
  //                                  Apple's wrapper that does extra host-side
  //                                  conversion).
  //
  //   FBSIMCTL_LEGACY_INSTALL=1,
  //   or for .app input            → SecureTransferPath + SecureInstallApplication
  //                                  (the original two-step path).
  BOOL isIPA = [path.pathExtension.lowercaseString isEqualToString:@"ipa"];
  NSString *absolutePath = path.stringByStandardizingPath;
  if (![absolutePath isAbsolutePath]) {
    absolutePath = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:absolutePath].stringByStandardizingPath;
  }
  NSDictionary *env = NSProcessInfo.processInfo.environment;
  BOOL legacy    = [env[@"FBSIMCTL_LEGACY_INSTALL"]    isEqualToString:@"1"];
  BOOL streaming = [env[@"FBSIMCTL_STREAMING_INSTALL"] isEqualToString:@"1"];
  BOOL forceStream = [env[@"FBSIMCTL_STREAMING_FORCE"] isEqualToString:@"1"];

  if (isIPA && !legacy && !streaming) {
    BOOL hasAppex = SZCContainsAppex(absolutePath);
    if (forceStream || !hasAppex) {
      return [self nativeStreamingInstallAtPath:absolutePath];
    }
    [self.device.logger logFormat:@"%@ contains a .appex — falling back to legacy install (streaming_zip_conduit drops per-entry mode bits, which breaks Apple's signature verifier on app extensions). Set FBSIMCTL_STREAMING_FORCE=1 to override.", absolutePath.lastPathComponent];
  }

  NSURL *appURL = [NSURL fileURLWithPath:absolutePath isDirectory:!isIPA];
  NSDictionary *options = @{@"PackageType" : @"Developer"};
  if (streaming && self.device.amDevice.calls.SecureInstallApplicationBundle != NULL) {
    return [self secureInstallApplicationBundle:appURL options:options];
  }
  return [[self
    transferAppURL:appURL options:options]
    onQueue:self.device.workQueue fmap:^(NSNull *_) {
      return [self secureInstallApplication:appURL options:options];
    }];
}

- (FBFuture<id> *)uninstallApplicationWithBundleID:(NSString *)bundleID
{
  // It may be better to investigate if FB_AMDeviceSecureUninstallApplication
  // outputs some error message when the bundle id doesn't exist
  // Currently it returns 0 as if it had succeded
  // In case that's not possible, we should look into querying if
  // the app is installed first (FB_AMDeviceLookupApplications)
  return [[self.device.amDevice
    connectToDeviceWithPurpose:@"uninstall_%@", bundleID]
    onQueue:self.device.workQueue pop:^(FBAMDevice *device) {
      [self.device.logger logFormat:@"Uninstalling Application %@", bundleID];
      int status = self.device.amDevice.calls.SecureUninstallApplication(
        0,
        device.amDevice,
        (__bridge CFStringRef _Nonnull)(bundleID),
        0,
        (AMDeviceProgressCallback) UninstallCallback,
        (__bridge void *) (device)
      );
      if (status != 0) {
        NSString *internalMessage = CFBridgingRelease(device.calls.CopyErrorText(status));
        return [[FBDeviceControlError
          describeFormat:@"Failed to uninstall application '%@' with error (%@)", bundleID, internalMessage]
          failFuture];
      }
      [self.device.logger logFormat:@"Uninstalled Application %@", bundleID];
      return [FBFuture futureWithResult:NSNull.null];
    }];
}

- (FBFuture<NSArray<FBInstalledApplication *> *> *)installedApplications
{
  return [[self
    installedApplicationsData:FBDeviceApplicationCommands.installedApplicationLookupAttributes]
    onQueue:self.device.asyncQueue map:^(NSDictionary<NSString *, NSDictionary<NSString *, id> *> *applicationData) {
      NSMutableArray<FBInstalledApplication *> *installedApplications = [[NSMutableArray alloc] initWithCapacity:applicationData.count];
      NSEnumerator *objectEnumerator = [applicationData objectEnumerator];
      for (NSDictionary *app in objectEnumerator) {
        if (app == nil) {
          continue;
        }
        FBInstalledApplication *application = [FBDeviceApplicationCommands installedApplicationFromDictionary:app];
        [installedApplications addObject:application];
      }
      return installedApplications;
    }];
}

- (FBFuture<FBInstalledApplication *> *)installedApplicationWithBundleID:(NSString *)bundleID
{
  return [[self
    installedApplicationsData:FBDeviceApplicationCommands.installedApplicationLookupAttributes]
    onQueue:self.device.asyncQueue fmap:^FBFuture *(NSDictionary<NSString *, NSDictionary<NSString *, id> *> *applicationData) {
      NSDictionary <NSString *, id> *app = applicationData[bundleID];
      if (!app) {
        return [[FBDeviceControlError describeFormat:@"Application with bundle ID: %@ is not installed", bundleID] failFuture];
      }
      FBInstalledApplication *application = [FBDeviceApplicationCommands installedApplicationFromDictionary:app];
      return [FBFuture futureWithResult:application];
   }];
}

- (FBFuture<NSDictionary<NSString *, FBProcessInfo *> *> *)runningApplications
{
  // TODO: This is unimplemented, yet. Adding "empty" implementation so that it will not crash on selector forwarding
  return [FBFuture futureWithResult:@{}];
}

- (FBFuture<NSNumber *> *)isApplicationInstalledWithBundleID:(NSString *)bundleID
{
  return [[self
    installedApplicationWithBundleID:bundleID]
    onQueue:self.device.workQueue chain:^(FBFuture *future) {
      return [FBFuture futureWithResult:(future.state == FBFutureStateDone ? @YES : @NO)];
    }];
}

- (FBFuture<id> *)processIDWithBundleID:(NSString *)bundleID
{
  return [[FBDeviceControlError
    describeFormat:@"-[%@ %@] is unimplemented", NSStringFromClass(self.class), NSStringFromSelector(_cmd)]
    failFuture];
}

- (FBFuture<NSNull *> *)killApplicationWithBundleID:(NSString *)bundleID
{
  return [[FBDeviceControlError
    describeFormat:@"-[%@ %@] is unimplemented", NSStringFromClass(self.class), NSStringFromSelector(_cmd)]
    failFuture];
}

- (FBFuture<id<FBLaunchedProcess>> *)launchApplication:(FBApplicationLaunchConfiguration *)configuration
{
  __block NSString *remoteAppPath = nil;
  return [[[self
    launchableRemoteApplicationPathForConfiguration:configuration]
    onQueue:self.device.workQueue pushTeardown:^(NSString *result) {
      remoteAppPath = result;
      return [[FBDeviceDebuggerCommands
        commandsWithTarget:self.device]
        connectToDebugServer];
    }]
    onQueue:self.device.workQueue pop:^(FBAMDServiceConnection *connection) {
      return [[FBDeviceApplicationLaunchStrategy
        strategyWithDevice:self.device debugConnection:connection logger:self.device.logger]
        launchApplication:configuration remoteAppPath:remoteAppPath];
    }];
}

#pragma mark Private

- (FBFuture<NSNull *> *)transferAppURL:(NSURL *)appURL options:(NSDictionary *)options
{
  return [FBFuture onQueue:self.device.workQueue resolve:^ {
    [self.device.logger logFormat:@"Transferring %@ to device", appURL.lastPathComponent];
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    int status = self.device.amDevice.calls.SecureTransferPath(
      0,
      self.device.amDevice.amDevice,
      (__bridge CFURLRef _Nonnull)(appURL),
      (__bridge CFDictionaryRef _Nonnull)(options),
      (AMDeviceProgressCallback) TransferCallback,
      (__bridge void *) (self.device.amDevice)
    );
    NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - started;
    if (status != 0) {
      NSString *internalMessage = CFBridgingRelease(self.device.amDevice.calls.CopyErrorText(status));
      [self.device.logger logFormat:@"Transfer failed for %@ after %.2fs: %@", appURL.lastPathComponent, elapsed, internalMessage];
      return [[FBDeviceControlError
        describeFormat:@"Failed to transfer '%@' with error (%@)", appURL, internalMessage]
        failFuture];
    }
    [self.device.logger logFormat:@"Transferred %@ to device in %.2fs", appURL.lastPathComponent, elapsed];
    return [FBFuture futureWithResult:NSNull.null];
  }];
}

- (FBFuture<NSNull *> *)nativeStreamingInstallAtPath:(NSString *)ipaPath
{
  // Talks to com.apple.streaming_zip_conduit directly, bypassing Apple's
  // AMDeviceSecureInstallApplicationBundle wrapper. See the explanatory
  // comment block above the static helpers (#pragma mark - Native streaming…)
  // for the full protocol.
  //
  // Default mode is concurrent: one serial dispatch queue does the SSL
  // sends while we run zlib inflate on the calling thread. Set
  // FBSIMCTL_STREAMING_NATIVE_SYNC=1 to force the previous synchronous
  // path for A/B comparison.
  BOOL concurrent = ![NSProcessInfo.processInfo.environment[@"FBSIMCTL_STREAMING_NATIVE_SYNC"] isEqualToString:@"1"];
  return [[self.device.amDevice
    startService:@"com.apple.streaming_zip_conduit"]
    onQueue:self.device.workQueue pop:^FBFuture *(FBAMDServiceConnection *connection) {
      return [FBFuture onQueue:self.device.workQueue resolve:^FBFuture *{
        [self.device.logger logFormat:@"Installing %@ via native streaming_zip_conduit (%@)", ipaPath.lastPathComponent, concurrent ? @"concurrent" : @"sync"];
        CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();

        NSError *innerError = nil;
        // mmap the IPA so the OS handles paging — we'll touch the bytes
        // sequentially as we walk the central directory.
        NSData *ipa = [NSData dataWithContentsOfFile:ipaPath options:NSDataReadingMappedAlways error:&innerError];
        if (!ipa) {
          return [[FBDeviceControlError describeFormat:@"Cannot read IPA: %@", innerError] failFuture];
        }

        NSArray<SZCIPAEntry *> *entries = SZCParseIPAEntries(ipa, &innerError);
        if (!entries) {
          return [[FBDeviceControlError describeFormat:@"Cannot parse IPA: %@", innerError] failFuture];
        }

        // Tally the totals the device-side metadata plist needs (record
        // count includes META-INF/ + the metadata plist itself, plus every
        // entry from the IPA).
        uint64_t totalUncompressed = 0;
        for (SZCIPAEntry *e in entries) {
          totalUncompressed += e.uncompressedSize;
        }
        NSUInteger recordCount = entries.count + 2;
        SZCSender *sender = [[SZCSender alloc] initWithConnection:connection concurrent:concurrent];

        // 1. InitTransfer
        if (!SZCSendPlist(sender, SZCInitTransferPlist(ipaPath.lastPathComponent), &innerError)) {
          return [[FBDeviceControlError describeFormat:@"InitTransfer send failed: %@", innerError] failFuture];
        }

        // 2. META-INF/ directory + metadata plist (as if they were the first
        //    two entries of the streamed zip).
        if (!SZCWriteZipDir(sender, @"META-INF/")) {
          return [[FBDeviceControlError describe:@"Failed to send META-INF dir entry"] failFuture];
        }
        NSData *metaPlist = SZCMetadataPlist(recordCount, totalUncompressed);
        uint32_t metaCRC = (uint32_t)crc32(0, metaPlist.bytes, (uInt)metaPlist.length);
        if (!SZCWriteZipFileHeader(sender, @"META-INF/com.apple.ZipMetadata.plist", (uint32_t)metaPlist.length, metaCRC)) {
          return [[FBDeviceControlError describe:@"Failed to send metadata plist header"] failFuture];
        }
        if (![sender sendData:metaPlist]) {
          return [[FBDeviceControlError describe:@"Failed to send metadata plist body"] failFuture];
        }

        // 3. Stream every IPA entry, decompressing on the fly.
        for (SZCIPAEntry *e in entries) {
          NSError *streamError = nil;
          if (!SZCStreamEntry(sender, ipa, e, &streamError)) {
            return [[FBDeviceControlError describeFormat:@"Streaming failed: %@", streamError.localizedDescription] failFuture];
          }
        }

        // 4. Trailer — just the central-directory-header signature, no actual
        //    central directory body. The device-side parser only needs this
        //    sentinel to know we're done emitting local file headers.
        uint32_t trailer = SZCZipCDSig;
        if (![sender sendBytes:&trailer length:4]) {
          return [[FBDeviceControlError describe:@"Failed to send central directory trailer"] failFuture];
        }

        // Wait for any queued sends to drain before we start reading the
        // device's response — otherwise the progress recv would race the
        // last bytes we still need to push.
        if (![sender flush]) {
          return [[FBDeviceControlError describe:@"Send queue drained with errors"] failFuture];
        }

        // 5. Read progress plists until DataComplete or error.
        for (;;) {
          NSDictionary *progress = SZCRecvPlist(connection, &innerError);
          if (!progress) {
            return [[FBDeviceControlError describeFormat:@"Lost connection to streaming_zip_conduit: %@", innerError] failFuture];
          }
          NSString *status = progress[@"Status"];
          if ([status isEqualToString:@"DataComplete"]) {
            break;
          }
          NSDictionary *progressDict = progress[@"InstallProgressDict"];
          NSString *err = progressDict[@"Error"] ?: progress[@"Error"];
          if (err) {
            NSString *desc = progressDict[@"ErrorDescription"] ?: progress[@"ErrorDescription"];
            return [[FBDeviceControlError describeFormat:@"Streaming install failed: %@ (%@)", err, desc] failFuture];
          }
          // Other intermediate progress messages (PercentComplete) — ignore at
          // info level. Available via debug logger if the user wants them.
          [self.device.logger.debug logFormat:@"streaming_zip_conduit progress: %@", progress];
        }

        NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - started;
        [self.device.logger logFormat:@"Installed %@ via native streaming_zip_conduit in %.2fs", ipaPath.lastPathComponent, elapsed];
        return [FBFuture futureWithResult:NSNull.null];
      }];
    }];
}

- (FBFuture<NSNull *> *)secureInstallApplicationBundle:(NSURL *)bundleURL options:(NSDictionary *)options
{
  // Single-call streaming install via com.apple.streaming_zip_conduit. This
  // is what Xcode and ios-deploy use. Combines transfer + on-device unzip
  // into one pipelined operation — typically ~2x faster than the legacy
  // SecureTransferPath + SecureInstallApplication sequence.
  return [[self.device.amDevice
    connectToDeviceWithPurpose:@"install_bundle"]
    onQueue:self.device.workQueue pop:^(FBAMDevice *device) {
      [self.device.logger logFormat:@"Installing %@ via streaming_zip_conduit", bundleURL.lastPathComponent];
      CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
      // Signature: (AMDeviceRef, NSURL *, NSDictionary *, callback). No
      // leading int and no callback context — confirmed from mobdevim's RE'd
      // MobileDevice header. Different from SecureInstallApplication which
      // has 6 args including a leading int and a void* context. We use a
      // dedicated StreamingInstallCallback that doesn't retain the second
      // arg, since there's no user context — what the streaming API passes
      // there is an internal MobileDevice pointer that ARC must not touch.
      int status = self.device.amDevice.calls.SecureInstallApplicationBundle(
        device.amDevice,
        (__bridge CFURLRef _Nonnull)(bundleURL),
        (__bridge CFDictionaryRef _Nonnull)(options),
        (AMDeviceProgressCallback) StreamingInstallCallback
      );
      NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - started;
      if (status != 0) {
        NSString *errorMessage = CFBridgingRelease(self.device.amDevice.calls.CopyErrorText(status));
        [self.device.logger logFormat:@"Streaming install failed for %@ after %.2fs: %@", bundleURL.lastPathComponent, elapsed, errorMessage];
        return [[FBDeviceControlError
          describeFormat:@"Failed to install bundle %@ via streaming_zip_conduit (%@)", bundleURL.lastPathComponent, errorMessage]
          failFuture];
      }
      [self.device.logger logFormat:@"Installed %@ via streaming_zip_conduit in %.2fs", bundleURL.lastPathComponent, elapsed];
      return [FBFuture futureWithResult:NSNull.null];
    }];
}

- (FBFuture<NSNull *> *)secureInstallApplication:(NSURL *)appURL options:(NSDictionary *)options
{
  return [[self.device.amDevice
    connectToDeviceWithPurpose:@"install"]
    onQueue:self.device.workQueue pop:^(FBAMDevice *device) {
      [self.device.logger logFormat:@"Installing Application %@", appURL];
      CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
      int status = self.device.amDevice.calls.SecureInstallApplication(
        0,
        device.amDevice,
        (__bridge CFURLRef _Nonnull)(appURL),
        (__bridge CFDictionaryRef _Nonnull)(options),
        (AMDeviceProgressCallback) InstallCallback,
        (__bridge void *) (self.device.amDevice)
      );
      NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - started;
      if (status != 0) {
        NSString *errorMessage = CFBridgingRelease(self.device.amDevice.calls.CopyErrorText(status));
        [self.device.logger logFormat:@"Install failed for %@ after %.2fs: %@", [appURL lastPathComponent], elapsed, errorMessage];
        return [[FBDeviceControlError
          describeFormat:@"Failed to install application %@ (%@)", [appURL lastPathComponent], errorMessage]
          failFuture];
      }
      [self.device.logger logFormat:@"Installed Application %@ in %.2fs", appURL, elapsed];
      return [FBFuture futureWithResult:NSNull.null];
    }];
}

- (FBFuture<NSDictionary<NSString *, NSDictionary<NSString *, id> *> *> *)installedApplicationsData:(NSArray<NSString *> *)returnAttributes
{
  return [[self.device.amDevice
    connectToDeviceWithPurpose:@"installed_apps"]
    onQueue:self.device.workQueue pop:^ FBFuture<NSDictionary<NSString *, NSDictionary<NSString *, id> *> *> * (FBAMDevice *device) {
      NSDictionary<NSString *, id> *options = @{
        @"ReturnAttributes": returnAttributes,
      };
      CFDictionaryRef applications;
      int status = self.device.amDevice.calls.LookupApplications(
        device.amDevice,
        (__bridge CFDictionaryRef _Nullable)(options),
        &applications
      );
      if (status != 0) {
        NSString *errorMessage = CFBridgingRelease(self.device.amDevice.calls.CopyErrorText(status));
        return [[FBDeviceControlError
          describeFormat:@"Failed to get list of applications (%@)", errorMessage]
          failFuture];
      }
      return [FBFuture futureWithResult:CFBridgingRelease(applications)];
    }];
}

- (FBFuture<NSString *> *)launchableRemoteApplicationPathForConfiguration:(FBApplicationLaunchConfiguration *)configuration
{
  return [[self
    installedApplicationWithBundleID:configuration.bundleID]
    onQueue:self.device.workQueue fmap:^(FBInstalledApplication *installedApplication) {
      if (installedApplication.installType != FBApplicationInstallTypeUserDevelopment) {
        return [[FBDeviceControlError
          describeFormat:@"Application %@ cannot be launched as it's not signed with a development identity", installedApplication]
          failFuture];
      }
      return [FBFuture futureWithResult:installedApplication.bundle.path];
    }];
}

+ (FBInstalledApplication *)installedApplicationFromDictionary:(NSDictionary<NSString *, id> *)app
{
  NSString *bundleName = app[FBApplicationInstallInfoKeyBundleName] ?: @"";
  NSString *path = app[FBApplicationInstallInfoKeyPath] ?: @"";
  NSString *bundleID = app[FBApplicationInstallInfoKeyBundleIdentifier];
  FBApplicationInstallType installType = [FBInstalledApplication
    installTypeFromString:(app[FBApplicationInstallInfoKeyApplicationType] ?: @"")
    signerIdentity:(app[FBApplicationInstallInfoKeySignerIdentity] ? : @"")];

  FBApplicationBundle *bundle = [FBApplicationBundle
    applicationWithName:bundleName
    path:path
    bundleID:bundleID];

  return [FBInstalledApplication
    installedApplicationWithBundle:bundle
    installType:installType];
}

+ (NSArray<NSString *> *)installedApplicationLookupAttributes
{
  static dispatch_once_t onceToken;
  static NSArray<NSString *> *lookupAttributes = nil;
  dispatch_once(&onceToken, ^{
    lookupAttributes = @[
      FBApplicationInstallInfoKeyApplicationType,
      FBApplicationInstallInfoKeyBundleIdentifier,
      FBApplicationInstallInfoKeyBundleName,
      FBApplicationInstallInfoKeyPath,
      FBApplicationInstallInfoKeySignerIdentity,
    ];
  });
  return lookupAttributes;
}

@end
