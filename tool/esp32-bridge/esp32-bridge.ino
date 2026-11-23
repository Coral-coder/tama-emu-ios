// Tama serial bridge for an ESP32 (tested layout: LilyGO TTGO T-LoRa / LoRa32 v1.3).
//
// Wires the toy's link port (UART, 460800 baud 8N1, 3.3 V) to the Tama app on the phone, two ways
// at once, whichever the app uses:
//   * Bluetooth LE, Nordic UART Service ("Tama Bridge" in the app's Hardware page, Scan)
//   * Wi-Fi: its own network "Tama-Bridge" (password tamagotchi), TCP 192.168.4.1 port 23
//
// Wiring (3 wires): ESP32 TX pin -> toy RX, ESP32 RX pin <- toy TX, GND <-> GND.
// Do not connect the toy's power pin. The LoRa radio and the screen of the T-LoRa are not used.
//
// Arduino IDE: board "ESP32 Dev Module" (or "TTGO LoRa32-OLED"), Partition "Huge APP", upload.

#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <WiFi.h>

// ---- settings ---------------------------------------------------------------------------------
// Pins of the serial line to the toy. On the T-LoRa v1.3 these are free (not used by the LoRa
// radio or the OLED). GPIO 34 can only be an input, which is all RX needs. Change them if your
// board's pins are taken; avoid 0, 2, 5, 12, 14, 15, 18, 19, 26, 27 on the T-LoRa.
#if CONFIG_IDF_TARGET_ESP32C3
static const int PIN_RX = 20;  // ESP32-C3 (SuperMini, XIAO C3): the pins marked RX / TX
static const int PIN_TX = 21;
#elif CONFIG_IDF_TARGET_ESP32S3
static const int PIN_RX = 44;  // ESP32-S3 (XIAO S3 and most S3 boards): the pins marked RX / TX
static const int PIN_TX = 43;
#else
static const int PIN_RX = 34;  // the original ESP32 (T-LoRa v1.3, DevKit): from the toy's TX
static const int PIN_TX = 13;  // to the toy's RX
#endif
static const uint32_t BAUD = 460800;  // the Paradise link port; first toys' comm boards: change

static const char *BLE_NAME = "Tama Bridge";
static const char *WIFI_NAME = "Tama-Bridge";
static const char *WIFI_PASS = "tamagotchi";  // 8 characters or more
static const uint16_t TCP_PORT = 23;
#ifdef LED_BUILTIN
static const int LED = LED_BUILTIN;  // the board's LED: on while the app is connected
#else
static const int LED = 2;
#endif
// ------------------------------------------------------------------------------------------------

#define NUS_SERVICE "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define NUS_RX "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"  // the app writes here
#define NUS_TX "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"  // the bridge notifies here

#if CONFIG_IDF_TARGET_ESP32
HardwareSerial Toy(2);
#else
HardwareSerial Toy(1);  // the C3 and S3 have no third serial port
#endif
BLECharacteristic *txChar = nullptr;
volatile bool bleConnected = false;
uint16_t blePayload = 20;  // grows with the MTU the phone agrees to
WiFiServer server(TCP_PORT);
WiFiClient client;

class ServerEvents : public BLEServerCallbacks {
  void onConnect(BLEServer *s) override { bleConnected = true; }
  void onDisconnect(BLEServer *s) override {
    bleConnected = false;
    blePayload = 20;
    s->startAdvertising();  // ready for the next connection
  }
  void onMtuChanged(BLEServer *s, esp_ble_gatts_cb_param_t *p) override {
    blePayload = p->mtu.mtu > 3 ? p->mtu.mtu - 3 : 20;
  }
};

class RxEvents : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *c) override {
    // from the app to the toy
    String v = c->getValue();
    if (v.length()) Toy.write((const uint8_t *)v.c_str(), v.length());
  }
};

void setup() {
  pinMode(LED, OUTPUT);
  Serial.begin(115200);
  Toy.setRxBufferSize(8192);
  Toy.begin(BAUD, SERIAL_8N1, PIN_RX, PIN_TX);

  BLEDevice::init(BLE_NAME);
  BLEDevice::setMTU(247);
  BLEServer *srv = BLEDevice::createServer();
  srv->setCallbacks(new ServerEvents());
  BLEService *nus = srv->createService(NUS_SERVICE);
  txChar = nus->createCharacteristic(NUS_TX, BLECharacteristic::PROPERTY_NOTIFY);
  txChar->addDescriptor(new BLE2902());
  BLECharacteristic *rx = nus->createCharacteristic(NUS_RX, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  rx->setCallbacks(new RxEvents());
  nus->start();
  BLEAdvertising *adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(NUS_SERVICE);
  adv->setScanResponse(true);
  BLEDevice::startAdvertising();

  WiFi.mode(WIFI_AP);
  WiFi.softAP(WIFI_NAME, WIFI_PASS);
  server.begin();
  server.setNoDelay(true);

  Serial.printf("Tama Bridge: Bluetooth \"%s\", Wi-Fi \"%s\" at %s:%u, toy line %u baud on RX %d / TX %d\n", BLE_NAME, WIFI_NAME,
                WiFi.softAPIP().toString().c_str(), TCP_PORT, BAUD, PIN_RX, PIN_TX);
}

void loop() {
  // a Wi-Fi app connecting takes the place of the previous one
  if (server.hasClient()) {
    if (client) client.stop();
    client = server.available();
    client.setNoDelay(true);
  }
  // from the app (Wi-Fi) to the toy
  uint8_t buf[512];
  while (client && client.connected() && client.available()) {
    int n = client.read(buf, sizeof(buf));
    if (n > 0) Toy.write(buf, n);
  }
  // from the toy to the app (both ways it may be connected)
  int n = Toy.available();
  if (n > 0) {
    n = Toy.read(buf, min(n, (int)sizeof(buf)));
    if (client && client.connected()) client.write(buf, n);
    if (bleConnected && txChar) {
      for (int o = 0; o < n; o += blePayload) {
        int k = min((int)blePayload, n - o);
        txChar->setValue(buf + o, k);
        txChar->notify();
        delay(2);  // let the radio send it before the next piece
      }
    }
  }
  digitalWrite(LED, bleConnected || (client && client.connected()) ? HIGH : LOW);
  if (!n) delay(1);
}
