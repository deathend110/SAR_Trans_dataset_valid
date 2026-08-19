function outputs = run_range_2dsft_v4_str_ablation()
%RUN_RANGE_2DSFT_V4_STR_ABLATION 快速验证H/L独立STR是否值得升级生产协议。
%
% 固定qH/qL=4/2、fr/Br=1.3、fa/Ba=0.5、phi0=0，仅扫描：
%   STR_H = [-2, -1, 0]
%   STR_L = [-1,  0, 1]
% 使用V3全部35条序列和候选专属JointHL归一化。实验通过只表示值得
% 进入独立样本确认，不会自动修改分位数脚本或生产数据集生成器。

repo_root = string(fileparts(mfilename('fullpath')));
addpath(repo_root);
cfg = sarvalid.default_config();
v4 = v4_config(repo_root);
cfg.hlh_normalization_ablation.policies = "joint_hl_shared";
cfg.hlh_normalization_ablation.low_percentile = v4.low_percentile;
cfg.hlh_normalization_ablation.high_percentile = v4.high_percentile;
cfg.hlh_normalization_ablation.normalization_roi_size = v4.roi_size;
cfg.hlh_normalization_ablation.metric_patch_size = v4.patch_size;
cfg.hlh_normalization_ablation.energy_buffer = v4.energy_buffer;

sarvalid.ensure_dir(v4.output_root);
sarvalid.ensure_dir(fullfile(v4.output_root, "figures"));
S60 = load(cfg.parameter_file_60);
manifest = load_v3_manifest(v4.manifest_source);
candidates = build_candidates(v4, cfg);
validate_protocol(cfg, S60, manifest, candidates, v4);

signature = experiment_signature(cfg, S60, manifest, candidates, v4);
checkpoint_path = fullfile(v4.output_root, "v4_checkpoint.mat");
initial_state = struct( ...
    "completed_units", strings(0, 1), ...
    "per_frame", table(), ...
    "per_sequence", table(), ...
    "normalization", table());
state = sarvalid.load_checkpoint( ...
    string(checkpoint_path), signature, initial_state);

preregistration = build_preregistration(v4, manifest, candidates);
sarvalid.write_json(fullfile(v4.output_root, ...
    "preregistration.json"), preregistration);
save(fullfile(v4.output_root, "config.mat"), ...
    "v4", "candidates", "manifest", "signature");

scenes = unique(string(manifest.Scene), 'stable');
fprintf(['V4双STR快速消融：%d个候选，%d个场景，%d条序列；' ...
    '仅评价JointHL。\n'], height(candidates), numel(scenes), height(manifest));
for candidate_idx = 1:height(candidates)
    candidate = candidates(candidate_idx, :);
    pair = pair_from_candidate(cfg, candidate, v4);
    fprintf('\n[%d/%d] %s\n', candidate_idx, height(candidates), ...
        candidate.CandidateKey);
    for scene_idx = 1:numel(scenes)
        scene = scenes(scene_idx);
        unit_key = candidate.CandidateKey + "|" + scene;
        if any(state.completed_units == unit_key)
            fprintf('  [%d/%d] %s：checkpoint已完成，跳过。\n', ...
                scene_idx, numel(scenes), scene);
            continue;
        end
        scene_manifest = manifest(string(manifest.Scene) == scene, :);
        evaluated = sarvalid.evaluate_hlh_normalization_scene( ...
            cfg, S60, scene_manifest, pair, ...
            ContactDirectory="", CaseLabel="v4_quick35");

        frame_rows = evaluated.per_frame( ...
            evaluated.per_frame.Policy == "joint_hl_shared", :);
        sequence_rows = evaluated.sequence_summary( ...
            evaluated.sequence_summary.Policy == "joint_hl_shared", :);
        normalization_rows = evaluated.normalization( ...
            evaluated.normalization.Policy == "joint_hl_shared", :);
        verify_evaluated_rows(frame_rows, sequence_rows, ...
            normalization_rows, scene_manifest, candidate);

        frame_rows = add_candidate_columns(frame_rows, candidate);
        sequence_rows = add_candidate_columns(sequence_rows, candidate);
        normalization_rows = add_candidate_columns( ...
            normalization_rows, candidate);
        state.per_frame = append_table(state.per_frame, frame_rows);
        state.per_sequence = append_table( ...
            state.per_sequence, sequence_rows);
        state.normalization = append_table( ...
            state.normalization, normalization_rows);
        state.completed_units(end + 1, 1) = unit_key;
        sarvalid.atomic_save(string(checkpoint_path), struct("state", state));
        fprintf('  [%d/%d] %s：完成。\n', ...
            scene_idx, numel(scenes), scene);
    end
end

verify_complete_state(state, candidates, scenes, manifest, cfg.sequence.n_frames);
scene_metrics = aggregate_candidate_scenes(state.per_sequence, candidates);
candidate_summary = aggregate_candidates(scene_metrics, candidates);
curve_summary = aggregate_curves(state.per_frame, candidates, scenes);
[decision, best_key] = make_decision(scene_metrics, candidate_summary, v4);

writetable(state.per_frame, fullfile(v4.output_root, ...
    "per_frame_metrics.csv"));
writetable(state.per_sequence, fullfile(v4.output_root, ...
    "per_sequence_metrics.csv"));
writetable(state.normalization, fullfile(v4.output_root, ...
    "normalization_stats.csv"));
writetable(scene_metrics, fullfile(v4.output_root, ...
    "candidate_scene_metrics.csv"));
writetable(candidate_summary, fullfile(v4.output_root, ...
    "candidate_summary.csv"));
writetable(curve_summary, fullfile(v4.output_root, ...
    "curve_summary.csv"));
writetable(decision, fullfile(v4.output_root, "v4_decision.csv"));
plot_best_curves(curve_summary, v4.baseline_key, best_key, ...
    fullfile(v4.output_root, "figures", "baseline_vs_best_curves.png"));

save(fullfile(v4.output_root, "range_2dsft_v4_final.mat"), ...
    "v4", "candidates", "manifest", "signature", "state", ...
    "scene_metrics", "candidate_summary", "curve_summary", ...
    "decision", "-v7.3");
outputs = struct( ...
    "candidates", candidates, ...
    "scene_metrics", scene_metrics, ...
    "candidate_summary", candidate_summary, ...
    "curve_summary", curve_summary, ...
    "decision", decision, ...
    "output_root", v4.output_root);
fprintf('\nV4实验完成：%s\n', decision.Outcome);
fprintf('结果目录：%s\n', v4.output_root);
end

function v4 = v4_config(repo_root)
%V4_CONFIG 固定快速消融中允许变化的参数和自动判据。
v4 = struct();
v4.version = "range_2dsft_v4_dual_str_quick";
v4.q_high = 4;
v4.q_low = 2;
v4.STR_H = [-2, -1, 0];
v4.STR_L = [-1, 0, 1];
v4.fr_over_Br = 1.3;
v4.fa_over_Ba = 0.5;
v4.phi0 = 0;
v4.low_percentile = 0.99;
v4.high_percentile = 99.9;
v4.roi_size = 600;
v4.patch_size = 512;
v4.energy_buffer = 64;
v4.manifest_source = fullfile(repo_root, ...
    "results_range_2dsft_v3", "manifests", "sequence.csv");
v4.output_root = fullfile(repo_root, ...
    "results_range_2dsft_v4_str_ablation");
v4.baseline_key = candidate_key(-1, -1);
v4.decision = struct( ...
    "mean_psnr_gain_db", 0.05, ...
    "mean_ssim_gain", 0.001, ...
    "minimum_joint_scene_wins", 5, ...
    "worst_ssim_loss", 0.001, ...
    "l_region_ssim_loss", 0, ...
    "overlap_loss_increase", 0.001, ...
    "boundary_excess_increase", 0.001, ...
    "ssim_smoothness_increase", 0.001);
end

function manifest = load_v3_manifest(file_path)
%LOAD_V3_MANIFEST 读取并验证固定的35条V3连续序列清单。
if ~isfile(file_path)
    error('sarvalid:V4ManifestMissing', '找不到V3清单：%s。', file_path);
end
manifest = readtable(file_path, TextType="string");
required = ["SequenceID", "SceneIdx", "Scene", "File", ...
    "FilePath", "CStart", "BlockWidth"];
if ~all(ismember(required, string(manifest.Properties.VariableNames)))
    error('sarvalid:V4ManifestSchema', 'V3清单缺少必要字段。');
end
scenes = unique(string(manifest.Scene), 'stable');
counts = zeros(numel(scenes), 1);
for idx = 1:numel(scenes)
    counts(idx) = sum(string(manifest.Scene) == scenes(idx));
end
if height(manifest) ~= 35 || numel(scenes) ~= 7 || ...
        any(counts ~= 5) || numel(unique(manifest.SequenceID)) ~= 35 || ...
        any(manifest.BlockWidth ~= 2224)
    error('sarvalid:V4ManifestCounts', ...
        'V4必须复用35条、7场景、每场景5条的V3清单。');
end
end

function candidates = build_candidates(v4, cfg)
%BUILD_CANDIDATES 构造3×3双STR网格并标记当前共享STR基线。
[STRHigh, STRLow] = ndgrid(v4.STR_H, v4.STR_L);
count = numel(STRHigh);
CandidateKey = strings(count, 1);
for idx = 1:count
    CandidateKey(idx) = candidate_key(STRHigh(idx), STRLow(idx));
end
QHigh = repmat(v4.q_high, count, 1);
QLow = repmat(v4.q_low, count, 1);
STRHigh = STRHigh(:);
STRLow = STRLow(:);
FrOverBr = repmat(v4.fr_over_Br, count, 1);
FaOverBa = repmat(v4.fa_over_Ba, count, 1);
Phi0 = repmat(v4.phi0, count, 1);
IsBaseline = CandidateKey == v4.baseline_key;
candidates = table(CandidateKey, QHigh, QLow, STRHigh, STRLow, ...
    FrOverBr, FaOverBa, Phi0, IsBaseline);
if height(candidates) ~= 9 || sum(IsBaseline) ~= 1 || ...
        numel(unique(CandidateKey)) ~= 9 || cfg.threshold.phi0 ~= v4.phi0
    error('sarvalid:V4CandidateGrid', ...
        'V4候选必须是包含唯一共享基线的3×3双STR网格。');
end
end

function pair = pair_from_candidate(cfg, candidate, v4)
%PAIR_FROM_CANDIDATE 构造只在STR上非对称的H/L采集配置。
threshold = struct("As", cfg.threshold.As, ...
    "STR_dB", -1, ...
    "fr_over_Br", v4.fr_over_Br, ...
    "fa_over_Ba", v4.fa_over_Ba, ...
    "phi0", v4.phi0);
pair = sarvalid.make_pair_config(cfg, "Range_2D_SFT", ...
    v4.q_high, v4.q_low, 1, threshold);
pair.H.threshold.STR_dB = double(candidate.STRHigh);
pair.L.threshold.STR_dB = double(candidate.STRLow);
pair.H.share_policy = "shared_frequency_phase_independent_STR";
pair.L.share_policy = "shared_frequency_phase_independent_STR";
pair.file_key = string(candidate.CandidateKey);
end

function validate_protocol(cfg, S60, manifest, candidates, v4)
%VALIDATE_PROTOCOL 检查共享频率、实际网格和评价协议没有漂移。
if cfg.sequence.n_frames ~= 9 || cfg.sequence.step ~= 128 || ...
        cfg.sequence.block_width ~= 2224 || ...
        cfg.sequence.signal_width ~= 1200 || ...
        cfg.sequence.patch_size ~= 512 || ...
        v4.roi_size ~= 600 || v4.patch_size ~= 512 || ...
        v4.energy_buffer ~= 64
    error('sarvalid:V4SequenceProtocol', ...
        'V4必须保持V3的九帧、600 ROI、512裁剪和64列边界协议。');
end
for idx = 1:height(candidates)
    pair = pair_from_candidate(cfg, candidates(idx, :), v4);
    high = sarvalid.resolve_acquisition(pair.H, ...
        [cfg.sequence.signal_height, cfg.sequence.block_width], S60);
    low = sarvalid.resolve_acquisition(pair.L, ...
        [cfg.sequence.signal_height, cfg.sequence.block_width], S60);
    Ba = resolve_azimuth_bandwidth(S60);
    fr_limit = cfg.threshold.nyquist_margin * ...
        min(high.Fs_up, low.Fs_up) / (2 * S60.B);
    fa_limit = cfg.threshold.nyquist_margin * ...
        min(high.PRF_up, low.PRF_up) / (2 * Ba);
    if v4.fr_over_Br >= fr_limit || v4.fa_over_Ba >= fa_limit
        error('sarvalid:V4NyquistViolation', ...
            '共享SFT频率超过H/L共同Nyquist上限。');
    end
end
if height(manifest) ~= 35
    error('sarvalid:V4ManifestSize', 'V4必须使用全部35条V3序列。');
end
end

function signature = experiment_signature(cfg, S60, manifest, candidates, v4)
%EXPERIMENT_SIGNATURE 保存所有会改变V4结论的显式配置。
signature = struct( ...
    "version", v4.version, ...
    "manifest", manifest(:, ["SequenceID", "Scene", "File", ...
    "FilePath", "CStart", "BlockWidth"]), ...
    "candidates", candidates, ...
    "shared_sft", struct("fr_over_Br", v4.fr_over_Br, ...
    "fa_over_Ba", v4.fa_over_Ba, "phi0", v4.phi0, ...
    "time_origin", "block_global"), ...
    "normalization", struct("policy", "joint_hl_shared", ...
    "low_percentile", v4.low_percentile, ...
    "high_percentile", v4.high_percentile, ...
    "roi_size", v4.roi_size, "patch_size", v4.patch_size, ...
    "scope", "candidate_scene_all_5_sequences"), ...
    "energy_buffer", v4.energy_buffer, ...
    "decision", v4.decision, ...
    "sequence", cfg.sequence, ...
    "threshold_seed", cfg.threshold_seed, ...
    "nyquist_margin", cfg.threshold.nyquist_margin, ...
    "imaging", imaging_signature(S60));
end

function value = build_preregistration(v4, manifest, candidates)
%BUILD_PREREGISTRATION 构造可审计的V4固定实验说明。
value = struct( ...
    "version", v4.version, ...
    "purpose", "screen_independent_HL_STR_before_production_change", ...
    "manifest_source", string(v4.manifest_source), ...
    "sequence_count", height(manifest), ...
    "scene_count", numel(unique(string(manifest.Scene))), ...
    "candidate_count", height(candidates), ...
    "candidates", table2struct(candidates), ...
    "normalization", "candidate_specific_joint_hl_shared", ...
    "ranking", ["MeanSSIM_desc", "LRegionSSIM_desc", ...
    "WorstSSIM_desc", "MeanPSNR_desc", "CandidateKey_asc"], ...
    "decision", v4.decision, ...
    "production_behavior", ...
    "no_change_unless_all_thresholds_pass_then_confirm_on_heldout");
end

function verify_evaluated_rows( ...
        frame_rows, sequence_rows, normalization_rows, manifest, candidate)
%VERIFY_EVALUATED_ROWS 检查一个候选场景的输出行数、策略和配对关系。
expected_sequences = height(manifest);
if height(frame_rows) ~= expected_sequences * 9 || ...
        height(sequence_rows) ~= expected_sequences || ...
        any(frame_rows.Policy ~= "joint_hl_shared") || ...
        any(sequence_rows.Policy ~= "joint_hl_shared") || ...
        numel(unique(sequence_rows.SequenceID)) ~= expected_sequences || ...
        ~isequal(sort(sequence_rows.SequenceID), sort(manifest.SequenceID)) || ...
        any(string(sequence_rows.PairKey) ~= candidate.CandidateKey)
    error('sarvalid:V4EvaluatedRows', ...
        '候选%s的JointHL评价行数或序列配对不正确。', ...
        candidate.CandidateKey);
end
modalities = string(normalization_rows.Modality);
if height(normalization_rows) ~= 2 || ...
        ~all(ismember(["GT", "JointHL"], modalities))
    error('sarvalid:V4NormalizationRows', ...
        '候选%s必须输出GT和JointHL两行归一化统计。', ...
        candidate.CandidateKey);
end
end

function rows = add_candidate_columns(rows, candidate)
%ADD_CANDIDATE_COLUMNS 为公共评价表补充H/L独立STR身份字段。
count = height(rows);
STRHigh = repmat(double(candidate.STRHigh), count, 1);
STRLow = repmat(double(candidate.STRLow), count, 1);
IsBaseline = repmat(logical(candidate.IsBaseline), count, 1);
rows = addvars(rows, STRHigh, STRLow, IsBaseline, ...
    'After', "QLow");
end

function verify_complete_state(state, candidates, scenes, manifest, frame_count)
%VERIFY_COMPLETE_STATE 写出结果前核对所有候选、场景和序列均已完成。
expected_units = height(candidates) * numel(scenes);
expected_sequences = height(candidates) * height(manifest);
expected_frames = expected_sequences * frame_count;
if numel(unique(state.completed_units)) ~= expected_units || ...
        height(state.per_sequence) ~= expected_sequences || ...
        height(state.per_frame) ~= expected_frames || ...
        any(~isfinite(state.per_sequence.MeanPSNR)) || ...
        any(~isfinite(state.per_sequence.MeanSSIM))
    error('sarvalid:V4IncompleteState', ...
        'V4 checkpoint尚未包含全部候选评价结果。');
end
end

function scene_metrics = aggregate_candidate_scenes(per_sequence, candidates)
%AGGREGATE_CANDIDATE_SCENES 先在场景内汇总5条序列，避免样本权重漂移。
scene_metrics = table();
scenes = unique(string(per_sequence.Scene), 'stable');
for candidate_idx = 1:height(candidates)
    candidate = candidates(candidate_idx, :);
    for scene_idx = 1:numel(scenes)
        mask = string(per_sequence.PairKey) == candidate.CandidateKey & ...
            string(per_sequence.Scene) == scenes(scene_idx);
        rows = per_sequence(mask, :);
        if height(rows) ~= 5
            error('sarvalid:V4SceneSequenceCount', ...
                '候选%s场景%s必须包含5条序列。', ...
                candidate.CandidateKey, scenes(scene_idx));
        end
        scene_metrics = append_table(scene_metrics, ...
            aggregate_metric_rows(rows, candidate, scenes(scene_idx), 5));
    end
end
end

function candidate_summary = aggregate_candidates(scene_metrics, candidates)
%AGGREGATE_CANDIDATES 按七场景等权汇总并执行预注册排序。
candidate_summary = table();
for idx = 1:height(candidates)
    candidate = candidates(idx, :);
    rows = scene_metrics( ...
        scene_metrics.CandidateKey == candidate.CandidateKey, :);
    if height(rows) ~= 7
        error('sarvalid:V4CandidateSceneCount', ...
            '候选%s必须包含7个场景汇总。', candidate.CandidateKey);
    end
    candidate_summary = append_table(candidate_summary, ...
        aggregate_metric_rows(rows, candidate, "ALL_SCENES", 7));
end
candidate_summary = add_scene_wins(candidate_summary, scene_metrics);
candidate_summary = sortrows(candidate_summary, ...
    ["MeanSSIM", "LRegionSSIM", "WorstSSIM", ...
    "MeanPSNR", "CandidateKey"], ...
    ["descend", "descend", "descend", "descend", "ascend"]);
Rank = (1:height(candidate_summary)).';
candidate_summary = addvars(candidate_summary, Rank, 'Before', 1);
end

function summary = add_scene_wins(summary, scene_metrics)
%ADD_SCENE_WINS 逐候选记录相对共享基线的PSNR、SSIM及联合场景胜场。
baseline_key = summary.CandidateKey(summary.IsBaseline);
if numel(baseline_key) ~= 1
    error('sarvalid:V4SceneWinBaseline', ...
        '场景胜场统计需要唯一共享STR基线。');
end
baseline = sortrows(scene_metrics( ...
    scene_metrics.CandidateKey == baseline_key, :), "Scene");
PSNRSceneWins = zeros(height(summary), 1);
SSIMSceneWins = zeros(height(summary), 1);
JointSceneWins = zeros(height(summary), 1);
for idx = 1:height(summary)
    current = sortrows(scene_metrics( ...
        scene_metrics.CandidateKey == summary.CandidateKey(idx), :), "Scene");
    if height(current) ~= height(baseline) || ...
            ~isequal(current.Scene, baseline.Scene)
        error('sarvalid:V4SceneWinPairing', ...
            '候选%s无法与共享基线逐场景配对。', ...
            summary.CandidateKey(idx));
    end
    psnr_gain = current.MeanPSNR > baseline.MeanPSNR;
    ssim_gain = current.MeanSSIM > baseline.MeanSSIM;
    PSNRSceneWins(idx) = sum(psnr_gain);
    SSIMSceneWins(idx) = sum(ssim_gain);
    JointSceneWins(idx) = sum(psnr_gain & ssim_gain);
end
summary = addvars(summary, PSNRSceneWins, SSIMSceneWins, ...
    JointSceneWins, 'After', "RowCount");
end

function row = aggregate_metric_rows(rows, candidate, scene, row_count)
%AGGREGATE_METRIC_ROWS 汇总V4决策所需的质量和一致性指标。
CandidateKey = string(candidate.CandidateKey);
STRHigh = double(candidate.STRHigh);
STRLow = double(candidate.STRLow);
IsBaseline = logical(candidate.IsBaseline);
Scene = string(scene);
RowCount = row_count;
names = ["MeanPSNR", "MeanSSIM", "WorstPSNR", "WorstSSIM", ...
    "HRegionPSNR", "HRegionSSIM", "LRegionPSNR", "LRegionSSIM", ...
    "PSNRSmoothness", "SSIMSmoothness", "OverlapExcessSSIMLoss", ...
    "BoundaryGradientExcess", "RangeLeakageRatio", ...
    "AzimuthLeakageRatio"];
values = zeros(1, numel(names));
for idx = 1:numel(names)
    values(idx) = mean(rows.(names(idx)), 'omitnan');
end
if any(~isfinite(values))
    error('sarvalid:V4NonfiniteMetric', ...
        '候选%s场景%s包含非有限汇总指标。', CandidateKey, Scene);
end
metric_table = array2table(values, 'VariableNames', cellstr(names));
row = [table(CandidateKey, STRHigh, STRLow, IsBaseline, ...
    Scene, RowCount), metric_table];
end

function curve_summary = aggregate_curves(per_frame, candidates, scenes)
%AGGREGATE_CURVES 按场景等权汇总每个候选的九帧PSNR/SSIM曲线。
curve_summary = table();
for candidate_idx = 1:height(candidates)
    candidate = candidates(candidate_idx, :);
    for frame_idx = 0:8
        scene_psnr = zeros(numel(scenes), 1);
        scene_ssim = zeros(numel(scenes), 1);
        for scene_idx = 1:numel(scenes)
            mask = string(per_frame.PairKey) == candidate.CandidateKey & ...
                string(per_frame.Scene) == scenes(scene_idx) & ...
                per_frame.FrameIdx == frame_idx;
            rows = per_frame(mask, :);
            if height(rows) ~= 5
                error('sarvalid:V4CurveSceneCount', ...
                    '候选%s场景%s帧%d必须包含5条记录。', ...
                    candidate.CandidateKey, scenes(scene_idx), frame_idx);
            end
            scene_psnr(scene_idx) = mean(rows.PSNR);
            scene_ssim(scene_idx) = mean(rows.SSIM);
        end
        CandidateKey = candidate.CandidateKey;
        STRHigh = candidate.STRHigh;
        STRLow = candidate.STRLow;
        IsBaseline = candidate.IsBaseline;
        FrameIdx = frame_idx;
        MeanPSNR = mean(scene_psnr);
        MeanSSIM = mean(scene_ssim);
        curve_summary = append_table(curve_summary, table( ...
            CandidateKey, STRHigh, STRLow, IsBaseline, ...
            FrameIdx, MeanPSNR, MeanSSIM));
    end
end
end

function [decision, best_key] = make_decision(scene_metrics, summary, v4)
%MAKE_DECISION 比较最佳非对称STR与共享基线并执行全部升级门槛。
baseline = summary(summary.CandidateKey == v4.baseline_key, :);
asymmetric = summary(~summary.IsBaseline & ...
    summary.STRHigh ~= summary.STRLow, :);
if height(baseline) ~= 1 || isempty(asymmetric)
    error('sarvalid:V4DecisionCandidates', ...
        'V4决策缺少唯一共享基线或非对称候选。');
end
asymmetric = sortrows(asymmetric, ...
    ["MeanSSIM", "LRegionSSIM", "WorstSSIM", ...
    "MeanPSNR", "CandidateKey"], ...
    ["descend", "descend", "descend", "descend", "ascend"]);
best = asymmetric(1, :);
best_key = string(best.CandidateKey);

baseline_scene = sortrows(scene_metrics( ...
    scene_metrics.CandidateKey == v4.baseline_key, :), "Scene");
best_scene = sortrows(scene_metrics( ...
    scene_metrics.CandidateKey == best_key, :), "Scene");
if ~isequal(baseline_scene.Scene, best_scene.Scene)
    error('sarvalid:V4DecisionScenePairing', ...
        '最佳候选和基线无法逐场景配对。');
end
scene_psnr_delta = best_scene.MeanPSNR - baseline_scene.MeanPSNR;
scene_ssim_delta = best_scene.MeanSSIM - baseline_scene.MeanSSIM;
JointSceneWins = sum(scene_psnr_delta > 0 & scene_ssim_delta > 0);

MeanPSNRDelta = best.MeanPSNR - baseline.MeanPSNR;
MeanSSIMDelta = best.MeanSSIM - baseline.MeanSSIM;
WorstSSIMDelta = best.WorstSSIM - baseline.WorstSSIM;
LRegionSSIMDelta = best.LRegionSSIM - baseline.LRegionSSIM;
OverlapLossDelta = best.OverlapExcessSSIMLoss - ...
    baseline.OverlapExcessSSIMLoss;
BoundaryExcessDelta = best.BoundaryGradientExcess - ...
    baseline.BoundaryGradientExcess;
SSIMSmoothnessDelta = best.SSIMSmoothness - baseline.SSIMSmoothness;

MeanPSNRPass = MeanPSNRDelta >= v4.decision.mean_psnr_gain_db;
MeanSSIMPass = MeanSSIMDelta >= v4.decision.mean_ssim_gain;
SceneWinsPass = JointSceneWins >= ...
    v4.decision.minimum_joint_scene_wins;
WorstSSIMPass = WorstSSIMDelta >= -v4.decision.worst_ssim_loss;
LRegionSSIMPass = LRegionSSIMDelta >= ...
    -v4.decision.l_region_ssim_loss;
OverlapPass = OverlapLossDelta <= ...
    v4.decision.overlap_loss_increase;
BoundaryPass = BoundaryExcessDelta <= ...
    v4.decision.boundary_excess_increase;
SmoothnessPass = SSIMSmoothnessDelta <= ...
    v4.decision.ssim_smoothness_increase;
AllPass = MeanPSNRPass && MeanSSIMPass && SceneWinsPass && ...
    WorstSSIMPass && LRegionSSIMPass && OverlapPass && ...
    BoundaryPass && SmoothnessPass;
if AllPass
    Outcome = "needs_heldout_confirmation";
else
    Outcome = "keep_current_shared_sft";
end

BaselineKey = string(baseline.CandidateKey);
BestCandidateKey = best_key;
BestSTRHigh = best.STRHigh;
BestSTRLow = best.STRLow;
BaselineMeanPSNR = baseline.MeanPSNR;
BestMeanPSNR = best.MeanPSNR;
BaselineMeanSSIM = baseline.MeanSSIM;
BestMeanSSIM = best.MeanSSIM;
decision = table(Outcome, BaselineKey, BestCandidateKey, ...
    BestSTRHigh, BestSTRLow, BaselineMeanPSNR, BestMeanPSNR, ...
    MeanPSNRDelta, BaselineMeanSSIM, BestMeanSSIM, MeanSSIMDelta, ...
    WorstSSIMDelta, LRegionSSIMDelta, JointSceneWins, ...
    OverlapLossDelta, BoundaryExcessDelta, SSIMSmoothnessDelta, ...
    MeanPSNRPass, MeanSSIMPass, SceneWinsPass, WorstSSIMPass, ...
    LRegionSSIMPass, OverlapPass, BoundaryPass, SmoothnessPass, AllPass);
end

function plot_best_curves(curves, baseline_key, best_key, file_path)
%PLOT_BEST_CURVES 保存共享基线与最佳非对称候选的九帧质量曲线。
baseline = sortrows(curves(curves.CandidateKey == baseline_key, :), "FrameIdx");
best = sortrows(curves(curves.CandidateKey == best_key, :), "FrameIdx");
if height(baseline) ~= 9 || height(best) ~= 9
    error('sarvalid:V4CurveRows', '基线和最佳候选必须各有九帧曲线。');
end
figure_handle = figure('Visible', 'off', 'Color', 'w', ...
    'Position', [100, 100, 900, 700]);
cleanup = onCleanup(@() close(figure_handle));
tiledlayout(2, 1, 'Padding', 'compact', 'TileSpacing', 'compact');
nexttile;
plot(baseline.FrameIdx, baseline.MeanPSNR, '-o', 'LineWidth', 1.5);
hold on;
plot(best.FrameIdx, best.MeanPSNR, '-s', 'LineWidth', 1.5);
grid on;
xlabel('Frame index');
ylabel('Mean PSNR (dB)');
legend(["Shared STR baseline", "Best asymmetric STR"], ...
    'Location', 'best');
title('Range+2D-SFT V4 PSNR');
nexttile;
plot(baseline.FrameIdx, baseline.MeanSSIM, '-o', 'LineWidth', 1.5);
hold on;
plot(best.FrameIdx, best.MeanSSIM, '-s', 'LineWidth', 1.5);
grid on;
xlabel('Frame index');
ylabel('Mean SSIM');
legend(["Shared STR baseline", "Best asymmetric STR"], ...
    'Location', 'best');
title('Range+2D-SFT V4 SSIM');
exportgraphics(figure_handle, file_path, 'Resolution', 180);
clear cleanup;
end

function value = imaging_signature(S60)
%IMAGING_SIGNATURE 提取会改变成像结论的FS60核心参数。
names = ["fc", "B", "Fs", "prf", "R0", "C", "v", ...
    "Tp", "Ta", "nrn", "nan", "R_total", "A_num"];
value = struct();
for name = names
    if isfield(S60, name)
        value.(name) = S60.(name);
    end
end
end

function bandwidth = resolve_azimuth_bandwidth(S60)
%RESOLVE_AZIMUTH_BANDWIDTH 从FS60参数中解析方位带宽。
if isfield(S60, "Ba")
    bandwidth = S60.Ba;
elseif isfield(S60, "Bd")
    bandwidth = S60.Bd;
elseif isfield(S60, "Da")
    bandwidth = 2 * S60.v / S60.Da;
else
    error('sarvalid:V4MissingAzimuthBandwidth', ...
        'FS60参数必须包含Ba、Bd或Da。');
end
end

function key = candidate_key(str_high, str_low)
%CANDIDATE_KEY 构造包含H/L独立STR的稳定ASCII候选键。
key = "range_2d_sft_v4_qh4_ql2_sh" + encode(str_high) + ...
    "_sl" + encode(str_low) + "_fr1p3_fa0p5_phi0";
end

function output = encode(value)
%ENCODE 将数值转换为稳定ASCII键片段。
output = replace(string(sprintf('%.12g', double(value))), "-", "m");
output = replace(output, ".", "p");
output = replace(output, "+", "");
end

function output = append_table(input, rows)
%APPEND_TABLE 安全追加table，避免double空数组与table混用。
if isempty(input)
    output = rows;
else
    output = [input; rows];
end
end
