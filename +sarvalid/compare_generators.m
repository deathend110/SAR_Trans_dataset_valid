function [comparison, decision_report] = compare_generators( ...
        stage_a, stage_b, cfg)
%COMPARE_GENERATORS 按场景聚合并执行预注册的数据生成器决策规则。

comparison = table();
for pair_idx = 1:size(cfg.generator_compare.hl_pairs, 1)
    q_high = cfg.generator_compare.hl_pairs(pair_idx, 1);
    q_low = cfg.generator_compare.hl_pairs(pair_idx, 2);
    a = stage_a.verification_sample_detail;
    b = stage_b.sequence_summary;
    a = a(a.QHigh == q_high & a.QLow == q_low, :);
    b = b(b.QHigh == q_high & b.QLow == q_low, :);
    a_range = a(a.Method == "Range_2D_SFT", :);
    a_baru = a(a.Method == "BARU_RT", :);
    b_range = b(b.Method == "Range_2D_SFT", :);
    b_baru = b(b.Method == "BARU_RT", :);
    require_paired_rows(a_range, a_baru, "SampleID", 70);
    require_paired_rows(b_range, b_baru, "SequenceID", 14);

    [a_range, a_baru] = align_rows(a_range, a_baru, "SampleID");
    [b_range, b_baru] = align_rows(b_range, b_baru, "SequenceID");
    a_range_ssim = mean([a_range.HSSIM, a_range.LSSIM], 2);
    a_baru_ssim = mean([a_baru.HSSIM, a_baru.LSSIM], 2);
    a_diff = a_range_ssim - a_baru_ssim;
    [a_scene_diff, a_wins] = scene_differences( ...
        a_range.Scene, a_diff);
    [a_ci_low, a_ci_high] = cluster_bootstrap_ci( ...
        a_range.Scene, a_diff, cfg, pair_idx);

    b_diff = b_range.MeanSSIM - b_baru.MeanSSIM;
    [b_scene_diff, b_wins] = scene_differences( ...
        b_range.Scene, b_diff);
    [b_ci_low, b_ci_high] = cluster_bootstrap_ci( ...
        b_range.Scene, b_diff, cfg, 100 + pair_idx);

    audit = stage_a.difficulty_matching( ...
        stage_a.difficulty_matching.QHigh == q_high & ...
        stage_a.difficulty_matching.QLow == q_low, :);
    if height(audit) ~= 1
        error('sarvalid:GeneratorDifficultyAudit', ...
            '每个倍率对必须恰好有一条难度匹配审计记录。');
    end

    a_seed_rows = stage_a.verification_seed_detail( ...
        stage_a.verification_seed_detail.QHigh == q_high & ...
        stage_a.verification_seed_detail.QLow == q_low & ...
        stage_a.verification_seed_detail.Method == "BARU_RT", :);
    a_seed_rows.SeedMeanSSIM = mean( ...
        [a_seed_rows.HSSIM, a_seed_rows.LSSIM], 2);
    a_seed_means = groupsummary( ...
        a_seed_rows, "SeedFamily", "mean", "SeedMeanSSIM");
    StageABARUMaxSeedMeanSSIM = max(a_seed_means.mean_SeedMeanSSIM);
    StageASeedRankingStable = mean(a_range_ssim) >= ...
        StageABARUMaxSeedMeanSSIM - 1e-12;

    seed_rows = stage_b.seed_detail( ...
        stage_b.seed_detail.QHigh == q_high & ...
        stage_b.seed_detail.QLow == q_low & ...
        stage_b.seed_detail.Method == "BARU_RT", :);
    seed_means = groupsummary(seed_rows, "SeedFamily", "mean", "MeanSSIM");
    range_b_mean = mean(b_range.MeanSSIM);
    StageBSeedRankingStable = range_b_mean >= ...
        max(seed_means.mean_MeanSSIM) - 1e-12;
    SeedRankingStable = StageASeedRankingStable && StageBSeedRankingStable;

    QHigh = q_high;
    QLow = q_low;
    DifficultyStatus = string(audit.Status);
    DifficultyMatched = logical(audit.DifficultyMatched);
    StageAMeanSSIMRange = mean(a_range_ssim);
    StageAMeanSSIMBARU = mean(a_baru_ssim);
    StageAMeanSSIMDifference = mean(a_diff);
    StageASSIMCILow = a_ci_low;
    StageASSIMCIHigh = a_ci_high;
    StageASceneWins = a_wins;
    StageASceneCount = numel(a_scene_diff);
    StageAWorstSSIMRange = min([a_range.HSSIM; a_range.LSSIM]);
    StageAWorstSSIMBARU = min([a_baru.HSSIM; a_baru.LSSIM]);
    StageAGradientDifference = mean([a_range.HGradientRMSE; ...
        a_range.LGradientRMSE]) - mean([a_baru.HGradientRMSE; ...
        a_baru.LGradientRMSE]);
    StageABrightDifference = mean([a_range.HBrightScattererError; ...
        a_range.LBrightScattererError]) - ...
        mean([a_baru.HBrightScattererError; ...
        a_baru.LBrightScattererError]);
    StageBMeanSSIMRange = range_b_mean;
    StageBMeanSSIMBARU = mean(b_baru.MeanSSIM);
    StageBMeanSSIMDifference = mean(b_diff);
    StageBSSIMCILow = b_ci_low;
    StageBSSIMCIHigh = b_ci_high;
    StageBSceneWins = b_wins;
    StageBSceneCount = numel(b_scene_diff);
    StageBWorstSSIMRange = min(b_range.WorstSSIM);
    StageBWorstSSIMBARU = min(b_baru.WorstSSIM);
    StageBGradientDifference = mean(b_range.GradientRMSE) - ...
        mean(b_baru.GradientRMSE);
    StageBBrightDifference = mean(b_range.BrightScattererError) - ...
        mean(b_baru.BrightScattererError);
    RangeOverlapExcessSSIMLoss = mean(b_range.OverlapExcessSSIMLoss);
    BARUOverlapExcessSSIMLoss = mean(b_baru.OverlapExcessSSIMLoss);
    RangeBoundaryJumpDB = mean(abs(b_range.BoundaryJumpDB));
    BARUMaxSeedMeanSSIM = max(seed_means.mean_MeanSSIM);

    rule = cfg.generator_compare.decision;
    MeanSSIMNonInferior = StageAMeanSSIMDifference >= 0 && ...
        StageBMeanSSIMDifference >= 0;
    SceneWinCriterion = StageASceneWins >= 6 && StageBSceneWins >= 6;
    WorstSSIMNonInferior = StageAWorstSSIMRange >= StageAWorstSSIMBARU && ...
        StageBWorstSSIMRange >= StageBWorstSSIMBARU;
    StructureNonInferior = StageAGradientDifference <= 0 && ...
        StageABrightDifference <= 0 && StageBGradientDifference <= 0 && ...
        StageBBrightDifference <= 0;
    OverlapAcceptable = abs(RangeOverlapExcessSSIMLoss) <= ...
        rule.overlap_ssim_loss_tolerance && ...
        RangeOverlapExcessSSIMLoss <= BARUOverlapExcessSSIMLoss + ...
        rule.overlap_ssim_loss_tolerance;
    BoundaryAcceptable = RangeBoundaryJumpDB <= ...
        rule.boundary_jump_db_tolerance;
    DisadvantageWithinLimit = StageAMeanSSIMDifference >= ...
        -rule.mean_ssim_disadvantage_limit && ...
        StageBMeanSSIMDifference >= -rule.mean_ssim_disadvantage_limit;
    RangeSelectedForPair = DifficultyMatched && MeanSSIMNonInferior && ...
        SceneWinCriterion && WorstSSIMNonInferior && ...
        StructureNonInferior && OverlapAcceptable && BoundaryAcceptable && ...
        DisadvantageWithinLimit && SeedRankingStable;

    row = table(QHigh, QLow, DifficultyStatus, DifficultyMatched, ...
        StageAMeanSSIMRange, StageAMeanSSIMBARU, ...
        StageAMeanSSIMDifference, StageASSIMCILow, StageASSIMCIHigh, ...
        StageASceneWins, StageASceneCount, StageAWorstSSIMRange, ...
        StageAWorstSSIMBARU, StageAGradientDifference, ...
        StageABrightDifference, StageBMeanSSIMRange, StageBMeanSSIMBARU, ...
        StageBMeanSSIMDifference, StageBSSIMCILow, StageBSSIMCIHigh, ...
        StageBSceneWins, StageBSceneCount, StageBWorstSSIMRange, ...
        StageBWorstSSIMBARU, StageBGradientDifference, ...
        StageBBrightDifference, RangeOverlapExcessSSIMLoss, ...
        BARUOverlapExcessSSIMLoss, RangeBoundaryJumpDB, ...
        StageABARUMaxSeedMeanSSIM, BARUMaxSeedMeanSSIM, ...
        StageASeedRankingStable, StageBSeedRankingStable, ...
        MeanSSIMNonInferior, SceneWinCriterion, ...
        WorstSSIMNonInferior, StructureNonInferior, OverlapAcceptable, ...
        BoundaryAcceptable, DisadvantageWithinLimit, ...
        SeedRankingStable, RangeSelectedForPair);
    comparison = append_table(comparison, row);
end

decision_report = build_decision_report(comparison);
end

function report = build_decision_report(comparison)
pair_count = height(comparison);
Scope = [repmat("pair", pair_count, 1); "overall"];
QHigh = [comparison.QHigh; NaN];
QLow = [comparison.QLow; NaN];
DifficultyMatched = [comparison.DifficultyMatched; ...
    all(comparison.DifficultyMatched)];
RangeSelected = [comparison.RangeSelectedForPair; ...
    all(comparison.RangeSelectedForPair)];
EqualWeightStageASSIMDifference = [comparison.StageAMeanSSIMDifference; ...
    mean(comparison.StageAMeanSSIMDifference)];
EqualWeightStageBSSIMDifference = [comparison.StageBMeanSSIMDifference; ...
    mean(comparison.StageBMeanSSIMDifference)];
Outcome = strings(pair_count + 1, 1);
for idx = 1:pair_count
    if comparison.RangeSelectedForPair(idx)
        Outcome(idx) = "select_range_2d_sft";
    elseif ~comparison.DifficultyMatched(idx)
        Outcome(idx) = "difficulty_unmatched_descriptive_only";
    else
        Outcome(idx) = "range_selection_criteria_not_met";
    end
end
if all(comparison.RangeSelectedForPair)
    Outcome(end) = "select_range_2d_sft";
elseif ~any(comparison.DifficultyMatched)
    Outcome(end) = "descriptive_only_both_pairs_unmatched";
elseif prod(sign(comparison.StageBMeanSSIMDifference)) < 0
    Outcome(end) = "sampling_rate_dependent_no_freeze";
else
    Outcome(end) = "no_automatic_freeze";
end
report = table(Scope, QHigh, QLow, DifficultyMatched, RangeSelected, ...
    EqualWeightStageASSIMDifference, EqualWeightStageBSSIMDifference, ...
    Outcome);
end

function [left, right] = align_rows(left, right, key)
left = sortrows(left, key);
right = sortrows(right, key);
if ~isequal(left.(key), right.(key))
    error('sarvalid:GeneratorPairingMismatch', ...
        'Range与BARU的%s无法一一配对。', key);
end
end

function require_paired_rows(left, right, key, expected_count)
if height(left) ~= expected_count || height(right) ~= expected_count || ...
        numel(unique(left.(key))) ~= expected_count || ...
        numel(unique(right.(key))) ~= expected_count
    error('sarvalid:GeneratorComparisonRowCount', ...
        '%s比较要求Range/BARU各%d条唯一记录。', key, expected_count);
end
end

function [scene_values, wins] = scene_differences(scenes, differences)
scene_names = unique(scenes, 'stable');
scene_values = zeros(numel(scene_names), 1);
for idx = 1:numel(scene_names)
    scene_values(idx) = mean(differences(scenes == scene_names(idx)));
end
wins = sum(scene_values > 0);
end

function [ci_low, ci_high] = cluster_bootstrap_ci( ...
        scenes, differences, cfg, seed_offset)
scene_names = unique(scenes, 'stable');
scene_means = zeros(numel(scene_names), 1);
for idx = 1:numel(scene_names)
    scene_means(idx) = mean(differences(scenes == scene_names(idx)));
end
stream = RandStream("mt19937ar", "Seed", ...
    cfg.generator_compare.bootstrap_seed + seed_offset);
draw_count = cfg.generator_compare.bootstrap_repetitions;
draws = zeros(draw_count, 1);
for idx = 1:draw_count
    selected = randi(stream, numel(scene_means), numel(scene_means), 1);
    draws(idx) = mean(scene_means(selected));
end
interval = prctile(draws, [2.5, 97.5]);
ci_low = interval(1);
ci_high = interval(2);
end

function output = append_table(input, rows)
if isempty(input)
    output = rows;
else
    output = [input; rows];
end
end
