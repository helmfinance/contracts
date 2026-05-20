# Helm — AI Agent ETF on Mantle

> Mantle Turing Test Hackathon 2026 — Phase 2 "AI Awakening" 출품작

## 한 줄 정의

**AI 에이전트가 자율 운용하는 토큰화 ETF (REIT 모델). 포지션 yield는 보유자에게 USDC 배당으로 분배되고 capital gain은 NAV 성장으로 반영된다. Dev은 yield의 10%를 carry로 받아 인센티브 정렬되며, 포지션 변경 빈도에 따라 환매 락업 큐를 mandate에서 설정할 수 있다. 30일 온체인 트랙레코드로 자격을 통과한 에이전트만 공개 등록 가능하며, 종업(wind-down) 시 외부 보유자가 dev보다 우선 청산받는 구조로 러그풀이 구조적으로 차단된다. 거래 수수료는 Helm 플랫폼 수익으로 귀속된다.**

## 멘탈 모델

- 에이전트 = ETF
- 에이전트 토큰 = ETF 주식
- **Yield (USDY 이자, mETH 스테이킹, Init lending, FBTC 등) → 90% 보유자 USDC 배당 + 10% Dev carry**
- **Capital gain (sNVDA, sSPY 가격 상승 등) → NAV 잔존 → 모든 보유자 (dev 포함)가 토큰 가격 상승으로 공유**
- 거래 수수료 (Mint/Redeem/Rebalance) = Helm 플랫폼 수익
- ERC-8004 NFT = 에이전트의 영구 정체성·평판
- **환매 락업 옵션**: mandate 단계에서 dev이 환매 큐 (0/30/60/90일) 설정 → 평판 프리미엄 실현 + 강제 매도 압박 완화
- **종업 시 우선순위**: 외부 토큰 보유자 (Senior) → Dev (Junior). 회사 파산 시 채권자 우선 분배와 동일.

비유: **REIT의 AI 버전**. REIT는 임대료 (yield) 를 주주에게 분배하고 자산 가치 상승은 주식 가격에 반영. 우리는 포지션 yield → 보유자 배당, capital gain → NAV 성장. 매니저가 AI고, 평판이 ERC-8004 NFT에 영구 기록.

추가 비유: **버크셔 해서웨이 주식의 AI 버전**. 단, 버크셔는 1개, Helm 위 에이전트는 무한히 많이 자유 진입. Founder 지분이 자동으로 subordinated 처리되어 러그풀 불가능.

---

## 트랙 매칭

| 트랙 | 어필 강도 |
|---|---|
| AI x RWA | ⭐⭐⭐⭐⭐ (USDY + 합성 주식 노출) |
| Agentic Wallets & Economy | ⭐⭐⭐⭐⭐ (에이전트 = 자율 지갑 운용 + 토큰화) |
| AI Trading & Strategy | ⭐⭐⭐⭐ (각 에이전트의 운용 전략) |
| AI Alpha & Data | ⭐⭐⭐ (매크로 데이터 파싱 등) |

---

## 핵심 토큰 모델 (단일 토큰)

```
Agent Token (ERC-20, 고정 공급량)
  ↕ 1:1 페어링
Agent NFT (ERC-8004, 영구 정체성)
  ↓ 권한
Agent Vault (ERC-4626 호환)
  ├─ USDC 보유
  ├─ 합성 자산 포지션 (sNVDA, sSPY, mETH, USDY 등)
  └─ 누적 수수료 (배당 풀)
```

### 입출금 흐름

- **민팅(입금)**: USDC → Vault → 보유자에게 Agent Token 발행 (NAV 기준)
- **환매(출금)**: Agent Token burn → Vault에서 NAV에 해당하는 USDC 지급
- **2차 시장**: Merchant Moe AMM에서 Agent Token / USDC 자유 거래

### 가격 결정

```
시장가격 = NAV + 평판 프리미엄/디스카운트
```

- **NAV**: 운용 결과 직접 반영. AUM ÷ 발행량.
- **평판 프리미엄**: 시장이 매니저 미래를 평가. 트랙레코드·평판 NFT 점수 기반.
- 운용 잘하는 에이전트 → 시장가 NAV 대비 프리미엄 형성 → 창업자 보유 지분 가치 상승.

---

## 수익 흐름 (REIT 모델 + Carry)

### Stream 1: Yield → 보유자 배당 (90%) + Dev Carry (10%)

**포지션이 자연 발생시키는 cash yield만 배당 대상**. 강제 매도 없음. 자산이 들어오는 형태 그대로 풀에 누적.

#### Yield 발생 자산 (배당 대상)

| 자산 | 발생 yield | 형태 | 배당 풀 누적 |
|---|---|---|---|
| **Ondo USDY** | T-bill 이자 (~5% APY) | 보유 시 USDC로 자동 이자 | 직접 |
| **Mantle mETH** | 스테이킹 보상 | mETH 추가 발행 (rebasing 또는 reward) | mETH → USDC 자동 변환 후 풀 |
| **Init Capital lending** | 대출 이자 | USDC | 직접 |
| **Pendle PT** | 만기 yield | USDC | 만기 시 직접 |
| **FBTC 스테이킹** | 보상 | FBTC | FBTC → USDC 자동 변환 후 풀 |

#### Capital Gain 자산 (배당 대상 아님 — NAV 잔존)

| 자산 | 효과 |
|---|---|
| **sNVDA, sSPY, sMSFT 등 합성 주식** | 가격 변동 → NAV에 직접 반영. 강제 매도 없음. |
| **mETH 가격 변동** | 스테이킹 보상은 yield, mETH 자체 가격은 capital gain |
| **합성 자산 매매 차익** | 에이전트가 리밸런싱으로 익절 시 → USDC로 들어와 NAV 잔존 (배당 X) |

#### 분배 메커니즘

- **분배 빈도**: 매월 1일 KST 09:00 (월 1회)
- **분배 비율**: 누적 yield 풀의 **90% 보유자 배당 + 10% Dev carry**
  - 90%: 보유 비율 pro-rata로 USDC 배당 (claim 기반, 가스비 효율)
  - 10%: FounderVault로 USDC 송금 (dev carry, dev 인센티브)
- **HWM 불필요**: yield는 자연 발생이므로 신고가 개념 무관
- **손실 월에도 yield는 나옴**: 자산 가격 떨어져도 USDY 이자는 들어옴 → 배당 발생
- **Capital gain은 NAV에 누적**: 보유자는 토큰 가격 상승 (capital gain) + 매월 USDC 배당 (yield) 동시 수령

#### 시뮬레이션

설정: AUM 100만 USDC, 발행량 1,000,000 AGT
- 60% USDY (60만 → 연 5% 이자 → 월 $2,500)
- 30% mETH (30만 → 연 4% 스테이킹 → 월 $1,000)
- 10% sNVDA (10만 → 가격 변동 capital gain, yield 없음)

월 yield 풀: $3,500
- 90% 배당: $3,150 → 보유자 (1,000 AGT 보유자 → $3.15 USDC)
- 10% carry: $350 → FounderVault (dev carry)

별도로 sNVDA 가격 +20% → NAV 0.02 증가 (배당 X, 토큰 가치 상승만)

→ 보유자 월 수익 = $3.15 USDC 배당 + $0.02/AGT capital gain (sNVDA 상승 반영)

### Stream 2: 거래 수수료 → Helm 플랫폼 수익

| 스트림 | 비율 | 출처 | 귀속 |
|---|---|---|---|
| Mint Fee | 0.5% | 신규 입금자 | Helm 플랫폼 트레저리 |
| Redeem Fee | 0.5% | 환매자 | Helm 플랫폼 트레저리 |
| Rebalance Fee | 0.05% × 거래액 | 에이전트 자산 리밸런싱 | Helm 플랫폼 트레저리 |

### 보유자 총 수익 = USDC 배당 + Capital Gain

- **배당** (월간 USDC): yield 발생 자산이 만든 자연 cash flow의 90%
- **Capital Gain** (지속적): 합성 자산 가격 상승, 매매 차익이 NAV에 누적 → 토큰 가격 상승

### Dev 인센티브 (Carry 메커니즘)

- **Yield Carry 10%**: 매월 yield 풀의 10%를 USDC로 수령. 좋은 에이전트일수록 dev 수익 ↑
- **본인 FounderVault 토큰의 capital gain**: 자산 가치 상승 시 dev 본인 토큰도 같이 상승
- **Skin in the Game 유지**: Wind-down 시 dev 후순위, 본인 자본 리스크 100%
- TradFi 비유: Carry 10% (헤지펀드 표준 20%보다 낮음, 보유자 친화적). Mgmt fee는 0% (별도 청구 없음, 거래 수수료가 그 역할).

### 인센티브 정렬

- **보유자**: 배당 + capital gain 양방향 수익. 좋은 에이전트 holding 강한 인센티브.
- **Dev**: Yield carry 10% + 본인 토큰 가치 상승. Wind-down 후순위로 책임 강화.
- **Helm 플랫폼**: 거래량 증가가 직접 수익. → 좋은 에이전트 큐레이션·검증·마케팅 동기 강함.
- **에이전트**: yield 자산 비중 / capital gain 자산 비중 mandate에 따라 조정. 둘 다 본인 평판으로 누적.

### 환매 락업 옵션 (Mandate 설정)

dev이 mandate 작성 시 환매 큐 길이를 다음 중 선택:

| 락업 | 효과 | 적합한 mandate |
|---|---|---|
| **Instant (0일)** | 즉시 NAV로 환매. 평판 프리미엄 미미 (±0.5%). | 단기 트레이딩, 변동성 낮은 mandate |
| **30일 큐** | 환매 요청 후 30일 후 NAV로 정산. 락업 동안 평판 프리미엄 5%~ 형성 가능. | mid-term 운용, 합성 주식 비중 큼 |
| **60일 큐** | 60일 큐. 평판 프리미엄 더 큼. | 매크로 동적 운용, 분기 사이클 |
| **90일 큐** | 90일 큐. 평판 프리미엄 가장 큼. 장기 가치투자형. | 장기 mandate, Pendle PT 등 만기 자산 |

#### 동작 방식

1. 유저 환매 요청 → tokens를 `RedemptionQueue.sol`에 락 → 큐 진입
2. 큐 기간 동안 토큰은 환매자 지갑 밖에 있음 (transfer 불가)
3. 큐 만료 시 NAV (만료 시점) 기준으로 USDC 환매
4. 큐 기간 동안 발생한 yield는 배당 받지 못 (snapshot 시점이 큐 진입 전)
5. 큐 기간 동안 capital gain/loss는 환매가에 반영

#### 평판 프리미엄 실현 메커니즘

락업이 길수록:
- 즉시 환매가 어려움 → 차익거래 압력 약화
- 시장가 (Merchant Moe) 가 NAV에서 더 자유롭게 발산
- 좋은 에이전트는 시장가가 NAV 위로 올라감 (평판 프리미엄)
- 보유자는 capital gain (시장가 상승)을 추가로 얻음

**Trade-off**: 유동성 ↓, 평판 프리미엄 ↑. 보유자는 mandate 보고 본인 시간 지평 맞춰서 투자.

### 플랫폼 트레저리 사용처 (post-MVP 결정사항)

- 인프라 비용 (Pyth 데이터, 백엔드, RPC)
- 보안 audit
- 신규 에이전트 시드 보조금
- 향후 거버넌스 토큰 도입 시 보유자 환원 옵션

---

## Rug Pull Protection (Subordinated Founder Tier)

**핵심 원리**: Dev은 본인 지분이 자동으로 subordinated 처리됨을 받아들이고 launch한다. 외부 보유자는 어떤 경우든 dev보다 먼저 청산받는다. 회사 파산 시 채권자 → 주주 순위와 동일한 구조.

### 단일 토큰 유지 + FounderVault 래퍼

토큰은 **1종 ERC-20 (AGT-42)** 그대로 유지. 단, dev 지분은 `FounderVault` 컨트랙트 안에 보관됨. Wind-down 시점에:
- FounderVault **외부**의 모든 AGT-42 보유자 = **Senior Tier**
- FounderVault **내부**에 남은 AGT-42 = **Junior Tier**

### Founder Lockup 기간

Phase 3 (Public Launch) 시점부터 **6개월간 dev 지분 transfer 불가**. FounderVault가 강제. 락업 기간 중 dev은 절대 매도 불가.

### Wind-Down Trigger

다음 중 하나 발동 시 wind-down 활성:

1. **자동**: 락업 종료 후, dev이 FounderVault에서 누적 출금이 초기 dev 할당의 **50% 초과**
2. **수동**: dev이 직접 `signalWindDown()` 호출 (의도적 종료)
3. **평판 슬래시**: ERC-8004 reputation score가 임계값 이하로 폭락 (예: mandate 위반 누적)

### Wind-Down 실행 흐름

```
Trigger 발동
   ↓
[1단계] Vault.mint() 일시 정지
        새로운 외부 자본 유입 차단
   ↓
[2단계] Senior Tier 우선 환매 (90일 시간창)
        FounderVault 외부의 모든 AGT-42 보유자가
        NAV 가격으로 환매 가능
   ↓
[3단계] Junior Tier 잔여 분배
        Senior 환매 종료 후 vault 잔여 자산을
        FounderVault 안의 AGT-42 비율대로 분배
        잔여 부족 시 dev 손실 흡수
   ↓
[4단계] ERC-8004 NFT에 "Wound Down" 영구 기록
        Dev의 평판 NFT에 표시 → 향후 신규 launch 시 시장이 가격으로 페널티
```

### 청산 시뮬레이션

초기 상태:
- Dev 200,000 AGT (20%, FounderVault 내), 외부 800,000 AGT (80%)
- AUM $1,000,000, NAV $1.00/AGT

6개월 후:
- AUM $1,200,000 (+20%), NAV $1.20/AGT
- Dev이 FounderVault에서 100,000 AGT 출금 (자기 지분의 50% 초과) → Wind-down 발동

청산 진행:
- Senior Tier: 외부 800,000 + dev 매도 100,000 = **900,000 AGT**
- Senior 환매: 900,000 × $1.20 = **$1,080,000** 지급
- Vault 잔여: $1,200,000 - $1,080,000 = **$120,000**
- Junior Tier: FounderVault 내 100,000 AGT
- Junior 분배: $120,000 / 100,000 = **$1.20/AGT** (이 시나리오는 NAV 보존)

손실 시나리오:
- AUM $800,000 (-20%), NAV $0.80/AGT
- Senior 환매: 900,000 × $0.80 = **$720,000**
- Vault 잔여: $80,000
- Junior 분배: $80,000 / 100,000 = **$0.80/AGT** (Senior과 동률, 동등 손실 흡수)

극단 손실 시나리오 (수익률 -50%):
- AUM $500,000, NAV $0.50/AGT (파레토 균등 NAV 분배 시)
- 그러나 Wind-down 시 Senior 우선: 900,000 × $0.55 = $495,000 (Senior 보호)
- Junior 잔여: $5,000 / 100,000 = **$0.05/AGT** (dev 거의 소실)

→ **Dev은 본인 지분으로 손실을 먼저 흡수하고, 외부 보유자가 보호받음.**

### 발표 메시지

> **"러그풀이 구조적으로 불가능한 첫 토큰화 펀드. Dev의 지분이 자동으로 subordinated 된다."**

### Trade-off (솔직)

- Dev 입장에서 자본 매력 ↓ (자기 지분 묶임 + 청산 시 후순위)
- 그러나 그 대가로 외부 자본 유치 용이 (보호 메커니즘이 신뢰 형성)
- 평판 좋은 dev은 시장가 프리미엄으로 보상 (자기 지분 가치 상승)

---

## Vetting Phase (자격 심사 단계)

**스팸·sybil 에이전트 차단 + 실 트랙레코드 검증**. 모든 에이전트는 3단계를 거친다.

### Phase 1: Incubation (최소 30일)

- 창업자가 에이전트 NFT + Vault 배포
- **시드 자본 $1,000 이상 본인 USDC 입금** (skin in the game)
- 에이전트가 자율 운용 시작
- **외부 토큰 판매 불가**. 공개 마켓플레이스에 노출 안 됨
- 모든 의사결정은 온체인에 기록 (ERC-8004 메타데이터)
- 다른 사용자는 read-only로 관찰 가능

### Phase 2: Qualification Check (30일 종료 시점)

자동 평가 기준:

| 기준 | 임계값 |
|---|---|
| 연속 운영 일수 | ≥ 30일 |
| 의사결정 횟수 | ≥ 10회 (의미 있는 리밸런스) |
| Mandate 위반 | 0회 |
| 최대 NAV 손실 | 초기 자본 대비 -30% 이내 |
| 모든 결정의 온체인 기록 | 100% |
| Sharpe Ratio | 계산 가능한 데이터 충분 |

미달 시: 90일 추가 incubation 또는 폐기.

### Phase 3: Public Launch (자격 통과 시)

- ERC-8004 NFT가 "Verified" 상태로 업그레이드
- Agent Token 공개 mint/redeem 활성화
- Merchant Moe 2차 시장 풀 자동 배포 (선택)
- 마켓플레이스에 "Public" 카테고리로 등록

### Phase 4: Continuous Monitoring

- 실시간 평판 점수 업데이트
- 임계치 미달 시 "Watchlist" 표시 (투자자 경고)
- 심각 실패 (mandate 위반 등) 시 mint 일시 정지, redeem만 허용

### 데모 시 가속 시뮬레이션

해커톤 데모에서는 30일 운영을 실시간으로 보여주기 어려움 → **타임 가속 모드** 구현 (블록 타임스탬프 시뮬). 실제 메인넷 배포 시에는 진짜 30일.

---

## Mandate 시스템

### 자연어 입력

창업자가 자연어로 운용 방침 선언:

- "AI 메가캡 테크 + 매주 리밸런싱, 중간 정도 공격성"
- "S&P 500 60% + BTC 40%, 매크로 동적, 분기 락업"
- "USDY 70% + sQQQ 30%, 변동성 최소화"

### LLM 파서 (Claude Sonnet 4.6)

자연어 → JSON schema 변환. 환각 방지를 위해 Tier 2 제약형:

```json
{
  "raw": "AI 메가캡 테크 + 매주 리밸런싱, 30일 환매 큐",
  "parsed": {
    "allowedAssets": ["sNVDA", "sMSFT", "sGOOGL", "sMETA", "sTSLA"],
    "weights": {"sNVDA": [10, 30], "sMSFT": [10, 30], "sGOOGL": [10, 30], "sMETA": [10, 25], "sTSLA": [5, 20]},
    "rebalanceFreq": "weekly",
    "leverage": false,
    "maxDD": 30,
    "personalityHint": "growth-aggressive",
    "redemptionQueueDays": 30,
    "expectedYieldAPY": "0.5% (capital gain 위주, yield 자산 적음)"
  }
}
```

#### 환매 락업 자연어 예시

- "즉시 환매 가능" → `redemptionQueueDays: 0`
- "30일 환매 큐 / 한 달 락업" → `redemptionQueueDays: 30`
- "분기 단위 운용 / 90일 락업" → `redemptionQueueDays: 90`

### 의사결정 분리 (안전성)

- **계산은 결정론적 룰**: APY 비교, 가중치 최적화, 임계값 체크
- **LLM은 설명만 담당**: 매주 운용 노트 생성 (자연어, 페르소나 톤)
- LLM 환각이 자금에 직접 영향 못 미침

---

## 컨트랙트 아키텍처

```
contracts/
├── AgentNFT.sol            // ERC-8004 호환, 평판 + mandate + 결정 로그
├── AgentToken.sol          // ERC-20, 1:1 페어링
├── AgentVault.sol          // ERC-4626 호환, USDC 보관 + 자산 운용 + wind-down 상태머신
├── FounderVault.sol        // Dev 지분 보관, 6개월 락업, 출금 추적, wind-down 트리거 + dev carry 수령
├── SyntheticAsset.sol      // sNVDA, sSPY 등 Pyth 오라클 추종
├── HelmRegistry.sol        // 에이전트 등록 + Vetting 평가
├── YieldHarvester.sol      // yield 발생 자산에서 cash yield 수확 → 풀 누적
├── DividendDistributor.sol // yield 풀 → 90% 보유자 배당 + 10% dev carry (Stream 1)
├── RedemptionQueue.sol     // mandate 락업 옵션 (0/30/60/90일) 환매 큐 관리
├── PlatformTreasury.sol    // 거래 수수료 수집 (Stream 2, 플랫폼 수익)
└── adapters/
    ├── PythPriceAdapter.sol
    ├── MantleMETHAdapter.sol
    └── OndoUSDYAdapter.sol
```

### 보안 경계

- Vault는 **화이트리스트된 자산/dApp만** 접근 가능
- 에이전트 백엔드는 `executeRebalance` 만 호출 가능
- 사용자는 `mint/redeem` 만 호출 가능
- 백엔드가 사용자 자금 직접 인출 불가 (수학적 보장)
- Mandate 위반 시 Registry가 자동 동결

---

## ERC-8004 NFT 메타데이터

```json
{
  "agentId": "helm-#42",
  "tokenSymbol": "AGT-42",
  "tokenName": "AI Mega Tech",
  "personality": "growth-aggressive",
  "vettingStatus": "verified",
  "windDownStatus": "active",
  "founderLockup": {
    "lockedAmount": "200000",
    "unlockDate": "2026-11-09",
    "withdrawnSinceUnlock": "0"
  },
  "mandate": {
    "raw": "AI 메가캡 테크...",
    "parsed": { ... }
  },
  "lifetime": {
    "totalReturn": "+18.4%",
    "yieldAPY": "4.2%",
    "capitalGainContribution": "+14.2%",
    "sharpe": 1.72,
    "maxDD": "-7.2%",
    "rebalances": 24,
    "mandateBreaches": 0,
    "currentAUM": "1,247,000 USDC",
    "holderCount": 89,
    "platformFeesPaid": "12,400 USDC",
    "totalYieldDistributed": "42,000 USDC",
    "totalDevCarryPaid": "4,667 USDC",
    "lastDividendDate": "2026-04-01",
    "redemptionQueueDays": 30,
    "pendingRedemptions": "120,000 AGT (큐 진행 중)"
  },
  "weeklyNotes": [
    {
      "week": 24,
      "narrative": "이번 주 NVDA 어닝 가이던스 부진으로 비중 12% → 9% 축소...",
      "actions": ["sell 3% sNVDA", "buy 3% sMSFT"]
    }
  ]
}
```

---

## Mantle 인프라 활용

| 인프라 | 용도 | 우선순위 |
|---|---|---|
| **Pyth Network** | 합성 주식 + 크립토 가격 피드 | 필수 (Step 1 검증) |
| **Mantle mETH** | 크립토 노출 자산 | 필수 |
| **Ondo USDY** | RWA 안전자산 | 필수 |
| **Init Capital** | 에이전트 운용 시 USDC 단기 lending (mandate 옵션) | 선택 |
| **Merchant Moe** | 2차 시장 풀 (선택), 자산 라우팅 | 선택 |
| **Pendle on Mantle** | 고정수익 자산 (mandate 옵션) | 선택 |
| **Bybit API** | 외부 데이터 / 검증 | 선택 |

### 핵심 검증 — Pyth Mantle 주식 피드

Step 1 첫 3일 내 검증:
1. Pyth가 Mantle 메인넷에서 NVDA, AAPL, MSFT 등 가격 피드 제공하는가
2. 업데이트 빈도 충분한가 (최소 시간당 1회)
3. 가격 정확도 어느 정도인가

**미지원 시 백업 플랜**: Pyth Solana 피드를 백엔드가 가져와 Mantle reporter contract에 push (1시간 간격, MVP 충분).

---

## Human vs AI 메커니즘

1. **벤치마크 비교**: 각 에이전트 NAV vs naive 60/40 holding vs 시장 인덱스 (S&P 500 등)
2. **에이전트 간 토너먼트**: 모든 Helm 에이전트의 Sharpe / Total Return / Max DD 리더보드
3. **운용 노트의 자연스러움**: ERC-8004 NFT의 자연어 결정 로그가 사람이 쓴 것과 구별 안 되는지 — 비공식 Turing Test 콘텐츠. 심사위원에게 "이 운용 노트가 사람일까 AI일까" 직접 묻는 데모 가능.

---

## 단계별 일정 (Step-Based)

각 단계는 명확한 산출물 기반. 시간 단위는 진행 상황과 리스크에 따라 유연 조정.

### Step 1: Foundation — 가장 큰 리스크 우선 검증

- Pyth Network Mantle 주식 피드 검증 (3일 timebox)
- 미지원 시 백엔드 reporter contract 백업 PoC
- `AgentVault.sol` ERC-4626 호환 골격
- `AgentToken.sol` ERC-20 (1:1 페어링)
- USDC 입금 → 토큰 mint 흐름

**산출물**: 지갑에서 USDC 입금 → AGT 토큰 받는 최소 흐름 + Pyth 피드 정상 작동 확인

### Step 2: Asset Layer

- `SyntheticAsset.sol` — Pyth 가격 추종
- 합성 자산 통합 (sNVDA, sSPY 우선 → sMSFT, mETH, USDY 확장)
- NAV 계산 엔진
- 환매 흐름 (token burn → USDC, 단방향 우선)
- 24h 큐 환매 (대량) + 즉시 환매 (소액)

**산출물**: NAV 변동 추적 + 환매 시연 가능

### Step 3: Founder Subordination

- `FounderVault.sol` — dev 지분 보관, 6개월 락업
- Transfer 추적 + 출금 누적 카운터
- `AgentVault`에 wind-down 상태 필드 추가

**산출물**: dev 지분이 락된 상태로 Vault에 보관됨, transfer 차단 검증

### Step 4: Agent Runtime

- Python 에이전트 백엔드 + cron 스케줄링
- `AgentNFT.sol` (ERC-8004 호환)
- Mandate 파서 (Claude Sonnet 4.6, Tier 2 제약)
- 결정론적 의사결정 룰 + LLM narrator (운용 노트)
- 결정 로그를 NFT 메타데이터에 push

**산출물**: 자동 리밸런싱 1회 실행 + NFT 결정 로그 추가

### Step 5: Vetting System

- `HelmRegistry.sol` — Phase 1/2/3 상태 머신
- Phase 1: incubation 카운터 + 외부 mint 차단
- Phase 2: 자동 평가 (운영 일수, 결정 횟수, mandate 위반, NAV, Sharpe)
- Phase 3: Verified 뱃지 발급 + 공개 마켓 등록

**산출물**: 30일 incubation → 자격 통과 → 공개 launch 흐름 (가속 시뮬 모드 포함)

### Step 6: Wind-down Mechanism

- AgentVault wind-down 상태머신
- 트리거: dev 50% 출금 / 수동 호출 / 평판 슬래시
- Senior 우선 환매 로직 (FounderVault 외부 = senior)
- 90일 시간창 + 자동 종료
- Junior 잔여 분배

**산출물**: dev 매도 시 외부 보유자 우선 보호 시연 (가속 시뮬)

### Step 7: Yield Harvester + Dividend + Carry + Redemption Queue + Platform Revenue

- `YieldHarvester.sol` — yield 발생 자산에서 cash 수확 → 풀 누적
  - USDY 이자 자동 수집
  - mETH 스테이킹 보상 → USDC 변환
  - Init lending 이자 수확
- `DividendDistributor.sol` — 월 1회 yield 풀 분배 (90% 보유자 + 10% Dev carry)
- `RedemptionQueue.sol` — mandate별 환매 큐 (0/30/60/90일)
- `PlatformTreasury.sol` — 거래 수수료 수집 (Mint/Redeem/Rebalance)
- 배당 분배 cron + claim 함수
- 큐 만료 → NAV 정산 → USDC 환매 흐름

**산출물**: 1개월 가속 시뮬 → yield 풀 누적 → 배당 분배 → 보유자 USDC 수령 + Dev carry FounderVault 입금 + 환매 큐 만료 정산 시연

### Step 8: Marketplace UI

- Next.js 프론트엔드
- 에이전트 카드 리스트 (Vetting 상태별 필터, APY/배당률 표시)
- 개별 에이전트 페이지 (NAV 차트, 배당 이력, 결정 로그, FounderVault 상태, wind-down 위험)
- 입금/환매 UI + 배당 claim UI
- ERC-8004 NFT 토크나우스코프

**산출물**: 사용자가 마켓플레이스 둘러보고 거래·배당 수령 가능한 풀스택 UI

### Step 9: Demo Polish

- 가속 시뮬 모드 (블록 타임 조작) 마무리
- 데모 영상 4분 촬영
- 발표 자료
- 백테스트 차트 (가능 시)

**산출물**: 제출 가능한 4분 데모 영상

### 우선순위 컷 트리 (시간 부족 시)

- Step 2 늦어짐: 합성 주식 5종 → 3종으로 축소 (NVDA, SPY, mETH만)
- Step 5 늦어짐: Vetting Phase 2 자동 평가를 hardcoded 통과로 단순화
- Step 6 늦어짐: Wind-down 트리거를 수동 호출만 지원 (자동 임계 감시는 post-MVP)
- Step 7 늦어짐:
  - 배당 분배를 수동 호출 (`triggerDividend()`)만 지원, 월 cron은 post-MVP
  - YieldHarvester를 USDY 단일 자산으로 시작 (mETH/Init 통합은 post-MVP)
  - RedemptionQueue를 30일 한 옵션만 데모 (0/60/90 옵션은 post-MVP)
- Step 8 빡셈: 마켓플레이스 UI를 단일 에이전트 상세 페이지만으로 축소
- **절대 컷 금지** (제품 정체성):
  1. Pyth 검증
  2. FounderVault (러그풀 방지)
  3. Senior 우선 환매 (wind-down)
  4. Vetting Phase 1 (incubation 락)
  5. **YieldHarvester + DividendDistributor (90/10 분배)** — REIT 모델 핵심
  6. **RedemptionQueue (최소 30일 옵션 1종)** — 평판 프리미엄 메커니즘

---

## 데모 영상 시나리오 (4분)

| 시간 | 화면 | 메시지 |
|---|---|---|
| 0:00-0:25 | 페인 인트로 — "주식과 크립토를 한 곳에서 운용할 방법이 없다 + 토큰화 펀드는 러그풀 위험" | 시장 컨텍스트 |
| 0:25-0:50 | Helm 마켓플레이스 — 에이전트 카드 (트랙레코드, Sharpe, AUM, **Yield APY + 환매 큐**, Vetting 뱃지) | "30일 시험 통과한 AI 매니저들" |
| 0:50-1:20 | $AGT-42 클릭 → 30일 incubation 결정 로그 + 운용 노트 + Vetting 통과 뱃지 + FounderVault 6개월 락 + **30일 환매 큐 표시** | "온체인 트랙레코드 + dev 지분 자동 락 + 환매 큐 명시" |
| 1:20-1:50 | USDC 1,000 입금 → AGT-42 토큰 받음 (NAV 기준, 0.5% mint fee → Helm 플랫폼) | "에이전트를 산다" |
| 1:50-2:30 | 1개월 fast-forward → 자동 리밸런싱 + 운용 노트 + **Yield 풀 누적** ($USDY 이자, mETH 스테이킹) → **배당 분배: 보유자 90% + Dev carry 10%** + **합성 주식 NAV 성장 (capital gain)** | "REIT처럼 yield 흘러나오고 capital gain은 토큰 가격 상승으로" |
| 2:30-2:55 | **환매 큐 시연**: 일부 토큰 환매 요청 → 30일 큐 진입 → 가속 시뮬 → 큐 만료 → NAV 기준 USDC 정산 | "락업이 평판 프리미엄을 만든다" |
| 2:55-3:35 | **Wind-down 시연**: dev이 50% 매도 시도 → 자동 트리거 → 외부 보유자 우선 환매 → 청산 시뮬레이션 | "**러그풀 구조적 차단**" — 핵심 차별화 |
| 3:35-3:55 | ERC-8004 NFT 페이지 — 평판 점수, 누적 결정 로그, **Yield 배당 이력 + Dev carry 이력**, FounderVault 상태, wind-down 이벤트 | 영구 온체인 평판 |
| 3:55-4:00 | 비전 — "Mantle 위 새로운 자산 클래스: REIT처럼 배당 흐르고 러그풀 불가능한 AI 매니저 ETF 시장" | 클로징 |

### 발표 결정타 한 줄들

- **"버크셔 한 주가 아니라, 미래 버크셔 후보 100개 중 골라 산다"**
- **"30일 온체인 시험을 통과한 AI만 자본을 받는다"**
- **"Yearn에 LLM 붙인 게 아니다. 자산운용 회사 자체를 토큰화했다"**
- **"러그풀이 구조적으로 불가능한 첫 토큰화 펀드. Dev 지분이 자동 subordinated."**
- **"외부 보유자가 dev보다 먼저 청산받는다. 회사 파산 시 채권자 우선 분배 룰을 그대로."**
- **"REIT 구조 — 자산이 발생시키는 yield는 매월 USDC 배당, capital gain은 토큰 가격 상승."**
- **"강제 매도 없는 배당. 자연 cash flow만 분배. 합성 주식은 안 팔고 NAV로 누적."**
- **"Dev은 yield carry 10%로 인센티브. TradFi 헤지펀드 절반 수준, 보유자 친화적."**

---

## 위험 / 완화

| 위험 | 영향 | 완화 |
|---|---|---|
| Pyth Mantle 주식 피드 미지원 | 컨셉 무너짐 | Step 1 첫 3일에 검증, 미지원 시 reporter contract 우회 |
| 합성 자산 청산 메커니즘 복잡 | Step 2 위협 | 단방향 시작 (mint만, redeem은 큐 적용) |
| Vetting Phase가 데모에서 어색 | 시연 임팩트 약화 | 가속 시뮬 모드 (블록 타임 조작) |
| 컴포넌트 수가 많아 완성도 위협 | 미완성 | 단계별 컷 트리 사전 정의, 절대 컷 금지 5종 명시 |
| 증권 규제 회색지대 | 실 launch 어려움 | 발표에서 "regulatory consideration" 언급, 해커톤 스코프는 안전 |
| Mandate LLM 파서 환각 | 잘못된 자산 매매 | Tier 2 제약형 + 화이트리스트 + 결정 vs 설명 분리 |
| Vault 보안 (자금 보관) | 공격 표적 | 좁은 컨트랙트, 자산 화이트리스트, timelock 인출 |
| Dev이 락업 전 토큰 분산해 wind-down 회피 | 러그풀 보호 무력화 | FounderVault 강제 (dev EOA 보유 불가). Phase 3 시점부터 6개월 transfer 절대 불가 |
| Wind-down 청산 중 시장 충격 | NAV 일시 왜곡 | 90일 환매 시간창 분산, 단번에 던지지 않음 |
| Senior 보유자 모두 환매 안 하면 wind-down 종료 안 됨 | dev 영구 락 | 90일 시간창 후 자동 진행, 미환매 senior는 NAV 청구권 유지 |
| Yield 발생 자산 protocol risk (USDY/Init/mETH 컨트랙트 해킹) | 보유자 자본 손실 | 자산별 노출 한도 (mandate에서 weight 상한). 한 protocol 비중 50% 초과 금지 룰 강제 |
| mETH/FBTC 스테이킹 보상이 토큰 형태로 들어옴 (USDC 변환 필요) | 변환 슬리피지 | 월 단위 일괄 변환 + Merchant Moe 라우팅 + 임계 금액 이상에서만 변환 |
| 환매 큐 락업 중 큰 NAV 변동 | 환매자 불만 | 큐 진입 시점 NAV 표시 + 만료 시 NAV 정산 명확 고지 (mandate에 명시) |
| Dev carry 10%가 너무 적어 좋은 dev 안 옴 | 마켓플레이스 품질 저하 | 평판 좋은 dev은 본인 토큰 가치 상승 + 카피 효과로 추가 보상 가능. 향후 carry 비율 조정 가능 거버넌스. |

---

## 다음 액션 (즉시)

1. **PoC #1 — Pyth Mantle 주식 피드 검증** (3일 timebox)
   - Mantle 메인넷에서 NVDA 가격 받아오는 최소 코드
   - 업데이트 빈도, 정확도 확인
   - 미지원 시 즉시 백업 플랜 (Solana → Mantle reporter)
2. **PoC #2 — AgentVault ERC-4626 골격** (Step 1 후반)
   - USDC 입금 → 토큰 발행 → NAV 기반 환매
   - 단일 자산 (USDC) 만으로 시작
3. **mandate 파서 프롬프트 설계** (병행)
   - Claude Sonnet 4.6 + prompt cache로 비용 최적화
   - Tier 2 제약형 schema 정의

---

## 결정 사항 기록

| 항목 | 결정 | 일자 |
|---|---|---|
| 토큰 모델 | 단일 토큰 (에이전트 = ETF) | 2026-05-09 |
| **수익 흐름 1: Yield (REIT 모델)** | **포지션 자연 yield만 분배 — 90% 보유자 USDC 배당 + 10% Dev carry. 강제 매도 없음. HWM 폐기.** | 2026-05-09 |
| **수익 흐름 2: Capital Gain** | **NAV 잔존 → 모든 보유자 토큰 가격 상승으로 공유 (강제 매도 없음)** | 2026-05-09 |
| **수익 흐름 3: 거래 수수료** | **Helm 플랫폼 수익 (Mint/Redeem/Rebalance)** | 2026-05-09 |
| 자격 심사 | 30일 incubation + 자동 평가 | 2026-05-09 |
| 엣지 정책 | 베이스 컨셉(Vetting + Rug Pull Protection + REIT Dividend + Carry + Redemption Queue)에 집중. Blind Mode·Composable 제거 | 2026-05-09 |
| 일정 형식 | Step-Based (시간 단위 비고정, 단계별 산출물 기반) | 2026-05-09 |
| 작업명 | Helm (가칭) | 2026-05-09 |
| MVP 자산 | sNVDA, sSPY, mETH, USDY 필수 | 2026-05-09 |
| Rug Pull Protection | FounderVault subordination + Senior/Junior wind-down 우선순위 | 2026-05-09 |
| Founder 락업 기간 | 6개월 (Public Launch 시점부터) | 2026-05-09 |
| Wind-down 트리거 | Dev 출금 50% 초과 / 수동 호출 / 평판 슬래시 | 2026-05-09 |
| Senior 환매 시간창 | 90일 | 2026-05-09 |
| 배당 분배 빈도 | 월 1회 (매월 1일 KST 09:00) | 2026-05-09 |
| 배당 분배 출처 | **포지션 yield만** (USDY 이자, mETH 스테이킹, Init lending, Pendle PT, FBTC) — capital gain 제외 | 2026-05-09 |
| 배당 분배 비율 | **Yield 풀의 90% 보유자 + 10% Dev carry** | 2026-05-09 |
| Dev Carry 메커니즘 | Yield 풀의 10%를 매월 USDC로 FounderVault에 송금 (TradFi 헤지펀드 carry의 절반 수준) | 2026-05-09 |
| 환매 락업 옵션 | Mandate에서 0/30/60/90일 큐 설정. 토큰 락 → 큐 만료 → NAV 정산 | 2026-05-09 |
| 환매 큐 NAV 기준 | 큐 만료 시점 NAV (큐 진입 시점 아님) | 2026-05-09 |

---

## 보류 / 차후 결정

- 작업명 최종 (Helm vs 다른 후보)
- 합성 주식 MVP 종목 선정 (NVDA, AAPL, MSFT, GOOGL, META vs SPY/QQQ 인덱스)
- 거래 수수료 정확한 비율 (0.5% vs 0.3% vs 다른 값)
- 플랫폼 트레저리 사용처 정책 (인프라 / audit / 시드 보조금 / 향후 거버넌스 토큰 환원)
- Vetting 최소 시드 자본 ($1,000 vs 다른 값)
- Vetting 임계 Sharpe (계산만 하고 임계 안 둘지, 둘지)
- Founder 초기 지분 비율 (20% 권장? 다른 값?)
- Dev carry 비율 정확한 값 (10%이 적절한지, 5% / 15% / 20% 검토)
- 환매 큐 옵션 폭 — MVP는 30일 1종 vs 0/30/60/90 4종 모두?
- 배당 형태 — claim 기반 vs 자동 전송 (가스비·UX 트레이드오프)
- Wind-down 활성 시 배당·carry 분배 정책 (즉시 중단? 마지막 1회 분배 후 중단?)
- mETH/FBTC 스테이킹 보상 USDC 변환 정책 (실시간 vs 월 일괄)
- 환매 큐 진입 후 취소 가능 여부 (가능 시 페널티?)
