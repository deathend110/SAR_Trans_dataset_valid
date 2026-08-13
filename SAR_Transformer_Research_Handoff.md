# SAR 1-bit Transformer 数据生成与实验筛选：Research Handoff / Technical Specification

> 目标读者：一个对既往聊天、论文背景、MATLAB 数据生成代码和当前仓库状态完全没有上下文的 Codex。
>
> 本文档用于让 Codex 在不重新阅读聊天记录的情况下，理解当前研究问题、数学模型、历史代码、已确认结论、待验证假设、下一阶段实验设计与建议的工程组织方式。
>
> 当前阶段的首要任务不是训练 Transformer，而是先冻结一个适合作为序列恢复任务输入的数据退化模型（degradation / acquisition model）。

---

## 注意：本仓库是G:\MATLAB-G\SAR_Trans_dataset_valid，这是专门的实验仓库。不是SAR_Transformer

## 0. 当前工作阶段与仓库状态

项目仓库为 `deathend110/SAR_Transformer`。仓库定位是基于 Transformer 类图像恢复模型进行单比特 SAR（Synthetic Aperture Radar，合成孔径雷达）图像恢复。当前主要训练框架来自 KAIR/SwinIR，仓库还包含 Restormer 等模型代码。

仓库中的 `AGENTS.md` 约定：在用户没有明确要求写代码、修改代码、实现功能或修复问题之前，优先进行分析、解释、实验设计和结果讨论；代码或文档修改完成后优先对应提交一次 Git commit；默认不使用 git worktree；文件按 UTF-8 阅读。

当前工程状态并不是“完整数据集 + 完整网络已经实现，只差训练”。现状是：

- `KAIR/data/dataset_sar_1bit.py` 已创建，但 `__init__`、`__getitem__`、`__len__` 仍是空实现；
- `KAIR/data/select_dataset.py` 已注册 `dataset_type = "sar_1bit"`；
- `KAIR/options/swinir/train_swinir_sar_1bit.json` 已建立，目前采用 9 通道、512×512、`upscale=1`、SwinIR、Charbonnier loss 的训练骨架；
- `SAR_experiment_design.md` 已提出若干时序/3D attention 方案，但这些属于较早的网络结构设想，不能视为当前已冻结的最终设计；
- 当前真正需要先确定的是 MATLAB 侧的数据生成机制：如何在 H/L/H 连续条带中定义高低 1-bit 采集质量，并保证序列内部物理一致性和统计一致性。

因此当前阶段可概括为：

```text
SAR 仿真和 1-bit 成像基础链路已存在
        ↓
历史 Range + RT 序列生成脚本已存在
        ↓
BARU 双向上采样已有论文与大量实验基础
        ↓
SFT 阈值已有实现与相关实验经验
        ↓
当前：筛选“最终用于 Transformer 数据集”的退化模型
        ↓
冻结数据生成模型
        ↓
再设计/实现序列 Transformer
```

---

# 1. 研究问题与背景

## 1.1 基本任务

研究对象是无人机条带式（stripmap）SAR 连续扫描产生的 1-bit SAR 图像序列恢复。

“1-bit SAR”中的 1-bit 指的是**复数 SAR 回波在 ADC/量化阶段进行 I/Q 一比特符号量化**，不是指最终保存给网络的图片只有 1 bit 像素深度。

实际链路中：

1. MATLAB 产生高精度复数 SAR 回波；
2. 在回波域进行预量化上采样；
3. 构造 RT 或 SFT 阈值；
4. 对复回波的实部和虚部分别进行 1-bit 判决；
5. 量化后继续使用 MATLAB double 精度执行距离压缩、RCMC、方位压缩等 RD 成像；
6. 对最终 SAR 幅度图归一化并保存为普通 8-bit 灰度图；
7. Transformer 的输入是这些由 1-bit 回波形成的普通灰度 SAR 图像，目标是真值 GT 图像。

因此网络解决的不是“从 ±1±j 原始回波恢复复数回波”，而是一个**图像域监督恢复问题**：

$$
F_\theta(I_{1b}) \approx I_{GT}.
$$

对于 9 帧序列：

$$
F_\theta(I_{1b}^{(0)},\ldots,I_{1b}^{(8)})
\rightarrow
(\hat I_{GT}^{(0)},\ldots,\hat I_{GT}^{(8)}).
$$

目标是每一帧恢复结果都尽量接近对应的全精度 SAR 成像 GT。

## 1.2 为什么要构造 H/L/H 序列

已有 BARU（Bidirectional Range-Azimuth Upsampling，双向距离-方位上采样）研究和大量前期实验已经表明：预量化上采样与阈值设计会显著影响 1-bit SAR 最终成像质量。较高的预量化采样冗余可以使 1-bit SAR 图像接近全精度 GT；在较高上采样率下，已有实验曾出现 PSNR 30 dB 以上、SSIM 0.9 以上的情况。

当前序列任务不是单纯追求“所有帧都使用最高采样率”。研究目标是构造一个连续无人机 SAR 扫描场景，其中：

- 条带左侧是高采样率 H；
- 中间是低采样率 L；
- 右侧重新回到高采样率 H；
- 512×512 成像窗口以 128 px 步进滑动，因此只有 F0/F4/F8 是纯 H/L/H，其余帧同时含 H 和 L 区域。

Transformer 需要利用序列中信息更丰富的区域/帧去帮助信息更贫乏的区域，最终希望降低中间低质量区域相对 GT 的性能凹陷，使输出序列的 PSNR/SSIM 曲线明显比输入序列更平坦，同时整体向 GT 靠近。

## 1.3 UAV stripmap SAR 是一切实验的起点

当前系统的基本 SAR 仿真参数由固定的一套参数生成。用户给出的基础仿真参数包括：

```matlab
C = 3e8;            % 光速
Tp = 10e-6;         % 脉冲宽度
lambda = 0.03125;   % 波长
Da = 1;             % 方位向天线孔径
atheta = lambda/Da; % 波束宽度
fc = C/lambda;
v = 100;            % 平台速度
prf = 240;          % 脉冲重复频率
Fs = 180e6;         % 原始复回波距离向采样率
B = 45e6;           % 处理带宽
gama = B/Tp;        % 距离向调频率
R0 = 4000;          % 斜距
squint_angle = 0;   % 正侧视
Ta = R0*atheta/v;   % 合成孔径时间
Bd = 2*v/Da;        % 多普勒带宽
deltaX = v/prf;     % 方位采样间隔对应的地面位移
deltaR = C/Fs/2;    % 距离向采样点间隔
```

其他维度参数如 `nrn`、`nan`、`tnrn`、`tnan`、`fnrn`、`fnan` 等均由该固定参数组计算。所有训练样本和 GT 的 SAR 仿真参数应保持一致，以避免把系统参数变化混入“1-bit 退化”中。

### 重要实现差异：180 MHz 概念模型 vs 历史 60 MHz 数据脚本

研究问题的概念定义是：GT 来自高精度、未量化回波的原始 RD 成像，不人为加入 1-bit 上采样/阈值/量化退化。

但是历史数据生成脚本 `seqdatacut_RangeMix_25.m` 的实际实现先执行：

```matlab
channel_60_clean = raw_data(1:3:end, :);
```

即从原始数据抽取为约 60 MHz 工作回波，再用 `FS60_params.mat` 中的参数执行 GT 和 1-bit 输入生成。因此：

- **研究目标层面的 GT 定义**：高精度回波直接正常 RD 成像；
- **历史脚本的 GT 实现**：先从原始回波降到 60 MHz 工作网格，再进行无量化 RD 成像。

两者目前存在口径差异。后续冻结最终数据集之前必须明确：最终 GT 是继续以 60 MHz clean 回波为共同基准，还是回到 180 MHz 原始高精度回波直接成像。不得静默把两者视为同一件事。

---

# 2. 当前完整处理流程

## 2.1 抽象总链路

设高精度复数回波为：

$$
S \in \mathbb C^{N_r\times N_a},
$$

其中：

- $N_r$：距离向（fast time）采样点数；
- $N_a$：方位向（slow time）采样点数。

GT 链路：

```text
高精度复 SAR 回波 S
    ↓
Range Compression（距离压缩）
    ↓
RCMC（距离徙动校正）
    ↓
Azimuth Compression / SAR Imaging（方位压缩）
    ↓
abs(·) 取幅度
    ↓
ROI 裁剪 / 归一化
    ↓
GT 图像
```

1-bit 输入链路：

```text
高精度复 SAR 回波 S
    ↓
预量化上采样 U(qr, qa)
    ↓
构造阈值 U_threshold（RT 或 SFT）
    ↓
S_up + U_threshold
    ↓
I/Q 1-bit 量化
    ↓
Range Compression
    ↓
必要时投影/裁剪回 base RC 网格
    ↓
H/L 在 RC 域能量对齐并混合
    ↓
RCMC
    ↓
Azimuth Compression / SAR Imaging
    ↓
abs(·)
    ↓
ROI 裁剪 / 统一归一化
    ↓
普通 8-bit 1-bit SAR 输入图像
```

## 2.2 数据域区分

必须明确区分以下数据域：

### 复回波域（echo domain）

数据为复数 SAR 原始/基带回波。上采样、阈值和 1-bit 量化发生在这一域。

### RC 域（Range-Compressed domain）

执行距离匹配滤波之后的复数二维数据。历史 H/L mixed 数据集在这一域进行高低采样结果拼接。

### RCMC 域

完成距离徙动校正后的复数数据。已有实验也测试过在此处进行 H/L 能量对齐和混合。

### 图像域

完成方位压缩后的 SAR 聚焦图像。网络训练实际使用的是图像域的 512×512 单通道灰度图。

## 2.3 已经做过的 MIX 位置实验

历史实验比较过至少三种混合位置：

1. 在 1-bit 回波/量化结果阶段直接把 H 和 L 拼在一起；
2. 在 RC 后对 H/L 做能量对齐，再混合；
3. 在 RCMC 后做能量对齐，再混合。

已有实验事实：

- **1-bit 回波直接混合不可用**：会出现强烈撕裂和明显非连续 artifact；
- **RC 后能量对齐再混合效果较好**；
- **RCMC 后混合也能得到较好连续性**；
- 当前已确定继续采用 **RC 域作为主要 H/L/H common-grid mixing domain**。

RC 被选择的原因不是理论上唯一正确，而是：

- 有已有实验支持；
- 其输出仍保持复数相干信息；
- H/L 不同上采样链路可以在 RC 后先投影回同一 base grid；
- 在统一网格上做能量对齐和 mask 拼接后，再进入相同 RCMC/方位成像链路，便于控制变量。

## 2.4 9 帧连续序列

最终 512 px 地理有效轴定义为：

```text
地面全局坐标：
[0, 512)      H
[512, 1024)   L
[1024, 1536)  H
```

512×512 成像窗口每次沿方位/航迹方向移动 128 px：

```text
F0 [0,    512 ]   = 512H
F1 [128,  640 ]   = 384H + 128L
F2 [256,  768 ]   = 256H + 256L
F3 [384,  896 ]   = 128H + 384L
F4 [512, 1024 ]   = 512L
F5 [640, 1152 ]   = 384L + 128H
F6 [768, 1280 ]   = 256L + 256H
F7 [896, 1408 ]   = 128L + 384H
F8 [1024,1536 ]   = 512H
```

只有 F0/F4/F8 是纯 H/L/H。其余帧都是混合 acquisition regime。

相邻帧共享 384 px 全局地理区域。因此同一序列的 9 帧不是独立图像，而是同一连续飞行/扫描过程的高度相关窗口。

全局坐标与局部帧坐标关系可写成：

$$
u = 128k + w,
$$

其中：

- $k\in\{0,\ldots,8\}$ 为帧索引；
- $w\in[0,511]$ 为帧内局部列坐标；
- $u\in[0,1535]$ 为全局条带坐标。

这一定义对后续 Transformer 极其重要：不同帧中的同一个局部坐标 $(h,w)$ 并不对应同一全局地理位置；若要进行“同位置跨帧融合”，必须考虑 128 px 的已知几何平移。

---

# 3. 核心数学模型

## 3.1 原始离散 SAR 回波

以固定 stripmap SAR 参数生成连续复数回波：

$$
S[n,m] = s(\tau_n,\eta_m),
$$

其中：

$$
\tau_n = T_{start} + \frac{n}{F_s},
$$

为距离向 fast-time 网格，

$$
\eta_m \approx \frac{m-m_0}{PRF},
$$

为方位向 slow-time 网格。

本项目不需要 Transformer 显式求解完整 SAR 前向模型。对数据生成而言，只需保证：

- 所有样本使用固定 SAR 系统参数；
- GT 和 1-bit 输入来自同一基础回波；
- 退化差异只来自预量化上采样、阈值、1-bit 量化和 H/L mixing，而不是其他隐藏参数变化。

## 3.2 距离向 FFT 零填充上采样

对于 $S\in\mathbb C^{N_r\times N_a}$，距离向倍率 $q_r$：

1. 沿第 1 维 FFT；
2. `fftshift`；
3. 在频谱中心两侧补零；
4. IFFT；
5. 乘以倍率补偿幅值。

MATLAB 实现：

```matlab
Sf = fftshift(fft(S, [], 1), 1);
% centered zero padding
S_up = ifft(ifftshift(Sf_up, 1), [], 1) * q_r;
```

其数学含义是对带限离散信号进行频域零填充插值，而不是简单空间复制或线性插值。

## 3.3 方位向 FFT 零填充上采样

方位向倍率 $q_a$ 同理：

```matlab
Sf = fftshift(fft(S, [], 2), 2);
% centered zero padding
S_up = ifft(ifftshift(Sf_up, 2), [], 2) * q_a;
```

## 3.4 BARU 双向上采样

BARU 的基本形式是：

$$
S^\uparrow
= \mathcal U_a^{q_a}\mathcal U_r^{q_r}(S).
$$

当前实现先距离后方位：

```matlab
if q_range > 1
    S_up = rangeUpsample(S_up, q_range);
end
if q_azimuth > 1
    S_up = azimuthUpsample(S_up, q_azimuth);
end
```

对于可分离 FFT zero-padding，理想条件下先后顺序不应改变最终二维插值结果，但数值尺寸舍入等细节仍应保持统一。

## 3.5 总采样预算

为公平比较 Range-only 和 BARU，引入总预量化采样预算：

$$
q_{total}=q_r q_a.
$$

Range-only：

$$
(q_r,q_a)=(q_{total},1).
$$

BARU：

$$
q_rq_a=q_{total},\qquad q_r>1,\ q_a>1.
$$

若采用均衡分配：

$$
q_r=q_a=\sqrt{q_{total}}.
$$

但 BARU 不要求一定均衡，实验可以扫描不同 range/azimuth allocation，只要总预算一致。

## 3.6 非整数倍率与有效倍率

历史 Range-only 使用：

$$
q_H=2.5,\qquad q_L=1.5.
$$

当双向均衡分解时：

$$
\sqrt{2.5}\approx1.5811,
\qquad
\sqrt{1.5}\approx1.2247.
$$

矩阵尺寸必须为整数，因此通用实现应使用：

$$
N_r^\uparrow=\operatorname{round}(q_rN_r),
\qquad
N_a^\uparrow=\operatorname{round}(q_aN_a).
$$

实际有效倍率定义为：

$$
q_r^{eff}=\frac{N_r^\uparrow}{N_r},
\qquad
q_a^{eff}=\frac{N_a^\uparrow}{N_a}.
$$

并建议后续时间网格/采样率使用实际倍率：

$$
F_s^\uparrow=q_r^{eff}F_s,
\qquad
PRF^\uparrow=q_a^{eff}PRF.
$$

原因是 SFT 相位显式依赖时间轴。如果矩阵实际尺寸和 nominal q 不完全一致，却仍使用 nominal q 构造时间坐标，会产生小的 deterministic phase/grid mismatch。

### 关于“非整数倍率会产生奇怪谐波”的当前判断

这是当前需要实验验证的风险点，但不能把它直接写成已知定理。

目前更准确的理论判断是：

- 非整数 FFT zero-padding 本身并不会天然“产生新谐波”；
- 主要数值问题来自尺寸 `round` 后的有效采样率误差、有限窗口频谱泄漏和不同窗口边界；
- 1-bit `sign(·)` 是强非线性，真正会产生大量高次频谱分量；
- SFT 若与离散 FFT 网格/有限窗不匹配，也可能出现额外 leakage；
- 因此非整数 BARU + SFT 的频谱行为必须通过实验确认，而不能仅凭直觉定性。

## 3.7 RT：Random Threshold

### 历史 Range RT

先估计上采样回波幅度尺度：

$$
\hat\sigma
=\sqrt{\frac{2}{\pi}}\operatorname{mean}(|S^\uparrow|).
$$

阈值幅度：

$$
A_{RT}=A_s\hat\sigma.
$$

距离向随机相位：

$$
\phi_r(n)\sim\mathcal U(0,2\pi).
$$

阈值：

$$
U_{RT}(n,m)=A_{RT}e^{j\phi_r(n)},
$$

沿方位维广播。

历史脚本使用：

```matlab
As = 0.6;
phi_seq = 2*pi*rand(size(seq_up,1),1);
U_master_seq = A_rt * exp(1i*phi_seq);
```

### BARU 示例中的 SplitRT

BARU 示例代码中二维 RT 主要采用可分离随机相位：

$$
\phi_r(n)\sim U(0,2\pi),
\qquad
\phi_a(m)\sim U(0,2\pi),
$$

$$
U(n,m)=A_{RT}e^{j(\phi_r(n)+\phi_a(m))}.
$$

代码：

```matlab
phi_r = 2*pi*rand(Nr_up,1);
phi_a = 2*pi*rand(1,Na_up);
U = A_rt * exp(1i*(phi_r + phi_a));
```

还存在 Full 2D RT（每个二维采样点独立随机相位），但当前候选 `BARU+RT` 最终使用哪一种 RT protocol 需要显式冻结，不能混用。

## 3.8 SFT：Single Frequency Threshold

SFT 同样先估计：

$$
\hat\sigma
=\sqrt{\frac{2}{\pi}}\operatorname{mean}(|S^\uparrow|).
$$

使用 STR（signal-to-threshold ratio 风格的幅度参数）定义：

$$
A_u=\frac{\hat\sigma}{10^{STR_{dB}/20}}.
$$

二维 SFT：

$$
U_{SFT}(n,m)
=
A_u\exp\left\{j\left[
2\pi f_r\tau_n
+2\pi f_a\eta_m
+\phi_0
\right]\right\}.
$$

其中：

$$
\tau_n=\frac{n-\lfloor N_r^\uparrow/2\rfloor}{F_s^\uparrow},
\qquad
\eta_m=\frac{m-\lfloor N_a^\uparrow/2\rfloor}{PRF^\uparrow}.
$$

统一函数：

```matlab
U = build2DSFTThreshold(...,
    Fs_range_up, PRF_up,
    fr_Hz, fa_Hz, amplitude, initial_phase);
```

三种特例：

- RSFT：$f_r\neq0,\ f_a=0$；
- ASFT：$f_r=0,\ f_a\neq0$；
- 2D-SFT：$f_r\neq0,\ f_a\neq0$。

SFT 是确定性阈值，不依赖 RNG。

### SFT 在不同 q 下的当前理解

一个重要的工作假设是：在较低总采样预算 $q<4$ 时，尤其把总预算拆成两个方向后，每个方向的冗余很弱，SFT 的增益可能不明显。

例如：

$$
q_{total}=2.5
\Rightarrow q_r\approx q_a\approx1.58,
$$

$$
q_{total}=1.5
\Rightarrow q_r\approx q_a\approx1.225.
$$

SFT 的作用可以理解为：在更多预量化采样点上提供随时间变化的判决边界。若每轴只增加很少采样点，则它能够提供的额外符号约束本来就有限。

这不是一个已证明的普适定理，而是结合已有实验经验和当前采样预算形成的假设，必须通过 Range+SFT / BARU+SFT 实验验证。

## 3.9 1-bit I/Q 量化

本项目采用“加阈值”约定：

$$
S^\uparrow + U.
$$

实部与虚部分别判负：

$$
Q_R(n,m)=
\begin{cases}
-1,&\Re(S^\uparrow+U)<0\\
+1,&\text{otherwise}
\end{cases},
$$

$$
Q_I(n,m)=
\begin{cases}
-1,&\Im(S^\uparrow+U)<0\\
+1,&\text{otherwise}
\end{cases}.
$$

复数量化输出：

$$
Q(n,m)=Q_R(n,m)+jQ_I(n,m).
$$

MATLAB：

```matlab
re = ones(size(S), "like", real(S));
im = ones(size(S), "like", real(S));
re(real(S)+real(U) < 0) = -1;
im(imag(S)+imag(U) < 0) = -1;
S1 = complex(re,im);
```

零值映射为 +1。

---

# 4. 当前几个核心方法

下一阶段需要比较四类 acquisition pipeline。

## 4.1 Range + RT

### 方法定义

仅距离向预量化上采样：

$$
(q_r,q_a)=(q,1).
$$

随后使用 Range RT：

$$
S\rightarrow \mathcal U_r^q
\rightarrow U_{RT,r}
\rightarrow Q_{1b}
\rightarrow RC
\rightarrow base\ grid
\rightarrow RCMC
\rightarrow image.
$$

### 与其他方法差异

- 不进行方位向上采样；
- RT 是随机阈值；
- 历史 H/L 数据集已经采用这一方案；
- 对 H/L 方位边界而言，距离向插值不会直接跨越列边界，mixed frame 较容易在 RC 域按列组合。

### 理论预期

这是最稳妥的历史 baseline。其工程行为、H/L=2.5/1.5 下的 mixed 生成方式和 U 型曲线已有较多验证。

### 当前证据

已有完整历史脚本和 H/L mixed 经验，RC/RCMC 后混合能够得到较平滑的序列质量变化。

### 尚未验证

是否仍然是最终最适合 Transformer 的数据退化模型，需要与 BARU/ SFT 方案比较。

---

## 4.2 BARU + RT

### 方法定义

保持总预算：

$$
q=q_rq_a,
$$

同时在距离和方位进行 FFT zero-padding 上采样，再使用二维 RT（当前 BARU 示例采用 SplitRT）：

$$
S
\rightarrow \mathcal U_r^{q_r}
\rightarrow \mathcal U_a^{q_a}
\rightarrow U_{SplitRT}
\rightarrow Q_{1b}
\rightarrow RC^\uparrow
\rightarrow 2D\ frequency\ crop
\rightarrow RC_{base}
\rightarrow RCMC
\rightarrow image.
$$

### 与其他方法差异

- 采样预算分配到距离 + 方位两个方向；
- 比 Range-only 多了方位向插值；
- BARU 示例中在 RC 后同时将方位 Doppler 和距离频谱裁回 base grid。

### 理论预期

已有 BARU 研究表明合理的 range/azimuth allocation 可以改善 1-bit SAR 的信息保留，因此在相同总预算下可能优于纯 Range-only。

但在当前很低的总预算（如 1.5/2.5）下，二维分摊后每轴倍率很低，是否仍有稳定优势必须重新验证。

### 当前证据

BARU 已有论文和大量单帧实验基础；用户给出的示例代码在总预算 q=4 时比较了：

- 纯方位 q=4；
- 纯距离 q=4；
- 双向 q_a=2, q_r=2。

### 尚未验证

- q=1.5、2.5 这种低预算下的优势；
- 非整数二维倍率的数值行为；
- BARU 与 H/L sequence-level consistency 的兼容性；
- BARU+RT 最终采用 Range RT / SplitRT / FullRT 中哪一套公平 protocol。

---

## 4.3 Range + SFT

### 方法定义

只在距离向上采样，再使用 RSFT 或统一 SFT 函数的 $f_a=0$ 特例：

$$
S
\rightarrow \mathcal U_r^q
\rightarrow U_{SFT}(f_r,0)
\rightarrow Q_{1b}
\rightarrow RC
\rightarrow image.
$$

### 与其他方法差异

- 上采样仍然只有距离向，因此与历史 Range+RT 在 sampling geometry 上最接近；
- 阈值从随机 RT 改为确定性单频阈值；
- 更容易单独判断“RT vs SFT”的贡献。

### 理论预期

如果 SFT 在当前低 q 仍有效，那么 Range+SFT 可以在不引入方位非整数插值复杂度的情况下提高 H 或 L 的 1-bit 成像质量。

### 当前证据

SFT 已有单独实验经验，但当前用于 H/L=1.5/2.5 连续序列的系统对比尚未完成。

### 尚未验证

- 低 q 下是否仍能获得明显增益；
- SFT 参数 $STR,f_r,\phi_0$ 在 H/L 间如何共享；
- 序列级 sigma 和单帧 sigma 哪种更合理。

---

## 4.4 BARU + SFT

### 方法定义

双向上采样 + 2D-SFT：

$$
S
\rightarrow \mathcal U_r^{q_r}
\rightarrow \mathcal U_a^{q_a}
\rightarrow U_{SFT}(f_r,f_a)
\rightarrow Q_{1b}
\rightarrow RC
\rightarrow 2D\ crop\ to\ base\ grid
\rightarrow RCMC
\rightarrow image.
$$

### 与其他方法差异

这是当前最复杂的组合：

- sampling geometry 二维化；
- q 可能分解为非整数倍率；
- SFT 相位同时依赖 fast-time 和 slow-time；
- SFT 时间轴依赖实际 $F_s^\uparrow$ 和 $PRF^\uparrow$；
- H/L 还要求 sequence-level consistency。

### 理论预期

BARU 和 SFT 可能互补：BARU 增加二维采样冗余，SFT 为新增样本提供确定性变化判决边界。

但也存在反向可能：当 q 很低时，二维分摊使每轴冗余过少，SFT 的可利用采样点不足，复杂度增加却不带来收益。

### 当前证据

尚不能依据 BARU 的高预算/整数倍率实验直接推断当前 H/L=1.5/2.5 下 BARU+SFT 会最好。

### 尚未验证

这是下一阶段最需要实验回答的组合之一。

---

# 5. 当前最重要的理论判断

## 5.1 已基本确认

### A. 1-bit 发生在回波域，网络输入是正常灰度 SAR 图像

量化后 RD 仍使用 double 精度，最终网络读取的是普通 8-bit/单通道图像。

### B. H/L 的根本物理差异是预量化采样/量化信息量差异

H/L 不应该仅理解为“高质量图片/低质量图片”。更准确地说：

$$
H=(q_r^H,q_a^H,\text{threshold protocol}),
$$

$$
L=(q_r^L,q_a^L,\text{threshold protocol}).
$$

高采样率通常保留更多 1-bit measurement information，从而形成更接近 GT 的图像。

### C. 场景内容差异不是 H/L 的成因，但会影响实际 PSNR/SSIM

不同地理区域本身可能有不同散射结构、纹理复杂度和强散射点。因此实际图像质量是 acquisition condition 与 scene content 的共同函数：

$$
Q=f(q_r,q_a,\text{threshold},x_{scene}).
$$

所以方法筛选必须跨多个场景看 H/L gap 的稳定性，不能只看一个 patch。

### D. 9 帧是同一连续扫描序列，不应当被当成 9 个独立样本

更合适的统计单元是：

$$
\mathcal S_i=\{F_{i,0},\ldots,F_{i,8}\}.
$$

不同序列之间尽量来自同一生成分布；序列内部恰恰应该保留相关性。

### E. 直接在 1-bit 回波阶段做 H/L 拼接会严重撕裂

已有实验明确支持。

### F. RC/RCMC 后能量对齐再混合效果较好

当前选定 RC 为主要混合位置。

### G. 正常输入序列的质量曲线应当是平滑 U 型

随着 H 占比从 100% → 0% → 100%，输入的 PSNR/SSIM 应逐渐下降到 F4，再逐渐恢复，而不是在 mixed frame 突然崩塌。平滑 U 型说明退化随 H/L 占比连续变化，没有明显人为拼接 artifact 主导指标。

## 5.2 当前工作假设

### A. 同序列所有帧应尽量使用一致的 threshold / sampling protocol

动机：同一序列表示同一次无人机飞行/扫描，若人为给每帧重新随机阈值、重新定义时间原点、重新估计强度尺度，会增加非物理 frame-to-frame variation，给 Transformer 增加不必要学习难度。

因此倾向：

- RNG 状态在 sequence level 控制；
- SFT 相位原点尽量在 sequence/global coordinate 上定义；
- 能 sequence-level 生成的量尽量不要逐帧重置；
- normalization 也尽量避免人为造成帧间尺度漂移。

这一原则是当前设计约束，但具体实现方式仍需结合 BARU/RT/SFT 的网格兼容性确定。

### B. 同序列最好整体统一生成

对于 Range-only，逐帧距离上采样不会跨方位列，因此旧做法问题相对小。

加入方位上采样后，若每一帧分别在 1200 列窗口上做 azimuth FFT zero-padding，则相同重叠区域在 F2/F3 中会由于 FFT 窗口边界不同得到略不同插值结果。该差异来自数据生成方式，而不是雷达本身。

因此当前倾向把 `1200 × 2224` sequence echo block，甚至更长连续条带作为统一处理对象，尽可能 sequence-level 生成 H/L RC，再切出 9 帧。

但这会影响现有成像函数尺寸、RC mixing、边界处理和归一化，仍需单样本验证后再固定。

### C. 低 q 下 SFT 可能作用有限

当前经验/推断：总 q < 4，尤其 BARU 分摊后每轴只有 1.2–1.6 倍时，新增 sign constraints 较少，SFT 的确定性 threshold diversity 可能难以充分发挥。

这必须通过实验验证，不能直接当成结论。

## 5.3 尚存争议 / 未解决

### A. 最终 GT 使用 60 MHz clean 还是原始 180 MHz high-precision echo

历史脚本和研究口径当前不完全一致。

### B. BARU+RT 的 RT 形式

历史 Range+RT 使用距离向 RT；BARU 示例使用 SplitRT。公平比较时必须确定统一 protocol。

### C. H/L threshold 是否必须是同一个“连续场”的不同采样

SFT 可以天然用同一 $f_r,f_a,\phi_0$ 在不同采样网格上评价；RT 对非整数 BARU 网格没有简单 LCM 公共 master grid，需要设计共享随机性的方式。

### D. sigma 的估计范围

可选：

- 每帧估计；
- 每序列估计；
- H/L 各自 sequence-level 估计；
- 使用统一固定/校准尺度。

sequence-level consistency 倾向减少逐帧估计，但最终需实验。

### E. normalization protocol

历史代码 H、L、mixed 使用不同 meta normalization 范围，可能把额外 domain shift 引入网络。最终数据集应统一控制，但具体方案未冻结。

---

# 6. H / L / H 序列问题

## 6.1 H 和 L 的定义

H/L 不是地物类别，也不是人工图像标签。

它们表示预量化 acquisition configuration 的不同采样预算：

$$
H:\ q_H\text{ 较高},
\qquad
L:\ q_L\text{ 较低}.
$$

Range-only 时：

$$
H=(q_H,1),\quad L=(q_L,1).
$$

BARU 时：

$$
H=(q_r^H,q_a^H),
\quad q_r^Hq_a^H\approx q_H,
$$

$$
L=(q_r^L,q_a^L),
\quad q_r^Lq_a^L\approx q_L.
$$

## 6.2 为什么是连续 H/L/H

实际任务模拟无人机一次连续 stripmap SAR 扫描，其中 acquisition quality 随航迹位置发生人为设定的高-低-高变化：

```text
512 H  |  512 L  |  512 H
```

成像窗口继续固定滑动，而不是分别为 H/L 段单独生成不相关图像，因此自然产生 3 个纯帧 + 6 个 mixed 帧。

## 6.3 MIX 直接在 1-bit 回波拼接为什么失败

在量化回波域，H 和 L 来自不同预量化采样率/阈值后的离散复数 sign measurement，二者的采样网格、局部频谱和幅值统计不同。直接硬拼会在边界制造强不连续，后续相干成像会把边界不连续传播成明显撕裂、旁瓣/纹理 artifact。

该解释与已有实验现象一致，但具体频谱机制可以继续用 RC spectrum 分析量化。

## 6.4 RC 域能量对齐混合

历史 mixed frame 生成流程不是“把 1-bit 回波直接拼起来”，而是：

$$
S\xrightarrow{H\ pipeline} RC_H,
$$

$$
S\xrightarrow{L\ pipeline} RC_L.
$$

然后在统一 RC 网格中：

$$
RC_{mix}
=
M\odot \alpha RC_H+(1-M)\odot RC_L.
$$

其中 $M$ 是 H/L 方位 mask。

`energy_crop()` 在边界两侧取 buffer（历史值 64）估计能量：

$$
P_H=E(|RC_H|^2),
\qquad
P_L=E(|RC_L|^2),
$$

并把 H 对齐到 L：

$$
\alpha=\sqrt{\frac{P_L+\epsilon}{P_H+\epsilon}}.
$$

之后再按 mask 拼接。

已有结果表明，这样得到的 mixed frame 及完整 9 帧序列可以呈现平滑 U 型 PSNR/SSIM，而不是 mixed 帧突然塌陷。

## 6.5 一个需要改进的历史细节：逐帧 energy scale

历史脚本对每一个 mixed frame 独立调用 `energy_crop()`，因此不同帧可能得到不同：

$$
\alpha_1,\alpha_2,\alpha_3,\ldots
$$

同一全局地理区域出现在不同重叠帧时，可能因为不同帧的边界局部能量估计而被乘上不同尺度。

从 sequence consistency 原则看，这可能是人为 frame-to-frame variation。新数据生成方案应考虑：

- 是否使用 sequence-level H/L energy calibration；
- 或至少确保相同 global region 在重叠帧中的幅度映射一致。

此项尚未最终确定。

---

# 7. 当前代码实现

## 7.1 历史序列脚本：`seqdatacut_RangeMix_25.m`

### 关键配置

```matlab
N_SEQ        = 9;
STEP         = 128;
SEQ_STEP     = 3*STEP;   % 384
SIG_H        = 1200;
SIG_W        = 1200;
IMG_VALID    = 600;
PATCH_SIZE   = 512;
LOGIC_LEN    = 1536;
INPUT_LEN    = 2224;

q_high       = 2.5;
q_low        = 1.5;
q_lcm        = 7.5;
As           = 0.6;
EDGE_BUFFER  = 64;
rng(42);
```

### 原始数据处理

```matlab
raw_data = ...;
channel_60_clean = raw_data(1:3:end,:);
channel_60_input = channel_60_clean;
```

当前脚本不加高斯噪声。

### sequence block

每条序列先切：

$$
1200\times2224
$$

的大块，然后每帧再取：

$$
1200\times1200
$$

的回波 patch，列起点每次移动 128。

### global H/L mask

最终 512 有效地理轴：

```matlab
1:512       -> H
513:1024    -> L
1025:1536   -> H
```

`mode_mask_512` 再通过左右 margin 扩展为 1200 列 `mode_mask_1200` 供 RC mixing 使用。

## 7.2 历史 sequence-level master RT

函数：

```matlab
build_master_threshold_seq(seq60_input, q_lcm, As)
```

步骤：

1. 对整个 `1200×2224` block 进行 q_lcm=7.5 的距离上采样；
2. 用整个上采样 block 估计 `sigma_seq`；
3. 生成一个距离向随机相位向量；
4. H 与 L 从 master threshold 中按整数步长抽取子网格。

这意味着旧 Range+RT 的 H/L threshold 不是两套独立随机 realization，而是同一个高密度 master RT 的不同子采样。

这一设计对 sequence consistency 是正面的。

## 7.3 Range-only 上采样

函数：

```matlab
range_upsample_fft(S,q)
```

输入：`Nr×Na` 复数回波。

输出：`(q*Nr)×Na` 复数插值回波。

执行：沿第 1 维 FFT → centered zero pad → IFFT → `*q`。

## 7.4 mixed frame 的 RC 域流程

对同一个 `1200×1200` frame echo：

### High branch

```text
range upsample q_high
→ master RT 子采样
→ 1-bit
→ Range_Compress(Fs_high, tnrn_high)
→ crop_range_doppler_to_width(..., base nrn)
→ RC_high(base grid)
```

### Low branch

同样但使用 `q_low`。

### Mix

```text
RC_high + RC_low
→ energy_crop(..., mode_mask_1200, EDGE_BUFFER)
→ RC_mix
→ RCMC(base params)
→ SAR_Imaging(base params)
→ abs
→ 600 ROI
→ normalize
→ center crop 512
```

## 7.5 旧归一化行为

历史脚本使用不同 meta：

- GT：`q_high_meta.V_MAX_GT_L / V_MIN_GT_L`；
- High：`q_high_meta.V_MAX_Q_L / V_MIN_Q_L`；
- Low/Mixed：`q_low_meta.V_MAX_Q_L / V_MIN_Q_L`。

这会让 H/L 差异同时包含 acquisition difference 与 normalization mapping difference。最终 Transformer 数据集是否继续这样做必须重新审视。

## 7.6 输出 HDF5

每个 sequence `.mat`/HDF5 保存：

```text
/seq_GT_L              uint8 [512,512,9]
/seq_input_L           uint8 [512,512,9]
/frame_mode_id         uint8 [1,9]
/mode_mask_512_all     uint8 [9,512]
/sigma_seq             single
/A_rt                  single
```

frame mode 编码：

```text
1 = low
2 = high
3 = mixed
4 = gt
```

## 7.7 BARU 示例代码

用户提供的单次实验示例使用：

```matlab
Azimuth_q_m = 2;
Range_q_m   = 2;
q = 4;
```

并比较：

- 纯方位 q=4；
- 纯距离 q=4；
- BARU：2×2。

### BARU 主链

```text
signal60_input
→ two_dim_upsample_fft(q_a,q_r)
→ Build_2D_SplitRT
→ quantize_1bit_with_U
→ Range_Compress(使用上采样后的 Fs/tnrn)
→ two_dim_downsample_fft
    先 crop azimuth Doppler 到 base nan
    再 crop range spectrum 到 base nrn
→ RCMC(base grid)
→ SAR_Imaging(base params)
```

这段代码证明了一个关键实现模式：**BARU 的二维上采样数据在 RC 后被频域裁剪/投影回原始 base grid，之后才使用原始参数继续 RCMC 和方位成像。**

## 7.8 SFT 函数接口

建议统一保留：

```matlab
build2DSFTThreshold(
    signal_up,
    Fs_range_up,
    PRF_up,
    fr_Hz,
    fa_Hz,
    amplitude,
    initial_phase)
```

其中 `amplitude` 来自：

```matlab
sigma = sqrt(2/pi) * mean(abs(signal_up(:)));
A_u = sigma / (10^(STR_dB/20));
```

并明确记录：

- `fr_Hz`；
- `fa_Hz`；
- `STR_dB`；
- `phi0`；
- `sigma_scope`；
- `Fs_up/PRF_up` 是 nominal 还是 effective。

---

# 8. 当前实验约束

以下是当前已形成的实验原则。

## 8.1 sequence-level consistency 优先

同一 9 帧序列表示同一次连续无人机扫描，因此：

- 不应无理由逐帧改变 threshold protocol；
- 不应无理由逐帧改变上采样实现；
- 不应无理由逐帧重置 SFT phase origin；
- RT 随机性应以 sequence 为单位控制；
- 尽量避免逐帧独立 normalization 带来的额外尺度漂移；
- 若采用 azimuth upsampling，应注意逐帧 FFT window 不一致问题。

## 8.2 IID 的正确理解

深度学习需要训练/验证样本来自稳定分布，但这里的基本样本应定义为“9 帧序列”。

理想状态：

$$
\mathcal S_1,\mathcal S_2,\ldots
\sim P_{sequence},
$$

而不是要求：

$$
F_0,F_1,\ldots,F_8
$$

在同一序列内独立。

序列内部依赖正是 Transformer 要利用的信息。

## 8.3 H/L 比较必须保持公平总采样预算

对于同一个总预算 q：

- Range-only：$(q,1)$；
- BARU：$(q_r,q_a)$，满足 $q_rq_a\approx q$。

不能让 BARU 因为额外使用更多总样本而得到不公平优势。

## 8.4 控制变量

四种方法比较时，除目标变量外尽量固定：

- 同一 raw echo；
- 同一 GT；
- 同一 ROI/crop；
- 同一 SAR 成像参数；
- 同一 normalization protocol；
- 同一数据划分；
- 同一 H/L global mask；
- 同一 RC mixing 方法；
- 同一 energy alignment protocol；
- RT 比较时固定 seed；
- SFT 比较时固定/记录完整参数；
- 同一总采样预算。

## 8.5 随机性与可复现

RT：

- 必须记录 seed；
- 最低要求 sequence-level 固定 RNG；
- 若跨 H/L 要共享 threshold realization，需要显式记录共享策略。

SFT：

- 本身确定性；
- 必须记录 `fr_Hz/fa_Hz/STR_dB/phi0`；
- 时间原点定义也必须成为配置的一部分。

## 8.6 RC 为当前主 mixing domain

此项不再作为主要开放问题。RCMC 可作为历史对照/必要消融，但主数据集生成优先按 RC common-grid mixing 组织。

## 8.7 不要在数据退化模型未冻结前开始大规模 Transformer 训练

否则网络结果无法解释：如果后续更换 H/L 采样、RT/SFT 或 mixing protocol，前面训练结果会失去可比性。

---

# 9. 下一阶段核心实验

## 9.1 四类方法

必须系统比较：

```text
Range + RT
BARU  + RT
Range + SFT
BARU  + SFT
```

## 9.2 H/L 参数化扫描

不要提前固定最终 H/L。

实验配置应支持：

$$
(q_H,q_L)\in\mathcal G.
$$

历史基准：

$$
(2.5,1.5).
$$

可考虑但不预先承诺的候选示例包括：

```text
(2.5, 1.5)
(3.0, 1.5)
(3.0, 2.0)
(4.0, 2.0)
```

这些只是合理搜索点，不是最终参数决定。

BARU 对每个总 q 还要定义 allocation：

```text
range-only: (qr=q, qa=1)
balanced BARU: (qr≈sqrt(q), qa≈sqrt(q))
或其他满足 qr*qa≈q 的 allocation
```

## 9.3 推荐分两阶段筛选

### Stage A：纯 H / 纯 L 单帧或单块筛选

先不生成完整 9 帧 mixed sequence。

对同一回波/GT分别得到：

$$
I_H=\mathcal D_H(S),
\qquad
I_L=\mathcal D_L(S).
$$

至少记录：

$$
PSNR_H,\quad SSIM_H,
$$

$$
PSNR_L,\quad SSIM_L,
$$

$$
\Delta PSNR=PSNR_H-PSNR_L,
$$

$$
\Delta SSIM=SSIM_H-SSIM_L.
$$

目标不是只找最高 H，而是找：

- H 足够接近 GT；
- L 明显低于 H；
- L 仍保留可恢复的 SAR 结构；
- H/L gap 在不同场景上相对稳定。

如果 H 和 L 都非常好且 gap 过小，Transformer 的“高质量辅助低质量”任务过弱。

如果 L 过差，则网络可能主要依赖生成先验而不是利用序列冗余。

### Stage B：完整 9 帧序列验证

对 Stage A 中少数优选配置生成：

```text
H(512) - L(512) - H(512)
```

并记录 F0…F8。

重点检查：

- per-frame PSNR/SSIM 是否形成平滑 U 型；
- mixed frame 是否有局部撕裂；
- H/L 边界是否产生异常纹理；
- 相邻重叠帧的同一 global region 是否保持结构和幅度一致；
- F4 是否明显低于两端但仍有有效 SAR 结构；
- sequence mean 和 H/L gap 是否稳定。

## 9.4 自变量

至少包括：

- `method ∈ {Range_RT, BARU_RT, Range_SFT, BARU_SFT}`；
- `q_H_total`；
- `q_L_total`；
- BARU allocation `(qr, qa)`；
- RT variant / `As`；
- SFT `STR_dB, fr_Hz, fa_Hz, phi0`；
- threshold/sigma sharing scope（如作为消融）。

## 9.5 控制变量

见第 8 节。特别重要的是：同一 raw echo、GT、ROI、normalization、RC mixing 和总采样预算。

## 9.6 因变量 / 输出指标

必须记录：

- PSNR；
- SSIM；
- per-frame PSNR/SSIM；
- sequence mean PSNR/SSIM；
- H 纯帧指标；
- L 纯帧指标；
- H-L gap；
- mixed frame 指标；
- H/L transition 区域指标；
- U 型曲线平滑程度。

建议额外记录：

- RC 频谱图；
- off-support spectral energy；
- range/azimuth directional leakage；
- H/L boundary 两侧局部能量；
- energy alignment scale factor；
- overlap region consistency 指标。

频谱指标不是为了堆指标，而是用于判断：BARU/SFT 在低 q 和非整数 q 下是否引入异常泄漏/量化谐波，或是否真正改善可用频谱信息。

## 9.7 公平比较 SFT 参数

不能让方法比较变成“某一方法进行了更充分参数搜索”。建议先定义统一 threshold-selection protocol，例如：

- 所有 SFT 方法使用同样的 STR 候选集合；
- `fr/fa` 的搜索范围按各自物理采样率归一或用统一 Hz 规则；
- Range+SFT 设置 `fa=0`；
- BARU+SFT 使用二维 `(fr,fa)`；
- 参数搜索预算必须记录。

最终方法比较时同时报告：

1. 固定统一阈值参数的公平对比；
2. 若需要，再报告各方法各自最优参数结果。

---

# 10. 建议的实验代码架构

当前重点是 MATLAB 数据生成实验。不要为了架构漂亮而重写全部历史代码。建议围绕现有函数做“小而明确”的统一封装。

## 10.1 核心思想：统一到 `generate_base_rc`

建议把四种方法的共同输出定义为：

```matlab
[RC_base, meta] = generate_base_rc(signal, cfg_acq)
```

输入：

- 原始 clean/input 复回波；
- acquisition 配置。

输出：

- 已完成上采样、阈值、1-bit、Range Compression、必要二维投影后的 base-grid RC；
- meta：实际尺寸、q_eff、sigma、threshold 参数、seed 等。

这样：

```text
Range + RT
BARU  + RT
Range + SFT
BARU  + SFT
```

只在 `cfg_acq` 中切换，不需要复制四套完整成像代码。

## 10.2 建议复用的现有函数

直接复用或轻度整理：

```text
Range_Compress
RCMC
SAR_Imaging
range_upsample_fft / rangeUpsample
azimuth_upsample_fft / azimuthUpsample
two_dim_upsample_fft
crop_range_doppler_to_width
crop_azimuth_doppler_to_width
two_dim_downsample_fft
quantize_1bit_with_U / quantizeWithThreshold
energy_crop
crop_center
```

## 10.3 建议统一封装的模块

### `resolve_sampling_grid`

职责：

- 根据 method、q_total、allocation 计算 nominal `qr/qa`；
- 根据原始 `Nr/Na` 得到整数 `Nr_up/Na_up`；
- 返回 `qr_eff/qa_eff`；
- 返回 `Fs_up/PRF_up`。

### `apply_upsampling`

统一接口：

```matlab
S_up = apply_upsampling(S, grid_cfg)
```

### `build_threshold`

统一接口：

```matlab
[U, th_meta] = build_threshold(S_up, grid_cfg, th_cfg, seq_ctx)
```

支持：

```text
range_rt
split_rt
full_rt
rsft
asft
2d_sft
```

### `quantize_1bit`

保持单一实现，避免不同实验复制判决逻辑。

### `project_rc_to_base_grid`

Range-only 只裁距离；BARU 同时裁方位和距离。

### `mix_hl_rc`

统一：

- H/L mask；
- energy alignment；
- sequence-level 或 frame-level calibration policy；
- 输出 RC_mix 和 alignment meta。

### `image_from_base_rc`

统一执行：

```text
RCMC → SAR_Imaging → abs → ROI → normalize → crop
```

### `evaluate_case`

输出指标和中间诊断信息。

## 10.4 sequence_generation

建议支持两种模式，便于验证：

```text
legacy_framewise
sequence_level
```

`legacy_framewise` 用于复现历史数据。

`sequence_level` 用于验证：先对完整连续 sequence block 建立一致的上采样/阈值/RC，再按照 global H/L/H mask 和 frame positions 生成 9 帧。

不要直接删除 legacy 行为，因为它是重要对照。

## 10.5 与 Python/Transformer 训练侧的边界

MATLAB 数据退化模型冻结后，再实现：

```text
HDF5/MAT sequence
→ KAIR DatasetSAR1bit
→ SwinIR/temporal model
```

当前 `dataset_sar_1bit.py` 是空壳，因此不要在 acquisition model 未确定时过早把 Python loader 写死成某种文件布局。

---

# 11. 推荐的实验配置形式

建议使用 MATLAB struct，减少额外依赖，并与现有脚本兼容。

示例：

```matlab
cfg = struct();

cfg.name = "baru_sft_qH2p5_qL1p5";
cfg.seed = 42;

% ---------- 数据 ----------
cfg.data.root = "G:\\MATLAB-G\\SAR Full PSF";
cfg.data.dataset_list = [...];
cfg.data.gt_source = "TBD_60MHz_or_full_precision";

% ---------- 序列 ----------
cfg.seq.n_frames = 9;
cfg.seq.step = 128;
cfg.seq.patch_size = 512;
cfg.seq.echo_h = 1200;
cfg.seq.echo_w = 1200;
cfg.seq.sequence_echo_w = 2224;
cfg.seq.regime = "H_L_H";
cfg.seq.generate_scope = "sequence_level";  % or legacy_framewise

% ---------- H / L ----------
cfg.H.q_total = 2.5;
cfg.L.q_total = 1.5;

% ---------- 方法 ----------
cfg.method = "BARU_SFT";
% Range_RT | BARU_RT | Range_SFT | BARU_SFT

% ---------- sampling allocation ----------
cfg.H.allocation = "balanced";  % range_only | balanced | manual
cfg.L.allocation = "balanced";
cfg.H.q_range = [];
cfg.H.q_azimuth = [];
cfg.L.q_range = [];
cfg.L.q_azimuth = [];

% ---------- threshold ----------
cfg.threshold.type = "SFT";
cfg.threshold.sigma_scope = "sequence";

cfg.threshold.RT.As = 0.6;
cfg.threshold.RT.variant = "split";
cfg.threshold.RT.share_policy = "TBD";

cfg.threshold.SFT.STR_dB = ...;
cfg.threshold.SFT.fr_Hz = ...;
cfg.threshold.SFT.fa_Hz = ...;
cfg.threshold.SFT.phi0 = ...;
cfg.threshold.SFT.time_origin = "sequence_global";

% ---------- mixing ----------
cfg.mix.domain = "RC";
cfg.mix.energy_align = true;
cfg.mix.edge_buffer = 64;
cfg.mix.scale_scope = "TBD_frame_or_sequence";

% ---------- normalization ----------
cfg.norm.mode = "TBD_unified";

% ---------- 保存 ----------
cfg.save.intermediate_rc = true;
cfg.save.spectrum = true;
cfg.save.images = true;
cfg.save.config_json = true;
```

## 11.1 配置必须记录 effective q

runner 启动后根据实际尺寸补充：

```matlab
result.H.qr_eff
result.H.qa_eff
result.L.qr_eff
result.L.qa_eff
result.H.Fs_up
result.H.PRF_up
...
```

这样之后不会出现“配置写 sqrt(2.5)，实际尺寸却对应另一个 q”的不可追踪问题。

---

# 12. 输出与结果管理

建议每一次完整实验都拥有唯一 run directory。

示例：

```text
results/
└── 2026xxxx_method-BARU_SFT_H-2p5_L-1p5_seed42/
    ├── config.json
    ├── config.mat
    ├── summary.csv
    ├── per_frame_metrics.csv
    ├── per_scene_metrics.csv
    ├── alignment_metrics.csv
    ├── run.log
    ├── images/
    │   ├── GT/
    │   ├── input/
    │   └── difference/
    ├── curves/
    │   ├── psnr_u_curve.png
    │   └── ssim_u_curve.png
    ├── spectrum/
    │   ├── RC_H/
    │   ├── RC_L/
    │   └── RC_mix/
    └── intermediate/
        └── optional MAT files
```

## 12.1 `summary.csv`

建议至少包含：

```text
run_id
method
qH_total
qL_total
qH_r_eff
qH_a_eff
qL_r_eff
qL_a_eff
threshold_type
seed
mean_psnr
mean_ssim
H_psnr
H_ssim
L_psnr
L_ssim
delta_psnr
delta_ssim
u_curve_smoothness
```

## 12.2 `per_frame_metrics.csv`

每帧保存：

```text
scene_id
sequence_id
frame_idx
frame_mode
H_ratio
L_ratio
psnr
ssim
boundary_metric
overlap_consistency
```

## 12.3 频谱诊断

对于 BARU/SFT 尤其重要，建议保存：

- RC complex spectrum；
- log magnitude spectrum；
- support mask；
- off-support energy ratio；
- range leakage；
- azimuth leakage；
- H/L boundary 附近频谱/能量差。

这些数据用于解释“低 q + 非整数 BARU + SFT”是否出现异常，而不是只依赖最终 PSNR/SSIM。

---

# 13. Codex 下一步行动建议

Codex 接手后建议严格按以下顺序推进。

## Step 1：确认当前 MATLAB 代码入口与依赖

定位并确认：

```text
seqdatacut_RangeMix_25.m
Range_Compress
RCMC
SAR_Imaging
FS60_params.mat
各 dataset meta normalization 文件
BARU 相关 V5Core / helper functions
SFT threshold functions
```

不要先修改 Transformer。

## Step 2：建立“历史结果可复现”基线

用原始：

```text
Range + RT
qH = 2.5
qL = 1.5
seed = 42
RC mix
```

复现至少一个已有 9 帧 U 型结果。

这是后续重构正确性的锚点。

## Step 3：统一 acquisition function 接口

目标：四种方法都输出相同尺寸的 base-grid RC。

优先实现/封装：

```matlab
generate_base_rc(signal, cfg_acq)
```

而不是直接写四份主脚本。

## Step 4：实现 effective sampling grid

对非整数 q：

- `round(q*N)`；
- 计算 `q_eff`；
- 用 `q_eff` 更新 `Fs_up/PRF_up`；
- 所有 metadata 记录实际值。

## Step 5：统一 threshold builder

把 RT/SFT 参数和生成范围配置化。

先保证单帧/单块结果和现有函数一致，再考虑 sequence-global threshold。

## Step 6：建立 Stage A 纯 H/L runner

对四种方法和参数网格批量运行：

```text
method × qH × qL × threshold parameters × scene
```

输出 H/L 指标和 gap。

此阶段不要生成 9 帧 mixed sequence，以降低调试复杂度。

## Step 7：筛选少数 configuration

根据：

- H 绝对质量；
- L 绝对质量；
- H/L gap；
- 跨场景稳定性；
- 频谱行为；

进入 Stage B。

## Step 8：建立 sequence-level 生成路径

首先保留 legacy framewise 作为对照，再增加 sequence-level 版本。

重点检查：

- SFT slow-time origin；
- RT random field sharing；
- azimuth FFT window 边界；
- energy alignment scope；
- normalization consistency。

## Step 9：生成完整 9 帧 H/L/H

统一 RC mixing，检查 U 型曲线、边界和 overlap consistency。

## Step 10：建立结果自动汇总

自动生成：

- CSV；
- H/L comparison table；
- per-frame curve；
- method × q heatmap；
- 最优配置排序；
- spectrum diagnostics。

## Step 11：冻结 degradation model

最终选择 1–2 套最适合 Transformer 的数据生成机制。

选择标准不是只看“最高 PSNR”，而是综合：

```text
H 信息丰富
L 明显较弱但仍可恢复
H/L gap 稳定
序列内部一致
mixed 过渡平滑
无明显人为 artifact
计算代价可接受
可复现
```

## Step 12：再进入 Transformer 数据加载和网络结构

冻结数据格式后再完成 `DatasetSAR1bit`、训练配置和时序网络。

---

# 14. Open Questions

以下内容不得被 Codex 当作已经确定的事实。

## 14.1 最终 GT 基准

- 是否继续用历史 60 MHz clean echo 作为 GT 母体？
- 还是严格回到原始 180 MHz high-precision echo 直接 RD 成像？

需要明确。

## 14.2 最终 H/L 数值

历史 `(2.5,1.5)` 只是基准，不是最终决定。

需要扫描多组 `(q_H,q_L)`。

## 14.3 BARU allocation

对于每个 q：

- 是否只测试 balanced `sqrt(q)×sqrt(q)`；
- 还是沿 BARU 已有结果测试若干非均衡 allocation；
- 低 q 下是否仍有 near-optimal plateau；

均待实验。

## 14.4 SFT 在低 q 下究竟有多大收益

当前认为可能较弱，但必须通过：

```text
Range+RT vs Range+SFT
BARU+RT  vs BARU+SFT
```

直接验证。

## 14.5 非整数 BARU + SFT 的频谱影响

需要区分：

- round 引起的 q_eff 误差；
- FFT 有限窗泄漏；
- SFT frequency-grid mismatch；
- 1-bit sign nonlinearity 产生的高次频谱；
- 是否真正出现影响成像质量的异常谐波/泄漏。

不能简单归因于“sqrt(q) 是小数”。

## 14.6 RT 在 H/L 非整数二维网格上如何共享

历史 q=2.5/1.5 Range RT 可以用 `q_lcm=7.5` 建 master field。

BARU 若使用近似 `sqrt(q)`，没有简单整数 LCM 网格。需要决定：

- H/L 分别生成但共享 seed；
- 构造某种 base random phase field 再插值；
- 采用 SplitRT 的共享 component；
- 或接受 H/L threshold realization 不完全相同。

这是 fairness 和 sequence consistency 的关键开放问题。

## 14.7 SFT threshold 是否 sequence-global

需要验证：

- same `fr/fa/phi0` + global slow-time coordinate；
- 每帧 local time origin；

哪一种最符合连续飞行模型并且更利于训练。

当前倾向 sequence-global。

## 14.8 sigma scope

需要比较/决定：

```text
frame-level
sequence-level
regime-level H/L
fixed calibration
```

## 14.9 energy alignment scope

历史 `energy_crop()` 是 frame-level。

是否改成 sequence-level calibration 以保持 overlap region 一致性，需要实验。

## 14.10 normalization protocol

必须明确最终 H/L/GT 是否使用完全统一的全局尺度、每场景固定尺度或其他策略。

历史 H 与 L/mixed 使用不同 meta，可能构成额外 domain shift。

## 14.11 sequence-level 全块生成是否优于 framewise

加入 azimuth upsampling 后，sequence-level 在物理一致性上更合理，但可能改变：

- FFT 边界；
- 内存/计算量；
- 现有 RD 函数调用方式；
- frame crop 与 aperture/window 关系。

需要单样本验证。

## 14.12 Transformer 最终如何使用跨帧信息

当前目标明确：利用 H 信息帮助 L 区域。

但具体网络结构仍未冻结。

必须记住：

$$
u=128k+w.
$$

因此不同帧相同 local coordinate 并不是同一个 global location。

旧 `SAR_experiment_design.md` 中“同位置 temporal attention”如果不做几何对齐，会把不同地理位置当作同一点。后续网络设计至少应明确区分：

- 基于已知 128 px shift 的真正 overlap alignment；
- 非重叠区域的纹理/统计先验传递；
- 纯粹 channel stacking baseline。

网络设计应在 degradation model 冻结后再继续。

---

# 15. 给 Codex 的最终上下文摘要

如果只保留最核心的决策逻辑，可以记住以下几点：

1. 任务是 UAV stripmap SAR 1-bit 图像序列恢复；1-bit 发生在回波 I/Q 量化阶段，网络输入最终是普通 512×512 灰度 SAR 图。
2. 9 帧来自同一连续长回波的滑动成像窗口，步进 128 px；它们高度相关，不应被视为彼此独立。
3. H/L/H 是预量化 sampling regime：512H-512L-512H；F0/F4/F8 纯 H/L/H，其余帧混合。
4. 历史数据集使用 Range-only qH=2.5/qL=1.5 + sequence-level Range RT + RC-domain energy-aligned mixing。
5. 直接在 1-bit echo 域 H/L 拼接会严重撕裂；RC/RCMC mixing 更好，目前主方案确定为 RC mixing。
6. BARU 双向上采样已有大量前期研究基础，但当前低 q 和非整数 `sqrt(q)` 条件与历史 BARU 整数高预算实验不同，不能直接外推。
7. SFT 在低 q 下可能收益有限，但这是待验证假设，不是结论。
8. 当前需要先比较 `Range+RT / BARU+RT / Range+SFT / BARU+SFT`，并扫描多组 H/L。
9. 最优数据集模型不是简单追求最高 PSNR，而要同时满足：高 H、可恢复 L、稳定 H/L gap、序列一致性、平滑 U 型过渡、低人为 artifact、可复现。
10. degradation model 冻结后，再实现 Python Dataset 和时序 Transformer。

---

# 16. 来源与代码依据

本交接文档主要依据以下现有材料整理：


- 仓库 `AGENTS.md`；
- 仓库 `SAR_experiment_design.md`；
- 仓库 `KAIR/data/dataset_sar_1bit.py`；
- 仓库 `KAIR/data/select_dataset.py`；
- 仓库 `KAIR/options/swinir/train_swinir_sar_1bit.json`；
- 历史数据生成脚本 `seqdatacut_RangeMix_25.m`；
- BARU 单次双向上采样示例代码（用户提供文本文件）；
- 用户提供的 `twoDimUpsample / rangeUpsample / azimuthUpsample` 实现；
- 用户提供的 `build2DSFTThreshold` 与 1-bit quantization 实现；
- 已有 H/L mix position 实验现象和 BARU/SFT 研究经验。

本文档刻意将“已有实验事实”“当前工作假设”“开放问题”分开，后续 Codex 不应自行把 Open Questions 补成事实。
