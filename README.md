# ESP8266 LED Controller with Audio Visualization

## Project Overview

This project implements a wireless LED strip controller using an ESP8266 microcontroller paired with a Flutter mobile application. The system provides real-time control of WS2812B (NeoPixel) LED strips with support for 15 visual effects including advanced audio visualization modes that react to music input. Communication occurs via WebSocket protocol over Wi-Fi with automatic network discovery and seamless transition between access point and station modes.

## Key Features

### ESP8266 Firmware
- WebSocket server implementation for low-latency bidirectional communication
- 15 visual effects including static color, dynamic patterns, and audio-reactive modes
- Automatic Wi-Fi reconnection with credential persistence via EEPROM
- Graceful fallback to access point mode when home network is unavailable
- Power management with configurable current limiting (up to 1500mA)
- Client connection animation for visual feedback
- Factory reset capability via GPIO0 button press during boot
- mDNS service advertisement (`esp-led.local`)

### Flutter Application
- Smart device discovery with multiple strategies:
    - Auto-reconnect to last known IP address
    - mDNS hostname resolution (`esp-led.local`)
    - Subnet scanning with parallel connection testing
    - Manual IP entry fallback
- Comprehensive effect gallery with categorized browsing
- Audio visualization with real-time FFT analysis:
    - 16-band frequency spectrum analysis
    - Logarithmic frequency binning matching human hearing perception
    - Beat detection algorithms with energy differential analysis
    - Platform-specific audio capture handling (Android/iOS limitations documented)
- Wi-Fi configuration workflow for initial ESP setup
- Color picker with brightness control for static mode
- Connection status monitoring with visual feedback

### Audio Visualization Modes
1. **Frequency Spectrum**: Classic EQ bars with bass (red) to treble (blue) mapping
2. **Pulsing Waves**: Dual traveling waves that pulse with music energy
3. **Energy Glow**: Full-strip brightness modulation with beat-triggered flashes
4. **Beat Particles**: Particle system emitting from center on detected beats
5. **Rainbow Bars**: Colorful spectrum bars with peak hold indicators and shimmer effects

## Hardware Requirements

### Core Components
- ESP8266 module (NodeMCU, Wemos D1 Mini, or equivalent)
- WS2812B LED strip (tested with 120 LEDs, configurable)
- 5V power supply rated for LED strip current requirements
- Optional: Momentary push button connected to GPIO0 for factory reset

### Wiring Diagram
```
ESP8266    → WS2812B LED Strip
----------   -----------------
3.3V       → Not connected (LEDs require 5V power)
GND        → GND (power supply and LED strip)
D2 (GPIO4) → DIN (data input)
5V (ext)   → +5V (power supply to LED strip)
```

**Critical Note**: Power the LED strip directly from an external 5V supply rated for the strip's current requirements. Do not power more than 10 LEDs directly from the ESP8266's 5V pin.

## Software Architecture

### ESP8266 Firmware Structure
```
src/
├── Configuration Constants      # LED count, pins, network settings
├── State Management             # WiFi state machine (AP/Connecting/Connected)
├── WebSocket Handler            # Command processing and status broadcasting
├── Effect Engine                # 15 visual effects with dedicated rendering functions
├── Audio Processing             # Bin smoothing, peak hold, beat detection
├── EEPROM Management            # Credential storage with CRC validation
└── Power Management             # Current limiting and thermal protection
```

### Flutter Application Structure
```
lib/
├── Connection Layer             # Smart discovery, WebSocket management
├── Control Interface            # Color picker, brightness slider, mode selection
├── Effects Gallery              # Categorized effect browsing with previews
├── Audio Processing             # FFT analysis, frequency binning, beat detection
├── Setup Workflow               # AP mode instructions, Wi-Fi configuration
└── Platform Integration         # Permissions handling, audio session configuration
```

### Communication Protocol
All commands use binary WebSocket payloads with single-byte opcodes:

| Opcode | Payload Format                     | Description                          |
|--------|------------------------------------|--------------------------------------|
| 0x01   | `[0x01, R, G, B]`                  | Set static RGB color                 |
| 0x02   | `[0x02, mode_id]`                  | Change visual effect mode            |
| 0x03   | `[0x03, brightness]`               | Set brightness (0-255)               |
| 0x04   | `[0x04, bin0..bin15]`              | Audio frequency bins (16 values)     |
| 0xFF   | `[0xFF, ssid_len, pass_len, ...]`  | Wi-Fi reconfiguration (AP mode only) |

Status messages use plain text format:
- `IP:192.168.x.x` - Successfully connected to home network
- `AUTO_CONNECTED:192.168.x.x` - Auto-reconnected on boot
- `AP_MODE` - Device operating in access point mode
- `RECONFIG:SSID` - Wi-Fi credentials accepted

## Setup and Installation

### ESP8266 Firmware Deployment
1. Install Arduino IDE with ESP8266 board support
2. Install required libraries via Library Manager:
    - FastLED
    - WebSocketsServer
    - ESP8266mDNS
3. Configure parameters in `websotcket.ino`:
   ```cpp
   #define NUM_LEDS 120          // Update to match your strip length
   #define MAX_POWER_MA 1500     // Set to match your power supply rating
   #define AP_SSID "ESP_LED"     // Optional: customize AP credentials
   #define AP_PASSWORD "12345678"
   ```
4. Connect ESP8266 via USB and select correct board/port
5. Upload firmware and monitor serial output for IP address

### Flutter Application Setup
1. Install Flutter SDK and required dependencies
2. Add required packages to `pubspec.yaml`:
   ```yaml
   dependencies:
     flutter:
       sdk: flutter
     web_socket_channel: ^2.4.0
     flex_color_picker: ^3.3.0
     network_info_plus: ^5.0.1
     shared_preferences: ^2.2.2
     permission_handler: ^11.3.0
     audio_session: ^0.1.16
     flutter_sound: ^9.3.0
     fft: ^0.4.0
   ```
3. Configure platform-specific permissions:
    - **Android**: Add to `AndroidManifest.xml`:
      ```xml
      <uses-permission android:name="android.permission.RECORD_AUDIO"/>
      <uses-permission android:name="android.permission.INTERNET"/>
      <uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>
      <uses-permission android:name="android.permission.CHANGE_WIFI_STATE"/>
      ```
    - **iOS**: Add to `Info.plist`:
      ```xml
      <key>NSMicrophoneUsageDescription</key>
      <string>Required for audio visualization</string>
      <key>NSLocalNetworkUsageDescription</key>
      <string>Required for device discovery</string>
      ```

### Initial Configuration Workflow
1. Power on ESP8266 with no saved credentials
2. ESP creates access point `ESP_LED` (password: `12345678`)
3. Connect mobile device to ESP access point
4. Open application and navigate to Wi-Fi configuration
5. Enter home network credentials and submit
6. ESP connects to home network and reports IP address
7. Reconnect mobile device to home network
8. Application auto-discovers ESP via mDNS or saved IP

## Usage Guide

### Connection Workflow
1. Launch application - automatic discovery begins immediately
2. Status indicators:
    - Spinning icon: Active discovery in progress
    - Green checkmark: Successfully connected
    - Red warning: Connection issues or AP mode active
3. If auto-discovery fails after 8 seconds:
    - "Show Discovered Devices" button appears to view scan results
    - "Enter IP Manually" option for direct connection
    - "Set Up via ESP Hotspot" for initial configuration

### Effect Control
- **Static Mode**: Use color picker and brightness slider for ambient lighting
- **Dynamic Modes**: Select from quick-access buttons or full effects gallery
- **Audio Modes**:
    1. Tap "Audio" button in mode selector
    2. Grant microphone permission when prompted
    3. Select visualization mode from horizontal selector
    4. Start audio capture (Android: ensure "Audio capture" enabled in system settings)

### Audio Visualization Notes
- **Android**: For true internal audio capture (not microphone):
    1. Settings → Apps → [Your App] → Permissions
    2. Tap menu (⋮) → Advanced permissions
    3. Enable "Audio capture" capability
    4. Restart application
- **iOS Limitation**: Apple restricts internal audio capture. Microphone input only - place device near speakers for best results.

## Technical Implementation Details

### Audio Processing Pipeline (Flutter)
1. **Capture**: 44.1kHz mono PCM audio via Flutter Sound
2. **Buffering**: 1024-sample buffer with Hamming window application
3. **Transformation**: FFT computation yielding 512 frequency bins
4. **Binning**: Logarithmic mapping of 512 FFT bins → 16 perceptual bands:
   ```
   Band 0:   0-100Hz    (sub-bass)
   Band 1: 100-200Hz    (bass)
   ...
   Band 15: 15.2-20.5kHz (presence)
   ```
5. **Perceptual Scaling**: Non-linear curve emphasizing quiet sounds
6. **Smoothing**: Exponential moving average (attack: 50%, decay: 12.5%)
7. **Beat Detection**: Energy differential analysis with 16-sample history buffer
8. **Transmission**: 17-byte payload (opcode + 16 bins) at ~60fps

### ESP8266 Audio Rendering
- Bin smoothing with faster attack than decay for natural response
- Peak hold effect maintaining maximum values for ~300ms
- Beat detection using 8-sample energy history buffer
- Mode-specific rendering optimizations:
    - Spectrum: Frequency-to-hue mapping with gradient bars
    - Wave: Dual traveling waves with energy-modulated width
    - Particles: Physics-based emission on beat detection

### Power Management
- Configurable maximum current limit (`MAX_POWER_MA`)
- Automatic brightness scaling when power threshold approached
- Thermal protection via FastLED's power management API
- Critical safety: Always use external power supply rated for full LED strip current

## Configuration Parameters

### Firmware Configuration (`websotcket.ino`)
| Parameter              | Default     | Description                                  |
|------------------------|-------------|----------------------------------------------|
| `NUM_LEDS`             | 120         | Number of LEDs in strip                      |
| `BRIGHTNESS`           | 255         | Default startup brightness                   |
| `MAX_POWER_MA`         | 1500        | Current limit for power protection           |
| `FRAME_TIME_MS`        | 17          | Target frame interval (~60fps)               |
| `AP_SSID`              | "ESP_LED"   | Access point SSID                            |
| `AP_PASSWORD`          | "12345678"  | Access point password                        |
| `CLIENT_CONNECT_ANIM_DURATION` | 1800 | Client connection animation duration (ms) |

### EEPROM Storage Format
```cpp
struct StoredConfig {
  uint16_t signature;  // 0x4553 validation marker
  char ssid[33];       // Null-terminated SSID
  char password[64];   // Null-terminated password
  uint16_t crc;        // CRC16 validation of credentials
};
```

## Troubleshooting

### Connection Issues
| Symptom                          | Resolution                                                                 |
|----------------------------------|----------------------------------------------------------------------------|
| ESP not found on network         | 1. Check serial monitor for IP address<br>2. Verify power supply stability<br>3. Reset ESP and retry discovery |
| Stuck in AP mode                 | 1. Verify home Wi-Fi credentials<br>2. Ensure ESP within Wi-Fi range<br>3. Factory reset via GPIO0 button |
| mDNS resolution fails            | Use IP address directly or enable mDNS on router                           |
| Frequent disconnections          | 1. Check power supply adequacy<br>2. Reduce `NUM_LEDS` or `BRIGHTNESS`<br>3. Improve Wi-Fi signal strength |

### Audio Visualization Issues
| Platform | Symptom                          | Resolution                                                                 |
|----------|----------------------------------|----------------------------------------------------------------------------|
| Android  | No internal audio capture        | Enable "Audio capture" in system app permissions (Android 10+)             |
| Android  | Audio latency >200ms             | Reduce FFT buffer size in code (trade-off: frequency resolution)           |
| iOS      | Weak audio response              | Place device closer to speakers; microphone is only input source           |
| Both     | Visualizer unresponsive          | Verify WebSocket connection status; restart audio capture                  |

### LED Strip Issues
| Symptom                  | Resolution                                                                 |
|--------------------------|----------------------------------------------------------------------------|
| Flickering LEDs          | 1. Add 1000µF capacitor across power rails<br>2. Verify ground connection between ESP and power supply |
| Color inaccuracies       | Verify LED chipset in FastLED initialization (`WS2812B` vs `SK6812`)       |
| First LED malfunction    | Check data line wiring; add 330Ω resistor between ESP pin and DIN          |
| Power-related resets     | Never power >10 LEDs from ESP's 5V pin; use external supply with common ground |

## Safety Considerations

1. **Electrical Safety**:
    - Use properly rated power supplies with appropriate fusing
    - Ensure all connections are insulated and secure before powering
    - Never exceed power supply current rating

2. **Thermal Management**:
    - LED strips generate significant heat at high brightness
    - Provide adequate ventilation for dense LED installations
    - Consider thermal monitoring for permanent installations

3. **Fire Prevention**:
    - Avoid covering LED strips with flammable materials
    - Implement brightness limits for enclosed installations
    - Use fire-retardant mounting surfaces where required

## Future Enhancements

1. **Protocol Improvements**:
    - Binary protocol optimization for reduced bandwidth
    - Command queuing with priority system
    - Firmware update over WebSocket (FUOTA)

2. **Audio Processing**:
    - Machine learning-based beat detection
    - Genre-specific visualization profiles
    - Multi-band compression for dynamic range optimization

3. **User Experience**:
    - Preset saving and synchronization across devices
    - Scheduled effect transitions (time/day-based)
    - Integration with music streaming services for metadata-aware visuals

4. **Hardware Expansion**:
    - Support for multiple ESP8266 units in synchronized operation
    - Integration with ambient light sensors for automatic brightness adjustment
    - IR remote control support as fallback interface

## License

This project is provided as open-source reference implementation. Hardware designs and firmware follow MIT License terms. The Flutter application implementation is provided for educational purposes with dependencies subject to their respective licenses.

---

*Document Version: 1.0*  
*Last Updated: February 2026*  
*Compatible with ESP8266 Arduino Core 3.1+ and Flutter 3.19+*