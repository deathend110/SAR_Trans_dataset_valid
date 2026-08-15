classdef TestGeneratorComparison < matlab.unittest.TestCase
    % Range+2D-SFT与BARU+RT补充实验的轻量验收测试。

    methods (TestClassSetup)
        function addRepositoryToPath(testCase)
            tests_dir = fileparts(mfilename("fullpath"));
            repo_root = fileparts(tests_dir);
            addpath(repo_root);
            testCase.addTeardown(@() rmpath(repo_root));
        end
    end

    methods (Test)
        function range2DSFTOpensAzimuthFrequency(testCase)
            signal = complex(ones(8, 10), ones(8, 10));
            grid = struct("Fs_up", 20, "PRF_up", 8);
            threshold = struct("STR_dB", 0, "fr_over_Br", 0.5, ...
                "fa_over_Ba", 0.5, "phi0", 0);
            S60 = struct("B", 4, "Bd", 2);
            acq = struct("method", "Range_2D_SFT", "q_total", 2, ...
                "threshold", threshold, "time_origin", "block_global");
            [U, meta] = sarvalid.build_threshold(signal, grid, acq, S60);
            testCase.verifyEqual(meta.fa_Hz, 1);
            testCase.verifyNotEqual(U(1, 1), U(1, 2));
            testCase.verifyNotEqual(U(1, 1), U(2, 1));
        end

        function legacyRangeSFTKeepsZeroAzimuthFrequency(testCase)
            signal = complex(ones(8, 10), ones(8, 10));
            grid = struct("Fs_up", 20, "PRF_up", 8);
            threshold = struct("STR_dB", 0, "fr_over_Br", 0, ...
                "fa_over_Ba", 0.5, "phi0", 0);
            S60 = struct("B", 4, "Bd", 2);
            acq = struct("method", "Range_SFT", "q_total", 2, ...
                "threshold", threshold, "time_origin", "block_global");
            [U, meta] = sarvalid.build_threshold(signal, grid, acq, S60);
            testCase.verifyEqual(meta.fa_Hz, 0);
            testCase.verifyEqual(U(:, 1), U(:, end), 'AbsTol', 0);
        end

        function fractionalRatesUseRoundedDimensions(testCase)
            S60 = struct("Fs", 60e6, "prf", 240);
            range_acq = struct("method", "Range_2D_SFT", ...
                "q_total", 2.5, "alpha", 1);
            range_grid = sarvalid.resolve_acquisition( ...
                range_acq, [1200, 1200], S60);
            testCase.verifyEqual(range_grid.upsampled_size, [3000, 1200]);
            testCase.verifyEqual(range_grid.q_total_eff, 2.5, 'AbsTol', 0);

            baru_acq = struct("method", "BARU_RT", ...
                "q_total", 1.5, "alpha", 0.35);
            baru_grid = sarvalid.resolve_acquisition( ...
                baru_acq, [1200, 1200], S60);
            testCase.verifyEqual(baru_grid.upsampled_size, ...
                round([1.5^0.35, 1.5^0.65] * 1200));
            testCase.verifyLessThan(abs(baru_grid.q_total_eff - 1.5), 1e-3);
        end

        function randomThresholdSeedsAreReproducibleAndDistinct(testCase)
            signal = complex(ones(12, 14), ones(12, 14));
            grid = struct("Fs_up", 60, "PRF_up", 240);
            S60 = struct("B", 20, "Bd", 30);
            threshold = struct("As", 0.6);
            acq = struct("method", "BARU_RT", "q_total", 2, ...
                "seed", 42, "threshold", threshold);
            U1 = sarvalid.build_threshold(signal, grid, acq, S60);
            U2 = sarvalid.build_threshold(signal, grid, acq, S60);
            acq.seed = 1000045;
            U3 = sarvalid.build_threshold(signal, grid, acq, S60);
            testCase.verifyEqual(U1, U2, 'AbsTol', 0);
            testCase.verifyNotEqual(U1, U3);
        end

        function baruCandidateKeysIncludeAlphaAndAmplitude(testCase)
            cfg = sarvalid.default_config();
            threshold = struct("As", 0.4, "STR_dB", NaN, ...
                "fr_over_Br", 0, "fa_over_Ba", 0, "phi0", 0);
            first = sarvalid.make_pair_config( ...
                cfg, "BARU_RT", 4, 2, 0.35, threshold);
            threshold.As = 0.5;
            second = sarvalid.make_pair_config( ...
                cfg, "BARU_RT", 4, 2, 0.35, threshold);
            third = sarvalid.make_pair_config( ...
                cfg, "BARU_RT", 4, 2, 0.50, threshold);
            keys = [sarvalid.generator_file_key(first); ...
                sarvalid.generator_file_key(second); ...
                sarvalid.generator_file_key(third)];
            testCase.verifyEqual(numel(unique(keys)), 3);
            seeded_key = sarvalid.generator_file_key(first, ...
                cfg.generator_compare.rt_seed_families);
            testCase.verifyTrue(contains(seeded_key, "sf42_1000045"));
        end

        function pairsShareThresholdParametersAndAlpha(testCase)
            cfg = sarvalid.default_config();
            threshold = struct("As", 0.7, "STR_dB", -2, ...
                "fr_over_Br", 0.8, "fa_over_Ba", 0.4, "phi0", 0);
            sft = sarvalid.make_pair_config( ...
                cfg, "Range_2D_SFT", 4, 2, 1, threshold);
            baru = sarvalid.make_pair_config( ...
                cfg, "BARU_RT", 4, 2, 0.35, threshold);
            testCase.verifyEqual(sft.H.threshold, sft.L.threshold);
            testCase.verifyEqual(baru.H.alpha, baru.L.alpha);
            testCase.verifyEqual(baru.H.threshold.As, baru.L.threshold.As);
        end

        function difficultyMatchingCoversAllBranches(testCase)
            target = candidate_table("baru", 0.7, 0.05, 0.6, 0.8, 25);
            initial = candidate_table("initial", 0.702, 0.058, 0.7, 0.82, 26);
            expanded = candidate_table("expanded", 0.708, 0.065, 0.7, 0.82, 26);
            failed = candidate_table("failed", 0.73, 0.09, 0.7, 0.82, 26);
            cfg = sarvalid.default_config();
            tolerance = cfg.generator_compare.difficulty_tolerance;
            [~, audit_initial] = sarvalid.select_generator_match( ...
                initial, target, tolerance);
            [~, audit_expanded] = sarvalid.select_generator_match( ...
                expanded, target, tolerance);
            [~, audit_failed] = sarvalid.select_generator_match( ...
                failed, target, tolerance);
            testCase.verifyEqual(audit_initial.Status, "matched");
            testCase.verifyEqual(audit_expanded.Status, "matched_expanded");
            testCase.verifyEqual(audit_failed.Status, "failed_closest");
            testCase.verifyFalse(audit_failed.DifficultyMatched);
        end

        function seedAggregationPreservesSequenceCount(testCase)
            SequenceID = repelem((1:2).', 5);
            Scene = repelem(["A"; "B"], 5);
            Method = repmat("BARU_RT", 10, 1);
            PairKey = repmat("pair", 10, 1);
            SeedFamily = repmat((1:5).', 2, 1);
            MeanSSIM = (1:10).' / 10;
            input = table(SequenceID, Scene, Method, PairKey, ...
                SeedFamily, MeanSSIM);
            output = sarvalid.aggregate_seed_replicates(input, ...
                ["SequenceID", "Scene", "Method", "PairKey"]);
            testCase.verifyEqual(height(output), 2);
            testCase.verifyEqual(output.SeedCount, [5; 5]);
        end

        function comparisonAggregatesSeedsBeforeSceneStatistics(testCase)
            [stage_a, stage_b] = synthetic_comparison_inputs();
            cfg = sarvalid.default_config();
            cfg.generator_compare.bootstrap_repetitions = 100;
            [comparison, report] = sarvalid.compare_generators( ...
                stage_a, stage_b, cfg);
            testCase.verifyEqual(height(comparison), 2);
            testCase.verifyEqual(comparison.StageASceneCount, [7; 7]);
            testCase.verifyEqual(comparison.StageBSceneCount, [7; 7]);
            testCase.verifyTrue(all(comparison.RangeSelectedForPair));
            testCase.verifyEqual(report.Outcome(end), "select_range_2d_sft");
        end

        function dryRunWritesOnlyManifestsAndConfig(testCase)
            cfg = sarvalid.default_config();
            output_root = string(tempname);
            testCase.addTeardown(@() remove_folder(output_root));
            cfg.generator_compare.output_root = output_root;
            cfg.runtime.dry_run = true;
            outputs = run_generator_threshold_comparison(cfg);
            testCase.verifyEqual(sum(outputs.stage_a_manifest.Split == ...
                "development"), 14);
            testCase.verifyEqual(sum(outputs.stage_a_manifest.Split == ...
                "verification"), 70);
            testCase.verifyEqual(sum(outputs.stage_b_manifest.Split == ...
                "calibration"), 7);
            testCase.verifyEqual(sum(outputs.stage_b_manifest.Split == ...
                "evaluation"), 14);
            testCase.verifyFalse(isfile(fullfile(output_root, ...
                "generator_comparison_final.mat")));
        end
    end
end

function [stage_a, stage_b] = synthetic_comparison_inputs()
pairs = [4, 2; 2.5, 1.5];
scenes_a = repelem("S" + string((1:7).'), 10);
scenes_b = repelem("S" + string((1:7).'), 2);
sample_rows = table();
verification_seed_rows = table();
sequence_rows = table();
sequence_seed_rows = table();
audit_rows = table();
for pair_idx = 1:2
    q_high = pairs(pair_idx, 1);
    q_low = pairs(pair_idx, 2);
    for method = ["Range_2D_SFT", "BARU_RT"]
        is_range = method == "Range_2D_SFT";
        SampleID = (1:70).';
        Scene = scenes_a;
        Method = repmat(method, 70, 1);
        QHigh = repmat(q_high, 70, 1);
        QLow = repmat(q_low, 70, 1);
        HSSIM = repmat(0.81 + 0.01 * is_range, 70, 1);
        LSSIM = repmat(0.76 + 0.01 * is_range, 70, 1);
        HGradientRMSE = repmat(0.08 - 0.01 * is_range, 70, 1);
        LGradientRMSE = HGradientRMSE;
        HBrightScattererError = repmat(0.06 - 0.01 * is_range, 70, 1);
        LBrightScattererError = HBrightScattererError;
        sample_rows = [sample_rows; table(Method, QHigh, QLow, ...
            SampleID, Scene, HSSIM, LSSIM, HGradientRMSE, ...
            LGradientRMSE, HBrightScattererError, ...
            LBrightScattererError)]; %#ok<AGROW>

        SequenceID = (1:14).';
        Scene = scenes_b;
        Method = repmat(method, 14, 1);
        QHigh = repmat(q_high, 14, 1);
        QLow = repmat(q_low, 14, 1);
        MeanSSIM = repmat(0.78 + 0.01 * is_range, 14, 1);
        WorstSSIM = repmat(0.70 + 0.01 * is_range, 14, 1);
        GradientRMSE = repmat(0.08 - 0.01 * is_range, 14, 1);
        BrightScattererError = repmat(0.06 - 0.01 * is_range, 14, 1);
        OverlapExcessSSIMLoss = repmat(0.001, 14, 1);
        BoundaryJumpDB = repmat(0.01, 14, 1);
        sequence_rows = [sequence_rows; table(Method, QHigh, QLow, ...
            SequenceID, Scene, MeanSSIM, WorstSSIM, GradientRMSE, ...
            BrightScattererError, OverlapExcessSSIMLoss, ...
            BoundaryJumpDB)]; %#ok<AGROW>
    end

    for seed = 42 + (0:4) * 1000003
        Method = repmat("BARU_RT", 70, 1);
        QHigh = repmat(q_high, 70, 1);
        QLow = repmat(q_low, 70, 1);
        SeedFamily = repmat(seed, 70, 1);
        HSSIM = repmat(0.81, 70, 1);
        LSSIM = repmat(0.76, 70, 1);
        verification_seed_rows = [verification_seed_rows; ...
            table(Method, QHigh, QLow, SeedFamily, HSSIM, LSSIM)]; %#ok<AGROW>

        Method = repmat("BARU_RT", 14, 1);
        QHigh = repmat(q_high, 14, 1);
        QLow = repmat(q_low, 14, 1);
        SeedFamily = repmat(seed, 14, 1);
        MeanSSIM = repmat(0.78, 14, 1);
        sequence_seed_rows = [sequence_seed_rows; ...
            table(Method, QHigh, QLow, SeedFamily, MeanSSIM)]; %#ok<AGROW>
    end
    QHigh = q_high;
    QLow = q_low;
    Status = "matched";
    DifficultyMatched = true;
    audit_rows = [audit_rows; ...
        table(QHigh, QLow, Status, DifficultyMatched)]; %#ok<AGROW>
end
stage_a = struct("verification_sample_detail", sample_rows, ...
    "verification_seed_detail", verification_seed_rows, ...
    "difficulty_matching", audit_rows);
stage_b = struct("sequence_summary", sequence_rows, ...
    "seed_detail", sequence_seed_rows);
end

function output = candidate_table(key, l_ssim, delta_ssim, ...
        worst_ssim, pair_ssim, pair_psnr)
PairKey = string(key);
L_SSIM_Mean = l_ssim;
Delta_SSIM_Mean = delta_ssim;
Worst_SSIM = worst_ssim;
Pair_SSIM_Mean = pair_ssim;
Pair_PSNR_Mean = pair_psnr;
output = table(PairKey, L_SSIM_Mean, Delta_SSIM_Mean, ...
    Worst_SSIM, Pair_SSIM_Mean, Pair_PSNR_Mean);
end

function remove_folder(path_value)
if isfolder(path_value)
    rmdir(path_value, 's');
end
end
