# OpenRemote 技术架构与功能模块分析

> 本文基于仓库 `openremote/core` 分支 `mydev`（HEAD `72aff0f`）的源码静态分析整理，所有结论均可在代码中追溯到具体文件。
> 数据库表与字段的逐列说明见配套文档 [`DATABASE_SCHEMA.md`](./DATABASE_SCHEMA.md)。

---

## 目录

1. [项目概览](#1-项目概览)
2. [代码库结构与 Gradle 模块](#2-代码库结构与-gradle-模块)
3. [整体运行时架构](#3-整体运行时架构)
4. [Container 内核：服务容器与基础设施](#4-container-内核服务容器与基础设施)
5. [Model 模块：资产模型与领域模型](#5-model-模块资产模型与领域模型)
6. [Manager 模块：核心业务服务](#6-manager-模块核心业务服务)
7. [属性事件处理管道（系统数据主干）](#7-属性事件处理管道系统数据主干)
8. [Agent 模块：协议接入层](#8-agent-模块协议接入层)
9. [规则与自动化引擎](#9-规则与自动化引擎)
10. [安全、身份与多租户](#10-安全身份与多租户)
11. [对外接口体系（REST / WebSocket / MQTT）](#11-对外接口体系rest--websocket--mqtt)
12. [边缘网关与隧道](#12-边缘网关与隧道)
13. [数据持久化与时序数据](#13-数据持久化与时序数据)
14. [前端架构（UI）](#14-前端架构ui)
15. [可观测性与健康检查](#15-可观测性与健康检查)
16. [构建、测试与 CI/CD](#16-构建测试与-cicd)
17. [部署形态](#17-部署形态)
18. [扩展点汇总](#18-扩展点汇总)
19. [架构特征评述](#19-架构特征评述)

---

## 1. 项目概览

OpenRemote 是一个 100% 开源（AGPL-3.0-or-later）的 IoT 平台，提供从设备接入、资产建模、规则自动化、数据分析到前端可视化的完整能力栈。

**技术栈定位**

| 层面 | 技术选型 |
|---|---|
| 后端语言 | Java 21（`project.gradle:433` 设定 `sourceCompatibility = VERSION_21`） |
| 测试语言 | Groovy + Spock 2.4（`spock = "2.4-groovy-5.0"`） |
| 构建系统 | Gradle（多项目，版本目录 `gradle/libs.versions.toml`） |
| 前端 | TypeScript + Lit（Web Components）+ Vaadin，yarn workspaces + rsbuild |
| HTTP 容器 | Undertow 2.3 + RESTEasy 7（Jakarta REST 4.0） |
| 消息/集成 | Apache Camel 4.22（内部路由）、ActiveMQ Artemis 2.55（MQTT Broker） |
| ORM / 迁移 | Hibernate 7.4 + HikariCP + Flyway 13 |
| 数据库 | PostgreSQL + PostGIS + ltree + TimescaleDB |
| 身份认证 | Keycloak 26（OIDC/JWT） |
| 规则引擎 | Easy Rules 4.1 + Groovy 5 沙箱 + 自研 JSON/Flow 规则编译器 |
| 指标/追踪 | Micrometer + Prometheus、OpenTelemetry Java Agent（可选） |

**核心能力**：设备管理与自动置备、可自定义资产类型、四种规则语言（when-then/flow/JavaScript/Groovy）、数据分析、多协议 Agent、多租户（Realm）、用户与角色管理、边缘网关、前端 Web Components 与移动 Console、Insights 仪表盘构建器。

---

## 2. 代码库结构与 Gradle 模块

`settings.gradle` 采用**动态包含**：扫描 `**/build.gradle`（排除 `.git`、`build`、`node_modules`、`dist`、`lib`、`generic_app`），任何含 `build.gradle` 且无 `.buildignore` 的目录自动成为子项目。

```
openremote/
├── container/     运行时内核：ContainerService 注册表、持久化、Web、消息、安全基元
├── model/         领域模型 + REST 接口定义 + 资产模型描述符（383 个 Java 文件）
├── model-util/    typescript-generator 扩展，用于把 Java 模型生成 model.ts
├── agent/         协议实现层：20+ 协议族（406 个 Java 文件）
├── manager/       核心后端应用（136 个 Java 文件），main = org.openremote.manager.Main
├── setup/         多 sourceSet 的部署/测试数据初始化（integration/datetime/load1/load2/clustering/notification）
├── test/          集成测试项目（82 个 Spock 规格）
├── deployment/    自定义部署资源（manager app、map、keycloak 主题、query-exporter）
├── ui/            前端 monorepo：app/（manager、insights、swagger、storybook、shared）+ component/（30 个包）
├── profile/       Docker Compose profiles：deploy/demo/dev-testing/dev-ui/dev-map/dev-proxy
├── kubernetes/    Helm charts（manager、proxy、or-setup）+ EKS 脚本
├── balena/        Balena 边缘设备部署
├── .ci_cd/        AWS 部署脚本与 CI 配置
└── tools/         IntelliJ 配置、spotless 配置
```

**模块依赖方向**（`manager/build.gradle`）：

```
model-util ──> (构建期) model
model  ──>  container  ──>  agent  ──>  manager  ──>  setup / test
             (manager 同时 api 依赖 container、agent、model)
```

`model` 是无容器依赖的纯模型层，可被前端代码生成器和第三方客户端独立复用（发布为 Maven artifact `io.openremote:openremote-model`）。

---

## 3. 整体运行时架构

```
                         ┌──────────────────────────────────────┐
  浏览器 / 移动 Console   │  HAProxy (openremote/proxy)          │
  第三方系统             │  443 HTTPS/WSS · 8883 MQTTS · 80 ACME │
                         └───────────────┬──────────────────────┘
                                         │
      ┌──────────────────────────────────┴───────────────────────────────────┐
      │                       Manager (单 JVM 进程)                          │
      │                                                                      │
      │  ┌────────────────── ManagerWebService (Undertow) ─────────────────┐ │
      │  │  /api/{realm}/*  REST (RESTEasy)   │  /websocket/events  (WS)   │ │
      │  │  /manager /insights /swagger  静态资源   │  /  → 重定向          │ │
      │  └─────────────────────────────────────────────────────────────────┘ │
      │  ┌────────────── MQTTBrokerService (Artemis, 1883) ────────────────┐ │
      │  │  DefaultMQTTHandler · UserAssetProvisioningMQTTHandler ·        │ │
      │  │  ConnectionMonitorHandler                                       │ │
      │  └─────────────────────────────────────────────────────────────────┘ │
      │                                                                      │
      │   ClientEventService  ←→  MessageBrokerService (Camel) ←→ 内部路由   │
      │              │                                                       │
      │   AssetProcessingService  ── 属性事件主干（拦截器链 + 发布）          │
      │        │          │            │            │           │            │
      │   AgentService  RulesService  AssetStorage  Datapoint  Gateway…      │
      │        │                                                             │
      │   Protocol 实例（HTTP/MQTT/Modbus/KNX/Z-Wave/…）                     │
      └──────┬────────────────────────────────┬──────────────────────────────┘
             │                                │
    ┌────────┴────────┐              ┌────────┴────────┐
    │  Keycloak 26    │              │  PostgreSQL     │
    │  (OIDC/JWT)     │              │  PostGIS/ltree/ │
    │  schema: public │              │  TimescaleDB    │
    └────────┬────────┘              └────────┬────────┘
             │                                │
             └─ 同一数据库 `openremote`，不同 schema ─┘
                （Keycloak → public，Manager → openremote）
```

**4 个容器（`docker-compose.yml`）**：`proxy`（HAProxy + Let's Encrypt）、`postgresql`（openremote/postgresql）、`keycloak`、`manager`。Manager 依赖 Keycloak 健康、Keycloak 依赖 PostgreSQL 健康。

Keycloak 与 Manager **共用同一个 PostgreSQL 数据库 `openremote`，但使用不同 schema**（`KC_DB_SCHEMA=public` vs `OR_DB_SCHEMA=openremote`，见 `profile/deploy.yml:244,414`）。这使 Manager 能通过只读视图 `RealmView` 直接读取 Keycloak 的 realm 数据，并让 Java 版 Flyway 迁移（`AbstractKeycloakRolesMigration` 等）直接操作 Keycloak 的角色表。

---

## 4. Container 内核：服务容器与基础设施

### 4.1 ContainerService 生命周期

`org.openremote.container.Container`（`container/src/main/java/org/openremote/container/Container.java`）是一个**线程安全的 `ContainerService` 注册表**，无 Spring/CDI 等 DI 框架，完全基于 JDK `ServiceLoader`：

1. 无参构造器通过 `ServiceLoader.load(ContainerService.class)` 发现所有服务；
2. 按 `ContainerService#getPriority()` 升序排序（`HIGH_PRIORITY = Integer.MIN_VALUE + 1000`、`MED_PRIORITY = 0`、`DEFAULT_PRIORITY = 1000`、`LOW_PRIORITY = Integer.MAX_VALUE - 1000`）；
3. `start()` 分两阶段：先对所有服务调用 `init(container)`，随后 `ValueUtil.initialise(container)` 初始化资产模型，最后再对所有服务调用 `start(container)`；
4. 注册 JVM shutdown hook 调用 `stop()`，按逆序停止服务。

两阶段启动让服务可以在 `init` 阶段相互查找（`getService(Class)`）而不依赖启动顺序，在 `start` 阶段才真正建立连接。

**共享线程池**（静态字段，全局可用）：

- `Container.EXECUTOR`：`ThreadPoolExecutor`，core = `min(CPU, 8)`（`OR_EXECUTOR_THREADS_MIN`），max = `CPU × 10`（`OR_EXECUTOR_THREADS_MAX`），`SynchronousQueue` + `CallerRunsPolicy` 背压；
- `Container.SCHEDULED_EXECUTOR`：固定大小 `min(CPU, 4)`（`OR_SCHEDULED_EXECUTOR_THREADS`）。

启用指标时（`OR_METRICS_ENABLED`，默认 true）两个池都被 `ExecutorServiceMetrics` 包装并注册到 Prometheus registry。

### 4.2 服务注册清单与启动顺序

`manager/src/main/resources/META-INF/services/org.openremote.model.ContainerService` 列出 39 个服务，实际顺序由 priority 决定。关键服务及其职责：

| 服务 | 职责 |
|---|---|
| `TimerService` | 可控时钟（测试中可用伪时钟做时间旅行） |
| `ManagerPersistenceService` | Hibernate/Flyway/HikariCP 启动，实体发现 |
| `ManagerIdentityService` | 身份提供者选择（`OR_IDENTITY_PROVIDER`，目前仅 `keycloak`） |
| `SetupService` / `KeycloakInitService` | 启动期数据与 Keycloak realm/client/role 初始化 |
| `ClientEventService` | 客户端/服务端事件总线 |
| `MessageBrokerService` | Camel `CamelContext` 容器 |
| `AssetStorageService` | 资产 CRUD、`AssetQuery` → SQL |
| `AssetProcessingService` | 属性事件处理主干 |
| `RulesetStorageService` / `RulesService` | 规则集存储与规则引擎管理 |
| `AgentService` | Agent 资产 ↔ Protocol 实例生命周期 |
| `AssetDatapointService` / `AssetPredictedDatapointService` / `ApplyPredictedDataPointsService` | 历史与预测时序数据 |
| `AttributeLinkingService` | 属性间链接（`ATTRIBUTE_LINKS` meta） |
| `ForecastService` | 基于 `FORECAST` meta 的预测值计算 |
| `NotificationService` + 3 个 handler | 通知（Push/Email/Localized） |
| `WebhookService` | 出站 Webhook |
| `AlarmService` | 告警 |
| `DashboardStorageService` | Insights 仪表盘 |
| `GatewayService` / `GatewayClientService` | 中心侧网关管理 / 边缘侧出站连接 |
| `MQTTBrokerService` | 内嵌 Artemis MQTT Broker |
| `ProvisioningService` | 设备自动置备（X.509） |
| `AssetModelService` | 资产模型元数据 REST 暴露 |
| `MapService` | 矢量瓦片与地图样式 |
| `ConsoleAppService` | Console/App 清单 |
| `ConfigurationService` | 运行时管理端配置（品牌化等） |
| `ExternalServiceRegistryService` | 外部服务注册（租约制） |
| `KeyStoreServiceImpl` | 密钥库（协议 TLS 客户端证书等） |
| `AuthorisationService` | 授权钩子 |
| `ORConsoleGeofenceAssetAdapter` | 移动端地理围栏下发 |
| `HealthService` | 健康检查聚合 |
| `ManagerWebService` | HTTP/WS 服务（最后启动） |

### 4.3 Web 基础设施（`container/web`）

- `WebService` / `WebApplication`：Undertow + RESTEasy 装配；
- 过滤器链：`JWTAuthenticationFilter`、`SecurityServletFilter`、`CORSConfig`、`RealmPathExtractorFilter`（从 `/api/{realm}/…` 提取 realm）、`RealmInjectorFilter`、`DynamicValueInjectorFilter` / `DynamicTimeInjectorFilter`（`%VALUE%` / `%TIME%` 占位符替换）、`AlreadyGZippedFilter`、`LoggingFilter`；
- `WebTargetBuilder`：出站 JAX-RS 客户端构造器，配合 `OAuthFilter`、`FollowRedirectFilter`、`PermanentFailureFilter`（熔断）供 HTTP 协议 Agent 使用；
- 静态资源：`CompositeResourceManager` + `DirectoryAwareClassPathResourceManager`，支持内置 docroot（`OR_APP_DOCROOT`，默认 `ui/app`）与自定义 docroot（`OR_CUSTOM_APP_DOCROOT`，默认 `deployment/manager/app`）叠加，自定义优先；
- 根路径重定向：`OR_ROOT_REDIRECT_PATH`（默认 `/manager`）。

### 4.4 持久化基础设施（`container/persistence`）

`PersistenceService` 负责：Hibernate `EntityManagerFactory` 构建、HikariCP 连接池（`OR_DB_POOL_MIN_SIZE=5`、`OR_DB_POOL_MAX_SIZE=20`、`OR_DB_CONNECTION_TIMEOUT_SECONDS=300`）、Flyway 迁移、`PersistenceEventInterceptor`（把实体变更转成 `PersistenceEvent` 发到 Camel，驱动各服务的缓存/部署刷新）、`JsonFormatMapper`（jsonb ↔ Java 对象）、`PersistenceHealthStatusProvider`。

数据库配置项：`OR_DB_VENDOR`（默认 POSTGRES）、`OR_DB_HOST`、`OR_DB_PORT`（5432）、`OR_DB_NAME`（openremote）、`OR_DB_SCHEMA`（openremote）、`OR_DB_USER`/`OR_DB_PASSWORD`、`OR_DB_FLYWAY_OUT_OF_ORDER`。文件存储目录由 `OR_STORAGE_DIR`（默认 `tmp`，容器内为 `/storage`）指定。

---

## 5. Model 模块：资产模型与领域模型

### 5.1 资产 / 属性 / 元数据三层模型

OpenRemote 的核心抽象是一个**自描述的、带元数据的属性树**：

```
Asset (实体, jsonb ATTRIBUTES 列)
 └── AttributeMap (NamedMap<Attribute<?>>)
      └── Attribute<T>  (name, ValueDescriptor<T>, value, timestamp)
           └── MetaMap (NamedMap<MetaItem<?>>)
                └── MetaItem<T>  (MetaItemDescriptor<T>, value)
```

- `ValueDescriptor<T>`（`model/value/ValueType.java`）定义值类型（含数组、约束、单位、格式）；
- `AttributeDescriptor<T>` 定义某资产类型上某属性的"模板"；
- `MetaItemDescriptor<T>` 定义元数据项类型，`MetaItemType` 提供 23 个内置元数据：

| 类别 | MetaItem |
|---|---|
| 协议绑定 | `AGENT_LINK`、`AGENT_LINK_CONFIG` |
| 属性联动 | `ATTRIBUTE_LINKS` |
| 访问控制 | `ACCESS_PUBLIC_READ/WRITE`、`ACCESS_RESTRICTED_READ/WRITE`、`READ_ONLY` |
| 时序数据 | `STORE_DATA_POINTS`、`DATA_POINTS_MAX_AGE_DAYS`、`HAS_PREDICTED_DATA_POINTS`、`APPLY_PREDICTED_DATA_POINTS`、`FORECAST` |
| 规则 | `RULE_STATE`、`RULE_RESET_IMMEDIATE` |
| 展示 | `LABEL`、`FORMAT`、`UNITS`、`CONSTRAINTS`、`SECRET`、`MULTILINE`、`SHOW_ON_DASHBOARD`、`MOMENTARY` |
| 其他 | `USER_CONNECTED` |

元数据驱动行为，是整个平台**可配置而非硬编码**的关键：一个属性是否入库、是否进入规则引擎、是否对公开用户可读，全部由 meta 决定（见 §7）。

### 5.2 内置资产类型

`model/asset/impl` 提供 21 个资产类型，均为 Hibernate `@Entity`（单表继承，`TYPE` 列区分）：

`ThingAsset`（通用根类型）、`GroupAsset`、`BuildingAsset`、`CityAsset`、`RoomAsset`、`DoorAsset`、`LightAsset`、`PlugAsset`、`ThermostatAsset`、`VentilationAsset`、`WeatherAsset`、`EnvironmentSensorAsset`、`GroundwaterSensorAsset`、`MicrophoneAsset`、`ParkingAsset`、`PeopleCounterAsset`、`PresenceSensorAsset`、`ShipAsset`、`ConsoleAsset`（移动端）、`GatewayAsset`（边缘网关）、`UnknownAsset`。

### 5.3 资产模型注册表 `ValueUtil`

`model/util/ValueUtil.java` 是资产模型的运行时注册表与 JSON 工具：

- 持有全局配置好的 Jackson `ObjectMapper`（`ValueUtil.JSON`）；
- 通过 `AssetModelProvider` SPI（`ServiceLoader`）发现模型；`StandardModelProvider` 实现基于反射的**约定式发现**：新增 `Asset`/`Agent` 子类并遵循描述符声明约定即自动注册；
- 提供值类型强制转换（`getValueCoerced`）、JSR-380 校验（`validate`）、`ValueFilter` 应用（`JsonPathFilter`、`RegexValueFilter`、`SubStringValueFilter`、`MathExpressionValueFilter`）。

自定义扩展只需提供新的 `Asset` 子类或自定义 `AssetModelProvider`，无需改动平台代码（见 §18）。

### 5.4 查询 DSL

`model/query/AssetQuery` 是一个可序列化的查询对象，由 `AssetStorageService` 翻译成 SQL：

```java
public boolean recursive;              // 递归包含后代
public Select select;                  // 字段/属性裁剪
public Access access;                  // PRIVATE / PROTECTED / PUBLIC
public String[] ids;
public StringPredicate[] names;
public ParentPredicate[] parents;
public PathPredicate[] paths;          // 基于 ltree PATH 列
public RealmPredicate realm;
public String[] userIds;               // 经 USER_ASSET_LINK
public String[] types;
public LogicGroup<AttributePredicate> attributes;  // AND/OR 嵌套的属性条件
public Boolean includeDeletePending;
public OrderBy orderBy;
public int limit, offset;
```

谓词体系（`model/query/filter`）包含字符串、数值、布尔、日期时间、数组、空值、日历事件，以及三种地理围栏谓词（`RadialGeofencePredicate`、`RectangularGeofencePredicate`、`GeoJSONGeofencePredicate`，依托 PostGIS）。同类 DSL 还有 `UserQuery`、`RulesetQuery`、`DashboardQuery`。

---

## 6. Manager 模块：核心业务服务

Manager 的服务大多继承 Camel `RouteBuilder` 并实现 `ContainerService`，既是容器托管服务，也在 `MessageBrokerService` 的 `CamelContext` 中注册内部路由。

### 6.1 资产域

| 类 | 职责 |
|---|---|
| `AssetStorageService` | 资产 CRUD、`AssetQuery` → 原生 SQL（含 ltree 路径、PostGIS、jsonb 属性谓词）、`UserAssetLink` 管理、属性值原子更新（`updateAttributeValue`） |
| `AssetProcessingService` | 属性事件主干（见 §7） |
| `AssetModelService` + `AssetModelResourceImpl` | 把资产/属性/元数据描述符通过 REST 暴露给前端，驱动 UI 的动态表单 |
| `AttributeLinkingService` | 订阅 `AttributeEvent`，按 `ATTRIBUTE_LINKS` meta 把值（可经 `ValueFilter` 和值映射转换）写到其他属性 |
| `ForecastService` | 按 `FORECAST` meta（如 `ForecastConfigurationWeightedExponentialAverage` 加权指数平均）周期性计算预测值写入预测时序表 |
| `ConsoleResourceImpl` | 移动 Console 注册（`ConsoleRegistration`、`ConsoleProvider`） |

### 6.2 时序数据域

- `AbstractDatapointService`：共用的写入/聚合/查询逻辑；
- `AssetDatapointService`：历史数据写入与**基于 TimescaleDB `drop_chunks()` 的周粒度保留清理**（对齐 7 天 chunk interval，默认无限保留，可用 `OR_DATA_POINTS_MAX_AGE_DAYS` 全局配置、`dataPointsMaxAgeDays` meta 按属性覆盖）；
- `AssetPredictedDatapointService`：预测数据表；
- `ApplyPredictedDataPointsService`：按 `APPLY_PREDICTED_DATA_POINTS` meta 将到期的预测值"落地"为实际属性值；
- 查询模型 `model/datapoint/query` 支持多种聚合方式（`V20260506_01__DatapointMetricQuery.sql` 引入 metric query 支持）。

### 6.3 通知与告警

`NotificationService` + `NotificationHandler` SPI：

- `PushNotificationHandler`（Firebase Admin SDK → FCM，支持 `PushNotificationAction`/`PushNotificationButton` 交互）；
- `EmailNotificationHandler`（Angus Mail SMTP，支持 OAuth2：`OR_EMAIL_OAUTH2_URL`/`CLIENT_ID`/`CLIENT_SECRET`/`SCOPES`）；
- `LocalizedNotificationHandler`（`LocalizedNotificationMessage`，按用户语言选择内容）。

通知目标 `Notification.TargetType`：`REALM` / `USER` / `ASSET` / `CUSTOM`；`RepeatFrequency` 控制去重节流；发送记录落 `NOTIFICATION` 表（`SentNotification`）。

`AlarmService`：`Alarm` 含 `Source`、`Status`、`Severity` 三个枚举，可通过 `ALARM_ASSET_LINK` 关联资产，支持 assignee；表由 `V20240813_01__Alarms.sql` 创建。

`WebhookService`：出站 HTTP 回调，供规则 `RuleActionWebhook` 使用。

### 6.4 其他业务服务

- `DashboardStorageService` / `DashboardResourceImpl`：Insights 仪表盘持久化，`DashboardTemplate` + `DashboardWidget` + `DashboardGridItem` + 响应式 `DashboardScreenPreset`/`DashboardScalingPreset`，`DashboardAccess` 控制可见性（`V20250422_01__DashboardAccess.sql`）；
- `MapService`：矢量瓦片（mbtiles）与 Mapbox 风格 JSON 服务，按 realm 定制；
- `ConsoleAppService` / `AppResourceImpl`：可用 App 与 Console 清单；
- `ConfigurationService` / `ConfigurationResourceImpl`：运行时管理端配置（`ManagerConfig`，品牌化/主题/favicon）；
- `SyslogService`：平台自身日志持久化到 `SYSLOG_EVENT` 表并通过事件总线推送给 UI 日志页（`SyslogCategory` 分类）；
- `ExternalServiceRegistryService`：**租约制外部服务注册表**，支持全局（跨租户）与 realm 绑定服务，同一 service ID 可注册多实例以支持水平扩展与高可用；定时任务把过期实例标记为不可用、长期过期的实例注销；并向 `ClientEventService` 注册订阅授权器，按 realm 与用户角色过滤 `ExternalServiceEvent`；
- `SimulatorService`：把 UI 连接到 `SimulatorProtocol`，用于无硬件仿真；
- `ProvisioningService`：设备自动置备配置（`X509ProvisioningConfig`），配合 MQTT 置备通道（见 §11.3）。

---

## 7. 属性事件处理管道（系统数据主干）

`AttributeEvent` 是平台的通用数据单元，所有读写——无论来自 REST、WebSocket、MQTT、协议、规则还是网关——都汇聚到 `AssetProcessingService`。处理流程（`AssetProcessingService.java:~420-580`）：

```
入口（REST / WebSocket / MQTT / Protocol / Rules / Gateway）
   │
   ▼  Camel 路由 + 单事务 (EntityManager)
1. 解析资产与属性，权限与存在性校验
2. 值类型强制转换 (ValueUtil.getValueCoerced) —— 失败 → INVALID_VALUE
3. 构造 enrichedEvent（携带 asset、attribute、oldValue、oldValueTimestamp、source）
4. JSR-380 约束校验 (ValueUtil.validate) —— 失败 → INVALID_VALUE
5. 拦截器链（按 getPriority 升序；任一返回 true 即短路）
      ├── AgentService#onAttributeEventIntercepted   —— 有 AGENT_LINK 的属性：转交 Protocol，不落库
      └── GatewayService 拦截器                      —— 目标是 GatewayAsset 后代：转发给边缘网关
6. 未被拦截：
      ├── 事件时间戳早于当前值 → 发布 OutdatedAttributeEvent（不落库）
      └── assetStorageService.updateAttributeValue(em, event)
             成功 → 作为待发布事件；失败 → STATE_STORAGE_FAILED
7. clientEventService.publishEvent(result)
```

**关键设计**：拦截器**不是**下游消费者。落库后的事件通过 `ClientEventService` 的内部订阅扩散给下游：

```java
// RulesService.java:225
clientEventService.addSubscription(AttributeEvent.class, null, this::onAttributeEvent);
// AssetDatapointService.java:153
clientEventService.addSubscription(AttributeEvent.class, null, this::onAttributeEvent);
// AttributeLinkingService.java:64
clientEventService.addSubscription(AttributeEvent.class, null, this::onAttributeEvent);
```

这把"**能否写入**"（拦截器，同事务内、可短路）与"**写入后做什么**"（事件订阅，事务后、互不阻塞）清晰分离。

**错误处理现状**：失败事件抛 `AssetProcessingException` 并记录日志，**当前没有死信队列与重试机制**（源码 javadoc 明确说明）。

**协议写入回环防护**：来自某 `Agent` `Protocol` 的 `AttributeEvent` 再次经过 `AgentService` 时不会被同一 Protocol 消费，避免无限循环（`AgentService` javadoc）。执行器写入由 Protocol 自行产生新的 `AttributeEvent` 来确认成功，形成**命令 → 确认**的异步语义，而非同步写回。

---

## 8. Agent 模块：协议接入层

### 8.1 Agent / Protocol / AgentLink 三元组

- `Agent<...>`（`model/asset/agent/Agent.java`）是一种特殊资产，其属性即协议连接配置；
- `Protocol<T extends Agent>`（`model/asset/agent/Protocol.java`）是协议运行时实例；
- `AgentLink`（`DefaultAgentLink` 及各协议专用子类）是属性上的 `AGENT_LINK` meta 值，描述该属性如何映射到协议地址/寄存器/主题，并可携带 `ValueFilter`、写入值模板（`%VALUE%`）等。

`AgentService` 的职责（其 javadoc 明确）：把属性写入通过 Protocol 实例送达执行器；并在 Agent 资产 CRUD 或 Agent 自身属性 `AttributeEvent` 变化时**重新部署** Protocol 实例。`ConnectionStatus` 枚举反映连接状态并作为 Agent 属性暴露，`AgentHealthStatusProvider` 汇总到健康检查。

`AbstractProtocol` 提供统一骨架；`ProtocolDatapointService` / `ProtocolPredictedDatapointService` 给协议实现提供受控的时序数据写入入口。

### 8.2 协议清单（28 个 Agent 类型 / 34 个 Protocol 类）

| 协议族 | Agent / Protocol | 说明 |
|---|---|---|
| HTTP | `HTTPAgent` / `HTTPProtocol`、`AbstractHTTPServerProtocol` | 轮询式 REST 客户端 + 内嵌 HTTP 服务端基类 |
| WebSocket | `WebsocketAgent` / `WebsocketAgentProtocol` | WS 客户端 |
| MQTT | `MQTTAgent` / `MQTTProtocol`、`AbstractMQTTClientProtocol` | HiveMQ MQTT 客户端 |
| TCP/UDP | `TCPAgent`、`UDPAgent`、`AbstractTCPServerAgent` | Netty 基础的 IO 客户端/服务端 |
| Serial | `SerialAgent` / `SerialProtocol` | jSerialComm |
| Modbus | `ModbusTcpAgent`、`ModbusSerialAgent` | nifty-modbus |
| KNX | `KNXAgent` / `KNXProtocol` | Calimero |
| Z-Wave | `ZWaveAgent` / `ZWaveProtocol` | |
| Velbus | `VelbusTCPAgent`、`VelbusSerialAgent` | 含完整 `device/` 子系统 |
| BLE Mesh | `BluetoothMeshAgent` / `BluetoothMeshProtocol` | 完整 mesh 栈：`provisionerstates`、`transport`、`models`、`opcodes`、`control` |
| LoRaWAN | `ChirpStackAgent`、`TheThingsStackAgent`、`LoRaWANMQTTProtocol` | ChirpStack（gRPC）与 TTS 两种 LNS |
| SNMP | `SNMPAgent` / `SNMPProtocol` | Camel SNMP |
| Art-Net | `ArtnetAgent` / `ArtnetProtocol` | DMX 灯光 |
| IKEA Trådfri | `TradfriAgent` / `TradfriProtocol` | 含 `device/`、`payload/` |
| Mail | `MailAgent` / `MailProtocol` | IMAP/POP3 收信转属性 |
| OpenWeatherMap | `OpenWeatherMapAgent` | 云 API |
| 仿真 | `SimulatorAgent` / `SimulatorProtocol` | 无硬件仿真（`V20260302_01__RequireSimulatorSchedule.sql` 要求 schedule） |

IO 抽象层（`agent/protocol/io`）：`IOClient`/`IOServer` 接口 + `AbstractNettyIOClient`/`AbstractNettyIOServer` 实现，所有基于字节流的协议复用同一套编解码、重连与背压逻辑。

`AgentModelProvider` 把 agent 模块的所有 Agent 类型注册进 `ValueUtil` 资产模型。

---

## 9. 规则与自动化引擎

### 9.1 规则集作用域与语言

`Ruleset` 三种作用域，各自独立表：

| 作用域 | 实体 | 表 |
|---|---|---|
| 全局 | `GlobalRuleset` | `GLOBAL_RULESET` |
| 租户 | `RealmRuleset` | `REALM_RULESET`（`V20220523_03__RenameTenantRuleset.sql` 把 `TENANT_RULESET` 重命名而来） |
| 资产 | `AssetRuleset` | `ASSET_RULESET` |

四种语言（`Ruleset.Lang`），默认 `GROOVY`：

- `GROOVY` —— Groovy 5，运行在 **groovy-sandbox** 中并配有 `GroovyDenyAllFilter` 值过滤器（白名单式沙箱）；可由 `groovyRulesExecutionEnabled` 开关禁用；
- `JSON` —— when-then 声明式规则，由 `JsonRulesBuilder` 编译；
- `FLOW` —— 可视化流程图，由 `FlowRulesBuilder` 编译 `NodeCollection`；
- `JAVASCRIPT` —— **仅为历史记录保留，不能新建**（`Ruleset.java:117` 注释明确）。

### 9.2 规则引擎管理

`RulesService` 为每个启用的 `Ruleset` 管理一个 `RulesEngine`（Easy Rules 4.1 之上的封装）。它同时是 `AttributeEvent` 的订阅者：把带 `RULE_STATE` meta 的属性变化转成 `AttributeInfo` 事实（fact）注入引擎，保持规则事实与资产状态同步。

**处理顺序**（`RulesService` javadoc）：

1. 全局规则集
2. 租户规则集
3. 资产规则集（按资产层级从最老的祖先向下）

同作用域/同父级内部顺序不保证。`RulesEngineId` 标识引擎实例，`RulesEngineStatus` / `RulesEngineInfo` / `RulesEngineStatusEvent` 暴露状态，`RulesLoopException` 检测规则循环，`RulesHealthStatusProvider` 接入健康检查，`RulesFacts` 管理事实集与 `TemporaryFact`（带 TTL 的事实）。

### 9.3 规则 Facade（规则 DSL 的受控 API）

`manager/rules/facade` 提供给规则脚本的受限门面，对应 `model/rules` 中的接口：

| Facade | 接口 | 能力 |
|---|---|---|
| `AssetsFacade` | `Assets` | 按 `AssetQuery` 查询、写属性 |
| `UsersFacade` | `Users` | 查询用户（需 `read:users`） |
| `NotificationsFacade` | `Notifications` | 发送通知 |
| `AlarmFacade` | `Alarms` | 创建/更新告警 |
| `HistoricFacade` | `HistoricDatapoints` | 读历史时序 |
| `PredictedFacade` | `PredictedDatapoints` | 读写预测时序 |
| `WebhooksFacade` | `Webhooks` | 触发 Webhook |

Facade 自动把查询限定在规则集作用域内（全局/租户/资产），这是规则沙箱的**授权边界**。注意 `WRITE_RULES` 角色描述标注 "NOTE: effectively super-user access!"——能写 Groovy 规则等于能执行代码。

### 9.4 JSON（when-then）规则模型

`model/rules/json`：

- `JsonRulesetDefinition` → `JsonRule[]`；
- `JsonRule` = `RuleCondition`（when，支持 `AssetQuery` 谓词、`SunPositionTrigger` 日升日落、`CalendarEventPredicate` 日历、时间窗/持续时间）+ `RuleAction[]`（then）+ `RuleRecurrence`（重复策略）；
- `RuleAction` 实现：`RuleActionWriteAttribute`、`RuleActionUpdateAttribute`、`RuleActionNotification`、`RuleActionAlarm`、`RuleActionWebhook`、`RuleActionWait`；
- `RuleActionTarget` 指定动作目标（资产/用户/自定义）；
- `RuleTemplate` 支持规则模板化。

`AssetQueryPredicate` 把 `AssetQuery` 谓词编译成内存谓词在规则引擎中求值（而非走 SQL），`AssetLocationPredicateProcessor` / `AssetLocationPredicateConsumer` 专门处理位置谓词。

### 9.5 Flow（可视化）规则

`model/rules/flow`：`NodeCollection` 由 `Node`（`NodeType`、`NodeInternal`、`NodeSocket`、`NodeDataType`、`NodePosition`）与 `NodeConnection` 组成；`Picker`/`PickerType`/`Option` 定义节点在 UI 中的编辑控件。后端 `manager/rules/flow`：`NodeModel`、`NodeImplementation`、`NodeTriggerFunction`、`NodeTriggerParameters`、`NodeExecutionRequestInfo`，由 `FlowResourceImpl` 把节点目录暴露给 `or-rules` 前端组件。另有旧的 `model/flow`（`Flow`/`Node`/`Slot`/`Wire` 实体与 `catalog/`）。

### 9.6 地理围栏

`rules/geofence`：`GeofenceAssetAdapter` SPI + `ORConsoleGeofenceAssetAdapter` 实现。从规则/资产中提取 `RadialGeofencePredicate` 等位置谓词，转成 `GeofenceDefinition` 下发给移动 Console，由设备端在本地做进出围栏判断并回报，避免持续上传位置。

---

## 10. 安全、身份与多租户

### 10.1 多租户模型

**Realm** 是租户边界，与 Keycloak realm 一一对应：

- `MASTER_REALM = "master"`，内置管理员 `admin`（`MASTER_REALM_ADMIN_USER`）；
- Keycloak 客户端：`KEYCLOAK_CLIENT_ID = "openremote"`（前端/用户）、`MANAGER_CLIENT_ID = "manager-keycloak"`（服务端）；
- 资产、规则集、仪表盘、通知、告警、用户均带 realm 归属；
- REST 路径形如 `/api/{realm}/…`，由 `RealmPathExtractorFilter` 提取；
- 事件通过 `RealmScopedEvent` / `RealmFilter` 按 realm 过滤。

### 10.2 认证

`ManagerIdentityService` 按 `OR_IDENTITY_PROVIDER` 选择提供者。`createIdentityProvider` 的 switch **只有 `"keycloak"` 一个分支**（→ `ManagerKeycloakIdentityProvider`，继承 `container` 的 `KeycloakIdentityProvider`），其余值直接抛 `UnsupportedOperationException`——即身份提供者目前没有真正的可替换实现。Keycloak 服务地址由 `OR_KEYCLOAK_HOST`（默认 `keycloak`）与 `OR_KEYCLOAK_PORT` 指定。

认证链：Keycloak 颁发 OIDC access token（`ACCESS_TOKEN_LIFESPAN_SECONDS = 60`，**1 分钟**——因此 compose 文件强调所有服务必须时钟同步）→ `JWTAuthenticationFilter` 用 `TokenVerifierImpl` + `KeyResolver`（JWKS）校验 → 构造 `AuthContext`（存于请求属性 `AUTH_CONTEXT`）→ `TokenPrincipal`。

出站认证由 `OAuthFilter` + `AuthForm` 体系（`PasswordAuthForm`、`ClientCredentialsAuthForm`）支持，供 HTTP 协议 Agent 和网关客户端使用。`ReactiveTokenService` 负责 token 刷新。`KeyStoreServiceImpl` 管理协议侧的客户端证书/密钥。`LDAPComponentBuilder` 提供 LDAP 集成能力。

### 10.3 授权模型

**客户端角色**（`ClientRole`，`Constants` 中定义字符串）按资源域分：

```
read:admin  read:logs  read:users  read:map  read:assets  read:rules
read:insights  read:alarms  read:notifications  read:services  read:tunnels
write:user  write:admin  write:logs  write:assets  write:attributes
write:rules  write:insights  write:alarms  write:notifications
write:services  write:tunnels
```

两个复合角色 `read` / `write` 聚合上述原子角色。**`read:admin`/`write:admin` 是独立角色，持有 `write:admin` 不代表拥有 `write:notifications`**（项目 `AGENTS.md` 明确规定）。

**Realm 角色**：`SUPER_USER_REALM_ROLE = "admin"`（超级用户）、`RESTRICTED_USER_REALM_ROLE = "restricted_user"`（受限用户，只能访问通过 `USER_ASSET_LINK` 关联的资产）。

**三级资产访问**（`AssetQuery.Access`）：

- `PRIVATE`：完整访问（常规已认证用户）；
- `PROTECTED`：受限用户，只见关联资产，且属性需有 `ACCESS_RESTRICTED_READ/WRITE` meta；
- `PUBLIC`：匿名访问，资产需 `ACCESS_PUBLIC_READ` 列为真且属性有 `ACCESS_PUBLIC_READ/WRITE` meta。

### 10.4 访问控制实现约定

项目 `AGENTS.md` 规定了访问控制的代码位置与形态：

- 访问控制在**资源实现**中，而非 service 层；
- 资源继承 `ManagerWebResource`，使用其检查方法而非直接调身份提供者：`throwIfNotRealmActiveAndAccessible` / `throwIfRestrictedUser`（抛 403）、`isRealmActiveAndAccessible` / `isRestrictedUser`（条件判断）；
- 顺序：先解析实体（不存在返回 404）→ 再要求 realm 访问权 → 再应用受限用户规则；
- Service 方法接收**已授权**的输入，并在 javadoc 中声明 "Callers are responsible for enforcing realm authorization."；
- Alarms 与 notifications 是该模式的参考实现；
- 不经资源层的流程（如发布到消息代理的通知）在 service 内部授权。

事件总线授权由 `EventAuthorizer` / `EventSubscriptionAuthorizer` SPI 实现，各服务（如 `RulesService:198`、`ExternalServiceRegistryService`）向 `ClientEventService` 注册自己的订阅授权器。

---

## 11. 对外接口体系（REST / WebSocket / MQTT）

### 11.1 REST API

接口定义（JAX-RS 注解接口）全部在 `model` 模块，实现在 `manager`，形成**契约与实现分离**，`model` 可作为客户端 SDK 发布。23 个资源接口：

| 接口 | 域 |
|---|---|
| `AssetResource` / `AssetModelResource` | 资产 CRUD、查询、属性读写；资产模型元数据 |
| `AgentResource` | Agent 与协议相关操作（如协议资产发现/导入） |
| `AssetDatapointResource` / `AssetPredictedDatapointResource` | 历史/预测时序查询与导出 |
| `RulesResource` / `FlowResource` | 规则集 CRUD；Flow 节点目录 |
| `UserResource` / `RealmResource` | 用户、角色、租户管理 |
| `NotificationResource` / `AlarmResource` | 通知、告警 |
| `DashboardResource` | Insights 仪表盘 |
| `MapResource` | 地图样式与瓦片 |
| `ConsoleResource` | 移动 Console 注册 |
| `GatewayClientResource` / `GatewayServiceResource` | 网关连接配置；网关服务（含隧道） |
| `ProvisioningResource` | 自动置备配置 |
| `ConfigurationResource` | 管理端运行时配置 |
| `AppResource` | App/Console 清单 |
| `ExternalServiceResource` | 外部服务注册表 |
| `SyslogResource` | 平台日志与日志级别配置 |
| `StatusResource` | 健康与版本信息 |

**端点角色约定**（`AGENTS.md`）：每个端点必须标注所属域的资源角色（如 `read:alarms`、`write:notifications`）；只有在该域没有资源角色、或刻意只允许管理员时才用 `read:admin`/`write:admin`。

OpenAPI 规范由 swagger-gradle-plugin 从 `org.openremote.model` 包生成（`manager/build.gradle` 的 `resolve` 任务，基线 `src/main/resources/openapi-base.yaml`，自定义 `ManagerObjectMapperProcessor`），产出 JSON + YAML 并作为 Maven artifact（classifier `openapi`）发布；`ui/app/swagger` 提供 Swagger UI。

### 11.2 WebSocket 事件总线

`ClientEventService`（javadoc 定义了完整线路协议）通过 Camel 的 undertow 组件复用 Manager 已有的 Undertow 实例，端点为 `/websocket/events`（`ClientEventService.java:120`）。报文为**大写判别符 + 可选 JSON 负载**：

客户端 → 服务端：

| 报文 | 负载 |
|---|---|
| `SUBSCRIBE:{...}` | `EventSubscription`（可带 `EventFilter`），按 `SharedEvent#getEventType` 订阅 |
| `UNSUBSCRIBE:{...}` | `CancelEventSubscription` |
| `EVENT:{...}` | `SharedEvent` 子类；无法识别则静默忽略 |

服务端 → 客户端：

| 报文 | 负载 |
|---|---|
| `UNAUTHORIZED:{...}` | `UnauthorizedEventSubscription` |
| `EVENT:{...}` | 单个 `SharedEvent` |
| `EVENT:[...]` | `SharedEvent` 数组 |

主要事件类型：`AttributeEvent`、`AssetEvent`、`AssetsEvent`、`AssetTreeEvent`、`ReadAssetEvent`/`ReadAssetsEvent`/`ReadAttributeEvent`/`ReadAssetTreeEvent`（请求式）、`AlarmEvent`、`NotificationEvent`、`RulesetChangedEvent`、`RulesEngineStatusEvent`、`SyslogEvent`、`GatewayConnectionStatusEvent`、`ExternalServiceEvent`，以及网关隧道的请求/响应事件对（`RespondableEvent` 支持请求-响应语义）。

同一套 `ClientEventService` 同时服务**外部 WebSocket 客户端**和**内部服务订阅**（`addSubscription(Class, filter, consumer)`），内外统一。

### 11.3 MQTT Broker

`MQTTBrokerService` 内嵌 **ActiveMQ Artemis**（`artemis-server` + `artemis-mqtt-protocol`），监听端口由 `MQTT_SERVER_LISTEN_PORT` 配置（默认 **1883**，`MQTTBrokerService.java:148`），对外经 proxy 的 **8883** 端口做 TLS 终结（MQTTS）。

**`MQTTHandler` SPI**（`ServiceLoader` 发现，`META-INF/services/org.openremote.manager.mqtt.MQTTHandler`）让不同 topic 空间由不同 handler 处理：

| Handler | 用途 |
|---|---|
| `DefaultMQTTHandler` | 资产/属性读写与订阅 |
| `UserAssetProvisioningMQTTHandler` | 设备自动置备（X.509 证书签名请求 → 自动建资产建用户） |
| `ConnectionMonitorHandler` | 连接状态监控（配合 `USER_CONNECTED` meta） |

Topic 约定：前两段一般是 `{realm}/{clientId}`，第三段是动作（`MQTTHandler#handlesTopic` 要求至少 3 段）。`DefaultMQTTHandler` 的动作段：

```
{realm}/{clientId}/asset/...                 资产事件订阅
{realm}/{clientId}/attribute/...             属性事件订阅（完整 AttributeEvent）
{realm}/{clientId}/attributevalue/...        仅属性值订阅
{realm}/{clientId}/writeattribute/...        写属性（完整事件）
{realm}/{clientId}/writeattributevalue/...   写属性值
```

授权通过 `canSubscribe` / `canPublish`（基于 `AuthContext`），`ActiveMQORSecurityManager` 把 Artemis 的安全模型桥接到 OpenRemote 身份体系；`MQTTUtil` 负责 MQTT topic ↔ Artemis core address 转换。置备流程使用 `ProvisioningMessage` / `X509ProvisioningMessage` / `SuccessResponseMessage` / `ErrorResponseMessage`。

---

## 12. 边缘网关与隧道

OpenRemote 支持**分层部署**：边缘实例作为"网关"连接到中心实例。

**中心侧 `GatewayService`**（javadoc）：管理本地 `GatewayAsset`，为每个网关创建 Keycloak 客户端；**由网关主动连入**，中心负责认证网关并发起资产同步。同时注册 `AttributeEventInterceptor` 拦截所有目标为 `GatewayAsset` 后代的 `AttributeEvent`，转发给下游网关处理，由网关回报成败。

**边缘侧 `GatewayClientService`**：管理出站连接（`GatewayConnection` 实体，`GATEWAY_CONNECTION` 表），`GatewayClientConnector` 负责连接与重连。

**同步与协商**：`GatewayInitStartEvent` / `GatewayInitDoneEvent`（初始同步握手）、`GatewayCapabilitiesRequestEvent` / `GatewayCapabilitiesResponseEvent`（版本与隧道能力协商）、`GatewayDisconnectEvent`、`GatewayConnectionStatusEvent`。`GatewayAssetSyncRule` 与 `GatewayAttributeFilter` 控制哪些资产/属性参与同步（`V20240508_01__Gateways.sql`、`V20250617_01__GatewayWidgetRefs.sql`、`V20250218_01__UpdateGatewayConnection.sql`）。

**隧道**：`GatewayTunnelFactory` / `MINAGatewayTunnelFactory`（Apache SSHD 2.18）+ `GatewayTunnelSession`，通过 SSH 反向隧道（`GatewayInitStartEvent` 携带隧道 SSH 服务端的公网 hostname/port，compose 中可配 `SISH_HOST`/`SISH_PORT`）让中心运维人员访问边缘侧内网设备的 HTTP/TCP 服务。请求/响应事件：`GatewayTunnelStartRequestEvent`/`StartResponseEvent`、`StopRequestEvent`/`StopResponseEvent`，`GatewayTunnelInfo` 描述隧道。权限由 `read:tunnels`/`write:tunnels` 控制（`V20260903_1000__AddTunnelRoles.sql`）。

---

## 13. 数据持久化与时序数据

### 13.1 Flyway 迁移

迁移脚本位于 `manager/src/main/resources/org/openremote/manager/setup/database/`（SQL）与 `manager/src/main/java/org/openremote/manager/setup/database/`（Java 迁移，主要是 Keycloak 角色变更：`AbstractKeycloakMigration`、`AbstractKeycloakRolesMigration`、`V20250916_01__AddServiceRoles`、`V20260715_1444__AddNotificationRoles`、`V20260903_1000__AddTunnelRoles`）。

**命名约定**（根 `AGENTS.md`）：`V<YYYYMMDD>_<HHmm>__<描述>.sql`，时间为 UTC，`V` 前缀必须大写，例如 `V20260611_0755__Changes.sql`。

### 13.2 核心表

基线 `V20191202_01__Schema.sql` 启用扩展 `POSTGIS`、`POSTGIS_TOPOLOGY`、`ltree`，创建序列 `OPENREMOTE_SEQUENCE`（起始 1000）与下列表：

| 表 | 要点 |
|---|---|
| `ASSET` | `ID varchar(22)`（friendly-id，Base62 UUID）、`ATTRIBUTES jsonb`、`PATH ltree`（层级路径）、`REALM`、`TYPE varchar(500)`、`ACCESS_PUBLIC_READ`、乐观锁 `VERSION`，`check (ID != PARENT_ID)` |
| `ASSET_DATAPOINT` | 主键 `(TIMESTAMP, ENTITY_ID, ATTRIBUTE_NAME)`，`VALUE jsonb` |
| `ASSET_PREDICTED_DATAPOINT` | 预测时序 |
| `GLOBAL_RULESET` / `ASSET_RULESET` / `REALM_RULESET` | 规则集，`RULES text` + `RULES_LANG` + `META jsonb`（`REALM_RULESET` 原名 `TENANT_RULESET`，由 `V20220523_03` 重命名） |
| `USER_ASSET_LINK` | 受限用户 ↔ 资产关联 |
| `NOTIFICATION` | 发送记录（`V20260715_1443__AddNotificationRealm.sql` 加 realm，`V20260715_1443_1__BackfillNotificationRealmUsers` 回填） |
| `SYSLOG_EVENT` | 平台日志 |
| `GATEWAY_CONNECTION` | 出站网关连接 |
| `PROVISIONING_CONFIG` | 自动置备配置 |
| `DASHBOARD` | `V20220705_01__Schema.sql` |
| `ALARM` / `ALARM_ASSET_LINK` | `V20240813_01__Alarms.sql` |

`RealmView`（`manager/security/RealmView.java`）是只读视图实体，让 Manager 直接读取 Keycloak 共享库中的 realm 信息。

### 13.3 时序数据与 TimescaleDB

`V20230120_01__Timescale.sql` 把数据点表转为 hypertable，`V20260506_02__EnableHyperCore.sql` 启用 hypercore（列式压缩）。保留策略由 `AssetDatapointService` 用 `drop_chunks()` 按**周粒度**执行，对齐 7 天 chunk interval；默认无限保留，`OR_DATA_POINTS_MAX_AGE_DAYS` 全局配置，`dataPointsMaxAgeDays` meta 按属性覆盖。

其他性能相关迁移：`V20221219_01__HelperFunctions.sql` / `V20230105_01__HelperFunctionsFix.sql`（辅助函数）、`V20240722_01__Indexes.sql`、`V20241210_01__ImproveAssetPath.sql`（ltree 路径优化）、`V20251022_01__UpdateIndexesSchemaName.sql`、`V20260518_01__AssetFillFactor.sql`（降低 HOT 更新膨胀）、`V20260120_01__addTableFunc.sql`、`V20260506_01__DatapointMetricQuery.sql`、`V20260923_1100__AssetDeletePending.sql`（软删除 `includeDeletePending`）。

`deployment/query-exporter` 提供 SQL 指标导出配置，把业务查询结果暴露为 Prometheus 指标。

---

## 14. 前端架构（UI）

### 14.1 组织方式

`ui/` 是 yarn workspaces monorepo，同时每个包有 `build.gradle` 被 Gradle 动态包含，形成 **Gradle 驱动 npm** 的构建模型。

```
ui/
├── app/
│   ├── manager/    管理端 SPA（Lit + 自研路由 routes.ts）
│   ├── insights/   仪表盘查看端
│   ├── swagger/    Swagger UI
│   ├── storybook/  组件文档站（MDX 文档 + 各包 stories/）
│   └── shared/     共享 locales、map、fonts
├── component/      30 个 @openremote/* Web Component 包
├── test/           Playwright 共享配置与 fixtures
├── util/           rspack/rsbuild 共享配置（rspack.util.js）
└── demo/
```

**管理端页面**（`ui/app/manager/src/pages/`）：assets、map、rules、insights、alarms、notifications、logs、users、roles、realms、provisioning、gateway、gateway-tunnel、services、configuration、export、account —— 与后端服务一一对应。

**核心组件包**：`core`（manager 单例、REST 客户端、事件总线）、`model`（生成的 TS 类型）、`rest`（生成的 REST 客户端）、`or-app`、`or-element`（所有自有组件的基类）、`or-asset-tree`、`or-asset-viewer`、`or-attribute-input`/`-picker`/`-card`/`-history`/`-barchart`、`or-chart`、`or-gauge`、`or-map`（MapLibre）、`or-rules`（三种规则编辑器）、`or-dashboard-builder`、`or-json-forms`（JSON Schema 表单）、`or-mwc-components`、`or-vaadin-components`、`or-tree-menu`、`or-scheduler`、`or-services`、`or-log-viewer`、`or-translate`（i18next）、`or-icon`、`or-rive-renderer`、`theme`。

### 14.2 关键前端约定（`ui/AGENTS.md`）

- **生成的模型**：`ui/component/model/src/model.ts` 由 typescript-generator 从 Java 后端生成（`./gradlew :ui:component:model:generateTypeScript`），**不可手改**，含枚举与常量。任何镜像后端类/枚举的东西都应从 `@openremote/model` 导入，例如用 `manager.hasRole(ClientRole.READ_ASSETS)` 而不是硬编码 `"read:assets"`。`model-util` 模块提供生成器扩展（`CustomTypeProcessor`、`EnumWithInterfacesExtension`、`JsonSerializeExtension`、`AssetModelInfoExtension` 等）。`restclient.ts` 同理生成。
- **基类**：自有 Lit 组件继承 `OrElement`（`@openremote/or-element`）而非 `LitElement`，以自动获得共享 shadow-DOM 样式；Vaadin 包装器例外（继承 Vaadin 基类，走 Lumo 主题）。
- **细粒度渲染**：状态变化只重渲染受影响部分，避免整页/整表重渲染丢失排序、分页、选中、滚动位置。
- **构建输出**：每个包输出到自己的 `build/`，禁止新增顶层输出目录。三个例外：`ui/app/shared/fonts`、`ui/app/shared/cache`、生成的 `model.ts`/`restclient.ts`。
- **新增组件包**：yarn workspace 与 Gradle 自动识别，但必须手动加入 `ui/app/manager/rsbuild.config.ts` 与 `ui/app/storybook/rsbuild.config.ts` 的 `@openremote/*` alias map。
- **Vaadin 包装与样式**：按"需要保留多少基础组件样式"选择策略——优先外部 `::part()` 规则（`ui/component/theme/src/components/or-vaadin-<name>.css`），其次 Lumo `@media` 模块注入；只有组件完全自绘时才覆盖 `static get is()` 并用 `registerStyles()`（因为 `ThemableMixin.finalizeStyles()` 在 Lumo 之前注入 `static styles`，会被主题覆盖）。
- **测试**：Playwright。App 测试在 `ui/app/<app>/test/`，组件测试在 `ui/component/<pkg>/test/`（`@sand4rt/experimental-ct-web`）；测试命名以 "should …" 开头，默认扁平结构；每个 bug 修复都要带一个"没有修复就会失败"的回归测试。`ui/AGENTS.md` 详细记录了组件测试的多项陷阱（懒加载的自定义元素需显式注册、每个测试只能一次 `mount()`、`on` handler 收到的是 `event.detail`、Vaadin 挂载时会先发一次 `<prop>-changed`、Vaadin `theme` 只能通过属性设置等）。

---

## 15. 可观测性与健康检查

**健康检查**：`HealthService` 聚合 `HealthStatusProvider` SPI（`META-INF/services/org.openremote.model.system.HealthStatusProvider`），8 个内置提供者：

`JvmHealthStatusProvider`、`SystemHealthStatusProvider`、`SslHealthStatusProvider`、`CamelHealthStatusProvider`、`PersistenceHealthStatusProvider`、`RulesHealthStatusProvider`、`AgentHealthStatusProvider`、`AssetDatapointHealthStatusProvider`、`AssetPredictedDatapointHealthStatusProvider`。

通过 `StatusResourceImpl` / `StatusResource` 暴露，`VersionInfo` 提供版本（构建期由 `setVersionProperties` 任务写入 `version.properties`）。Docker compose 用 manager 的健康检查作为 proxy 的启动依赖。

**指标**：Micrometer + Prometheus（`OR_METRICS_ENABLED` 默认 true），manager 暴露在 8405，proxy 在 8404，默认仅绑 127.0.0.1，可通过 `PRIVATE_IP` 额外暴露到私有子网。线程池、Camel 路由、MQTT topic（`MQTTHandler#getPublishTopicAddressSettings` 默认启用 topic 指标）均有埋点。

**追踪**：OpenTelemetry Java Agent 以 `otelJavaAgent` configuration 打包进发行版 `opentelemetry/opentelemetry-javaagent.jar`，默认关闭（`OTEL_JAVAAGENT_ENABLED=false`），支持 OTLP/HTTP 导出到本地 Alloy，`OTEL_INSTRUMENTATION_COMMON_DB_STATEMENT_SANITIZER_ENABLED=true`。

**日志**：`LogUtil.initialiseJUL()` 在 `Main` 静态块中最先执行；`LogFormatter`/`NoTimeLogFormatter`/`LoggingFileHandler` 自定义格式；`SyslogService` 把平台日志按 `SyslogCategory` 持久化并实时推送给 UI。

---

## 16. 构建、测试与 CI/CD

### 16.1 构建

```bash
./gradlew clean installDist            # 完整清理构建（前后端）
./gradlew clean installDist --offline  # 沙箱环境（依赖需已缓存）
./gradlew :ui:component:model:generateTypeScript   # 重新生成前端模型
./gradlew :manager:generateOpenApi     # 生成 OpenAPI 规范
```

`spotless.gradle` 统一 Java/Groovy/TS 格式化（根 `AGENTS.md` 与 CI 中的 `check-spotless.yml` / `ui-check-spotless.yml` 强制）；`buildSrc` 与 `project.gradle` 承载公共构建逻辑；版本号由 axion-release 插件管理；`gradle-file-encrypt` 用于加密部署凭据。

### 16.2 测试

**后端测试全部是 Groovy Spock 规格**（根 `AGENTS.md`）：

- 单元测试放在代码所属项目的 `<project>/src/test/groovy`；
- 只有当行为需要**运行中的 manager** 时才放到 `test` 项目作为集成测试（当前 82 个规格）；
- Spock 2.0 起 unroll 是默认行为，不要加多余的 `@Unroll`；
- JAX-RS 代理抛出的 `WebApplicationException` 携带的 response 会持有连接，必须用 `ex.response.withCloseable { r -> assert r.status == 403; return true }` 读取状态，否则大量断言拒绝的规格会耗尽连接池。

集成测试需要先起依赖栈：

```bash
docker compose -f profile/dev-testing.yml -p openremote up -d --no-build
```

（只起 PostgreSQL 与 Keycloak，Keycloak 暴露 8081，PostgreSQL 暴露 5432，manager 预期在 `http://127.0.0.1:8080`）

`setup` 项目的多个 sourceSet 提供不同测试/演示数据集：`integration`（含 `MockAgent`/`MockProtocol`/`MockVelbusProtocol`/`TestHTTPServerProtocol` 等测试替身与 `TestAssetModelProvider` 自定义资产）、`datetime`、`load1`/`load2`（压测数据）、`clustering`、`notification`。由 `SetupService` + `SetupTasks` SPI + `OR_SETUP_TYPE` 环境变量选择（注意 `manager:run` 显式拒绝 `OR_SETUP_TYPE`，须用 `setup:run`）。

### 16.3 CI/CD

31 个 GitHub Actions workflow，分层组织（可复用 workflow + 编排 workflow）：

- **检查**：`check-spotless`、`ui-check-spotless`、`ui-check-dependencies`、`ui-check-outdated-translations`；
- **测试**：`unit-tests`、`integration-tests`、`ui-app-tests`、`ui-component-tests`、`code-coverage`（JaCoCo）、`install-browsers`、`install-dist`；
- **镜像**：`build-manager-image`、`build-deployment-image`、`build-snapshot-image`、`push-snapshot-image`；
- **发布**：`release`、`publish-maven`、`publish-npm`、`publish-npm-dry-run`；
- **部署**：`deploy`、`deployment`、`staging`、`review`、`custom-staging`、`custom-review`、`provision-host`、`provision-account`、`start-stop-host`；
- **编排**：`ci_cd.yml`（配合 `.ci_cd/ci_cd.json`、`.ci_cd/aws`、`.ci_cd/deploy.sh`、`.ci_cd/host_init` 做 AWS 环境编排）。

工作流遵循 GitHub Flow，分支命名约定 `feature/*`、`hotfix/*`、`issue/123`。

---

## 17. 部署形态

| 形态 | 载体 | 说明 |
|---|---|---|
| 单机 Docker Compose | `docker-compose.yml` | 4 容器，开箱即用，`OR_HOSTNAME` 决定访问地址与证书 |
| 开发 | `profile/dev-testing.yml`（只起依赖）、`dev-ui.yml`、`dev-proxy.yml`、`dev-map.yml` | IDE 中跑 manager，依赖跑在容器里 |
| 演示 | `profile/demo.yml` | 带演示数据 |
| 完整参考配置 | `profile/deploy.yml` | 所有服务全部环境变量的文档化基线（需被扩展后使用） |
| Kubernetes | `kubernetes/` Helm charts：`manager`、`proxy`、`or-setup` | 含 EKS 建/删集群脚本、HAProxy ingress 变体、PV/PVC、Secret |
| 边缘设备 | `balena/` | Balena 平台部署（配合网关模式） |
| 自定义部署 | `deployment/` + `OR_CUSTOM_APP_DOCROOT` | 品牌化 manager app、自定义地图、Keycloak 主题 |

**持久化卷**：`postgresql-data`（数据库）、`manager-data`（`/storage`，供服务与协议做文件持久化）、`proxy-data`（SSL 证书，避免反复请求 Let's Encrypt）。

**时区**：compose 注释强调所有服务必须同时区且时间同步——bearer token 只有几分钟有效期（实际 `ACCESS_TOKEN_LIFESPAN_SECONDS = 60`），Keycloak 时钟漂移会直接导致认证失败。

---

## 18. 扩展点汇总

OpenRemote 的可扩展性几乎全部建立在 **JDK `ServiceLoader` SPI** 之上，自定义项目只需提供实现类 + `META-INF/services` 文件：

| SPI / 扩展点 | 用途 | 注册文件 |
|---|---|---|
| `ContainerService` | 新增后端服务（含 REST 资源注册、Camel 路由） | `org.openremote.model.ContainerService` |
| `AssetModelProvider` | 自定义资产类型、属性、元数据描述符 | `org.openremote.model.AssetModelProvider` |
| `Agent` + `Protocol` 子类 | 自定义协议（由 `StandardModelProvider` 约定式发现） | 随 `AssetModelProvider` |
| `MQTTHandler` | 自定义 MQTT topic 空间与语义 | `org.openremote.manager.mqtt.MQTTHandler` |
| `NotificationHandler` | 自定义通知通道 | 作为 `ContainerService` 注册 |
| `HealthStatusProvider` | 自定义健康指标 | `org.openremote.model.system.HealthStatusProvider` |
| `SetupTasks` | 自定义初始化数据 | `setup/src/<name>/resources/META-INF/services` |
| `GeofenceAssetAdapter` | 自定义地理围栏下发目标 | 作为 `ContainerService` 注册 |
| `EntityClassProvider` | 注册额外 JPA 实体 | `org.openremote.model.EntityClassProvider` |
| `AttributeEventInterceptor` | 介入属性写入决策 | 代码注册：`assetProcessingService.addEventInterceptor(...)` |
| `EventSubscriptionAuthorizer` / `EventAuthorizer` | 事件总线授权 | 代码注册：`clientEventService.addSubscriptionAuthorizer(...)` |
| `NodeImplementation` | 自定义 Flow 规则节点 | `manager/rules/flow` |
| 前端组件包 | 新 `@openremote/*` 包 | yarn workspace + Gradle 自动发现 + rsbuild alias 手动登记 |
| `ExternalService` 注册 | 以外部进程/语言实现服务，经 REST 注册（租约制） | `ExternalServiceResource` |

---

## 19. 架构特征评述

**优势**

1. **统一的数据主干**。所有写入路径（REST/WS/MQTT/协议/规则/网关）收敛到 `AssetProcessingService` 的单一管道，校验、授权、持久化、扩散只有一处实现。拦截器（同事务、可短路、决定"能否写"）与事件订阅（事务后、并行、决定"写完做什么"）的分离干净且可扩展。
2. **元数据驱动而非硬编码**。入库、规则参与、访问级别、单位格式、预测配置全部由 `MetaItem` 控制，使同一套引擎服务差异极大的部署而不需分支代码。
3. **契约与实现分离**。REST 接口与领域模型全在 `model`（无容器依赖），既是服务端契约，也是客户端 SDK，还是前端 TS 类型的生成源——三者天然不会漂移。
4. **无 DI 框架的轻量容器**。`ServiceLoader` + priority + 两阶段启动，启动顺序显式、可测试、无反射魔法，`Container` 可在测试中直接 new 出来并注入伪时钟（`TimerService`）。
5. **SPI 一致性**。扩展方式高度统一，自定义项目（协议、资产类型、通知通道、MQTT 语义、初始化数据）都是"加一个类 + 一行 services 文件"。
6. **成规模的协议覆盖**。28 个 Agent 类型覆盖工业（Modbus/KNX/SNMP）、楼宇（Velbus/Art-Net）、无线（BLE Mesh/Z-Wave/LoRaWAN 双 LNS）、云（HTTP/MQTT/WS/Mail/OWM），且共享统一的 IO 抽象与 `AgentLink` 配置模型。
7. **边缘-中心分层**完备：资产同步 + 能力协商 + 属性转发 + SSH 反向隧道运维通道。
8. **工程规范显式化**。根 `AGENTS.md` 与 `ui/AGENTS.md` 把迁移命名、端点角色、访问控制位置、测试形态、Vaadin 样式策略等约定写成可执行规则，而不是靠口头传承。

**约束与注意事项**

1. **Manager 是单体**。39 个服务在一个 JVM 内，水平扩展不是天然能力（`setup/src/clustering` 存在但仅为 setup sourceSet，不构成通用集群方案）。`ExternalServiceRegistryService` 的租约制注册表与多实例支持是朝可扩展方向的设计，但核心服务本身仍是单进程。
2. **属性事件无死信队列、无重试**（源码 javadoc 明确）。失败只记日志，对要求至少一次投递的场景需自行补偿。
3. **`write:rules` 等同超级用户**。`ClientRole` 自身注释为 "NOTE: effectively super-user access!"——Groovy 规则虽有 groovy-sandbox + `GroovyDenyAllFilter` 白名单过滤，但授予该角色应视为授予代码执行权。
4. **token 生命周期仅 60 秒**，对部署的时钟同步要求很高，时钟漂移的故障表现是认证失败而非明显报错。
5. **MQTT 授权在连接/订阅时决定**。`MQTTBrokerService` 顶部 TODO 指出队列大小限制需要在鉴权阶段做（以便能拒绝 publish），当前尚未实现。
6. **`JAVASCRIPT` 规则语言已停止支持新建**，仅为兼容历史记录保留，新项目应使用 JSON（when-then）、FLOW 或 GROOVY。
7. **生成文件不可手改**：`ui/component/model/src/model.ts` 与 `restclient.ts` 由构建生成（且被 gitignore）。发现缺少成员意味着文件过期需重新生成，而不是手工补写。
8. **数据库是 PostgreSQL 专属**。虽有 `OR_DB_VENDOR` 抽象，但 PostGIS、ltree、jsonb、TimescaleDB `drop_chunks()`/hypercore 的深度使用使其实际上无法替换。
9. **身份提供者同样没有可替换实现**。`OR_IDENTITY_PROVIDER` 看似是扩展点，但 switch 只有 `keycloak` 分支，其他值抛异常。替换 Keycloak 需要实现 `ManagerIdentityProvider` 并改动 `ManagerIdentityService`。

---

*文档生成于 2026-10-17，基于 `mydev` 分支 HEAD `72aff0f`。*
