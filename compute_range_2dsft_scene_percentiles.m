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
% 每一行是一套生产参数；H/L严格共享STR、fr、fa和phi0，仅q不同。
PARAMETERS = table( ...
    [4; 2.5], ...          % QHigh
    [2; 1.5], ...          % QLow
    [-1; 1], ...           % STRdB
    [1.3; 0.9], ...        % FrOverBr
    [0.5; 0.5], ...        % FaOverBa
    [0; 0], ...            % Phi0，单位rad
    'VariableNames', [ ...
    "QHigh", "QLow", "STRdB", "FrOverBr", "FaOverBa", "Phi0"]);

BLOCKS_PER_FILE = 10;     % 每条rstart轨迹均匀抽取的连续序列数量
LOW_PERCENTILE = 0.99;   % Robust min-max下限：0.99百分位
HIGH_PERCENTILE = 99.9;  % Robust min-max上限：99.9百分位
ROI_SIZE = 600;          % 分位数必须在600×600原始幅度ROI上统计
ENERGY_BUFFER = 64;      % 每个H/L边界两侧用于估计功率的RC列数

%% ========================== 仓库与公共配置 ===============================
% 脚本位置同时作为FS60参数文件和结果目录的基准路径。
SCRIPT_PATH = string(mfilename('fullpath'));
REPO_ROOT = string(fileparts(SCRIPT_PATH));
addpath(REPO_ROOT);

% cfg只保存本脚本实际使用的生产配置，不依赖任何外部配置函数。
cfg = struct();
cfg.data_root = "G:\MATLAB-G\SAR Full PSF";
cfg.dataset_names = [ ...
    "SAR_Dataset_Bangkok_1", "SAR_Dataset_city1_histeq", ...
    "SAR_Dataset_city2_histeq", "SAR_Dataset_SAR_figure", ...
    "SAR_Dataset_filed", "SAR_Dataset_port", "SAR_Dataset_suburb"];
cfg.parameter_file_60 = fullfile(REPO_ROOT, "FS60_params.mat");
cfg.nyquist_margin = 0.98; % SFT频率相对理论Nyquist保留2%安全余量
% 九帧在2224列连续块上以128列滑动；512有效区形成H-L-H结构。
cfg.sequence = struct( ...
    "n_frames", 9, "step", 128, ...
    "signal_height", 1200, "signal_width", 1200, ...
    "patch_size", 512, "roi_size", 600, ...
    "valid_margin", 344, "logic_length", 1536, ...
    "block_width", 2224);
S60 = load(cfg.parameter_file_60); % 60MHz距离-多普勒成像参数
OUTPUT_ROOT = fullfile(REPO_ROOT, ...
    "results_range_2dsft_scene_percentiles");
WORK_ROOT = fullfile(OUTPUT_ROOT, "_work"); % 分位数chunk和checkpoint临时目录

% protocol记录所有会影响统计结果的公共规则；manifest固定数据来源。
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
    scene = scenes(scene_idx); % 当前场景全名，例如SAR_Dataset_port
    scene_manifest = manifest(string(manifest.Scene) == scene, :);
    scene_key = string(scene_manifest.SceneKey(1)); % 稳定、可读的MAT文件名
    output_path = fullfile(OUTPUT_ROOT, scene_key + ".mat");
    % header用于确认已有MAT与本次场景、清单和统计协议完全一致。
    header = struct( ...
        "schema_version", "range_2dsft_scene_percentiles_v2", ...
        "scene_name", scene, ...
        "scene_key", scene_key, ...
        "protocol", protocol, ...
        "source_manifest", scene_manifest);
    gt_stats = load_existing_gt(output_path, header); % GT与SFT参数无关，场景内共享

    fprintf('\n[%d/%d] 场景%s：%d个文件，%d条序列。\n', ...
        scene_idx, numel(scenes), scene, ...
        numel(unique(scene_manifest.FilePath)), height(scene_manifest));

    for parameter_idx = 1:height(PARAMETERS)
        parameter_row = PARAMETERS(parameter_idx, :); % 当前倍率和SFT参数行
        parameters = parameter_struct(parameter_row);
        parameter_key = parameter_keys(parameter_idx); % MAT条目的唯一可读键
        pair = make_range_sft_pair(parameters);
        % 有效倍率由round(q*N)后的真实尺寸决定，并用于Nyquist检查。
        [grid_h, grid_l] = resolve_pair_grids(pair, cfg, S60);
        need_gt = isempty(fieldnames(gt_stats)); % 仅场景首个参数需要同步计算GT
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

        % 一个entry对应一套完整Range+2D-SFT参数及其JointHL输入分位数。
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
%BUILD_PROTOCOL 汇总会改变分位数结果的公共统计协议。
% 输入：场景/序列配置、60MHz成像参数、抽样数、分位点、ROI和边界宽度。
% 输出：写入场景MAT和checkpoint的protocol结构，用于显式一致性检查。
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
%VALIDATE_PARAMETERS 检查参数表、归一化范围和SFT物理合法性。
% parameters每行必须完整描述一组H/L倍率及共享2D-SFT参数。
% 本函数不修改参数；任何超Nyquist或重复配置都直接报错。
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
%BUILD_PARAMETER_KEYS 为参数表逐行生成稳定、可读且不冲突的文件键。
% 键中包含倍率、SFT参数和归一化协议，防止统计量被错误复用。
keys = strings(height(parameters), 1);
for idx = 1:height(parameters)
    keys(idx) = make_parameter_key( ...
        parameter_struct(parameters(idx, :)), protocol);
end
end

function parameters = parameter_struct(row)
%PARAMETER_STRUCT 将单行table转换为便于函数传递的标量结构。
% 输出字段保留物理名称和double类型，避免table标量类型扩散。
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
%MAKE_RANGE_SFT_PAIR 构造共享阈值参数的H/L距离向采集配置。
% H和L只有q_total不同；STR、fr/Br、fa/Ba、phi0完全相同。
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
%RESOLVE_PAIR_GRIDS 计算H/L实际整数网格并检查共同Nyquist上限。
% 输出grid_h/grid_l记录有效倍率、上采样尺寸、Fs和PRF，供审计保存。
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
%RESOLVE_AZIMUTH_BANDWIDTH 从FS60参数中解析方位带宽Ba。
% 优先使用Ba，其次兼容Bd；若只有天线孔径Da则按2v/Da换算。
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
%RESOLVE_RANGE_GRID 将名义距离倍率映射为可执行的整数采样网格。
% 输入q_range为名义倍率，input_size=[距离点数, 方位点数]。
% 小数倍率使用round(q*N)；输出中的q_range_eff才是实际成像倍率。
if q_range < 1 || ~isfinite(q_range)
    error('scenePercentiles:InvalidSamplingFactor', ...
        '距离向采样倍率必须是不小于1的有限数。');
end
nr_up = round(q_range * input_size(1)); % FFT补零后的整数距离维尺寸
q_range_eff = nr_up / input_size(1);    % 由整数尺寸反算的有效倍率
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
%GENERATE_RANGE_2DSFT_RC 生成一条采集分支的60MHz基网格RC。
% signal：1200×2224的60MHz复回波；acquisition：倍率和2D-SFT参数。
% 流程：距离FFT上采样→2D-SFT阈值→复1-bit量化→RC→中心频谱回投影。
% 输出RC_base与原始signal同尺寸，保证H/L能够逐列能量对齐和混合。
grid = resolve_range_grid(acquisition.q_total, size(signal), S60);
signal_up = upsample_range_fft(signal, grid.upsampled_size(1)); % 带限插值回波
threshold = build_2dsft_threshold(signal_up, grid, ...
    acquisition.threshold, S60);
channel_1bit = quantize_1bit(signal_up, threshold); % I/Q各保留一个符号位

% 上采样后必须使用对应Fs_up重建距离快时间轴。
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
%UPSAMPLE_RANGE_FFT 仅沿距离维进行中心频谱补零带限插值。
% target_rows是round(q*Nr)后的整数长度；方位维完全不改变。
% IFFT后乘有效倍率，补偿零填充导致的离散变换幅度变化。
current_rows = size(signal, 1);
if target_rows < current_rows
    error('scenePercentiles:UpsampleSize', ...
        '上采样目标行数不能小于输入行数。');
elseif target_rows == current_rows
    signal_up = signal;
    return;
end
spectrum = fftshift(fft(signal, [], 1), 1); % 距离频谱，零频移到中心
pad_total = target_rows - current_rows;
pad_top = floor(pad_total / 2);       % 奇数补零时上侧取floor
pad_bottom = pad_total - pad_top;     % 剩余零点放在下侧
spectrum_up = [ ...
    zeros(pad_top, size(signal, 2), 'like', spectrum); ...
    spectrum; ...
    zeros(pad_bottom, size(signal, 2), 'like', spectrum)];
signal_up = ifft(ifftshift(spectrum_up, 1), [], 1) ...
    * (target_rows / current_rows);
end

function threshold = build_2dsft_threshold(signal_up, grid, parameters, S60)
%BUILD_2DSFT_THRESHOLD 在上采样网格上构造确定性的二维单频复阈值。
% fast-time对应距离维，slow-time对应方位维；二者相位相加后取复指数。
% STR定义为信号尺度与阈值幅度之比，H/L共享归一化频率和初相位。
sigma_hat = sqrt(2 / pi) * mean(abs(signal_up(:))); % 当前分支信号尺度估计
amplitude = sigma_hat / (10 ^ (parameters.STR_dB / 20)); % 阈值复幅度
fr_hz = parameters.fr_over_Br * S60.B; % 距离归一化频率转物理Hz
fa_hz = parameters.fa_over_Ba * resolve_azimuth_bandwidth(S60); % 方位Hz

% block_global时间原点：每个2224列连续块共用同一方位坐标。
fast_time = ((0:size(signal_up, 1)-1).' ...
    - floor(size(signal_up, 1) / 2)) / grid.Fs_up;
slow_time = ((0:size(signal_up, 2)-1) ...
    - floor(size(signal_up, 2) / 2)) / grid.PRF_up;
phase_range = 2 * pi * fr_hz * fast_time;   % Nr_up×1距离相位
phase_azimuth = 2 * pi * fa_hz * slow_time; % 1×Na方位相位
threshold = amplitude * exp(1i * ...
    (phase_range + phase_azimuth + parameters.phi0));
end

function output = quantize_1bit(signal, threshold)
%QUANTIZE_1BIT 对复回波I/Q分别执行“信号+阈值”的符号判决。
% 输出字母表固定为实部±1、虚部±1；零值按+1处理。
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
%CROP_RANGE_SPECTRUM 将上采样RC投影回原始60MHz距离网格。
% 只裁距离中心频谱，不改变方位维；偶数和奇数目标尺寸分别处理。
current_rows = size(input, 1);
if target_rows > current_rows
    error('scenePercentiles:CropSize', ...
        '频谱裁剪目标不能大于当前距离维。');
elseif target_rows == current_rows
    output = input;
    return;
end
spectrum = fftshift(fft(input, [], 1), 1); % 上采样RC的距离频谱
center = floor(current_rows / 2) + 1;      % fftshift后的中心索引
half_width = floor(target_rows / 2);       % 目标频谱半宽
if mod(target_rows, 2) == 0
    indices = center-half_width:center+half_width-1;
else
    indices = center-half_width:center+half_width;
end
spectrum = spectrum(indices, :);
output = ifft(ifftshift(spectrum, 1), [], 1);
end

function mask = build_hlh_mask(sequence)
%BUILD_HLH_MASK 构造2224列连续RC上的H-L-H空间选择掩膜。
% 有效逻辑区为H(512)-L(512)-H(512)，两端各扩展344列。
% true选择对齐后的RC_H，false选择RC_L；边界应固定为两个。
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
%LOAD_ECHO_BLOCK 读取清单指定的180MHz轨迹连续块并转换为60MHz。
% manifest_row提供文件、变量名和CStart；persistent缓存避免重复读同一轨迹。
% 输出固定为S60.nrn×block_width复回波，供H/L两分支共同使用。
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
start_index = manifest_row.CStart(1);          % 当前2224列块的首列
stop_index = start_index + block_width - 1;   % 当前块的末列
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
%ALIGN_AND_MIX_RC 用双边界单一gamma完成H/L能量对齐和空间拼接。
% RC_H/RC_L必须位于同一60MHz基网格；mode_mask=true的位置选择H。
% 输出RC_mix用于流程审计，info中的scale_factor用于纯H统计量对齐。
if ~isequal(size(RC_H), size(RC_L))
    error('scenePercentiles:RCSizeMismatch', 'H/L RC尺寸不一致。');
end
mode_mask = logical(mode_mask(:).');
if numel(mode_mask) ~= size(RC_H, 2)
    error('scenePercentiles:RCMaskLength', ...
        'H-L-H掩膜长度必须等于RC列数。');
end
boundaries = find(diff(mode_mask) ~= 0); % H→L和L→H两个空间边界
if numel(boundaries) ~= 2
    error('scenePercentiles:RCBoundaryCount', ...
        'H-L-H连续块必须包含两个边界。');
end

power_h = zeros(numel(boundaries), 1); % 每个边界H侧的平均RC功率
power_l = zeros(numel(boundaries), 1); % 每个边界L侧的平均RC功率
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
pooled_h = mean(power_h); % 两个边界等权汇总后的H功率
pooled_l = mean(power_l); % 两个边界等权汇总后的L功率
if pooled_h <= 1e-12
    scale_factor = 1;
else
    % gamma=sqrt(P_L/P_H)，使缩放后H功率与L处于同一强度尺度。
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
%FOCUS_BASE_RC 从60MHz基网格RC生成指定尺寸的线性幅度ROI。
% 仅调用允许的RCMC和SAR_Imaging；不做归一化、对数显示或均衡化。
% 输出image_roi为实数非负幅度图，是JointHL分位数的直接像素来源。
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
full_roi = abs(image_complex(row_start:row_end, ... % 标准600×600有效幅度区
    column_start:column_end));
image_roi = crop_center(full_roi, roi_size);
end

function image_roi = generate_gt_image(signal, S60, roi_size)
%GENERATE_GT_IMAGE 对未量化60MHz复回波执行标准成像。
% GT只依赖原始回波和成像参数，与H/L倍率及2D-SFT参数无关。
RC_gt = Range_Compress(signal, S60.fc, S60.tnrn, S60.gama, ...
    S60.R0, S60.C, S60.Fs, S60.Tp);
image_roi = focus_base_rc(RC_gt, S60, roi_size);
end

function output = crop_center(input, target_size)
%CROP_CENTER 从二维图像中心裁出target_size×target_size区域。
% 分位数脚本传入600时通常保持原ROI；函数保留尺寸检查以防协议变化。
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
%PROCESS_SCENE_PARAMETER 计算一个场景、一组参数的JointHL分位数。
% scene_manifest包含该场景全部均匀抽样序列；pair定义H/L采集分支。
% need_gt=true时在同一遍历中同步收集GT像素，避免额外读取和成像。
% 输出result包含JointHL输入统计、可选GT统计和能量对齐审计量。
% 大像素池按序列写入chunk，避免将整个场景一次性保存在内存中。
joint_directory = fullfile(work_directory, "joint");
gt_directory = fullfile(work_directory, "gt");
checkpoint_path = fullfile(work_directory, "checkpoint.mat");
ensure_directory(joint_directory);
if need_gt
    ensure_directory(gt_directory);
end

% checkpoint_config保存显式配置和完整清单，不使用哈希或摘要。
checkpoint_config = struct( ...
    "version", "range_2dsft_scene_percentiles_checkpoint_v2", ...
    "scene", string(scene_manifest.Scene(1)), ...
    "manifest", scene_manifest, ...
    "parameters", parameters, ...
    "protocol", protocol, ...
    "include_gt", need_gt);
sequence_count = height(scene_manifest); % 当前场景参与统计的连续序列数
% 每条序列完成后记录gamma和边界残差，便于恢复及最终审计。
initial_state = struct( ...
    "config", checkpoint_config, ...
    "completed_sequences", 0, ...
    "scale_factors", nan(sequence_count, 1), ...
    "boundary_jump_db", nan(sequence_count, 1));
state = load_checkpoint(checkpoint_path, checkpoint_config, initial_state);
verify_completed_chunks( ...
    state.completed_sequences, joint_directory, gt_directory, need_gt);

frame_count = cfg.sequence.n_frames;       % 固定九帧
pixels_per_image = protocol.roi_size ^ 2; % 单张600×600 ROI的像素数
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

    % 同一连续回波分别生成H/L完整RC；二者共享SFT物理参数。
    RC_H = generate_range_2dsft_rc(signal, S60, pair.H);
    RC_L = generate_range_2dsft_rc(signal, S60, pair.L);
    [~, mix_info] = align_and_mix_rc( ...
        RC_H, RC_L, mask.full, protocol.energy_buffer);
    % JointHL中的纯H图必须与实际RC_mix里的H区域使用同一个gamma。
    RC_H = RC_H * mix_info.scale_factor;

    % 每帧贡献一张H和一张L，因此JointHL像素数严格为GT的两倍。
    joint_values = zeros(2 * pixels_per_image * frame_count, 1, 'single');
    if need_gt
        gt_values = zeros(pixels_per_image * frame_count, 1, 'single');
    end
    for frame_idx = 1:frame_count
        % 九个1200列成像窗口沿2224列连续块每次移动128列。
        columns = frame_columns(cfg.sequence, frame_idx);
        h_image = focus_base_rc( ...
            RC_H(:, columns), S60, protocol.roi_size);
        l_image = focus_base_rc( ...
            RC_L(:, columns), S60, protocol.roi_size);
        frame_pool = make_joint_hl_pool(h_image, l_image); % H/L等像素权重
        % 将当前帧的2×600×600像素写入预分配列向量对应区间。
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

    % chunk编号与场景清单行一一对应，保证断点恢复顺序确定。
    chunk_name = sprintf('chunk_%06d.mat', sequence_idx);
    atomic_save(fullfile(joint_directory, chunk_name), ...
        struct("values", joint_values));
    if need_gt
        atomic_save(fullfile(gt_directory, chunk_name), ...
            struct("values", gt_values));
    end
    % 先完整写出像素chunk，再更新checkpoint，避免声明完成但文件缺失。
    state.completed_sequences = sequence_idx;
    state.scale_factors(sequence_idx) = mix_info.scale_factor;
    state.boundary_jump_db(sequence_idx) = mix_info.boundary_jump_db;
    atomic_save(checkpoint_path, struct("state", state));
    fprintf('    序列 %d/%d 完成。\n', sequence_idx, sequence_count);
end

% 所有序列完成后，跨全部chunk计算场景级精确分位数。
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

% audit不参与归一化，只用于检查gamma范围和RC边界是否仍接近0 dB。
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
%FRAME_COLUMNS 返回第frame_idx帧在2224列连续块中的1200列索引。
% frame_idx使用MATLAB的1~9编号；首列按128步长线性移动。
start_idx = 1 + (frame_idx - 1) * sequence_cfg.step;
columns = start_idx:start_idx + sequence_cfg.signal_width - 1;
end

function verify_completed_chunks(completed, joint_dir, gt_dir, need_gt)
%VERIFY_COMPLETED_CHUNKS 核对checkpoint声称完成的磁盘像素块。
% JointHL chunk必须存在；need_gt=true时对应GT chunk也必须存在。
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
%LOAD_EXISTING_GT 从已有场景MAT读取可复用的GT分位数。
% 复用前直接比较schema、场景身份、完整协议和源清单，不使用哈希。
% 文件不存在时返回空结构，主流程会在首个参数中计算GT。
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
%SCENE_ENTRY_EXISTS 判断指定参数的JointHL统计是否已经成功提交。
% 返回true时主流程跳过重复成像，并清理可能残留的临时目录。
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
%IMAGING_PARAMETERS 提取会影响成像和分位数的FS60核心参数。
% 这些显式字段随protocol保存，用于后续逐字段一致性检查。
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
%BUILD_SCENE_MANIFEST 枚举全部场景轨迹并建立确定性的统计清单。
% 每个rstart文件在[1,max_start]内均匀选取blocks_per_file个CStart。
% 输出manifest逐行记录场景、文件、变量、起点和文件元数据，既用于
% 主循环读取，也用于已有结果和checkpoint的显式一致性比较。
manifest = table();
sequence_id = 0; % 跨场景递增的唯一序列编号
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
        raw_width = variables(1).size(2); % 180MHz原始回波总列数
        max_start = raw_width - cfg.sequence.block_width + 1; % 最大合法首列
        if max_start < blocks_per_file
            error('scenePercentiles:EchoTooShort', ...
                '文件%s无法抽取%d个宽度为%d的不同连续块。', ...
                file.name, blocks_per_file, cfg.sequence.block_width);
        end
        % 包含轨迹首尾位置，round后仍要求所有起点互不重复。
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
%SORT_ECHO_FILES 按rstart后的数字对轨迹文件进行稳定排序。
% 例如rstart 20.mat排在rstart 100.mat前；无法解析时按名称排序。
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
%MAKE_SCENE_KEY 将场景全名转换为稳定、可读的MAT文件名。
% 已知七场景使用固定映射，未知名称再执行小写和安全字符清理。
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
%MAKE_JOINT_HL_POOL 将一张纯H和一张纯L幅度图等权连接。
% h_image必须已经乘过当前序列的gamma；这里不做像素融合或加权平均。
% 输出顺序为[H(:);L(:)]，相同尺寸天然保证H/L像素权重各占50%。
if ~isequal(size(h_image), size(l_image)) || ...
        ~isreal(h_image) || ~isreal(l_image)
    error('scenePercentiles:JointHLImageMismatch', ...
        'JointHL要求H/L为同尺寸实数幅度图。');
end
values = [single(h_image(:)); single(l_image(:))];
end

function stats = calculate_chunk_percentiles( ...
        chunk_directory, percentages, modality, image_count)
%CALCULATE_CHUNK_PERCENTILES 计算跨全部磁盘chunk的场景级分位数。
% percentages=[低分位,高分位]，modality用于结果标识，image_count用于审计。
% fileDatastore+tall避免一次载入数十亿像素；Method=midpoint固定插值规则。
files = dir(fullfile(chunk_directory, "chunk_*.mat"));
[~, order] = sort(lower(string({files.name})));
files = files(order);
if isempty(files)
    error('scenePercentiles:PercentileChunksMissing', ...
        '没有找到分位数数据块：%s', chunk_directory);
end

paths = strings(numel(files), 1); % 按chunk编号排序后的完整路径
pixel_count = 0;                  % 所有chunk实际像素总数
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

% 每次只读取一个single列向量，tall在本地会话中顺序汇总。
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
%READ_CHUNK_VALUES fileDatastore的单文件读取函数。
% 每个chunk只允许包含一个名为values的列向量。
loaded = load(file_path, 'values');
if ~isfield(loaded, 'values')
    error('scenePercentiles:ChunkSchema', ...
        '数据块缺少values变量：%s', file_path);
end
values = loaded.values(:);
end

function key = make_parameter_key(parameters, protocol)
%MAKE_PARAMETER_KEY 构造一套统计结果的稳定ASCII条目键。
% 倍率、STR、fr、fa、phi0、分位点、ROI和buffer全部进入键，避免误用。
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
%ENCODE_NUMBER 将数值转换为适合文件键的ASCII片段。
% 负号编码为m，小数点编码为p，避免不同平台文件名歧义。
value = replace(string(sprintf('%.12g', double(number))), "-", "m");
value = replace(value, ".", "p");
value = replace(value, "+", "");
end

function scene_stats = upsert_scene_stats( ...
        file_path, header, gt_stats, entry)
%UPSERT_SCENE_STATS 原子新增或替换场景MAT中的一组参数统计。
% 一个MAT保存场景共享GT以及多组Range+2D-SFT JointHL输入分位数。
% parameter_key唯一匹配；重复运行同一参数时保留created_at并更新时间。
now_text = string(datetime('now', ... % 当前结果写入时间，使用带时区ISO格式
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
keys = strings(0, 1); % 已有entries的parameter_key列表
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
%VERIFY_SCENE_HEADER 防止新统计写入不兼容的已有场景MAT。
% 直接逐字段比较场景身份、统计协议和完整源清单，不计算哈希。
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
%APPEND_TABLE 将单行table安全追加到table累加器。
% 空累加器必须初始化为table()，避免table与double空数组混合拼接。
if isempty(input)
    output = row;
else
    output = [input; row];
end
end

function ensure_directory(path)
%ENSURE_DIRECTORY 确保输出或临时目录存在；创建失败立即报错。
if ~isfolder(path)
    [ok, message] = mkdir(path);
    if ~ok
        error('scenePercentiles:CreateDirectory', ...
            '无法创建目录%s：%s', path, message);
    end
end
end

function state = load_checkpoint(file_path, checkpoint_config, initial_state)
%LOAD_CHECKPOINT 恢复长时间统计的序列级进度。
% 不计算哈希；直接保存并逐字段比较完整配置和场景清单。
% 文件不存在时返回initial_state，配置不一致时拒绝静默复用。
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
%ATOMIC_SAVE 先写临时MAT，再替换目标文件。
% payload为待保存结构；先完整写入.tmp可避免中断留下半写结果。
output_directory = string(fileparts(file_path));
if strlength(output_directory) > 0
    ensure_directory(output_directory);
end
temporary_path = string(file_path) + ".tmp"; % 与目标文件同目录，便于原子替换
save(temporary_path, '-struct', 'payload', '-v7.3');
[ok, message] = movefile(temporary_path, file_path, 'f');
if ~ok
    error('scenePercentiles:AtomicMove', ...
        '无法更新%s：%s', file_path, message);
end
end

function print_scene_counts(manifest)
%PRINT_SCENE_COUNTS 在正式计算前打印每个场景的文件数和序列数。
scenes = unique(string(manifest.Scene), 'stable');
for idx = 1:numel(scenes)
    rows = manifest(string(manifest.Scene) == scenes(idx), :);
    fprintf('  %-28s 文件=%d，序列=%d\n', scenes(idx), ...
        numel(unique(rows.FilePath)), height(rows));
end
end

function remove_completed_work_directory(work_directory, work_root)
%REMOVE_COMPLETED_WORK_DIRECTORY 删除已提交结果对应的临时chunk目录。
% 删除前解析规范绝对路径，并强制要求目标位于_work根目录内部。
% 最终场景MAT已原子写入，因此这里只清理可再生的临时文件。
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
