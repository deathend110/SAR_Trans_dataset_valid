function grid = resolve_acquisition(acq_cfg, input_size, S60)
%RESOLVE_ACQUISITION 将总采样预算解析为实际整数采样网格。

arguments
    acq_cfg (1, 1) struct
    input_size (1, 2) double {mustBePositive, mustBeInteger}
    S60 (1, 1) struct
end

method = string(acq_cfg.method);
q_total = snap_near_integer(double(acq_cfg.q_total));
if q_total < 1
    error('sarvalid:InvalidSamplingBudget', 'q_total必须不小于1。');
end

if startsWith(method, "Range_")
    q_range = q_total;
    q_azimuth = 1;
    alpha = 1;
elseif startsWith(method, "BARU_")
    if isfield(acq_cfg, "q_range") && isfield(acq_cfg, "q_azimuth") && ...
            ~isempty(acq_cfg.q_range) && ~isempty(acq_cfg.q_azimuth)
        q_range = double(acq_cfg.q_range);
        q_azimuth = double(acq_cfg.q_azimuth);
        alpha = log(q_range) / log(q_total);
    else
        alpha = double(acq_cfg.alpha);
        q_range = q_total ^ alpha;
        q_azimuth = q_total ^ (1 - alpha);
    end
else
    error('sarvalid:UnknownMethod', '未知采集方法：%s', method);
end

q_range = snap_near_integer(q_range);
q_azimuth = snap_near_integer(q_azimuth);
if abs(q_range * q_azimuth - q_total) > 1e-10 * max(1, q_total)
    error('sarvalid:SamplingBudgetMismatch', ...
        'qr*qa与q_total不一致：qr=%.16g, qa=%.16g, q=%.16g。', ...
        q_range, q_azimuth, q_total);
end

nr = input_size(1);
na = input_size(2);
nr_up = round(q_range * nr);
na_up = round(q_azimuth * na);
q_range_eff = nr_up / nr;
q_azimuth_eff = na_up / na;

grid = struct();
grid.method = method;
grid.q_total = q_total;
grid.alpha = alpha;
grid.q_range = q_range;
grid.q_azimuth = q_azimuth;
grid.q_range_eff = q_range_eff;
grid.q_azimuth_eff = q_azimuth_eff;
grid.q_total_eff = q_range_eff * q_azimuth_eff;
grid.input_size = input_size;
grid.upsampled_size = [nr_up, na_up];
grid.Fs_up = q_range_eff * S60.Fs;
grid.PRF_up = q_azimuth_eff * S60.prf;
grid.file_key = sarvalid.stable_file_key(method, q_total, alpha);
end

function value = snap_near_integer(value)
if abs(value - round(value)) < 1e-12
    value = round(value);
end
end
