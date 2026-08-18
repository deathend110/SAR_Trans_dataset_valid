function outputs = run_hlh_normalization_ablation(cfg)
%RUN_HLH_NORMALIZATION_ABLATION 比较旧H/L分支归一化与联合统一归一化。
%
% 仅审计输入，不运行成像：
%   cfg = sarvalid.default_config();
%   cfg.hlh_normalization_ablation.dry_run = true;
%   outputs = run_hlh_normalization_ablation(cfg);

arguments
    cfg (1, 1) struct = sarvalid.default_config()
end

validate_config(cfg);
addpath(cfg.repo_root);
ablation = cfg.hlh_normalization_ablation;
root = string(ablation.output_root);
sarvalid.ensure_dir(root);
sarvalid.ensure_dir(fullfile(root, "figures"));
sarvalid.ensure_dir(fullfile(root, "contact_sheets"));

manifest = readtable(ablation.manifest_source, TextType="string");
locked = readtable(ablation.locked_source, TextType="string");
validate_inputs(manifest, locked, ablation);
S60 = load(cfg.parameter_file_60);
writetable(manifest, fullfile(root, "input_manifest.csv"));
writetable(locked, fullfile(root, "input_locked_parameters.csv"));
sarvalid.write_json(fullfile(root, "config.json"), cfg);

signature = experiment_signature(cfg, S60, manifest, locked);
outputs = struct("status", "dry_run", "manifest", manifest, ...
    "locked", locked, "per_frame_metrics", table(), ...
    "sequence_summary", table(), "scene_summary", table(), ...
    "curve_summary", table(), "comparison", table(), ...
    "decision", table(), "example", struct());
if ablation.dry_run || cfg.runtime.dry_run
    fprintf(['H/L联合归一化消融dry-run完成：35条序列、7个场景、' ...
        '2组倍率、2种策略；未运行成像。\n']);
    return;
end

checkpoint_path = fullfile(root, "ablation_checkpoint.mat");
initial = struct("completed_units", strings(0, 1), ...
    "per_frame_metrics", table(), "sequence_summary", table(), ...
    "normalization_stats", table());
if ablation.resume
    state = sarvalid.load_checkpoint( ...
        string(checkpoint_path), signature, initial);
else
    state = initial;
    state.signature = signature;
end

scenes = unique(string(manifest.Scene), 'stable');
for pair_idx = 1:size(ablation.hl_pairs, 1)
    q_high = ablation.hl_pairs(pair_idx, 1);
    q_low = ablation.hl_pairs(pair_idx, 2);
    locked_row = locked(locked.QHigh == q_high & locked.QLow == q_low, :);
    pair = sarvalid.range_sft_v3_pair_from_row(cfg, locked_row);
    for scene_idx = 1:numel(scenes)
        scene = scenes(scene_idx);
        unit_key = string(pair.file_key) + "|" + scene;
        if any(state.completed_units == unit_key)
            continue;
        end
        fprintf('归一化消融：qH=%.3g qL=%.3g，场景%s。\n', ...
            q_high, q_low, scene);
        scene_manifest = manifest(string(manifest.Scene) == scene, :);
        evaluated = sarvalid.evaluate_hlh_normalization_scene( ...
            cfg, S60, scene_manifest, pair, ...
            ContactDirectory=fullfile(root, "contact_sheets"), ...
            CaseLabel="main35");
        state.per_frame_metrics = append_table( ...
            state.per_frame_metrics, evaluated.per_frame);
        state.sequence_summary = append_table( ...
            state.sequence_summary, evaluated.sequence_summary);
        state.normalization_stats = append_table( ...
            state.normalization_stats, evaluated.normalization);
        state.completed_units(end + 1, 1) = unit_key;
        sarvalid.atomic_save(string(checkpoint_path), struct("state", state));
    end
end

expected_rows = 35 * size(ablation.hl_pairs, 1) * ...
    numel(ablation.policies) * cfg.sequence.n_frames;
if height(state.per_frame_metrics) ~= expected_rows
    error('sarvalid:HLHAblationRowCount', ...
        '逐帧结果应为%d行，实际为%d行。', ...
        expected_rows, height(state.per_frame_metrics));
end

[scene_summary, curve_summary, comparison, decision] = ...
    sarvalid.summarize_hlh_normalization_ablation( ...
    state.per_frame_metrics, state.sequence_summary, cfg);
writetable(state.normalization_stats, ...
    fullfile(root, "normalization_stats.csv"));
writetable(state.per_frame_metrics, ...
    fullfile(root, "per_frame_metrics.csv"));
writetable(state.sequence_summary, ...
    fullfile(root, "sequence_summary.csv"));
writetable(scene_summary, fullfile(root, "scene_summary.csv"));
writetable(curve_summary, fullfile(root, "curve_summary.csv"));
writetable(comparison, ...
    fullfile(root, "normalization_comparison.csv"));
writetable(decision, fullfile(root, "normalization_decision.csv"));
plot_policy_curves(curve_summary, fullfile(root, "figures"));

example = struct();
if ablation.run_fixed_example
    example = run_fixed_example(cfg, S60, locked, root);
end

per_frame_metrics = state.per_frame_metrics;
sequence_summary = state.sequence_summary;
normalization_stats = state.normalization_stats;
save(fullfile(root, "hlh_normalization_ablation_final.mat"), ...
    "cfg", "S60", "manifest", "locked", "signature", ...
    "per_frame_metrics", "sequence_summary", "normalization_stats", ...
    "scene_summary", "curve_summary", "comparison", "decision", ...
    "example", "-v7.3");

outputs.status = "complete";
outputs.per_frame_metrics = per_frame_metrics;
outputs.sequence_summary = sequence_summary;
outputs.scene_summary = scene_summary;
outputs.curve_summary = curve_summary;
outputs.comparison = comparison;
outputs.decision = decision;
outputs.example = example;
fprintf('H/L联合归一化消融完成，结果写入%s。\n', root);
end

function validate_config(cfg)
required = ["version", "hl_pairs", "policies", "low_percentile", ...
    "high_percentile", "normalization_roi_size", "metric_patch_size", ...
    "energy_buffer", "manifest_source", "locked_source", ...
    "output_root", "resume", "dry_run", "run_fixed_example", ...
    "example_scene", "example_file", "example_cstart", "decision"];
if ~isfield(cfg, "hlh_normalization_ablation") || ...
        ~all(isfield(cfg.hlh_normalization_ablation, required))
    error('sarvalid:HLHAblationConfigMissing', ...
        'cfg.hlh_normalization_ablation缺少必要字段。');
end
ablation = cfg.hlh_normalization_ablation;
if ~isequal(ablation.hl_pairs, [4, 2; 2.5, 1.5]) || ...
        ~isequal(string(ablation.policies), ...
        ["legacy_split", "joint_hl_shared"])
    error('sarvalid:HLHAblationFixedProtocol', ...
        '消融倍率或策略集合与预注册协议不一致。');
end
if ablation.low_percentile ~= 0.99 || ...
        ablation.high_percentile ~= 99.9 || ...
        ablation.normalization_roi_size ~= 600 || ...
        ablation.metric_patch_size ~= 512
    error('sarvalid:HLHAblationNormalizationProtocol', ...
        '消融必须使用0.99/99.9分位数及600→512协议。');
end
if strcmpi(char(ablation.output_root), ...
        char(cfg.range_2dsft_v3.output_root))
    error('sarvalid:HLHAblationOutputIsolation', ...
        '消融输出不得覆盖V3结果。');
end
end

function validate_inputs(manifest, locked, ablation)
manifest_required = ["SequenceID", "Scene", "File", ...
    "FilePath", "CStart", "BlockWidth"];
locked_required = ["PairKey", "QHigh", "QLow", ...
    "STRdB", "FrOverBr", "FaOverBa"];
if ~all(ismember(manifest_required, ...
        string(manifest.Properties.VariableNames))) || ...
        ~all(ismember(locked_required, ...
        string(locked.Properties.VariableNames)))
    error('sarvalid:HLHAblationInputSchema', ...
        'V3清单或锁参表缺少必要字段。');
end
scene_names = unique(string(manifest.Scene));
scene_counts = zeros(numel(scene_names), 1);
for idx = 1:numel(scene_names)
    scene_counts(idx) = sum(string(manifest.Scene) == scene_names(idx));
end
if height(manifest) ~= 35 || numel(scene_names) ~= 7 || ...
        any(scene_counts ~= 5)
    error('sarvalid:HLHAblationManifestCounts', ...
        '主实验必须使用35条序列、7个场景且每场景5条。');
end
for idx = 1:size(ablation.hl_pairs, 1)
    mask = locked.QHigh == ablation.hl_pairs(idx, 1) & ...
        locked.QLow == ablation.hl_pairs(idx, 2);
    if sum(mask) ~= 1
        error('sarvalid:HLHAblationLockedPair', ...
            '每个倍率必须对应唯一V3锁参行。');
    end
end
end

function signature = experiment_signature(cfg, S60, manifest, locked)
ablation = cfg.hlh_normalization_ablation;
signature = struct("experiment", ablation.version, ...
    "manifest_hash", table_hash(manifest), ...
    "locked_hash", table_hash(locked), "manifest", manifest, ...
    "locked", locked, "hl_pairs", ablation.hl_pairs, ...
    "policies", ablation.policies, ...
    "normalization", struct("percentiles", ...
    [ablation.low_percentile, ablation.high_percentile], ...
    "roi_size", ablation.normalization_roi_size, ...
    "patch_size", ablation.metric_patch_size, ...
    "joint_pool", "equal_pixel_pool_aligned_H_and_L_5x9", ...
    "legacy_policy", "F0_F8_H_other_L", ...
    "joint_policy", "same_joint_HL_range_all_9_frames"), ...
    "energy", struct("buffer", ablation.energy_buffer, ...
    "policy", "single_full_block_H_to_L_scale"), ...
    "sequence", cfg.sequence, "imaging", imaging_signature(S60), ...
    "decision", ablation.decision);
end

function example = run_fixed_example(cfg, S60, locked, root)
ablation = cfg.hlh_normalization_ablation;
file_path = fullfile(cfg.data_root, ablation.example_scene, ...
    ablation.example_file);
if ~isfile(file_path)
    error('sarvalid:HLHExampleMissing', ...
        '固定city1样例轨迹不存在：%s', file_path);
end
variables = whos('-file', file_path);
max_start = variables(1).size(2) - cfg.sequence.block_width + 1;
if ablation.example_cstart < 1 || ablation.example_cstart > max_start
    error('sarvalid:HLHExampleCStart', ...
        '固定样例CStart超出轨迹范围。');
end
SequenceID = 900001;
Scene = string(ablation.example_scene);
File = string(ablation.example_file);
FilePath = string(file_path);
CStart = ablation.example_cstart;
BlockWidth = cfg.sequence.block_width;
example_manifest = table(SequenceID, Scene, File, FilePath, ...
    CStart, BlockWidth);
locked_row = locked(locked.QHigh == 4 & locked.QLow == 2, :);
pair = sarvalid.range_sft_v3_pair_from_row(cfg, locked_row);
evaluated = sarvalid.evaluate_hlh_normalization_scene( ...
    cfg, S60, example_manifest, pair, ...
    ContactDirectory=fullfile(root, "contact_sheets"), ...
    CaseLabel="fixed_city1_example");
writetable(evaluated.per_frame, ...
    fullfile(root, "fixed_example_per_frame_metrics.csv"));
writetable(evaluated.sequence_summary, ...
    fullfile(root, "fixed_example_sequence_summary.csv"));
writetable(evaluated.normalization, ...
    fullfile(root, "fixed_example_normalization_stats.csv"));
plot_example_curves(evaluated.per_frame, fullfile(root, "figures"));
example = evaluated;
end

function plot_policy_curves(curves, output_dir)
pairs = unique(curves(:, ["QHigh", "QLow"]), 'rows', 'stable');
for pair_idx = 1:height(pairs)
    rows = curves(curves.QHigh == pairs.QHigh(pair_idx) & ...
        curves.QLow == pairs.QLow(pair_idx), :);
    save_overlay_plot(rows, output_dir, ...
        "qh" + encode(pairs.QHigh(pair_idx)) + ...
        "_ql" + encode(pairs.QLow(pair_idx)) + "_mean35");
end
end

function plot_example_curves(frames, output_dir)
curves = table();
policies = unique(string(frames.Policy), 'stable');
for policy_idx = 1:numel(policies)
    rows = frames(frames.Policy == policies(policy_idx), :);
    QHigh = rows.QHigh;
    QLow = rows.QLow;
    Policy = rows.Policy;
    FrameIdx = rows.FrameIdx;
    MeanPSNR = rows.PSNR;
    MeanSSIM = rows.SSIM;
    curves = append_table(curves, ...
        table(QHigh, QLow, Policy, FrameIdx, MeanPSNR, MeanSSIM));
end
save_overlay_plot(curves, output_dir, "fixed_city1_example");
end

function save_overlay_plot(rows, output_dir, name)
figure_handle = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [100, 100, 1000, 760]);
cleanup = onCleanup(@() close(figure_handle));
layout = tiledlayout(2, 1, 'TileSpacing', 'compact');
title(layout, replace(name, "_", " "));
policies = unique(string(rows.Policy), 'stable');
nexttile;
hold on;
for policy = policies.'
    values = rows(rows.Policy == policy, :);
    plot(values.FrameIdx, values.MeanPSNR, '-o', ...
        'LineWidth', 1.7, 'DisplayName', policy);
end
grid on; xlim([0, 8]); xticks(0:8); ylabel('PSNR (dB)');
legend('Location', 'best', 'Interpreter', 'none');
nexttile;
hold on;
for policy = policies.'
    values = rows(rows.Policy == policy, :);
    plot(values.FrameIdx, values.MeanSSIM, '-o', ...
        'LineWidth', 1.7, 'DisplayName', policy);
end
grid on; xlim([0, 8]); xticks(0:8); ylabel('SSIM'); xlabel('Frame');
legend('Location', 'best', 'Interpreter', 'none');
exportgraphics(figure_handle, fullfile(output_dir, name + ".png"), ...
    'Resolution', 180);
end

function digest = table_hash(input)
digest = sarvalid.sha256_text(string(jsonencode(table2struct(input))));
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

function output = encode(value)
output = replace(string(sprintf('%.12g', value)), ".", "p");
end

function output = append_table(input, rows)
if isempty(input)
    output = rows;
else
    output = [input; rows];
end
end
