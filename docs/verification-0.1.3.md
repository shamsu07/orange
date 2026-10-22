# Orange 0.1.3 verification

Date: 22 October 2026. Target: Apple silicon; deployment target macOS 13. Runtime behavior on macOS 13 remains unverified.

## Reported failure and established cause

After the 0.1.2 audio change, the user confirmed that selection tones played during a held drag. The user then reported intermittent activation: the rotated PNG sometimes produced no wheel for Shift, Command or Control, worked after dragging the original sample, and failed again after returning to Finder.

Code review established an activation failure path in 0.1.2. Orange sampled the named drag pasteboard's change count when its global mouse-down callback executed, then required a later change before accepting files. Global event monitors deliver copied events asynchronously. If Finder had already published the current drag before that callback executed, the sampled baseline already described the current drag, so every subsequent unchanged read was rejected. Trying another modifier could not recover that gesture. This is a demonstrated consequence of the code and AppKit's delivery contract; no captured runtime trace establishes that it caused every reported failure. [Apple: global event monitoring](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:))

The named `.drag` pasteboard was also an unsuitable authority for cross-process file identity. Apple explicitly states that the standard named dragging pasteboard is not guaranteed to be used by a cross-process drag and directs destinations to use the sender's `draggingPasteboard`. [Apple: dragging destinations](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/DragandDrop/Concepts/dragdestination.html)

This report supersedes the fresh named-pasteboard capture description in [the historical 0.1.2 report](verification-0.1.2.md). Previous verification reports remain unchanged.

## Changes

- A recorded left-drag plus configured modifier arms a native receiver beneath the recorded pointer position. This no longer requires a named-pasteboard change or a previously delivered mouse-down callback. A click plus modifier, without dragging, does not arm it.
- Only the destination's actual `NSDraggingInfo.draggingPasteboard` supplies file URLs. `draggingSequenceNumber` binds those files to one native session. Repeated updates for that session must preserve the same URLs. Named `.drag` and general clipboard contents are neither an activation gate nor a fallback. [Apple: dragged data](https://developer.apple.com/documentation/appkit/nsdragginginfo/draggingpasteboard), [Apple: session identity](https://developer.apple.com/documentation/appkit/nsdragginginfo/draggingsequencenumber)
- The controller processes snapshots of event kind, timestamp, modifier flags and screen position. Older copied events are ignored. Mouse-drag events can update the mode without a separate modifier notification. Mouse coordinates use the event's associated window conversion, or its screen coordinates when that window is absent. [Apple: event location](https://developer.apple.com/documentation/appkit/nsevent/locationinwindow)
- Each gesture has a generation identifier. Deferred mouse-up completion and capability results must still belong to that generation and selection. Known retired native sequences cannot bind to a later gesture.
- Returning to another application dismisses a released picker or preview. It does not dismiss a drag still owned by Finder. The next gesture starts with a fresh binding.
- A temporary global mouse-movement monitor exists only while the receiver is armed. A later free-pointer movement recovers from a missing mouse-up, and the monitor is removed on completion or dismissal. This handles native window dragging, for which Apple documents that mouse-up may not be sent, without installing a high-frequency idle movement monitor. [Apple: native window dragging](https://developer.apple.com/documentation/appkit/nswindow/performdrag(with:))
- Before valid file data arrives, the artwork stays hidden and the receiver uses a 2% gray background without a shadow. This avoids relying on an entirely zero-alpha window for routing. Actual Finder routing into this receiver remains a native acceptance check. Apple's mouse hit-testing excludes windows transparent at the queried point. [Apple: window hit-testing](https://developer.apple.com/documentation/appkit/nswindow/windownumber(at:belowwindowwithwindownumber:))
- Empty or changed data from a bound current session cancels the selection. An unexpected non-retired replacement session also cancels it. Late callbacks from a known retired session are ignored. An invalidated selection cannot be revived by trailing release callbacks.
- Releasing a verified drag freezes its files for a later explicit click or keyboard confirmation. Hovering and drag release never execute an operation. Native destination callbacks return only copy, generic or no operation, according to the source's allowed mask; they never return move or delete. This does not stop an explicitly selected Move action from running later. [Apple: source operation masks and modifier filtering](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/DragandDrop/Concepts/dragsource.html)

## Automated checks

**111 tests passed: 69 core tests and 42 app tests, with zero failures, zero skips and no compiler warnings.** The test run uses the local source-built FFmpeg/libwebp backend and normal macOS service access for native media, Vision, audio, clipboard and window checks.

The app tests include **18 controller regressions** covering:

- A native payload published before Orange processes mouse-down; actual destination entry, update, preparation and drop callbacks.
- An armed receiver remains hit-testable through its native view hierarchy before file data arrives.
- A modifier held before the drag threshold, tapped afterward, or carried only by mouse-drag events.
- Recovery when the activation mouse-down was missed.
- Repeated and alternating original/rotated file URLs in independent native sessions.
- Returning to Finder after a released picker, while preserving a newly active Finder-owned drag.
- A queued release from an earlier gesture, late retired-session data and older copied events.
- Window/text/nonfile drags, including a window drag that omits mouse-up before free-pointer recovery.
- Empty current-session data, unexpected replacement data and an empty unexpected native session.
- Mode switching without replacing the files or moving the receiver.
- A source that permits only move never receiving a move operation from Orange.

The native sender test helper uses a unique private pasteboard and does not touch `.drag` or the general clipboard. Capability loading is injected in controller tests; those tests establish controller and destination-callback behavior, not that Finder or the window server delivers those callbacks. No controller regression starts a conversion or transmits a file.

Existing conversion, output-preservation, cancellation, login-service, sharing-session, held-drag feedback and geometry tests remain in the full suite. Login tests inject the OS service and do not establish installed login or reboot behavior. Sharing tests do not establish device-to-device delivery.

Repository-local logs:

- `.cache/tests-0.1.3-final.log`
- `.cache/build-0.1.3-final.log`

The release-build log records a completed build of `build/Orange.app`. The live process was checked before requesting acceptance: only `/Users/shxms/dev/oss/orange/build/Orange.app/Contents/MacOS/Orange` was running, with no second Orange copy.

## Native acceptance — failed

The user tested the running 0.1.3 repository build after returning to Finder and reported: “At least one first attempt fails.” This fails the repeated first-attempt acceptance requirement. The native-session rewrite and passed automated tests did not resolve the reported reliability issue.

An explicitly instrumented debug build was then used to record input delivery, receiver presentation, native drag callbacks and cancellation reasons. The user reported that this attempt worked. A successful diagnostic attempt does not establish the intermittent fault's cause or resolution; diagnostic timing can differ from release timing. The user also reported that Resize created an image with unchanged dimensions. Code inspection confirmed that the 1,920-pixel default maximum leaves smaller inputs unchanged while still writing a new file.

Required remaining checks include repeated and alternating `sample.png`/`sample-rotated.png` drags; leaving and returning to Finder; Shift/Command/Control activation; release-then-click confirmation; and cancellation/recovery. The earlier user's confirmation of held-drag tones applies to 0.1.2, not completed 0.1.3 acceptance. Automated callback injection and the passed native view hit-test do not establish reliable Finder routing, perceived smoothness or audible latency.

## Packaged artifacts

The 0.1.3 DMG and ZIP passed integrity and SHA-256 checks. A read-only DMG mount inside `.cache/` verified the Applications shortcut, strict deep app signature, bundled FFmpeg/libwebp source checksums, and executable/icon identity against the tested build. The mounted executable's self-check reported 0.1.3 with both media tools available. The ZIP was extracted inside `.cache/`; its app signature and executable/icon comparisons passed. The image was detached afterward. Packaging log: `.cache/package-0.1.3.log`.

| Artifact | SHA-256 |
| --- | --- |
| `Orange-0.1.3-macos-arm64.dmg` | `b1768c67b779a16a13d3ba036d71b0daacce44d087f9fc75440aacfe05f6346c` |
| `Orange-0.1.3-macos-arm64.zip` | `98ccd306e3477af04bb17210950cdb5b59c6c447782a6653bc14298253fe7c6e` |

Signing is ad hoc. No publication, Developer ID signing, notarization or Gatekeeper installation acceptance is claimed. Earlier release archives were preserved; their reports are historical evidence, not validation of the 0.1.3 artifacts.

## Remaining boundaries

Installed login registration/approval/reboot, device-to-device AirDrop transfer, multiple displays and Spaces, macOS 13 runtime, full Tangerine parity and matched-output performance remain unverified. Passing the suite does not establish complete product quality or native interaction parity.
