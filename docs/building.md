# Building

# Server (PC, Linux)

## Build dependencies

As Arch package names: `cmake` `ninja` `pkgconf` `eigen` `nlohmann-json` `cli11` `boost-libs` `openssl` `avahi` `glslang` `vulkan-headers` `vulkan-icd-loader`

For audio support, install at least one of: `pipewire` (recommended) or `libpulse`

## Compile

From your checkout directory, with automatic detection of encoders
```bash
cmake -B build-server . -GNinja -DWIVRN_BUILD_CLIENT=OFF -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build-server
```

It is possible to disable specific encoders, by adding options
```
-DWIVRN_USE_NVENC=OFF
-DWIVRN_USE_VAAPI=OFF
-DWIVRN_USE_VULKAN_ENCODE=OFF
-DWIVRN_USE_X264=OFF
```

Force specific audio backends
```
-DWIVRN_USE_PIPEWIRE=ON
-DWIVRN_USE_PULSEAUDIO=ON
```

Systemd service and pretty hostname support
```
-DWIVRN_USE_SYSTEMD=ON
```

Lighthouse driver support for use with lighthouse-tracked devices
```
-DWIVRN_FEATURE_STEAMVR_LIGHTHOUSE=ON
```

Additionally, if your environment requires absolute paths inside the OpenXR runtime manifest, you can add `-DWIVRN_OPENXR_MANIFEST_TYPE=absolute` to the build configuration.

# Server (macOS)

> [!WARNING]
> The macOS port is experimental. Only bare minimum features are implemented. See the top of [README.md](../README.md) for known limitations.

## Prerequisites

- macOS 13 (Ventura) or later
- Xcode Command Line Tools: `xcode-select --install`
- [Homebrew](https://brew.sh)
- [LunarG Vulkan SDK](https://vulkan.lunarg.com/sdk/home#mac) (1.3.261 or later) — provides MoltenVK, Vulkan headers, and `glslangValidator`

## Build dependencies

Install the required packages with Homebrew:

```bash
brew install cmake ninja pkg-config eigen nlohmann-json cli11 boost openssl librsvg
```

After installing the Vulkan SDK, source its environment setup script (the exact path depends on the SDK version):

```bash
source ~/VulkanSDK/<version>/setup-env.sh
```

Or add it permanently to your shell profile (e.g. `~/.zprofile`).

## Compile

From your checkout directory:

```bash
cmake -B build-server . -GNinja -DWIVRN_BUILD_CLIENT=OFF -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build-server
```

CMake automatically detects macOS and configures the build accordingly:
- Uses VideoToolbox for hardware encoding
- Uses CoreAudio for audio
- Uses Bonjour (built into macOS) for headset discovery
- Disables Linux-only features (systemd, avahi, etc.)

The build produces two executables in `build-server/server/`:
- `wivrn-server` — the main server process (manages connections and launches the compositor)
- `wivrn-compositor` — the XR compositor process (spawned automatically by `wivrn-server`)

## Running on macOS

Run the server directly from the terminal:

```bash
./build-server/server/wivrn-server
```

Make sure the headset connects **before** launching any VR application.

# Dashboard

The WiVRn dashboard requires Qt6, and the WiVRn server.

## Dashboard (Linux)

### Compile

From your checkout directory, compile both the server and the dashboard:
```bash
cmake -B build-dashboard . -GNinja -DWIVRN_BUILD_CLIENT=OFF -DWIVRN_BUILD_SERVER=ON -DWIVRN_BUILD_DASHBOARD=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build-dashboard
```

See [Server (PC, Linux)](#server-pc-linux) for the server compile options.

## Dashboard (macOS)

The dashboard can be built on macOS alongside the server. The D-Bus interface used on Linux is automatically disabled; all other features are available.

### Build dependencies

The dashboard requires several KDE Frameworks 6 packages (Kirigami, KCoreAddons, KIconThemes, kirigami-addons) that are **not yet available in Homebrew** (neither Homebrew Core nor the official KDE tap). The recommended way to obtain these on macOS is via [KDE Craft](https://community.kde.org/Craft), the official KDE build framework for macOS.

#### 1. Install KDE Craft

Requires Python 3 and Xcode Command Line Tools (already listed in [Prerequisites](#prerequisites)):

```bash
curl https://raw.githubusercontent.com/KDE/craft/master/setup/CraftBootstrap.py -o /tmp/setup.py
python3 /tmp/setup.py --prefix ~/CraftRoot
```

#### 2. Install KDE Framework dependencies via Craft

```bash
source ~/CraftRoot/craft/craftenv.sh
craft kirigami
craft kirigami-addons
craft qcoro
```

Craft automatically resolves and builds all transitive dependencies (Qt 6, KCoreAddons, KIconThemes, extra-cmake-modules, etc.).

> [!NOTE]
> `librsvg` must be installed via **Homebrew** (`brew install librsvg`), not through Craft.
> Craft may ship an older `fontconfig` (< 2.17.0) that conflicts with `librsvg`'s dependency
> requirements. CMake automatically prepends Homebrew's pkgconfig paths so that Homebrew's
> `librsvg` and its dependencies are found first, even when the Craft environment is active.

### Compile

Source the Craft environment, then compile both the server and the dashboard. CMake will automatically find the Qt and KDE Frameworks installed by Craft:

```bash
source ~/CraftRoot/craft/craftenv.sh
cmake -B build-dashboard . -GNinja -DWIVRN_BUILD_CLIENT=OFF -DWIVRN_BUILD_SERVER=ON -DWIVRN_BUILD_DASHBOARD=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build-dashboard
```

The dashboard executable `wivrn-dashboard` will be placed in `build-dashboard/dashboard/`.

# Client (headset)

#### Build dependencies
As Arch package names: git pkgconf glslang cmake jdk17-openjdk librsvg cli11 ktx_software-git ([AUR](https://aur.archlinux.org/packages/ktx_software-git))

OpenSSL build dependencies are also needed, as described [here](https://github.com/openssl/openssl/blob/master/INSTALL.md#prerequisites), in particular perl 5.

#### Android environment
Download [sdkmanager](https://developer.android.com/tools/sdkmanager) commandline tool and extract it to any directory.
Create your `ANDROID_HOME` directory, for instance `~/Android`.

Review and accept the licenses with
```bash
sdkmanager --sdk_root="${HOME}/Android" --licenses
```

Install the correct cmake version with
```bash
sdkmanager --install "cmake;3.31.5"
```

#### Apk signing
Your device may refuse to install an unsigned apk, so you must create signing keys before building the client
```
# Create key, then enter the password and other information that the tool asks for
keytool -genkey -v -keystore ks.keystore -alias default_key -keyalg RSA -keysize 2048 -validity 10000

# Substitute your password that you entered in the command above instead of YOUR_PASSWORD
echo signingKeyPassword="YOUR_PASSWORD" > gradle.properties
```
Once you have generated the keys, the apk will be automatically signed at build time

#### Client build
From the main directory.
```bash
export ANDROID_HOME=~/Android
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk/

./gradlew assembleRelease
```

Outputs will be in `build/outputs/apk/release/WiVRn-release.apk`

#### Install apk with adb
Before using adb you must enable usb debugging on your device:
 * Pico - https://developer.picoxr.com/document/unity-openxr/set-up-the-development-environment/ (see first step)
 * Quest - https://developer.oculus.com/documentation/unity/unity-env-device-setup/#headset-setup (see "Set Up Meta Headset" and "Test an App on Headset" until step 4)

Also add your device in udev rules: https://wiki.archlinux.org/title/Android_Debug_Bridge#Adding_udev_rules

Then connect the device via usb to your computer and execute the following commands
```
# Start adb server
adb start-server

# Check if the device is connected
adb devices

# Install apk
adb install build/outputs/apk/release/WiVRn-release.apk

# When you're done, you can stop the adb server
adb kill-server
```
