function [RC_mix, info] = align_and_mix_rc(RC_H, RC_L, mode_mask, buffer)
%ALIGN_AND_MIX_RC 在全部H/L边界汇总能量，并用单一比例完成RC混合。

arguments
    RC_H
    RC_L
    mode_mask
    buffer (1, 1) double {mustBePositive, mustBeInteger} = 64
end
if ~isequal(size(RC_H), size(RC_L))
    error('sarvalid:RCMixSizeMismatch', 'H/L RC尺寸不一致。');
end
mode_mask = logical(mode_mask(:).');
if numel(mode_mask) ~= size(RC_H, 2)
    error('sarvalid:RCMixMaskLength', 'H/L掩膜长度必须等于RC列数。');
end

boundaries = find(diff(mode_mask) ~= 0);
if isempty(boundaries)
    if all(mode_mask)
        RC_mix = RC_H;
    else
        RC_mix = RC_L;
    end
    info = struct("boundaries", boundaries, "scale_factor", 1, ...
        "power_H", mean(abs(RC_H(:)).^2), ...
        "power_L", mean(abs(RC_L(:)).^2), ...
        "boundary_jump_db", 0);
    return;
end

power_h = zeros(numel(boundaries), 1);
power_l = zeros(numel(boundaries), 1);
for idx = 1:numel(boundaries)
    boundary = boundaries(idx);
    left = max(1, boundary-buffer+1):boundary;
    right = boundary+1:min(size(RC_H, 2), boundary+buffer);
    if mode_mask(boundary)
        h_indices = left;
        l_indices = right;
    else
        l_indices = left;
        h_indices = right;
    end
    power_h(idx) = mean(abs(RC_H(:, h_indices)).^2, 'all');
    power_l(idx) = mean(abs(RC_L(:, l_indices)).^2, 'all');
end

pooled_h = mean(power_h);
pooled_l = mean(power_l);
if pooled_h <= 1e-12
    scale_factor = 1;
else
    scale_factor = sqrt((pooled_l + eps) / (pooled_h + eps));
end
RC_H_aligned = RC_H * scale_factor;
RC_mix = zeros(size(RC_H), 'like', RC_H);
RC_mix(:, mode_mask) = RC_H_aligned(:, mode_mask);
RC_mix(:, ~mode_mask) = RC_L(:, ~mode_mask);

info = struct();
info.boundaries = boundaries;
info.scale_factor = scale_factor;
info.power_H = pooled_h;
info.power_L = pooled_l;
info.power_H_per_boundary = power_h;
info.power_L_per_boundary = power_l;
info.boundary_jump_db = 10 * log10((pooled_h * scale_factor^2 + eps) / ...
    (pooled_l + eps));
end
