# EcobeeBar

A native macOS menu bar app for controlling an ecobee thermostat **locally over HomeKit (HAP)**. It doesn't use the ecobee cloud, an API key, Python, or Home Assistant.

The HomeKit Accessory Protocol client is written in Swift on CryptoKit and Network.framework: SRP-6a pair setup, Ed25519/X25519 pair verify, ChaCha20-Poly1305 session framing, Bonjour discovery, and event subscriptions. Pairing files are compatible with [ecobee-local](https://github.com/addition-official/ecobee-local) and aiohomekit in both directions.

## Features

- Menu bar item shows the room temperature, plus a flame or snowflake icon while the system is heating or cooling.
- Popover controls:
  - Setpoint slider and −/+ buttons (whole °F or half °C steps).
  - Separate heat and cool thresholds in Auto mode.
  - Mode (Off/Heat/Cool/Auto), fan (Auto/On), and a power toggle that restores the last mode.
  - Comfort profile (Home/Sleep/Away/Hold) and an Away toggle, on models that expose them. The ecobee3 lite doesn't.
  - Humidity, and remote SmartSensor temperature and occupancy.
- Push updates over HAP events, with a 60 s poll as a safety net. Reconnects with backoff and after the Mac wakes.
- Multiple thermostats, switched from the name in the popover header.

## Requirements

- macOS 14 or later. Builds with the Command Line Tools; Xcode isn't required.
- An ecobee that **is not paired to Apple Home**. A HomeKit accessory belongs to a single home, and only that home can add other controllers. If the thermostat is in Apple Home, reset it first: **Menu → Settings → HomeKit → Reset**. This removes it from Apple Home.

## Build & run

```sh
scripts/bundle.sh          # → build/EcobeeBar.app (release, ad-hoc signed)
open build/EcobeeBar.app
```

On first launch macOS asks for Local Network access. Allow it, otherwise discovery and connections fail.

## Pairing

Click the menu bar item, pick your thermostat, and enter the 8-digit code from **Menu → Settings → HomeKit** on the thermostat. There are two other ways to add one:

- **Import → From ecobee-local** picks up files that `ecobee-pair` wrote to `~/ecobee-local/`.
- **Enter address manually** (`host:port`) works when mDNS doesn't cross your network, for example on separate VLANs.

Credentials are stored in `~/Library/Application Support/EcobeeBar/pairings/` (mode 0600), in aiohomekit's JSON format. They contain long-term keys that grant full control of the thermostat, so treat them like passwords. **Remove…** in the settings menu sends a HAP RemovePairing request so the thermostat can be paired somewhere else.

## hapctl

A CLI that uses the same libraries, for scripting and debugging:

```sh
swift run hapctl scan                       # HomeKit accessories on the LAN
swift run hapctl pair "Main Floor" 12345678
swift run hapctl status
swift run hapctl set-temp 21.5              # °C; also set-heat / set-cool
swift run hapctl set-mode cool              # off | heat | cool | auto
swift run hapctl watch                      # stream push updates
swift run hapctl dump                       # every service/characteristic
swift run hapctl unpair
```

`--dir PATH` points it at a different pairing folder.

## Development

```sh
scripts/test.sh                             # unit tests (SRP, TLV8, framing, HTTP parsing)
uv run --with HAP-python dev/fake_thermostat.py   # simulated ecobee, setup code 123-45-678
```

The fake thermostat exposes the same characteristics as a real ecobee: fan state, ecobee's vendor comfort-profile UUIDs, and a remote sensor. It also drifts the room temperature so you can see HVAC activity and events. When it runs on the same Mac, mDNSResponder may not resolve its hostname, so pair with its address: `hapctl pair <your-ip>:51826 12345678`.

## Layout

```
Sources/HAPKit     HAP client: TLV8, SRP, pairing, encrypted session, HTTP, discovery, pairing store
Sources/EcobeeKit  thermostat mapping (by HomeKit type), typed state, reconnecting client
Sources/EcobeeBar  menu bar app (AppKit status item + SwiftUI popover)
Sources/hapctl     CLI
```
