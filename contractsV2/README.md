# Pons V2 合约 — 业务逻辑与事件详解

Pons V2 是一套 memecoin 发射台（launchpad）合约。它的核心思路是：**代币全部供应量先铸造到一条恒定乘积（constant-product）债券曲线上，用户直接在曲线上买卖；当曲线的可售份额被买空时，剩余储备"毕业"迁移到一个由共享 Hook 治理的 Uniswap V4 全区间池，并把仓位 NFT 永久锁死。**

整套设计有一条贯穿始终的主线：**曲线从第一笔交易起就收取未来池子要用的那种报价资产（quote asset）**。因此毕业时不需要任何兑换、不需要路由器、不需要价格预言机 —— 曲线里存的就是池子要用的东西。

- **Solidity**: `^0.8.26`
- **依赖**: OpenZeppelin、Uniswap V4 core / periphery / hooks、Permit2
- **构建**: `forge build`（配置见 [构建](#构建) 一节，必须启用 IR 管线）

---

## 目录

- [合约清单与职责](#合约清单与职责)
- [核心业务流程](#核心业务流程)
  - [阶段 0：协议初始化与配置](#阶段-0协议初始化与配置)
  - [阶段 1：发射](#阶段-1发射)
  - [阶段 2：曲线交易期](#阶段-2曲线交易期)
  - [阶段 3：毕业（两段式）](#阶段-3毕业两段式)
  - [阶段 4：V4 池运行期](#阶段-4v4-池运行期)
- [费用模型](#费用模型)
- [回购金库：五年线性释放](#回购金库五年线性释放)
- [权限与治理模型](#权限与治理模型)
- [应急救援路径](#应急救援路径)
- [事件详解](#事件详解)
- [已知缺口与注意事项](#已知缺口与注意事项)
- [构建](#构建)

---

## 合约清单与职责

| 合约 | 行数 | 职责 |
| --- | --- | --- |
| `PonsV2LaunchFactory` | 1526 | 总控。发射入口、发射配置、报价资产白名单、毕业编排、创作者收款人治理、救援路径 |
| `PonsV2BondingCurve` | 797 | 单个发射的债券曲线。买/卖、费用计提、费用清算、回购、移交储备 |
| `PonsV2MemeHook` | 887 | 单例 V4 Hook。毕业后所有池共用。`afterSwap` 抽费、内部兑换、回购、分账。**同时它就是全协议的 `IPonsV2FeePolicy`** |
| `PonsV2BuybackVault` | 357 | 单例。所有发射回购来的代币在此按五年线性释放（不销毁） |
| `PonsV2GraduationExecutor` | 209 | 毕业时铸造 V4 全区间仓位。拆出来纯粹是为了让 Factory 字节码不超 EIP-170 |
| `PonsV2LaunchDeployer` | 149 | 用 CREATE2 部署曲线与代币。拆出来同样是为了 Factory 的体积 |
| `PonsV2LaunchLocker` | 123 | 永久持有毕业后的 V4 仓位 NFT 与锁死的代币余量。**没有任何提取函数** |
| `PonsV2GraduationGuard` | 125 | 无状态预检。在不可逆的资产移交之前，模拟 V4 铸造会不会被拒 |
| `PonsV2LauncherToken` | 106 | 固定供应量 ERC-20。全部供应量在构造函数里铸给曲线 |
| `libraries/PonsV2BondingCurveMath` | 88 | 恒定乘积定价（`getAmountOut` / `quoteAmountOut` / `getAmountIn`） |
| `libraries/PonsV2GraduationMath` | 63 | 从两侧金额反推 V4 开池所需的 `sqrtPriceX96` |
| `interfaces/ILaunchpadV2` | 139 | 共享接口：费用托管、费用政策、发射记录、毕业阶段枚举 |

### 依赖拓扑

```
                        ┌─────────────────────┐
                        │  PonsV2MemeHook     │  ← 单例，同时是 IPonsV2FeePolicy
                        │  (V4 Hook + 政策)    │
                        └──────────┬──────────┘
                                   │ 读取政策
        ┌──────────────────────────┼──────────────────────────┐
        │                          │                          │
┌───────▼────────┐      ┌──────────▼──────────┐    ┌──────────▼─────────┐
│ PonsV2Bonding  │      │ PonsV2LaunchFactory │    │ PonsV2BuybackVault │
│ Curve (每发射)  │◄─────┤      (总控)          ├───►│      (单例)         │
└───────┬────────┘      └──────────┬──────────┘    └────────────────────┘
        │                          │
        │              ┌───────────┼───────────┬──────────────┐
        │              │           │           │              │
        │        ┌─────▼─────┐ ┌───▼────┐ ┌────▼─────┐ ┌──────▼──────┐
        │        │ Launch    │ │Gradua- │ │Gradua-   │ │ LaunchLocker│
        │        │ Deployer  │ │tionExec│ │tionGuard │ │  (永久锁)    │
        │        └───────────┘ └────────┘ └──────────┘ └─────────────┘
        │
        └──────────────► IPonsV2FeeEscrow（可领取余额账本，实现不在本仓库）
```

> **注意**：`IPonsV2FeeEscrow` 在本仓库中**只有接口，没有实现合约**。所有协议方/创作者的费用收入都通过它派发（`credit` / `creditToken` 记账，收款人自己 `claim`）。部署时必须提供一个外部的托管合约地址。

---

## 核心业务流程

### 阶段 0：协议初始化与配置

单例合约（Hook、金库、Locker）与 Factory 存在**循环依赖**：Factory 的构造函数需要它们的地址，而它们又需要认 Factory 为唯一特权调用者。因此采用"先部署、后一次性接线"的模式：

1. 部署 `PonsV2MemeHook`（地址需要 mine，因为 V4 用地址低位比特编码 hook 权限）、`PonsV2BuybackVault`、`PonsV2LaunchLocker`。
2. 部署 `PonsV2LaunchFactory`（构造时传入上述地址 + PoolManager / PositionManager / Permit2 / FeeEscrow）。
3. 部署 `PonsV2LaunchDeployer`、`PonsV2GraduationExecutor`（构造时传入 Factory 地址）。
4. 一次性接线（每个都只能设一次）：
   - `memeHook.setFactory()` / `memeHook.setBuybackVault()`
   - `buybackVault.setFactory()`
   - `locker.setFactory()`
   - `factory.setLaunchDeployer()` / `factory.setGraduationExecutor()`

`_requireLaunchDependenciesWired()` 会在**每一次发射**时把整张接线图重新校验一遍（谁指向谁、PoolManager/Escrow 是否一致），所以半接线状态下无法发射 —— 避免出现"能买入但永远无法清算费用或毕业"的僵局。

#### 发射配置（LaunchConfig）

Owner 维护一个 `LaunchConfig[]` 数组，创作者发射时按下标选择：

| 字段 | 含义 | 约束 |
| --- | --- | --- |
| `supply` | 代币总供应量 | `≥ 1 ether`，`≤ int128 上限` |
| `curveFeeBps` | 曲线基础交易费 | `≤ 1000`（10%） |
| `phantomQuote` | **虚拟**报价储备（从不实际持有） | `≠ 0` |
| `graduationThreshold` | 毕业所需的真实报价储备 | `≠ 0` |
| `poolFee` | V4 池的 core LP 费率 | **必须为 0**，否则 `CoreLpFeeMustBeZero` |
| `tickSpacing` | V4 池 tick 间距 | `1 ~ 32767` |
| `enabled` | 是否开放 | — |

`poolFee` 强制为 0 是一个关键设计：**毕业后的池子不通过 V4 原生 LP 费率收费，全部费用由 Hook 在 `afterSwap` 里抽取**，这样协议才能控制分账。

配置写入时会做两项前置检查：

- `_requireQuotable`：用 `phantomQuote / 1e6` 作为参考买单，检查它在这条曲线上能不能换出非零代币。防止 `phantomQuote` 相对 `supply` 设得过大，导致所有现实交易都定价为 0、曲线一发射就是死的。
- `_requireSeedableTerms`：按这套参数推算毕业时两侧的金额，交给 `PonsV2GraduationGuard` 检查 V4 会不会拒绝这次铸造 —— **在任何合约被部署之前**就拒掉无法毕业的参数。

#### 非原生报价资产（ERC-20 quote）

如果发射选择用 ERC-20 作为报价资产（而非原生 ETH），`phantomQuote` / `graduationThreshold` **不从 LaunchConfig 取**，而是从 `pairTokenEconomics[pairToken]` 取，因为这两个数字跨小数位没有意义。

- 必须先 `setPairTokenEconomics(token, phantomQuote, graduationThreshold, expectedDecimals)`，再 `setPairTokenApproved(token, true)`。
- `expectedDecimals` 必须 `≥ 6`。理由：曲线费用是报价腿的整数 bps，在小数位太粗的资产上，任何小于 `10000/feeBps` 个最小单位的交易费用都会向下取整成 0，交易者可以把订单拆成免费的碎片。
- 小数位会被校验两次：配置时（合约还没部署时容忍读不到）与批准时（**强制**要求能读到且匹配）。这是防止把 18 位小数的配置误用到 6 位小数资产上——那会造成十二个数量级的静默定价错误。

---

### 阶段 1：发射

三个入口，业务主体相同：

| 入口 | 调用者 | 说明 |
| --- | --- | --- |
| `launchToken(params, configId, pairToken)` | 任意（受门禁） | 标准发射 |
| `launchToken(params, configId, pairToken, exemptions[])` | 任意（受门禁） | 额外声明一批狙击税豁免钱包 |
| `launchTokenFor(params, configId, pairToken, originalDeployer, exemptions[])` | 仅 `launchForwarder` | 供可信的"发射即买入"路由器代理调用 |

> `launchTokenFor` 用显式的 `originalDeployer` 参数而非 `tx.origin` 来还原真实用户 —— `tx.origin` 在账户抽象中继下会失效，绝不能用于授权。

**门禁**：`canLaunch(launcher)` = `launchEnabled || whitelistedLaunchers[launcher]`。即公开开关关闭时，白名单地址仍可发射。

**发射费**：`msg.value` 必须**精确等于** `launchFee`（即使是 ERC-20 报价的发射也一样要付原生费）。费用在整条发射记录写完之后才转给协议收款人 —— 因为收款人可能是会回调进来的合约。

#### 经济参数锁定（expectedEconomics）

`TokenParams.expectedEconomics` 是一个可选的**参数指纹**（`bytes32`，零值表示放弃检查）。创作者可以先调 `previewLaunchEconomics(configId, pairToken)` 拿到当下的指纹并填进来，这样 Owner 在交易在途时改配置或改费率就不会静默地改变创作者拿到的条款，而是直接 revert `LaunchEconomicsMismatch`。

指纹覆盖十个字段：`phantomQuote`、`graduationThreshold`、`supply`、`curveFeeBps`、`poolFee`、`tickSpacing`、`protocolFeeShareBps`、`buybackBurnBps`、`hookFeeBps`、`maxInternalPriceImpactBps`。

`maxCreatorTaxBps` **故意不在其中**：它约束的是创作者自己填的数字，改动会让发射直接 revert 而不是静默改价。

#### 部署顺序

```
1. Factory 校验：门禁、发射费、配置有效性、报价资产已批准、
                 创作者税 ≤ maxCreatorTaxBps、
                 curveFeeBps + creatorTaxBps ≤ 2000 bps、
                 经济参数指纹匹配、种子参数可铸造
2. Factory → LaunchDeployer.deployLaunch()
     a. CREATE2 部署 PonsV2BondingCurve
        salt = keccak256(abi.encode(originalDeployer, params.salt))
     b. CREATE2 部署 PonsV2LauncherToken
        → 构造函数里把【全部供应量】铸给曲线
3. Factory → curve.initialize(token)
     计算 reservedTokens = supply × phantomQuote / (phantomQuote + graduationThreshold)
4. Factory → curve.exemptFromSnipeTax(originalDeployer / creatorFeeRecipient / 声明列表)
5. Factory 写入 LaunchedToken 记录 + 冻结 FeePolicySnapshot
6. Factory 转出发射费
```

**`reservedTokens` 是整个设计的枢纽**。它是曲线**永不卖出**的那部分余额，正是未来池子的种子。曲线之上（`trackedTokens - reservedTokens`）才是可售份额；**毕业的定义就是可售份额被买空**。

数学上，可售份额买空的那一刻，真实报价储备恰好达到 `graduationThreshold` —— 所以"代币侧耗尽"和"报价侧达标"是同一个点。代码选择用代币侧作为触发条件，因为**报价侧是一个可以被大单一笔越过的地板，而代币侧是曲线硬性拒绝跨过的墙**。

`PonsV2LaunchDeployer` 还负责限制元数据长度（name ≤ 64、symbol ≤ 16、logo ≤ 512、description ≤ 2048、每个社交字段 ≤ 256）。这是唯一能限制的地方 —— 这些字符串在代币上是不可变的，而 `socials()` 一次性返回五个字符串，无界写入会造成一个**永久无法读取**的代币（RPC 会超时或 gas 耗尽）。

---

### 阶段 2：曲线交易期

#### 定价

恒定乘积，带虚拟报价储备：

```
报价储备 = phantomQuote + trackedQuote - quoteFeeBalance - creatorTaxBalance
代币储备 = trackedTokens
```

`phantomQuote` 是**虚拟的**，从不实际持有。它的作用是给曲线一个非零起始价格，避免第一笔买单以近乎为零的价格吃掉大量供应。

#### 储备为什么显式记账，而不读实时余额

`trackedQuote` 与 `trackedTokens` 都是显式的状态变量，只在买/卖/回购/毕业时增减，**从不读 `balanceOf`**。原因是防捐赠攻击：

- 若读实时余额，任何人可以直接给曲线转报价资产（或用 `selfdestruct` 塞 ETH），从而**推高曲线定价**、或**把发射推过毕业阈值而实际上没卖出任何代币**。
- 同理，任何持币人可以直接转代币进来，**推迟毕业**、改变发射经济参数被报价时的条款、并改变毕业池的开盘价。

被强行转入的资产会**永久滞留**在曲线上（毕业时只移交 tracked 部分），这是有意为之：捐赠不能移动池子的开盘价。

#### 买入 `buy(quoteIn, minTokensOut, recipient)`

- 原生报价：`msg.value` 必须**精确等于** `quoteIn`；ERC-20 报价：不得附带任何 `msg.value`。
- ERC-20 的入账金额是**实测余额差**，不是请求金额 —— 这样 fee-on-transfer 的报价资产不会让曲线承诺它从未收到的储备。
- 费用与税都从**报价腿**扣（`fee = spent × feeBps`，`tax = spent × creatorTaxBps`），扣完才进定价公式。
- **部分成交**：如果买单会越过 `reservedTokens`，只成交到该额度为止，按实际拿到的量收费，差额退还。**故意不 revert**：一笔发射的最后一单最可能是按已被别人改动过的状态来估的，revert 会让任何人插一笔小单就能恶意阻塞它。
- **滑点检查是价格约束而非数量约束**：`spent × minTokensOut > received × tokensOut` 才 revert。花得比出价少的调用者不能指望拿到全部数量；要求的是"成交价不差于调用者自己参数隐含的价格"。当没有 clamp 发生时，它精确退化为 `tokensOut >= minTokensOut`。
- 买入成功后调用 `_tryAutoGraduate()`。

#### 卖出 `sell(tokensIn, minQuoteOut, recipient)`

- 费用从报价**输出**扣，所以卖出方向的费用同样是报价计价的。
- **一旦 `readyToGraduate()` 为真就关闭，而不是等 `graduated` 标志被置位。** 这两者之间存在一个窗口（因为 `_tryAutoGraduate` 会吞掉失败）。必须双侧关闭，否则落在窗口里的卖单会把代币放回曲线、把报价拿走，而 `graduate` 移交的是 `trackedTokens` 的当前值 —— 池子就会被种得比预定份额更深更便宜，确定性的毕业价格就破了。
- 这不会困住持币人：`graduate` 是无权限的，被这里拦住的人可以在同一笔交易里自己结算发射，然后去 V4 池交易。

#### 自动毕业

```solidity
function _tryAutoGraduate() private {
    if (readyToGraduate()) {
        try IPonsV2LaunchFactoryGraduation(factory).graduate(token) {}
        catch { emit AutoGraduationFailed(token, gasleft()); }
    }
}
```

跨过阈值的那笔买单本身就触发迁移，原子完成。用 try/catch 包住是因为：**无论毕业因何失败，底层的买入必须仍然成功**；毕业保持无权限可重试。失败会 `emit` 而不是静默吞掉 —— 跨阈值的买家自己设 gas limit，可以按 63/64 规则饿死这次调用、把毕业成本推给下一个调用者，这个事件就是让 keeper 能发现"某个发射已就绪但未毕业"的信号。

---

### 阶段 3：毕业（两段式）

毕业**故意拆成两个无权限阶段**，这样一次失败的开池不会困住曲线的储备：

```
NotGraduated ──graduate()──► Swept ──createGraduatedPool()──► PoolCreated
                                │
                                └──rescueSweptGraduation()──► Rescued
                                   （仅 Owner，7 天延迟后）
```

#### 第一段：`graduate(token)` —— 无权限，不可逆

```
1. 检查 phase == NotGraduated 且 curve.readyToGraduate()
2. 【预检】_assertGraduationSeedable() → GraduationGuard.assertSeedable()
      ↑ 在不可逆动作之前跑，所以被拒的发射停留在 NotGraduated
3. curve.graduate(factory)：
      a. graduated = true          ← 先置标志，再清算
      b. _sweepFees(0, false)      ← 跳过回购
      c. 把 trackedQuote / trackedTokens 全部移交给 Factory
4. Factory 记录 sweptQuote（实测余额差！）、sweptTokens、sweptAt，phase = Swept
```

**为什么先置 `graduated = true` 再清算**：清算会向托管合约付款，而带转账回调的报价资产可以从那笔付款里重入 `buy()` / `sell()`。`graduate` 故意不加 `nonReentrant`（它需要能从 `buy()` 自己的守卫作用域里被调用），所以这个标志是唯一关闭该窗口的东西。若在标志仍为 false 时重入，费用桶会在被清零之后重新填充，导致移交储备后留下一堆没有报价资产支撑的余额，且永远无法清算。

**`sweptQuote` 记录的是 Factory 实测收到的量**，不是曲线报告发送的量。否则一个不足额交付的报价资产会让该发射声称一个它从未收到的余额，而缺口会从其他发射寄存在此的同种资产里被抽走。

#### 第二段：`createGraduatedPool(token)` —— 无权限，可重试

```
1. 检查 phase == Swept，再跑一次预检
2. 计算真正进池的代币量：
      poolTokenAmount = sweptTokens × sweptQuote / (sweptQuote + phantomQuote)
   余量（虚拟储备对应的那部分）→ locker.lockTokenSupply() 永久锁死
3. phase = PoolCreated（先改状态）
4. poolManager.initialize(key, sqrtPriceX96)
      sqrtPriceX96 由 PonsV2GraduationMath 从两侧金额反推
5. memeHook.registerPool(...) —— 冻结该池终身的费用条款
6. Factory 把精确金额转给 GraduationExecutor，后者：
      a. Permit2 两步授权
      b. positionManager.modifyLiquidities([MINT_POSITION, SETTLE_PAIR, (SWEEP)])
         仓位【直接铸给 Locker】
      c. 铸造后扫走两侧的舍入尘埃
7. locker.lockPosition(token, positionId) —— 校验 ownerOf 确实是 Locker
```

**为什么要扣掉虚拟储备对应的代币量**：曲线的终端价格是 `(phantomQuote + graduationThreshold) / reservedTokens`，但池子里只能放进真实持有的 `sweptQuote`。要保持同一个价格，代币侧必须按 `sweptQuote / (sweptQuote + phantomQuote)` 的比例缩减。多出来的代币**永久锁进 Locker，永不进入流通**。

`PonsV2GraduationGuard` 的预检要镜像**整条下游调用图**，而不只是 PositionManager 的 ABI 字段宽度。关键点：V4 用 `BalanceDelta`（两个 `int128`）承载池子余额变化，`Pool.modifyLiquidity` 用 `SafeCast.toInt128` 收窄每一侧；而 PositionManager 的 `MINT_POSITION` ABI 接受 `uint128`。**介于两者之间的金额能通过所有字段宽度检查，却仍会在 V4 core 内部 revert** —— 所以有符号的界才是真正的界。Guard 还检查 `sqrtPrice` 在界内，以及仓位流动性不为零且不超过 tick spacing 隐含的 `tickSpacingToMaxLiquidityPerTick` 上限。

`GraduationExecutor` 的尘埃清扫**失败也不 revert**（`GraduationDustRetained`）：处理舍入尘埃对开池而言是附带动作，让它 revert 会让一个已经交出储备的发射永远无法完成。清不掉的留在这里，由下一次扫同种货币的毕业带走。清扫时**发射代币那一腿走向 Locker 而不是国库** —— 保持"没进池子的供应量永不进入流通"这个保证是精确的而非近似的。

---

### 阶段 4：V4 池运行期

毕业后，池子由单例 `PonsV2MemeHook` 治理。Hook 只开启两个回调：

| 回调 | 用途 |
| --- | --- |
| `beforeInitialize` | **仅 Factory 可调**。保证带此 Hook 的池子不可能在没有注册记录的情况下存在 |
| `afterSwap` (+ `afterSwapReturnDelta`) | 抽费 |

#### `afterSwap` 抽费

从这笔 swap 的**未指定货币**（unspecified currency）里，一次 `take` 抽走 `hookFeeBps + creatorTaxBps`，两笔分别记入不同的待清算桶：

```
pendingFees[poolId][currency]       ← hookFeeBps 那部分（要走协议/回购/创作者三分）
pendingCreatorTax[poolId][currency] ← creatorTaxBps 那部分（全额归创作者）
pendingBuyback[poolId][currency]    ← 计提时就标记好的回购切片
```

**如果抽到的费用落在 memecoin 一侧，这里不做任何兑换** —— 留到批量的 `sweepPoolFees` 里再一次性换成报价货币，而不是每笔 swap 都换。

Hook 自己发起的内部 swap（兑换腿与回购腿）**不会被抽费**：v4-core 在 hook 自己是调用者时会跳过该池的 hooks（见 `Hooks.afterSwap`）。若非如此，回购在到达金库之前就会先被抽一刀。

#### `sweepPoolFees(poolId, minConversionQuoteOut, minBuybackTokensOut)`

```
1. 权限：feeSweepOperator，或该池的 creator
   （但只要需要内部 swap，creator 就被拒 → InternalSwapRequiresOperator）
2. _convertPendingMemecoin：把 memecoin 计价的 fee + tax 【合并成一笔 swap】
      - 部分成交时，按比例把输入/输出摊回各自的桶
      - 回购标记随它所依附的 fee 桶按同比例转换
      - 若 consumed == 0：原样还回三个桶，emit PoolConversionSkipped，不算失败
3. 汇总报价货币侧的 totalQuote / taxQuote / buybackQuote，清零三个桶
4. _distribute：三分账 + 回购 + 派发
```

**滑点最小值只对真正执行了的腿生效。** 什么都没换的时候若还强制 `minConversionQuoteOut`，会因为一次根本没发生的兑换而阻塞整个清算的报价计价腿。

#### 内部 swap 的价格保护

`_executeInternalSwap` 开一个独立的 `unlock` 上下文跑一笔精确输入的 swap，用 `_priceLimit` 把 `sqrtPriceX96` 的移动限制在 `maxInternalPriceImpactBps` 内。

> **代码明确指出这个上限的局限**：它限制的是"这笔 swap 把价格推多远"，而不是"价格从哪里起步"。抢跑者先把现价压低，整个价带就跟着下移 —— 所以它是**滑点控制，不是抗操纵**。真正能封住三明治损失的是调用者传入的 `minConversionQuoteOut` / `minBuybackTokensOut`，这也正是为什么所有价格敏感的清算都被 `_requiresTrustedOperator` 收归给 sweep operator。**把这两个最小值当作真正的防线，并用一个独立的价格来源去估算它们。**

对于恒定乘积池，`_priceLimit` 的界与曲线的 `amountIn / (reserve + amountIn)` 储备位移界是等价的。注意实际的现价百分比会更大，因为现价与 `sqrtPriceX96` 的平方成正比；`maxInternalPriceImpactBps` 这个名字是为了两个阶段（曲线期 / 池期）的政策口径统一而保留的。

---

## 费用模型

### 两种费用，性质完全不同

| | 基础费 | 创作者税 |
| --- | --- | --- |
| 曲线期字段 | `feeBps`（来自 `config.curveFeeBps`） | `creatorTaxBps`（创作者自选） |
| 池期字段 | `hookFeeBps`（全局政策） | `creatorTaxBps`（发射时快照） |
| 上限 | 曲线 1000 bps / Hook 1000 bps | `maxCreatorTaxBps`，硬上限 1000 bps |
| 归属 | 三分：协议 / 回购 / 创作者 | **全额归创作者，完全不进分账** |
| 记账桶 | `quoteFeeBalance` / `pendingFees` | `creatorTaxBalance` / `pendingCreatorTax` |

**合并上限**：`基础费 + 创作者税 ≤ 2000 bps（20%）`。这个界在三处独立强制：Factory 发射时、曲线构造函数里（不继承 Factory 的检查，自己守自己的不变量）、Hook 注册池时。

**两个阶段的费用都是报价资产计价的。** 曲线上无论买还是卖，费用都从报价腿收，所以曲线**永远不会持有 memecoin 计价的费用** —— 协议与创作者的收入从第一笔交易起就是报价计价的，早在毕业之前。

### 三分账公式

```
protocolAmount = pending × protocolFeeShareBps / 10000
creatorBucket  = pending - protocolAmount
buybackAmount  = min(buybackQuoteBalance, creatorBucket)   ← 计提时就已标记
creatorAmount  = creatorBucket - buybackAmount + tax
```

默认政策值（Hook 构造函数）：`protocolFeeShareBps = 3000`（30%）、`buybackBurnBps = 5000`（50%）、`hookFeeBps = 100`（1%）、`maxInternalPriceImpactBps = 300`（3%）。

**回购切片只从创作者那一桶里出**，所以它是对"扣掉协议份额之后剩下的"来度量的；创作者税从不进入分账。

### 为什么在计提时就标记回购切片（`pendingBuyback` / `buybackQuoteBalance`）

回购份额在**每笔交易收费的那一刻**就按当时的 `buybackEnabled` 状态记账，而不是在清算时按当前开关反推。这让开关**只对未来生效**：

- 如果不这样做，一次"关闭"落在清算之前，会把创作者**已经挣到的**回购转进他们自己的payout；
- 一次"开启"则会把在普通分账下挣到的费用扫进锁仓。

### 回购降级：折回创作者

回购不是无条件执行的。曲线端（`_sweepFees`）与 Hook 端（`_distribute`）都有降级路径：

**曲线端** —— 满足以下任一条件就把回购金额**折回创作者的 payout**：
- 储备位移 `buybackAmount × 10000 / (quoteReserve + buybackAmount)` 超过 `maxInternalPriceImpactBps`；
- 曲线太浅，`quoteAmountOut` 报价为 0；
- 换出的代币量超过 `sellableTokens()`（回购与 `buy` 吃的是同一份储备，受同一个 `reservedTokens` 地板约束 —— 发射越接近毕业，可售量趋近于零，回购就会折回而不是侵蚀池子的份额）。

注意这里用的是**不会 revert 的** `quoteAmountOut`，而非 `getAmountOut`。若走会 revert 的版本，曲线太浅时会把整个费用清算一起带下去 —— 恰好在最需要清算的时候把费用困住。

**只有真正执行了的回购才受调用者最小值约束。** 把最小值施加到折回分支上会让那个分支不可达（任何被接受的参数都大于它产出的零），费用就会恰好在曲线太浅时被困住。

**Hook 端**多一个分支：如果输入被消耗了但输出舍入成 0，那笔报价资产已经进了池子而没有任何代币被锁住 —— 既不能折回也不能当作跳过，直接 `revert SlippageExceeded(0, min)`。

---

## 回购金库：五年线性释放

`PonsV2BuybackVault` 是**单例**，服务所有发射。回购来的 memecoin **不销毁**，而是锁进一个五年（`VESTING_DURATION = 5 × 365 days`）线性释放的计划。

### 加权平均归属时钟（而非分笔 tranche）

一次发射的费用清算**每次都可能追加锁仓**，如果用无界的 tranche 数组，`release()` 的 gas 成本会永远增长。金库改用单一的加权平均时钟：

```solidity
combinedAmount   = existingUnvested + amount
remainingDuration = existingUnvested == 0 ? 0 : vestingEnd - now
combinedDuration = (existingUnvested × remainingDuration + amount × VESTING_DURATION) / combinedAmount

unvestedAmount = combinedAmount
vestingEnd     = now + combinedDuration
vestingStart   = now - (VESTING_DURATION - combinedDuration)
```

效果：**大额存量几乎不受小额追加的扰动，小额存量则会被拉近到新存款自己的时钟**。每次 `lock` / `release` 都先 `_checkpoint`，把已归属部分"结晶"进 `vestedUnreleased`，所以已归属的代币不会被时钟位移倒扣回去。

> `vestingStart()` **仅供展示**。用它对 `VESTING_DURATION` 做插值**无法**复现 `vestedAmount`，因为已归属部分是在每次存款时被结算掉的，而不是从位移后的时钟重算的。权威数字请读 `vestedAmount()` / `releasable()`。

### 释放与分账

`release(token)` **只允许 `creatorRecipient` 或 `protocolRecipient` 调用**。这不是为了收租，而是防两类攻击：

1. 任意调用者可以把释放**掐在协议 Owner 的创作者收款人恢复窗口内**，把已归属的代币冲到那个恢复机制正要抛弃的地址上；
2. 任意调用者可以**每秒推进一次 checkpoint**，让每一步新归属的量都向下取整成零，归属就在从不付款的情况下停滞。

释放按 `protocolFeeShareBps`（该发射的快照值）分给协议与创作者，通过 `feeEscrow.creditToken` 记账。

### ⚠️ 关键经济学提示：开启回购会把价值从创作者转移给协议

代码注释明确点出了这一点，这里如实转述：

> **分账作用于释放，而不是作用于出资。** 曲线与 Hook 都是**只从创作者那一份费用里**切出回购切片，创作者出资了整笔锁仓，然后**只拿回其中属于自己的费用份额**。因此相对于直接拿走费用，开启回购会把价值从创作者转移给协议，转移量随 `buybackBurnBps` 增大。

正因如此，`setBuybackEnabled` 的权限是**不对称**的：

- **只有创作者**（当前 `creatorFeeRecipient`）可以**开启**；
- 协议 Owner **只能关闭**（严格对创作者有利的动作）。

这样 Owner 永远无法违背创作者意愿、把创作者的费用强行推进回购金库来捕获协议那 30% 的释放份额。

### 授权的锁仓者

`_isAuthorizedLocker(token, caller)`：

- 共享 Hook（`caller == address(feePolicy)`，直接比对）—— 它治理所有池；
- 毕业前，`token` **自己的**曲线 —— 从 Factory 的发射记录里**实时查**地址。

后者意味着**新发射的曲线不需要任何管理动作就能锁自己的回购**。

### 归属纪元（epoch）

只有当上一个纪元的代币**全部释放完毕**后，才会开启新纪元并重新快照条款。这让每个活跃的加权平均归属都绑定在一组不可变的受益人上，而不需要无界的 tranche 存储。

`creatorRecipient` **被有意排除在条款一致性检查之外**：它由 `updateCreatorRecipient` 独立管理，这样恢复操作可以移动归属，而不会因为条款不匹配而让后续的 `lock` 变砖。协议侧的分账条款则是每个发射不可变的。同时，一旦 Factory 通过 `updateCreatorRecipient` 重定向过归属，后来的 `lock` **不会**把它静默重置回发射时的收款人，即使跨越了新纪元。

---

## 权限与治理模型

### 角色

| 角色 | 能力 |
| --- | --- |
| **Protocol Owner** | 全部配置；创作者收款人覆写（带时间锁）；各条救援路径；只能**关闭**回购 |
| **Creator**（`creatorFeeRecipient`） | 自助转移收款人（**无延迟**）；开启/关闭回购；在无需内部 swap 时清算费用 |
| **Fee Sweep Operator** | 执行需要内部 swap 的费用清算（带显式最小输出）。可由 Owner 轮换 |
| **Launch Forwarder** | 唯一可以代他人发射（`launchTokenFor`）的地址 |
| **任何人** | 买 / 卖 / `graduate` / `createGraduatedPool` / `executeCreatorFeeRecipientChange` |

### `renounceOwnership` 在四处被永久禁用

`PonsV2LaunchFactory`、`PonsV2MemeHook`、`PonsV2BuybackVault`、`PonsV2LaunchLocker` 都 override 成 `revert OwnershipCannotBeRenounced()`。理由各不相同：

- **Locker / Vault**：所有权只用于一次性接线 Factory，在接线前放弃会让 Locker 永远无法接收毕业仓位、让所有未来的回购锁仓变成孤儿；
- **Hook**：无主的 Hook 永远无法轮换 fee sweep operator，所有毕业池上计提的费用会永久困住。

所有权仍可**转移**（`Ownable2Step`，两步确认）。

### 创作者收款人：两条路径

```
创作者自助：transferCreatorFeeRecipient(token, newRecipient)
             → 立即生效，无延迟

Owner 覆写：setCreatorFeeRecipient(token, newRecipient)
             → 3 天时间锁（CREATOR_FEE_RECIPIENT_TIMELOCK）
             → 之后 3 天执行窗口（CREATOR_FEE_RECIPIENT_EXECUTION_WINDOW）
             → executeCreatorFeeRecipientChange()【无权限，任何人可执行】
             → 或 cancelCreatorFeeRecipientChange()（仅 Owner）
```

> **文档如实说明这项权力的范围**：它的动机场景是创作者丢失钱包时的恢复，但**权力本身并不以此为条件** —— Owner 可以重定向**任何**发射的收款人。而且 `transferCreatorFeeRecipient` **故意不取消**待执行的覆写：时间锁是一个**通知期**，而不是一个让创作者可以靠自己改地址来否决的窗口。已成熟的覆写**优先于**在其待执行期间发生的任何创作者转移。
>
> 所以这是一项**对创作者费用路由的常设协议权力**，而不是一个范围狭窄的丢钥匙恢复机制。这个冲突是可观测的、不需要额外状态：`CreatorFeeRecipientChangeProposed` 记录的是**提案时**的收款人，而 `CreatorFeeRecipientUpdated` 记录的是**实际被替换掉**的收款人；期间落地的创作者转移会表现为两者不一致。

任何一次收款人变更都会**三处同步**：Factory 记录、当前付费方（毕业前是曲线，毕业后是 Hook 池）、以及回购金库的归属受益人。

### 流动性锁的强度

`PonsV2LaunchLocker` **不暴露任何提取函数，也没有任意调用（arbitrary call）入口**。它也没有 V1 那样的 `collectFees()` —— V4 仓位的费用累积在单例 PoolManager 内部，而不是 NFT 上，费用的收取与分配完全归 `PonsV2MemeHook` 与费用托管合约。**因此毕业后的流动性无法被任何管理员移除。**

`onERC721Received` 不在毕业路径上（PositionManager 用普通 `_mint`，不触发接收回调；托管关系由 `lockPosition` 里的 `ownerOf` 检查确立）。它存在是为了让 Locker 在显式 `safeTransferFrom` 下也行为正确，并且**只接受来自规范 PositionManager 的转入**。

---

## 应急救援路径

有一类报价资产会在被批准之后才"变坏"：变成 fee-on-transfer、rebasing、或开始按地址封锁。这类资产可以照常允许交易者之间转账，却无法向某个特定地址交付精确金额。这会让费用与储备**永久卡死**。四条救援路径分别覆盖各个环节：

| 路径 | 位置 | 覆盖 | 门槛 |
| --- | --- | --- | --- |
| `rescueCurveFees(token)` | Factory → `curve.rescueFees()` | 仍在曲线期的待清算费用 | 仅 Owner，无延迟 |
| `rescueSweptGraduation(token, recipient)` | Factory | 已 Swept、无法开池的储备 | 仅 Owner，**7 天延迟** |
| `forceSweptGraduation(token)` | Factory | 预检拒绝其种子的曲线 | 仅 Owner；**种子仍可行时会 revert** |
| `rescuePoolFees(poolId)` | MemeHook | 毕业池的待清算费用 | 仅 Owner |

关于 `rescueCurveFees` 有一个不显然的必要性：**它也是解开这类发射毕业死锁的唯一办法**。`graduate` 会在移交储备之前先清算费用，而费用从第一笔交易起就在累积，所以跨过阈值时那次清算绝不会是空操作。清算 revert，毕业就 revert，发射会永远停在曲线上。清空费用桶让那次内部清算变成空操作，毕业就能继续。

`rescueSweptGraduation` 的 7 天延迟之所以有意义，是因为**开池在整个等待期内保持无权限**：任何持币人都可以用一次 `createGraduatedPool` 调用永久地提前结束这个窗口。储备只有在**没人能种下它们**的情况下才会真的走到这条路径上。它**故意不使用** `_transferExact` —— 资产无法精确交付正是这条路径存在的原因。储备被整体转给单一收款人做链下分配，因为处于这种状态的发射没有可靠的方式在链上支付给很多人。

`forceSweptGraduation` 存在是因为 `graduate` 的预检跑在不可逆的清算**之前**，被拒的发射会停在 `NotGraduated`。但此时交易其实已经关闭了（曲线在 `readyToGraduate()` 为真时就关掉卖出侧），而 `rescueSweptGraduation` 是以 `Swept` 阶段为键的 —— 没有这条路径，这些储备根本没有出口。它被严格限制在**预检真正拒绝**的发射上：只要种子仍然可行，任何人都能调 `graduate`，而这个函数会 revert，所以它不能被用来劫走一个健康发射的储备。

`rescuePoolFees` 对**原生报价腿是跳过而非拒绝**：ETH 不会失败于精确交付，所以它没有什么需要救援的。但池子的 memecoin 计价费用**无论报价货币是什么都会被救援**，因为它们唯一的正常出口就是那次兑换 swap。把整个函数门禁在"ERC-20 报价"上，会让原生池的 memecoin 费用完全没有恢复手段，并且连带把它的 ETH 费用也困在后面（`sweepPoolFees` 先兑换再分配，作为一个整体 revert）。

---

## 事件详解

全部 **61 个**自定义事件。此外还会发出继承来的 `Ownable2Step` 事件（`OwnershipTransferStarted`、`OwnershipTransferred`）与 ERC-20 的 `Transfer` / `Approval`。

> **索引器警告**：`CreatorFeeRecipientUpdated`、`BuybackEnabledUpdated`、`FactorySet` 这几个名字在**多个合约里重复出现且签名不同**。务必按合约地址而不是仅按事件名来解析。

### PonsV2LaunchFactory（23 个）

#### 发射与生命周期

**`TokenLaunched(address indexed token, address indexed curve, address indexed deployer, address pairToken, uint256 launchConfigId, uint256 graduationThreshold)`**
一次发射完全落地时发出，是 `launchToken` / `launchTokenFor` 的最后一个动作（在发射费转出之后）。
- `token` / `curve`：新部署的一对地址（CREATE2，salt 按发起账户命名空间化）
- `deployer`：**原始发起人**。经 `launchTokenFor` 转发时，这是转发器还原出的真实用户，不是转发器自己
- `pairToken`：报价资产，`address(0)` 表示原生 ETH
- `launchConfigId`：所选配置的下标。**注意配置内容不在事件里**，需要另读 `getLaunchConfig(id)`；且该配置**后续可被 Owner 修改**，所以历史事件的 id 不足以还原当时的条款 —— 权威快照是 `getLaunchFeePolicy(token)` 与曲线自己的 immutable
- `graduationThreshold`：该发射实际生效的阈值（ERC-20 报价时取自 `pairTokenEconomics`，而非配置）

**`LaunchSwept(address indexed token, uint256 quoteOut, uint256 tokenOut)`**
毕业第一段完成、曲线储备已进入 Factory 时发出（`phase` 变为 `Swept`）。
- `quoteOut`：**Factory 实测收到的量**（余额差），不是曲线报告发送的量。对于不足额交付的报价资产，这个数字会小于曲线的 `trackedQuote`
- `tokenOut`：移交的全部 `trackedTokens`（此时还未扣除虚拟储备对应的余量）

**`LaunchForceSwept(address indexed token)`**
仅在 Owner 调 `forceSweptGraduation` 时**追加**发出（`LaunchSwept` 也会发）。它的存在就是为了区分"正常毕业清算"与"预检拒绝后的强制清算"。看到它意味着该发射的种子被 Guard 判定为不可铸造，接下来只能走 7 天延迟的 `rescueSweptGraduation`。

**`PoolGraduated(address indexed token, uint256 positionId, uint256 tokenAmount, uint256 pairTokenAmount)`**
毕业第二段成功、V4 池已开、全区间仓位已铸给并锁进 Locker 时发出。
- `positionId`：仓位 NFT 的 tokenId（取自铸造前的 `positionManager.nextTokenId()`）
- `tokenAmount`：**真正进池的**发射代币量（已扣掉虚拟储备对应的余量），不是 `LaunchSwept.tokenOut`
- `pairTokenAmount`：进池的报价资产量，等于 `LaunchSwept.quoteOut`

**`GraduationTokensPermanentlyLocked(address indexed token, uint256 amount)`**
与 `PoolGraduated` 同一笔交易，在其之前发出。`amount` 是虚拟储备对应的、**永久锁进 Locker 且永不进入流通**的代币量。恒等式：`LaunchSwept.tokenOut = PoolGraduated.tokenAmount + 此 amount`。`amount` 为 0 时不发出。

**`LaunchGraduationRescued(address indexed token, address indexed recipient, uint256 quoteAmount, uint256 tokenAmount)`**
Owner 在 7 天延迟后调 `rescueSweptGraduation` 时发出。`phase` 变为终态 `Rescued`，**该发射永远不会再有 V4 池**。资产整体转给单一 `recipient` 做链下分配。这是一个需要高度关注的事件。

#### 创作者收款人治理

**`CreatorFeeRecipientUpdated(address indexed token, address indexed previousRecipient, address indexed newRecipient)`**
收款人**实际变更**时发出，两条路径共用（创作者自助转移、Owner 覆写执行）。`previousRecipient` 是**真正被替换掉的**那个地址。同一笔交易里，变更还会被同步到曲线或 Hook 池、以及回购金库。

**`CreatorFeeRecipientChangeProposed(address indexed token, address indexed currentRecipient, address indexed proposedRecipient, uint256 effectiveAt, uint256 expiresAt)`**
Owner 调 `setCreatorFeeRecipient` 提案时发出（**此时尚未生效**）。
- `currentRecipient`：**提案那一刻**的收款人
- `effectiveAt` = `now + 3 days`；`expiresAt` = `effectiveAt + 3 days`
- 同一 token 的新提案会**替换**旧提案并重置时钟（不会为被替换的旧提案发 `Cancelled`）

> **把这个事件的 `currentRecipient` 与后续 `CreatorFeeRecipientUpdated` 的 `previousRecipient` 对比**：不一致就说明在时间锁期间有一次创作者自助转移落地，而这次覆写把它盖掉了。这是设计上唯一的观测手段。

**`CreatorFeeRecipientChangeCancelled(address indexed token, address indexed proposedRecipient)`**
Owner 在提案生效前调 `cancelCreatorFeeRecipientChange` 时发出。

#### 回购开关

**`BuybackEnabledUpdated(address indexed token, bool enabled, address indexed controller)`**
`setBuybackEnabled` 成功时发出。`controller` 是实际操作者，用于区分创作者与 Owner —— 结合权限的不对称性（**只有创作者能开启，Owner 只能关闭**），`enabled == true` 的事件里 `controller` 必然是当时的 `creatorFeeRecipient`。同一笔交易里还会向下转发给曲线（毕业前）或 Hook（毕业后），各自再发一个同名但签名不同的事件。

#### 配置类

**`LaunchConfigAdded(uint256 indexed id)`** / **`LaunchConfigUpdated(uint256 indexed id)`**
新增 / 修改发射配置。**只带 id，不带内容** —— 索引器必须调 `getLaunchConfig(id)` 取值。因为 `Updated` 会原地覆盖，若要保留历史，必须在每个事件发生的区块高度上抓取快照。

**`LaunchFeeUpdated(uint256 launchFee)`** — 发射费改变（以 wei 计，原生 ETH）。

**`LaunchEnabledUpdated(bool enabled)`** — 公开发射门禁开关。关闭时只有白名单地址能发射。

**`WhitelistedLauncherUpdated(address indexed launcher, bool enabled)`** — 白名单增删。

**`MaxCreatorTaxUpdated(uint256 bps)`** — 创作者税**上限**改变（硬顶 1000 bps）。**只影响此后的新发射**，已发射代币保留自己不可变的税率。

**`SnipeTaxStartBpsUpdated(uint256 bps)`** / **`SnipeTaxSecondsUpdated(uint256 secondsWindow)`**
狙击税参数改变（起始 bps 上限 9900，衰减窗口上限 60 秒）。⚠️ **见[已知缺口](#已知缺口与注意事项)：本仓库的曲线版本并未实装狙击税，这两个参数目前不产生任何链上效果。**

**`PairTokenApprovalUpdated(address indexed pairToken, bool approved)`**
ERC-20 报价资产的批准状态。批准时会强制要求该地址有代码、已配置 economics、且 `decimals()` 可读并匹配。

**`PairTokenEconomicsUpdated(address indexed pairToken, uint256 phantomQuote, uint256 graduationThreshold, uint8 decimals)`**
某报价资产的曲线经济参数被设置/刷新（以该资产自身的小数位计价）。**已有发射不受影响** —— 每条曲线在构造时就把这两个值收为 immutable。

#### 一次性接线

**`GraduationExecutorSet(address executor)`** / **`LaunchDeployerSet(address deployer)`** / **`LaunchForwarderSet(address forwarder)`**
分别接线毕业执行器、部署器、可信转发器。前两者是发射的硬依赖（未接线时 `_requireLaunchDependenciesWired` 会拒绝发射）。

---

### PonsV2BondingCurve（12 个）

**`Initialized(address token)`**
`initialize` 被 Factory 调用、曲线与代币接线完成时发出。同一笔交易里 `reservedTokens` 与 `trackedTokens` 被一次性定死。此时曲线才可交易。

**`CurveBuy(address indexed buyer, address indexed recipient, uint256 quoteIn, uint256 tokensOut, uint256 fee, uint256 tax)`**
每笔买入。
- `quoteIn`：**实际花掉的量（`spent`）**，不是调用者请求的量，也不是收到的量。发生部分成交 clamp 时这个值小于收到的量
- `tokensOut`：交付给 `recipient` 的代币量。clamp 时精确等于剩余可售量
- `fee`：基础费（进三分账），`tax`：创作者税（全额归创作者）。**两者都从报价腿扣，并已在定价前扣除**
- 恒等式：`quoteIn = 定价用的净额 + fee + tax`

**`CurveBuyRefunded(address indexed buyer, uint256 refund)`**
仅在买入被 clamp 到 `reservedTokens` 地板、有差额退还时发出。`refund = 收到的量 - spent`。**在退款转账之前发出**（转账可能触发回调）。它总是与同一笔交易里的 `CurveBuy` 配对，且 `CurveBuy` 在其之后发出。

**`CurveSell(address indexed seller, address indexed recipient, uint256 tokensIn, uint256 quoteOut, uint256 fee, uint256 tax)`**
每笔卖出。
- `quoteOut`：**扣费后**实际付给 `recipient` 的净额
- `fee` / `tax`：从毛报价输出里扣的两笔。恒等式：`毛输出 = quoteOut + fee + tax`

**`FeesSwept(uint256 protocolAmount, uint256 buybackAmount, uint256 creatorAmount)`**
一次费用清算完成（`sweepFees` 显式调用，或 `graduate` 内部调用）。
- `protocolAmount`：协议份额（`pending × protocolFeeShareBps`）
- `buybackAmount`：**实际花在回购上的报价资产量**。回购被降级折回时为 **0**（此时那部分已并入 `creatorAmount`）
- `creatorAmount`：创作者所得 = `创作者桶 - buybackAmount + 创作者税`
- 由 `graduate` 触发时 `buybackAmount` 必然为 0（毕业清算传 `executeBuyback = false`）
- 三个桶都为空时函数提前返回，**不发出此事件**

**`BuybackLocked(uint256 quoteSpent, uint256 tokensLocked)`**
仅在回购**真正执行**时发出，位于 `FeesSwept` 之前。`quoteSpent` 与同一次 `FeesSwept.buybackAmount` 相等；`tokensLocked` 是买到并存入五年归属金库的 memecoin 数量。**代币不销毁。**

**`CurveCompleted(address recipient, uint256 quoteOut, uint256 tokenOut)`**
`graduate` 成功、曲线交易永久停止时发出。`recipient` 是 Factory。`quoteOut` / `tokenOut` 是移交的 tracked 储备。**被强行转入曲线的资产不在其中，会永久滞留在曲线上** —— 这是有意的，捐赠不能移动池子的开盘价。

**`AutoGraduationFailed(address indexed token, uint256 gasRemaining)`**
跨越阈值的那笔买入尝试自动毕业但失败时发出（买入本身**仍然成功**）。`gasRemaining` 是 catch 时的 `gasleft()`。

> **这是一个运维告警事件。** 跨阈值的买家自己设 gas limit，可以按 63/64 规则饿死这次调用，把毕业成本推给下一个调用者。看到它意味着该发射处于"已就绪但未毕业"状态，需要有人（任何人）去调 `factory.graduate(token)`。`gasRemaining` 很小说明是 gas 不足；很大则说明是真实的失败原因，需要排查。

**`FeesRescued(address indexed protocolRecipient, address indexed creatorRecipient, uint256 protocolAmount, uint256 creatorAmount)`**
Owner 经 `factory.rescueCurveFees` 触发 `rescueFees` 时发出。与 `FeesSwept` 的区别：
- **绕过费用托管合约**，直接转账给两个收款人
- **完全跳过回购**（回购要经金库与同一个托管合约，而那正是这条路径要绕开的依赖），整个创作者桶直接付出
- 因此没有 `buybackAmount` 字段；回购标记被清零

**`CreatorFeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient)`**
Factory 转发收款人变更时发出。注意签名与 Factory 的同名事件**不同**（这里没有 `token` 字段，因为一条曲线只服务一个代币）。

**`BuybackEnabledUpdated(bool enabled)`**
Factory 转发回购开关时发出。**只影响此后计提的费用**，已计提的回购标记不受影响。

**`SnipeTaxExempted(address indexed account)`**
Factory 在发射接线期间为创作者地址与声明列表标记豁免时发出。幂等（已豁免则直接返回，不重复发出）。
⚠️ **本仓库的曲线版本没有任何狙击税逻辑，此事件目前只是记录，`snipeTaxExempt` 映射从不被读取。** 见[已知缺口](#已知缺口与注意事项)。

---

### PonsV2MemeHook（16 个）

**`FactorySet(address factory)`** — 一次性接线 Factory。设定之后 `beforeInitialize` 只接受该地址开池。

**`BuybackVaultSet(address vault)`** — 一次性接线回购金库。

**`PoolRegistered(PoolId indexed poolId, address memecoin, address quoteToken, address creator)`**
Factory 在毕业第二段注册池子、**冻结该池终身费用条款**时发出。
- `quoteToken` 是**推导出来的**（memecoin 的对侧货币），`address(0)` 表示原生 ETH
- **完整的 `FeePolicySnapshot`（`protocolFeeShareBps` / `buybackBurnBps` / `hookFeeBps` / `maxInternalPriceImpactBps` / `protocolFeeRecipient`）与 `creatorTaxBps`、`buybackEnabled` 都不在事件里** —— 需读 `launches(poolId)`
- 注册时会强校验 `key.hooks == address(this)` 且 memecoin 确实是两侧货币之一（否则会把错误的一侧当作报价资产，把费用路由到没人读的槽位）

**`HookFeeCollected(PoolId indexed poolId, address currency, uint256 feeAmount, uint256 taxAmount)`**
每笔被抽费的 swap 在 `afterSwap` 中发出。
- `currency`：**未指定货币**（unspecified currency）。它可能是 memecoin，也可能是报价资产，取决于 swap 方向与精确输入/输出
- `feeAmount`：`hookFeeBps` 那部分（进 `pendingFees`，将走三分账）
- `taxAmount`：`creatorTaxBps` 那部分（进 `pendingCreatorTax`，全额归创作者）
- 两者之和为 0 时不发出。Hook 自己的内部 swap **不会**发出此事件（v4-core 跳过 hook 自身调用的 hooks）
- **`currency` 是 memecoin 时，这笔费用此刻并未被兑换**，要等后续批量清算

**`PoolFeesSwept(PoolId indexed poolId, uint256 protocolAmount, uint256 buybackAmount, uint256 creatorAmount, uint256 tokensLocked)`**
一次 `sweepPoolFees` 的分配阶段完成时发出。
- `buybackAmount`：**实际被消耗的**报价资产（`buybackSpent`）。价格上限导致的未成交部分已折回 `creatorAmount`
- `tokensLocked`：存入五年归属金库的 memecoin 量
- `creatorAmount` 已包含：创作者桶剩余 + 创作者税 + 回购未成交折回部分
- 全部待清算桶都为空时函数提前返回，**不发出此事件**

**`PoolConversionSkipped(PoolId indexed poolId, uint256 retainedMemecoin)`**
memecoin → 报价资产的兑换 swap **一点都没成交**（`consumed == 0`，通常是撞上价格上限）时发出。三个待清算桶被**原样还回**，留待下次重试。**这不是失败**：清算的报价计价腿会继续正常执行。`retainedMemecoin` 是还回去的 memecoin 总量（fee + tax）。

**`PoolBuybackSkipped(PoolId indexed poolId, uint256 foldedBackQuote)`**
回购 swap 一点都没成交（`buybackSpent == 0` 且 `tokensLocked == 0`）时发出。`foldedBackQuote` 已被**并入创作者的 payout**。同一笔交易里仍会发出 `PoolFeesSwept`（其 `buybackAmount` 与 `tokensLocked` 均为 0）。

> 对比：如果输入被消耗了但输出舍入成 0，则**不发此事件而是 revert** —— 那笔报价资产已经进池且没有任何代币被锁住，既不能折回也不能算作跳过。

**`PoolFeesRescued(PoolId indexed poolId, address indexed quoteToken, uint256 protocolAmount, uint256 creatorAmount)`**
Owner 调 `rescuePoolFees` 时**按货币各发一次**（报价货币一次、memecoin 一次），绕过托管合约直接转账。
- 第二个参数名为 `quoteToken`，但实际传入的是**被救援的那种货币**，memecoin 那次调用里它就是 memecoin 地址
- 跳过回购（swap 会因同样的底层原因失败），整个创作者桶直接付出，回购标记清零
- 原生报价腿被跳过而非拒绝（ETH 不会失败于精确交付），但 memecoin 腿**无论报价货币是什么都会被救援**
- 该货币没有任何待清算余额时返回 `(0, 0)` 且不发出

**`CreatorFeeRecipientUpdated(PoolId indexed poolId, address indexed previousRecipient, address indexed newRecipient)`**
Factory 转发收款人变更时发出。签名与 Factory / 曲线的同名事件均不同（这里以 `poolId` 为键）。注意它只改 `info.creator`（**即时费用**的收款人）；`info.buybackCreatorRecipient` 不变，回购归属的重定向由金库的 `updateCreatorRecipient` 独立处理。

**`BuybackEnabledUpdated(PoolId indexed poolId, bool enabled)`**
Factory 转发回购开关时发出。只影响此后计提的费用。

#### 全局政策变更（均为 Owner）

这五个事件都**只影响此后创建的发射** —— 已存在的曲线与已注册的池都持有自己的快照。

| 事件 | 上限 | 含义 |
| --- | --- | --- |
| `ProtocolFeeShareUpdated(uint256 bps)` | 5000（50%） | 基础费中协议的份额 |
| `BuybackBurnBpsUpdated(uint256 bps)` | 10000 | 创作者桶中走回购的份额 |
| `HookFeeBpsUpdated(uint256 bps)` | 1000（10%） | 毕业池的基础抽费率 |
| `MaxInternalPriceImpactUpdated(uint256 bps)` | `1 ~ 9999` | 内部 swap 的价格位移上限 |
| `ProtocolFeeRecipientUpdated(address recipient)` | — | 协议收款人。**也是发射费的收款地址** |

**`FeeSweepOperatorUpdated(address operator)`**
可信清算操作者轮换。**这个角色是即时生效、不走快照的**（曲线通过 `feePolicy.feeSweepOperator()` 实时读取），因为它需要运维上的活性。它是唯一能执行带最小输出的价格敏感清算的角色。

---

### PonsV2BuybackVault（5 个）

**`FactorySet(address factory)`** — 一次性接线 Factory，用于实时查询每个发射的曲线以授权锁仓。

**`Locked(address indexed token, address indexed depositor, uint256 amount, uint256 newVestingStart)`**
一笔回购锁入时发出。
- `depositor`：曲线（毕业前）或 Hook（毕业后）
- `amount`：**实测到账量**（余额差），不是请求量。记录名义量会让该纪元最后一次释放因余额不足而 revert，把归属的尾巴困住
- `newVestingStart`：**重算后的加权平均**起始时间。注意它会随每次存款**向前移动**
- `amount` 为 0（或实测到账为 0）时静默返回，不发出

> `newVestingStart` **不能**用来插值计算已归属量。已归属部分在每次存款时被结晶保存，不会从位移后的时钟重算。权威数字请读 `vestedAmount()` / `releasable()`。

**`VestingTermsSnapshotted(address indexed token, address indexed creatorRecipient, address indexed protocolRecipient, uint256 protocolFeeShareBps)`**
**仅在开启新归属纪元时**发出（即上一纪元的代币已全部释放完毕）。
- `creatorRecipient` 是**金库里实际生效的那个值**，不一定是调用者传入的。若之前 Factory 已通过 `updateCreatorRecipient` 重定向过，这里会保留重定向后的地址，**不会静默重置回发射时的收款人**
- `protocolRecipient` 与 `protocolFeeShareBps` 是该纪元内**不可变**的；后续 `lock` 若传入不同值会 `revert VestingTermsMismatch`

**`Released(address indexed token, uint256 creatorAmount, uint256 protocolAmount)`**
`release(token)` 成功释放时发出。**注意参数顺序是 creator 在前、protocol 在后**（与其他事件里"协议在前"的习惯相反，容易解析错）。
- 只有 `creatorRecipient` 或 `protocolRecipient` 能调用
- 按该纪元快照的 `protocolFeeShareBps` 分账，经托管合约 `creditToken` 记账
- 可释放量为 0 时返回 0 且不发出

**`CreatorRecipientUpdated(address indexed token, address indexed previousRecipient, address indexed newRecipient)`**
Factory 在任何一次收款人变更中转发过来时发出。**已归属但未释放的代币也会跟随新收款人** —— 这符合钱包恢复的意图。新旧相同时静默返回，不发出。

---

### PonsV2LaunchLocker（3 个）

**`FactorySet(address factory)`** — 一次性接线 Factory。

**`PositionLocked(address indexed token, uint256 indexed tokenId)`**
毕业仓位 NFT 的**永久托管**被登记并校验时发出。发出前会检查 `IERC721(positionManager).ownerOf(tokenId) == address(this)`，所以这个事件是**链上托管已确立的证明**，而不仅是一个记账动作。每个 token 只能发生一次。

> **此后没有任何函数可以移出这个仓位。** Locker 不暴露提取或任意调用入口。

**`TokenSupplyLocked(address indexed token, uint256 amount)`**
虚拟储备对应的代币余量被永久锁入时发出，由 Factory 在开池同一笔交易里通过 `lockTokenSupply` 触发（`onlyFactory`）。`lockedTokenSupply[token]` 累加。`amount` 为 0 时直接返回，不发出。

> **账目提示**：`GraduationExecutor` 扫来的发射代币尘埃是用普通 `transfer` 直接打到 Locker **地址**上的，**不经过 `lockTokenSupply`**。因此这部分尘埃**既不发出本事件，也不计入 `lockedTokenSupply`**。若要核算 Locker 实际持有的代币，应读 `balanceOf(locker)`，它会 ≥ `lockedTokenSupply[token]`；差额即历次毕业沉淀的尘埃。

---

### PonsV2GraduationExecutor（2 个）

铸造仓位之后，Executor 会对两侧货币各做一次尘埃清扫，每次发出以下之一：

**`GraduationDustSwept(address indexed launchToken, address indexed currency, uint256 amount)`**
残余余额成功转出。**收款人取决于货币**：发射代币那一腿走向 **Locker**（保持"没进池子的供应量永不进入流通"），其余走向协议收款人。

**`GraduationDustRetained(address indexed launchToken, address indexed currency, uint256 amount)`**
转出**失败**，余额留在 Executor 里。
- 清扫失败**不会 revert**：处理舍入尘埃对开池而言是附带动作，让它 revert 会让一个已经交出储备的发射永远无法完成
- 留下的余额由**下一次扫同种货币的毕业**带走
- 因此该事件的 `amount` 是**当时的合约总余额**，可能包含前几次毕业的遗留 —— 不要把它当作本次毕业的增量
- ERC-20 腿用低层 `call` 而非 `try/catch` 包裹 `transfer`：`catch` 覆盖被调用方内部的 revert，但覆盖不了返回值解码失败，而解码发生在本帧并会向上传播。一个转账成功但不返回数据的代币会因此让整个毕业 revert —— 而这恰好是本设计要容忍的代币类别

---

### 无自定义事件的合约

`PonsV2LauncherToken`（只有 ERC-20 的 `Transfer` / `Approval`；构造时向曲线铸造全部供应量会发出一笔 `Transfer`）、`PonsV2LaunchDeployer`、`PonsV2GraduationGuard`（无状态纯函数）。

---

## 已知缺口与注意事项

以下是**代码现状与文档/注释所声称的行为之间的实际偏差**，以及部署前需要注意的事项。

### 1. 狙击税（snipe tax）未实装 ⚠️

Factory 具备完整的狙击税**发射侧**机制：`snipeTaxStartBps`（默认 9900 = 99%）、`snipeTaxSeconds`（默认 15 秒）、上下限校验、`setSnipeTaxStartBps` / `setSnipeTaxSeconds` 两个 setter、`MAX_SNIPE_TAX_EXEMPTIONS = 32` 的豁免列表上界，并在发射时为创作者地址与声明列表调用 `curve.exemptFromSnipeTax()`。

但**本仓库的 `PonsV2BondingCurve` 完全没有狙击税逻辑**：

- `buy()` 里没有任何按时间衰减的税；
- `LaunchDeployment` 结构体**不携带** `snipeTaxStartBps` / `snipeTaxSeconds`，Factory 快照的这两个值**从未传给曲线**；
- `exemptFromSnipeTax` / `snipeTaxExempt` 映射只记录，**从不被读取**。

也就是说：Factory 侧的这套配置目前**不产生任何链上效果**，`launchToken` 的豁免列表参数与 `SnipeTaxExempted` 事件同样只是记录。要让它真正生效，需要与 Factory 版本匹配的曲线实现（把两个参数纳入部署结构体、在 `buy()` 里按 `block.timestamp` 衰减计税、并在计税时查询豁免映射），而不是打补丁。

> 说明：`exemptFromSnipeTax(address)` 这个 `onlyFactory` setter 与 `LaunchDeployment.salt` 字段是为了让 `forge build` 通过而补上的最小改动（Factory 的版本比曲线与部署器新，缺这两处会编译失败）。补的是接收端签名，**不是业务行为**。

### 2. `PonsV2FeeEscrow` 实现不在本仓库

只有 `IPonsV2FeeEscrow` 接口。所有协议方与创作者的费用收入、以及回购金库的释放，都依赖这个外部合约记账。部署时必须提供，且它必须同时支持原生 ETH（`credit` / `claim`）与 ERC-20（`creditToken` / `claimToken`）两套账本。

Hook 的 `_payOut` 对 ERC-20 腿会**校验托管合约的实际到账量等于名义量**（`InexactQuoteTransfer`），所以托管合约不能对入账做任何截留。

### 3. `PonsV2LaunchDeployer.predictLaunchAddresses` 不存在

Factory 中 `TokenParams.salt` 的文档注释指引调用者"调 `PonsV2LaunchDeployer.predictLaunchAddresses` 提前确认地址"，但该函数在本仓库中并未实现。链下需要自行按 CREATE2 规则计算（salt 为 `keccak256(abi.encode(originalDeployer, params.salt))`，initcode 为对应合约的创建码加构造参数）。

### 4. `PonsV2LaunchFactory` 距 EIP-170 上限仅 402 字节

启用 IR 管线、`optimizer_runs = 200` 时的实测运行时体积：

| 合约 | 运行时字节 | 距 24576 的余量 |
| --- | --- | --- |
| **PonsV2LaunchFactory** | **24,174** | **402** ⚠️ |
| PonsV2LaunchDeployer | 19,560 | 5,016 |
| PonsV2MemeHook | 15,166 | 9,410 |
| PonsV2BondingCurve | 9,461 | 15,115 |
| PonsV2BuybackVault | 4,602 | 19,974 |
| PonsV2GraduationExecutor | 4,402 | 20,174 |
| PonsV2LauncherToken | 3,248 | 21,328 |
| PonsV2GraduationGuard | 2,896 | 21,680 |
| PonsV2LaunchLocker | 1,969 | 22,607 |

**任何对 Factory 的新增逻辑都极可能使其无法部署。** 这也解释了为什么 Deployer、Executor、Guard 会被拆成独立合约。若需扩展，应继续沿用"拆到辅助合约 + `onlyFactory`"的模式。

### 5. 本仓库没有测试

`contractsV2` 下没有 `test/` 目录。上表体积数据与构建结果来自 `forge build`；**没有任何功能性测试被执行过**。

### 6. 运维要点

- **`AutoGraduationFailed` 必须被监控**。跨阈值买家可以饿死自动毕业，此后该发射的卖出侧已关闭但池子还没开，需要有人调 `graduate` / `createGraduatedPool`（两者都无权限）。
- **`feeSweepOperator` 的最小输出参数是唯一真实的抗三明治防线**，且必须依据**独立的价格来源**估算 —— `maxInternalPriceImpactBps` 只是滑点控制，会随被操纵的现价一起平移。
- **开启回购在经济上对创作者不利**（创作者出资全部锁仓，只拿回自己的费用份额，其余归协议）。这是设计意图，也是为什么只有创作者能开启。
- **Owner 对创作者收款人的覆写是常设权力**，不是仅限丢钥匙的恢复；3 天时间锁是通知期，创作者无法通过自助转移否决它。

---

## 构建

```bash
cd contractsV2
forge build
```

`foundry.toml` 的关键配置：

```toml
[profile.default]
solc = "0.8.26"
evm_version = "cancun"
optimizer = true
optimizer_runs = 200
via_ir = true          # 必需
remappings = [
    "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/",
    "@uniswap/v4-core/=lib/v4-core/",
    "@uniswap/v4-periphery/=lib/v4-periphery/",
    "@uniswap/v4-hooks-public/=lib/v4-hooks-public/",
    "permit2/=lib/v4-periphery/lib/permit2/",
]
```

**`via_ir = true` 不是可选项**：`PonsV2LaunchFactory` 与 `PonsV2MemeHook` 在传统编译管线下都会超出 16 槽栈窗口（`Stack too deep`）。

`lib/` 下的依赖是**手工裁剪的子集**（71 个 `.sol` 文件），不是 git submodule，导入路径已改写为 `@uniswap/...` / `@openzeppelin/...` 形式。查看合约体积：

```bash
forge build --sizes
```
