# ==============================================================================
# deploy-stack.ps1 - Complete Smart House Stack with Real Equipment Images
# EMQX Broker | Home Assistant | Zigbee2MQTT | Zabbix 7.0 | 3D Digital Twin
# ==============================================================================
$ErrorActionPreference = "Stop"
$ProjectDir = "$PSScriptRoot\smarthouse-stack"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# Trygt generert gradtegn som aldri blir korrupt til Â°C uavhengig av editor/tegnsett
$degC = "$([char]176)C"

function Get-AvailablePort([int]$startPort) {
    $port = $startPort
    while ($true) {
        $conn = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue
        if (-not $conn) {
            return $port
        }
        $port++
    }
}

# ------------------------------------------------------------------------------
# 0. Check & Start Docker Desktop
# ------------------------------------------------------------------------------
Write-Host "==> Verifying Docker Desktop status..." -ForegroundColor Cyan

& docker info > $null 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker daemon is not running. Launching Docker Desktop..." -ForegroundColor Yellow
    $dockerPath = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    if (Test-Path $dockerPath) {
        Start-Process $dockerPath
    } else {
        Write-Error "Docker Desktop executable not found at: $dockerPath. Please launch it manually."
        exit 1
    }

    Write-Host "Waiting for Docker daemon to initialize..." -ForegroundColor Yellow
    $timeout = 90
    $elapsed = 0
    $dockerReady = $false

    while ($elapsed -lt $timeout) {
        Start-Sleep -Seconds 3
        $elapsed += 3
        & docker info > $null 2>&1
        if ($LASTEXITCODE -eq 0) {
            $dockerReady = $true
            break
        }
        Write-Host "  ... waiting ($elapsed / $timeout seconds)" -ForegroundColor Gray
    }

    if (-not $dockerReady) {
        Write-Error "Timeout: Docker daemon did not respond within $timeout seconds."
        exit 1
    }
}
Write-Host "Docker daemon is active and ready." -ForegroundColor Green

# ------------------------------------------------------------------------------
# 1. Cleanup Old Containers & Allocate Free Ports
# ------------------------------------------------------------------------------
Write-Host "==> Cleaning up older containers..." -ForegroundColor Cyan
& docker rm -f smarthouse-bridge smarthouse-broker smarthouse-app smarthouse-homeassistant zabbix-server zabbix-web zabbix-agent2 zabbix-db > $null 2>&1

$z2mPort  = Get-AvailablePort 8085
$zbxPort  = Get-AvailablePort 8080
$emqxPort = Get-AvailablePort 18083
$haPort   = Get-AvailablePort 8123

Write-Host "Port Allocations:" -ForegroundColor Green
Write-Host "  * EMQX Broker Dashboard   : $emqxPort"
Write-Host "  * Home Assistant Portal   : $haPort"
Write-Host "  * Zigbee2MQTT Frontend    : $z2mPort"
Write-Host "  * Zabbix Web Portal       : $zbxPort"
Write-Host "  * 3D Digital Twin / Web   : 3000"

# ------------------------------------------------------------------------------
# 2. Directory Structure
# ------------------------------------------------------------------------------
Write-Host "==> Ensuring project folder structure exists..." -ForegroundColor Cyan
$dirsToCreate = @(
    "$ProjectDir\zigbee2mqtt\data",
    "$ProjectDir\homeassistant\config",
    "$ProjectDir\homeassistant\config\themes",
    "$ProjectDir\app",
    "$ProjectDir\app\public"
)
foreach ($dir in $dirsToCreate) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
}

# ------------------------------------------------------------------------------
# 3. Zigbee2MQTT Configuration
# ------------------------------------------------------------------------------
$z2mConfig = @"
homeassistant:
  enabled: true
permit_join: true
mqtt:
  base_topic: zigbee2mqtt
  server: 'mqtt://emqx:1883'
serial:
  port: null
frontend:
  port: 8080
  host: 0.0.0.0
advanced:
  log_level: info
"@
[System.IO.File]::WriteAllText("$ProjectDir\zigbee2mqtt\data\configuration.yaml", $z2mConfig, $Utf8NoBom)

# ------------------------------------------------------------------------------
# 4. Home Assistant Configuration
# ------------------------------------------------------------------------------
$haConfig = @"
default_config:

frontend:
  themes: !include_dir_merge_named themes

http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 127.0.0.1
    - 172.16.0.0/12
    - 192.168.0.0/16
    - 10.0.0.0/8

mqtt:
  sensor:
    - name: "Living Room Temperature"
      unique_id: "living_room_temperature"
      state_topic: "zigbee2mqtt/living_room/temperature"
      value_template: "{{ value_json.value }}"
      unit_of_measurement: "$degC"
      device_class: "temperature"
    - name: "Living Room Humidity"
      unique_id: "living_room_humidity"
      state_topic: "zigbee2mqtt/living_room/humidity"
      value_template: "{{ value_json.value }}"
      unit_of_measurement: "%"
      device_class: "humidity"
    - name: "Living Room CO2"
      unique_id: "living_room_co2"
      state_topic: "zigbee2mqtt/living_room/co2"
      value_template: "{{ value_json.value }}"
      unit_of_measurement: "ppm"
      device_class: "carbon_dioxide"
    - name: "Kitchen Temperature"
      unique_id: "kitchen_temperature"
      state_topic: "zigbee2mqtt/kitchen/temperature"
      value_template: "{{ value_json.value }}"
      unit_of_measurement: "$degC"
      device_class: "temperature"
    - name: "Bedroom Temperature"
      unique_id: "bedroom_temperature"
      state_topic: "zigbee2mqtt/bedroom/temperature"
      value_template: "{{ value_json.value }}"
      unit_of_measurement: "$degC"
      device_class: "temperature"
    - name: "Office Temperature"
      unique_id: "office_temperature"
      state_topic: "zigbee2mqtt/office/temperature"
      value_template: "{{ value_json.value }}"
      unit_of_measurement: "$degC"
      device_class: "temperature"
  binary_sensor:
    - name: "Living Room Motion"
      unique_id: "living_room_motion"
      state_topic: "zigbee2mqtt/living_room/motion"
      value_template: "{{ 'ON' if value_json.value == 1 else 'OFF' }}"
      device_class: "motion"
    - name: "Kitchen Smoke"
      unique_id: "kitchen_smoke"
      state_topic: "zigbee2mqtt/kitchen/smoke"
      value_template: "{{ 'ON' if value_json.value == 1 else 'OFF' }}"
      device_class: "smoke"
    - name: "Bedroom Motion"
      unique_id: "bedroom_motion"
      state_topic: "zigbee2mqtt/bedroom/motion"
      value_template: "{{ 'ON' if value_json.value == 1 else 'OFF' }}"
      device_class: "motion"
    - name: "Office Motion"
      unique_id: "office_motion"
      state_topic: "zigbee2mqtt/office/motion"
      value_template: "{{ 'ON' if value_json.value == 1 else 'OFF' }}"
      device_class: "motion"

automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml
"@
[System.IO.File]::WriteAllText("$ProjectDir\homeassistant\config\configuration.yaml", $haConfig, $Utf8NoBom)

if (-not (Test-Path "$ProjectDir\homeassistant\config\automations.yaml")) {
    New-Item -ItemType File -Force -Path "$ProjectDir\homeassistant\config\automations.yaml" | Out-Null
}
if (-not (Test-Path "$ProjectDir\homeassistant\config\scripts.yaml")) {
    New-Item -ItemType File -Force -Path "$ProjectDir\homeassistant\config\scripts.yaml" | Out-Null
}
if (-not (Test-Path "$ProjectDir\homeassistant\config\scenes.yaml")) {
    New-Item -ItemType File -Force -Path "$ProjectDir\homeassistant\config\scenes.yaml" | Out-Null
}

# Auto-configure MQTT Integration with EMQX (only if not configured already)
if (-not (Test-Path "$ProjectDir\homeassistant\config\.storage\core.config_entries")) {
    New-Item -ItemType Directory -Force -Path "$ProjectDir\homeassistant\config\.storage" | Out-Null
    $haConfigEntries = @'
{
  "version": 1,
  "minor_version": 1,
  "key": "core.config_entries",
  "data": {
    "entries": [
      {
        "entry_id": "01J8MQTTBROKERCONFIGENTRY001",
        "version": 1,
        "minor_version": 1,
        "domain": "mqtt",
        "title": "emqx",
        "data": {
          "broker": "emqx",
          "port": 1883,
          "discovery": true,
          "discovery_prefix": "homeassistant"
        },
        "options": {},
        "pref_disable_new_entities": false,
        "pref_disable_polling": false,
        "source": "user",
        "unique_id": null,
        "disabled_by": null
      }
    ]
  }
}
'@
    [System.IO.File]::WriteAllText("$ProjectDir\homeassistant\config\.storage\core.config_entries", $haConfigEntries, $Utf8NoBom)
}

# ------------------------------------------------------------------------------
# 5. Go Module Definition (go.mod)
# ------------------------------------------------------------------------------
$goMod = @'
module smarthouse-app

go 1.22

require (
	github.com/eclipse/paho.mqtt.golang v1.4.3
	github.com/gorilla/websocket v1.5.1
)

require (
	golang.org/x/net v0.21.0 // indirect
	golang.org/x/sync v0.1.0 // indirect
)
'@
[System.IO.File]::WriteAllText("$ProjectDir\app\go.mod", $goMod, $Utf8NoBom)

# ------------------------------------------------------------------------------
# 6. Backend App (Go Native Engine): Telemetry, Persistent Events & Zabbix 7.0 Complete Auto-Setup
# ------------------------------------------------------------------------------
$appMainGo = @'
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"math/rand"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	mqtt "github.com/eclipse/paho.mqtt.golang"
	"github.com/gorilla/websocket"
)

type Room string

const (
	LivingRoom Room = "living_room"
	Kitchen    Room = "kitchen"
	Bedroom    Room = "bedroom"
	Office     Room = "office"
)

var Rooms = []Room{LivingRoom, Kitchen, Bedroom, Office}

type RoomState struct {
	Temperature       float64 `json:"temperature"`
	Humidity          float64 `json:"humidity"`
	CO2               int     `json:"co2"`
	Motion            int     `json:"motion"`
	Smoke             int     `json:"smoke"`
	LastTempTimestamp int64   `json:"lastTempTimestamp"`
	PrevTemperature   float64 `json:"prevTemperature"`
}

type FireAlarmSubsystem struct {
	Active int    `json:"active"`
	Room   string `json:"room"`
	Reason string `json:"reason"`
}

type BurglarAlarmSubsystem struct {
	Active        int      `json:"active"`
	DetectedRooms []string `json:"detectedRooms"`
}

type VentilationSubsystem struct {
	Level       int     `json:"level"`
	TargetRpm   int     `json:"targetRpm"`
	MaxCo2      int     `json:"maxCo2"`
	AvgHumidity float64 `json:"avgHumidity"`
}

type HVACSubsystem struct {
	HeatingActive bool    `json:"heatingActive"`
	CoolingActive bool    `json:"coolingActive"`
	TargetTemp    float64 `json:"targetTemp"`
}

type Subsystems struct {
	AlarmArmed   bool                  `json:"alarmArmed"`
	FireAlarm    FireAlarmSubsystem    `json:"fireAlarm"`
	BurglarAlarm BurglarAlarmSubsystem `json:"burglarAlarm"`
	Ventilation  VentilationSubsystem  `json:"ventilation"`
	HVAC         HVACSubsystem         `json:"hvac"`
}

type ActiveEvents struct {
	Fire       bool `json:"fire"`
	CO2Spike   bool `json:"co2_spike"`
	AlarmArmed bool `json:"alarmArmed"`
	Heating    bool `json:"heating"`
	Cooling    bool `json:"cooling"`
}

type BroadcastPayload struct {
	HouseState   map[Room]*RoomState `json:"houseState"`
	Subsystems   Subsystems          `json:"subsystems"`
	SensorStatus map[string]bool     `json:"sensorStatus"`
	ActiveEvents ActiveEvents        `json:"activeEvents"`
	Timestamp    int64               `json:"timestamp"`
}

type TelemetryMessage struct {
	Room       string  `json:"room"`
	SensorType string  `json:"sensorType"`
	Value      float64 `json:"value"`
	Timestamp  int64   `json:"timestamp,omitempty"`
}

var (
	stateMu sync.RWMutex

	houseState = map[Room]*RoomState{
		LivingRoom: {Temperature: 21.5, Humidity: 45, CO2: 600, Motion: 0, Smoke: 0, LastTempTimestamp: time.Now().UnixMilli(), PrevTemperature: 21.5},
		Kitchen:    {Temperature: 22.0, Humidity: 50, CO2: 650, Motion: 0, Smoke: 0, LastTempTimestamp: time.Now().UnixMilli(), PrevTemperature: 22.0},
		Bedroom:    {Temperature: 19.5, Humidity: 42, CO2: 550, Motion: 0, Smoke: 0, LastTempTimestamp: time.Now().UnixMilli(), PrevTemperature: 19.5},
		Office:     {Temperature: 21.0, Humidity: 44, CO2: 700, Motion: 0, Smoke: 0, LastTempTimestamp: time.Now().UnixMilli(), PrevTemperature: 21.0},
	}

	sensorStatus = map[string]bool{
		"living_room_pir":     true,
		"living_room_climate": true,
		"kitchen_smoke":       true,
		"kitchen_climate":     true,
		"bedroom_pir":         true,
		"bedroom_climate":     true,
		"office_pir":          true,
		"office_climate":      true,
	}

	simulatedFireActive     = false
	simulatedCo2SpikeActive = false

	subsystems = Subsystems{
		AlarmArmed:   true,
		FireAlarm:    FireAlarmSubsystem{Active: 0, Room: "none", Reason: "none"},
		BurglarAlarm: BurglarAlarmSubsystem{Active: 0, DetectedRooms: []string{}},
		Ventilation:  VentilationSubsystem{Level: 1, TargetRpm: 1200, MaxCo2: 700, AvgHumidity: 45.2},
		HVAC:         HVACSubsystem{HeatingActive: false, CoolingActive: false, TargetTemp: 21.0},
	}
)

func evaluateSubsystemsLocked() {
	var fireDetected bool
	fireRoom := "none"
	fireReason := "none"
	var motionRooms []string
	maxCo2 := 0
	var totalHumidity, totalTemp float64

	for _, r := range Rooms {
		state := houseState[r]
		totalHumidity += state.Humidity
		totalTemp += state.Temperature
		if state.CO2 > maxCo2 {
			maxCo2 = state.CO2
		}
		if state.Motion == 1 {
			motionRooms = append(motionRooms, string(r))
		}

		tempRate := state.Temperature - state.PrevTemperature
		if state.Smoke == 1 && (tempRate > 2.0 || state.Temperature > 32.0) {
			fireDetected = true
			fireRoom = string(r)
			fireReason = fmt.Sprintf("Smoke detected with rapid heat increase (+%.1f°C)", tempRate)
		} else if state.Temperature > 55.0 {
			fireDetected = true
			fireRoom = string(r)
			fireReason = fmt.Sprintf("Extreme heat threshold breached (%.1f°C)", state.Temperature)
		} else if state.Smoke == 1 {
			fireDetected = true
			fireRoom = string(r)
			fireReason = "Smoke detector triggered"
		}
	}

	fireActive := 0
	if fireDetected {
		fireActive = 1
	}
	subsystems.FireAlarm = FireAlarmSubsystem{
		Active: fireActive,
		Room:   fireRoom,
		Reason: fireReason,
	}

	burglarActive := 0
	if subsystems.AlarmArmed && len(motionRooms) > 0 {
		burglarActive = 1
	}
	subsystems.BurglarAlarm = BurglarAlarmSubsystem{
		Active:        burglarActive,
		DetectedRooms: motionRooms,
	}

	avgHumidity := math.Round((totalHumidity/float64(len(Rooms)))*10) / 10
	ventLevel := 1
	if maxCo2 > 1200 || avgHumidity > 65.0 {
		ventLevel = 3
	} else if maxCo2 > 800 || avgHumidity > 55.0 {
		ventLevel = 2
	}

	subsystems.Ventilation = VentilationSubsystem{
		Level:       ventLevel,
		TargetRpm:   ventLevel * 700,
		MaxCo2:      maxCo2,
		AvgHumidity: avgHumidity,
	}

	avgTemp := totalTemp / float64(len(Rooms))
	subsystems.HVAC = HVACSubsystem{
		TargetTemp:    21.0,
		HeatingActive: avgTemp < 20.0,
		CoolingActive: avgTemp > 22.5,
	}
}

// -----------------------------------------------------------------------------
// WebSocket Hub
// -----------------------------------------------------------------------------
var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

type WsHub struct {
	clients   map[*websocket.Conn]bool
	broadcast chan []byte
	mu        sync.Mutex
}

var hub = &WsHub{
	clients:   make(map[*websocket.Conn]bool),
	broadcast: make(chan []byte, 128),
}

func (h *WsHub) run() {
	for msg := range h.broadcast {
		h.mu.Lock()
		for client := range h.clients {
			err := client.WriteMessage(websocket.TextMessage, msg)
			if err != nil {
				client.Close()
				delete(h.clients, client)
			}
		}
		h.mu.Unlock()
	}
}

func (h *WsHub) register(conn *websocket.Conn) {
	h.mu.Lock()
	h.clients[conn] = true
	h.mu.Unlock()
}

func (h *WsHub) unregister(conn *websocket.Conn) {
	h.mu.Lock()
	delete(h.clients, conn)
	h.mu.Unlock()
}

func broadcastState() {
	stateMu.RLock()
	payload := BroadcastPayload{
		HouseState:   houseState,
		Subsystems:   subsystems,
		SensorStatus: sensorStatus,
		ActiveEvents: ActiveEvents{
			Fire:       simulatedFireActive,
			CO2Spike:   simulatedCo2SpikeActive,
			AlarmArmed: subsystems.AlarmArmed,
			Heating:    subsystems.HVAC.HeatingActive,
			Cooling:    subsystems.HVAC.CoolingActive,
		},
		Timestamp: time.Now().UnixMilli(),
	}
	stateMu.RUnlock()

	data, err := json.Marshal(payload)
	if err == nil {
		select {
		case hub.broadcast <- data:
		default:
		}
	}
}

// -----------------------------------------------------------------------------
// MQTT Integration
// -----------------------------------------------------------------------------
var mqttClient mqtt.Client

func initMqtt() {
	opts := mqtt.NewClientOptions()
	opts.AddBroker("tcp://emqx:1883")
	opts.SetClientID("smart-house-controller")
	opts.SetCleanSession(true)
	opts.SetAutoReconnect(true)

	opts.OnConnect = func(c mqtt.Client) {
		log.Println("[Broker Layer] Connected to EMQX Broker on port 1883.")
		token := c.Subscribe("zigbee2mqtt/+/+", 0, handleMqttMessage)
		token.Wait()
	}

	opts.OnConnectionLost = func(c mqtt.Client, err error) {
		log.Printf("[Broker Layer] MQTT connection lost: %v", err)
	}

	mqttClient = mqtt.NewClient(opts)
	for {
		if token := mqttClient.Connect(); token.Wait() && token.Error() == nil {
			break
		}
		time.Sleep(2 * time.Second)
	}

	// Simulation loop
	go func() {
		r := rand.New(rand.NewSource(time.Now().UnixNano()))
		ticker := time.NewTicker(2500 * time.Millisecond)
		defer ticker.Stop()

		for range ticker.C {
			stateMu.Lock()
			for _, rm := range Rooms {
				state := houseState[rm]
				if sensorStatus[fmt.Sprintf("%s_climate", rm)] {
					if !simulatedFireActive || rm != Kitchen {
						delta := (r.Float64()*0.3 - 0.15)
						state.Temperature = math.Round((state.Temperature+delta)*100) / 100
					}
					tPayload, _ := json.Marshal(TelemetryMessage{Room: string(rm), SensorType: "temperature", Value: state.Temperature})
					mqttClient.Publish(fmt.Sprintf("zigbee2mqtt/%s/temperature", rm), 0, false, tPayload)

					h := math.Round((45.0+(r.Float64()*6.0-3.0))*10) / 10
					state.Humidity = h
					hPayload, _ := json.Marshal(TelemetryMessage{Room: string(rm), SensorType: "humidity", Value: h})
					mqttClient.Publish(fmt.Sprintf("zigbee2mqtt/%s/humidity", rm), 0, false, hPayload)

					co2 := 550 + r.Intn(200)
					if rm == LivingRoom && simulatedCo2SpikeActive {
						co2 = 1450
					}
					state.CO2 = co2
					cPayload, _ := json.Marshal(TelemetryMessage{Room: string(rm), SensorType: "co2", Value: float64(co2)})
					mqttClient.Publish(fmt.Sprintf("zigbee2mqtt/%s/co2", rm), 0, false, cPayload)
				}

				if sensorStatus[fmt.Sprintf("%s_pir", rm)] {
					motion := 0
					if r.Float64() > 0.90 {
						motion = 1
					}
					state.Motion = motion
					mPayload, _ := json.Marshal(TelemetryMessage{Room: string(rm), SensorType: "motion", Value: float64(motion)})
					mqttClient.Publish(fmt.Sprintf("zigbee2mqtt/%s/motion", rm), 0, false, mPayload)
				} else {
					state.Motion = 0
				}

				if rm == Kitchen {
					if !sensorStatus["kitchen_smoke"] {
						houseState[Kitchen].Smoke = 0
					} else if simulatedFireActive {
						houseState[Kitchen].Smoke = 1
					}
					sPayload, _ := json.Marshal(TelemetryMessage{Room: "kitchen", SensorType: "smoke", Value: float64(houseState[Kitchen].Smoke)})
					mqttClient.Publish("zigbee2mqtt/kitchen/smoke", 0, false, sPayload)
				}
			}

			evaluateSubsystemsLocked()
			stateMu.Unlock()

			broadcastState()
		}
	}()
}

func handleMqttMessage(c mqtt.Client, m mqtt.Message) {
	var msg TelemetryMessage
	if err := json.Unmarshal(m.Payload(), &msg); err != nil {
		return
	}

	stateMu.Lock()
	rm := Room(msg.Room)
	currentRoom, exists := houseState[rm]
	if !exists {
		stateMu.Unlock()
		return
	}

	switch msg.SensorType {
	case "temperature":
		currentRoom.PrevTemperature = currentRoom.Temperature
		currentRoom.Temperature = msg.Value
		currentRoom.LastTempTimestamp = time.Now().UnixMilli()
	case "humidity":
		currentRoom.Humidity = msg.Value
	case "co2":
		currentRoom.CO2 = int(msg.Value)
	case "motion":
		if sensorStatus[fmt.Sprintf("%s_pir", rm)] {
			currentRoom.Motion = int(msg.Value)
		}
	case "smoke":
		if sensorStatus[fmt.Sprintf("%s_smoke", rm)] {
			currentRoom.Smoke = int(msg.Value)
		}
	}

	evaluateSubsystemsLocked()
	stateMu.Unlock()

	broadcastState()
}

// -----------------------------------------------------------------------------
// HTTP REST & WebSocket Server
// -----------------------------------------------------------------------------
func handleHttp(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type")

	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	path := r.URL.Path

	// Check for WebSocket upgrade
	if r.Header.Get("Upgrade") == "websocket" || path == "/ws" {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			log.Printf("WebSocket upgrade failed: %v", err)
			return
		}
		hub.register(conn)

		// Send initial state immediately
		stateMu.RLock()
		initPayload := BroadcastPayload{
			HouseState:   houseState,
			Subsystems:   subsystems,
			SensorStatus: sensorStatus,
			ActiveEvents: ActiveEvents{
				Fire:       simulatedFireActive,
				CO2Spike:   simulatedCo2SpikeActive,
				AlarmArmed: subsystems.AlarmArmed,
				Heating:    subsystems.HVAC.HeatingActive,
				Cooling:    subsystems.HVAC.CoolingActive,
			},
			Timestamp: time.Now().UnixMilli(),
		}
		stateMu.RUnlock()
		if initData, err := json.Marshal(initPayload); err == nil {
			_ = conn.WriteMessage(websocket.TextMessage, initData)
		}

		go func() {
			defer func() {
				hub.unregister(conn)
				conn.Close()
			}()
			for {
				if _, _, err := conn.ReadMessage(); err != nil {
					break
				}
			}
		}()
		return
	}

	switch path {
	case "/api/toggle-sensor":
		id := r.URL.Query().Get("id")
		stateMu.Lock()
		if val, exists := sensorStatus[id]; exists {
			sensorStatus[id] = !val
			evaluateSubsystemsLocked()
			resp := map[string]interface{}{"id": id, "enabled": sensorStatus[id]}
			stateMu.Unlock()
			broadcastState()

			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(resp)
			return
		}
		stateMu.Unlock()
		http.Error(w, "Invalid sensor id", http.StatusBadRequest)
		return

	case "/api/event":
		evtType := r.URL.Query().Get("type")
		stateMu.Lock()
		switch evtType {
		case "fire":
			simulatedFireActive = true
			houseState[Kitchen].Smoke = 1
			houseState[Kitchen].PrevTemperature = houseState[Kitchen].Temperature
			houseState[Kitchen].Temperature = 65.0
			sPay, _ := json.Marshal(TelemetryMessage{Room: "kitchen", SensorType: "smoke", Value: 1})
			tPay, _ := json.Marshal(TelemetryMessage{Room: "kitchen", SensorType: "temperature", Value: 65.0})
			go func() {
				if mqttClient != nil && mqttClient.IsConnected() {
					mqttClient.Publish("zigbee2mqtt/kitchen/smoke", 0, false, sPay)
					mqttClient.Publish("zigbee2mqtt/kitchen/temperature", 0, false, tPay)
				}
			}()

		case "clear_fire":
			simulatedFireActive = false
			houseState[Kitchen].Smoke = 0
			houseState[Kitchen].PrevTemperature = 22.0
			houseState[Kitchen].Temperature = 22.0
			sPay, _ := json.Marshal(TelemetryMessage{Room: "kitchen", SensorType: "smoke", Value: 0})
			tPay, _ := json.Marshal(TelemetryMessage{Room: "kitchen", SensorType: "temperature", Value: 22.0})
			go func() {
				if mqttClient != nil && mqttClient.IsConnected() {
					mqttClient.Publish("zigbee2mqtt/kitchen/smoke", 0, false, sPay)
					mqttClient.Publish("zigbee2mqtt/kitchen/temperature", 0, false, tPay)
				}
			}()

		case "co2_spike":
			simulatedCo2SpikeActive = !simulatedCo2SpikeActive
			co2Val := 600
			if simulatedCo2SpikeActive {
				co2Val = 1450
			}
			houseState[LivingRoom].CO2 = co2Val
			cPay, _ := json.Marshal(TelemetryMessage{Room: "living_room", SensorType: "co2", Value: float64(co2Val)})
			go func() {
				if mqttClient != nil && mqttClient.IsConnected() {
					mqttClient.Publish("zigbee2mqtt/living_room/co2", 0, false, cPay)
				}
			}()

		case "freeze":
			for _, rm := range Rooms {
				houseState[rm].PrevTemperature = houseState[rm].Temperature
				houseState[rm].Temperature = 16.0
				p, _ := json.Marshal(TelemetryMessage{Room: string(rm), SensorType: "temperature", Value: 16.0})
				tTopic := fmt.Sprintf("zigbee2mqtt/%s/temperature", rm)
				go func(top string, payload []byte) {
					if mqttClient != nil && mqttClient.IsConnected() {
						mqttClient.Publish(top, 0, false, payload)
					}
				}(tTopic, p)
			}

		case "heatwave":
			for _, rm := range Rooms {
				houseState[rm].PrevTemperature = houseState[rm].Temperature
				houseState[rm].Temperature = 28.5
				p, _ := json.Marshal(TelemetryMessage{Room: string(rm), SensorType: "temperature", Value: 28.5})
				tTopic := fmt.Sprintf("zigbee2mqtt/%s/temperature", rm)
				go func(top string, payload []byte) {
					if mqttClient != nil && mqttClient.IsConnected() {
						mqttClient.Publish(top, 0, false, payload)
					}
				}(tTopic, p)
			}

		case "toggle_arm":
			subsystems.AlarmArmed = !subsystems.AlarmArmed
		}

		evaluateSubsystemsLocked()
		stateMu.Unlock()
		broadcastState()

		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok", "event": evtType})
		return

	case "/api/metrics":
		stateMu.RLock()
		flatMetrics := map[string]float64{
			"living_room_temp":     houseState[LivingRoom].Temperature,
			"living_room_humidity": houseState[LivingRoom].Humidity,
			"living_room_co2":      float64(houseState[LivingRoom].CO2),
			"living_room_motion":   float64(houseState[LivingRoom].Motion),
			"living_room_smoke":    float64(houseState[LivingRoom].Smoke),

			"kitchen_temp":     houseState[Kitchen].Temperature,
			"kitchen_humidity": houseState[Kitchen].Humidity,
			"kitchen_co2":      float64(houseState[Kitchen].CO2),
			"kitchen_motion":   float64(houseState[Kitchen].Motion),
			"kitchen_smoke":    float64(houseState[Kitchen].Smoke),

			"bedroom_temp":     houseState[Bedroom].Temperature,
			"bedroom_humidity": houseState[Bedroom].Humidity,
			"bedroom_co2":      float64(houseState[Bedroom].CO2),
			"bedroom_motion":   float64(houseState[Bedroom].Motion),
			"bedroom_smoke":    float64(houseState[Bedroom].Smoke),

			"office_temp":     houseState[Office].Temperature,
			"office_humidity": houseState[Office].Humidity,
			"office_co2":      float64(houseState[Office].CO2),
			"office_motion":   float64(houseState[Office].Motion),
			"office_smoke":    float64(houseState[Office].Smoke),

			"fire_alarm_active":    float64(subsystems.FireAlarm.Active),
			"burglar_alarm_active": float64(subsystems.BurglarAlarm.Active),
			"ventilation_level":    float64(subsystems.Ventilation.Level),
			"ventilation_max_co2":  float64(subsystems.Ventilation.MaxCo2),
			"hvac_heating_active":  boolToFloat(subsystems.HVAC.HeatingActive),
			"hvac_cooling_active":  boolToFloat(subsystems.HVAC.CoolingActive),
		}
		stateMu.RUnlock()

		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(flatMetrics)
		return

	default:
		// Serve static 3D Digital Twin UI
		filePath := filepath.Join("public", "index.html")
		if path != "/" && path != "/index.html" {
			cleanPath := strings.TrimPrefix(path, "/")
			candidate := filepath.Join("public", cleanPath)
			if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
				filePath = candidate
			}
		}

		data, err := os.ReadFile(filePath)
		if err != nil {
			http.Error(w, "Failed to load 3D Digital Twin UI", http.StatusInternalServerError)
			return
		}
		if strings.HasSuffix(filePath, ".html") {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(data)
	}
}

func boolToFloat(b bool) float64 {
	if b {
		return 1.0
	}
	return 0.0
}

// -----------------------------------------------------------------------------
// Zabbix 7.0 Auto-Provisioning
// -----------------------------------------------------------------------------
type ZabbixRpcRequest struct {
	JsonRpc string      `json:"jsonrpc"`
	Method  string      `json:"method"`
	Params  interface{} `json:"params"`
	ID      int64       `json:"id"`
}

type ZabbixRpcResponse struct {
	JsonRpc string          `json:"jsonrpc"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   interface{}     `json:"error,omitempty"`
	ID      int64           `json:"id"`
}

func zabbixApiCall(method string, params interface{}, auth string) (*ZabbixRpcResponse, error) {
	reqBody := ZabbixRpcRequest{
		JsonRpc: "2.0",
		Method:  method,
		Params:  params,
		ID:      time.Now().UnixNano(),
	}
	data, err := json.Marshal(reqBody)
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequest(http.MethodPost, "http://zabbix-web:8080/api_jsonrpc.php", bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json-rpc")
	if auth != "" {
		req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", auth))
	}

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var rpcResp ZabbixRpcResponse
	if err := json.NewDecoder(resp.Body).Decode(&rpcResp); err != nil {
		return nil, err
	}
	return &rpcResp, nil
}

func initZabbixProvisioning() {
	time.Sleep(6 * time.Second)
	log.Println("[Zabbix Setup] Connecting to Zabbix API...")

	var authToken string
	for {
		resp, err := zabbixApiCall("user.login", map[string]string{
			"username": "Admin",
			"password": "zabbix",
		}, "")
		if err == nil && resp != nil && len(resp.Result) > 0 {
			var token string
			if err := json.Unmarshal(resp.Result, &token); err == nil && token != "" {
				authToken = token
				log.Println("[Zabbix Setup] Authenticated to Zabbix via Bearer Token.")
				break
			}
		}
		time.Sleep(5 * time.Second)
	}

	// 1. Host Group "Smart House"
	var groupId string
	groupRes, err := zabbixApiCall("hostgroup.get", map[string]interface{}{
		"filter": map[string][]string{"name": {"Smart House"}},
	}, authToken)
	if err == nil && groupRes != nil {
		var groups []struct {
			GroupID string `json:"groupid"`
		}
		_ = json.Unmarshal(groupRes.Result, &groups)
		if len(groups) > 0 {
			groupId = groups[0].GroupID
		}
	}
	if groupId == "" {
		createRes, err := zabbixApiCall("hostgroup.create", map[string]string{"name": "Smart House"}, authToken)
		if err == nil && createRes != nil {
			var created struct {
				GroupIDs []string `json:"groupids"`
			}
			_ = json.Unmarshal(createRes.Result, &created)
			if len(created.GroupIDs) > 0 {
				groupId = created.GroupIDs[0]
			}
		}
	}

	// 2. Host "Smart-House-System"
	var hostId string
	hostRes, err := zabbixApiCall("host.get", map[string]interface{}{
		"filter": map[string][]string{"host": {"Smart-House-System"}},
	}, authToken)
	if err == nil && hostRes != nil {
		var hosts []struct {
			HostID string `json:"hostid"`
		}
		_ = json.Unmarshal(hostRes.Result, &hosts)
		if len(hosts) > 0 {
			hostId = hosts[0].HostID
		}
	}
	if hostId == "" && groupId != "" {
		createHostRes, err := zabbixApiCall("host.create", map[string]interface{}{
			"host": "Smart-House-System",
			"interfaces": []map[string]interface{}{
				{"type": 1, "main": 1, "useip": 0, "dns": "app", "ip": "", "port": "3000"},
			},
			"groups": []map[string]string{{"groupid": groupId}},
		}, authToken)
		if err == nil && createHostRes != nil {
			var created struct {
				HostIDs []string `json:"hostids"`
			}
			_ = json.Unmarshal(createHostRes.Result, &created)
			if len(created.HostIDs) > 0 {
				hostId = created.HostIDs[0]
			}
		}
	}

	// 3. Host "Docker-Desktop-Host" (for zabbix-agent2)
	agentHostRes, err := zabbixApiCall("host.get", map[string]interface{}{
		"filter": map[string][]string{"host": {"Docker-Desktop-Host"}},
	}, authToken)
	var agentHostId string
	if err == nil && agentHostRes != nil {
		var hosts []struct {
			HostID string `json:"hostid"`
		}
		_ = json.Unmarshal(agentHostRes.Result, &hosts)
		if len(hosts) > 0 {
			agentHostId = hosts[0].HostID
		}
	}
	if agentHostId == "" && groupId != "" {
		_, _ = zabbixApiCall("host.create", map[string]interface{}{
			"host": "Docker-Desktop-Host",
			"interfaces": []map[string]interface{}{
				{"type": 1, "main": 1, "useip": 0, "dns": "zabbix-agent2", "ip": "", "port": "10050"},
			},
			"groups": []map[string]string{{"groupid": groupId}},
		}, authToken)
		log.Println("[Zabbix Setup] Provisioned Docker-Desktop-Host for active agent checks.")
	}

	// 4. Master HTTP Agent Item "smarthouse.metrics"
	if hostId == "" {
		log.Println("[Zabbix Setup] Host ID is empty, skipping item creation.")
		return
	}

	var masterItemId string
	masterItemRes, err := zabbixApiCall("item.get", map[string]interface{}{
		"hostids": hostId,
		"filter":  map[string][]string{"key_": {"smarthouse.metrics"}},
	}, authToken)
	if err == nil && masterItemRes != nil {
		var items []struct {
			ItemID string `json:"itemid"`
		}
		_ = json.Unmarshal(masterItemRes.Result, &items)
		if len(items) > 0 {
			masterItemId = items[0].ItemID
		}
	}
	if masterItemId == "" {
		mItem, err := zabbixApiCall("item.create", map[string]interface{}{
			"name":       "Smart House Telemetry Master Poll",
			"key_":       "smarthouse.metrics",
			"hostid":     hostId,
			"type":       19,
			"url":        "http://app:3000/api/metrics",
			"value_type": 4,
			"delay":      "3s",
		}, authToken)
		if err == nil && mItem != nil {
			var created struct {
				ItemIDs []string `json:"itemids"`
			}
			_ = json.Unmarshal(mItem.Result, &created)
			if len(created.ItemIDs) > 0 {
				masterItemId = created.ItemIDs[0]
			}
		}
	}

	// 5. Dependent Items
	type MetricDef struct {
		Key       string
		Name      string
		ValueType int
		Unit      string
	}

	var metricsToCreate []MetricDef
	for _, r := range Rooms {
		upper := strings.ToUpper(strings.ReplaceAll(string(r), "_", " "))
		metricsToCreate = append(metricsToCreate,
			MetricDef{Key: fmt.Sprintf("%s_temp", r), Name: fmt.Sprintf("%s Temperature", upper), ValueType: 0, Unit: "°C"},
			MetricDef{Key: fmt.Sprintf("%s_humidity", r), Name: fmt.Sprintf("%s Humidity", upper), ValueType: 0, Unit: "%"},
			MetricDef{Key: fmt.Sprintf("%s_co2", r), Name: fmt.Sprintf("%s CO2", upper), ValueType: 3, Unit: "ppm"},
			MetricDef{Key: fmt.Sprintf("%s_motion", r), Name: fmt.Sprintf("%s Motion", upper), ValueType: 3, Unit: ""},
			MetricDef{Key: fmt.Sprintf("%s_smoke", r), Name: fmt.Sprintf("%s Smoke", upper), ValueType: 3, Unit: ""},
		)
	}
	metricsToCreate = append(metricsToCreate,
		MetricDef{Key: "fire_alarm_active", Name: "Fire Alarm Status", ValueType: 3, Unit: ""},
		MetricDef{Key: "burglar_alarm_active", Name: "Burglar Alarm Status", ValueType: 3, Unit: ""},
		MetricDef{Key: "ventilation_level", Name: "Ventilation Stage", ValueType: 3, Unit: "Stage"},
		MetricDef{Key: "ventilation_max_co2", Name: "Max CO2 Reading", ValueType: 3, Unit: "ppm"},
		MetricDef{Key: "hvac_heating_active", Name: "Heating System Active", ValueType: 3, Unit: ""},
		MetricDef{Key: "hvac_cooling_active", Name: "Cooling System Active", ValueType: 3, Unit: ""},
	)

	for _, m := range metricsToCreate {
		itemRes, err := zabbixApiCall("item.get", map[string]interface{}{
			"hostids": hostId,
			"filter":  map[string][]string{"key_": {m.Key}},
		}, authToken)
		var existingItems []struct {
			ItemID string `json:"itemid"`
		}
		if err == nil && itemRes != nil {
			_ = json.Unmarshal(itemRes.Result, &existingItems)
		}
		if len(existingItems) == 0 && masterItemId != "" {
			_, _ = zabbixApiCall("item.create", map[string]interface{}{
				"name":          m.Name,
				"key_":          m.Key,
				"hostid":        hostId,
				"type":          18,
				"master_itemid": masterItemId,
				"value_type":    m.ValueType,
				"units":         m.Unit,
				"preprocessing": []map[string]string{
					{"type": "12", "params": fmt.Sprintf("$.%s", m.Key), "error_handler": "1", "error_handler_params": ""},
				},
			}, authToken)
		}
	}

	// 6. Triggers
	triggers := []struct {
		Description string
		Expression  string
		Priority    int
	}{
		{"[CRITICAL FIRE] Fire alarm triggered in house zone", "last(/Smart-House-System/fire_alarm_active)=1", 5},
		{"[SECURITY] Burglar alarm active in armed mode", "last(/Smart-House-System/burglar_alarm_active)=1", 4},
		{"[AIR QUALITY] Dangerous CO2 concentration detected (>1000 ppm)", "last(/Smart-House-System/ventilation_max_co2)>1000", 3},
		{"[CLIMATE] Low temperature warning (<18°C)", "last(/Smart-House-System/living_room_temp)<18", 2},
		{"[CLIMATE] High temperature warning (>27°C)", "last(/Smart-House-System/kitchen_temp)>27", 2},
		{"[HVAC] Heating system currently active", "last(/Smart-House-System/hvac_heating_active)=1", 1},
	}

	for _, t := range triggers {
		trigRes, err := zabbixApiCall("trigger.get", map[string]interface{}{
			"filter": map[string][]string{"description": {t.Description}},
		}, authToken)
		var existingTrigs []struct {
			TriggerID string `json:"triggerid"`
		}
		if err == nil && trigRes != nil {
			_ = json.Unmarshal(trigRes.Result, &existingTrigs)
		}
		if len(existingTrigs) == 0 {
			_, _ = zabbixApiCall("trigger.create", map[string]interface{}{
				"description": t.Description,
				"expression":  t.Expression,
				"priority":    t.Priority,
			}, authToken)
		}
	}

	log.Println("[Zabbix Setup] Host, items, agent host, and all active triggers successfully provisioned.")
}

func main() {
	go hub.run()
	go initMqtt()
	go initZabbixProvisioning()

	http.HandleFunc("/", handleHttp)

	log.Println("[Application Layer] Web, WebSocket, and Zabbix Metrics running on port 3000 (Go Native Engine)")
	if err := http.ListenAndServe(":3000", nil); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
'@
[System.IO.File]::WriteAllText("$ProjectDir\app\main.go", $appMainGo, $Utf8NoBom)

# ------------------------------------------------------------------------------
# 7. 3D Digital Twin UI
# ------------------------------------------------------------------------------
$appIndexHtml = @'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Smart House 3D Digital Twin - Environmental & Physics Engine</title>
  <style>
    * { box-sizing: border-box; }
    body { margin: 0; overflow: hidden; background: #0f172a; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", sans-serif; user-select: none; }
    
    #vignette-overlay {
      position: absolute; inset: 0; pointer-events: none; z-index: 5;
      transition: box-shadow 0.8s ease, background 0.8s ease;
    }
    .cold-vignette {
      box-shadow: inset 0 0 100px 30px rgba(56, 189, 248, 0.45), inset 0 0 200px rgba(186, 230, 253, 0.2);
    }
    .heat-vignette {
      box-shadow: inset 0 0 120px 40px rgba(239, 68, 68, 0.45), inset 0 0 220px rgba(249, 115, 22, 0.25);
    }
    .co2-vignette {
      box-shadow: inset 0 0 110px 35px rgba(234, 179, 8, 0.4), inset 0 0 210px rgba(163, 230, 53, 0.25);
    }

    #hud {
      position: absolute; top: 16px; left: 16px; width: 330px;
      background: rgba(15, 23, 42, 0.92); border: 1px solid rgba(255, 255, 255, 0.15);
      border-radius: 12px; padding: 16px; color: #fff; box-shadow: 0 10px 30px rgba(0,0,0,0.7);
      backdrop-filter: blur(8px); z-index: 10;
    }
    #event-panel {
      position: absolute; top: 16px; right: 16px; width: 320px;
      background: rgba(15, 23, 42, 0.94); border: 1px solid rgba(255, 255, 255, 0.16);
      border-radius: 12px; padding: 14px; color: #fff; box-shadow: 0 10px 30px rgba(0,0,0,0.7);
      backdrop-filter: blur(8px); z-index: 10;
    }
    h2, h3 { margin: 0 0 8px 0; font-size: 1.05rem; color: #38bdf8; display: flex; justify-content: space-between; align-items: center; }
    h3 { font-size: 0.92rem; border-bottom: 1px solid rgba(255,255,255,0.1); padding-bottom: 6px; }
    .room-badge { background: #1e293b; color: #38bdf8; padding: 4px 10px; border-radius: 6px; font-size: 0.82rem; font-weight: bold; border: 1px solid #334155; }
    
    .status-row { display: flex; gap: 6px; margin: 10px 0; flex-wrap: wrap; }
    .badge { padding: 4px 8px; border-radius: 6px; font-weight: bold; font-size: 0.72rem; text-transform: uppercase; }
    .badge-ok { background: #065f46; color: #6ee7b7; }
    .badge-warn { background: #92400e; color: #fde68a; }
    .badge-danger { background: #991b1b; color: #fca5a5; animation: blink 1s infinite alternate; }
    @keyframes blink { from { opacity: 0.7; } to { opacity: 1; } }
    
    .sensor-grid { background: rgba(255,255,255,0.03); border-radius: 8px; padding: 10px; margin-top: 8px; border: 1px solid rgba(255,255,255,0.06); }
    .sensor-item { display: flex; justify-content: space-between; font-size: 0.82rem; margin: 4px 0; }
    .val { font-weight: bold; color: #38bdf8; }

    #debuff-card {
      margin-top: 8px; padding: 8px 12px; border-radius: 8px; background: rgba(0,0,0,0.4);
      display: flex; align-items: center; justify-content: space-between; font-size: 0.8rem; font-weight: bold;
    }
    .state-normal { border-left: 4px solid #22c55e; color: #4ade80; }
    .state-cold { border-left: 4px solid #38bdf8; color: #7dd3fc; animation: shiver-text 0.2s infinite; }
    .state-hot { border-left: 4px solid #ef4444; color: #f87171; }
    .state-co2 { border-left: 4px solid #eab308; color: #fde047; animation: cough-text 0.4s infinite; }
    @keyframes shiver-text { 0% { transform: translateX(0); } 50% { transform: translateX(1px); } 100% { transform: translateX(-1px); } }
    @keyframes cough-text { 0% { transform: translateY(0); } 50% { transform: translateY(2px); } 100% { transform: translateY(0); } }

    #interact-prompt {
      display: none; position: absolute; top: 45%; left: 50%; transform: translate(-50%, -50%);
      background: rgba(15, 23, 42, 0.95); border: 2px solid #38bdf8; color: #fff;
      padding: 12px 24px; border-radius: 30px; font-size: 0.95rem; font-weight: bold;
      box-shadow: 0 0 25px rgba(56, 189, 248, 0.5); z-index: 30; pointer-events: none;
      text-align: center;
    }
    #interact-prompt span.key { background: #38bdf8; color: #0f172a; padding: 3px 8px; border-radius: 6px; margin-right: 6px; }

    #unstuck-toast {
      display: none; position: absolute; top: 22%; left: 50%; transform: translate(-50%, -50%);
      background: rgba(34, 197, 94, 0.95); color: #0f172a; padding: 8px 20px;
      border-radius: 20px; font-weight: bold; font-size: 0.85rem; z-index: 40;
      box-shadow: 0 0 20px rgba(34, 197, 94, 0.6); pointer-events: none;
    }

    #action-status {
      display: none; font-size: 0.76rem; font-weight: bold; padding: 6px 10px;
      margin-bottom: 8px; border-radius: 6px; background: rgba(56, 189, 248, 0.15);
      border: 1px solid #38bdf8; color: #38bdf8; text-align: center;
      transition: opacity 1s ease-out; opacity: 1;
    }

    .btn-grid { display: flex; flex-direction: column; gap: 6px; }
    .btn-evt {
      display: flex; justify-content: space-between; align-items: center;
      padding: 8px 12px; border: 1px solid rgba(255,255,255,0.12); border-radius: 6px;
      background: #1e293b; color: #cbd5e1; font-size: 0.78rem; font-weight: 600;
      cursor: pointer; text-align: left; transition: all 0.25s ease;
    }
    .btn-evt:hover { background: #334155; border-color: #38bdf8; color: #fff; }
    .tag-icon { font-size: 0.7rem; font-weight: bold; padding: 2px 6px; border-radius: 4px; background: rgba(255,255,255,0.08); margin-right: 8px; }

    .btn-evt.btn-persistent-active {
      background: #0284c7 !important; border-color: #38bdf8 !important; color: #ffffff !important;
      box-shadow: 0 0 12px rgba(56, 189, 248, 0.45);
    }
    .btn-evt.btn-persistent-co2 {
      background: #a16207 !important; border-color: #eab308 !important; color: #ffffff !important;
      box-shadow: 0 0 14px rgba(234, 179, 8, 0.5);
    }
    .btn-evt.btn-persistent-fire {
      background: #b91c1c !important; border-color: #ef4444 !important; color: #ffffff !important;
      box-shadow: 0 0 14px rgba(239, 68, 68, 0.6); animation: blink 1.2s infinite alternate;
    }
    .btn-evt.btn-just-activated {
      background: #059669 !important; border-color: #34d399 !important; color: #ffffff !important;
      box-shadow: 0 0 15px rgba(52, 211, 153, 0.6); transition: none;
    }
    .btn-evt.btn-fading-out {
      background: #1e293b; border-color: rgba(255,255,255,0.12); color: #cbd5e1;
      box-shadow: none; transition: all 1.8s cubic-bezier(0.4, 0, 0.2, 1);
    }

    .state-indicator { font-size: 0.68rem; font-weight: bold; text-transform: uppercase; padding: 2px 6px; border-radius: 4px; background: rgba(0,0,0,0.3); }

    #instructions {
      position: absolute; bottom: 20px; left: 50%; transform: translateX(-50%);
      background: rgba(15, 23, 42, 0.88); border: 1px solid rgba(255, 255, 255, 0.12);
      padding: 8px 20px; border-radius: 20px; color: #94a3b8; font-size: 0.82rem; pointer-events: none; z-index: 10;
      white-space: nowrap;
    }
    #instructions span { color: #f8fafc; font-weight: bold; }
  </style>

  <script src="https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js"></script>
</head>
<body>
  <div id="vignette-overlay"></div>

  <div id="hud">
    <h2>
      <span>Digital Twin</span>
      <span id="current-room-name" class="room-badge">HALLWAY</span>
    </h2>
    <div class="status-row">
      <span id="status-fire" class="badge badge-ok">Fire: Normal</span>
      <span id="status-burglar" class="badge badge-ok">Alarm: Armed</span>
      <span id="status-vent" class="badge badge-ok">Vent: Stage 1</span>
      <span id="status-hvac" class="badge badge-ok">HVAC: Idle</span>
    </div>

    <div class="sensor-grid">
      <div style="font-size:0.72rem; color:#94a3b8; font-weight:bold; margin-bottom:4px; text-transform:uppercase;">Room Telemetry:</div>
      <div class="sensor-item"><span>Temperature:</span><span id="disp-temp" class="val">--</span></div>
      <div class="sensor-item"><span>Humidity:</span><span id="disp-hum" class="val">--</span></div>
      <div class="sensor-item"><span>CO2 Level:</span><span id="disp-co2" class="val">--</span></div>
      <div class="sensor-item"><span>PIR Motion:</span><span id="disp-motion" class="val">--</span></div>
      <div class="sensor-item"><span>Smoke Detector:</span><span id="disp-smoke" class="val">--</span></div>
    </div>

    <div id="debuff-card" class="state-normal">
      <span>Player Condition:</span>
      <span id="player-condition-text">NORMAL</span>
    </div>
  </div>

  <div id="event-panel">
    <h3>Simulate Events</h3>
    <div id="action-status">Action applied</div>
    <div class="btn-grid">
      <button id="btn-fire" class="btn-evt" onclick="triggerEvent('fire', 'Kitchen Fire Simulation')">
        <span><span class="tag-icon">[FIRE]</span> Kitchen Fire & Smoke Spike</span>
        <span id="tag-fire" class="state-indicator">OFF</span>
      </button>

      <button id="btn-clear-fire" class="btn-evt" onclick="triggerEvent('clear_fire', 'Extinguish / Clear Fire')">
        <span><span class="tag-icon">[CLEAR]</span> Extinguish / Clear Fire</span>
        <span class="state-indicator">EXEC</span>
      </button>

      <button id="btn-co2" class="btn-evt" onclick="triggerEvent('co2_spike', 'Living Room CO2 Spike')">
        <span><span class="tag-icon">[CO2]</span> Living Room CO2 Spike</span>
        <span id="tag-co2" class="state-indicator">OFF</span>
      </button>

      <button id="btn-freeze" class="btn-evt" onclick="triggerEvent('freeze', 'Cold Wave Triggered')">
        <span><span class="tag-icon">[COLD]</span> Cold Wave (16&deg;C -&gt; Heat ON)</span>
        <span id="tag-freeze" class="state-indicator">EXEC</span>
      </button>

      <button id="btn-heatwave" class="btn-evt" onclick="triggerEvent('heatwave', 'Heatwave Triggered')">
        <span><span class="tag-icon">[HEAT]</span> Heatwave (28.5&deg;C -&gt; Cooling)</span>
        <span id="tag-heatwave" class="state-indicator">EXEC</span>
      </button>

      <button id="btn-arm" class="btn-evt" onclick="triggerEvent('toggle_arm', 'Alarm Arming State')">
        <span><span class="tag-icon">[ALARM]</span> Toggle Alarm Arming</span>
        <span id="tag-arm" class="state-indicator">ARMED</span>
      </button>
    </div>
  </div>

  <div id="interact-prompt"><span class="key">E</span> <span id="prompt-text">Toggle Sensor</span></div>
  <div id="unstuck-toast">Position reset to safe open floor</div>

  <div id="instructions">
    <span>W/A/S/D</span> Camera Relative | <span>SHIFT</span> Run | <span>SPACE</span> Jump | <span>E</span> Toggle Sensor | <span>U</span> Unstuck | <span>DRAG</span> Look
  </div>

  <script>
    let toastTimeout = null;

    function flashButton(btnId, actionTitle) {
      const btn = document.getElementById(btnId);
      if (!btn) return;

      btn.classList.remove('btn-fading-out');
      btn.classList.add('btn-just-activated');

      const banner = document.getElementById('action-status');
      banner.style.display = 'block';
      banner.style.opacity = '1';
      banner.innerText = `Applied: ${actionTitle}`;

      clearTimeout(toastTimeout);
      toastTimeout = setTimeout(() => {
        banner.style.opacity = '0';
        setTimeout(() => { banner.style.display = 'none'; }, 800);
      }, 2000);

      setTimeout(() => {
        btn.classList.remove('btn-just-activated');
        btn.classList.add('btn-fading-out');
      }, 100);
    }

    async function triggerEvent(type, actionTitle) {
      const btnMap = {
        'fire': 'btn-fire',
        'clear_fire': 'btn-clear-fire',
        'co2_spike': 'btn-co2',
        'freeze': 'btn-freeze',
        'heatwave': 'btn-heatwave',
        'toggle_arm': 'btn-arm'
      };
      flashButton(btnMap[type], actionTitle);

      try {
        const res = await fetch(`${window.location.origin}/api/event?type=${type}`, { method: 'POST' });
        if (!res.ok) console.error("Event trigger failed:", await res.text());
      } catch (err) {
        console.error("Network error triggering event:", err);
      }
    }

    async function toggleSensorApi(sensorId) {
      try {
        const res = await fetch(`${window.location.origin}/api/toggle-sensor?id=${sensorId}`, { method: 'POST' });
        if (!res.ok) console.error("Toggle failed:", await res.text());
      } catch (err) {
        console.error("Network error toggling sensor:", err);
      }
    }

    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0x0f172a);
    scene.fog = new THREE.FogExp2(0x0f172a, 0.025);

    const camera = new THREE.PerspectiveCamera(65, window.innerWidth / window.innerHeight, 0.1, 100);
    const renderer = new THREE.WebGLRenderer({ antialias: true });
    renderer.setSize(window.innerWidth, window.innerHeight);
    renderer.shadowMap.enabled = true;
    renderer.shadowMap.type = THREE.PCFSoftShadowMap;
    document.body.appendChild(renderer.domElement);

    const ambientLight = new THREE.AmbientLight(0xffffff, 0.65);
    scene.add(ambientLight);

    const sun = new THREE.DirectionalLight(0xffedd5, 0.85);
    sun.position.set(12, 18, 10);
    sun.castShadow = true;
    sun.shadow.mapSize.width = 2048;
    sun.shadow.mapSize.height = 2048;
    scene.add(sun);

    const fireLight = new THREE.PointLight(0xff4500, 0, 8);
    fireLight.position.set(4.5, 1.2, -6.0);
    scene.add(fireLight);

    function makeTexture(type) {
      const c = document.createElement('canvas');
      c.width = 256; c.height = 256;
      const ctx = c.getContext('2d');
      if (type === 'wood') {
        ctx.fillStyle = '#b47846'; ctx.fillRect(0,0,256,256);
        ctx.fillStyle = '#8f5627';
        for (let y = 0; y < 256; y += 32) {
          ctx.fillRect(0, y, 256, 2);
          for (let x = (y % 64 === 0 ? 0 : 32); x < 256; x += 64) ctx.fillRect(x, y, 2, 32);
        }
      } else if (type === 'tile') {
        ctx.fillStyle = '#cbd5e1'; ctx.fillRect(0,0,256,256);
        ctx.strokeStyle = '#94a3b8'; ctx.lineWidth = 4;
        ctx.strokeRect(2, 2, 126, 126); ctx.strokeRect(130, 2, 126, 126);
        ctx.strokeRect(2, 130, 126, 126); ctx.strokeRect(130, 130, 126, 126);
      } else if (type === 'carpet') {
        ctx.fillStyle = '#334155'; ctx.fillRect(0,0,256,256);
        for (let i = 0; i < 300; i++) {
          ctx.fillStyle = Math.random() > 0.5 ? '#475569' : '#1e293b';
          ctx.fillRect(Math.random()*256, Math.random()*256, 3, 3);
        }
      }
      const tex = new THREE.CanvasTexture(c);
      tex.wrapS = THREE.RepeatWrapping; tex.wrapT = THREE.RepeatWrapping;
      return tex;
    }

    const texWood = makeTexture('wood'); texWood.repeat.set(4, 4);
    const texTile = makeTexture('tile'); texTile.repeat.set(4, 4);
    const texCarpet = makeTexture('carpet'); texCarpet.repeat.set(4, 4);

    const colliders = [];
    function addBox(w, h, d, x, y, z, mat, isObstacle = true) {
      const mesh = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), mat);
      mesh.position.set(x, y + h / 2, z);
      mesh.castShadow = true;
      mesh.receiveShadow = true;
      scene.add(mesh);
      if (isObstacle) {
        colliders.push(new THREE.Box3(
          new THREE.Vector3(x - w / 2, y, z - d / 2),
          new THREE.Vector3(x + w / 2, y + h, z + d / 2)
        ));
      }
      return mesh;
    }

    const wallMat = new THREE.MeshStandardMaterial({ color: 0xf1f5f9, roughness: 0.8 });
    const woodMat = new THREE.MeshStandardMaterial({ color: 0x854d0e, roughness: 0.6 });
    const darkWoodMat = new THREE.MeshStandardMaterial({ color: 0x3f2e21, roughness: 0.5 });
    const fabricMat = new THREE.MeshStandardMaterial({ color: 0x1e293b, roughness: 0.9 });
    const metalMat = new THREE.MeshStandardMaterial({ color: 0x94a3b8, metalness: 0.8, roughness: 0.2 });

    function makeFloor(x, z, tex) {
      const m = new THREE.Mesh(new THREE.PlaneGeometry(8, 8), new THREE.MeshStandardMaterial({ map: tex }));
      m.rotation.x = -Math.PI / 2; m.position.set(x, 0, z); m.receiveShadow = true; scene.add(m);
    }
    makeFloor(-4, -4, texWood);
    makeFloor(4, -4, texTile);
    makeFloor(-4, 4, texCarpet);
    makeFloor(4, 4, texWood);

    const H = 2.8, T = 0.3;
    addBox(16.6, H, T, 0, 0, -8.15, wallMat);
    addBox(16.6, H, T, 0, 0, 8.15, wallMat);
    addBox(T, H, 16.6, -8.15, 0, 0, wallMat);
    addBox(T, H, 16.6, 8.15, 0, 0, wallMat);

    addBox(T, H, 4.5, 0, 0, -5.75, wallMat);
    addBox(T, H, 4.0, 0, 0, 0, wallMat);
    addBox(T, H, 4.5, 0, 0, 5.75, wallMat);
    addBox(4.5, H, T, -5.75, 0, 0, wallMat);
    addBox(4.5, H, T, 5.75, 0, 0, wallMat);

    // Furniture
    addBox(3.2, 0.7, 1.0, -4.5, 0, -7.2, fabricMat);
    addBox(1.0, 0.7, 2.2, -6.0, 0, -5.6, fabricMat);
    addBox(1.6, 0.4, 0.9, -4.2, 0, -5.3, darkWoodMat);
    addBox(2.6, 0.5, 0.5, -4.2, 0, -0.6, woodMat);
    addBox(2.2, 1.2, 0.1, -4.2, 0.7, -0.4, new THREE.MeshStandardMaterial({ color: 0x0284c7 }));

    addBox(3.0, 0.9, 1.2, 4.5, 0, -6.8, new THREE.MeshStandardMaterial({ color: 0xf8fafc, roughness: 0.3 }));
    addBox(0.9, 2.0, 0.9, 7.2, 0, -6.8, metalMat);
    addBox(2.0, 0.75, 1.1, 4.0, 0, -3.5, woodMat);
    addBox(0.5, 0.85, 0.5, 4.0, 0, -2.4, fabricMat);
    addBox(0.5, 0.85, 0.5, 4.0, 0, -4.6, fabricMat);

    addBox(2.2, 0.6, 2.0, -4.8, 0, 6.6, fabricMat);
    addBox(2.4, 1.2, 0.2, -4.8, 0, 7.7, darkWoodMat);
    addBox(0.6, 0.5, 0.5, -6.4, 0, 7.3, woodMat);
    addBox(0.6, 0.5, 0.5, -3.2, 0, 7.3, woodMat);
    addBox(1.2, 2.3, 2.8, -7.2, 0, 3.5, woodMat);

    addBox(2.2, 0.75, 1.0, 5.0, 0, 6.8, darkWoodMat);
    addBox(1.0, 0.5, 0.1, 5.0, 0.75, 7.1, new THREE.MeshStandardMaterial({ color: 0x38bdf8 }));
    addBox(0.6, 0.9, 0.6, 5.0, 0, 5.5, fabricMat);
    addBox(0.5, 2.2, 2.4, 7.6, 0, 3.5, woodMat);

    // 3D Fire & Smoke Simulation
    const fireGroup = new THREE.Group();
    scene.add(fireGroup);

    const flameCount = 45;
    const flameGeo = new THREE.DodecahedronGeometry(0.12, 1);
    const flames = [];

    for (let i = 0; i < flameCount; i++) {
      const mat = new THREE.MeshBasicMaterial({
        color: Math.random() > 0.4 ? 0xff4500 : 0xffaa00,
        transparent: true,
        opacity: 0.85
      });
      const mesh = new THREE.Mesh(flameGeo, mat);
      mesh.position.set(
        4.5 + (Math.random() - 0.5) * 1.2,
        0.9 + Math.random() * 0.4,
        -6.8 + (Math.random() - 0.5) * 0.6
      );
      mesh.userData = {
        baseY: 0.9,
        speedY: 1.2 + Math.random() * 1.5,
        speedX: (Math.random() - 0.5) * 0.4,
        speedZ: (Math.random() - 0.5) * 0.4,
        life: Math.random()
      };
      fireGroup.add(mesh);
      flames.push(mesh);
    }

    const smokeCount = 35;
    const smokeGeo = new THREE.SphereGeometry(0.18, 8, 8);
    const smokes = [];

    for (let i = 0; i < smokeCount; i++) {
      const mat = new THREE.MeshBasicMaterial({
        color: 0x334155,
        transparent: true,
        opacity: 0.4
      });
      const mesh = new THREE.Mesh(smokeGeo, mat);
      mesh.position.set(
        4.5 + (Math.random() - 0.5) * 1.5,
        1.5 + Math.random() * 1.2,
        -6.8 + (Math.random() - 0.5) * 1.0
      );
      mesh.userData = {
        baseY: 1.3,
        speedY: 0.6 + Math.random() * 0.7,
        life: Math.random()
      };
      fireGroup.add(mesh);
      smokes.push(mesh);
    }

    fireGroup.visible = false;

    // Falling Frost / Ice Particles
    const frostCount = 120;
    const frostGeo = new THREE.BufferGeometry();
    const frostPos = new Float32Array(frostCount * 3);
    for (let i = 0; i < frostCount * 3; i += 3) {
      frostPos[i] = (Math.random() - 0.5) * 16;
      frostPos[i+1] = Math.random() * 2.8;
      frostPos[i+2] = (Math.random() - 0.5) * 16;
    }
    frostGeo.setAttribute('position', new THREE.BufferAttribute(frostPos, 3));
    const frostMat = new THREE.PointsMaterial({
      color: 0xe0f2fe,
      size: 0.08,
      transparent: true,
      opacity: 0.0
    });
    const frostPoints = new THREE.Points(frostGeo, frostMat);
    scene.add(frostPoints);

    // CO2 Dust/Gas Particles
    const co2Count = 150;
    const co2Geo = new THREE.BufferGeometry();
    const co2Pos = new Float32Array(co2Count * 3);
    for (let i = 0; i < co2Count * 3; i += 3) {
      co2Pos[i] = (Math.random() - 0.5) * 16;
      co2Pos[i+1] = Math.random() * 2.5;
      co2Pos[i+2] = (Math.random() - 0.5) * 16;
    }
    co2Geo.setAttribute('position', new THREE.BufferAttribute(co2Pos, 3));
    const co2Mat = new THREE.PointsMaterial({
      color: 0xeab308,
      size: 0.12,
      transparent: true,
      opacity: 0.0
    });
    const co2Points = new THREE.Points(co2Geo, co2Mat);
    scene.add(co2Points);

    // Sensors
    const interactiveSensors = [];

    function createPIRSensor(id, name, room, pos, rotY) {
      const group = new THREE.Group();
      group.position.copy(pos);
      group.rotation.y = rotY;

      const base = new THREE.Mesh(new THREE.BoxGeometry(0.2, 0.28, 0.08), new THREE.MeshStandardMaterial({ color: 0xffffff }));
      const dome = new THREE.Mesh(new THREE.SphereGeometry(0.08, 16, 16), new THREE.MeshStandardMaterial({ color: 0xe2e8f0, roughness: 0.2 }));
      dome.position.z = 0.05;
      const led = new THREE.Mesh(new THREE.SphereGeometry(0.02, 8, 8), new THREE.MeshBasicMaterial({ color: 0x22c55e }));
      led.position.set(0, 0.09, 0.05);

      group.add(base); group.add(dome); group.add(led);

      const coneHeight = 3.6;
      const coneRadius = 2.4;
      const coneGeo = new THREE.ConeGeometry(coneRadius, coneHeight, 20, 1, true);
      coneGeo.translate(0, -coneHeight / 2, 0);
      coneGeo.rotateX(-Math.PI / 2.3);

      const coneMat = new THREE.MeshBasicMaterial({
        color: 0x38bdf8,
        transparent: true,
        opacity: 0.18,
        wireframe: true,
        side: THREE.DoubleSide
      });
      const cone = new THREE.Mesh(coneGeo, coneMat);
      cone.position.set(0, 0, 0.1);
      group.add(cone);

      scene.add(group);

      const sensorObj = {
        id, name, room, type: "pir",
        worldPos: pos, meshGroup: group,
        led, cone, coneMat,
        enabled: true, active: false
      };
      interactiveSensors.push(sensorObj);
      return sensorObj;
    }

    function createSmokeDetector(id, name, room, pos) {
      const group = new THREE.Group();
      group.position.copy(pos);

      const disc = new THREE.Mesh(new THREE.CylinderGeometry(0.25, 0.25, 0.06, 24), new THREE.MeshStandardMaterial({ color: 0xf8fafc }));
      disc.position.y = -0.03;
      const ring = new THREE.Mesh(new THREE.TorusGeometry(0.18, 0.015, 8, 24), new THREE.MeshStandardMaterial({ color: 0x94a3b8 }));
      ring.rotation.x = Math.PI / 2; ring.position.y = -0.06;
      const led = new THREE.Mesh(new THREE.SphereGeometry(0.025, 8, 8), new THREE.MeshBasicMaterial({ color: 0x22c55e }));
      led.position.set(0.14, -0.06, 0);

      group.add(disc); group.add(ring); group.add(led);

      const fieldGeo = new THREE.CylinderGeometry(2.0, 2.0, 2.4, 20, 1, true);
      const fieldMat = new THREE.MeshBasicMaterial({
        color: 0xef4444,
        transparent: true,
        opacity: 0.12,
        wireframe: true,
        side: THREE.DoubleSide
      });
      const field = new THREE.Mesh(fieldGeo, fieldMat);
      field.position.y = -1.2;
      group.add(field);

      scene.add(group);

      const sensorObj = {
        id, name, room, type: "smoke",
        worldPos: pos, meshGroup: group,
        led, cone: field, coneMat: fieldMat,
        enabled: true, active: false
      };
      interactiveSensors.push(sensorObj);
      return sensorObj;
    }

    function createClimateSensor(id, name, room, pos) {
      const group = new THREE.Group();
      group.position.copy(pos);

      const box = new THREE.Mesh(new THREE.BoxGeometry(0.18, 0.18, 0.04), new THREE.MeshStandardMaterial({ color: 0xf1f5f9 }));
      const screen = new THREE.Mesh(new THREE.PlaneGeometry(0.12, 0.08), new THREE.MeshBasicMaterial({ color: 0x0284c7 }));
      screen.position.z = 0.021;
      const led = new THREE.Mesh(new THREE.SphereGeometry(0.015, 8, 8), new THREE.MeshBasicMaterial({ color: 0x22c55e }));
      led.position.set(0, 0.065, 0.022);

      group.add(box); group.add(screen); group.add(led);
      scene.add(group);

      const sensorObj = {
        id, name, room, type: "climate",
        worldPos: pos, meshGroup: group,
        led, cone: null, coneMat: null,
        enabled: true, active: false
      };
      interactiveSensors.push(sensorObj);
      return sensorObj;
    }

    createPIRSensor("living_room_pir", "Living Room PIR", "living_room", new THREE.Vector3(-0.4, 2.2, -7.9), 0);
    createClimateSensor("living_room_climate", "Living Room Climate/CO2", "living_room", new THREE.Vector3(-4.0, 1.4, -7.95));

    createSmokeDetector("kitchen_smoke", "Kitchen Smoke Detector", "kitchen", new THREE.Vector3(4.5, 2.75, -5.5));
    createClimateSensor("kitchen_climate", "Kitchen Climate", "kitchen", new THREE.Vector3(7.95, 1.5, -4.0));

    createPIRSensor("bedroom_pir", "Bedroom PIR", "bedroom", new THREE.Vector3(-7.9, 2.2, 0.4), Math.PI / 2);
    createClimateSensor("bedroom_climate", "Bedroom Thermostat", "bedroom", new THREE.Vector3(-7.95, 1.4, 5.0));

    createPIRSensor("office_pir", "Office PIR", "office", new THREE.Vector3(0.4, 2.2, 7.9), Math.PI);
    createClimateSensor("office_climate", "Office Climate", "office", new THREE.Vector3(7.95, 1.5, 5.0));

    // Player rig
    const character = new THREE.Group();
    scene.add(character);

    const skinMat = new THREE.MeshStandardMaterial({ color: 0xfbbf24, roughness: 0.4 });
    const clothesMat = new THREE.MeshStandardMaterial({ color: 0x2563eb, roughness: 0.5 });
    const pantsMat = new THREE.MeshStandardMaterial({ color: 0x1e293b, roughness: 0.6 });

    const torso = new THREE.Mesh(new THREE.CylinderGeometry(0.24, 0.18, 0.65, 12), clothesMat);
    torso.position.y = 1.1; torso.castShadow = true; character.add(torso);

    const head = new THREE.Mesh(new THREE.SphereGeometry(0.16, 16, 16), skinMat);
    head.position.y = 1.6; head.castShadow = true; character.add(head);

    function createLimb(w, h, mat, px, py, pz) {
      const pivot = new THREE.Group();
      pivot.position.set(px, py, pz);
      const mesh = new THREE.Mesh(new THREE.CylinderGeometry(w, w*0.8, h, 8), mat);
      mesh.position.y = -h / 2;
      mesh.castShadow = true;
      pivot.add(mesh);
      character.add(pivot);
      return pivot;
    }

    const leftLeg = createLimb(0.08, 0.7, pantsMat, -0.12, 0.75, 0);
    const rightLeg = createLimb(0.08, 0.7, pantsMat, 0.12, 0.75, 0);
    const leftArm = createLimb(0.06, 0.6, clothesMat, -0.32, 1.35, 0);
    const rightArm = createLimb(0.06, 0.6, clothesMat, 0.32, 1.35, 0);

    const playerRadius = 0.35;
    const SAFE_SPAWN = new THREE.Vector3(-3.0, 0, -3.0);
    const playerPos = SAFE_SPAWN.clone();
    const playerVel = new THREE.Vector3();
    let onFloor = true;

    const keys = {};
    let nearestSensor = null;

    function resetToSafePosition() {
      playerPos.copy(SAFE_SPAWN);
      playerVel.set(0, 0, 0);
      cameraAngle.yaw = 0;
      cameraAngle.pitch = 0.35;
      character.position.copy(playerPos);
      
      const toast = document.getElementById("unstuck-toast");
      toast.style.display = "block";
      setTimeout(() => { toast.style.display = "none"; }, 2000);
    }

    window.addEventListener('keydown', (e) => {
      keys[e.code] = true;
      if (e.code === 'KeyE' && nearestSensor) {
        toggleSensorApi(nearestSensor.id);
      }
      if (e.code === 'KeyU') {
        resetToSafePosition();
      }
    });
    window.addEventListener('keyup', (e) => { keys[e.code] = false; });

    let isMouseDown = false;
    let cameraAngle = { yaw: 0, pitch: 0.35 };
    window.addEventListener('mousedown', () => { isMouseDown = true; });
    window.addEventListener('mouseup', () => { isMouseDown = false; });
    window.addEventListener('mousemove', (e) => {
      if (isMouseDown) {
        cameraAngle.yaw -= e.movementX * 0.003;
        cameraAngle.pitch = Math.max(0.1, Math.min(1.1, cameraAngle.pitch + e.movementY * 0.003));
      }
    });

    let walkCycle = 0;

    function updatePhysics(dt) {
      const currentRoom = getCurrentRoom(playerPos.x, playerPos.z);
      let ambientTemp = 21.0;
      let ambientCo2 = 600;

      if (latestTelemetry && currentRoom !== "hallway" && latestTelemetry.houseState[currentRoom]) {
        ambientTemp = latestTelemetry.houseState[currentRoom].temperature;
        ambientCo2 = latestTelemetry.houseState[currentRoom].co2;
      }

      const isCold = ambientTemp <= 16.5;
      const isHot = ambientTemp >= 27.0 || (latestTelemetry && latestTelemetry.subsystems.fireAlarm.active === 1);
      const isHighCo2 = ambientCo2 >= 1100;

      let baseSpeed = 3.8;
      let sprintSpeed = 7.5;

      if (isHighCo2) {
        baseSpeed = 1.8;
        sprintSpeed = 3.2;
      } else if (isCold) {
        baseSpeed = 2.0;
        sprintSpeed = 3.8;
      } else if (isHot) {
        baseSpeed = 2.4;
        sprintSpeed = 4.2;
      }

      const isRunning = keys['ShiftLeft'] || keys['ShiftRight'];
      const speed = isRunning ? sprintSpeed : baseSpeed;

      let forwardInput = 0;
      let strafeInput = 0;

      if (keys['KeyW'] || keys['ArrowUp']) forwardInput += 1;
      if (keys['KeyS'] || keys['ArrowDown']) forwardInput -= 1;
      if (keys['KeyA'] || keys['ArrowLeft']) strafeInput -= 1;
      if (keys['KeyD'] || keys['ArrowRight']) strafeInput += 1;

      const inputLen = Math.hypot(forwardInput, strafeInput);
      if (inputLen > 0) {
        forwardInput /= inputLen;
        strafeInput /= inputLen;

        const camForward = new THREE.Vector3(-Math.sin(cameraAngle.yaw), 0, -Math.cos(cameraAngle.yaw));
        const camRight = new THREE.Vector3(Math.cos(cameraAngle.yaw), 0, -Math.sin(cameraAngle.yaw));

        const moveDir = new THREE.Vector3()
          .addScaledVector(camForward, forwardInput)
          .addScaledVector(camRight, strafeInput)
          .normalize();

        playerVel.x = moveDir.x * speed;
        playerVel.z = moveDir.z * speed;

        const targetAngle = Math.atan2(moveDir.x, moveDir.z);
        character.rotation.y = targetAngle;

        walkCycle += dt * (isRunning ? 18 : 10) * (isCold || isHighCo2 ? 0.7 : 1.0);
        const swing = Math.sin(walkCycle) * (isCold ? 0.35 : 0.6);
        leftLeg.rotation.x = swing;
        rightLeg.rotation.x = -swing;
        leftArm.rotation.x = -swing;
        rightArm.rotation.x = swing;
        torso.position.y = 1.1 + Math.abs(Math.sin(walkCycle * 2)) * 0.04;
      } else {
        playerVel.x = 0;
        playerVel.z = 0;
        leftLeg.rotation.x = 0;
        rightLeg.rotation.x = 0;
        leftArm.rotation.x = 0;
        rightArm.rotation.x = 0;
        torso.position.y = 1.1 + Math.sin(Date.now() * 0.003) * 0.015;
      }

      if (isHighCo2) {
        const coughJerk = Math.sin(Date.now() * 0.015) > 0.7 ? 0.25 : 0;
        head.rotation.x = 0.35 + coughJerk;
        torso.rotation.x = 0.2 + coughJerk * 0.5;
        torso.position.x = 0;
      } else if (isCold) {
        const shiver = (Math.random() - 0.5) * 0.035;
        torso.position.x = shiver;
        head.position.x = -shiver;
        torso.rotation.x = 0.15;
      } else if (isHot) {
        torso.position.x = 0;
        head.position.x = 0;
        torso.rotation.x = 0.32;
        head.rotation.x = 0.25;
      } else {
        torso.position.x = 0;
        head.position.x = 0;
        torso.rotation.x = 0;
        head.rotation.x = 0;
      }

      if (onFloor && keys['Space']) {
        playerVel.y = isHot || isHighCo2 ? 4.2 : 6.0;
        onFloor = false;
      }
      playerVel.y -= 19.8 * dt;

      const nextX = playerPos.x + playerVel.x * dt;
      const nextZ = playerPos.z + playerVel.z * dt;
      const nextY = playerPos.y + playerVel.y * dt;

      let canMoveX = true;
      for (const box of colliders) {
        if (nextX + playerRadius > box.min.x && nextX - playerRadius < box.max.x &&
            playerPos.z + playerRadius > box.min.z && playerPos.z - playerRadius < box.max.z &&
            playerPos.y + 1.5 > box.min.y && playerPos.y < box.max.y) {
          canMoveX = false;
          break;
        }
      }
      if (canMoveX) playerPos.x = nextX;

      let canMoveZ = true;
      for (const box of colliders) {
        if (playerPos.x + playerRadius > box.min.x && playerPos.x - playerRadius < box.max.x &&
            nextZ + playerRadius > box.min.z && nextZ - playerRadius < box.max.z &&
            playerPos.y + 1.5 > box.min.y && playerPos.y < box.max.y) {
          canMoveZ = false;
          break;
        }
      }
      if (canMoveZ) playerPos.z = nextZ;

      if (nextY <= 0) {
        playerPos.y = 0;
        playerVel.y = 0;
        onFloor = true;
      } else {
        playerPos.y = nextY;
      }

      character.position.copy(playerPos);

      const dist = 3.6;
      const camH = Math.sin(cameraAngle.pitch) * dist;
      const camR = Math.cos(cameraAngle.pitch) * dist;

      camera.position.set(
        playerPos.x + Math.sin(cameraAngle.yaw) * camR,
        playerPos.y + 1.6 + camH,
        playerPos.z + Math.cos(cameraAngle.yaw) * camR
      );
      camera.lookAt(playerPos.x, playerPos.y + 1.3, playerPos.z);

      nearestSensor = null;
      let minDist = 1.8;
      for (const s of interactiveSensors) {
        const d = playerPos.distanceTo(s.worldPos);
        if (d < minDist) {
          minDist = d;
          nearestSensor = s;
        }
      }

      const promptEl = document.getElementById("interact-prompt");
      const promptText = document.getElementById("prompt-text");
      if (nearestSensor) {
        promptEl.style.display = "block";
        promptText.innerText = nearestSensor.enabled ? `Turn OFF ${nearestSensor.name}` : `Turn ON ${nearestSensor.name}`;
      } else {
        promptEl.style.display = "none";
      }
    }

    function getCurrentRoom(x, z) {
      if (x < -0.3 && z < -0.3) return "living_room";
      if (x > 0.3 && z < -0.3) return "kitchen";
      if (x < -0.3 && z > 0.3) return "bedroom";
      if (x > 0.3 && z > 0.3) return "office";
      return "hallway";
    }

    let latestTelemetry = null;
    const socket = new WebSocket(`ws://${location.host}`);
    socket.onmessage = (event) => {
      latestTelemetry = JSON.parse(event.data);
      updateSensorVisuals();
      updateHUD();
    };

    function updateSensorVisuals() {
      if (!latestTelemetry) return;
      const { houseState, sensorStatus, activeEvents } = latestTelemetry;

      const btnFire = document.getElementById('btn-fire');
      const tagFire = document.getElementById('tag-fire');
      if (activeEvents?.fire) {
        btnFire.classList.add('btn-persistent-fire');
        tagFire.innerText = 'ACTIVE';
        fireGroup.visible = true;
        fireLight.intensity = 2.5 + Math.random() * 1.5;
      } else {
        btnFire.classList.remove('btn-persistent-fire');
        tagFire.innerText = 'OFF';
        fireGroup.visible = false;
        fireLight.intensity = 0;
      }

      const btnCo2 = document.getElementById('btn-co2');
      const tagCo2 = document.getElementById('tag-co2');
      if (activeEvents?.co2_spike) {
        btnCo2.classList.add('btn-persistent-co2');
        tagCo2.innerText = 'SPIKED';
      } else {
        btnCo2.classList.remove('btn-persistent-co2');
        tagCo2.innerText = 'NORMAL';
      }

      const btnArm = document.getElementById('btn-arm');
      const tagArm = document.getElementById('tag-arm');
      if (activeEvents?.alarmArmed) {
        btnArm.classList.add('btn-persistent-active');
        tagArm.innerText = 'ARMED';
      } else {
        btnArm.classList.remove('btn-persistent-active');
        tagArm.innerText = 'DISARMED';
      }

      interactiveSensors.forEach(s => {
        const isEnabled = sensorStatus[s.id] !== false;
        s.enabled = isEnabled;

        if (!isEnabled) {
          s.led.material.color.setHex(0x64748b);
          if (s.cone) s.cone.visible = false;
          return;
        }

        if (s.cone) s.cone.visible = true;

        if (s.type === "pir") {
          const hasMotion = houseState[s.room] && houseState[s.room].motion === 1;
          if (hasMotion) {
            s.led.material.color.setHex(0xf59e0b);
            if (s.coneMat) {
              s.coneMat.color.setHex(0xf59e0b);
              s.coneMat.opacity = 0.45;
            }
          } else {
            s.led.material.color.setHex(0x22c55e);
            if (s.coneMat) {
              s.coneMat.color.setHex(0x38bdf8);
              s.coneMat.opacity = 0.18;
            }
          }
        } else if (s.type === "smoke") {
          const isSmoke = houseState[s.room] && houseState[s.room].smoke === 1;
          if (isSmoke) {
            s.led.material.color.setHex(0xef4444);
            if (s.coneMat) {
              s.coneMat.color.setHex(0xef4444);
              s.coneMat.opacity = 0.6;
            }
          } else {
            s.led.material.color.setHex(0x22c55e);
            if (s.coneMat) {
              s.coneMat.color.setHex(0x94a3b8);
              s.coneMat.opacity = 0.1;
            }
          }
        } else if (s.type === "climate") {
          s.led.material.color.setHex(0x38bdf8);
        }
      });
    }

    function updateHUD() {
      if (!latestTelemetry) return;
      const { houseState, subsystems, sensorStatus } = latestTelemetry;
      const room = getCurrentRoom(playerPos.x, playerPos.z);

      document.getElementById("current-room-name").innerText = room.replace("_", " ").toUpperCase();

      let currentRoomTemp = 21.0;
      let currentRoomCo2 = 600;

      if (room !== "hallway" && houseState[room]) {
        const s = houseState[room];
        currentRoomTemp = s.temperature;
        currentRoomCo2 = s.co2;
        const isClimateOn = sensorStatus[`${room}_climate`] !== false;
        const isPirOn = sensorStatus[`${room}_pir`] !== false;

        document.getElementById("disp-temp").innerText = isClimateOn ? `${s.temperature} \u00B0C` : "Sensor Off";
        document.getElementById("disp-hum").innerText = isClimateOn ? `${s.humidity} %` : "Sensor Off";
        document.getElementById("disp-co2").innerText = isClimateOn ? `${s.co2} ppm` : "Sensor Off";
        document.getElementById("disp-motion").innerText = isPirOn ? (s.motion ? "MOTION DETECTED" : "Clear") : "Sensor Off";
        document.getElementById("disp-smoke").innerText = s.smoke ? "SMOKE ALARM!" : "Normal";
      } else {
        document.getElementById("disp-temp").innerText = "Hallway / Transit";
        document.getElementById("disp-hum").innerText = "--";
        document.getElementById("disp-co2").innerText = "--";
        document.getElementById("disp-motion").innerText = "--";
        document.getElementById("disp-smoke").innerText = "Normal";
      }

      const overlay = document.getElementById("vignette-overlay");
      const debuffCard = document.getElementById("debuff-card");
      const conditionText = document.getElementById("player-condition-text");

      if (currentRoomCo2 >= 1100) {
        overlay.className = "co2-vignette";
        co2Mat.opacity = 0.7;
        frostMat.opacity = 0.0;
        debuffCard.className = "state-co2";
        conditionText.innerText = "SUFFOCATING / CO2 HAZARD (COUGHING)";
      } else if (currentRoomTemp <= 16.5) {
        overlay.className = "cold-vignette";
        frostMat.opacity = 0.75;
        co2Mat.opacity = 0.0;
        debuffCard.className = "state-cold";
        conditionText.innerText = "SHIVERING / JOINT STIFFNESS (SLOW)";
      } else if (currentRoomTemp >= 27.0 || subsystems.fireAlarm.active === 1) {
        overlay.className = "heat-vignette";
        frostMat.opacity = 0.0;
        co2Mat.opacity = 0.0;
        debuffCard.className = "state-hot";
        conditionText.innerText = "HEAT EXHAUSTION / SLUGGISH";
      } else {
        overlay.className = "";
        frostMat.opacity = 0.0;
        co2Mat.opacity = 0.0;
        debuffCard.className = "state-normal";
        conditionText.innerText = "NORMAL CONDITION";
      }

      const fireBadge = document.getElementById("status-fire");
      if (subsystems.fireAlarm.active === 1) {
        fireBadge.className = "badge badge-danger";
        fireBadge.innerText = `FIRE: ${subsystems.fireAlarm.room.toUpperCase()}`;
      } else {
        fireBadge.className = "badge badge-ok";
        fireBadge.innerText = "Fire: Normal";
      }

      const burglarBadge = document.getElementById("status-burglar");
      if (subsystems.burglarAlarm.active === 1) {
        burglarBadge.className = "badge badge-danger";
        burglarBadge.innerText = `ALARM: ${subsystems.burglarAlarm.detectedRooms.join(", ")}`;
      } else {
        burglarBadge.className = "badge badge-ok";
        burglarBadge.innerText = subsystems.alarmArmed ? "Alarm: Armed" : "Alarm: Disarmed";
      }

      const ventBadge = document.getElementById("status-vent");
      ventBadge.innerText = `Vent: Stage ${subsystems.ventilation.level}`;

      const hvacBadge = document.getElementById("status-hvac");
      if (subsystems.hvac.heatingActive) {
        hvacBadge.className = "badge badge-warn";
        hvacBadge.innerText = "HVAC: Heating";
      } else if (subsystems.hvac.coolingActive) {
        hvacBadge.className = "badge badge-warn";
        hvacBadge.innerText = "HVAC: Cooling";
      } else {
        hvacBadge.className = "badge badge-ok";
        hvacBadge.innerText = "HVAC: Standby";
      }
    }

    let lastTime = performance.now();

    function animate() {
      requestAnimationFrame(animate);
      const now = performance.now();
      const dt = Math.min(0.05, (now - lastTime) / 1000);
      lastTime = now;

      if (fireGroup.visible) {
        flames.forEach(f => {
          f.position.y += f.userData.speedY * dt;
          f.position.x += f.userData.speedX * dt;
          f.position.z += f.userData.speedZ * dt;
          f.scale.multiplyScalar(0.965);
          if (f.position.y > f.userData.baseY + 1.2 || f.scale.x < 0.1) {
            f.position.set(
              4.5 + (Math.random() - 0.5) * 1.2,
              f.userData.baseY,
              -6.8 + (Math.random() - 0.5) * 0.6
            );
            f.scale.set(1, 1, 1);
          }
        });

        smokes.forEach(s => {
          s.position.y += s.userData.speedY * dt;
          s.scale.multiplyScalar(1.018);
          s.material.opacity *= 0.985;
          if (s.position.y > 2.7 || s.material.opacity < 0.05) {
            s.position.set(
              4.5 + (Math.random() - 0.5) * 1.5,
              s.userData.baseY,
              -6.8 + (Math.random() - 0.5) * 1.0
            );
            s.scale.set(1, 1, 1);
            s.material.opacity = 0.4;
          }
        });
      }

      if (frostMat.opacity > 0.01) {
        const positions = frostGeo.attributes.position.array;
        for (let i = 1; i < frostCount * 3; i += 3) {
          positions[i] -= 0.6 * dt;
          if (positions[i] < 0) positions[i] = 2.8;
        }
        frostGeo.attributes.position.needsUpdate = true;
      }

      if (co2Mat.opacity > 0.01) {
        const cPositions = co2Geo.attributes.position.array;
        for (let i = 1; i < co2Count * 3; i += 3) {
          cPositions[i] -= 0.25 * dt;
          cPositions[i-1] += Math.sin(Date.now() * 0.001 + i) * 0.005;
          if (cPositions[i] < 0.1) cPositions[i] = 2.2;
        }
        co2Geo.attributes.position.needsUpdate = true;
      }

      updatePhysics(dt);
      updateHUD();
      renderer.render(scene, camera);
    }
    animate();

    window.addEventListener('resize', () => {
      camera.aspect = window.innerWidth / window.innerHeight;
      camera.updateProjectionMatrix();
      renderer.setSize(window.innerWidth, window.innerHeight);
    });
  </script>
</body>
</html>
'@
[System.IO.File]::WriteAllText("$ProjectDir\app\public\index.html", $appIndexHtml, $Utf8NoBom)

# ------------------------------------------------------------------------------
# 8. Go Native App Dockerfile
# ------------------------------------------------------------------------------
$dockerfile = @'
# Multi-stage build for ultra-compact, high-performance compiled Go binary
FROM golang:1.22-alpine AS builder
WORKDIR /app
RUN apk add --no-cache git
COPY go.mod ./
RUN go mod download || true
COPY . .
RUN go mod tidy
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o smarthouse-app .

FROM alpine:3.19
WORKDIR /app
RUN apk add --no-cache ca-certificates tzdata
COPY --from=builder /app/smarthouse-app .
COPY public ./public
EXPOSE 3000
CMD ["./smarthouse-app"]
'@
[System.IO.File]::WriteAllText("$ProjectDir\app\Dockerfile", $dockerfile, $Utf8NoBom)

# ------------------------------------------------------------------------------
# 9. Docker Compose Configuration
# ------------------------------------------------------------------------------
$dockerComposeContent = @"
services:
  emqx:
    image: emqx/emqx:5.8.0
    container_name: smarthouse-broker
    restart: unless-stopped
    ports:
      - "1883:1883"
      - "8083:8083"
      - "$($emqxPort):18083"
    environment:
      - EMQX_DASHBOARD__DEFAULT_USERNAME=admin
      - EMQX_DASHBOARD__DEFAULT_PASSWORD=public
    networks:
      - smarthouse-net

  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:stable
    container_name: smarthouse-homeassistant
    restart: unless-stopped
    ports:
      - "$($haPort):8123"
    volumes:
      - ./homeassistant/config:/config
    environment:
      - TZ=Europe/Oslo
    depends_on:
      - emqx
    networks:
      - smarthouse-net

  zigbee2mqtt:
    image: koenkk/zigbee2mqtt:latest
    container_name: smarthouse-bridge
    restart: unless-stopped
    ports:
      - "$($z2mPort):8080"
    volumes:
      - ./zigbee2mqtt/data:/app/data
    environment:
      - TZ=Europe/Oslo
    depends_on:
      - emqx
    networks:
      - smarthouse-net

  app:
    build:
      context: ./app
      dockerfile: Dockerfile
    container_name: smarthouse-app
    restart: unless-stopped
    ports:
      - "3000:3000"
    depends_on:
      - emqx
    networks:
      - smarthouse-net

  postgres-zabbix:
    image: postgres:16-alpine
    container_name: zabbix-db
    restart: unless-stopped
    environment:
      POSTGRES_USER: zabbix
      POSTGRES_PASSWORD: zabbix_password
      POSTGRES_DB: zabbix
    volumes:
      - zabbix-db-data:/var/lib/postgresql/data
    networks:
      - smarthouse-net

  zabbix-server:
    image: zabbix/zabbix-server-pgsql:alpine-7.0-latest
    container_name: zabbix-server
    restart: unless-stopped
    ports:
      - "10051:10051"
    environment:
      DB_SERVER_HOST: postgres-zabbix
      POSTGRES_USER: zabbix
      POSTGRES_PASSWORD: zabbix_password
      POSTGRES_DB: zabbix
    depends_on:
      - postgres-zabbix
    networks:
      - smarthouse-net

  zabbix-web:
    image: zabbix/zabbix-web-nginx-pgsql:alpine-7.0-latest
    container_name: zabbix-web
    restart: unless-stopped
    ports:
      - "$($zbxPort):8080"
    environment:
      ZBX_SERVER_HOST: zabbix-server
      DB_SERVER_HOST: postgres-zabbix
      POSTGRES_USER: zabbix
      POSTGRES_PASSWORD: zabbix_password
      POSTGRES_DB: zabbix
      PHP_TZ: Europe/Oslo
    depends_on:
      - postgres-zabbix
      - zabbix-server
    networks:
      - smarthouse-net

  zabbix-agent2:
    image: zabbix/zabbix-agent2:alpine-7.0-latest
    container_name: zabbix-agent2
    restart: unless-stopped
    privileged: true
    user: root
    environment:
      ZBX_HOSTNAME: "Docker-Desktop-Host"
      ZBX_SERVER: zabbix-server
      ZBX_SERVER_ACTIVE: zabbix-server
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    depends_on:
      - zabbix-server
    networks:
      - smarthouse-net

networks:
  smarthouse-net:
    driver: bridge

volumes:
  zabbix-db-data:
"@
[System.IO.File]::WriteAllText("$ProjectDir\docker-compose.yml", $dockerComposeContent, $Utf8NoBom)

# ------------------------------------------------------------------------------
# 10. Build and Start Stack
# ------------------------------------------------------------------------------
Write-Host "==> Building and deploying smart house stack..." -ForegroundColor Green
Set-Location -Path $ProjectDir

& docker compose down --remove-orphans
& docker compose up -d --build
if ($LASTEXITCODE -ne 0) {
    Write-Error "docker compose up failed during deployment."
    exit 1
}

Write-Host "`n=================================================================" -ForegroundColor Green
Write-Host " All Services Deployed Successfully!" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green
Write-Host "  * 3D Digital Twin (Direct)       : http://localhost:3000"
Write-Host "  * Home Assistant Portal          : http://localhost:$haPort"
Write-Host "  * EMQX Broker Web Console        : http://localhost:$emqxPort (Login: admin / public)"
Write-Host "  * Zabbix 7.0 Web UI              : http://localhost:$zbxPort (Login: Admin / zabbix)"
Write-Host "  * Zigbee2MQTT Frontend           : http://localhost:$z2mPort"
