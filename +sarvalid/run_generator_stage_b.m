function outputs = run_generator_stage_b( ...
        cfg, S60, manifest, locked_generators, protocol)
%RUN_GENERATOR_STAGE_B 对锁定生成器执行九帧连续序列验证。

if nargin < 5
    protocol = struct();
end
stage_dir = get_field(protocol, "output_dir", ...
    fullfile(cfg.generator_compare.output_root, "stage_b"));
resume = get_field(protocol, "resume", cfg.generator_compare.resume);
sarvalid.ensure_dir(stage_dir);
calibration_manifest = manifest(manifest.Split == "calibration", :);
evaluation_manifest = manifest(manifest.Split == "evaluation", :);

all_seed_detail = table();
all_sequence_summary = table();
all_frame_detail = table();
all_overlap_detail = table();
normalization_records = cell(numel(locked_generators), 1);

for lock_idx = 1:numel(locked_generators)
    lock = locked_generators{lock_idx};
    pair = lock.pair_cfg;
    task_dir = fullfile(stage_dir, string(pair.file_key));
    sarvalid.ensure_dir(task_dir);
    sarvalid.ensure_dir(fullfile(task_dir, "contact_sheets"));
    sarvalid.ensure_dir(fullfile(task_dir, "representative_rc"));

    [norm_stats, norm_audit] = calibrate_normalization( ...
        calibration_manifest, pair, lock.seed_families, S60, cfg);
    normalization_records{lock_idx} = norm_stats;
    writetable(norm_stats, fullfile(task_dir, "normalization.csv"));

    signature = stage_b_signature(cfg, S60, pair, ...
        lock.seed_families, evaluation_manifest, norm_stats, protocol);
    checkpoint_path = string(fullfile(task_dir, "sequence_checkpoint.mat"));
    initial = struct("completed_keys", strings(0, 1), ...
        "seed_detail", table(), "frame_detail", table(), ...
        "overlap_detail", table());
    if resume
        state = sarvalid.load_checkpoint(checkpoint_path, signature, initial);
    else
        state = initial;
        state.signature = signature;
    end

    for sequence_idx = 1:height(evaluation_manifest)
        sequence_id = evaluation_manifest.SequenceID(sequence_idx);
        for seed_idx = 1:numel(lock.seed_families)
            seed_family = lock.seed_families(seed_idx);
            completion_key = "seq" + sequence_id + "_seed" + seed_family;
            if any(state.completed_keys == completion_key)
                continue;
            end

            sequence_pair = derive_sequence_seed( ...
                pair, seed_family, sequence_id);
            signal = sarvalid.load_echo_block( ...
                evaluation_manifest(sequence_idx, :), S60, ...
                cfg.sequence.block_width);
            context = struct("return_rc_mix", true);
            [raw_sequence, meta] = sarvalid.generate_hlh_sequence( ...
                signal, S60, sequence_pair, context);
            scene = string(evaluation_manifest.Scene(sequence_idx));
            normalized = sarvalid.normalize_sequence( ...
                raw_sequence, norm_stats, scene);
            [frame_rows, summary, overlap_rows] = ...
                sarvalid.sequence_metrics(normalized.input, normalized.gt, ...
                raw_sequence.frame_masks);
            boundary = sarvalid.boundary_gradient_excess( ...
                normalized.input, normalized.gt, raw_sequence.frame_masks);
            reference_rc = Range_Compress(signal, S60.fc, S60.tnrn, ...
                S60.gama, S60.R0, S60.C, S60.Fs, S60.Tp);
            leakage = sarvalid.leakage_metrics(meta.rc_mix, reference_rc, ...
                cfg.diagnostics.support_threshold_ratio);

            seed_row = sequence_seed_row( ...
                evaluation_manifest(sequence_idx, :), pair, ...
                seed_family, lock.seed_families, summary, ...
                boundary, leakage, meta.mix);
            frame_rows = prefix_detail(frame_rows, ...
                evaluation_manifest(sequence_idx, :), pair, seed_family);
            overlap_rows = prefix_detail(overlap_rows, ...
                evaluation_manifest(sequence_idx, :), pair, seed_family);
            assert_finite_required(seed_row);
            state.seed_detail = append_table(state.seed_detail, seed_row);
            state.frame_detail = append_table(state.frame_detail, frame_rows);
            state.overlap_detail = append_table( ...
                state.overlap_detail, overlap_rows);

            % 视觉审计固定为每场景首条evaluation序列的第一个预注册seed。
            if seed_idx == 1 && is_first_scene_sequence( ...
                    evaluation_manifest, sequence_idx)
                sheet_path = fullfile(task_dir, "contact_sheets", ...
                    sprintf('%s_seq%03d_seed%s.png', scene, ...
                    sequence_id, encode(seed_family)));
                sarvalid.save_sequence_contact_sheet(sheet_path, ...
                    normalized.input, normalized.gt, pair.file_key);
                if cfg.diagnostics.save_representative_rc
                    RC_mix = meta.rc_mix;
                    save(fullfile(task_dir, "representative_rc", ...
                        sprintf('%s_seq%03d_seed%s.mat', scene, ...
                        sequence_id, encode(seed_family))), ...
                        "RC_mix", "reference_rc", "-v7.3");
                end
            end

            state.completed_keys(end+1, 1) = completion_key;
            sarvalid.atomic_save(checkpoint_path, struct("state", state));
        end
    end

    sequence_summary = aggregate_sequence_seeds(state.seed_detail);
    writetable(state.seed_detail, fullfile(task_dir, "sequence_seed_detail.csv"));
    writetable(sequence_summary, fullfile(task_dir, "sequence_summary.csv"));
    writetable(state.frame_detail, fullfile(task_dir, "per_frame_metrics.csv"));
    writetable(state.overlap_detail, fullfile(task_dir, "overlap_metrics.csv"));
    save(fullfile(task_dir, "stage_b_task.mat"), "pair", "norm_stats", ...
        "norm_audit", "state", "sequence_summary", "-v7.3");

    all_seed_detail = append_table(all_seed_detail, state.seed_detail);
    all_sequence_summary = append_table( ...
        all_sequence_summary, sequence_summary);
    all_frame_detail = append_table(all_frame_detail, state.frame_detail);
    all_overlap_detail = append_table( ...
        all_overlap_detail, state.overlap_detail);
end

writetable(all_seed_detail, fullfile(stage_dir, "sequence_seed_detail.csv"));
writetable(all_sequence_summary, fullfile(stage_dir, "sequence_summary.csv"));
writetable(all_frame_detail, fullfile(stage_dir, "per_frame_metrics.csv"));
writetable(all_overlap_detail, fullfile(stage_dir, "overlap_metrics.csv"));
save(fullfile(stage_dir, "stage_b_final.mat"), ...
    "all_seed_detail", "all_sequence_summary", "all_frame_detail", ...
    "all_overlap_detail", "normalization_records", "-v7.3");

outputs = struct("seed_detail", all_seed_detail, ...
    "sequence_summary", all_sequence_summary, ...
    "frame_detail", all_frame_detail, ...
    "overlap_detail", all_overlap_detail, ...
    "normalization", {normalization_records});
end

function [norm_stats, norm_audit] = calibrate_normalization( ...
        manifest, pair, seed_families, S60, cfg)
case_count = height(manifest) * numel(seed_families);
sequences = cell(case_count, 1);
manifest_indices = zeros(case_count, 1);
SeedFamily = zeros(case_count, 1);
ptr = 0;
for seed_family = seed_families
    for idx = 1:height(manifest)
        ptr = ptr + 1;
        sequence_pair = derive_sequence_seed( ...
            pair, seed_family, manifest.SequenceID(idx));
        signal = sarvalid.load_echo_block( ...
            manifest(idx, :), S60, cfg.sequence.block_width);
        sequences{ptr} = sarvalid.generate_hlh_sequence( ...
            signal, S60, sequence_pair);
        manifest_indices(ptr) = idx;
        SeedFamily(ptr) = seed_family;
    end
end
expanded_manifest = manifest(manifest_indices, :);
expanded_manifest = addvars(expanded_manifest, SeedFamily, ...
    'After', "SequenceID", 'NewVariableNames', "SeedFamily");
[norm_stats, norm_audit] = sarvalid.fit_sequence_normalization( ...
    sequences, expanded_manifest, cfg);
end

function pair = derive_sequence_seed(pair, seed_family, sequence_id)
% 同一family下H/L共享随机族，但用稳定的不同偏移避免阈值完全相同。
pair.H.seed = seed_family + sequence_id * 1000;
pair.L.seed = seed_family + sequence_id * 1000 + 1;
end

function signature = stage_b_signature( ...
        cfg, S60, pair, seeds, manifest, norm_stats, protocol)
high = sarvalid.resolve_acquisition(pair.H, ...
    [cfg.sequence.signal_height, cfg.sequence.block_width], S60);
low = sarvalid.resolve_acquisition(pair.L, ...
    [cfg.sequence.signal_height, cfg.sequence.block_width], S60);
experiment = get_field(protocol, "experiment", ...
    cfg.experiment_name + "_generator_compare");
signature_context = get_field(protocol, "signature_context", struct());
signature = struct("experiment", experiment, ...
    "stage", "generator_stage_b", "pair", pair, ...
    "rt_seed_families", seeds, ...
    "effective_grid_H", compact_grid(high), ...
    "effective_grid_L", compact_grid(low), ...
    "manifest", manifest(:, ["SequenceID", "Scene", "File", "CStart"]), ...
    "normalization", norm_stats, ...
    "normalization_protocol", cfg.normalization, ...
    "sequence", cfg.sequence, "signature_context", signature_context, ...
    "imaging", imaging_signature(S60));
end

function row = sequence_seed_row( ...
        manifest_row, pair, seed_family, all_seeds, ...
        summary, boundary, leakage, mix)
SequenceID = manifest_row.SequenceID;
Scene = string(manifest_row.Scene);
Method = string(pair.method);
PairKey = string(pair.file_key);
QHigh = pair.q_high;
QLow = pair.q_low;
Alpha = pair.alpha;
As = pair.H.threshold.As;
SeedFamily = seed_family;
SeedFamilies = strjoin(string(all_seeds), ";");
MeanPSNR = summary.mean_psnr;
MeanSSIM = summary.mean_ssim;
WorstPSNR = summary.worst_psnr;
WorstSSIM = summary.worst_ssim;
GradientRMSE = summary.mean_gradient_rmse;
BrightScattererError = summary.mean_bright_scatterer_error;
HRegionPSNR = summary.h_region_psnr;
HRegionSSIM = summary.h_region_ssim;
LRegionPSNR = summary.l_region_psnr;
LRegionSSIM = summary.l_region_ssim;
UDepthPSNR = summary.u_depth_psnr;
UDepthSSIM = summary.u_depth_ssim;
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
row = table(SequenceID, Scene, Method, PairKey, QHigh, QLow, ...
    Alpha, As, SeedFamily, SeedFamilies, MeanPSNR, MeanSSIM, ...
    WorstPSNR, WorstSSIM, ...
    GradientRMSE, BrightScattererError, HRegionPSNR, HRegionSSIM, ...
    LRegionPSNR, LRegionSSIM, UDepthPSNR, UDepthSSIM, ...
    PSNRSmoothness, SSIMSmoothness, OverlapExcessRMSE, ...
    OverlapExcessSSIMLoss, BoundaryGradientExcess, ...
    BoundaryGradientRatio, OffSupportRatio, RangeLeakageRatio, ...
    AzimuthLeakageRatio, EnergyScaleFactor, BoundaryJumpDB);
end

function output = prefix_detail(input, manifest_row, pair, seed_family)
count = height(input);
output = addvars(input, ...
    repmat(manifest_row.SequenceID, count, 1), ...
    repmat(string(manifest_row.Scene), count, 1), ...
    repmat(string(pair.method), count, 1), ...
    repmat(string(pair.file_key), count, 1), ...
    repmat(pair.q_high, count, 1), repmat(pair.q_low, count, 1), ...
    repmat(seed_family, count, 1), ...
    'Before', 1, 'NewVariableNames', ...
    ["SequenceID", "Scene", "Method", "PairKey", ...
    "QHigh", "QLow", "SeedFamily"]);
end

function output = aggregate_sequence_seeds(input)
key_names = ["SequenceID", "Scene", "Method", "PairKey", ...
    "QHigh", "QLow", "Alpha", "As", "SeedFamilies"];
output = sarvalid.aggregate_seed_replicates( ...
    input, key_names, "SeedFamily");
end

function yes = is_first_scene_sequence(manifest, idx)
yes = ~any(manifest.Scene(1:idx-1) == manifest.Scene(idx));
end

function compact = compact_grid(grid)
compact = struct("q_total", grid.q_total, "q_range", grid.q_range, ...
    "q_azimuth", grid.q_azimuth, ...
    "q_range_eff", grid.q_range_eff, ...
    "q_azimuth_eff", grid.q_azimuth_eff, ...
    "q_total_eff", grid.q_total_eff, ...
    "upsampled_size", grid.upsampled_size, ...
    "Fs_up", grid.Fs_up, "PRF_up", grid.PRF_up);
end

function assert_finite_required(row)
required = ["MeanPSNR", "MeanSSIM", "WorstPSNR", "WorstSSIM", ...
    "GradientRMSE", "BrightScattererError", "HRegionSSIM", ...
    "LRegionSSIM", "UDepthSSIM", "OverlapExcessSSIMLoss", ...
    "BoundaryJumpDB"];
for name = required
    if ~isfinite(row.(name))
        error('sarvalid:NonfiniteGeneratorSequence', ...
            '连续序列指标%s包含非有限值。', name);
    end
end
end

function signature = imaging_signature(S60)
names = ["fc", "B", "Fs", "prf", "R0", "C", "v", ...
    "Tp", "Ta", "nrn", "nan", "R_total", "A_num"];
signature = struct();
for name = names
    if isfield(S60, name)
        signature.(name) = S60.(name);
    end
end
end

function value = encode(number)
value = string(sprintf('%.12g', number));
value = replace(value, "-", "m");
value = replace(value, ".", "p");
value = replace(value, "+", "");
end

function output = append_table(input, rows)
if isempty(input)
    output = rows;
else
    output = [input; rows];
end
end

function value = get_field(input, name, default_value)
if isfield(input, name)
    value = input.(name);
else
    value = default_value;
end
end
