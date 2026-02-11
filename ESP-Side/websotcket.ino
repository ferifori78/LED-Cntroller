#include <ESP8266WiFi.h>
#include <WebSocketsServer.h>
#include <FastLED.h>
#include <ESP8266mDNS.h>
#include <EEPROM.h>
// ===== CONFIGURATION =====
#define LED_PIN D2
#define NUM_LEDS 120
#define BRIGHTNESS 255
#define MAX_POWER_MA 1500
#define FRAME_TIME_MS 17
#define AUDIO_MODE_FRAME_TIME_MS 16
#define AP_SSID "ESP_LED"
#define AP_PASSWORD "esp_led_2026" 
#define WS_PORT 80
#define WIFI_TIMEOUT 15000
#define AP_GRACE_PERIOD 3000
#define EEPROM_SIZE 512
#define EEPROM_SIG 0x4553
#define CLIENT_CONNECT_ANIM_DURATION 1800
#define NUM_AUDIO_BINS 16  // Must match Flutter side

// ===== MODES (Extended with audio visualizers) =====
enum {
  MODE_STATIC,
  MODE_RAINBOW,
  MODE_FIRE,
  MODE_PALETTE,
  MODE_CYLON,
  MODE_PACIFICA,
  MODE_PRIDE,
  MODE_PLASMA,
  MODE_AURORA,
  MODE_MATRIX,
  MODE_AUDIO_SPECTRUM,    // Frequency bars (bass=red → treble=blue)
  MODE_AUDIO_WAVE,        // Smooth wave pulsing with energy
  MODE_AUDIO_ENERGY,      // Overall energy glow with beat detection
  MODE_AUDIO_PARTICLES,   // Particles explode on beats
  MODE_AUDIO_RAINBOW_BARS // Colorful spectrum with gradient bars
};

enum { STATE_AP_MODE, STATE_CONNECTING, STATE_CONNECTED, STATE_WAITING, STATE_WIFI_CONFIG };

// ===== GLOBALS =====
CRGB leds[NUM_LEDS];
WebSocketsServer webSocket(WS_PORT);
uint8_t wifiState = STATE_AP_MODE;
uint8_t mode = MODE_STATIC;
uint8_t paletteIndex = 0;
uint8_t currentBrightness = 255;
uint32_t lastFrame = 0;
uint32_t stateTimer = 0;
uint32_t apGraceTimer = 0;
uint32_t cylonTimer = 0;
bool pendingApShutdown = false;
char homeSSID[33] = "";
char homePassword[64] = "";
bool autoReconnected = false;
bool awaitingFirstCommand = false;

#define MODE_PRE_RENDERED 255  // Special transient mode
bool isPreRenderedMode = false;
uint8_t savedMode = MODE_STATIC;  // For mode restoration
uint32_t lastPreRenderedFrame = 0;
const uint32_t PRE_RENDERED_TIMEOUT_MS = 2000;  // Revert after silence

// Client connection animation state
uint32_t clientConnectAnimStart = 0;
bool isClientConnectAnimActive = false;
CRGB ledsBeforeAnim[NUM_LEDS];

// Fire effect buffer
#define COOLING 55
#define SPARKING 120
uint8_t heat[NUM_LEDS];

// Cylon scanner state
int8_t cylonPosition = 0;
int8_t cylonDirection = 1;
uint8_t cylonHue = 0;

// Color palette globals
CRGBPalette16 currentPalette = RainbowColors_p;
TBlendType currentBlending = LINEARBLEND;

// Custom effect state variables
uint16_t plasmaPseudoTime = 0;
uint16_t auroraTime = 0;
uint8_t matrixRaindrops[NUM_LEDS];

// ===== AUDIO VISUALIZATION GLOBALS =====
uint8_t audioBins[NUM_AUDIO_BINS] = {0};  // 0-255 values from phone
uint8_t smoothedBins[NUM_AUDIO_BINS] = {0};
uint32_t lastAudioUpdate = 0;
const uint32_t AUDIO_TIMEOUT_MS = 1000;  // Reset bins after silence
uint8_t beatHistory[8] = {0};
uint8_t beatIndex = 0;
uint8_t lastEnergy = 0;
uint8_t peakHold[NUM_AUDIO_BINS] = {0};
uint8_t peakDecayTimer[NUM_AUDIO_BINS] = {0};

// Particles for MODE_AUDIO_PARTICLES
struct Particle {
  int16_t position;
  int8_t velocity;
  uint8_t hue;
  uint8_t brightness;
  bool active;
};
#define MAX_PARTICLES 12
Particle particles[MAX_PARTICLES];
uint8_t nextParticle = 0;
volatile bool audioProcessing = false;  // Guard against WebSocket packet pileup

// ===== EEPROM STRUCTURE =====
struct StoredConfig {
  uint16_t signature;
  char ssid[33];
  char password[64];
  uint16_t crc;
};

// ===== UTILITY FUNCTIONS =====
uint8_t triangleWave8(uint32_t time, uint16_t period) {
  uint16_t t = (time % period) * 255 / period;
  return (t < 128) ? (t * 2) : (510 - t * 2);
}

// Prevent watchdog reset during heavy processing
void safeYield() {
  ::yield();
  delay(2);  // Tiny delay lets WiFi stack process packets
}

void sendStatus(const String& msg) {
  Serial.print("[WS] ");
  Serial.println(msg);
  webSocket.broadcastTXT(msg.c_str());
  delay(5);
}

// Smooth audio bins with exponential moving average
void smoothAudioBins() {
  for (int i = 0; i < NUM_AUDIO_BINS; i++) {
    // Instant attack — no smoothing on rise
    if (audioBins[i] > smoothedBins[i]) {
      smoothedBins[i] = audioBins[i];
    } else {
      // Fast decay: drop ~50% per frame for real-time feel
      smoothedBins[i] = smoothedBins[i] - ((smoothedBins[i] - audioBins[i]) >> 1);
    }

    // Peak hold
    if (audioBins[i] > peakHold[i]) {
      peakHold[i] = audioBins[i];
      peakDecayTimer[i] = 4;  // Shorter hold for snappier peaks
    } else if (peakDecayTimer[i] > 0 && --peakDecayTimer[i] == 0) {
      if (peakHold[i] > 20) peakHold[i] -= 20;
      else peakHold[i] = 0;
    }
  }
}

// Beat detection using energy differential
bool detectBeat() {
  uint8_t energy = 0;
  for (int i = 0; i < NUM_AUDIO_BINS; i++) {
    energy += smoothedBins[i];
  }
  energy = energy / NUM_AUDIO_BINS;
  
  // Store in history buffer
  beatHistory[beatIndex++] = energy;
  if (beatIndex >= 8) beatIndex = 0;
  
  // Calculate average of past 7 samples
  uint16_t avg = 0;
  for (int i = 0; i < 7; i++) {
    avg += beatHistory[(beatIndex + i) % 8];
  }
  avg /= 7;
  
  // Beat if current energy is notably higher than recent average
  bool isBeat = (energy > avg + 20) && (energy > 45) && (energy > lastEnergy + 10);
  lastEnergy = energy;
  return isBeat;
}

// ===== CLIENT CONNECTION ANIMATION =====
void startClientConnectAnimation() {
  memcpy(ledsBeforeAnim, leds, sizeof(CRGB) * NUM_LEDS);
  clientConnectAnimStart = millis();
  isClientConnectAnimActive = true;
  Serial.println("[ANIM] Client connection animation started");
}

void animClientConnected() {
  uint32_t elapsed = millis() - clientConnectAnimStart;
  if (elapsed >= CLIENT_CONNECT_ANIM_DURATION) {
    memcpy(leds, ledsBeforeAnim, sizeof(CRGB) * NUM_LEDS);
    isClientConnectAnimActive = false;
    return;
  }
  float progress = (float)elapsed / CLIENT_CONNECT_ANIM_DURATION;
  float pulsePos = progress * (NUM_LEDS / 2 + 20);
  for (int i = 0; i < NUM_LEDS; i++) {
    int distFromCenter = abs(i - (NUM_LEDS / 2));
    float distToPulse = abs(pulsePos - distFromCenter);
    float brightnessFactor;
    if (distToPulse < 8) {
      brightnessFactor = 1.0 - (distToPulse / 8.0);
      brightnessFactor = brightnessFactor * brightnessFactor * brightnessFactor;
    } else {
      brightnessFactor = 0.0;
    }
    uint8_t hue = 180 - (uint8_t)(progress * 40);
    uint8_t saturation = 200 - (uint8_t)(progress * 100);
    uint8_t value = 255;
    CRGB animColor = CHSV(hue, saturation, value);
    CRGB bgColor = ledsBeforeAnim[i];
    uint8_t blendAmount = (uint8_t)(brightnessFactor * 255 * (1.0 - progress * 0.4));
    leds[i] = blend(animColor, bgColor, blendAmount);
  }
}

// ===== EEPROM HELPER FUNCTIONS =====
uint16_t crc16(const uint8_t* data, size_t len) {
  uint16_t crc = 0xFFFF;
  for (size_t i = 0; i < len; i++) {
    crc ^= data[i];
    for (uint8_t j = 0; j < 8; j++) {
      if (crc & 0x0001) {
        crc >>= 1;
        crc ^= 0xA001;
      } else {
        crc >>= 1;
      }
    }
  }
  return crc;
}

bool loadCredentials() {
  EEPROM.begin(EEPROM_SIZE);
  StoredConfig config;
  EEPROM.get(0, config);
  if (config.signature != EEPROM_SIG) {
    EEPROM.end();
    return false;
  }
  uint16_t computedCrc = crc16((uint8_t*)&config.ssid, sizeof(config.ssid) + sizeof(config.password));
  if (computedCrc != config.crc) {
    EEPROM.end();
    return false;
  }
  strncpy(homeSSID, config.ssid, 32);
  homeSSID[32] = 0;
  strncpy(homePassword, config.password, 63);
  homePassword[63] = 0;
  EEPROM.end();
  return true;
}

void saveCredentials(const char* ssid, const char* password) {
  StoredConfig config;
  config.signature = EEPROM_SIG;
  strncpy(config.ssid, ssid, 32);
  config.ssid[32] = 0;
  strncpy(config.password, password, 63);
  config.password[63] = 0;
  config.crc = crc16((uint8_t*)&config.ssid, sizeof(config.ssid) + sizeof(config.password));
  EEPROM.begin(EEPROM_SIZE);
  EEPROM.put(0, config);
  EEPROM.commit();
  EEPROM.end();
}

void clearCredentials() {
  EEPROM.begin(EEPROM_SIZE);
  for (int i = 0; i < EEPROM_SIZE; i++) EEPROM.write(i, 0);
  EEPROM.commit();
  EEPROM.end();
  homeSSID[0] = 0;
  homePassword[0] = 0;
}

// ===== EXISTING EFFECTS (unchanged) =====
void effectFire() {
  for (int i = 0; i < NUM_LEDS; i++) {
    heat[i] = qsub8(heat[i], random8(0, ((COOLING * 10) / NUM_LEDS) + 2));
  }
  for (int k = NUM_LEDS - 1; k >= 2; k--) {
    heat[k] = (heat[k - 1] + heat[k - 2] + heat[k - 2]) / 3;
  }
  if (random8() < SPARKING) {
    int y = random8(7);
    heat[y] = qadd8(heat[y], random8(160, 255));
  }
  for (int j = 0; j < NUM_LEDS; j++) {
    leds[j] = HeatColor(heat[j]);
  }
}

void effectPalette() {
  uint8_t secondHand = (millis() / 10000) % 8;
  static uint8_t lastSecond = 99;
  if (lastSecond != secondHand) {
    lastSecond = secondHand;
    switch (secondHand) {
      case 0: currentPalette = RainbowColors_p; currentBlending = LINEARBLEND; break;
      case 1: currentPalette = RainbowStripeColors_p; currentBlending = LINEARBLEND; break;
      case 2: currentPalette = OceanColors_p; currentBlending = LINEARBLEND; break;
      case 3: currentPalette = CloudColors_p; currentBlending = LINEARBLEND; break;
      case 4: currentPalette = ForestColors_p; currentBlending = LINEARBLEND; break;
      case 5: currentPalette = PartyColors_p; currentBlending = LINEARBLEND; break;
      case 6:
        currentPalette = CRGBPalette16(
          CHSV(HUE_GREEN, 255, 255), CHSV(HUE_GREEN, 255, 255), CRGB::Black, CRGB::Black,
          CHSV(HUE_PURPLE, 255, 255), CHSV(HUE_PURPLE, 255, 255), CRGB::Black, CRGB::Black,
          CHSV(HUE_GREEN, 255, 255), CHSV(HUE_GREEN, 255, 255), CRGB::Black, CRGB::Black,
          CHSV(HUE_PURPLE, 255, 255), CHSV(HUE_PURPLE, 255, 255), CRGB::Black, CRGB::Black);
        currentBlending = LINEARBLEND;
        break;
      case 7:
        currentPalette = CRGBPalette16(
          CRGB::Red, CRGB::Red, CRGB::Red, CRGB::Red,
          CRGB::White, CRGB::White, CRGB::White, CRGB::White,
          CRGB::Blue, CRGB::Blue, CRGB::Blue, CRGB::Blue,
          CRGB::White, CRGB::White, CRGB::White, CRGB::White);
        currentBlending = LINEARBLEND;
        break;
    }
  }
  static uint8_t startIndex = 0;
  startIndex = startIndex + 1;
  for (int i = 0; i < NUM_LEDS; i++) {
    leds[i] = ColorFromPalette(currentPalette, startIndex + (i * 2), 255, currentBlending);
  }
}

void effectCylon() {
  for (int i = 0; i < NUM_LEDS; i++) {
    leds[i].nscale8(220);
  }
  if (millis() - cylonTimer > 30) {
    cylonTimer = millis();
    cylonPosition += cylonDirection;
    if (cylonPosition >= NUM_LEDS - 1 || cylonPosition <= 0) {
      cylonDirection = -cylonDirection;
      cylonPosition += cylonDirection * 2;
      cylonHue += 40;
    }
    leds[cylonPosition] = CHSV(cylonHue, 255, 255);
    if (cylonPosition + cylonDirection >= 0 && cylonPosition + cylonDirection < NUM_LEDS) {
      leds[cylonPosition + cylonDirection] = CHSV(cylonHue, 255, 180);
    }
    if (cylonPosition + cylonDirection * 2 >= 0 && cylonPosition + cylonDirection * 2 < NUM_LEDS) {
      leds[cylonPosition + cylonDirection * 2] = CHSV(cylonHue, 255, 100);
    }
  }
}

void effectRainbow() {
  for (int i = 0; i < NUM_LEDS; i++) {
    leds[i] = CHSV(paletteIndex + (i * 256 / NUM_LEDS), 255, 255);
  }
  paletteIndex += 2;
}

// ===== NEW CUSTOM EFFECTS (unchanged from original) =====
void pacifica_one_layer(CRGBPalette16& p, uint16_t cistart, uint16_t wavescale, uint8_t bri, uint16_t ioff) {
  uint16_t ci = cistart;
  uint16_t waveangle = ioff;
  uint16_t wavescale_half = (wavescale / 2) + 20;
  for (uint16_t i = 0; i < NUM_LEDS; i++) {
    waveangle += 250;
    uint16_t s16 = sin16(waveangle) + 32768;
    uint16_t cs = scale16(s16, wavescale_half) + wavescale_half;
    ci += cs;
    uint16_t sindex16 = sin16(ci) + 32768;
    uint8_t sindex8 = scale16(sindex16, 240);
    CRGB c = ColorFromPalette(p, sindex8, bri, LINEARBLEND);
    leds[i] += c;
  }
}

void effectPacifica() {
  static uint16_t sCIStart1, sCIStart2, sCIStart3, sCIStart4;
  static uint32_t sLastms = 0;
  uint32_t ms = millis();
  uint32_t deltams = ms - sLastms;
  sLastms = ms;
  uint16_t speedfactor1 = beatsin16(3, 179, 269);
  uint16_t speedfactor2 = beatsin16(4, 179, 269);
  uint32_t deltams1 = (deltams * speedfactor1) / 256;
  uint32_t deltams2 = (deltams * speedfactor2) / 256;
  uint32_t deltams21 = (deltams1 + deltams2) / 2;
  sCIStart1 += (deltams1 * beatsin88(1011, 10, 13));
  sCIStart2 -= (deltams21 * beatsin88(777, 8, 11));
  sCIStart3 -= (deltams1 * beatsin88(501, 5, 7));
  sCIStart4 -= (deltams2 * beatsin88(257, 4, 6));
  
  CRGBPalette16 pacifica_palette_1 = { 0x000507, 0x000409, 0x00030B, 0x00030D, 0x000210, 0x000212, 0x000114, 0x000117,
    0x000019, 0x00001C, 0x000026, 0x000031, 0x00003B, 0x000046, 0x14554B, 0x28AA50 };
  CRGBPalette16 pacifica_palette_2 = { 0x000507, 0x000409, 0x00030B, 0x00030D, 0x000210, 0x000212, 0x000114, 0x000117,
    0x000019, 0x00001C, 0x000026, 0x000031, 0x00003B, 0x000046, 0x0C5F52, 0x19BE5F };
  CRGBPalette16 pacifica_palette_3 = { 0x000208, 0x00030E, 0x000514, 0x00061A, 0x000820, 0x000927, 0x000B2D, 0x000C33,
    0x000E39, 0x001040, 0x001450, 0x001860, 0x001C70, 0x002080, 0x1040BF, 0x2060FF };
  
  fill_solid(leds, NUM_LEDS, CRGB(2, 6, 10));
  pacifica_one_layer(pacifica_palette_1, sCIStart1, beatsin16(3, 11 * 256, 14 * 256), beatsin8(10, 70, 130), 0 - beat16(301));
  pacifica_one_layer(pacifica_palette_2, sCIStart2, beatsin16(4, 6 * 256, 9 * 256), beatsin8(17, 40, 80), beat16(401));
  pacifica_one_layer(pacifica_palette_3, sCIStart3, 6 * 256, beatsin8(9, 10, 38), 0 - beat16(503));
  pacifica_one_layer(pacifica_palette_3, sCIStart4, 5 * 256, beatsin8(8, 10, 28), beat16(601));
  
  // Whitecaps
  uint8_t basethreshold = beatsin8(9, 55, 65);
  uint8_t wave = beat8(7);
  for (uint16_t i = 0; i < NUM_LEDS; i++) {
    uint8_t threshold = scale8(sin8(wave), 20) + basethreshold;
    wave += 7;
    uint8_t l = leds[i].getAverageLight();
    if (l > threshold) {
      uint8_t overage = l - threshold;
      uint8_t overage2 = qadd8(overage, overage);
      leds[i] += CRGB(overage, overage2, qadd8(overage2, overage2));
    }
  }
}

void effectPride() {
  static uint16_t sPseudotime = 0;
  static uint16_t sLastMillis = 0;
  static uint16_t sHue16 = 0;
  uint8_t sat8 = beatsin88(87, 220, 250);
  uint8_t brightdepth = beatsin88(341, 96, 224);
  uint16_t brightnessthetainc16 = beatsin88(203, (25 * 256), (40 * 256));
  uint8_t msmultiplier = beatsin88(147, 23, 60);
  uint16_t hue16 = sHue16;
  uint16_t hueinc16 = beatsin88(113, 1, 3000);
  uint16_t ms = millis();
  uint16_t deltams = ms - sLastMillis;
  sLastMillis = ms;
  sPseudotime += deltams * msmultiplier;
  sHue16 += deltams * beatsin88(400, 5, 9);
  uint16_t brightnesstheta16 = sPseudotime;
  for (uint16_t i = 0; i < NUM_LEDS; i++) {
    hue16 += hueinc16;
    uint8_t hue8 = hue16 / 256;
    brightnesstheta16 += brightnessthetainc16;
    uint16_t b16 = sin16(brightnesstheta16) + 32768;
    uint16_t bri16 = (uint32_t)((uint32_t)b16 * (uint32_t)b16) / 65536;
    uint8_t bri8 = (uint32_t)(((uint32_t)bri16) * brightdepth) / 65536;
    bri8 += (255 - brightdepth);
    CRGB newcolor = CHSV(hue8, sat8, bri8);
    uint16_t pixelnumber = i;
    pixelnumber = (NUM_LEDS - 1) - pixelnumber;
    nblend(leds[pixelnumber], newcolor, 64);
  }
}

void effectPlasma() {
  plasmaPseudoTime += 1;
  for (int i = 0; i < NUM_LEDS; i++) {
    int16_t wave1 = sin16(plasmaPseudoTime * 13 + i * 400);
    int16_t wave2 = sin16(plasmaPseudoTime * 17 - i * 300);
    int16_t wave3 = sin16(plasmaPseudoTime * 11 + i * 250);
    int32_t combined = wave1 + wave2 + wave3;
    uint8_t hue = (combined >> 8) + 128;
    uint8_t brightness = beatsin8(7, 128, 255);
    leds[i] = CHSV(hue, 240, brightness);
  }
}

void effectAurora() {
  auroraTime++;
  for (int i = 0; i < NUM_LEDS; i++) {
    uint16_t angle = (auroraTime * 3) + (i * 20);
    int16_t wave = sin16(angle);
    uint16_t shimmerAngle = (auroraTime * 7) - (i * 15);
    int16_t shimmer = sin16(shimmerAngle);
    uint8_t baseHue;
    if (wave > 16384) baseHue = 96;
    else if (wave > 0) baseHue = 128;
    else if (wave > -16384) baseHue = 160;
    else baseHue = 192;
    uint8_t hue = baseHue + (shimmer >> 10);
    uint8_t depth = abs(wave) >> 8;
    uint8_t brightness = 255 - depth;
    uint8_t sat = beatsin8(5, 180, 255);
    leds[i] = CHSV(hue, sat, brightness);
  }
  if (random8() < 30) {
    int pos = random16(NUM_LEDS);
    leds[pos] = CRGB::White;
  }
}

void effectMatrix() {
  for (int i = 0; i < NUM_LEDS; i++) {
    leds[i].nscale8(240);
  }
  for (int i = 0; i < NUM_LEDS; i++) {
    if (matrixRaindrops[i] > 0) {
      matrixRaindrops[i]--;
      uint8_t brightness = matrixRaindrops[i];
      leds[i] = CHSV(96, 255, brightness);
      if (matrixRaindrops[i] > 200) {
        leds[i] = CRGB::White;
      }
    }
  }
  if (random8() < 40) {
    int pos = random16(NUM_LEDS);
    if (matrixRaindrops[pos] == 0) {
      matrixRaindrops[pos] = 255;
    }
  }
}

// ===== AUDIO VISUALIZATION EFFECTS =====
void effectAudioSpectrum() {
  fill_solid(leds, NUM_LEDS, CRGB(0, 3, 12));
  
  int half = NUM_LEDS / 2;
  int ledsPerBin = (half + NUM_AUDIO_BINS - 1) / NUM_AUDIO_BINS;
  
  for (int bin = 0; bin < NUM_AUDIO_BINS; bin++) {
    int rawHeight = smoothedBins[bin];
    int height = map(rawHeight, 0, 255, 0, (ledsPerBin * 14) / 10);
    height = constrain(height, 0, ledsPerBin);
    
    // Color: bass(red) → mid(green) → treble(blue)
    uint8_t hue = map(bin, 0, NUM_AUDIO_BINS - 1, 0, 170);
    hue = constrain(hue, 0, 255);
    
    // Starting position: bin 0 starts at center, bin 15 at edges
    int binStart = bin * ledsPerBin;
    
    for (int i = 0; i < height; i++) {
      uint8_t brightness = (height > 1) ? map(i, 0, height - 1, 100, 255) : 200;
      
      // Mirror RIGHT (center → end)
      int posR = half + binStart + i;
      if (posR < NUM_LEDS) leds[posR] = CHSV(hue, 255, brightness);
      
      // Mirror LEFT (center → start)
      int posL = half - 1 - binStart - i;
      if (posL >= 0) leds[posL] = CHSV(hue, 255, brightness);
      
      if (i % 15 == 0) yield();
    }
    
    // Peak hold on both sides
    if (peakHold[bin] > 30) {
      int peakOffset = binStart + height;
      int peakR = half + peakOffset;
      int peakL = half - 1 - peakOffset;
      if (peakR < NUM_LEDS) leds[peakR] = CHSV(hue, 200, 255);
      if (peakL >= 0) leds[peakL] = CHSV(hue, 200, 255);
    }
    
    yield();
  }
} 

void effectAudioWave() {
  // Deep space background
  fill_solid(leds, NUM_LEDS, CRGB(2, 0, 15));
  
  // Calculate overall energy for wave intensity
  uint16_t totalEnergy = 0;
  for (int i = 0; i < NUM_AUDIO_BINS; i++) {
    totalEnergy += smoothedBins[i];
  }
  uint8_t energy = totalEnergy / NUM_AUDIO_BINS;
  
  // Timeout handling - fade out after silence
  if (millis() - lastAudioUpdate > AUDIO_TIMEOUT_MS) {
    if (energy > 5) energy -= 5;
    else energy = 0;
  }
  
  // Beat detection for pulse enhancement
  bool isBeat = detectBeat();
  uint8_t waveWidth = 12 + (energy >> 3);
  if (isBeat) waveWidth = min(255, waveWidth + 8);
  
  // Create dual traveling waves (left and right)
  int pos1 = (millis() >> 3) % NUM_LEDS;
  int pos2 = (NUM_LEDS - 1) - ((millis() >> 3) % NUM_LEDS);
  
  // Draw wave 1
  for (int i = 0; i < NUM_LEDS; i++) {
    int dist = abs(i - pos1);
    if (dist < waveWidth) {
      uint8_t brightness = 255 - (dist * 255 / waveWidth);
      brightness = (brightness * energy) >> 8;
      if (isBeat) brightness = min(255, brightness + 80);
      
      // FIXED: Use Arduino's map() for color mapping
      uint8_t hue = map(energy, 0, 255, 160, 0);
      hue = constrain(hue, 0, 255);
      
      uint8_t sat = 255 - (dist * 150 / waveWidth);
      leds[i] += CHSV(hue, sat, brightness >> 1);
    }
    if (i % 20 == 0) yield();
  }
  
  // Draw wave 2 (opposite direction, complementary color)
  for (int i = 0; i < NUM_LEDS; i++) {
    int dist = abs(i - pos2);
    if (dist < (waveWidth - 3)) {  // Slightly narrower
      uint8_t brightness = 200 - (dist * 200 / waveWidth);
      brightness = (brightness * energy) >> 9;
      
      // FIXED: Use Arduino's map() for color mapping
      uint8_t hue = map(energy, 0, 255, 96, 40);
      hue = constrain(hue, 0, 255);
      
      uint8_t sat = 220 - (dist * 120 / waveWidth);
      leds[i] += CHSV(hue, sat, brightness >> 1);
    }
    if (i % 20 == 0) yield();
  }
  yield();  // Prevent watchdog reset
}

void effectAudioEnergy() {
  // Calculate overall energy with smoothing
  uint16_t totalEnergy = 0;
  for (int i = 0; i < NUM_AUDIO_BINS; i++) {
    totalEnergy += smoothedBins[i];
  }
  uint8_t energy = totalEnergy / NUM_AUDIO_BINS;
  
  // Timeout handling - fade out after silence
  if (millis() - lastAudioUpdate > AUDIO_TIMEOUT_MS) {
    if (energy > 5) energy -= 5;
    else energy = 0;
  }
  
  // Beat detection for dramatic effects
  bool isBeat = detectBeat();
  
  // FIXED: Use Arduino's map() for color mapping
  uint8_t hue = map(energy, 0, 255, 96, 0);
  hue = constrain(hue, 0, 255);
  
  uint8_t saturation = 255;
  uint8_t brightness = 40 + (energy >> 1);
  if (isBeat) {
    brightness = 255;
    saturation = 255;
    hue = 0;  // Flash red on beat
  }
  
  // Pulsing background
  fill_solid(leds, NUM_LEDS, CHSV(hue, saturation, brightness));
  
  // Beat sparks - white flashes radiating from center
  if (isBeat) {
    int center = NUM_LEDS / 2;
    for (int offset = 0; offset < 15; offset++) {
      if (center - offset >= 0) leds[center - offset] = CRGB::White;
      if (center + offset < NUM_LEDS) leds[center + offset] = CRGB::White;
    }
  }
  
  // Subtle edge glow for non-beat moments
  if (!isBeat && energy > 30) {
    uint8_t edgeBrightness = energy >> 2;
    for (int i = 0; i < min(8, NUM_LEDS); i++) {
      leds[i] += CHSV(hue, 150, edgeBrightness);
      leds[NUM_LEDS - 1 - i] += CHSV(hue, 150, edgeBrightness);
    }
  }
  yield();  // Prevent watchdog reset
}

void effectAudioParticles() {
  /* ===== Calculate overall audio energy ===== */
  uint16_t totalEnergy = 0;
  for (int i = 0; i < NUM_AUDIO_BINS; i++) {
    totalEnergy += smoothedBins[i];
  }
  uint8_t energy = totalEnergy / NUM_AUDIO_BINS;
  
  // Fade energy after silence
  if (millis() - lastAudioUpdate > AUDIO_TIMEOUT_MS) {
    if (energy > 5) energy -= 5;
    else energy = 0;
  }
  
  /* ===== Background ===== */
  for (int i = 0; i < NUM_LEDS; i++) {
    uint8_t bg = 4 + (i * 4 / NUM_LEDS);
    leds[i] = CRGB(bg, bg >> 2, bg >> 1);
  }
  
  /* ===== Beat detection ===== */
  bool isBeat = detectBeat();
  
  /* ===== Spawn particles on beat ===== */
  if (isBeat && energy > 60) {
    // FIXED: Use Arduino's map() instead of map8()
    uint8_t spawnCount = map(energy, 60, 255, 2, 6);
    spawnCount = constrain(spawnCount, 2, 6);
    
    for (uint8_t p = 0; p < spawnCount; p++) {
      if (nextParticle >= MAX_PARTICLES) nextParticle = 0;
      
      particles[nextParticle].position   = NUM_LEDS / 2;
      particles[nextParticle].velocity   = random8(3, 8) * (random8() & 1 ? 1 : -1);
      particles[nextParticle].hue        = random8();
      particles[nextParticle].brightness = 200 + (energy >> 1);
      particles[nextParticle].active     = true;
      
      nextParticle++;
    }
  }
  
  /* ===== Update & render particles ===== */
  for (int i = 0; i < MAX_PARTICLES; i++) {
    if (!particles[i].active) continue;
    
    particles[i].position   += particles[i].velocity;
    particles[i].brightness  = qsub8(particles[i].brightness, 10);
    
    if (particles[i].brightness < 20 ||
        particles[i].position < -6 ||
        particles[i].position >= NUM_LEDS + 6) {
      particles[i].active = false;
      continue;
    }
    
    int pos = particles[i].position;
    uint8_t size = 3;
    for (int offset = -size; offset <= size; offset++) {
      int ledPos = pos + offset;
      if (ledPos >= 0 && ledPos < NUM_LEDS) {
        uint8_t falloff = 255 - (abs(offset) * 255 / (size + 1));
        uint8_t bri = (particles[i].brightness * falloff) >> 8;
        leds[ledPos] += CHSV(particles[i].hue, 255, bri);
      }
      if (offset % 5 == 0) yield();
    }
  }
  yield();  // Prevent watchdog reset
}

void effectAudioRainbowBars() {
  fill_solid(leds, NUM_LEDS, CRGB(6, 0, 18));
  
  int half = NUM_LEDS / 2;
  int ledsPerBin = (half + NUM_AUDIO_BINS - 1) / NUM_AUDIO_BINS;
  
  for (int bin = 0; bin < NUM_AUDIO_BINS; bin++) {
    int height = map(smoothedBins[bin], 0, 255, 0, (ledsPerBin * 14) / 10);
    height = constrain(height, 0, ledsPerBin);
    
    uint8_t baseHue = map(bin, 0, NUM_AUDIO_BINS - 1, 0, 255);
    baseHue = constrain(baseHue, 0, 255);
    
    int binStart = bin * ledsPerBin;
    
    for (int i = 0; i < height; i++) {
      uint8_t verticalPos = (height > 1) ? map(i, 0, height - 1, 0, 255) : 128;
      uint8_t hueOffset = verticalPos >> 2;
      uint8_t brightness = (height > 1) ? map(i, 0, height - 1, 100, 255) : 200;
      
      // Shimmer
      if ((millis() & 0x3F) == 0 && random8(100) < 5) {
        brightness = min(255, brightness + 50);
      }
      
      // Mirror both sides from center
      int posR = half + binStart + i;
      int posL = half - 1 - binStart - i;
      if (posR < NUM_LEDS) leds[posR] = CHSV(baseHue + hueOffset, 255, brightness);
      if (posL >= 0) leds[posL] = CHSV(baseHue + hueOffset, 255, brightness);
      
      if (i % 15 == 0) yield();
    }
    
    // Peak indicators on both sides
    if (peakHold[bin] > 40) {
      int peakOffset = binStart + height;
      int peakR = half + peakOffset;
      int peakL = half - 1 - peakOffset;
      if (peakR < NUM_LEDS) leds[peakR] = CHSV(baseHue, 150, 255);
      if (peakL >= 0) leds[peakL] = CHSV(baseHue, 150, 255);
    }
    
    yield();
  }
}

// ===== ANIMATIONS FOR SETUP STATES =====
void animAPMode() {
  uint8_t bright = triangleWave8(millis(), 1000);
  bright = scale8(bright, 128);
  fill_solid(leds, NUM_LEDS, CRGB(0, bright, bright));
}

void animConnecting() {
  static uint8_t pos = 0;
  if (millis() - stateTimer > 150) {
    stateTimer = millis();
    pos = (pos + 1) % 4;
    fadeToBlackBy(leds, NUM_LEDS, 45);
  }
  for (int i = pos; i < NUM_LEDS; i += 4) {
    leds[i] = CRGB(0, 0, 180);
  }
}

void animConnectedState() {
  uint8_t hue = (millis() >> 6) % 256;
  uint8_t breath = triangleWave8(millis(), 3000);
  uint8_t brightness = 64 + (breath >> 1);
  for (int i = 0; i < NUM_LEDS; i++) {
    uint8_t ledHue = hue + (i * 2);
    leds[i] = CHSV(ledHue, 240, brightness);
  }
}

// ===== SETUP =====
void setup() {
  Serial.begin(115200);
  delay(100);
  
  // Physical reset button
  pinMode(0, INPUT_PULLUP);
  delay(50);
  if (digitalRead(0) == LOW) {
    Serial.println("\n[FACTORY RESET] Button detected - erasing credentials...");
    clearCredentials();
    Serial.println("[FACTORY RESET] Credentials erased. Rebooting...");
    ESP.restart();
  }
  
  Serial.println("\n=== ESP LED Controller v6.0 (WITH AUDIO VISUALIZERS) ===");
  
  // Initialize LEDs
  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW);
  delay(100);
  FastLED.addLeds<WS2812B, LED_PIN, GRB>(leds, NUM_LEDS).setCorrection(TypicalLEDStrip);
  FastLED.setBrightness(currentBrightness);
  FastLED.setMaxPowerInVoltsAndMilliamps(5, MAX_POWER_MA);
  FastLED.clear();
  FastLED.show();
  
  // Initialize EEPROM
  EEPROM.begin(EEPROM_SIZE);
  EEPROM.end();
  
  // Initialize audio visualization state
  memset(audioBins, 0, NUM_AUDIO_BINS);
  memset(smoothedBins, 0, NUM_AUDIO_BINS);
  memset(peakHold, 0, NUM_AUDIO_BINS);
  memset(particles, 0, sizeof(particles));
  
  // Try auto-reconnect first
  Serial.println("[BOOT] Checking for saved Wi-Fi credentials...");
  if (loadCredentials() && strlen(homeSSID) > 0) {
    Serial.print("[BOOT] Attempting auto-reconnect to \"");
    Serial.print(homeSSID);
    Serial.println("\"...");
    wifiState = STATE_CONNECTING;
    stateTimer = millis();
    autoReconnected = true;
    WiFi.begin(homeSSID, homePassword);
  } else {
    Serial.println("[BOOT] No saved credentials - starting AP mode");
    WiFi.mode(WIFI_AP);  // 👈 Critical fix
    WiFi.softAP(AP_SSID, AP_PASSWORD);
    Serial.print("AP IP: ");
    Serial.println(WiFi.softAPIP());
    wifiState = STATE_AP_MODE;
  }
  
  // Start WebSocket server
  webSocket.begin();
  webSocket.onEvent([](uint8_t num, WStype_t type, uint8_t* payload, size_t length) {
    switch (type) {
      case WStype_CONNECTED:
        Serial.printf("[WS] Client #%u connected\n", num);
        startClientConnectAnimation();
        if (wifiState == STATE_CONNECTED) {
          if (autoReconnected) {
            sendStatus("AUTO_CONNECTED:" + WiFi.localIP().toString());
            autoReconnected = false;
          } else {
            sendStatus("IP:" + WiFi.localIP().toString());
          }
        } else {
          sendStatus("AP_MODE");
        }
        break;
        
      case WStype_BIN:
        if (length >= 1 && payload[0] == 0xFF) {
          // WiFi reconfiguration command
          if (length >= 2) {
            uint8_t ssid_len = payload[1];
            uint8_t pass_len = (length >= 3) ? payload[2] : 0;
            if (ssid_len > 32 || pass_len > 63 || length < 3 + ssid_len + pass_len) {
              sendStatus("ERR:Invalid reconfiguration payload");
              return;
            }
            memcpy(homeSSID, &payload[3], ssid_len);
            homeSSID[ssid_len] = 0;
            memcpy(homePassword, &payload[3 + ssid_len], pass_len);
            homePassword[pass_len] = 0;
            Serial.printf("[RECONFIG] New WiFi credentials received: %s\n", homeSSID);
            sendStatus("RECONFIG:" + String(homeSSID));
            saveCredentials(homeSSID, homePassword);
            WiFi.disconnect();
            delay(500);
            WiFi.begin(homeSSID, homePassword);
            wifiState = STATE_CONNECTING;
            stateTimer = millis();
            pendingApShutdown = false;
            autoReconnected = false;
          }
        }
        // WiFi credential handling (AP mode only)
        else if ((wifiState == STATE_AP_MODE || wifiState == STATE_WIFI_CONFIG) && length >= 2) {
          uint8_t ssid_len = payload[0];
          uint8_t pass_len = payload[1];
          if (ssid_len > 32 || pass_len > 63 || length < 2 + ssid_len + pass_len) {
            sendStatus("ERR:Invalid payload");
            return;
          }
          memcpy(homeSSID, &payload[2], ssid_len);
          homeSSID[ssid_len] = 0;
          memcpy(homePassword, &payload[2 + ssid_len], pass_len);
          homePassword[pass_len] = 0;
          sendStatus("RECV:" + String(homeSSID));
          saveCredentials(homeSSID, homePassword);
          WiFi.begin(homeSSID, homePassword);
          wifiState = STATE_CONNECTING;
          stateTimer = millis();
          pendingApShutdown = false;
          autoReconnected = false;
        }
        // Color/mode/brightness/audio commands
        else if (wifiState == STATE_CONNECTED && length >= 1) {
          awaitingFirstCommand = false;
          switch (payload[0]) {
            case 0x01:  // Static color
              if (length >= 4) {
                mode = MODE_STATIC;
                CRGB color(payload[1], payload[2], payload[3]);
                fill_solid(leds, NUM_LEDS, color);
                Serial.printf("[COLOR] Set RGB(%d,%d,%d)\n", payload[1], payload[2], payload[3]);
              }
              break;
              
            case 0x02:  // Mode select
              if (length >= 2) {
                uint8_t newMode = payload[1];
                if (newMode <= MODE_AUDIO_RAINBOW_BARS && newMode != mode) {
                  mode = newMode;
                  // Reset effect buffers on mode change
                  memset(heat, 0, NUM_LEDS);
                  cylonPosition = NUM_LEDS / 2;
                  cylonDirection = 1;
                  paletteIndex = 0;
                  plasmaPseudoTime = 0;
                  auroraTime = 0;
                  memset(matrixRaindrops, 0, NUM_LEDS);
                  memset(particles, 0, sizeof(particles));
                  nextParticle = 0;
                  Serial.printf("[MODE] Changed to %d\n", mode);
                }
              }
              break;
              
            case 0x03:  // Brightness control
              if (length >= 2) {
                uint8_t brightness = payload[1];
                currentBrightness = brightness;
                FastLED.setBrightness(brightness);
                Serial.printf("[BRIGHTNESS] Set to %d\n", brightness);
              }
              break;
              
            case 0x04:  // AUDIO DATA - 16 bins
              // CRITICAL: Drop IMMEDIATELY if still processing previous frame
              if (audioProcessing) {
                break;  // Prevent buffer overflow during render
              }
              
              if (length >= NUM_AUDIO_BINS + 1) {
                for (int i = 0; i < NUM_AUDIO_BINS; i++) {
                  audioBins[i] = payload[i + 1];
                }
                lastAudioUpdate = millis();
                
                // Auto-switch to audio mode ONLY if not already in one
              if (mode < MODE_AUDIO_SPECTRUM || mode > MODE_AUDIO_RAINBOW_BARS) {
                mode = MODE_AUDIO_SPECTRUM;
              }

              }
              break;
          }
        }
        break;
        
      case WStype_DISCONNECTED:
        Serial.printf("[WS] Client #%u disconnected\n", num);
        break;
    }
  });
  
  Serial.println("WebSocket server started on port " + String(WS_PORT));
  
  // Initialize effect buffers
  memset(heat, 0, NUM_LEDS);
  memset(matrixRaindrops, 0, NUM_LEDS);
  lastFrame = millis();

  WiFi.setSleepMode(WIFI_NONE_SLEEP);
  
  Serial.println("=== Boot completed - AUDIO VISUALIZERS ENABLED ===\n");
}

// ===== WIFI CONNECTION HANDLER =====
void handleWiFiConnection() {
  if (pendingApShutdown && (millis() - apGraceTimer >= AP_GRACE_PERIOD)) {
    Serial.println("\n[AP] Grace period ended - disabling hotspot...");
    WiFi.softAPdisconnect(true);
    pendingApShutdown = false;
    if (MDNS.begin("esp-led")) {
      MDNS.addService("ws", "tcp", WS_PORT);
      Serial.println("[mDNS] Started: esp-led.local");
    }
    Serial.println("[SYSTEM] Ready on home network!");
    return;
  }
  
  if (wifiState != STATE_CONNECTING) return;
  
  if (WiFi.status() == WL_CONNECTED) {
    Serial.print("\n[WiFi] SUCCESS: Connected to \"");
    Serial.print(homeSSID);
    Serial.print("\" | IP: ");
    Serial.println(WiFi.localIP());
    if (autoReconnected) {
      sendStatus("AUTO_CONNECTED:" + WiFi.localIP().toString());
    } else {
      sendStatus("IP:" + WiFi.localIP().toString());
    }
    wifiState = STATE_CONNECTED;
    awaitingFirstCommand = true;
    // WiFi.mode(WIFI_STA | WIFI_AP); 
    // WiFi.softAP(AP_SSID, AP_PASSWORD);
    pendingApShutdown = true;
    apGraceTimer = millis();
    Serial.println("[AP] Keeping hotspot alive 3s to deliver IP...");
  } else if (millis() - stateTimer > WIFI_TIMEOUT) {
    Serial.println("[WiFi] TIMEOUT: Failed to connect");
     WiFi.mode(WIFI_AP);
    WiFi.softAP(AP_SSID, AP_PASSWORD);
    
    Serial.println("[AP] Re-enabled hotspot");
    Serial.print("AP IP: ");
    Serial.println(WiFi.softAPIP());
    if (autoReconnected) {
      Serial.println("[BOOT] Auto-reconnect failed - starting AP mode");
      WiFi.mode(WIFI_AP);  // 👈 Critical fix
      WiFi.softAP(AP_SSID, AP_PASSWORD);
      Serial.print("AP IP: ");
      Serial.println(WiFi.softAPIP());
      wifiState = STATE_AP_MODE;
      sendStatus("AP_MODE");
      autoReconnected = false;
    } else {
      sendStatus("FAIL:Connection timeout");
      wifiState = STATE_AP_MODE;
      if (WiFi.softAPgetStationNum() == 0) {
        WiFi.mode(WIFI_AP);  // 👈 Critical fix
        WiFi.softAP(AP_SSID, AP_PASSWORD);
        Serial.println("[AP] Re-enabled hotspot");
      }
    }
  }
}

// ===== MAIN LOOP =====
void loop() {
  yield();
  webSocket.loop();
  yield();
  handleWiFiConnection();

  static uint32_t lastYield = millis();
  if (millis() - lastYield > 2500) {  // Watchdog triggers at ~3s
    Serial.println("[WARNING] Approaching watchdog limit!");
    lastYield = millis();
  }
    
  // CRITICAL: Use slower frame rate for audio modes
  uint32_t targetFrameTime = (mode >= MODE_AUDIO_SPECTRUM && mode <= MODE_AUDIO_RAINBOW_BARS) 
      ? AUDIO_MODE_FRAME_TIME_MS 
      : FRAME_TIME_MS;
      
  if (millis() - lastFrame < targetFrameTime) {
    delay(1);  // Let WiFi + watchdog breathe (yield alone isn't enough)
    return;
  }
  
  lastFrame = millis();
  
  // Smooth audio data before rendering
  if (mode >= MODE_AUDIO_SPECTRUM && mode <= MODE_AUDIO_RAINBOW_BARS) {
    audioProcessing = true;  // Guard: drop incoming audio packets during render
    smoothAudioBins();
    static uint32_t lastDebug = 0;
    if (millis() - lastDebug > 1000 && mode >= MODE_AUDIO_SPECTRUM) {
      Serial.print("Audio bins: ");
      for(int i=0; i<4; i++) Serial.print(audioBins[i]); Serial.print(" ");
      Serial.println();
      lastDebug = millis();
    }
    // Timeout: zero out bins if no data received recently
    if (millis() - lastAudioUpdate > AUDIO_TIMEOUT_MS) {
      memset(smoothedBins, 0, NUM_AUDIO_BINS);
      memset(audioBins, 0, NUM_AUDIO_BINS);
    }
    yield();
  }
  
  if (isClientConnectAnimActive) {
    animClientConnected();
  } else {
    switch (wifiState) {
      case STATE_AP_MODE: animAPMode(); break;
      case STATE_CONNECTING: animConnecting(); break;
      case STATE_CONNECTED:
        if (awaitingFirstCommand) {
          animConnectedState();
        } else {
          switch (mode) {
            case MODE_STATIC: break;
            case MODE_RAINBOW: effectRainbow(); break;
            case MODE_FIRE: effectFire(); break;
            case MODE_PALETTE: effectPalette(); break;
            case MODE_CYLON: effectCylon(); break;
            case MODE_PACIFICA: effectPacifica(); break;
            case MODE_PRIDE: effectPride(); break;
            case MODE_PLASMA: effectPlasma(); break;
            case MODE_AURORA: effectAurora(); break;
            case MODE_MATRIX: effectMatrix(); break;
            case MODE_AUDIO_SPECTRUM: effectAudioSpectrum(); break;
            case MODE_AUDIO_WAVE: effectAudioWave(); break;
            case MODE_AUDIO_ENERGY: effectAudioEnergy(); break;
            case MODE_AUDIO_PARTICLES: effectAudioParticles(); break;
            case MODE_AUDIO_RAINBOW_BARS: effectAudioRainbowBars(); break;
          }
        }
        break;
      case STATE_WAITING:
        {
          uint8_t val = triangleWave8(millis(), 800);
          fill_solid(leds, NUM_LEDS, CRGB(val, val, val));
        }
        break;
      case STATE_WIFI_CONFIG:
        {
          bool on = (millis() / 500) & 0x01;
          fill_solid(leds, NUM_LEDS, on ? CRGB(255, 200, 0) : CRGB(20, 15, 0));
        }
        break;
    }
  }

  // if (mode == MODE_AUDIO_SPECTRUM && millis() % 2000 < 1000) {
  // // Force full brightness bars for 1 second every 2 seconds
  //   for (int i=0; i<NUM_AUDIO_BINS; i++) {
  //     smoothedBins[i] = 255;
  //     audioBins[i] = 255;
  //   }
  // }
  
  FastLED.show();
  audioProcessing = false;  // Allow new audio packets
  lastYield = millis();
  yield();
}