classdef TestRangeSFTV3 < matlab.unittest.TestCase
    methods (TestClassSetup)
        function addRepositoryToPath(testCase)
            tests_dir = fileparts(mfilename("fullpath"));
            repo_root = fileparts(tests_dir);
            addpath(repo_root);
            testCase.addTeardown(@() rmpath(repo_root));
        end
    end

    methods (Test)
        function testDefaultGridAndCandidateCounts(testCase)
            cfg = sarvalid.default_config();
            S60 = load(cfg.parameter_file_60);
            [grid_42, limits_42] = sarvalid.range_sft_v3_grid( ...
                cfg, S60, 4, 2);
            [grid_2515, limits_2515] = sarvalid.range_sft_v3_grid( ...
                cfg, S60, 2.5, 1.5);
            [grid_325175, limits_325175] = sarvalid.range_sft_v3_grid( ...
                cfg, S60, 3.25, 1.75);
            testCase.verifyEqual(height(grid_42), 231);
            testCase.verifyEqual(height(grid_2515), 165);
            testCase.verifyEqual(height(grid_325175), 198);
            testCase.verifyEqual(limits_42.fr_over_Br, 1.30666666666667, ...
                'AbsTol', 1e-12);
            testCase.verifyEqual(limits_2515.fr_over_Br, 0.98, ...
                'AbsTol', 1e-12);
            testCase.verifyEqual(limits_325175.fr_over_Br, ...
                1.14333333333333, 'AbsTol', 1e-12);
            testCase.verifyEqual(limits_325175.fa_over_Ba, 0.588, ...
                'AbsTol', 1e-12);
            testCase.verifyEqual(limits_325175.H.upsampled_size, ...
                [3900, 2224]);
            testCase.verifyEqual(limits_325175.L.upsampled_size, ...
                [2100, 2224]);
            testCase.verifyTrue(any(contains(grid_325175.PairKey, ...
                "qh3p25_ql1p75")));
            testCase.verifyEqual(limits_42.fa_over_Ba, 0.588, ...
                'AbsTol', 1e-12);
            testCase.verifyTrue(all(grid_42.FrOverBr < grid_42.FrLimit));
            testCase.verifyTrue(all(grid_42.FaOverBa < grid_42.FaLimit));
        end

        function testFineGridCoversLegalNeighborhood(testCase)
            cfg = sarvalid.default_config();
            S60 = load(cfg.parameter_file_60);
            anchor = table("anchor", 4, 2, 0, 1.2, 0.4, ...
                'VariableNames', ["PairKey", "QHigh", "QLow", ...
                "STRdB", "FrOverBr", "FaOverBa"]);
            fine = sarvalid.range_sft_v3_grid(cfg, S60, 4, 2, anchor);
            testCase.verifyTrue(any(abs(fine.FrOverBr - 1.3) < 1e-12));
            testCase.verifyTrue(any(abs(fine.FaOverBa - 0.5) < 1e-12));
            testCase.verifyTrue(all(fine.FrOverBr >= 0 & ...
                fine.FrOverBr < fine.FrLimit));
            testCase.verifyTrue(all(fine.FaOverBa >= 0 & ...
                fine.FaOverBa < fine.FaLimit));
        end

        function testNormalizationUsesHOnlyForPureHFrames(testCase)
            mixed = zeros(6, 6, 3, 'single');
            mixed(:, :, 1) = 5;
            mixed(:, :, 2) = 5;
            mixed(:, :, 3) = 5;
            gt = zeros(size(mixed), 'single');
            gt_stats = struct("VMin", 0, "VMax", 1);
            h_stats = struct("VMin", 0, "VMax", 10);
            l_stats = struct("VMin", 0, "VMax", 100);
            [input, target] = sarvalid.normalize_range_sft_v3_sequence( ...
                mixed, gt, [1, 0.5, 1], gt_stats, h_stats, l_stats, 4);
            testCase.verifySize(input, [4, 4, 3]);
            testCase.verifyEqual(input(:, :, 1), ...
                single(0.5 * ones(4)), 'AbsTol', 1e-7);
            testCase.verifyEqual(input(:, :, 2), ...
                single(0.05 * ones(4)), 'AbsTol', 1e-7);
            testCase.verifyEqual(input(:, :, 3), ...
                single(0.5 * ones(4)), 'AbsTol', 1e-7);
            testCase.verifyEqual(target, zeros(4, 4, 3, 'single'));
        end

        function testRankingUsesPreregisteredTieBreakers(testCase)
            Stage = repmat("coarse", 3, 1);
            PairKey = ["b"; "a"; "c"];
            QHigh = repmat(4, 3, 1);
            QLow = repmat(2, 3, 1);
            STRdB = zeros(3, 1);
            FrOverBr = zeros(3, 1);
            FaOverBa = zeros(3, 1);
            Scene = repmat("scene", 3, 1);
            MeanPSNR = [20; 19; 30];
            MeanSSIM = [0.8; 0.8; 0.79];
            WorstSSIM = [0.7; 0.7; 0.9];
            LRegionSSIM = [0.75; 0.76; 0.9];
            rows = table(Stage, PairKey, QHigh, QLow, STRdB, ...
                FrOverBr, FaOverBa, Scene, MeanPSNR, MeanSSIM, ...
                WorstSSIM, LRegionSSIM);
            ranked = sarvalid.rank_range_sft_v3_candidates(rows);
            testCase.verifyEqual(ranked.PairKey, ["a"; "b"; "c"]);
            testCase.verifyEqual(ranked.Rank, (1:3).');
        end

        function testDryRunUsesAllV2SequencesAsSearchData(testCase)
            cfg = sarvalid.default_config();
            output_root = string(tempname);
            cleanup = onCleanup(@() remove_directory(output_root));
            cfg.range_2dsft_v3.output_root = output_root;
            cfg.range_2dsft_v3.dry_run = true;
            outputs = run_range_2dsft_search_v3(cfg);
            testCase.verifyEqual(height(outputs.manifest), 35);
            testCase.verifyEqual(numel(unique(outputs.manifest.Scene)), 7);
            testCase.verifyTrue(all(outputs.manifest.SearchRole == "search"));
            testCase.verifyEqual(height(outputs.coarse_candidates), 594);
            testCase.verifyTrue(isfile(fullfile( ...
                output_root, "preregistration.json")));
            testCase.verifyTrue(isfile(fullfile( ...
                output_root, "manifests", "sequence.csv")));
            clear cleanup;
        end

        function testIncrementalMergePreservesBaselinePairRows(testCase)
            base = synthetic_v3_stage_result([4, 2; 2.5, 1.5]);
            addition = synthetic_v3_stage_result([3.25, 1.75]);
            merged = sarvalid.merge_range_sft_v3_results(base, addition);

            testCase.verifyEqual(height(merged.scene_metrics), 3);
            testCase.verifyEqual(sum(merged.scene_metrics.QHigh == 4 & ...
                merged.scene_metrics.QLow == 2), 1);
            testCase.verifyEqual(sum(merged.scene_metrics.QHigh == 2.5 & ...
                merged.scene_metrics.QLow == 1.5), 1);
            testCase.verifyEqual(sum(merged.scene_metrics.QHigh == 3.25 & ...
                merged.scene_metrics.QLow == 1.75), 1);
            testCase.verifyEqual(height(merged.candidate_summary), 3);
        end
    end
end

function remove_directory(path)
if isfolder(path)
    rmdir(path, 's');
end
end

function result = synthetic_v3_stage_result(pairs)
count = size(pairs, 1);
Stage = repmat("coarse", count, 1);
PairKey = "pair" + string((1:count).');
QHigh = pairs(:, 1);
QLow = pairs(:, 2);
STRdB = zeros(count, 1);
FrOverBr = zeros(count, 1);
FaOverBa = zeros(count, 1);
Scene = repmat("scene", count, 1);
MeanPSNR = (20:20 + count - 1).';
MeanSSIM = (0.70:0.01:0.70 + 0.01 * (count - 1)).';
WorstSSIM = MeanSSIM - 0.05;
LRegionSSIM = MeanSSIM - 0.02;
scene_metrics = table(Stage, PairKey, QHigh, QLow, STRdB, FrOverBr, ...
    FaOverBa, Scene, MeanPSNR, MeanSSIM, WorstSSIM, LRegionSSIM);
normalization_stats = table(Scene, PairKey, QHigh, QLow);
result = struct("scene_metrics", scene_metrics, ...
    "normalization_stats", normalization_stats);
end
