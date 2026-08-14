function row = candidate_row(pair_cfg, stage, evaluation)
%CANDIDATE_ROW 将候选配置和开发集汇总转换为单行table。

threshold = pair_cfg.H.threshold;
summary = evaluation.summary;
Method = string(pair_cfg.method);
PairKey = string(pair_cfg.file_key);
Stage = string(stage);
QHigh = pair_cfg.q_high;
QLow = pair_cfg.q_low;
Alpha = pair_cfg.alpha;
STRdB = threshold.STR_dB;
FrOverBr = threshold.fr_over_Br;
FaOverBa = threshold.fa_over_Ba;
H_PSNR_Mean = summary.H_PSNR_Mean;
H_SSIM_Mean = summary.H_SSIM_Mean;
L_PSNR_Mean = summary.L_PSNR_Mean;
L_SSIM_Mean = summary.L_SSIM_Mean;
Delta_PSNR_Mean = summary.Delta_PSNR_Mean;
Delta_SSIM_Mean = summary.Delta_SSIM_Mean;
Pair_PSNR_Mean = summary.Pair_PSNR_Mean;
Pair_SSIM_Mean = summary.Pair_SSIM_Mean;
SampleCount = summary.SampleCount;
row = table(Method, PairKey, Stage, QHigh, QLow, Alpha, STRdB, ...
    FrOverBr, FaOverBa, H_PSNR_Mean, H_SSIM_Mean, L_PSNR_Mean, ...
    L_SSIM_Mean, Delta_PSNR_Mean, Delta_SSIM_Mean, ...
    Pair_PSNR_Mean, Pair_SSIM_Mean, SampleCount);
end
