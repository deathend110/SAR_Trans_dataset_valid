function [frame_table, summary, overlap_table] = sequence_metrics( ...
        input_seq, gt_seq, frame_masks)
%SEQUENCE_METRICS 计算九帧质量、U曲线和平移对齐后的重叠一致性。

if ~isequal(size(input_seq), size(gt_seq)) || ndims(input_seq) ~= 3
    error('sarvalid:SequenceMetricSize', '输入序列与GT必须为同尺寸三维数组。');
end
num_frames = size(input_seq, 3);
if nargin < 3 || isempty(frame_masks)
    frame_masks = true(num_frames, size(input_seq, 2));
end
if ~isequal(size(frame_masks), [num_frames, size(input_seq, 2)])
    error('sarvalid:SequenceMaskMetricSize', ...
        '帧掩膜必须为NFrame×图像宽度。');
end
FrameIdx = (0:num_frames-1).';
PSNR = zeros(num_frames, 1);
SSIM = zeros(num_frames, 1);
GradientRMSE = zeros(num_frames, 1);
BrightScattererError = zeros(num_frames, 1);
HRegionPSNR = nan(num_frames, 1);
HRegionSSIM = nan(num_frames, 1);
LRegionPSNR = nan(num_frames, 1);
LRegionSSIM = nan(num_frames, 1);
for idx = 1:num_frames
    metrics = sarvalid.evaluate_case( ...
        struct("image", input_seq(:, :, idx)), gt_seq(:, :, idx));
    PSNR(idx) = metrics.psnr;
    SSIM(idx) = metrics.ssim;
    GradientRMSE(idx) = metrics.gradient_rmse;
    BrightScattererError(idx) = metrics.bright_scatterer_error;
    [HRegionPSNR(idx), HRegionSSIM(idx)] = region_metrics( ...
        input_seq(:, :, idx), gt_seq(:, :, idx), frame_masks(idx, :));
    [LRegionPSNR(idx), LRegionSSIM(idx)] = region_metrics( ...
        input_seq(:, :, idx), gt_seq(:, :, idx), ~frame_masks(idx, :));
end
frame_table = table(FrameIdx, PSNR, SSIM, GradientRMSE, ...
    BrightScattererError, HRegionPSNR, HRegionSSIM, ...
    LRegionPSNR, LRegionSSIM);

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
summary.mean_gradient_rmse = mean(GradientRMSE);
summary.mean_bright_scatterer_error = mean(BrightScattererError);
summary.h_region_psnr = mean(HRegionPSNR, 'omitnan');
summary.h_region_ssim = mean(HRegionSSIM, 'omitnan');
summary.l_region_psnr = mean(LRegionPSNR, 'omitnan');
summary.l_region_ssim = mean(LRegionSSIM, 'omitnan');
summary.u_depth_psnr = mean(PSNR([1, end])) - PSNR(ceil(num_frames / 2));
summary.u_depth_ssim = mean(SSIM([1, end])) - SSIM(ceil(num_frames / 2));
summary.psnr_smoothness = mean(abs(diff(PSNR, 2)));
summary.ssim_smoothness = mean(abs(diff(SSIM, 2)));
summary.overlap_excess_rmse = mean(ExcessRMSE);
summary.overlap_excess_ssim_loss = mean(ExcessSSIMLoss);
end

function [psnr_value, ssim_value] = region_metrics(input_image, gt, columns)
% 区域指标只在对应H或L列上计算；全空区域保留NaN供聚合时忽略。
if ~any(columns) || sum(columns) < 11
    psnr_value = NaN;
    ssim_value = NaN;
    return;
end
input_region = input_image(:, columns);
gt_region = gt(:, columns);
psnr_value = psnr(input_region, gt_region, 1);
ssim_value = ssim(input_region, gt_region, 'DynamicRange', 1);
end
