function [results, ranking] = run_180_sensitivity( ...
        cfg, calibration_manifest, top_by_method, locked_configs, S60)
%RUN_180_SENSITIVITY 对每种方法首选候选执行7场景180 MHz GT检查。

if ~isfile(cfg.parameter_file_180)
    error('sarvalid:MissingFS180Parameters', ...
        '未找到180 MHz参数文件：%s', cfg.parameter_file_180);
end
S180 = load(cfg.parameter_file_180);
results = table();

for top_idx = 1:height(top_by_method)
    pair_key = top_by_method.PairKey(top_idx);
    pair = find_locked_pair(locked_configs, pair_key);
    task_dir = fullfile(cfg.stage_b.output_dir, pair.file_key);
    norm_stats = readtable(fullfile(task_dir, "normalization.csv"), ...
        'TextType', 'string');

    raw_inputs = cell(height(calibration_manifest), 1);
    raw_gt180 = cell(height(calibration_manifest), 1);
    for idx = 1:height(calibration_manifest)
        sequence_pair = pair;
        sequence_pair.H.seed = pair.H.seed + calibration_manifest.SequenceID(idx) * 1000;
        sequence_pair.L.seed = pair.L.seed + ...
            calibration_manifest.SequenceID(idx) * 1000 + 1;
        signal60 = sarvalid.load_echo_block( ...
            calibration_manifest(idx, :), S60, cfg.sequence.block_width);
        sequence60 = sarvalid.generate_hlh_sequence(signal60, S60, sequence_pair);
        raw_inputs{idx} = sequence60.input_raw;
        raw_gt180{idx} = sarvalid.generate_gt_180_sequence( ...
            calibration_manifest(idx, :), S180, cfg.sequence);
    end

    Scene = string(calibration_manifest.Scene);
    Modality = repmat("GT180", height(calibration_manifest), 1);
    Split = repmat("calibration", height(calibration_manifest), 1);
    Pixels = raw_gt180;
    [norm180, ~] = sarvalid.fit_global_normalization( ...
        table(Scene, Modality, Split, Pixels), "calibration", ...
        LowPercentile=cfg.normalization.low_percentile, ...
        HighPercentile=cfg.normalization.high_percentile);

    for idx = 1:height(calibration_manifest)
        scene = calibration_manifest.Scene(idx);
        input = sarvalid.apply_normalization( ...
            raw_inputs{idx}, norm_stats, scene, "MIXED");
        gt180 = sarvalid.apply_normalization( ...
            raw_gt180{idx}, norm180, scene, "GT180");
        [~, summary, ~] = sarvalid.sequence_metrics(input, gt180);
        Method = string(pair.method);
        PairKey = string(pair.file_key);
        Scene = string(scene);
        SequenceID = calibration_manifest.SequenceID(idx);
        MeanPSNR180 = summary.mean_psnr;
        MeanSSIM180 = summary.mean_ssim;
        WorstPSNR180 = summary.worst_psnr;
        WorstSSIM180 = summary.worst_ssim;
        MeanPSNR60 = top_by_method.MeanPSNR(top_idx);
        MeanSSIM60 = top_by_method.MeanSSIM(top_idx);
        DeltaPSNR180vs60 = MeanPSNR180 - MeanPSNR60;
        DeltaSSIM180vs60 = MeanSSIM180 - MeanSSIM60;
        row = table(Method, PairKey, Scene, SequenceID, MeanPSNR180, ...
            MeanSSIM180, WorstPSNR180, WorstSSIM180, MeanPSNR60, ...
            MeanSSIM60, DeltaPSNR180vs60, DeltaSSIM180vs60);
        results = [results; row]; %#ok<AGROW>
    end
end

ranking = summarize_ranking(results, top_by_method);
end

function pair = find_locked_pair(locked_configs, pair_key)
for idx = 1:numel(locked_configs)
    if string(locked_configs{idx}.file_key) == string(pair_key)
        pair = locked_configs{idx};
        return;
    end
end
error('sarvalid:LockedPairNotFound', '找不到锁定配置：%s', pair_key);
end

function ranking = summarize_ranking(results, top_by_method)
methods = unique(results.Method, 'stable');
row_count = numel(methods);
Method = strings(row_count, 1);
PairKey = strings(row_count, 1);
MeanPSNR60 = zeros(row_count, 1);
MeanSSIM60 = zeros(row_count, 1);
MeanPSNR180 = zeros(row_count, 1);
MeanSSIM180 = zeros(row_count, 1);
for idx = 1:row_count
    Method(idx) = methods(idx);
    mask = results.Method == methods(idx);
    PairKey(idx) = results.PairKey(find(mask, 1));
    top_mask = top_by_method.Method == methods(idx);
    MeanPSNR60(idx) = top_by_method.MeanPSNR(top_mask);
    MeanSSIM60(idx) = top_by_method.MeanSSIM(top_mask);
    MeanPSNR180(idx) = mean(results.MeanPSNR180(mask));
    MeanSSIM180(idx) = mean(results.MeanSSIM180(mask));
end
ranking = table(Method, PairKey, MeanPSNR60, MeanSSIM60, ...
    MeanPSNR180, MeanSSIM180);
[~, order60] = sortrows([-MeanSSIM60, -MeanPSNR60], [1, 2]);
[~, order180] = sortrows([-MeanSSIM180, -MeanPSNR180], [1, 2]);
Rank60 = zeros(row_count, 1);
Rank180 = zeros(row_count, 1);
Rank60(order60) = (1:row_count).';
Rank180(order180) = (1:row_count).';
RankingChanged = Rank60 ~= Rank180;
ranking = addvars(ranking, Rank60, Rank180, RankingChanged);
ranking = sortrows(ranking, "Rank180");
end
