function outputs = run_range_2dsft_search_v3(cfg)
%RUN_RANGE_2DSFT_SEARCH_V3 搜索连续H-L-H序列的Range+2D-SFT生产参数。
%
% 仅执行清单和网格审计：
%   cfg = sarvalid.default_config();
%   cfg.range_2dsft_v3.dry_run = true;
%   outputs = run_range_2dsft_search_v3(cfg);
%
% 完整搜索包含396个粗候选及局部细化，必须由用户另行明确授权运行。

arguments
    cfg (1, 1) struct = sarvalid.default_config()
end

validate_v3_config(cfg);
addpath(cfg.repo_root);
v3 = cfg.range_2dsft_v3;
root = string(v3.output_root);
directories = ["manifests", "cache", "coarse", "fine", "final", ...
    fullfile("final", "contact_sheets"), ...
    fullfile("final", "parameter_heatmaps"), ...
    fullfile("final", "sequence_curves")];
sarvalid.ensure_dir(root);
for directory = directories
    sarvalid.ensure_dir(fullfile(root, directory));
end

S60 = load(cfg.parameter_file_60);
manifest = load_search_manifest(v3.manifest_source);
manifest_hash = table_hash(manifest);
writetable(manifest, fullfile(root, "manifests", "sequence.csv"));

[coarse_candidates, limits] = build_all_coarse_grids(cfg, S60);
if height(coarse_candidates) ~= 396 || ...
        sum(coarse_candidates.QHigh == 4) ~= 231 || ...
        sum(coarse_candidates.QHigh == 2.5) ~= 165
    error('sarvalid:V3CoarseCandidateCount', ...
        'V3粗候选必须严格为231+165=396。');
end
preregistration = build_preregistration( ...
    cfg, manifest_hash, coarse_candidates, limits);
sarvalid.write_json(fullfile(root, "preregistration.json"), preregistration);
sarvalid.write_json(fullfile(root, "config.json"), cfg);
save(fullfile(root, "config.mat"), "cfg", "S60", "manifest", ...
    "manifest_hash", "coarse_candidates", "limits", ...
    "preregistration", "-v7.3");

outputs = struct("status", "dry_run", "manifest", manifest, ...
    "manifest_hash", manifest_hash, "coarse_candidates", ...
    coarse_candidates, "limits", limits, "coarse", struct(), ...
    "fine", struct(), "locked_parameters", table(), ...
    "final", struct());
if v3.dry_run || cfg.runtime.dry_run
    fprintf(['V3 dry-run完成：35条搜索序列、7个场景、每场景5条；' ...
        '粗候选231+165=396，未运行成像。\n']);
    return;
end

[cache_index, gt_stats] = sarvalid.prepare_range_sft_v3_gt_cache( ...
    cfg, S60, manifest, fullfile(root, "cache"));
writetable(gt_stats, fullfile(root, "cache", "gt_scene_stats.csv"));
grid_context = struct("manifest_hash", manifest_hash, ...
    "coarse_grid", coarse_candidates, "limits", limits, ...
    "fine_policy", struct("STR_offsets", v3.fine_STR_offsets, ...
    "frequency_offsets", v3.fine_frequency_offsets, ...
    "deduplicate_against_coarse", true));
coarse = sarvalid.run_range_sft_v3_search( ...
    cfg, S60, manifest, cache_index, coarse_candidates, "coarse", ...
    fullfile(root, "coarse"), grid_context);
outputs.coarse = coarse;
outputs.status = "coarse_complete";
if lower(string(v3.stop_after)) == "coarse"
    return;
end

coarse_winners = pair_winners(coarse.scene_metrics, v3.hl_pairs);
[fine_candidates, fine_anchors] = build_fine_grids( ...
    cfg, S60, coarse_winners, coarse_candidates);
fine_context = grid_context;
fine_context.fine_anchors = fine_anchors;
fine_context.fine_grid = fine_candidates;
fine = sarvalid.run_range_sft_v3_search( ...
    cfg, S60, manifest, cache_index, fine_candidates, "fine", ...
    fullfile(root, "fine"), fine_context);
outputs.fine = fine;
outputs.status = "fine_complete";

all_scene_metrics = [coarse.scene_metrics; fine.scene_metrics];
locked = pair_winners(all_scene_metrics, v3.hl_pairs);
locked = enrich_locked_parameters(cfg, S60, locked, limits);
writetable(locked, fullfile(root, "locked_parameters.csv"));
outputs.locked_parameters = locked;
if lower(string(v3.stop_after)) == "fine"
    return;
end

final_context = fine_context;
final_context.locked_parameters = locked;
final_result = sarvalid.run_range_sft_v3_final( ...
    cfg, S60, manifest, cache_index, locked, fullfile(root, "final"), ...
    final_context);
plot_sequence_curves(final_result.per_frame_metrics, ...
    fullfile(root, "final", "sequence_curves"));
plot_parameter_heatmaps(coarse.candidate_summary, coarse_winners, ...
    fullfile(root, "final", "parameter_heatmaps"));
save(fullfile(root, "range_2dsft_v3_final.mat"), ...
    "cfg", "S60", "manifest", "manifest_hash", "preregistration", ...
    "coarse", "fine", "locked", "final_result", "-v7.3");
outputs.final = final_result;
outputs.status = "final_complete";
fprintf('Range+2D-SFT V3搜索完成，结果写入%s。\n', root);
end

function validate_v3_config(cfg)
required = ["version", "hl_pairs", "STR_grid", "fr_grid", "fa_grid", ...
    "fine_STR_offsets", "fine_frequency_offsets", "low_percentile", ...
    "high_percentile", "normalization_roi_size", "metric_patch_size", ...
    "energy_buffer", "manifest_source", "output_root", "resume", ...
    "dry_run", "stop_after"];
if ~isfield(cfg, "range_2dsft_v3") || ...
        ~all(isfield(cfg.range_2dsft_v3, required))
    error('sarvalid:V3ConfigMissing', ...
        'cfg.range_2dsft_v3缺少必要字段。');
end
v3 = cfg.range_2dsft_v3;
if ~isequal(v3.hl_pairs, [4, 2; 2.5, 1.5]) || ...
        ~isequal(v3.STR_grid, -10:2:10) || ...
        ~isequal(v3.fr_grid, 0:0.2:4) || ...
        ~isequal(v3.fa_grid, 0:0.2:4)
    error('sarvalid:V3FixedSearchProtocol', ...
        'V3倍率对或粗搜索网格与预注册协议不一致。');
end
if v3.low_percentile ~= 0.99 || v3.high_percentile ~= 99.9 || ...
        v3.normalization_roi_size ~= 600 || v3.metric_patch_size ~= 512
    error('sarvalid:V3FixedNormalizationProtocol', ...
        'V3必须使用600 ROI、512裁剪及0.99/99.9分位数。');
end
if ~ismember(lower(string(v3.stop_after)), ["coarse", "fine", "final"])
    error('sarvalid:V3StopStage', ...
        'stop_after必须为coarse、fine或final。');
end
if strcmpi(char(v3.output_root), char(cfg.output_root)) || ...
        strcmpi(char(v3.output_root), ...
        char(cfg.generator_confirmation.output_root))
    error('sarvalid:V3OutputIsolation', ...
        'V3输出目录不得与旧实验目录重叠。');
end
end

function manifest = load_search_manifest(source)
source = string(source);
if ~isfile(source)
    error('sarvalid:V3ManifestMissing', '找不到V2序列清单：%s', source);
end
manifest = readtable(source, TextType="string");
required = ["SequenceID", "SceneIdx", "Scene", "Split", "File", ...
    "FilePath", "CStart", "BlockWidth"];
if ~all(ismember(required, string(manifest.Properties.VariableNames)))
    error('sarvalid:V3ManifestSchema', 'V2序列清单缺少必要字段。');
end
manifest.Properties.VariableNames{strcmp( ...
    manifest.Properties.VariableNames, 'Split')} = 'OriginalSplit';
SearchRole = repmat("search", height(manifest), 1);
manifest = addvars(manifest, SearchRole, 'After', "OriginalSplit");
scene_names = unique(string(manifest.Scene));
scene_counts = zeros(numel(scene_names), 1);
for scene_idx = 1:numel(scene_names)
    scene_counts(scene_idx) = sum(string(manifest.Scene) == scene_names(scene_idx));
end
if height(manifest) ~= 35 || numel(unique(string(manifest.Scene))) ~= 7 || ...
        any(scene_counts ~= 5) || ...
        numel(unique(manifest.SequenceID)) ~= height(manifest) || ...
        any(manifest.BlockWidth ~= 2224)
    error('sarvalid:V3ManifestCounts', ...
        'V3清单必须为35条、7场景、每场景5条且连续块宽2224。');
end
end

function [candidates, limits] = build_all_coarse_grids(cfg, S60)
candidates = table();
pair_count = size(cfg.range_2dsft_v3.hl_pairs, 1);
limits = repmat(struct("q_high", 0, "q_low", 0, ...
    "fr_over_Br", 0, "fa_over_Ba", 0, "H", struct(), "L", struct()), ...
    pair_count, 1);
for pair_idx = 1:pair_count
    q_high = cfg.range_2dsft_v3.hl_pairs(pair_idx, 1);
    q_low = cfg.range_2dsft_v3.hl_pairs(pair_idx, 2);
    [rows, pair_limits] = sarvalid.range_sft_v3_grid( ...
        cfg, S60, q_high, q_low);
    candidates = append_table(candidates, rows);
    pair_limits.q_high = q_high;
    pair_limits.q_low = q_low;
    limits(pair_idx) = pair_limits;
end
end

function [candidates, anchors] = build_fine_grids( ...
        cfg, S60, coarse_winners, coarse_candidates)
candidates = table();
anchors = coarse_winners(:, ["PairKey", "QHigh", "QLow", ...
    "STRdB", "FrOverBr", "FaOverBa"]);
for idx = 1:height(anchors)
    rows = sarvalid.range_sft_v3_grid(cfg, S60, ...
        anchors.QHigh(idx), anchors.QLow(idx), anchors(idx, :));
    rows(ismember(rows.PairKey, coarse_candidates.PairKey), :) = [];
    rows = unique(rows, 'rows', 'stable');
    if isempty(rows)
        error('sarvalid:V3EmptyFineGrid', ...
            '局部细化去重后没有新候选。');
    end
    candidates = append_table(candidates, rows);
end
end

function winners = pair_winners(scene_metrics, hl_pairs)
winners = table();
for pair_idx = 1:size(hl_pairs, 1)
    mask = scene_metrics.QHigh == hl_pairs(pair_idx, 1) & ...
        scene_metrics.QLow == hl_pairs(pair_idx, 2);
    ranked = sarvalid.rank_range_sft_v3_candidates(scene_metrics(mask, :));
    if isempty(ranked)
        error('sarvalid:V3MissingPairResult', ...
            '倍率对(%.3g,%.3g)没有可排名结果。', ...
            hl_pairs(pair_idx, 1), hl_pairs(pair_idx, 2));
    end
    winners = append_table(winners, ranked(1, :));
end
end

function locked = enrich_locked_parameters(cfg, S60, locked, limits)
count = height(locked);
FrLimit = zeros(count, 1);
FaLimit = zeros(count, 1);
QRangeHighEff = zeros(count, 1);
QAzimuthHighEff = zeros(count, 1);
QTotalHighEff = zeros(count, 1);
QRangeLowEff = zeros(count, 1);
QAzimuthLowEff = zeros(count, 1);
QTotalLowEff = zeros(count, 1);
for idx = 1:count
    limit_idx = find([limits.q_high] == locked.QHigh(idx) & ...
        [limits.q_low] == locked.QLow(idx), 1);
    FrLimit(idx) = limits(limit_idx).fr_over_Br;
    FaLimit(idx) = limits(limit_idx).fa_over_Ba;
    pair = sarvalid.range_sft_v3_pair_from_row(cfg, locked(idx, :));
    grid_h = sarvalid.resolve_acquisition(pair.H, ...
        [cfg.sequence.signal_height, cfg.sequence.block_width], S60);
    grid_l = sarvalid.resolve_acquisition(pair.L, ...
        [cfg.sequence.signal_height, cfg.sequence.block_width], S60);
    QRangeHighEff(idx) = grid_h.q_range_eff;
    QAzimuthHighEff(idx) = grid_h.q_azimuth_eff;
    QTotalHighEff(idx) = grid_h.q_total_eff;
    QRangeLowEff(idx) = grid_l.q_range_eff;
    QAzimuthLowEff(idx) = grid_l.q_azimuth_eff;
    QTotalLowEff(idx) = grid_l.q_total_eff;
end
locked = addvars(locked, FrLimit, FaLimit, QRangeHighEff, ...
    QAzimuthHighEff, QTotalHighEff, QRangeLowEff, QAzimuthLowEff, ...
    QTotalLowEff, 'After', "FaOverBa");
end

function value = build_preregistration(cfg, manifest_hash, candidates, limits)
v3 = cfg.range_2dsft_v3;
value = struct("material_passport", struct( ...
    "origin_skill", "SAR Master + Experiment Agent", ...
    "origin_mode", "implementation", "origin_date", "2026-08-16", ...
    "verification_status", "UNVERIFIED", "version", v3.version), ...
    "method", "Range_2D_SFT", "hl_pairs", v3.hl_pairs, ...
    "manifest", struct("source", string(v3.manifest_source), ...
    "hash", manifest_hash, "sequence_count", 35, "scene_count", 7, ...
    "role", "all_sequences_for_production_parameter_search"), ...
    "coarse_grid", struct("STR", v3.STR_grid, "fr_over_Br", v3.fr_grid, ...
    "fa_over_Ba", v3.fa_grid, "legal_candidate_count", ...
    height(candidates), "limits", limits), ...
    "fine_grid", struct("STR_offsets", v3.fine_STR_offsets, ...
    "frequency_offsets", v3.fine_frequency_offsets, ...
    "center", "coarse_rank_1", "merge_and_rerank", true), ...
    "normalization", struct("low_percentile", v3.low_percentile, ...
    "high_percentile", v3.high_percentile, ...
    "roi_size", v3.normalization_roi_size, ...
    "patch_size", v3.metric_patch_size, ...
    "pool", "per_scene_per_candidate_5_sequences_x_9_frames", ...
    "frame_policy", "GT_GTstats_F0F8_Hstats_other_Lstats"), ...
    "energy_alignment", "single_full_block_H_to_L_scale", ...
    "phi0", cfg.threshold.phi0, "time_origin", "block_global", ...
    "ranking", ["MeanSSIM_desc", "LRegionSSIM_desc", ...
    "WorstSSIM_desc", "MeanPSNR_desc", "PairKey_asc"]);
end

function plot_sequence_curves(frame_metrics, output_dir)
sarvalid.ensure_dir(output_dir);
keys = unique(string(frame_metrics.PairKey), 'stable');
for key_idx = 1:numel(keys)
    rows = frame_metrics(string(frame_metrics.PairKey) == keys(key_idx), :);
    frames = unique(rows.FrameIdx);
    mean_psnr = zeros(size(frames));
    mean_ssim = zeros(size(frames));
    for idx = 1:numel(frames)
        frame_rows = rows(rows.FrameIdx == frames(idx), :);
        mean_psnr(idx) = mean(frame_rows.PSNR);
        mean_ssim(idx) = mean(frame_rows.SSIM);
    end
    fig = figure('Visible', 'off', 'Color', 'w', ...
        'Position', [100, 100, 900, 700]);
    cleanup = onCleanup(@() close(fig));
    layout = tiledlayout(2, 1, 'TileSpacing', 'compact');
    title(layout, keys(key_idx), 'Interpreter', 'none');
    nexttile;
    plot(frames, mean_psnr, '-o', 'LineWidth', 1.5);
    grid on; xlim([0, 8]); xticks(0:8); ylabel('PSNR (dB)');
    nexttile;
    plot(frames, mean_ssim, '-o', 'LineWidth', 1.5);
    grid on; xlim([0, 8]); xticks(0:8); ylabel('SSIM'); xlabel('Frame');
    exportgraphics(fig, fullfile(output_dir, safe_name(keys(key_idx)) + ...
        "_sequence_curve.png"), 'Resolution', 180);
    clear cleanup;
end
end

function plot_parameter_heatmaps(summary, winners, output_dir)
sarvalid.ensure_dir(output_dir);
for idx = 1:height(winners)
    rows = summary(summary.QHigh == winners.QHigh(idx) & ...
        summary.QLow == winners.QLow(idx) & ...
        summary.STRdB == winners.STRdB(idx), :);
    fig = figure('Visible', 'off', 'Color', 'w', ...
        'Position', [100, 100, 850, 650]);
    cleanup = onCleanup(@() close(fig));
    scatter(rows.FrOverBr, rows.FaOverBa, 100, rows.MeanSSIM, 'filled');
    xlabel('f_r/B_r'); ylabel('f_a/B_a'); colorbar; grid on;
    title(sprintf('q_H=%.3g, q_L=%.3g, STR=%.3g dB', ...
        winners.QHigh(idx), winners.QLow(idx), winners.STRdB(idx)));
    exportgraphics(fig, fullfile(output_dir, ...
        sprintf('qh%s_ql%s_coarse_heatmap.png', ...
        encode(winners.QHigh(idx)), encode(winners.QLow(idx)))), ...
        'Resolution', 180);
    clear cleanup;
end
end

function digest = table_hash(input)
digest = sarvalid.sha256_text(string(jsonencode(table2struct(input))));
end

function output = safe_name(input)
output = regexprep(string(input), '[^A-Za-z0-9_-]+', '_');
end

function output = encode(value)
output = char(replace(string(sprintf('%.12g', value)), ".", "p"));
end

function output = append_table(input, rows)
if isempty(input)
    output = rows;
else
    output = [input; rows];
end
end
