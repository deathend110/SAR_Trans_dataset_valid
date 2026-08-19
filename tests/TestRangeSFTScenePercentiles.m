classdef TestRangeSFTScenePercentiles < matlab.unittest.TestCase
    methods (TestClassSetup)
        function addRepositoryToPath(testCase)
            tests_dir = fileparts(mfilename("fullpath"));
            repo_root = fileparts(tests_dir);
            addpath(repo_root);
            testCase.addTeardown(@() rmpath(repo_root));
        end
    end

    methods (Test)
        function testManifestUsesTenUniformStartsPerFile(testCase)
            root = string(tempname);
            cleanup = onCleanup(@() remove_directory(root));
            scenes = ["SAR_Dataset_Bangkok_1", ...
                "SAR_Dataset_city1_histeq"];
            for scene = scenes
                mkdir(fullfile(root, scene));
                for file_idx = 1:2
                    raw_data = complex(single(ones(6, 50 + file_idx)), ...
                        single(zeros(6, 50 + file_idx)));
                    save(fullfile(root, scene, ...
                        "rstart " + string(file_idx * 100) + ".mat"), ...
                        "raw_data");
                end
            end

            cfg = struct("data_root", root, "dataset_names", scenes, ...
                "sequence", struct("block_width", 20));
            manifest = sarvalid.build_scene_percentile_manifest(cfg, 10);
            testCase.verifyEqual(height(manifest), 40);
            testCase.verifyEqual(numel(unique(manifest.FilePath)), 4);
            testCase.verifyEqual(unique(manifest.SceneKey, 'stable'), ...
                ["bangkok"; "city1_histeq"]);

            files = unique(manifest.FilePath, 'stable');
            for file = files.'
                rows = manifest(manifest.FilePath == file, :);
                expected = round(linspace(1, ...
                    rows.RawWidth(1) - rows.BlockWidth(1) + 1, 10)).';
                testCase.verifyEqual(rows.CStart, expected);
                testCase.verifyEqual(numel(unique(rows.CStart)), 10);
            end
            clear cleanup;
        end

        function testJointPoolAppliesAlignedHAndEqualWeight(testCase)
            h = single(reshape(1:8, [2, 2, 2]));
            l = single(reshape(21:28, [2, 2, 2]));
            gamma = single(0.25);
            actual = sarvalid.joint_hl_pixel_pool(h * gamma, l);
            expected = [single(h(:) * gamma); single(l(:))];
            testCase.verifyEqual(actual, expected, 'AbsTol', 0);
            testCase.verifyEqual(numel(actual), 2 * numel(h));
        end

        function testExactTallPercentilesMatchInMemory(testCase)
            root = string(tempname);
            mkdir(root);
            cleanup = onCleanup(@() remove_directory(root));
            all_values = single([1:100, 200:240]).';
            split_points = [1, 38, 91, numel(all_values) + 1];
            for idx = 1:3
                values = all_values(split_points(idx):split_points(idx + 1)-1);
                save(fullfile(root, sprintf('chunk_%06d.mat', idx)), ...
                    "values", '-v7.3');
            end
            percentages = [7.5, 92.5];
            stats = sarvalid.exact_percentiles_from_chunks( ...
                root, percentages, "JointHL", 6);
            expected = prctile(all_values, percentages, Method="midpoint");
            testCase.verifyEqual([stats.VMin, stats.VMax], ...
                double(expected), 'AbsTol', 1e-12);
            testCase.verifyEqual(stats.PixelCount, numel(all_values));
            testCase.verifyEqual(stats.ChunkCount, 3);
            clear cleanup;
        end

        function testSceneMatUpsertAppendsAndReplaces(testCase)
            root = string(tempname);
            mkdir(root);
            cleanup = onCleanup(@() remove_directory(root));
            file_path = fullfile(root, "bangkok.mat");
            header = sample_header();
            gt = sample_stats("GT", "gt-signature", 0, 10);

            entry_a = sample_entry("key-a", 1, 2);
            first = sarvalid.upsert_scene_percentile_stats( ...
                file_path, header, gt, entry_a);
            testCase.verifyEqual(numel(first.entries), 1);
            created_at = first.entries(1).created_at;

            entry_b = sample_entry("key-b", 3, 4);
            second = sarvalid.upsert_scene_percentile_stats( ...
                file_path, header, gt, entry_b);
            testCase.verifyEqual(string({second.entries.parameter_key}), ...
                ["key-a", "key-b"]);

            replacement = sample_entry("key-a", 5, 6);
            third = sarvalid.upsert_scene_percentile_stats( ...
                file_path, header, gt, replacement);
            testCase.verifyEqual(numel(third.entries), 2);
            testCase.verifyEqual(third.entries(1).input_stats.VMin, 5);
            testCase.verifyEqual(third.entries(1).created_at, created_at);
            clear cleanup;
        end

        function testSceneMatRejectsSourceMismatch(testCase)
            root = string(tempname);
            mkdir(root);
            cleanup = onCleanup(@() remove_directory(root));
            file_path = fullfile(root, "bangkok.mat");
            header = sample_header();
            gt = sample_stats("GT", "gt-signature", 0, 10);
            entry = sample_entry("key-a", 1, 2);
            sarvalid.upsert_scene_percentile_stats( ...
                file_path, header, gt, entry);

            changed = header;
            changed.source_signature = "changed";
            testCase.verifyError(@() ...
                sarvalid.upsert_scene_percentile_stats( ...
                file_path, changed, gt, entry), ...
                'sarvalid:ScenePercentileSourceSignatureMismatch');
            clear cleanup;
        end

        function testParameterKeyCoversProtocolAndPhase(testCase)
            parameters = struct("QHigh", 4, "QLow", 2, ...
                "STRdB", -1, "FrOverBr", 1.3, ...
                "FaOverBa", 0.5, "Phi0", 0);
            protocol = struct("low_percentile", 0.99, ...
                "high_percentile", 99.9, "roi_size", 600, ...
                "energy_buffer", 64);
            key = sarvalid.range_2dsft_percentile_key( ...
                parameters, protocol);
            changed = parameters;
            changed.Phi0 = pi / 4;
            changed_key = sarvalid.range_2dsft_percentile_key( ...
                changed, protocol);
            testCase.verifyNotEqual(key, changed_key);
            testCase.verifySubstring(key, "_lp0p99_hp99p9_roi600_eb64");
        end
    end
end

function header = sample_header()
header = struct( ...
    "schema_version", "range_2dsft_scene_percentiles_v1", ...
    "scene_name", "SAR_Dataset_Bangkok_1", ...
    "scene_key", "bangkok", ...
    "protocol", struct("version", 1), ...
    "source_manifest", table(1, 'VariableNames', "ID"), ...
    "source_signature", "source-signature");
end

function stats = sample_stats(modality, signature, v_min, v_max)
stats = struct("Modality", modality, "VMin", v_min, "VMax", v_max, ...
    "ImageCount", 1, "PixelCount", 10, "ChunkCount", 1, ...
    "LowPercentile", 0.99, "HighPercentile", 99.9, ...
    "Method", "midpoint_exact_tall", "signature", signature);
end

function entry = sample_entry(key, v_min, v_max)
entry = struct( ...
    "parameter_key", key, ...
    "parameters", struct("QHigh", 4, "QLow", 2), ...
    "effective_sampling", struct("H", 4, "L", 2), ...
    "input_stats", sample_stats("JointHL", "input", v_min, v_max), ...
    "audit", struct("SequenceCount", 1), ...
    "created_at", "", ...
    "updated_at", "");
end

function remove_directory(path)
if isfolder(path)
    rmdir(path, 's');
end
end
