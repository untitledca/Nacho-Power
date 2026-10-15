# Direct EcoFlow USB monitoring

EcoFlow Cat’s USB mode reads the power station directly through native macOS USB and serial APIs. It does not require PowerManager, NUT, Homebrew, Python, a cloud account, internet access, or installed third-party drivers. Connect one supported EcoFlow by USB and quit PowerManager before opening EcoFlow Cat.

## Read-only implementation

`DirectEcoFlowMonitor` uses Apple's `IOUSBHostDevice` with the default options. It never requests device capture/seize, resets the device, selects a USB configuration, changes a power setting, sends an output report, or writes a HID feature. The USB control requests are only `GET_DESCRIPTOR` and `GET_REPORT`.

The monitor matches USB vendor/product `3746:ffff`, discovers the HID interface from its configuration descriptor, then parses the device's actual HID report descriptor. It locates the Battery System `RemainingCapacity` and `ACPresent` Feature fields by their standard usage codes rather than assuming a firmware-specific report ID or bit position. Battery values outside 0–100 and invalid AC flags are rejected. Communication-loss flags, when exposed, are also checked.

The USB CDC modem belonging to that same EcoFlow is discovered through IOKit's USB-parent hierarchy. The monitor configures the local serial connection for 115200 baud/raw reads, restores its original terminal settings on close, and sends only the read-only telemetry query documented by [r3pcomms](https://github.com/greyltc/r3pcomms). The query requests measurements, never device controls or serial identification. CRC, packet size, response opcode, sequence, and segment lengths are validated. The entire serial exchange has a 1.5-second monotonic deadline. Only input-power fields are retained; serial/identifier fields are ignored.

Native `IOHIDManager` enumeration returned no EcoFlow devices on this Mac. Direct `IOUSBHostDevice` control reads work without a permission helper, privileged process, or device capture. The existing vendor PowerManagerService remains installed, but EcoFlow Cat neither connects to it nor uses any of its files, ports, APIs or processes. Apple's `ioupsd` is untouched.

## Input-power interpretation

The protocol can report both combined input and a dedicated AC-input measurement. The physical telemetry model keeps these separate; missing AC-only watts remain unknown.

The DELTA 3 Plus firmware previously tested here returns combined input but omits the dedicated AC-input segment. The current reminder uses the verified USB AC-present flag directly:

- AC absent: `ACPresent` starts the intro/loop reminder, subject to the selected battery threshold, independently of solar input.
- AC present: the cat stops immediately with a short pop, including when input is 0 W because the battery is full.
- Unknown/disconnected data: no unplug event or AC-restored event is inferred. A visible reminder expires after the telemetry grace period.

The Dock uses the same AC flag: green for connected, red for disconnected, and an unknown state when a reliable reading is unavailable. Input wattage remains informational and is not required to recognize a fresh, explicit AC flag.

The app labels the numeric measurement **Input power**. Solar or another source can contribute to that combined value while AC is connected. It does not claim to measure exclusively AC watts when the station does not expose that field.

## Prior USB hardware verification

The USB implementation was previously physically verified on DELTA 3 Plus with AC unplugged and plugged in while PowerManager's GUI and NUT processes were closed. Consecutive direct snapshots correctly reported AC absent with zero input, then AC present with positive input. Dedicated AC segment 9 was absent; combined input was reported through segment 8. No power settings or hardware outputs were changed.

The native direct monitor and parser tests compile for both Apple silicon and Intel with the macOS 14 deployment target. Actual Intel execution and other EcoFlow model/firmware combinations have not been tested. The current USB support is intended for EcoFlow models exposing the HID/CDC UPS interface, including the DELTA 3 Plus tested here. A real AC plug transition should be checked before treating another model or firmware as verified.

Run checks with:

```sh
xcrun swiftc -parse-as-library -swift-version 5 Sources/TelemetryModels.swift Sources/DirectEcoFlowMonitor.swift Tests/DirectEcoFlowChecks.swift -o /tmp/ecoflow-direct-checks
/tmp/ecoflow-direct-checks --live
```

Checks cover HID descriptor/bit parsing, wire-report IDs, known battery and AC flag reports, request framing, CRC, response sequence and opcode, truncation, missing AC fields, solar-versus-AC values, non-finite values, and absurd finite watts. The native USB/serial code rejects power readings over 100,000 W so malformed floats cannot overflow UI integer formatting.

## Protocol references and notices

- [Apple IOUSBHostDevice](https://developer.apple.com/documentation/iousbhost/iousbhostdevice) and the installed Apple SDK headers define the native USB request APIs.
- [r3pcomms](https://github.com/greyltc/r3pcomms), by M. Greyson Christoforo, documents USB HID/CDC telemetry framing and is MIT licensed. Its notice is included in `Resources/ThirdPartyNotices.txt`.
- The official [NUT EcoFlow support discussion](https://github.com/networkupstools/nut/issues/2735) provides DELTA 3 Plus HID mapping verification. The [NUT EcoFlow driver](https://github.com/networkupstools/nut/blob/master/drivers/ecoflow-hid.c) and [CDC documentation](https://networkupstools.org/docs/man/usbhid-ups.html) corroborate the measurements. No NUT binaries, libraries or source code are included in EcoFlow Cat.
