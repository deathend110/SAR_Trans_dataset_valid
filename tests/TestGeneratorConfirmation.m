classdef TestGeneratorConfirmation < matlab.unittest.TestCase
    methods (TestClassSetup)
        function addRepositoryToPath(testCase)
            tests_dir = fileparts(mfilename("fullpath"));
            repo_root = fileparts(tests_dir);
            addpath(repo_root);
            testCase.addTeardown(@() rmpath(repo_root));
        end
    end

    methods (Test)
        function testDefaultConfiguration(testCase)
            cfg = sarvalid.default_config();
            gc = cfg.generator_confirmation;
            testCase.verifyEqual(gc.hl_pairs, [4, 2; 2.5, 1.5]);
            testCase.verifyEqual(gc.baru_coarse_alpha, ...
                [0.35, 0.50, 0.65, 0.80]);
            testCase.verifyEqual(gc.baru_coarse_As, [0.20, 0.30, 0.40]);
            testCase.verifyEqual(gc.strict_difficulty_tolerance.l_ssim, 0.005);
            testCase.verifyEqual(gc.strict_difficulty_tolerance.delta_ssim, 0.01);
            testCase.verifyEqual(gc.nonzero_fa_min, 0.1);
        end

        function testDryRunBuildsIndependentManifests(testCase)
            cfg = sarvalid.default_config();
            output_root = string(tempname);
            cleanup = onCleanup(@() remove_directory(output_root));
            cfg.generator_confirmation.output_root = output_root;
            cfg.generator_confirmation.dry_run = true;
            outputs = run_generator_confirmation_v2(cfg);
            manifests = outputs.manifests;
            testCase.verifyEqual(height(manifests.development), 14);
            testCase.verifyEqual(height(manifests.bridge_verification), 70);
            testCase.verifyEqual(height(manifests.confirmation), 140);
            testCase.verifyEqual(sum(manifests.sequence.Split == "calibration"), 7);
            testCase.verifyEqual(sum(manifests.sequence.Split == "evaluation"), 28);
            testCase.verifyTrue(all(manifests.audit.OldNewDisjoint));
            testCase.verifyTrue(all(manifests.audit.StageABDisjoint));
            testCase.verifyEqual(min(manifests.confirmation.SampleID), 100001);
            testCase.verifyEqual(min(manifests.sequence.SequenceID), 200001);
            testCase.verifyTrue(isfile(fullfile(output_root, ...
                "preregistration.json")));
            clear cleanup;
        end

        function testStrictDifficultyMatchHasNoExpansion(testCase)
            candidates = candidate_fixture([0.700, 0.706], [0.050, 0.056]);
            target = candidate_fixture(0.704, 0.054);
            tolerance = struct("l_ssim", 0.005, "delta_ssim", 0.01);
            [selected, audit] = sarvalid.select_generator_match_strict( ...
                candidates, target, tolerance);
            testCase.verifyTrue(audit.DifficultyMatched);
            testCase.verifyEqual(audit.Status, "matched_strict");
            testCase.verifyLessThanOrEqual( ...
                abs(selected.L_SSIM_Mean - target.L_SSIM_Mean), 0.005);

            far = candidate_fixture(0.680, 0.090);
            [~, failed] = sarvalid.select_generator_match_strict( ...
                far, target, tolerance);
            testCase.verifyFalse(failed.DifficultyMatched);
            testCase.verifyEqual(failed.Status, "failed_closest");
        end

        function testBoundaryGainStopsSearch(testCase)
            cfg = sarvalid.default_config();
            gc = cfg.generator_confirmation;
            candidates = table( ...
                [0.20; 0.30; 0.40], [0.10; 0.20; 0.30], ...
                [0.82; 0.80; 0.79], ["edge"; "inner1"; "inner2"], ...
                'VariableNames', ["Alpha", "As", ...
                "Pair_SSIM_Mean", "PairKey"]);
            best = candidates(1, :);
            audit = sarvalid.audit_baru_boundary(best, candidates, gc, 4, 2);
            testCase.verifyFalse(audit.SearchClosed);
            testCase.verifyEqual(audit.Status, "BARU_search_not_closed");

            candidates.Pair_SSIM_Mean(1) = 0.8005;
            best = candidates(1, :);
            audit = sarvalid.audit_baru_boundary(best, candidates, gc, 4, 2);
            testCase.verifyTrue(audit.SearchClosed);
        end

        function testNonzeroFaMethodKeepsAzimuthFrequency(testCase)
            cfg = sarvalid.default_config();
            S60 = load(cfg.parameter_file_60);
            threshold = struct("As", 0.6, "STR_dB", 0, ...
                "fr_over_Br", 0.4, "fa_over_Ba", 0.1, "phi0", 0);
            pair = sarvalid.make_pair_config(cfg, ...
                "Range_NonzeroFa_SFT", 2.5, 1.5, 1, threshold);
            grid = sarvalid.resolve_acquisition(pair.H, [32, 32], S60);
            signal = complex(ones(grid.upsampled_size, 'single'));
            [~, meta] = sarvalid.build_threshold(signal, grid, pair.H, S60);
            testCase.verifyEqual(meta.fa_over_Ba, 0.1, 'AbsTol', 1e-12);
            testCase.verifyNotEqual(meta.fa_Hz, 0);
        end

        function testHashIsStable(testCase)
            first = sarvalid.sha256_text("generator_confirmation_v2");
            second = sarvalid.sha256_text("generator_confirmation_v2");
            testCase.verifyEqual(first, second);
            testCase.verifyEqual(strlength(first), 64);
        end

        function testOppositePairResultsDoNotFreezeMixedPolicy(testCase)
            [c1, c2, stage_a, stage_b, cfg] = confirmation_fixture();
            [~, report] = sarvalid.compare_generator_confirmation( ...
                c1, c2, stage_a, stage_b, cfg);
            testCase.verifyEqual(report.Outcome(end), ...
                "freeze_range_sft_open2d");

            mask = stage_b.sequence_summary.QHigh == 2.5 & ...
                stage_b.sequence_summary.Method == "Range_2D_SFT";
            stage_b.sequence_summary.MeanSSIM(mask) = 0.60;
            stage_b.sequence_summary.WorstSSIM(mask) = 0.58;
            [comparison, report] = sarvalid.compare_generator_confirmation( ...
                c1, c2, stage_a, stage_b, cfg);
            testCase.verifyTrue(comparison.RangeSelectedForPair(1));
            testCase.verifyFalse(comparison.RangeSelectedForPair(2));
            testCase.verifyEqual(report.Outcome(end), ...
                "rate_dependent_no_automatic_freeze");
            testCase.verifyFalse(report.RangeSelected(end));
        end
    end
end

function rows = candidate_fixture(l_ssim, delta_ssim)
count = numel(l_ssim);
Method = repmat("Range_2D_SFT", count, 1);
PairKey = "candidate_" + string((1:count).');
L_SSIM_Mean = l_ssim(:);
Delta_SSIM_Mean = delta_ssim(:);
Worst_SSIM = 0.5 + zeros(count, 1);
Pair_SSIM_Mean = 0.7 + zeros(count, 1);
Pair_PSNR_Mean = 20 + zeros(count, 1);
rows = table(Method, PairKey, L_SSIM_Mean, Delta_SSIM_Mean, ...
    Worst_SSIM, Pair_SSIM_Mean, Pair_PSNR_Mean);
end

function [c1, c2, stage_a, stage_b, cfg] = confirmation_fixture()
cfg = sarvalid.default_config();
cfg.generator_confirmation.bootstrap_repetitions = 100;
pair_values = [4, 2; 2.5, 1.5];
scene_names = "scene" + string((1:7).');

sample_detail = table();
seed_detail = table();
sequence_summary = table();
sequence_seed_detail = table();
for pair_idx = 1:2
    q_high = pair_values(pair_idx, 1);
    q_low = pair_values(pair_idx, 2);
    sample_ids = (1:140).';
    scenes = repelem(scene_names, 20);
    for method = ["Range_2D_SFT", "BARU_RT"]
        advantage = 0.02 * (method == "Range_2D_SFT");
        count = numel(sample_ids);
        rows = table( ...
            repmat(q_high, count, 1), repmat(q_low, count, 1), ...
            repmat(method, count, 1), sample_ids, scenes, ...
            repmat(0.72 + advantage, count, 1), ...
            repmat(0.68 + advantage, count, 1), ...
            repmat(0.05 - 0.005 * (method == "Range_2D_SFT"), count, 1), ...
            repmat(0.06 - 0.005 * (method == "Range_2D_SFT"), count, 1), ...
            repmat(0.12 - 0.01 * (method == "Range_2D_SFT"), count, 1), ...
            repmat(0.13 - 0.01 * (method == "Range_2D_SFT"), count, 1), ...
            'VariableNames', ["QHigh", "QLow", "Method", "SampleID", ...
            "Scene", "HSSIM", "LSSIM", "HGradientRMSE", ...
            "LGradientRMSE", "HBrightScattererError", ...
            "LBrightScattererError"]);
        sample_detail = append_table(sample_detail, rows);
    end
    for seed_idx = 1:5
        seed = cfg.generator_confirmation.rt_seed_families(seed_idx);
        offset = (seed_idx - 3) * 0.0001;
        count = numel(sample_ids);
        rows = table( ...
            repmat(q_high, count, 1), repmat(q_low, count, 1), ...
            repmat("BARU_RT", count, 1), repmat(seed, count, 1), ...
            repmat(0.72 + offset, count, 1), ...
            repmat(0.68 + offset, count, 1), ...
            'VariableNames', ["QHigh", "QLow", "Method", ...
            "SeedFamily", "HSSIM", "LSSIM"]);
        seed_detail = append_table(seed_detail, rows);
    end

    sequence_ids = (1:28).';
    sequence_scenes = repelem(scene_names, 4);
    for method = ["Range_2D_SFT", "BARU_RT"]
        advantage = 0.04 * (method == "Range_2D_SFT");
        count = numel(sequence_ids);
        rows = table( ...
            repmat(q_high, count, 1), repmat(q_low, count, 1), ...
            repmat(method, count, 1), sequence_ids, sequence_scenes, ...
            repmat(0.67 + advantage, count, 1), ...
            repmat(0.64 + advantage, count, 1), ...
            repmat(0.06 - 0.005 * (method == "Range_2D_SFT"), count, 1), ...
            repmat(0.14 - 0.01 * (method == "Range_2D_SFT"), count, 1), ...
            zeros(count, 1), zeros(count, 1), ...
            'VariableNames', ["QHigh", "QLow", "Method", ...
            "SequenceID", "Scene", "MeanSSIM", "WorstSSIM", ...
            "GradientRMSE", "BrightScattererError", ...
            "OverlapExcessSSIMLoss", "BoundaryJumpDB"]);
        sequence_summary = append_table(sequence_summary, rows);
    end
    for seed_idx = 1:5
        seed = cfg.generator_confirmation.rt_seed_families(seed_idx);
        offset = (seed_idx - 3) * 0.0001;
        count = numel(sequence_ids);
        rows = table( ...
            repmat(q_high, count, 1), repmat(q_low, count, 1), ...
            repmat("BARU_RT", count, 1), repmat(seed, count, 1), ...
            repmat(0.67 + offset, count, 1), ...
            'VariableNames', ["QHigh", "QLow", "Method", ...
            "SeedFamily", "MeanSSIM"]);
        sequence_seed_detail = append_table(sequence_seed_detail, rows);
    end
end

QHigh = pair_values(:, 1);
QLow = pair_values(:, 2);
SearchClosed = true(2, 1);
c1 = struct("boundary_audit", table(QHigh, QLow, SearchClosed));
Role = repmat("severity_matched", 2, 1);
DifficultyMatched = true(2, 1);
c2 = struct("difficulty_matching", ...
    table(QHigh, QLow, Role, DifficultyMatched));
stage_a = struct("confirmation_sample_detail", sample_detail, ...
    "confirmation_seed_detail", seed_detail);
stage_b = struct("sequence_summary", sequence_summary, ...
    "seed_detail", sequence_seed_detail);
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
