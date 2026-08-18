function result = evaluate_hlh_normalization_scene( ...
        cfg, S60, scene_manifest, pair, output_context)
%EVALUATE_HLH_NORMALIZATION_SCENE 在相同原始成像结果上比较两种归一化。

arguments
    cfg (1, 1) struct
    S60 (1, 1) struct
    scene_manifest table
    pair (1, 1) struct
    output_context.ContactDirectory (1, 1) string = ""
    output_context.CaseLabel (1, 1) string = "main35"
end

ablation = cfg.hlh_normalization_ablation;
frame_count = cfg.sequence.n_frames;
sequence_count = height(scene_manifest);
roi_size = ablation.normalization_roi_size;
mask = sarvalid.build_hlh_mask(cfg.sequence);

gt_roi = zeros(roi_size, roi_size, frame_count, sequence_count, 'single');
h_roi = zeros(size(gt_roi), 'single');
l_roi = zeros(size(gt_roi), 'single');
mixed_roi = zeros(size(gt_roi), 'single');
mix_meta = cell(sequence_count, 1);
leakage = cell(sequence_count, 1);

for sequence_idx = 1:sequence_count
    signal = sarvalid.load_echo_block( ...
        scene_manifest(sequence_idx, :), S60, cfg.sequence.block_width);
    [RC_H, ~] = sarvalid.generate_base_rc(signal, S60, pair.H);
    [RC_L, ~] = sarvalid.generate_base_rc(signal, S60, pair.L);
    [RC_mix, mix_meta{sequence_idx}] = sarvalid.align_and_mix_rc( ...
        RC_H, RC_L, mask.full, ablation.energy_buffer);
    RC_H_aligned = RC_H * mix_meta{sequence_idx}.scale_factor;
    reference_rc = Range_Compress(signal, S60.fc, S60.tnrn, ...
        S60.gama, S60.R0, S60.C, S60.Fs, S60.Tp);
    leakage{sequence_idx} = sarvalid.leakage_metrics( ...
        RC_mix, reference_rc, cfg.diagnostics.support_threshold_ratio);

    for frame_idx = 1:frame_count
        columns = frame_columns(cfg.sequence, frame_idx);
        gt_roi(:, :, frame_idx, sequence_idx) = single( ...
            sarvalid.generate_gt_image(signal(:, columns), S60, roi_size));
        h_roi(:, :, frame_idx, sequence_idx) = single( ...
            sarvalid.focus_base_rc( ...
            RC_H_aligned(:, columns), S60, roi_size));
        l_roi(:, :, frame_idx, sequence_idx) = single( ...
            sarvalid.focus_base_rc(RC_L(:, columns), S60, roi_size));
        mixed_roi(:, :, frame_idx, sequence_idx) = single( ...
            sarvalid.focus_base_rc(RC_mix(:, columns), S60, roi_size));
    end
end

image_count = sequence_count * frame_count;
gt_stats = percentile_stats(gt_roi, ablation, "GT", image_count);
h_stats = percentile_stats(h_roi, ablation, "H", image_count);
l_stats = percentile_stats(l_roi, ablation, "L", image_count);
% H和L像素数严格相同，连接后计算分位数即为等权联合像素池。
joint_pool = [h_roi(:); l_roi(:)];
joint_stats = percentile_stats( ...
    joint_pool, ablation, "JointHL", 2 * image_count);
clear joint_pool;

scene = string(scene_manifest.Scene(1));
normalization = table();
normalization = append_table(normalization, ...
    stats_row(scene, pair, "legacy_split", gt_stats));
normalization = append_table(normalization, ...
    stats_row(scene, pair, "legacy_split", h_stats));
normalization = append_table(normalization, ...
    stats_row(scene, pair, "legacy_split", l_stats));
normalization = append_table(normalization, ...
    stats_row(scene, pair, "joint_hl_shared", gt_stats));
normalization = append_table(normalization, ...
    stats_row(scene, pair, "joint_hl_shared", joint_stats));

per_frame = table();
sequence_summary = table();
first_inputs = cell(numel(ablation.policies), 1);
first_gt = [];
for policy_idx = 1:numel(ablation.policies)
    policy = string(ablation.policies(policy_idx));
    for sequence_idx = 1:sequence_count
        [input_sequence, gt_sequence, input_ranges] = ...
            sarvalid.normalize_hlh_with_policy( ...
            mixed_roi(:, :, :, sequence_idx), ...
            gt_roi(:, :, :, sequence_idx), mask.h_ratio, ...
            gt_stats, h_stats, l_stats, joint_stats, policy, ...
            ablation.metric_patch_size);
        [frame_rows, summary, overlap_rows] = sarvalid.sequence_metrics( ...
            input_sequence, gt_sequence, mask.frames);
        boundary = sarvalid.boundary_gradient_excess( ...
            input_sequence, gt_sequence, mask.frames);
        frame_rows = prefix_frame_rows(frame_rows, input_ranges, ...
            scene_manifest(sequence_idx, :), pair, policy, ...
            output_context.CaseLabel, mask.h_ratio);
        per_frame = append_table(per_frame, frame_rows);
        sequence_row = make_sequence_row( ...
            scene_manifest(sequence_idx, :), pair, policy, ...
            output_context.CaseLabel, summary, boundary, ...
            leakage{sequence_idx}, mix_meta{sequence_idx}, ...
            overlap_rows, frame_rows);
        sequence_summary = append_table(sequence_summary, sequence_row);
        if sequence_idx == 1
            first_inputs{policy_idx} = input_sequence;
            first_gt = gt_sequence;
        end
    end
end

if strlength(output_context.ContactDirectory) > 0
    sarvalid.ensure_dir(output_context.ContactDirectory);
    for policy_idx = 1:numel(ablation.policies)
        policy = string(ablation.policies(policy_idx));
        contact_name = safe_name(output_context.CaseLabel + "_" + scene + ...
            "_" + policy + "_seq" + ...
            string(scene_manifest.SequenceID(1))) + ".png";
        sarvalid.save_sequence_contact_sheet( ...
            fullfile(output_context.ContactDirectory, contact_name), ...
            first_inputs{policy_idx}, first_gt, ...
            string(pair.file_key) + " / " + policy);
    end
end

result = struct("per_frame", per_frame, ...
    "sequence_summary", sequence_summary, ...
    "normalization", normalization);
end

function row = make_sequence_row(manifest_row, pair, policy, case_label, ...
        summary, boundary, leakage, mix, overlap_rows, frame_rows)
CaseLabel = case_label;
Policy = policy;
SequenceID = manifest_row.SequenceID;
Scene = string(manifest_row.Scene);
PairKey = string(pair.file_key);
QHigh = pair.q_high;
QLow = pair.q_low;
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
OverlapExcessRMSE = mean(overlap_rows.ExcessRMSE);
OverlapExcessSSIMLoss = mean(overlap_rows.ExcessSSIMLoss);
BoundaryGradientExcess = boundary.mean_excess;
BoundaryGradientRatio = boundary.mean_ratio;
OffSupportRatio = leakage.off_support_ratio;
RangeLeakageRatio = leakage.range_leakage_ratio;
AzimuthLeakageRatio = leakage.azimuth_leakage_ratio;
EnergyScaleFactor = mix.scale_factor;
BoundaryJumpDB = mix.boundary_jump_db;
LeftPSNRJump = abs(frame_rows.PSNR(1) - frame_rows.PSNR(2));
RightPSNRJump = abs(frame_rows.PSNR(end) - frame_rows.PSNR(end-1));
LeftSSIMJump = abs(frame_rows.SSIM(1) - frame_rows.SSIM(2));
RightSSIMJump = abs(frame_rows.SSIM(end) - frame_rows.SSIM(end-1));
F4PSNR = frame_rows.PSNR(5);
F4SSIM = frame_rows.SSIM(5);
[~, psnr_minimum_index] = min(frame_rows.PSNR);
[~, ssim_minimum_index] = min(frame_rows.SSIM);
PSNRMinimumFrame = frame_rows.FrameIdx(psnr_minimum_index);
SSIMMinimumFrame = frame_rows.FrameIdx(ssim_minimum_index);
PSNRShapeAnomaly = PSNRMinimumFrame < 3 || PSNRMinimumFrame > 5;
SSIMShapeAnomaly = SSIMMinimumFrame < 3 || SSIMMinimumFrame > 5;
row = table(CaseLabel, Policy, SequenceID, Scene, PairKey, QHigh, QLow, ...
    MeanPSNR, MeanSSIM, WorstPSNR, WorstSSIM, ...
    HRegionPSNR, HRegionSSIM, LRegionPSNR, LRegionSSIM, ...
    GradientRMSE, BrightScattererError, PSNRSmoothness, ...
    SSIMSmoothness, OverlapExcessRMSE, OverlapExcessSSIMLoss, ...
    BoundaryGradientExcess, BoundaryGradientRatio, OffSupportRatio, ...
    RangeLeakageRatio, AzimuthLeakageRatio, EnergyScaleFactor, ...
    BoundaryJumpDB, LeftPSNRJump, RightPSNRJump, LeftSSIMJump, ...
    RightSSIMJump, F4PSNR, F4SSIM, PSNRMinimumFrame, ...
    SSIMMinimumFrame, PSNRShapeAnomaly, SSIMShapeAnomaly);
end

function rows = prefix_frame_rows(rows, input_ranges, manifest_row, pair, ...
        policy, case_label, h_ratio)
count = height(rows);
CaseLabel = repmat(case_label, count, 1);
Policy = repmat(policy, count, 1);
SequenceID = repmat(manifest_row.SequenceID, count, 1);
Scene = repmat(string(manifest_row.Scene), count, 1);
PairKey = repmat(string(pair.file_key), count, 1);
QHigh = repmat(pair.q_high, count, 1);
QLow = repmat(pair.q_low, count, 1);
HRatio = h_ratio(:);
InputVMin = input_ranges.VMin;
InputVMax = input_ranges.VMax;
rows = addvars(rows, CaseLabel, Policy, SequenceID, Scene, PairKey, ...
    QHigh, QLow, HRatio, InputVMin, InputVMax, 'Before', 1);
end

function row = stats_row(scene, pair, policy, stats)
Policy = policy;
Scene = scene;
PairKey = string(pair.file_key);
QHigh = pair.q_high;
QLow = pair.q_low;
Modality = stats.Modality;
VMin = stats.VMin;
VMax = stats.VMax;
ImageCount = stats.ImageCount;
PixelCount = stats.PixelCount;
LowPercentile = stats.LowPercentile;
HighPercentile = stats.HighPercentile;
row = table(Policy, Scene, PairKey, QHigh, QLow, Modality, ...
    VMin, VMax, ImageCount, PixelCount, LowPercentile, HighPercentile);
end

function stats = percentile_stats(values, config, modality, image_count)
limits = prctile(values(:), ...
    [config.low_percentile, config.high_percentile]);
stats = struct("Modality", modality, "VMin", double(limits(1)), ...
    "VMax", double(limits(2)), "ImageCount", image_count, ...
    "PixelCount", numel(values), ...
    "LowPercentile", config.low_percentile, ...
    "HighPercentile", config.high_percentile);
if ~isfinite(stats.VMin) || ~isfinite(stats.VMax) || ...
        stats.VMax <= stats.VMin
    error('sarvalid:DegenerateHLHNormalizationStats', ...
        '%s联合归一化统计无效。', modality);
end
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
