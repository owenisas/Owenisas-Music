---
description: Build, Test, and Deploy to iOS Device (Prioritize iPhone 13 mini)
---

This workflow helps you discover connected physical devices (prioritizing iPhone 13 mini), tests the app using `xcodebuild`, builds it, and installs it onto the device.

## 1. List Available Devices

Check what devices are available and connected to the Mac. We will search for physical devices (ignoring simulators) and prioritize the iPhone 13 mini.

// turbo
```bash
xcrun devicectl list devices || xcrun xctrace list devices
```

Look at the output and identify the target device. Ideally, choose the "iPhone 13 mini". Note its identifier/UDID. If the iPhone 13 mini is not available, pick another connected physical device.

## 2. Build and Test on the Target Device

Use `xcodebuild` to build the app and run existing tests on the selected device.
*Note: We set `derivedDataPath` so we easily know where the built `.app` is located.*

Replace `iPhone 13 mini` with the actual device name if it differs:

```bash
xcodebuild test -project "Owenisas Music.xcodeproj" -scheme "Owenisas Music" -destination "generic/platform=iOS" -derivedDataPath ./derivedData -allowProvisioningUpdates
```
*(If the project does not run tests successfully but you still want to deploy, use the command in Step 3 to build instead.)*

## 3. Build for Deployment

If you want to just build the app for this physical device without testing:

```bash
xcodebuild build -project "Owenisas Music.xcodeproj" -scheme "Owenisas Music" -destination "generic/platform=iOS" -derivedDataPath ./derivedData -allowProvisioningUpdates
```

## 4. Install app onto the Device

Locate the compiled `.app` file in the derived data path and install it directly via `xcrun devicectl`.
Replace `<DEVICE_ID>` with the actual UDID/identifier of the connected iPhone from step 1:

```bash
xcrun devicectl device install app --device <DEVICE_ID> "./derivedData/Build/Products/Debug-iphoneos/Owenisas Music.app"
```

*Fallback for older Xcode versions (< 15):*
If `devicectl` is not available, try using `ios-deploy`:
```bash
ios-deploy --id <DEVICE_ID> --bundle "./derivedData/Build/Products/Debug-iphoneos/Owenisas Music.app" --debug --justlaunch
```
