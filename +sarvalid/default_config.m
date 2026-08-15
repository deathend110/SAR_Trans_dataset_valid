function cfg = default_config()
%DEFAULT_CONFIG 返回SAR 1-bit退化筛选实验的唯一默认配置。

package_dir = fileparts(mfilename("fullpath"));
repo_root = fileparts(package_dir);

cfg = struct();
cfg.experiment_name = "sar_1bit_degradation_screening_v1";
cfg.repo_root = repo_root;
cfg.data_root = "G:\MATLAB-G\SAR Full PSF";
cfg.parameter_file_60 = fullfile(repo_root, "FS60_params.mat");
cfg.parameter_file_180 = fullfile(repo_root, "FS180_params.mat");
cfg.output_root = fullfile(repo_root, "results");

cfg.dataset_names = [ ...
    "SAR_Dataset_Bangkok_1", ...
    "SAR_Dataset_city1_histeq", ...
    "SAR_Dataset_city2_histeq", ...
    "SAR_Dataset_SAR_figure", ...
    "SAR_Dataset_filed", ...
    "SAR_Dataset_port", ...
    "SAR_Dataset_suburb"];

cfg.sample_seed = 2026;
cfg.threshold_seed = 42;
cfg.methods = ["Range_RT", "BARU_RT", "Range_SFT", "BARU_SFT"];
cfg.hl_pairs = [4, 2; 3, 2; 2.5, 1.5; 3, 1.5];
cfg.baru_alpha = [0.35, 0.50, 0.65];

cfg.threshold.As = 0.6;
cfg.threshold.phi0 = 0;
cfg.threshold.STR_coarse_dB = -8:2:8;
cfg.threshold.range_frequency_step = 0.2;
cfg.threshold.baru_frequency_step = 0.4;
cfg.threshold.frequency_cap = 2.4;
cfg.threshold.nyquist_margin = 0.98;
cfg.threshold.fine_STR_offsets_dB = -2:1:2;
cfg.threshold.fine_frequency_offsets = -0.2:0.1:0.2;
cfg.threshold.max_boundary_expansions = 1;

cfg.normalization.low_percentile = 0.1;
cfg.normalization.high_percentile = 99.9;

cfg.stage_a.development_samples_per_scene = 2;
cfg.stage_a.verification_samples_per_scene = 10;
cfg.stage_a.output_dir = fullfile(cfg.output_root, "stage_a");
cfg.stage_a.resume = true;

cfg.sequence.n_frames = 9;
cfg.sequence.step = 128;
cfg.sequence.signal_height = 1200;
cfg.sequence.signal_width = 1200;
cfg.sequence.patch_size = 512;
cfg.sequence.roi_size = 600;
cfg.sequence.valid_margin = 344;
cfg.sequence.logic_length = 1536;
cfg.sequence.block_width = 2224;
cfg.sequence.energy_buffer = 64;

cfg.stage_b.sequences_per_scene = 3;
cfg.stage_b.calibration_sequences_per_scene = 1;
cfg.stage_b.output_dir = fullfile(cfg.output_root, "stage_b");
cfg.stage_b.run_framewise_ablation = true;
cfg.stage_b.run_180_sensitivity = true;
cfg.stage_b.resume = true;

% 独立的数据生成器选择实验，不复用既有Stage A/B输出或checkpoint。
cfg.generator_compare.methods = ["Range_2D_SFT", "BARU_RT"];
cfg.generator_compare.hl_pairs = [4, 2; 2.5, 1.5];
cfg.generator_compare.baru_alpha = [0.35, 0.50, 0.65];
cfg.generator_compare.baru_As = 0.4:0.1:0.8;
cfg.generator_compare.rt_seed_families = ...
    cfg.threshold_seed + (0:4) * 1000003;
cfg.generator_compare.difficulty_tolerance = struct( ...
    "l_ssim", 0.005, "delta_ssim", 0.01, ...
    "expanded_l_ssim", 0.01, "expanded_delta_ssim", 0.02);
cfg.generator_compare.bootstrap_repetitions = 10000;
cfg.generator_compare.bootstrap_seed = 2026;
cfg.generator_compare.decision.mean_ssim_disadvantage_limit = 0.005;
cfg.generator_compare.decision.overlap_ssim_loss_tolerance = 0.005;
cfg.generator_compare.decision.boundary_jump_db_tolerance = 0.1;
cfg.generator_compare.output_root = fullfile( ...
    repo_root, "results_generator_comparison");
cfg.generator_compare.resume = true;

cfg.diagnostics.support_threshold_ratio = 0.35;
cfg.diagnostics.save_representative_rc = true;
cfg.runtime.num_workers = 0;
cfg.runtime.dry_run = false;
end
