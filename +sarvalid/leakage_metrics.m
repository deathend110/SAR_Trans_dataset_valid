function metrics = leakage_metrics(X, reference_matrix, threshold_ratio)
%LEAKAGE_METRICS 相对clean RC支持域统计二维和方向泄漏。

arguments
    X
    reference_matrix
    threshold_ratio (1, 1) double {mustBePositive} = 0.35
end
if ~isequal(size(X), size(reference_matrix))
    error('sarvalid:LeakageSizeMismatch', '待测RC与参考RC尺寸不一致。');
end

reference_spectrum = abs(fftshift(fft2(reference_matrix)));
peak = max(reference_spectrum(:));
if peak <= eps
    metrics = struct("off_support_ratio", NaN, ...
        "range_leakage_ratio", NaN, "azimuth_leakage_ratio", NaN);
    return;
end
support = reference_spectrum >= threshold_ratio * peak;
spectrum_power = abs(fftshift(fft2(X))).^2;
total_power = sum(spectrum_power(:)) + eps;

range_profile = sum(spectrum_power, 2);
azimuth_profile = sum(spectrum_power, 1).';
range_mask = any(support, 2);
azimuth_mask = any(support, 1).';

metrics = struct();
metrics.off_support_ratio = sum(spectrum_power(~support), 'all') / total_power;
metrics.range_leakage_ratio = sum(range_profile(~range_mask)) / ...
    (sum(range_profile) + eps);
metrics.azimuth_leakage_ratio = sum(azimuth_profile(~azimuth_mask)) / ...
    (sum(azimuth_profile) + eps);
end
