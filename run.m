cfg = sarvalid.default_config();
cfg.generator_confirmation.dry_run = false;

cfg.generator_confirmation.stop_after = "C1"; % 先关闭BARU边界
c1 = run_generator_confirmation_v2(cfg);

cfg.generator_confirmation.stop_after = "C2"; % 再完成严格难度匹配
c2 = run_generator_confirmation_v2(cfg);

cfg.generator_confirmation.stop_after = "C3"; % 旧集桥接和新样本盲测
c3 = run_generator_confirmation_v2(cfg);

cfg.generator_confirmation.stop_after = "C5"; % 九帧验证与最终报告
final = run_generator_confirmation_v2(cfg);