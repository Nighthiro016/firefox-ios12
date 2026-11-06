#!/bin/bash
# Auto-resolve the known 0.20.x upstream sync conflicts while keeping the fork
# iOS 12 compatible. Anything outside the known conflict set aborts loudly for
# manual review - never force-resolve unknown files.
#
# Strategies (see .github/workflows/sync-upstream.yml):
#   PromptDelegate/PromptPresenter.swift      ours + overlay (port upstream's
#                                             beforeunload to sync/no-Concurrency)
#   Bookmarks/History view controllers        auto-merged upstream #488 code,
#                                             overlay adds @available(iOS 13.0,*)
#   StaticPrefList.yaml.patch                 ours (XP_IOS socket-process-off guard)
#   NativeLayerCA.mm.patch                    ours + overlay (preventsCapture guard
#                                             re-anchored to the Firefox 159 source)
#   nsWindow.mm.patch                         theirs (Firefox 159 APZBridge rebase)
#                                             + overlay (iOS 12 nil-interaction guard)
#   nsHttpHandler.cpp.patch                   accept upstream's deletion of the
#                                             socket-process IPC family; install the
#                                             fresh real-iOS-version UA patch
#   .github/workflows/build.yml               keep the fork's deletion (drop
#                                             upstream's CI workflows)
#   nsNetworkLinkServiceIOS.mm.patch          drop (target file no longer exists
#                                             in Firefox 159)
#
# Self-contained: the overlay patches are embedded below and unpacked into a
# temp dir at runtime. No other files are required.
set -eu
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

KNOWN_SET="
.github/workflows/build.yml
browser/GeckoView/Delegates/PromptDelegate.swift
browser/Reynard/Client/Interface/ContentView/WebContent/PromptPresenter.swift
patches/gfx/layers/NativeLayerCA.mm.patch
patches/modules/libpref/init/StaticPrefList.yaml.patch
patches/netwerk/protocol/http/nsHttpHandler.cpp.patch
patches/widget/uikit/nsWindow.mm.patch
"

UNKNOWN="$(git diff --name-only --diff-filter=U | grep -v -x -f <(printf '%s' "$KNOWN_SET") || true)"
if [ -n "$UNKNOWN" ]; then
        echo "ERROR: unresolved paths outside the known sync conflict set:" >&2
        echo "$UNKNOWN" >&2
        echo "Manual iOS 12 review is required; do not force-resolve." >&2
        exit 1
fi

cat > "$TMP/PromptDelegate.swift.patch" <<'REY_EOF_1'
diff --git a/browser/GeckoView/Delegates/PromptDelegate.swift b/browser/GeckoView/Delegates/PromptDelegate.swift
index 88571a4d..2c15be3f 100644
--- a/browser/GeckoView/Delegates/PromptDelegate.swift
+++ b/browser/GeckoView/Delegates/PromptDelegate.swift
@@ -61,7 +61,7 @@ func newPromptHandler(_ session: GeckoSession) -> GeckoSessionHandler {
                 // Upstream beforeUnload/repost fix (sync, no Concurrency):
                 // a prompt that fails to parse still cancels the reload spinner.
                 let promptType = promptData["type"] as? String
-                if promptType == "beforeUnload" || promptType == "repost" {
+                if promptType == "repost" {
                     session.progressDelegate?.onReloadCancelled(session: session)
                 }
                 completion(.success(nil))
@@ -72,9 +72,15 @@ func newPromptHandler(_ session: GeckoSession) -> GeckoSessionHandler {
                 return
             }
             delegate.onPrompt(session: session, request: request) { response in
+                // Upstream 0.20.x beforeUnload fix, ported to the fork's sync
+                // (no Concurrency) style: if the user does not allow leaving,
+                // the reload spinner must be cancelled.
+                if case .beforeUnload = request,
+                   response?.geckoMessage["allow"] as? Bool != true {
+                    session.progressDelegate?.onReloadCancelled(session: session)
+                }
                 completion(.success(response?.geckoMessage))
             }
-
         case .promptUpdate:
             guard let promptData = message?["prompt"] as? [String: Any],
                   let request = parsePromptRequest(promptData) else {
REY_EOF_1
cat > "$TMP/PromptPresenter.swift.patch" <<'REY_EOF_2'
diff --git a/browser/Reynard/Client/Interface/ContentView/WebContent/PromptPresenter.swift b/browser/Reynard/Client/Interface/ContentView/WebContent/PromptPresenter.swift
index 25e2b15e..f99cfacb 100644
--- a/browser/Reynard/Client/Interface/ContentView/WebContent/PromptPresenter.swift
+++ b/browser/Reynard/Client/Interface/ContentView/WebContent/PromptPresenter.swift
@@ -10,6 +10,7 @@ import UIKit
 
 
 final class PromptPresenter: PromptPresenting {
+    private var beforeUnloadAlerts: [String: PromptAlertController] = [:]
     private var selectPickers: [String: SelectPicker] = [:]
     private var colorPickers: [String: ColorPicker] = [:]
     private var dateTimePickers: [String: DateTimePicker] = [:]
@@ -33,6 +34,10 @@ final class PromptPresenter: PromptPresenting {
         case .auth(let request):
             presentAuth(request: request, completion: completion)
 
+        case .beforeUnload(let request):
+            presentBeforeUnload(request: request, completion: completion)
+
+
         case .folderUpload(let request):
             presentFolderUpload(request: request, completion: completion)
 
@@ -67,6 +72,7 @@ final class PromptPresenter: PromptPresenting {
             // Gecko fires dismiss when native date UI steals focus; the picker owns completion.
             return
         }
+        beforeUnloadAlerts.removeValue(forKey: promptID)?.dismiss(animated: true)
         selectPickers.removeValue(forKey: promptID)?.cancelAndDismiss()
         colorPickers.removeValue(forKey: promptID)?.cancelAndDismiss()
         dateTimePickers.removeValue(forKey: promptID)?.cancelAndDismiss()
@@ -239,6 +245,33 @@ final class PromptPresenter: PromptPresenting {
         presenter.present(alert, animated: true)
     }
 
+    // Upstream 0.20.x beforeunload prompt, ported to the fork's sync
+    // (no Concurrency) style. beforeUnloadAlerts also lets dismiss(promptID:)
+    // cancel the alert when Gecko dismisses the prompt itself.
+    private func presentBeforeUnload(request: BeforeUnloadPromptRequest, completion: @escaping (PromptResponse?) -> Void) {
+        guard let presenter = UIApplication.shared.topViewController() else {
+            completion(nil)
+            return
+        }
+
+        var allowed = false
+        let alert = PromptAlertController(
+            title: NSLocalizedString("Leave Page?", comment: ""),
+            message: NSLocalizedString("Changes you made may not be saved.", comment: ""),
+            preferredStyle: .alert
+        )
+        alert.onDismissed = { [weak self] in
+            self?.beforeUnloadAlerts.removeValue(forKey: request.id)
+            completion(.beforeUnload(allowed: allowed))
+        }
+        alert.addAction(UIAlertAction(title: NSLocalizedString("Stay", comment: ""), style: .cancel))
+        alert.addAction(UIAlertAction(title: NSLocalizedString("Leave", comment: ""), style: .destructive) { _ in
+            allowed = true
+        })
+        beforeUnloadAlerts[request.id] = alert
+        presenter.present(alert, animated: true)
+    }
+
     private func presentFolderUpload(request: FolderUploadPromptRequest, completion: @escaping (PromptResponse?) -> Void) {
         guard let presenter = UIApplication.shared.topViewController() else {
             completion(nil)
REY_EOF_2
cat > "$TMP/BookmarksViewController.swift.patch" <<'REY_EOF_3'
diff --git a/browser/Reynard/Client/Interface/Library/Bookmarks/BookmarksViewController.swift b/browser/Reynard/Client/Interface/Library/Bookmarks/BookmarksViewController.swift
index 9271a90c..d30ddffa 100644
--- a/browser/Reynard/Client/Interface/Library/Bookmarks/BookmarksViewController.swift
+++ b/browser/Reynard/Client/Interface/Library/Bookmarks/BookmarksViewController.swift
@@ -384,6 +384,7 @@ final class BookmarksViewController: UIViewController, UITableViewDataSource, UI
         return didDelete
     }
     
+    @available(iOS 13.0, *)
     func tableView(
         _ tableView: UITableView,
         contextMenuConfigurationForRowAt indexPath: IndexPath,
REY_EOF_3
cat > "$TMP/HistoryViewController.swift.patch" <<'REY_EOF_4'
diff --git a/browser/Reynard/Client/Interface/Library/History/HistoryViewController.swift b/browser/Reynard/Client/Interface/Library/History/HistoryViewController.swift
index a7128224..c4cb99b2 100644
--- a/browser/Reynard/Client/Interface/Library/History/HistoryViewController.swift
+++ b/browser/Reynard/Client/Interface/Library/History/HistoryViewController.swift
@@ -564,6 +564,7 @@ final class HistoryViewController: UIViewController, UITableViewDataSource, UITa
         return configuration
     }
     
+    @available(iOS 13.0, *)
     func tableView(
         _ tableView: UITableView,
         contextMenuConfigurationForRowAt indexPath: IndexPath,
REY_EOF_4
cat > "$TMP/NativeLayerCA.mm.patch.patch" <<'REY_EOF_5'
diff --git a/patches/gfx/layers/NativeLayerCA.mm.patch b/patches/gfx/layers/NativeLayerCA.mm.patch
index 75ff5a6d..384966ab 100644
--- a/patches/gfx/layers/NativeLayerCA.mm.patch
+++ b/patches/gfx/layers/NativeLayerCA.mm.patch
@@ -230,15 +230,15 @@ index 0d8cd5a..af933a2 100644
  #ifdef NIGHTLY_BUILD
      if (StaticPrefs::gfx_core_animation_specialize_video_log()) {
        NSLog(@"VIDEO_LOG: EnqueueSurface failed on allocating sample buffer.");
-@@ -1843,7 +1969,10 @@ bool NativeLayerCARepresentation::ApplyChanges(
-   }
- 
-   if (aSpecializeVideo && mMutatedIsDRM) {
--    ((AVSampleBufferDisplayLayer*)mContentCALayer).preventsCapture = aIsDRM;
-+    // preventsCapture is iOS 13+.
-+    if (__builtin_available(iOS 13.0, *)) {
-+      ((AVSampleBufferDisplayLayer*)mContentCALayer).preventsCapture = aIsDRM;
-+    }
-   }
- 
+@@ -1820,6 +1946,9 @@ bool NativeLayerCARepresentation::ApplyChanges(
+         [(AVSampleBufferDisplayLayer*)mContentCALayer
+             setControlTimebase:timebase];
+         CFRelease(timebase);
+-        ((AVSampleBufferDisplayLayer*)mContentCALayer).preventsCapture = aIsDRM;
++        // preventsCapture is iOS 13+ (AVSampleBufferDisplayLayer property).
++        if (__builtin_available(iOS 13.0, *)) {
++          ((AVSampleBufferDisplayLayer*)mContentCALayer).preventsCapture = aIsDRM;
++        }
+         if (aIsDRM) {
+           mProtectedBackingLayer = [[CALayer layer] retain];
    bool shouldTintOpaqueness = StaticPrefs::gfx_core_animation_tint_opaque();
REY_EOF_5
cat > "$TMP/nsWindow.mm.patch.patch" <<'REY_EOF_6'
diff --git a/patches/widget/uikit/nsWindow.mm.patch b/patches/widget/uikit/nsWindow.mm.patch
index bbf6000a..8fc5ae6b 100644
--- a/patches/widget/uikit/nsWindow.mm.patch
+++ b/patches/widget/uikit/nsWindow.mm.patch
@@ -185,7 +185,7 @@ index c1c4c3deb341..db9c9c679c87 100644
      mRootCALayer = [[CALayer layer] retain];
      mRootCALayer.position = CGPointZero;
      mRootCALayer.bounds = CGRectZero;
-@@ -169,19 +191,21 @@ - (id)initWithFrame:(CGRect)inFrame geckoChild:(nsWindow*)inChild {
+@@ -169,19 +191,26 @@ - (id)initWithFrame:(CGRect)inFrame geckoChild:(nsWindow*)inChild {
      mRootCALayer.contentsGravity = kCAGravityTopLeft;
      [[self layer] addSublayer:mRootCALayer];
    }
@@ -211,9 +211,14 @@ index c1c4c3deb341..db9c9c679c87 100644
 +                                           pointerSupport:mPointerSupport
 +                                            pencilSupport:mPencilSupport];
 +  [self setupTextInput];
-+  [mPointerSupport requireTextInteractionsToFail:@[
-+    mEditable.mEditableTextInteraction, mEditable.mReadOnlyTextInteraction
-+  ]];
++  // Both interactions are nil on iOS 12 (no +textInteractionForMode:);
++  // stuffing nil into the array literal below would raise.
++  if (mEditable.mEditableTextInteraction &&
++      mEditable.mReadOnlyTextInteraction) {
++    [mPointerSupport requireTextInteractionsToFail:@[
++      mEditable.mEditableTextInteraction, mEditable.mReadOnlyTextInteraction
++    ]];
++  }
  
    // This is managed with weak references by the notification center so that we
    // do not need to call removeObserver.
REY_EOF_6
cat > "$TMP/nsHttpHandler-ios12-ua.patch" <<'REY_EOF_7'
diff --git a/netwerk/protocol/http/nsHttpHandler.cpp b/netwerk/protocol/http/nsHttpHandler.cpp
--- a/netwerk/protocol/http/nsHttpHandler.cpp
+++ b/netwerk/protocol/http/nsHttpHandler.cpp
@@ -107,8 +107,12 @@
 
 #if defined(XP_MACOSX)
 #  include <CoreServices/CoreServices.h>
 #endif
 
+#if defined(XP_IOS)
+#  include <sys/sysctl.h>
+#endif
+
 //-----------------------------------------------------------------------------
 #include "mozilla/net/HttpChannelChild.h"
 
@@ -1187,8 +1191,20 @@
 
 #if defined(XP_IOS)
-  // Freeze the iOS version to 18.0, use an underscore separator to avoid
-  // detection as macOS.
-  mCompatDevice.AssignLiteral("CPU iPhone OS 18_0 like Mac OS X");
+  // Report the actual iOS version, using an underscore separator to avoid
+  // detection as macOS. Fall back to a frozen version if the sysctl fails.
+  nsAutoCString iosVersion;
+  char osVersionBuf[128];
+  size_t osVersionLen = sizeof(osVersionBuf);
+  if (sysctlbyname("kern.osproductversion", osVersionBuf, &osVersionLen,
+                   nullptr, 0) == 0) {
+    iosVersion.Assign(osVersionBuf);
+    iosVersion.ReplaceChar('.', '_');
+  } else {
+    iosVersion.AssignLiteral("18_0");
+  }
+  mCompatDevice.AssignLiteral("CPU iPhone OS ");
+  mCompatDevice.Append(iosVersion);
+  mCompatDevice.AppendLiteral(" like Mac OS X");
 #endif
 
   // Gather OS/CPU.
REY_EOF_7

P_DELEGATE="$TMP/PromptDelegate.swift.patch"
P_PRESENTER="$TMP/PromptPresenter.swift.patch"
P_BOOKMARKS="$TMP/BookmarksViewController.swift.patch"
P_HISTORY="$TMP/HistoryViewController.swift.patch"
P_NATIVELAYER="$TMP/NativeLayerCA.mm.patch.patch"
P_NSWINDOW="$TMP/nsWindow.mm.patch.patch"
P_UA="$TMP/nsHttpHandler-ios12-ua.patch"

echo "== Swift: fork's sync prompt flow + ported upstream beforeunload"
git checkout --ours -- browser/GeckoView/Delegates/PromptDelegate.swift
git apply --whitespace=nowarn "$P_DELEGATE"
git checkout --ours -- browser/Reynard/Client/Interface/ContentView/WebContent/PromptPresenter.swift
git apply --whitespace=nowarn "$P_PRESENTER"

echo "== Swift: @availability for the upstream context-menu delegate methods"
git apply --whitespace=nowarn "$P_BOOKMARKS"
git apply --whitespace=nowarn "$P_HISTORY"

echo "== engine patches"
git checkout --ours -- patches/modules/libpref/init/StaticPrefList.yaml.patch
git checkout --ours -- patches/gfx/layers/NativeLayerCA.mm.patch
git apply --whitespace=nowarn "$P_NATIVELAYER"
git checkout --theirs -- patches/widget/uikit/nsWindow.mm.patch
git apply --whitespace=nowarn "$P_NSWINDOW"
git rm -q -- patches/netwerk/protocol/http/nsHttpHandler.cpp.patch
cp "$P_UA" patches/netwerk/protocol/http/

echo "== workflows: keep the fork's set only"
git rm -qf -- .github/workflows/build.yml

if [ -f patches/netwerk/system/ios/nsNetworkLinkServiceIOS.mm.patch ]; then
        echo "== drop patch for a file Firefox 159 no longer has"
        git rm -qf -- patches/netwerk/system/ios/nsNetworkLinkServiceIOS.mm.patch
fi

git add -A
GIT_EDITOR=true git merge --continue
echo "== merge resolved and committed; next: iOS 12 compile check"
