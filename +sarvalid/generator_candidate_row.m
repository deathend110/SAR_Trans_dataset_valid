function [row, seed_rows] = generator_candidate_row( ...
        pair, stage, evaluation, seeds)
%GENERATOR_CANDIDATE_ROW 将确认实验候选结果转换为审计表行。

s = evaluation.summary;
threshold = pair.H.threshold;
Method = string(pair.method);
PairKey = string(pair.file_key);
Stage = string(stage);
QHigh = pair.q_high;
QLow = pair.q_low;
Alpha = pair.alpha;
As = threshold.As;
STRdB = threshold.STR_dB;
FrOverBr = threshold.fr_over_Br;
FaOverBa = threshold.fa_over_Ba;
H_PSNR_Mean = s.H_PSNR_Mean;
H_SSIM_Mean = s.H_SSIM_Mean;
L_PSNR_Mean = s.L_PSNR_Mean;
L_SSIM_Mean = s.L_SSIM_Mean;
Delta_PSNR_Mean = s.Delta_PSNR_Mean;
Delta_SSIM_Mean = s.Delta_SSIM_Mean;
Pair_PSNR_Mean = s.Pair_PSNR_Mean;
Pair_SSIM_Mean = s.Pair_SSIM_Mean;
Worst_SSIM = s.Worst_SSIM;
Pair_SSIM_SeedStd = s.Pair_SSIM_SeedStd;
SampleCount = s.SampleCount;
SeedCount = s.SeedCount;
SeedFamilies = strjoin(string(seeds), ";");
row = table(Method, PairKey, Stage, QHigh, QLow, Alpha, As, ...
    STRdB, FrOverBr, FaOverBa, H_PSNR_Mean, H_SSIM_Mean, ...
    L_PSNR_Mean, L_SSIM_Mean, Delta_PSNR_Mean, Delta_SSIM_Mean, ...
    Pair_PSNR_Mean, Pair_SSIM_Mean, Worst_SSIM, ...
    Pair_SSIM_SeedStd, SampleCount, SeedCount, SeedFamilies);

count = height(evaluation.seed_summary);
seed_rows = addvars(evaluation.seed_summary, ...
    repmat(Method, count, 1), repmat(PairKey, count, 1), ...
    repmat(Stage, count, 1), repmat(QHigh, count, 1), ...
    repmat(QLow, count, 1), repmat(Alpha, count, 1), ...
    repmat(As, count, 1), 'Before', 1, 'NewVariableNames', ...
    ["Method", "PairKey", "Stage", "QHigh", "QLow", "Alpha", "As"]);
end
