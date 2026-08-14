classdef TestStageAConfiguration < matlab.unittest.TestCase
    % Stage A配置、清单和候选锁定规则测试。

    methods (TestClassSetup)
        function addRepositoryToPath(testCase)
            tests_dir = fileparts(mfilename("fullpath"));
            repo_root = fileparts(tests_dir);
            addpath(repo_root);
            testCase.addTeardown(@() rmpath(repo_root));
        end
    end

    methods (Test)
        function manifestHasDisjointDevelopmentAndVerification(testCase)
            cfg = sarvalid.default_config();
            S60 = load(cfg.parameter_file_60);
            manifest = sarvalid.build_stage_a_manifest(cfg, S60);
            testCase.verifyEqual(height(manifest), 84);
            testCase.verifyEqual(sum(manifest.Split == "development"), 14);
            testCase.verifyEqual(sum(manifest.Split == "verification"), 70);
            for scene = cfg.dataset_names
                dev_files = unique(manifest.File( ...
                    manifest.Scene == scene & manifest.Split == "development"));
                verify_files = unique(manifest.File( ...
                    manifest.Scene == scene & manifest.Split == "verification"));
                testCase.verifyEmpty(intersect(dev_files, verify_files));
            end
        end

        function sftGridRespectsLowBranchNyquist(testCase)
            cfg = sarvalid.default_config();
            S60 = load(cfg.parameter_file_60);
            candidates = sarvalid.sft_candidate_grid( ...
                cfg, "BARU_SFT", 2.5, 1.5, 0.5, S60);
            testCase.verifyTrue(all(candidates.FrOverBr < candidates.FrLimit));
            testCase.verifyTrue(all(candidates.FaOverBa < candidates.FaLimit));
            testCase.verifyTrue(all(candidates.STRdB >= -8 & candidates.STRdB <= 8));
        end

        function candidateSelectionUsesRegisteredOrdering(testCase)
            Pair_SSIM_Mean = [0.8; 0.8; 0.79];
            Pair_PSNR_Mean = [25; 26; 30];
            STRdB = [-2; -4; 0];
            FrOverBr = [1; 1; 0];
            FaOverBa = [0; 0; 0];
            ID = [1; 2; 3];
            candidates = table(ID, Pair_SSIM_Mean, Pair_PSNR_Mean, ...
                STRdB, FrOverBr, FaOverBa);
            best = sarvalid.select_best_candidate(candidates);
            testCase.verifyEqual(best.ID, 2);
        end

        function pairSharesAlphaAndSFTParameters(testCase)
            cfg = sarvalid.default_config();
            threshold = struct("As", 0.6, "STR_dB", -2, ...
                "fr_over_Br", 0.8, "fa_over_Ba", 0.4, "phi0", 0);
            pair = sarvalid.make_pair_config( ...
                cfg, "BARU_SFT", 3, 1.5, 0.35, threshold);
            testCase.verifyEqual(pair.H.alpha, pair.L.alpha);
            testCase.verifyEqual(pair.H.threshold, pair.L.threshold);
            testCase.verifyEqual(pair.H.seed, pair.L.seed);
        end
    end
end
