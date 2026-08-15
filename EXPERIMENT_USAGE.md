# SAR 1-bit 退化模型实验使用说明

本仓库实现两阶段实验，但不会在代码安装或测试时自动启动完整搜索。

## 入口

- `run_stage_a_screening.m`：纯 H/L 联合筛选、锁参和 70 样本验证。
- `run_stage_b_sequence_validation.m`：连续全块九帧验证、framewise 消融、Pareto 排名和 180 MHz 敏感性检查。
- `run_generator_threshold_comparison.m`：独立比较 Range+2D-SFT 与 BARU+RT，并给出数据生成器选择报告。
- `sarvalid.default_config()`：唯一默认配置。实验前应复制到调用脚本中覆盖路径或开关，不要直接修改公共默认值来记录单次实验。

## 先做 dry-run

```matlab
cfg = sarvalid.default_config();
cfg.runtime.dry_run = true;
stage_a = run_stage_a_screening(cfg);
stage_b = run_stage_b_sequence_validation(cfg);
```

dry-run 只检查参数文件、数据轨迹和样本清单，并写出配置与 manifest；不会生成退化数据或运行参数搜索。预期 Stage A 为 14 条开发样本和 70 条验证样本，Stage B 为 7 条标定序列和 14 条评估序列。

## 完整实验顺序

```matlab
cfg = sarvalid.default_config();
cfg.runtime.dry_run = false;

stage_a = run_stage_a_screening(cfg);
stage_b = run_stage_b_sequence_validation(cfg);
```

Stage B 会读取 `results/stage_a/stage_a_final.mat` 中的锁定参数，因此必须在 Stage A 完成后运行。若只需先验证 60 MHz 主结论，可临时设置：

```matlab
cfg.stage_b.run_180_sensitivity = false;
```

并行 worker 数不参与实验签名；当前实现默认串行，避免 Parallel Computing Toolbox 许可证失败改变实验协议。

## 输出和恢复

每个任务目录保存配置、清单、归一化统计、逐样本或逐帧 CSV、MAT 汇总和诊断图。Stage B 的代表性 RC 每场景只保存一条，避免大型中间量无限增长。

checkpoint 使用临时文件加原子替换。恢复时会用 `isequaln` 检查方法、H/L、alpha、名义与实际倍率、阈值参数、seed、样本清单、归一化协议和成像参数；签名不一致会直接报错。若要开始一套新协议，应更换 `cfg.output_root`，不要复用旧目录。

## 验证命令

```matlab
results = runtests('tests');
assertSuccess(results);
```

完整实验预计耗时较长。代码实现授权与运行授权彼此独立；除非明确要求启动，默认只执行 dry-run、静态检查和单样本轻量验证。

## Range+2D-SFT 与 BARU+RT 补充实验

该实验固定使用 `(4,2)` 和 `(2.5,1.5)` 两组 H/L 倍率，输出到独立目录 `results_generator_comparison`，不会读取、覆盖或清理原 `results`。其中 `Range_2D_SFT` 仅做距离向上采样，但 `fr`、`fa` 均参与二维 SFT 搜索；旧 `Range_SFT` 的 `fa=0` 语义保持不变。BARU+RT 对每个 `alpha/As` 候选使用五个预注册 seed family，主统计先在样本或序列内部聚合 seed。

先检查 14/70 样本和 7/14 序列清单：

```matlab
cfg = sarvalid.default_config();
cfg.runtime.dry_run = true;
preview = run_generator_threshold_comparison(cfg);
```

只有在明确决定启动完整补充实验后，才运行：

```matlab
cfg = sarvalid.default_config();
cfg.runtime.dry_run = false;
result = run_generator_threshold_comparison(cfg);
```

入口依次完成 Stage A 难度匹配与 70 样本验证、Stage B 九帧序列验证、场景聚类 bootstrap 和最终冻结判据。它不运行 framewise 消融或 180 MHz 敏感性实验。主要输出为：

- `stage_a/all_candidates.csv`、`difficulty_matching.csv`、`locked_generators.csv`、`verification_detail.csv` 和 `verification_summary.csv`
- `stage_b/sequence_seed_detail.csv`、`sequence_summary.csv` 和 `generator_comparison.csv`
- `generator_decision_report.csv` 和 `generator_comparison_final.mat`

将 `cfg.generator_compare.resume=false` 可忽略同目录已有 checkpoint 并从当前配置重新计算；建议新协议仍使用新的 `output_root`，以保留既有实验审计链。
