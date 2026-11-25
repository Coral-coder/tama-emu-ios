// Tama serial bridge for any ESP32 with Bluetooth LE (ESP32, ESP32-C3, ESP32-S3, ESP32-C6).
//
// Wires a Tamagotchi's link port (UART, 460800 baud 8N1, 3.3 V) to:
//   * the Tama app over Bluetooth LE (Nordic UART Service, "Tama Bridge"),
//   * the Tama app over Wi-Fi (TCP port 23): its own network "Tama-Bridge" or your home network,
//   * another Tama Bridge over Bluetooth, directly (two real toys on a playdate, no phone needed).
// Its settings are kept on the board and changed from the app (Tools -> Dongle) over Bluetooth.
//
// Wiring: bridge TX -> toy RX, bridge RX <- toy TX, GND <-> GND (pins per chip below).
// Needs the library ArduinoJson, and for the Heltec boards "ESP8266 and ESP32 OLED driver for
// SSD1306 displays" (Library Manager); the esp32 core 3.3.x (4.x changed the Bluetooth library). Prebuilt files and a Windows flasher are on the
// repository's Releases page (esp32-bridge-*).

#include <ArduinoJson.h>
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <ESPmDNS.h>
#include <Preferences.h>
#include <WiFi.h>
#if defined(BOARD_HELTEC_V3) || defined(BOARD_HELTEC_V4) || defined(BOARD_TLORA_V161)
#include <SSD1306Wire.h>
#include <Wire.h>
#endif

#define FW_VERSION "2.1"

#if defined(BOARD_HELTEC_V3) || defined(BOARD_HELTEC_V4)
// Heltec WiFi LoRa 32 V3 / V4 (ESP32-S3 with a 0.96" screen): toy line on header pins 47 / 48
// (43 / 44 go to the board's own USB chip)
static const int PIN_RX = 47, PIN_TX = 48;
#ifdef BOARD_HELTEC_V4
static const char *CHIP = "Heltec V4";
#else
static const char *CHIP = "Heltec V3";
#endif
#define HAS_SCREEN 1
#define SCREEN_SDA 17
#define SCREEN_SCL 18
#define SCREEN_RST 21
#define SCREEN_POWER 36  // Vext: LOW powers the screen
#define BOARD_LED 35
#elif defined(BOARD_TLORA_V161)
// LilyGO T-LoRa (T3) V1.6.1, ESP32 with a 0.96" screen (LilyGO's schematic T3_V1.6.1): toy line
// on the right header JP2, RX = IO34 (pin 10), TX = IO4 (pin 2); GND on JP1 pin 2 or 4. The LoRa
// radio has 5, 18, 19, 23, 26, 27, 32, 33, the SD card slot 2, 13, 14, 15, the screen 21, 22,
// the battery 35, the LED 25.
static const int PIN_RX = 34, PIN_TX = 4;
static const char *CHIP = "T-LoRa V1.6.1";
#define HAS_SCREEN 1
#define SCREEN_SDA 21
#define SCREEN_SCL 22
#define BOARD_LED 25
#elif CONFIG_IDF_TARGET_ESP32C3
static const int PIN_RX = 20, PIN_TX = 21;
static const char *CHIP = "ESP32-C3";
#elif CONFIG_IDF_TARGET_ESP32S3
static const int PIN_RX = 44, PIN_TX = 43;
static const char *CHIP = "ESP32-S3";
#elif CONFIG_IDF_TARGET_ESP32C6
static const int PIN_RX = 17, PIN_TX = 16;
static const char *CHIP = "ESP32-C6";
#else
static const int PIN_RX = 34, PIN_TX = 13;  // the original ESP32 (T-LoRa v1.3, DevKit)
static const char *CHIP = "ESP32";
#endif

#if defined(BOARD_LED)
static const int LED = BOARD_LED;
#elif defined(LED_BUILTIN)
static const int LED = LED_BUILTIN;
#else
static const int LED = 2;
#endif

#if CONFIG_IDF_TARGET_ESP32
HardwareSerial Toy(2);
#else
HardwareSerial Toy(1);
#endif

#define NUS_SERVICE "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define NUS_RX "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"  // written by the app (or a peer bridge)
#define NUS_TX "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"  // notified to the app (or a peer bridge)
#define CFG_SERVICE "7A3E0001-6B5C-4C1D-9C2A-5D1E8F7A0001"
#define CFG_CHAR "7A3E0002-6B5C-4C1D-9C2A-5D1E8F7A0001"  // JSON lines both ways

// ---- settings (kept on the board) -------------------------------------------------------------
struct Settings {
  String name = "Tama Bridge";
  uint32_t baud = 460800;
  uint8_t wifiMode = 1;  // 0 off, 1 its own network, 2 join a network
  String apPass = "tamagotchi";
  String ssid, pass;     // the network to join
  bool peerOn = false;   // link to another bridge over Bluetooth
  String peer;           // its address
} S;
Preferences prefs;

void loadSettings() {
  prefs.begin("tama", true);
  S.name = prefs.getString("name", S.name);
  S.baud = prefs.getUInt("baud", S.baud);
  S.wifiMode = prefs.getUChar("wifi", S.wifiMode);
  S.apPass = prefs.getString("appass", S.apPass);
  S.ssid = prefs.getString("ssid", "");
  S.pass = prefs.getString("pass", "");
  S.peerOn = prefs.getBool("peeron", false);
  S.peer = prefs.getString("peer", "");
  prefs.end();
}

void saveSettings() {
  prefs.begin("tama", false);
  prefs.putString("name", S.name);
  prefs.putUInt("baud", S.baud);
  prefs.putUChar("wifi", S.wifiMode);
  prefs.putString("appass", S.apPass);
  prefs.putString("ssid", S.ssid);
  prefs.putString("pass", S.pass);
  prefs.putBool("peeron", S.peerOn);
  prefs.putString("peer", S.peer);
  prefs.end();
}

uint32_t bytesIn = 0, bytesOut = 0;  // from / to the toy

// ---- Bluetooth: the app side (server) ---------------------------------------------------------
BLEServer *srv = nullptr;
BLECharacteristic *txChar = nullptr, *cfgChar = nullptr;
volatile bool appConnected = false;
uint16_t payload = 20;
String cfgIn;          // a JSON line being received
volatile bool cfgPending = false;
String cfgLine;

class ServerEvents : public BLEServerCallbacks {
  void onConnect(BLEServer *s) override {
    appConnected = true;
    BLEDevice::startAdvertising();  // stay visible (a peer bridge may connect too)
  }
  void onDisconnect(BLEServer *s) override {
    appConnected = false;
    payload = 20;
    BLEDevice::startAdvertising();
  }
};

class RxEvents : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *c) override {
    String v = c->getValue();
    if (v.length()) Toy.write((const uint8_t *)v.c_str(), v.length());
    bytesOut += v.length();
  }
};

class CfgEvents : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *c) override {
    cfgIn += c->getValue();
    int nl = cfgIn.indexOf('\n');
    if (nl >= 0) {
      cfgLine = cfgIn.substring(0, nl);
      cfgIn = cfgIn.substring(nl + 1);
      cfgPending = true;  // handled in loop(), not in the Bluetooth task
    }
  }
};

void notifyChunks(BLECharacteristic *c, const uint8_t *d, size_t n) {
  // the packet size the phone agreed to
  uint16_t mtu = srv ? srv->getPeerMTU(srv->getConnId()) : 23;
  payload = mtu > 23 ? mtu - 3 : 20;
  for (size_t o = 0; o < n; o += payload) {
    size_t k = min((size_t)payload, n - o);
    c->setValue((uint8_t *)d + o, k);
    c->notify();
    // paced to what a phone takes (about 25 KB/s): faster, the Bluetooth stack drops packets
    // and a long answer from the toy arrives with holes
    delay(n > payload ? 10 : 2);
  }
}

void sendCfg(JsonDocument &doc) {
  String s;
  serializeJson(doc, s);
  s += "\n";
  if (appConnected && cfgChar) notifyChunks(cfgChar, (const uint8_t *)s.c_str(), s.length());
}

// ---- Bluetooth: the peer side (client to another bridge) --------------------------------------
BLEClient *peerClient = nullptr;
BLERemoteCharacteristic *peerRx = nullptr;
volatile bool peerConnected = false;
uint32_t peerRetryAt = 0;

void onPeerData(BLERemoteCharacteristic *, uint8_t *d, size_t n, bool) {
  Toy.write(d, n);
  bytesOut += n;
}

class PeerEvents : public BLEClientCallbacks {
  void onConnect(BLEClient *) override {}
  void onDisconnect(BLEClient *) override {
    peerConnected = false;
    peerRx = nullptr;
  }
};

void peerTry() {
  if (!S.peerOn || S.peer.isEmpty() || peerConnected || millis() < peerRetryAt) return;
  peerRetryAt = millis() + 5000;
  if (!peerClient) {
    peerClient = BLEDevice::createClient();
    peerClient->setClientCallbacks(new PeerEvents());
  }
  if (!peerClient->connect(BLEAddress(S.peer.c_str()))) return;
  peerClient->setMTU(247);
  BLERemoteService *svc = peerClient->getService(NUS_SERVICE);
  if (!svc) {
    peerClient->disconnect();
    return;
  }
  BLERemoteCharacteristic *tx = svc->getCharacteristic(NUS_TX);
  peerRx = svc->getCharacteristic(NUS_RX);
  if (!tx || !peerRx) {
    peerClient->disconnect();
    return;
  }
  tx->registerForNotify(onPeerData);
  peerConnected = true;
}

void peerSend(const uint8_t *d, size_t n) {
  if (!peerConnected || !peerRx) return;
  for (size_t o = 0; o < n; o += 180) peerRx->writeValue((uint8_t *)d + o, min((size_t)180, n - o), false);
}

// a search for other bridges, for the app to pick one
void scanPeers() {
  BLEScan *sc = BLEDevice::getScan();
  sc->setActiveScan(true);
  BLEScanResults *r = sc->start(4, false);
  JsonDocument doc;
  JsonArray a = doc["found"].to<JsonArray>();
  for (int i = 0; r && i < r->getCount(); i++) {
    BLEAdvertisedDevice d = r->getDevice(i);
    if (!d.isAdvertisingService(BLEUUID(NUS_SERVICE))) continue;
    JsonObject o = a.add<JsonObject>();
    o["name"] = d.getName().c_str();
    o["addr"] = d.getAddress().toString().c_str();
    o["rssi"] = d.getRSSI();
  }
  sc->clearResults();
  sendCfg(doc);
}

// ---- Wi-Fi --------------------------------------------------------------------------------------
WiFiServer server(23);
WiFiClient client;

void startWifi() {
  WiFi.disconnect(true);
  if (S.wifiMode == 0) {
    WiFi.mode(WIFI_OFF);
    return;
  }
  if (S.wifiMode == 2 && S.ssid.length()) {
    WiFi.mode(WIFI_STA);
    WiFi.setHostname("tama-bridge");
    WiFi.begin(S.ssid.c_str(), S.pass.c_str());
  } else {
    WiFi.mode(WIFI_AP);
    WiFi.softAP("Tama-Bridge", S.apPass.length() >= 8 ? S.apPass.c_str() : "tamagotchi");
  }
  server.begin();
  server.setNoDelay(true);
  MDNS.begin("tama-bridge");
  MDNS.addService("tama", "tcp", 23);
}

String wifiIp() {
  if (S.wifiMode == 1) return WiFi.softAPIP().toString();
  if (S.wifiMode == 2 && WiFi.status() == WL_CONNECTED) return WiFi.localIP().toString();
  return "";
}

// ---- the screen (Heltec boards, T-LoRa V1.6.1) ----------------------------------------------------------------
#ifdef HAS_SCREEN
SSD1306Wire screen(0x3c, SCREEN_SDA, SCREEN_SCL);
uint32_t screenAt = 0;

void screenStart() {
#ifdef SCREEN_POWER
  pinMode(SCREEN_POWER, OUTPUT);
  digitalWrite(SCREEN_POWER, LOW);
#endif
#ifdef SCREEN_RST
  pinMode(SCREEN_RST, OUTPUT);
  digitalWrite(SCREEN_RST, LOW);
  delay(20);
  digitalWrite(SCREEN_RST, HIGH);
#endif
  screen.init();
  screen.flipScreenVertically();
  screen.setFont(ArialMT_Plain_10);
}

String wifiIp();
void screenDraw() {
  if (millis() < screenAt) return;
  screenAt = millis() + 500;
  screen.clear();
  screen.setFont(ArialMT_Plain_16);
  screen.drawString(0, 0, S.name);
  screen.setFont(ArialMT_Plain_10);
  screen.drawString(0, 18, String("App: ") + (appConnected ? "Bluetooth" : "-") + ((client && client.connected()) ? " + Wi-Fi" : ""));
  screen.drawString(0, 29, String("Peer: ") + (S.peerOn ? (peerConnected ? "linked" : "looking...") : "off"));
  String ip = wifiIp();
  screen.drawString(0, 40, String("Wi-Fi: ") + (ip.length() ? ip : (S.wifiMode == 0 ? "off" : "joining...")));
  screen.drawString(0, 51, String("Toy ") + S.baud + "  in " + bytesIn + " out " + bytesOut);
  screen.display();
}
#endif

// ---- settings channel ---------------------------------------------------------------------------
void sendState() {
  JsonDocument doc;
  doc["v"] = FW_VERSION;
  doc["chip"] = CHIP;
  doc["mac"] = BLEDevice::getAddress().toString().c_str();
  doc["name"] = S.name;
  doc["baud"] = S.baud;
  doc["pins"]["rx"] = PIN_RX;
  doc["pins"]["tx"] = PIN_TX;
  JsonObject w = doc["wifi"].to<JsonObject>();
  w["mode"] = S.wifiMode;
  w["ssid"] = S.ssid;
  w["ip"] = wifiIp();
  w["connected"] = S.wifiMode == 1 || WiFi.status() == WL_CONNECTED;
  w["client"] = (bool)(client && client.connected());
  JsonObject p = doc["peer"].to<JsonObject>();
  p["on"] = S.peerOn;
  p["addr"] = S.peer;
  p["connected"] = (bool)peerConnected;
  sendCfg(doc);
}

void handleCfg(const String &line) {
  JsonDocument in;
  if (deserializeJson(in, line)) return;
  if (in["scan"].is<bool>()) {
    scanPeers();
    return;
  }
  if (in["restart"].is<bool>()) {
    delay(200);
    ESP.restart();
  }
  if (in["set"].is<JsonObject>()) {
    JsonObject s = in["set"];
    bool wifi = false, restart = false;
    if (s["name"].is<const char *>()) {
      S.name = s["name"].as<String>();
      restart = true;  // the Bluetooth name is set at start
    }
    if (s["baud"].is<uint32_t>()) {
      S.baud = s["baud"];
      Toy.updateBaudRate(S.baud);
    }
    if (s["wifi"].is<uint8_t>()) {
      S.wifiMode = s["wifi"];
      wifi = true;
    }
    if (s["ssid"].is<const char *>()) {
      S.ssid = s["ssid"].as<String>();
      wifi = true;
    }
    if (s["pass"].is<const char *>()) {
      S.pass = s["pass"].as<String>();
      wifi = true;
    }
    if (s["appass"].is<const char *>()) {
      S.apPass = s["appass"].as<String>();
      wifi = true;
    }
    if (s["peer"].is<const char *>()) {
      S.peer = s["peer"].as<String>();
      if (peerClient && peerConnected) peerClient->disconnect();
      peerRetryAt = 0;
    }
    if (s["peeron"].is<bool>()) {
      S.peerOn = s["peeron"];
      if (!S.peerOn && peerClient && peerConnected) peerClient->disconnect();
      peerRetryAt = 0;
    }
    saveSettings();
    if (wifi) startWifi();
    sendState();
    if (restart) {
      delay(300);
      ESP.restart();
    }
    return;
  }
  sendState();  // {"get":1} or anything else
}

// ---- start and run ------------------------------------------------------------------------------
void setup() {
  pinMode(LED, OUTPUT);
  Serial.begin(115200);
  loadSettings();
  Toy.setRxBufferSize(8192);
  Toy.begin(S.baud, SERIAL_8N1, PIN_RX, PIN_TX);

  BLEDevice::init(S.name.c_str());
  BLEDevice::setMTU(247);
  srv = BLEDevice::createServer();
  srv->setCallbacks(new ServerEvents());
  BLEService *nus = srv->createService(NUS_SERVICE);
  txChar = nus->createCharacteristic(NUS_TX, BLECharacteristic::PROPERTY_NOTIFY);
  txChar->addDescriptor(new BLE2902());
  BLECharacteristic *rx = nus->createCharacteristic(NUS_RX, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  rx->setCallbacks(new RxEvents());
  nus->start();
  BLEService *cfg = srv->createService(CFG_SERVICE);
  cfgChar = cfg->createCharacteristic(CFG_CHAR, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR | BLECharacteristic::PROPERTY_NOTIFY);
  cfgChar->addDescriptor(new BLE2902());
  cfgChar->setCallbacks(new CfgEvents());
  cfg->start();
  BLEAdvertising *adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(NUS_SERVICE);
  adv->setScanResponse(true);
  BLEDevice::startAdvertising();

  startWifi();
#ifdef HAS_SCREEN
  screenStart();
#endif
  Serial.printf("Tama Bridge %s on %s: \"%s\", toy line %u baud (RX %d, TX %d)\n", FW_VERSION, CHIP, S.name.c_str(), S.baud, PIN_RX, PIN_TX);
}

void loop() {
  if (cfgPending) {
    cfgPending = false;
    handleCfg(cfgLine);
  }
  peerTry();
  if (server.hasClient()) {
    if (client) client.stop();
    client = server.available();
    client.setNoDelay(true);
  }
  uint8_t buf[512];
  while (client && client.connected() && client.available()) {
    int n = client.read(buf, sizeof(buf));
    if (n > 0) {
      Toy.write(buf, n);
      bytesOut += n;
    }
  }
  int n = Toy.available();
  if (n > 0) {
    n = Toy.read(buf, min(n, (int)sizeof(buf)));
    bytesIn += n;
    if (client && client.connected()) client.write(buf, n);
    if (appConnected && txChar) notifyChunks(txChar, buf, n);
    peerSend(buf, n);
  }
#ifdef HAS_SCREEN
  screenDraw();
#endif
  digitalWrite(LED, appConnected || peerConnected || (client && client.connected()) ? HIGH : LOW);
  if (!n) delay(1);
}
