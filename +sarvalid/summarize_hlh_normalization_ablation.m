function [scene_summary, curve_summary, comparison, decision] = ...
        summarize_hlh_normalization_ablation(per_frame, sequence_summary, cfg)
%SUMMARIZE_HLH_NORMALIZATION_ABLATION 汇总场景、曲线与预注册判据。

main_frames = per_frame(per_frame.CaseLabel == "main35", :);
main_sequences = sequence_summary(sequence_summary.CaseLabel == "main35", :);
policies = string(cfg.hlh_normalization_ablation.policies);
pairs = cfg.hlh_normalization_ablation.hl_pairs;
scenes = unique(string(main_sequences.Scene), 'stable');

scene_summary = table();
for pair_idx = 1:size(pairs, 1)
    for policy_idx = 1:numel(policies)
        for scene_idx = 1:numel(scenes)
            mask = main_sequences.QHigh == pairs(pair_idx, 1) & ...
                main_sequences.QLow == pairs(pair_idx, 2) & ...
                main_sequences.Policy == policies(policy_idx) & ...
                main_sequences.Scene == scenes(scene_idx);
            rows = main_sequences(mask, :);
            if isempty(rows)
                error('sarvalid:MissingHLHSceneRows', ...
                    '场景汇总缺少倍率、策略或场景组合。');
            end
            scene_summary = append_table(scene_summary, ...
                aggregate_scene(rows));
        end
    end
end

curve_summary = table();
for pair_idx = 1:size(pairs, 1)
    for policy_idx = 1:numel(policies)
        for frame_idx = 0:cfg.sequence.n_frames-1
            scene_psnr = zeros(numel(scenes), 1);
            scene_ssim = zeros(numel(scenes), 1);
            for scene_idx = 1:numel(scenes)
                mask = main_frames.QHigh == pairs(pair_idx, 1) & ...
                    main_frames.QLow == pairs(pair_idx, 2) & ...
                    main_frames.Policy == policies(policy_idx) & ...
                    main_frames.Scene == scenes(scene_idx) & ...
                    main_frames.FrameIdx == frame_idx;
                rows = main_frames(mask, :);
                scene_psnr(scene_idx) = mean(rows.PSNR);
                scene_ssim(scene_idx) = mean(rows.SSIM);
            end
            QHigh = pairs(pair_idx, 1);
            QLow = pairs(pair_idx, 2);
            Policy = policies(policy_idx);
            FrameIdx = frame_idx;
            SceneCount = numel(scenes);
            MeanPSNR = mean(scene_psnr);
            MeanSSIM = mean(scene_ssim);
            PSNRStdAcrossScenes = std(scene_psnr);
            SSIMStdAcrossScenes = std(scene_ssim);
            curve_summary = append_table(curve_summary, table( ...
                QHigh, QLow, Policy, FrameIdx, SceneCount, MeanPSNR, ...
                MeanSSIM, PSNRStdAcrossScenes, SSIMStdAcrossScenes));
        end
    end
end

comparison = table();
limits = cfg.hlh_normalization_ablation.decision;
for pair_idx = 1:size(pairs, 1)
    q_high = pairs(pair_idx, 1);
    q_low = pairs(pair_idx, 2);
    legacy = main_sequences(main_sequences.QHigh == q_high & ...
        main_sequences.QLow == q_low & ...
        main_sequences.Policy == "legacy_split", :);
    joint = main_sequences(main_sequences.QHigh == q_high & ...
        main_sequences.QLow == q_low & ...
        main_sequences.Policy == "joint_hl_shared", :);
    legacy = sortrows(legacy, ["Scene", "SequenceID"]);
    joint = sortrows(joint, ["Scene", "SequenceID"]);
    if ~isequal(legacy.SequenceID(:), joint.SequenceID(:)) || ...
            ~isequal(legacy.Scene(:), joint.Scene(:))
        error('sarvalid:HLHPolicyPairingMismatch', ...
            '两种归一化策略的SequenceID无法逐条配对。');
    end

    LegacyLeftPSNRJump = mean(legacy.LeftPSNRJump);
    JointLeftPSNRJump = mean(joint.LeftPSNRJump);
    LeftEdgeJumpReduction = safe_reduction( ...
        LegacyLeftPSNRJump, JointLeftPSNRJump);
    LegacyRightPSNRJump = mean(legacy.RightPSNRJump);
    JointRightPSNRJump = mean(joint.RightPSNRJump);
    RightEdgeJumpReduction = safe_reduction( ...
        LegacyRightPSNRJump, JointRightPSNRJump);
    LegacyEdgeJump = mean((legacy.LeftPSNRJump + legacy.RightPSNRJump) / 2);
    JointEdgeJump = mean((joint.LeftPSNRJump + joint.RightPSNRJump) / 2);
    EdgeJumpReduction = safe_reduction(LegacyEdgeJump, JointEdgeJump);
    LegacyPSNRRoughness = mean(legacy.PSNRSmoothness);
    JointPSNRRoughness = mean(joint.PSNRSmoothness);
    PSNRRoughnessReduction = safe_reduction( ...
        LegacyPSNRRoughness, JointPSNRRoughness);
    LegacySSIMRoughness = mean(legacy.SSIMSmoothness);
    JointSSIMRoughness = mean(joint.SSIMSmoothness);
    SSIMRoughnessReduction = safe_reduction( ...
        LegacySSIMRoughness, JointSSIMRoughness);
    MeanPSNRDelta = mean(joint.MeanPSNR - legacy.MeanPSNR);
    MeanSSIMDelta = mean(joint.MeanSSIM - legacy.MeanSSIM);
    WorstPSNRDelta = mean(joint.WorstPSNR - legacy.WorstPSNR);
    WorstSSIMDelta = mean(joint.WorstSSIM - legacy.WorstSSIM);
    LRegionPSNRDelta = mean(joint.LRegionPSNR - legacy.LRegionPSNR);
    LRegionSSIMDelta = mean(joint.LRegionSSIM - legacy.LRegionSSIM);
    F4PSNRDelta = mean(joint.F4PSNR - legacy.F4PSNR);
    F4SSIMDelta = mean(joint.F4SSIM - legacy.F4SSIM);
    OverlapLossDelta = mean( ...
        joint.OverlapExcessSSIMLoss - legacy.OverlapExcessSSIMLoss);
    GradientRelativeChange = relative_change( ...
        mean(legacy.GradientRMSE), mean(joint.GradientRMSE));
    BrightRelativeChange = relative_change( ...
        mean(legacy.BrightScattererError), ...
        mean(joint.BrightScattererError));
    MaxAbsBoundaryJumpDB = max(abs(joint.BoundaryJumpDB));
    LegacyPSNRAnomalyRate = mean(legacy.PSNRShapeAnomaly);
    JointPSNRAnomalyRate = mean(joint.PSNRShapeAnomaly);
    LegacySSIMAnomalyRate = mean(legacy.SSIMShapeAnomaly);
    JointSSIMAnomalyRate = mean(joint.SSIMShapeAnomaly);

    legacy_scene = scene_summary(scene_summary.QHigh == q_high & ...
        scene_summary.QLow == q_low & ...
        scene_summary.Policy == "legacy_split", :);
    joint_scene = scene_summary(scene_summary.QHigh == q_high & ...
        scene_summary.QLow == q_low & ...
        scene_summary.Policy == "joint_hl_shared", :);
    legacy_scene = sortrows(legacy_scene, "Scene");
    joint_scene = sortrows(joint_scene, "Scene");
    if ~isequal(legacy_scene.Scene(:), joint_scene.Scene(:))
        error('sarvalid:HLHScenePairingMismatch', ...
            '场景平滑度无法逐场景配对。');
    end
    SceneRoughnessWins = sum( ...
        joint_scene.PSNRSmoothness < legacy_scene.PSNRSmoothness);

    joint_curve = curve_summary(curve_summary.QHigh == q_high & ...
        curve_summary.QLow == q_low & ...
        curve_summary.Policy == "joint_hl_shared", :);
    [~, min_idx] = min(joint_curve.MeanPSNR);
    JointCurveMinimumFrame = joint_curve.FrameIdx(min_idx);

    EdgeJumpPass = LeftEdgeJumpReduction >= limits.edge_jump_reduction && ...
        RightEdgeJumpReduction >= limits.edge_jump_reduction;
    PSNRRoughnessPass = PSNRRoughnessReduction >= ...
        limits.psnr_roughness_reduction;
    SSIMPass = MeanSSIMDelta >= -limits.ssim_margin && ...
        WorstSSIMDelta >= -limits.ssim_margin;
    MeanPSNRPass = MeanPSNRDelta >= -limits.mean_psnr_margin_db;
    F4Pass = F4PSNRDelta >= -limits.f4_psnr_margin_db && ...
        F4SSIMDelta >= -limits.f4_ssim_margin;
    SceneWinsPass = SceneRoughnessWins >= limits.scene_roughness_wins;
    OverlapPass = OverlapLossDelta <= limits.overlap_loss_delta;
    StructurePass = GradientRelativeChange <= ...
        limits.structure_relative_margin && BrightRelativeChange <= ...
        limits.structure_relative_margin;
    BoundaryPass = MaxAbsBoundaryJumpDB <= limits.boundary_jump_db;
    VShapePass = JointCurveMinimumFrame >= 3 && ...
        JointCurveMinimumFrame <= 5;
    AllPass = EdgeJumpPass && PSNRRoughnessPass && SSIMPass && ...
        MeanPSNRPass && F4Pass && SceneWinsPass && OverlapPass && ...
        StructurePass && BoundaryPass;

    QHigh = q_high;
    QLow = q_low;
    comparison = append_table(comparison, table(QHigh, QLow, ...
        LegacyLeftPSNRJump, JointLeftPSNRJump, LeftEdgeJumpReduction, ...
        LegacyRightPSNRJump, JointRightPSNRJump, RightEdgeJumpReduction, ...
        LegacyEdgeJump, JointEdgeJump, EdgeJumpReduction, ...
        LegacyPSNRRoughness, JointPSNRRoughness, ...
        PSNRRoughnessReduction, LegacySSIMRoughness, ...
        JointSSIMRoughness, SSIMRoughnessReduction, MeanPSNRDelta, ...
        MeanSSIMDelta, WorstPSNRDelta, WorstSSIMDelta, ...
        LRegionPSNRDelta, LRegionSSIMDelta, F4PSNRDelta, F4SSIMDelta, ...
        SceneRoughnessWins, OverlapLossDelta, GradientRelativeChange, ...
        BrightRelativeChange, MaxAbsBoundaryJumpDB, ...
        LegacyPSNRAnomalyRate, JointPSNRAnomalyRate, ...
        LegacySSIMAnomalyRate, JointSSIMAnomalyRate, ...
        JointCurveMinimumFrame, EdgeJumpPass, PSNRRoughnessPass, ...
        SSIMPass, MeanPSNRPass, F4Pass, SceneWinsPass, OverlapPass, ...
        StructurePass, BoundaryPass, VShapePass, AllPass));
end

EligibleForIntegration = all(comparison.AllPass);
if EligibleForIntegration
    Outcome = "eligible_for_joint_hl_shared_integration";
else
    Outcome = "retain_legacy_split_pending_evidence";
end
PairCount = height(comparison);
PassingPairCount = sum(comparison.AllPass);
decision = table(Outcome, EligibleForIntegration, PairCount, PassingPairCount);
end

function row = aggregate_scene(rows)
Policy = string(rows.Policy(1));
Scene = string(rows.Scene(1));
QHigh = rows.QHigh(1);
QLow = rows.QLow(1);
SequenceCount = height(rows);
MeanPSNR = mean(rows.MeanPSNR);
MeanSSIM = mean(rows.MeanSSIM);
WorstPSNR = mean(rows.WorstPSNR);
WorstSSIM = mean(rows.WorstSSIM);
F4PSNR = mean(rows.F4PSNR);
F4SSIM = mean(rows.F4SSIM);
PSNRSmoothness = mean(rows.PSNRSmoothness);
SSIMSmoothness = mean(rows.SSIMSmoothness);
LeftPSNRJump = mean(rows.LeftPSNRJump);
RightPSNRJump = mean(rows.RightPSNRJump);
GradientRMSE = mean(rows.GradientRMSE);
BrightScattererError = mean(rows.BrightScattererError);
OverlapExcessSSIMLoss = mean(rows.OverlapExcessSSIMLoss);
BoundaryJumpDB = mean(rows.BoundaryJumpDB);
PSNRAnomalyRate = mean(rows.PSNRShapeAnomaly);
SSIMAnomalyRate = mean(rows.SSIMShapeAnomaly);
row = table(Policy, Scene, QHigh, QLow, SequenceCount, MeanPSNR, ...
    MeanSSIM, WorstPSNR, WorstSSIM, F4PSNR, F4SSIM, ...
    PSNRSmoothness, SSIMSmoothness, LeftPSNRJump, RightPSNRJump, ...
    GradientRMSE, BrightScattererError, OverlapExcessSSIMLoss, ...
    BoundaryJumpDB, PSNRAnomalyRate, SSIMAnomalyRate);
end

function value = safe_reduction(baseline, candidate)
value = (baseline - candidate) / max(abs(baseline), eps);
end

function value = relative_change(baseline, candidate)
value = (candidate - baseline) / max(abs(baseline), eps);
end

function output = append_table(input, rows)
if isempty(input)
    output = rows;
else
    output = [input; rows];
end
end
