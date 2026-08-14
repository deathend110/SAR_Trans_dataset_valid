function outputs = run_stage_b_sequence_validation(cfg)
%RUN_STAGE_B_SEQUENCE_VALIDATION 运行连续全块H/L/H九帧验证与framewise消融。

arguments
    cfg (1, 1) struct = sarvalid.default_config()
end

addpath(cfg.repo_root);
sarvalid.ensure_dir(cfg.stage_b.output_dir);
S60 = load(cfg.parameter_file_60);
manifest = sarvalid.build_stage_b_manifest(cfg);
writetable(manifest, fullfile(cfg.stage_b.output_dir, "stage_b_manifest.csv"));
sarvalid.write_json(fullfile(cfg.stage_b.output_dir, "config.json"), cfg);
save(fullfile(cfg.stage_b.output_dir, "config.mat"), "cfg", "S60");

if cfg.runtime.dry_run
    outputs = struct("cfg", cfg, "manifest", manifest, ...
        "summary", table(), "ranked", table());
    fprintf('Stage B dry-run完成：calibration=%d，evaluation=%d。\n', ...
        sum(manifest.Split == "calibration"), sum(manifest.Split == "evaluation"));
    return;
end

stage_a_path = fullfile(cfg.stage_a.output_dir, "stage_a_final.mat");
if ~isfile(stage_a_path)
    error('sarvalid:MissingStageAResult', ...
        'Stage B需要先完成Stage A锁参：%s', stage_a_path);
end
stage_a = load(stage_a_path, "locked_configs");
locked_configs = stage_a.locked_configs;
calibration_manifest = manifest(manifest.Split == "calibration", :);
evaluation_manifest = manifest(manifest.Split == "evaluation", :);

all_sequence_summary = table();
all_frame_detail = table();
all_overlap_detail = table();
all_ablation_summary = table();
config_summary = table();

for config_idx = 1:numel(locked_configs)
    pair_cfg = locked_configs{config_idx};
    task_dir = fullfile(cfg.stage_b.output_dir, pair_cfg.file_key);
    sarvalid.ensure_dir(task_dir);
    sarvalid.ensure_dir(fullfile(task_dir, "contact_sheets"));
    sarvalid.ensure_dir(fullfile(task_dir, "representative_rc"));

    fprintf('Stage B calibration：%s\n', pair_cfg.file_key);
    calibration_sequences = cell(height(calibration_manifest), 1);
    for idx = 1:height(calibration_manifest)
        sequence_pair = derive_sequence_seed( ...
            pair_cfg, calibration_manifest.SequenceID(idx));
        signal = sarvalid.load_echo_block( ...
            calibration_manifest(idx, :), S60, cfg.sequence.block_width);
        calibration_sequences{idx} = sarvalid.generate_hlh_sequence( ...
            signal, S60, sequence_pair);
    end
    [norm_stats, norm_audit] = sarvalid.fit_sequence_normalization( ...
        calibration_sequences, calibration_manifest, cfg);
    writetable(norm_stats, fullfile(task_dir, "normalization.csv"));

    signature = struct("experiment", cfg.experiment_name, "stage", "B", ...
        "pair_cfg", pair_cfg, "threshold_seed", cfg.threshold_seed, ...
        "effective_grid_H", compact_grid_signature( ...
            sarvalid.resolve_acquisition(pair_cfg.H, ...
            [cfg.sequence.signal_height, cfg.sequence.block_width], S60)), ...
        "effective_grid_L", compact_grid_signature( ...
            sarvalid.resolve_acquisition(pair_cfg.L, ...
            [cfg.sequence.signal_height, cfg.sequence.block_width], S60)), ...
        "manifest", evaluation_manifest(:, ...
        ["SequenceID", "Scene", "File", "CStart"]), ...
        "normalization", norm_stats, ...
        "normalization_protocol", cfg.normalization, ...
        "sequence", cfg.sequence, "imaging", imaging_signature(S60));
    initial = struct("completed_ids", zeros(0, 1), ...
        "sequence_summary", table(), "frame_detail", table(), ...
        "overlap_detail", table());
    checkpoint_path = fullfile(task_dir, "sequence_checkpoint.mat");
    state = sarvalid.load_checkpoint(checkpoint_path, signature, initial);

    for idx = 1:height(evaluation_manifest)
        sequence_id = evaluation_manifest.SequenceID(idx);
        if ismember(sequence_id, state.completed_ids)
            continue;
        end
        sequence_pair = derive_sequence_seed(pair_cfg, sequence_id);
        signal = sarvalid.load_echo_block( ...
            evaluation_manifest(idx, :), S60, cfg.sequence.block_width);
        context = struct("return_rc_mix", true);
        [raw_sequence, sequence_meta] = sarvalid.generate_hlh_sequence( ...
            signal, S60, sequence_pair, context);
        scene = evaluation_manifest.Scene(idx);
        normalized = sarvalid.normalize_sequence(raw_sequence, norm_stats, scene);
        [frame_table, summary, overlap_table] = sarvalid.sequence_metrics( ...
            normalized.input, normalized.gt);
        boundary = sarvalid.boundary_gradient_excess( ...
            normalized.input, normalized.gt, raw_sequence.frame_masks);
        reference_rc = Range_Compress(signal, S60.fc, S60.tnrn, ...
            S60.gama, S60.R0, S60.C, S60.Fs, S60.Tp);
        leakage = sarvalid.leakage_metrics(sequence_meta.rc_mix, ...
            reference_rc, cfg.diagnostics.support_threshold_ratio);

        summary_row = make_sequence_summary_row( ...
            evaluation_manifest(idx, :), pair_cfg, "sequence_global", ...
            summary, boundary, leakage, sequence_meta.mix);
        assert_finite_table(summary_row, "Stage B sequence summary");
        frame_table = prefix_frame_table(frame_table, ...
            evaluation_manifest(idx, :), pair_cfg, "sequence_global");
        overlap_table = prefix_overlap_table(overlap_table, ...
            evaluation_manifest(idx, :), pair_cfg, "sequence_global");
        state.sequence_summary = [state.sequence_summary; summary_row];
        state.frame_detail = [state.frame_detail; frame_table];
        state.overlap_detail = [state.overlap_detail; overlap_table];
        state.completed_ids(end+1, 1) = sequence_id;

        if is_first_evaluation_for_scene(evaluation_manifest, idx)
            sheet_path = fullfile(task_dir, "contact_sheets", ...
                sprintf('%s_seq%03d.png', scene, sequence_id));
            sarvalid.save_sequence_contact_sheet(sheet_path, ...
                normalized.input, normalized.gt, pair_cfg.file_key);
            if cfg.diagnostics.save_representative_rc
                RC_mix = sequence_meta.rc_mix;
                save(fullfile(task_dir, "representative_rc", ...
                    sprintf('%s_seq%03d.mat', scene, sequence_id)), ...
                    "RC_mix", "reference_rc", "-v7.3");
            end
        end
        % 只有指标和该序列要求的诊断产物全部成功后，才标记checkpoint完成。
        sarvalid.atomic_save(checkpoint_path, struct("state", state));
        fprintf('  sequence %d完成。\n', sequence_id);
    end

    writetable(state.sequence_summary, fullfile(task_dir, "sequence_summary.csv"));
    writetable(state.frame_detail, fullfile(task_dir, "per_frame_metrics.csv"));
    writetable(state.overlap_detail, fullfile(task_dir, "overlap_metrics.csv"));

    ablation_summary = table();
    framewise_norm_stats = table();
    if cfg.stage_b.run_framewise_ablation
        [ablation_summary, framewise_norm_stats] = run_framewise_ablation( ...
            calibration_manifest, pair_cfg, S60, cfg);
        writetable(ablation_summary, fullfile(task_dir, "framewise_ablation.csv"));
        writetable(framewise_norm_stats, ...
            fullfile(task_dir, "normalization_framewise.csv"));
    end

    task_summary = aggregate_config(pair_cfg, state.sequence_summary);
    all_sequence_summary = [all_sequence_summary; state.sequence_summary]; %#ok<AGROW>
    all_frame_detail = [all_frame_detail; state.frame_detail]; %#ok<AGROW>
    all_overlap_detail = [all_overlap_detail; state.overlap_detail]; %#ok<AGROW>
    all_ablation_summary = [all_ablation_summary; ablation_summary]; %#ok<AGROW>
    config_summary = [config_summary; task_summary]; %#ok<AGROW>
    save(fullfile(task_dir, "stage_b_task.mat"), ...
        "pair_cfg", "norm_stats", "norm_audit", "state", ...
        "framewise_norm_stats", "ablation_summary", "task_summary", "-v7.3");
end

ranked = sarvalid.pareto_rank(config_summary);
top_by_method = select_top_by_method(ranked);
writetable(all_sequence_summary, ...
    fullfile(cfg.stage_b.output_dir, "all_sequence_summary.csv"));
writetable(all_frame_detail, ...
    fullfile(cfg.stage_b.output_dir, "all_per_frame_metrics.csv"));
writetable(all_overlap_detail, ...
    fullfile(cfg.stage_b.output_dir, "all_overlap_metrics.csv"));
writetable(all_ablation_summary, ...
    fullfile(cfg.stage_b.output_dir, "all_framewise_ablation.csv"));
writetable(ranked, fullfile(cfg.stage_b.output_dir, "pareto_ranking.csv"));
writetable(top_by_method, ...
    fullfile(cfg.stage_b.output_dir, "top_candidate_per_method.csv"));

sensitivity_180 = table();
sensitivity_180_ranking = table();
if cfg.stage_b.run_180_sensitivity
    [sensitivity_180, sensitivity_180_ranking] = sarvalid.run_180_sensitivity( ...
        cfg, calibration_manifest, top_by_method, locked_configs, S60);
    writetable(sensitivity_180, ...
        fullfile(cfg.stage_b.output_dir, "sensitivity_180.csv"));
    writetable(sensitivity_180_ranking, ...
        fullfile(cfg.stage_b.output_dir, "sensitivity_180_ranking.csv"));
end
save(fullfile(cfg.stage_b.output_dir, "stage_b_final.mat"), ...
    "cfg", "manifest", "config_summary", "ranked", "top_by_method", ...
    "sensitivity_180", "sensitivity_180_ranking", "-v7.3");
outputs = struct("cfg", cfg, "manifest", manifest, ...
    "summary", config_summary, "ranked", ranked, ...
    "top_by_method", top_by_method, "sensitivity_180", sensitivity_180, ...
    "sensitivity_180_ranking", sensitivity_180_ranking);
end

function pair = derive_sequence_seed(pair, sequence_id)
pair.H.seed = pair.H.seed + sequence_id * 1000;
pair.L.seed = pair.L.seed + sequence_id * 1000 + 1;
end

function row = make_sequence_summary_row( ...
        manifest_row, pair, protocol, summary, boundary, leakage, mix)
SequenceID = manifest_row.SequenceID;
Scene = string(manifest_row.Scene);
Method = string(pair.method);
PairKey = string(pair.file_key);
Protocol = string(protocol);
MeanPSNR = summary.mean_psnr;
MeanSSIM = summary.mean_ssim;
WorstPSNR = summary.worst_psnr;
WorstSSIM = summary.worst_ssim;
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
row = table(SequenceID, Scene, Method, PairKey, Protocol, MeanPSNR, ...
    MeanSSIM, WorstPSNR, WorstSSIM, PSNRSmoothness, SSIMSmoothness, ...
    OverlapExcessRMSE, OverlapExcessSSIMLoss, BoundaryGradientExcess, ...
    BoundaryGradientRatio, OffSupportRatio, RangeLeakageRatio, ...
    AzimuthLeakageRatio, EnergyScaleFactor, BoundaryJumpDB);
end

function output = prefix_frame_table(input, manifest_row, pair, protocol)
count = height(input);
output = addvars(input, ...
    repmat(manifest_row.SequenceID, count, 1), ...
    repmat(string(manifest_row.Scene), count, 1), ...
    repmat(string(pair.method), count, 1), ...
    repmat(string(pair.file_key), count, 1), ...
    repmat(string(protocol), count, 1), ...
    'Before', 1, 'NewVariableNames', ...
    ["SequenceID", "Scene", "Method", "PairKey", "Protocol"]);
end

function output = prefix_overlap_table(input, manifest_row, pair, protocol)
output = prefix_frame_table(input, manifest_row, pair, protocol);
end

function yes = is_first_evaluation_for_scene(manifest, row_idx)
previous = manifest.Scene(1:row_idx-1);
yes = ~any(previous == manifest.Scene(row_idx));
end

function [rows, framewise_norm_stats] = run_framewise_ablation( ...
        manifest, pair, S60, cfg)
raw_sequences = cell(height(manifest), 1);
frame_metadata = cell(height(manifest), 1);
for idx = 1:height(manifest)
    sequence_pair = derive_sequence_seed(pair, manifest.SequenceID(idx));
    signal = sarvalid.load_echo_block(manifest(idx, :), S60, cfg.sequence.block_width);
    legacy_lcm = string(pair.method) == "Range_RT" && ...
        abs(pair.q_high - 2.5) < 1e-12 && abs(pair.q_low - 1.5) < 1e-12;
    context = struct("legacy_lcm", legacy_lcm, "legacy_seed", sequence_pair.H.seed);
    [raw_sequences{idx}, frame_metadata{idx}] = ...
        sarvalid.generate_hlh_sequence_framewise( ...
        signal, S60, sequence_pair, context);
end

% framewise是独立退化配置，必须由其自身标定序列拟合MIXED统计。
[framewise_norm_stats, ~] = sarvalid.fit_sequence_normalization( ...
    raw_sequences, manifest, cfg);
rows = table();
for idx = 1:height(manifest)
    raw_sequence = raw_sequences{idx};
    frame_meta = frame_metadata{idx};
    normalized = sarvalid.normalize_sequence( ...
        raw_sequence, framewise_norm_stats, manifest.Scene(idx));
    [~, summary, ~] = sarvalid.sequence_metrics(normalized.input, normalized.gt);
    boundary = sarvalid.boundary_gradient_excess( ...
        normalized.input, normalized.gt, raw_sequence.frame_masks);
    leakage = struct("off_support_ratio", NaN, ...
        "range_leakage_ratio", NaN, "azimuth_leakage_ratio", NaN);
    mix = struct("scale_factor", mean(frame_meta.scale_factors), ...
        "boundary_jump_db", NaN);
    row = make_sequence_summary_row( ...
        manifest(idx, :), pair, "framewise_legacy_style", ...
        summary, boundary, leakage, mix);
    rows = [rows; row]; %#ok<AGROW>
end
end

function compact = compact_grid_signature(grid)
compact = struct("q_total", grid.q_total, ...
    "q_range", grid.q_range, "q_azimuth", grid.q_azimuth, ...
    "q_range_eff", grid.q_range_eff, ...
    "q_azimuth_eff", grid.q_azimuth_eff, ...
    "q_total_eff", grid.q_total_eff, ...
    "upsampled_size", grid.upsampled_size, ...
    "Fs_up", grid.Fs_up, "PRF_up", grid.PRF_up);
end

function assert_finite_table(input, label)
for name = string(input.Properties.VariableNames)
    values = input.(name);
    if isnumeric(values) && any(~isfinite(values), 'all')
        error('sarvalid:NonfiniteOutput', '%s的%s列包含非有限值。', ...
            label, name);
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

function row = aggregate_config(pair, sequence_summary)
Method = string(pair.method);
PairKey = string(pair.file_key);
QHigh = pair.q_high;
QLow = pair.q_low;
Alpha = pair.alpha;
SequenceCount = height(sequence_summary);
MeanPSNR = mean(sequence_summary.MeanPSNR);
MeanSSIM = mean(sequence_summary.MeanSSIM);
WorstPSNR = min(sequence_summary.WorstPSNR);
WorstSSIM = min(sequence_summary.WorstSSIM);
OverlapExcessRMSE = mean(sequence_summary.OverlapExcessRMSE);
OverlapExcessSSIMLoss = mean(sequence_summary.OverlapExcessSSIMLoss);
BoundaryGradientExcess = mean(sequence_summary.BoundaryGradientExcess);
BoundaryJumpDB = mean(abs(sequence_summary.BoundaryJumpDB));
OffSupportRatio = mean(sequence_summary.OffSupportRatio);
RangeLeakageRatio = mean(sequence_summary.RangeLeakageRatio);
AzimuthLeakageRatio = mean(sequence_summary.AzimuthLeakageRatio);
PSNRSmoothness = mean(sequence_summary.PSNRSmoothness);
SSIMSmoothness = mean(sequence_summary.SSIMSmoothness);
row = table(Method, PairKey, QHigh, QLow, Alpha, SequenceCount, ...
    MeanPSNR, MeanSSIM, WorstPSNR, WorstSSIM, OverlapExcessRMSE, ...
    OverlapExcessSSIMLoss, BoundaryGradientExcess, BoundaryJumpDB, ...
    OffSupportRatio, RangeLeakageRatio, AzimuthLeakageRatio, ...
    PSNRSmoothness, SSIMSmoothness);
end

function top = select_top_by_method(ranked)
top = table();
methods = unique(ranked.Method, 'stable');
for method = methods.'
    candidates = ranked(ranked.Method == method, :);
    top = [top; candidates(1, :)]; %#ok<AGROW>
end
end
