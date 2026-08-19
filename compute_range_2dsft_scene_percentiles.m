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

cfg = sarvalid.default_config();
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

sarvalid.ensure_dir(OUTPUT_ROOT);
sarvalid.ensure_dir(WORK_ROOT);
scenes = unique(string(manifest.Scene), 'stable');

%% ========================== 场景与参数循环 ===============================
for scene_idx = 1:numel(scenes)
    scene = scenes(scene_idx);
    scene_manifest = manifest(string(manifest.Scene) == scene, :);
    scene_key = string(scene_manifest.SceneKey(1));
    output_path = fullfile(OUTPUT_ROOT, scene_key + ".mat");
    source_signature = manifest_signature(scene_manifest);
    header = struct( ...
        "schema_version", "range_2dsft_scene_percentiles_v1", ...
        "scene_name", scene, ...
        "scene_key", scene_key, ...
        "protocol", protocol, ...
        "source_manifest", scene_manifest, ...
        "source_signature", source_signature);
    gt_signature = make_gt_signature(header);
    gt_stats = load_existing_gt(output_path, header, gt_signature);

    fprintf('\n[%d/%d] 场景%s：%d个文件，%d条序列。\n', ...
        scene_idx, numel(scenes), scene, ...
        numel(unique(scene_manifest.FilePath)), height(scene_manifest));

    for parameter_idx = 1:height(PARAMETERS)
        parameter_row = PARAMETERS(parameter_idx, :);
        parameters = parameter_struct(parameter_row);
        parameter_key = parameter_keys(parameter_idx);
        pair = make_range_sft_pair(cfg, parameters);
        [grid_h, grid_l] = resolve_pair_grids(pair, cfg, S60);
        need_gt = isempty(fieldnames(gt_stats));
        work_directory = fullfile(WORK_ROOT, scene_key, parameter_key);

        fprintf('  [%d/%d] %s\n', ...
            parameter_idx, height(PARAMETERS), parameter_key);
        result = process_scene_parameter( ...
            cfg, S60, scene_manifest, pair, parameters, protocol, ...
            source_signature, gt_signature, work_directory, ...
            need_gt);
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
    "imaging", imaging_signature(S60));
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
    pair = make_range_sft_pair(cfg, value);
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

function pair = make_range_sft_pair(cfg, parameters)
threshold = struct( ...
    "As", cfg.threshold.As, ...
    "STR_dB", parameters.STRdB, ...
    "fr_over_Br", parameters.FrOverBr, ...
    "fa_over_Ba", parameters.FaOverBa, ...
    "phi0", parameters.Phi0);
pair = sarvalid.make_pair_config(cfg, "Range_2D_SFT", ...
    parameters.QHigh, parameters.QLow, 1, threshold);
end

function [grid_h, grid_l] = resolve_pair_grids(pair, cfg, S60)
input_size = [cfg.sequence.signal_height, cfg.sequence.block_width];
grid_h = sarvalid.resolve_acquisition(pair.H, input_size, S60);
grid_l = sarvalid.resolve_acquisition(pair.L, input_size, S60);
azimuth_bandwidth = resolve_azimuth_bandwidth(S60);
fr_limit = cfg.threshold.nyquist_margin * ...
    min(grid_h.Fs_up, grid_l.Fs_up) / (2 * S60.B);
fa_limit = cfg.threshold.nyquist_margin * ...
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

function result = process_scene_parameter(cfg, S60, scene_manifest, ...
        pair, parameters, protocol, source_signature, gt_signature, ...
        work_directory, need_gt)
joint_directory = fullfile(work_directory, "joint");
gt_directory = fullfile(work_directory, "gt");
checkpoint_path = fullfile(work_directory, "checkpoint.mat");
sarvalid.ensure_dir(joint_directory);
if need_gt
    sarvalid.ensure_dir(gt_directory);
end

signature = struct( ...
    "version", "range_2dsft_scene_percentiles_checkpoint_v1", ...
    "scene", string(scene_manifest.Scene(1)), ...
    "source_signature", source_signature, ...
    "manifest", scene_manifest, ...
    "parameters", parameters, ...
    "protocol", protocol, ...
    "gt_signature", gt_signature, ...
    "include_gt", need_gt);
sequence_count = height(scene_manifest);
initial_state = struct( ...
    "completed_sequences", 0, ...
    "scale_factors", nan(sequence_count, 1), ...
    "boundary_jump_db", nan(sequence_count, 1));
state = sarvalid.load_checkpoint(checkpoint_path, signature, initial_state);
verify_completed_chunks( ...
    state.completed_sequences, joint_directory, gt_directory, need_gt);

frame_count = cfg.sequence.n_frames;
pixels_per_image = protocol.roi_size ^ 2;
mask = sarvalid.build_hlh_mask(cfg.sequence);
for sequence_idx = state.completed_sequences + 1:sequence_count
    signal = sarvalid.load_echo_block( ...
        scene_manifest(sequence_idx, :), S60, cfg.sequence.block_width);
    if isreal(signal) || ~isequal(size(signal), ...
            [cfg.sequence.signal_height, cfg.sequence.block_width])
        error('scenePercentiles:InvalidEchoBlock', ...
            '序列%d的60MHz复回波尺寸不正确。', ...
            scene_manifest.SequenceID(sequence_idx));
    end

    [RC_H, ~] = sarvalid.generate_base_rc(signal, S60, pair.H);
    [RC_L, ~] = sarvalid.generate_base_rc(signal, S60, pair.L);
    [~, mix_info] = sarvalid.align_and_mix_rc( ...
        RC_H, RC_L, mask.full, protocol.energy_buffer);
    RC_H = RC_H * mix_info.scale_factor;

    joint_values = zeros(2 * pixels_per_image * frame_count, 1, 'single');
    if need_gt
        gt_values = zeros(pixels_per_image * frame_count, 1, 'single');
    end
    for frame_idx = 1:frame_count
        columns = frame_columns(cfg.sequence, frame_idx);
        h_image = sarvalid.focus_base_rc( ...
            RC_H(:, columns), S60, protocol.roi_size);
        l_image = sarvalid.focus_base_rc( ...
            RC_L(:, columns), S60, protocol.roi_size);
        frame_pool = make_joint_hl_pool(h_image, l_image);
        joint_start = (frame_idx - 1) * 2 * pixels_per_image + 1;
        joint_stop = frame_idx * 2 * pixels_per_image;
        joint_values(joint_start:joint_stop) = frame_pool;

        if need_gt
            gt_image = sarvalid.generate_gt_image( ...
                signal(:, columns), S60, protocol.roi_size);
            gt_start = (frame_idx - 1) * pixels_per_image + 1;
            gt_stop = frame_idx * pixels_per_image;
            gt_values(gt_start:gt_stop) = single(gt_image(:));
        end
    end

    chunk_name = sprintf('chunk_%06d.mat', sequence_idx);
    sarvalid.atomic_save(fullfile(joint_directory, chunk_name), ...
        struct("values", joint_values));
    if need_gt
        sarvalid.atomic_save(fullfile(gt_directory, chunk_name), ...
            struct("values", gt_values));
    end
    state.completed_sequences = sequence_idx;
    state.scale_factors(sequence_idx) = mix_info.scale_factor;
    state.boundary_jump_db(sequence_idx) = mix_info.boundary_jump_db;
    sarvalid.atomic_save(checkpoint_path, struct("state", state));
    fprintf('    序列 %d/%d 完成。\n', sequence_idx, sequence_count);
end

percentages = [protocol.low_percentile, protocol.high_percentile];
input_stats = calculate_chunk_percentiles( ...
    joint_directory, percentages, "JointHL", ...
    2 * sequence_count * frame_count);
input_stats.signature = sarvalid.sha256_text(string(jsonencode(struct( ...
    "source", source_signature, "parameters", parameters, ...
    "protocol", protocol))));

if need_gt
    gt_stats = calculate_chunk_percentiles( ...
        gt_directory, percentages, "GT", sequence_count * frame_count);
    gt_stats.signature = gt_signature;
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
    "CompletedSequences", state.completed_sequences, ...
    "SourceSignature", source_signature, ...
    "CheckpointSignature", sarvalid.sha256_text( ...
    string(jsonencode(struct( ...
    "source_signature", source_signature, ...
    "parameters", parameters, ...
    "protocol", protocol, ...
    "include_gt", need_gt)))));
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

function signature = manifest_signature(manifest)
signature = sarvalid.sha256_text( ...
    string(jsonencode(table2struct(manifest))));
end

function signature = make_gt_signature(header)
value = struct( ...
    "source_signature", header.source_signature, ...
    "working_echo", header.protocol.working_echo, ...
    "roi_size", header.protocol.roi_size, ...
    "low_percentile", header.protocol.low_percentile, ...
    "high_percentile", header.protocol.high_percentile, ...
    "sequence", header.protocol.sequence, ...
    "imaging", header.protocol.imaging);
signature = sarvalid.sha256_text(string(jsonencode(value)));
end

function gt_stats = load_existing_gt(file_path, header, gt_signature)
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
    "protocol", "source_manifest", "source_signature", "gt"];
if ~all(isfield(existing, required)) || ...
        string(existing.schema_version) ~= string(header.schema_version) || ...
        string(existing.scene_name) ~= string(header.scene_name) || ...
        string(existing.scene_key) ~= string(header.scene_key) || ...
        ~isequaln(existing.protocol, header.protocol) || ...
        ~isequaln(existing.source_manifest, header.source_manifest) || ...
        string(existing.source_signature) ~= string(header.source_signature)
    error('scenePercentiles:SourceSignatureMismatch', ...
        '已有场景MAT与当前数据或协议不一致：%s', file_path);
end
if ~isfield(existing.gt, "signature") || ...
        string(existing.gt.signature) ~= string(gt_signature)
    error('scenePercentiles:GTSignatureMismatch', ...
        '已有场景MAT的GT签名不一致：%s', file_path);
end
gt_stats = existing.gt;
end

function value = imaging_signature(S60)
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
    if string(scene_stats.gt.signature) ~= string(gt_stats.signature)
        error('scenePercentiles:GTSignatureMismatch', ...
            '已有GT统计与当前协议不一致：%s', file_path);
    end
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
sarvalid.atomic_save(file_path, struct("scene_stats", scene_stats));
end

function verify_scene_header(scene_stats, header, file_path)
required = ["schema_version", "scene_name", "scene_key", ...
    "protocol", "source_manifest", "source_signature", ...
    "gt", "entries", "created_at"];
if ~all(isfield(scene_stats, required)) || ...
        string(scene_stats.schema_version) ~= string(header.schema_version) || ...
        string(scene_stats.scene_name) ~= string(header.scene_name) || ...
        string(scene_stats.scene_key) ~= string(header.scene_key) || ...
        ~isequaln(scene_stats.protocol, header.protocol) || ...
        string(scene_stats.source_signature) ~= ...
        string(header.source_signature) || ...
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
