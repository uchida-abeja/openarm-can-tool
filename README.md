# OpenArm Damiao レジスタ・ダンプ/復元ツール マニュアル

## 0. 目的とできること

このツールは、OpenArmに搭載されたDamiao製QDDモータ（DM8009 / DM4340 / DM4310等）に対して、

* **レジスタ値の一括取得（ダンプ）** → CSVに保存
* **CSVの内容を一括書き戻し（復元）**（安全フィルタ付き）
* 必要に応じて **書き込み後の検証（verify）**
* 必要に応じて **Flashへ保存（storage parameters）**

を、Linuxの `can-utils`（`cansend`, `candump`）で実施するためのものです。
Damiaoのレジスタ読み書きは **CAN ID=0x7FF**、Read=**0x33**、Write=**0x55**、Storage=**0xAA 0x01** を使います。 ([Manuals+][2])

---

## 1. 前提（環境）

* Linux（OpenArmは現状Linux前提） ([Hugging Face][1])
* `can-utils`（`cansend`, `candump`）
* `python3`（float32変換・タイムアウト計算などで使用）
* CANインターフェース（例 `can0`）がUPしていること

---

## 2. CANインターフェース事前セットアップ

### 2.1 CAN FD（OpenArm推奨）

OpenArmはデフォルトで **CAN FD有効**、nominal 1Mbps / data 5Mbps を前提にしています。 ([Hugging Face][1])

```bash
sudo ip link set can0 down
sudo ip link set can0 type can bitrate 1000000 dbitrate 5000000 fd on
sudo ip link set can0 up
```

### 2.2 通常CAN（FDなし）

```bash
sudo ip link set can0 down
sudo ip link set can0 type can bitrate 1000000
sudo ip link set can0 up
```

> 注意：モータがCAN FD設定の場合、**CAN2.0Bは受信できても、フィードバックがCAN FDで送られて上位が取り逃す**ことがあり、「送れてるのに受けられない」状況の原因になります。OpenArm運用ではCAN FD設定が基本です。 ([Manuals+][2])

---

## 3. OpenArmのモータCAN ID（デフォルト）

OpenArmのデフォルトは以下です（Send IDがコマンド、Recv IDがフィードバック/レジスタ応答の受信側）。 ([Hugging Face][1])

| Joint   | Motor  | Send ID | Recv ID |
| ------- | ------ | ------: | ------: |
| joint_1 | DM8009 |    0x01 |    0x11 |
| joint_2 | DM8009 |    0x02 |    0x12 |
| joint_3 | DM4340 |    0x03 |    0x13 |
| joint_4 | DM4340 |    0x04 |    0x14 |
| joint_5 | DM4310 |    0x05 |    0x15 |
| joint_6 | DM4310 |    0x06 |    0x16 |
| joint_7 | DM4310 |    0x07 |    0x17 |
| gripper | DM4310 |    0x08 |    0x18 |

---

## 4. Damiao “レジスタ読み書き” のフレーム仕様（0x7FF）

### 4.1 読み出し（Read = 0x33）

**CAN ID = 0x7FF**、データは以下： ([Manuals+][2])

* `D0=CANID_L`（例: 0x01）
* `D1=CANID_H`（通常 0x00）
* `D2=0x33`
* `D3=RID`
* `D4..D7=0`

例：ID=0x01の CTRL_MODE（RID=0x0A）を読む

```bash
cansend can0 7FF#0100330A00000000
```

返答は **Recv ID（例 0x11）** から、
`D4..D7` に 32-bit値（float or uint32、**little-endian**）で返ります。 ([Manuals+][2])

### 4.2 書き込み（Write = 0x55）

**CAN ID = 0x7FF**、データ： ([Manuals+][2])

* `D0 CANID_L`
* `D1 CANID_H`
* `D2 0x55`
* `D3 RID`
* `D4..D7 data(32-bit little-endian)`

例：ID=0x01の VMAX（RID=0x16）へ float32を書き込む

```bash
cansend can0 7FF#01005516XXXXXXXX
```

### 4.3 保存（Storage parameters = 0xAA 0x01）

レジスタwriteは **即時反映だが電源断で消える**ため、Flashへ保存するには storage コマンドを使います。 ([Manuals+][2])

* `0x7FF# <CANID_L> <CANID_H> AA 01 00 00 00 00`

> **重要**：storageは **disabled状態でのみ有効**、1回最大30ms、Flash書換寿命（目安1万回）注意。 ([Manuals+][2])

---

## 5. 付随コマンド（Clear / Enable / Disable）

モータへの制御フレーム（Send ID側）として以下が定義されています。 ([Manuals+][2])

* Enable: `FF FF FF FF FF FF FF FC`
* Disable: `FF FF FF FF FF FF FF FD`
* Clear errors: `FF FF FF FF FF FF FF FB`

例（ID=0x01）：

```bash
cansend can0 001#FFFFFFFFFFFFFFFB  # clear
cansend can0 001#FFFFFFFFFFFFFFFC  # enable
```

---

# 6. ツールの使い方

## 6.1 ダンプ（CSV保存）

### コマンド

```bash
IFACE=can0 OUT=openarm_regs.csv ./dump_openarm_registers.sh
```

### 出力CSVの列

* `node_name` / `node_id_hex` / `recv_id_hex`
* `rid_hex` / `rid_name`
* `type`（`f32`/`u32`/`unknown`）
* `writable`（yes/no）
* `dangerous`（yes/no：通信断の危険がある項目）
* `status`（OK/TIMEOUT）
* `raw_le_hex`（D4..D7のLE32）
* `value`（型に応じて解釈した値）

### TIMEOUTの意味

* **そのRIDが間違い**とは限りません。
* よくある原因：

  * そのモータFWがそのRID未実装（RO/未対応）
  * 連続問い合わせで処理が詰まって取りこぼす（`TIMEOUT_S`/`INTERVAL_S`調整）
  * 物理層エラー（ただしあなたはすでに個別Read成功済みなので可能性低）

まずは `TIMEOUT_S=0.8`、`INTERVAL_S=0.02` などに増やすのが実務的です。

```bash
TIMEOUT_S=0.8 INTERVAL_S=0.02 IFACE=can0 OUT=openarm_regs.csv ./dump_openarm_registers.sh
```

---

## 6.2 復元（CSV→レジスタ書き戻し）

### 基本（安全デフォルト）

```bash
IFACE=can0 ./restore_openarm_registers.sh openarm_regs.csv --verify
```

* `writable=yes` かつ `dangerous=no` のみを書き戻します（通信断リスクのあるID/baud/timeout類を避ける）。

### 危険レジスタも含める（非推奨）

```bash
IFACE=can0 ./restore_openarm_registers.sh openarm_regs.csv --verify --include-dangerous
```

### Flash保存まで実施（必要時のみ）

```bash
IFACE=can0 ./restore_openarm_registers.sh openarm_regs.csv --verify --store
```

> storageはdisabledでのみ有効・Flash寿命に影響するので、**頻繁な実行は避ける**のが前提です。 ([Manuals+][2])

---

# 7. Damiao レジスタテーブル（RID一覧）

以下はDamiaoマニュアルの **Register list and range**（抜粋ではなく主要一覧）です。 ([Manuals+][2])
※PDF内で `0x0A` が二重に出るなど表記の揺れがありますが、あなたの実機確認では **0x0A=CTRL_MODE** が成立しています（OpenArm運用ではID/baud系は基本触らないのが安全です）。 ([Manuals+][2])

> 型：`float`＝float32、`uint32`＝uint32。Read/Writeの値は `D4..D7` の32-bit little-endian。 ([Manuals+][2])

## 7.1 設定・保護系（0x00〜0x24）

| RID(hex) | 変数        | 説明                 | R/W | 型      | 範囲/備考（マニュアル）                          |
| -------: | --------- | ------------------ | --- | ------ | ------------------------------------- |
|     0x00 | UV_Value  | 低電圧保護              | RW  | float  | (10.0, fmax]                          |
|     0x01 | KT_Value  | トルク係数              | RW  | float  | [0.0, fmax]                           |
|     0x02 | OT_Value  | 過温保護温度             | RW  | float  | [80.0, 200)                           |
|     0x03 | OC_Value  | 過電流保護              | RW  | float  | (0.0, 1.0)                            |
|     0x04 | ACC       | 加速                 | RW  | float  | (0.0, fmax)                           |
|     0x05 | DEC       | 減速                 | RW  | float  | [-fmax, 0.0)                          |
|     0x06 | MAX_SPD   | 最大速度               | RW  | float  | (0.0, fmax]                           |
|     0x07 | MST_ID    | フィードバックID          | RW  | uint32 | [0, 0x7FF]（※変更注意）                     |
|     0x09 | TIMEOUT   | 通信断タイムアウト          | RW  | uint32 | [0, 2^32-1]（0は危険になり得る）                |
|     0x0A | CTRL_MODE | 制御モード              | RW  | uint32 | [0, 4]（1:MIT,2:PosVel,3:Vel,4:Hybrid） |
|     0x0B | Damp      | 粘性係数               | RO  | float  | -                                     |
|     0x0C | Inertia   | 慣性                 | RO  | float  | -                                     |
|     0x0D | hw_ver    | HW version         | RO  | uint32 | -                                     |
|     0x0E | sw_ver    | SW version         | RO  | uint32 | -                                     |
|     0x0F | SN        | シリアル               | RO  | uint32 | -                                     |
|     0x10 | NPP       | 極対数                | RO  | uint32 | -                                     |
|     0x11 | Rs        | 相抵抗                | RO  | float  | -                                     |
|     0x12 | Ls        | 相インダクタンス           | RO  | float  | -                                     |
|     0x13 | Flux      | 磁束                 | RO  | float  | -                                     |
|     0x14 | Gr        | 減速比                | RO  | float  | -                                     |
|     0x15 | PMAX      | 位置マッピング範囲          | RW  | float  | (0.0, fmax]                           |
|     0x16 | VMAX      | 速度マッピング範囲          | RW  | float  | (0.0, fmax]                           |
|     0x17 | TMAX      | トルクマッピング範囲         | RW  | float  | (0.0, fmax]                           |
|     0x18 | I_BW      | 電流ループ帯域            | RW  | float  | [100.0, 1e4]                          |
|     0x19 | KP_ASR    | 速度ループKp            | RW  | float  | [0.0, fmax]                           |
|     0x1A | KI_ASR    | 速度ループKi            | RW  | float  | [0.0, fmax]                           |
|     0x1B | KP_APR    | 位置ループKp            | RW  | float  | [0.0, fmax]                           |
|     0x1C | KI_APR    | 位置ループKi            | RW  | float  | [0.0, fmax]                           |
|     0x1D | OV_Value  | 過電圧保護              | RW  | float  | TBD                                   |
|     0x1E | GREF      | ギア効率               | RW  | float  | (0.0, 1.0]                            |
|     0x1F | Deta      | 速度ループ減衰            | RW  | float  | [1.0, 30.0]                           |
|     0x20 | V_BW      | 速度フィルタ帯域           | RW  | float  | (0.0, 500.0)                          |
|     0x21 | IQ_c1     | 電流ループ強化係数          | RW  | float  | [100.0, 1e4]                          |
|     0x22 | VL_c1     | 速度ループ強化係数          | RW  | float  | (0.0, 1e4]                            |
|     0x23 | can_br    | CAN baud rate code | RW  | uint32 | 0..9（※変更注意：通信断の原因）                    |
|     0x24 | sub_ver   | サブバージョン            | RO  | uint32 | -                                     |

## 7.2 キャリブ/内部（0x32〜）

| RID(hex) | 変数    | 説明                           | R/W | 型     |
| -------: | ----- | ---------------------------- | --- | ----- |
|     0x32 | u_off | u相オフセット                      | RO  | float |
|     0x33 | v_off | v相オフセット                      | RO  | float |
|     0x34 | k1    | 補償係数1                        | RO  | float |
|     0x35 | k2    | 補償係数2                        | RO  | float |
|     0x36 | m_off | 角度オフセット                      | RO  | float |
|     0x37 | dir   | 方向                           | RO  | float |
|     0x50 | p_m   | motor current position（精密位置） | RO  | float |
|     0x51 | xout  | output shaft position        | RO  | float |

（上記一覧はマニュアル表の該当箇所に基づく） ([Manuals+][2])

---

# 8. 典型運用フロー（推奨）

1. **現状ダンプ**

   ```bash
   IFACE=can0 OUT=openarm_regs.csv ./dump_openarm_registers.sh
   ```

2. （必要なら）CSVをバックアップして編集・比較（例：VMAX/TMAXなど）

3. **復元（安全）＋verify**

   ```bash
   IFACE=can0 ./restore_openarm_registers.sh openarm_regs.csv --verify
   ```

4. **Flash保存が必要な場合のみ**

   ```bash
   IFACE=can0 ./restore_openarm_registers.sh openarm_regs.csv --verify --store
   ```

---

# 9. 注意事項（重要）

* `MST_ID(0x07)` や `can_br(0x23)`、`TIMEOUT(0x09)` などは、設定を誤ると **通信が途切れて復旧が面倒**です（ツールはデフォルトで復元対象から除外）。 ([Manuals+][2])
* storage（Flash書込）は寿命があるので、**頻繁に回さない**。 ([Manuals+][2])
* OpenArmのID構成はLeRobotドキュメントに沿うのが基本です（勝手に変えるとLeRobot側との整合が崩れます）。 ([Hugging Face][1])


[1]: https://huggingface.co/docs/lerobot/en/openarm?utm_source=chatgpt.com "OpenArm"
[2]: https://manuals.plus/m/95b7b82c505a4eb6dca555b29e71aa35d470f4a1fcb0b02f62857dbf6d26d6db_optim.pdf?utm_source=chatgpt.com "DAMIAO DM-H3510 Hub Motor User Manual"
