function result = evaluate_range_sft_v3_scene( ...
        cfg, S60, scene_manifest, pair, gt_cache_path, options)
%EVALUATE_RANGE_SFT_V3_SCENE 用候选专属H/L分位数评价一个场景。

arguments
    cfg (1, 1) struct
    S60 (1, 1) struct
    scene_manifest table
    pair (1, 1) struct
    gt_cache_path (1, 1) string
    options.CollectDetails (1, 1) logical = false
    options.ContactDirectory (1, 1) string = ""
end

v3 = cfg.range_2dsft_v3;
loaded = load(gt_cache_path, 'cache');
if ~isfield(loaded, 'cache')
    error('sarvalid:V3GTCacheSchema', 'GT缓存缺少cache变量。');
end
gt_cache = loaded.cache;
if ~isequal(gt_cache.SequenceID(:), scene_manifest.SequenceID(:))
    error('sarvalid:V3GTCacheManifestMismatch', ...
        'GT缓存的SequenceID与当前场景清单不一致。');
end

sequence_count = height(scene_manifest);
frame_count = cfg.sequence.n_frames;
roi_size = v3.normalization_roi_size;
h_roi = zeros(roi_size, roi_size, frame_count, sequence_count, 'single');
l_roi = zeros(roi_size, roi_size, frame_count, sequence_count, 'single');
mixed_roi = zeros(roi_size, roi_size, frame_count, sequence_count, 'single');
mix_meta = cell(sequence_count, 1);
leakage = cell(sequence_count, 1);
mask = sarvalid.build_hlh_mask(cfg.sequence);

for sequence_idx = 1:sequence_count
    signal = sarvalid.load_echo_block( ...
        scene_manifest(sequence_idx, :), S60, cfg.sequence.block_width);
    [RC_H, ~] = sarvalid.generate_base_rc(signal, S60, pair.H);
    [RC_L, ~] = sarvalid.generate_base_rc(signal, S60, pair.L);
    [RC_mix, mix_meta{sequence_idx}] = sarvalid.align_and_mix_rc( ...
        RC_H, RC_L, mask.full, v3.energy_buffer);
    % H统计量必须对应实际混合块中的H强度，因此复用同一个全长块缩放系数。
    RC_H_aligned = RC_H * mix_meta{sequence_idx}.scale_factor;
    reference_rc = Range_Compress(signal, S60.fc, S60.tnrn, ...
        S60.gama, S60.R0, S60.C, S60.Fs, S60.Tp);
    leakage{sequence_idx} = sarvalid.leakage_metrics( ...
        RC_mix, reference_rc, cfg.diagnostics.support_threshold_ratio);
    for frame_idx = 1:frame_count
        columns = frame_columns(cfg.sequence, frame_idx);
        h_roi(:, :, frame_idx, sequence_idx) = single( ...
            sarvalid.focus_base_rc(RC_H_aligned(:, columns), S60, roi_size));
        l_roi(:, :, frame_idx, sequence_idx) = single( ...
            sarvalid.focus_base_rc(RC_L(:, columns), S60, roi_size));
        mixed_roi(:, :, frame_idx, sequence_idx) = single( ...
            sarvalid.focus_base_rc(RC_mix(:, columns), S60, roi_size));
    end
end

scene = string(scene_manifest.Scene(1));
h_stats = modality_stats(scene, "H", h_roi, v3, ...
    sequence_count * frame_count);
l_stats = modality_stats(scene, "L", l_roi, v3, ...
    sequence_count * frame_count);
norm_stats = [gt_cache.norm_stats; h_stats; l_stats];

sequence_detail = table();
frame_detail = table();
overlap_detail = table();
first_input = [];
first_gt = [];
for sequence_idx = 1:sequence_count
    [input_sequence, gt_sequence] = ...
        sarvalid.normalize_range_sft_v3_sequence( ...
        mixed_roi(:, :, :, sequence_idx), ...
        gt_cache.gt_roi(:, :, :, sequence_idx), mask.h_ratio, ...
        gt_cache.norm_stats, h_stats, l_stats, v3.metric_patch_size);

    [frame_rows, summary, overlap_rows] = sarvalid.sequence_metrics( ...
        input_sequence, gt_sequence, mask.frames);
    boundary = sarvalid.boundary_gradient_excess( ...
        input_sequence, gt_sequence, mask.frames);
    sequence_row = make_sequence_row( ...
        scene_manifest(sequence_idx, :), pair, summary, boundary, ...
        leakage{sequence_idx}, mix_meta{sequence_idx});
    sequence_detail = append_table(sequence_detail, sequence_row);
    if options.CollectDetails
        frame_detail = append_table(frame_detail, prefix_frame_rows( ...
            frame_rows, scene_manifest(sequence_idx, :), pair));
        overlap_detail = append_table(overlap_detail, prefix_overlap_rows( ...
            overlap_rows, scene_manifest(sequence_idx, :), pair));
        if sequence_idx == 1
            first_input = input_sequence;
            first_gt = gt_sequence;
        end
    end
end

scene_metrics = summarize_scene(sequence_detail, pair);
if options.CollectDetails && strlength(options.ContactDirectory) > 0
    sarvalid.ensure_dir(options.ContactDirectory);
    contact_path = fullfile(options.ContactDirectory, ...
        safe_name(scene) + "_seq" + ...
        string(scene_manifest.SequenceID(1)) + ".png");
    sarvalid.save_sequence_contact_sheet( ...
        contact_path, first_input, first_gt, pair.file_key);
end
result = struct("scene_metrics", scene_metrics, ...
    "normalization", prefix_norm_stats(norm_stats, pair), ...
    "sequence_detail", sequence_detail, "frame_detail", frame_detail, ...
    "overlap_detail", overlap_detail);
end

function stats = modality_stats(scene, modality, values, v3, sample_count)
limits = prctile(values(:), [v3.low_percentile, v3.high_percentile]);
VMin = double(limits(1));
VMax = double(limits(2));
if ~isfinite(VMin) || ~isfinite(VMax) || VMax <= VMin
    error('sarvalid:V3DegenerateNormalization', ...
        '场景%s模态%s的候选归一化范围无效。', scene, modality);
end
Scene = scene;
Modality = modality;
SampleCount = sample_count;
PixelCount = numel(values);
LowPercentile = v3.low_percentile;
HighPercentile = v3.high_percentile;
stats = table(Scene, Modality, VMin, VMax, SampleCount, ...
    PixelCount, LowPercentile, HighPercentile);
end

function row = make_sequence_row(manifest_row, pair, summary, boundary, leakage, mix)
SequenceID = manifest_row.SequenceID;
Scene = string(manifest_row.Scene);
PairKey = string(pair.file_key);
QHigh = pair.q_high;
QLow = pair.q_low;
STRdB = pair.H.threshold.STR_dB;
FrOverBr = pair.H.threshold.fr_over_Br;
FaOverBa = pair.H.threshold.fa_over_Ba;
MeanPSNR = summary.mean_psnr;
MeanSSIM = summary.mean_ssim;
WorstPSNR = summary.worst_psnr;
WorstSSIM = summary.worst_ssim;
HRegionPSNR = summary.h_region_psnr;
HRegionSSIM = summary.h_region_ssim;
LRegionPSNR = summary.l_region_psnr;
LRegionSSIM = summary.l_region_ssim;
GradientRMSE = summary.mean_gradient_rmse;
BrightScattererError = summary.mean_bright_scatterer_error;
PSNRSmoothness = summary.psnr_smoothness;
SSIMSmoothness = summary.ssim_smoothness;
OverlapExcessRMSE = summary.overlap_excess_rmse;
OverlapExcessSSIMLoss = summary.overlap_excess_ssim_loss;
BoundaryGradientExcess = boundary.mean_excess;
BoundaryGradientRatio = boundary.mean_ratio;
OffSupportRatio = leakage.off_support_ratio;
RangeLeakageRatio = leakage.range_leakage_ratio;
AzimuthLeakageRatio = leakage.azimuth_leakage_ratio;
EnergyScaleFactor = mix.scale_factor;
BoundaryJumpDB = mix.boundary_jump_db;
row = table(SequenceID, Scene, PairKey, QHigh, QLow, STRdB, ...
    FrOverBr, FaOverBa, MeanPSNR, MeanSSIM, WorstPSNR, WorstSSIM, ...
    HRegionPSNR, HRegionSSIM, LRegionPSNR, LRegionSSIM, ...
    GradientRMSE, BrightScattererError, PSNRSmoothness, ...
    SSIMSmoothness, OverlapExcessRMSE, OverlapExcessSSIMLoss, ...
    BoundaryGradientExcess, BoundaryGradientRatio, OffSupportRatio, ...
    RangeLeakageRatio, AzimuthLeakageRatio, EnergyScaleFactor, BoundaryJumpDB);
end

function row = summarize_scene(sequence_detail, pair)
Stage = "";
PairKey = string(pair.file_key);
QHigh = pair.q_high;
QLow = pair.q_low;
STRdB = pair.H.threshold.STR_dB;
FrOverBr = pair.H.threshold.fr_over_Br;
FaOverBa = pair.H.threshold.fa_over_Ba;
Scene = string(sequence_detail.Scene(1));
SequenceCount = height(sequence_detail);
MeanPSNR = mean(sequence_detail.MeanPSNR);
MeanSSIM = mean(sequence_detail.MeanSSIM);
WorstPSNR = mean(sequence_detail.WorstPSNR);
WorstSSIM = mean(sequence_detail.WorstSSIM);
HRegionSSIM = mean(sequence_detail.HRegionSSIM, 'omitnan');
LRegionSSIM = mean(sequence_detail.LRegionSSIM, 'omitnan');
GradientRMSE = mean(sequence_detail.GradientRMSE);
BrightScattererError = mean(sequence_detail.BrightScattererError);
BoundaryGradientExcess = mean(sequence_detail.BoundaryGradientExcess);
OverlapExcessSSIMLoss = mean(sequence_detail.OverlapExcessSSIMLoss);
RangeLeakageRatio = mean(sequence_detail.RangeLeakageRatio);
AzimuthLeakageRatio = mean(sequence_detail.AzimuthLeakageRatio);
row = table(Stage, PairKey, QHigh, QLow, STRdB, FrOverBr, FaOverBa, ...
    Scene, SequenceCount, MeanPSNR, MeanSSIM, WorstPSNR, WorstSSIM, ...
    HRegionSSIM, LRegionSSIM, GradientRMSE, BrightScattererError, ...
    BoundaryGradientExcess, OverlapExcessSSIMLoss, ...
    RangeLeakageRatio, AzimuthLeakageRatio);
end

function rows = prefix_norm_stats(stats, pair)
count = height(stats);
PairKey = repmat(string(pair.file_key), count, 1);
QHigh = repmat(pair.q_high, count, 1);
QLow = repmat(pair.q_low, count, 1);
STRdB = repmat(pair.H.threshold.STR_dB, count, 1);
FrOverBr = repmat(pair.H.threshold.fr_over_Br, count, 1);
FaOverBa = repmat(pair.H.threshold.fa_over_Ba, count, 1);
rows = addvars(stats, PairKey, QHigh, QLow, STRdB, FrOverBr, ...
    FaOverBa, 'Before', 1);
end

function rows = prefix_frame_rows(rows, manifest_row, pair)
count = height(rows);
SequenceID = repmat(manifest_row.SequenceID, count, 1);
Scene = repmat(string(manifest_row.Scene), count, 1);
PairKey = repmat(string(pair.file_key), count, 1);
QHigh = repmat(pair.q_high, count, 1);
QLow = repmat(pair.q_low, count, 1);
rows = addvars(rows, SequenceID, Scene, PairKey, QHigh, QLow, 'Before', 1);
end

function rows = prefix_overlap_rows(rows, manifest_row, pair)
rows = prefix_frame_rows(rows, manifest_row, pair);
end

function columns = frame_columns(sequence_cfg, frame_idx)
start_idx = 1 + (frame_idx - 1) * sequence_cfg.step;
columns = start_idx:start_idx + sequence_cfg.signal_width - 1;
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
