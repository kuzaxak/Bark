// Licensed under GPL-3.0. See LICENSE.

#import <CloudKit/CloudKit.h>

#include "bark/bridge/barc_bridge_api.h"
#include "chrome/browser/app_controller_mac.h"

@interface AppController (BarkCloudShare)
@end

@implementation AppController (BarkCloudShare)

- (void)application:(NSApplication*)application
    userDidAcceptCloudKitShareWithMetadata:(CKShareMetadata*)metadata {
  if (application.delegate != self || !metadata)
    return;
  [NSNotificationCenter.defaultCenter
      postNotificationName:@BARC_CLOUD_SHARE_NOTIFICATION
                    object:self
                  userInfo:@{@"metadata" : metadata}];
}

@end
