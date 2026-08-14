classdef TestStageBConfiguration < matlab.unittest.TestCase
    % Stage B清单、序列指标和Pareto规则测试。

    methods (TestClassSetup)
        function addRepositoryToPath(testCase)
            tests_dir = fileparts(mfilename("fullpath"));
            repo_root = fileparts(tests_dir);
            addpath(repo_root);
            testCase.addTeardown(@() rmpath(repo_root));
        end
    end

    methods (Test)
        function manifestHasSevenCalibrationAndFourteenEvaluation(testCase)
            cfg = sarvalid.default_config();
            S60 = load(cfg.parameter_file_60);
            stage_a = sarvalid.build_stage_a_manifest(cfg, S60);
            stage_b = sarvalid.build_stage_b_manifest(cfg);
            testCase.verifyEqual(height(stage_b), 21);
            testCase.verifyEqual(sum(stage_b.Split == "calibration"), 7);
            testCase.verifyEqual(sum(stage_b.Split == "evaluation"), 14);
            for scene = cfg.dataset_names
                files_a = unique(stage_a.File(stage_a.Scene == scene));
                files_b = unique(stage_b.File(stage_b.Scene == scene));
                testCase.verifyEmpty(intersect(files_a, files_b));
            end
        end

        function overlapUsesKnown128PixelShift(testCase)
            base = repmat(single(1:1536), 8, 1);
            sequence = zeros(8, 512, 9, 'single');
            for idx = 1:9
                start_idx = 1 + (idx-1)*128;
                sequence(:, :, idx) = base(:, start_idx:start_idx+511);
            end
            normalized = sequence / max(sequence(:));
            [~, summary, overlap] = sarvalid.sequence_metrics(normalized, normalized);
            testCase.verifyEqual(overlap.InputRMSE, zeros(8, 1), 'AbsTol', 0);
            testCase.verifyEqual(summary.overlap_excess_rmse, 0, 'AbsTol', 0);
        end

        function paretoRankingFindsDominatedConfiguration(testCase)
            Method = ["A"; "A"; "B"];
            PairKey = ["x"; "y"; "z"];
            MeanPSNR = [30; 29; 31];
            MeanSSIM = [0.9; 0.8; 0.91];
            WorstPSNR = [25; 24; 26];
            WorstSSIM = [0.8; 0.7; 0.81];
            OverlapExcessRMSE = [0.1; 0.2; 0.09];
            OverlapExcessSSIMLoss = [0.01; 0.02; 0.009];
            BoundaryGradientExcess = [0.01; 0.02; 0.01];
            BoundaryJumpDB = [0.1; 0.2; 0.09];
            OffSupportRatio = [0.2; 0.3; 0.19];
            RangeLeakageRatio = [0.1; 0.2; 0.09];
            AzimuthLeakageRatio = [0.1; 0.2; 0.09];
            input = table(Method, PairKey, MeanPSNR, MeanSSIM, WorstPSNR, ...
                WorstSSIM, OverlapExcessRMSE, BoundaryGradientExcess, ...
                OffSupportRatio, OverlapExcessSSIMLoss, BoundaryJumpDB, ...
                RangeLeakageRatio, AzimuthLeakageRatio);
            ranked = sarvalid.pareto_rank(input);
            rank_y = ranked.ParetoRank(ranked.PairKey == "y");
            testCase.verifyGreaterThan(rank_y, 1);
        end

        function boundaryMetricIsZeroWhenInputEqualsGT(testCase)
            cfg = sarvalid.default_config();
            mask = sarvalid.build_hlh_mask(cfg.sequence);
            image = rand(16, 512, 9, 'single');
            metrics = sarvalid.boundary_gradient_excess(image, image, mask.frames);
            testCase.verifyEqual(metrics.mean_excess, 0, 'AbsTol', 0);
            testCase.verifyEqual(metrics.mean_ratio, 1, 'AbsTol', 1e-12);
        end
    end
end
