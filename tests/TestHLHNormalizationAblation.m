classdef TestHLHNormalizationAblation < matlab.unittest.TestCase
    methods (TestClassSetup)
        function addRepositoryToPath(testCase)
            tests_dir = fileparts(mfilename("fullpath"));
            repo_root = fileparts(tests_dir);
            addpath(repo_root);
            testCase.addTeardown(@() rmpath(repo_root));
        end
    end

    methods (Test)
        function testJointPolicyUsesOneRangeForAllFrames(testCase)
            mixed = 5 * ones(6, 6, 3, 'single');
            gt = zeros(size(mixed), 'single');
            gt_stats = struct("VMin", 0, "VMax", 10);
            h_stats = struct("VMin", 0, "VMax", 10);
            l_stats = struct("VMin", 0, "VMax", 100);
            joint_stats = struct("VMin", 0, "VMax", 20);
            [joint, ~, ranges] = sarvalid.normalize_hlh_with_policy( ...
                mixed, gt, [1, 0.5, 1], gt_stats, h_stats, l_stats, ...
                joint_stats, "joint_hl_shared", 4);
            testCase.verifyEqual(joint, ...
                single(0.25 * ones(4, 4, 3)), 'AbsTol', 1e-7);
            testCase.verifyEqual(ranges.VMin, zeros(3, 1));
            testCase.verifyEqual(ranges.VMax, 20 * ones(3, 1));
        end

        function testLegacyAndJointMatchWhenStatisticsMatch(testCase)
            stream = RandStream("mt19937ar", "Seed", 17);
            mixed = single(rand(stream, 6, 6, 3));
            gt = single(rand(stream, 6, 6, 3));
            stats = struct("VMin", 0.1, "VMax", 0.9);
            [legacy_input, legacy_gt] = ...
                sarvalid.normalize_hlh_with_policy( ...
                mixed, gt, [1, 0.5, 1], stats, stats, stats, stats, ...
                "legacy_split", 4);
            [joint_input, joint_gt] = ...
                sarvalid.normalize_hlh_with_policy( ...
                mixed, gt, [1, 0.5, 1], stats, stats, stats, stats, ...
                "joint_hl_shared", 4);
            testCase.verifyEqual(joint_input, legacy_input, 'AbsTol', 0);
            testCase.verifyEqual(joint_gt, legacy_gt, 'AbsTol', 0);
        end

        function testSummaryAppliesBothEndpointCriteria(testCase)
            cfg = sarvalid.default_config();
            [frames, sequences] = synthetic_results(cfg);
            [scenes, curves, comparison, decision] = ...
                sarvalid.summarize_hlh_normalization_ablation( ...
                frames, sequences, cfg);
            testCase.verifyEqual(height(scenes), 28);
            testCase.verifyEqual(height(curves), 36);
            testCase.verifyTrue(all(comparison.LeftEdgeJumpReduction >= 0.5));
            testCase.verifyTrue(all(comparison.RightEdgeJumpReduction >= 0.5));
            testCase.verifyTrue(all(comparison.AllPass));
            testCase.verifyTrue(decision.EligibleForIntegration);

            sequences.RightPSNRJump( ...
                sequences.Policy == "joint_hl_shared") = 1.2;
            [~, ~, comparison, decision] = ...
                sarvalid.summarize_hlh_normalization_ablation( ...
                frames, sequences, cfg);
            testCase.verifyTrue(all(~comparison.EdgeJumpPass));
            testCase.verifyFalse(decision.EligibleForIntegration);
        end

        function testDryRunReadsV3Protocol(testCase)
            cfg = sarvalid.default_config();
            output_root = string(tempname);
            cleanup = onCleanup(@() remove_directory(output_root));
            cfg.hlh_normalization_ablation.output_root = output_root;
            cfg.hlh_normalization_ablation.dry_run = true;
            outputs = run_hlh_normalization_ablation(cfg);
            testCase.verifyEqual(outputs.status, "dry_run");
            testCase.verifyEqual(height(outputs.manifest), 35);
            testCase.verifyEqual(numel(unique(outputs.manifest.Scene)), 7);
            testCase.verifyEqual(height(outputs.locked), 2);
            testCase.verifyTrue(isfile(fullfile(output_root, "config.json")));
            clear cleanup;
        end
    end
end

function [frames, sequences] = synthetic_results(cfg)
pairs = cfg.hlh_normalization_ablation.hl_pairs;
policies = cfg.hlh_normalization_ablation.policies;
legacy_psnr = [25, 23, 22, 21, 20, 21, 22, 23, 25].';
joint_psnr = [24, 23.5, 22.5, 21.5, 20.5, 21.5, 22.5, 23.5, 24].';
ssim_curve = [0.85, 0.82, 0.79, 0.76, 0.74, 0.76, 0.79, 0.82, 0.85].';
frames = table();
sequences = table();
sequence_id = 0;
for pair_idx = 1:size(pairs, 1)
    for scene_idx = 1:7
        sequence_id = sequence_id + 1;
        for policy_idx = 1:numel(policies)
            policy = policies(policy_idx);
            if policy == "legacy_split"
                psnr_curve = legacy_psnr;
                jump = 2;
                roughness = 1;
            else
                psnr_curve = joint_psnr;
                jump = 0.5;
                roughness = 0.5;
            end
            frame_count = numel(psnr_curve);
            CaseLabel = repmat("main35", frame_count, 1);
            Policy = repmat(policy, frame_count, 1);
            Scene = repmat("scene" + scene_idx, frame_count, 1);
            QHigh = repmat(pairs(pair_idx, 1), frame_count, 1);
            QLow = repmat(pairs(pair_idx, 2), frame_count, 1);
            FrameIdx = (0:frame_count-1).';
            PSNR = psnr_curve;
            SSIM = ssim_curve;
            frames = append_table(frames, table(CaseLabel, Policy, ...
                Scene, QHigh, QLow, FrameIdx, PSNR, SSIM));

            CaseLabel = "main35";
            Policy = policy;
            SequenceID = sequence_id;
            Scene = "scene" + scene_idx;
            QHigh = pairs(pair_idx, 1);
            QLow = pairs(pair_idx, 2);
            MeanPSNR = mean(psnr_curve);
            MeanSSIM = mean(ssim_curve);
            WorstPSNR = min(psnr_curve);
            WorstSSIM = min(ssim_curve);
            LRegionPSNR = 21;
            LRegionSSIM = 0.75;
            F4PSNR = psnr_curve(5);
            F4SSIM = ssim_curve(5);
            PSNRSmoothness = roughness;
            SSIMSmoothness = 0.01;
            LeftPSNRJump = jump;
            RightPSNRJump = jump;
            GradientRMSE = 0.1;
            BrightScattererError = 0.1;
            OverlapExcessSSIMLoss = 0;
            BoundaryJumpDB = 0;
            PSNRShapeAnomaly = false;
            SSIMShapeAnomaly = false;
            sequences = append_table(sequences, table(CaseLabel, ...
                Policy, SequenceID, Scene, QHigh, QLow, MeanPSNR, ...
                MeanSSIM, WorstPSNR, WorstSSIM, LRegionPSNR, ...
                LRegionSSIM, F4PSNR, F4SSIM, PSNRSmoothness, ...
                SSIMSmoothness, LeftPSNRJump, RightPSNRJump, ...
                GradientRMSE, BrightScattererError, ...
                OverlapExcessSSIMLoss, BoundaryJumpDB, ...
                PSNRShapeAnomaly, SSIMShapeAnomaly));
        end
    end
end
end

function output = append_table(input, rows)
if isempty(input)
    output = rows;
else
    output = [input; rows];
end
end

function remove_directory(path)
if isfolder(path)
    rmdir(path, 's');
end
end
