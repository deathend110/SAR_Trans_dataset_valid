function [metrics, diagnostics] = evaluate_case(result, gt, meta)
%EVALUATE_CASE 评价归一化图像，并按需计算RC频谱诊断。

arguments
    result (1, 1) struct
    gt
    meta (1, 1) struct = struct()
end
if ~isfield(result, "image")
    error('sarvalid:MissingResultImage', 'result必须包含image字段。');
end
image = single(result.image);
gt = single(gt);
if ~isequal(size(image), size(gt))
    error('sarvalid:MetricSizeMismatch', '输入图像与GT尺寸不一致。');
end

metrics = struct();
metrics.psnr = psnr(image, gt, 1);
metrics.ssim = ssim(image, gt, 'DynamicRange', 1);
metrics.entropy = local_entropy(image, 256);
metrics.gradient_rmse = gradient_rmse(image, gt);
metrics.bright_scatterer_error = bright_scatterer_error(image, gt);

diagnostics = struct("off_support_ratio", NaN, ...
    "range_leakage_ratio", NaN, "azimuth_leakage_ratio", NaN);
if isfield(result, "RC_base") && isfield(meta, "reference_rc") && ...
        ~isempty(meta.reference_rc)
    threshold_ratio = 0.35;
    if isfield(meta, "support_threshold_ratio")
        threshold_ratio = meta.support_threshold_ratio;
    end
    diagnostics = sarvalid.leakage_metrics( ...
        result.RC_base, meta.reference_rc, threshold_ratio);
end
end

function value = local_entropy(image, num_bins)
values = min(max(double(image(:)), 0), 1);
counts = histcounts(values, linspace(0, 1, num_bins + 1));
probabilities = counts / max(sum(counts), 1);
probabilities = probabilities(probabilities > 0);
value = -sum(probabilities .* log2(probabilities));
end

function value = gradient_rmse(image, gt)
[gx, gy] = gradient(double(image));
[gtx, gty] = gradient(double(gt));
gradient_image = hypot(gx, gy);
gradient_gt = hypot(gtx, gty);
value = sqrt(mean((gradient_image(:) - gradient_gt(:)).^2));
end

function value = bright_scatterer_error(image, gt)
threshold = prctile(double(gt(:)), 99);
mask = double(gt) >= threshold;
if ~any(mask, 'all')
    value = NaN;
else
    value = mean(abs(double(image(mask)) - double(gt(mask))));
end
end
