function [U, meta] = build_threshold(signal_up, grid, acq_cfg, S60, context)
%BUILD_THRESHOLD 构造Range RT、SplitRT或二维SFT阈值。

arguments
    signal_up
    grid (1, 1) struct
    acq_cfg (1, 1) struct
    S60 (1, 1) struct
    context (1, 1) struct = struct()
end

if isfield(context, "threshold_override") && ~isempty(context.threshold_override)
    U = context.threshold_override;
    if ~isequal(size(U), size(signal_up))
        error('sarvalid:ThresholdOverrideSizeMismatch', ...
            '外部阈值尺寸与上采样回波不一致。');
    end
    meta = struct("type", "override", "sigma", NaN, ...
        "amplitude", mean(abs(U(:))), "seed", NaN, ...
        "share_policy", "external_override", "time_origin", "external");
    return;
end

sigma_hat = sqrt(2 / pi) * mean(abs(signal_up(:)));
method = string(acq_cfg.method);
seed = get_field(acq_cfg, "seed", 42);
share_policy = string(get_field(acq_cfg, "share_policy", ...
    "same_seed_independent_grid"));

if endsWith(method, "_RT")
    As = get_nested_field(acq_cfg, "threshold", "As", 0.6);
    amplitude = As * sigma_hat;
    if startsWith(method, "Range_")
        stream = RandStream("mt19937ar", "Seed", seed);
        phi_r = 2 * pi * rand(stream, size(signal_up, 1), 1);
        U = repmat(amplitude * exp(1i * phi_r), 1, size(signal_up, 2));
        threshold_type = "range_rt";
    else
        range_stream = RandStream("mt19937ar", "Seed", seed);
        azimuth_stream = RandStream("mt19937ar", "Seed", seed + 104729);
        phi_r = 2 * pi * rand(range_stream, size(signal_up, 1), 1);
        phi_a = 2 * pi * rand(azimuth_stream, 1, size(signal_up, 2));
        U = amplitude * exp(1i * (phi_r + phi_a));
        threshold_type = "split_rt";
    end
    meta = struct("type", threshold_type, "sigma", sigma_hat, ...
        "amplitude", amplitude, "seed", seed, ...
        "share_policy", share_policy, "time_origin", "acquisition_block");
    return;
end

if ~endsWith(method, "_SFT")
    error('sarvalid:UnknownThresholdMethod', '无法为方法%s构造阈值。', method);
end

STR_dB = get_nested_field(acq_cfg, "threshold", "STR_dB", 0);
fr_over_Br = get_nested_field(acq_cfg, "threshold", "fr_over_Br", 0);
fa_over_Ba = get_nested_field(acq_cfg, "threshold", "fa_over_Ba", 0);
phi0 = get_nested_field(acq_cfg, "threshold", "phi0", 0);
if startsWith(method, "Range_")
    fa_over_Ba = 0;
end

azimuth_bandwidth = resolve_azimuth_bandwidth(S60);
fr_Hz = fr_over_Br * S60.B;
fa_Hz = fa_over_Ba * azimuth_bandwidth;
fast_time = ((0:size(signal_up, 1)-1).' - floor(size(signal_up, 1) / 2)) ...
    / grid.Fs_up;

slow_offset = get_field(context, "slow_time_sample_offset", 0);
slow_center = get_field(context, "slow_time_center_index", ...
    floor(size(signal_up, 2) / 2));
slow_indices = slow_offset + (0:size(signal_up, 2)-1);
slow_time = (slow_indices - slow_center) / grid.PRF_up;

amplitude = sigma_hat / (10 ^ (STR_dB / 20));
phase_range = 2 * pi * fr_Hz * fast_time;
phase_azimuth = 2 * pi * fa_Hz * slow_time;
U = amplitude * exp(1i * (phase_range + phase_azimuth + phi0));

meta = struct("type", "2d_sft", "sigma", sigma_hat, ...
    "amplitude", amplitude, "seed", NaN, ...
    "share_policy", "deterministic_shared_physical_frequency", ...
    "time_origin", string(get_field(acq_cfg, "time_origin", "block_global")), ...
    "STR_dB", STR_dB, "fr_over_Br", fr_over_Br, ...
    "fa_over_Ba", fa_over_Ba, "fr_Hz", fr_Hz, "fa_Hz", fa_Hz, ...
    "phi0", phi0);
end

function value = get_field(input, name, default_value)
if isfield(input, name)
    value = input.(name);
else
    value = default_value;
end
end

function value = get_nested_field(input, parent, name, default_value)
if isfield(input, parent) && isfield(input.(parent), name)
    value = input.(parent).(name);
else
    value = default_value;
end
end

function bandwidth = resolve_azimuth_bandwidth(S60)
if isfield(S60, "Ba")
    bandwidth = S60.Ba;
elseif isfield(S60, "Bd")
    bandwidth = S60.Bd;
elseif isfield(S60, "Da")
    bandwidth = 2 * S60.v / S60.Da;
else
    error('sarvalid:MissingAzimuthBandwidth', ...
        '成像参数必须包含Ba、Bd或Da以确定方位带宽。');
end
end
