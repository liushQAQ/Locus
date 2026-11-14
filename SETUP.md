# Locus — install & first teleport

## 1. Sideload the IPA

Install the latest IPA from [Releases](https://github.com/ChrisMack32/Locus/releases) (or build from source) with Feather, SideStore, AltStore, Sideloadly, or LiveContainer.

Bundle ID: `com.chrismack.locus`

### LiveContainer

File pickers often break inside LiveContainer. Do one of the following:

1. Long-press **Locus** in LiveContainer → **Settings** → enable **Fix File Picker**, then try Import again.
2. Share / open the pairing file **into LiveContainer → Locus** (iOS share sheet).
3. Copy the RPPairing plist contents, open Locus → **Paste RPPairing from clipboard** (setup or Settings).

## 2. Pairing

### On iOS 27 — no computer

1. Open Locus → **Settings → Pair on this iPhone** → **Start pairing**.
2. Allow **Local Network** (and Location / Notifications if asked).
3. Leave Locus open. Go to **Settings › Privacy & Security › Developer Mode › Pair with Host**.
4. Pick **Locus** → **Pair**.
5. Enter your **iPhone unlock passcode** first (authorizes pairing).
6. When the second prompt appears, type the **6-digit code** Locus shows (also sent as a notification).
7. Done — RPPairing file is saved on-device.

### On iOS 18–26

1. On a computer, download [idevice_pair](https://github.com/jkcoxson/idevice_pair/releases).
2. Plug in your iPhone, unlock, Trust.
3. Generate an **RPPairing** file (not lockdown / SideStore `.mobiledevicepairing`).
4. AirDrop / Share → Open in **Locus**, **Import**, or **Paste from clipboard**.

### On iOS 14–16 (lockdown engine)

iOS 16 and below use the classic lockdownd developer service. Two requirements:

**A. Pairing record** — do one of:

1. **Pair on this iPhone (no computer):** Locus → Settings (or first-run setup) → **Pair on this iPhone**, keep the phone unlocked, tap **Trust** in the popup.
2. **Import from a computer:** install [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) (`pip install pymobiledevice3`), plug in and pair:
   ```
   pymobiledevice3 lockdown pair
   ```
   Then copy `%USERPROFILE%\.pymobiledevice3\pairing_records\<UDID>.plist` (Windows) or `~/.pymobiledevice3/pairing_records/<UDID>.plist` (macOS) to the phone and **Import** it in Locus (or Paste its contents).

**B. Developer Disk Image (once per reboot)** — the location simulation service only exists while the DDI is mounted. From the same computer (phone plugged in):

```
pymobiledevice3 developer ddi mount
```

After every phone reboot, run this once more (~1 minute); no computer needed while spoofing itself.

## 3. LocalDevVPN

Install [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044), connect it (default tunnel IP `10.7.0.1`).

## 4. Teleport

On Wi‑Fi: drop a pin → **Teleport**. Then joystick / routes / GPX work; the session can continue on cellular.

### iOS 16 notes

- The map falls back to the classic (pre-iOS 17) map flavor; pin drag, draw, routes and GPX all work, map style switching is standard-only.
- If teleport fails with "Developer Disk Image not mounted", run `pymobiledevice3 developer ddi mount` from the computer once.

