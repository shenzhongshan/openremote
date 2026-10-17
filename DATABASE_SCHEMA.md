# OpenRemote 数据库表结构与字段详解

> 本文基于仓库 `openremote/core` 分支 `mydev`（HEAD `8f8a5d2`）的 Flyway 迁移脚本与 JPA 实体类静态分析整理。
> 每张表同时给出**物理 DDL**（迁移脚本的真实列定义）与 **JPA 映射**（实体类字段、校验、类型转换），两者不一致之处已明确标注。
> 配套文档：[`ARCHITECTURE.md`](./ARCHITECTURE.md)（技术架构与功能模块）。

---

## 目录

1. [总览](#1-总览)
2. [Schema 与扩展](#2-schema-与扩展)
3. [序列与主键生成策略](#3-序列与主键生成策略)
4. [实体注册机制](#4-实体注册机制)
5. [资产域](#5-资产域)
   - [5.1 ASSET](#51-asset)
   - [5.2 ATTRIBUTES jsonb 内部结构](#52-attributes-jsonb-内部结构)
   - [5.3 USER_ASSET_LINK](#53-user_asset_link)
6. [时序数据域](#6-时序数据域)
   - [6.1 ASSET_DATAPOINT](#61-asset_datapoint)
   - [6.2 ASSET_PREDICTED_DATAPOINT](#62-asset_predicted_datapoint)
   - [6.3 TimescaleDB 配置](#63-timescaledb-配置)
7. [规则域](#7-规则域)
   - [7.1 GLOBAL_RULESET](#71-global_ruleset)
   - [7.2 REALM_RULESET](#72-realm_ruleset)
   - [7.3 ASSET_RULESET](#73-asset_ruleset)
8. [通知与告警域](#8-通知与告警域)
   - [8.1 NOTIFICATION](#81-notification)
   - [8.2 ALARM](#82-alarm)
   - [8.3 ALARM_ASSET_LINK](#83-alarm_asset_link)
9. [仪表盘域](#9-仪表盘域)
10. [网关域](#10-网关域)
11. [置备域](#11-置备域)
12. [系统日志域](#12-系统日志域)
13. [Keycloak 只读视图映射](#13-keycloak-只读视图映射)
14. [数据库函数](#14-数据库函数)
15. [触发器](#15-触发器)
16. [索引清单](#16-索引清单)
17. [外键与级联行为](#17-外键与级联行为)
18. [Flyway 迁移清单](#18-flyway-迁移清单)
19. [已发现的问题](#19-已发现的问题)

---

## 1. 总览

Manager 共管理 **15 张物理表** + **4 个 Keycloak 只读视图映射**：

| # | 表名 | 域 | 主键 | 创建于 | 说明 |
|---|---|---|---|---|---|
| 1 | `ASSET` | 资产 | `ID` | `V20191202_01` | 单表继承，`ATTRIBUTES jsonb` 承载全部属性 |
| 2 | `ASSET_DATAPOINT` | 时序 | `(TIMESTAMP, ENTITY_ID, ATTRIBUTE_NAME)` | `V20191202_01` | TimescaleDB hypertable + 列存 |
| 3 | `ASSET_PREDICTED_DATAPOINT` | 时序 | `(TIMESTAMP, ENTITY_ID, ATTRIBUTE_NAME)` | `V20191202_01` | TimescaleDB hypertable |
| 4 | `GLOBAL_RULESET` | 规则 | `ID` | `V20191202_01` | 全局作用域规则集 |
| 5 | `REALM_RULESET` | 规则 | `ID` | `V20191202_01`（原名 `TENANT_RULESET`） | 租户作用域；`V20220523_03` **重命名** |
| 6 | `ASSET_RULESET` | 规则 | `ID` | `V20191202_01` | 资产作用域 |
| 7 | `USER_ASSET_LINK` | 资产 | `(ASSET_ID, REALM, USER_ID)` | `V20191202_01` | 受限用户 ↔ 资产关联 |
| 8 | `NOTIFICATION` | 通知 | `ID` | `V20191202_01` | 通知发送记录 |
| 9 | `SYSLOG_EVENT` | 日志 | `ID` | `V20191202_01` | 平台自身日志 |
| 10 | `GATEWAY_CONNECTION` | 网关 | `LOCAL_REALM` | `V20191202_01` | 边缘侧出站连接配置 |
| 11 | `PROVISIONING_CONFIG` | 置备 | `ID` | `V20191202_01` | 单表继承（`TYPE` 判别） |
| 12 | `DASHBOARD` | 仪表盘 | `ID` | `V20220705_01` | Insights 仪表盘 |
| 13 | `ALARM` | 告警 | `ID` | `V20240813_01` | 实体名 `SentAlarm` |
| 14 | `ALARM_ASSET_LINK` | 告警 | `(ASSET_ID, REALM, SENTALARM_ID)` | `V20240813_01` | 告警 ↔ 资产关联 |
| 15 | `flyway_schema_history` | 元数据 | — | Flyway 自建 | 迁移历史 |

**命名风格**：DDL 中表名与列名写作大写（`ASSET`、`PARENT_ID`），但 PostgreSQL 未加引号的标识符会**折叠为小写**，因此实际存储的名称是 `asset`、`parent_id`。后期迁移（如 `V20240722_01`、`V20260518_01`）直接使用小写形式，两者等价。

---

## 2. Schema 与扩展

### 2.1 双 Schema 布局

| Schema | 归属 | 内容 |
|---|---|---|
| `openremote`（可由 `OR_DB_SCHEMA` 改） | Manager | 上表 15 张表 |
| `public` | Keycloak + PostgreSQL 扩展 | Keycloak 的 `REALM`、`USER_ENTITY`、`USER_ATTRIBUTE`、`KEYCLOAK_ROLE`、`CLIENT`、`REALM_ATTRIBUTE` 等；以及 timescaledb / postgis 扩展对象 |
| `topology` | PostGIS | `postgis_topology` 扩展 |

两个 schema 位于**同一数据库** `openremote`（`KC_DB_SCHEMA=public` vs `OR_DB_SCHEMA=openremote`，见 `profile/deploy.yml:244,414`）。Manager 在 Flyway 初始化时把数据库级 `search_path` 设为 `<schemaName>, public, topology`（`PersistenceService.java:~614`）：

```sql
ALTER DATABASE <dbName> SET search_path TO <schemaName>, public, topology;
```

这使得 Manager 的 SQL 可以**不加限定符**地引用 Keycloak 的表，是跨 schema 外键和 `@Subselect` 视图映射能工作的基础。

### 2.2 扩展

| 扩展 | 创建位置 | 用途 |
|---|---|---|
| `postgis` | `V20191202_01` | 地理类型与空间函数，支撑 `GeoJSONPoint` 位置属性与地理围栏谓词 |
| `postgis_topology` | `V20191202_01` | 拓扑（`topology` schema） |
| `ltree` | `V20191202_01` | `ASSET.PATH` 的层级路径类型 |
| `timescaledb` | `PersistenceService` initSql（非迁移脚本） | 时序 hypertable；放在 initSql 中是为了**避免 Flyway clean 把扩展一起删掉**（见 flyway#2271） |
| `timescaledb_toolkit` | `PersistenceService` initSql | 时序分析函数 |
| `tablefunc` | `V20260120_01` | `crosstab` 等，用于数据点透视查询 |

> `timescaledb` 由 Java 代码而非迁移脚本创建，因此一个只跑过迁移脚本的数据库**不会**自动具备 TimescaleDB；`V20260506_02` 会在扩展缺失时 `RAISE EXCEPTION 'TimescaleDB extension is missing.'` 快速失败。

---

## 3. 序列与主键生成策略

```sql
create sequence OPENREMOTE_SEQUENCE start 1000 increment 1;
```

常量 `Constants.PERSISTENCE_SEQUENCE_ID_GENERATOR = "OPENREMOTE_SEQUENCE"`。所有 `int8` 主键实体统一使用它：

```java
@Id
@Column(name = "ID")
@GeneratedValue(strategy = GenerationType.SEQUENCE, generator = PERSISTENCE_SEQUENCE_ID_GENERATOR)
@SequenceGenerator(name = PERSISTENCE_SEQUENCE_ID_GENERATOR, sequenceName = ..., allocationSize = 1)
protected Long id;
```

使用该序列的表：`GLOBAL_RULESET`、`REALM_RULESET`、`ASSET_RULESET`、`NOTIFICATION`、`SYSLOG_EVENT`、`PROVISIONING_CONFIG`、`ALARM`。

**三种不同的主键风格并存**：

| 风格 | 表 | 值形态 |
|---|---|---|
| 序列 `int8` | 上述 7 张表 | `1000`, `1001`, … |
| 应用生成 `varchar(22)` | `ASSET`、`DASHBOARD` | friendly-id（Base62 编码的 UUID），如 `1ZyG7BmsTQ2cGmbuaMsi0A`；受 `Constants.ASSET_ID_REGEXP = ^[0-9A-Za-z]{22}$` 约束 |
| 自然键 / 复合键 | `GATEWAY_CONNECTION`（`LOCAL_REALM`）、`USER_ASSET_LINK`、`ALARM_ASSET_LINK`、两张数据点表 | 业务字段本身 |

---

## 4. 实体注册机制

没有 `persistence.xml`。实体在 `PersistenceService.start()`（`container/src/main/java/org/openremote/container/persistence/PersistenceService.java:374-420`）分四批注册：

1. **硬编码清单**（20 项）：`Asset`、`UserAssetLink`、`AssetDatapoint`、`SentNotification`、`AssetPredictedDatapoint`、`Realm`、`User`、`UserAttribute`、`RealmRole`、`GlobalRuleset`、`AssetRuleset`、`RealmRuleset`、`SyslogEvent`、`GatewayConnection`、`ConsoleAppConfig`、`Dashboard`、`ProvisioningConfig`、`X509ProvisioningConfig`、`SentAlarm`、`AlarmAssetLink`；
2. **带 `package-info` 的包**：`org.openremote.container.util`（注册自定义 Hibernate 类型，如 `LTreeType`）；
3. **资产模型中的资产子类**：`UnknownAsset` 显式加入（它没有 asset descriptor），其余从 `ValueUtil.getAssetDescriptors(null)` 取出并**过滤出带 `@Entity` 的类**；
4. **`EntityClassProvider` SPI**：`ServiceLoader` 发现，同样过滤 `@Entity`。

> **注意**：第 1 批（硬编码清单）**不做 `@Entity` 过滤**，而第 3、4 批做。这导致 `ConsoleAppConfig` 这个纯 POJO 被注册进实体列表 —— 详见[第 19 节](#19-已发现的问题)。

`model/flow` 下的 `Flow`、`Node`、`Slot`、`Wire` 虽带 `@Entity`/`@Table`，但**不在任何一批注册名单中**，也没有任何迁移脚本创建对应表 —— 它们是遗留代码，不构成运行时 schema。

---

## 5. 资产域

### 5.1 ASSET

资产是平台的核心实体，采用**单表继承**（`InheritanceType.SINGLE_TABLE`）+ **jsonb 属性包**的混合建模：结构性字段（父子、租户、名称）是真实列，业务属性全部在一个 `jsonb` 列里。

```java
@Entity
@Table(name = "ASSET", check = @CheckConstraint(constraint = "ID != PARENT_ID"))
@Inheritance(strategy = InheritanceType.SINGLE_TABLE)
@DiscriminatorColumn(name = "TYPE", discriminatorType = STRING)
@DynamicUpdate
public abstract class Asset<T extends Asset<?>> implements IdentifiableEntity<T>, AssetInfo
```

| 列 | 类型 | 约束 | JPA 字段 | 说明 |
|---|---|---|---|---|
| `ID` | `varchar(22)`（DDL）/ `char(22)`（JPA `columnDefinition`） | PK | `id` | friendly-id；`@Pattern(ASSET_ID_REGEXP)` 校验 `^[0-9A-Za-z]{22}$` |
| `VERSION` | `int8` | NOT NULL | `version` | `@Version` 乐观锁；`@Min(0)` |
| `CREATED_ON` | `timestamp with time zone` | NOT NULL | `createdOn` (`Instant`) | `@CreationTimestamp`，`updatable = false`；OpenAPI 标记 READ_ONLY |
| `NAME` | `varchar(1023)` | NOT NULL | `name` | `@NotBlank`，`@Size(1..1023)` |
| `PARENT_ID` | `varchar(22)` / `char(22)` | FK → `ASSET(ID)` | `parentId` | 根资产为 NULL；`@Pattern(ASSET_ID_REGEXP)` |
| `PATH` | `ltree` | — | `path` (`String[]`) | **DB 生成**：`insertable=false, updatable=false` + `@Generated(INSERT, UPDATE)`，由触发器维护；`@Type(LTreeType.class)` 做 ltree ↔ `String[]` 转换 |
| `REALM` | `varchar(255)` | NOT NULL，FK → `PUBLIC.REALM(NAME)` | `realm` | `updatable = false`（**创建后不可改租户**）；`@NotBlank`，`@Size(1..255)` |
| `TYPE` | `varchar(500)` | NOT NULL | `type` | `@DiscriminatorColumn`；JPA 侧 `insertable=false, updatable=false`，值由 Hibernate 按 `getClass().getSimpleName()` 写入（如 `ThingAsset`、`GatewayAsset`） |
| `ACCESS_PUBLIC_READ` | `boolean` | NOT NULL | `accessPublicRead` | 允许匿名调用方在支持公开访问的端点上读取该资产 |
| `DELETE_PENDING` | `boolean` | NOT NULL DEFAULT false | `deletePending` | `V20260923_1100` 新增；软删除标记，查询侧由 `AssetQuery.includeDeletePending` 控制 |
| `ATTRIBUTES` | `jsonb` | — | `attributes` (`AttributeMap`) | `@JdbcTypeCode(SqlTypes.JSON)` + `@Valid` 级联校验 |

**表级约束**：`check (ID != PARENT_ID)` —— 资产不能是自己的父节点（自环的最小防护；更深层的环由触发器检测，见 §15）。

**存储参数**：`fillfactor = 90`（`V20260518_01`）。资产行的 `ATTRIBUTES` 会被频繁 UPDATE（每次属性值变化），留 10% 页内空间让 PostgreSQL 做 HOT 更新，避免索引膨胀。配合 `@DynamicUpdate`（只 UPDATE 实际变更的列）降低写放大。

#### PATH 列与 ltree

`PATH` 存储从根到自身的完整 ID 链，形如 `rootId.childId.selfId`（点号分隔的 ltree）。它让"查某资产的所有后代"从递归 CTE 变成一次 GiST 索引扫描：

```sql
-- 所有后代（含自身）
SELECT * FROM asset WHERE path <@ (SELECT path FROM asset WHERE id = '<ancestorId>');
```

对应 `AssetQuery.recursive` 与 `PathPredicate`。注意 ltree 标签只允许字母数字和下划线 —— 这正是资产 ID 使用 Base62 friendly-id（而非带连字符的 UUID）的原因。

### 5.2 ATTRIBUTES jsonb 内部结构

`ATTRIBUTES` 是一个以**属性名为键**的 JSON 对象，每个值是一个属性对象：

```json
{
  "temperature": {
    "name": "temperature",
    "type": "number",
    "value": 21.5,
    "timestamp": 1760659200000,
    "meta": {
      "storeDataPoints": true,
      "ruleState": true,
      "units": ["celsius"],
      "agentLink": {
        "type": "SimulatorAgentLink",
        "id": "4pMNvFr8TQ2cGmbuaMsi0A",
        "schedule": { "start": 1760659200000, "recurrence": "FREQ=DAILY" }
      }
    }
  },
  "location": {
    "name": "location",
    "type": "GeoJSONPoint",
    "value": { "type": "Point", "coordinates": [4.89, 52.37] },
    "timestamp": 1760659200000,
    "meta": { "showOnDashboard": true }
  }
}
```

| JSON 键 | 类型 | 说明 |
|---|---|---|
| `name` | string | 属性名，与外层键重复（冗余但便于反序列化为 `Attribute` 对象） |
| `type` | string | `ValueDescriptor` 名称，如 `number`、`boolean`、`text`、`GeoJSONPoint`、`number[]` |
| `value` | any | 属性值，类型由 `type` 决定 |
| `timestamp` | number | **Unix 毫秒**（不是 ISO 字符串）。`AssetProcessingService` 用它与入库事件比较以识别过期事件（`OutdatedAttributeEvent`） |
| `meta` | object | 元数据包，键为 `MetaItemDescriptor` 名（见 `MetaItemType`，共 23 个内置项） |

**这个 jsonb 列是整个平台最关键的数据结构**：属性是否入库（`storeDataPoints`）、是否进规则引擎（`ruleState`）、是否绑定协议（`agentLink`）、受限/公开用户可见性（`accessRestrictedRead`/`accessPublicRead`）全在这里，而非表结构中。

#### 属性读写的两条路径

| 路径 | 实现 | 说明 |
|---|---|---|
| ORM | `assetStorageService.updateAttributeValue(em, event)` | 常规属性写入，走 Hibernate |
| 原生 SQL 辅助函数 | `ADD_ATTRIBUTE` / `REMOVE_ATTRIBUTES` / `ADD_UPDATE_META` / `REMOVE_META` | 供**迁移脚本**批量改属性结构用（见 §14），避免在 SQL 里手写繁琐的 jsonb 操作 |

#### jsonb 查询示例

`V20260302_01` 展示了基于 JSON Path 的属性筛选（找出缺少 schedule 的仿真链接）：

```sql
WHERE attributes @? '$.* ? (@.meta.agentLink.type == "SimulatorAgentLink" && !exists(@.meta.agentLink.schedule))'
```

> `ATTRIBUTES` 上**没有建 GIN 索引**。`AssetQuery.attributes`（`LogicGroup<AttributePredicate>`）生成的 jsonb 谓词因此是顺序扫描 + jsonb 解包。在资产数很大且按属性值过滤频繁的部署中，这是首要的性能关注点。

### 5.3 USER_ASSET_LINK

受限用户（`restricted_user` realm 角色）与资产的多对多关联表。受限用户只能看到通过该表关联的资产，对应 `AssetQuery.Access.PROTECTED`。

```java
@Entity
@Table(name = "USER_ASSET_LINK")
public class UserAssetLink {
  @EmbeddedId protected Id id;   // (realm, userId, assetId)
```

| 列 | 类型 | 约束 | JPA | 说明 |
|---|---|---|---|---|
| `ASSET_ID` | `char(22)` | PK 的一部分，FK → `ASSET(ID)` **ON DELETE CASCADE** | `id.assetId` | |
| `REALM` | `varchar(255)` | PK 的一部分，FK → `PUBLIC.REALM(NAME)` **ON DELETE CASCADE** | `id.realm` | JPA 标 `length = 36`，DDL 为 255 —— 不一致，见 §19 |
| `USER_ID` | `varchar(36)` | PK 的一部分，FK → `PUBLIC.USER_ENTITY(ID)` **ON DELETE CASCADE** | `id.userId` | Keycloak 用户 UUID |
| `CREATED_ON` | `timestamp with time zone` | NOT NULL | `createdOn` | `@CreationTimestamp` |

**派生字段**（`@Formula`，不是列）：`assetName`、`parentAssetName`、`userFullName` —— 由 Hibernate 在查询时 JOIN 出来，用于 UI 展示，避免前端额外请求。

三个外键都是 `ON DELETE CASCADE`：删资产、删用户或删租户时关联自动清理。

---

## 6. 时序数据域

两张数据点表结构完全相同，共用 `@MappedSuperclass Datapoint`：

```java
@MappedSuperclass
@IdClass(DatapointID.class)
public abstract class Datapoint implements Serializable {
  @Id @Column(name = "ENTITY_ID", length = 36, nullable = false) protected String assetId;
  @Id @Column(name = "ATTRIBUTE_NAME", nullable = false)         protected String attributeName;
  @Id @Column(name = "TIMESTAMP", updatable = false, nullable = false,
              columnDefinition = "TIMESTAMP")                    protected Date timestamp;
  @Column(name = "VALUE", nullable = false)
  @JdbcTypeCode(SqlTypes.JSON)                                   protected Object value;
}
```

两个子类都标 `@org.hibernate.annotations.Immutable` —— **数据点只插入，不更新**。

### 6.1 ASSET_DATAPOINT

实际采集的历史数据。

| 列 | 类型 | 约束 | 说明 |
|---|---|---|---|
| `TIMESTAMP` | `timestamp`（**无时区**） | PK 的一部分 | TimescaleDB 分区键。注意是 `timestamp` 而非 `timestamptz`，与资产表的 `CREATED_ON` 不同 —— 值按 UTC 写入 |
| `ENTITY_ID` | `varchar(22)` | PK 的一部分，FK → `ASSET(ID)` **ON DELETE CASCADE** | 资产 ID |
| `ATTRIBUTE_NAME` | `varchar(255)` | PK 的一部分 | 属性名（无外键，属性不是独立实体） |
| `VALUE` | `jsonb` | NOT NULL | 属性值，与 `ATTRIBUTES` 中的 `value` 同构 |

主键 `(TIMESTAMP, ENTITY_ID, ATTRIBUTE_NAME)` 天然保证同一属性同一时刻只有一个值（重复写入会冲突）。

### 6.2 ASSET_PREDICTED_DATAPOINT

预测/计划数据，由 `ForecastService`（按 `FORECAST` meta 计算）、规则的 `PredictedDatapoints` facade 或协议写入。

与 `ASSET_DATAPOINT` 的**两处差异**：

1. `ENTITY_ID` 是 `varchar(36)`（不是 22）—— 历史遗留，字段实际只存 22 字符的资产 ID；
2. **没有指向 `ASSET` 的外键**，因此删除资产不会级联清理预测数据。

`ApplyPredictedDataPointsService` 会按 `APPLY_PREDICTED_DATA_POINTS` meta 把到期的预测值"落地"成实际属性值。

### 6.3 TimescaleDB 配置

**转为 hypertable**（`V20230120_01`）：

```sql
SELECT public.create_hypertable('asset_datapoint',           'timestamp', if_not_exists := true, migrate_data := true);
SELECT public.create_hypertable('asset_predicted_datapoint', 'timestamp', if_not_exists := true, migrate_data := true);
```

**列存（Hypercore）**，仅对 `asset_datapoint`（`V20260506_02`）：

```sql
ALTER TABLE <schema>.asset_datapoint SET (
    timescaledb.enable_columnstore = true,
    timescaledb.orderby            = 'timestamp DESC',
    timescaledb.segmentby          = 'entity_id,attribute_name',
    timescaledb.chunk_interval     = '7 days');

CALL public.add_columnstore_policy('<schema>.asset_datapoint', after => INTERVAL '7 days');
```

| 参数 | 值 | 作用 |
|---|---|---|
| `segmentby` | `entity_id, attribute_name` | 同一属性的数据点物理聚簇，单属性时间范围查询只读少量 chunk |
| `orderby` | `timestamp DESC` | 段内按时间倒序，"最近 N 个值"最快 |
| `chunk_interval` | 7 天 | 与保留策略的周粒度对齐 |
| 列存策略 | 7 天后 | 近 7 天保持行存（写入友好），更老的数据压缩成列存 |

该迁移是**防御式**的：先检查 `timescaledb` 扩展存在（缺失则 `RAISE EXCEPTION`），再分别在嵌套 `BEGIN...EXCEPTION` 块中尝试移除遗留的 `compression_policy`（函数，用 `PERFORM`）和 `columnstore_policy`（存储过程，用 `EXECUTE 'CALL ...'`），失败只 `RAISE NOTICE` 不中断。

**保留清理**由 Java 侧而非 DB 策略执行：`AssetDatapointService` 调用 TimescaleDB 的 `drop_chunks()`，按**周粒度**对齐 7 天 chunk interval。默认无限保留；`OR_DATA_POINTS_MAX_AGE_DAYS` 全局配置，`dataPointsMaxAgeDays` meta 可按属性覆盖。

---

## 7. 规则域

三张表共用 `@MappedSuperclass Ruleset` 的字段，各自是独立 `@Entity`/`@Table`（**不是**继承到一张表）。

### 7.1 GLOBAL_RULESET

| 列 | 类型 | 约束 | JPA | 说明 |
|---|---|---|---|---|
| `ID` | `int8` | PK | `id` | `OPENREMOTE_SEQUENCE` |
| `VERSION` | `int8` | NOT NULL | `version` | `@Version` 乐观锁 |
| `CREATED_ON` | `timestamp with time zone` | NOT NULL | `createdOn` | 默认 `Instant.now()` |
| `LAST_MODIFIED` | `timestamp with time zone` | NOT NULL | `lastModified` | 由 `updateLastModified()` 在 `@PrePersist`/`@PreUpdate` 维护 |
| `NAME` | `varchar(255)` | NOT NULL | `name` | `@NotNull` |
| `ENABLED` | `boolean` | NOT NULL | `enabled` | 默认 `true`；`RulesService` 只为启用的规则集创建引擎 |
| `RULES` | `text` | NOT NULL | `rules` | 规则源码：Groovy 脚本、JSON 规则定义或 Flow 的 `NodeCollection` JSON |
| `RULES_LANG` | `varchar(255)` | NOT NULL | `lang` | `@Enumerated(STRING)`，`GROOVY`（默认）/ `JSON` / `FLOW` / `JAVASCRIPT`（**仅历史记录保留，不可新建**） |
| `META` | `jsonb` | — | `meta` (`Map<String,Object>`) | 任意元数据 |

**非列字段**：`status`（`RulesetStatus`）与 `error` 是 `@Transient` —— 部署状态是运行时信息，由 `RulesService` 填充后随 REST 响应返回，不入库。

### 7.2 REALM_RULESET

> 原名 `TENANT_RULESET`，`V20220523_03__RenameTenantRuleset.sql` 执行 `ALTER TABLE TENANT_RULESET RENAME TO REALM_RULESET`。实体 `RealmRuleset` 的 `@Table(name = "REALM_RULESET")` 与之一致。

在 `GLOBAL_RULESET` 全部字段之外，额外：

| 列 | 类型 | 约束 | JPA | 说明 |
|---|---|---|---|---|
| `REALM` | `varchar(255)` | NOT NULL，FK → `PUBLIC.REALM(NAME)` | `realm` | 规则集所属租户 |
| `ACCESS_PUBLIC_READ` | `boolean` | NOT NULL DEFAULT false | `accessPublicRead` | 允许匿名读取该规则集 |

DDL 中 `RULES_LANG` 带 `default 'GROOVY'`（`GLOBAL_RULESET` 无此默认值）。

### 7.3 ASSET_RULESET

| 列 | 类型 | 约束 | JPA | 说明 |
|---|---|---|---|---|
| `ASSET_ID` | `char(22)` | NOT NULL，FK → `ASSET(ID)` **ON DELETE CASCADE** | `assetId` | 规则集挂载的资产；删资产即删规则集 |
| `ACCESS_PUBLIC_READ` | `boolean` | NOT NULL DEFAULT false | `accessPublicRead` | |

`realm` 在 `AssetRuleset` 中是 `@Transient` —— 从所属资产推导，不存列。

**规则引擎的执行顺序**（`RulesService`）：全局 → 租户 → 资产（按资产层级从最老祖先向下）。同作用域内部顺序不保证。

---

## 8. 通知与告警域

### 8.1 NOTIFICATION

实体名 `SentNotification` —— 这张表是**发送记录**（已发生的事实），不是待发队列。

| 列 | 类型 | 约束 | JPA | 说明 |
|---|---|---|---|---|
| `ID` | `int8` | PK | `id` | `OPENREMOTE_SEQUENCE` |
| `NAME` | `varchar(255)` | — | `name` | 通知名称，用于 `RepeatFrequency` 去重节流 |
| `TYPE` | `varchar(50)` | NOT NULL | `type` | 通知通道：`push` / `email` / `localized`，对应 `NotificationHandler` 实现 |
| `TARGET` | `varchar(50)` | NOT NULL（DDL）；JPA 未标 nullable=false | `target` | `@Enumerated(STRING)`，`Notification.TargetType`：`REALM` / `USER` / `ASSET` / `CUSTOM` |
| `TARGET_ID` | `varchar(255)` | NOT NULL | `targetId` | 目标标识，语义随 `TARGET` 变化：realm 名 / 用户 ID / 资产 ID / 自定义串 |
| `SOURCE` | `varchar(50)` | NOT NULL | `source` | `@Enumerated(STRING)`，`Notification.Source`：含 `GLOBAL_RULESET`、`REALM_RULESET`、`ASSET_RULESET`、`CLIENT` 等 |
| `SOURCE_ID` | `varchar(43)` | — | `sourceId` | 发送方标识。43 字符上限对应规则集 ID 或资产 ID 的最大长度 |
| `REALM` | `varchar(255)` | NOT NULL（由 Java 迁移补上），`updatable = false` | `realm` | `V20260715_1443` 新增，见下 |
| `MESSAGE` | `jsonb` | — | `message` | `@JdbcTypeCode(JSON)`，多态 `AbstractNotificationMessage`（`PushNotificationMessage` / `EmailNotificationMessage` / `LocalizedNotificationMessage`） |
| `ERROR` | `varchar(4096)` | — | `error` | 发送失败原因 |
| `SENT_ON` | `timestamp with time zone` | NOT NULL | `sentOn` | |
| `DELIVERED_ON` | `timestamp with time zone` | — | `deliveredOn` | 送达确认（FCM 回执等） |
| `ACKNOWLEDGED_ON` | `timestamp with time zone` | — | `acknowledgedOn` | 用户确认时间 |
| `ACKNOWLEDGEMENT` | `varchar(255)` | — | `acknowledgement` | 确认内容，如用户点了哪个 `PushNotificationButton` |

#### REALM 列的两段式回填

`V20260715_1443__AddNotificationRealm.sql` + Java 迁移 `V20260715_1443_1__BackfillNotificationRealmUsers` 是一个**典型的跨系统回填**案例，值得单独说明：

SQL 部分（先加可空列，再按可从库内推导的来源回填，镜像 `NotificationService.resolveTargetRealm` 的逻辑）：

| 回填来源 | 规则 |
|---|---|
| `TARGET = 'REALM'` | `realm = TARGET_ID`（目标 ID 本身就是 realm 名） |
| `TARGET = 'ASSET'` | JOIN `ASSET`，取 `a.REALM` |
| `SOURCE = 'REALM_RULESET'` | `realm = SOURCE_ID` |
| `SOURCE = 'ASSET_RULESET'` | JOIN `ASSET` 取源资产的 realm |

Java 部分负责 SQL 做不到的事：`TARGET = 'USER'` 和 `SOURCE = 'CLIENT'` 的行需要**调 Keycloak API** 解析，之后应用 master 兜底，最后才加上 `NOT NULL` 约束。这是为什么该迁移必须拆成 `V20260715_1443`（SQL）+ `V20260715_1443_1`（Java）两步。

### 8.2 ALARM

实体名 `SentAlarm`。

| 列 | 类型 | 约束 | JPA | 说明 |
|---|---|---|---|---|
| `ID` | `int8` | PK | `id` | `OPENREMOTE_SEQUENCE` |
| `REALM` | `varchar(255)` | NOT NULL，`updatable = false` | `realm` | `@NotNull`。**注意：DDL 未对 `PUBLIC.REALM` 建外键**（与 `ASSET`、`REALM_RULESET`、`PROVISIONING_CONFIG` 不同） |
| `TITLE` | `varchar(255)` | NOT NULL | `title` | |
| `CONTENT` | `varchar(4096)` | — | `content` | |
| `SEVERITY` | `varchar(15)` | NOT NULL | `severity` | `@Enumerated(STRING)`，`Alarm.Severity` |
| `STATUS` | `varchar(15)` | NOT NULL | `status` | `@Enumerated(STRING)`，`Alarm.Status`；新建默认 `OPEN` |
| `SOURCE` | `varchar(50)` | NOT NULL | `source` | `@Enumerated(STRING)`，`Alarm.Source` |
| `SOURCE_ID` | `varchar(43)` | NOT NULL | `sourceId` | |
| `CREATED_ON` | `timestamp with time zone` | NOT NULL | `createdOn` | |
| `ACKNOWLEDGED_ON` | `timestamp with time zone` | — | `acknowledgedOn` | |
| `LAST_MODIFIED` | `timestamp with time zone` | NOT NULL | `lastModified` | |
| `ASSIGNEE_ID` | `varchar(255)` | FK → `PUBLIC.USER_ENTITY(ID)` **ON DELETE CASCADE** | `assigneeId` | 指派给某用户 |

**派生字段**（`@Formula`）：`sourceUsername`、`assigneeUsername` —— 从 Keycloak 的 `USER_ENTITY` JOIN 出用户名。
**关联**：`asset` (`List<Asset<?>>`) 通过 `ALARM_ASSET_LINK` 装载。

> `ASSIGNEE_ID` 的 `ON DELETE CASCADE` 值得注意：**删除一个用户会连带删除指派给他的所有告警**，而不是把 `ASSIGNEE_ID` 置空。如果告警需要作为审计记录长期保留，这个级联策略需要评估。

### 8.3 ALARM_ASSET_LINK

| 列 | 类型 | 约束 | JPA | 说明 |
|---|---|---|---|---|
| `SENTALARM_ID` | `int8` | PK 的一部分，FK → `ALARM(ID)` **ON DELETE CASCADE** | `id.sentalarmId` | |
| `REALM` | `varchar(255)` | PK 的一部分，FK → `PUBLIC.REALM(NAME)` **ON DELETE CASCADE** | `id.realm` | JPA 标 `length = 36`，DDL 为 255 —— 与 `USER_ASSET_LINK` 同样的不一致 |
| `ASSET_ID` | `varchar(22)` | PK 的一部分，FK → `ASSET(ID)` **ON DELETE CASCADE** | `id.assetId` | |
| `CREATED_ON` | `timestamp with time zone` | NOT NULL | `createdOn` | |

主键列序为 `(ASSET_ID, REALM, SENTALARM_ID)` —— 按资产查告警走索引前缀，按告警查资产则需全表扫描或额外索引（当前**没有**为 `SENTALARM_ID` 单独建索引）。

**派生字段**（`@Formula`）：`assetName`、`parentAssetName`。

---

## 9. 仪表盘域

### DASHBOARD

| 列 | 类型 | 约束 | JPA | 说明 |
|---|---|---|---|---|
| `ID` | `varchar(22)` / `char(22)` | PK | `id` | friendly-id |
| `CREATED_ON` | `timestamp with time zone` | NOT NULL | `createdOn` | |
| `REALM` | `varchar(255)` | NOT NULL，`updatable = false` | `realm` | `@NotBlank`，`@Size(1..255)`。**无外键** |
| `VERSION` | `int8` | NOT NULL | `version` (`Long`) | `@Version` 乐观锁 |
| `OWNER_ID` | `varchar(255)` | NOT NULL | `ownerId` | 创建者用户 ID |
| `ACCESS` | `int8` | NOT NULL | `access` (`DashboardAccess`) | 由 `VIEW_ACCESS` 重命名而来（见下） |
| `DISPLAY_NAME` | `varchar(255)` | NOT NULL | `displayName` | `@NotBlank` |
| `TEMPLATE` | `jsonb` | NOT NULL | `template` (`DashboardTemplate`) | `@JdbcTypeCode(JSON)`，`@NotNull` |

#### 访问控制列的演进

基线有两列 `VIEW_ACCESS` 和 `EDIT_ACCESS`，`V20250422_01__DashboardAccess.sql` 把模型简化为单一访问级别：

```sql
ALTER TABLE DASHBOARD DROP COLUMN edit_access;
ALTER TABLE DASHBOARD RENAME COLUMN view_access TO access;
```

`DashboardAccess` 枚举以 `int8` 存储 —— 实体字段**没有** `@Enumerated(EnumType.STRING)`，也没有 `AttributeConverter`，因此走 JPA 默认的 `ORDINAL` 映射。实际存储值：

| 值 | 常量 |
|---|---|
| `0` | `PUBLIC` |
| `1` | `SHARED` |
| `2` | `PRIVATE` |

**这意味着枚举常量的声明顺序就是数据契约**：在中间插入或重排常量会静默改变既有行的语义。

#### TEMPLATE jsonb 与两次数据迁移

`TEMPLATE` 存 `DashboardTemplate`：`widgets[]`（每个含 `widgetTypeId`、`widgetConfig`、`gridItem`）、响应式断点 `screenPresets`、缩放 `scalingPresets`、刷新间隔等。

两个迁移展示了**在 jsonb 内做结构演进**的手法：

**`V20250217_01__KeepExistingWidgetConfig.sql`** —— 为新增的 `allOfType` 开关填入保持既有行为的默认值（map 组件原本显示全部，table 组件不是）：

```sql
UPDATE dashboard SET template = jsonb_set(template, '{widgets}',
  (SELECT jsonb_agg(CASE
     WHEN widget->>'widgetTypeId' = 'map'   THEN jsonb_set(widget, '{widgetConfig,allOfType}', 'true'::jsonb)
     WHEN widget->>'widgetTypeId' = 'table' THEN jsonb_set(widget, '{widgetConfig,allOfType}', 'false'::jsonb)
     ELSE widget END)
   FROM jsonb_array_elements(template->'widgets') widget))
WHERE template->'widgets' IS NOT NULL;
```

**`V20250617_01__GatewayWidgetRefs.sql`** —— 把 gateway 组件的单值 `gatewayId` 改成通用的 `attributeRefs` 数组（空 `gatewayId` 转为 `[]`）。

两者都是 `jsonb_array_elements` 展开 → `CASE` 改写 → `jsonb_agg` 聚回 → `jsonb_set` 写入的同一模式。

---

## 10. 网关域

### GATEWAY_CONNECTION

**边缘侧**配置：本实例作为网关要连到哪个中心实例。每个本地 realm 最多一条（主键即 `LOCAL_REALM`）。

| 列 | 类型 | 约束 | JPA | 说明 |
|---|---|---|---|---|
| `LOCAL_REALM` | `varchar(255)` | **PK** | `localRealm` | 本地（边缘侧）realm |
| `REALM` | `varchar(255)` | NOT NULL | `realm` | 中心实例上的目标 realm |
| `HOST` | `varchar(255)` | NOT NULL | `host` | 中心实例主机；`@NotNull`，`@Size(1..255)` |
| `PORT` | `int8` | NULL | `port` (`Integer`) | `@Min(1) @Max(65536)`（注意上界应为 65535，见 §19） |
| `CLIENT_ID` | `varchar(36)` | NOT NULL | `clientId` | 中心侧为该网关创建的 Keycloak 客户端 ID |
| `CLIENT_SECRET` | `varchar(36)` | NOT NULL | `clientSecret` | `@Size(min=36, max=36)` 恰好 36 字符（UUID 形态） |
| `SECURED` | `boolean` | NULL | `secured` (`Boolean`) | 是否 TLS；三态（NULL = 未指定） |
| `DISABLED` | `boolean` | NOT NULL DEFAULT false | `disabled` | JPA 侧未标 `nullable = false` |
| `ATTRIBUTE_FILTERS` | `jsonb` | — | `attributeFilters` (`List<GatewayAttributeFilter>`) | `V20240711_01` 新增；控制哪些属性同步 |
| `SYNC_RULES` | `jsonb` | — | `assetSyncRules` (`Map<String, GatewayAssetSyncRule>`) | `V20250218_01` 新增；按资产类型配置同步规则 |

**中心侧没有对应表** —— 中心侧的网关以 `GatewayAsset`（`ASSET` 表中 `TYPE = 'GatewayAsset'` 的行）表示，连接状态作为该资产的属性存在 `ATTRIBUTES` 里。`V20240508_01__Gateways.sql` 正是用 §14 的辅助函数给所有既有 `GatewayAsset` 批量加上 `tunnelingSupported` 属性：

```sql
SELECT a.id, ADD_ATTRIBUTE(a, 'tunnelingSupported', 'boolean', null, now(), null)
FROM asset a WHERE a.type = 'GatewayAsset';
```

隧道本身（`GatewayTunnelInfo`）是运行时状态，不落库。

---

## 11. 置备域

### PROVISIONING_CONFIG

设备自动置备配置，单表继承（`TYPE` 判别），当前唯一子类是 `X509ProvisioningConfig`（`@DiscriminatorValue("x509")`）。

| 列 | 类型 | 约束 | JPA | 说明 |
|---|---|---|---|---|
| `ID` | `int8` | PK | `id` | `OPENREMOTE_SEQUENCE`；`@Min(1)` |
| `TYPE` | `varchar(100)` | NOT NULL | `type` | `@DiscriminatorColumn`，值 `x509` |
| `NAME` | `varchar(255)` | NOT NULL | `name` | `@NotNull` |
| `REALM` | `varchar(255)` | NOT NULL，FK → `PUBLIC.REALM(NAME)`，`updatable = false` | `realm` | |
| `CREATED_ON` | `timestamp with time zone` | NOT NULL | `createdOn` | 默认 `Instant.now()` |
| `LAST_MODIFIED` | `timestamp with time zone` | NOT NULL | `lastModified` | |
| `DISABLED` | `boolean` | NOT NULL DEFAULT false | `disabled` | |
| `ROLES` | `varchar(255)[]` | NULL | `userRoles` (`ClientRole[]`) | **PostgreSQL 数组列**（非 jsonb），存置备出的用户应获得的客户端角色 |
| `RESTRICTED_USER` | `boolean` | NOT NULL DEFAULT false | `restrictedUser` | 置备出的用户是否为受限用户 |
| `ASSET_TEMPLATE` | `text` | NULL | `assetTemplate` | 资产模板 JSON，置备时据此创建资产 |
| `DATA` | `jsonb` | — | 子类的 `data` | 基类**不映射**该列（见下） |

`DATA` 列的映射交给子类，`ProvisioningConfig` 的注释解释了原因：

> *"Implementors must annotate the data field with @Column as JPA (Hibernate) doesn't work with ..."*

即泛型字段无法在基类上正确映射，因此 `X509ProvisioningConfig` 自己声明：

```java
@Column(name = DATA_PROPERTY_NAME)
@JdbcTypeCode(SqlTypes.JSON)
protected X509ProvisioningData data;   // 存 CA 证书等
```

置备流程走 MQTT（`UserAssetProvisioningMQTTHandler`）：设备用 X.509 证书发起请求 → 校验签名 → 按 `ASSET_TEMPLATE` 建资产、按 `ROLES`/`RESTRICTED_USER` 建用户 → 返回 `SuccessResponseMessage` 或 `ErrorResponseMessage`。

---

## 12. 系统日志域

### SYSLOG_EVENT

| 列 | 类型 | 约束 | JPA | 说明 |
|---|---|---|---|---|
| `ID` | `int8` | PK | `id` | `OPENREMOTE_SEQUENCE` |
| `TIMESTAMP` | `timestamp with time zone` | NOT NULL | 继承自 `SharedEvent` 的 `timestamp` | **Unix 毫秒 `long`**，父类 `Event` 字段 |
| `CATEGORY` | `varchar(255)` | NOT NULL | `category` | `@Enumerated(STRING)`，`SyslogCategory`（如 `RULES`、`PROTOCOL`、`MODEL_AND_VALUES`、`AGENT`、`DATA`） |
| `LEVEL` | `int4` | NOT NULL | `level` | `@Enumerated(**ORDINAL**)`，`SyslogLevel`：`0`=INFO、`1`=WARN、`2`=ERROR |
| `SUBCATEGORY` | `varchar(1024)` | — | `subCategory` | 通常是 logger 名称 |
| `MESSAGE` | `varchar(131072)` | — | `message` | 128 KiB 上限 |

`SyslogEvent extends SharedEvent` —— 它既是 JPA 实体也是可通过 WebSocket 推送的事件，UI 的日志页因此能实时接收新日志而无需轮询。

`LEVEL` 用 `@Enumerated(EnumType.ORDINAL)` 存序数（而 `CATEGORY` 用 STRING）。与 `DASHBOARD.ACCESS` 同样的约束：**`SyslogLevel` 常量顺序是数据契约**。好处是序数天然单调递增（INFO=0 < WARN=1 < ERROR=2），可以直接写 `WHERE level >= 1` 取"警告及以上"（`LevelCategoryFilter` 正是依赖这一点做级别过滤）。

---

## 13. Keycloak 只读视图映射

Manager 不维护用户表，而是用 Hibernate `@Subselect` 把 Keycloak 的 `public` schema 表映射成**不可变只读实体**。这些实体**不对应 Manager schema 中的任何表**，Hibernate 也不会为它们生成 DDL。

| 实体 | `@Subselect` | 用途 |
|---|---|---|
| `Realm` | `select * from PUBLIC.REALM` | 租户，含密码策略、主题、token 生命周期等 |
| `User` | `select * from PUBLIC.USER_ENTITY` | 用户 |
| `UserAttribute` | `select * from PUBLIC.USER_ATTRIBUTE` | 用户自定义属性 |
| `RealmRole` | `select * from PUBLIC.KEYCLOAK_ROLE where NOT CLIENT_ROLE` | **仅 realm 角色**（过滤掉客户端角色） |
| `RealmView`（`manager` 包） | `select * from PUBLIC.REALM` | 与 `Realm` 同源的精简投影，供内部使用 |

### Realm 映射的列

`ID`（PK）、`NAME`、`DISPLAY_NAME`、`ENABLED`、`NOT_BEFORE`、`password_policy`、`reset_password_allowed`、`duplicate_emails_allowed`、`remember_me`、`registration_allowed`、`reg_email_as_username`、`verify_email`、`login_with_email_allowed`、`login_theme`、`account_theme`、`admin_theme`、`email_theme`、`access_token_lifespan`。

`password_policy` 用自定义 `PasswordPolicyDeserializer` 把 Keycloak 的策略串解析为 `List<String>`。

### User 映射的列与派生字段

| 列 / 派生 | 说明 |
|---|---|
| `ID`（PK）、`USERNAME`、`FIRST_NAME`、`LAST_NAME`、`EMAIL`、`ENABLED`、`CREATED_TIMESTAMP`、`REALM_ID` | `USER_ENTITY` 的直接列 |
| `realm`（`@Formula`） | `(select r.NAME from PUBLIC.REALM r where r.ID = REALM_ID)` —— 把 realm UUID 翻成 realm 名 |
| `secret`（`@Formula`） | `(SELECT C.SECRET FROM PUBLIC.CLIENT C WHERE C.ID = SERVICE_ACCOUNT_CLIENT_LINK)` —— 服务账户用户的客户端密钥 |

`RealmView` 也用 `@Formula` 取 `displayName`：`(select ra.VALUE from REALM_ATTRIBUTE ra where ra.REALM_ID = ID and ra.name = 'displayName')`。

> **耦合提示**：这些映射把 Manager 绑在 Keycloak 的**内部表结构**上，而内部 schema 不属于 Keycloak 的公开契约。Keycloak 大版本升级若调整 `USER_ENTITY` / `KEYCLOAK_ROLE` / `REALM_ATTRIBUTE`，这里会直接失效。写操作走 Keycloak Admin REST API（`ManagerKeycloakIdentityProvider`），只有读走视图。

---

## 14. 数据库函数

### 14.1 属性/元数据 CRUD 辅助函数

`V20221219_01__HelperFunctions.sql` 定义 4 个函数，`V20230105_01__HelperFunctionsFix.sql` 修复其中 2 个的 NULL 处理。它们接受一个 `asset` 行类型作为第一参数，便于在 `SELECT ... FROM asset` 中直接调用。

| 函数 | 签名 | 作用 |
|---|---|---|
| `ADD_ATTRIBUTE` | `(ASSET_ROW asset, ATTRIBUTE_NAME text, ATTRIBUTE_TYPE text, VALUE jsonb, TIME_STAMP timestamptz, META jsonb) → boolean` | 新增属性，自动构造 `{name,type,value,timestamp,meta}` 结构，并把 `timestamptz` 转成 Unix 毫秒：`(extract(epoch from TIME_STAMP AT TIME ZONE 'UTC') * 1000)::bigint` |
| `REMOVE_ATTRIBUTES` | `(ASSET_ROW asset, VARIADIC ATTRIBUTE_NAMES text[]) → boolean` | 批量删属性（`attributes - ATTRIBUTE_NAMES`） |
| `ADD_UPDATE_META` | `(ASSET_ROW asset, ATTRIBUTE_NAME text, META jsonb) → boolean` | 合并元数据到指定属性 |
| `REMOVE_META` | `(ASSET_ROW asset, ATTRIBUTE_NAME text, VARIADIC META_NAMES text[]) → boolean` | 删除指定元数据项 |

全部返回 `FOUND`（是否有行被更新）。

**`V20230105_01` 修的是什么**：原版 `REMOVE_META` / `ADD_UPDATE_META` 在属性没有 `meta` 键时，`a.attributes -> ATTRIBUTE_NAME -> 'meta'` 得到 SQL NULL，与之 `||` 拼接会把整个结果变成 NULL（属性被意外清空）。修复版加了 `'{}'::jsonb || COALESCE(jsonb_strip_nulls(...) -> 'meta', '{}'::jsonb)` 兜底。

用例：`V20240508_01`（给 GatewayAsset 加 `tunnelingSupported`）。

### 14.2 GET_ASSET_TREE_PATH

```sql
GET_ASSET_TREE_PATH(ASSET_ID text) → text[]
```

递归 CTE 从给定资产向上走到根，返回 `[self, parent, ..., root]` 的 ID 数组（**自底向上**）。基线迁移定义；`V20241210_01` 用它配合 `array_reverse` 重算所有资产的 `PATH`（ltree 需要自顶向下，故要反转）。

### 14.3 array_reverse

```sql
array_reverse(anyarray) → anyarray   -- STRICT IMMUTABLE
```

`V20241210_01` 定义的通用数组反转工具。

### 14.4 datapoint_metric_query

```sql
datapoint_metric_query() → integer
```

`V20260506_01` 定义，供 `deployment/query-exporter` 作为 Prometheus 指标采集。两步：

1. 找出**过去 1 天内数据点最多的** `(entity_id, attribute_name)` 组合；
2. 用**动态 SQL**（`EXECUTE format(...%L...)`）对该组合做 7–14 天前的 1 小时 `time_bucket` 平均聚合，返回桶数。

注释说明了为什么必须用动态 SQL 和为什么移除了 `jsonb_typeof` 检查：都是为了**保证走 Index Only Scan**。这个函数的用途是把"重负载聚合查询的耗时"变成一个可观测指标，而不是返回业务数据。

---

## 15. 触发器

### asset_parent_info_tgr

```sql
CREATE TRIGGER asset_parent_info_tgr
  BEFORE INSERT OR UPDATE ON ASSET
  FOR EACH ROW EXECUTE PROCEDURE update_asset_parent_info();
```

唯一的触发器，负责维护 `ASSET.PATH`。这也是 JPA 侧 `path` 字段标 `insertable=false, updatable=false` + `@Generated(INSERT, UPDATE)` 的原因 —— 值由数据库产生，Hibernate 写后回读。

**基线版本**（`V20191202_01`）只处理自身路径：

- `parent_id IS NULL` → `path = id`
- INSERT，或父节点发生变化 → 取父的 `path` 拼上自身 ID；父路径为空则 `RAISE EXCEPTION 'Invalid parent_id %'`

**`V20241210_01__ImproveAssetPath.sql` 修复的缺陷**：资产被**重新挂载父节点**时，只更新了自己的 `path`，**所有后代的 `path` 仍指向旧位置**。新版本：

```sql
ELSEIF TG_OP = 'UPDATE' AND NEW.parent_id IS DISTINCT FROM OLD.parent_id THEN
    cnode = NEW.id::ltree;
    SELECT A.path INTO ppath FROM ASSET A WHERE id = NEW.parent_id;
    IF index(ppath, cnode) > -1 THEN
        RAISE EXCEPTION 'Circular reference. Tried to set parent to % for row %, but % is already in parent path %', ...;
    ELSEIF ppath IS NULL AND NEW.parent_id IS NULL THEN  NEW.path = cnode;
    ELSEIF ppath IS NULL THEN  RAISE EXCEPTION 'Invalid parent_id %', NEW.parent_id;
    ELSE  NEW.path = ppath || cnode;
    END IF;
    -- 关键修复：同步修补所有后代
    UPDATE asset SET path = NEW.path || subpath(path, nlevel(OLD.path))
    WHERE path <@ OLD.path AND id <> OLD.id;
END IF;
```

两项改进：

1. **后代路径级联修补** —— `path <@ OLD.path` 选出子树，`subpath(path, nlevel(OLD.path))` 截掉旧前缀，拼上新前缀；
2. **环检测** —— `index(ppath, cnode) > -1` 判断新父节点的路径里是否已包含自己，是则拒绝。这补上了表级 `check (ID != PARENT_ID)` 只能防自环的不足（A→B→A 这类间接环靠它拦住）。

迁移同时用 `GET_ASSET_TREE_PATH` + `array_reverse` **重算所有既有资产的 `PATH`**，修正历史上因该缺陷产生的错误路径。

> 这个 `UPDATE` 在触发器内对同表执行，重挂一个大子树会触发大量行更新 —— 深层级 + 大批量重挂的操作需留意耗时。

---

## 16. 索引清单

### 显式创建的索引

| 索引 | 表 | 定义 | 来源 |
|---|---|---|---|
| `SECTION_PARENT_PATH_IDX` | `ASSET` | `USING GIST (path)` | `V20191202_01` |
| `SECTION_PARENT_ID_IDX` | `ASSET` | `(parent_id)` | `V20191202_01` |
| `asset_datapoint_entity_id_attribute_name_timestamp_idx` | `ASSET_DATAPOINT` | `(entity_id, attribute_name, timestamp DESC)` | `V20240722_01`，`V20251022_01` 重建 |
| `asset_predicted_datapoint_entity_id_attribute_name_timestamp_idx` | `ASSET_PREDICTED_DATAPOINT` | `(entity_id, attribute_name, timestamp DESC)` | 同上 |

GiST 索引是 ltree 子树查询（`<@`、`@>`）走索引的前提，直接决定 `AssetQuery.recursive` 的性能。

数据点索引的列序 `(entity_id, attribute_name, timestamp DESC)` 精准匹配最常见的访问模式："某资产某属性的最近 N 个值 / 某时间范围的值"。`DESC` 让"最新值"成为索引首项。

### V20251022_01 的 schema 名参数化

`V20240722_01` 把 schema 名 `openremote` **硬编码**在索引 DDL 里。`V20251022_01__UpdateIndexesSchemaName.sql` 先 `DROP INDEX IF EXISTS openremote.<name>` 再用 Flyway 占位符 `${schemaName}` 重建，使自定义 `OR_DB_SCHEMA` 的部署也能正确建索引。

占位符由 `PersistenceService` 注入：

```java
.placeholders(Map.of("schemaName", schemaName))
```

同样用到 `${schemaName}` 的迁移：`V20260518_01`（fillfactor）、`V20260923_1100`（delete_pending）、`V20260506_02`（列存策略）。

### 隐式索引

所有 `primary key` 自动产生唯一索引：

- `ASSET(ID)`、`DASHBOARD(ID)`、`GATEWAY_CONNECTION(LOCAL_REALM)`
- 7 张序列主键表的 `(ID)`
- `ASSET_DATAPOINT`/`ASSET_PREDICTED_DATAPOINT` 的 `(TIMESTAMP, ENTITY_ID, ATTRIBUTE_NAME)`
- `USER_ASSET_LINK(ASSET_ID, REALM, USER_ID)`、`ALARM_ASSET_LINK(ASSET_ID, REALM, SENTALARM_ID)`

TimescaleDB 另为 hypertable 的每个 chunk 维护时间维索引。

### 值得注意的索引缺口

| 缺口 | 影响 |
|---|---|
| `ASSET.ATTRIBUTES` 无 GIN 索引 | 按属性值过滤资产（`AssetQuery.attributes`）走顺序扫描 |
| `ASSET.REALM` 无索引 | 多租户部署中按 realm 列资产依赖顺序扫描（`PARENT_ID` 索引对根资产查询帮助有限） |
| `NOTIFICATION` 无二级索引 | 按 realm / 目标 / 时间查历史通知走全表扫描；该表随时间单调增长 |
| `SYSLOG_EVENT` 无二级索引 | 同上，日志页按级别/分类/时间过滤走全表扫描 |
| `ALARM` 无二级索引 | 按 realm / 状态 / assignee 查告警走全表扫描 |
| `ALARM_ASSET_LINK` 的 `SENTALARM_ID` 不是主键前缀 | "某告警关联了哪些资产"无法走索引 |

这些表都是写入持续增长、UI 频繁过滤查询的 —— 在数据量上来后是优化的首选位置。

---

## 17. 外键与级联行为

| 子表.列 | 父表.列 | ON DELETE | 后果 |
|---|---|---|---|
| `ASSET.PARENT_ID` | `ASSET.ID` | **无**（默认 RESTRICT） | 有子资产时不能直接删父资产；应用层须先处理子树（`deletePending` 软删除标记即服务于此） |
| `ASSET.REALM` | `PUBLIC.REALM.NAME` | 无 | 有资产的 realm 不能删 |
| `ASSET_DATAPOINT.ENTITY_ID` | `ASSET.ID` | **CASCADE** | 删资产自动清历史数据 |
| `ASSET_PREDICTED_DATAPOINT.ENTITY_ID` | — | **无外键** | 删资产**不会**清预测数据（与历史数据不一致，见 §19） |
| `REALM_RULESET.REALM` | `PUBLIC.REALM.NAME` | 无 | |
| `ASSET_RULESET.ASSET_ID` | `ASSET.ID` | **CASCADE** | 删资产自动删其规则集 |
| `USER_ASSET_LINK.USER_ID` | `PUBLIC.USER_ENTITY.ID` | **CASCADE** | 删用户清关联 |
| `USER_ASSET_LINK.ASSET_ID` | `ASSET.ID` | **CASCADE** | 删资产清关联 |
| `USER_ASSET_LINK.REALM` | `PUBLIC.REALM.NAME` | **CASCADE** | 删 realm 清关联 |
| `PROVISIONING_CONFIG.REALM` | `PUBLIC.REALM.NAME` | 无 | |
| `ALARM.ASSIGNEE_ID` | `PUBLIC.USER_ENTITY.ID` | **CASCADE** | **删用户会删掉指派给他的所有告警** |
| `ALARM_ASSET_LINK.SENTALARM_ID` | `ALARM.ID` | **CASCADE** | |
| `ALARM_ASSET_LINK.ASSET_ID` | `ASSET.ID` | **CASCADE** | |
| `ALARM_ASSET_LINK.REALM` | `PUBLIC.REALM.NAME` | **CASCADE** | |

**跨 schema 外键**：7 个外键指向 `public` schema 的 Keycloak 表（`REALM.NAME`、`USER_ENTITY.ID`）。这是双 schema 共库设计的直接体现 —— 也意味着 Manager 和 Keycloak **无法拆到两个数据库**，除非先去掉这些约束。

**无外键保护的 realm 列**：`ALARM.REALM`、`DASHBOARD.REALM`、`NOTIFICATION.REALM`、`GATEWAY_CONNECTION.REALM`/`LOCAL_REALM` 都没有指向 `PUBLIC.REALM` 的外键，与 `ASSET.REALM` 等的处理不一致（见 §19）。

---

## 18. Flyway 迁移清单

**配置**（`PersistenceService.java:625-636`）：

| 设置 | 值 | 含义 |
|---|---|---|
| `locations` | `classpath:org/openremote/manager/setup/database` 等 | `ManagerPersistenceService.appendSchemaLocations` 追加 |
| `schemas` | `<OR_DB_SCHEMA>` + `appendSchemas` 追加项 | |
| `baselineOnMigrate` | `true` | 允许在已有对象的库上建立基线 |
| `validateMigrationNaming` | `true` | 强制命名规范 |
| `cleanDisabled` | `false` | 允许 `clean`（开发/测试用） |
| `outOfOrder` | `OR_DB_FLYWAY_OUT_OF_ORDER`（默认 false） | 是否允许乱序应用 |
| `placeholders` | `{schemaName: <schema>}` | 供 `${schemaName}` 使用 |
| `initSql` | 设 `search_path` + 建 timescaledb 扩展 | 每次连接执行 |

**命名约定**（根 `AGENTS.md`）：`V<YYYYMMDD>_<HHmm>__<描述>.sql`，时间用 UTC，`V` 前缀大写。基线及早期脚本用的是 `V<YYYYMMDD>_<NN>__` 序号式（如 `V20191202_01`），新脚本应使用时间式（如 `V20260923_1100`）。

### SQL 迁移（23 个）

| 版本 | 名称 | 类型 | 内容 |
|---|---|---|---|
| `V20191202_01` | `Schema` | DDL | 基线：3 个扩展、1 个序列、11 张表、2 个函数、1 个触发器、9 个外键、2 个索引 |
| `V20220523_03` | `RenameTenantRuleset` | DDL | `TENANT_RULESET` → `REALM_RULESET` |
| `V20220705_01` | `Schema` | DDL | 建 `DASHBOARD` |
| `V20221219_01` | `HelperFunctions` | 函数 | 4 个属性/元数据 CRUD 函数 |
| `V20230105_01` | `HelperFunctionsFix` | 函数 | 修 `REMOVE_META`/`ADD_UPDATE_META` 的 NULL 处理 |
| `V20230120_01` | `Timescale` | DDL | 两张数据点表转 hypertable |
| `V20240508_01` | `Gateways` | 数据 | 给 `GatewayAsset` 加 `tunnelingSupported` 属性 |
| `V20240711_01` | `UpdateGatewayConnection` | DDL | `GATEWAY_CONNECTION` 加 `ATTRIBUTE_FILTERS jsonb` |
| `V20240722_01` | `Indexes` | 索引 | 两张数据点表的复合索引（schema 名硬编码） |
| `V20240813_01` | `Alarms` | DDL | 建 `ALARM`、`ALARM_ASSET_LINK` + 4 个外键 |
| `V20241210_01` | `ImproveAssetPath` | 函数+数据 | 重写路径触发器（后代级联 + 环检测）、加 `array_reverse`、重算全部 `PATH` |
| `V20250217_01` | `KeepExistingWidgetConfig` | 数据 | 仪表盘 map/table 组件补 `allOfType` |
| `V20250218_01` | `UpdateGatewayConnection` | DDL | `GATEWAY_CONNECTION` 加 `SYNC_RULES jsonb` |
| `V20250422_01` | `DashboardAccess` | DDL | 删 `EDIT_ACCESS`，`VIEW_ACCESS` → `ACCESS` |
| `V20250617_01` | `GatewayWidgetRefs` | 数据 | gateway 组件 `gatewayId` → `attributeRefs[]` |
| `V20251022_01` | `UpdateIndexesSchemaName` | 索引 | 用 `${schemaName}` 重建数据点索引 |
| `V20260120_01` | `addTableFunc` | 扩展 | `CREATE EXTENSION tablefunc` |
| `V20260302_01` | `RequireSimulatorSchedule` | 数据 | 给缺 schedule 的 `SimulatorAgentLink` 补每日调度（含两段验证用注释 SQL） |
| `V20260506_01` | `DatapointMetricQuery` | 函数 | `datapoint_metric_query()` 指标函数 |
| `V20260506_02` | `EnableHyperCore` | DDL | 启用列存 + 7 天后压缩策略（含扩展存在性快速失败） |
| `V20260518_01` | `AssetFillFactor` | DDL | `asset` 表 `fillfactor = 90` |
| `V20260715_1443` | `AddNotificationRealm` | DDL+数据 | `NOTIFICATION` 加 `realm` 并部分回填 |
| `V20260923_1100` | `AssetDeletePending` | DDL | `asset` 加 `delete_pending boolean NOT NULL DEFAULT false` |

### Java 迁移（`manager/setup/database/`）

Java 迁移处理 SQL 做不到的事 —— 主要是需要调 **Keycloak Admin API** 的变更。基类 `AbstractKeycloakMigration` / `AbstractKeycloakRolesMigration`。

| 版本 | 作用 |
|---|---|
| `V20250916_01__AddServiceRoles` | 新增服务相关客户端角色（`read:services` / `write:services`） |
| `V20260715_1443_1__BackfillNotificationRealmUsers` | 接 `V20260715_1443`：解析 USER/CLIENT 来源的 realm、master 兜底、最后加 `NOT NULL` |
| `V20260715_1444__AddNotificationRoles` | 新增 `read:notifications` / `write:notifications` 角色 |
| `V20260903_1000__AddTunnelRoles` | 新增 `read:tunnels` / `write:tunnels` 角色 |
| `Disabled_V20171031_03__Migration` | 已停用（`Disabled_` 前缀使 Flyway 不识别为迁移） |

---

## 19. 已发现的问题

静态分析中发现的不一致与风险点，按严重度排序。均为**观察结论**，是否需要处理取决于实际部署场景。

### 19.1 `ConsoleAppConfig` 被注册为实体，但它不是实体

`PersistenceService.start():385` 把 `ConsoleAppConfig.class.getName()` 加入实体清单，但 `model/src/main/java/org/openremote/model/apps/ConsoleAppConfig.java` **没有任何 `jakarta.persistence` 注解**（该文件对 `jakarta.persistence` 的 import 数为 0），字段只有 `@JsonProperty`，也没有任何迁移脚本创建对应表。

同方法中第 3、4 批注册都做了 `.filter(c -> c.getAnnotation(Entity.class) != null)`，唯独第 1 批硬编码清单不过滤。这是一处残留：该类应从清单移除，或给第 1 批也加上同样的过滤。

### 19.2 `ASSET_PREDICTED_DATAPOINT` 缺少指向 `ASSET` 的外键

`ASSET_DATAPOINT.ENTITY_ID` 有 `FK → ASSET(ID) ON DELETE CASCADE`，而 `ASSET_PREDICTED_DATAPOINT` 没有任何外键。后果：**删除资产后其预测数据点成为孤儿行**，既不会被清理，也不会被任何查询命中（无资产可引用），只是持续占用存储和 hypertable chunk。

两张表同为数据点、同一基类、同为 hypertable，这个差异看不出设计意图。

### 19.3 `ALARM.ASSIGNEE_ID` 的 CASCADE 会删除告警

```sql
alter table ALARM add foreign key (ASSIGNEE_ID) references PUBLIC.USER_ENTITY (ID) on delete cascade;
```

删除一个 Keycloak 用户会**连带删除所有指派给该用户的告警行**，而不是把 `ASSIGNEE_ID` 置为 NULL。`ASSIGNEE_ID` 本身可空，所以 `ON DELETE SET NULL` 在语义上是可行的。如果告警被当作运维审计记录使用，员工离职清理账号会静默丢失历史。

### 19.4 多个 `REALM` 列缺少外键约束

有外键的：`ASSET`、`REALM_RULESET`、`PROVISIONING_CONFIG`、`USER_ASSET_LINK`、`ALARM_ASSET_LINK`。
没有外键的：`ALARM.REALM`、`DASHBOARD.REALM`、`NOTIFICATION.REALM`、`GATEWAY_CONNECTION.REALM` 与 `LOCAL_REALM`。

同一个概念（租户归属）在不同表上保护强度不同。注意 `ALARM_ASSET_LINK.REALM` 有外键而 `ALARM.REALM` 没有 —— 同一特性的两张表就不一致。

### 19.5 JPA 与 DDL 的列长度不一致

| 表.列 | DDL | JPA `@Column(length)` |
|---|---|---|
| `USER_ASSET_LINK.REALM` | `varchar(255)` | `36` |
| `ALARM_ASSET_LINK.REALM` | `varchar(255)` | `36` |
| `ASSET_PREDICTED_DATAPOINT.ENTITY_ID` | `varchar(36)` | `36`（基类 `Datapoint`） |
| `ASSET_DATAPOINT.ENTITY_ID` | `varchar(22)` | `36`（同一基类） |

因为 schema 由 Flyway 管理而非 `hbm2ddl` 生成，`length` 不影响实际 DDL，但它**参与 Hibernate 的校验与元数据**，且会误导读代码的人。`realm` 名在 `ASSET` 表中按 255 定义，`length = 36` 显然是误抄了 UUID 长度。

### 19.6 两处 `@Enumerated(ORDINAL)` 使枚举顺序成为数据契约

| 字段 | 枚举 | 存储 |
|---|---|---|
| `DASHBOARD.ACCESS` | `DashboardAccess` | `int8`（无 `@Enumerated` 注解 → JPA 默认 ORDINAL） |
| `SYSLOG_EVENT.LEVEL` | `SyslogLevel` | `int4`（显式 `@Enumerated(EnumType.ORDINAL)`） |

在枚举中间插入常量或重新排序，会**静默改变所有既有行的含义**，且没有任何报错。`SyslogLevel` 用序数有明确收益（`INFO=0 < WARN=1 < ERROR=2` 单调递增，可以 `WHERE level >= 1` 做范围过滤，`LevelCategoryFilter` 正依赖此）；`DashboardAccess` 则看不出必须用序数的理由，且它是**隐式**的（没写 `@Enumerated`，靠 JPA 默认值），比显式写出来更容易被忽视。

对比：同为枚举的 `ALARM.SEVERITY`/`STATUS`/`SOURCE`、`NOTIFICATION.TARGET`/`SOURCE`、`RULES_LANG`、`SYSLOG_EVENT.CATEGORY` 都用 `@Enumerated(STRING)`。

### 19.7 `GatewayConnection.port` 的上界是 65536

```java
@Min(value = 1) @Max(value = 65536) @Column(name = "PORT")
protected Integer port;
```

TCP 端口的有效范围是 1–65535。`65536` 会通过校验但不是合法端口。

### 19.8 增长型表缺少二级索引

`NOTIFICATION`、`SYSLOG_EVENT`、`ALARM` 三张表只有主键索引，而它们都是**持续追加**且 UI 会按 realm / 状态 / 时间范围过滤查询的。`ASSET.REALM` 同样无索引，多租户部署中列租户资产会扫全表。`ASSET.ATTRIBUTES` 无 GIN 索引，按属性值过滤资产亦然。

`SYSLOG_EVENT` 与 `NOTIFICATION` 的增长没有自动清理机制（不像数据点表有 `drop_chunks` 保留策略），长期运行的实例需要自行安排归档。

### 19.9 与 Keycloak 内部 schema 的紧耦合

5 个 `@Subselect` 实体直接 `select * from PUBLIC.<KeycloakTable>`，另有 7 个外键指向 `PUBLIC.REALM` / `PUBLIC.USER_ENTITY`，并有 3 处 `@Formula` 内联查询 `PUBLIC.REALM`、`PUBLIC.CLIENT`、`REALM_ATTRIBUTE`。

Keycloak 的数据库 schema **不是公开契约**，不受其版本兼容承诺保护。这带来两个约束：

1. Keycloak 大版本升级可能因内部表结构调整而破坏这些映射；
2. Manager 与 Keycloak **无法分库部署** —— 跨 schema 外键要求两者在同一数据库实例内。

---

*文档生成于 2026-10-17，基于 `mydev` 分支 HEAD `8f8a5d2`。*
