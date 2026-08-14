classdef TestSarValidCore < matlab.unittest.TestCase
    % 公共采集核心的轻量单元测试，不读取真实SAR数据集。

    methods (TestClassSetup)
        function addRepositoryToPath(testCase)
            tests_dir = fileparts(mfilename("fullpath"));
            repo_root = fileparts(tests_dir);
            addpath(repo_root);
            testCase.addTeardown(@() rmpath(repo_root));
        end
    end

    methods (Test)
        function resolveFractionalSamplingGrid(testCase)
            S60 = struct("Fs", 60e6, "prf", 240);
            acq = struct("method", "BARU_RT", "q_total", 2.5, "alpha", 0.35);
            grid = sarvalid.resolve_acquisition(acq, [1200, 1200], S60);
            testCase.verifyEqual(grid.upsampled_size, [1654, 2177]);
            testCase.verifyEqual(grid.q_range_eff, 1654/1200, 'AbsTol', 1e-15);
            testCase.verifyEqual(grid.q_azimuth_eff, 2177/1200, 'AbsTol', 1e-15);
            testCase.verifyTrue(contains(grid.file_key, "q2p5"));
        end

        function fftRoundTripHasPredictableScale(testCase)
            stream = RandStream("mt19937ar", "Seed", 7);
            input = randn(stream, 8, 10) + 1i * randn(stream, 8, 10);
            grid = struct("upsampled_size", [13, 17]);
            upsampled = sarvalid.upsample_fft(input, grid);
            restored = sarvalid.crop_spectrum(upsampled, 10, 2);
            restored = sarvalid.crop_spectrum(restored, 8, 1);
            expected_scale = (13/8) * (17/10);
            testCase.verifyEqual(restored / expected_scale, input, ...
                'AbsTol', 1e-11);
        end

        function sftUsesRangeAndAzimuthAxes(testCase)
            signal = ones(4, 5) + 1i * ones(4, 5);
            grid = struct("Fs_up", 10, "PRF_up", 4);
            threshold = struct("STR_dB", 0, "fr_over_Br", 1, ...
                "fa_over_Ba", 1, "phi0", 0);
            acq = struct("method", "BARU_SFT", "q_total", 2, ...
                "threshold", threshold, "time_origin", "block_global");
            S60 = struct("B", 2, "Bd", 1);
            [U, meta] = sarvalid.build_threshold(signal, grid, acq, S60);
            testCase.verifySize(U, [4, 5]);
            testCase.verifyEqual(meta.fr_Hz, 2);
            testCase.verifyEqual(meta.fa_Hz, 1);
            testCase.verifyNotEqual(U(1, 1), U(2, 1));
            testCase.verifyNotEqual(U(1, 1), U(1, 2));
        end

        function quantizationAlphabetAndZeroRule(testCase)
            signal = complex([0, -1; 1, 0], [0, 1; -1, 0]);
            output = sarvalid.quantize_with_threshold(signal, zeros(size(signal)));
            testCase.verifyEqual(real(output(1, 1)), 1);
            testCase.verifyEqual(imag(output(1, 1)), 1);
            testCase.verifyTrue(all(ismember(real(output(:)), [-1, 1])));
            testCase.verifyTrue(all(ismember(imag(output(:)), [-1, 1])));
        end

        function hlhMaskHasExpectedFrameRatios(testCase)
            cfg = sarvalid.default_config();
            mask = sarvalid.build_hlh_mask(cfg.sequence);
            expected = [1, 0.75, 0.5, 0.25, 0, 0.25, 0.5, 0.75, 1].';
            testCase.verifyEqual(mask.h_ratio, expected, 'AbsTol', 0);
            testCase.verifyEqual(mask.boundaries, [856, 1368]);
        end

        function twoBoundaryEnergyAlignmentUsesOneScale(testCase)
            cfg = sarvalid.default_config();
            mask = sarvalid.build_hlh_mask(cfg.sequence);
            RC_H = complex(2 * ones(4, cfg.sequence.block_width));
            RC_L = complex(ones(4, cfg.sequence.block_width));
            [mixed, info] = sarvalid.align_and_mix_rc(RC_H, RC_L, mask.full, 16);
            testCase.verifyEqual(info.scale_factor, 0.5, 'AbsTol', 1e-12);
            testCase.verifyEqual(mixed, complex(ones(size(mixed))), 'AbsTol', 1e-12);
            testCase.verifyEqual(numel(info.boundaries), 2);
        end

        function normalizationUsesOnlyRequestedSplit(testCase)
            Scene = ["A"; "A"; "A"];
            Modality = ["GT"; "GT"; "GT"];
            Split = ["development"; "development"; "verification"];
            Pixels = {reshape(1:100, 10, 10); reshape(101:200, 10, 10); 1e9};
            samples = table(Scene, Modality, Split, Pixels);
            [stats, audit] = sarvalid.fit_global_normalization(samples, "development", ...
                LowPercentile=0, HighPercentile=100);
            testCase.verifyEqual(stats.VMin, 1);
            testCase.verifyEqual(stats.VMax, 200);
            testCase.verifyEqual(audit.selected_rows, 2);
            normalized = sarvalid.apply_normalization([1, 200, 300], stats, "A", "GT");
            testCase.verifyEqual(normalized, single([0, 1, 1]));
        end

        function checkpointRejectsMismatchedSignature(testCase)
            file_path = string(tempname) + ".mat";
            testCase.addTeardown(@() delete_if_exists(file_path));
            state = struct("signature", struct("q", 2), "completed", 1);
            sarvalid.atomic_save(file_path, struct("state", state));
            restored = sarvalid.load_checkpoint(file_path, struct("q", 2), ...
                struct("completed", 0));
            testCase.verifyEqual(restored.completed, 1);
            testCase.verifyError(@() sarvalid.load_checkpoint( ...
                file_path, struct("q", 3), struct("completed", 0)), ...
                'sarvalid:CheckpointSignatureMismatch');
        end

        function rangeCompressionAcceptsOddGrid(testCase)
            nr = 15;
            signal = ones(nr, 8) + 1i * ones(nr, 8);
            Fs = 5;
            Tp = 1;
            t = ((0:nr-1).' - floor(nr/2)) / Fs;
            output = Range_Compress(signal, 0, t, 1, 0, 1, Fs, Tp);
            testCase.verifySize(output, size(signal));
            testCase.verifyTrue(all(isfinite(output), 'all'));
        end
    end
end

function delete_if_exists(file_path)
if isfile(file_path)
    delete(file_path);
end
end
