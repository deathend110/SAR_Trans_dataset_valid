function [cache_index, gt_stats] = prepare_range_sft_v3_gt_cache( ...
        cfg, S60, manifest, cache_dir)
%PREPARE_RANGE_SFT_V3_GT_CACHE 按场景缓存35条序列的600像素GT原图。

arguments
    cfg (1, 1) struct
    S60 (1, 1) struct
    manifest table
    cache_dir (1, 1) string
end

sarvalid.ensure_dir(cache_dir);
scenes = unique(string(manifest.Scene), 'stable');
cache_index = table();
gt_stats = table();
for scene_idx = 1:numel(scenes)
    scene = scenes(scene_idx);
    rows = manifest(string(manifest.Scene) == scene, :);
    cache_path = fullfile(cache_dir, safe_name(scene) + "_gt_cache.mat");
    signature = cache_signature(cfg, S60, rows);
    if isfile(cache_path)
        loaded = load(cache_path, 'cache');
        if ~isfield(loaded, 'cache') || ...
                ~isequaln(loaded.cache.signature, signature)
            error('sarvalid:V3GTCacheSignatureMismatch', ...
                'GT缓存与当前配置不一致：%s', cache_path);
        end
        cache = loaded.cache;
    else
        cache = build_scene_cache(cfg, S60, rows, signature);
        sarvalid.atomic_save(string(cache_path), struct("cache", cache));
    end

    Scene = scene;
    Path = string(cache_path);
    SequenceCount = numel(cache.SequenceID);
    ImageCount = numel(cache.SequenceID) * cfg.sequence.n_frames;
    PixelCount = numel(cache.gt_roi);
    cache_index = append_table(cache_index, ...
        table(Scene, Path, SequenceCount, ImageCount, PixelCount));
    gt_stats = append_table(gt_stats, cache.norm_stats);
end
end

function cache = build_scene_cache(cfg, S60, rows, signature)
v3 = cfg.range_2dsft_v3;
sequence_count = height(rows);
frame_count = cfg.sequence.n_frames;
roi_size = v3.normalization_roi_size;
gt_roi = zeros(roi_size, roi_size, frame_count, sequence_count, 'single');
for sequence_idx = 1:sequence_count
    signal = sarvalid.load_echo_block( ...
        rows(sequence_idx, :), S60, cfg.sequence.block_width);
    for frame_idx = 1:frame_count
        columns = frame_columns(cfg.sequence, frame_idx);
        gt_roi(:, :, frame_idx, sequence_idx) = single( ...
            sarvalid.generate_gt_image( ...
            signal(:, columns), S60, roi_size));
    end
end
[v_min, v_max] = percentiles(gt_roi, ...
    v3.low_percentile, v3.high_percentile);
Scene = string(rows.Scene(1));
Modality = "GT";
VMin = v_min;
VMax = v_max;
SampleCount = sequence_count * frame_count;
PixelCount = numel(gt_roi);
LowPercentile = v3.low_percentile;
HighPercentile = v3.high_percentile;
norm_stats = table(Scene, Modality, VMin, VMax, SampleCount, ...
    PixelCount, LowPercentile, HighPercentile);

cache = struct("signature", signature, ...
    "SequenceID", rows.SequenceID(:), "gt_roi", gt_roi, ...
    "norm_stats", norm_stats);
end

function columns = frame_columns(sequence_cfg, frame_idx)
start_idx = 1 + (frame_idx - 1) * sequence_cfg.step;
columns = start_idx:start_idx + sequence_cfg.signal_width - 1;
end

function [v_min, v_max] = percentiles(values, low, high)
limits = prctile(values(:), [low, high]);
v_min = double(limits(1));
v_max = double(limits(2));
if ~isfinite(v_min) || ~isfinite(v_max) || v_max <= v_min
    error('sarvalid:V3DegenerateGTNormalization', ...
        'GT的0.99%%/99.9%%归一化范围无效。');
end
end

function signature = cache_signature(cfg, S60, rows)
v3 = cfg.range_2dsft_v3;
signature = struct("experiment", v3.version, "stage", "gt_cache", ...
    "manifest", rows(:, ["SequenceID", "Scene", "File", ...
    "FilePath", "CStart", "BlockWidth"]), ...
    "roi_size", v3.normalization_roi_size, ...
    "low_percentile", v3.low_percentile, ...
    "high_percentile", v3.high_percentile, ...
    "sequence", cfg.sequence, "imaging", imaging_signature(S60));
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

function output = safe_name(input)
output = regexprep(string(input), '[^A-Za-z0-9_-]+', '_');
end

function output = append_table(input, rows)
if isempty(input)
    output = rows;
else
    output = [input; rows];
end
end
