clear; clc; close all;

%% ========================================================================
% Range+2D-SFT 单序列调试脚本
%
% 用途：
%   从指定SAR场景中随机选择一条轨迹和一个连续回波块，按照V3的
%   H-L-H长块成像协议生成9帧输入/GT序列，保存PNG并绘制PSNR、SSIM曲线。
%
% 说明：
%   本脚本为了便于快速调参，归一化分位数只由当前单序列的9帧统计。
%   因此这里得到的指标不能直接等同于V3的“同场景5条序列×9帧”结果。
%% ========================================================================

%% ============================== 参数区 ==================================
SCENE      = "SAR_Dataset_Bangkok_1";  % 可写完整名称，也可写Bangkok_1等短名称
Q_HIGH     = 4;                         % H分支距离向上采样倍率
Q_LOW      = 2;                         % L分支距离向上采样倍率
STR_DB     = -1;                        % SFT信号阈值比，单位dB
FR_OVER_BR = 1.3;                       % 距离SFT频率归一化值 fr/Br
FA_OVER_BA = 0.5;                       % 方位SFT频率归一化值 fa/Ba
PHI0       = 0;                         % SFT初相位，单位rad

RANDOM_SEED = 42;                       % 固定后可复现随机轨迹和随机块起点

% 留空时随机选择；指定后可精确复现某条轨迹或某个连续块。
% 示例：ECHO_FILE_OVERRIDE = "rstart 1801.mat";
ECHO_FILE_OVERRIDE = "";
CSTART_OVERRIDE = NaN;

LOW_PERCENTILE  = 0.99;
HIGH_PERCENTILE = 99.9;
ENERGY_BUFFER   = 64;

% MATLAB桌面运行时显示两张指标图；matlab -batch运行时只保存、不弹窗。
SHOW_METRIC_FIGURES = usejava('desktop');

%% ========================== 仓库与数据配置 ===============================
SCRIPT_PATH = string(mfilename('fullpath'));
REPO_ROOT = string(fileparts(SCRIPT_PATH));
addpath(REPO_ROOT);

cfg = sarvalid.default_config();
DATA_ROOT = string(cfg.data_root);
PARAMETER_FILE = string(cfg.parameter_file_60);
OUTPUT_ROOT = fullfile(REPO_ROOT, "debug_single_sequence_output");

S60 = load(PARAMETER_FILE);
scene_name = resolve_scene_name(SCENE, cfg.dataset_names);
scene_dir = fullfile(DATA_ROOT, scene_name);
if ~isfolder(scene_dir)
    error('debugRangeSFT:SceneDirectoryMissing', ...
        '场景目录不存在：%s', scene_dir);
end

%% ======================= 随机选择轨迹和连续块 ============================
rng(RANDOM_SEED, 'twister');
echo_files = dir(fullfile(scene_dir, 'rstart*.mat'));
[~, file_order] = sort(lower(string({echo_files.name})));
echo_files = echo_files(file_order);
echo_files = filter_valid_echo_files(echo_files, S60, cfg.sequence.block_width);
if isempty(echo_files)
    error('debugRangeSFT:NoValidEcho', ...
        '场景%s中没有能生成1200×2224连续块的rstart回波。', scene_name);
end

if strlength(ECHO_FILE_OVERRIDE) > 0
    selected_mask = strcmpi(string({echo_files.name}), ECHO_FILE_OVERRIDE);
    if sum(selected_mask) ~= 1
        error('debugRangeSFT:EchoOverrideMissing', ...
            '指定轨迹%s不存在或不满足尺寸要求。', ECHO_FILE_OVERRIDE);
    end
    selected_file = echo_files(selected_mask);
else
    selected_file = echo_files(randi(numel(echo_files)));
end

echo_path = string(fullfile(selected_file.folder, selected_file.name));
variables = whos('-file', echo_path);
raw_width = variables(1).size(2);
max_start = raw_width - cfg.sequence.block_width + 1;
if isfinite(CSTART_OVERRIDE)
    if CSTART_OVERRIDE ~= round(CSTART_OVERRIDE) || ...
            CSTART_OVERRIDE < 1 || CSTART_OVERRIDE > max_start
        error('debugRangeSFT:InvalidCStartOverride', ...
            'CSTART_OVERRIDE必须是[1,%d]内的整数。', max_start);
    end
    c_start = double(CSTART_OVERRIDE);
else
    c_start = randi(max_start);
end

manifest_row = table(string(selected_file.name), echo_path, c_start, ...
    'VariableNames', ["File", "FilePath", "CStart"]);
signal60 = sarvalid.load_echo_block( ...
    manifest_row, S60, cfg.sequence.block_width);
if isreal(signal60) || ~isequal(size(signal60), ...
        [cfg.sequence.signal_height, cfg.sequence.block_width])
    error('debugRangeSFT:InvalidEchoBlock', ...
        '60MHz回波必须是1200×2224复数矩阵，实际尺寸为%s。', ...
        mat2str(size(signal60)));
end

%% ======================== 构造H/L采集参数 ================================
if ~isscalar(Q_HIGH) || ~isscalar(Q_LOW) || ...
        ~isfinite(Q_HIGH) || ~isfinite(Q_LOW) || ...
        Q_HIGH <= Q_LOW || Q_LOW < 1
    error('debugRangeSFT:InvalidSamplingPair', ...
        '当前Range上采样实现要求Q_HIGH>Q_LOW>=1。');
end
if any(~isfinite([STR_DB, FR_OVER_BR, FA_OVER_BA, PHI0])) || ...
        FR_OVER_BR < 0 || FA_OVER_BA < 0
    error('debugRangeSFT:InvalidSFTParameters', ...
        'STR、fr/Br、fa/Ba和phi0必须有限，归一化频率不能为负。');
end

threshold = struct("As", cfg.threshold.As, "STR_dB", STR_DB, ...
    "fr_over_Br", FR_OVER_BR, "fa_over_Ba", FA_OVER_BA, "phi0", PHI0);
pair = sarvalid.make_pair_config( ...
    cfg, "Range_2D_SFT", Q_HIGH, Q_LOW, 1, threshold);
pair.file_key = sarvalid.generator_file_key(pair, cfg.threshold_seed);

grid_h = sarvalid.resolve_acquisition(pair.H, size(signal60), S60);
grid_l = sarvalid.resolve_acquisition(pair.L, size(signal60), S60);
azimuth_bandwidth = resolve_azimuth_bandwidth(S60);
fr_limit = cfg.threshold.nyquist_margin * ...
    min(grid_h.Fs_up, grid_l.Fs_up) / (2 * S60.B);
fa_limit = cfg.threshold.nyquist_margin * ...
    min(grid_h.PRF_up, grid_l.PRF_up) / (2 * azimuth_bandwidth);
if FR_OVER_BR >= fr_limit || FA_OVER_BA >= fa_limit
    error('debugRangeSFT:SFTNyquistViolation', ...
        ['SFT频率必须严格小于H/L共同Nyquist上限：' ...
        'fr/Br < %.12g，fa/Ba < %.12g；当前为%.12g和%.12g。'], ...
        fr_limit, fa_limit, FR_OVER_BR, FA_OVER_BA);
end

shared_fields = ["STR_dB", "fr_over_Br", "fa_over_Ba", "phi0"];
for field_name = shared_fields
    if pair.H.threshold.(field_name) ~= pair.L.threshold.(field_name)
        error('debugRangeSFT:UnsharedThreshold', ...
            'H/L未共享阈值参数%s。', field_name);
    end
end

%% =================== 全长块生成、能量对齐与混合 ==========================
sequence_mask = sarvalid.build_hlh_mask(cfg.sequence);
[RC_H, meta_h] = sarvalid.generate_base_rc(signal60, S60, pair.H);
[RC_L, meta_l] = sarvalid.generate_base_rc(signal60, S60, pair.L);
if ~isequal(size(RC_H), size(RC_L), size(signal60))
    error('debugRangeSFT:RCSizeMismatch', ...
        'H、L和60MHz回波必须保持相同的基网格尺寸。');
end

% 两处H/L边界共同估计一个gamma，并作用到整个H分支。
[RC_mix, mix_info] = sarvalid.align_and_mix_rc( ...
    RC_H, RC_L, sequence_mask.full, ENERGY_BUFFER);
RC_H_aligned = RC_H * mix_info.scale_factor;

%% ======================= 九帧成像与分位数池 ==============================
frame_count = cfg.sequence.n_frames;
roi_size = cfg.sequence.roi_size;
patch_size = cfg.sequence.patch_size;
gt_roi = zeros(roi_size, roi_size, frame_count, 'single');
h_roi = zeros(size(gt_roi), 'single');
l_roi = zeros(size(gt_roi), 'single');
mixed_roi = zeros(size(gt_roi), 'single');

for frame_idx = 1:frame_count
    column_start = 1 + (frame_idx - 1) * cfg.sequence.step;
    columns = column_start:column_start + cfg.sequence.signal_width - 1;

    gt_roi(:, :, frame_idx) = single(sarvalid.generate_gt_image( ...
        signal60(:, columns), S60, roi_size));
    h_roi(:, :, frame_idx) = single(sarvalid.focus_base_rc( ...
        RC_H_aligned(:, columns), S60, roi_size));
    l_roi(:, :, frame_idx) = single(sarvalid.focus_base_rc( ...
        RC_L(:, columns), S60, roi_size));
    mixed_roi(:, :, frame_idx) = single(sarvalid.focus_base_rc( ...
        RC_mix(:, columns), S60, roi_size));
end

gt_stats = percentile_stats(gt_roi, LOW_PERCENTILE, HIGH_PERCENTILE, "GT");
h_stats = percentile_stats(h_roi, LOW_PERCENTILE, HIGH_PERCENTILE, "H");
l_stats = percentile_stats(l_roi, LOW_PERCENTILE, HIGH_PERCENTILE, "L");

% F0/F8是纯H帧，使用H统计量；纯L及所有混合帧使用L统计量。
[input_sequence, gt_sequence] = ...
    sarvalid.normalize_range_sft_v3_sequence( ...
    mixed_roi, gt_roi, sequence_mask.h_ratio, ...
    gt_stats, h_stats, l_stats, patch_size);
if ~isequal(size(input_sequence), [patch_size, patch_size, 9]) || ...
        ~isequal(size(gt_sequence), [patch_size, patch_size, 9])
    error('debugRangeSFT:SequenceSizeMismatch', ...
        '最终输入和GT必须均为512×512×9。');
end

%% =========================== 指标计算 ====================================
[frame_metrics, sequence_summary] = sarvalid.sequence_metrics( ...
    input_sequence, gt_sequence, sequence_mask.frames);
HRatio = sequence_mask.h_ratio(:);
FrameMode = repmat("mixed", frame_count, 1);
FrameMode(HRatio == 1) = "high";
FrameMode(HRatio == 0) = "low";
metrics = frame_metrics(:, ["FrameIdx", "PSNR", "SSIM"]);
metrics = addvars(metrics, HRatio, FrameMode, 'After', "FrameIdx");

%% ============================== 保存结果 =================================
timestamp = string(datetime('now', 'Format', 'yyyyMMdd_HHmmss_SSS'));
parameter_tag = "qh" + encode_number(Q_HIGH) + ...
    "_ql" + encode_number(Q_LOW) + "_s" + encode_number(STR_DB) + ...
    "_fr" + encode_number(FR_OVER_BR) + ...
    "_fa" + encode_number(FA_OVER_BA);
run_name = safe_name(scene_name) + "_" + parameter_tag + "_" + timestamp;
run_dir = fullfile(OUTPUT_ROOT, run_name);
input_dir = fullfile(run_dir, "input");
gt_dir = fullfile(run_dir, "gt");
if isfolder(run_dir)
    error('debugRangeSFT:OutputAlreadyExists', ...
        '输出目录已存在，拒绝覆盖：%s', run_dir);
end
sarvalid.ensure_dir(input_dir);
sarvalid.ensure_dir(gt_dir);

for frame_idx = 1:frame_count
    frame_name = sprintf('frame_%d.png', frame_idx - 1);
    imwrite(input_sequence(:, :, frame_idx), fullfile(input_dir, frame_name));
    imwrite(gt_sequence(:, :, frame_idx), fullfile(gt_dir, frame_name));
end
writetable(metrics, fullfile(run_dir, "metrics.csv"));

visibility = "off";
if SHOW_METRIC_FIGURES
    visibility = "on";
end
curve_title = sprintf(['%s | q_H=%.4g, q_L=%.4g | ' ...
    'STR=%.4g dB, f_r/B_r=%.4g, f_a/B_a=%.4g'], ...
    scene_name, Q_HIGH, Q_LOW, STR_DB, FR_OVER_BR, FA_OVER_BA);

psnr_figure = figure('Visible', visibility, 'Color', 'w', ...
    'Position', [100, 100, 900, 560]);
plot(metrics.FrameIdx, metrics.PSNR, '-o', 'LineWidth', 1.8, ...
    'MarkerSize', 7);
grid on; xlim([0, 8]); xticks(0:8);
xlabel('帧序号'); ylabel('PSNR (dB)');
title({curve_title, sprintf('Mean %.3f dB | Worst %.3f dB', ...
    mean(metrics.PSNR), min(metrics.PSNR))}, 'Interpreter', 'none');
exportgraphics(psnr_figure, fullfile(run_dir, "psnr_curve.png"), ...
    'Resolution', 180);

ssim_figure = figure('Visible', visibility, 'Color', 'w', ...
    'Position', [140, 140, 900, 560]);
plot(metrics.FrameIdx, metrics.SSIM, '-o', 'LineWidth', 1.8, ...
    'MarkerSize', 7);
grid on; xlim([0, 8]); xticks(0:8);
xlabel('帧序号'); ylabel('SSIM');
title({curve_title, sprintf('Mean %.4f | Worst %.4f', ...
    mean(metrics.SSIM), min(metrics.SSIM))}, 'Interpreter', 'none');
exportgraphics(ssim_figure, fullfile(run_dir, "ssim_curve.png"), ...
    'Resolution', 180);

sarvalid.save_sequence_contact_sheet( ...
    fullfile(run_dir, "sequence_comparison.png"), ...
    input_sequence, gt_sequence, curve_title);

if ~SHOW_METRIC_FIGURES
    close(psnr_figure);
    close(ssim_figure);
end

%% ============================= 审计信息 ==================================
metadata = struct();
metadata.script = string(mfilename);
metadata.generated_at = timestamp;
metadata.normalization_warning = ...
    "single_sequence_9_frames_not_comparable_to_v3_scene_5x9_pool";
metadata.scene = scene_name;
metadata.echo_file = string(selected_file.name);
metadata.echo_path = echo_path;
metadata.echo_variable = string(variables(1).name);
metadata.c_start = c_start;
metadata.random_seed = RANDOM_SEED;
metadata.file_override = ECHO_FILE_OVERRIDE;
metadata.cstart_override = CSTART_OVERRIDE;
metadata.q_high_nominal = Q_HIGH;
metadata.q_low_nominal = Q_LOW;
metadata.q_high_effective = grid_h.q_total_eff;
metadata.q_low_effective = grid_l.q_total_eff;
metadata.q_range_high_effective = grid_h.q_range_eff;
metadata.q_range_low_effective = grid_l.q_range_eff;
metadata.q_azimuth_high_effective = grid_h.q_azimuth_eff;
metadata.q_azimuth_low_effective = grid_l.q_azimuth_eff;
metadata.STR_dB = STR_DB;
metadata.fr_over_Br = FR_OVER_BR;
metadata.fa_over_Ba = FA_OVER_BA;
metadata.phi0 = PHI0;
metadata.fr_over_Br_limit = fr_limit;
metadata.fa_over_Ba_limit = fa_limit;
metadata.low_percentile = LOW_PERCENTILE;
metadata.high_percentile = HIGH_PERCENTILE;
metadata.gt_stats = gt_stats;
metadata.h_stats = h_stats;
metadata.l_stats = l_stats;
metadata.energy_buffer = ENERGY_BUFFER;
metadata.energy_scale_factor = mix_info.scale_factor;
metadata.energy_alignment = mix_info;
metadata.threshold_meta_H = meta_h.threshold;
metadata.threshold_meta_L = meta_l.threshold;
metadata.sequence_summary = sequence_summary;
metadata.output_directory = run_dir;
save(fullfile(run_dir, "metadata.mat"), "metadata");

fprintf('\nRange+2D-SFT单序列生成完成。\n');
fprintf('  场景：%s\n', scene_name);
fprintf('  轨迹：%s\n', selected_file.name);
fprintf('  CStart：%d / 最大%d\n', c_start, max_start);
fprintf('  有效倍率：H=%.12g，L=%.12g\n', ...
    grid_h.q_total_eff, grid_l.q_total_eff);
fprintf('  Nyquist上限：fr/Br < %.12g，fa/Ba < %.12g\n', ...
    fr_limit, fa_limit);
fprintf('  分位数 GT=[%.6g, %.6g]，H=[%.6g, %.6g]，L=[%.6g, %.6g]\n', ...
    gt_stats.VMin, gt_stats.VMax, h_stats.VMin, h_stats.VMax, ...
    l_stats.VMin, l_stats.VMax);
fprintf('  H到L能量缩放 gamma=%.12g，边界跳变=%.6g dB\n', ...
    mix_info.scale_factor, mix_info.boundary_jump_db);
fprintf('  PSNR：Mean=%.4f dB，Worst=%.4f dB\n', ...
    mean(metrics.PSNR), min(metrics.PSNR));
fprintf('  SSIM：Mean=%.6f，Worst=%.6f\n', ...
    mean(metrics.SSIM), min(metrics.SSIM));
fprintf('  输出：%s\n\n', run_dir);

%% ============================ 本地函数 ===================================
function scene_name = resolve_scene_name(requested, dataset_names)
% 支持完整数据集名称或去掉SAR_Dataset_前缀后的短名称。
requested = string(requested);
dataset_names = string(dataset_names(:));
exact = strcmpi(dataset_names, requested);
short = strcmpi(erase(dataset_names, "SAR_Dataset_"), requested);
matches = exact | short;
if sum(matches) ~= 1
    error('debugRangeSFT:UnknownScene', ...
        '场景%s无法唯一匹配。可选场景：%s', ...
        requested, strjoin(dataset_names, ', '));
end
scene_name = dataset_names(matches);
end

function valid_files = filter_valid_echo_files(files, S60, block_width)
% 只保留距离维可抽取1200行、方位维可截取完整连续块的MAT文件。
keep = false(numel(files), 1);
for idx = 1:numel(files)
    file_path = fullfile(files(idx).folder, files(idx).name);
    variables = whos('-file', file_path);
    if isempty(variables) || numel(variables(1).size) < 2
        continue;
    end
    raw_rows = variables(1).size(1);
    raw_columns = variables(1).size(2);
    rows_after_60mhz = numel(1:3:raw_rows);
    keep(idx) = rows_after_60mhz >= S60.nrn && raw_columns >= block_width;
end
valid_files = files(keep);
end

function stats = percentile_stats(values, low_percentile, high_percentile, label)
% 对当前单序列9张600×600幅度图构造一个像素池。
limits = prctile(values(:), [low_percentile, high_percentile]);
stats = struct("VMin", double(limits(1)), "VMax", double(limits(2)), ...
    "Modality", string(label), "ImageCount", size(values, 3), ...
    "PixelCount", numel(values), "LowPercentile", low_percentile, ...
    "HighPercentile", high_percentile);
if ~isfinite(stats.VMin) || ~isfinite(stats.VMax) || ...
        stats.VMax <= stats.VMin
    error('debugRangeSFT:DegenerateNormalization', ...
        '%s分位数归一化范围无效：[%.12g, %.12g]。', ...
        label, stats.VMin, stats.VMax);
end
end

function bandwidth = resolve_azimuth_bandwidth(S60)
if isfield(S60, 'Ba')
    bandwidth = S60.Ba;
elseif isfield(S60, 'Bd')
    bandwidth = S60.Bd;
elseif isfield(S60, 'Da')
    bandwidth = 2 * S60.v / S60.Da;
else
    error('debugRangeSFT:MissingAzimuthBandwidth', ...
        'FS60参数必须包含Ba、Bd或Da。');
end
end

function output = encode_number(value)
output = replace(string(sprintf('%.12g', value)), "-", "m");
output = replace(output, ".", "p");
output = replace(output, "+", "");
end

function output = safe_name(input)
output = regexprep(string(input), '[^A-Za-z0-9_-]+', '_');
end
