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

% 独立确认实验：直接比较Range+2D-SFT与BARU+RT的成像效果。
cfg.generator_confirmation.version = "generator_confirmation_v2";
cfg.generator_confirmation.methods = [ ...
    "Range_2D_SFT", "BARU_RT", "Range_NonzeroFa_SFT"];
cfg.generator_confirmation.hl_pairs = [4, 2; 2.5, 1.5];
cfg.generator_confirmation.baru_coarse_alpha = [0.35, 0.50, 0.65, 0.80];
cfg.generator_confirmation.baru_coarse_As = [0.20, 0.30, 0.40];
cfg.generator_confirmation.baru_fine_offsets = ...
    [-0.10, -0.05, 0, 0.05, 0.10];
cfg.generator_confirmation.baru_alpha_bounds = [0.20, 0.90];
cfg.generator_confirmation.baru_As_bounds = [0.10, 0.50];
cfg.generator_confirmation.baru_boundary_gain_tolerance = 0.001;
cfg.generator_confirmation.rt_seed_families = ...
    cfg.threshold_seed + (0:4) * 1000003;
% 仅用于选择相近候选和记录难度误差，不作为运行或推荐门槛。
cfg.generator_confirmation.strict_difficulty_tolerance = struct( ...
    "l_ssim", 0.005, "delta_ssim", 0.01);
cfg.generator_confirmation.range_micro_STR_offsets_dB = -1:0.25:1;
cfg.generator_confirmation.range_micro_frequency_offsets = -0.2:0.05:0.2;
cfg.generator_confirmation.nonzero_fa_min = 0.1;
cfg.generator_confirmation.confirmation_trajectories_per_scene = 2;
cfg.generator_confirmation.confirmation_samples_per_trajectory = 10;
cfg.generator_confirmation.confirmation_sample_id_start = 100001;
cfg.generator_confirmation.sequence_files_per_scene = 5;
cfg.generator_confirmation.sequence_id_start = 200001;
cfg.generator_confirmation.bootstrap_repetitions = 10000;
cfg.generator_confirmation.bootstrap_seed = 2026;
cfg.generator_confirmation.tail_noninferiority_margin = 0.005;
cfg.generator_confirmation.catastrophic_minimum_margin = 0.01;
cfg.generator_confirmation.mean_noninferiority_margin = 0.005;
cfg.generator_confirmation.structure_relative_margin = 0.02;
cfg.generator_confirmation.seed_spread_fraction = 0.20;
cfg.generator_confirmation.overlap_ssim_loss_tolerance = 0.005;
cfg.generator_confirmation.boundary_jump_db_tolerance = 0.1;
cfg.generator_confirmation.output_root = fullfile( ...
    repo_root, "results_generator_confirmation_v2");
cfg.generator_confirmation.resume = true;
cfg.generator_confirmation.dry_run = false;
cfg.generator_confirmation.stop_after = "C5";

% Range+2D-SFT生产参数搜索V3：复用V2的35条连续序列，不设置验证集。
cfg.range_2dsft_v3.version = "range_2dsft_search_v3";
cfg.range_2dsft_v3.hl_pairs = [4, 2; 2.5, 1.5];
cfg.range_2dsft_v3.STR_grid = -10:2:10;
cfg.range_2dsft_v3.fr_grid = 0:0.2:4;
cfg.range_2dsft_v3.fa_grid = 0:0.2:4;
cfg.range_2dsft_v3.fine_STR_offsets = -2:1:2;
cfg.range_2dsft_v3.fine_frequency_offsets = -0.2:0.05:0.2;
cfg.range_2dsft_v3.low_percentile = 0.99;
cfg.range_2dsft_v3.high_percentile = 99.9;
cfg.range_2dsft_v3.normalization_roi_size = 600;
cfg.range_2dsft_v3.metric_patch_size = 512;
cfg.range_2dsft_v3.energy_buffer = 64;
cfg.range_2dsft_v3.manifest_source = fullfile( ...
    repo_root, "results_generator_confirmation_v2", ...
    "manifests", "sequence.csv");
cfg.range_2dsft_v3.output_root = fullfile( ...
    repo_root, "results_range_2dsft_v3");
cfg.range_2dsft_v3.resume = true;
cfg.range_2dsft_v3.dry_run = false;
cfg.range_2dsft_v3.stop_after = "final";

cfg.diagnostics.support_threshold_ratio = 0.35;
cfg.diagnostics.save_representative_rc = true;
cfg.runtime.num_workers = 0;
cfg.runtime.dry_run = false;
end
