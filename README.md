# Smart House Stack - Go Backend, MQTT & 3D Digital Twin

<img width="956" height="494" alt="3D Digital Twin Overview" src="https://github.com/user-attachments/assets/79fce286-96c4-445a-957b-ded5c4600dce" />
<img width="956" height="477" alt="Home Assistant and Sensors" src="https://github.com/user-attachments/assets/a3b18728-081e-47c4-a49a-69344d471e8a" />
<img width="947" height="524" alt="Zabbix 7.0 Telemetry Monitoring" src="https://github.com/user-attachments/assets/b73bb0c0-81fb-47ad-a2d6-2ee06b82356b" />

En helhetlig, distribuert IoT-, SCADA- og Digital Twin-plattform implementert med **EMQX MQTT Broker**, **Home Assistant**, **Zigbee2MQTT**, **Zabbix 7.0 Enterprise Monitoring**, en **kompilert Go Native Engine** og et **Three.js 3D SCADA-grensesnitt**.

Alt provisjoneres og orkestreres automatisk som Infrastructure-as-Code (IaC) via PowerShell-skriptet `deploy-stack.ps1`.

---

## Innhold

1. [Oversikt & Utbrettet Struktur](#oversikt--utbrettet-struktur)
2. [System- og Containerarkitektur](#1-system--og-containerarkitektur)
3. [Go Native Engine Intern Arkitektur](#2-go-native-engine-intern-arkitektur)
4. [ER-diagram: Domene- og Tilstandsmodell](#3-er-diagram-domene--og-tilstandsmodell)
5. [ER-diagram: Zabbix 7.0 & PostgreSQL Relasjonsmodell](#4-er-diagram-zabbix-70--postgresql-relasjonsmodell)
6. [Sekvensdiagram: Telemetriflyt og Hendelsesinjeksjon](#5-sekvensdiagram-telemetriflyt-og-hendelsesinjeksjon)
7. [Tilstandsdiagram for Hoveddelsystemer](#6-tilstandsdiagram-for-hoveddelsystemer)
8. [Deployment- og Utførelsesflyt](#7-deployment--og-utførelsesflyt)
9. [Porter og Nettverk](#8-porter-og-nettverk)
10. [REST API & MQTT-struktur](#9-rest-api--mqtt-struktur)
11. [Kjøreinstruksjoner](#10-kjøreinstruksjoner)

---

## Oversikt & Utbrettet Struktur

Når `deploy-stack.ps1` kjøres, genereres en komplett mikrotjenestearkitektur i mappen `smarthouse-stack/`:

```
smarthouse-stack/
├── docker-compose.yml              # 8 samvirkende mikrotjenester på smarthouse-net
├── zigbee2mqtt/
│   └── data/
│       └── configuration.yaml      # Z2M broker-oppsett og discovery
├── homeassistant/
│   └── config/
│       ├── configuration.yaml      # MQTT sensorer for alle 4 rom
│       └── .storage/
│           └── core.config_entries # Forhåndskonfigurert EMQX MQTT-tilkobling
└── app/
    ├── go.mod                      # Go 1.22 modulavhengigheter (Paho MQTT, Gorilla WS)
    ├── main.go                     # Go Native Engine (Simulering, Hub, Zabbix Auto-Setup)
    ├── Dockerfile                  # Multi-stage build for ultra-kompakt Linux-binær
    └── public/
        └── index.html              # Three.js 3D Digital Twin SCADA UI
```

---

## 1. System- og Containerarkitektur

Diagrammet viser alle 8 containere på det felles Docker-nettverket `smarthouse-net`, eksponerte host-porter og kommunikasjonsprotokoller.

```mermaid
graph TB
    subgraph HostEnvironment["Host / Brukerflate (Windows / Browser)"]
        Browser["Nettleser / Operatør"]
        DockerHost["Docker Desktop Daemon (/var/run/docker.sock)"]
    end

    subgraph DockerNetwork["Docker Bridge Network: smarthouse-net"]
        
        subgraph MessagingLayer["Meldings- og IoT-bro"]
            EMQX["smarthouse-broker<br/>(emqx/emqx:5.8.0)<br/>MQTT Broker"]
            Z2M["smarthouse-bridge<br/>(koenkk/zigbee2mqtt:latest)<br/>Zigbee Bridge"]
        end

        subgraph CoreApplication["Kjerneapplikasjon (Go)"]
            GoApp["smarthouse-app<br/>(Go 1.22 Native Engine)<br/>Simulering, Hub, API & Zabbix Auto-Setup"]
            UI3D["Statisk 3D Digital Twin UI<br/>(Three.js / WebGL SCADA)"]
            GoApp --- UI3D
        end

        subgraph HomeAutomation["Smarthusstyring"]
            HA["smarthouse-homeassistant<br/>(home-assistant:stable)<br/>Dashbord & Automasjon"]
        end

        subgraph MonitoringStack["Overvåking & Telemetri (Zabbix 7.0)"]
            ZbxWeb["zabbix-web<br/>(Nginx + PHP 7.0)"]
            ZbxServer["zabbix-server<br/>(Zabbix Server pgsql 7.0)"]
            ZbxDB[("postgres-zabbix<br/>(PostgreSQL 16 Alpine)<br/>Volum: zabbix-db-data")]
            ZbxAgent["zabbix-agent2<br/>(Docker & Host metrics)"]
        end
    end

    %% Host tilgang
    Browser -->|HTTP :3000| GoApp
    Browser -->|WebSocket :3000/ws| GoApp
    Browser -->|HTTP :8123| HA
    Browser -->|HTTP :18083| EMQX
    Browser -->|HTTP :8080| ZbxWeb
    Browser -->|HTTP :8085| Z2M

    %% Intern kommunikasjon
    GoApp -->|MQTT TCP :1883<br/>Pub/Sub: zigbee2mqtt/#| EMQX
    Z2M -->|MQTT TCP :1883| EMQX
    HA -->|MQTT TCP :1883<br/>State topics| EMQX

    %% Zabbix-flyt
    GoApp -->|JSON-RPC Bearer Auth<br/>HTTP :8080/api_jsonrpc.php| ZbxWeb
    ZbxServer -->|HTTP Agent Poll :3000/api/metrics| GoApp
    ZbxServer <-->|SQL TCP :5432| ZbxDB
    ZbxWeb <-->|SQL TCP :5432| ZbxDB
    ZbxAgent -->|Active Checks :10051| ZbxServer
    DockerHost -.->|Montert sokkel| ZbxAgent
```

---

## 2. Go Native Engine Intern Arkitektur

Go-applikasjonen (`app/main.go`) fungerer som det sentrale nervesystemet for sanntidssimulering, telemetri, delsystemevaluering og overvåking.

```mermaid
graph LR
    subgraph GoNativeEngine["Go Native Engine (app/main.go)"]
        direction TB

        subgraph Simulation["Simuleringsmotor (Ticker 2500ms)"]
            SimLoop["Rom- og sensormodell<br/>(Living Room, Kitchen, Bedroom, Office)"]
            NoiseGen["Stokastisk støygenerator<br/>(Temp, Hum, CO2, Motion)"]
            SimLoop --- NoiseGen
        end

        subgraph StateManagement["Minnebasert Tilstand & Låsing"]
            Mutex["stateMu sync.RWMutex"]
            HouseState["houseState: map[Room]*RoomState"]
            SubsystemState["subsystems: Subsystems"]
            SensorsEnabled["sensorStatus: map[string]bool"]
            EventState["activeEvents: ActiveEvents"]
            Mutex --- HouseState
            Mutex --- SubsystemState
            Mutex --- SensorsEnabled
            Mutex --- EventState
        end

        subgraph LogicEngine["Regel- og Evalueringsmotor"]
            EvalFunc["evaluateSubsystemsLocked()"]
            FireLogic["Brannlogikk (Røyk, Rask temp-økning, Ekstremvarme)"]
            BurglarLogic["Innbruddslogikk (Armed + PIR-deteksjon)"]
            VentLogic["Ventilasjonslogikk (CO2 og Fuktighetstrinn 1-3)"]
            HvacLogic["HVAC-logikk (Varme under 20°C, Kjøling over 22.5°C)"]
            EvalFunc --> FireLogic
            EvalFunc --> BurglarLogic
            EvalFunc --> VentLogic
            EvalFunc --> HvacLogic
        end

        subgraph NetLayer["Nettverks- og API-lag"]
            MqttClient["Paho MQTT Klient<br/>Publiserer telemetri / Lytter på meldinger"]
            WsHub["Gorilla WsHub<br/>(Broadcast channel & Conn pool)"]
            HttpEndpoints["HTTP Router / Endepunkter<br/>/api/toggle-sensor<br/>/api/event<br/>/api/metrics<br/>/ & public/index.html"]
        end

        subgraph ZabbixProvisioner["Zabbix 7.0 Provisjonering"]
            ZbxAuth["user.login (Admin/zabbix)"]
            ZbxHosts["hostgroup / host.create<br/>(Smart-House-System)"]
            ZbxItems["item.create<br/>(Master Poll + 26 Dependent Items)"]
            ZbxTrigs["trigger.create<br/>(Fire, CO2, Temp, Burglar, HVAC)"]
            ZbxAuth --> ZbxHosts --> ZbxItems --> ZbxTrigs
        end
    end

    SimLoop -->|Låser og oppdaterer| StateManagement
    StateManagement -->|Input til regler| LogicEngine
    LogicEngine -->|Oppdaterer subsystemer| StateManagement
    StateManagement -->|Pakker BroadcastPayload| WsHub
    StateManagement -->|JSON payload| MqttClient
    HttpEndpoints -->|Modifiserer tilstand/events| StateManagement
    HttpEndpoints -->|Eksporterer flat JSON| ZabbixProvisioner
```

---

## 3. ER-diagram: Domene- og Tilstandsmodell

Domenemodellen definerer rom, sensorer, telemetri, subsystemer og hendelser:

```mermaid
erDiagram
    ROOM ||--|{ SENSOR : "inneholder"
    ROOM ||--|| ROOM_STATE : "har gjeldende"
    ROOM_STATE ||--o{ TELEMETRY_MESSAGE : "genererer"
    SUBSYSTEMS ||--|| FIRE_ALARM : "styrer"
    SUBSYSTEMS ||--|| BURGLAR_ALARM : "styrer"
    SUBSYSTEMS ||--|| VENTILATION : "styrer"
    SUBSYSTEMS ||--|| HVAC : "styrer"
    ACTIVE_EVENTS ||--|| SUBSYSTEMS : "påvirker"
    BROADCAST_PAYLOAD ||--|| SUBSYSTEMS : "inkluderer"
    BROADCAST_PAYLOAD ||--|{ ROOM_STATE : "inkluderer"

    ROOM {
        string id PK "living_room | kitchen | bedroom | office"
        string name "Visningsnavn"
    }

    SENSOR {
        string id PK "f.eks. kitchen_smoke, living_room_pir"
        string room FK
        string type "climate | pir | smoke"
        boolean enabled "Aktiv / deaktivert via UI"
    }

    ROOM_STATE {
        string room_id PK, FK
        float temperature "Gjeldende temperatur (°C)"
        float prev_temperature "Forrige temperatur for stigningsrate"
        float humidity "Relativ luftfuktighet (%)"
        int co2 "CO2-konsentrasjon (ppm)"
        int motion "0 eller 1"
        int smoke "0 eller 1"
        int64 last_temp_timestamp "Millisekunder"
    }

    SUBSYSTEMS {
        boolean alarm_armed "Global alarmstatus"
    }

    FIRE_ALARM {
        int active "0: Normal, 1: Utløst"
        string room "Rom med alarm eller 'none'"
        string reason "F.eks. Røyk + tempstigning"
    }

    BURGLAR_ALARM {
        int active "0: Normal, 1: Utløst"
        string detected_rooms "Rom med bevegelse"
    }

    VENTILATION {
        int level "Trinn 1, 2 eller 3"
        int target_rpm "level * 700 RPM"
        int max_co2 "Høyeste CO2 målt"
        float avg_humidity "Gjennomsnittlig luftfuktighet"
    }

    HVAC {
        boolean heating_active "Aktiv ved snitt-temp < 20.0°C"
        boolean cooling_active "Aktiv ved snitt-temp > 22.5°C"
        float target_temp "Måltemperatur (21.0°C)"
    }

    ACTIVE_EVENTS {
        boolean fire "Simulert brann aktiv"
        boolean co2_spike "Simulert CO2-økning aktiv"
        boolean alarm_armed "Innbruddsalarm armert"
        boolean heating "Varme aktiv"
        boolean cooling "Kjøling aktiv"
    }

    TELEMETRY_MESSAGE {
        string room "Romnavn"
        string sensor_type "temperature | humidity | co2 | motion | smoke"
        float value "Målt verdi"
        int64 timestamp "Tidsstempel"
    }
```

---

## 4. ER-diagram: Zabbix 7.0 & PostgreSQL Relasjonsmodell

Modellen viser hvordan Zabbix auto-provisjoneringen oppretter og strukturerer overvåkingen i PostgreSQL (`zabbix-db`):

```mermaid
erDiagram
    HOST_GROUP ||--|{ HOSTS_GROUPS : "knytter"
    HOSTS ||--|{ HOSTS_GROUPS : "tilhører"
    HOSTS ||--|{ INTERFACE : "har grensesnitt"
    HOSTS ||--|{ ITEMS : "eier metrikker"
    ITEMS ||--o{ ITEMS : "master_item genererer dependent_items"
    ITEMS ||--|{ ITEM_PREPROC : "har JSONPath-uttrekk"
    ITEMS ||--o{ FUNCTIONS : "brukes i"
    TRIGGERS ||--|{ FUNCTIONS : "evaluerer"
    TRIGGERS ||--o{ EVENTS : "genererer ved feil"
    ITEMS ||--o{ HISTORY : "historiske verdier"

    HOST_GROUP {
        bigint groupid PK
        string name "Smart House"
    }

    HOSTS {
        bigint hostid PK
        string host "Smart-House-System / Docker-Desktop-Host"
        int status "0: Monitored"
    }

    INTERFACE {
        bigint interfaceid PK
        bigint hostid FK
        string dns "app / zabbix-agent2"
        string port "3000 / 10050"
        int type "1: Agent"
    }

    ITEMS {
        bigint itemid PK
        bigint hostid FK
        string name "Smart House Telemetry Master Poll / Rom-metrikk"
        string key_ "smarthouse.metrics / living_room_temp osv."
        int type "19: HTTP Agent, 18: Dependent Item"
        string url "http://app:3000/api/metrics"
        string delay "3s"
        bigint master_itemid FK "Peker til master for type 18"
        int value_type "0: Float, 3: Numeric unsigned, 4: Text"
        string units "°C, %, ppm, Stage"
    }

    ITEM_PREPROC {
        bigint item_preprocid PK
        bigint itemid FK
        int type "12: JSONPath"
        string params "f.eks. $.living_room_temp"
    }

    TRIGGERS {
        bigint triggerid PK
        string description "Kritisk brann, Høy CO2, etc."
        string expression "last(/Smart-House-System/fire_alarm_active)=1"
        int priority "1: Info opp til 5: Katastrofe"
    }

    EVENTS {
        bigint eventid PK
        int source "0: Trigger"
        int object "0: Trigger"
        bigint objectid FK "triggerid"
        int value "1: Problem, 0: Resolved"
        int clock "Unix timestamp"
    }
```

---

## 5. Sekvensdiagram: Telemetriflyt og Hendelsesinjeksjon

Eksempel på sanntids hendelsesflyt når en operatør utløser en brannsimulering fra 3D-grensesnittet:

```mermaid
sequenceDiagram
    autonumber
    actor Bruker as Operatør (3D Digital Twin UI)
    participant Web as Go Web / API (:3000)
    participant State as State Engine & Mutex
    participant MQTT as EMQX Broker (:1883)
    participant HA as Home Assistant (:8123)
    participant Zbx as Zabbix Server (:10051)

    Note over Bruker,Web: Bruker trykker på [Kitchen Fire & Smoke Spike]
    Bruker->>Web: POST /api/event?type=fire
    activate Web
    Web->>State: stateMu.Lock()
    State->>State: Setter simulatedFireActive = true
    State->>State: kitchen.Smoke = 1, kitchen.Temperature = 65.0°C
    State->>State: evaluateSubsystemsLocked() -> FireAlarm.Active = 1
    State->>State: stateMu.Unlock()

    par Publiser til MQTT
        Web->>MQTT: PUBLISH zigbee2mqtt/kitchen/smoke {"room":"kitchen","sensorType":"smoke","value":1}
        Web->>MQTT: PUBLISH zigbee2mqtt/kitchen/temperature {"room":"kitchen","sensorType":"temperature","value":65.0}
    and Kringkast til 3D UI
        Web->>Bruker: WebSocket Broadcast (houseState, subsystems, activeEvents)
    end
    Web-->>Bruker: HTTP 200 {"status":"ok","event":"fire"}
    deactivate Web

    Note over Bruker: 3D Twin tennes: flammer, røyk, alarmlyd, rød vignett

    MQTT->>HA: Leverer state topics til HA sensorer
    Note over HA: Kjøkken-temperatur 65°C & Kitchen Smoke ON

    opt Zabbix Polling syklus (hvert 3. sekund)
        Zbx->>Web: GET /api/metrics (HTTP Agent master poll)
        Web-->>Zbx: JSON med flat metrics (fire_alarm_active=1.0)
        Note over Zbx: Evaluerer triggers: last(/Smart-House-System/fire_alarm_active)=1
        Zbx->>Zbx: Utløser Alarm: [CRITICAL FIRE] Severity 5 (Disaster)
    end
```

---

## 6. Tilstandsdiagram for Hoveddelsystemer

```mermaid
stateDiagram-v2
    [*] --> Sikkerhetssystem

    state Sikkerhetssystem {
        [*] --> Disarmed
        Disarmed --> Armed : Toggle Arming
        Armed --> Disarmed : Toggle Arming
        Armed --> IntrusionAlert : PIR Motion detektert i et rom
        IntrusionAlert --> Armed : Motion = 0 eller Toggle Arm
    }

    state Brannvarsling {
        [*] --> NormalTilstand
        NormalTilstand --> PreAlarm : Røyk detektert (Smoke = 1)
        NormalTilstand --> BrannAlarm : Ekstremvarme (> 55°C)
        PreAlarm --> BrannAlarm : Rask temp-stigning (+2°C) eller Temp > 32°C
        BrannAlarm --> NormalTilstand : Event 'clear_fire'
    }

    state Ventilasjon {
        [*] --> Trinn1 : CO2 <= 800 ppm & Fukt <= 55%
        Trinn1 --> Trinn2 : CO2 > 800 ppm eller Fukt > 55%
        Trinn2 --> Trinn3 : CO2 > 1200 ppm eller Fukt > 65%
        Trinn3 --> Trinn2 : CO2 faller under 1200 ppm
        Trinn2 --> Trinn1 : CO2 faller under 800 ppm
    }

    state HVAC_Klimastyring {
        [*] --> Idle : 20.0°C <= Snitt-temp <= 22.5°C
        Idle --> VarmeAktiv : Snitt-temp < 20.0°C (f.eks. Freeze Event 16°C)
        Idle --> KjolingAktiv : Snitt-temp > 22.5°C (f.eks. Heatwave 28.5°C)
        VarmeAktiv --> Idle : Snitt-temp >= 20.0°C
        KjolingAktiv --> Idle : Snitt-temp <= 22.5°C
    }
```

---

## 7. Deployment- og Utførelsesflyt

```mermaid
flowchart TD
    Start([Kjør deploy-stack.ps1]) --> Step0[0. Verifiser & Start Docker Desktop]
    Step0 --> DockerRunning{Kjører Docker Daemon?}
    DockerRunning -- Nei --> LaunchDocker[Start Docker Desktop.exe og vent inntil 90s]
    LaunchDocker --> DockerRunning
    DockerRunning -- Ja --> Step1[1. Cleanup eldre containere & Finn ledige porter]
    
    Step1 --> PortAlloc[Alloker dynamisk ledige porter:<br/>Z2M: 8085+, Zabbix: 8080+, EMQX: 18083+, HA: 8123+]
    PortAlloc --> Step2[2. Opprett katalogstruktur: smarthouse-stack/...]
    
    Step2 --> Step3[3. Generer zigbee2mqtt/data/configuration.yaml]
    Step3 --> Step4[4. Generer homeassistant/config/configuration.yaml & .storage]
    Step4 --> Step5[5. Generer app/go.mod]
    Step5 --> Step6[6. Generer app/main.go - Go Native Engine]
    Step6 --> Step7[7. Generer app/public/index.html - 3D Digital Twin UI]
    Step7 --> Step8[8. Generer app/Dockerfile - Multi-stage build]
    Step8 --> Step9[9. Generer docker-compose.yml med 8 containere]
    
    Step9 --> Step10[10. Utfør: docker compose up -d --build]
    Step10 --> ServicesReady{Bygging & oppstart OK?}
    ServicesReady -- Nei --> Fail([Feilmelding & Avbryt])
    ServicesReady -- Ja --> Success([Ferdig utrullet:<br/>Web 3D: :3000<br/>HA: :8123<br/>EMQX: :18083<br/>Zabbix: :8080<br/>Z2M: :8085])
```

---

## 8. Porter og Nettverk

| Tjeneste | Container | Standard Port | Protokoll | Beskrivelse |
| :--- | :--- | :--- | :--- | :--- |
| **3D Digital Twin / Go App** | `smarthouse-app` | `3000` | HTTP / WS | Three.js SCADA UI, REST API og Zabbix telemetri |
| **Home Assistant** | `smarthouse-homeassistant` | `8123` | HTTP | Smarthus-dashbord med forhåndsdefinerte sensorer |
| **EMQX Broker** | `smarthouse-broker` | `1883`, `18083` | TCP / HTTP | MQTT-megler og EMQX Web Dashboard (`admin`/`public`) |
| **Zabbix Web UI** | `zabbix-web` | `8080` | HTTP | Overvåkingsportal og JSON-RPC API (`Admin`/`zabbix`) |
| **Zabbix Server** | `zabbix-server` | `10051` | TCP | Zabbix kjerne med PostgreSQL backend |
| **Zigbee2MQTT** | `smarthouse-bridge` | `8085` | HTTP | Frontend for Zigbee bridge og enheter |
| **PostgreSQL** | `zabbix-db` | *Intern 5432* | SQL | Persistent database for Zabbix (`zabbix-db-data`) |
| **Zabbix Agent 2** | `zabbix-agent2` | *Intern 10050* | TCP | Docker-socket og containerovervåking |

---

## 9. REST API & MQTT-struktur

### REST Endepunkter (`smarthouse-app:3000`)
- `GET /api/metrics`: Returnerer flat JSON-struktur for Zabbix HTTP Agent master polling.
- `POST /api/event?type={fire|clear_fire|co2_spike|freeze|heatwave|toggle_arm}`: Injiserer hendelser og tester delsystemrespons i sanntid.
- `POST /api/toggle-sensor?id={sensor_id}`: Skrur virtuelle sensorer av/på (f.eks. `kitchen_smoke`, `living_room_pir`).
- `GET /ws`: WebSocket-endepunkt for full sanntidssynkronisering mot 3D-tvillingen.

### MQTT Emne-hierarki (`zigbee2mqtt/`)
- `zigbee2mqtt/<room>/temperature`
- `zigbee2mqtt/<room>/humidity`
- `zigbee2mqtt/<room>/co2`
- `zigbee2mqtt/<room>/motion`
- `zigbee2mqtt/kitchen/smoke`

---

## 10. Kjøreinstruksjoner

1. Åpne en PowerShell-terminal som administrator eller vanlig bruker.
2. Naviger til mappen:
   ```powershell
   cd C:\dev\mqttStack-goBackend-main
   ```
3. Start distribusjonen:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\deploy-stack.ps1
   ```
4. Åpne nettleseren på `http://localhost:3000` for 3D Digital Twin, eller portene angitt i terminalen ved fullført utrulling.
