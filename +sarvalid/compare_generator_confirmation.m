function [comparison, decision_report, scene_summary, ...
        tail_summary, nonzero_fa_summary] = compare_generator_confirmation( ...
        c1, c2, stage_a, stage_b, cfg)
%COMPARE_GENERATOR_CONFIRMATION 汇总两种生成器的直接成像效果。

gc = cfg.generator_confirmation;
comparison = table();
scene_summary = table();
tail_summary = table();

for pair_idx = 1:size(gc.hl_pairs, 1)
    q_high = gc.hl_pairs(pair_idx, 1);
    q_low = gc.hl_pairs(pair_idx, 2);
    a = stage_a.confirmation_sample_detail;
    b = stage_b.sequence_summary;
    a = a(a.QHigh == q_high & a.QLow == q_low, :);
    b = b(b.QHigh == q_high & b.QLow == q_low, :);
    a_range = a(a.Method == "Range_2D_SFT", :);
    a_baru = a(a.Method == "BARU_RT", :);
    b_range = b(b.Method == "Range_2D_SFT", :);
    b_baru = b(b.Method == "BARU_RT", :);
    require_paired_rows(a_range, a_baru, "SampleID", 140);
    require_paired_rows(b_range, b_baru, "SequenceID", 28);
    [a_range, a_baru] = align_rows(a_range, a_baru, "SampleID");
    [b_range, b_baru] = align_rows(b_range, b_baru, "SequenceID");

    a_range_ssim = mean([a_range.HSSIM, a_range.LSSIM], 2);
    a_baru_ssim = mean([a_baru.HSSIM, a_baru.LSSIM], 2);
    a_diff = a_range_ssim - a_baru_ssim;
    [a_scene_rows, a_wins, pair_tail] = ...
        sarvalid.summarize_confirmation_samples( ...
        a_range, a_baru, q_high, q_low, ...
        gc.tail_noninferiority_margin);
    [a_ci_low, a_ci_high] = cluster_bootstrap_ci( ...
        a_range.Scene, a_diff, gc, pair_idx);

    b_diff = b_range.MeanSSIM - b_baru.MeanSSIM;
    [b_scene_rows, b_wins] = scene_rows( ...
        b_range.Scene, b_diff, q_high, q_low, "Stage B");
    [b_ci_low, b_ci_high] = cluster_bootstrap_ci( ...
        b_range.Scene, b_diff, gc, 100 + pair_idx);
    scene_summary = append_table(scene_summary, [a_scene_rows; b_scene_rows]);

    tail_summary = append_table(tail_summary, pair_tail);
    p10_wins = sum(pair_tail.P10Difference >= ...
        -gc.tail_noninferiority_margin);
    worst3_wins = sum(pair_tail.Worst3Difference >= ...
        -gc.tail_noninferiority_margin);

    boundary = c1.boundary_audit(c1.boundary_audit.QHigh == q_high & ...
        c1.boundary_audit.QLow == q_low, :);
    difficulty = c2.difficulty_matching( ...
        c2.difficulty_matching.QHigh == q_high & ...
        c2.difficulty_matching.QLow == q_low & ...
        c2.difficulty_matching.Role == "severity_matched", :);
    if height(boundary) ~= 1 || height(difficulty) ~= 1
        error('sarvalid:ConfirmationDecisionAudit', ...
            '每个倍率对必须恰好有一条边界和主难度匹配记录。');
    end

    [a_seed_max, a_seed_std] = stage_a_seed_stats( ...
        stage_a.confirmation_seed_detail, q_high, q_low);
    [b_seed_max, b_seed_std] = stage_b_seed_stats( ...
        stage_b.seed_detail, q_high, q_low);

    QHigh = q_high;
    QLow = q_low;
    SearchClosed = logical(boundary.SearchClosed);
    StrictDifficultyMatched = logical(difficulty.DifficultyMatched);
    StageAMeanSSIMRange = mean(a_range_ssim);
    StageAMeanSSIMBARU = mean(a_baru_ssim);
    StageAMeanSSIMDifference = mean(a_diff);
    StageASSIMCILow = a_ci_low;
    StageASSIMCIHigh = a_ci_high;
    StageASceneWins = a_wins;
    StageAP10TailWins = p10_wins;
    StageAWorst3TailWins = worst3_wins;
    StageAGlobalMinimumDifference = ...
        min([a_range.HSSIM; a_range.LSSIM]) - ...
        min([a_baru.HSSIM; a_baru.LSSIM]);
    StageBMeanSSIMRange = mean(b_range.MeanSSIM);
    StageBMeanSSIMBARU = mean(b_baru.MeanSSIM);
    StageBMeanSSIMDifference = mean(b_diff);
    StageBSSIMCILow = b_ci_low;
    StageBSSIMCIHigh = b_ci_high;
    StageBSceneWins = b_wins;
    StageBWorstFrameMeanDifference = ...
        mean(b_range.WorstSSIM - b_baru.WorstSSIM);
    StageAGradientRatio = mean([a_range.HGradientRMSE; ...
        a_range.LGradientRMSE]) / max(mean([a_baru.HGradientRMSE; ...
        a_baru.LGradientRMSE]), eps);
    StageABrightRatio = mean([a_range.HBrightScattererError; ...
        a_range.LBrightScattererError]) / ...
        max(mean([a_baru.HBrightScattererError; ...
        a_baru.LBrightScattererError]), eps);
    StageBGradientRatio = mean(b_range.GradientRMSE) / ...
        max(mean(b_baru.GradientRMSE), eps);
    StageBBrightRatio = mean(b_range.BrightScattererError) / ...
        max(mean(b_baru.BrightScattererError), eps);
    RangeOverlapExcessSSIMLoss = mean(abs(b_range.OverlapExcessSSIMLoss));
    RangeBoundaryJumpDB = mean(abs(b_range.BoundaryJumpDB));
    StageABARUMaxSeedMeanSSIM = a_seed_max;
    StageBBARUMaxSeedMeanSSIM = b_seed_max;
    StageABARUSeedStd = a_seed_std;
    StageBBARUSeedStd = b_seed_std;

    StageAMeanPass = StageAMeanSSIMDifference >= 0 && ...
        StageASSIMCILow >= -gc.mean_noninferiority_margin;
    StageAScenePass = StageASceneWins >= 6;
    TailPass = StageAP10TailWins >= 6 && ...
        StageAWorst3TailWins >= 6 && ...
        StageAGlobalMinimumDifference >= ...
        -gc.catastrophic_minimum_margin;
    StageBMeanPass = StageBMeanSSIMDifference > 0 && ...
        StageBSSIMCILow > 0 && StageBSceneWins == 7;
    StageBWorstPass = StageBWorstFrameMeanDifference >= 0;
    StructurePass = all([StageAGradientRatio, StageABrightRatio, ...
        StageBGradientRatio, StageBBrightRatio] <= ...
        1 + gc.structure_relative_margin);
    ContinuityPass = RangeOverlapExcessSSIMLoss <= ...
        gc.overlap_ssim_loss_tolerance && ...
        RangeBoundaryJumpDB <= gc.boundary_jump_db_tolerance;
    SeedRankingStable = StageAMeanSSIMRange >= ...
        StageABARUMaxSeedMeanSSIM - 1e-12 && ...
        StageBMeanSSIMRange >= StageBBARUMaxSeedMeanSSIM - 1e-12;
    SeedSpreadStable = StageABARUSeedStd <= ...
        gc.seed_spread_fraction * abs(StageAMeanSSIMDifference) && ...
        StageBBARUSeedStd <= ...
        gc.seed_spread_fraction * abs(StageBMeanSSIMDifference);
    % 本实验用于直接观察两种生成器的成像效果。难度、尾部、结构和
    % seed指标继续完整保存，但不再作为停止或自动推荐门槛。
    RangeSelectedForPair = StageAMeanSSIMDifference > 0 && ...
        StageBMeanSSIMDifference > 0;

    row = table(QHigh, QLow, SearchClosed, StrictDifficultyMatched, ...
        StageAMeanSSIMRange, StageAMeanSSIMBARU, ...
        StageAMeanSSIMDifference, StageASSIMCILow, StageASSIMCIHigh, ...
        StageASceneWins, StageAP10TailWins, StageAWorst3TailWins, ...
        StageAGlobalMinimumDifference, StageBMeanSSIMRange, ...
        StageBMeanSSIMBARU, StageBMeanSSIMDifference, StageBSSIMCILow, ...
        StageBSSIMCIHigh, StageBSceneWins, ...
        StageBWorstFrameMeanDifference, StageAGradientRatio, ...
        StageABrightRatio, StageBGradientRatio, StageBBrightRatio, ...
        RangeOverlapExcessSSIMLoss, RangeBoundaryJumpDB, ...
        StageABARUMaxSeedMeanSSIM, StageBBARUMaxSeedMeanSSIM, ...
        StageABARUSeedStd, StageBBARUSeedStd, StageAMeanPass, ...
        StageAScenePass, TailPass, StageBMeanPass, StageBWorstPass, ...
        StructurePass, ContinuityPass, SeedRankingStable, ...
        SeedSpreadStable, RangeSelectedForPair);
    comparison = append_table(comparison, row);
end

decision_report = build_decision_report(comparison);
nonzero_fa_summary = build_nonzero_summary(stage_a, stage_b);
end

function [rows, wins] = scene_rows(scene_values, differences, ...
        q_high, q_low, stage)
scenes = unique(scene_values, 'stable');
rows = table();
wins = 0;
for idx = 1:numel(scenes)
    scene = scenes(idx);
    mask = scene_values == scene;
    MeanSSIMDifference = mean(differences(mask));
    wins = wins + (MeanSSIMDifference > 0);
    QHigh = q_high;
    QLow = q_low;
    Stage = string(stage);
    Scene = scene;
    rows = append_table(rows, ...
        table(QHigh, QLow, Stage, Scene, MeanSSIMDifference));
end
end

function [ci_low, ci_high] = cluster_bootstrap_ci( ...
        scenes, differences, gc, seed_offset)
unique_scenes = unique(scenes, 'stable');
scene_count = numel(unique_scenes);
draw_count = gc.bootstrap_repetitions;
stream = RandStream("mt19937ar", ...
    "Seed", gc.bootstrap_seed + seed_offset);
draws = zeros(draw_count, 1);
for draw_idx = 1:draw_count
    selected = randi(stream, scene_count, scene_count, 1);
    values = zeros(scene_count, 1);
    for scene_idx = 1:scene_count
        scene = unique_scenes(selected(scene_idx));
        values(scene_idx) = mean(differences(scenes == scene));
    end
    draws(draw_idx) = mean(values);
end
draws = sort(draws);
ci_low = indexed_percentile(draws, 0.025);
ci_high = indexed_percentile(draws, 0.975);
end

function value = indexed_percentile(values, probability)
index = max(1, min(numel(values), ...
    round(probability * (numel(values) - 1)) + 1));
value = values(index);
end

function [max_seed_mean, seed_std] = stage_a_seed_stats( ...
        input, q_high, q_low)
rows = input(input.QHigh == q_high & input.QLow == q_low & ...
    input.Method == "BARU_RT", :);
seeds = unique(rows.SeedFamily, 'stable');
means = zeros(numel(seeds), 1);
for idx = 1:numel(seeds)
    subset = rows(rows.SeedFamily == seeds(idx), :);
    means(idx) = mean([subset.HSSIM; subset.LSSIM]);
end
max_seed_mean = max(means);
seed_std = std(means, 0);
end

function [max_seed_mean, seed_std] = stage_b_seed_stats( ...
        input, q_high, q_low)
rows = input(input.QHigh == q_high & input.QLow == q_low & ...
    input.Method == "BARU_RT", :);
seeds = unique(rows.SeedFamily, 'stable');
means = zeros(numel(seeds), 1);
for idx = 1:numel(seeds)
    means(idx) = mean(rows.MeanSSIM(rows.SeedFamily == seeds(idx)));
end
max_seed_mean = max(means);
seed_std = std(means, 0);
end

function report = build_decision_report(comparison)
pair_count = height(comparison);
Scope = [repmat("pair", pair_count, 1); "overall"];
QHigh = [comparison.QHigh; NaN];
QLow = [comparison.QLow; NaN];
SearchClosed = [comparison.SearchClosed; all(comparison.SearchClosed)];
StrictDifficultyMatched = [comparison.StrictDifficultyMatched; ...
    all(comparison.StrictDifficultyMatched)];
RangeSelected = [comparison.RangeSelectedForPair; ...
    all(comparison.RangeSelectedForPair)];
EqualWeightStageASSIMDifference = ...
    [comparison.StageAMeanSSIMDifference; ...
    mean(comparison.StageAMeanSSIMDifference)];
EqualWeightStageBSSIMDifference = ...
    [comparison.StageBMeanSSIMDifference; ...
    mean(comparison.StageBMeanSSIMDifference)];
Outcome = strings(pair_count + 1, 1);
for idx = 1:pair_count
    if comparison.RangeSelectedForPair(idx)
        Outcome(idx) = "select_range_sft_open2d";
    else
        Outcome(idx) = "range_not_better_in_both_stages";
    end
end
if all(comparison.RangeSelectedForPair)
    Outcome(end) = "freeze_range_sft_open2d";
elseif any(comparison.RangeSelectedForPair)
    Outcome(end) = "rate_dependent_no_automatic_freeze";
else
    Outcome(end) = "do_not_freeze_range_sft_open2d";
end
report = table(Scope, QHigh, QLow, SearchClosed, ...
    StrictDifficultyMatched, RangeSelected, ...
    EqualWeightStageASSIMDifference, ...
    EqualWeightStageBSSIMDifference, Outcome);
end

function output = build_nonzero_summary(stage_a, stage_b)
a = stage_a.confirmation_sample_detail;
b = stage_b.sequence_summary;
main_a = a(a.QHigh == 2.5 & a.QLow == 1.5 & ...
    a.Method == "Range_2D_SFT", :);
aux_a = a(a.QHigh == 2.5 & a.QLow == 1.5 & ...
    a.Method == "Range_NonzeroFa_SFT", :);
main_b = b(b.QHigh == 2.5 & b.QLow == 1.5 & ...
    b.Method == "Range_2D_SFT", :);
aux_b = b(b.QHigh == 2.5 & b.QLow == 1.5 & ...
    b.Method == "Range_NonzeroFa_SFT", :);
if isempty(aux_a) || isempty(aux_b)
    output = table();
    return;
end
QHigh = 2.5;
QLow = 1.5;
StageAMainMeanSSIM = mean([main_a.HSSIM; main_a.LSSIM]);
StageANonzeroFaMeanSSIM = mean([aux_a.HSSIM; aux_a.LSSIM]);
StageANonzeroFaDifference = ...
    StageANonzeroFaMeanSSIM - StageAMainMeanSSIM;
StageBMainMeanSSIM = mean(main_b.MeanSSIM);
StageBNonzeroFaMeanSSIM = mean(aux_b.MeanSSIM);
StageBNonzeroFaDifference = ...
    StageBNonzeroFaMeanSSIM - StageBMainMeanSSIM;
InterpretationOnly = true;
output = table(QHigh, QLow, StageAMainMeanSSIM, ...
    StageANonzeroFaMeanSSIM, StageANonzeroFaDifference, ...
    StageBMainMeanSSIM, StageBNonzeroFaMeanSSIM, ...
    StageBNonzeroFaDifference, InterpretationOnly);
end

function require_paired_rows(a, b, key_name, expected_count)
if height(a) ~= expected_count || height(b) ~= expected_count || ...
        numel(unique(a.(key_name))) ~= expected_count || ...
        numel(unique(b.(key_name))) ~= expected_count || ...
        ~isequal(sort(a.(key_name)), sort(b.(key_name)))
    error('sarvalid:ConfirmationPairedRows', ...
        '确认实验%s配对行不完整，期望%d行。', key_name, expected_count);
end
end

function [a, b] = align_rows(a, b, key_name)
[~, order_a] = sort(a.(key_name));
[~, order_b] = sort(b.(key_name));
a = a(order_a, :);
b = b(order_b, :);
end

function output = append_table(input, rows)
if isempty(input)
    output = rows;
else
    output = [input; rows];
end
end
