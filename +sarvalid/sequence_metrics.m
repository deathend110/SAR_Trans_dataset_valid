function [frame_table, summary, overlap_table] = sequence_metrics(input_seq, gt_seq)
%SEQUENCE_METRICS 计算九帧质量、U曲线和平移对齐后的重叠一致性。

if ~isequal(size(input_seq), size(gt_seq)) || ndims(input_seq) ~= 3
    error('sarvalid:SequenceMetricSize', '输入序列与GT必须为同尺寸三维数组。');
end
num_frames = size(input_seq, 3);
FrameIdx = (0:num_frames-1).';
PSNR = zeros(num_frames, 1);
SSIM = zeros(num_frames, 1);
for idx = 1:num_frames
    PSNR(idx) = psnr(input_seq(:, :, idx), gt_seq(:, :, idx), 1);
    SSIM(idx) = ssim(input_seq(:, :, idx), gt_seq(:, :, idx), ...
        'DynamicRange', 1);
end
frame_table = table(FrameIdx, PSNR, SSIM);

overlap_width = size(input_seq, 2) - 128;
PairIdx = (0:num_frames-2).';
InputRMSE = zeros(num_frames-1, 1);
GTRMSE = zeros(num_frames-1, 1);
InputSSIM = zeros(num_frames-1, 1);
GTSSIM = zeros(num_frames-1, 1);
for idx = 1:num_frames-1
    input_left = input_seq(:, end-overlap_width+1:end, idx);
    input_right = input_seq(:, 1:overlap_width, idx+1);
    gt_left = gt_seq(:, end-overlap_width+1:end, idx);
    gt_right = gt_seq(:, 1:overlap_width, idx+1);
    InputRMSE(idx) = sqrt(mean((double(input_left(:))-double(input_right(:))).^2));
    GTRMSE(idx) = sqrt(mean((double(gt_left(:))-double(gt_right(:))).^2));
    InputSSIM(idx) = ssim(input_left, input_right, 'DynamicRange', 1);
    GTSSIM(idx) = ssim(gt_left, gt_right, 'DynamicRange', 1);
end
ExcessRMSE = InputRMSE - GTRMSE;
ExcessSSIMLoss = (1-InputSSIM) - (1-GTSSIM);
overlap_table = table(PairIdx, InputRMSE, GTRMSE, ExcessRMSE, ...
    InputSSIM, GTSSIM, ExcessSSIMLoss);

summary = struct();
summary.mean_psnr = mean(PSNR);
summary.mean_ssim = mean(SSIM);
summary.worst_psnr = min(PSNR);
summary.worst_ssim = min(SSIM);
summary.psnr_smoothness = mean(abs(diff(PSNR, 2)));
summary.ssim_smoothness = mean(abs(diff(SSIM, 2)));
summary.overlap_excess_rmse = mean(ExcessRMSE);
summary.overlap_excess_ssim_loss = mean(ExcessSSIMLoss);
end
