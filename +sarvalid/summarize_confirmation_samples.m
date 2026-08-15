function [scene_summary, scene_wins, tail_summary] = ...
        summarize_confirmation_samples(range, baru, q_high, q_low, margin)
%SUMMARIZE_CONFIRMATION_SAMPLES 汇总Stage A场景均值与分支感知尾部指标。

[range, baru] = align_rows(range, baru, "SampleID");
range_ssim = mean([range.HSSIM, range.LSSIM], 2);
baru_ssim = mean([baru.HSSIM, baru.LSSIM], 2);
differences = range_ssim - baru_ssim;
scenes = unique(range.Scene, 'stable');
scene_summary = table();
tail_summary = table();
scene_wins = 0;

for idx = 1:numel(scenes)
    scene = scenes(idx);
    mask = range.Scene == scene;
    MeanSSIMDifference = mean(differences(mask));
    scene_wins = scene_wins + (MeanSSIMDifference > 0);
    QHigh = q_high;
    QLow = q_low;
    Stage = "Stage A";
    Scene = scene;
    scene_summary = append_table(scene_summary, ...
        table(QHigh, QLow, Stage, Scene, MeanSSIMDifference));

    r = range(mask, :);
    b = baru(mask, :);
    RangeP10H = percentile(r.HSSIM, 0.10);
    RangeP10L = percentile(r.LSSIM, 0.10);
    BARUP10H = percentile(b.HSSIM, 0.10);
    BARUP10L = percentile(b.LSSIM, 0.10);
    RangeWorst3H = worst_k_mean(r.HSSIM, 3);
    RangeWorst3L = worst_k_mean(r.LSSIM, 3);
    BARUWorst3H = worst_k_mean(b.HSSIM, 3);
    BARUWorst3L = worst_k_mean(b.LSSIM, 3);
    RangeP10 = min(RangeP10H, RangeP10L);
    BARUP10 = min(BARUP10H, BARUP10L);
    RangeWorst3 = min(RangeWorst3H, RangeWorst3L);
    BARUWorst3 = min(BARUWorst3H, BARUWorst3L);
    P10Difference = RangeP10 - BARUP10;
    Worst3Difference = RangeWorst3 - BARUWorst3;
    P10NonInferior = P10Difference >= -margin;
    Worst3NonInferior = Worst3Difference >= -margin;
    tail_summary = append_table(tail_summary, ...
        table(QHigh, QLow, Scene, RangeP10H, RangeP10L, ...
        BARUP10H, BARUP10L, RangeWorst3H, RangeWorst3L, ...
        BARUWorst3H, BARUWorst3L, RangeP10, BARUP10, ...
        P10Difference, RangeWorst3, BARUWorst3, Worst3Difference, ...
        P10NonInferior, Worst3NonInferior));
end
end

function value = percentile(values, probability)
values = sort(values(:));
position = 1 + (numel(values) - 1) * probability;
lower_index = floor(position);
upper_index = ceil(position);
if lower_index == upper_index
    value = values(lower_index);
else
    fraction = position - lower_index;
    value = values(lower_index) * (1 - fraction) + ...
        values(upper_index) * fraction;
end
end

function value = worst_k_mean(values, count)
values = sort(values(:));
value = mean(values(1:min(count, numel(values))));
end

function [a, b] = align_rows(a, b, key_name)
[~, order_a] = sort(a.(key_name));
[~, order_b] = sort(b.(key_name));
a = a(order_a, :);
b = b(order_b, :);
end

function output = append_table(input, rows)
if isempty(input)
    output = rows;
else
    output = [input; rows];
end
end
