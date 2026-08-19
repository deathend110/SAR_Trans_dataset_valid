clear; clc;

%% ========================================================================
% Range+2D-SFT 场景级分位数统计
%
% 本脚本只统计未经归一化的幅度图分位数，不生成PNG或评价指标。
% 每个rstart文件均匀抽取10条H-L-H序列；同一参数下，H分支先按
% RC边界能量缩放，再与L分支的纯分支成像结果等权汇总为JointHL。
%
% 直接运行本脚本即开始正式统计。长时间任务按“场景+参数+序列”
% 自动保存checkpoint，中断后使用相同配置重新运行即可继续。
%% ========================================================================

%% ============================== 参数区 ==================================
PARAMETERS = table( ...
    [4; 2.5], ...          % QHigh
    [2; 1.5], ...          % QLow
    [-1; 1], ...           % STRdB
    [1.3; 0.9], ...        % FrOverBr
    [0.5; 0.5], ...        % FaOverBa
    [0; 0], ...            % Phi0，单位rad
    'VariableNames', [ ...
    "QHigh", "QLow", "STRdB", "FrOverBr", "FaOverBa", "Phi0"]);

BLOCKS_PER_FILE = 10;
LOW_PERCENTILE = 0.99;
HIGH_PERCENTILE = 99.9;
ROI_SIZE = 600;
ENERGY_BUFFER = 64;

%% ========================== 仓库与公共配置 ===============================
SCRIPT_PATH = string(mfilename('fullpath'));
REPO_ROOT = string(fileparts(SCRIPT_PATH));
addpath(REPO_ROOT);

cfg = struct();
cfg.data_root = "G:\MATLAB-G\SAR Full PSF";
cfg.dataset_names = [ ...
    "SAR_Dataset_Bangkok_1", "SAR_Dataset_city1_histeq", ...
    "SAR_Dataset_city2_histeq", "SAR_Dataset_SAR_figure", ...
    "SAR_Dataset_filed", "SAR_Dataset_port", "SAR_Dataset_suburb"];
cfg.parameter_file_60 = fullfile(REPO_ROOT, "FS60_params.mat");
cfg.nyquist_margin = 0.98;
cfg.sequence = struct( ...
    "n_frames", 9, "step", 128, ...
    "signal_height", 1200, "signal_width", 1200, ...
    "patch_size", 512, "roi_size", 600, ...
    "valid_margin", 344, "logic_length", 1536, ...
    "block_width", 2224);
S60 = load(cfg.parameter_file_60);
OUTPUT_ROOT = fullfile(REPO_ROOT, ...
    "results_range_2dsft_scene_percentiles");
WORK_ROOT = fullfile(OUTPUT_ROOT, "_work");

protocol = build_protocol(cfg, S60, BLOCKS_PER_FILE, ...
    LOW_PERCENTILE, HIGH_PERCENTILE, ROI_SIZE, ENERGY_BUFFER);
validate_parameters(PARAMETERS, cfg, S60, protocol);
manifest = build_scene_manifest(cfg, BLOCKS_PER_FILE);
parameter_keys = build_parameter_keys(PARAMETERS, protocol);

fprintf('场景级分位数清单：%d个场景，%d个文件，%d条序列。\n', ...
    numel(unique(manifest.Scene)), ...
    numel(unique(manifest.FilePath)), height(manifest));
for parameter_idx = 1:height(PARAMETERS)
    fprintf('  参数%d：%s\n', parameter_idx, parameter_keys(parameter_idx));
end
print_scene_counts(manifest);

ensure_directory(OUTPUT_ROOT);
ensure_directory(WORK_ROOT);
scenes = unique(string(manifest.Scene), 'stable');

%% ========================== 场景与参数循环 ===============================
for scene_idx = 1:numel(scenes)
    scene = scenes(scene_idx);
    scene_manifest = manifest(string(manifest.Scene) == scene, :);
    scene_key = string(scene_manifest.SceneKey(1));
    output_path = fullfile(OUTPUT_ROOT, scene_key + ".mat");
    header = struct( ...
        "schema_version", "range_2dsft_scene_percentiles_v2", ...
        "scene_name", scene, ...
        "scene_key", scene_key, ...
        "protocol", protocol, ...
        "source_manifest", scene_manifest);
    gt_stats = load_existing_gt(output_path, header);

    fprintf('\n[%d/%d] 场景%s：%d个文件，%d条序列。\n', ...
        scene_idx, numel(scenes), scene, ...
        numel(unique(scene_manifest.FilePath)), height(scene_manifest));

    for parameter_idx = 1:height(PARAMETERS)
        parameter_row = PARAMETERS(parameter_idx, :);
        parameters = parameter_struct(parameter_row);
        parameter_key = parameter_keys(parameter_idx);
        pair = make_range_sft_pair(parameters);
        [grid_h, grid_l] = resolve_pair_grids(pair, cfg, S60);
        need_gt = isempty(fieldnames(gt_stats));
        work_directory = fullfile(WORK_ROOT, scene_key, parameter_key);

        fprintf('  [%d/%d] %s\n', ...
            parameter_idx, height(PARAMETERS), parameter_key);
        if scene_entry_exists(output_path, parameter_key)
            remove_completed_work_directory(work_directory, WORK_ROOT);
            fprintf('    该参数已有完整统计，跳过。\n');
            continue;
        end
        result = process_scene_parameter( ...
            cfg, S60, scene_manifest, pair, parameters, protocol, ...
            work_directory, need_gt);
        if need_gt
            gt_stats = result.gt_stats;
        end

        entry = struct( ...
            "parameter_key", parameter_key, ...
            "parameters", parameters, ...
            "effective_sampling", struct("H", grid_h, "L", grid_l), ...
            "input_stats", result.input_stats, ...
            "audit", result.audit, ...
            "created_at", "", ...
            "updated_at", "");
        upsert_scene_stats( ...
            output_path, header, gt_stats, entry);
        remove_completed_work_directory(work_directory, WORK_ROOT);
        fprintf('    已更新%s。\n', output_path);
    end
end

fprintf('\n全部场景和参数统计完成：%s\n', OUTPUT_ROOT);

%% ============================== 本地函数 =================================
function protocol = build_protocol(cfg, S60, blocks_per_file, ...
        low_percentile, high_percentile, roi_size, energy_buffer)
protocol = struct( ...
    "method", "Range_2D_SFT", ...
    "working_echo", "60MHz_from_180MHz_stride3", ...
    "parameter_file_60", string(cfg.parameter_file_60), ...
    "low_percentile", low_percentile, ...
    "high_percentile", high_percentile, ...
    "percentile_method", "midpoint_exact_tall", ...
    "roi_size", roi_size, ...
    "blocks_per_file", blocks_per_file, ...
    "block_sampling", "round(linspace(1,max_start,blocks_per_file))", ...
    "energy_buffer", energy_buffer, ...
    "joint_pool", "equal_pixels_H_aligned_and_L_all_9_frames", ...
    "mixed_pixels_in_pool", false, ...
    "sequence", cfg.sequence, ...
    "imaging", imaging_parameters(S60));
end

function validate_parameters(parameters, cfg, S60, protocol)
expected = ["QHigh", "QLow", "STRdB", ...
    "FrOverBr", "FaOverBa", "Phi0"];
if ~isequal(string(parameters.Properties.VariableNames), expected)
    error('scenePercentiles:ParameterSchema', ...
        'PARAMETERS变量名和顺序必须为：%s。', strjoin(expected, ', '));
end
if isempty(parameters)
    error('scenePercentiles:ParametersEmpty', ...
        'PARAMETERS至少需要一行。');
end

values = parameters{:, expected};
if ~isnumeric(values) || any(~isfinite(values), 'all')
    error('scenePercentiles:ParameterValues', ...
        'PARAMETERS必须全部为有限数值。');
end
if any(parameters.QHigh <= parameters.QLow) || ...
        any(parameters.QLow < 1) || ...
        any(parameters.FrOverBr < 0) || any(parameters.FaOverBa < 0)
    error('scenePercentiles:ParameterRanges', ...
        '必须满足QHigh>QLow>=1，且fr/Br、fa/Ba非负。');
end
if protocol.low_percentile < 0 || protocol.high_percentile > 100 || ...
        protocol.low_percentile >= protocol.high_percentile
    error('scenePercentiles:PercentileRange', ...
        '分位数必须满足0<=low<high<=100。');
end
if protocol.roi_size > cfg.sequence.roi_size
    error('scenePercentiles:ROISize', ...
        '统计ROI不能超过现有成像ROI尺寸%d。', cfg.sequence.roi_size);
end

keys = strings(height(parameters), 1);
for idx = 1:height(parameters)
    value = parameter_struct(parameters(idx, :));
    pair = make_range_sft_pair(value);
    resolve_pair_grids(pair, cfg, S60);
    keys(idx) = make_parameter_key(value, protocol);
end
if numel(unique(keys)) ~= numel(keys)
    error('scenePercentiles:DuplicateParameters', ...
        'PARAMETERS中存在重复的完整参数行。');
end
end

function keys = build_parameter_keys(parameters, protocol)
keys = strings(height(parameters), 1);
for idx = 1:height(parameters)
    keys(idx) = make_parameter_key( ...
        parameter_struct(parameters(idx, :)), protocol);
end
end

function parameters = parameter_struct(row)
parameters = struct( ...
    "Method", "Range_2D_SFT", ...
    "QHigh", double(row.QHigh), ...
    "QLow", double(row.QLow), ...
    "STRdB", double(row.STRdB), ...
    "FrOverBr", double(row.FrOverBr), ...
    "FaOverBa", double(row.FaOverBa), ...
    "Phi0", double(row.Phi0));
end

function pair = make_range_sft_pair(parameters)
threshold = struct( ...
    "STR_dB", parameters.STRdB, ...
    "fr_over_Br", parameters.FrOverBr, ...
    "fa_over_Ba", parameters.FaOverBa, ...
    "phi0", parameters.Phi0);
base = struct("method", "Range_2D_SFT", ...
    "threshold", threshold, "time_origin", "block_global");
pair = struct("method", "Range_2D_SFT", ...
    "q_high", parameters.QHigh, "q_low", parameters.QLow, ...
    "H", base, "L", base);
pair.H.q_total = parameters.QHigh;
pair.L.q_total = parameters.QLow;
end

function [grid_h, grid_l] = resolve_pair_grids(pair, cfg, S60)
input_size = [cfg.sequence.signal_height, cfg.sequence.block_width];
grid_h = resolve_range_grid(pair.H.q_total, input_size, S60);
grid_l = resolve_range_grid(pair.L.q_total, input_size, S60);
azimuth_bandwidth = resolve_azimuth_bandwidth(S60);
fr_limit = cfg.nyquist_margin * ...
    min(grid_h.Fs_up, grid_l.Fs_up) / (2 * S60.B);
fa_limit = cfg.nyquist_margin * ...
    min(grid_h.PRF_up, grid_l.PRF_up) / (2 * azimuth_bandwidth);
fr = pair.H.threshold.fr_over_Br;
fa = pair.H.threshold.fa_over_Ba;
if fr >= fr_limit || fa >= fa_limit
    error('scenePercentiles:SFTNyquistViolation', ...
        ['SFT频率必须满足fr/Br<%.12g、fa/Ba<%.12g；' ...
        '当前为%.12g、%.12g。'], fr_limit, fa_limit, fr, fa);
end
end

function bandwidth = resolve_azimuth_bandwidth(S60)
if isfield(S60, "Ba")
    bandwidth = S60.Ba;
elseif isfield(S60, "Bd")
    bandwidth = S60.Bd;
elseif isfield(S60, "Da")
    bandwidth = 2 * S60.v / S60.Da;
else
    error('scenePercentiles:MissingAzimuthBandwidth', ...
        'FS60参数必须包含Ba、Bd或Da。');
end
end

function grid = resolve_range_grid(q_range, input_size, S60)
% 小数倍率先映射到整数尺寸，再由实际尺寸计算有效采样率。
if q_range < 1 || ~isfinite(q_range)
    error('scenePercentiles:InvalidSamplingFactor', ...
        '距离向采样倍率必须是不小于1的有限数。');
end
nr_up = round(q_range * input_size(1));
q_range_eff = nr_up / input_size(1);
grid = struct( ...
    "q_range", q_range, ...
    "q_azimuth", 1, ...
    "q_range_eff", q_range_eff, ...
    "q_azimuth_eff", 1, ...
    "q_total_eff", q_range_eff, ...
    "input_size", input_size, ...
    "upsampled_size", [nr_up, input_size(2)], ...
    "Fs_up", q_range_eff * S60.Fs, ...
    "PRF_up", S60.prf);
end

function RC_base = generate_range_2dsft_rc(signal, S60, acquisition)
% 距离向FFT带限上采样、2D-SFT阈值、1-bit量化和距离压缩。
grid = resolve_range_grid(acquisition.q_total, size(signal), S60);
signal_up = upsample_range_fft(signal, grid.upsampled_size(1));
threshold = build_2dsft_threshold(signal_up, grid, ...
    acquisition.threshold, S60);
channel_1bit = quantize_1bit(signal_up, threshold);

tnrn_up = 2 * S60.R0 / S60.C + ...
    ((0:size(signal_up, 1)-1).' - floor(size(signal_up, 1) / 2)) ...
    / grid.Fs_up;
RC_up = Range_Compress(channel_1bit, S60.fc, tnrn_up, S60.gama, ...
    S60.R0, S60.C, grid.Fs_up, S60.Tp);
RC_base = crop_range_spectrum(RC_up, size(signal, 1));
if ~isequal(size(RC_base), size(signal))
    error('scenePercentiles:BaseRCSize', ...
        '距离压缩结果无法投影回60MHz基网格。');
end
end

function signal_up = upsample_range_fft(signal, target_rows)
% 在距离频谱中心补零，保持带限插值后的幅度尺度。
current_rows = size(signal, 1);
if target_rows < current_rows
    error('scenePercentiles:UpsampleSize', ...
        '上采样目标行数不能小于输入行数。');
elseif target_rows == current_rows
    signal_up = signal;
    return;
end
spectrum = fftshift(fft(signal, [], 1), 1);
pad_total = target_rows - current_rows;
pad_top = floor(pad_total / 2);
pad_bottom = pad_total - pad_top;
spectrum_up = [ ...
    zeros(pad_top, size(signal, 2), 'like', spectrum); ...
    spectrum; ...
    zeros(pad_bottom, size(signal, 2), 'like', spectrum)];
signal_up = ifft(ifftshift(spectrum_up, 1), [], 1) ...
    * (target_rows / current_rows);
end

function threshold = build_2dsft_threshold(signal_up, grid, parameters, S60)
% 二维单频阈值：距离与方位相位相加后取复指数。
sigma_hat = sqrt(2 / pi) * mean(abs(signal_up(:)));
amplitude = sigma_hat / (10 ^ (parameters.STR_dB / 20));
fr_hz = parameters.fr_over_Br * S60.B;
fa_hz = parameters.fa_over_Ba * resolve_azimuth_bandwidth(S60);

fast_time = ((0:size(signal_up, 1)-1).' ...
    - floor(size(signal_up, 1) / 2)) / grid.Fs_up;
slow_time = ((0:size(signal_up, 2)-1) ...
    - floor(size(signal_up, 2) / 2)) / grid.PRF_up;
phase_range = 2 * pi * fr_hz * fast_time;
phase_azimuth = 2 * pi * fa_hz * slow_time;
threshold = amplitude * exp(1i * ...
    (phase_range + phase_azimuth + parameters.phi0));
end

function output = quantize_1bit(signal, threshold)
% 对复回波实部和虚部分别执行带阈值的符号量化。
if ~isequal(size(signal), size(threshold))
    error('scenePercentiles:ThresholdSize', ...
        '回波和2D-SFT阈值尺寸不一致。');
end
real_part = ones(size(signal), 'like', real(signal));
imag_part = ones(size(signal), 'like', real(signal));
real_part(real(signal) + real(threshold) < 0) = -1;
imag_part(imag(signal) + imag(threshold) < 0) = -1;
output = complex(real_part, imag_part);
end

function output = crop_range_spectrum(input, target_rows)
% 距离压缩后裁剪中心频谱，返回FS60基网格。
current_rows = size(input, 1);
if target_rows > current_rows
    error('scenePercentiles:CropSize', ...
        '频谱裁剪目标不能大于当前距离维。');
elseif target_rows == current_rows
    output = input;
    return;
end
spectrum = fftshift(fft(input, [], 1), 1);
center = floor(current_rows / 2) + 1;
half_width = floor(target_rows / 2);
if mod(target_rows, 2) == 0
    indices = center-half_width:center+half_width-1;
else
    indices = center-half_width:center+half_width;
end
spectrum = spectrum(indices, :);
output = ifft(ifftshift(spectrum, 1), [], 1);
end

function mask = build_hlh_mask(sequence)
% 有效区固定为H(512)-L(512)-H(512)，两端扩展344列成完整RC掩膜。
logic_mask = false(1, sequence.logic_length);
logic_mask(1:512) = true;
logic_mask(1025:1536) = true;
full_mask = [ ...
    repmat(logic_mask(1), 1, sequence.valid_margin), ...
    logic_mask, ...
    repmat(logic_mask(end), 1, sequence.valid_margin)];
if numel(full_mask) ~= sequence.block_width
    error('scenePercentiles:HLHMaskLength', ...
        'H-L-H完整掩膜长度与连续回波块不一致。');
end
mask = struct("logic", logic_mask, "full", full_mask, ...
    "boundaries", find(diff(full_mask) ~= 0));
end

function signal60 = load_echo_block(manifest_row, S60, block_width)
% 从180MHz轨迹裁出连续块，再按1:3抽取为60MHz复回波。
persistent cached_path cached_raw
file_path = string(manifest_row.FilePath(1));
if isempty(cached_path) || cached_path ~= file_path
    variable_name = char(manifest_row.EchoVariable(1));
    loaded = load(file_path, variable_name);
    if ~isfield(loaded, variable_name)
        error('scenePercentiles:EchoVariableMissing', ...
            '回波文件缺少变量%s：%s', variable_name, file_path);
    end
    cached_raw = loaded.(variable_name);
    cached_path = file_path;
end
start_index = manifest_row.CStart(1);
stop_index = start_index + block_width - 1;
if stop_index > size(cached_raw, 2)
    error('scenePercentiles:EchoBlockRange', ...
        '轨迹%s无法裁出指定连续块。', file_path);
end
signal60 = cached_raw(1:3:end, start_index:stop_index);
if size(signal60, 1) < S60.nrn
    error('scenePercentiles:EchoRows', ...
        '降至60MHz后的距离维长度不足。');
end
signal60 = signal60(1:S60.nrn, :);
end

function [RC_mix, info] = align_and_mix_rc(RC_H, RC_L, mode_mask, buffer)
% 汇总两个边界的局部功率，用一个gamma将完整H分支对齐到L分支。
if ~isequal(size(RC_H), size(RC_L))
    error('scenePercentiles:RCSizeMismatch', 'H/L RC尺寸不一致。');
end
mode_mask = logical(mode_mask(:).');
if numel(mode_mask) ~= size(RC_H, 2)
    error('scenePercentiles:RCMaskLength', ...
        'H-L-H掩膜长度必须等于RC列数。');
end
boundaries = find(diff(mode_mask) ~= 0);
if numel(boundaries) ~= 2
    error('scenePercentiles:RCBoundaryCount', ...
        'H-L-H连续块必须包含两个边界。');
end

power_h = zeros(numel(boundaries), 1);
power_l = zeros(numel(boundaries), 1);
for idx = 1:numel(boundaries)
    boundary = boundaries(idx);
    left = max(1, boundary-buffer+1):boundary;
    right = boundary+1:min(size(RC_H, 2), boundary+buffer);
    if mode_mask(boundary)
        h_indices = left;
        l_indices = right;
    else
        l_indices = left;
        h_indices = right;
    end
    power_h(idx) = mean(abs(RC_H(:, h_indices)).^2, 'all');
    power_l(idx) = mean(abs(RC_L(:, l_indices)).^2, 'all');
end
pooled_h = mean(power_h);
pooled_l = mean(power_l);
if pooled_h <= 1e-12
    scale_factor = 1;
else
    scale_factor = sqrt((pooled_l + eps) / (pooled_h + eps));
end
RC_H_aligned = RC_H * scale_factor;
RC_mix = zeros(size(RC_H), 'like', RC_H);
RC_mix(:, mode_mask) = RC_H_aligned(:, mode_mask);
RC_mix(:, ~mode_mask) = RC_L(:, ~mode_mask);
info = struct( ...
    "boundaries", boundaries, ...
    "scale_factor", scale_factor, ...
    "power_H", pooled_h, ...
    "power_L", pooled_l, ...
    "boundary_jump_db", 10 * log10( ...
    (pooled_h * scale_factor ^ 2 + eps) / (pooled_l + eps)));
end

function image_roi = focus_base_rc(RC_base, S60, roi_size)
% 使用允许调用的RCMC和SAR_Imaging完成成像并提取中心幅度ROI。
if ~isequal(size(RC_base), [S60.nrn, S60.nan])
    error('scenePercentiles:FocusRCSize', ...
        '成像RC必须位于FS60基网格。');
end
RCMC_out = RCMC(RC_base, S60.lambda, S60.fnrn, S60.fnan, ...
    S60.R0, S60.C, S60.v);
image_complex = SAR_Imaging(RCMC_out, S60.lambda, S60.Fs, ...
    S60.R0, S60.C, S60.v, S60.tnan, S60.Ta, S60.prf);
row_start = S60.nrn / 2 - S60.R_total / 2 + 1;
row_end = S60.nrn / 2 + S60.R_total / 2;
column_start = S60.nan / 2 - S60.A_num / 2;
column_end = S60.nan / 2 + S60.A_num / 2 - 1;
full_roi = abs(image_complex(row_start:row_end, ...
    column_start:column_end));
image_roi = crop_center(full_roi, roi_size);
end

function image_roi = generate_gt_image(signal, S60, roi_size)
% 未量化60MHz复回波的标准成像结果，作为GT分位数像素来源。
RC_gt = Range_Compress(signal, S60.fc, S60.tnrn, S60.gama, ...
    S60.R0, S60.C, S60.Fs, S60.Tp);
image_roi = focus_base_rc(RC_gt, S60, roi_size);
end

function output = crop_center(input, target_size)
row_start = floor((size(input, 1) - target_size) / 2) + 1;
column_start = floor((size(input, 2) - target_size) / 2) + 1;
if row_start < 1 || column_start < 1
    error('scenePercentiles:CropCenterSize', ...
        '中心裁剪尺寸超过输入图像。');
end
output = input(row_start:row_start+target_size-1, ...
    column_start:column_start+target_size-1);
end

function result = process_scene_parameter(cfg, S60, scene_manifest, ...
        pair, parameters, protocol, work_directory, need_gt)
joint_directory = fullfile(work_directory, "joint");
gt_directory = fullfile(work_directory, "gt");
checkpoint_path = fullfile(work_directory, "checkpoint.mat");
ensure_directory(joint_directory);
if need_gt
    ensure_directory(gt_directory);
end

checkpoint_config = struct( ...
    "version", "range_2dsft_scene_percentiles_checkpoint_v2", ...
    "scene", string(scene_manifest.Scene(1)), ...
    "manifest", scene_manifest, ...
    "parameters", parameters, ...
    "protocol", protocol, ...
    "include_gt", need_gt);
sequence_count = height(scene_manifest);
initial_state = struct( ...
    "config", checkpoint_config, ...
    "completed_sequences", 0, ...
    "scale_factors", nan(sequence_count, 1), ...
    "boundary_jump_db", nan(sequence_count, 1));
state = load_checkpoint(checkpoint_path, checkpoint_config, initial_state);
verify_completed_chunks( ...
    state.completed_sequences, joint_directory, gt_directory, need_gt);

frame_count = cfg.sequence.n_frames;
pixels_per_image = protocol.roi_size ^ 2;
mask = build_hlh_mask(cfg.sequence);
for sequence_idx = state.completed_sequences + 1:sequence_count
    signal = load_echo_block( ...
        scene_manifest(sequence_idx, :), S60, cfg.sequence.block_width);
    if isreal(signal) || ~isequal(size(signal), ...
            [cfg.sequence.signal_height, cfg.sequence.block_width])
        error('scenePercentiles:InvalidEchoBlock', ...
            '序列%d的60MHz复回波尺寸不正确。', ...
            scene_manifest.SequenceID(sequence_idx));
    end

    RC_H = generate_range_2dsft_rc(signal, S60, pair.H);
    RC_L = generate_range_2dsft_rc(signal, S60, pair.L);
    [~, mix_info] = align_and_mix_rc( ...
        RC_H, RC_L, mask.full, protocol.energy_buffer);
    RC_H = RC_H * mix_info.scale_factor;

    joint_values = zeros(2 * pixels_per_image * frame_count, 1, 'single');
    if need_gt
        gt_values = zeros(pixels_per_image * frame_count, 1, 'single');
    end
    for frame_idx = 1:frame_count
        columns = frame_columns(cfg.sequence, frame_idx);
        h_image = focus_base_rc( ...
            RC_H(:, columns), S60, protocol.roi_size);
        l_image = focus_base_rc( ...
            RC_L(:, columns), S60, protocol.roi_size);
        frame_pool = make_joint_hl_pool(h_image, l_image);
        joint_start = (frame_idx - 1) * 2 * pixels_per_image + 1;
        joint_stop = frame_idx * 2 * pixels_per_image;
        joint_values(joint_start:joint_stop) = frame_pool;

        if need_gt
            gt_image = generate_gt_image( ...
                signal(:, columns), S60, protocol.roi_size);
            gt_start = (frame_idx - 1) * pixels_per_image + 1;
            gt_stop = frame_idx * pixels_per_image;
            gt_values(gt_start:gt_stop) = single(gt_image(:));
        end
    end

    chunk_name = sprintf('chunk_%06d.mat', sequence_idx);
    atomic_save(fullfile(joint_directory, chunk_name), ...
        struct("values", joint_values));
    if need_gt
        atomic_save(fullfile(gt_directory, chunk_name), ...
            struct("values", gt_values));
    end
    state.completed_sequences = sequence_idx;
    state.scale_factors(sequence_idx) = mix_info.scale_factor;
    state.boundary_jump_db(sequence_idx) = mix_info.boundary_jump_db;
    atomic_save(checkpoint_path, struct("state", state));
    fprintf('    序列 %d/%d 完成。\n', sequence_idx, sequence_count);
end

percentages = [protocol.low_percentile, protocol.high_percentile];
input_stats = calculate_chunk_percentiles( ...
    joint_directory, percentages, "JointHL", ...
    2 * sequence_count * frame_count);

if need_gt
    gt_stats = calculate_chunk_percentiles( ...
        gt_directory, percentages, "GT", sequence_count * frame_count);
else
    gt_stats = struct();
end

audit = struct( ...
    "SequenceCount", sequence_count, ...
    "FileCount", numel(unique(scene_manifest.FilePath)), ...
    "BlocksPerFile", protocol.blocks_per_file, ...
    "ScaleFactorMin", min(state.scale_factors), ...
    "ScaleFactorMean", mean(state.scale_factors), ...
    "ScaleFactorMax", max(state.scale_factors), ...
    "MaxAbsBoundaryJumpDB", max(abs(state.boundary_jump_db)), ...
    "CompletedSequences", state.completed_sequences);
if any(~isfinite([audit.ScaleFactorMin, audit.ScaleFactorMean, ...
        audit.ScaleFactorMax, audit.MaxAbsBoundaryJumpDB]))
    error('scenePercentiles:NonfiniteAudit', ...
        '场景统计审计量中存在非有限值。');
end
result = struct("input_stats", input_stats, ...
    "gt_stats", gt_stats, "audit", audit);
end

function columns = frame_columns(sequence_cfg, frame_idx)
start_idx = 1 + (frame_idx - 1) * sequence_cfg.step;
columns = start_idx:start_idx + sequence_cfg.signal_width - 1;
end

function verify_completed_chunks(completed, joint_dir, gt_dir, need_gt)
for idx = 1:completed
    name = sprintf('chunk_%06d.mat', idx);
    if ~isfile(fullfile(joint_dir, name)) || ...
            (need_gt && ~isfile(fullfile(gt_dir, name)))
        error('scenePercentiles:CheckpointChunkMissing', ...
            'checkpoint声明完成的chunk缺失：%s', name);
    end
end
end

function gt_stats = load_existing_gt(file_path, header)
gt_stats = struct();
if ~isfile(file_path)
    return;
end
loaded = load(file_path, 'scene_stats');
if ~isfield(loaded, 'scene_stats')
    error('scenePercentiles:SceneFileSchema', ...
        '已有MAT缺少scene_stats：%s', file_path);
end
existing = loaded.scene_stats;
required = ["schema_version", "scene_name", "scene_key", ...
    "protocol", "source_manifest", "gt"];
if ~all(isfield(existing, required)) || ...
        string(existing.schema_version) ~= string(header.schema_version) || ...
        string(existing.scene_name) ~= string(header.scene_name) || ...
        string(existing.scene_key) ~= string(header.scene_key) || ...
        ~isequaln(existing.protocol, header.protocol) || ...
        ~isequaln(existing.source_manifest, header.source_manifest)
    error('scenePercentiles:SceneSourceMismatch', ...
        '已有场景MAT与当前数据或协议不一致：%s', file_path);
end
gt_stats = existing.gt;
end

function exists = scene_entry_exists(file_path, parameter_key)
% 已写入场景MAT的参数不重复成像；残留work目录可安全清理。
exists = false;
if ~isfile(file_path)
    return;
end
loaded = load(file_path, 'scene_stats');
if ~isfield(loaded, 'scene_stats') || ...
        ~isfield(loaded.scene_stats, 'entries') || ...
        isempty(loaded.scene_stats.entries)
    return;
end
keys = string({loaded.scene_stats.entries.parameter_key});
exists = any(keys == string(parameter_key));
end

function value = imaging_parameters(S60)
names = ["fc", "B", "Fs", "prf", "R0", "C", "v", ...
    "Tp", "Ta", "nrn", "nan", "R_total", "A_num"];
value = struct();
for name = names
    if isfield(S60, name)
        value.(name) = S60.(name);
    end
end
end

function manifest = build_scene_manifest(cfg, blocks_per_file)
% 枚举场景中的全部rstart文件，并在每个文件内均匀选取连续块。
manifest = table();
sequence_id = 0;
for scene_idx = 1:numel(cfg.dataset_names)
    scene = string(cfg.dataset_names(scene_idx));
    scene_directory = fullfile(string(cfg.data_root), scene);
    if ~isfolder(scene_directory)
        error('scenePercentiles:SceneDirectoryMissing', ...
            '场景目录不存在：%s', scene_directory);
    end

    files = sort_echo_files(dir(fullfile(scene_directory, "rstart*.mat")));
    if isempty(files)
        error('scenePercentiles:EchoFilesMissing', ...
            '场景%s中没有rstart*.mat。', scene);
    end
    scene_key = make_scene_key(scene);

    for file_idx = 1:numel(files)
        file = files(file_idx);
        file_path = string(fullfile(file.folder, file.name));
        variables = whos('-file', file_path);
        if isempty(variables) || numel(variables(1).size) ~= 2
            error('scenePercentiles:EchoSchema', ...
                '回波文件缺少二维变量：%s', file_path);
        end
        raw_width = variables(1).size(2);
        max_start = raw_width - cfg.sequence.block_width + 1;
        if max_start < blocks_per_file
            error('scenePercentiles:EchoTooShort', ...
                '文件%s无法抽取%d个宽度为%d的不同连续块。', ...
                file.name, blocks_per_file, cfg.sequence.block_width);
        end
        starts = unique(round(linspace(1, max_start, blocks_per_file)), ...
            'stable');
        if numel(starts) ~= blocks_per_file
            error('scenePercentiles:StartsNotUnique', ...
                '文件%s无法得到%d个不同的均匀起点。', ...
                file.name, blocks_per_file);
        end

        for block_idx = 1:blocks_per_file
            sequence_id = sequence_id + 1;
            SequenceID = sequence_id;
            SceneIdx = scene_idx;
            Scene = scene;
            SceneKey = scene_key;
            FileIdx = file_idx;
            File = string(file.name);
            FilePath = file_path;
            EchoVariable = string(variables(1).name);
            CStart = starts(block_idx);
            BlockWidth = cfg.sequence.block_width;
            RawWidth = raw_width;
            BlockIndex = block_idx;
            FileBytes = double(file.bytes);
            FileDatenum = double(file.datenum);
            row = table(SequenceID, SceneIdx, Scene, SceneKey, FileIdx, ...
                File, FilePath, EchoVariable, CStart, BlockWidth, RawWidth, ...
                BlockIndex, FileBytes, FileDatenum);
            manifest = append_table(manifest, row);
        end
    end
end
end

function files = sort_echo_files(files)
% 优先按rstart后的数字排序，无法解析的文件再按名称排序。
numbers = inf(numel(files), 1);
for idx = 1:numel(files)
    token = regexp(files(idx).name, ...
        '^rstart\s*([0-9]+)\.mat$', 'tokens', 'once', 'ignorecase');
    if ~isempty(token)
        numbers(idx) = str2double(token{1});
    end
end
names = lower(string({files.name})).';
order = table(numbers, names, (1:numel(files)).', ...
    'VariableNames', ["Number", "Name", "OriginalIndex"]);
order = sortrows(order, ["Number", "Name"]);
files = files(order.OriginalIndex);
end

function key = make_scene_key(scene_name)
% 将已知场景名转换为稳定、可读的输出文件名。
known_names = ["SAR_Dataset_Bangkok_1", "SAR_Dataset_city1_histeq", ...
    "SAR_Dataset_city2_histeq", "SAR_Dataset_SAR_figure", ...
    "SAR_Dataset_filed", "SAR_Dataset_port", "SAR_Dataset_suburb"];
known_keys = ["bangkok", "city1_histeq", "city2_histeq", ...
    "sar_figure", "filed", "port", "suburb"];
index = find(strcmpi(string(scene_name), known_names), 1);
if ~isempty(index)
    key = known_keys(index);
    return;
end
key = lower(regexprep(string(scene_name), '^SAR_Dataset_', ''));
key = strip(regexprep(key, '[^a-z0-9_]+', '_'), '_');
if strlength(key) == 0
    error('scenePercentiles:InvalidSceneKey', ...
        '场景名称无法转换为文件键：%s', scene_name);
end
end

function values = make_joint_hl_pool(h_image, l_image)
% H已完成能量对齐；同尺寸连接确保H/L在统计中具有相同像素权重。
if ~isequal(size(h_image), size(l_image)) || ...
        ~isreal(h_image) || ~isreal(l_image)
    error('scenePercentiles:JointHLImageMismatch', ...
        'JointHL要求H/L为同尺寸实数幅度图。');
end
values = [single(h_image(:)); single(l_image(:))];
end

function stats = calculate_chunk_percentiles( ...
        chunk_directory, percentages, modality, image_count)
% 从磁盘分块建立tall列向量，避免一次把全场景像素载入内存。
files = dir(fullfile(chunk_directory, "chunk_*.mat"));
[~, order] = sort(lower(string({files.name})));
files = files(order);
if isempty(files)
    error('scenePercentiles:PercentileChunksMissing', ...
        '没有找到分位数数据块：%s', chunk_directory);
end

paths = strings(numel(files), 1);
pixel_count = 0;
for idx = 1:numel(files)
    paths(idx) = string(fullfile(files(idx).folder, files(idx).name));
    variables = whos('-file', paths(idx));
    match = strcmp({variables.name}, 'values');
    if sum(match) ~= 1
        error('scenePercentiles:ChunkSchema', ...
            '数据块必须且只能包含一个values变量：%s', paths(idx));
    end
    variable = variables(match);
    if ~strcmp(variable.class, 'single') || ...
            numel(variable.size) ~= 2 || variable.size(2) ~= 1
        error('scenePercentiles:ChunkType', ...
            'chunk.values必须是single列向量：%s', paths(idx));
    end
    pixel_count = pixel_count + prod(variable.size);
end

datastore_value = fileDatastore(paths, ...
    'ReadFcn', @read_chunk_values, 'UniformRead', true);
mapreducer(0); % 使用本地MATLAB会话，不依赖并行许可证。
tall_values = tall(datastore_value);
limits = gather(prctile(tall_values, percentages, Method="midpoint"));
limits = double(limits(:));
if numel(limits) ~= 2 || any(~isfinite(limits)) || limits(2) <= limits(1)
    error('scenePercentiles:DegeneratePercentiles', ...
        '%s分位数范围无效。', modality);
end
stats = struct("Modality", modality, "VMin", limits(1), ...
    "VMax", limits(2), "ImageCount", image_count, ...
    "PixelCount", pixel_count, "ChunkCount", numel(files), ...
    "LowPercentile", percentages(1), ...
    "HighPercentile", percentages(2), ...
    "Method", "midpoint_exact_tall");
end

function values = read_chunk_values(file_path)
loaded = load(file_path, 'values');
if ~isfield(loaded, 'values')
    error('scenePercentiles:ChunkSchema', ...
        '数据块缺少values变量：%s', file_path);
end
values = loaded.values(:);
end

function key = make_parameter_key(parameters, protocol)
% 参数、相位和归一化协议全部进入键，避免误用不匹配的统计量。
key = "range_2d_sft" + ...
    "_qh" + encode_number(parameters.QHigh) + ...
    "_ql" + encode_number(parameters.QLow) + ...
    "_s" + encode_number(parameters.STRdB) + ...
    "_fr" + encode_number(parameters.FrOverBr) + ...
    "_fa" + encode_number(parameters.FaOverBa) + ...
    "_phi" + encode_number(parameters.Phi0) + ...
    "_lp" + encode_number(protocol.low_percentile) + ...
    "_hp" + encode_number(protocol.high_percentile) + ...
    "_roi" + encode_number(protocol.roi_size) + ...
    "_eb" + encode_number(protocol.energy_buffer);
end

function value = encode_number(number)
value = replace(string(sprintf('%.12g', double(number))), "-", "m");
value = replace(value, ".", "p");
value = replace(value, "+", "");
end

function scene_stats = upsert_scene_stats( ...
        file_path, header, gt_stats, entry)
% 一个场景MAT保存共享GT统计及多组Range+2D-SFT输入统计。
now_text = string(datetime('now', ...
    'Format', 'yyyy-MM-dd''T''HH:mm:ss.SSSXXX'));
if isfile(file_path)
    loaded = load(file_path, 'scene_stats');
    if ~isfield(loaded, 'scene_stats')
        error('scenePercentiles:SceneFileSchema', ...
            'MAT文件缺少scene_stats：%s', file_path);
    end
    scene_stats = loaded.scene_stats;
    verify_scene_header(scene_stats, header, file_path);
else
    scene_stats = header;
    scene_stats.gt = gt_stats;
    scene_stats.entries = struct([]);
    scene_stats.created_at = now_text;
end

entry.updated_at = now_text;
keys = strings(0, 1);
if ~isempty(scene_stats.entries)
    keys = string({scene_stats.entries.parameter_key}).';
end
match = find(keys == string(entry.parameter_key));
if numel(match) > 1
    error('scenePercentiles:DuplicateParameterKey', ...
        '场景MAT中存在重复参数键：%s', entry.parameter_key);
elseif isempty(match)
    entry.created_at = now_text;
    if isempty(scene_stats.entries)
        scene_stats.entries = entry;
    else
        scene_stats.entries(end + 1) = entry;
    end
else
    entry.created_at = scene_stats.entries(match).created_at;
    scene_stats.entries(match) = entry;
end
scene_stats.updated_at = now_text;
atomic_save(file_path, struct("scene_stats", scene_stats));
end

function verify_scene_header(scene_stats, header, file_path)
required = ["schema_version", "scene_name", "scene_key", ...
    "protocol", "source_manifest", "gt", "entries", "created_at"];
if ~all(isfield(scene_stats, required)) || ...
        string(scene_stats.schema_version) ~= string(header.schema_version) || ...
        string(scene_stats.scene_name) ~= string(header.scene_name) || ...
        string(scene_stats.scene_key) ~= string(header.scene_key) || ...
        ~isequaln(scene_stats.protocol, header.protocol) || ...
        ~isequaln(scene_stats.source_manifest, header.source_manifest)
    error('scenePercentiles:SceneSourceMismatch', ...
        '已有场景MAT与当前数据清单或协议不一致：%s', file_path);
end
end

function output = append_table(input, row)
if isempty(input)
    output = row;
else
    output = [input; row];
end
end

function ensure_directory(path)
if ~isfolder(path)
    [ok, message] = mkdir(path);
    if ~ok
        error('scenePercentiles:CreateDirectory', ...
            '无法创建目录%s：%s', path, message);
    end
end
end

function state = load_checkpoint(file_path, checkpoint_config, initial_state)
% 不计算哈希；直接保存并逐字段比较完整配置和场景清单。
state = initial_state;
if ~isfile(file_path)
    return;
end
loaded = load(file_path, 'state');
if ~isfield(loaded, 'state') || ~isfield(loaded.state, 'config')
    error('scenePercentiles:CheckpointSchema', ...
        'checkpoint缺少完整配置：%s', file_path);
end
if ~isequaln(loaded.state.config, checkpoint_config)
    error('scenePercentiles:CheckpointConfigMismatch', ...
        'checkpoint配置或场景清单与当前运行不一致：%s', file_path);
end
state = loaded.state;
end

function atomic_save(file_path, payload)
% 先写临时MAT，再替换目标文件，避免中断留下半写文件。
output_directory = string(fileparts(file_path));
if strlength(output_directory) > 0
    ensure_directory(output_directory);
end
temporary_path = string(file_path) + ".tmp";
save(temporary_path, '-struct', 'payload', '-v7.3');
[ok, message] = movefile(temporary_path, file_path, 'f');
if ~ok
    error('scenePercentiles:AtomicMove', ...
        '无法更新%s：%s', file_path, message);
end
end

function print_scene_counts(manifest)
scenes = unique(string(manifest.Scene), 'stable');
for idx = 1:numel(scenes)
    rows = manifest(string(manifest.Scene) == scenes(idx), :);
    fprintf('  %-28s 文件=%d，序列=%d\n', scenes(idx), ...
        numel(unique(rows.FilePath)), height(rows));
end
end

function remove_completed_work_directory(work_directory, work_root)
if ~isfolder(work_directory)
    return;
end
canonical_work = string(java.io.File(char(work_directory)).getCanonicalPath());
canonical_root = string(java.io.File(char(work_root)).getCanonicalPath());
expected_prefix = canonical_root + string(filesep);
if canonical_work == canonical_root || ...
        ~startsWith(canonical_work, expected_prefix)
    error('scenePercentiles:UnsafeWorkCleanup', ...
        '拒绝清理工作目录之外的路径：%s', canonical_work);
end
[ok, message] = rmdir(canonical_work, 's');
if ~ok
    warning('scenePercentiles:WorkCleanupFailed', ...
        '结果已提交，但临时目录清理失败：%s', message);
end
end
