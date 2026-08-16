cfg = sarvalid.default_config();
cfg.generator_confirmation.dry_run = false;
cfg.generator_confirmation.stop_after = "C5";

% 直接运行Range+2D-SFT与BARU+RT的完整成像效果比较。
% C1边界审计和C2难度误差仅写入结果，不再提前终止实验。
final = run_generator_confirmation_v2(cfg);
